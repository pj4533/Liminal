//
//  TestPatternGenerator.swift
//  Liminal
//
//  DEBUG-only orientation + colour test card (-LiminalTestPattern YES).
//  3:2 like generated images. Reading it on screen:
//    - big upward arrow + "TOP" at the top; "BOTTOM" at the bottom
//    - corners: top-left RED, top-right GREEN, bottom-left BLUE, bottom-right YELLOW
//    - "L" / "R" labels near the left/right edges (mirroring check)
//    - a circle + square grid in the middle (aspect check: the circle must look round)
//    - bottom strip: left-to-right black→white ramp, 18% and 50% grey patches,
//      saturated R G B C M Y swatches
//

#if DEBUG

import CoreGraphics
import CoreText
import Foundation

enum TestPatternGenerator {

    static let width = 1536
    static let height = 1024

    /// Cached so every caller gets the same CGImage (stable identity → uploaded once).
    static let image: CGImage = make()

    private static func make() -> CGImage {
        let w = CGFloat(width), h = CGFloat(height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        // CoreGraphics user space is bottom-left origin: rect(fromTop:) converts top-left coords.
        func rect(_ x: CGFloat, _ yTop: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect {
            CGRect(x: x, y: h - yTop - rh, width: rw, height: rh)
        }
        func fill(_ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat)) {
            ctx.setFillColor(CGColor(colorSpace: cs, components: [c.0, c.1, c.2, 1])!)
            ctx.fill(r)
        }
        func text(_ s: String, size: CGFloat, centerX: CGFloat, centerYFromTop: CGFloat,
                  color: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(colorSpace: cs, components: [color.0, color.1, color.2, 1])!
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: centerX - b.midX, y: (h - centerYFromTop) - b.midY)
            CTLineDraw(line, ctx)
        }

        // Background
        fill(CGRect(x: 0, y: 0, width: w, height: h), (0.12, 0.12, 0.14))

        // Square grid (aspect check): 64 px cells
        ctx.setStrokeColor(CGColor(colorSpace: cs, components: [0.3, 0.3, 0.33, 1])!)
        ctx.setLineWidth(2)
        var gx: CGFloat = 0
        while gx <= w { ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: h)); gx += 64 }
        var gy: CGFloat = 0
        while gy <= h { ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: w, y: gy)); gy += 64 }
        ctx.strokePath()

        // Corners (220 px squares)
        let c: CGFloat = 220
        fill(rect(0, 0, c, c), (1, 0, 0))           // TL red
        fill(rect(w - c, 0, c, c), (0, 1, 0))       // TR green
        fill(rect(0, h - c, c, c), (0, 0, 1))       // BL blue
        fill(rect(w - c, h - c, c, c), (1, 1, 0))   // BR yellow
        text("TL", size: 70, centerX: c / 2, centerYFromTop: c / 2)
        text("TR", size: 70, centerX: w - c / 2, centerYFromTop: c / 2, color: (0, 0, 0))
        text("BL", size: 70, centerX: c / 2, centerYFromTop: h - c / 2)
        text("BR", size: 70, centerX: w - c / 2, centerYFromTop: h - c / 2, color: (0, 0, 0))

        // Circle (aspect check), centred
        ctx.setStrokeColor(CGColor(colorSpace: cs, components: [0, 1, 1, 1])!)
        ctx.setLineWidth(10)
        ctx.strokeEllipse(in: CGRect(x: w / 2 - 260, y: h / 2 - 260, width: 520, height: 520))

        // Big upward arrow (top centre): shaft + head
        let white = CGColor(colorSpace: cs, components: [1, 1, 1, 1])!
        ctx.setFillColor(white)
        fill(rect(w / 2 - 40, 150, 80, 300), (1, 1, 1))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: w / 2, y: h - 30))            // tip (30 px from top)
        ctx.addLine(to: CGPoint(x: w / 2 - 150, y: h - 180))
        ctx.addLine(to: CGPoint(x: w / 2 + 150, y: h - 180))
        ctx.closePath()
        ctx.fillPath()
        text("TOP", size: 120, centerX: w / 2 - 330, centerYFromTop: 110)
        text("TOP", size: 120, centerX: w / 2 + 330, centerYFromTop: 110)
        text("L", size: 140, centerX: 110, centerYFromTop: h / 2)
        text("R", size: 140, centerX: w - 110, centerYFromTop: h / 2)
        text("BOTTOM", size: 60, centerX: w / 2, centerYFromTop: h - 45)

        // Bottom strip: gray ramp (left black → right white)
        let rampX = c + 20, rampW = w - 2 * (c + 20)
        let steps = 32
        for i in 0..<steps {
            let v = CGFloat(i) / CGFloat(steps - 1)
            fill(rect(rampX + rampW * CGFloat(i) / CGFloat(steps), h - 250, rampW / CGFloat(steps) + 1, 70), (v, v, v))
        }
        // 18% and 50% grey patches (sRGB-encoded reflectance: 18% ≈ 0.46, 50% ≈ 0.735;
        // plus literal 0.18 / 0.5 code values) and saturated swatches
        let patchY = h - 165, ps: CGFloat = 70
        let patches: [(CGFloat, CGFloat, CGFloat)] = [
            (0.18, 0.18, 0.18), (0.46, 0.46, 0.46), (0.5, 0.5, 0.5), (0.735, 0.735, 0.735),
            (1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, 0)
        ]
        let totalW = CGFloat(patches.count) * ps + CGFloat(patches.count - 1) * 10
        var px = w / 2 - totalW / 2
        for p in patches {
            fill(rect(px, patchY, ps, ps), p)
            px += ps + 10
        }

        return ctx.makeImage()!
    }
}

#endif
