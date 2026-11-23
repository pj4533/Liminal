#!/usr/bin/env python3
"""Download pinned ciphertext using an ephemeral URL, without logging its capability."""
import argparse
import datetime
import hashlib
import os
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request


HOST = 'release-assets.githubusercontent.com'


def validate_url(value, now=None):
    """Only GitHub's signed asset host with at least 30 minutes remaining is accepted."""
    try:
        url = urllib.parse.urlsplit(value)
        query = urllib.parse.parse_qs(url.query)
        expiry, = query['se']
        expires = datetime.datetime.fromisoformat(expiry.replace('Z', '+00:00'))
        now = now or datetime.datetime.now(datetime.timezone.utc)
        valid = (url.scheme == 'https' and url.hostname == HOST and url.port in (None, 443)
                 and not url.username and not url.password and not url.fragment
                 and url.path.startswith('/') and not any(c.isspace() for c in value)
                 and (expires - now).total_seconds() > 1800)
    except Exception:
        valid = False
    if not valid:
        raise ValueError('invalid or expired ciphertext download capability')
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('ciphertext download redirects are forbidden')


def download(value, output, expected, opener=None):
    validate_url(value)
    if not re.fullmatch('[a-f0-9]{64}', expected):
        raise ValueError('invalid ciphertext digest')
    output = Path(output)
    staging = output.with_name(output.name + '.download')
    opener = opener or urllib.request.build_opener(NoRedirect())
    owned = False
    try:
        digest = hashlib.sha256()
        fd = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        owned = True
        with os.fdopen(fd, 'wb') as target, opener.open(value, timeout=60) as source:
            while block := source.read(1024 * 1024):
                digest.update(block)
                target.write(block)
        if digest.hexdigest() != expected:
            raise ValueError('ciphertext identity mismatch')
        # Hard-link creation refuses an existing final path instead of overwriting it.
        os.link(staging, output)
    except Exception:
        # Never emit an HTTP exception: it may contain the secret signed URL.
        raise ValueError('ciphertext download failed') from None
    finally:
        if owned:
            staging.unlink(missing_ok=True)


def capture(asset_id, output):
    if not re.fullmatch('[0-9]+', asset_id):
        raise ValueError('invalid asset ID')
    # gh's documented verbose HEAD emits redirect headers on stdout. Neither stream
    # is logged or saved; retain only the validated Location capability.
    result = subprocess.run(['gh', 'api', '--verbose', '--method', 'HEAD', '-H',
        'Accept: application/octet-stream', 'repos/pj4533/Liminal/releases/assets/' + asset_id],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    values = [line.split(':', 1)[1].strip() for line in result.stdout.decode(errors='replace').splitlines()
              if line.lstrip('<> ').lower().startswith('location:')]
    if result.returncode or len(values) != 1:
        raise ValueError('signed ciphertext redirect unavailable')
    value = validate_url(values[0])
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as target:
        target.write(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    get = sub.add_parser('download'); get.add_argument('output'); get.add_argument('--sha256', required=True)
    cap = sub.add_parser('capture'); cap.add_argument('asset_id'); cap.add_argument('output')
    args = parser.parse_args()
    try:
        if args.command == 'capture':
            capture(args.asset_id, args.output)
        else:
            value = os.environ.pop('PRIVATE_CIPHERTEXT_URL', '')
            download(value, args.output, args.sha256)
    except Exception:
        parser.exit(1, 'Private ciphertext transport failed; no capability details logged.\n')


if __name__ == '__main__': main()
