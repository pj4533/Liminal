#!/usr/bin/env python3
"""Export performed figures, qualifying only complete transcript-backed examples."""
import json
from pathlib import Path
import subprocess
import sys


def qualifies(row):
    if row.get('mode') != 'T' or row.get('kind') not in ('letter', 'syllable') or not row.get('complete'):
        return False
    expected, parent = row.get('spellUnits', []), row.get('parent')
    events = row.get('events', [])
    start, end = row.get('transportStart', 0), row.get('transportStart', 0) + row.get('seconds', 0)
    if len(expected) < 2 or any(e['start'] < start or e['end'] > end for e in events):
        return False
    for i in range(len(events) - len(expected)):
        units, whole = events[i:i + len(expected)], events[i + len(expected)]
        steps = [e['step'] for e in units]
        if ([e['id'] for e in units] == expected and whole['id'] == parent and
            {b-a for a,b in zip(steps, steps[1:])} in ({1}, {2}) and whole['step'] == (steps[-1] // 4 + 1) * 4):
            text = row.get('parentText', '')
            letters = ''.join(c for c in text if c.isalpha())
            if row['kind'] == 'letter':
                return 2 <= len(letters) <= 5 and letters.isupper()
            # The probe records salience; demand an explicit drug/proper-name annotation for syllables.
            return row.get('semanticClass') in ('drug', 'properName')
    return False


def export(source, destination, summary):
    destination.mkdir(parents=True, exist_ok=True)
    selected, extras, missing = [], [], []
    rows = summary.get('auditions', [])
    for row in rows:
        path = source / (row['name'] + '.wav')
        if not path.is_file():
            missing.append(row['name'])
            continue
        subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', str(path), '-c:a', 'aac', '-b:a', '192k',
                        str(destination / path.with_suffix('.m4a').name)], check=True)
        (selected if qualifies(row) else extras).append(row)
    # Keep at most four qualifying examples; extras remain visible and never fill the denominator.
    selected = selected[:4]
    complete = 3 <= len(selected) <= 4 and {r['kind'] for r in selected} == {'letter', 'syllable'}
    (destination / 'provenance.json').write_text(json.dumps(dict(qualified=selected, extras=extras,
        missing=missing, passed=complete, limitation='Isolated performed effects and source context; full mix and human listening remain unverified.'), indent=2))
    return complete


if __name__ == '__main__':
    source, destination, summary = map(Path, sys.argv[1:])
    if not export(source, destination, json.loads(summary.read_text())):
        raise SystemExit('Missing 3-4 complete authentic initialism AND drug/proper-name syllable figures; acoustic extras do not qualify')
