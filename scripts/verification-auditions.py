#!/usr/bin/env python3
"""Export performed figures, qualifying only complete transcript-backed examples."""
import argparse
import hashlib
import json
import re
import wave
from pathlib import Path
import subprocess
import sys


def qualifies(row):
    if row.get('mode') != 'T' or row.get('kind') not in ('letter', 'syllable') or not row.get('complete'):
        return False
    expected, parent = row.get('spellUnits', []), row.get('parent')
    events = row.get('events', [])
    start, end = row.get('transportStart', 0), row.get('transportStart', 0) + row.get('seconds', 0)
    if len(expected) < 2 or any(e['start'] < start or e['end'] > end for e in events):
        return False
    for i in range(len(events) - len(expected)):
        units, whole = events[i:i + len(expected)], events[i + len(expected)]
        steps = [e['step'] for e in units]
        if ([e['id'] for e in units] == expected and whole['id'] == parent and
            {b-a for a,b in zip(steps, steps[1:])} in ({1}, {2}) and whole['step'] == (steps[-1] // 4 + 1) * 4):
            text = row.get('parentText', '')
            letters = ''.join(c for c in text if c.isalpha())
            if row['kind'] == 'letter':
                return 2 <= len(letters) <= 5 and letters.isupper() and len(letters) == len(expected)
            # The probe records salience; demand an explicit drug/proper-name annotation for syllables.
            return row.get('semanticClass') in ('drug', 'properName')
    return False


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export(source, destination, summary, reviews=None):
    destination.mkdir(parents=True, exist_ok=True)
    identity_path = source.parent / 'render-identity.json'
    build = json.loads(identity_path.read_text()) if identity_path.is_file() else {}
    build_ok = (re.fullmatch(r'[0-9a-f]{40}', build.get('revision', '')) is not None
                and re.fullmatch(r'[0-9a-f]{64}', build.get('trackedDiffSHA256', '')) is not None)
    selected, extras, missing = [], [], []
    films = {f['id']: f for f in summary.get('corpus', {}).get('films', [])}
    for row in summary.get('auditions', []):
        name = row['name']
        if Path(name).name != name:
            raise ValueError('Unexpected path in audition name')
        qualified = qualifies(row)
        film = films.get(row.get('film'), {})
        source_ok = (re.fullmatch(r'[0-9a-f]{64}', film.get('sha256', '')) is not None
                     and film.get('url', '').startswith('https://'))
        core = row.get('wordCoreFrames', [])
        whole = row['events'][-1].get('sourceFrames', []) if row.get('events') else []
        context = row.get('contextFrames', [])
        qualified = (qualified and build_ok and source_ok and row.get('usedTranscript') is True
                     and row.get('mixRender') == 'LofiMasterBus/public-test-fixture-v2'
                     and row.get('transcriptModel') not in (None, '', 'missing')
                     and len(core) == len(whole) == len(context) == 2
                     and max(context[0], whole[0]) <= core[0] < core[1] <= min(context[1], whole[1])
                     and all(e.get('effect') != 'reversed' for e in row['events']))
        assets = {}
        for role, suffix in [('performed', ''), ('context', '-context'), ('dry', '-dry'), ('mix', '-mix')]:
            if row.get('mode') != 'T' and role in ('dry', 'mix'):
                continue
            path = source / (name + suffix + '.wav')
            if not path.is_file():
                missing.append(path.name)
                qualified = False
                continue
            digest = sha256(path)
            if digest != row.get('wavSHA256', {}).get(role):
                qualified = False
            with wave.open(str(path), 'rb') as wav:
                frames, rate, channels = wav.getnframes(), wav.getframerate(), wav.getnchannels()
                expected = context[1] - context[0] if role == 'context' and len(context) == 2 else round(rate * row['seconds'])
                if frames != expected or rate != row.get('sampleRate') or (role in ('dry', 'mix') and channels != 2):
                    qualified = False
            target = destination / path.with_suffix('.m4a').name
            subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', str(path), '-c:a', 'aac', '-b:a', '192k', str(target)], check=True)
            assets[role] = dict(file=target.name, sha256=sha256(target), wavSHA256=digest,
                                frames=frames, sampleRate=rate, channels=channels)
        item = dict(row, derivative=film, audio=assets)
        identity = (row['film'], tuple(core), row.get('windowOffset'))
        if qualified and all((r['film'], tuple(r['wordCoreFrames']), r['windowOffset']) != identity for r in selected):
            selected.append(item)
        else:
            extras.append(item)
    # Reserve one place per class before capping the reel at four.
    first = [next((r for r in selected if r['kind'] == kind), None) for kind in ('letter', 'syllable')]
    priority = [r for r in first if r is not None]
    ordered = priority + [r for r in selected if r not in priority]
    selected = ordered[:4]
    extras.extend(ordered[4:])
    complete = 3 <= len(selected) <= 4 and {r['kind'] for r in selected} == {'letter', 'syllable'}
    listening = []
    for item in selected:
        review = (reviews or {}).get(item['name'], {})
        hashes = {role: item['audio'][role]['sha256'] for role in ('dry', 'mix', 'context')}
        matched = (review.get('sha256') == hashes and isinstance(review.get('outcome'), str)
                   and bool(review['outcome'].strip()) and review.get('accepted') is True)
        listening.append(dict(name=item['name'], matched=matched, review=review or None))
    passed = complete and all(item['matched'] for item in listening)
    (destination / 'provenance.json').write_text(json.dumps(dict(renderSource=build, qualified=selected, extras=extras, missing=missing,
        completeExports=complete, listening=listening, passed=passed), indent=2) + '\n')
    return complete, passed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('source', 'destination', 'summary'):
        parser.add_argument(key, type=Path)
    parser.add_argument('--reviews', type=Path, help='Human review JSON keyed by example name')
    args = parser.parse_args()
    reviews = json.loads(args.reviews.read_text()) if args.reviews else None
    complete, reviewed = export(args.source, args.destination, json.loads(args.summary.read_text()), reviews)
    if not complete or (args.reviews and not reviewed):
        raise SystemExit('Audition checks incomplete. See completeExports and listening in provenance.json.')
    if not reviewed:
        print('Audition exports verified. Human listening review remains unconfirmed.')
