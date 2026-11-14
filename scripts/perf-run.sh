#!/bin/zsh
# perf-run.sh — repeatable visionOS-simulator performance capture for Liminal.
#
# What it does
#   1. Installs an already-built DEBUG Liminal.app into the visionOS simulator
#      (build first with: xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,id=<udid>'
#       -derivedDataPath <dd> build).
#   2. Terminates any running instance, then launches it with the DEBUG-only launch args
#        -LiminalAutoPlay YES -LiminalOpenDome YES -LiminalPerfLogInterval 1 [-LiminalFreezeTime <t>]
#      (these are compiled out of Release; see Liminal/Utils/DebugLaunchOptions.swift).
#   3. Streams the app's unified log (subsystem com.saygoodnight.Liminal) to <out>/log.txt.
#   4. Waits for the dome render loop's first "📊 visionOS PERF" line. If the auto-open flag did not
#      open the dome within ~25s it falls back to scripts/sim-tap.sh (Play, then Enter Dome).
#   5. Warms up (default 15s), collects --seconds of PERF lines, takes a screenshot, and prints a
#      JSON summary (also written to <out>/summary.json).
#
# Usage
#   scripts/perf-run.sh [--label NAME] [--seconds N] [--warmup N] [--freeze T] [--split]
#                       [--udid UDID] [--app PATH | --dd DERIVED_DATA_DIR] [--out DIR]
#     --label    output folder name under $PERF_ROOT (default: run-<timestamp>)
#     --seconds  collection window in seconds after warm-up (default 30)
#     --warmup   seconds to ignore after the first PERF line (default 15)
#     --freeze   pin effect time to T seconds (deterministic screenshots)
#     --split    also pass -LiminalPerfSplitPasses YES (no-op since direct-drawable render)
#     --app      path to Liminal.app (default: <dd>/Build/Products/Debug-xrsimulator/Liminal.app)
#     --dd       derived-data dir holding the build (default: $SCRATCH/dd-perf)
#   Env: PERF_ROOT (default $SCRATCH/perf), SCRATCH (default: this session's scratchpad dir).
#
# Output (<PERF_ROOT>/<label>/): log.txt (full stream), perf.txt (PERF lines in the window),
#   screenshot.png (3840x2160), summary.json.
#
# Summary fields: fps_mean (mean of per-second fps), frame_interval_p95_ms (median of per-second
#   p95s), gpu_ms_mean (frame-weighted mean), gpu_ms_p95 (median of per-second p95s),
#   gpu_ms_max, dropped_per_5s (dropped = render-loop interval >15ms, per 5 s), per_pass (avg ms).
#   Simulator numbers run on the host Mac GPU: use them only for before/after comparisons.
#
# Requirements: booted "Apple Vision Pro" simulator, Simulator.app window visible (for the tap
#   fallback, which uses Peekaboo), python3.

set -u
SCRIPT_DIR=${0:A:h}
SCRATCH=${SCRATCH:-/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad}
PERF_ROOT=${PERF_ROOT:-$SCRATCH/perf}
UDID=19A53057-4A6A-47EE-A627-33A845C5E7FF
BUNDLE=com.saygoodnight.Liminal
LABEL="run-$(date +%Y%m%d-%H%M%S)"
SECONDS_N=30
WARMUP=15
FREEZE=""
SPLIT=0
DD="$SCRATCH/dd-perf"
APP=""
OUT=""

while (( $# > 0 )); do
  case "$1" in
    --label) LABEL=$2; shift 2;;
    --seconds) SECONDS_N=$2; shift 2;;
    --warmup) WARMUP=$2; shift 2;;
    --freeze) FREEZE=$2; shift 2;;
    --split) SPLIT=1; shift;;
    --udid) UDID=$2; shift 2;;
    --app) APP=$2; shift 2;;
    --dd) DD=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) if [[ -d "$1" && "$1" == *.app ]]; then APP=$1; shift; else echo "unknown arg: $1" >&2; exit 2; fi;;
  esac
done

APP=${APP:-$DD/Build/Products/Debug-xrsimulator/Liminal.app}
OUT=${OUT:-$PERF_ROOT/$LABEL}
mkdir -p "$OUT"
LOG="$OUT/log.txt"; PERF="$OUT/perf.txt"; SHOT="$OUT/screenshot.png"
log() { print -r -- "[perf-run $(date +%H:%M:%S)] $*" >&2; }

[[ -d "$APP" ]] || { log "app not found: $APP"; exit 1; }

# Simulator must be booted
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  log "booting simulator $UDID"
  xcrun simctl boot "$UDID" 2>/dev/null
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
  open -a Simulator
  sleep 5
fi

log "installing $APP"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || { log "install failed"; exit 1; }

: > "$LOG"
xcrun simctl spawn "$UDID" log stream --level info --style compact \
  --predicate "subsystem == \"$BUNDLE\"" >> "$LOG" 2>&1 &
LOGPID=$!
cleanup() { kill $LOGPID 2>/dev/null; wait $LOGPID 2>/dev/null; }
trap cleanup EXIT INT TERM
sleep 2

ARGS=(-LiminalAutoPlay YES -LiminalOpenDome YES -LiminalPerfLogInterval 1)
[[ -n "$FREEZE" ]] && ARGS+=(-LiminalFreezeTime "$FREEZE")
(( SPLIT )) && ARGS+=(-LiminalPerfSplitPasses YES)
log "launching with: ${ARGS[*]}"
xcrun simctl launch "$UDID" "$BUNDLE" "${ARGS[@]}" >/dev/null || { log "launch failed"; exit 1; }

perf_count() { local c; c=$(grep -c "visionOS PERF" "$LOG" 2>/dev/null); echo ${c:-0}; }

# Wait for the dome render loop. Fallback to UI taps if auto-open did not work.
waited=0; tapped=0
while (( $(perf_count) == 0 )); do
  sleep 1; (( waited++ ))
  if (( waited == 25 && tapped == 0 )) && ! grep -q "auto-opened liminalDome" "$LOG"; then
    log "dome not open after 25s; falling back to sim-tap (Play, Enter Dome)"
    grep -q "auto-play started" "$LOG" || "$SCRIPT_DIR/sim-tap.sh" 1795 937
    sleep 2
    "$SCRIPT_DIR/sim-tap.sh" 1918 937
    tapped=1
  fi
  if (( waited >= 150 )); then
    log "no PERF lines after ${waited}s (image generation stuck?) — see $LOG"; exit 1
  fi
done
log "render loop running after ${waited}s; warming up ${WARMUP}s"
sleep "$WARMUP"
START_LINE=$(wc -l < "$LOG")
log "collecting ${SECONDS_N}s"
sleep "$SECONDS_N"
END_LINE=$(wc -l < "$LOG")
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1 || log "screenshot failed"
sed -n "$((START_LINE + 1)),${END_LINE}p" "$LOG" | grep "visionOS PERF" > "$PERF"

python3 -I - "$PERF" "$LABEL" "$SHOT" "$FREEZE" > "$OUT/summary.json" <<'PY'
import json, re, statistics, sys
path, label, shot, freeze = sys.argv[1:5]
num = r"([0-9.]+)"
rows = []
for line in open(path, encoding="utf-8", errors="replace"):
    r = {}
    for key, pat in [("fps", r"fps=" + num), ("render_avg", r"render avg=" + num),
                     ("dropped", r"dropped=(\d+)"), ("ivl_p95", r"interval p95=" + num),
                     ("gpu_avg", r"gpu avg=" + num), ("gpu_p95", r"p95=" + num + r"ms max"),
                     ("gpu_max", r"ms max=" + num + r"ms n="), ("gpu_n", r" n=(\d+)")]:
        m = re.search(pat, line)
        if m: r[key] = float(m.group(1))
    m = re.search(r"passes\[avg/max ms\]: (.*)$", line)
    if m:
        r["passes"] = {k: float(v.split("/")[0]) for k, v in re.findall(r"(\w+)=([0-9./]+)", m.group(1))}
    if "fps" in r: rows.append(r)
def col(k): return [r[k] for r in rows if k in r]
med = lambda xs: round(statistics.median(xs), 3) if xs else None
gpu_rows = [r for r in rows if r.get("gpu_n")]
wsum = sum(r["gpu_n"] for r in gpu_rows)
gpu_mean = round(sum(r["gpu_avg"] * r["gpu_n"] for r in gpu_rows) / wsum, 3) if wsum else None
passes = {}
for r in gpu_rows:
    for k, v in r.get("passes", {}).items(): passes.setdefault(k, []).append((v, r["gpu_n"]))
per_pass = {k: round(sum(v * n for v, n in xs) / sum(n for _, n in xs), 3) for k, xs in passes.items()}
dropped = col("dropped")
out = {
    "label": label, "samples": len(rows), "freeze": float(freeze) if freeze else None,
    "fps_mean": round(statistics.mean(col("fps")), 2) if rows else None,
    "frame_interval_p95_ms": med(col("ivl_p95")),
    "render_cpu_avg_ms": med(col("render_avg")),
    "gpu_ms_mean": gpu_mean, "gpu_ms_p95": med(col("gpu_p95")),
    "gpu_ms_max": max(col("gpu_max")) if col("gpu_max") else None,
    "dropped_per_5s": round(sum(dropped) / len(dropped) * 5, 2) if dropped else None,
    "per_pass_gpu_ms": per_pass, "screenshot": shot,
}
print(json.dumps(out, indent=2))
PY
cat "$OUT/summary.json"
log "done -> $OUT"
