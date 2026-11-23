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

    def test_identity_survives_archive_sweep_and_migrates_legacy_records(self):
        import json
        import tempfile
        from unittest.mock import patch

        with tempfile.TemporaryDirectory() as root:
            cache = Path(root) / 'ArchiveFootage'
            provenance = Path(root) / 'provenance'
            with self.assertRaisesRegex(ValueError, 'outside the managed footage cache'):
                prepare.prepare(cache, cache / 'provenance', 1)
            cache.mkdir()
            provenance.mkdir()
            identifier = prepare.PINS[0]
            file = dict(name='source.mp4', format='H.264', size='12')
            metadata = provenance / (identifier + '.metadata.json')
            metadata.write_text(json.dumps({'files': [file]}))
            film = cache / (identifier + '.mp4')
            film.write_bytes(b'public media')
            identity = dict(id=identifier, url=f'https://archive.org/download/{identifier}/source.mp4',
                            archiveFile=file, metadataSHA256=prepare.digest(metadata), sha256=prepare.digest(film))
            legacy = film.with_suffix('.provenance.json')
            durable = provenance / legacy.name
            facts = dict(streams=[dict(codec_type='video', width=10, height=10), dict(codec_type='audio')],
                         format=dict(duration=120))
            with patch.object(prepare, 'PINS', [identifier]), patch.object(prepare, 'fetch') as fetch, \
                    patch.object(prepare, 'inspect', return_value=facts), \
                    patch.object(prepare, 'decoded_windows', return_value=[]):
                # Migrate a recorded legacy identity without another network transfer.
                legacy.write_text(json.dumps(identity))
                prepare.prepare(cache, provenance, 1)
                self.assertEqual(json.loads(durable.read_text()), identity)

                # A cache sweep removes unindexed sidecars. The durable copy remains sufficient.
                legacy.unlink()
                (provenance / 'dataset.json').unlink()
                prepare.prepare(cache, provenance, 1)
                self.assertEqual(json.loads(legacy.read_text()), identity)

                # A pre-migration dataset also recovers swept per-film identities.
                legacy.unlink()
                durable.unlink()
                prepare.prepare(cache, provenance, 1)
                self.assertEqual(json.loads(durable.read_text()), identity)
                fetch.assert_not_called()

                # A stale record must never authenticate replaced media.
                film.write_bytes(b'changed')
                fetch.side_effect = OSError('offline')
                with self.assertRaisesRegex(RuntimeError, 'only 0/1'):
                    prepare.prepare(cache, provenance, 1)
                fetch.assert_called_once()
