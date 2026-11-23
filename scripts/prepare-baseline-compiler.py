#!/usr/bin/env python3
"""Exact-source compiler-only adapters for historical verification checkout."""
from pathlib import Path
import sys
path = Path(sys.argv[1]) / 'Liminal/Audio/Lofi/LofiBassVoice.swift'
text = path.read_text()
old = '            cuePartials(note, voice: voice, envelope: envelope, rate: rate, onset: cueOnset, cue: $0, sub: sub, tone: tone)'
assert text.count(old) == 1, 'Historical baseline compiler adapter no longer matches'
path.write_text(text.replace(old, old.replace('cuePartials(', 'Self.cuePartials(', 1)))
path = Path(sys.argv[1]) / 'LiminalTests/DialogueHookMetrics.swift'
text = path.read_text()
old = '        m.fragmentsPer4 = (0..<4).map { g in Double(Set((0..<4).flatMap { bars[4 * g + $0].map(\\.fragment) }).count) }.reduce(0, +) / 4'
assert text.count(old) == 1, 'Historical hook metrics compiler adapter no longer matches'
new = """        var fragmentTotal = 0
        for group in 0..<4 {
            var fragments = Set<Int>()
            for bar in (group * 4)..<(group * 4 + 4) {
                for hit in bars[bar] { fragments.insert(hit.fragment) }
            }
            fragmentTotal += fragments.count
        }
        m.fragmentsPer4 = Double(fragmentTotal) / 4"""
path.write_text(text.replace(old, new))
