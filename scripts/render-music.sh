#!/bin/bash
# Offline-render the generative music engine to WAV and analyze it.
# Usage: scripts/render-music.sh <label> [seconds=300] [seed=1] [bypass=0]
#        scripts/render-music.sh probe          (PASS 1 node probes, checked by analyze-probes.py)
# Output: $OUT/<label>.wav, $OUT/<label>.score.json (score log) and $OUT/<label>.json (analysis)
# SOLO=<layer> env mutes every other layer (debug gain staging).
# bypass=1 renders with the master limiter bypassed (gain-staging check: must peak <= -3 dBFS).
set -euo pipefail
LABEL=${1:?label}; SECS=${2:-300}; SEED=${3:-1}; BYPASS=${4:-0}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad/music-eval}
DD=${DD:-/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad/dd-music-mac}
mkdir -p "$OUT"
# The test reads this file (xcodebuild does not forward env vars reliably).
MODE=render; [ "$LABEL" = probe ] && MODE=probe
printf 'enabled=1\nmode=%s\nlabel=%s\nseconds=%s\nseed=%s\nbypass=%s\noutdir=%s\n' "$MODE" "$LABEL" "$SECS" "$SEED" "$BYPASS" "$OUT" > /private/tmp/liminal-render-config.txt
[ -n "${SOLO:-}" ] && echo "solo=$SOLO" >> /private/tmp/liminal-render-config.txt
# ONLY=<layer> renders that layer's stem with the score unchanged (other trims zeroed, nothing forced).
# MUTE=a,b zeroes layers' trims; reverb, delay and shimmer mute those returns. Diagnosis only.
[ -n "${ONLY:-}" ] && echo "only=$ONLY" >> /private/tmp/liminal-render-config.txt
[ -n "${MUTE:-}" ] && echo "mute=$MUTE" >> /private/tmp/liminal-render-config.txt
cd "$ROOT"
# CONFIG=Release renders with optimized DSP (realistic CPU numbers); default Debug.
CONFIG=${CONFIG:-Debug}
EXTRA=(CODE_SIGNING_ALLOWED=NO); [ "$CONFIG" = Release ] && EXTRA+=(ENABLE_TESTABILITY=YES) && DD=${DD_REL:-$DD-rel}
xcodebuild test -scheme Liminal -configuration "$CONFIG" -destination 'platform=macOS' -derivedDataPath "$DD" \
  -only-testing:LiminalTests/MusicRenderTests CODE_SIGNING_ALLOWED=NO "${EXTRA[@]}" 2>&1 | grep -E "RENDERED|error: |TEST (SUCCEEDED|FAILED)|\*\* "
rm -f /private/tmp/liminal-render-config.txt
if [ "$MODE" = probe ]; then python3 "$ROOT/scripts/analyze-probes.py" "$OUT"; exit; fi
# NOANALYZE=1 skips the analysis (stem renders are analysed by their own script).
[ -n "${NOANALYZE:-}" ] && exit 0
python3 "$ROOT/scripts/analyze-audio.py" "$OUT/$LABEL.wav" --json "$OUT/$LABEL.json"
# Relaxation metrics (docs/plans/music-calm.md): written beside the analysis as <label>.calm.json.
python3 "$ROOT/scripts/analyze-calm.py" "$OUT/$LABEL.wav" --json "$OUT/$LABEL.calm.json" --quiet
