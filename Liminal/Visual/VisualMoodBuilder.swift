//
//  VisualMoodBuilder.swift
//  Liminal
//
//  Visuals -> music (docs/plans/av-coupling.md section 2, decisions C9, C10, C12).
//  Turns an image's metadata (prompt intent + measured colour) and its pixels into the VisualMood
//  the music conductor follows, and throttles the visual-activity signal.
//

import CoreGraphics
import Synchronization
import Foundation

nonisolated enum VisualMoodBuilder {

    /// Shared crossfade length (both platforms' crossfades are 1.5 s); also sent to `imageDidChange`.
    static let crossfadeDuration: Double = 1.5

    /// Measured values lead (the model does not always follow the prompt); the prompt adds intent the
    /// pixels cannot show (mood words, intended warmth and energy). Without metadata (test pattern,
    /// old cache entries) everything comes from one 32x32 pass over the pixels.
    static func mood(metadata: ImageMetadata?, image: CGImage?) -> VisualMood {
        let px = image.flatMap(ImageColorStats.measureFull)
        let contrast = clamp01((px?.lumaStdDev ?? 0.125) / 0.25)
        let pixelWarmth = clamp01(0.5 + 1.5 * (px?.redMinusBlue ?? 0))
        var m = VisualMood()
        guard let meta = metadata else {
            m.brightness = px?.luma ?? 0.5
            m.saturation = px?.saturation ?? 0.5
            m.warmth = pixelWarmth
            m.energy = contrast
            return m
        }
        m.brightness = clamp01(Float(meta.measuredBrightness))
        m.saturation = clamp01(Float(meta.measuredSaturation))
        let measuredWarmth = dominantWarmth(meta.dominantColors) ?? pixelWarmth
        let intendedWarmth = clamp01(Float((meta.spec.warmth + 1) / 2))
        m.warmth = clamp01(0.6 * measuredWarmth + 0.4 * intendedWarmth)
        m.energy = clamp01(0.5 * Float(meta.spec.energy) + 0.5 * contrast)
        m.palette = meta.dominantColors.prefix(5).map { SIMD3(linear($0.r), linear($0.g), linear($0.b)) }
        m.moodWords = meta.spec.moods.map(\.rawValue) + [meta.spec.subjectCategory.rawValue]
        return m
    }

    /// clamp(0.5 + 1.5 * mean(r - b)) over the dominant colours, weighted 5, 4, 3, 2, 1 by coverage rank.
    static func dominantWarmth(_ colors: [RGB]) -> Float? {
        guard !colors.isEmpty else { return nil }
        var sum = 0.0, wsum = 0.0
        for (i, c) in colors.prefix(5).enumerated() {
            let w = Double(5 - i)
            sum += w * (c.r - c.b)
            wsum += w
        }
        return clamp01(Float(0.5 + 1.5 * sum / wsum))
    }

    @inline(__always) static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

    /// sRGB transfer function -> linear.
    static func linear(_ c: Double) -> Float {
        let v = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        return Float(v)
    }
}

/// Sends `visualActivity` at most twice a second and only when it moved by more than 0.02 (plan 2.3).
nonisolated struct VisualActivityThrottle {
    private(set) var lastSent: Float = -1
    private var lastSendTime: Double = -1000

    /// Returns the value to send, or nil.
    mutating func next(_ value: Float, at time: Double) -> Float? {
        guard time - lastSendTime >= 0.5 || time < lastSendTime, abs(value - lastSent) > 0.02 else { return nil }
        lastSent = value
        lastSendTime = time
        return value
    }
}

/// Last mood sent to the music, written from a background task and read by the sync log.
nonisolated final class SentMoodRecord: Sendable {
    private let value = Mutex<VisualMood?>(nil)
    func store(_ mood: VisualMood) { value.withLock { $0 = mood } }
    func load() -> VisualMood? { value.withLock { $0 } }
}
