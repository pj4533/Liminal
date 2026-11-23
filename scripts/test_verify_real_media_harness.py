import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class MediaHarnessPrerequisiteTests(unittest.TestCase):
    def run_harness(self, preparation_exit=0, compiler_exit=0):
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
            result = subprocess.run(['bash', str(script), str(after), str(baseline), str(output)],
                                    env=env, text=True, capture_output=True)
            return result.returncode, trace.read_text().splitlines(), (output / 'steps.tsv').read_text()

    def test_failed_media_preparation_does_not_launch_model_build_or_captures(self):
        code, calls, status = self.run_harness(preparation_exit=23)
        self.assertEqual(code, 23)
        self.assertEqual(calls, ['python3'])
        self.assertIn('prepare-media\t23', status)

    def test_failed_model_compiler_does_not_launch_provisioning_or_captures(self):
        code, calls, status = self.run_harness(compiler_exit=29)
        self.assertEqual(code, 29)
        self.assertEqual(calls, ['python3', 'xcrun'])
        self.assertIn('compile-provisioner\t29', status)
