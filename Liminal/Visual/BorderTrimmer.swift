//
//  BorderTrimmer.swift
//  Liminal
//
//  Safety net for scan-style white borders (mounts, paper margins).
//  Samples a strip on each side; if all four strips are near-uniform and
//  near-white while the interior is not, crops inward to the content.
//  Near-black edges are deliberately left alone: night scenes and dark studio
//  photographs have black surroundings on purpose, and cropping them would
//  cut into real content.
//

import Foundation
import CoreGraphics

nonisolated enum BorderTrimmer {

    /// Returns the image unchanged unless a uniform near-white border surrounds it.
    static func trimmedIfBordered(_ image: CGImage) -> CGImage {
        guard let rect = contentRect(image) else { return image }
        return image.cropping(to: rect) ?? image
    }

    /// The crop rect when a border is detected, else nil. Internal for tests.
    static func contentRect(_ image: CGImage) -> CGRect? {
        // Work on a 200-px-wide proxy.
        let w = 200, h = max(2, Int(Double(image.height) / Double(image.width) * 200))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
        }
        func stats(_ points: [(Int, Int)]) -> (mean: Double, spread: Double) {
            let values = points.map { luma($0.0, $0.1) }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            return (mean, variance.squareRoot())
        }
        // Row/column helpers in proxy coordinates (y = 0 is the top row in memory).
        func row(_ y: Int) -> [(Int, Int)] { (0..<w).map { ($0, y) } }
        func column(_ x: Int) -> [(Int, Int)] { (0..<h).map { (x, $0) } }
        func isBorderLine(_ s: (mean: Double, spread: Double), like edge: Double) -> Bool {
            s.spread < 0.04 && abs(s.mean - edge) < 0.06 && edge > 0.88
        }

        let stripX = max(1, w / 50), stripY = max(1, h / 50)   // outer 2%
        let top = stats((0..<stripY).flatMap(row))
        let bottom = stats(((h - stripY)..<h).flatMap(row))
        let left = stats((0..<stripX).flatMap(column))
        let right = stats(((w - stripX)..<w).flatMap(column))
        let edge = (top.mean + bottom.mean + left.mean + right.mean) / 4
        guard [top, bottom, left, right].allSatisfy({ isBorderLine($0, like: edge) }) else { return nil }

        let interior = stats((h / 4..<(3 * h / 4)).flatMap { y in (w / 4..<(3 * w / 4)).map { ($0, y) } })
        guard interior.spread > 0.08 || abs(interior.mean - edge) > 0.25 else { return nil }

        // Walk inward from each side until the line stops looking like border.
        var t = 0, b = h - 1, l = 0, r = w - 1
        while t < h / 3, isBorderLine(stats(row(t)), like: edge) { t += 1 }
        while b > 2 * h / 3, isBorderLine(stats(row(b)), like: edge) { b -= 1 }
        while l < w / 3, isBorderLine(stats(column(l)), like: edge) { l += 1 }
        while r > 2 * w / 3, isBorderLine(stats(column(r)), like: edge) { r -= 1 }

        let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
        let inset = 1.0  // one extra proxy pixel to clear anti-aliased edges
        let rect = CGRect(x: (Double(l) + inset) * sx, y: (Double(t) + inset) * sy,
                          width: (Double(r - l) - 2 * inset) * sx, height: (Double(b - t) - 2 * inset) * sy).integral
        guard rect.width > Double(image.width) * 0.5, rect.height > Double(image.height) * 0.5 else { return nil }
        return rect
    }
}
