#!/usr/bin/env python3
"""Solo stems at final-mix level from a check-lofi.sh capture.

Each section stem (drums, bass, melody, chords, reverb-echo, chops, film-footage)
goes through the same pre-master staging gain, master latency, 25 Hz high-pass,
static finisher gain and time-varying glue/clip/limiter gain reduction
(master-gr.csv) as the real mix, so the stems sum back to master.wav. Like
pressing solo on a mixer channel.

usage: scripts/solo-stems.py CAPTURE_DIR OUT_DIR [--wav]
Writes numbered .m4a files (AAC 256k; --wav keeps float WAVs) and prints each
stem's level and the sum-of-stems residual against master.wav.

Encode headroom: every file is lowered by ENCODE_TRIM_DB (one common gain, so the
stems keep their relative levels and still sum to the mix) before the AAC encode,
because a lossy encode raises true peak (+0.23 dB for the master at 256k, +1.5 dB
at 160k on the 20 November 2026 capture; D121). The --wav files are not trimmed.
"""
import os, subprocess, sys
from pathlib import Path

import numpy as np, soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mixlib import delivery  # noqa: E402

# (file label, capture stem): the same seven stems as mixlib.delivery.DELIVERED.
STEMS = [('drums', 'drums'), ('bass', 'bass'), ('chords', 'texture'), ('melody', 'dry'),
         ('reverb-echo', 'wet'), ('chops', 'dialogue-chops'), ('film-footage', 'footage')]
ENCODE_TRIM_DB = -1.0

def main():
    cap, out = sys.argv[1], sys.argv[2]
    keep_wav = '--wav' in sys.argv
    os.makedirs(out, exist_ok=True)
    rd = lambda n: sf.read(os.path.join(cap, f'{n}.wav'), dtype='float64')
    master, sr = rd('master')
    # Latency and static finisher gain fitted against master.wav (mixlib.delivery, shared with
    # scripts/translation-report.py).
    chain, _ = delivery.load_chain(cap, master=master, pre=rd('pre-master')[0])
    print(f'latency {chain.latency} frames, finisher gain {20 * np.log10(chain.gain):+.2f} dB')
    db = lambda v: 20 * np.log10(v + 1e-12)
    rms = lambda v: np.sqrt(np.mean(v ** 2))
    try:
        import pyloudnorm as pyln; meter = pyln.Meter(sr)
    except ImportError:
        meter = None
    files = [('01-full-mix', master)]
    total = 0
    for i, (name, src) in enumerate(STEMS, start=2):
        y = chain.apply(rd(src)[0]); total = total + y
        files.append((f'{i:02d}-{name}', y))
        L = f'{meter.integrated_loudness(y):6.1f} LUFS' if meter else ''
        act = np.mean(np.abs(y).max(axis=1) > 10 ** (-60 / 20))
        print(f'{name:13s} rms {db(rms(y)):6.1f} dBFS  peak {db(np.abs(y).max()):6.1f} dBFS  {L}  active {act:4.0%}')
    print(f'sum of stems vs master: {db(rms(master - total) / rms(master)):.1f} dB')
    trim = 1.0 if keep_wav else 10 ** (ENCODE_TRIM_DB / 20)
    if not keep_wav:
        print(f'encode trim {ENCODE_TRIM_DB:+.1f} dB on every file before AAC 256k')
    for base, y in files:
        wav = os.path.join(out, base + '.wav')
        sf.write(wav, (y * trim).astype(np.float32), sr, subtype='FLOAT')
        if not keep_wav:
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', wav, '-c:a', 'aac', '-b:a', '256k',
                            os.path.join(out, base + '.m4a')], check=True)
            os.remove(wav)

if __name__ == '__main__':
    main()
