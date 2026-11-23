#!/bin/bash
# Run the public-media phases serially on the Mac. Evidence stays under OUT.
# Usage: verify-real-media.sh AFTER BASELINE OUT [prepare|speech|baseline|after|gates|auditions|app|final]
set -uo pipefail
umask 077
export LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED=NO
AFTER=$(cd "$1" && pwd)
export LIMINAL_MIX_REPORT_CHECKOUT="$AFTER"
BASELINE=$(cd "$2" && pwd)
mkdir -p "$3"
OUT=$(cd "$3" && pwd)
PHASE=${4:-prepare}
CACHE="$OUT/ArchiveFootage"
export LIMINAL_VERIFICATION_ARCHIVE_DIR="$CACHE"
export TEST_RUNNER_LIMINAL_VERIFICATION_ARCHIVE_DIR="$CACHE"
export TEST_RUNNER_LIMINAL_VERIFICATION_PROVENANCE_DIR="$OUT/provenance"
STATUS="$OUT/steps.tsv"
if [ ! -f "$STATUS" ]; then printf 'step\texit\n' > "$STATUS"; fi
run_step() {
    local name=$1
    shift
    "$@" > "$OUT/$name.log" 2>&1
    local result=$?
    printf '%s\t%s\n' "$name" "$result" >> "$STATUS"
    cat "$OUT/$name.log"
    return "$result"
}
case "$PHASE" in
prepare)
    run_step prepare-media python3 "$AFTER/scripts/prepare-verification-media.py" --cache "$CACHE" --provenance "$OUT/provenance" --count 12 || exit $?
    run_step baseline-cache-check git -C "$BASELINE" apply --check "$AFTER/scripts/baseline-verification-cache.patch" || exit $?
    run_step baseline-cache-adapter git -C "$BASELINE" apply "$AFTER/scripts/baseline-verification-cache.patch" || exit $?
    run_step baseline-matrix-adapter cp "$AFTER/scripts/mix-matrix.sh" "$BASELINE/scripts/mix-matrix.sh" || exit $?
    run_step baseline-mix-shell-adapter cp "$AFTER/scripts/mix-report.sh" "$BASELINE/scripts/mix-report.sh" || exit $?
    run_step baseline-report-adapter cp "$AFTER/scripts/dialogue-salience-report.py" "$BASELINE/scripts/dialogue-salience-report.py" || exit $?
    run_step baseline-probe-adapter-check git -C "$BASELINE" apply --check "$AFTER/scripts/baseline-probe-measurement.patch" || exit $?
    run_step baseline-probe-adapter git -C "$BASELINE" apply "$AFTER/scripts/baseline-probe-measurement.patch" || exit $?
    python3 "$AFTER/scripts/prepare-baseline-compiler.py" "$BASELINE"
    adapter=$?
    printf 'baseline-compiler-adapter\t%s\n' "$adapter" >> "$STATUS"
    [ "$adapter" -eq 0 ] || exit "$adapter"
    run_step baseline-capture-adapter python3 "$AFTER/scripts/prepare-baseline-capture.py" "$BASELINE" || exit $?
    run_step baseline-public-fixture-adapter python3 "$AFTER/scripts/prepare-baseline-capture.py" --public-fixture "$BASELINE" || exit $?
    run_step baseline-event-gain-adapter python3 "$AFTER/scripts/prepare-baseline-capture.py" --event-gain "$BASELINE" || exit $?
    git -C "$BASELINE" diff > "$OUT/baseline-verification-adapters.patch" || exit $?
    ;;
speech)
    run_step compile-provisioner xcrun swiftc -parse-as-library "$AFTER/scripts/provision-verification-speech.swift" -o "$OUT/provision-speech" || exit $?
    # Test the actual native executable first. Clean failure is evidence, never a fatal Swift trap.
    run_step provision-speech python3 -c 'import subprocess,sys; sys.exit(subprocess.run([sys.argv[1]], timeout=600).returncode)' "$OUT/provision-speech"
    native=$?
    # An ad hoc signed application bundle checks whether launch/signing context affects availability.
    APP="$OUT/SpeechDiagnostic.app"
    mkdir -p "$APP/Contents/MacOS"
    cp "$OUT/provision-speech" "$APP/Contents/MacOS/SpeechDiagnostic"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.saygoodnight.Liminal.VerificationSpeech</string><key>CFBundleExecutable</key><string>SpeechDiagnostic</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
    run_step speech-signing codesign --force --sign - "$APP"
    run_step speech-bundle python3 -c 'import subprocess,sys; sys.exit(subprocess.run([sys.argv[1]], timeout=600).returncode)' "$APP/Contents/MacOS/SpeechDiagnostic"
    bundle=$?
    if [ "$native" -ne 0 ] && [ "$bundle" -ne 0 ]; then
        printf 'Apple SpeechTranscriber unavailable: T end-to-end and initialism/syllable auditions BLOCKED; acoustic evidence remains independent.\n' > "$OUT/transcript-blocked.txt"
        exit 1
    fi
    ;;
baseline|after)
    label=$PHASE
    if [ "$label" = baseline ]; then TREE=$BASELINE; else TREE=$AFTER; fi
    export DD="$OUT/dd-$label"
    cd "$TREE" || exit 2
    git rev-parse HEAD > "$OUT/$label-commit.txt"
    run_step "$label-build" xcodebuild build-for-testing CODE_SIGNING_ALLOWED=NO -scheme Liminal -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" || exit $?
    # Installed-only probe reports unavailable T honestly and still measures real acoustic playback.
    phase_status=0
    run_step "$label-probe" env BUILD=0 DD="$DD" scripts/dialogue-salience-probe.sh "$OUT/$label-probe" 8 72 || phase_status=$?
    matrix=(env DD="$DD" scripts/mix-matrix.sh --out "$OUT/$label-public-matrix" --cases ref,fast,same,transcribe --bundled-drums --strict)
    if [ "$label" = after ]; then matrix+=(--baseline "$OUT/baseline-public-matrix"); fi
    run_step "$label-public-matrix" "${matrix[@]}" || phase_status=$?
    exit "$phase_status"
    ;;
gates)
    run_step media-gates python3 "$AFTER/scripts/verify-salience-gates.py" "$OUT/baseline-probe/summary.json" "$OUT/after-probe/summary.json" "$OUT/salience-gates.json"
    ;;
auditions)
    audition=(python3 "$AFTER/scripts/verification-auditions.py" "$OUT/after-probe/bugs" "$OUT/auditions" "$OUT/after-probe/summary.json")
    if [ -f "$OUT/audition-reviews.json" ]; then audition+=(--reviews "$OUT/audition-reviews.json"); fi
    run_step auditions "${audition[@]}"
    ;;
app)
    # Playback updates the index and sweeps files outside it, including probe provenance.
    # Give this run a disposable copy so later verification sees the same corpus.
    APP_CACHE=$(mktemp -d "$OUT/app-archive.XXXXXX") || exit $?
    cp -cR "${LIMINAL_APP_SMOKE_CACHE:-$CACHE}/." "$APP_CACHE" || exit $?
    provenance=(python3 "$AFTER/scripts/verify-app-smoke-cache.py" "$APP_CACHE"
        "${LIMINAL_APP_SMOKE_DATASET:-$OUT/provenance/dataset.json}")
    if [ -n "${LIMINAL_APP_SMOKE_IDENTITY:-}" ]; then provenance+=(--identity "$LIMINAL_APP_SMOKE_IDENTITY"); fi
    run_step app-cache-provenance "${provenance[@]}" || exit $?
    export LIMINAL_VERIFICATION_ARCHIVE_DIR="$APP_CACHE"
    SEED="$OUT/after-probe/salience-index.json"
    if [ -s "$SEED" ]; then
        export LIMINAL_VERIFICATION_SALIENCE_SEED="$SEED"
        printf 'probe-learned salience snapshot\n' > "$OUT/app-index-scope.txt"
    else
        unset LIMINAL_VERIFICATION_SALIENCE_SEED
        printf 'empty salience index at launch\n' > "$OUT/app-index-scope.txt"
    fi
    APP="$OUT/dd-after/Build/Products/Debug/Liminal.app/Contents/MacOS/Liminal"
    [ -x "$APP" ] || { printf 'Build the candidate before app verification.\n' >&2; exit 2; }
    cd "$OUT" || exit $?
    /usr/bin/log stream --level info --predicate 'subsystem == "com.saygoodnight.Liminal"' > "$OUT/app-200s.log" 2>&1 &
    LOGGER=$!
    "$APP" -LiminalAutoPlay YES -audio.musicMode lofi -archive.enabled YES -LiminalDialogueTranscription installedOnly -LiminalImageAPIFresh YES -LiminalVideoOffline YES -LiminalMusicSeed 1042 -LiminalVideoSeed 1 > "$OUT/app-stdout.log" 2>&1 &
    APP_PID=$!
    cleanup_app() {
        kill "$APP_PID" "$LOGGER" 2>/dev/null || true
        wait "$APP_PID" "$LOGGER" 2>/dev/null || true
    }
    trap cleanup_app EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    sleep 200
    if kill -0 "$APP_PID" 2>/dev/null; then
        printf 'app-survived-200s\t0\n' >> "$STATUS"
    else
        printf 'app-survived-200s\t1\n' >> "$STATUS"
    fi
    cleanup_app
    trap - EXIT INT TERM
    run_step app-playback-evidence python3 "$AFTER/scripts/verify-app-playback.py" "$OUT/app-200s.log" "$OUT/app-stdout.log"

    ;;
final)
    for label in baseline after; do
        pair=-
        if [ "$label" = after ]; then pair="$OUT/baseline-public-matrix"; fi
        revision=$(cat "$OUT/$label-commit.txt" 2>/dev/null) || revision=missing
        baseline_revision=$(cat "$OUT/baseline-commit.txt" 2>/dev/null) || baseline_revision=missing
        run_step "$label-public-inventory" python3 "$AFTER/scripts/verify-matrix-integrity.py" "$OUT/$label-public-matrix" "$pair" "$revision" "$baseline_revision"
    done
    python3 - "$STATUS" "$OUT" <<'PY'
import csv, json, sys
from pathlib import Path
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
required = {'prepare-media', 'provision-speech', 'baseline-build', 'after-build', 'baseline-probe', 'after-probe', 'baseline-public-matrix', 'after-public-matrix', 'media-gates', 'auditions', 'app-cache-provenance', 'app-survived-200s', 'app-playback-evidence', 'baseline-cache-adapter', 'baseline-matrix-adapter', 'baseline-mix-shell-adapter', 'baseline-report-adapter', 'baseline-probe-adapter-check', 'baseline-probe-adapter', 'baseline-compiler-adapter', 'baseline-capture-adapter', 'baseline-public-fixture-adapter', 'baseline-event-gain-adapter', 'baseline-public-inventory', 'after-public-inventory'}
latest = {r['step']: r for r in rows}
missing = required - latest.keys()
try:
    prior = json.loads((Path(sys.argv[2]) / 'baseline-public-matrix/integrity.json').read_text())
    baseline_failure_measured = prior['complete'] and not prior['rawStrictPassed']
except (OSError, ValueError, KeyError):
    baseline_failure_measured = False
failed = [r for r in latest.values() if int(r['exit']) and not (
    r['step'] == 'baseline-public-matrix' and int(r['exit']) == 1 and baseline_failure_measured)]
earlier_failures = [r for r in rows if int(r['exit']) and r is not latest[r['step']]]
print('Missing required steps:', sorted(missing))
print('Latest failed steps:', failed)
if baseline_failure_measured:
    print('Baseline matrix completed with measured strict failures:', {
        case: row['strictFailures'] for case, row in prior['cases'].items()})
print('Earlier failed attempts retained in steps.tsv:', earlier_failures)
raise SystemExit(1 if missing or failed else 0)
PY
    ;;
*) echo "Unknown phase: $PHASE" >&2; exit 2 ;;
esac
