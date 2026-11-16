#!/bin/zsh
# archive-fetch-fixture.sh — download one known public-domain Prelinger clip for offline, deterministic
# footage tests (docs/plans/archive-video.md 7). One metadata request plus one download, cached: a second
# run makes no request. No video binary goes in the repository.
#
#   scripts/archive-fetch-fixture.sh [OUT_DIR] [IDENTIFIER]
#     OUT_DIR     default $SCRATCH or $TMPDIR/liminal-archive-fixture
#     IDENTIFIER  default NewsMaga1957 ("News Magazine of the Screen, The (1957)", Prelinger, public domain)
# Prints the path of the mp4. Use it with the app's -LiminalVideoFile <mp4>.
set -euo pipefail
OUT="${1:-${SCRATCH:-${TMPDIR:-/tmp}/liminal-archive-fixture}}"
ID="${2:-NewsMaga1957}"
UA="Liminal/1.0"
mkdir -p "$OUT"
DEST="$OUT/$ID.mp4"
if [[ -s "$DEST" ]]; then echo "$DEST"; exit 0; fi
META="$OUT/$ID.metadata.json"
[[ -s "$META" ]] || curl -fsSL -A "$UA" "https://archive.org/metadata/$ID" -o "$META"
# The smallest h.264 / 512Kb MPEG4 mp4 (not an _edit master).
FILE=$(python3 -I - "$META" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
ok = [f for f in m.get("files", []) if f["name"].lower().endswith(".mp4") and not f["name"].lower().endswith("_edit.mp4")
      and (f.get("format") or "").lower() in ("h.264", "h.264 ia", "512kb mpeg4", "mpeg4")]
ok.sort(key=lambda f: int(f.get("size") or 0))
print(ok[0]["name"] if ok else "")
EOF
)
[[ -n "$FILE" ]] || { echo "no playable mp4 in $ID" >&2; exit 1; }
sleep 2
curl -fsSL -A "$UA" "https://archive.org/download/$ID/${FILE// /%20}" -o "$DEST.part"
mv "$DEST.part" "$DEST"
echo "$DEST"
