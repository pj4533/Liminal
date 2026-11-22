import Testing
import Foundation
@testable import Liminal

/// Music -> visuals coupling checks (docs/plans/av-coupling.md section 5): the uniforms' caps under
/// extreme modulation, the neutral modulation, and the reactor without music. Fast, no audio.
@MainActor
struct AVCouplingTests {

    @Test func capsHoldUnderExtremeInputs() {
        var m = MusicModulation()
        m.amount = 10; m.energy = 1; m.pulseColor = 1; m.pulseMotion = 1; m.shimmer = 1; m.air = 1; m.ghostReach = 1
        for t in stride(from: Float(0), to: 2000, by: 7.3) {
            let u = EffectsUniformsComputer.compute(time: t, music: m)
            #expect(u.bloomAmount <= 0.72 + 1e-6)
            #expect(u.vibranceAmount <= 0.50 + 1e-6)
            // Feedback mix moves at most 0.04 from its look base (0.25...0.30 at the default intensity).
            #expect(u.feedbackMix >= 0.21 - 1e-6 && u.feedbackMix <= 0.34 + 1e-6)
            #expect(u.feedbackWarpAmount <= 0.04 + 1e-6)
            #expect(u.ghostTapMaxDistance <= 0.08 + 1e-6)
            #expect(u.distortionAmplitude <= 0.10 + 1e-6)
            #expect(u.chromaticAmount <= 0.02 + 1e-6)
            #expect(u.logSphereAmount <= 0.020 + 1e-6)
            #expect(u.fractalNoiseAmount <= 0.036 + 1e-6)
        }
    }

    @Test func neutralMatchesUncoupled() {
        for t in stride(from: Float(0), to: 1000, by: 13.7) {
            let a = EffectsUniformsComputer.compute(time: t, transitionProgress: 0.3)
            let b = EffectsUniformsComputer.compute(time: t, transitionProgress: 0.3, music: .neutral)
            #expect(Self.fields(a) == Self.fields(b))
        }
    }

    @Test func reactorOffWithoutMusic() {
        // Bus never started (now = 0): amount stays 0 and visionOS (base rate 0) gets hue 0.
        var r = MusicReactor()
        var m = MusicModulation.neutral
        for i in 0..<900 { m = r.update(state: MusicState(), now: 0, effectTime: Float(i) / 90, enabled: true, baseHueRate: 0) }
        #expect(m.amount == 0 && m.hueBaseShift == 0 && m.motionLead == 0 && m.ghostBurstSerial == 0)
    }

    @Test func fifthsMapping() {
        #expect(MusicReactor.fifths(0) == 0)
        #expect(MusicReactor.fifths(7) == 1)
        #expect(MusicReactor.fifths(5) == -1)
        #expect(MusicReactor.fifths(6) == 6)
        #expect((0..<12).map(MusicReactor.fifths).allSatisfy { $0 >= -5 && $0 <= 6 })
    }

    // MARK: Helpers

    static func fields(_ u: EffectsUniforms) -> [Float] {
        [u.kenBurnsScale, u.kenBurnsOffsetX, u.kenBurnsOffsetY, u.distortionAmplitude, u.distortionSpeed, u.hueBaseShift,
         u.hueWaveIntensity, u.hueBlendAmount, u.ghostTapMaxDistance, u.chromaticAmount, u.feedbackWarpAmount, u.feedbackMix,
         u.bloomAmount, u.logSphereAmount, u.fractalNoiseAmount, u.fractalHueAmount, u.vibranceAmount, u.blackPoint, u.tunnelStrength]
    }
}
