#!/bin/zsh
# shader-bench.sh — build (cached) and run scripts/shader-bench.swift.
#
# Usage
#   scripts/shader-bench.sh [shader-bench options]          # benchmark, JSON on stdout
#   scripts/shader-bench.sh --out DIR                        # also write per-scenario PNGs
#   scripts/shader-bench.sh --compare DIR_A DIR_B            # pixel diff of two --out dirs
# See the header of scripts/shader-bench.swift for all options.
#
# Env: SCRATCH (where the binary is cached; default: $TMPDIR/liminal-shader-bench).
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SRC="$SCRIPT_DIR/shader-bench.swift"
BIN_DIR="${SCRATCH:-${TMPDIR:-/tmp}/liminal-shader-bench}"
BIN="$BIN_DIR/shader-bench"
mkdir -p "$BIN_DIR"

if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  echo "building $BIN ..." >&2
  swiftc -O "$SRC" -o "$BIN" >&2
fi

exec "$BIN" "$@"
