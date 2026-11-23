#!/usr/bin/env python3
"""Prepare byte-preserved private drums and authenticated, streaming transport.

Never pass a key on the command line. Ciphertext and sanitized summaries alone may
leave the machine. Decryption authenticates the entire staged tar before extraction.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import tarfile
import tempfile

MAGIC = b'LIMINAL-PRIVATE\x00\x01'
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


def read_key(path):
    mode = path.stat().st_mode
    if path.is_symlink() or not stat.S_ISREG(mode) or mode & 0o077:
        raise ValueError('key must be a private regular file (mode 600)')
    key = path.read_bytes()
    if len(key) != 32:
        raise ValueError('AES-256 key must contain exactly 32 bytes')
    return key


def generate_key(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(os.urandom(32))


def regular_files(root):
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError('archive accepts regular files and directories only')
        if path.is_file():
            yield path


def encrypt(root, destination, key_path):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    root = root.resolve(strict=True)
    if destination.resolve().is_relative_to(root):
        raise ValueError('ciphertext must be outside archived directory')
    if key_path.resolve().is_relative_to(root):
        raise ValueError('key must be outside archived directory')
    key = read_key(key_path)
    nonce = os.urandom(12)
    header = MAGIC + nonce
    context = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
    context.authenticate_additional_data(header)
    # tar writes to the cipher, so neither a plaintext archive nor a whole-file buffer is needed.
    class Sink:
        def write(self, data):
            target.write(context.update(data))
            return len(data)
    created = False
    try:
        with destination.open('xb') as target:
            created = True
            destination.chmod(0o600)
            target.write(header)
            with tarfile.open(fileobj=Sink(), mode='w|') as archive:
                for path in regular_files(root):
                    archive.add(path, arcname=path.relative_to(root).as_posix(), recursive=False)
            target.write(context.finalize())
            target.write(context.tag)
    except Exception:
        if created:
            destination.unlink(missing_ok=True)
        raise


def safe_extract(archive_path, output):
    """Validate every member before writing anything; no links, devices or traversal."""
    with tarfile.open(archive_path, 'r:') as archive:
        members = archive.getmembers()
        names = set()
        for member in members:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or '..' in path.parts
                    or '\\' in member.name or not path.parts or member.name in names):
                raise ValueError('unsafe archive member')
            names.add(member.name)
        if output.exists():
            raise ValueError('extraction destination must not exist')
        private_directory(output)
        try:
            for member in members:
                path = output / member.name
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with archive.extractfile(member) as source, path.open('xb') as target:
                    path.chmod(0o600)
                    shutil.copyfileobj(source, target, CHUNK)
        except Exception:
            shutil.rmtree(output)
            raise


def decrypt(source, output, key_path):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    if output.exists():
        raise ValueError('extraction destination must not exist')
    key = read_key(key_path)
    # Staging stays on the private filesystem and is unlinked even on authentication failure.
    with tempfile.TemporaryDirectory(prefix='.private-auth-', dir=output.parent) as stage:
        staged = Path(stage) / 'authenticated.tar'
        with source.open('rb') as stream:
            size = source.stat().st_size
            header = stream.read(len(MAGIC) + 12)
            if len(header) != len(MAGIC) + 12 or not header.startswith(MAGIC) or size < len(header) + 16:
                raise ValueError('invalid encrypted archive header')
            stream.seek(-16, 2)
            tag = stream.read(16)
            stream.seek(len(header))
            context = Cipher(algorithms.AES(key), modes.GCM(header[-12:], tag)).decryptor()
            context.authenticate_additional_data(header)
            left = size - len(header) - 16
            with staged.open('xb') as target:
                staged.chmod(0o600)
                while left:
                    data = stream.read(min(CHUNK, left))
                    if not data:
                        raise ValueError('truncated ciphertext')
                    left -= len(data)
                    target.write(context.update(data))
                target.write(context.finalize())  # Authentication MUST precede safe_extract.
        safe_extract(staged, output)


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
    key = sub.add_parser('keygen'); key.add_argument('key', type=Path)
    for name in ('encrypt', 'decrypt'):
        command = sub.add_parser(name)
        command.add_argument('source', type=Path); command.add_argument('output', type=Path); command.add_argument('--key-file', type=Path, required=True)
    command = sub.add_parser('install'); command.add_argument('bundle', type=Path); command.add_argument('checkouts', type=Path, nargs='+')
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'prepare':
        result = prepare(args.source, args.output)
        print(json.dumps({k: result[k] for k in ('original', 'eligible', 'excluded', 'packs', 'beatGridSHA256')}))
    elif args.command == 'keygen': generate_key(args.key)
    elif args.command == 'encrypt': encrypt(args.source, args.output, args.key_file)
    elif args.command == 'decrypt': decrypt(args.source, args.output, args.key_file)
    elif args.command == 'install': install(args.bundle, args.checkouts)


if __name__ == '__main__':
    main()
