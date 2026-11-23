#!/usr/bin/env python3
"""Prepare and install byte-preserved private drums for local verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import tempfile

CHUNK = 1024 * 1024
PACKS = (
    ('A.J HALL - "SLOW BURN" SAMPLE PACK!', 'BREAKS!', 25, 20),
    ('@AJHALL89 - "SLOW BURN" VOL. 2 DRUM BREAK PACK', 'DRUM BREAKS!', 25, 23),
    ('@AJHALL89 - SLOW BURN VOL. 3 BREAKS W- BONUS MELODIES!', 'DRUM BREAKS!', 25, 25),
    ('@AJHALL89 - SLOW BURN VOL. 4 BREAKS & MELODIC SAMPLES', 'FINAL BREAKS', 37, 32),
)
DRUMS = Path('Liminal/SlowBurnDrums')
GRID = Path('Liminal/Audio/Lofi/SlowBurnBeatGrid.json')


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('private directory cannot be a symlink')
    path.chmod(0o700)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for data in iter(lambda: source.read(CHUNK), b''):
            digest.update(data)
    return digest.hexdigest()


def wav_metadata(path):
    """Read PCM/IEEE-float (including extensible) RIFF metadata without decoding."""
    with path.open('rb') as stream:
        header = stream.read(12)
        if len(header) != 12 or header[:4] != b'RIFF' or header[8:] != b'WAVE':
            raise ValueError('not a RIFF WAV')
        end = struct.unpack('<I', header[4:8])[0] + 8
        if end > path.stat().st_size:
            raise ValueError('truncated RIFF')
        fmt = None
        data_size = None
        while stream.tell() + 8 <= end:
            kind, size = struct.unpack('<4sI', stream.read(8))
            start = stream.tell()
            if start + size > end:
                raise ValueError('truncated WAV chunk')
            if kind == b'fmt ':
                raw = stream.read(size)
                if len(raw) < 16:
                    raise ValueError('short WAV fmt')
                encoding, channels, rate, _, align, bits = struct.unpack('<HHIIHH', raw[:16])
                if encoding == 0xfffe:
                    if len(raw) < 40 or raw[26:40] != bytes.fromhex('000000001000800000aa00389b71'):
                        raise ValueError('unsupported extensible WAV')
                    encoding = struct.unpack('<H', raw[24:26])[0]
                if encoding not in (1, 3) or align != channels * ((bits + 7) // 8) or not align:
                    raise ValueError('unsupported WAV format')
                fmt = (channels, rate, align)
            elif kind == b'data':
                if data_size is not None:
                    raise ValueError('multiple WAV data chunks')
                data_size = size
            stream.seek(start + size + size % 2)
        if fmt is None or data_size is None or data_size % fmt[2]:
            raise ValueError('missing/unaligned WAV data')
        return dict(channels=fmt[0], sampleRate=fmt[1], frameCount=data_size // fmt[2])


def canonical_name(filename):
    stem = Path(filename).stem.upper()
    match = re.search(r'_(\d{2,3}(?:\.\d+)?)[_ ]BPM!?$', stem)
    if not match:
        raise ValueError('missing labeled BPM')
    title = stem[:match.start()]
    title = re.sub(r'^(?:@AJHALL89|A\.J\._HALL_?|AJ_HALL)_DRUM_BREA(?:K)?_', '', title)
    if not re.fullmatch(r'[A-Z0-9_]+', title):
        raise ValueError('unrecognized break name')
    bpm = float(match[1])
    return f'AJ_HALL_DRUM_BREAK_{title}_{match[1]}_BPM', bpm


def _prepare(source, output):
    if output.exists():
        raise ValueError('output must not exist')
    private_directory(output)
    (output / DRUMS).mkdir(parents=True)
    (output / GRID).parent.mkdir(parents=True, exist_ok=True)
    rows, entries, packs = [], [], []
    names = set()
    for volume, (pack, folder, expected, eligible) in enumerate(PACKS, 1):
        directory = source / pack / folder
        files = sorted(p for p in directory.iterdir() if p.suffix.lower() == '.wav')
        if len(files) != expected:
            raise ValueError(f'volume {volume}: expected {expected} original WAVs')
        accepted = 0
        for path in files:
            if not path.is_file() or path.is_symlink():
                raise ValueError('original WAV must be a regular file')
            name, bpm = canonical_name(path.name)
            meta = wav_metadata(path)
            reason = None
            if not 45 <= bpm <= 120:
                reason = 'BPM outside 45..120'
            elif meta['channels'] not in (1, 2) or not 22050 <= meta['sampleRate'] <= 96000:
                reason = 'unsupported channels/sample rate'
            elif abs(meta['frameCount'] - 64 * meta['sampleRate'] * 60 / bpm) > 2:
                reason = 'not 64 beats within two frames'
            digest = sha256(path)
            rows.append(dict(volume=volume, sourceName=path.name, name=name, sha256=digest,
                             bpm=bpm, **meta, exclusion=reason))
            if reason:
                continue
            if name in names:
                raise ValueError('duplicate canonical name')
            names.add(name)
            target = output / DRUMS / (name + '.wav')
            shutil.copyfile(path, target)
            target.chmod(0o600)
            if sha256(target) != digest:
                raise ValueError('copy hash mismatch')
            entries.append(dict(name=name, sha256=digest, bpm=bpm, beats=64, **meta,
                                framesPerBeat=meta['frameCount'] / 64,
                                onsetPhaseMilliseconds=0, beatSupport=0))
            accepted += 1
        if accepted != eligible:
            raise ValueError(f'volume {volume}: expected {eligible} eligible originals, got {accepted}')
        packs.append(dict(volume=volume, original=expected, eligible=accepted))
    entries.sort(key=lambda row: row['name'])
    (output / GRID).write_text(json.dumps(entries, indent=2) + '\n')
    provenance = dict(schema=1, scope='Fresh regenerated D122 corpus; not historical exact cache',
                      original=len(rows), eligible=len(entries), excluded=len(rows) - len(entries), packs=packs, files=rows,
                      beatGridSHA256=sha256(output / GRID), bytePreserved=True)
    (output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    return provenance


def prepare(source, output):
    if output.exists():
        raise ValueError('output must not exist')
    private_directory(output.parent)
    with tempfile.TemporaryDirectory(prefix='.prepare-', dir=output.parent) as stage:
        staged = Path(stage) / 'bundle'
        result = _prepare(source, staged)
        staged.rename(output)
    return result


def install(bundle, checkouts):
    provenance = json.loads((bundle / 'provenance.json').read_text())
    entries = json.loads((bundle / GRID).read_text())
    if (provenance.get('eligible') != 100 or len(entries) != 100
            or provenance['beatGridSHA256'] != sha256(bundle / GRID)):
        raise ValueError('invalid corpus inventory')
    names = set()
    for row in entries:
        name = row['name']
        if not re.fullmatch(r'AJ_HALL_DRUM_BREAK_[A-Z0-9_.]+_BPM', name) or name in names:
            raise ValueError('unsafe/duplicate corpus name')
        names.add(name)
        path = bundle / DRUMS / (name + '.wav')
        if path.is_symlink() or sha256(path) != row['sha256'] or wav_metadata(path) != {k: row[k] for k in ('sampleRate', 'channels', 'frameCount')}:
            raise ValueError('corpus WAV identity mismatch')
    if len(list((bundle / DRUMS).iterdir())) != 100:
        raise ValueError('unexpected corpus files')
    for checkout in checkouts:
        if (checkout / DRUMS).exists() or (checkout / GRID).exists():
            raise ValueError('refusing to overwrite installed private corpus')
    for checkout in checkouts:
        shutil.copytree(bundle / DRUMS, checkout / DRUMS)
        shutil.copyfile(bundle / GRID, checkout / GRID)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare'); prep.add_argument('source', type=Path); prep.add_argument('output', type=Path)
    command = sub.add_parser('install'); command.add_argument('bundle', type=Path); command.add_argument('checkouts', type=Path, nargs='+')
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'prepare':
        result = prepare(args.source, args.output)
        print(json.dumps({k: result[k] for k in ('original', 'eligible', 'excluded', 'packs', 'beatGridSHA256')}))
    elif args.command == 'install': install(args.bundle, args.checkouts)


if __name__ == '__main__':
    main()
