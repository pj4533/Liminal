#!/usr/bin/env python3
"""Convert actual performed probe figures; missing authentic classes remain failures."""
import json
from pathlib import Path
import subprocess
import sys

source, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
selected = []
for path in sorted(source.glob('audition-*.wav')):
    if path.name.endswith('-context.wav'):
        continue
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', str(path), '-c:a', 'aac', '-b:a', '192k',
                    str(destination / path.with_suffix('.m4a').name)], check=True)
    selected.append(path.name)
(destination / 'provenance.json').write_text(json.dumps(dict(files=selected,
    source='Actual performed dialogue chops with original event timing and effects. SALIENCE-AUDITION log rows give film/chunk/text; paired context WAVs are in probe/bugs.'), indent=2))
if len(selected) < 3 or not any('letter' in p for p in selected) or not any('syllable' in p for p in selected):
    raise SystemExit('Missing 3-4 authentic initialism/syllable figures; inspect probe output')
