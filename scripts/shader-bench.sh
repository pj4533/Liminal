#!/bin/zsh
# shader-bench.sh — deterministic Mac-GPU benchmark of the visionOS eye pass (2048², MRT stereo).
# Builds (cached) scripts/shader-bench.swift with the app's uniform/ghost-tap/framing/vibrance/depth
# sources, compiles the shader into a metallib, and runs it on the fixed fixture image + depth map.
#
# Usage
#   scripts/shader-bench.sh [--shader FILE.metal] [bench options]   # JSON summary on stdout
#   scripts/shader-bench.sh --shader-b CANDIDATE.metal [--shader REF.metal]  # interleaved A/B
#   scripts/shader-bench.sh --out DIR                                # also write parity PNGs
#   scripts/shader-bench.sh --compare DIR_A DIR_B                    # PSNR / max-abs-diff
#   scripts/shader-bench.sh --gen-depth IMAGE OUT.png                # regenerate a depth fixture
#   scripts/shader-bench.sh --image IMG --render-only --out DIR [--set k=v,...] [--scenarios F.json]
#                           [--png-size 768x512] [--left-only]       # frames only, no timing
#   (effect attribution and judge sets are built on this: scripts/fx-structure.py, scripts/fx-judge-set.sh)
# Defaults: --shader Liminal/Shaders/EffectsRenderer.metal (working tree),
#           --image tools/ShaderBench/fixtures/07.jpg, --depth tools/ShaderBench/fixtures/07-depth.png.
# See the header of scripts/shader-bench.swift for all options (--frames, --trials, --times, --mono ...).
#
# Env: SCRATCH (binary + metallib cache; default $TMPDIR/liminal-shader-bench).
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
FIX="$ROOT/tools/ShaderBench/fixtures"
SRC="$SCRIPT_DIR/shader-bench.swift"
APP_SRCS=(
  "$ROOT/Liminal/EffectsUniforms.swift"
  "$ROOT/Liminal/Visual/EffectsUniformsComputer.swift"
  "$ROOT/Liminal/Visual/EffectLook.swift"
  "$ROOT/Liminal/Visual/ImageTransition.swift"
  "$ROOT/Liminal/Visual/MusicModulation.swift"
  "$ROOT/Liminal/Visual/SmoothOscillator.swift"
  "$ROOT/Liminal/Visual/GhostTapManager.swift"
  "$ROOT/Liminal/Visual/ImageFraming.swift"
  "$ROOT/Liminal/Visual/ImageColorStats.swift"
  "$ROOT/Liminal/Visual/DepthMapGenerator.swift"
)
BIN_DIR="${SCRATCH:-${TMPDIR:-/tmp}/liminal-shader-bench}"
BIN="$BIN_DIR/shader-bench"
mkdir -p "$BIN_DIR"
export LIMINAL_REPO="$ROOT"

# 1. Binary (rebuilt when any source is newer)
rebuild=0
[[ -x "$BIN" ]] || rebuild=1
for f in "$SRC" "${APP_SRCS[@]}"; do [[ "$f" -nt "$BIN" ]] && rebuild=1; done
if (( rebuild )); then
  echo "building $BIN ..." >&2
  # Top-level code is only allowed in a file named main.swift when compiling several files.
  cp "$SRC" "$BIN_DIR/main.swift"
  xcrun -sdk macosx swiftc -O -o "$BIN" "$BIN_DIR/main.swift" "${APP_SRCS[@]}" >&2
fi

# Compare / depth-generation modes need no shader
if [[ " $* " == *" --compare "* ]]; then exec "$BIN" "$@"; fi
if [[ " $* " == *" --gen-depth "* ]]; then
  MODELC="$BIN_DIR/DepthAnythingV2SmallF16.mlmodelc"
  if [[ ! -d "$MODELC" ]]; then
    xcrun coremlcompiler compile "$ROOT/Liminal/DepthAnythingV2SmallF16.mlpackage" "$BIN_DIR" >&2
  fi
  exec "$BIN" "$@"
fi

# 2. Shader -> metallib (same compiler and fast-math as the Xcode build; cached by content hash)
SHADER="$ROOT/Liminal/Shaders/EffectsRenderer.metal"
SHADER_B=""
pass=()
while (( $# )); do
  case "$1" in
    --shader) SHADER="$2"; shift 2 ;;
    --shader-b) SHADER_B="$2"; shift 2 ;;
    *) pass+=("$1"); shift ;;
  esac
done
compile() {  # $1 = .metal -> prints the cached metallib path
  local hash lib
  hash=$(shasum -a 256 "$1" | cut -c1-16)
  lib="$BIN_DIR/eye-$hash.metallib"
  if [[ ! -f "$lib" ]]; then
    echo "compiling $1 -> $lib" >&2
    xcrun -sdk macosx metal -ffast-math -c "$1" -o "$BIN_DIR/eye-$hash.air" >&2
    xcrun -sdk macosx metallib "$BIN_DIR/eye-$hash.air" -o "$lib" >&2
  fi
  echo "$lib"
}
LIB=$(compile "$SHADER")
if [[ -n "$SHADER_B" ]]; then pass+=(--metallib-b "$(compile "$SHADER_B")"); fi

# The depth fixture belongs to the default image: another --image gets a flat depth map unless
# its own --depth is given (a mismatched map would shift parallax and fractal hue at random).
defaults=()
if [[ " ${pass[*]} " != *" --image "* ]]; then
  defaults+=(--image "$FIX/07.jpg")
  [[ " ${pass[*]} " == *" --depth "* || ! -f "$FIX/07-depth.png" ]] || defaults+=(--depth "$FIX/07-depth.png")
fi

exec "$BIN" --metallib "$LIB" "${defaults[@]}" "${pass[@]}"
