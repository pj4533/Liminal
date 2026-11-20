#!/usr/bin/env python3
"""Per-stem band energy of a check-lofi.sh capture, with deltas to a baseline.

For each stem (drums, bass, texture, dry, wet, dialogue-chops, footage,
pre-master) prints the mean-square level in dB of 40-120 Hz, 120-300 Hz,
300-800 Hz and 1-4 kHz (4th-order zero-phase Butterworth band-passes), over the
whole file and over the stem's active windows only: 400 ms windows whose
full-band level is within 30 dB of the stem's strongest window. With
--baseline the same numbers for the baseline capture and the deltas are shown,
and the band gates of docs/plans/bass-tone-redo.md sections 6.1 and 6.5 are evaluated (they replace
the bass-and-pads 5.5 gates, which encoded the brighter D116 bass).

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
    """Band gates of docs/plans/bass-tone-redo.md 6.1 and 6.5 (the bass against the baseline capture,
    everything else unchanged)."""
    g = []

    def add(label, value, ok, limit):
        g.append({"gate": label, "value": round(value, 2), "limit": limit, "pass": bool(ok)})

    b, d, pm = cur["bass"], cur["drums"], cur["pre-master"]
    bb, pmb = base["bass"], base["pre-master"]
    v = b["40-120"]["active"] - d["40-120"]["active"]
    add("bass 40-120 vs drums 40-120 (active)", v, abs(v) <= 1.5, "within 1.5 dB")
    v = b["40-120"]["active"] - bb["40-120"]["active"]
    add("bass 40-120 vs baseline bass (active)", v, abs(v) <= 1, "within 1 dB")
    v = b["120-300"]["active"] - bb["120-300"]["active"]
    add("bass 120-300 vs baseline bass (active)", v, -4 <= v <= 0, "0 to 4 dB lower")
    v = b["300-800"]["active"] - bb["300-800"]["active"]
    add("bass 300-800 vs baseline bass (active)", v, v <= -7, ">= 7 dB lower")
    v = b["1-4k"]["active"] - bb["1-4k"]["active"]
    add("bass 1-4k vs baseline bass (active)", v, v <= -10, ">= 10 dB lower")
    v = b["1-4k"]["active"]
    add("bass 1-4k (active, absolute)", v, v <= -62, "<= -62 dB")
    for stem in ("texture", "dry", "wet", "dialogue-chops", "footage"):
        if cur.get(stem) and base.get(stem):
            v = max(abs(cur[stem][n]["whole"] - base[stem][n]["whole"]) for n in NAMES)
            add(f"{stem} unchanged (largest band change)", v, v <= 0.1, "within 0.1 dB")
    for name in ("40-120", "120-300"):
        v = pm[name]["active"] - pmb[name]["active"]
        add(f"pre-master {name} vs baseline", v, abs(v) <= 1, "within 1 dB")
    for name in ("300-800", "1-4k"):
        v = pm[name]["active"] - pmb[name]["active"]
        add(f"pre-master {name} vs baseline", v, -3 <= v <= 0, "0 to 3 dB lower")
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
    if base and all(cur.get(k) and base.get(k) for k in ("bass", "drums", "pre-master")):
        result["gates"] = gates(cur, base)
        print()
        for g in result["gates"]:
            print(f"{'PASS' if g['pass'] else 'FAIL'}  {g['gate']:45s} {g['value']:+8.2f}  ({g['limit']})")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(result, f, indent=1)


if __name__ == "__main__":
    main()
