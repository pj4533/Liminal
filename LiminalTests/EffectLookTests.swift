import Testing
import Foundation
@testable import Liminal

/// Effects balance (docs/plans/effects-balance.md 7.4): golden parity with scripts/fx_model.py
/// `proposed()`, the recognisability budget, monotonic intensity, a slow and bounded clarity cycle.
@MainActor
struct EffectLookTests {

    struct G {
        let time: Float, intensity: Float, age: Float?, tp: Float, drive: Float
        let values: [Float]
    }

    /// `python3 scripts/fx_model.py golden` (regenerate both when the numbers are retuned).
    /// Order: kenBurnsScale, kenBurnsOffsetX, kenBurnsOffsetY, distortionAmplitude, logSphereAmount,
    /// fractalNoiseAmount, chromaticAmount, fractalHueAmount, hueBlendAmount, hueWaveIntensity, feedbackMix, bloomAmount.
    static let golden: [G] = [
        G(time: 0, intensity: 0.5, age: nil, tp: 0, drive: 0.000000,
          values: [1.180000, 0.000000, 0.800000, 0.028000, 0.000000, 0.000000, 0.009000, 0.112500, 0.270000, 0.060000, 0.250000, 0.500000]),
        G(time: 100, intensity: 0.5, age: 25.0, tp: 0, drive: 1.000000,
          values: [1.062827, -0.334387, -0.645103, 0.052510, 0.009408, 0.006553, 0.007502, 0.227896, 0.382368, 0.102634, 0.300000, 0.500000]),
        G(time: 100, intensity: 0, age: 25.0, tp: 0, drive: 1.000000,
          values: [1.089752, -0.334387, -0.645103, 0.014902, 0.000000, 0.000000, 0.002308, 0.068369, 0.147065, 0.018328, 0.140000, 0.300000]),
        G(time: 100, intensity: 0.25, age: 25.0, tp: 0, drive: 1.000000,
          values: [1.076290, -0.334387, -0.645103, 0.033706, 0.004704, 0.003277, 0.004905, 0.148132, 0.264716, 0.060481, 0.220000, 0.400000]),
        G(time: 100, intensity: 1, age: 25.0, tp: 0, drive: 1.000000,
          values: [1.035901, -0.334387, -0.645103, 0.065412, 0.017106, 0.013107, 0.009233, 0.262080, 0.400016, 0.146621, 0.340000, 0.500000]),
        G(time: 190, intensity: 0.5, age: 9.0, tp: 0, drive: 0.376678,
          values: [1.128498, 0.380893, 0.401891, 0.035923, 0.000000, 0.001858, 0.010533, 0.086834, 0.326183, 0.085991, 0.268834, 0.500000]),
        G(time: 330, intensity: 0.5, age: 3.0, tp: 0, drive: 0.000000,
          values: [1.090520, 0.539765, 0.505920, 0.028000, 0.000000, 0.000000, 0.006782, 0.106877, 0.283880, 0.066406, 0.250000, 0.500000]),
        G(time: 540, intensity: 1, age: 12.0, tp: 0, drive: 1.000000,
          values: [1.102696, 0.389507, 0.560371, 0.066020, 0.013132, 0.012464, 0.006729, 0.137961, 0.426876, 0.152269, 0.340000, 0.500000]),
        G(time: 600, intensity: 0.5, age: 7.0, tp: 0, drive: 0.329995,
          values: [1.035810, -0.413289, -0.159867, 0.037008, 0.000000, 0.001008, 0.004260, 0.089082, 0.313576, 0.079727, 0.266500, 0.500000]),
        G(time: 600, intensity: 0.5, age: 0.75, tp: 0.5, drive: 0.500000,
          values: [1.035810, -0.413289, -0.159867, 0.201649, 0.006231, 0.024184, 0.017829, 0.093630, 0.341197, 0.092277, 0.275000, 0.500000]),
        G(time: 760, intensity: 0.75, age: 22.0, tp: 0, drive: 0.000000,
          values: [1.180697, -0.480006, -0.112736, 0.032000, 0.000000, 0.000000, 0.004377, 0.142574, 0.316272, 0.087463, 0.280000, 0.500000]),
        G(time: 2000, intensity: 0.5, age: 15.0, tp: 0, drive: 0.000620,
          values: [1.117149, -0.648808, 0.246604, 0.028012, 0.000000, 0.000000, 0.009531, 0.138821, 0.221367, 0.037546, 0.250031, 0.500000]),
    ]

    static func values(_ u: EffectsUniforms) -> [Float] {
        [u.kenBurnsScale, u.kenBurnsOffsetX, u.kenBurnsOffsetY, u.distortionAmplitude, u.logSphereAmount,
         u.fractalNoiseAmount, u.chromaticAmount, u.fractalHueAmount, u.hueBlendAmount, u.hueWaveIntensity,
         u.feedbackMix, u.bloomAmount]
    }

    static func strain(_ u: EffectsUniforms) -> Float {
        EffectLook.strainLoad(distortion: u.distortionAmplitude, logSphere: u.logSphereAmount, noise: u.fractalNoiseAmount)
    }

    @Test func goldenParityWithModel() {
        for g in Self.golden {
            let look = EffectLook(intensity: g.intensity, imageAge: g.age)
            #expect(abs(look.drive(time: g.time) - g.drive) < 1e-4, "drive at t=\(g.time)")
            let u = EffectsUniformsComputer.compute(time: g.time, transitionProgress: g.tp, look: look)
            for (k, (got, want)) in zip(Self.values(u), g.values).enumerated() {
                #expect(abs(got - want) < 1e-4, "t=\(g.time) I=\(g.intensity) field \(k): \(got) vs \(want)")
            }
        }
    }

    @Test func budgetAndCapsHoldForRandomInputs() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<10_000 {
            let t = Float.random(in: 0...7200, using: &rng)
            let i = Float.random(in: 0...1, using: &rng)
            let age: Float? = Bool.random(using: &rng) ? nil : Float.random(in: 0...60, using: &rng)
            var m = MusicModulation()
            m.amount = Float.random(in: 0...3, using: &rng); m.energy = Float.random(in: 0...1, using: &rng)
            m.pulseColor = Float.random(in: 0...1, using: &rng); m.pulseMotion = Float.random(in: 0...1, using: &rng)
            m.shimmer = Float.random(in: 0...1, using: &rng); m.air = Float.random(in: 0...1, using: &rng)
            m.ghostReach = Float.random(in: 0...1, using: &rng)
            let u = EffectsUniformsComputer.compute(time: t, music: m, look: EffectLook(intensity: i, imageAge: age))
            #expect(Self.strain(u) <= EffectLook.strainBudget(i) + 1e-4, "budget at t=\(t) I=\(i)")
            #expect(u.distortionAmplitude <= 0.10 + 1e-6 && u.distortionAmplitude >= 0)
            #expect(u.logSphereAmount <= 0.020 + 1e-6 && u.logSphereAmount >= 0)
            #expect(u.fractalNoiseAmount <= 0.036 + 1e-6 && u.fractalNoiseAmount >= 0)
            #expect(u.chromaticAmount <= 0.02 + 1e-6)
            #expect(u.feedbackMix <= 0.34 + 1e-6 && u.feedbackMix >= 0.06 - 1e-6)
            #expect(u.bloomAmount <= 0.72 + 1e-6)
            #expect(u.hueWaveIntensity <= 0.20 + 1e-6 && u.hueBlendAmount <= 0.68 + 1e-6)
            #expect(u.hueWaveIntensity * u.hueBlendAmount <= 0.065 + 1e-5, "stacked rainbow at t=\(t) I=\(i)")
            let finite = AVCouplingTests.fields(u).allSatisfy { $0.isFinite }
            #expect(finite)
        }
    }

    @Test func strainRisesWithIntensity() {
        let steps: [Float] = [0, 0.25, 0.5, 0.75, 1]
        for t in stride(from: Float(0), to: 1800, by: 3.7) {
            for age: Float? in [nil, 2, 6, 20] {
                var last: Float = -1
                for i in steps {
                    let s = Self.strain(EffectsUniformsComputer.compute(time: t, look: EffectLook(intensity: i, imageAge: age)))
                    #expect(s >= last - 1e-6, "strain fell at t=\(t) I=\(i)")
                    last = s
                }
            }
        }
    }

    @Test func clarityCycleIsBoundedAndSlow() {
        // Drive in 0...1, changes at most ~0.031/s (clear -> wild takes >= 30 s), and both clear and wild
        // stretches occur at the default.
        var prev = EffectLook.macroDrive(time: 0, intensity: 0.5)
        var maxRate: Float = 0, clear = 0, wild = 0, n = 0
        for k in 1...36_000 {  // 1 h at 0.1 s
            let t = Float(k) * 0.1
            let d = EffectLook.macroDrive(time: t, intensity: 0.5)
            #expect(d >= 0 && d <= 1)
            maxRate = max(maxRate, abs(d - prev) / 0.1)
            prev = d
            n += 1
            if d < 0.15 { clear += 1 }
            if d > 0.7 { wild += 1 }
        }
        #expect(maxRate < 0.035, "max drive rate \(maxRate)/s")
        #expect(Double(clear) / Double(n) > 0.25, "clear share \(clear)/\(n)")
        #expect(Double(wild) / Double(n) > 0.15 && Double(wild) / Double(n) < 0.5, "wild share \(wild)/\(n)")
        // A session starts clear.
        #expect(EffectLook.macroDrive(time: 0, intensity: 0.5) < 0.05)
    }

    @Test func freshImageIsHeldClear() {
        for age: Float in [1.5, 2.5, 4.0] {
            #expect(EffectLook(intensity: 1, imageAge: age).fresh() < 0.01)
        }
        #expect(EffectLook(intensity: 1, imageAge: 0).fresh() == 1)
        #expect(EffectLook(intensity: 1, imageAge: 11).fresh() > 0.999)
        #expect(EffectLook(intensity: 1, imageAge: nil).fresh() == 1)
    }

    @Test func wildStretchesZoomOut() {
        // E27: the Ken Burns zoom eases back by up to 60 % of (scale - 1) at I = 1 in wild stretches,
        // never zooms in past the plain Ken Burns, and does nothing at I = 0.
        for t in stride(from: Float(0), to: 1800, by: 2.9) {
            let plain = EffectsUniformsComputer.computeKenBurns(time: t).scale
            for i: Float in [0, 0.5, 1] {
                let s = EffectsUniformsComputer.compute(time: t, look: EffectLook(intensity: i)).kenBurnsScale
                let d = EffectLook.macroDrive(time: t, intensity: i)
                #expect(s <= plain + 1e-6 && s >= 1)
                if i == 0 { #expect(abs(s - plain) < 1e-6) }
                if i == 1 && d > 0.99 { #expect(s - 1 <= (plain - 1) * 0.41 + 1e-4) }
            }
        }
    }

    @Test func noPopsAtFullIntensity() {
        // Max step per 1/90 s of every uniform (time aside) below 0.002, with images every 30 s.
        // The first 1.5 s of each image are the crossfade, where the fade to clear hides under the
        // transition melt (which itself moves much faster); they are skipped.
        var prev: [Float]?
        var worst: Float = 0
        for k in 0...(900 * 90) {
            let t = Float(k) / 90
            let age = t.truncatingRemainder(dividingBy: 30)
            let look = EffectLook(intensity: 1, imageAge: age)
            let f = AVCouplingTests.fields(EffectsUniformsComputer.compute(time: t, look: look))
            if let p = prev, age >= 1.5 + 1.0 / 90 { worst = max(worst, zip(f, p).map { abs($0 - $1) }.max() ?? 0) }
            prev = f
        }
        #expect(worst < 0.002, "max step \(worst)")
    }

    @Test func zeroIntensityHasNoRadialOrNoise() {
        for t in stride(from: Float(0), to: 3600, by: 11.3) {
            let u = EffectsUniformsComputer.compute(time: t, look: EffectLook(intensity: 0))
            #expect(u.logSphereAmount == 0 && u.fractalNoiseAmount == 0)
            #expect(Self.strain(u) <= 0.30 + 1e-4)
        }
    }

    @Test func smootherEasesAndSnaps() {
        var s = EffectIntensitySmoother()
        #expect(s.next(target: 0.2, time: 10) == 0.2)
        let v = s.next(target: 1, time: 10.1)
        #expect(v > 0.2 && v < 0.5)
        #expect(s.next(target: 1, time: 10.1) == v)       // same frame twice
        #expect(s.next(target: 0.7, time: 0) == 0.7)      // clock restart snaps
    }
}
