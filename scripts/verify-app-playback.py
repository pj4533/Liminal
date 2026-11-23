#!/usr/bin/env python3
"""Automated playback evidence only; does not substitute for human visual/listening review."""
import json
from pathlib import Path
import sys


def evidence(text):
    return dict(hook='Lo-Fi dialogue hook' in text,
                footage='📼 piece #' in text and 'sound=true' in text,
                salientPick='salient-pick id=' in text,
                errors=[line for line in text.splitlines() if any(s in line.lower() for s in ('fatal error', 'audio engine failed', 'render error'))])


if __name__ == '__main__':
    result = evidence('\n'.join(Path(p).read_text(errors='replace') for p in sys.argv[1:]))
    print(json.dumps(dict(automatic=result, humanVisual='unverified', humanListening='unverified'), indent=2))
    raise SystemExit(0 if result['hook'] and result['footage'] and result['salientPick'] and not result['errors'] else 1)
