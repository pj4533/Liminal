#!/usr/bin/env python3
"""PASS/FAIL table for a render. Usage:
  check-music.py <label> [--dir DIR] [--pass N] [--bypass LABEL]
Reads DIR/<label>.json (analyze-audio.py), DIR/<label>.score.json (score log) and optionally the
analysis of a limiter-bypassed render. Criteria: scripts/music-criteria.json. Exit 1 if a gate of
pass <= N fails."""
import json, argparse, os, sys
ap = argparse.ArgumentParser()
ap.add_argument("label"); ap.add_argument("--dir", default=os.environ.get("OUT", "."))
ap.add_argument("--pass", dest="p", type=int, default=1); ap.add_argument("--bypass")
a = ap.parse_args()
here = os.path.dirname(os.path.abspath(__file__))
crit = json.load(open(os.path.join(here, "music-criteria.json")))["criteria"]
A = json.load(open(os.path.join(a.dir, a.label + ".json")))
S = json.load(open(os.path.join(a.dir, a.label + ".score.json")))
B = json.load(open(os.path.join(a.dir, a.bypass + ".json"))) if a.bypass else None

# score-derived metrics
dur = A["duration_s"]
S["scene_changes_per_10min"] = (len(S["scenes"]) - 1) * 600 / dur
names = sorted({k for s in S["samples"] for k in s["levels"]})
active = {n: sum(1 for s in S["samples"] if s["levels"][n] > 0.2) for n in names}   # samples are 1/s
S["layers_active_30s"] = sum(1 for n in names if active[n] >= 30)
counts = [sum(1 for n in names if s["levels"][n] > 0.2) for s in S["samples"]]
S["max_simultaneous_layers"] = max(counts) if counts else 0
late = [c for s, c in zip(S["samples"], counts) if s["t"] >= 60]
S["min_simultaneous_layers_after60s"] = min(late) if late else 0

def get(d, path):
    if isinstance(d, dict) and path in d: return d[path]
    for k in path.split("."):
        if d is None: return None
        if isinstance(d, list): d = d[int(k)]
        else: d = d.get(k)
    return d

fails = 0
print(f"{'id':20} {'value':>10}  {'gate':16} pass  result")
for c in crit:
    src = {"a": A, "s": S, "b": B}[c["src"]]
    v = get(src, c["metric"]) if src is not None else None
    gate = f"{c.get('min', '')}..{c.get('max', '')}"
    if v is None:
        res = "n/a"
    else:
        ok = ("min" not in c or v >= c["min"]) and ("max" not in c or v <= c["max"])
        res = "PASS" if ok else "FAIL"
        if not ok and c["pass"] <= a.p: fails += 1; res += " *"
    vs = f"{v:.4g}" if isinstance(v, (int, float)) else str(v)
    print(f"{c['id']:20} {vs:>10}  {gate:16} {c['pass']:>4}  {res}")
print(f"\n{fails} gating failure(s) for pass {a.p} (marked *)")
sys.exit(1 if fails else 0)
