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
"""
import json, os, subprocess, sys
import numpy as np, soundfile as sf
from scipy.signal import butter, sosfilt

STEMS = [('drums', 'drums'), ('bass', 'bass'), ('chords', 'texture'), ('melody', 'dry'),
         ('reverb-echo', 'wet'), ('chops', 'dialogue-chops'), ('film-footage', 'footage')]

def main():
    cap, out = sys.argv[1], sys.argv[2]
    keep_wav = '--wav' in sys.argv
    os.makedirs(out, exist_ok=True)
    rd = lambda n: sf.read(os.path.join(cap, f'{n}.wav'), dtype='float64')
    master, sr = rd('master'); pre, _ = rd('pre-master')
    man = json.load(open(os.path.join(cap, 'manifest.json')))
    dyn = man.get('diagnostics', {}).get('masterDynamics', {})
    stage = 10 ** (dyn.get('preMasterStagingDb', 0.0) / 20)
    gr = np.loadtxt(os.path.join(cap, 'master-gr.csv'), delimiter=',', skiprows=1)
    env = 10 ** (-np.interp(np.arange(len(master)), gr[:, 0], gr[:, 1] + gr[:, 2] + gr[:, 3]) / 20)
    hp = butter(2, dyn.get('settings', {}).get('highpassHz', 25), 'highpass', fs=sr, output='sos')

    def chain(x, lat, g):
        y = np.zeros_like(x); y[lat:] = x[:len(x) - lat]
        return sosfilt(hp, y, axis=0) * (g * env[:, None])

    best = None  # fit latency and static gain of the finisher against master.wav
    for lat in range(max(0, dyn.get('latencyFrames', 200) - 60), dyn.get('latencyFrames', 200) + 60):
        r = chain(pre, lat, 1.0); g = np.sum(r * master) / np.sum(r * r)
        res = np.sqrt(np.mean((master - g * r) ** 2))
        if best is None or res < best[2]: best = (lat, g, res)
    lat, g, _ = best
    db = lambda v: 20 * np.log10(v + 1e-12)
    rms = lambda v: np.sqrt(np.mean(v ** 2))
    print(f'latency {lat} frames, finisher gain {db(g):+.2f} dB')
    try:
        import pyloudnorm as pyln; meter = pyln.Meter(sr)
    except ImportError:
        meter = None
    files = [('01-full-mix', master)]
    total = 0
    for i, (name, src) in enumerate(STEMS, start=2):
        y = chain(rd(src)[0] * stage, lat, g); total = total + y
        files.append((f'{i:02d}-{name}', y))
        L = f'{meter.integrated_loudness(y):6.1f} LUFS' if meter else ''
        act = np.mean(np.abs(y).max(axis=1) > 10 ** (-60 / 20))
        print(f'{name:13s} rms {db(rms(y)):6.1f} dBFS  peak {db(np.abs(y).max()):6.1f} dBFS  {L}  active {act:4.0%}')
    print(f'sum of stems vs master: {db(rms(master - total) / rms(master)):.1f} dB')
    for base, y in files:
        wav = os.path.join(out, base + '.wav')
        sf.write(wav, y.astype(np.float32), sr, subtype='FLOAT')
        if not keep_wav:
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', wav, '-c:a', 'aac', '-b:a', '256k',
                            os.path.join(out, base + '.m4a')], check=True)
            os.remove(wav)

if __name__ == '__main__':
    main()
