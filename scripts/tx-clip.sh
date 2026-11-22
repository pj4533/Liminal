#!/bin/zsh
# tx-clip.sh — render one image transition (image A -> image B) with the real shader and the app's
# own uniform code, and turn it into a clip, a GIF, a filmstrip and objective scores.
# Built on scripts/shader-bench.sh --sequence and scripts/tx-check.py (docs/plans/transitions.md 8).
#
# Usage
#   scripts/tx-clip.sh --a A.jpg --b B.jpg --out DIR [--style classic|tide|facets|...] [--seed 0] [--intensity 0.5]
#                      [--start 113] [--duration S (default: 1.5 classic, else the style's mid range)] [--pre 1] [--post 3] [--fps 30] [--shader FILE.metal]
#                      [--depth B-depth.png] [--no-score] [--no-clip]
#                      [--drop --fill S [--hits a,b,..] [--tx-colour NAME] [--tx-finisher NAME] [--tx-strength X]]
#   --drop renders a drop (docs/plans/drop-transitions.md): A breaks up over the fill, B is cut in at the
#   downbeat; scored with tx-check.py score --drop (use --fps 60 so the cut frame is exact).
# Writes
#   DIR/frames/f0000-L.png ... + sequence.json   the transition (left eye, 768x512, 30 fps)
#   DIR/ref-a/, DIR/ref-b/                       image A / image B alone, effects off, same timeline
#   DIR/clip.mp4, DIR/clip.gif                   real-time clips (ffmpeg)
#   DIR/filmstrip.png                            18 labelled frames from -0.3 s to 1 s after the end
#   DIR/plot.png, DIR/metrics.csv, DIR/check.json   visibility of A and B, frame steps, gates
# Runs offline from the given pictures: it fetches nothing and does not launch the app. Env: FFMPEG (default /opt/homebrew/bin/ffmpeg).
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
A="" B="" OUT="" STYLE="classic" SEED=0 FPS=30 SCORE=1 CLIP=1 DROP=0
pass=()
while (( $# )); do
  case "$1" in
    --a) A="$2"; shift 2 ;;
    --b) B="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --style) STYLE="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --intensity) pass+=(--intensity "$2"); shift 2 ;;
    --start) pass+=(--seq-start "$2"); shift 2 ;;
    --duration) pass+=(--seq-duration "$2"); shift 2 ;;
    --pre) pass+=(--seq-pre "$2"); shift 2 ;;
    --post) pass+=(--seq-post "$2"); shift 2 ;;
    --shader) pass+=(--shader "$2"); shift 2 ;;
    --depth) pass+=(--depth "$2"); shift 2 ;;
    --drop) pass+=(--drop); DROP=1; shift ;;
    --fill) pass+=(--fill "$2"); shift 2 ;;
    --hits) pass+=(--hits "$2"); shift 2 ;;
    --tx-colour) pass+=(--tx-colour "$2"); shift 2 ;;
    --tx-finisher) pass+=(--tx-finisher "$2"); shift 2 ;;
    --tx-strength) pass+=(--tx-strength "$2"); shift 2 ;;
    --no-score) SCORE=0; shift ;;
    --no-clip) CLIP=0; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$A" && -n "$B" && -n "$OUT" ]] || { sed -n '2,17p' "$0" >&2; exit 2; }
mkdir -p "$OUT"

seq_args=(--sequence --prev-image "$A" --image "$B" --left-only --png-size 768x512 --seq-fps "$FPS"
          --tx-style "$STYLE" --tx-seed "$SEED" "${pass[@]}")
"$SCRIPT_DIR/shader-bench.sh" "${seq_args[@]}" --out "$OUT/frames" > /dev/null
if (( SCORE )); then
  "$SCRIPT_DIR/shader-bench.sh" "${seq_args[@]}" --seq-ref a --out "$OUT/ref-a" > /dev/null
  "$SCRIPT_DIR/shader-bench.sh" "${seq_args[@]}" --seq-ref b --out "$OUT/ref-b" > /dev/null
fi

if (( CLIP )); then
  "$FFMPEG" -y -loglevel error -framerate "$FPS" -i "$OUT/frames/f%04d-L.png" \
    -c:v libx264 -pix_fmt yuv420p -crf 16 -movflags +faststart "$OUT/clip.mp4"
  "$FFMPEG" -y -loglevel error -framerate "$FPS" -i "$OUT/frames/f%04d-L.png" \
    -vf "fps=15,scale=384:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse" "$OUT/clip.gif"
fi
python3 "$SCRIPT_DIR/tx-check.py" sheet "$OUT" "$OUT/filmstrip.png" > /dev/null
if (( SCORE )); then
  python3 "$SCRIPT_DIR/tx-check.py" plot "$OUT" "$OUT/plot.png" > /dev/null
  if (( DROP )); then python3 "$SCRIPT_DIR/tx-check.py" score --drop "$OUT"; else python3 "$SCRIPT_DIR/tx-check.py" score "$OUT"; fi
fi
