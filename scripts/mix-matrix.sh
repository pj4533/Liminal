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
# Optional case (not in the default set; add it with --cases ...,transcribe):
#   transcribe --film-reel --bars 32 --seed 1042 --bpm 70 --transcribe (the ref case with on-device
#              transcription). When the installed Apple speech model is not ready the capture still runs
#              on the acoustic plan; the case is then skipped with the model status logged and written to
#              DIR/transcribe/skipped.txt, and it is left out of the summary and of --strict.
# Output: DIR/<case>/ (capture, report/), DIR/matrix-summary.md (counts, criteria-by-case grid, failing
# fail-level criteria per case, baseline deltas) and matrix-summary.json.
# Exit status: nonzero when a case produced no capture; under --strict also when any case has a strict failure.
# --prune-wavs deletes the WAVs of long, fast and nofilm after their reports. --baseline DIR compares
# each case with DIR/<case>/report. A case directory that already holds a capture is reported on again
# without capturing; one with a report and pruned WAVs is kept as it is; one without a manifest (a
# capture that failed part way) is cleared and captured again. check-lofi.sh itself captures again
# when a tap drops a block under machine load (`skippedTapFrames`, see --capture-attempts). Extra check-lofi.sh options can follow a literal "--".
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
        transcribe) echo "--film-reel --bars 32 --seed 1042 --bpm 70 --transcribe" ;;
        *) return 1 ;;
    esac
}

# The transcribe case counts only when the capture actually transcribed: manifest.dialogueTranscripts
# with at least one cue whose model status is "ready". Prints the reason and returns 1 otherwise.
transcription_skip_reason() {
    python3 - "$1/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
rows = m.get("dialogueTranscripts")
if not rows:
    print("the capture wrote no dialogueTranscripts (transcription hook not applied)")
    sys.exit(0)
if any(r.get("status") == "ready" for r in rows):
    sys.exit(1)
statuses = sorted({str(r.get("status")) for r in rows})
errors = sorted({str(r.get("error")) for r in rows if r.get("error")})
print(f"on-device speech model status {', '.join(statuses)}" + (f" ({'; '.join(errors)})" if errors else "")
      + "; no download is started, so this case is skipped")
PY
}

status=0
summary_cases=()
for name in ${cases//,/ }; do
    flags=$(args_for "$name") || { echo "unknown case $name" >&2; exit 2; }
    echo "=== case $name: $flags ==="
    case_args=(--out "$out/$name" --case "$name" --private-drums $flags)
    if [ -n "$baseline" ] && [ -f "$baseline/$name/report/mix-report.json" ]; then
        case_args+=(--baseline "$baseline/$name")
    fi
    [ -n "$strict" ] && case_args+=(--strict)
    rc=0
    if [ -d "$out/$name" ] && [ ! -f "$out/$name/manifest.json" ]; then
        # A capture that stopped before its manifest leaves partial WAVs; they are never analysed.
        echo "$out/$name has no manifest (an earlier capture failed); clearing it and capturing again"
        rm -rf "$out/$name"
    fi
    if [ -f "$out/$name/report/mix-report.json" ] && [ ! -f "$out/$name/master.wav" ]; then
        echo "$out/$name has a report and pruned WAVs; keeping the report (delete the directory to recapture)"
    elif [ -f "$out/$name/manifest.json" ]; then
        echo "$out/$name holds a capture; skipping capture and reporting on it (delete it to recapture)"
        python3 scripts/mix-report.py "$out/$name" --case "$name" ${baseline:+--baseline "$baseline/$name"} $strict || rc=$?
    else
        scripts/mix-report.sh "${case_args[@]}" ${extra[@]+"${extra[@]}"} || rc=$?
    fi
    # Without a ready on-device model the transcribe capture is the acoustic ref case again: skip it cleanly.
    if [ "$name" = transcribe ] && [ -f "$out/$name/manifest.json" ]; then
        if reason=$(transcription_skip_reason "$out/$name"); then
            echo "case transcribe skipped: $reason" | tee "$out/$name/skipped.txt"
            continue
        fi
    fi
    # A case without a manifest always fails the run; analysis failures only gate --strict.
    if [ ! -f "$out/$name/manifest.json" ]; then
        echo "case $name produced no capture; see $out/$name/xcodebuild.log" >&2
        status=1
    elif [ -n "$strict" ] && [ "$rc" -ne 0 ]; then
        status=$rc
    fi
    summary_cases+=("$name")
    if [ -n "$prune" ]; then
        case "$name" in long|fast|nofilm)
            if [ -f "$out/$name/report/mix-report.json" ]; then rm -f "$out/$name"/*.wav; fi ;;
        esac
    fi
done

summary_status=0
summary_list=$(IFS=,; echo "${summary_cases[*]-}")
if [ -z "$summary_list" ]; then
    echo "no case produced a report" >&2
    exit 1
fi
python3 scripts/mix-report.py --matrix-summary "$out" --cases "$summary_list" ${baseline:+--baseline "$baseline"} $strict || summary_status=$?
[ "$summary_status" -ne 0 ] && status=$summary_status
exit "$status"
