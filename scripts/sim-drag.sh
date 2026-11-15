#!/bin/zsh
# Drag in the visionOS Simulator between two points given in SIMULATOR SCREENSHOT pixels (3840x2160).
# Needed for SwiftUI Sliders: a tap does not move them, and neither does `peekaboo drag`. This posts
# CGEvent drags with delta fields set (scripts/sim-drag.swift, compiled on first use into $TMPDIR).
# The slider moves less than the pointer (damped and not constant): +160 px moved it 11-22 points in testing; check the screenshot.
# Usage: scripts/sim-drag.sh <x0> <y0> <x1> <y1>
# Default control-window slider rows (1240x960 window, fresh launch); track x=1700..2140, 50% thumb ~1920:
#   Density y=960   Space y=1062   Echo y=1163
set -e
DIR=${0:A:h}
BIN=${TMPDIR:-/tmp}/liminal-sim-drag
if [[ ! -x $BIN || $DIR/sim-drag.swift -nt $BIN ]]; then swiftc -O $DIR/sim-drag.swift -o $BIN; fi
X0=$1; Y0=$2; X1=$3; Y1=$4
B=$(peekaboo list windows --app Simulator --json | python3 -I -c '
import json,sys
w=[w for w in json.load(sys.stdin)["data"]["windows"] if w.get("isMainWindow")][0]["bounds"]
print(w[0][0],w[0][1],w[1][0],w[1][1])')
read WX WY WW WH <<< "$B"
CH=$(( WW * 9 / 16 )); TOP=$(( WY + WH - CH ))
FX=$(( WX + X0 * WW / 3840 )); FY=$(( TOP + Y0 * CH / 2160 ))
TX=$(( WX + X1 * WW / 3840 )); TY=$(( TOP + Y1 * CH / 2160 ))
$BIN $FX $FY $TX $TY && echo "dragged sim ($X0,$Y0)->($X1,$Y1) -> screen ($FX,$FY)->($TX,$TY)"
