#!/bin/bash
# Run the plan section 9.1 capture matrix sequentially and summarize the criteria by case.
#
#   DD=$S/dd-name scripts/mix-matrix.sh --out DIR [--baseline DIR] [--cases ref,long,fast,same,nofilm] [--strict] [--prune-wavs]
#
# Cases (all --private-drums):
#   ref    --film-reel --bars 32 --seed 1042 --bpm 70
#   long   --film-reel --bars 64 --seed 7    --bpm 62
#   fast   --film-reel --bars 32 --seed 2025 --bpm 80
#   same   --same-film --bars 64 --seed 1042 --bpm 70
#   nofilm --no-footage --bars 16 --seed 1042 --bpm 70
# Output: DIR/<case>/ (capture, report/), DIR/matrix-summary.md and matrix-summary.json.
# --prune-wavs deletes the WAVs of long, fast and nofilm after their reports. --baseline DIR compares
# each case with DIR/<case>/report. Extra check-lofi.sh options can follow a literal "--".
set -uo pipefail
cd "$(dirname "$0")/.."

out=""
baseline=""
cases="ref,long,fast,same,nofilm"
strict=""
prune=""
extra=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        --baseline) baseline="$2"; shift 2 ;;
        --cases) cases="$2"; shift 2 ;;
        --strict) strict="--strict"; shift ;;
        --prune-wavs) prune=1; shift ;;
        --) shift; extra=("$@"); break ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
if [ -z "$out" ]; then
    echo "usage: $0 --out DIR [--baseline DIR] [--cases a,b] [--strict] [--prune-wavs]" >&2
    exit 2
fi
mkdir -p "$out"

args_for() {
    case "$1" in
        ref) echo "--film-reel --bars 32 --seed 1042 --bpm 70" ;;
        long) echo "--film-reel --bars 64 --seed 7 --bpm 62" ;;
        fast) echo "--film-reel --bars 32 --seed 2025 --bpm 80" ;;
        same) echo "--same-film --bars 64 --seed 1042 --bpm 70" ;;
        nofilm) echo "--no-footage --bars 16 --seed 1042 --bpm 70" ;;
        *) return 1 ;;
    esac
}

status=0
for name in ${cases//,/ }; do
    flags=$(args_for "$name") || { echo "unknown case $name" >&2; exit 2; }
    echo "=== case $name: $flags ==="
    case_args=(--out "$out/$name" --case "$name" --private-drums $flags)
    if [ -n "$baseline" ] && [ -f "$baseline/$name/report/mix-report.json" ]; then
        case_args+=(--baseline "$baseline/$name")
    fi
    [ -n "$strict" ] && case_args+=(--strict)
    if [ -e "$out/$name" ] && [ -n "$(ls -A "$out/$name" 2>/dev/null)" ]; then
        echo "$out/$name is not empty; skipping capture and reusing it (delete it to recapture)"
        python3 scripts/mix-report.py "$out/$name" --case "$name" ${baseline:+--baseline "$baseline/$name"} $strict || status=$?
    else
        scripts/mix-report.sh "${case_args[@]}" ${extra[@]+"${extra[@]}"} || status=$?
    fi
    if [ -n "$prune" ]; then
        case "$name" in long|fast|nofilm)
            if [ -f "$out/$name/report/mix-report.json" ]; then rm -f "$out/$name"/*.wav; fi ;;
        esac
    fi
done

python3 - "$out" "$cases" <<'PY'
import json, sys
from pathlib import Path
out, cases = Path(sys.argv[1]), sys.argv[2].split(",")
summary, ids = {}, []
for case in cases:
    path = out / case / "report" / "mix-report.json"
    if not path.is_file():
        summary[case] = None
        continue
    doc = json.loads(path.read_text())
    summary[case] = {r["id"]: {"status": r["status"], "level": r["level"], "values": r.get("values", {})} for r in doc["criteria"]}
    summary[case]["_summary"] = doc["summary"]
    for r in doc["criteria"]:
        if r["id"] not in ids:
            ids.append(r["id"])
(out / "matrix-summary.json").write_text(json.dumps(summary, indent=1) + "\n")
lines = ["# Mix matrix summary", "", "| Criterion | Level | " + " | ".join(cases) + " |", "|---|---|" + "---|" * len(cases)]
for cid in ids:
    level = next((v[cid]["level"] for v in summary.values() if v and cid in v), "")
    row = [(summary[c][cid]["status"] if summary.get(c) and cid in summary[c] else "-") for c in cases]
    lines.append(f"| {cid} | {level} | " + " | ".join(row) + " |")
lines += ["", "Strict failures: " + "; ".join(f"{c}: {', '.join(summary[c]['_summary']['strictFailures']) or 'none'}" for c in cases if summary.get(c))]
(out / "matrix-summary.md").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
PY
exit "$status"
