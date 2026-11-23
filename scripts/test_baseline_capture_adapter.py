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

    def test_public_fixture_adapter_matches_candidate_normalization_and_requires_pristine_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = Path('Liminal/Audio/Lofi/LofiDrumLibrary.swift')
            fixture = Path('LiminalTests/LofiMixRenderTests.swift')
            for path in (library, fixture):
                (root/path).parent.mkdir(parents=True, exist_ok=True)
                (root/path).write_bytes(subprocess.check_output(['git', 'show', '47a01fe:'+str(path)], cwd=ROOT))
            adapter.adapt_public_fixture(root)
            self.assertEqual((root/library).read_bytes(), (ROOT/library).read_bytes())
            self.assertIn('return LofiDrumLibrary.normalizedBreak(entry: entry, left: left, right: right)',
                          (root/fixture).read_text())
            self.assertIn('public-test-fixture-v2', (root/fixture).read_text())
            with self.assertRaises(ValueError):
                adapter.adapt_public_fixture(root)
            adapter.adapt_event_gain(root)
            self.assertIn('"authoredGainDB": e.gainDB', (root/fixture).read_text())

    def test_event_gain_adapter_preserves_the_private_baseline_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = 'LiminalTests/LofiMixRenderTests.swift'
            path = root / source
            path.parent.mkdir()
            before = subprocess.check_output(['git', 'show', '47a01fe:' + source], cwd=ROOT)
            path.write_bytes(before)
            adapter.adapt_event_gain(root)
            after = path.read_bytes()
            self.assertEqual(after.replace(b' "authoredGainDB": e.gainDB,', b''), before)
            with self.assertRaises(ValueError):
                adapter.adapt_event_gain(root)
            self.assertEqual(path.read_bytes(), after)

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
