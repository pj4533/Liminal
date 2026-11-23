import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('matrix', Path(__file__).with_name('verify-matrix-integrity.py'))
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


def capture(case='ref', addition=0):
    amp = 4.0 + addition
    frames = 5266288
    manifest = dict(drumSourceHash=matrix.PUBLIC_DRUMS, hasFootage=True,
                    footageSourceHash='/'.join('SHA256 digest: ' + h for h in matrix.REF_REEL),
                    seed='1042', bpm=70, sameFilm=False, frames=frames, scoredFrames=frames, sampleRate=48000,
                    masterCalibration='fixed-nominal', scaleSetting='Auto', hooks={'transcription': 'apple'} if case == 'transcribe' else {},
                    schema='liminal-lofi-capture-v2', gitRevision='rev',
                    filmReel=[dict(title='Film ' + str(n), sourceSeconds=n * 100) for n in range(4)],
                    footageStartFrames=[0, 1316572, 2633144, 3949716])
    events = [dict(startFrame=n * 48000, endFrame=n * 48000 + 24000, snr1to4kDb=amp) for n in range(3)]
    pieces = dict(perPiece=events, count=3, siiMean=.5, siiP10=.37, snr1to4kMeanDb=amp)
    dialogue = dict(perChop=events, chops=3, siiMean=.5, siiP10=.37,
                    snr1to4kMeanDb=amp, loudnessSpreadLu=2, allPieces=pieces)
    values = dict(featuredChops=3, allPieces=3, siiMean=.5, siiP10=.37, snr1to4kMeanDb=amp,
                  loudnessSpreadLu=2, allPiecesSiiMean=.5, allPiecesSiiP10=.37, allPiecesSnr1to4kMeanDb=amp)
    rows = [dict(id='C-B8', level='fail', status='fail', values=values, failedChecks=['snr1to4kMeanDb']),
            dict(id='C-M1', level='fail', status='fail', values=dict(integratedLufs=-14.56), failedChecks=['integratedLufs'])]
    report = dict(case=case, gitRevision='rev', captureSchema=manifest['schema'],
                  metrics=dict(dialogue=dialogue, loudness=dict(integratedLufs=-14.56)), criteria=rows)
    return manifest, report


class PublicFixtureRelease(unittest.TestCase):
    def test_qualified_pair_keeps_raw_failures_and_rejects_three_db(self):
        for case in ('ref', 'transcribe'):
            before = capture(case)
            for delta, passed in ((0, True), (1, True), (1.01, False), (3, False)):
                after = capture(case, delta)
                raw = copy.deepcopy(after[1]['criteria'])
                result = matrix.public_fixture_release(case, *before, *after)
                self.assertEqual(result['passed'], passed)
                self.assertEqual(result['pieceSnrDeltaDb'], delta)
                self.assertEqual(after[1]['criteria'], raw)

    def test_private_other_footage_and_different_seed_or_offsets_do_not_qualify(self):
        before = capture()
        for field, value in (('drumSourceHash', 'authentic'), ('drumSourceHash', 'public-test-fixture-v1'),
                             ('footageSourceHash', 'other'), ('seed', '1'), ('bpm', 72), ('hooks', {'tuning': 'on'})):
            after = capture()
            after[0][field] = value
            with self.assertRaises(ValueError):
                matrix.public_fixture_release('ref', *before, *after)
        after = capture()
        after[0]['filmReel'][0]['sourceSeconds'] += 1
        with self.assertRaises(ValueError):
            matrix.public_fixture_release('ref', *before, *after)

    def test_spread_other_raw_failures_and_missing_measurements_remain_blocking(self):
        before = capture()
        after = capture()
        after[1]['criteria'][0]['failedChecks'].append('loudnessSpreadLu')
        after[1]['criteria'].append(dict(id='C-B6', level='fail', status='fail'))
        self.assertEqual(matrix.public_fixture_release('ref', *before, *after)['failures'], ['C-B8', 'C-B6'])
        after[1]['metrics']['dialogue']['allPieces']['perPiece'].pop()
        with self.assertRaises(ValueError):
            matrix.public_fixture_release('ref', *before, *after)
        after = capture()
        after[1]['metrics']['dialogue']['allPieces']['perPiece'][0]['snr1to4kDb'] = 18
        with self.assertRaises(ValueError):
            matrix.public_fixture_release('ref', *before, *after)

    def test_low_featured_snr_and_out_of_general_film_loudness_stay_blocking(self):
        before = capture()
        after = capture()
        after[1]['metrics']['dialogue']['snr1to4kMeanDb'] = -4
        after[1]['criteria'][0]['values']['snr1to4kMeanDb'] = -4
        after[1]['metrics']['loudness']['integratedLufs'] = -15.8
        after[1]['criteria'][1]['values']['integratedLufs'] = -15.8
        self.assertEqual(matrix.public_fixture_release('ref', *before, *after)['failures'], ['C-B8', 'C-M1'])
