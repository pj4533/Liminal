#!/bin/bash
# Print prompts from the app's PromptBuilder without Xcode.
#   scripts/print-prompts.sh [-n 24] [-s SEED] [--jsonl] > prompts.txt
# Compiles Liminal/Visual/Prompt/*.swift + scripts/PromptDump/main.swift with swiftc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${TMPDIR:-/tmp}/liminal-promptdump"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/promptdump"
SOURCES=("$ROOT"/Liminal/Visual/Prompt/*.swift "$ROOT/scripts/PromptDump/main.swift")

needs_build=0
if [[ ! -x "$BIN" ]]; then needs_build=1; else
  for f in "${SOURCES[@]}"; do [[ "$f" -nt "$BIN" ]] && needs_build=1; done
fi
if [[ $needs_build -eq 1 ]]; then
  swiftc -O -parse-as-library -module-name PromptDump -o "$BIN" "${SOURCES[@]}" 1>&2 2>/dev/null || \
  swiftc -O -module-name PromptDump -o "$BIN" "${SOURCES[@]}" 1>&2
fi
exec "$BIN" "$@"
