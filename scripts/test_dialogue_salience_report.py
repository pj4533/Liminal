#!/usr/bin/env python3
"""Executable regressions for complete beat-aligned spell-figure reporting."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("report", Path(__file__).with_name("dialogue-salience-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

class SpellFigures(unittest.TestCase):
    def count(self, ids=(2, 3, 4), slots=(0, 1, 2), whole=4):
        hits = [dict(mode="T", film="film", chunk=0, loop=0, block=0, slot=s,
                     kind="letter", frag=i, parent=1, spellUnits=[2, 3, 4]) for i, s in zip(ids, slots)]
        hits.append(dict(mode="T", film="film", chunk=0, loop=0, block=0, slot=whole, kind="piece", frag=1))
        return report.spell_figures(hits)["T"]

    def test_complete_sixteenths(self): self.assertEqual(self.count(), 1)
    def test_complete_eighths(self): self.assertEqual(self.count(slots=(0, 2, 4), whole=8), 1)
    def test_prefix_is_not_complete(self): self.assertEqual(self.count(ids=(2, 3), slots=(0, 1)), 0)
    def test_skipped_letter(self): self.assertEqual(self.count(ids=(2, 4), slots=(0, 1)), 0)
    def test_irregular_grid(self): self.assertEqual(self.count(slots=(0, 1, 3)), 0)
    def test_distant_word(self): self.assertEqual(self.count(whole=12), 0)
    def test_offbeat_word(self): self.assertEqual(self.count(whole=3), 0)
    def test_reverse_order(self): self.assertEqual(self.count(ids=(4, 3, 2)), 0)

if __name__ == "__main__": unittest.main()
