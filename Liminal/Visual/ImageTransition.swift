//
//  ImageTransition.swift
//  Liminal
//
//  The family of image transitions (docs/plans/transitions.md, docs/decisions/transitions.md).
//  Every style follows one idea: the live effects surge, the two pictures exchange inside the
//  distortion (ordered by a field the shader already has), and the effects settle back into the
//  new picture. A transition is a `TransitionSpec`, chosen once per crossfade by the
//  `TransitionDirector`; `EffectsUniformsComputer.compute(transition:)` turns it into uniforms.
//
//  Shared with scripts/shader-bench.swift (offline renders), so it depends on Foundation only.
//

import Foundation

nonisolated enum TransitionFamily: String, Sendable {
    case flow, colour, geometric, temporal
}

/// Raw values are the shader's `txStyle` (EffectsRenderer.metal, TX_* constants).
nonisolated enum TransitionStyle: Int, CaseIterable, Sendable {
    /// The pre-family crossfade: sin(pi * tp) boost, whole-frame eased dissolve over the full duration.
    /// Default of `compute` (golden parity) and the hidden control of the judge sets; never picked.
    case classic = 0
    case tide, facets, prism, rainbow, kaleidoscope, whirlpool, dive, afterimage, ripple, solarize, melt, shatter

    /// The styles the director picks from.
    static let family: [TransitionStyle] = allCases.filter { $0 != .classic }

    var name: String { String(describing: self) }

    init?(name: String) {
        guard let s = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = s
    }

    var familyGroup: TransitionFamily {
        switch self {
        case .classic, .tide, .melt, .ripple: return .flow
        case .prism, .rainbow, .solarize: return .colour
        case .kaleidoscope, .whirlpool, .dive, .shatter, .facets: return .geometric
        case .afterimage: return .temporal
        }
    }

    /// Offered at any intensity (plan 7.1); the others need intensity >= 0.25.
    var isGentle: Bool {
        switch self {
        case .tide, .afterimage, .melt, .rainbow, .ripple: return true
        default: return false
        }
    }

    /// Timing per style (plan 6): the swap window [s0, s1] in linear progress is also the envelope's
    /// plateau; durations in seconds before the music / interval scaling; mask edge softness.
    var shape: TransitionShape {
        switch self {
        case .classic:      return TransitionShape(s0: 0, s1: 1, duration: (1.5, 1.5), soft: 0.5)
        case .tide:         return TransitionShape(s0: 0.26, s1: 0.74, duration: (2.0, 2.8), soft: 0.14)
        case .facets:       return TransitionShape(s0: 0.30, s1: 0.66, duration: (2.4, 3.2), soft: 0.16)
        case .prism:        return TransitionShape(s0: 0.26, s1: 0.76, duration: (2.2, 3.0), soft: 0.30)
        case .rainbow:      return TransitionShape(s0: 0.30, s1: 0.72, duration: (2.4, 3.4), soft: 0.12)
        case .kaleidoscope: return TransitionShape(s0: 0.32, s1: 0.60, duration: (3.6, 4.5), soft: 0.24)
        case .whirlpool:    return TransitionShape(s0: 0.30, s1: 0.60, duration: (2.4, 3.4), soft: 0.20)
        case .dive:         return TransitionShape(s0: 0.34, s1: 0.58, duration: (2.6, 3.4), soft: 0.16)
        case .afterimage:   return TransitionShape(s0: 0.30, s1: 0.60, duration: (2.8, 4.0), soft: 0.35)
        case .ripple:       return TransitionShape(s0: 0.28, s1: 0.70, duration: (2.4, 3.4), soft: 0.12)
        case .solarize:     return TransitionShape(s0: 0.30, s1: 0.68, duration: (2.4, 3.4), soft: 0.30)
        case .melt:         return TransitionShape(s0: 0.30, s1: 0.70, duration: (2.6, 3.6), soft: 0.12)
        case .shatter:      return TransitionShape(s0: 0.30, s1: 0.70, duration: (2.2, 3.0), soft: 0.20)
        }
    }
}

nonisolated struct TransitionShape: Sendable, Equatable {
    var s0: Float
    var s1: Float
    var duration: (Float, Float)
    var soft: Float

    static func == (a: Self, b: Self) -> Bool {
        a.s0 == b.s0 && a.s1 == b.s1 && a.duration == b.duration && a.soft == b.soft
    }
}

/// One transition, chosen once when the crossfade starts.
nonisolated struct TransitionSpec: Sendable, Equatable {
    var style: TransitionStyle
    /// 0...1: direction, centre, wedge count, channel order (shader `txSeed`).
    var seed: Float
    /// Seconds; the platform crossfade timer runs `transitionProgress` 0...1 over it.
    var duration: Float
    /// Reverses the swap order (edges in, darks first, near first ...).
    var flip: Bool

    static let classic = TransitionSpec(style: .classic, seed: 0, duration: 1.5, flip: false)

    static let minDuration: Float = 1.5, maxDuration: Float = 4.5

    /// The spec a pinned style and integer seed give (debug flags, shader bench): same mapping everywhere.
    static func pinned(_ style: TransitionStyle, seed n: Int, duration: Float? = nil) -> TransitionSpec {
        let s = Float((Double(n) * 0.6180339887 + 0.137).truncatingRemainder(dividingBy: 1))
        let r = style.shape.duration
        return TransitionSpec(style: style, seed: abs(s), duration: duration ?? (r.0 + r.1) / 2, flip: n % 2 == 1)
    }

    /// Effect envelope E(tp), 0...1: zero value and zero slope at both ends, plateau over the swap window.
    /// Classic keeps its sin(pi * tp).
    func envelope(_ tp: Float) -> Float {
        let t = min(max(tp, 0), 1)
        if style == .classic { return sin(Float.pi * t) }
        let s = style.shape
        return EffectLook.smoothstep(0, s.s0, t) * (1 - EffectLook.smoothstep(s.s1, 1, t))
    }

    /// Swap progress M(tp), 0...1, confined to the swap window. Classic: ease-in-out cubic over the whole duration.
    func swap(_ tp: Float) -> Float {
        let t = min(max(tp, 0), 1)
        if style == .classic { return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
        // Linear inside the window: the mask's own smoothstep gives every pixel a C1 change, and a
        // linear sweep spreads the exchange evenly over the window (a smoothstep sweep crowded it
        // into the middle third: one 0.15 s luma jump on the calm pair).
        let s = style.shape
        return min(max((t - s.s0) / (s.s1 - s.s0), 0), 1)
    }

    /// Progress at which half the picture has exchanged.
    var swapCentre: Float { (style.shape.s0 + style.shape.s1) / 2 }

    /// Duration posted to `imageDidChange`: the conductor lands its chord change at half of it, i.e. on the swap.
    var musicDuration: Double { Double(2 * swapCentre * duration) }

    /// Signed mask softness for the shader (`txSoft`): negative reverses the order.
    var shaderSoft: Float { style.shape.soft * (flip ? -1 : 1) }
}

// MARK: - What a style pushes (plan 6)

/// Additive / multiplicative pushes on the existing uniforms at one instant (already times the envelope).
nonisolated struct TransitionBoost: Sendable, Equatable {
    var water: Float = 0, logSphere: Float = 0, noise: Float = 0
    var chromaticMul: Float = 1, chromaticAdd: Float = 0
    /// Feedback mix is pulled toward this target by `feedbackPull` (0 = untouched), never below the live value.
    var feedbackTarget: Float = 0, feedbackPull: Float = 0
    var feedbackAdd: Float = 0
    var feedbackWarpMul: Float = 1
    var hueWaveTarget: Float = 0, hueBlendTarget: Float = 0, huePull: Float = 0
    var hueBlendAdd: Float = 0
    var hueBase: Float = 0
    var fractalHueAdd: Float = 0
    var bloomAdd: Float = 0, bloomRadiusMul: Float = 1
    var contrastAdd: Float = 0
    var kenBurnsMul: Float = 1
    var ghostReachMul: Float = 1
    /// Style amount the shader reads as `txAmount` (Prism stagger, fold, swirl angle, wave, lens, tone fold, ripple, drip).
    var shaderAmount: Float = 0

    /// - Parameters: e = envelope (possibly swelled by the music), tp = linear progress, i = intensity.
    static func make(_ spec: TransitionSpec, intensity i: Float, envelope e: Float, tp: Float) -> TransitionBoost {
        typealias T = EffectLook.Tuning
        func tri(_ a: Float, _ b: Float, _ c: Float) -> Float { EffectLook.tri(i, a, b, c) }
        var b = TransitionBoost()
        switch spec.style {
        case .classic:
            b.water = EffectLook.tri(i, T.boostWater) * e
            b.logSphere = EffectLook.tri(i, T.boostLogSphere) * e
            b.noise = EffectLook.tri(i, T.boostNoise) * e
            b.chromaticMul = 1 + 3 * e
        case .tide:
            // Round 2: today's water surge plus a breaking wave that rolls across and carries the swap
            // (judges: "close to the classic"); the water is a little lower so the wave reads.
            b.shaderAmount = tri(0.07, 0.15, 0.22)   // wave push at the crest
            b.water = tri(0.05, 0.13, 0.26) * e
            b.logSphere = tri(0, 0.004, 0.014) * e
            b.noise = tri(0.004, 0.015, 0.045) * e
            b.chromaticMul = 1 + 4 * e
            b.feedbackAdd = 0.10 * e
        case .facets:
            // Round 2 (replaces Undertow, judged a Tide twin): hexagonal compound-eye lenses.
            b.shaderAmount = tri(0.55, 0.80, 0.95)   // 0.38 = flat hex mosaic, above it the lenses invert
            b.water = tri(0.02, 0.05, 0.09) * e
            b.chromaticMul = 1 + 3 * e
            b.bloomAdd = 0.08 * e
        case .prism:
            b.chromaticAdd = tri(0.035, 0.07, 0.11) * e
            b.hueBlendAdd = 0.15 * e
            b.water = tri(0.03, 0.07, 0.12) * e
            b.feedbackAdd = 0.08 * e
            b.shaderAmount = tri(0.10, 0.18, 0.25)   // channel stagger; the shader's split is 0.35 x this, twist 0.7 x
        case .rainbow:
            b.hueWaveTarget = tri(0.30, 0.45, 0.60)
            b.hueBlendTarget = tri(0.55, 0.80, 0.90)
            b.huePull = e
            b.hueBase = EffectLook.smoothstep(0, 1, tp)   // one full turn: ends where it started
            b.water = tri(0.05, 0.11, 0.16) * e
            b.noise = tri(0, 0.010, 0.020) * e
        case .kaleidoscope:
            b.shaderAmount = tri(0.48, 0.72, 0.90)   // round 2: a softer fold (frame steps in the unfold)
            b.logSphere = tri(0.004, 0.012, 0.024) * e
            b.chromaticMul = 1 + 2 * e
            b.water = tri(0.01, 0.03, 0.06) * e
        case .whirlpool:
            b.shaderAmount = (spec.flip ? -1 : 1) * tri(0.8, 2.0, 3.4)
            b.water = tri(0.03, 0.08, 0.18) * e
            b.feedbackAdd = 0.12 * e
            b.chromaticMul = 1 + 1.5 * e
        case .dive:
            b.kenBurnsMul = 1 + tri(0.5, 1.0, 1.8) * e
            b.logSphere = tri(0.006, 0.016, 0.030) * e
            b.feedbackAdd = tri(0, 0.03, 0.06) * e   // round 2: almost no trails (the double image at the deepest zoom)
            b.chromaticMul = 1 + 3 * e
        case .afterimage:
            // Round 2: shorter, more warped trails, glow and contrast so the smear keeps light and
            // streaks ("flat purple wash, loses detail, muddy").
            b.feedbackTarget = tri(0.56, 0.64, 0.72)
            b.feedbackPull = e
            b.feedbackWarpMul = 1 + 8 * e
            b.water = tri(0.05, 0.10, 0.16) * e
            b.bloomAdd = 0.18 * e
            b.contrastAdd = 0.15 * e
            b.ghostReachMul = 1 + 1.5 * e
            b.hueBlendAdd = 0.35 * e
            b.hueBase = 0.18 * e
            b.chromaticMul = 1 + 3 * e
        case .ripple:
            b.shaderAmount = tri(0.015, 0.035, 0.055)   // ring displacement
            b.water = tri(0.02, 0.05, 0.10) * e
            b.chromaticMul = 1 + 2 * e
            b.feedbackAdd = 0.10 * e
        case .solarize:
            // Round 2 (replaces Depthwash, judged a generic warp): the tone curve folds over itself.
            b.shaderAmount = tri(0.6, 1.1, 1.6)   // extra tone folds at the plateau
            b.water = tri(0.04, 0.08, 0.13) * e
            b.chromaticMul = 1 + 2 * e
            b.feedbackAdd = 0.08 * e
        case .melt:
            b.shaderAmount = tri(0.12, 0.24, 0.36)   // drip length
            b.water = tri(0.03, 0.06, 0.10) * e
            b.feedbackAdd = tri(0.10, 0.20, 0.30) * e
            b.hueBlendAdd = 0.10 * e
        case .shatter:
            b.noise = tri(0.022, 0.048, 0.088) * e   // round 2: a little less, softer edge ("harsh, messy")
            b.chromaticMul = 1 + 3 * e
            b.water = tri(0.03, 0.06, 0.11) * e
        }
        return b
    }
}

// MARK: - Selection (plan 7)

/// Picks one `TransitionSpec` per crossfade: no style within the last 4, no family twice in a row,
/// weighted toward the mood the effects are in. Seeded, so a seed gives the same sequence.
nonisolated struct TransitionDirector: Sendable {
    /// Styles that may not come back for this many transitions.
    static let recency = 4

    private var state: UInt64
    private(set) var history: [TransitionStyle] = []
    /// Debug: always this style (and this integer seed, if set).
    var pinnedStyle: TransitionStyle?
    var pinnedSeed: Int?

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    private mutating func nextUnit() -> Float {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }

    /// Base weight times the fit to the moment (plan 7.1).
    static func weight(_ s: TransitionStyle, drive d: Float, intensity i: Float, energy e: Float) -> Float {
        var w: Float = s == .tide ? 0.7 : 1
        switch s {
        case .kaleidoscope, .whirlpool, .dive, .shatter, .prism, .facets: w *= 1 + d          // wild stretch
        case .tide, .melt, .ripple, .afterimage, .solarize: w *= 2 - d          // clear stretch
        default: break
        }
        if s == .kaleidoscope || s == .shatter { w *= 1 + 0.5 * min(max((i - 0.25) / 0.75, 0), 1) }
        let mid = (s.shape.duration.0 + s.shape.duration.1) / 2
        let short: Float = mid < 2.8 ? 1 : -1
        w *= 1 + 0.6 * (e - 0.5) * short
        return max(w, 0.01)
    }

    /// Eligible styles: the gentle set below intensity 0.25 (no style needs a depth map since round 2), and the
    /// recency / family rules, relaxed step by step only when nothing is left (small gentle set).
    static func eligible(history: [TransitionStyle], intensity: Float, hasDepth: Bool) -> [TransitionStyle] {
        let base = TransitionStyle.family.filter { s in
            intensity >= 0.25 || s.isGentle
        }
        let last = history.last
        for k in stride(from: recency, through: 1, by: -1) {
            let recent = Set(history.suffix(k))
            for sameFamilyOK in [false, true] {
                let pool = base.filter { s in
                    !recent.contains(s) && (sameFamilyOK || last == nil || s.familyGroup != last!.familyGroup)
                }
                if !pool.isEmpty { return pool }
            }
        }
        return base.filter { $0 != last }.isEmpty ? base : base.filter { $0 != last }
    }

    /// - Parameters: energy = music energy 0...1 when synced (nil: 0.5); imageInterval in seconds.
    mutating func next(time: Float, intensity: Float, energy: Float?, hasDepth: Bool,
                       imageInterval: Float = 30) -> TransitionSpec {
        let i = min(max(intensity, 0), 1)
        let e = min(max(energy ?? 0.5, 0), 1)
        let d = EffectLook.macroDrive(time: time, intensity: i)
        var style: TransitionStyle
        if let p = pinnedStyle {
            style = p
        } else {
            let pool = Self.eligible(history: history, intensity: i, hasDepth: hasDepth)
            let ws = pool.map { Self.weight($0, drive: d, intensity: i, energy: e) }
            var r = nextUnit() * ws.reduce(0, +)
            style = pool.last!
            for (s, w) in zip(pool, ws) {
                if r < w { style = s; break }
                r -= w
            }
        }
        history.append(style)
        if history.count > 16 { history.removeFirst(history.count - 16) }

        let u = nextUnit(), seed = nextUnit(), flip = nextUnit() < 0.5
        let range = style.shape.duration
        let raw = (range.0 + (range.1 - range.0) * u) * (1.15 - 0.30 * e)
        let duration = Self.clampDuration(raw, imageInterval: imageInterval)
        if let n = pinnedSeed {
            var spec = TransitionSpec.pinned(style, seed: n)
            spec.duration = Self.clampDuration(spec.duration, imageInterval: imageInterval)
            return spec
        }
        return TransitionSpec(style: style, seed: seed, duration: duration, flip: flip)
    }

    /// 1.5...4.5 s and at most 20 % of the image interval (never below 1.5 s).
    static func clampDuration(_ d: Float, imageInterval: Float) -> Float {
        let hi = max(min(TransitionSpec.maxDuration, 0.2 * imageInterval), TransitionSpec.minDuration)
        return min(max(d, TransitionSpec.minDuration), hi)
    }
}
