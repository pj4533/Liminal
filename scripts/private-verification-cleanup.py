#!/usr/bin/env python3
"""Collect only relevant crash reports privately; remove private runner residues."""
import argparse
import os
from pathlib import Path
import shutil

BUNDLE_IDS = ('com.saygoodnight.Liminal', 'com.saygoodnight.LiminalTests')
PROCESSES = ('Liminal', 'LiminalTests', 'xctest')


def capture_caches(home):
    yield home / 'Library/Caches/Liminal/OfflineAudio'
    for bundle in BUNDLE_IDS:
        yield home / f'Library/Containers/{bundle}/Data/Library/Caches/Liminal/OfflineAudio'
        yield home / f'Library/Caches/{bundle}/Liminal/OfflineAudio'


def diagnostics(home, system=Path('/Library/Logs/DiagnosticReports')):
    for directory in (home / 'Library/Logs/DiagnosticReports', system):
        for process in PROCESSES:
            for separator in ('_', '-'):
                for extension in ('ips', 'crash', 'diag'):
                    yield from directory.glob(f'{process}{separator}*.{extension}')
                    yield from (directory / 'Retired').glob(f'{process}{separator}*.{extension}')


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def collect(out, home, system=Path('/Library/Logs/DiagnosticReports')):
    destination = out / 'raw/runner-diagnostics'
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    for index, source in enumerate(sorted(set(diagnostics(home, system)))):
        if source.is_file() and not source.is_symlink():
            # Original process/source details remain exclusively inside encrypted raw evidence.
            target = destination / f'{index:04d}-{source.name}'
            shutil.copyfile(source, target)
            target.chmod(0o600)


def clean(out, workspace, home, system=Path('/Library/Logs/DiagnosticReports')):
    paths = list(capture_caches(home)) + list(set(diagnostics(home, system)))
    # A crash can bypass both Swift defer and the harness's finally cleanup.
    paths += [Path('/private/tmp') / f'liminal-lofi-audio-config-{os.getuid()}.json',
              out, out.parent / 'private-evidence.enc']
    for checkout in ('after', 'baseline'):
        root = workspace / checkout
        paths += [root / 'Liminal/SlowBurnDrums', root / 'Liminal/Audio/Lofi/SlowBurnBeatGrid.json']
    failed = 0
    for path in paths:
        try:
            remove(path)
        except OSError:
            failed += 1
    if failed:
        raise RuntimeError(f'Private cleanup could not remove {failed} paths; hosted runner destruction required')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('collect', 'clean'))
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if args.phase == 'collect': collect(args.out, Path.home())
    else: clean(args.out, args.workspace, Path.home())
