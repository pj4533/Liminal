#!/usr/bin/env python3
"""Measure acoustic phrase levels in an exported Lo-Fi mix (NumPy and SciPy)."""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.io import wavfile


def db(amplitude):
    return round(float(20 * np.log10(max(amplitude, 1e-10))), 2)


def body_db(samples, window):
    # Overlapping stereo RMS windows every 10 ms. Rests do not dilute loud phrases.
    power = np.mean(np.square(samples, dtype=np.float64), axis=1)
    sums = np.r_[0, np.cumsum(power)]
    windows = (sums[window:] - sums[:-window])[::max(1, window // 40)]
    return db(np.sqrt(windows.max() / window))


def measure(directory):
    rate = json.loads((directory / "manifest.json").read_text())["sampleRate"]
    stems = {}
    for name in ("dry", "texture", "wet", "master"):
        sr, stems[name] = wavfile.read(directory / f"{name}.wav", mmap=True)
        if sr != rate:
            raise ValueError(f"{name} sample rate differs from manifest")
    rows = []
    for phrase in json.loads((directory / "score.json").read_text()):
        start, stop = phrase["range"]
        dry, texture, wet, master = (stem[start:stop] for stem in stems.values())
        pitched = dry + texture + wet
        window = round(rate * 0.4)
        rows.append(dict(program=phrase["program"], startSeconds=round(start / rate, 2),
                         dry400=body_db(dry, window), wet400=body_db(wet, window),
                         instruments400=body_db(pitched, window), instrumentsPeak=db(np.abs(pitched).max()),
                         master400=body_db(master, window)))
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    args = parser.parse_args()
    print(json.dumps(measure(args.capture), indent=2))
