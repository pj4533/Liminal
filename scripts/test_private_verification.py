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
cleanup = module('private-verification-cleanup')
transport = module('private-ciphertext-download')


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

    def test_final_requires_successful_phase_exits_even_with_passing_reports(self):
        repo = Path(__file__).resolve().parents[1]
        bundle = self.root / 'bundle'; bundle.mkdir()
        (bundle / 'provenance.json').write_text(json.dumps(dict(scope='Fresh', original=112,
            eligible=100, excluded=12, packs=[], beatGridSHA256='a'*64, bytePreserved=True, files=[])))
        out = self.root / 'run'; raw = out / 'raw'; raw.mkdir(parents=True)
        for label, revision in [('baseline', runner.BASELINE), ('after', 'candidate')]:
            (raw / (label + '-native.json')).write_text(json.dumps(dict(exit=0,
                resourceIdentity=True, coverage=dict(passed=True))))
            for case in ('ref', 'fast', 'same', 'transcribe'):
                directory = raw / (label + '-matrix') / case
                (directory / 'report').mkdir(parents=True)
                (directory / 'manifest.json').write_text(json.dumps(dict(gitRevision=revision,
                    dialogueTranscripts=[dict(status='ready', words=10, transcriptUsed=True)])))
                (directory / 'report/mix-report.json').write_text(json.dumps(dict(criteria=[
                    dict(id='C-D9', level='fail', status='pass', values=dict(emptyBars=0))])))
        passing = [dict(step=name, exit=0) for name in runner.REQUIRED_STEPS]
        variants = [('success', passing, 0),
                    ('matrix failure', [dict(row, exit=1) if row['step'].endswith('-matrix') else row for row in passing], 1),
                    ('missing timeout completion', [row for row in passing if row['step'] != 'baseline-matrix'], 1),
                    ('explicit timeout', [dict(row, exit=124) if row['step'] == 'after-matrix' else row for row in passing], 1),
                    ('duplicate completion', passing + [dict(step='after-matrix', exit=0)], 1)]
        for name, rows, expected in variants:
            with self.subTest(name=name):
                (raw / 'steps.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
                argv = ['verify-private-drums.py', 'final', '--after', str(repo), '--baseline', str(repo),
                        '--out', str(out), '--bundle', str(bundle)]
                with patch.object(sys, 'argv', argv), patch.object(runner.subprocess, 'check_output',
                        side_effect=[runner.BASELINE + '\n', 'candidate\n']), patch('builtins.print'):
                    self.assertEqual(runner.main(), expected)
                summary = json.loads((out / 'sanitized/summary.json').read_text())
                self.assertTrue(summary['matrices']['after']['rawStrictPassed'])
                self.assertEqual(summary['status'], 'VERIFIED' if expected == 0 else 'UNMET')
        (raw / 'steps.jsonl').write_text('malformed ledger')
        self.assertFalse(runner.phase_status(raw)['passed'])

    def test_cleanup_removes_capture_caches_and_targeted_diagnostics_only(self):
        home = self.root / 'home'; system = self.root / 'system-diagnostics'
        out = self.root / 'out'; workspace = self.root / 'workspace'
        for cache in cleanup.capture_caches(home):
            cache.mkdir(parents=True)
            (cache / 'orphan-private.wav').write_bytes(b'private')
        reports = home / 'Library/Logs/DiagnosticReports'; reports.mkdir(parents=True)
        targeted = reports / 'Liminal-2026.ips'; targeted.write_text('private crash data')
        unrelated = reports / 'OtherApp-2026.ips'; unrelated.write_text('keep')
        cleanup.collect(out, home, system)
        collected = list((out / 'raw/runner-diagnostics').iterdir())
        self.assertEqual(len(collected), 1)
        self.assertEqual(collected[0].read_text(), 'private crash data')
        self.assertEqual(collected[0].stat().st_mode & 0o777, 0o600)
        with patch.object(cleanup.os, 'getuid', return_value=999999):
            cleanup.clean(out, workspace, home, system)
        self.assertFalse(targeted.exists())
        self.assertTrue(unrelated.exists())
        self.assertFalse(out.exists())
        self.assertTrue(all(not path.exists() for path in cleanup.capture_caches(home)))

    def test_workflow_only_triggers_approved_execute_push_and_has_safe_artifact_paths(self):
        path = Path(__file__).resolve().parents[1] / '.github/workflows/private-drum-verification.yml'
        text = path.read_text()
        self.assertIn("branches: ['verify/private-execute/**']", text)
        self.assertNotIn("branches: ['verify/dialogue-private-20261123']", text)
        self.assertNotIn('pull_request', text)
        self.assertIn('secrets.LIMINAL_PRIVATE_DRUMS_URL_20261123', text)
        self.assertNotIn('GH_TOKEN:', text)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('releases/tags/', text)
        self.assertIn('group: private-drums-pj4533-liminal', text)
        self.assertNotIn('group: private-drums-${{ github.run_id }}', text)
        self.assertIn('private-verification-cleanup.py clean', text)
        self.assertIn("github.ref == 'refs/heads/verify/dialogue-private-20261123'", text)
        self.assertEqual(text.count('uses: actions/upload-artifact@v4'), 2)
        self.assertIn('path: ${{ runner.temp }}/private-verification/sanitized/summary.json', text)
        self.assertIn('path: ${{ runner.temp }}/private-evidence.enc', text)
        self.assertNotIn('path: ${{ runner.temp }}/private-verification/raw', text)
        self.assertIn('Remove runner plaintext, private build resources and key\n        if: always()', text)
        self.assertIn('unset PRIVATE_KEY_B64\n          python3', text)


class CiphertextTransportTests(unittest.TestCase):
    def url(self, host='release-assets.githubusercontent.com', minutes=60):
        import datetime
        expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=minutes)
        return 'https://' + host + '/asset?se=' + expires.isoformat().replace('+00:00', 'Z') + '&sig=private-capability'

    def test_url_host_scheme_expiry_credentials_and_fragment_fail_closed(self):
        transport.validate_url(self.url())
        for value in [self.url('evil.example'), self.url(minutes=29), self.url().replace('https:', 'http:'),
                      self.url().replace('https://', 'https://user@'), self.url() + '#fragment',
                      'https://release-assets.githubusercontent.com/asset?se=bad']:
            with self.subTest(value=value), self.assertRaises(ValueError): transport.validate_url(value)

    def test_owner_capture_stores_only_one_validated_location_privately(self):
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'url'
            value = self.url()
            result = Mock(returncode=0, stdout=('> Authorization: redacted\n< Location: ' + value + '\n').encode(), stderr=b'')
            with patch.object(transport.subprocess, 'run', return_value=result):
                transport.capture('783833664', output)
            self.assertEqual(output.read_text(), value)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            output.unlink()
            for data in (b'HTTP 200', ('Location: ' + value + '\nLocation: ' + value).encode()):
                result.stdout = data
                with patch.object(transport.subprocess, 'run', return_value=result), self.assertRaises(ValueError):
                    transport.capture('783833664', output)
                self.assertFalse(output.exists())

    def test_download_hash_mismatch_network_errors_and_redirects_never_leak_capability(self):
        import hashlib
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'fixtures.enc'
            opener = Mock(); opener.open.return_value = io.BytesIO(b'ciphertext')
            transport.download(self.url(), output, hashlib.sha256(b'ciphertext').hexdigest(), opener)
            self.assertEqual(output.read_bytes(), b'ciphertext')
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            output.unlink()
            for error in (False, True):
                opener = Mock()
                if error: opener.open.side_effect = RuntimeError(self.url())
                else: opener.open.return_value = io.BytesIO(b'tampered')
                with self.assertRaises(ValueError) as caught:
                    transport.download(self.url(), output, 'a'*64, opener)
                self.assertNotIn('private-capability', str(caught.exception))
                self.assertFalse(output.exists())
                self.assertFalse(output.with_name('fixtures.enc.download').exists())
            with self.assertRaises(ValueError): transport.NoRedirect().redirect_request(None, None, 302, None, None, self.url('evil.example'))


if __name__ == '__main__': unittest.main()
