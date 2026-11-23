import runpy
from pathlib import Path
import unittest


evidence = runpy.run_path(str(Path(__file__).with_name('verify-app-playback.py')))['evidence']
HOOK = 'Lo-Fi dialogue hook cue=56 loop=1 interest=0.72 line="The telescope." arc=opening feel=anchor template=2 S="The telescope" R="#1" T="stars" bars=b1:0S,4R,8S b2:4L chopRepeat=0/5 chopPieces=3'
PICK = 'salient-pick id=film line=90.003...91.61 interest=0.74 peakWord=The telescope peakWeight=0.91'
PIECE = '📼 piece #4 slot=1 recipe=still id=film title="Sample clip" segment=86.2s rate=1.00 warp=1.00 level=0.80+0.20 length=21.0s fade=1.0s sound=true (wanted true, audio=true) starts 88.3s at 85.1s'


class PlaybackEvidenceTests(unittest.TestCase):
    def test_keeps_parsed_hook_and_same_piece_salience(self):
        report = evidence('\n'.join((HOOK, PICK, PIECE)))
        self.assertTrue(report['hook'])
        self.assertTrue(report['footage'])
        self.assertTrue(report['salientPick'])
        self.assertEqual(report['hooks'][0]['signature'], 'The telescope')
        self.assertEqual(report['hooks'][0]['bars'], 'b1:0S,4R,8S b2:4L')
        self.assertEqual(report['matchedSalientPicks'][0]['pick']['peakWord'], 'The telescope')
        self.assertEqual(report['errors'], [])

    def test_does_not_join_unrelated_sound_and_does_not_reuse_stale_pick(self):
        silent = PIECE.replace('sound=true', 'sound=false')
        report = evidence('\n'.join((PICK, silent, 'arbitrary log sound=true')))
        self.assertFalse(report['footage'])
        self.assertFalse(report['salientPick'])
        self.assertTrue(evidence(PIECE)['footage'])
        report = evidence('\n'.join((PICK, PIECE.replace('id=film', 'id=other'), PIECE)))
        self.assertTrue(report['footage'])
        self.assertFalse(report['salientPick'])

    def test_detects_decode_failures_and_late_chops(self):
        report = evidence('\n'.join((
            '📼🔊 no dialogue: native decode failed (bad format)',
            '📼🔊 no sound: decode failed (bad format)',
            'Lo-Fi dialogue dropped 3 late chops',
            '📼🔊 sound started 0.27s late',
        )))
        self.assertEqual([item['kind'] for item in report['faults']],
                         ['archiveDecode', 'archiveDecode', 'lateChops', 'archivePlayback'])
        self.assertEqual(report['faults'][2]['count'], '3')
        self.assertEqual(len(report['errors']), 4)
