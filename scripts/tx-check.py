#!/usr/bin/env python3
"""Objective checks and contact sheets for a rendered image transition (docs/plans/transitions.md 8).

    python3 scripts/tx-check.py score DIR [--json OUT.json] [--csv OUT.csv] [--gate]
    python3 scripts/tx-check.py sheet DIR OUT.png [--from -0.3] [--to END] [--count 18] [--cols 6]
    python3 scripts/tx-check.py plot  DIR OUT.png

DIR is what scripts/tx-clip.sh writes: frames/ (the transition, with sequence.json), ref-a/ and ref-b/
(the same timeline with image A or image B alone and every effect off: what the viewer would see of
each picture without effects). Frames are compared on luma at 384x256.

Per frame
  vis_a / vis_b   how much of image A / image B is structurally visible: correlation of blurred
                  gradient magnitude with the effect-free frame of the same instant (the `edge` metric
                  of scripts/fx-structure.py), rescaled so that 0 = as similar as the two clean
                  pictures are to each other (an unrelated picture) and 1 = identical.
                  raw_a / raw_b / floor are the unscaled values.
  hog_a / hog_b   HOG cosine against the same references (shape descriptor, compressed range)
  step            mean absolute luma change from the previous written frame
  step_rgb        the same over RGB (colour pops that luma does not see)
  mean_luma       frame mean (strobing shows as fast reversals)

Summary (the gates of the plan; thresholds in GATES below)
  swap_frame      first frame from which image B stays more visible than image A
  swap_vis        max(vis_a, vis_b) at the swap, mean over the 3 frames around it. Low = the exchange
                  happens while neither picture can be read (hidden swap).
  double_exposure highest min(vis_a, vis_b) over the clip. High = both pictures readable at once
                  (the look of a plain dissolve).
  pop             largest step divided by the median step of the +-0.25 s around it (a hard cut or a
                  layer switching on shows as an isolated spike), and where it happened
  seam_in/out     the step at the first transition frame / the first frame after it, relative to the
                  median step of the 0.25 s before / after (does the transition grow out of and settle
                  back into the live effects, or start and stop with a jump)
  step_max        largest step anywhere
  strobe          luma reversals per second larger than 0.012 of full scale inside the transition
  peak_time       when the picture is least readable, as a fraction of the transition
  resolve         vis_b at the end of the clip (the new image has to come back readable)
  wild_seconds    seconds during which max(vis_a, vis_b) is under 0.25 (how long neither is readable)
"""
import argparse
import csv
import importlib.util
import json
import os
import sys

import warnings

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fx_structure", os.path.join(HERE, "fx-structure.py"))
fx = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fx)

warnings.filterwarnings("ignore", category=RuntimeWarning)  # spurious matmul warnings from Accelerate
SIZE = (384, 256)

# Gates (docs/plans/transitions.md section 8.2). "classic" in the comments = the shipped crossfade
# measured on 2 fixture pairs at the default intensity (docs/decisions/transitions.md T3).
GATES = {
    "swap_vis": ("<=", 0.20),         # neither picture readable while they exchange (classic 0.16 / 0.29)
    "double_exposure": ("<=", 0.18),  # never two readable pictures at once (classic 0.14 / 0.26)
    "pop": ("<=", 2.5),               # no isolated frame-to-frame spike (classic 2.9 / 6.8)
    "seam_in": ("<=", 2.5),           # starts without a jump (classic 12 / 24)
    "seam_out": ("<=", 2.5),          # ends without a jump (classic 9 / 9)
    "step_max": ("<=", 0.050),        # absolute limit on luma change per 1/30 s (classic 0.043 / 0.088)
    "strobe": ("<=", 3.0),            # luma reversals per second (no flashing)
    "resolve": (">=", 0.55),          # the new image is back by the end of the clip (classic 0.71 / 0.74)
}
# Below this Effect-intensity setting transitions are meant to be subtle: a soft dissolve is allowed
# to show more of both pictures (classic at intensity 0: swap_vis 0.48, double_exposure 0.43).
SUBTLE_BELOW = 0.4
SUBTLE_GATES = {"swap_vis": ("<=", 0.45), "double_exposure": ("<=", 0.40), "resolve": (">=", 0.70)}


def load(path):
    im = Image.open(path).convert("RGB").resize(SIZE, Image.LANCZOS)
    a = np.asarray(im, dtype=np.float64) / 255.0
    return a, 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def frames_of(d):
    seq = json.load(open(os.path.join(d, "frames", "sequence.json")))
    return seq, seq["frames"]


def measure(d):
    seq, frames = frames_of(d)
    rows, prev = [], None
    for f in frames:
        name = f["frame"] + "-L.png"
        rgb, y = load(os.path.join(d, "frames", name))
        _, ya = load(os.path.join(d, "ref-a", name))
        _, yb = load(os.path.join(d, "ref-b", name))
        # Two unrelated photos still correlate (both have a centred subject): subtract that floor.
        floor = max(fx._edge(ya, yb), 0.0)
        raw_a, raw_b = fx._edge(ya, y), fx._edge(yb, y)
        with np.errstate(all="ignore"):
            hog_a, hog_b = fx._hog(ya, y), fx._hog(yb, y)
        row = {"frame": f["frame"], "rel": f["rel"], "phase": f["phase"], "tp": f["tp"],
               "vis_a": (raw_a - floor) / (1 - floor), "vis_b": (raw_b - floor) / (1 - floor),
               "raw_a": raw_a, "raw_b": raw_b, "floor": floor, "hog_a": hog_a, "hog_b": hog_b,
               "mean_luma": float(y.mean()),
               "step": float(np.abs(y - prev[1]).mean()) if prev else 0.0,
               "step_rgb": float(np.abs(rgb - prev[0]).mean()) if prev else 0.0}
        rows.append(row)
        prev = (rgb, y)
    return seq, rows


def summarize(seq, rows):
    fps, dur = seq["fps"], seq["duration"]
    rel = np.array([r["rel"] for r in rows])
    va, vb = np.array([r["vis_a"] for r in rows]), np.array([r["vis_b"] for r in rows])
    step = np.array([r["step"] for r in rows])
    n = len(rows)
    win = max(2, int(round(0.25 * fps)))

    # Swap: first frame from which B stays ahead of A.
    ahead = vb > va
    swap = next((i for i in range(n) if ahead[i:].all()), n - 1)
    lo, hi = max(swap - 1, 0), min(swap + 2, n)
    swap_vis = float(np.maximum(va, vb)[lo:hi].mean())

    def local(i):  # median step around i, excluding i itself
        idx = [j for j in range(max(1, i - win), min(n, i + win + 1)) if j != i]
        return float(np.median(step[idx])) + 1e-4

    ratios = np.array([step[i] / local(i) if i > 0 else 0 for i in range(n)])
    pop_i = int(ratios.argmax())

    first_tx = next((i for i, r in enumerate(rows) if r["phase"] == "transition"), None)
    first_post = next((i for i, r in enumerate(rows) if r["phase"] == "post"), None)

    def seam(i, before):
        if i is None or i < 1:
            return 0.0
        idx = range(max(1, i - win), i) if before else range(i + 1, min(n, i + 1 + win))
        base = float(np.median(step[list(idx)])) + 1e-4 if len(idx) else 1e-4
        return float(step[i] / base)

    inside = [i for i, r in enumerate(rows) if r["phase"] == "transition"]
    luma = np.array([r["mean_luma"] for r in rows])
    reversals, last_ext, direction = 0, luma[inside[0]] if inside else 0, 0
    for i in inside[1:]:
        delta = luma[i] - last_ext
        if abs(delta) > 0.012:
            d = 1 if delta > 0 else -1
            if direction and d != direction:
                reversals += 1
            direction, last_ext = d, luma[i]
    worst = np.maximum(va, vb)
    peak = int(worst.argmin())
    return {
        "swap_frame": rows[swap]["frame"], "swap_rel": float(rel[swap]), "swap_tp": rows[swap]["tp"],
        "swap_vis": swap_vis,
        "double_exposure": float(np.minimum(va, vb).max()),
        "pop": float(ratios[pop_i]), "pop_rel": float(rel[pop_i]), "pop_phase": rows[pop_i]["phase"],
        "seam_in": seam(first_tx, True), "seam_out": seam(first_post, False),
        "step_max": float(step.max()), "step_max_rel": float(rel[int(step.argmax())]),
        "step_median_pre": float(np.median(step[1:first_tx])) if first_tx and first_tx > 1 else 0.0,
        "strobe": reversals / dur,
        "peak_time": float(rel[peak] / dur), "peak_vis": float(worst[peak]),
        "resolve": float(vb[-3:].mean()),
        "wild_seconds": float((worst < 0.25).sum() / fps),
        "vis_a_start": float(va[:3].mean()),
    }


# Drop gates (docs/plans/drop-transitions.md 8.2). d = the downbeat frame (sequence.json "downbeat_frame");
# the clip needs 60 fps and at least 1.5 s after the cut.
DROP_GATES = {
    "cut_frame": ("==", 0),            # the first frame showing the new picture is d exactly
    "clean_from_cut": (">=", 0.95),    # vis_b[d] against its settled median (d+30 ... d+90)
    "tail": ("<=", 1.5),               # largest step in d+3 ... d+12 against the settled median step
                                       # (d+1, d+2: the trails re-converge on the clean frame, 33 ms)
    "old_residue": ("<=", 0.05),       # vis_a[d] above its settled median
    "peak_at_cut": ("<=", 0.25),       # A barely readable over the last 3 build frames
    "build_monotonic": ("<=", 0.10),   # A's 9-frame median never comes back from 40 % of the build on
                                       # (glitch states re-hash per step: single frames flicker)
    "pre_leak": ("<=", 0.20),          # B before the cut (Bleed 0.40)
    "seam_in": ("<=", 2.5),            # the build grows out of the live effects
    "flash_rate": ("<=", 3),           # full-field mean-luma reversals of 0.10 or more in any 1 s (WCAG 2.3.1)
}
DROP_SUBTLE = {"peak_at_cut": ("<=", 0.45)}


def summarize_drop(seq, rows):
    fps = seq["fps"]
    d = int(seq["downbeat_frame"])
    n = len(rows)
    va, vb = np.array([r["vis_a"] for r in rows]), np.array([r["vis_b"] for r in rows])
    step = np.array([r["step"] for r in rows])
    luma = np.array([r["mean_luma"] for r in rows])
    settle = slice(min(d + int(0.5 * fps), n - 1), min(d + int(1.5 * fps), n))
    vb_set, va_set = float(np.median(vb[settle])), float(np.median(va[settle]))
    step_set = float(np.median(step[settle])) + 1e-4
    showing = [i for i in range(n) if vb[i] > 0.5 * vb_set and vb[i] > va[i]]
    first_new = next((i for i in showing if all(vb[j] > va[j] for j in range(i, min(n, i + 10)))), n - 1)
    build0 = next((i for i, r in enumerate(rows) if r["phase"] == "transition"), 0)
    lo = build0 + int(0.4 * (d - build0))
    med = np.array([np.median(va[max(lo, i - 4):min(i + 5, d)]) for i in range(lo, d)]) if d > lo else np.array([0.0])
    run_min, rise = np.inf, 0.0
    for v in med:
        run_min = min(run_min, v)
        rise = max(rise, v - run_min)
    win = max(2, int(round(0.25 * fps)))
    pre = step[max(1, build0 - win):build0]
    seam_in = float(step[build0] / (float(np.median(pre)) + 1e-4)) if build0 > 1 and len(pre) else 0.0
    # Mean-luma reversals of 0.10 or more (extrema of the luma curve with that swing).
    rev_t, ext, direction = [], luma[0], 0
    for i in range(1, n):
        delta = luma[i] - ext
        if abs(delta) >= 0.10:
            dd = 1 if delta > 0 else -1
            if direction and dd != direction:
                rev_t.append(rows[i]["rel"])
            direction, ext = dd, luma[i]
        elif direction and (luma[i] - ext) * direction > 0:
            ext = luma[i]
    flash = max((sum(1 for u in rev_t if t <= u < t + 1) for t in rev_t), default=0)
    return {
        "downbeat_frame": d, "first_new_frame": first_new, "cut_frame": first_new - d,
        "clean_from_cut": float(vb[d] / max(vb_set, 1e-4)),
        "tail": float(step[d + 3:d + 13].max() / step_set) if d + 3 < n else 0.0,
        "tail_d1": float(step[d + 1] / step_set) if d + 1 < n else 0.0,
        "old_residue": float(va[d] - va_set),
        "peak_at_cut": float(va[max(build0, d - 3):d].min()) if d > build0 else 1.0,
        "build_monotonic": float(rise),
        "pre_leak": float(vb[build0:d].max()) if d > build0 else 0.0,
        "seam_in": seam_in,
        "flash_rate": float(flash),
        "vis_b_cut": float(vb[d]), "vis_b_settled": vb_set, "vis_a_settled": va_set,
        "cut_step": float(step[d]), "step_settled": step_set,
    }


def gate_drop(summary, seq):
    gates = dict(DROP_GATES)
    if seq.get("intensity") is not None and seq["intensity"] < SUBTLE_BELOW:
        gates.update(DROP_SUBTLE)
    if seq.get("tx_style") == "bleed":
        gates["pre_leak"] = ("<=", 0.40)
    out = {}
    for k, (op, thr) in gates.items():
        v = summary[k]
        ok = v == thr if op == "==" else (v <= thr if op == "<=" else v >= thr)
        out[k] = {"value": round(v, 4) if isinstance(v, float) else v, "limit": f"{op} {thr}", "pass": bool(ok)}
    return out


def gate(summary, intensity=0.5):
    out = {}
    gates = dict(GATES)
    if intensity is not None and intensity < SUBTLE_BELOW:
        gates.update(SUBTLE_GATES)
    for k, (op, thr) in gates.items():
        v = summary[k]
        out[k] = {"value": round(v, 4), "limit": f"{op} {thr}", "pass": bool(v <= thr if op == "<=" else v >= thr)}
    return out


def cmd_score(a):
    seq, rows = measure(a.dir)
    if a.drop or seq.get("drop"):
        s = summarize_drop(seq, rows)
        g = gate_drop(s, seq)
    else:
        s = summarize(seq, rows)
        g = gate(s, seq.get("intensity"))
    result = {"dir": a.dir, "tx_style": seq.get("tx_style"), "tx_seed": seq.get("tx_seed"),
              "tx_colour": seq.get("tx_colour"), "tx_finisher": seq.get("tx_finisher"),
              "intensity": seq.get("intensity"), "duration": seq["duration"],
              "summary": {k: (round(v, 4) if isinstance(v, float) else v) for k, v in s.items()},
              "gates": g, "pass": all(x["pass"] for x in g.values())}
    csv_path = a.csv or os.path.join(a.dir, "metrics.csv")
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    text = json.dumps(result, indent=1)
    with open(a.json or os.path.join(a.dir, "check.json"), "w") as f:
        f.write(text)
    print(text)
    if a.gate and not result["pass"]:
        sys.exit(1)


def cmd_sheet(a):
    seq, frames = frames_of(a.dir)
    end = a.to if a.to is not None else seq["duration"] + 1.0
    targets = np.linspace(a.start, end, a.count)
    rel = np.array([f["rel"] for f in frames])
    picks = [int(np.abs(rel - t).argmin()) for t in targets]
    tw, th, pad, label = 384, 256, 4, 18
    cols = a.cols
    rows_n = (len(picks) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (tw + pad) + pad, rows_n * (th + label + pad) + pad), (16, 16, 16))
    draw = ImageDraw.Draw(sheet)
    for k, i in enumerate(picks):
        f = frames[i]
        im = Image.open(os.path.join(a.dir, "frames", f["frame"] + "-L.png")).convert("RGB").resize((tw, th), Image.LANCZOS)
        x, y = pad + (k % cols) * (tw + pad), pad + (k // cols) * (th + label + pad)
        sheet.paste(im, (x, y + label))
        tag = f"{f['rel']:+.2f}s  {f['phase']}" + (f"  tp {f['tp']:.2f}" if f["phase"] == "transition" else "")
        draw.text((x + 2, y + 3), tag, fill=(230, 230, 230))
    sheet.save(a.out)
    print(a.out)


def _ssim(x, y, k=8):
    """Mean SSIM over k x k blocks of two luma images (0...1 floats)."""
    h, w = (x.shape[0] // k) * k, (x.shape[1] // k) * k
    bx = x[:h, :w].reshape(h // k, k, w // k, k)
    by = y[:h, :w].reshape(h // k, k, w // k, k)
    mx, my = bx.mean(axis=(1, 3)), by.mean(axis=(1, 3))
    vx, vy = bx.var(axis=(1, 3)), by.var(axis=(1, 3))
    cxy = ((bx - mx[:, None, :, None]) * (by - my[:, None, :, None])).mean(axis=(1, 3))
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    return float((((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx ** 2 + my ** 2 + c1) * (vx + vy + c2))).mean())


def cmd_distinct(a):
    frames = {}
    for d in a.dirs:
        seq, fr = frames_of(d)
        build = [f for f in fr if f["phase"] == "transition"]
        f = min(build, key=lambda f: abs(f["tp"] - a.at))
        frames[seq.get("tx_style") or d] = load(os.path.join(d, "frames", f["frame"] + "-L.png"))[1]
    names = sorted(frames)
    pairs, worst = [], (None, -1.0)
    for i, p in enumerate(names):
        for q in names[i + 1:]:
            v = _ssim(frames[p], frames[q])
            pairs.append({"a": p, "b": q, "ssim": round(v, 4)})
            if v > worst[1]:
                worst = ((p, q), v)
    result = {"at": a.at, "limit": a.limit, "worst": {"pair": worst[0], "ssim": round(worst[1], 4)},
              "fail": [x for x in pairs if x["ssim"] > a.limit], "pass": worst[1] <= a.limit, "count": len(names)}
    print(json.dumps(result, indent=1))


def cmd_plot(a):
    """Small dependency-free chart: vis_a (orange), vis_b (blue), step x10 (white) over time."""
    seq, rows = measure(a.dir)
    w, h, m = 900, 300, 30
    im = Image.new("RGB", (w, h), (16, 16, 16))
    d = ImageDraw.Draw(im)
    rel = [r["rel"] for r in rows]
    x0, x1 = rel[0], rel[-1]

    def px(t, v):
        return (m + (t - x0) / (x1 - x0) * (w - 2 * m), h - m - min(max(v, 0), 1) * (h - 2 * m))

    for t in (0, seq["duration"]):
        d.line([px(t, 0), px(t, 1)], fill=(90, 90, 90))
    for key, col, k in (("vis_a", (255, 150, 40), 1), ("vis_b", (70, 150, 255), 1), ("step", (235, 235, 235), 10)):
        d.line([px(r["rel"], r[key] * k) for r in rows], fill=col, width=2)
    d.text((m, 6), "orange vis_a   blue vis_b   white step x10   grey lines: transition start / end", fill=(200, 200, 200))
    im.save(a.out)
    print(a.out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("score")
    s.add_argument("dir")
    s.add_argument("--json")
    s.add_argument("--csv")
    s.add_argument("--gate", action="store_true", help="exit 1 when a gate fails")
    s.add_argument("--drop", action="store_true", help="drop gates (also chosen by sequence.json \"drop\")")
    s.set_defaults(fn=cmd_score)
    s = sub.add_parser("distinct", help="drop styles must look different: SSIM at p = 0.9 between clip dirs")
    s.add_argument("dirs", nargs="+")
    s.add_argument("--at", type=float, default=0.9)
    s.add_argument("--limit", type=float, default=0.85)
    s.set_defaults(fn=cmd_distinct)
    s = sub.add_parser("sheet")
    s.add_argument("dir")
    s.add_argument("out")
    s.add_argument("--from", dest="start", type=float, default=-0.3)
    s.add_argument("--to", type=float)
    s.add_argument("--count", type=int, default=18)
    s.add_argument("--cols", type=int, default=6)
    s.set_defaults(fn=cmd_sheet)
    s = sub.add_parser("plot")
    s.add_argument("dir")
    s.add_argument("out")
    s.set_defaults(fn=cmd_plot)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
