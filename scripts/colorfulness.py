#!/usr/bin/env python3
"""Color-loss metrics for the vibrance harness output.

    python3 scripts/colorfulness.py <out-dir>

Reads <out-dir>/<mode>/<image>/*.png written by tools/VibranceHarness, computes per-file
metrics, writes <out-dir>/metrics.csv, <out-dir>/summary.md and comparison sheets in
<out-dir>/sheets/.

Metrics (sRGB-encoded PNG bytes interpreted as sRGB, i.e. what the display shows):
  colorfulness  Hasler-Suesstrunk M (on 0-255 sRGB values)
  sat_mean/p90  HSV saturation
  chroma        mean OKLCH chroma (x100)
  lum           mean OKLab L (x100)
  contrast      std of OKLab L (x100)

Attribution:
  passthrough  vs input            pure pixel-format / colorspace loss
  full         vs input            what the viewer sees vs the source
  ko_<stage>   -> full vs ko_<stage>  marginal effect of the stage with everything else on
  solo_<stage> vs none             effect of the stage alone (same output format as none)
"""
import csv
import os
import sys
from collections import defaultdict

import numpy as np
from PIL import Image, ImageDraw

METRICS = ["colorfulness", "sat_mean", "sat_p90", "chroma", "lum", "contrast"]


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def metrics(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    rg = r - g
    yb = 0.5 * (r + g) - b
    m = np.sqrt(rg.std() ** 2 + yb.std() ** 2) + 0.3 * np.sqrt(rg.mean() ** 2 + yb.mean() ** 2)

    x = a / 255.0
    mx, mn = x.max(-1), x.min(-1)
    sat = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-6), 0.0)

    lin = srgb_to_linear(x)
    lr, lg, lb = lin[..., 0], lin[..., 1], lin[..., 2]
    l_ = np.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
    m_ = np.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
    s_ = np.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
    L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    C = np.sqrt(A ** 2 + B ** 2)
    return {
        "colorfulness": m,
        "sat_mean": sat.mean(),
        "sat_p90": np.percentile(sat, 90),
        "chroma": C.mean() * 100,
        "lum": L.mean() * 100,
        "contrast": L.std() * 100,
    }


def pct(new, old):
    return 100.0 * (new - old) / old if abs(old) > 1e-9 else 0.0


def main(out):
    rows = []
    cache = {}
    modes = [m for m in ("visionos", "macos") if os.path.isdir(os.path.join(out, m))]
    for mode in modes:
        for img in sorted(os.listdir(os.path.join(out, mode))):
            d = os.path.join(out, mode, img)
            if not os.path.isdir(d):
                continue
            for f in sorted(os.listdir(d)):
                if f.endswith(".png"):
                    v = metrics(os.path.join(d, f))
                    cache[(mode, img, f[:-4])] = v
                    rows.append({"mode": mode, "image": img, "variant": f[:-4], **{k: round(v[k], 4) for k in METRICS}})
    with open(os.path.join(out, "metrics.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["mode", "image", "variant"] + METRICS)
        w.writeheader()
        w.writerows(rows)

    # Aggregate % changes
    agg = defaultdict(lambda: defaultdict(list))  # (mode, label) -> metric -> [pct]
    for (mode, img, var), v in cache.items():
        inp = cache[(mode, img, "input")]
        if var == "passthrough":
            for k in METRICS:
                agg[(mode, "passthrough vs input")][k].append(pct(v[k], inp[k]))
            continue
        if "_" not in var:
            continue
        tag, kind = var.split("_", 1)
        if kind == "full":
            for k in METRICS:
                agg[(mode, "FULL vs input")][k].append(pct(v[k], inp[k]))
        elif kind == "none":
            for k in METRICS:
                agg[(mode, "all-off vs input")][k].append(pct(v[k], inp[k]))
        elif kind.startswith("ko_"):
            full = cache[(mode, img, f"{tag}_full")]
            for k in METRICS:
                agg[(mode, f"ko:{kind[3:]}")][k].append(pct(full[k], v[k]))
        elif kind.startswith("solo_"):
            none = cache[(mode, img, f"{tag}_none")]
            for k in METRICS:
                agg[(mode, f"solo:{kind[5:]}")][k].append(pct(v[k], none[k]))

    lines = ["# Vibrance harness summary", "",
             "Mean % change (and min..max across images x times). ",
             "`ko:X` = full vs full-with-X-neutralized (marginal effect of X). "
             "`solo:X` = only X enabled vs all-off.", ""]
    for mode in modes:
        lines += [f"## {mode}", "", "| comparison | " + " | ".join(METRICS) + " |",
                  "|---|" + "---|" * len(METRICS)]
        labels = [l for (m, l) in agg if m == mode]
        order = ["passthrough vs input", "all-off vs input", "FULL vs input"]
        labels = order + sorted(l for l in labels if l.startswith("ko:")) + sorted(l for l in labels if l.startswith("solo:"))
        for l in labels:
            if (mode, l) not in agg:
                continue
            cells = []
            for k in METRICS:
                a = np.array(agg[(mode, l)][k])
                cells.append(f"{a.mean():+.1f} ({a.min():+.0f}..{a.max():+.0f})")
            lines.append(f"| {l} | " + " | ".join(cells) + " |")
        lines.append("")
    with open(os.path.join(out, "summary.md"), "w") as fh:
        fh.write("\n".join(lines))
    print("\n".join(lines))

    make_sheets(out, modes, cache)


def make_sheets(out, modes, cache, tile=384):
    sheets = os.path.join(out, "sheets")
    os.makedirs(sheets, exist_ok=True)
    mode = "visionos" if "visionos" in modes else modes[0]
    imgs = sorted({i for (m, i, _) in cache if m == mode})
    times = sorted({int(v.split("_")[0][1:]) for (m, _, v) in cache if m == mode and v.endswith("_full")})
    pick = [times[0], times[len(times) // 2], times[-1]] if len(times) >= 3 else times
    for img in imgs:
        # Worst solo stage by colorfulness drop, averaged over times
        drops = defaultdict(list)
        for (m, i, v), val in cache.items():
            if m == mode and i == img and "_solo_" in v:
                tag, stage = v.split("_solo_")
                drops[stage].append(pct(val["colorfulness"], cache[(m, i, f"{tag}_none")]["colorfulness"]))
        worst = min(drops, key=lambda s: np.mean(drops[s])) if drops else None
        cols = [("input", f"{mode}/{img}/input.png")]
        cols += [(f"{mode} full t={t}", f"{mode}/{img}/t{t}_full.png") for t in pick]
        if "macos" in modes and mode != "macos":
            cols.append((f"macos full t={pick[1]}", f"macos/{img}/t{pick[1]}_full.png"))
        if worst:
            cols.append((f"solo {worst} t={pick[1]} ({np.mean(drops[worst]):+.0f}% M)", f"{mode}/{img}/t{pick[1]}_solo_{worst}.png"))
        sheet = Image.new("RGB", (tile * len(cols), tile + 28), "white")
        dr = ImageDraw.Draw(sheet)
        for n, (label, p) in enumerate(cols):
            fp = os.path.join(out, p)
            if not os.path.exists(fp):
                continue
            im = Image.open(fp).convert("RGB").resize((tile, tile), Image.LANCZOS)
            sheet.paste(im, (n * tile, 28))
            key = (p.split("/")[0], img, os.path.basename(p)[:-4])
            m = cache.get(key, {}).get("colorfulness", 0)
            c = cache.get(key, {}).get("chroma", 0)
            dr.text((n * tile + 6, 8), f"{label}  M={m:.0f} C={c:.1f}", fill="black")
        sheet.save(os.path.join(sheets, f"{img}.jpg"), quality=90)


if __name__ == "__main__":
    main(sys.argv[1])
