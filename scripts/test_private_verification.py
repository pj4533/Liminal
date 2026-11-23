import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import struct
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

    def test_summary_inventory_drops_private_paths_text_and_transcription_failure_is_unmet(self):
        value = dict(complete=False, error='private/source.wav', rawStrictPassed=False, noNewTargetedFailures=None,
                     cases=dict(transcribe=dict(complete=False, transcriptionReady=False,
                         rawStrictPassed=False, noNewTargetedFailures=None, error='private dialogue text')))
        result = runner.sanitized_inventory(value)
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(result['cases']['transcribe']['status'], 'UNMET')
        self.assertFalse(result['rawStrictPassed'])

    def test_numeric_criteria_summary_omits_transcript_or_arbitrary_fields(self):
        report = dict(criteria=[dict(id='C-D9', status='fail', level='fail',
            values=dict(emptyBars=3, privateText='licensed words', arbitrary=12, maxOccupancy=float('inf')),
            notes='private transcript'), dict(id='private source name', status='pass', values={})])
        rows = runner.sanitized_criteria(report, {'C-D9'}, {'emptyBars', 'privateText', 'maxOccupancy'})
        self.assertEqual(rows, [dict(id='C-D9', status='fail', level='fail', values=dict(emptyBars=3))])
        self.assertNotIn('licensed', json.dumps(rows))

    def test_missing_local_evidence_produces_unmet_sanitized_summary(self):
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

if __name__ == '__main__': unittest.main()
