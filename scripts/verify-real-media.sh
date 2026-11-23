#!/bin/bash
# Serial, reproducible Apple verification. Assets and outputs stay outside the checkout.
# Usage: verify-real-media.sh AFTER_CHECKOUT BASELINE_CHECKOUT OUT
set -uo pipefail
AFTER=$(cd "$1" && pwd)
BASELINE=$(cd "$2" && pwd)
OUT=$3
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CACHE="$HOME/Library/Application Support/Liminal/ArchiveFootage"
STATUS="$OUT/steps.tsv"
printf 'step\texit\n' > "$STATUS"
run_step() {
    local name=$1
    shift
    "$@" > "$OUT/$name.log" 2>&1
    local result=$?
    printf '%s\t%s\n' "$name" "$result" >> "$STATUS"
    cat "$OUT/$name.log"
    return "$result"
}
# The workflow has already compiled and tested stage 3. Stop at preparation/build failures;
# collect their diagnostics instead of launching dependent captures or unrelated full suites.
run_step prepare-media python3 "$AFTER/scripts/prepare-verification-media.py" --cache "$CACHE" --provenance "$OUT/provenance" --count 12 || exit $?
# Explicit model provisioning is a separate executable. Neither the application nor probe downloads.
run_step compile-provisioner xcrun swiftc -parse-as-library "$AFTER/scripts/provision-verification-speech.swift" -o "$OUT/provision-speech" || exit $?
run_step provision-speech python3 -c 'import subprocess,sys; subprocess.run([sys.argv[1]], check=True, timeout=600)' "$OUT/provision-speech" || exit $?
# Record missing private prerequisites explicitly; the public/bundled matrix is a distinct run.
python3 - "$AFTER" "$BASELINE" "$OUT" <<'PY'
import json, pathlib, sys
checks = []
for checkout in sys.argv[1:3]:
    root = pathlib.Path(checkout)
    drums = root / 'Liminal/SlowBurnDrums'
    grid = root / 'Liminal/Audio/Lofi/SlowBurnBeatGrid.json'
    checks.append(dict(checkout=checkout, drumDirectoryExists=drums.is_dir(),
                       drumFiles=sorted(p.name for p in drums.glob('*') if p.is_file()), beatGridExists=grid.is_file()))
pathlib.Path(sys.argv[3], 'private-prerequisites.json').write_text(json.dumps(checks, indent=2))
PY
# Copy the matrix harness; the separately documented baseline compiler adapter follows.
cp "$AFTER/scripts/mix-matrix.sh" "$BASELINE/scripts/mix-matrix.sh"
# The historical stage-1 source predates a compiler-only qualification already in after.
# Preserve the exact adapter diff rather than pretending the baseline builds unmodified.
python3 - "$BASELINE" <<'PYBASE'
from pathlib import Path
import sys
path = Path(sys.argv[1]) / 'Liminal/Audio/Lofi/LofiBassVoice.swift'
text = path.read_text()
old = '            cuePartials(note, voice: voice, envelope: envelope, rate: rate, onset: cueOnset, cue: $0, sub: sub, tone: tone)'
assert text.count(old) == 1, 'Historical baseline compiler adapter no longer matches'
path.write_text(text.replace(old, old.replace('cuePartials(', 'Self.cuePartials(', 1)))
PYBASE
git -C "$BASELINE" diff > "$OUT/baseline-verification-adapters.patch"

for label in baseline after; do
    if [ "$label" = baseline ]; then TREE=$BASELINE; else TREE=$AFTER; fi
    export DD="$OUT/dd-$label"
    cd "$TREE" || exit 2
    git rev-parse HEAD > "$OUT/$label-commit.txt"
    run_step "$label-build" xcodebuild build-for-testing CODE_SIGNING_ALLOWED=NO -scheme Liminal -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" || exit $?
    run_step "$label-probe" env BUILD=0 DD="$DD" scripts/dialogue-salience-probe.sh "$OUT/$label-probe" 8 72 || exit $?
    comparison=()
    if [ "$label" = after ]; then comparison=(--baseline "$OUT/baseline-public-matrix"); fi
    run_step "$label-public-matrix" env DD="$DD" scripts/mix-matrix.sh --out "$OUT/$label-public-matrix" --cases ref,fast,same,transcribe --bundled-drums --strict "${comparison[@]}"
    if [ -d Liminal/SlowBurnDrums ] && [ -f Liminal/Audio/Lofi/SlowBurnBeatGrid.json ]; then
        run_step "$label-private-matrix" env DD="$DD" scripts/mix-matrix.sh --out "$OUT/$label-private-matrix" --cases ref,fast,same,transcribe --strict
    fi
done
cd "$AFTER" || exit 2
run_step media-gates python3 scripts/verify-salience-gates.py "$OUT/baseline-probe/summary.json" "$OUT/after-probe/summary.json" "$OUT/salience-gates.json"
# Short listening clips are genuine rendered probe hits with their source contexts available beside them.
run_step auditions python3 scripts/verification-auditions.py "$OUT/after-probe/bugs" "$OUT/auditions"
APP="$OUT/dd-after/Build/Products/Debug/Liminal.app/Contents/MacOS/Liminal"
/usr/bin/log stream --level info --predicate 'subsystem == "com.saygoodnight.Liminal"' > "$OUT/app-200s.log" 2>&1 &
LOGGER=$!
"$APP" -LiminalAutoPlay YES -archive.enabled YES -LiminalImageAPIFresh YES -LiminalVideoOffline YES -LiminalMusicSeed 1042 -LiminalVideoSeed 1 > "$OUT/app-stdout.log" 2>&1 &
APP_PID=$!
sleep 200
if kill -0 "$APP_PID" 2>/dev/null; then
    printf 'app-survived-200s\t0\n' >> "$STATUS"
    kill "$APP_PID"
else
    printf 'app-survived-200s\t1\n' >> "$STATUS"
fi
kill "$LOGGER" 2>/dev/null || true
# Capture a window/screen where the hosted runner permits it; permissions failures stay evidence.
# The app's complete live hook log, not a build, is the runtime evidence.
python3 - "$STATUS" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
raise SystemExit(1 if any(int(r['exit']) != 0 for r in rows) else 0)
PY
