#!/usr/bin/env python3
"""PASS/FAIL table for a render. Usage:
  check-music.py <label> [--dir DIR] [--pass N] [--bypass LABEL] [--criteria FILE] [--calm FILE] [--other LABEL]
Reads DIR/<label>.json (analyze-audio.py), DIR/<label>.score.json (score log) and optionally the
analysis of a limiter-bypassed render. Criteria: scripts/music-criteria.json (the relaxation gates of
docs/plans/music-calm.md, decision D91), or --criteria FILE (music-criteria-legacy.json: the pre-calm gates). The relaxation
metrics of analyze-calm.py are read from DIR/<label>.calm.json (or --calm FILE) as calm.<metric>.
--other LABEL names a render of a different seed: the gate seeds_differ compares the two score logs.
Exit 1 if a gate of pass <= N fails."""
import json, argparse, os, sys
ap = argparse.ArgumentParser()
ap.add_argument("label"); ap.add_argument("--dir", default=os.environ.get("OUT", "."))
ap.add_argument("--pass", dest="p", type=int, default=1); ap.add_argument("--bypass")
ap.add_argument("--criteria"); ap.add_argument("--calm"); ap.add_argument("--other")
a = ap.parse_args()
here = os.path.dirname(os.path.abspath(__file__))
crit = json.load(open(a.criteria or os.path.join(here, "music-criteria.json")))["criteria"]
A = json.load(open(os.path.join(a.dir, a.label + ".json")))
calm = a.calm or os.path.join(a.dir, a.label + ".calm.json")
if "calm" not in A and os.path.exists(calm): A["calm"] = json.load(open(calm))
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

# notes (score log `onsets`: [t, layer, velocity]). "Pointed" = the struck layers; lead notes are slow swells
# and the grains are a texture, so they are counted apart.
on = S.get("onsets", [])
pointed = [o[0] for o in on if o[1] in ("keys", "drips", "pluck")]
S["pointed_notes_per_min"] = len(pointed) * 60 / dur
per_min = [sum(1 for t in pointed if m * 60 <= t < m * 60 + 60) for m in range(int(dur // 60))]
S["pointed_notes_max_minute"] = max(per_min) if per_min else 0
S["chord_changes_per_10min"] = len(S.get("chords", [])) * 600 / dur
S["key_changes_per_10min"] = max(0, len(S.get("keys", [])) - 1) * 600 / dur
S["rare_events_per_10min"] = len(S.get("rareEvents", [])) * 600 / dur
if a.other:
    O = json.load(open(os.path.join(a.dir, a.other + ".score.json")))
    sig = lambda X: ([s["kind"] for s in X["scenes"]], [round(s["start"]) for s in X["scenes"]],
                     [c["pcs"] for c in X["chords"]][:8], X.get("initialKey"))
    S["seeds_differ"] = sum(1 for x, y in zip(sig(S), sig(O)) if x != y)   # 0-4 of: scene kinds, scene times, chords, key

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
