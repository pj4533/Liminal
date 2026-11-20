#!/usr/bin/env python3
"""Prepare or measure Lo-Fi lead multisamples (NumPy, SciPy and FFmpeg).

Prepare: decode each source (WAV, FLAC, anything FFmpeg reads), fold to mono, resample to
32 kHz, trim leading silence while keeping the attack, roll off the top gently, match the
note body to a common level under a separate peak limit, and taper the tail. The result is
written as LofiLead-<group>-<midi>[-<layer>].wav (16-bit mono), the naming LofiSampleBank reads.
`--prefix LofiBass --group <kit>-<stroke>` writes the bass body samples instead (:LAYER is the round robin);
`--retune` resamples each file by its measured pitch error.

    scripts/prepare-lofi-samples.py prepare --group nylon --out Liminal/Audio/Lofi/InstrumentSamples \
        --source 'dir/C3.flac=48' --source 'dir/E3.flac=52' ...

`--source PATH=MIDI[:LAYER]` names the bundled concert-pitch root. `prepare` measures each
fundamental and refuses a file more than 50 cents from its root unless `--allow-detune`.

Measure: print the body level, peak, 2-5 kHz share and measured pitch of bundled samples.

    scripts/prepare-lofi-samples.py measure Liminal/Audio/Lofi/InstrumentSamples/LofiLead-grand-*.wav
"""
import argparse
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, resample_poly, sosfilt

RATE = 32_000
# Bundled Steinway layer-2 roots measure about -9 to -11 dBFS body RMS (strongest 75 ms), -2.5 dBFS peak.
DEFAULT_BODY_DB = -10.0
DEFAULT_PEAK_DB = -2.5


def decode(path):
    """Decode any FFmpeg-readable file to mono float32 at RATE."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(RATE),
                          "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def db(x):
    return 20 * np.log10(max(float(x), 1e-12))


def body_rms(x, window=int(0.075 * RATE)):
    """RMS of the strongest 75 ms window, the measure the renderer's lead gain also uses."""
    if len(x) < window:
        return float(np.sqrt(np.mean(x * x)))
    power = np.r_[0, np.cumsum(x * x)]
    return float(np.sqrt((power[window:] - power[:-window]).max() / window))


def rolloff(x, share=0.95):
    """Frequency under which `share` of the first second's energy lies."""
    seg = x[: RATE]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2
    freqs = np.fft.rfftfreq(len(seg), 1 / RATE)
    cumulative = np.cumsum(spec) / max(spec.sum(), 1e-20)
    return float(freqs[int(np.searchsorted(cumulative, share))])


def band_share(x, lo=2_000, hi=5_000):
    """Fraction of the first second's energy in lo..hi Hz (harshness proxy)."""
    seg = x[: RATE]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2
    freqs = np.fft.rfftfreq(len(seg), 1 / RATE)
    total = spec[freqs > 40].sum()
    return float(spec[(freqs >= lo) & (freqs < hi)].sum() / max(total, 1e-20))


def fundamental(x, expected_midi=None, floor=50.0, span=2.05, harmonic_refine=False):
    """Fundamental in Hz by subharmonic summation over the attack-free body.

    Autocorrelation alone locks onto a dominant second partial (several VCSL pianos), so each
    candidate f scores the spectrum at f, 2f, ... 8f with decaying weights, and the winner is refined
    on its first partial. Candidates span `floor` (50 Hz; bass uses 30 Hz, or 25 Hz under the label) to 1.4 kHz, or an octave either side of the
    label (`span`; bass narrows it to a tritone so the search cannot lock onto a subharmonic).
    """
    start = int(0.08 * RATE)
    seg = x[start:start + (2 * RATE if harmonic_refine else RATE)]  # bass: 2 s, a 27.5 Hz note has only 27 cycles in 1 s
    if len(seg) < 4096:
        seg = x[: RATE]
    seg = seg - seg.mean()
    n = 1 << 18
    mag = np.sqrt(np.abs(np.fft.rfft(seg * np.hanning(len(seg)), n)))
    bin_hz = RATE / n
    lo, hi = floor, 1_400.0
    if expected_midi is not None:
        f = 440 * 2 ** ((expected_midi - 69) / 12)
        lo, hi = max(f / span, floor), f * span
    candidates = lo * 2 ** (np.arange(int(1200 * np.log2(hi / lo) / 3)) * 3 / 1200)

    def partial(freq):
        k0 = int(freq * 0.985 / bin_hz)
        k1 = int(freq * 1.015 / bin_hz) + 1
        if k1 >= len(mag):
            return 0.0, freq
        k = k0 + int(np.argmax(mag[k0:k1]))
        return float(mag[k]), k * bin_hz

    scores = [sum(0.8 ** (h - 1) * partial(c * h)[0] for h in range(1, 9)) for c in candidates]
    best = candidates[int(np.argmax(scores))]
    if harmonic_refine:
        # Bass: the fundamental is often 15 dB under the 2nd and 3rd, so average f_h / h over the first four
        # partials weighted by magnitude instead of trusting the first partial alone.
        found = [(partial(best * h), h) for h in range(1, 5)]
        weights = [m for (m, _), _ in found]
        return sum(w * f / h for ((_, f), h), w in zip(found, weights)) / max(sum(weights), 1e-20)
    return partial(best)[1]


def midi_of(hz):
    return 69 + 12 * np.log2(hz / 440)


def bass_search(prefix, midi):
    """(floor Hz, span ratio) for the pitch search: lead keeps 50 Hz and an octave; bass uses a 30 Hz floor
    (25 Hz for notes under it, A0 sounds at 27.5 Hz) and a tritone span."""
    if prefix != "LofiBass":
        return 50.0, 2.05
    return (25.0 if midi is not None and midi < 24 else 30.0), 2 ** (6 / 12)


def prepare_one(path, midi, layer, args):
    floor, span = bass_search(args.prefix, midi)
    x = decode(path)
    # Trim leading silence: start 2 ms before the first sample above -50 dB of the peak.
    peak = np.abs(x).max()
    onset = int(np.argmax(np.abs(x) > peak * 10 ** (-50 / 20)))
    x = x[max(0, onset - int(0.002 * RATE)):]
    x = x[: int(args.duration * RATE)]
    # Top roll-off: a second-order low-pass by default; `--order 4` darkens a bright pickup.
    if args.lowpass > 0:
        sos = butter(args.order, args.lowpass, btype="low", fs=RATE, output="sos")
        x = sosfilt(sos, x)
    if args.highpass > 0:
        sos = butter(2, args.highpass, btype="high", fs=RATE, output="sos")
        x = sosfilt(sos, x)
    if args.retune:
        # Resample by the measured deviation so the fundamental lands on the label. The estimate depends on which part
        # of the note falls in its window, so repeat on the original until the resampled file measures within 1 cent.
        target = 440 * 2 ** ((midi - 69) / 12)
        hz0 = fundamental(x, midi, floor, span, args.prefix == "LofiBass")
        if abs(100 * (midi_of(hz0) - midi)) > 50:
            sys.exit(f"{Path(path).name}: measured pitch is {100 * (midi_of(hz0) - midi):+.0f} cents from MIDI {midi}; check the root")
        source, scale, best = x, target / hz0, None
        for _ in range(8):
            ratio = Fraction(scale).limit_denominator(4000)
            y = resample_poly(source, ratio.denominator, ratio.numerator)[: int(args.duration * RATE)]
            err = 100 * (midi_of(fundamental(y, midi, floor, span, args.prefix == "LofiBass")) - midi)
            if best is None or abs(err) < abs(best[0]):
                best = (err, y)
            if abs(err) < 1.0:
                break
            scale *= 2 ** (err / 1200)
        x = best[1]
    # Body match, then a separate peak limit (never boost a peak above the ceiling).
    gain = 10 ** (args.body_db / 20) / max(body_rms(x), 1e-9)
    gain = min(gain, 10 ** (args.peak_db / 20) / max(np.abs(x).max(), 1e-9))
    x = x * gain
    # Tapered tail: raised-cosine fade over the last `fade` seconds; 1 ms attack ramp only.
    fade = min(len(x) // 2, int(args.fade * RATE))
    x[-fade:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, fade))
    ramp = int(0.001 * RATE)
    x[:ramp] *= np.linspace(0, 1, ramp)
    hz = fundamental(x, midi, floor, span, args.prefix == "LofiBass")
    cents = 100 * (midi_of(hz) - midi)
    name = f"{args.prefix}-{args.group}-{midi}" + (f"-{layer}" if layer is not None else "") + ".wav"
    status = "ok" if abs(cents) <= 50 else "DETUNED"
    print(f"{name:32s} src={Path(path).name:36s} f0={hz:8.2f} Hz ({cents:+6.1f} c) "
          f"body={db(body_rms(x)):6.1f} dB peak={db(np.abs(x).max()):6.1f} dB "
          f"2-5k={100 * band_share(x):5.2f}% roll95={rolloff(x):6.0f} Hz len={len(x) / RATE:4.2f}s {status}")
    if status != "ok" and not args.allow_detune:
        sys.exit(f"{name}: measured pitch is {cents:+.0f} cents from MIDI {midi}; check the root")
    if not args.dry_run:
        out = Path(args.out) / name
        wavfile.write(out, RATE, np.clip(np.round(x * 32767), -32768, 32767).astype(np.int16))


def measure(paths):
    for p in paths:
        rate, data = wavfile.read(p)
        x = data.astype(np.float64)
        if data.dtype == np.int16:
            x /= 32768
        if x.ndim > 1:
            x = x.mean(axis=1)
        if rate != RATE:
            print(f"{Path(p).name}: rate {rate}, skipped")
            continue
        fields = Path(p).stem.split("-")
        # Label is the first numeric field after the prefix (LofiLead-grand-48-3, LofiBass-upright-short-40-2).
        label = next((int(f) for f in fields[1:] if f.isdigit()), None)
        hz = fundamental(x, label, *bass_search(fields[0], label), harmonic_refine=fields[0] == "LofiBass")
        off = f"{100 * (midi_of(hz) - label):+6.1f} c" if label else ""
        print(f"{Path(p).name:32s} body={db(body_rms(x)):6.1f} dB peak={db(np.abs(x).max()):6.1f} dB "
              f"2-5k={100 * band_share(x):5.2f}% roll95={rolloff(x):6.0f} Hz f0={hz:8.2f} Hz {off} len={len(x) / RATE:4.2f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--group", required=True, help="sample group, e.g. nylon, or <kit>-<stroke> for bass")
    prep.add_argument("--prefix", default="LofiLead", help="output prefix: LofiLead (default) or LofiBass "
                      "(LofiBass-<kit>-<stroke>-<midi>[-<rr>].wav, 30 Hz pitch floor)")
    prep.add_argument("--retune", action="store_true", help="resample by the measured deviation so the fundamental hits the label")
    prep.add_argument("--out", required=True)
    prep.add_argument("--source", action="append", required=True, help="PATH=MIDI[:LAYER]")
    prep.add_argument("--duration", type=float, default=2.65, help="seconds kept (loader limit is 3 s)")
    prep.add_argument("--fade", type=float, default=0.6, help="tail taper in seconds")
    prep.add_argument("--lowpass", type=float, default=7_500, help="Hz, 0 disables")
    prep.add_argument("--order", type=int, default=2, help="low-pass order")
    prep.add_argument("--highpass", type=float, default=45, help="Hz, 0 disables")
    prep.add_argument("--body-db", type=float, default=DEFAULT_BODY_DB)
    prep.add_argument("--peak-db", type=float, default=DEFAULT_PEAK_DB)
    prep.add_argument("--allow-detune", action="store_true")
    prep.add_argument("--dry-run", action="store_true")
    meas = sub.add_parser("measure")
    meas.add_argument("paths", nargs="+")
    args = parser.parse_args()
    if args.command == "measure":
        measure(args.paths)
        return
    Path(args.out).mkdir(parents=True, exist_ok=True)
    for spec in args.source:
        path, _, root = spec.rpartition("=")
        midi, _, layer = root.partition(":")
        prepare_one(path, int(midi), int(layer) if layer else None, args)


if __name__ == "__main__":
    main()
