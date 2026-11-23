#!/usr/bin/env python3
"""Reject successful xcodebuild runs that omitted requested Swift Testing suites/methods."""
import json
from pathlib import Path
import re
import sys


def coverage(text, source_directory, suites):
    result = {}
    for suite in suites:
        source = (source_directory / (suite + '.swift')).read_text()
        expected = set(re.findall(r'@Test\b(?:(?!\bfunc\b).)*\bfunc\s+(\w+)', source, re.S))
        completed = {name for name in expected if re.search(r'[✔✘] Test ' + re.escape(name) + r'\([^\n]*\)(?: with \d+ test cases)? (?:passed|failed) after ', text)}
        suite_finished = bool(re.search(r'[✔✘] Suite ' + re.escape(suite) + r' (?:passed|failed) after ', text))
        result[suite] = dict(expected=len(expected), completed=len(completed), missing=sorted(expected-completed),
                             suiteFinished=suite_finished, complete=bool(expected) and expected == completed and suite_finished)
    return dict(passed=bool(result) and all(r['complete'] for r in result.values()), suites=result)


if __name__ == '__main__':
    result = coverage(Path(sys.argv[1]).read_text(errors='replace'), Path(sys.argv[2]), sys.argv[3:])
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
