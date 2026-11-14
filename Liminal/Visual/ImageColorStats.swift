//
//  ImageColorStats.swift
//  Liminal
//
//  Per-image inputs for the final VIBRANCE shader stage (docs/decisions/vibrance.md, V6).
//  Measured once per image on the CPU from a 32x32 downsample (about 0.1 ms), so the GPU
//  cost is zero: already-vivid images get less vibrance, muted ones more, and dark images
//  get a smaller black-point pull so their shadows are not crushed.
//

import CoreGraphics
import Foundation

/// Multipliers applied by `EffectsUniformsComputer` to the vibrance stage's uniforms.
nonisolated struct VibranceFactors: Equatable {
    /// Scales `vibranceAmount`. clamp(1.3 - meanSaturation, 0.5, 1.1).
    var amount: Float
    /// Scales `blackPoint`. clamp(meanLuma / 0.30, 0.3, 1.0).
    var dark: Float

    static let neutral = VibranceFactors(amount: 1, dark: 1)

    /// Linear blend (used across a crossfade, t = transition progress 0...1).
    static func lerp(_ a: VibranceFactors, _ b: VibranceFactors, _ t: Float) -> VibranceFactors {
        let t = min(max(t, 0), 1)
        return VibranceFactors(amount: a.amount + (b.amount - a.amount) * t,
                               dark: a.dark + (b.dark - a.dark) * t)
    }
}

nonisolated enum ImageColorStats {

    /// One 32x32 pass: mean HSV saturation, mean (gamma) Rec.601 luma, luma standard deviation
    /// (contrast) and mean (r - b) (warm/cool tilt, -1...1). All in gamma sRGB.
    struct Measurement: Equatable {
        var saturation: Float
        var luma: Float
        var lumaStdDev: Float
        var redMinusBlue: Float
    }

    static func measureFull(_ image: CGImage) -> Measurement? {
        let n = 32
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var satSum: Float = 0, lumaSum: Float = 0, lumaSq: Float = 0, rbSum: Float = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = Float(buf[i]) / 255, g = Float(buf[i + 1]) / 255, b = Float(buf[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            satSum += mx > 0.001 ? (mx - mn) / mx : 0
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            lumaSum += y
            lumaSq += y * y
            rbSum += r - b
        }
        let count = Float(n * n)
        let mean = lumaSum / count
        return Measurement(saturation: satSum / count, luma: mean,
                           lumaStdDev: max(lumaSq / count - mean * mean, 0).squareRoot(),
                           redMinusBlue: rbSum / count)
    }

    /// Mean HSV saturation and mean (gamma) Rec.601 luma of the image, both 0...1.
    static func measure(_ image: CGImage) -> (saturation: Float, luma: Float)? {
        measureFull(image).map { ($0.saturation, $0.luma) }
    }

    /// Factors for one image (pure; see `VibranceFactors` for the formulas).
    static func factors(for image: CGImage) -> VibranceFactors {
        guard let m = measure(image) else { return .neutral }
        return VibranceFactors(amount: min(max(1.3 - m.saturation, 0.5), 1.1),
                               dark: min(max(m.luma / 0.30, 0.3), 1.0))
    }

    // MARK: - Cache (render loops ask every frame; measure once per image object)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [(key: AnyObject, factors: VibranceFactors)] = []

    /// Cached `factors(for:)`, keyed by object identity (CGImage or NSImage/UIImage).
    /// `image` is only evaluated on a cache miss.
    static func cachedFactors(key: AnyObject, image: () -> CGImage?) -> VibranceFactors {
        lock.lock()
        if let hit = cache.first(where: { $0.key === key }) { lock.unlock(); return hit.factors }
        lock.unlock()
        let f = image().map(factors(for:)) ?? .neutral
        lock.lock()
        cache.append((key, f))
        if cache.count > 4 { cache.removeFirst(cache.count - 4) }  // current + previous + slack
        lock.unlock()
        return f
    }
}
