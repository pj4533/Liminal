#!/usr/bin/env python3
"""Inventory required cases and keep raw strict and paired targeted results distinct."""
import json
from pathlib import Path
import sys

from mixlib import strict_failures

REQUIRED = ('ref', 'fast', 'same', 'transcribe')
CRITERIA_LEVELS = {row['id']: row['level'] for row in json.loads(
    Path(__file__).with_name('mix-criteria.json').read_text())['criteria']}

TARGETED_LEVELS = {
    'C-B8': 'fail', 'C-B9': 'fail',
    'C-D1': 'fail', 'C-D2': 'fail', 'C-D3': 'warn',
    'C-D4': 'fail', 'C-D5': 'fail', 'C-D6': 'fail',
    'C-D7': 'warn', 'C-D8': 'warn', 'C-D9': 'fail',
}
SHARED_SKIP_REASONS = {
    'C-D4': ('rests: not applicable in motif mode: the user direction of 19 November 2026 '
             'puts a piece in every bar (C-D9 gates it)'),
    'C-D7': 'hookSamePadFraction: no echo-family block (no repeated hook statement) in this capture',
}


def no_new_targeted_failures(baseline, candidate):
    before = {row['id']: row for row in baseline if row['id'] in TARGETED_LEVELS}
    after = {row['id']: row for row in candidate if row['id'] in TARGETED_LEVELS}
    for criteria, targeted in ((baseline, before), (candidate, after)):
        if targeted.keys() != TARGETED_LEVELS.keys():
            return False
        if sum(row['id'] in TARGETED_LEVELS for row in criteria) != len(targeted):
            return False
    for criterion, level in TARGETED_LEVELS.items():
        previous, current = before[criterion], after[criterion]
        if previous.get('level') != level or current.get('level') != level:
            return False
        statuses = previous.get('status'), current.get('status')
        if 'skipped' in statuses:
            reason = SHARED_SKIP_REASONS.get(criterion)
            if (statuses != ('skipped', 'skipped') or reason is None
                    or previous.get('reason') != reason or current.get('reason') != reason):
                return False
            continue
        if level == 'warn':
            if not all(status in ('pass', 'warn') for status in statuses):
                return False
        elif statuses not in (('pass', 'pass'), ('fail', 'pass'), ('fail', 'fail')):
            return False
    return True


def inventory(root, baseline=None, revision=None, baseline_revision=None):
    baseline_complete = baseline and inventory(baseline, revision=baseline_revision)['complete']
    cases = {}
    for case in REQUIRED:
        directory = root / case
        try:
            manifest = json.loads((directory / 'manifest.json').read_text())
            report = json.loads((directory / 'report/mix-report.json').read_text())
            criteria = report['criteria']
            ready = case != 'transcribe' or any(r.get('status') == 'ready' and r.get('words', 0) > 0 and r.get('transcriptUsed') is True and not r.get('error') for r in manifest.get('dialogueTranscripts', []))
            revision_matches = bool(revision) and manifest.get('gitRevision') == revision
            measured = {row['id']: row['level'] for row in criteria}
            criteria_complete = (len(criteria) == len(measured) and measured == CRITERIA_LEVELS
                                 and all(row.get('status') in ('pass', 'fail', 'warn', 'skipped') for row in criteria))
            complete = criteria_complete and revision_matches and ready and not (directory / 'skipped.txt').exists()
            failures = strict_failures(criteria)
            strict = complete and not failures
            paired = None
            if baseline:
                previous = json.loads((baseline / case / 'report/mix-report.json').read_text())
                paired = complete and baseline_complete and no_new_targeted_failures(previous['criteria'], criteria)
            cases[case] = dict(complete=complete, gitRevision=manifest.get('gitRevision'), expectedRevision=revision, transcriptionReady=ready, rawStrictPassed=strict, strictFailures=failures, noNewTargetedFailures=paired)
        except (OSError, ValueError, KeyError) as error:
            cases[case] = dict(complete=False, error=str(error), rawStrictPassed=False, noNewTargetedFailures=None)
    return dict(cases=cases, complete=all(c['complete'] for c in cases.values()),
                rawStrictPassed=all(c['rawStrictPassed'] for c in cases.values()),
                noNewTargetedFailures=all(c['noNewTargetedFailures'] is True for c in cases.values()) if baseline else None)


if __name__ == '__main__':
    root = Path(sys.argv[1])
    root.mkdir(parents=True, exist_ok=True)
    result = inventory(root, Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != '-' else None,
                       sys.argv[3] if len(sys.argv) > 3 else None, sys.argv[4] if len(sys.argv) > 4 else None)
    (root / 'integrity.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['complete'] else 1)
