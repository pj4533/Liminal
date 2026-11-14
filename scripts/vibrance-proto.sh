#!/usr/bin/env bash
# Measure the vibrance fix-plan prototype (docs/plans/vibrance.md) without touching the app shader.
#
#   scripts/vibrance-proto.sh <input-dir> <out-dir> [metal -D flags...]
#
# Copies Liminal/Shaders/*.metal to <out-dir>/.src, applies tools/VibranceHarness/proto_patch.py,
# then runs the harness in macos mode (bgra8Unorm target + real feedback loop). That mode is also
# what visionOS produces once its output encoding and feedback binding are fixed.
# Flags: -DFIX_HUE=0|1 -DFIX_TAPS=0|1 -DFIX_BLOOM=0|1 -DFIX_FB=0|1 -DVIB=0.3h -DBP=0.015h
#   baseline:     -DFIX_HUE=0 -DFIX_TAPS=0 -DFIX_BLOOM=0 -DFIX_FB=0 -DVIB=0.0h -DBP=0.0h
#   recommended:  -DVIB=0.3h -DBP=0.015h
# Requires the harness binary; it is built here if missing.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <input-dir> <out-dir> [metal -D flags...]" >&2; exit 1; }
IN="$(cd "$1" && pwd)"; mkdir -p "$2"; OUT="$(cd "$2" && pwd)"; shift 2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT/.src" "$OUT/.build"
cp "$ROOT"/Liminal/Shaders/*.metal "$OUT/.src/"
python3 -I "$ROOT/tools/VibranceHarness/proto_patch.py" "$OUT/.src/EffectsRenderer.metal"
AIRS=()
for f in "$OUT"/.src/*.metal; do
  air="$OUT/.build/$(basename "$f" .metal).air"
  xcrun -sdk macosx metal -w -c "$@" "$f" -o "$air"
  AIRS+=("$air")
done
xcrun -sdk macosx metallib "${AIRS[@]}" -o "$OUT/.build/default.metallib"
if [ ! -x "$OUT/.build/vibrance-harness" ]; then
  xcrun -sdk macosx swiftc -O -o "$OUT/.build/vibrance-harness" \
    "$ROOT/tools/VibranceHarness/main.swift" "$ROOT/Liminal/EffectsUniforms.swift" \
    "$ROOT/Liminal/Visual/EffectsUniformsComputer.swift" "$ROOT/Liminal/Visual/SmoothOscillator.swift" \
    "$ROOT/Liminal/Visual/MusicModulation.swift" "$ROOT/Liminal/Visual/ImageColorStats.swift" \
    "$ROOT/Liminal/Visual/GhostTapManager.swift"
fi
"$OUT/.build/vibrance-harness" --metallib "$OUT/.build/default.metallib" --in "$IN" --out "$OUT" \
  --mode macos --size "${SIZE:-512}" --times "${TIMES:-0,37,113,260,611}" --no-solo
python3 -I "$ROOT/scripts/colorfulness.py" "$OUT"
python3 -I "$ROOT/scripts/vibrance-check.py" "$OUT" || true
