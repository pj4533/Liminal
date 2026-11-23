#!/usr/bin/env python3
"""Inventory required cases and keep raw strict and paired targeted results distinct."""
import json
from pathlib import Path
import sys

REQUIRED = ('ref', 'fast', 'same', 'transcribe')


def inventory(root, baseline=None, revision=None, baseline_revision=None):
    cases = {}
    for case in REQUIRED:
        directory = root / case
        try:
            manifest = json.loads((directory / 'manifest.json').read_text())
            report = json.loads((directory / 'report/mix-report.json').read_text())
            criteria = report['criteria']
            ready = case != 'transcribe' or any(r.get('status') == 'ready' and r.get('words', 0) > 0 and r.get('transcriptUsed') is True and not r.get('error') for r in manifest.get('dialogueTranscripts', []))
            revision_matches = bool(revision) and manifest.get('gitRevision') == revision
            complete = bool(criteria) and revision_matches and ready and not (directory / 'skipped.txt').exists()
            strict = complete and not any(r.get('level') == 'fail' and r.get('status') != 'pass' for r in criteria)
            paired = None
            if baseline:
                previous = json.loads((baseline / case / 'report/mix-report.json').read_text())
                before = {r['id']: r for r in previous['criteria']}
                targeted = [r for r in criteria if r['id'] in ('C-B8', 'C-B9') or r['id'].startswith('C-D')]
                paired = complete and inventory(baseline, revision=baseline_revision)['complete'] and bool(targeted) and all(r['id'] in before and r.get('status') != 'skipped' and
                    (r.get('status') != 'fail' or before[r['id']].get('status') == 'fail') for r in targeted)
            cases[case] = dict(complete=complete, gitRevision=manifest.get('gitRevision'), expectedRevision=revision, transcriptionReady=ready, rawStrictPassed=strict, noNewTargetedFailures=paired)
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
