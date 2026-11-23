import importlib.util
import io
import json
from pathlib import Path
import os
import subprocess
import sys
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


assets = module('private-verification-assets')
runner = module('verify-private-drums')


def wav(path, frames=705600, rate=22050, channels=1, bits=16, encoding=1):
    align = channels * bits // 8
    fmt = struct.pack('<HHIIHH', encoding, channels, rate, rate * align, align, bits)
    data = bytes(frames * align)
    payload = b'WAVEfmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(data)) + data
    path.write_bytes(b'RIFF' + struct.pack('<I', len(payload)) + payload)


class PrivateAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.key = self.root / 'key'
        assets.generate_key(self.key)
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'nested').mkdir()
        self.payload = os.urandom(assets.CHUNK + 73)
        (self.source / 'nested/audio.wav').write_bytes(self.payload)

    def encrypt(self):
        encrypted = self.root / 'archive.enc'
        assets.encrypt(self.source, encrypted, self.key)
        return encrypted

    def test_streaming_roundtrip_preserves_bytes_and_private_modes(self):
        encrypted = self.encrypt()
        output = self.root / 'restored'
        assets.decrypt(encrypted, output, self.key)
        self.assertEqual((output / 'nested/audio.wav').read_bytes(), self.payload)
        self.assertEqual(encrypted.stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((output / 'nested/audio.wav').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)

    def test_tampered_header_nonce_ciphertext_and_tag_never_extract(self):
        encrypted = self.encrypt()
        original = encrypted.read_bytes()
        for index in (0, len(assets.MAGIC), len(assets.MAGIC) + 12 + 20, len(original) - 1):
            with self.subTest(index=index):
                data = bytearray(original); data[index] ^= 1
                encrypted.write_bytes(data)
                with patch.object(assets, 'safe_extract') as extract:
                    with self.assertRaises(Exception): assets.decrypt(encrypted, self.root / 'restored', self.key)
                    extract.assert_not_called()
                self.assertFalse((self.root / 'restored').exists())
                self.assertFalse(list(self.root.glob('.private-auth-*')))

    def test_wrong_key_and_truncation_never_extract(self):
        encrypted = self.encrypt()
        wrong = self.root / 'wrong'; assets.generate_key(wrong)
        with self.assertRaises(Exception): assets.decrypt(encrypted, self.root / 'restored', wrong)
        data = encrypted.read_bytes()
        for size in (0, len(assets.MAGIC) + 5, len(data) - 1, len(data) // 2):
            with self.subTest(size=size):
                encrypted.write_bytes(data[:size])
                with self.assertRaises(Exception): assets.decrypt(encrypted, self.root / 'restored', self.key)
                self.assertFalse((self.root / 'restored').exists())

    def test_each_archive_uses_a_fresh_nonce(self):
        first = self.encrypt().read_bytes()
        second = self.root / 'second.enc'; assets.encrypt(self.source, second, self.key)
        self.assertNotEqual(first[:len(assets.MAGIC) + 12], second.read_bytes()[:len(assets.MAGIC) + 12])

    def test_existing_output_and_key_are_never_overwritten(self):
        encrypted = self.encrypt(); original = encrypted.read_bytes()
        with self.assertRaises(FileExistsError): assets.encrypt(self.source, encrypted, self.key)
        self.assertEqual(encrypted.read_bytes(), original)
        original_key = self.key.read_bytes()
        with self.assertRaises(FileExistsError): assets.generate_key(self.key)
        self.assertEqual(self.key.read_bytes(), original_key)
        output = self.root / 'restored'; output.mkdir()
        (output / 'keep').write_bytes(b'keep')
        with self.assertRaises(ValueError): assets.decrypt(encrypted, output, self.key)
        self.assertEqual((output / 'keep').read_bytes(), b'keep')

    def test_key_permissions_symlink_and_length_fail_closed(self):
        self.key.chmod(0o644)
        with self.assertRaises(ValueError): self.encrypt()
        self.key.chmod(0o600)
        alias = self.root / 'alias'; alias.symlink_to(self.key)
        with self.assertRaises(ValueError): assets.read_key(alias)
        self.key.write_bytes(b'short')
        with self.assertRaises(ValueError): self.encrypt()

    def test_key_inside_archive_and_symlink_members_are_rejected(self):
        internal = self.source / 'key'; assets.generate_key(internal)
        with self.assertRaises(ValueError): assets.encrypt(self.source, self.root / 'archive.enc', internal)
        internal.unlink()
        (self.source / 'link').symlink_to(self.key)
        with self.assertRaises(ValueError): self.encrypt()
        self.assertFalse((self.root / 'archive.enc').exists())
        with self.assertRaises(ValueError): assets.encrypt(self.source, self.source / 'archive.enc', self.key)

    def test_tar_traversal_links_devices_directories_and_duplicates_rejected_before_writes(self):
        for name, kind in [('../escape', tarfile.REGTYPE), ('/escape', tarfile.REGTYPE),
                           ('nested/../../escape', tarfile.REGTYPE), ('nested\\escape', tarfile.REGTYPE),
                           ('link', tarfile.SYMTYPE), ('hardlink', tarfile.LNKTYPE),
                           ('device', tarfile.CHRTYPE), ('directory', tarfile.DIRTYPE),
                           ('valid', tarfile.REGTYPE)]:
            with self.subTest(name=name, kind=kind):
                archive = self.root / 'attack.tar'
                with tarfile.open(archive, 'w') as tar:
                    regular = tarfile.TarInfo('valid'); regular.size = 1
                    tar.addfile(regular, io.BytesIO(b'a'))
                    member = tarfile.TarInfo(name); member.type = kind
                    member.linkname = '../escape'
                    tar.addfile(member)
                with self.assertRaises(ValueError): assets.safe_extract(archive, self.root / 'restored')
                self.assertFalse((self.root / 'restored').exists())
                self.assertFalse((self.root / 'escape').exists())

    def test_known_names_and_vol2_space_bpm_normalize(self):
        for source, name, bpm in [
            ('@AJHALL89_DRUM_BREA_BUBBA_KUSH_71_BPM.wav', 'BUBBA_KUSH', 71),
            ('@AJHALL89_DRUM_BREAK_BISCOFF_BUTTER_73_BPM!.wav', 'BISCOFF_BUTTER', 73),
            ('A.J._HALL_DRUM_BREAK_FINN_72 BPM.wav', 'FINN', 72),
            ('A.J._HALL__DRUM_BREAK_LORD_LORD_67_BPM.wav', 'LORD_LORD', 67),
        ]:
            self.assertEqual(assets.canonical_name(source), (f'AJ_HALL_DRUM_BREAK_{name}_{bpm}_BPM', bpm))
        with self.assertRaises(ValueError): assets.canonical_name('random.wav')

    def test_riff_pcm_float_truncation_and_frame_metadata(self):
        for encoding, bits in [(1, 16), (1, 24), (3, 32)]:
            path = self.root / 'fixture.wav'
            wav(path, 100, 48000, 2, bits, encoding)
            self.assertEqual(assets.wav_metadata(path), dict(channels=2, sampleRate=48000, frameCount=100))
            path.write_bytes(path.read_bytes()[:-1])
            with self.assertRaises(ValueError): assets.wav_metadata(path)

    def test_prepare_selects_eligible_preserves_bytes_and_records_exclusion(self):
        original = self.root / 'original'; pack = original / 'pack/breaks'; pack.mkdir(parents=True)
        good = pack / 'AJ_HALL_DRUM_BREAK_GOOD_120_BPM.wav'; wav(good)
        excluded = pack / 'AJ_HALL_DRUM_BREAK_SHORT_120_BPM.wav'; wav(excluded, frames=100)
        output = self.root / 'bundle'
        with patch.object(assets, 'PACKS', (('pack', 'breaks', 2, 1),)):
            provenance = assets.prepare(original, output)
        self.assertEqual(provenance['packs'], [dict(volume=1, original=2, eligible=1)])
        copied = output / assets.DRUMS / good.name
        self.assertEqual(copied.read_bytes(), good.read_bytes())
        entries = json.loads((output / assets.GRID).read_text())
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['sha256'], assets.sha256(good))
        self.assertEqual(entries[0]['framesPerBeat'], 705600 / 64)
        self.assertEqual(provenance['files'][1]['exclusion'], 'not 64 beats within two frames')

    def test_bad_expected_inventory_leaves_no_partial_bundle(self):
        original = self.root / 'original'; pack = original / 'pack/breaks'; pack.mkdir(parents=True)
        output = self.root / 'bundle'
        with patch.object(assets, 'PACKS', (('pack', 'breaks', 25, 20),)):
            with self.assertRaises(ValueError): assets.prepare(original, output)
        self.assertFalse(output.exists())

    def test_install_rejects_incomplete_inventory_and_traversal_name(self):
        bundle = self.root / 'bundle'; (bundle / assets.GRID).parent.mkdir(parents=True)
        (bundle / assets.GRID).write_text('[]')
        (bundle / 'provenance.json').write_text(json.dumps(dict(eligible=100, beatGridSHA256=assets.sha256(bundle / assets.GRID))))
        with self.assertRaises(ValueError): assets.install(bundle, [self.root / 'checkout'])
        rows = [dict(name='../escape')] * 100
        (bundle / assets.GRID).write_text(json.dumps(rows))
        (bundle / 'provenance.json').write_text(json.dumps(dict(eligible=100, beatGridSHA256=assets.sha256(bundle / assets.GRID))))
        with self.assertRaises(ValueError): assets.install(bundle, [self.root / 'checkout'])

    def test_public_inventory_drops_private_paths_text_and_transcription_failure_is_unmet(self):
        value = dict(complete=False, error='private/source.wav', rawStrictPassed=False, noNewTargetedFailures=None,
                     cases=dict(transcribe=dict(complete=False, transcriptionReady=False,
                         rawStrictPassed=False, noNewTargetedFailures=None, error='private dialogue text')))
        result = runner.sanitized_inventory(value)
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(result['cases']['transcribe']['status'], 'UNMET')
        self.assertFalse(result['rawStrictPassed'])

    def test_numeric_criteria_allowlist_cannot_publish_transcript_or_arbitrary_fields(self):
        report = dict(criteria=[dict(id='C-D9', status='fail', level='fail',
            values=dict(emptyBars=3, privateText='licensed words', arbitrary=12, maxOccupancy=float('inf')),
            notes='private transcript'), dict(id='private source name', status='pass', values={})])
        rows = runner.sanitized_criteria(report, {'C-D9'}, {'emptyBars', 'privateText', 'maxOccupancy'})
        self.assertEqual(rows, [dict(id='C-D9', status='fail', level='fail', values=dict(emptyBars=3))])
        self.assertNotIn('licensed', json.dumps(rows))

    def test_missing_remote_evidence_produces_unmet_sanitized_summary(self):
        repo = Path(__file__).resolve().parents[1]
        bundle = self.root / 'bundle'; bundle.mkdir()
        provenance = dict(scope='Fresh regenerated corpus', original=112, eligible=100, excluded=12,
            packs=[], beatGridSHA256='a'*64, bytePreserved=True, files=[dict(sha256='b'*64)])
        (bundle / 'provenance.json').write_text(json.dumps(provenance))
        out = self.root / 'run'
        result = subprocess.run([sys.executable, str(repo / 'scripts/verify-private-drums.py'), 'final',
            '--after', str(repo), '--baseline', str(repo), '--out', str(out), '--bundle', str(bundle)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        summary = json.loads((out / 'sanitized/summary.json').read_text())
        self.assertEqual(summary['status'], 'UNMET')
        self.assertFalse(summary['matrices']['after']['cases']['transcribe']['complete'])
        self.assertNotIn(str(self.root), json.dumps(summary))
        self.assertNotIn('error', json.dumps(summary))

    def test_workflow_only_triggers_approved_execute_push_and_has_safe_artifact_paths(self):
        path = Path(__file__).resolve().parents[1] / '.github/workflows/private-drum-verification.yml'
        text = path.read_text()
        self.assertIn("branches: ['verify/private-execute/**']", text)
        self.assertNotIn("branches: ['verify/dialogue-private-20261123']", text)
        self.assertNotIn('pull_request', text)
        self.assertIn("github.ref == 'refs/heads/verify/dialogue-private-20261123'", text)
        self.assertEqual(text.count('uses: actions/upload-artifact@v4'), 2)
        self.assertIn('path: ${{ runner.temp }}/private-verification/sanitized/summary.json', text)
        self.assertIn('path: ${{ runner.temp }}/private-evidence.enc', text)
        self.assertNotIn('path: ${{ runner.temp }}/private-verification/raw', text)
        self.assertIn('Remove runner plaintext, private build resources and key\n        if: always()', text)
        self.assertIn('unset PRIVATE_KEY_B64\n          python3', text)


if __name__ == '__main__': unittest.main()
