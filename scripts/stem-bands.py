#!/usr/bin/env python3
"""Per-stem band energy of a check-lofi.sh capture, with deltas to a baseline.

For each stem (drums, bass, texture, dry, wet, dialogue-chops, footage,
pre-master) prints the mean-square level in dB of 40-120 Hz, 120-300 Hz,
300-800 Hz and 1-4 kHz (4th-order zero-phase Butterworth band-passes), over the
whole file and over the stem's active windows only: 400 ms windows whose
full-band level is within 30 dB of the stem's strongest window. With
--baseline the same numbers for the baseline capture and the deltas are shown,
and the band gates of docs/plans/bass-and-pads.md section 5.5 are evaluated.

usage: scripts/stem-bands.py CAPTURE [--baseline CAPTURE] [--json OUT.json]
Exit status 0 always; the gate lines say PASS or FAIL.
"""
import argparse
import json
import os
import sys

import numpy as np
from scipy.signal import butter, sosfiltfilt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib.audio import read_wav  # noqa: E402

STEMS = ["drums", "bass", "texture", "dry", "wet", "dialogue-chops", "footage", "pre-master"]
BANDS = [(40, 120), (120, 300), (300, 800), (1000, 4000)]
NAMES = ["40-120", "120-300", "300-800", "1-4k"]
WINDOW_SECONDS = 0.4
GATE_DB = 30.0


def db(x):
    return 10 * np.log10(max(float(x), 1e-30))


def stem_bands(capture, stem):
    path = os.path.join(capture, f"{stem}.wav")
    if not os.path.exists(path):
        return None
    mm, rate = read_wav(path)
    x = np.asarray(mm, dtype=np.float64)
    if x.ndim == 1:
        x = x[:, None]
    w = int(WINDOW_SECONDS * rate)
    n = len(x) // w
    full = (x[: n * w] ** 2).mean(axis=1).reshape(n, w).mean(axis=1)
    active = full >= full.max() * 10 ** (-GATE_DB / 10) if n and full.max() > 0 else np.zeros(n, bool)
    out = {"activeShare": float(active.mean()) if n else 0.0}
    for (lo, hi), name in zip(BANDS, NAMES):
        sos = butter(4, [lo, hi], "bandpass", fs=rate, output="sos")
        p = (sosfiltfilt(sos, x, axis=0) ** 2).mean(axis=1)
        pw = p[: n * w].reshape(n, w).mean(axis=1)
        out[name] = {"whole": db(p.mean()), "active": db(pw[active].mean()) if active.any() else -300.0}
    return out


def gates(cur, base):
    g = []

    def add(label, value, ok, limit):
        g.append({"gate": label, "value": round(value, 2), "limit": limit, "pass": bool(ok)})

    b, d, t, m, pm = cur["bass"], cur["drums"], cur["texture"], cur["dry"], cur["pre-master"]
    bb, tb, pmb = base["bass"], base["texture"], base["pre-master"]
    v = b["40-120"]["active"] - d["40-120"]["active"]
    add("bass 40-120 vs drums 40-120 (active)", v, abs(v) <= 1.5, "within 1.5 dB")
    v = b["120-300"]["active"] - bb["120-300"]["active"]
    add("bass 120-300 vs baseline bass (active)", v, 5 <= v <= 9, "+5 to +9 dB")
    v = b["300-800"]["active"] - bb["300-800"]["active"]
    add("bass 300-800 vs baseline bass (active)", v, 8 <= v <= 14, "+8 to +14 dB")
    v = b["1-4k"]["active"]
    add("bass 1-4k (active, absolute)", v, v <= -55, "<= -55 dB")
    v = t["40-120"]["active"]
    add("chords 40-120 (active, absolute)", v, v <= -60, "<= -60 dB")
    v = t["120-300"]["active"] - tb["120-300"]["active"]
    add("chords 120-300 vs baseline (active)", v, v <= -4, "<= -4 dB")
    v = t["120-300"]["whole"] - tb["120-300"]["whole"]
    add("chords 120-300 vs baseline (whole file)", v, v <= 0, "<= 0 dB")
    v = t["300-800"]["whole"] - tb["300-800"]["whole"]
    add("chords 300-800 vs baseline (whole file)", v, v <= 2, "<= +2 dB")
    v = m["1-4k"]["active"] - t["1-4k"]["active"]
    add("chords 1-4k under melody 1-4k (active)", v, v >= 8, ">= 8 dB under")
    for name, limit in (("40-120", 1.5), ("120-300", 1.0), ("300-800", 1.0)):
        v = pm[name]["active"] - pmb[name]["active"]
        add(f"pre-master {name} vs baseline", v, v <= limit, f"<= +{limit} dB")
    v = pm["1-4k"]["active"] - pmb["1-4k"]["active"]
    add("pre-master 1-4k vs baseline", v, abs(v) <= 0.5, "within 0.5 dB")
    return g


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--baseline")
    ap.add_argument("--json")
    a = ap.parse_args()
    cur = {s: stem_bands(a.capture, s) for s in STEMS}
    base = {s: stem_bands(a.baseline, s) for s in STEMS} if a.baseline else None
    print(f"{'stem':15s} {'band':8s} {'whole':>8s} {'active':>8s}" + ("   base whole/active    delta" if base else ""))
    for s in STEMS:
        if cur[s] is None:
            continue
        for name in NAMES:
            c = cur[s][name]
            line = f"{s:15s} {name:8s} {c['whole']:8.1f} {c['active']:8.1f}"
            if base and base.get(s):
                o = base[s][name]
                line += (f"   {o['whole']:7.1f} {o['active']:7.1f}   "
                         f"{c['whole'] - o['whole']:+6.2f} {c['active'] - o['active']:+6.2f}")
            print(line)
    result = {"capture": a.capture, "baseline": a.baseline, "stems": cur, "baselineStems": base}
    if base and all(cur.get(k) and base.get(k) for k in ("bass", "drums", "texture", "dry", "pre-master")):
        result["gates"] = gates(cur, base)
        print()
        for g in result["gates"]:
            print(f"{'PASS' if g['pass'] else 'FAIL'}  {g['gate']:45s} {g['value']:+8.2f}  ({g['limit']})")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(result, f, indent=1)


if __name__ == "__main__":
    main()
