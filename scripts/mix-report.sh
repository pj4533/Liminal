#!/bin/bash
# One command: offline Lo-Fi capture, then the full mix report.
#
#   DD=$S/dd-name scripts/mix-report.sh --out DIR [--baseline DIR] [--strict] [--no-plots] [--case NAME] \
#       [check-lofi.sh options: --private-drums --film-reel --bars 32 --seed 1042 --bpm 70 --hook k=v ...]
#
# --out, --baseline, --strict, --no-plots and --case are consumed here. Everything else goes to
# scripts/check-lofi.sh. DD selects the derived data path (default /private/tmp/liminal-overhaul-mac).
set -uo pipefail
cd "$(dirname "$0")/.."

out=""
report_args=()
capture_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        --baseline) report_args+=(--baseline "$2"); shift 2 ;;
        --case) report_args+=(--case "$2"); shift 2 ;;
        --strict|--no-plots) report_args+=("$1"); shift ;;
        *) capture_args+=("$1"); shift ;;
    esac
done
if [ -z "$out" ]; then
    echo "usage: $0 --out DIR [--baseline DIR] [--strict] [--no-plots] [check-lofi.sh options]" >&2
    exit 2
fi

capture_status=0
scripts/check-lofi.sh --out "$out" ${capture_args[@]+"${capture_args[@]}"} || capture_status=$?
if [ ! -f "$out/manifest.json" ]; then
    echo "No capture manifest in $out; see $out/xcodebuild.log" >&2
    exit "${capture_status:-1}"
fi
report_status=0
python3 scripts/mix-report.py "$out" ${report_args[@]+"${report_args[@]}"} || report_status=$?
if [ "$capture_status" -ne 0 ]; then
    echo "check-lofi.sh reported a routing or peak failure (status $capture_status); see $out/analysis.json" >&2
    exit "$capture_status"
fi
exit "$report_status"
