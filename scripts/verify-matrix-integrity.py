#!/usr/bin/env python3
"""Inventory required cases and keep raw strict and paired targeted results distinct."""
import argparse
import json
import math
from pathlib import Path

from mixlib import strict_failures

REQUIRED = ('ref', 'fast', 'same', 'transcribe')
CRITERIA = {row['id']: row for row in json.loads(
    Path(__file__).with_name('mix-criteria.json').read_text())['criteria']}

CRITERIA_LEVELS = {key: row['level'] for key, row in CRITERIA.items()}

TARGETED_LEVELS = {
    'C-B8': 'fail', 'C-B9': 'fail',
    'C-D1': 'fail', 'C-D2': 'fail', 'C-D3': 'warn',
    'C-D4': 'fail', 'C-D5': 'fail', 'C-D6': 'fail',
    'C-D7': 'warn', 'C-D8': 'warn', 'C-D9': 'fail',
}
SHARED_SKIP_REASONS = {
    'C-D4': ('rests: not applicable in motif mode: the user direction of 19 November 2026 '
             'puts a piece in every bar (C-D9 gates it)'),
    'C-D7': 'hookSamePadFraction: no echo-family block (no repeated hook statement) in this capture',
}


def no_new_targeted_failures(baseline, candidate):
    before = {row['id']: row for row in baseline if row['id'] in TARGETED_LEVELS}
    after = {row['id']: row for row in candidate if row['id'] in TARGETED_LEVELS}
    for criteria, targeted in ((baseline, before), (candidate, after)):
        if targeted.keys() != TARGETED_LEVELS.keys():
            return False
        if sum(row['id'] in TARGETED_LEVELS for row in criteria) != len(targeted):
            return False
    for criterion, level in TARGETED_LEVELS.items():
        previous, current = before[criterion], after[criterion]
        if previous.get('level') != level or current.get('level') != level:
            return False
        statuses = previous.get('status'), current.get('status')
        if 'skipped' in statuses:
            reason = SHARED_SKIP_REASONS.get(criterion)
            if (statuses != ('skipped', 'skipped') or reason is None
                    or previous.get('reason') != reason or current.get('reason') != reason):
                return False
            continue
        if level == 'warn':
            if not all(status in ('pass', 'warn') for status in statuses):
                return False
        elif statuses not in (('pass', 'pass'), ('fail', 'pass'), ('fail', 'fail')):
            return False
    return True


# Ordered SHA-256s of the priority-footage reel for the locally verified public corpus.
# A different public reel needs its own calibration evidence before opting into this comparison.
REF_REEL = (
    '9e3e266ce0f10509696587627e282d01676495d4e1ffbd9bb72c43ffd8e897a9',
    'f6989324081de4e17a0863e51f15bcb1e155e30865f2c90086531ca8193bcd32',
    'b4d0a194e801be9b52b581830a2e982d57554a8e03183db5e82ead62a02af7a7',
    '633da2f81d05d7ef9428220c27459d1c42d37437f6c06f1e06284e755b9348a2',
)
FAST_REEL = (
    'ec7d226767f35f16d78fa6903ed5aada86dfb6b569f56c2847696c8e8b51c4da',
    '760adc7a04afae73d7c9ff3a8c80e894ee18509feacda441bc84e2e0f5d8908c',
    'c628046bed56cc3dc9f73f3c3c28941899223d36a7968030b819fdf9b64c482b',
    '7007e9a06922bfd7ea96d2b0e29c25759f1529014ad5f478a3aa9a770a5169a8',
)
PUBLIC_DRUMS = 'public-test-fixture-v2'


def check_public_measurements(case, manifest, report):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    fast = case == 'fast'
    hashes = FAST_REEL if fast else REF_REEL[:1] if case == 'same' else REF_REEL
    bpm = 80 if fast else 70
    frames = round(48000 * 60 / bpm * 16) * (16 if case == 'same' else 8)
    require(manifest['drumSourceHash'] == PUBLIC_DRUMS and manifest['hasFootage'] is True
            and manifest['footageSourceHash'] == '/'.join('SHA256 digest: ' + h for h in hashes),
            'unexpected public drum fixture or priority footage hashes')
    require(manifest['seed'] == ('2025' if fast else '1042') and manifest['bpm'] == bpm
            and manifest['sameFilm'] is (case == 'same') and manifest['frames'] == frames
            and manifest['scoredFrames'] == frames and manifest['sampleRate'] == 48000
            and manifest['masterCalibration'] == 'fixed-nominal' and manifest['scaleSetting'] == 'Auto'
            and manifest['hooks'] == ({'transcription': 'apple'} if case == 'transcribe' else {}),
            'unexpected matrix case settings')
    require(report['case'] == case and report['gitRevision'] == manifest['gitRevision']
            and report['captureSchema'] == manifest['schema'] == 'liminal-lofi-capture-v2',
            'report and manifest identity differ')
    reel = manifest['filmReel']
    require(len(reel) == len(hashes) and all(f['title'] and math.isfinite(f['sourceSeconds'])
            and f['sourceSeconds'] >= 0 for f in reel), 'missing reel offsets')
    expected_starts = list(range(0, frames, round(48000 * 60 / bpm * 16) * 2))
    require(manifest['footageStartFrames'] == expected_starts, 'unexpected reel entry frames')

    rows = {row['id']: row for row in report['criteria']}
    values = rows['C-B8']['values']
    measured = report['metrics']['dialogue']
    pieces = measured['allPieces']
    require(rows['C-B8']['status'] in ('pass', 'fail') and rows['C-M1']['status'] in ('pass', 'fail')
            and measured['chops'] == values['featuredChops'] == len(measured['perChop']) >= 3
            and pieces['count'] == values['allPieces'] == len(pieces['perPiece']) >= 3,
            'incomplete featured or dry-piece measurement')
    for key, value in (
            ('siiMean', measured['siiMean']), ('siiP10', measured['siiP10']),
            ('snr1to4kMeanDb', measured['snr1to4kMeanDb']), ('loudnessSpreadLu', measured['loudnessSpreadLu']),
            ('allPiecesSiiMean', pieces['siiMean']), ('allPiecesSiiP10', pieces['siiP10']),
            ('allPiecesSnr1to4kMeanDb', pieces['snr1to4kMeanDb'])):
        require(math.isfinite(value) and value == values[key], f'missing or inconsistent {key}')
    for event in pieces['perPiece']:
        require(0 <= event['startFrame'] < event['endFrame'] and math.isfinite(event['snr1to4kDb']),
                'invalid dry-piece measurement')
    piece_mean = sum(event['snr1to4kDb'] for event in pieces['perPiece']) / pieces['count']
    require(abs(piece_mean - pieces['snr1to4kMeanDb']) < .00011, 'inconsistent dry-piece mean')
    loudness = rows['C-M1']['values']['integratedLufs']
    require(math.isfinite(loudness) and report['metrics']['loudness']['integratedLufs'] == loudness,
            'inconsistent integrated loudness')
    return values, loudness


def chop_active_balance(report):
    # M8 averages each band's linear power over the same union of scheduled chop windows.
    # Summing these powers gives the dialogue/backing energy ratio over that mask.
    masking = report['metrics']['masking']
    fraction = masking['chopActiveFraction']
    if not math.isfinite(fraction) or not 0 < fraction <= 1:
        raise ValueError('missing or invalid chop-active coverage')
    matrix = masking['duringChops']
    bands, levels = matrix['bands'], matrix['levelDb']
    sections = {'drums', 'bass', 'mids', 'lead', 'space', 'bed', 'dialogue'}
    if (set(matrix['sections']) != sections or len(matrix['sections']) != len(sections)
            or set(levels) != sections or len(bands) != len(set(bands))):
        raise ValueError('incomplete chop-active masking matrix')
    indices = [bands.index(band) for band in ('1-2k', '2-4k')]
    groups = {'dialogue': [], 'backing': []}
    for section, row in levels.items():
        if len(row) != len(bands) or not all(math.isfinite(row[i]) for i in indices):
            raise ValueError('missing chop-active speech-band levels')
        groups['dialogue' if section == 'dialogue' else 'backing'].extend(row[i] for i in indices)

    def combined_db(values):
        peak = max(values)
        if peak <= -200:  # mixlib.audio.db10's silence floor
            raise ValueError('no measurable chop-active energy')
        return peak + 10 * math.log10(sum(10 ** ((v - peak) / 10) for v in values))

    dialogue, backing = combined_db(groups['dialogue']), combined_db(groups['backing'])
    return dict(activeFraction=fraction, dialogueDb=dialogue, backingDb=backing, snrDb=dialogue - backing)


def public_fixture_release(case, before_manifest, before, manifest, report):
    previous, _ = check_public_measurements(case, before_manifest, before)
    current, loudness = check_public_measurements(case, manifest, report)
    if before_manifest['filmReel'] != manifest['filmReel']:
        raise ValueError('paired source offsets differ')
    rows = {row['id']: row for row in report['criteria']}
    failures = strict_failures(report['criteria'])
    piece_delta = current['allPiecesSnr1to4kMeanDb'] - previous['allPiecesSnr1to4kMeanDb']
    prior_balance, balance = chop_active_balance(before), chop_active_balance(report)
    delta = balance['snrDb'] - prior_balance['snrDb']
    allowed_delta = 1.0
    measured_bounds = CRITERIA['C-B8']['bounds']
    remaining = list(failures)
    if ('C-B8' in remaining and rows['C-B8'].get('failedChecks') == ['snr1to4kMeanDb']
            and current['snr1to4kMeanDb'] > measured_bounds['snr1to4kMeanDbMax']):
        remaining.remove('C-B8')
    if (delta > allowed_delta + 1e-9 or current['snr1to4kMeanDb'] < measured_bounds['snr1to4kMeanDbMin']
            or current['loudnessSpreadLu'] > measured_bounds['loudnessSpreadLuMax']
            or any(current[k] < measured_bounds[k + 'Min'] for k in (
                'siiMean', 'siiP10', 'allPiecesSiiMean', 'allPiecesSiiP10'))):
        if 'C-B8' not in remaining:
            remaining.append('C-B8')
    lo, hi = CRITERIA['C-M1']['bounds']['integratedLufs']
    if case in ('ref', 'transcribe') and 'C-M1' in remaining and lo <= loudness <= hi:
        if rows['C-M1'].get('failedChecks') == ['integratedLufs']:
            remaining.remove('C-M1')
    return dict(passed=not remaining, failures=remaining, fixture=PUBLIC_DRUMS,
                integratedLufs=loudness, generalFilmRangeLufs=[lo, hi],
                featuredSnrDb=current['snr1to4kMeanDb'], baselinePieceSnrDb=previous['allPiecesSnr1to4kMeanDb'],
                candidatePieceSnrDb=current['allPiecesSnr1to4kMeanDb'],
                pieceSnrDeltaDb=round(piece_delta, 4), baselineChopActive=prior_balance,
                candidateChopActive=balance, chopActiveSnrDeltaDb=round(delta, 4),
                maxChopActiveSnrRiseDb=allowed_delta)


def inventory(root, baseline=None, revision=None, baseline_revision=None, *, public_fixture=False):
    baseline_complete = baseline and inventory(baseline, revision=baseline_revision)['complete']
    cases = {}
    for case in REQUIRED:
        directory = root / case
        try:
            manifest = json.loads((directory / 'manifest.json').read_text())
            report = json.loads((directory / 'report/mix-report.json').read_text())
            criteria = report['criteria']
            ready = case != 'transcribe' or any(r.get('status') == 'ready' and r.get('words', 0) > 0 and r.get('transcriptUsed') is True and not r.get('error') for r in manifest.get('dialogueTranscripts', []))
            revision_matches = bool(revision) and manifest.get('gitRevision') == revision
            measured = {row['id']: row['level'] for row in criteria}
            criteria_complete = (len(criteria) == len(measured) and measured == CRITERIA_LEVELS
                                 and all(row.get('status') in ('pass', 'fail', 'warn', 'skipped') for row in criteria))
            complete = criteria_complete and revision_matches and ready and not (directory / 'skipped.txt').exists()
            failures = strict_failures(criteria)
            strict = complete and not failures
            paired = None
            if baseline:
                previous = json.loads((baseline / case / 'report/mix-report.json').read_text())
                paired = complete and baseline_complete and no_new_targeted_failures(previous['criteria'], criteria)
            cases[case] = dict(complete=complete, gitRevision=manifest.get('gitRevision'), expectedRevision=revision, transcriptionReady=ready, rawStrictPassed=strict, strictFailures=failures, noNewTargetedFailures=paired)
            if public_fixture:
                try:
                    if not (complete and baseline_complete):
                        raise ValueError('completed candidate and baseline matrices required')
                    prior_manifest = json.loads((baseline / case / 'manifest.json').read_text())
                    cases[case]['publicFixtureRelease'] = public_fixture_release(case, prior_manifest, previous, manifest, report)
                except (KeyError, TypeError, ValueError, OSError) as error:
                    cases[case]['publicFixtureRelease'] = dict(passed=False, error=str(error))
        except (OSError, ValueError, KeyError) as error:
            cases[case] = dict(complete=False, error=str(error), rawStrictPassed=False, noNewTargetedFailures=None)
    result = dict(cases=cases, complete=all(c['complete'] for c in cases.values()),
                rawStrictPassed=all(c['rawStrictPassed'] for c in cases.values()),
                noNewTargetedFailures=all(c['noNewTargetedFailures'] is True for c in cases.values()) if baseline else None)

    if public_fixture:
        result['releasePassed'] = all(c.get('publicFixtureRelease', {}).get('passed') is True for c in cases.values())
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('baseline', nargs='?')
    parser.add_argument('revision', nargs='?')
    parser.add_argument('baseline_revision', nargs='?')
    parser.add_argument('--public-fixture-release', action='store_true')
    args = parser.parse_args()
    root = args.root
    root.mkdir(parents=True, exist_ok=True)
    result = inventory(root, Path(args.baseline) if args.baseline and args.baseline != '-' else None,
                       args.revision, args.baseline_revision, public_fixture=args.public_fixture_release)
    (root / 'integrity.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result.get('releasePassed', result['complete']) else 1)
