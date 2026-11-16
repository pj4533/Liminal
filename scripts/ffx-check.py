#!/usr/bin/env python3
"""Objective checks for archive footage woven into the picture (docs/plans/footage-fx.md 9).

    python3 scripts/ffx-check.py score DIR [--every 3] [--json OUT.json]   # DIR from scripts/ffx-clip.sh
    python3 scripts/ffx-check.py sheet DIR OUT.png [--count 12] [--cols 4]
    python3 scripts/ffx-check.py table DIR [DIR ...]                       # one line per check.json

DIR holds three renders of the same timeline (scripts/shader-bench.sh --footage-seq):
  frames/  footage on, plus the footage stage per frame (s0000-A.png: R = luma, G = slow average, B = motion)
  off/     footage off, effects on    (what the viewer sees today without footage)
  ref/     effects off, Ken Burns only (the plain picture)

Scores (luma, 384x256 unless noted; fx-structure.py metrics):
  Image readability: is the still image still the anchor?
    hog_ref_on / hog_ref_off   HOG similarity to the plain picture with / without footage
    keep_hog, keep_edge        on / off ratio of HOG and edge similarity to the plain picture (1 = the footage
                               costs nothing; the gate is on the median and on the worst tenth of frames)
    off_ssim                   SSIM between the footage-on and footage-off frame
  Footage visibility: can the film be seen at all?
    delta                      mean |on - off| in 8-bit levels (RGB)
    area                       share of the frame where |on - off| > 6 levels
    film_corr                  correlation of the on - off luma difference with the film's luma (96x64, the
                               stage placed 1:1 on the frame; a blend look that shows the film scores high)
    motion_corr                correlation over time of the film's motion energy with the frame-to-frame
                               change the footage adds (does the picture move when the film moves?)
  Temporal smoothness: no flicker, no pops.
    step_p95_on / _off         95th percentile of the mean luma change per 1/30 s (gated on the absolute value)
    step_ratio                 on / off of that (reported: on a dark, still picture any film motion is a large ratio)
    jerk_ratio                 on / off of the mean second difference (frame-to-frame flicker)
    flash                      largest change of the frame's mean luma within 1/10 s (photosensitivity)
"""
import argparse
import importlib.util
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fx_structure", os.path.join(HERE, "fx-structure.py"))
fx = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fx)

SIZE = (384, 256)
SMALL = (96, 64)

# First gates (docs/plans/footage-fx.md 9.2); "today" = the four shipped looks measured in the plan.
GATES = {
    "keep_hog": (">=", 0.85),       # median over the clip (today's looks: 0.96-1.00)
    "keep_hog_p10": (">=", 0.70),   # the worst tenth of frames still reads (today: 0.96-1.00)
    "delta": (">=", 2.0),           # the film is there ...
    "area": (">=", 0.05),
    "step_p95_on": ("<=", 0.010),   # ... and does not make the picture nervous (today's looks: at most 0.006;
    "jerk_ratio": ("<=", 1.8),      # the ratio to footage off is reported only: a dark still barely moves)
    "flash": ("<=", 0.04),
}


def load(path, size=SIZE):
    im = Image.open(path).convert("RGB").resize(size, Image.LANCZOS)
    a = np.asarray(im, dtype=np.float64) / 255.0
    return a, 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def corr(a, b):
    a, b = a.ravel(), b.ravel()
    if a.std() < 1e-9 or b.std() < 1e-9:
        return 0.0
    return float(np.corrcoef(a, b)[0, 1])


def gates_of(s):
    gates = {}
    for key, (op, lim) in GATES.items():
        v = s.get(key)
        gates[key] = {"value": v, "limit": f"{op} {lim}", "pass": v is not None and (v >= lim if op == ">=" else v <= lim)}
    return gates


def cmd_score(a):
    d = a.dir
    seq = json.load(open(os.path.join(d, "frames", "sequence.json")))
    frames = seq["frames"]
    rows = []
    prev = None
    means = []
    for k, f in enumerate(frames):
        name = f["frame"] + "-L.png"
        rgb_on, y_on = load(os.path.join(d, "frames", name))
        rgb_off, y_off = load(os.path.join(d, "off", name))
        row = {"frame": f["frame"], "rel": f["rel"],
               "videoMix": f["uniforms"].get("videoMix", 0), "videoMixB": f["uniforms"].get("videoMixB", 0)}
        diff = np.abs(rgb_on - rgb_off)
        row["delta"] = float(diff.mean() * 255)
        row["area"] = float((diff.max(axis=2) > 6 / 255).mean())
        means.append(float(y_on.mean()))
        stage_path = os.path.join(d, "frames", "s" + f["frame"][1:] + "-A.png")
        stage = None
        if os.path.exists(stage_path):
            st = np.asarray(Image.open(stage_path).convert("RGB").resize(SMALL, Image.LANCZOS), dtype=np.float64) / 255
            stage = st
            _, s_on = load(os.path.join(d, "frames", name), SMALL)
            _, s_off = load(os.path.join(d, "off", name), SMALL)
            row["film_corr"] = abs(corr(s_on - s_off, st[..., 0]))
            row["film_motion"] = float(st[..., 2].mean())
        if prev is not None:
            row["step_on"] = float(np.abs(y_on - prev["y_on"]).mean())
            row["step_off"] = float(np.abs(y_off - prev["y_off"]).mean())
            # What the footage adds between two frames: change of the on - off difference.
            row["added_step"] = float(np.abs((y_on - y_off) - (prev["y_on"] - prev["y_off"])).mean())
            if prev.get("d_on") is not None:
                row["jerk_on"] = float(np.abs((y_on - prev["y_on"]) - prev["d_on"]).mean())
                row["jerk_off"] = float(np.abs((y_off - prev["y_off"]) - prev["d_off"]).mean())
            d_on, d_off = y_on - prev["y_on"], y_off - prev["y_off"]
        else:
            d_on = d_off = None
        if k % a.every == 0:
            _, y_ref = load(os.path.join(d, "ref", name))
            with np.errstate(all="ignore"):
                row["hog_ref_on"], row["hog_ref_off"] = fx._hog(y_ref, y_on), fx._hog(y_ref, y_off)
            row["edge_ref_on"], row["edge_ref_off"] = fx._edge(y_ref, y_on), fx._edge(y_ref, y_off)
            row["off_ssim"] = fx._ssim(y_off, y_on)
        prev = {"y_on": y_on, "y_off": y_off, "d_on": d_on, "d_off": d_off}
        rows.append(row)

    def col(key):
        return np.array([r[key] for r in rows if key in r], dtype=np.float64)

    def med(key):
        v = col(key)
        return float(np.median(v)) if len(v) else None

    keep_hog = col("hog_ref_on") / np.maximum(col("hog_ref_off"), 1e-6)
    keep_edge = col("edge_ref_on") / np.maximum(col("edge_ref_off"), 1e-6)
    fps = seq["fps"]
    w = max(1, round(fps / 10))
    m = np.array(means)
    flash = float(max(np.abs(m[w:] - m[:-w]).max(), 0)) if len(m) > w else 0.0
    s = {
        "hog_ref_on": med("hog_ref_on"), "hog_ref_off": med("hog_ref_off"),
        "keep_hog": float(np.median(keep_hog)), "keep_hog_p10": float(np.quantile(keep_hog, 0.1)),
        "keep_edge": float(np.median(keep_edge)), "off_ssim": med("off_ssim"),
        "delta": med("delta"), "area": med("area"), "film_corr": med("film_corr"),
        "step_p95_on": float(np.quantile(col("step_on"), 0.95)), "step_p95_off": float(np.quantile(col("step_off"), 0.95)),
        "flash": flash, "videoMix": med("videoMix"),
    }
    s["step_ratio"] = s["step_p95_on"] / max(s["step_p95_off"], 1e-6)
    s["jerk_ratio"] = float(col("jerk_on").mean() / max(col("jerk_off").mean(), 1e-6))
    fm, ad = col("film_motion"), col("added_step")
    s["motion_corr"] = corr(fm[1:], ad) if len(fm) == len(ad) + 1 and len(ad) > 8 else None
    gates = gates_of(s)
    result = {"dir": d, "look": seq.get("look", ""), "look_b": seq.get("look_b", ""), "mode": seq.get("mode", ""), "image": os.path.basename(seq["image"]),
              "footage": os.path.basename(seq.get("footage", "")), "intensity": seq["intensity"],
              "frames": len(rows), "summary": {k: (round(v, 4) if isinstance(v, float) else v) for k, v in s.items()},
              "gates": gates, "pass": all(g["pass"] for g in gates.values())}
    text = json.dumps(result, indent=1)
    with open(a.json or os.path.join(d, "check.json"), "w") as f:
        f.write(text)
    print(text)


def cmd_sheet(a):
    seq = json.load(open(os.path.join(a.dir, "frames", "sequence.json")))
    frames = seq["frames"]
    picks = [int(round(x)) for x in np.linspace(0, len(frames) - 1, a.count)]
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
        u = f["uniforms"]
        draw.text((x + 2, y + 3), f"{f['rel']:.2f}s  mix {u.get('videoMix', 0):.2f}/{u.get('videoMixB', 0):.2f}", fill=(230, 230, 230))
    sheet.save(a.out)
    print(a.out)


def cmd_table(a):
    keys = ["keep_hog", "keep_hog_p10", "keep_edge", "delta", "area", "film_corr", "motion_corr",
            "step_p95_on", "step_ratio", "jerk_ratio", "flash", "videoMix"]
    print("| clip | look / mode | " + " | ".join(keys) + " | pass |")
    print("|---|---|" + "---|" * (len(keys) + 1))
    for d in a.dirs:
        p = d if d.endswith(".json") else os.path.join(d, "check.json")
        r = json.load(open(p))
        s = r["summary"]
        cells = ["-" if s.get(k) is None else (f"{s[k]:.4f}" if k == "step_p95_on" else f"{s[k]:.3f}") for k in keys]
        ok = all(g["pass"] for g in gates_of(s).values())   # with the current gates, not the stored ones
        name = os.path.basename(os.path.dirname(os.path.abspath(p)))
        print(f"| {name} | {r.get('mode') or r['look']} | " + " | ".join(cells) + f" | {'yes' if ok else 'NO'} |")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("score"); p.add_argument("dir"); p.add_argument("--every", type=int, default=3); p.add_argument("--json")
    p = sub.add_parser("sheet"); p.add_argument("dir"); p.add_argument("out")
    p.add_argument("--count", type=int, default=12); p.add_argument("--cols", type=int, default=4)
    p = sub.add_parser("table"); p.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    {"score": cmd_score, "sheet": cmd_sheet, "table": cmd_table}[a.cmd](a)


if __name__ == "__main__":
    main()
