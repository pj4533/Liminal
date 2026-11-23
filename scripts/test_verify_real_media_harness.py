import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class MediaHarnessPrerequisiteTests(unittest.TestCase):
    def run_harness(self, preparation_exit=0, compiler_exit=0, phase="prepare"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            after, baseline, output, binaries = [root / name for name in ('after', 'baseline', 'output', 'bin')]
            for path in (after, baseline, binaries):
                path.mkdir()
            trace = root / 'calls.txt'
            for name, code in [('python3', preparation_exit), ('xcrun', compiler_exit)]:
                executable = binaries / name
                executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "{name}" >> "{trace}"\nexit {code}\n')
                executable.chmod(0o755)
            env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'])
            script = Path(__file__).with_name('verify-real-media.sh').resolve()
            result = subprocess.run(['bash', str(script), str(after), str(baseline), str(output), phase],
                                    env=env, text=True, capture_output=True)
            return result.returncode, trace.read_text().splitlines(), (output / 'steps.tsv').read_text()

    def test_failed_media_preparation_does_not_launch_model_build_or_captures(self):
        code, calls, status = self.run_harness(preparation_exit=23)
        self.assertEqual(code, 23)
        self.assertEqual(calls, ['python3'])
        self.assertIn('prepare-media\t23', status)

    def test_failed_model_compiler_does_not_launch_provisioning_or_captures(self):
        code, calls, status = self.run_harness(compiler_exit=29, phase="speech")
        self.assertEqual(code, 29)
        self.assertEqual(calls, ['xcrun'])
        self.assertIn('compile-provisioner\t29', status)

    def test_failed_compiler_adapter_assertion_cannot_be_masked_by_successful_git_diff(self):
        import sys
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            after, baseline, output, binaries = [root / n for n in ('after', 'baseline', 'output', 'bin')]
            for tree in (after, baseline): (tree / 'scripts').mkdir(parents=True)
            binaries.mkdir()
            (after/'scripts/prepare-verification-media.py').write_text('pass\n')
            import shutil
            shutil.copy(Path(__file__).with_name('prepare-baseline-compiler.py'), after/'scripts/prepare-baseline-compiler.py')
            for name in ('mix-matrix.sh', 'dialogue-salience-report.py', 'baseline-probe-measurement.patch'):
                (after/'scripts'/name).write_text('measurement adapter\n')
            voice = baseline/'Liminal/Audio/Lofi/LofiBassVoice.swift'
            voice.parent.mkdir(parents=True); voice.write_text('unexpected baseline source')
            trace = root/'git-calls'
            git = binaries/'git'
            git.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{trace}"\nexit 0\n'); git.chmod(0o755)
            env = dict(os.environ, PATH=str(binaries)+os.pathsep+os.environ['PATH'])
            script = Path(__file__).with_name('verify-real-media.sh').resolve()
            result = subprocess.run(['bash', str(script), str(after), str(baseline), str(output), 'prepare'], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('baseline-compiler-adapter\t1', (output/'steps.tsv').read_text())
            self.assertNotIn(' diff', trace.read_text())

    def test_required_transcribe_skip_fails_even_when_matrix_summary_passes(self):
        import json
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'scripts').mkdir()
            shutil.copy(Path(__file__).with_name('mix-matrix.sh'), root/'scripts/mix-matrix.sh')
            (root/'scripts/mix-report.py').write_text('pass\n')
            out = root/'matrix'
            for case in ('ref', 'fast', 'same', 'transcribe'):
                target=out/case; (target/'report').mkdir(parents=True)
                (target/'manifest.json').write_text(json.dumps(dict(dialogueTranscripts=[dict(status='ready', words=0, transcriptUsed=False)])))
                (target/'report/mix-report.json').write_text('{}')
            result=subprocess.run(['bash', str(root/'scripts/mix-matrix.sh'), '--out', str(out), '--cases', 'ref,fast,same,transcribe', '--strict'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((out/'transcribe/skipped.txt').is_file())
