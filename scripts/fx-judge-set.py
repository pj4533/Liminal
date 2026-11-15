#!/usr/bin/env python3
"""Render a blind judge set: effected frames with neutral names, and a private key.

    python3 scripts/fx-judge-set.py --out JUDGE_DIR --key KEY_DIR [--mode app|proto|current]
        [--fixtures a.jpg,b.jpg,...] [--times 47,160,...] [--ages 3,8,...]
        [--intensities 0.25,0.5,1.0] [--seed 7]

JUDGE_DIR gets only frame-001.png ... (768x512, shuffled; nothing in a name or in the directory
tells the subject, the intensity or the time). KEY_DIR (keep it away from the judges) gets:
  key.json      frame -> fixture, subject (prompt text from truth.json), intensity, time, image age,
                rotation (0, or 180 for the orientation decoys: --flip-fraction of the frames are
                shown upside down so "upright" cannot be answered blindly), the uniforms used, and
                the effect-free reference frame
  refs/         the effect-free frame (Ken Burns only) for every (fixture, time, intensity)
  metrics.csv   per frame: hog / ssim / coarse / edge vs its reference (scripts/fx-structure.py)
                and the warp statistics strain_p90 / disp_p95 / fold (scripts/fx_model.py)
  summary.md    means per intensity against the thresholds of docs/plans/effects-balance.md

Modes
  app      (default) the app's own EffectsUniformsComputer with the Effect-intensity setting and the
           image age, and the working-tree shader (EffectLook via shader-bench --intensity / --image-age).
  proto    the design prototype: uniforms from fx_model.proposed(), shader = working tree plus the
           two planned edits (periphery mask on the log-spherical offset, lower skip thresholds),
           patched into a temporary copy. For validating the plan's numbers before implementation.
  current  the pipeline exactly as shipped (one level, labelled intensity "current"): the baseline.

Fixtures are relative to $FX_FIXTURES (must hold truth.json). Each frame is (time, image age):
ages are seconds since the image's crossfade began, cycled over the times.
"""
import argparse
import csv
import json
import os
import random
import shutil
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fx_model  # noqa: E402
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("fx_structure", os.path.join(HERE, "fx-structure.py"))
fx_structure = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fx_structure)

DEFAULT_FIXTURES = "r2-04.jpg,r2-08.jpg,r2-11.jpg,r2-03.jpg,r2-05.jpg,f-02.jpg"
# Ten times that sample the clarity cycle at the default intensity as it is distributed over a long
# session (drive 0, 1, .5, .05, 0, .67, .84, 1, .18, 0: 40 % clear, 30 % wild), and image ages that
# sample a 30 s image interval (1 of 10 still held clear, 2 ramping, 7 settled).
DEFAULT_TIMES = "20,100,190,255,330,425,540,600,675,760"
DEFAULT_AGES = "20,25,9,14,3,28,12,7,17,22"
REF_OFF = fx_structure.off(fx_structure.EFFECTS)

# Thresholds (docs/plans/effects-balance.md section 8.2), per intensity label.
THRESHOLDS = {
    "0.25": {"hog_loss_mean": 0.07, "strain_p90_max": 0.60, "fold_max": 0.002},
    "0.5": {"hog_loss_mean": 0.10, "strain_p90_max": 1.00, "fold_max": 0.005},
    "1.0": {"hog_loss_mean": 0.14, "strain_p90_max": 1.60, "fold_max": 0.030},
}


def patched_shader(key_dir):
    """Working-tree shader plus the plan's two shader edits (plan section 6)."""
    src = open(os.path.join(os.path.dirname(HERE), "Liminal", "Shaders", "EffectsRenderer.metal")).read()
    edits = [
        ("    float displacement = ef * intensity;\n",
         "    float displacement = ef * intensity * smoothstep(%.2f, %.2f, R);\n" % fx_model.LOG_MASK),
        ("if (uniforms.logSphereAmount > 0.001)", "if (uniforms.logSphereAmount > 0.00002)"),
        ("if (uniforms.fractalNoiseAmount > 0.001)", "if (uniforms.fractalNoiseAmount > 0.00002)"),
    ]
    for old, new in edits:
        if old not in src:
            if new in src:
                continue  # already implemented in the working tree
            sys.exit("proto: shader text to patch not found: " + old.strip())
        src = src.replace(old, new)
    path = os.path.join(key_dir, "proto-shader.metal")
    with open(path, "w") as f:
        f.write(src)
    return path


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--mode", choices=["app", "proto", "current"], default="app")
    p.add_argument("--fixtures", default=DEFAULT_FIXTURES)
    p.add_argument("--times", default=DEFAULT_TIMES)
    p.add_argument("--ages", default=DEFAULT_AGES)
    p.add_argument("--intensities", default="0.25,0.5,1.0")
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--flip-fraction", type=float, default=0.25,
                   help="fraction of frames shown rotated 180 degrees (orientation decoys; recorded in the key)")
    a = p.parse_args()

    out, key = os.path.abspath(a.out), os.path.abspath(a.key)
    if os.path.commonpath([out, key]) == out:
        sys.exit("--key must not be inside --out (the judges read --out)")
    for d in (out, key):
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
    os.makedirs(os.path.join(key, "refs"))
    fixdir = fx_structure.DEFAULT_FIXTURES
    truth = {}
    tpath = os.path.join(fixdir, "truth.json")
    if os.path.isfile(tpath):
        truth = {e["file"]: e for e in json.load(open(tpath))}
    times = [float(t) for t in a.times.split(",")]
    ages = [float(x) for x in a.ages.split(",")]
    levels = ["current"] if a.mode == "current" else a.intensities.split(",")
    shader = ["--shader", patched_shader(key)] if a.mode == "proto" else []

    entries = []
    for fixture in a.fixtures.split(","):
        img = fixture if os.path.isabs(fixture) else os.path.join(fixdir, fixture)
        stem = os.path.splitext(os.path.basename(img))[0]
        work = os.path.join(key, "work", stem)
        os.makedirs(work)
        scenarios = []
        for li, level in enumerate(levels):
            for ti, t in enumerate(times):
                age = ages[ti % len(ages)]
                name = f"L{li}_T{ti}"
                base = {"time": t}
                over = {"stereoOffset": 0}
                if a.mode == "app":
                    base.update({"intensity": float(level), "age": age})
                elif a.mode == "proto":
                    u = fx_model.proposed(t, float(level), age)
                    over.update({k: v for k, v in u.items() if not k.startswith("_") and k != "time"})
                ref_over = dict(over)
                ref_over.update(REF_OFF)
                scenarios.append({"name": name, **base, "set": over})
                scenarios.append({"name": name + "_ref", **base, "set": ref_over})
                entries.append({"fixture": os.path.basename(img), "stem": stem, "name": name, "intensity": level,
                                "time": t, "age": None if a.mode == "current" else age, "mode": a.mode,
                                "subject": truth.get(os.path.basename(img), {}).get("prompt", "")})
        sc_path = os.path.join(work, "scenarios.json")
        json.dump(scenarios, open(sc_path, "w"))
        cmd = [os.path.join(HERE, "shader-bench.sh"), *shader, "--image", img, "--scenarios", sc_path,
               "--render-only", "--left-only", "--png-size", "768x512", "--out", work,
               "--json", os.path.join(work, "uniforms.json")]
        print(f"{stem}: {len(scenarios)} frames", file=sys.stderr)
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            sys.exit(r.stderr[-2000:])

    rng = random.Random(a.seed)
    rng.shuffle(entries)
    flipped = set(rng.sample(range(len(entries)), round(len(entries) * a.flip_fraction)))
    rows = []
    for n, e in enumerate(entries, 1):
        work = os.path.join(key, "work", e["stem"])
        uni = json.load(open(os.path.join(work, "uniforms.json")))["uniforms"][e["name"]]
        frame = f"frame-{n:03d}.png"
        ref = f"refs/{e['stem']}-{e['name']}.png"
        shutil.copyfile(os.path.join(work, e["name"] + "-L.png"), os.path.join(out, frame))
        shutil.copyfile(os.path.join(work, e["name"] + "_ref-L.png"), os.path.join(key, ref))
        s = fx_structure.score(os.path.join(key, ref), os.path.join(out, frame))
        mu = dict(uni)
        if a.mode != "current":
            mu["_drive"] = 1  # the model applies the planned shader edits (mask, thresholds)
        w = fx_model.warp_stats(mu)
        rotation = 180 if (n - 1) in flipped else 0
        if rotation:  # after scoring: the metrics are for the upright frame
            from PIL import Image
            Image.open(os.path.join(out, frame)).rotate(180).save(os.path.join(out, frame))
        e.update({"frame": frame, "ref": ref, "rotation": rotation, "uniforms": uni})
        rows.append({"frame": frame, "fixture": e["fixture"], "intensity": e["intensity"], "time": e["time"],
                     "age": e["age"], **{k + "_loss": round(1 - v, 4) for k, v in s.items()},
                     "strain_p90": round(w["strain_p90"], 4), "disp_p95": round(w["disp_p95"], 4),
                     "fold": round(w["fold"], 4)})
        del e["stem"], e["name"]
    shutil.rmtree(os.path.join(key, "work"))
    json.dump(entries, open(os.path.join(key, "key.json"), "w"), indent=1)
    with open(os.path.join(key, "metrics.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0]))
        wr.writeheader()
        wr.writerows(rows)

    lines = [f"# Judge set ({a.mode}): {len(rows)} frames", "",
             "| intensity | frames | hog loss mean | hog loss max | ssim loss mean | strain_p90 mean | strain_p90 max | disp_p95 max | fold max | objective gate |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for level in levels:
        rs = [r for r in rows if r["intensity"] == level]
        g = lambda k: np.array([r[k] for r in rs])
        th = THRESHOLDS.get(str(float(level)) if level != "current" else "", None)
        gate = "-"
        if th:
            ok = (g("hog_loss").mean() <= th["hog_loss_mean"] and g("strain_p90").max() <= th["strain_p90_max"]
                  and g("fold").max() <= th["fold_max"])
            gate = "PASS" if ok else "FAIL"
        lines.append(f"| {level} | {len(rs)} | {g('hog_loss').mean():.3f} | {g('hog_loss').max():.3f} | {g('ssim_loss').mean():.3f} "
                     f"| {g('strain_p90').mean():.2f} | {g('strain_p90').max():.2f} | {g('disp_p95').max():.3f} | {g('fold').max():.4f} | {gate} |")
    text = "\n".join(lines) + "\n"
    open(os.path.join(key, "summary.md"), "w").write(text)
    print(text)
    print(f"judge frames: {out}\nprivate key:  {key}/key.json")


if __name__ == "__main__":
    main()
