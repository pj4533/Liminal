import Testing
import Foundation
@testable import Liminal

/// Image transitions (docs/plans/transitions.md): envelopes, swap window, uniforms outside a
/// transition, intensity scaling, and the director's selection rules.
@MainActor
struct ImageTransitionTests {

    static let styles = TransitionStyle.family

    @Test func envelopesAreBoundedContinuousAndFlatAtBothEnds() {
        for style in Self.styles {
            let spec = TransitionSpec.pinned(style, seed: 3)
            #expect(spec.envelope(0) == 0 && spec.envelope(1) == 0, "\(style) ends")
            // Zero slope at both ends (C1 handover to the live effects).
            // Smoothstep ends: E(h) ~ 3 (h / w)^2, so the difference quotient vanishes with h.
            let h: Float = 1e-4
            #expect(spec.envelope(h) / h < 0.01, "\(style) start slope")
            #expect(spec.envelope(1 - h) / h < 0.01, "\(style) end slope")
            var prev = spec.envelope(0), maxStep: Float = 0
            for k in 1...2000 {
                let e = spec.envelope(Float(k) / 2000)
                #expect(e >= 0 && e <= 1, "\(style) bounded")
                maxStep = max(maxStep, abs(e - prev))
                prev = e
            }
            #expect(maxStep < 0.01, "\(style) continuous (max step \(maxStep))")
            // Full strength inside the swap window.
            #expect(abs(spec.envelope(spec.swapCentre) - 1) < 1e-5, "\(style) plateau")
        }
    }

    @Test func swapHappensOnlyInsideThePlateauAndNeverGoesBack() {
        for style in Self.styles {
            let spec = TransitionSpec.pinned(style, seed: 1)
            let s = style.shape
            #expect(0 < s.s0 && s.s0 < s.s1 && s.s1 < 1, "\(style) window")
            var prev: Float = 0
            for k in 0...1000 {
                let tp = Float(k) / 1000
                let m = spec.swap(tp)
                #expect(m >= prev, "\(style) monotonic")
                prev = m
                if tp <= s.s0 { #expect(m == 0, "\(style) no swap before the plateau") }
                if tp >= s.s1 { #expect(m == 1, "\(style) swapped after the plateau") }
                if m > 0 && m < 1 { #expect(spec.envelope(tp) > 0.999, "\(style) swap at full distortion") }
            }
        }
    }

    @Test func noTransitionUniformsMatchTheClassicDefault() {
        // tp = 0 (and the frames around a crossfade): every style gives exactly the classic uniforms.
        for t: Float in [0, 47, 113, 600, 1800] {
            let look = EffectLook(intensity: 0.5, imageAge: 20)
            let base = EffectsUniformsComputer.compute(time: t, transitionProgress: 0, look: look)
            for style in Self.styles {
                let u = EffectsUniformsComputer.compute(time: t, transitionProgress: 0, look: look,
                                                        transition: .pinned(style, seed: 2))
                #expect(withUnsafeBytes(of: u, { Array($0) }) == withUnsafeBytes(of: base, { Array($0) }),
                        "\(style) at t=\(t)")
                #expect(u.txStyle == 0 && u.txEnv == 0 && u.txMix == 0)
            }
        }
    }

    @Test func transitionUniformsAreFilledAndFinite() {
        for style in Self.styles {
            let spec = TransitionSpec.pinned(style, seed: 5)
            for k in 1..<50 {
                let tp = Float(k) / 50
                let u = EffectsUniformsComputer.compute(time: 300, transitionProgress: tp,
                                                        look: EffectLook(intensity: 1, imageAge: tp * spec.duration),
                                                        transition: spec)
                #expect(u.txStyle == Float(style.rawValue))
                let fields = [u.distortionAmplitude, u.logSphereAmount, u.fractalNoiseAmount, u.chromaticAmount,
                              u.feedbackMix, u.bloomAmount, u.hueWaveIntensity, u.hueBlendAmount, u.kenBurnsScale,
                              u.txMix, u.txEnv, u.txAmount]
                #expect(fields.allSatisfy { $0.isFinite }, "\(style) finite")
                #expect(u.feedbackMix < 0.95 && u.hueBlendAmount <= 1, "\(style) trails and hue bounded")
            }
        }
    }

    /// Total push of a style at its plateau, as a strain plus the non-warp amounts.
    static func push(_ style: TransitionStyle, intensity i: Float) -> Float {
        let spec = TransitionSpec.pinned(style, seed: 0)
        let b = TransitionBoost.make(spec, intensity: i, envelope: 1, tp: spec.swapCentre)
        return EffectLook.strainLoad(distortion: b.water, logSphere: b.logSphere, noise: b.noise)
            + abs(b.shaderAmount) + b.chromaticAdd * 10 + b.feedbackAdd + b.feedbackTarget + b.bloomAdd
            + b.hueWaveTarget + b.hueBlendTarget + b.fractalHueAdd + (b.kenBurnsMul - 1)
    }

    @Test func intensityScalesEveryStyleMonotonically() {
        for style in Self.styles {
            var prev = Self.push(style, intensity: 0)
            for k in 1...20 {
                let p = Self.push(style, intensity: Float(k) / 20)
                #expect(p >= prev - 1e-6, "\(style) at intensity \(Float(k) / 20)")
                prev = p
            }
            #expect(Self.push(style, intensity: 1) > Self.push(style, intensity: 0), "\(style) wilder at 1")
        }
    }

    @Test func directorNeverRepeatsWithinFiveOrAFamilyInARow() {
        for seed: UInt64 in [1, 2, 3, 42, 999] {
            var d = TransitionDirector(seed: seed)
            var picks: [TransitionSpec] = []
            for k in 0..<400 {
                let t = Float(k) * 30
                picks.append(d.next(time: t, intensity: Float(k % 7) / 6 * 0.75 + 0.25, energy: Float(k % 5) / 4,
                                    hasDepth: k % 3 != 0))
            }
            for (k, p) in picks.enumerated() {
                let recent = picks[max(0, k - TransitionDirector.recency)..<k].map { $0.style }
                #expect(!recent.contains(p.style), "seed \(seed) pick \(k): \(p.style) within 5")
                if k > 0 { #expect(picks[k - 1].style.familyGroup != p.style.familyGroup, "seed \(seed) family at \(k)") }
                #expect(p.duration >= 1.5 && p.duration <= 4.5, "duration \(p.duration)")
                #expect(p.seed >= 0 && p.seed < 1)
                #expect(p.style != .classic)
            }
            // Every style gets used.
            #expect(Set(picks.map { $0.style }).count == TransitionStyle.family.count, "seed \(seed) coverage")
        }
    }

    @Test func directorRespectsDepthIntensityAndInterval() {
        var d = TransitionDirector(seed: 7)
        for k in 0..<200 {
            let p = d.next(time: Float(k) * 30, intensity: 0.1, energy: nil, hasDepth: false, imageInterval: 8)
            #expect(p.style.isGentle, "only gentle styles below 0.25")
            #expect(p.style != .depthwash, "no depth style without a depth map")
            #expect(p.duration >= 1.5 && p.duration <= 1.6 + 1e-6, "8 s interval: at most 20 % (1.6 s)")
            if k > 0 { #expect(d.history[d.history.count - 2] != p.style, "no immediate repeat") }
        }
        var e = TransitionDirector(seed: 7)
        for _ in 0..<100 {
            let p = e.next(time: 100, intensity: 0.5, energy: 0.5, hasDepth: true, imageInterval: 10)
            #expect(p.duration <= 2.0 + 1e-6, "at most 20 % of a 10 s interval")
        }
    }

    @Test func sameSeedGivesTheSameSequence() {
        var a = TransitionDirector(seed: 1234), b = TransitionDirector(seed: 1234)
        for k in 0..<50 {
            let t = Float(k) * 30
            #expect(a.next(time: t, intensity: 0.6, energy: 0.3, hasDepth: true)
                    == b.next(time: t, intensity: 0.6, energy: 0.3, hasDepth: true))
        }
    }

    @Test func pinnedStyleAndSeed() {
        var d = TransitionDirector(seed: 1)
        d.pinnedStyle = .whirlpool
        d.pinnedSeed = 3
        let p = d.next(time: 0, intensity: 0.5, energy: nil, hasDepth: false)
        #expect(p == TransitionSpec.pinned(.whirlpool, seed: 3))
        #expect(TransitionStyle(name: "Kaleidoscope") == .kaleidoscope)
    }

    @Test func musicChordLandsOnTheSwap() {
        for style in Self.styles {
            let spec = TransitionSpec.pinned(style, seed: 0)
            // The conductor changes chord at half the posted duration.
            let chordAt = Float(spec.musicDuration / 2)
            #expect(abs(chordAt - spec.swapCentre * spec.duration) < 1e-4)
        }
        #expect(TransitionSpec.classic.musicDuration == 1.5)
    }

    @Test func freshHoldIsAnchoredToTheTransitionEnd() {
        // Classic 1.5 s: the judged timings (1.5 / 4.5 / 11).
        let c = EffectLook(intensity: 0.5, imageAge: 4.4, transitionDuration: 1.5)
        #expect(c.fresh() == 0)
        #expect(EffectLook(intensity: 0.5, imageAge: 11.5, transitionDuration: 1.5).fresh() == 1)
        // A 4 s transition still gets ~3 s of clear picture after it.
        #expect(EffectLook(intensity: 0.5, imageAge: 6.9, transitionDuration: 4).fresh() == 0)
        #expect(EffectLook(intensity: 0.5, imageAge: 14, transitionDuration: 4).fresh() == 1)
    }
}
