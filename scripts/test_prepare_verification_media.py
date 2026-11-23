import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("prepare", Path(__file__).with_name("prepare-verification-media.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class MediaPreparationTests(unittest.TestCase):
    def test_candidate_selection_matches_documented_archive_formats_and_is_deterministic(self):
        files = [dict(name="master_edit.mp4", format="H.264", size="1"),
                 dict(name="wrong.mp4", format="unknown", size="1"),
                 dict(name="audio.mp3", format="MPEG4", size="1"),
                 dict(name="b.mp4", format="H.264", size="20"),
                 dict(name="a.mp4", format="512Kb MPEG4", size="10")]
        self.assertEqual([f["name"] for f in prepare.candidates(dict(files=files))], ["a.mp4", "b.mp4"])

    def test_canonical_sources_are_unique_and_include_requested_speech_sources(self):
        self.assertEqual(len(set(prepare.PINS)), 13)
        self.assertIn("Timothy_Leary_Archives_198", prepare.PINS)
        self.assertIn("horizons-of-science-thinking-machines", prepare.PINS)
