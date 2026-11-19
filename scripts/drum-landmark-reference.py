#!/usr/bin/env python3
"""Independent reference for the Lo-Fi drum landmark detector.

The Swift detector (Liminal/Audio/Lofi/LofiDrumLandmarks.swift) uses a multiband STFT superflux.
This script uses a different method on the raw WAV takes: band envelopes at a 1 ms hop, their
dB derivative, and local-median peak picking. It then compares kicks and snares with the
`LANDMARKS {json}` lines that LofiRhythmTests prints for every installed take.

    python3 scripts/drum-landmark-reference.py --takes Liminal/SlowBurnDrums \
        --swift-log /path/to/rhythm-test.log --out /path/to/landmarks

Reported per take and class: recall (reference hits at or above the reference's strength median
that the Swift detector found with the same class), precision (Swift hits at or above that
median, measured with the reference's own strength at the Swift time, that the reference
confirms), and the median and p90 absolute attack difference of matched hits. Zoomed waveform
PNGs with both sets of marks are written for three takes. Neither detector is ground truth:
hand labels on complete takes remain the real test.
"""

import argparse
import json
import os
import sys
import warnings

import numpy as np
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d
from scipy.signal import butter, sosfiltfilt

HOP_MS = 1.0
MATCH_MS = 20.0
GAP_MS = {"kick": 50.0, "snare": 60.0}
HOLD_MS = {"low": 12, "mid": 4}  # trailing hold so low cycles and noise grain do not read as onsets
RISE_DB = 9.0          # minimum dB rise over the derivative span above the local median
MEDIAN_MS = 300.0      # local median window of the detection function
DERIVATIVE_MS = 3.0
CLICK_LEAD_MS = 45.0
LOW_SHARE = 0.5        # low (< 150 Hz) energy share that separates kicks from snares
FEATURE_MS = 60.0
ATTACK_SHARE = 0.15
FRESH_MS = 60.0
FRESH_RISE = 2.0
FLOOR_DB = 35.0


def load(path):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        rate, data = wavfile.read(path)
    if data.dtype.kind == "i":
        data = data.astype(np.float64) / float(np.iinfo(data.dtype).max)
    else:
        data = data.astype(np.float64)
    mono = data.mean(axis=1) if data.ndim > 1 else data
    return rate, mono


class Reference:
    def __init__(self, rate, mono):
        self.rate = rate
        self.mono = mono
        self.hop = max(1, int(round(rate * HOP_MS / 1000)))
        nyq = rate / 2
        self.low = sosfiltfilt(butter(4, 160, "low", fs=rate, output="sos"), mono)
        self.mid = sosfiltfilt(butter(4, [200, min(5000, 0.9 * nyq)], "band", fs=rate, output="sos"), mono)
        self.split_low = sosfiltfilt(butter(4, 150, "low", fs=rate, output="sos"), mono)
        self.split_high = mono - self.split_low
        self.env = {"low": self.envelope(self.low, HOLD_MS["low"]), "mid": self.envelope(self.mid, HOLD_MS["mid"])}

    def envelope(self, y, hold_ms):
        n = len(y) // self.hop
        blocks = np.abs(y[: n * self.hop]).reshape(n, self.hop).max(axis=1)
        width = max(1, int(round(hold_ms / HOP_MS)))
        # trailing maximum: value at j covers blocks j - width + 1 ... j
        return maximum_filter1d(blocks, size=width, origin=(width - 1) // 2, mode="nearest")

    def onsets(self, band, gap_ms):
        e = self.env[band]
        level = 20 * np.log10(e + 1e-6)
        span = max(1, int(round(DERIVATIVE_MS / HOP_MS)))
        d = np.zeros_like(level)
        d[span:] = np.maximum(0, level[span:] - level[:-span])
        half = int(MEDIAN_MS / HOP_MS / 2)
        padded = np.pad(d, half, mode="edge")
        windows = np.lib.stride_tricks.sliding_window_view(padded, 2 * half + 1)[:: 4]
        med = np.repeat(np.median(windows, axis=1), 4)[: len(d)]
        threshold = med + RISE_DB
        floor_level = 20 * np.log10(np.percentile(e, 99.5) + 1e-9) - FLOOR_DB  # ignore room noise
        radius = 4
        peaks = []
        for j in range(span, len(d) - radius):
            if d[j] <= threshold[j] or level[j] < floor_level:
                continue
            window = d[max(0, j - radius): j + radius + 1]
            if d[j] < window.max() or (j > 0 and d[j - 1] == d[j]):
                continue
            if peaks and (j - peaks[-1]) * HOP_MS < gap_ms:
                if d[j] > d[peaks[-1]]:
                    peaks[-1] = j
                continue
            peaks.append(j)
        return [self.refine(band, j) for j in peaks]

    def rise(self, band, frame):
        """Envelope rise above the preceding floor at a sample frame: the reference strength."""
        e = self.env[band]
        j = int(frame // self.hop)
        span = int(25 / HOP_MS)
        lo, hi = max(0, j - span), min(len(e), j + span + 1)
        if hi <= j:
            return 0.0
        return float(e[j:hi].max() - e[lo: j + 1].min())

    def refine(self, band, j):
        e = self.env[band]
        span = int(25 / HOP_MS)
        peak_j = j + int(np.argmax(e[j: j + span + 1]))
        floor = e[max(0, j - span): j + 1].min()
        peak = e[peak_j]
        target = floor + ATTACK_SHARE * (peak - floor)
        k = peak_j
        while k > max(0, j - span) and e[k - 1] > target:
            k -= 1
        # Sample-accurate crossing inside block k of the band signal.
        y = np.abs(self.low if band == "low" else self.mid)
        start = k * self.hop
        block = y[start: start + self.hop]
        above = np.nonzero(block > target)[0]
        frame = start + (int(above[0]) if len(above) else 0)
        return {"frame": frame, "strength": float(peak - floor)}

    def low_share(self, frame):
        n = int(FEATURE_MS * self.rate / 1000)
        lo = self.split_low[frame: frame + n]
        hi = self.split_high[frame: frame + n]
        total = float(np.sum(lo * lo) + np.sum(hi * hi))
        return float(np.sum(lo * lo)) / total if total > 0 else 0.0

    def hits(self):
        low = self.onsets("low", GAP_MS["kick"])
        mid = self.onsets("mid", GAP_MS["snare"])
        lead = CLICK_LEAD_MS * self.rate / 1000
        near = MATCH_MS * self.rate / 1000
        kicks, snares, used = [], [], set()
        for m in mid:
            share = self.low_share(m["frame"])
            if share >= LOW_SHARE:
                # A low-dominated transient is a kick's click: pair it with the low onset after it.
                # Ripples inside a ringing kick, below what the band held just before, are not clicks.
                if not self.fresh("mid", m["frame"], 1.0):
                    continue
                body = next((i for i, l in enumerate(low) if i not in used
                             and -near <= l["frame"] - m["frame"] <= lead), None)
                if body is not None:
                    used.add(body)
                    kicks.append({"frame": min(m["frame"], low[body]["frame"]), "strength": low[body]["strength"]})
                else:
                    kicks.append({"frame": m["frame"], "strength": self.rise("low", m["frame"])})
            else:
                snares.append({"frame": m["frame"], "strength": m["strength"]})
        for i, l in enumerate(low):
            if i in used:
                continue
            if self.low_share(l["frame"]) < LOW_SHARE or any(abs(s["frame"] - l["frame"]) <= near for s in snares):
                continue
            # No broadband transient: only a rise from relative quiet is a new hit. A swell inside a
            # ringing kick is beating between its modes.
            if self.fresh("low", l["frame"], FRESH_RISE):
                kicks.append(l)
        kicks.sort(key=lambda h: h["frame"])
        return {"kick": kicks, "snare": snares}

    def fresh(self, band, frame, factor):
        """True when the band peak after `frame` exceeds `factor` times its level just before."""
        e = self.env[band]
        j = frame // self.hop
        before = e[max(0, j - int(FRESH_MS / HOP_MS)): max(1, j - 3)]
        peak = e[j: j + int(25 / HOP_MS)].max()
        return not before.size or peak >= factor * before.max()


def compare(ref, ref_hits, swift_frames, scale, rate, verbose=False):
    """ref_hits in raw frames; swift_frames in take frames (scaled to raw by `scale`)."""
    tol = MATCH_MS * rate / 1000
    band = None
    out = {}
    for kind, band in (("kick", "low"), ("snare", "mid")):
        refs = ref_hits[kind]
        swift = [f * scale for f in swift_frames[kind]]
        if not refs:
            out[kind] = None
            continue
        median = float(np.median([h["strength"] for h in refs]))
        strong = [h for h in refs if h["strength"] >= median]
        swift_arr = np.array(swift) if swift else np.array([np.inf])
        diffs, found = [], 0
        for h in strong:
            k = int(np.argmin(np.abs(swift_arr - h["frame"])))
            delta = swift_arr[k] - h["frame"]
            if abs(delta) <= tol:
                found += 1
                diffs.append(abs(delta) * 1000 / rate)
            elif verbose:
                print(f"  missed {kind} at {h['frame'] / rate:.3f} s, strength {h['strength']:.3f}")
        ref_arr = np.array([h["frame"] for h in refs])
        considered, confirmed = 0, 0
        for f in swift:
            if ref.rise(band, f) < median:
                continue
            considered += 1
            if np.min(np.abs(ref_arr - f)) <= tol:
                confirmed += 1
            elif verbose:
                print(f"  unconfirmed {kind} at {f / rate:.3f} s, reference rise {ref.rise(band, f):.3f}")
        out[kind] = {
            "reference": len(refs), "strong": len(strong), "swift": len(swift),
            "recall": found / len(strong) if strong else 1.0,
            "precision": confirmed / considered if considered else 1.0,
            "considered": considered,
            "median_ms": float(np.median(diffs)) if diffs else float("nan"),
            "p90_ms": float(np.percentile(diffs, 90)) if diffs else float("nan"),
        }
    return out


def plot(path, ref, ref_hits, swift_frames, scale, rate, name, start_beat, beats, frames_per_beat_raw):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    a = int(start_beat * frames_per_beat_raw)
    b = min(len(ref.mono), int((start_beat + beats) * frames_per_beat_raw))
    t = np.arange(a, b) / rate
    fig, axes = plt.subplots(3, 1, figsize=(15, 8), sharex=True)
    for ax, sig, label in zip(axes, [ref.mono, ref.low, ref.mid], ["mono", "< 160 Hz", "200 Hz - 5 kHz"]):
        ax.plot(t, sig[a:b], color="0.2", lw=0.5)
        ax.set_ylabel(label)
    colors = {"kick": "tab:red", "snare": "tab:blue"}
    for kind, color in colors.items():
        for h in ref_hits[kind]:
            if a <= h["frame"] < b:
                for ax in axes:
                    ax.axvline(h["frame"] / rate, color=color, lw=1.6, alpha=0.35)
        for f in swift_frames[kind]:
            f = f * scale
            if a <= f < b:
                for ax in axes:
                    ax.axvline(f / rate, color=color, lw=0.8, ls="--")
    axes[0].set_title(f"{name}: beats {start_beat}-{start_beat + beats}. Wide pale = reference, dashed = Swift. "
                      "Red kick, blue snare")
    axes[-1].set_xlabel("seconds")
    fig.tight_layout()
    fig.savefig(path, dpi=90)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--takes", required=True, help="directory with the AJ Hall WAV takes")
    parser.add_argument("--swift-log", required=True, help="xcodebuild log containing LANDMARKS lines")
    parser.add_argument("--out", required=True, help="directory for PNGs and summary.json")
    parser.add_argument("--plots", type=int, default=3)
    parser.add_argument("--only", help="analyse only takes whose name contains this text")
    parser.add_argument("--verbose", action="store_true", help="list missed and unconfirmed hits")
    parser.add_argument("--plot-at", type=float, help="plot window start in beats (default 4)", default=4)
    parser.add_argument("--plot-beats", type=float, default=4)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    swift = {}
    with open(args.swift_log, errors="replace") as log:
        for line in log:
            at = line.find("LANDMARKS {")
            if at < 0:
                continue
            row = json.loads(line[at + len("LANDMARKS "):].strip())
            swift[row["name"]] = row
    if not swift:
        sys.exit("no LANDMARKS lines in the Swift log; did the private-take test run?")

    rows, worst = [], []
    names = sorted(n for n in swift if os.path.exists(os.path.join(args.takes, n + ".wav"))
                   and (args.only is None or args.only in n))
    for index, name in enumerate(names):
        row = swift[name]
        rate, mono = load(os.path.join(args.takes, name + ".wav"))
        ref = Reference(rate, mono)
        hits = ref.hits()
        take_frames = row["frames"]
        scale = len(mono) / take_frames      # raw frames per take frame
        if abs(row.get("sampleRate", rate) - rate) > 1:
            scale = len(mono) / take_frames
        frames = {"kick": [k[0] for k in row["kicks"]], "snare": [s[0] for s in row["snares"]]}
        if args.verbose:
            print(name)
        result = compare(ref, hits, frames, scale, rate, args.verbose)
        rows.append((name, result))
        if index < args.plots:
            fpb_raw = row["framesPerBeat"] * scale
            plot(os.path.join(args.out, f"{name}.png"), ref, hits, frames, scale, rate, name, args.plot_at,
                 args.plot_beats, fpb_raw)

    header = f"{'take':44} {'kind':5} {'ref':>4} {'strong':>6} {'swift':>5} {'recall':>6} {'prec':>6} {'med ms':>6} {'p90 ms':>6}"
    print(header)
    print("-" * len(header))
    totals = {"kick": [], "snare": []}
    for name, result in rows:
        short = name.replace("AJ_HALL_DRUM_BREAK_", "")
        for kind in ("kick", "snare"):
            r = result[kind]
            if r is None:
                print(f"{short:44} {kind:5} no reference hits")
                continue
            totals[kind].append(r)
            print(f"{short:44} {kind:5} {r['reference']:4d} {r['strong']:6d} {r['swift']:5d} {r['recall']:6.3f} "
                  f"{r['precision']:6.3f} {r['median_ms']:6.2f} {r['p90_ms']:6.2f}")
    summary = {}
    for kind, rs in totals.items():
        if not rs:
            continue
        strong = sum(r["strong"] for r in rs)
        considered = sum(r["considered"] for r in rs)
        recall = sum(r["recall"] * r["strong"] for r in rs) / max(1, strong)
        precision = sum(r["precision"] * r["considered"] for r in rs) / max(1, considered)
        summary[kind] = {"recall": recall, "precision": precision,
                         "median_ms": float(np.nanmedian([r["median_ms"] for r in rs])),
                         "p90_ms": float(np.nanmedian([r["p90_ms"] for r in rs])),
                         "min_recall": min(r["recall"] for r in rs), "min_precision": min(r["precision"] for r in rs)}
        s = summary[kind]
        print(f"ALL {kind}: recall {s['recall']:.3f} (min {s['min_recall']:.3f}), precision {s['precision']:.3f} "
              f"(min {s['min_precision']:.3f}), median {s['median_ms']:.2f} ms, p90 {s['p90_ms']:.2f} ms")
    with open(os.path.join(args.out, "summary.json"), "w") as f:
        json.dump({"overall": summary, "takes": {n: r for n, r in rows}}, f, indent=1)


if __name__ == "__main__":
    main()
