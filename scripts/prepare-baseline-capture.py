#!/usr/bin/env python3
"""Exact-source adapters for verification of the genuine 47a01fe capture harness."""
import hashlib
from pathlib import Path
import subprocess
import sys

BEFORE_SHA256 = 'cc709d45b71fa621461327b64210d9c18ac6bfda907f8eeed708d0198e97fd64'
AFTER_SHA256 = '5635d9223f656e4ef48f4857e1eec50815c35872dba30910e9e38f48b2f4d9e0'
OLD = '''            with log_path.open("w") as log:
                xcode = subprocess.run([
                    "xcodebuild", "test", "-scheme", "Liminal", "-destination", "platform=macOS",'''
NEW = '''            with log_path.open("w") as log:
                signing = []
                if os.environ.get("LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED"):
                    value = os.environ["LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED"]
                    if value not in ("YES", "NO"):
                        raise ValueError("LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED must be YES or NO")
                    signing = ["CODE_SIGNING_ALLOWED=" + value]
                xcode = subprocess.run([
                    "xcodebuild", "test", *signing, "-scheme", "Liminal", "-destination", "platform=macOS",'''


def adapt(checkout):
    path = checkout / 'scripts/check-lofi.sh'
    source = path.read_bytes()
    if hashlib.sha256(source).hexdigest() != BEFORE_SHA256:
        raise ValueError('Historical capture harness identity mismatch; refusing adapter')
    text = source.decode()
    if text.count(OLD) != 1:
        raise ValueError('Historical signing adapter no longer matches')
    result = text.replace(OLD, NEW).encode()
    if hashlib.sha256(result).hexdigest() != AFTER_SHA256:
        raise ValueError('Unexpected capture adapter output')
    path.write_bytes(result)


def adapt_public_fixture(checkout):
    # Refuse changed source before writing either file. Both complete source digests are pinned.
    expected = {
        'Liminal/Audio/Lofi/LofiDrumLibrary.swift': (
            'dc15bcfae933040c96a5f674a320007fc664a1307938953d49c62b050989a76e',
            'de5c48dfd8a8c1b8e8c98f153df28b51ec433625f4796645ab56c802199b903a'),
        'LiminalTests/LofiMixRenderTests.swift': (
            '0b1a612dcca6e2beccecafd8a2cfe5d6e8eab823c3c087a744240e48e67a658f',
            '75b2752b1405acde48a4491d3f475a98feb77a83b277ed2ed476b57c8370eac8'),
    }
    def verify(which):
        for filename, hashes in expected.items():
            if hashlib.sha256((checkout / filename).read_bytes()).hexdigest() != hashes[which]:
                raise ValueError(f'Unexpected public fixture adapter source: {filename}')
    verify(0)
    patch = str(Path(__file__).with_name('baseline-public-drum-fixture.patch').resolve())
    subprocess.run(['git', 'apply', '--check', patch], cwd=checkout, check=True)
    subprocess.run(['git', 'apply', patch], cwd=checkout, check=True)
    verify(1)


def adapt_event_gain(checkout):
    path = checkout / 'LiminalTests/LofiMixRenderTests.swift'
    source = path.read_bytes()
    expected = {
        '0b1a612dcca6e2beccecafd8a2cfe5d6e8eab823c3c087a744240e48e67a658f':
            '2f68cb4575d5f15e5b3d2aa77adfbb6e8d7cbd2c0254b490ebdf2271ad3cc525',
        '75b2752b1405acde48a4491d3f475a98feb77a83b277ed2ed476b57c8370eac8':
            '987f660fbe5e3beb73a4bcecdb5d1320ea1ad9e56e53ab20cba8bc709d4090e8',
    }
    field = b'"stutter": e.stutter, "feelMs": e.feelSeconds * 1000,'
    target = expected.get(hashlib.sha256(source).hexdigest())
    if target is None or source.count(field) != 1:
        raise ValueError('Historical capture event-gain adapter no longer matches')
    result = source.replace(field, field + b' "authoredGainDB": e.gainDB,')
    if hashlib.sha256(result).hexdigest() != target:
        raise ValueError('Unexpected event-gain adapter output')
    path.write_bytes(result)


if __name__ == '__main__':
    if sys.argv[1] == '--public-fixture':
        adapt_public_fixture(Path(sys.argv[2]))
    elif sys.argv[1] == '--event-gain':
        adapt_event_gain(Path(sys.argv[2]))
    else:
        adapt(Path(sys.argv[1]))
