import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('capture_adapter', Path(__file__).with_name('prepare-baseline-capture.py'))
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
ROOT = Path(__file__).resolve().parents[1]


class BaselineCaptureAdapterTests(unittest.TestCase):
    def test_genuine_baseline_changes_only_to_reviewed_hosted_signing_harness(self):
        source = subprocess.check_output(['git', 'show', '47a01fe267a3972241ed6918d031fffe55f26ed2:scripts/check-lofi.sh'], cwd=ROOT)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            path = root / 'scripts/check-lofi.sh'
            path.write_bytes(source)
            adapter.adapt(root)
            self.assertEqual(path.read_bytes(), (ROOT / 'scripts/check-lofi.sh').read_bytes())
            with self.assertRaises(ValueError): adapter.adapt(root)

    def test_unexpected_historical_source_is_rejected_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            path = root / 'scripts/check-lofi.sh'
            source = b'unexpected harness'
            path.write_bytes(source)
            with self.assertRaises(ValueError): adapter.adapt(root)
            self.assertEqual(path.read_bytes(), source)


if __name__ == '__main__': unittest.main()
