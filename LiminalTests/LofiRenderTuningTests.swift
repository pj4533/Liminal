import Foundation
import Testing
@testable import Liminal

/// The capture-only render tuning (`tune.*` hooks). The hooks are process-global, so these run serialized.
@Suite(.serialized) struct LofiRenderTuningTests {
    @Test func noHooksIsStandard() throws {
        LofiCaptureHooks.end()
        #expect(LofiRenderTuning.capture() == .standard)
        #expect(try LofiRenderTuning.parse([:]) == .standard)
        #expect(try LofiRenderTuning.parse(["bassTone": "upright", "guitarSlot": "2"]) == .standard)
        #expect(LofiRenderTuning.standard.bass == LofiStemChains.Bass.standard)
        #expect(LofiRenderTuning.standard.isStandard)
        #expect(LofiRenderTuning.standard.report["isStandard"] as? Bool == true)
    }

    @Test func standardBandHelperMatchesTheChain() {
        #expect(LofiStemChains.Bass.saturationBand(lowHz: 200, highHz: 450) == LofiStemChains.Bass.standard.saturationBand)
    }

    @Test func explicitDefaultsAreStandard() throws {
        let tuning = try LofiRenderTuning.parse(["tune.bassSatBand": "200-450", "tune.bassSatMix": "0.15"])
        #expect(tuning == .standard)
        #expect(tuning.isStandard)
    }

    @Test func keysParse() throws {
        let tuning = try LofiRenderTuning.parse(["tune.bassSatBand": "180-700", "tune.bassSatMix": "0.30"])
        #expect(tuning.bass.saturationBand == LofiStemChains.Bass.saturationBand(lowHz: 180, highHz: 700))
        #expect(tuning.bass.saturationMix == 0.30)
        #expect(!tuning.isStandard)
        // Only the two tuned fields move.
        var expected = LofiStemChains.Bass.standard
        expected.saturationBand = tuning.bass.saturationBand
        expected.saturationMix = 0.30
        #expect(tuning.bass == expected)
        #expect(tuning.report["bassSatBand"] as? [Double] == [180, 700])
        #expect(tuning.report["bassSatMix"] as? Double == Double(Float(0.30)))
    }

    @Test(arguments: [
        ("tune.bassSatBand", "450-200"), ("tune.bassSatBand", "50-450"), ("tune.bassSatBand", "200-2500"),
        ("tune.bassSatBand", "200"), ("tune.bassSatBand", "a-b"), ("tune.bassSatBand", "200-200"),
        ("tune.bassSatMix", "0.7"), ("tune.bassSatMix", "-0.1"), ("tune.bassSatMix", "x"), ("tune.bassSatMix", "nan"),
    ])
    func outOfRangeValuesAreRejected(key: String, value: String) {
        #expect(throws: LofiRenderTuning.ParseError.self) { try LofiRenderTuning.parse([key: value]) }
    }

    @Test func unknownTuneKeyIsRejected() {
        #expect(throws: LofiRenderTuning.ParseError.unknownKey("tune.bassSatDrive")) {
            try LofiRenderTuning.parse(["tune.bassSatDrive": "3"])
        }
    }

    @Test func captureReadsHooksAndEndRestoresStandard() throws {
        LofiCaptureHooks.begin(options: ["tune.bassSatMix": "0.3"])
        #expect(LofiRenderTuning.capture().bass.saturationMix == 0.3)
        LofiCaptureHooks.end()
        #expect(LofiRenderTuning.capture() == .standard)
        // Invalid hooks never reach the renderer as a partial tuning.
        LofiCaptureHooks.begin(options: ["tune.bassSatMix": "9"])
        defer { LofiCaptureHooks.end() }
        #expect(LofiRenderTuning.capture() == .standard)
    }

    /// The tuned chain on a bass-like test signal: absent and explicit-default hooks are bit for bit the
    /// standard chain, and a moved band changes the output.
    @Test func absentHooksRenderBitIdentically() throws {
        let rate = 48_000.0
        let count = 48_000
        func signal() -> [Float] {
            (0..<count).map { i in
                let t = Float(i) / Float(rate)
                let env = min(1, t / 0.01) * expf(-t * 1.5)
                return 0.4 * env * (sinf(2 * .pi * 55 * t) + 0.3 * sinf(2 * .pi * 110 * t))
            }
        }
        func render(_ settings: LofiStemChains.Bass) -> [Float] {
            var x = signal()
            x.withUnsafeMutableBufferPointer {
                _ = LofiStemChains.applyBass($0.baseAddress!, count: count, sampleRate: rate, settings: settings)
            }
            return x
        }
        let standard = render(.standard)
        #expect(render(try LofiRenderTuning.parse([:]).bass) == standard)
        #expect(render(try LofiRenderTuning.parse(["tune.bassSatBand": "200-450", "tune.bassSatMix": "0.15"]).bass) == standard)
        #expect(render(try LofiRenderTuning.parse(["tune.bassSatBand": "180-700"]).bass) != standard)
    }
}
