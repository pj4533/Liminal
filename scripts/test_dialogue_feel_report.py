import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('feel_report', pathlib.Path(__file__).with_name('dialogue-feel-report.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class FeelReportTests(unittest.TestCase):
    def row(self, seed=1, loop=0, positions=None):
        return {'film': 'fixture', 'seed': seed, 'loop': loop, 'line': str(loop),
                'moves': {m: positions or [32] for m in ['reverse', 'rest', 'roll', 'stutter', 'quiet']},
                'grid': [str(p) for p in positions or [32]], 'hookRecurrence': 1.0}

    def test_identical_grids_and_positions_are_measured_as_repeated(self):
        result = report.summarize([self.row(seed, loop) for seed in [1, 2] for loop in [0, 1]])
        self.assertEqual(result['pairs'], 2)
        self.assertEqual(result['reverse']['repeatGivenPrevious'], 1)
        self.assertEqual(result['reverse']['positionPredictability'], 1)
        self.assertEqual(result['consecutiveGridSimilarity'], 1)
        self.assertEqual(result['crossLinePairs'], 2)

    def test_disjoint_grids_have_no_recurrence(self):
        result = report.summarize([self.row(1, 0, [32]), self.row(1, 1, [64])])
        self.assertEqual(result['reverse']['repeatGivenPrevious'], 0)
        self.assertEqual(result['consecutiveGridSimilarity'], 0)

    def test_chop_beat_scope_excludes_surrounding_arc_positions(self):
        result = report.summarize([self.row(1, 0, [16, 32]), self.row(1, 1, [32, 96])])
        self.assertEqual(result['consecutiveGridSimilarity'], 1 / 3)
        self.assertEqual(result['chopBeat']['consecutiveGridSimilarity'], 1)
        self.assertEqual(result['chopBeat']['reverse']['count'], 2)
        self.assertEqual(result['chopBeat']['reverse']['positions'], {32: 2})

    def test_log_and_attachment_duplicates_are_not_counted_twice(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            text = 'prefix FEEL-METRIC ' + json.dumps(self.row()) + '\n'
            (root / 'a.txt').write_text(text)
            (root / 'b.txt').write_text(text)
            self.assertEqual(len(report.read_records(root)), 1)


if __name__ == '__main__':
    unittest.main()
