#!/bin/bash
# Offline-render the generative music engine to WAV and analyze it.
# Usage: scripts/render-music.sh <label> [seconds=300]
# Output: $OUT/<label>.wav and $OUT/<label>.json  (OUT defaults to the music-eval scratch dir)
set -euo pipefail
LABEL=${1:?label}; SECS=${2:-300}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad/music-eval}
DD=${DD:-/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad/dd-music-mac}
mkdir -p "$OUT"
# The test reads this file (xcodebuild does not forward env vars reliably).
printf 'enabled=1\nlabel=%s\nseconds=%s\noutdir=%s\n' "$LABEL" "$SECS" "$OUT" > /private/tmp/liminal-render-config.txt
cd "$ROOT"
xcodebuild test -scheme Liminal -destination 'platform=macOS' -derivedDataPath "$DD" \
  -only-testing:LiminalTests/MusicRenderTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "RENDERED|error: |TEST (SUCCEEDED|FAILED)|\*\* "
rm -f /private/tmp/liminal-render-config.txt
python3 "$ROOT/scripts/analyze-audio.py" "$OUT/$LABEL.wav" --json "$OUT/$LABEL.json"
