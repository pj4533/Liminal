#!/bin/zsh
# Tap the visionOS Simulator at a point given in SIMULATOR SCREENSHOT pixels (3840x2160).
# Uses Peekaboo to click the macOS Simulator window (AXe/simctl taps don't work on visionOS).
# Usage: scripts/sim-tap.sh <x_px> <y_px>
set -e
X=$1; Y=$2
B=$(peekaboo list windows --app Simulator --json | python3 -I -c '
import json,sys
w=[w for w in json.load(sys.stdin)["data"]["windows"] if w.get("isMainWindow")][0]["bounds"]
print(w[0][0],w[0][1],w[1][0],w[1][1])')
read WX WY WW WH <<< "$B"
# Display content is 16:9 at window width; remainder above it is title/toolbar chrome.
CH=$(( WW * 9 / 16 )); TOP=$(( WY + WH - CH ))
SX=$(( WX + X * WW / 3840 )); SY=$(( TOP + Y * CH / 2160 ))
peekaboo click --coords "$SX,$SY" --app Simulator >/dev/null && echo "tapped sim ($X,$Y) -> screen ($SX,$SY)"
