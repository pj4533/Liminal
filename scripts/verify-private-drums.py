#!/usr/bin/env python3
"""Verify private drums and matrices serially on the local Mac."""
import argparse
from collections import Counter
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

BASELINE = '47a01fe267a3972241ed6918d031fffe55f26ed2'
SUITES = ('LofiTests', 'LofiRhythmTests', 'LofiStemChainTests')
REQUIRED_STEPS = ('baseline-cache-adapter-check', 'baseline-cache-adapter',
                  'baseline-capture-adapter', 'baseline-event-gain-adapter', 'baseline-compiler-adapter',
                  'baseline-native', 'after-native',
                  'baseline-kick-reference', 'after-kick-reference', 'public-media',
                  'baseline-matrix', 'after-matrix')

# Exact 47a01fe assertions observed in the verified 100-take historical run.
BASELINE_ISSUES = {
    ('installedTakesHaveSaneLandmarks', 'coverage >= 0.5'): 6,
    ('installedTakesHaveSaneLandmarks', '(16...200).contains(kicks.count)'): 1,
    ('installedTakesLandInsideTheDrumBusTargets', 'rise <= 1.2'): 7,
    ('installedTakesLandInsideTheDrumBusTargets', '(10...14).contains(crest(after))'): 2,
}
BASELINE_ISSUE_PATTERN = re.compile(
    r'Test (\w+)\(\) recorded an issue at [^:]+:\d+:\d+: Expectation failed: (.+)$')


def baseline_native_issues(log, exit_code):
    reported = [line for line in log.splitlines() if 'recorded an issue' in line]
    matches = Counter(match.groups() for line in reported
                      if (match := BASELINE_ISSUE_PATTERN.search(line)))
    inventory = [dict(method=method, assertion=assertion, count=matches[method, assertion])
                 for method, assertion in BASELINE_ISSUES]
    known = (exit_code == 65 and matches == BASELINE_ISSUES
             and len(reported) == sum(BASELINE_ISSUES.values())
             and '** TEST FAILED **' in log
             and re.search(r'Test run with 52 tests in 3 suites failed .* with 16 issues\.', log) is not None)
    return dict(known=known, inventory=inventory,
                unexpected=len(reported) - sum(item['count'] for item in inventory))


def load(name, after):
    spec = importlib.util.spec_from_file_location(name, after / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(name, command, tree, raw, env=None):
    with (raw / (name + '.log')).open('wb') as log:
        result = subprocess.run(command, cwd=tree, stdout=log, stderr=subprocess.STDOUT, env=env)
    with (raw / 'steps.jsonl').open('a') as status:
        status.write(json.dumps(dict(step=name, exit=result.returncode)) + '\n')
    # Never echo captured logs (which may include proprietary source/mix content).
    print(f'{name}: exit {result.returncode}', flush=True)
    return result.returncode


def resource_identity(bundle, products, assets):
    entries = json.loads((bundle / assets.GRID).read_text())
    grids = list(products.glob('Liminal.app/Contents/Resources/SlowBurnBeatGrid.json'))
    if len(grids) != 1 or assets.sha256(grids[0]) != assets.sha256(bundle / assets.GRID):
        return False
    directory = grids[0].parent
    expected = {e['name'] + '.wav': e['sha256'] for e in entries}
    actual = {p.name: assets.sha256(p) for p in directory.rglob('AJ_HALL_DRUM_BREAK_*.wav')}
    return actual == expected and len(actual) == 100


def sanitized_inventory(value):
    result = {key: value.get(key) for key in ('complete', 'rawStrictPassed', 'noNewTargetedFailures')}
    result['cases'] = {case: {key: row.get(key) for key in
        ('complete', 'transcriptionReady', 'rawStrictPassed', 'noNewTargetedFailures')}
        for case, row in value.get('cases', {}).items()}
    for row in result['cases'].values():
        row['status'] = 'VERIFIED' if row['complete'] else 'UNMET'
    return result


def sanitized_criteria(report, allowed_ids, allowed_values):
    rows = []
    for row in report.get('criteria', []):
        if row.get('id') not in allowed_ids:
            continue
        values = {key: value for key, value in row.get('values', {}).items()
                  if key in allowed_values and (value is None or isinstance(value, (bool, int))
                      or isinstance(value, float) and math.isfinite(value))}
        rows.append(dict(id=row['id'],
                         level=row.get('level') if row.get('level') in ('fail', 'warn') else None,
                         status=row.get('status') if row.get('status') in ('pass', 'fail', 'skipped') else 'UNMET',
                         values=values))
    return rows


def phase_status(raw):
    try:
        rows = [json.loads(line) for line in (raw / 'steps.jsonl').read_text().splitlines()]
        valid = all(isinstance(row, dict) and isinstance(row.get('step'), str)
                    and type(row.get('exit')) is int for row in rows)
    except (OSError, ValueError):
        rows, valid = [], False
    phases = {}
    for name in REQUIRED_STEPS:
        exits = [row['exit'] for row in rows if isinstance(row, dict)
                 and row.get('step') == name and type(row.get('exit')) is int]
        status = 'VERIFIED' if valid and exits == [0] else 'UNMET'
        if valid and name == 'baseline-native' and exits == [65]:
            log = raw / 'baseline-native.log'
            if log.is_file() and baseline_native_issues(log.read_text(errors='replace'), 65)['known']:
                status = 'KNOWN_BASELINE_FAILURES'
        if valid and name == 'baseline-matrix' and exits == [1]:
            try:
                baseline = json.loads((raw / 'baseline-inventory.json').read_text())
                if baseline['complete'] and not baseline['rawStrictPassed']:
                    status = 'MEASURED_BASELINE_FAILURES'
            except (OSError, ValueError, KeyError):
                pass
        phases[name] = dict(exits=exits, status=status)
    return dict(ledgerValid=valid, phases=phases,
                passed=valid and all(row['status'] != 'UNMET' for row in phases.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('setup', 'native', 'prepare', 'baseline', 'after', 'final'))
    for key in ('after', 'baseline', 'out', 'bundle'):
        parser.add_argument('--' + key, required=True, type=Path)
    parser.add_argument('--archive-dir', type=Path, help='Shared verification media directory (default: OUT/ArchiveFootage)')
    args = parser.parse_args()
    os.umask(0o077)
    after, baseline, out, bundle = (getattr(args, key).resolve() for key in ('after', 'baseline', 'out', 'bundle'))
    raw = out / 'raw'; raw.mkdir(parents=True, exist_ok=True)
    assets = load('private-verification-assets', after)
    archive_dir = (args.archive_dir or out / 'ArchiveFootage').resolve()
    env = dict(os.environ, LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED='NO', LIMINAL_MIX_REPORT_CHECKOUT=str(after),
               LIMINAL_VERIFICATION_ARCHIVE_DIR=str(archive_dir),
               TEST_RUNNER_LIMINAL_VERIFICATION_ARCHIVE_DIR=str(archive_dir))
    if args.phase == 'setup':
        actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=baseline, text=True).strip()
        if actual != BASELINE:
            raise ValueError('baseline revision mismatch')
        cache_patch = str(after / 'scripts/baseline-verification-cache.patch')
        check = run('baseline-cache-adapter-check', ['git', 'apply', '--check', cache_patch], baseline, raw)
        if check:
            return check
        assets.install(bundle, [after, baseline])
        cache_adapter = run('baseline-cache-adapter', ['git', 'apply', cache_patch], baseline, raw)
        if cache_adapter:
            return cache_adapter
        shutil.copyfile(after / 'scripts/mix-matrix.sh', baseline / 'scripts/mix-matrix.sh')
        shutil.copyfile(after / 'scripts/mix-report.sh', baseline / 'scripts/mix-report.sh')
        capture = run('baseline-capture-adapter', [sys.executable, str(after / 'scripts/prepare-baseline-capture.py'), str(baseline)], after, raw)
        event_gain = run('baseline-event-gain-adapter', [sys.executable, str(after / 'scripts/prepare-baseline-capture.py'), '--event-gain', str(baseline)], after, raw)
        result = run('baseline-compiler-adapter', [sys.executable, str(after / 'scripts/prepare-baseline-compiler.py'), str(baseline)], after, raw)
        with (raw / 'baseline-compiler-adapter.patch').open('wb') as patch:
            subprocess.run(['git', 'diff'], cwd=baseline, stdout=patch, check=True)
        return result or capture or event_gain
    if args.phase == 'native':
        actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=baseline, text=True).strip()
        if actual != BASELINE:
            raise ValueError('baseline revision mismatch')
        passed = True
        for label, tree in [('baseline', baseline), ('after', after)]:
            dd = out / ('dd-' + label)
            command = ['xcodebuild', 'test', 'CODE_SIGNING_ALLOWED=NO', '-scheme', 'Liminal',
                       '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                       '-derivedDataPath', str(dd)] + ['-only-testing:LiminalTests/' + s for s in SUITES]
            rc = run(label + '-native', command, tree, raw, env)
            log = (raw / (label + '-native.log')).read_text(errors='replace')
            coverage = load('verify-swift-test-coverage', after).coverage(log, tree / 'LiminalTests', SUITES)
            identity = resource_identity(bundle, dd / 'Build/Products/Debug', assets)
            reference_exit = run(label + '-kick-reference', [
                sys.executable, str(after / 'scripts/drum-landmark-reference.py'),
                '--takes', str(bundle / assets.DRUMS), '--swift-log', str(raw / (label + '-native.log')),
                '--out', str(raw / (label + '-kick-reference')), '--plots', '0', '--verify-corpus',
            ], after, raw, env)
            native = dict(exit=rc, coverage=coverage, resourceIdentity=identity,
                          independentKickReference=reference_exit == 0)
            if label == 'baseline':
                native['historicalIssues'] = baseline_native_issues(log, rc)
            (raw / (label + '-native.json')).write_text(json.dumps(native))
            exit_accepted = rc == 0 or (label == 'baseline' and native['historicalIssues']['known'])
            passed = passed and exit_accepted and coverage['passed'] and identity and reference_exit == 0
        return 0 if passed else 1
    if args.phase == 'prepare':
        return run('public-media', [sys.executable, str(after / 'scripts/prepare-verification-media.py'),
            '--cache', str(archive_dir), '--provenance', str(raw / 'public-provenance'), '--count', '12'], after, raw, env)
    if args.phase in ('baseline', 'after'):
        label = args.phase
        tree = baseline if label == 'baseline' else after
        env['DD'] = str(out / ('dd-' + label))
        command = ['bash', 'scripts/mix-matrix.sh', '--out', str(raw / (label + '-matrix')),
                   '--cases', 'ref,fast,same,transcribe', '--strict']
        if label == 'after': command += ['--baseline', str(raw / 'baseline-matrix')]
        return run(label + '-matrix', command, tree, raw, env)
    matrix = load('verify-matrix-integrity', after)
    provenance = json.loads((bundle / 'provenance.json').read_text())
    summary = dict(scope=provenance['scope'], corpus={k: provenance[k] for k in
        ('original', 'eligible', 'excluded', 'packs', 'beatGridSHA256', 'bytePreserved')},
        sourceSHA256=sorted(row['sha256'] for row in provenance['files']), native={}, matrices={})
    summary['revisions'] = {label: subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=tree, text=True).strip()
                            for label, tree in [('baseline', baseline), ('after', after)]}
    criteria = json.loads((after / 'scripts/mix-criteria.json').read_text())
    allowed_ids = {row['id'] for row in criteria['criteria']}
    allowed_values = set(re.findall(r'c\.test\("([^"]+)"', (after / 'scripts/mixlib/report.py').read_text()))
    for label in ('baseline', 'after'):
        try:
            native = json.loads((raw / (label + '-native.json')).read_text())
            summary['native'][label] = native
        except (OSError, ValueError):
            summary['native'][label] = dict(exit=1, resourceIdentity=False, coverage={'passed': False})
        paired = raw / 'baseline-matrix' if label == 'after' else None
        inventory = matrix.inventory(raw / (label + '-matrix'), paired, summary['revisions'][label], BASELINE)
        summary['matrices'][label] = sanitized_inventory(inventory)
        for case, row in summary['matrices'][label]['cases'].items():
            try:
                report = json.loads((raw / (label + '-matrix') / case / 'report/mix-report.json').read_text())
                row['criteria'] = sanitized_criteria(report, allowed_ids, allowed_values)
            except (OSError, ValueError):
                row['criteria'] = []
        (raw / (label + '-inventory.json')).write_text(json.dumps(inventory, indent=2))
    summary['phaseExecution'] = phase_status(raw)
    native = summary['native']
    baseline_exit_accepted = (native['baseline']['exit'] == 0
                              or (native['baseline']['exit'] == 65
                                  and summary['phaseExecution']['phases']['baseline-native']['status'] == 'KNOWN_BASELINE_FAILURES'))
    summary['passed'] = (summary['phaseExecution']['passed'] and summary['revisions']['baseline'] == BASELINE
        and baseline_exit_accepted and native['after']['exit'] == 0
        and all(n['resourceIdentity'] and n['coverage']['passed'] and n.get('independentKickReference') is True
                for n in native.values())
        and all(m['complete'] for m in summary['matrices'].values())
        and summary['matrices']['after']['rawStrictPassed']
        and summary['matrices']['after']['noNewTargetedFailures'] is True)
    summary['status'] = 'VERIFIED' if summary['passed'] else 'UNMET'
    summary_dir = out / 'sanitized'; summary_dir.mkdir(exist_ok=True)
    (summary_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Private native/matrix verification: ' + summary['status'])
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
