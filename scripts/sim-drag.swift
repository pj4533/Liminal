// CGEvent mouse drag for scripts/sim-drag.sh. The visionOS Simulator only moves a Slider when the
// leftMouseDragged events carry mouseEventDeltaX/Y (Peekaboo drag and plain position-only events are ignored).
// Usage: sim-drag <x0> <y0> <x1> <y1>   (macOS screen points)
import CoreGraphics
import Foundation
let a = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let (x0, y0, x1, y1) = (a[0], a[1], a[2], a[3])
let src = CGEventSource(stateID: .hidSystemState)
var last = CGPoint(x: x0, y: y0)
func post(_ t: CGEventType, _ x: Double, _ y: Double) {
    let p = CGPoint(x: x, y: y)
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
    if t != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - last.x).rounded()))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - last.y).rounded()))
    last = p
    e.post(tap: .cghidEventTap)
}
post(.mouseMoved, x0, y0); usleep(150_000)
post(.leftMouseDown, x0, y0); usleep(400_000)
let n = 60
for i in 1...n { let f = Double(i) / Double(n); post(.leftMouseDragged, x0 + (x1 - x0) * f, y0 + (y1 - y0) * f); usleep(20_000) }
usleep(300_000); post(.leftMouseUp, x1, y1)
