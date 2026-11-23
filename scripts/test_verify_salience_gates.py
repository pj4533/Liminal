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
        after['footage'][1].update(catalogSalient=100, opportunities=350, rescued=220)
        after['footage'][3].update(catalogSalient=20, opportunities=450, rescued=10)
        results = gates.evaluate({}, after)
        self.assertTrue(results['freshIndex.policyUplift']['passed'])
        self.assertFalse(results['evolvingPlayback.policyUplift']['passed'])
        self.assertTrue(results['freshIndex.salient60']['passed'])
        self.assertTrue(results['freshIndex.salient2x']['passed'])
        self.assertFalse(results['evolvingPlayback.salient60']['passed'])
        self.assertFalse(results['evolvingPlayback.salient2x']['passed'])

    def test_dense_control_uses_policy_supported_uplift_and_reports_original_threshold(self):
        control = dict(policy='freshIndex', indexed=False, picks=500, salient=210, random=500)
        indexed = dict(policy='freshIndex', indexed=True, picks=500, salient=399, random=175,
                       catalogSalient=210, opportunities=290, rescued=189)
        gates_ = gates.evaluate({}, {'footage': [control, indexed]})
        self.assertTrue(gates_['freshIndex.policyUplift']['passed'])
        self.assertFalse(gates_['freshIndex.salient2x']['evidence']['applicable'])
        self.assertFalse(gates_['freshIndex.policyUplift']['evidence']['historicalDoubleMet'])
        self.assertTrue(gates_['freshIndex.salient60']['evidence']['applicable'])
        # Incorrect opportunity accounting cannot qualify a treatment.
        indexed['rescued'] -= 1
        self.assertFalse(gates.evaluate({}, {'footage': [control, indexed]})['freshIndex.policyUplift']['passed'])

    def test_no_worse_over35_does_not_satisfy_original_zero_target(self):
        results = gates.evaluate({'A': {'tightness': {'over35': 12}}},
                                 {'A': {'tightness': {'over35': 10}}})
        self.assertTrue(results['A.over35']['passed'])
        self.assertFalse(results['A.originalZeroOver35']['passed'])
