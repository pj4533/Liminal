#!/bin/zsh
# ffx-clip.sh — render a still image with moving archive footage through the real shader and the app's
# own uniform code and pre-pass kernel, and turn it into a clip, a filmstrip and objective scores.
# Built on scripts/shader-bench.sh --footage-seq and scripts/ffx-check.py (docs/plans/footage-fx.md 9).
#
# Usage
#   scripts/ffx-clip.sh --image IMG.jpg --footage CLIP.mp4 --out DIR [--look phantom|imprint|window|emerge]
#        [--footage-start 20] [--rate 0.72] [--len 8] [--start 113] [--intensity 0.5] [--level 0.5 | --mix X]
#        [--warp 0.6] [--seed 0.3] [--footage-b CLIP2.mp4 --footage-b-start S --look-b NAME --xfade AT,LEN]
#        [--set k=v,...] [--shader FILE.metal] [--prepass FILE.metal] [--fps 30] [--no-score] [--keep-frames]
#   --set pins uniforms after the app computed them: an interaction mode once its uniforms exist
#   (e.g. --set videoMode=3,videoModeAmt=0.6), or a fixed effect amount.
# Writes
#   DIR/clip.mp4                 real-time clip (768x512, left eye)
#   DIR/filmstrip.png            12 labelled frames across the clip
#   DIR/check.json               readability, footage visibility, temporal smoothness (ffx-check.py)
#   DIR/frames, DIR/off, DIR/ref frame dumps: footage on (+ stage dumps), footage off, effects off.
#                                Deleted after scoring unless --keep-frames.
# No image is generated and the app is not launched. Env: FFMPEG (default /opt/homebrew/bin/ffmpeg).
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
IMG="" CLIP="" OUT="" LOOK="window" FPS=30 SCORE=1 KEEP=0
common=() on=()
while (( $# )); do
  case "$1" in
    --image) IMG="$2"; shift 2 ;;
    --footage) CLIP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --look) LOOK="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --len) common+=(--seq-len "$2"); shift 2 ;;
    --start) common+=(--seq-start "$2"); shift 2 ;;
    --intensity) common+=(--intensity "$2"); shift 2 ;;
    --shader) common+=(--shader "$2"); shift 2 ;;
    --depth) common+=(--depth "$2"); shift 2 ;;
    --prepass) export PREPASS="$2"; shift 2 ;;
    --footage-start) on+=(--footage-start "$2"); shift 2 ;;
    --rate) on+=(--footage-rate "$2"); shift 2 ;;
    --level) on+=(--video-level "$2"); shift 2 ;;
    --mix) on+=(--video-mix "$2"); shift 2 ;;
    --warp) on+=(--video-warp "$2"); shift 2 ;;
    --seed) on+=(--video-seed "$2"); shift 2 ;;
    --footage-b) on+=(--footage-b "$2"); shift 2 ;;
    --footage-b-start) on+=(--footage-b-start "$2"); shift 2 ;;
    --look-b) on+=(--video-look-b "$2"); shift 2 ;;
    --xfade) on+=(--footage-xfade "$2"); shift 2 ;;
    --set) on+=(--set "$2"); shift 2 ;;
    --no-score) SCORE=0; shift ;;
    --keep-frames) KEEP=1; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$IMG" && -n "$CLIP" && -n "$OUT" ]] || { sed -n '2,20p' "$0" >&2; exit 2; }
mkdir -p "$OUT"

base=(--image "$IMG" --footage-seq --left-only --png-size 768x512 --seq-fps "$FPS" "${common[@]}")
"$SCRIPT_DIR/shader-bench.sh" "${base[@]}" --footage "$CLIP" --video-look "$LOOK" --footage-dump "${on[@]}" \
  --out "$OUT/frames" > /dev/null
if (( SCORE )); then
  "$SCRIPT_DIR/shader-bench.sh" "${base[@]}" --out "$OUT/off" > /dev/null
  "$SCRIPT_DIR/shader-bench.sh" "${base[@]}" --seq-ref b --out "$OUT/ref" > /dev/null
fi

"$FFMPEG" -y -loglevel error -framerate "$FPS" -i "$OUT/frames/f%04d-L.png" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart "$OUT/clip.mp4"
python3 "$SCRIPT_DIR/ffx-check.py" sheet "$OUT" "$OUT/filmstrip.png" > /dev/null
if (( SCORE )); then python3 "$SCRIPT_DIR/ffx-check.py" score "$OUT"; fi
if (( ! KEEP )); then rm -rf "$OUT/frames"/*.png "$OUT/off" "$OUT/ref"; fi
