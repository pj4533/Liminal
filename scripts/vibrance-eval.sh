#!/usr/bin/env bash
# Offline vibrance evaluation for Liminal's effect pipeline.
#
#   scripts/vibrance-eval.sh <input-dir> <out-dir>
#
# Env:
#   LIMINAL_METALLIB  use this compiled metallib (e.g. Liminal.app/Contents/Resources/default.metallib)
#                     instead of compiling Liminal/Shaders/*.metal from the working tree
#   MODES             default "visionos macos"
#   SIZE              render size (default 512)
#   TIMES             default "0,37,113,260,611"
#   SOLO              set to 0 to skip solo-stage renders
#
# Produces <out-dir>/<mode>/<image>/*.png, <out-dir>/metrics.csv, <out-dir>/summary.md
# and comparison sheets in <out-dir>/sheets/.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <input-dir> <out-dir>" >&2
  exit 1
fi
IN="$(cd "$1" && pwd)"
mkdir -p "$2"
OUT="$(cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$OUT/.build"
mkdir -p "$BUILD"

MODES="${MODES:-visionos macos}"
SIZE="${SIZE:-512}"
TIMES="${TIMES:-0,37,113,260,611}"
SOLO_FLAG=""
[ "${SOLO:-1}" = "0" ] && SOLO_FLAG="--no-solo"

# 1. Metal library
if [ -n "${LIMINAL_METALLIB:-}" ]; then
  METALLIB="$LIMINAL_METALLIB"
else
  echo "==> Compiling shaders from $ROOT/Liminal/Shaders"
  AIRS=()
  for f in "$ROOT"/Liminal/Shaders/*.metal; do
    air="$BUILD/$(basename "$f" .metal).air"
    xcrun -sdk macosx metal -c "$f" -o "$air"
    AIRS+=("$air")
  done
  METALLIB="$BUILD/default.metallib"
  xcrun -sdk macosx metallib "${AIRS[@]}" -o "$METALLIB"
fi

# 2. Harness, compiled against the app's real uniform computer + ghost tap manager
echo "==> Building harness"
xcrun -sdk macosx swiftc -O -o "$BUILD/vibrance-harness" \
  "$ROOT/tools/VibranceHarness/main.swift" \
  "$ROOT/Liminal/EffectsUniforms.swift" \
  "$ROOT/Liminal/Visual/EffectsUniformsComputer.swift" \
  "$ROOT/Liminal/Visual/SmoothOscillator.swift" \
  "$ROOT/Liminal/Visual/GhostTapManager.swift" \
  "$ROOT/Liminal/Visual/ImageFraming.swift" \
  "$ROOT/Liminal/Visual/ImageColorStats.swift"

# 3. Render
for MODE in $MODES; do
  echo "==> Rendering mode=$MODE"
  "$BUILD/vibrance-harness" --metallib "$METALLIB" --in "$IN" --out "$OUT" \
    --mode "$MODE" --size "$SIZE" --times "$TIMES" $SOLO_FLAG
done

# 4. Metrics + sheets
echo "==> Metrics"
python3 -I "$ROOT/scripts/colorfulness.py" "$OUT"
echo "==> Done: $OUT/summary.md"
