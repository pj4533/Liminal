import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('gates', Path(__file__).with_name('verify-salience-gates.py'))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


class SalienceGateTests(unittest.TestCase):
    def test_absent_evidence_fails(self):
        results = gates.evaluate({}, {})
        self.assertFalse(results['transcriptEvidence']['passed'])
        self.assertFalse(results['freshIndex.salient60']['passed'])
        self.assertFalse(results['evolvingPlayback.500paired']['passed'])

    def test_depleted_playback_does_not_borrow_fresh_index_success(self):
        after = {'footage': [dict(policy=p, indexed=i, picks=500, salient=n, random=r, filmShares={'f': 500})
                 for p, i, n, r in [('freshIndex', False, 100, 500), ('freshIndex', True, 320, 180),
                                     ('evolvingPlayback', False, 20, 500), ('evolvingPlayback', True, 30, 480)]]}
        results = gates.evaluate({}, after)
        self.assertTrue(results['freshIndex.salient60']['passed'])
        self.assertTrue(results['freshIndex.salient2x']['passed'])
        self.assertFalse(results['evolvingPlayback.salient60']['passed'])
        self.assertFalse(results['evolvingPlayback.salient2x']['passed'])
