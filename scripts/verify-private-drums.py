#!/usr/bin/env python3
"""Serial native verification; logs/audio stay private, summaries are allowlisted."""
import argparse
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('setup', 'native', 'prepare', 'baseline', 'after', 'final'))
    for key in ('after', 'baseline', 'out', 'bundle'):
        parser.add_argument('--' + key, required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    after, baseline, out, bundle = (getattr(args, key).resolve() for key in ('after', 'baseline', 'out', 'bundle'))
    raw = out / 'raw'; raw.mkdir(parents=True, exist_ok=True)
    assets = load('private-verification-assets', after)
    env = dict(os.environ, LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED='NO')
    if args.phase == 'setup':
        actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=baseline, text=True).strip()
        if actual != BASELINE:
            raise ValueError('baseline revision mismatch')
        assets.install(bundle, [after, baseline])
        shutil.copyfile(after / 'scripts/mix-matrix.sh', baseline / 'scripts/mix-matrix.sh')
        capture = run('baseline-capture-adapter', [sys.executable, str(after / 'scripts/prepare-baseline-capture.py'), str(baseline)], after, raw)
        result = run('baseline-compiler-adapter', [sys.executable, str(after / 'scripts/prepare-baseline-compiler.py'), str(baseline)], after, raw)
        with (raw / 'baseline-compiler-adapter.patch').open('wb') as patch:
            subprocess.run(['git', 'diff'], cwd=baseline, stdout=patch, check=True)
        return result or capture
    if args.phase == 'native':
        passed = True
        for label, tree in [('baseline', baseline), ('after', after)]:
            dd = out / ('dd-' + label)
            command = ['xcodebuild', 'test', 'CODE_SIGNING_ALLOWED=NO', '-scheme', 'Liminal',
                       '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                       '-derivedDataPath', str(dd)] + ['-only-testing:LiminalTests/' + s for s in SUITES]
            rc = run(label + '-native', command, tree, raw, env)
            coverage = load('verify-swift-test-coverage', after).coverage(
                (raw / (label + '-native.log')).read_text(errors='replace'), tree / 'LiminalTests', SUITES)
            identity = resource_identity(bundle, dd / 'Build/Products/Debug', assets)
            (raw / (label + '-native.json')).write_text(json.dumps(dict(exit=rc, coverage=coverage, resourceIdentity=identity)))
            passed = passed and rc == 0 and coverage['passed'] and identity
        return 0 if passed else 1
    if args.phase == 'prepare':
        cache = Path.home() / 'Library/Application Support/Liminal/ArchiveFootage'
        return run('public-media', [sys.executable, str(after / 'scripts/prepare-verification-media.py'),
            '--cache', str(cache), '--provenance', str(raw / 'public-provenance'), '--count', '12'], after, raw, env)
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
    summary['passed'] = (all(n['exit'] == 0 and n['resourceIdentity'] and n['coverage']['passed'] for n in summary['native'].values())
        and all(m['complete'] and m['rawStrictPassed'] for m in summary['matrices'].values())
        and summary['matrices']['after']['noNewTargetedFailures'] is True)
    summary['status'] = 'VERIFIED' if summary['passed'] else 'UNMET'
    public = out / 'sanitized'; public.mkdir(exist_ok=True)
    (public / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Private native/matrix verification: ' + summary['status'])
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
