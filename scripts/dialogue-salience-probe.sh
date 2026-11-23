#!/bin/zsh
# Salience / partial-word probe of the dialogue chop path on the cached archive films
# (LiminalTests/DialogueSalienceProbeTests; report by scripts/dialogue-salience-report.py).
#
# usage: scripts/dialogue-salience-probe.sh <out-dir> [chunks=8] [bpm=72]
# env:   DD (derived data, default /private/tmp/liminal-salience-dd), FOCUS (comma list of words that
#        always get a snippet), BUILD=0 to skip build-for-testing.
#        PROBE_FILM (film ID filter), PROBE_CHUNK (zero-based diagnostic window).
#
# Transcribes with the installed on-device model only (never downloads), never calls Gemini and never
# touches the network. Run one capture or test at a time on a machine. Output: <out-dir>/probe.log,
# summary.json and bugs/ (WAV snippets of suspect hits and index.tsv).
set -euo pipefail
OUT=${1:?out dir}
CHUNKS=${2:-8}
BPM=${3:-72}
DD=${DD:-/private/tmp/liminal-salience-dd}
FOCUS=${FOCUS:-lsd,ufo,dmt,psilocyb,peyote,mescal,marijuana,drug,trip,halluc,psychedel,machine,computer,brain}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"
CONFIG=/private/tmp/liminal-salience-probe-$(id -u).json
python3 - "$CONFIG" "$ROOT" "$CHUNKS" "$BPM" "$FOCUS" "$OUT/bugs" <<'PY'
import json, os, sys
path, root, chunks, bpm, focus, bugs = sys.argv[1:]
selection = {}
if film := os.getenv("PROBE_FILM"):
    selection["only"] = [film]
if value := os.getenv("PROBE_CHUNK"):
    chunk = int(value)
    if not 0 <= chunk < int(chunks):
        raise SystemExit("PROBE_CHUNK must be a zero-based index in the chosen window grid")
    selection["onlyChunk"] = chunk
json.dump({**selection, "checkout": root, "chunks": int(chunks), "bpm": float(bpm), "seed": 1, "maxSnippets": 700,
           "snippetDirectory": bugs, "focus": [f for f in focus.split(",") if f]}, open(path, "w"))
PY
trap 'rm -f "$CONFIG"' EXIT
cd "$ROOT"
if [[ ${BUILD:-1} != 0 ]]; then
  xcodebuild build-for-testing -scheme Liminal -destination 'platform=macOS' -derivedDataPath "$DD" > "$OUT/build.log" 2>&1
fi
python3 - "$OUT/render-identity.json" <<'PY_IDENTITY'
import hashlib, json, subprocess, sys
from pathlib import Path
def git(*args):
    return subprocess.check_output(['git', *args])
Path(sys.argv[1]).write_text(json.dumps(dict(revision=git('rev-parse', 'HEAD').decode().strip(),
    trackedDiffSHA256=hashlib.sha256(git('diff', '--binary', 'HEAD')).hexdigest()), indent=2))
PY_IDENTITY
xcodebuild test-without-building -scheme Liminal -destination 'platform=macOS' -derivedDataPath "$DD" \
  -parallel-testing-enabled NO -only-testing:LiminalTests/DialogueSalienceProbeTests > "$OUT/probe.log" 2>&1
python3 scripts/dialogue-salience-report.py "$OUT/probe.log" "$OUT"
