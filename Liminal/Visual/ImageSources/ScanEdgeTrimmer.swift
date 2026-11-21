//
//  ScanEdgeTrimmer.swift
//  Liminal
//
//  Trims the film rebate of a scanned slide or negative (FSA/OWI colour masters from the Library of
//  Congress): black edges of different widths on each side, edge codes and rounded mount corners.
//  BorderTrimmer needs all four edges to look alike, which these scans rarely do. Each side is walked
//  inward on its own while its line is mostly dark, then an extra inset clears the rounded corners.
//  Sources opt in with `trimScanEdges` in image-collections.json.
//

import CoreGraphics

nonisolated enum ScanEdgeTrimmer {
    /// Lines with at least this share of dark pixels count as rebate.
    static let darkShare = 0.55
    /// Luma (0...1) below which a pixel counts as dark.
    static let darkLuma = 0.16
    /// Never trim more than this share of a side.
    static let maxSideShare = 0.15
    /// Extra inset after the dark edge ends, as a share of the side (rounded corners, halation).
    static let inset = 0.02
    /// Every side loses at least this share: thin tinted rebates (green or amber film base) are not
    /// dark enough to detect, and the scans' rounded mount corners reach about this far in.
    static let minimumTrim = 0.03

    static func trimmed(_ image: CGImage) -> CGImage {
        guard let rect = contentRect(image), let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }

    static func contentRect(_ image: CGImage) -> CGRect? {
        let w = 300, h = max(2, Int(Double(image.height) / Double(image.width) * 300))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Row 0 of the buffer is the top of the image (CGContext draws with a flipped origin into memory).
        func dark(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            let l = (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
            return l < darkLuma
        }
        // Judge the middle 60% of each line so a dark corner alone does not make a line rebate.
        func rowDark(_ y: Int) -> Bool {
            let xs = (w / 5)..<(4 * w / 5)
            return Double(xs.filter { dark($0, y) }.count) / Double(xs.count) >= darkShare
        }
        func columnDark(_ x: Int) -> Bool {
            let ys = (h / 5)..<(4 * h / 5)
            return Double(ys.filter { dark(x, $0) }.count) / Double(ys.count) >= darkShare
        }
        let maxX = Int(Double(w) * maxSideShare), maxY = Int(Double(h) * maxSideShare)
        var t = 0, b = 0, l = 0, r = 0
        while t < maxY, rowDark(t) { t += 1 }
        while b < maxY, rowDark(h - 1 - b) { b += 1 }
        while l < maxX, columnDark(l) { l += 1 }
        while r < maxX, columnDark(w - 1 - r) { r += 1 }
        let ix = Int((Double(w) * inset).rounded(.up)), iy = Int((Double(h) * inset).rounded(.up))
        let mx = Int((Double(w) * minimumTrim).rounded(.up)), my = Int((Double(h) * minimumTrim).rounded(.up))
        let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
        let x0 = max(mx, l + (l > 0 ? ix : 0)), x1 = w - max(mx, r + (r > 0 ? ix : 0))
        let y0 = max(my, t + (t > 0 ? iy : 0)), y1 = h - max(my, b + (b > 0 ? iy : 0))
        guard x1 > x0, y1 > y0 else { return nil }
        let rect = CGRect(x: Double(x0) * sx, y: Double(y0) * sy,
                          width: Double(x1 - x0) * sx, height: Double(y1 - y0) * sy).integral
        guard rect.width > Double(image.width) * 0.6, rect.height > Double(image.height) * 0.6 else { return nil }
        return rect
    }
}
