#!/usr/bin/env python3
"""Reject successful xcodebuild runs that omitted requested Swift Testing suites/methods."""
import json
from pathlib import Path
import re
import sys


def swift_code(source):
    """Mask comments and string literals, preserving offsets and structural braces.

    Covers nested block comments and ordinary/raw single/multiline strings. String
    interpolation is masked with its containing literal: it cannot declare a test.
    """
    pattern = re.compile(r'//[^\n]*|/\*|#+"{3}|#+"|"{3}|"')
    chars = list(source)
    cursor = 0
    while match := pattern.search(source, cursor):
        start = match.start()
        marker = match.group()
        end = match.end()
        if marker == '/*':
            depth = 1
            while depth and end < len(source):
                nested = re.search(r'/\*|\*/', source[end:])
                if not nested:
                    end = len(source)
                    break
                depth += 1 if nested.group() == '/*' else -1
                end += nested.end()
        elif not marker.startswith('//'):
            hashes = len(marker) - len(marker.lstrip('#'))
            quotes = marker[hashes:]
            closing = quotes + '#' * hashes
            while end < len(source):
                if source.startswith('\\' + '#' * hashes, end):
                    end += 2 + hashes
                elif source.startswith(closing, end):
                    end += len(closing)
                    break
                else:
                    end += 1
        for index in range(start, end):
            if chars[index] != '\n':
                chars[index] = ' '
        cursor = end
    return ''.join(chars)


def declared_tests(source_directory):
    """Index direct @Test methods by their declaring type, across shared files."""
    suites = {}
    for path in sorted(source_directory.glob('*.swift')):
        source = swift_code(path.read_text())
        stack, pairs, depths = [], {}, []
        for index, char in enumerate(source):
            depths.append(len(stack))
            if char == '{':
                stack.append(index)
            elif char == '}' and stack:
                pairs[stack.pop()] = index
        for declaration in re.finditer(r'\b(?:struct|class|enum|actor|extension)\s+(\w+)[^{;]*\{', source):
            opening = declaration.end() - 1
            if opening not in pairs:
                continue
            name = declaration.group(1)
            methods = suites.setdefault(name, set())
            body_depth = depths[opening] + 1
            for test in re.finditer(r'@Test\b(?:(?!\bfunc\b).)*\bfunc\s+(\w+)', source[opening+1:pairs[opening]], re.S):
                if depths[opening + 1 + test.start()] == body_depth:
                    methods.add(test.group(1))
    return suites


def coverage(text, source_directory, suites):
    declarations = declared_tests(source_directory)
    result = {}
    # Xcode uses SF Symbols on newer macOS versions and Unicode checks on runners.
    marker = r"[✔✘\U0010105b\U00100884]"
    for suite in suites:
        expected = declarations.get(suite, set())
        completed = {name for name in expected if re.search(marker + ' Test ' + re.escape(name) + r'\([^\n]*\)(?: with \d+ test cases)? (?:passed|failed) after ', text)}
        suite_finished = bool(re.search(marker + ' Suite ' + re.escape(suite) + r' (?:passed|failed) after ', text))
        result[suite] = dict(expected=len(expected), completed=len(completed), missing=sorted(expected-completed),
                             suiteFinished=suite_finished, complete=bool(expected) and expected == completed and suite_finished)
    return dict(passed=bool(result) and all(r['complete'] for r in result.values()), suites=result)


if __name__ == '__main__':
    result = coverage(Path(sys.argv[1]).read_text(errors='replace'), Path(sys.argv[2]), sys.argv[3:])
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
