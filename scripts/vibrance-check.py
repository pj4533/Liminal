#!/usr/bin/env python3
"""Check a vibrance-eval output directory against the acceptance criteria in docs/plans/vibrance.md.

    vibrance-check.py <out-dir>

Reads <out-dir>/metrics.csv (from colorfulness.py) and the rendered PNGs. Exits 1 if any check fails.
"""
import csv, glob, os, sys
from collections import defaultdict
import numpy as np
from PIL import Image

KEYS = ("colorfulness", "sat_mean", "sat_p90", "chroma", "lum", "contrast")


def pct(a, b):
    return (a / b - 1.0) * 100.0 if b else 0.0


def main(out):
    rows = list(csv.DictReader(open(os.path.join(out, "metrics.csv"))))
    ok = True

    def check(name, value, lo=None, hi=None):
        nonlocal ok
        good = (lo is None or value >= lo) and (hi is None or value <= hi)
        ok &= good
        rng = f"[{'' if lo is None else lo}..{'' if hi is None else hi}]"
        print(f"{'PASS' if good else 'FAIL'}  {name}: {value:+.2f} {rng}")

    for mode in sorted({r["mode"] for r in rows}):
        print(f"== {mode}")
        by = {(r["image"], r["variant"]): {k: float(r[k]) for k in KEYS} for r in rows if r["mode"] == mode}
        images = sorted({i for i, _ in by})
        # 1. passthrough must be lossless
        worst = max(abs(pct(by[(i, "passthrough")][k], by[(i, "input")][k])) for i in images for k in KEYS)
        check("passthrough worst |delta| % (any metric, any image)", worst, hi=1.0)
        # 2. full pipeline vs input
        full = defaultdict(lambda: defaultdict(list))
        for (i, v), m in by.items():
            if v.endswith("_full"):
                for k in KEYS:
                    full[k][i].append(pct(m[k], by[(i, "input")][k]))
        mean = {k: float(np.mean([x for i in images for x in full[k][i]])) for k in KEYS}
        check("FULL sat_mean % (mean)", mean["sat_mean"], 0, 35)
        check("FULL sat_p90 % (mean)", mean["sat_p90"], -5, 20)
        check("FULL chroma % (mean)", mean["chroma"], 20, None)
        check("FULL colorfulness % (mean)", mean["colorfulness"], 20, None)
        check("FULL lum % (mean)", mean["lum"], -5, 15)
        check("FULL contrast % (mean)", mean["contrast"], -15, None)
        per_img = [float(np.mean(full["sat_mean"][i])) for i in images]
        check("FULL sat_mean % (worst image)", min(per_img), -5, None)
        check("FULL sat_mean % (most boosted image)", max(per_img), None, 60)
        # 3. marginal cost of each stage (full vs full-with-stage-off)
        ko = defaultdict(lambda: defaultdict(list))
        for (i, v), m in by.items():
            if "_ko_" in v:
                t, stage = v.split("_ko_")
                f = by.get((i, f"{t}_full"))
                if f:
                    for k in ("sat_mean", "chroma"):
                        ko[stage][k].append(pct(f[k], m[k]))
        for stage in sorted(ko):
            if stage == "kenburns":  # reframing changes content, not color
                continue
            for k in ("sat_mean", "chroma"):
                check(f"stage {stage} marginal {k} %", float(np.mean(ko[stage][k])), -8, None)
        # 4. clipping
        def clip(files):
            w, b = [], []
            for f in files:
                a = np.asarray(Image.open(f).convert("RGB"))
                w.append((a.min(2) >= 250).mean() * 100)
                b.append((a.max(2) <= 5).mean() * 100)
            return float(np.mean(w)), float(np.max(w)), float(np.mean(b))
        iw, _, ib = clip(sorted(glob.glob(os.path.join(out, mode, "*", "input.png"))))
        fw, fwmax, fb = clip(sorted(glob.glob(os.path.join(out, mode, "*", "t*_full.png"))))
        check("blown-white pixels % (mean; all channels >= 250)", fw, hi=0.3)
        check("blown-white pixels % (worst frame)", fwmax, hi=3.0)
        check(f"crushed-black pixels % minus input ({ib:.2f})", fb - ib, hi=1.5)
    print("ALL PASS" if ok else "SOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
