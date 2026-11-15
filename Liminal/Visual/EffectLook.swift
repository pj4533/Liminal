//
//  EffectLook.swift
//  Liminal
//
//  How wild the effects are right now: the user's "Effect intensity" setting, the slow clarity
//  cycle (clear stretches and wild stretches over minutes) and the fresh-image hold (a new image is
//  shown clear for a few seconds). docs/plans/effects-balance.md sections 3-4,
//  docs/decisions/effects-balance.md.
//
//  Must reproduce scripts/fx_model.py `proposed()` (golden test in LiminalTests/EffectLookTests).
//

import Foundation

nonisolated struct EffectLook: Sendable, Equatable {
    /// The user setting, 0 (subtle) ... 1 (wild).
    var intensity: Float = EffectLook.defaultIntensity
    /// Seconds on the effect clock since the current image's crossfade began; nil before the first crossfade.
    var imageAge: Float? = nil
    /// Seconds between images (the "image interval" setting); scales the fresh-image windows when short.
    var imageInterval: Float = 30

    static let defaultIntensity: Float = 0.5

    /// Every tuning constant of the balance pass, in one place (plan 8.4 gives the tuning order).
    /// Anchors are (I = 0, I = 0.5, I = 1); see `tri`.
    enum Tuning {
        // Clarity cycle (plan 4.1)
        static let macroOmega: Float = 2 * .pi / 420     // periods 420 s, 260 s, 160 s
        static let macroPhase: (Float, Float, Float) = (-0.3, -1.2, -2.4)
        static let macroLo: Float = -0.45, macroHi: Float = 0.55
        static let macroBias: Float = 0.50               // (intensity - 0.5) * bias is added to the wave
        // Fresh-image hold (plan 4.2), seconds since the crossfade started
        static let freshFade: Float = 1.5, freshHoldEnd: Float = 4.5, freshEnd: Float = 11
        // Strain per unit amount (fx_model scan) and the recognisability budget (plan 4.3)
        static let kTurb: Float = 12.8, kLog: Float = 26, kNoise: Float = 28
        static let budget: (Float, Float, Float) = (0.30, 0.90, 1.45)
        // Warps
        static let waterClear: (Float, Float, Float) = (0.010, 0.024, 0.030)
        static let waterWild: (Float, Float, Float) = (0.016, 0.056, 0.080)
        static let logSphereMax: (Float, Float, Float) = (0, 0.011, 0.020)
        static let logSphereWindow: (Float, Float) = (0.45, 0.90)  // drive window where the radial fades in
        static let noiseMax: (Float, Float, Float) = (0, 0.011, 0.026)
        static let noiseWindow: (Float, Float) = (0.20, 0.80)
        // Transition boost, additive, times sin(pi * tp)
        static let boostWater: (Float, Float, Float) = (0.05, 0.16, 0.40)
        static let boostLogSphere: (Float, Float, Float) = (0, 0.006, 0.020)
        static let boostNoise: (Float, Float, Float) = (0.004, 0.020, 0.060)
        // Colour and the rest (plan 4.4): (clear, wild) anchor triples
        static let hueBlend = (clear: (Float(0.15), Float(0.40), Float(0.60)), wild: (Float(0.25), Float(0.70), Float(0.80)))
        static let hueWave = (clear: (Float(0.02), Float(0.10), Float(0.30)), wild: (Float(0.05), Float(0.30), Float(0.60)))
        static let fractalHue = (clear: (Float(0.2), Float(0.5), Float(0.8)), wild: (Float(0.3), Float(0.85), Float(1.0)))
        static let chromatic = (clear: (Float(0.3), Float(0.6), Float(0.9)), wild: (Float(0.4), Float(0.9), Float(1.0)))
        static let feedbackMix = (clear: (Float(0.10), Float(0.20), Float(0.27)), wild: (Float(0.14), Float(0.28), Float(0.30)))
        static let bloom: (Float, Float, Float) = (0.30, 0.50, 0.50)
    }

    // MARK: Helpers

    /// Piecewise-linear in intensity through (0, a), (0.5, b), (1, c).
    static func tri(_ i: Float, _ a: Float, _ b: Float, _ c: Float) -> Float {
        let i = min(max(i, 0), 1)
        return i <= 0.5 ? a + (b - a) * i * 2 : b + (c - b) * (i - 0.5) * 2
    }

    static func tri(_ i: Float, _ t: (Float, Float, Float)) -> Float { tri(i, t.0, t.1, t.2) }

    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Clarity cycle

    /// Slow macro wave, -1...1: three golden-ratio sines (420 / 260 / 160 s).
    static func macroWave(time: Float) -> Float {
        let w = Tuning.macroOmega, phi: Float = 1.618034, p = Tuning.macroPhase
        // fmod keeps Float precision on long sessions (the phases repeat exactly every period).
        let a = Float(fmod(Double(w) * Double(time), 2 * .pi))
        let b = Float(fmod(Double(w * phi) * Double(time), 2 * .pi))
        let c = Float(fmod(Double(w * phi * phi) * Double(time), 2 * .pi))
        return (sin(a + p.0) + 0.6 * sin(b + p.1) + 0.35 * sin(c + p.2)) / 1.95
    }

    /// 0 = clear stretch, 1 = wild stretch. Higher intensity spends more time wild.
    static func macroDrive(time: Float, intensity: Float) -> Float {
        smoothstep(Tuning.macroLo, Tuning.macroHi, macroWave(time: time) + (min(max(intensity, 0), 1) - 0.5) * Tuning.macroBias)
    }

    /// 0 while a new image settles, 1 once it has been seen (plan 4.2).
    func fresh() -> Float {
        guard let age = imageAge else { return 1 }
        let k = min(max(imageInterval / 30, 0.33), 1)
        return 1 - Self.smoothstep(0, Tuning.freshFade, age)
            * (1 - Self.smoothstep(Tuning.freshHoldEnd * k, Tuning.freshEnd * k, age))
    }

    /// The one drive every amount is mixed by: clarity cycle times fresh-image hold.
    func drive(time: Float) -> Float { Self.macroDrive(time: time, intensity: intensity) * fresh() }

    /// Recognisability budget: maximum combined warp strain.
    static func strainBudget(_ i: Float) -> Float { tri(i, Tuning.budget) }

    /// Combined strain load of a set of warp amounts (root-sum-square of the per-warp strains).
    static func strainLoad(distortion: Float, logSphere: Float, noise: Float) -> Float {
        let a = Tuning.kTurb * distortion, b = Tuning.kLog * logSphere, c = Tuning.kNoise * noise
        return (a * a + b * b + c * c).squareRoot()
    }
}

/// Eases the intensity the renderers pass toward the setting (0.5 s one-pole), so a slider drag
/// does not step the picture. Callers with a frozen effect clock pass the target straight through.
nonisolated struct EffectIntensitySmoother: Sendable {
    private(set) var value: Float?
    private var lastTime: Float = 0
    static let timeConstant: Float = 0.5

    mutating func next(target: Float, time: Float) -> Float {
        let target = min(max(target, 0), 1)
        guard let v = value else { value = target; lastTime = time; return target }
        let dt = time - lastTime
        if dt == 0 { return v }  // same frame asked twice
        lastTime = time
        // Restarted clock or a long gap: snap.
        guard dt > 0, dt < 1 else { value = target; return target }
        let next = v + (target - v) * (1 - exp(-dt / Self.timeConstant))
        value = next
        return next
    }
}
