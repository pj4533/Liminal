//
//  DepthReliefField.swift
//  Liminal
//
//  Turns an ML depth map (Depth Anything V2, 0 = far, 1 = near, row 0 = image top) into the
//  spatial shell's relief: one inverse-radius offset q per shell vertex (docs/plans/spatial.md,
//  section 3). Pure Swift, all platforms, built once per image off the main actor and unit tested.
//
//  Steps:
//    1. Sample the depth at every vertex's (u, mirrored v). The depth map is generated from the
//       already cover-cropped 3:2 image, so it spans the image exactly (no further crop).
//    2. Normalise per image over the image rows: p2...p98 -> 0...1, minus the median, so about half
//       the scene sits in front of the base radius and half behind; clamp to -0.5...0.5.
//    3. Taper to zero across the mirrored bands.
//    4. 3x3 binomial blur, twice.
//    5. Slope limit: neighbouring vertices differ by at most ShellLayout.slopeLimit in inverse
//       radius at full strength (q step <= slopeLimit / inverseSpan), which bounds the "rubber
//       sheet" stretching at silhouettes. Exact: the mean of the lower and upper Lipschitz
//       envelopes (two-pass L1 chamfer each), which is itself Lipschitz and stays between them.
//
//  Per frame the shell uses radius = 1 / (1/rho0 + k * q * inverseSpan) (ShellLayout.radius).
//

import Foundation
import CoreGraphics

nonisolated struct DepthReliefField: Sendable, Equatable {

    /// Row-major over the shell grid (ShellLayout.vertexColumns x vertexRows, row 0 = bottom).
    let q: [Float]

    static var columns: Int { ShellLayout.vertexColumns }
    static var rows: Int { ShellLayout.vertexRows }
    /// Largest q step between neighbouring vertices.
    static var qSlopeLimit: Float { ShellLayout.slopeLimit / ShellLayout.inverseSpan }

    static var flat: DepthReliefField { DepthReliefField(q: [Float](repeating: 0, count: ShellLayout.vertexCount)) }

    // MARK: Build

    /// Build from a grey depth image (any size; 8-bit grey or anything CoreGraphics can draw).
    static func build(depthImage: CGImage) -> DepthReliefField? {
        let w = depthImage.width, h = depthImage.height
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(depthImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        // Bitmap memory is top row first, like the depth convention.
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        var depth = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { depth[i] = Float(bytes[i]) / 255 }
        return build(depth: depth, width: w, height: h)
    }

    /// Build from depth samples: row-major, row 0 = image top, 0 = far, 1 = near.
    static func build(depth: [Float], width: Int, height: Int) -> DepthReliefField {
        let cols = columns, rows = self.rows
        guard width > 1, height > 1, depth.count == width * height else { return flat }

        // 1. Sample at every vertex (mirrored v in the bands).
        var raw = [Float](repeating: 0, count: cols * rows)
        var heroSamples = [Float]()
        heroSamples.reserveCapacity(cols * (ShellLayout.heroRows + 1))
        var bands = [Float](repeating: 0, count: rows)
        for r in 0..<rows {
            let row = ShellLayout.row(r)
            bands[r] = row.band
            let y = (1 - row.sampleV) * Float(height - 1)  // v = 1 is the image top (row 0)
            for c in 0..<cols {
                let x = ShellLayout.column(c).u * Float(width - 1)
                let d = bilinear(depth, width, height, x, y)
                raw[r * cols + c] = d
                if row.band == 0 { heroSamples.append(d) }
            }
        }

        // 2. Normalise on the image rows.
        heroSamples.sort()
        let p2 = percentile(heroSamples, 0.02), p98 = percentile(heroSamples, 0.98)
        let range = p98 - p2
        guard range > 1e-3 else { return flat }
        let median = min(max((percentile(heroSamples, 0.5) - p2) / range, 0), 1)

        // 3. Normalised, centred, clamped, tapered across the bands.
        var q = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            let taper = 1 - ShellLayout.smoothstep(0, 1, bands[r])
            for c in 0..<cols {
                let i = r * cols + c
                let n = min(max((raw[i] - p2) / range, 0), 1)
                q[i] = min(max(n - median, -0.5), 0.5) * taper
            }
        }

        // 4. Blur twice, 5. slope limit.
        blur3x3(&q, cols: cols, rows: rows)
        blur3x3(&q, cols: cols, rows: rows)
        q = slopeLimited(q, cols: cols, rows: rows, limit: qSlopeLimit)
        return DepthReliefField(q: q)
    }

    // MARK: Helpers (internal for tests)

    static func bilinear(_ a: [Float], _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
        let x = min(max(x, 0), Float(w - 1)), y = min(max(y, 0), Float(h - 1))
        let x0 = min(Int(x), w - 2), y0 = min(Int(y), h - 2)
        let fx = x - Float(x0), fy = y - Float(y0)
        let i = y0 * w + x0
        let top = a[i] + (a[i + 1] - a[i]) * fx
        let bottom = a[i + w] + (a[i + w + 1] - a[i + w]) * fx
        return top + (bottom - top) * fy
    }

    /// Linear-interpolated percentile of an ascending array.
    static func percentile(_ sorted: [Float], _ p: Float) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let x = min(max(p, 0), 1) * Float(sorted.count - 1)
        let i = Int(x), f = x - Float(i)
        return i + 1 < sorted.count ? sorted[i] + (sorted[i + 1] - sorted[i]) * f : sorted[i]
    }

    /// 3x3 binomial blur (1 2 1 / 2 4 2 / 1 2 1) / 16 with clamped edges, separable.
    static func blur3x3(_ a: inout [Float], cols: Int, rows: Int) {
        var tmp = a
        for r in 0..<rows {
            for c in 0..<cols {
                let l = a[r * cols + max(c - 1, 0)], m = a[r * cols + c], rt = a[r * cols + min(c + 1, cols - 1)]
                tmp[r * cols + c] = (l + 2 * m + rt) * 0.25
            }
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let d = tmp[max(r - 1, 0) * cols + c], m = tmp[r * cols + c], u = tmp[min(r + 1, rows - 1) * cols + c]
                a[r * cols + c] = (d + 2 * m + u) * 0.25
            }
        }
    }

    /// Mean of the lower and upper `limit`-Lipschitz envelopes (4-neighbour L1 distance): every
    /// horizontal or vertical neighbour pair differs by at most `limit`, the result stays within
    /// the input's range, and fields that already satisfy the limit are returned unchanged.
    static func slopeLimited(_ a: [Float], cols: Int, rows: Int, limit s: Float) -> [Float] {
        var upper = a, lower = a
        // Forward pass (from left / below), then backward pass (from right / above).
        for r in 0..<rows {
            for c in 0..<cols {
                let i = r * cols + c
                if c > 0 { upper[i] = min(upper[i], upper[i - 1] + s); lower[i] = max(lower[i], lower[i - 1] - s) }
                if r > 0 { upper[i] = min(upper[i], upper[i - cols] + s); lower[i] = max(lower[i], lower[i - cols] - s) }
            }
        }
        for r in stride(from: rows - 1, through: 0, by: -1) {
            for c in stride(from: cols - 1, through: 0, by: -1) {
                let i = r * cols + c
                if c < cols - 1 { upper[i] = min(upper[i], upper[i + 1] + s); lower[i] = max(lower[i], lower[i + 1] - s) }
                if r < rows - 1 { upper[i] = min(upper[i], upper[i + cols] + s); lower[i] = max(lower[i], lower[i + cols] - s) }
            }
        }
        return zip(upper, lower).map { ($0 + $1) * 0.5 }
    }

    /// Largest absolute difference between horizontal or vertical neighbours.
    static func maxNeighbourStep(_ a: [Float], cols: Int, rows: Int) -> Float {
        var m: Float = 0
        for r in 0..<rows {
            for c in 0..<cols {
                let i = r * cols + c
                if c > 0 { m = max(m, abs(a[i] - a[i - 1])) }
                if r > 0 { m = max(m, abs(a[i] - a[i - cols])) }
            }
        }
        return m
    }

    var range: (min: Float, max: Float) { (q.min() ?? 0, q.max() ?? 0) }
}

/// Previous / current relief fields across an image change (docs/plans/spatial.md, section 3).
/// The previous image's field morphs into the new one with the crossfade's progress; if the new
/// depth is late, the old field is held and the new one eases in over `easeIn` seconds when it
/// arrives. Times are real (wall-clock) seconds, so a frozen effect clock does not stall it.
nonisolated struct ReliefBlend: Sendable {
    private(set) var previous: [Float]?
    private(set) var current: [Float]?
    private(set) var currentGeneration: UInt64 = 0
    private var arrival: Double?
    /// Image generation the current field belongs to (set when the image changes).
    private(set) var expectedGeneration: UInt64 = 0

    static let easeIn: Double = 0.6

    /// A new image (generation) is shown: the field on screen becomes `previous`.
    mutating func imageChanged(generation: UInt64) {
        if current != nil { previous = current }
        current = nil
        arrival = nil
        expectedGeneration = generation
    }

    /// Depth for `generation` is ready. Ignored if a newer image has replaced it meanwhile.
    mutating func depthArrived(_ q: [Float], generation: UInt64, now: Double) {
        guard generation == expectedGeneration else { return }
        current = q
        currentGeneration = generation
        arrival = now
    }

    /// Blend weight of `current` over `previous`: crossfade progress (nil when not transitioning,
    /// i.e. done) times the late-arrival ease.
    func weight(transitionProgress: Float?, now: Double) -> Float {
        guard current != nil, let a = arrival else { return 0 }
        let ease = ShellLayout.smoothstep(0, Float(Self.easeIn), Float(now - a))
        return (transitionProgress ?? 1) * ease
    }
}
