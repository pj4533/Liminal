#!/usr/bin/env python3
"""Effect attribution: how much does each effect destroy the structure of the source image?

    python3 scripts/fx-structure.py render  --out DIR [--fixtures a.jpg,b.jpg] [--times 20,137,...]
    python3 scripts/fx-structure.py analyze --out DIR            # writes DIR/metrics.csv, DIR/summary.md
    python3 scripts/fx-structure.py sweep   --out DIR [...]      # full pipeline only, many times
    python3 scripts/fx-structure.py score   REF.png FRAME.png    # the four metrics for one pair

`render` drives scripts/shader-bench.sh (the real shader and the app's own uniform code, frozen
time, 30 feedback frames) once per fixture with a scenario list. Per time it renders:
  ref          every effect off, Ken Burns on: the picture the viewer would see with no effects
  full         the pipeline as shipped
  ko_<effect>  full with that one effect off        (marginal damage with everything else on)
  solo_<effect> ref plus that one effect            (damage of the effect alone)
  geo / color  only the three UV warps / only the colour stages
Frames are the left eye at 768x512 (the 3:2 picture as displayed).
Fixture names are relative to $FX_FIXTURES (default tools/ShaderBench/fixtures); absolute paths work too.

Metrics, all on luma (so hue rotation alone costs nothing) against `ref` of the same time:
  ssim    SSIM at 384x256            fine structure and position
  coarse  SSIM at 96x64              layout: where the big shapes are
  edge    correlation of blurred gradient magnitude (sigma 1.5 px at 384 wide)   contours
  hog     cosine similarity of HOG descriptors (16 px cells, 9 unsigned orientations)
          contrast- and hue-agnostic shape descriptor; the closest proxy for "can I tell what it is"
Loss = 1 - metric. Ken Burns is not scored as structure loss (it is a crop); `analyze` reports the
visible fraction instead.
"""
import argparse
import csv
import json
import os
import subprocess
import sys
from collections import defaultdict

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
# Directory holding the fixture images (photos with a known subject; not in the repo).
DEFAULT_FIXTURES = os.environ.get("FX_FIXTURES", os.path.join(os.path.dirname(HERE), "tools", "ShaderBench", "fixtures"))
DEFAULT_TIMES = "20,137,251,368,489,603,724,871"

# Uniforms that switch each effect off (value 0).
EFFECTS = {
    "turbulence": ["distortionAmplitude"],
    "logsphere": ["logSphereAmount"],
    "noise": ["fractalNoiseAmount"],
    "chromatic": ["chromaticAmount"],
    "huewaves": ["hueBlendAmount", "hueWaveIntensity"],
    "fractalhue": ["fractalHueAmount"],
    "bloom": ["bloomAmount"],
    "ghost": ["ghostTapCount"],
    "feedback": ["feedbackMix"],
    "vibrance": ["vibranceAmount", "blackPoint"],
}
GEO = ["turbulence", "logsphere", "noise"]
ALWAYS = {"stereoOffset": 0}  # no depth map for the fixtures


def off(names):
    d = dict(ALWAYS)
    for n in names:
        for k in EFFECTS[n]:
            d[k] = 0
    return d


def variants():
    v = {"ref": off(EFFECTS), "full": dict(ALWAYS)}
    for e in EFFECTS:
        v["ko_" + e] = off([e])
        v["solo_" + e] = off([x for x in EFFECTS if x != e])
    v["geo"] = off([x for x in EFFECTS if x not in GEO])
    v["color"] = off(GEO)
    return v


def run_bench(image, scenarios, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    sc_path = os.path.join(out_dir, "scenarios.json")
    with open(sc_path, "w") as f:
        json.dump(scenarios, f)
    cmd = [os.path.join(HERE, "shader-bench.sh"), "--image", image, "--scenarios", sc_path, "--render-only",
           "--left-only", "--png-size", "768x512", "--out", out_dir, "--json", os.path.join(out_dir, "uniforms.json")]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def fixtures_arg(a):
    names = a.fixtures.split(",")
    return [n if os.path.isabs(n) else os.path.join(DEFAULT_FIXTURES, n) for n in names]


def cmd_render(a):
    times = [float(t) for t in a.times.split(",")]
    for img in fixtures_arg(a):
        stem = os.path.splitext(os.path.basename(img))[0]
        scenarios = [{"name": f"t{int(t)}_{name}", "time": t, "tp": a.tp, "set": over}
                     for t in times for name, over in variants().items()]
        print(f"{stem}: {len(scenarios)} frames", file=sys.stderr)
        run_bench(img, scenarios, os.path.join(a.out, stem))


def cmd_sweep(a):
    times = [float(t) for t in a.times.split(",")]
    for img in fixtures_arg(a):
        stem = os.path.splitext(os.path.basename(img))[0]
        scenarios = []
        for t in times:
            scenarios.append({"name": f"t{int(t)}_ref", "time": t, "set": off(EFFECTS)})
            scenarios.append({"name": f"t{int(t)}_full", "time": t, "set": dict(ALWAYS)})
        print(f"{stem}: {len(scenarios)} frames", file=sys.stderr)
        run_bench(img, scenarios, os.path.join(a.out, stem))


# ---------------------------------------------------------------- metrics

def luma(path, size):
    im = Image.open(path).convert("RGB").resize(size, Image.LANCZOS)
    a = np.asarray(im, dtype=np.float64) / 255.0
    return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def _ssim(a, b):
    from skimage.metrics import structural_similarity
    return float(structural_similarity(a, b, data_range=1.0, gaussian_weights=True, sigma=1.5,
                                       use_sample_covariance=False))


def _edge(a, b):
    from scipy import ndimage
    def g(x):
        return ndimage.gaussian_filter(np.hypot(ndimage.sobel(x, 0), ndimage.sobel(x, 1)), 1.5)
    ga, gb = g(a).ravel(), g(b).ravel()
    if ga.std() < 1e-9 or gb.std() < 1e-9:
        return 0.0
    return float(np.corrcoef(ga, gb)[0, 1])


def _hog(a, b):
    from skimage.feature import hog
    def h(x):
        return hog(x, orientations=9, pixels_per_cell=(16, 16), cells_per_block=(2, 2), feature_vector=True)
    ha, hb = h(a), h(b)
    n = np.linalg.norm(ha) * np.linalg.norm(hb)
    return float(ha @ hb / n) if n > 0 else 0.0


def score(ref_path, frame_path):
    r, f = luma(ref_path, (384, 256)), luma(frame_path, (384, 256))
    rc, fc = luma(ref_path, (96, 64)), luma(frame_path, (96, 64))
    return {"ssim": _ssim(r, f), "coarse": _ssim(rc, fc), "edge": _edge(r, f), "hog": _hog(r, f)}


METRICS = ["ssim", "coarse", "edge", "hog"]


def collect(out):
    rows = []
    for stem in sorted(os.listdir(out)):
        d = os.path.join(out, stem)
        if not os.path.isfile(os.path.join(d, "uniforms.json")):
            continue
        uni = json.load(open(os.path.join(d, "uniforms.json")))["uniforms"]
        for name in sorted(uni):
            t, variant = name.split("_", 1)
            if variant == "ref":
                continue
            s = score(os.path.join(d, f"{t}_ref-L.png"), os.path.join(d, f"{name}-L.png"))
            rows.append({"fixture": stem, "time": int(t[1:]), "variant": variant, **s,
                         **{"u_" + k: v for k, v in uni[f"{t}_full"].items()}})
    return rows


def cmd_analyze(a):
    rows = collect(a.out)
    if not rows:
        sys.exit("no rendered fixtures under " + a.out)
    keys = list(rows[0].keys())
    with open(os.path.join(a.out, "metrics.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)

    by = defaultdict(list)
    for r in rows:
        by[r["variant"]].append(r)
    full = {(r["fixture"], r["time"]): r for r in by["full"]}
    lines = ["# Effect structure attribution", "",
             f"{len(full)} frames ({len({k[0] for k in full})} fixtures x {len({k[1] for k in full})} times). "
             "Loss = 1 - metric vs the effect-free frame (Ken Burns kept). Mean [worst frame].", ""]

    def cell(vals):
        return f"{np.mean(vals):.3f} [{np.max(vals):.3f}]"

    lines += ["## Whole pipeline", "", "| variant | " + " | ".join(f"{m} loss" for m in METRICS) + " |",
              "|---|" + "---|" * len(METRICS)]
    for v in ["full", "geo", "color"]:
        if v in by:
            lines.append(f"| {v} | " + " | ".join(cell([1 - r[m] for r in by[v]]) for m in METRICS) + " |")

    if any(v.startswith("solo_") for v in by):
        lines += ["", "## Per effect", "",
                  "solo = damage of the effect alone. marginal = loss(full) - loss(full without it): "
                  "how much of the damage goes away when only this effect is removed.", "",
                  "| effect | solo hog loss | solo ssim loss | solo coarse loss | solo edge loss | marginal hog | marginal ssim | marginal coarse |",
                  "|---|---|---|---|---|---|---|---|"]
        table = []
        for e in EFFECTS:
            solo = by.get("solo_" + e, [])
            ko = by.get("ko_" + e, [])
            marg = {m: [(1 - full[(r["fixture"], r["time"])][m]) - (1 - r[m]) for r in ko] for m in METRICS}
            table.append((np.mean([1 - r["hog"] for r in solo]), e, solo, marg))
        for _, e, solo, marg in sorted(table, reverse=True):
            lines.append(f"| {e} | " + " | ".join(cell([1 - r[m] for r in solo]) for m in ["hog", "ssim", "coarse", "edge"])
                         + " | " + " | ".join(f"{np.mean(marg[m]):+.3f} [{np.max(marg[m]):+.3f}]" for m in ["hog", "ssim", "coarse"]) + " |")

        lines += ["", "## Over time (mean over fixtures)", "",
                  "| t (s) | turb amp | logSphere | noise | hueBlend | KB scale | full hog loss | solo turbulence | solo logsphere | solo noise | solo huewaves | solo feedback |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for t in sorted({k[1] for k in full}):
            fr = [r for r in by["full"] if r["time"] == t]
            u = fr[0]
            def sl(e):
                return np.mean([1 - r["hog"] for r in by["solo_" + e] if r["time"] == t])
            lines.append(f"| {t} | {u['u_distortionAmplitude']:.4f} | {u['u_logSphereAmount']:.4f} | {u['u_fractalNoiseAmount']:.4f} "
                         f"| {u['u_hueBlendAmount']:.2f} | {u['u_kenBurnsScale']:.2f} | {np.mean([1 - r['hog'] for r in fr]):.3f} "
                         f"| {sl('turbulence'):.3f} | {sl('logsphere'):.3f} | {sl('noise'):.3f} | {sl('huewaves'):.3f} | {sl('feedback'):.3f} |")

    # Which uniform explains the frame-to-frame variation of the full-pipeline loss?
    fr = by["full"]
    if len({r["time"] for r in fr}) >= 6:
        lines += ["", "## What drives the peaks (correlation of full-pipeline loss with each uniform, all frames)", "",
                  "| uniform | r with hog loss | r with ssim loss | r with coarse loss |", "|---|---|---|---|"]
        for k in ["u_distortionAmplitude", "u_logSphereAmount", "u_fractalNoiseAmount", "u_hueBlendAmount",
                  "u_fractalHueAmount", "u_chromaticAmount", "u_kenBurnsScale", "u_vibranceAmount"]:
            x = np.array([r[k] for r in fr])
            cs = [np.corrcoef(x, np.array([1 - r[m] for r in fr]))[0, 1] for m in ["hog", "ssim", "coarse"]]
            lines.append(f"| {k[2:]} | " + " | ".join(f"{c:+.2f}" for c in cs) + " |")

    lines += ["", "## Per fixture (full pipeline)", "", "| fixture | hog loss | ssim loss | coarse loss |", "|---|---|---|---|"]
    for fx in sorted({k[0] for k in full}):
        fr2 = [r for r in by["full"] if r["fixture"] == fx]
        lines.append(f"| {fx} | " + " | ".join(cell([1 - r[m] for r in fr2]) for m in ["hog", "ssim", "coarse"]) + " |")

    text = "\n".join(lines) + "\n"
    with open(os.path.join(a.out, "summary.md"), "w") as f:
        f.write(text)
    print(text)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ["render", "sweep"]:
        s = sub.add_parser(name)
        s.add_argument("--out", required=True)
        s.add_argument("--fixtures", default="r2-04.jpg,r2-08.jpg,r2-11.jpg,r2-03.jpg,r2-05.jpg,f-02.jpg")
        s.add_argument("--times", default=DEFAULT_TIMES)
        s.add_argument("--tp", type=float, default=0, help="transitionProgress for every frame (render only)")
    s = sub.add_parser("analyze")
    s.add_argument("--out", required=True)
    s = sub.add_parser("score")
    s.add_argument("ref")
    s.add_argument("frame")
    a = p.parse_args()
    if a.cmd == "render":
        cmd_render(a)
    elif a.cmd == "sweep":
        cmd_sweep(a)
    elif a.cmd == "analyze":
        cmd_analyze(a)
    else:
        print(json.dumps(score(a.ref, a.frame), indent=1))


if __name__ == "__main__":
    main()
