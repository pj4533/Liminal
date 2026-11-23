#!/usr/bin/env python3
"""Exact-source signing-only adapter for the genuine 47a01fe capture harness."""
import hashlib
from pathlib import Path
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


if __name__ == '__main__':
    adapt(Path(sys.argv[1]))
