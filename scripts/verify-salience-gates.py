#!/usr/bin/env python3
"""Evaluate unchanged plan gates on a paired, provenance-recorded real dataset."""
import json
import sys


def evaluate(before, after):
    gates = {}
    def gate(name, passed, evidence):
        gates[name] = dict(passed=bool(passed), evidence=evidence)
    gate('transcriptEvidence', before.get('transcribed', 0) > 0 and after.get('transcribed', 0) > 0,
         [before.get('transcribed', 0), after.get('transcribed', 0)])
    for mode, ceiling in [('T', .05), ('A', .20)]:
        b, a = before.get(mode, {}), after.get(mode, {})
        accidental = a.get('categories', {}).get('accidental', 1)
        gate(f'{mode}.accidental', accidental <= ceiling, accidental)
        gate(f'{mode}.functionOnly', a.get('functionOnly', 1) <= .08, a.get('functionOnly'))
        for key in ('halvesOfFunctionWords', 'halvesInsideOneSyllableWords', 'initialismCutsOffLetter'):
            value = a.get('splitChecks', {}).get(key)
            gate(f'{mode}.{key}', value == 0, value)
        bt, at = b.get('tightness', {}), a.get('tightness', {})
        medians = [bt.get('median'), at.get('median')]
        gate(f'{mode}.tightnessMedian', None not in medians and abs(medians[1] - medians[0]) <= 2, medians)
        gate(f'{mode}.originalZeroOver35', at.get('over35') == 0, at.get('over35'))
        gate(f'{mode}.over35', at.get('over35', float('inf')) <= bt.get('over35', -1), [bt.get('over35'), at.get('over35')])
        bv, av = b.get('variety') or {}, a.get('variety') or {}
        gate(f'{mode}.sameCutPairs', av.get('chopSamePairs', float('inf')) <= bv.get('chopSamePairs', -1),
             [bv.get('chopSamePairs'), av.get('chopSamePairs')])
    t = after.get('T', {})
    for name, ceiling in [('functionOnly', .03), ('noWordHeard', .05), ('bestHeardBelow0.5', .45), ('untextedLines', 8)]:
        value = t.get(name)
        gate('T.stage2.' + name, value is not None and value <= ceiling, value)
    for name, minimum in [('salientHeard', .35), ('salientWhole', .25), ('lineInterestMedian', .60)]:
        value = t.get(name)
        gate('T.stage2.' + name, value is not None and value >= minimum, value)
    words = after.get('salientWords', {})
    for name, minimum in [('inRankedLine', 110), ('inChosenLine', 50)]:
        value = words.get(name)
        gate('T.stage2.' + name, value is not None and value >= minimum, dict(value=value, denominator=words.get('inWindows'), historicalDenominator=159))
    protected = sum(v for k, v in words.get('unrankedReasons', {}).items() if 'protectedCut' in k)
    gate('T.stage2.protectedCut', bool(words) and protected <= 10, protected)
    passed = after.get('strikingPassedOver', {}).get('passedOver')
    gate('T.stage2.strikingPassedOver', passed is not None and passed <= 5, passed)
    bv, av = before.get('T', {}).get('variety') or {}, t.get('variety') or {}
    gate('T.longestRun', av.get('chopLongestRunMax', float('inf')) <= bv.get('chopLongestRunMax', -1),
         [bv.get('chopLongestRunMax'), av.get('chopLongestRunMax')])
    gate('T.threeCutsWhereOffered', av.get('cellsUnder3WhereOffered') == 0 and av.get('cellsWhereOffered', 0) > 0,
         [av.get('cellsUnder3WhereOffered'), av.get('cellsWhereOffered')])
    content = [v for k, v in after.get('reheard', {}).items() if k.startswith('piece/')]
    heard = sum(r.get('mainWord', 0) for r in content)
    total = sum(r.get('n', 0) for r in content)
    gate('T.reheardMainContentWord', total > 0 and heard / total >= .60, [heard, total])
    # Both experiments remain visible. Fresh index is policy sampling; evolving playback is the
    # finite learned-pool depletion stress test. Failure is never hidden by resetting its ledger.
    for policy in ('freshIndex', 'evolvingPlayback'):
        rows = {r['indexed']: r for r in after.get('footage', []) if r.get('policy') == policy}
        baseline, indexed = rows.get(False, {}), rows.get(True, {})
        bn, an = baseline.get('picks', 0), indexed.get('picks', 0)
        bshare = baseline.get('salient', 0) / max(1, bn)
        ashare = indexed.get('salient', 0) / max(1, an)
        gate(f'{policy}.500paired', bn == 500 and an == 500, [bn, an])
        gate(f'{policy}.salient2x', an > 0 and ashare >= 2 * bshare, [bshare, ashare])
        gate(f'{policy}.salient60', an > 0 and ashare >= .60, ashare)
        random = indexed.get('random', 0) / max(1, an)
        gate(f'{policy}.random25', an > 0 and random >= .25, random)
        shares = indexed.get('filmShares', {})
        for film, count in baseline.get('filmShares', {}).items():
            gate(f'{policy}.film.{film}', shares.get(film, 0) / max(1, an) >= .5 * count / max(1, bn),
                 [count, shares.get(film, 0)])
    return gates


if __name__ == '__main__':
    before, after = [json.load(open(p)) for p in sys.argv[1:3]]
    gates = evaluate(before, after)
    result = dict(passed=all(g['passed'] for g in gates.values()), gates=gates,
                  denominators=dict(beforeWindows=before.get('windows'), afterWindows=after.get('windows'),
                                    beforeSalientWords=before.get('salientWords'), afterSalientWords=after.get('salientWords')),
                  limitation='Evolving playback conservatively consumes all completely contained salient lines; no speculative rescanning. Historical 159-word dataset identity is unknown.')
    with open(sys.argv[3], 'w') as output:
        json.dump(result, output, indent=2)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
