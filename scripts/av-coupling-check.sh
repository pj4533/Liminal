#!/bin/bash
# Offline audio-visual coupling check (docs/plans/av-coupling.md section 5).
# Drives the real music conductor offline (no audio rendered) and runs MusicReactor + EffectsUniformsComputer
# at simulated 90 fps; asserts caps, slew limits, no-strobe band, coupling, clean toggle-off and the
# music-side response to synthetic moods. Also runs the fast always-on AVCouplingTests.
# Usage: scripts/av-coupling-check.sh [seconds=600] [seed=3]
# Output: $OUT/coupling.csv (every 3rd frame) and $OUT/summary.txt
set -euo pipefail
SECS=${1:-600}; SEED=${2:-3}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${SCRATCH:-/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad}
OUT=${OUT:-$SCRATCH/finish/av-coupling}
DD=${DD:-$SCRATCH/dd-finish-test}
mkdir -p "$OUT"
# The test reads this file (xcodebuild does not forward env vars reliably).
printf 'enabled=1\nseconds=%s\nseed=%s\noutdir=%s\n' "$SECS" "$SEED" "$OUT" > /private/tmp/liminal-avcoupling-config.txt
cd "$ROOT"
xcodebuild test -scheme Liminal -destination 'platform=macOS' -derivedDataPath "$DD" \
  -only-testing:LiminalTests/AVCouplingTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "AVCOUPLING|error: |Test .*(passed|failed)|TEST (SUCCEEDED|FAILED)|\*\* " || true
rm -f /private/tmp/liminal-avcoupling-config.txt
echo "CSV: $OUT/coupling.csv"
