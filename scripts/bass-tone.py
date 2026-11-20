#!/usr/bin/env python3
"""Bass tone gates of docs/plans/bass-tone-redo.md section 6 for one check-lofi.sh capture.

Reads bass.wav, drums.wav, score.json and manifest.json (diagnostics.bass) and prints, with PASS or FAIL:
- the third-octave table of bass.wav (Welch PSD, whole file; each band from its centre to the next) in dB re the power sum of the 50 and 63 Hz
  bands, against the allowed ranges of plan section 1; the power above 300 Hz re the stem total; the
  sustain-only bands 1-4 kHz (100 ms after each onset to the note's end) re the 50+63 Hz reference;
- continuity: the median sounding ratio per note and the share under 0.5 (score), silences longer than
  150 ms per minute (40-250 Hz envelope 40 dB under its 95th percentile, breakdown drop-outs excluded),
  and the stem's active share (400 ms windows within 30 dB of the loudest, as scripts/stem-bands.py);
- the strike: 300-1500 Hz and 1-3 kHz contrast (first 15 ms against 120-300 ms, from the strike's start
  `strikeOn` when the score has it, else the note's) on struck and unstruck notes, the 300-1500 Hz peak against the kick's broadband attack, and whether the first 15 ms is the
  brightest window of the note (300-3000 Hz power over 40-300 Hz power; see `brightness`).

Captures made before the strike existed (no `strike` in score.json) treat kick-anchored notes as struck.

usage: scripts/bass-tone.py CAPTURE [--baseline CAPTURE] [--json OUT.json]
Exit status 0 always; the gate lines say PASS or FAIL.
"""
import argparse
import json
import os
import sys

import numpy as np
from scipy.signal import butter, hilbert, sosfiltfilt, welch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib.audio import read_wav  # noqa: E402

CENTERS = [50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000]
# Each band runs from its nominal centre to the next one (4000 to 5000 Hz), the measure the plan's targets
# were set in: the 50 and 63 Hz bands then hold every structural fundamental (MIDI 31 to 39).
EDGES = CENTERS + [5000]
# (low, high) allowed in dB re 50+63 Hz; None = no bound (plan section 1).
ALLOWED = {80: (-18, -10), 100: (-20, -12), 125: (-20, -12), 160: (-21, -13), 200: (-20, -13), 250: (-23, -15),
           315: (-30, -21), 400: (-35, -25), 500: (-40, -29), 630: (-46, -33), 800: (-52, -38),
           1000: (None, -45), 1250: (None, -48), 1600: (None, -52), 2000: (None, -57), 2500: (None, -64),
           3150: (None, -70), 4000: (None, -76)}
# Release seconds per stroke when the capture does not carry them (D116 kits; classic and pluck 0.31).
OLD_RELEASE = {"thump": 0.060, "walk": 0.090, "hold": 0.160, "ghost": 0.050}


def db(x):
    return 10 * np.log10(max(float(x), 1e-30))


def band(x, rate, lo, hi, order=4):
    return sosfiltfilt(butter(order, [lo, hi], "bandpass", fs=rate, output="sos"), x)


def third_octaves(x, rate):
    f, p = welch(x, fs=rate, nperseg=1 << 14, window="hann")
    out = {}
    for c, hi in zip(CENTERS, EDGES[1:]):
        out[c] = float(p[(f >= c) & (f < hi)].sum())
    return f, p, out


def load_notes(cap):
    """Bass notes with on/off frames, stroke, strike, release, alignedKickFrame and the phrase index."""
    score = json.load(open(os.path.join(cap, "score.json")))
    man = json.load(open(os.path.join(cap, "manifest.json")))
    diag = {(n["frame"]): n for e in man.get("diagnostics", {}).get("bass", []) for n in e.get("notes", [])}
    voices = {e["phrase"]: e.get("voice") for e in man.get("diagnostics", {}).get("bass", [])}
    notes, phrases = [], []
    for p, phrase in enumerate(score):
        phrases.append(phrase)
        for n in phrase["notes"]:
            if n["role"] != "bass":
                continue
            d = diag.get(n["on"], {})
            stroke = n.get("stroke") or d.get("stroke")
            if "release" in n:
                release = n["release"]
            elif voices.get(p) in ("upright", "flatwound") and stroke in OLD_RELEASE:
                release = OLD_RELEASE[stroke]
            else:
                release = 0.31
            kick = d.get("alignedKickFrame")
            strike = n.get("strike")
            if strike is None:
                strike = 1.0 if kick is not None else 0.0
            notes.append(dict(on=n["on"], off=n["off"], strikeOn=n.get("strikeOn", n["on"]), stroke=stroke, strike=float(strike), release=release,
                              kick=kick, phrase=p, section=phrase["section"], range=phrase["range"],
                              legacyStrike="strike" not in n))
    return notes, phrases, man


def envelope(x, rate, smooth):
    env = np.abs(hilbert(x))
    w = max(1, int(round(smooth * rate)))
    return np.convolve(env, np.ones(w) / w, mode="same")


def rms_db(x):
    return db(np.mean(np.asarray(x, dtype=np.float64) ** 2)) if len(x) else -300.0


def brightness(seg, rate):
    """Brightness of a short window: 300-3000 Hz power over 40-300 Hz power, dB. (A spectral centroid of the
    bass is the fundamental's, about 90 Hz, and above the sub it follows the body's partials beating in a
    15 ms window more than the strike.)"""
    seg = seg * np.hanning(len(seg))
    spec = np.abs(np.fft.rfft(seg, 4096)) ** 2
    f = np.fft.rfftfreq(4096, 1 / rate)
    hi = spec[(f >= 300) & (f < 3000)].sum()
    lo = spec[(f >= 40) & (f < 300)].sum()
    return db(hi / lo) if lo > 0 else -300.0


def analyze(cap):
    mm, rate = read_wav(os.path.join(cap, "bass.wav"))
    x = np.asarray(mm[:, 0], dtype=np.float64)
    notes, phrases, man = load_notes(cap)
    r = {"capture": cap}
    total = float(np.mean(x ** 2))
    f, p, bands = third_octaves(x, rate)
    ref = bands[50] + bands[63]
    r["thirds"] = {c: db(bands[c] / ref) for c in CENTERS}
    r["above300"] = db(p[f >= 300].sum() / p.sum())
    r["refUnderTotal"] = db(ref / p.sum())

    # Sustain-only spectrum: frames from 100 ms after onset to the note's end. Each stretch gets its own
    # windowed segments (no joins, so no join clicks), averaged by length, as power per band.
    seg = 2048
    acc, used = None, 0
    for n in notes:
        a, b = n["on"] + int(0.1 * rate), min(n["off"], len(x))
        if b - a < seg:
            continue
        fs, ps = welch(x[a:b], fs=rate, nperseg=seg, window="hann")
        acc = ps * (b - a) if acc is None else acc + ps * (b - a)
        used += b - a
    if used:
        ps, df = acc / used, fs[1] - fs[0]
        ref_power = ref * (f[1] - f[0])
        r["sustain"] = {c: db(ps[(fs >= c) & (fs < hi)].sum() * df / ref_power)
                        for c, hi in zip(CENTERS, EDGES[1:]) if 1000 <= c <= 4000}
        r["sustainSeconds"] = used / rate

    # Continuity: sounding ratio per note.
    ratios = []
    by_phrase = {}
    for n in notes:
        by_phrase.setdefault(n["phrase"], []).append(n)
    dropouts = []
    for ph, ns in by_phrase.items():
        ns.sort(key=lambda n: n["on"])
        for i, n in enumerate(ns[:-1]):
            nxt = ns[i + 1]
            gap = nxt["on"] - n["on"]
            if gap <= 0:
                continue
            ratios.append(min(1.0, (n["off"] - n["on"] + n["release"] * rate) / gap))
        if ns and ns[0]["section"] == "breakdown":
            last = ns[-1]
            dropouts.append((last["off"] + int(last["release"] * rate), ns[0]["range"][1]))
    ratios = np.array(ratios)
    r["soundingMedian"] = float(np.median(ratios)) if len(ratios) else 0.0
    r["soundingUnderHalf"] = float((ratios < 0.5).mean()) if len(ratios) else 1.0

    # Silences > 150 ms in the 40-250 Hz envelope.
    low = band(x, rate, 40, 250)
    hop = int(0.005 * rate)
    env = np.sqrt(np.convolve(low ** 2, np.ones(hop) / hop, mode="same"))[::hop]
    thr = np.percentile(env, 95) * 10 ** (-40 / 20)
    quiet = env < thr
    excl = np.zeros(len(env), bool)
    for a, b in dropouts:
        excl[a // hop:b // hop + 1] = True
    count, run = 0, 0
    for q, e in zip(quiet, excl):
        if q and not e:
            run += 1
        else:
            if run * hop / rate > 0.150:
                count += 1
            run = 0
    if run * hop / rate > 0.150:
        count += 1
    minutes = (len(x) - sum(b - a for a, b in dropouts)) / rate / 60
    r["silencesPerMinute"] = count / minutes

    # Active share as stem-bands.py.
    stereo = np.asarray(mm, dtype=np.float64)
    w = int(0.4 * rate)
    k = len(stereo) // w
    full = (stereo[: k * w] ** 2).mean(axis=1).reshape(k, w).mean(axis=1)
    r["activeShare"] = float((full >= full.max() * 1e-3).mean())

    # Strike.
    mid = band(x, rate, 300, 1500)
    high = band(x, rate, 1000, 3000)
    env_mid = envelope(mid, rate, 0.001)
    drums_mm, _ = read_wav(os.path.join(cap, "drums.wav"))
    s15, s120, s300 = int(0.015 * rate), int(0.120 * rate), int(0.300 * rate)
    struck, plain, hi_c, hi_sus, timing, bright = [], [], [], [], [], []
    for n in notes:
        # The strike's own start (score `strikeOn`: an anchored note's strike sits on the kick's attack,
        # up to 25 ms before the note's start), else the note start.
        t0, length = n["strikeOn"], n["off"] - n["on"]
        if length < 0.32 * rate or t0 + s300 > len(x):
            continue
        c_mid = rms_db(mid[t0:t0 + s15]) - rms_db(mid[t0 + s120:t0 + s300])
        if n["strike"] >= 1:
            struck.append(c_mid)
            hi_c.append(rms_db(high[t0:t0 + s15]) - rms_db(high[t0 + s120:t0 + s300]))
            hi_sus.append(rms_db(high[t0 + s120:t0 + s300]) - db(total))
            if n["kick"] is not None:
                a = max(0, t0 - int(0.010 * rate))
                b = t0 + int(0.080 * rate)
                peak = a + int(np.argmax(env_mid[a:b]))
                timing.append((peak - n["kick"]) / rate * 1000)
            first = brightness(x[t0:t0 + s15], rate)
            later = [brightness(x[s:s + s15], rate) for s in range(t0 + s15, t0 + length - s15, s15)]
            bright.append(bool(later) and first > max(later))
        elif n["strike"] == 0:
            plain.append(c_mid)
    pct = lambda v, q: float(np.percentile(v, q)) if len(v) else float("nan")
    r["strike"] = {"struckNotes": len(struck), "plainNotes": len(plain),
                   "contrastMedian": pct(struck, 50), "contrastP10": pct(struck, 10),
                   "plainContrastMedian": pct(plain, 50),
                   "highContrastMedian": pct(hi_c, 50), "highSustainMedian": pct(hi_sus, 50),
                   "timingAbsMedian": pct(np.abs(timing), 50), "timingAbsP90": pct(np.abs(timing), 90),
                   "timingSignedMedian": pct(timing, 50),
                   "brightestFirstShare": float(np.mean(bright)) if bright else float("nan"),
                   "legacyStrike": any(n["legacyStrike"] for n in notes)}
    return r


def gates(r):
    g = []

    def add(label, value, ok, limit):
        g.append({"gate": label, "value": None if value is None else round(float(value), 2),
                  "limit": limit, "pass": bool(ok)})

    for c, (lo, hi) in ALLOWED.items():
        v = r["thirds"][c]
        ok = (lo is None or v >= lo) and v <= hi
        add(f"third {c} Hz re 50+63", v, ok, f"{'' if lo is None else lo} to {hi}")
    v = r["above300"]
    add("power above 300 Hz re total", v, -27 <= v <= -22, "-27 to -22")
    for c, v in (r.get("sustain") or {}).items():
        add(f"sustain-only {c} Hz re 50+63", v, v <= -55, "<= -55")
    add("sounding ratio median", r["soundingMedian"], r["soundingMedian"] >= 0.85, ">= 0.85")
    add("notes sounding under half", r["soundingUnderHalf"], r["soundingUnderHalf"] <= 0.15, "<= 0.15")
    add("silences > 150 ms per minute", r["silencesPerMinute"], r["silencesPerMinute"] <= 16, "<= 16")
    add("stem active share", r["activeShare"], 0.72 <= r["activeShare"] <= 0.92, "0.72 to 0.92")
    s = r["strike"]
    add("slap contrast 300-1500 median", s["contrastMedian"], s["contrastMedian"] >= 10, ">= +10 dB")
    add("slap contrast 300-1500 p10", s["contrastP10"], s["contrastP10"] >= 6, ">= +6 dB")
    add("unstruck contrast median", s["plainContrastMedian"],
        not np.isfinite(s["plainContrastMedian"]) or s["plainContrastMedian"] <= 3, "<= +3 dB")
    add("high contrast 1-3k median", s["highContrastMedian"], s["highContrastMedian"] >= 15, ">= +15 dB")
    add("high sustain 1-3k re total", s["highSustainMedian"], s["highSustainMedian"] <= -58, "<= -58 dB")
    add("strike peak vs kick |median| ms", s["timingAbsMedian"], s["timingAbsMedian"] <= 6, "<= 6 ms")
    add("strike peak vs kick |p90| ms", s["timingAbsP90"], s["timingAbsP90"] <= 12, "<= 12 ms")
    add("brightest at the strike share", s["brightestFirstShare"], s["brightestFirstShare"] >= 0.9, ">= 0.90")
    return g


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--baseline")
    ap.add_argument("--json")
    a = ap.parse_args()
    cur = analyze(a.capture)
    base = analyze(a.baseline) if a.baseline else None
    cur["gates"] = gates(cur)
    bmap = {}
    if base:
        base["gates"] = gates(base)
        bmap = {g["gate"]: g["value"] for g in base["gates"]}
    print(f"reference 50+63 Hz is {cur['refUnderTotal']:.1f} dB re the stem total"
          + (f" (baseline {base['refUnderTotal']:.1f})" if base else ""))
    print(f"{'':4s}  {'gate':38s} {'value':>8s} {'baseline':>9s}  limit")
    for g in cur["gates"]:
        bv = bmap.get(g["gate"])
        bs = f"{bv:9.2f}" if isinstance(bv, (int, float)) and bv is not None else f"{'':9s}"
        vs = f"{g['value']:8.2f}" if g["value"] is not None else f"{'nan':>8s}"
        print(f"{'PASS' if g['pass'] else 'FAIL'}  {g['gate']:38s} {vs} {bs}  ({g['limit']})")
    s = cur["strike"]
    print(f"struck notes {s['struckNotes']}, unstruck {s['plainNotes']}, strike signed median "
          f"{s['timingSignedMedian']:.2f} ms" + (" (strike from kick anchors)" if s["legacyStrike"] else ""))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"current": cur, "baseline": base}, f, indent=1, default=float)


if __name__ == "__main__":
    main()
