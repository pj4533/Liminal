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

    /// The cue layer's keys (D129): `tune.bassCueDb` turns it on at a level or `off`; the shape keys
    /// edit it.
    @Test func cueKeysParse() throws {
        let tuning = try LofiRenderTuning.parse([
            "tune.bassCueDb": "-13", "tune.bassCueBand": "200-350", "tune.bassCueSlopeDb": "5",
            "tune.bassCueOnsetMs": "60", "tune.bassCueSynthDb": "-6",
        ])
        let cue = try #require(tuning.bassCue)
        #expect(cue == LofiBassVoice.Cue(levelDB: -13, lowHz: 200, highHz: 350, slopeDB: 5, onset: 0.06, synthOffsetDB: -6))
        #expect(tuning.bass == LofiStemChains.Bass.standard)
        let report = try #require(tuning.report["bassCue"] as? [String: Any])
        #expect(report["levelDb"] as? Double == -13)
        #expect(report["band"] as? [Double] == [200, 350])
        #expect(try LofiRenderTuning.parse(["tune.bassCueDb": "off", "tune.bassCueSlopeDb": "6"]).bassCue == nil)
        #expect(try LofiRenderTuning.parse(["tune.bassCueDb": "OFF"]).report["bassCue"] as? String == "off")
        // Phase alignment to the body (on by default), and the round-2 sine phase.
        #expect(try LofiRenderTuning.parse(["tune.bassCueDb": "-15"]).bassCue?.alignToTone == true)
        let sine = try LofiRenderTuning.parse(["tune.bassCueDb": "-15", "tune.bassCueAlign": "off"])
        #expect(sine.bassCue?.alignToTone == false)
        #expect((sine.report["bassCue"] as? [String: Any])?["align"] as? Bool == false)
        #expect(throws: LofiRenderTuning.ParseError.self) {
            try LofiRenderTuning.parse(["tune.bassCueDb": "-15", "tune.bassCueAlign": "maybe"])
        }
        // The judged values (D129) are the cue's own defaults.
        let judged = try LofiRenderTuning.parse([
            "tune.bassCueDb": "-15", "tune.bassCueBand": "180-300", "tune.bassCueSlopeDb": "4",
            "tune.bassCueOnsetMs": "90", "tune.bassCueSynthDb": "-4",
        ])
        #expect(judged.bassCue == .standard)
        // Shape keys alone change the cue only when it plays by default.
        let shaped = try LofiRenderTuning.parse(["tune.bassCueSlopeDb": "6"])
        if LofiRenderTuning.defaultBassCue == nil {
            #expect(shaped.bassCue == nil)
        } else {
            #expect(shaped.bassCue?.slopeDB == 6)
        }
    }

    @Test func cueDuckKeyParses() throws {
        let both = try #require(try LofiRenderTuning.parse(["tune.cueDuck": "texture+wet:180-450:3"]).cueDuck)
        #expect(both == .standard)
        let wet = try #require(try LofiRenderTuning.parse(["tune.cueDuck": "wet:200-400:2"]).cueDuck)
        #expect(!wet.texture && wet.wet && wet.lowHz == 200 && wet.highHz == 400 && wet.maxDB == 2)
        let texture = try #require(try LofiRenderTuning.parse(["tune.cueDuck": "texture:180-450:3"]).cueDuck)
        #expect(texture.texture && !texture.wet)
        let off = try LofiRenderTuning.parse(["tune.cueDuck": "off"])
        #expect(off.cueDuck == nil)
        #expect(off.report["cueDuck"] as? String == "off")
        let report = try #require(try LofiRenderTuning.parse(["tune.cueDuck": "texture+wet:180-450:3"]).report["cueDuck"] as? [String: Any])
        #expect(report["sources"] as? [String] == ["texture", "wet"])
        #expect(report["maxDb"] as? Double == 3)
    }

    @Test(arguments: [
        ("tune.bassCueDb", "5"), ("tune.bassCueDb", "-41"), ("tune.bassCueDb", "loud"),
        ("tune.bassCueBand", "300-180"), ("tune.bassCueBand", "90-300"), ("tune.bassCueSlopeDb", "13"),
        ("tune.bassCueOnsetMs", "-1"), ("tune.bassCueOnsetMs", "600"), ("tune.bassCueSynthDb", "-30"),
        ("tune.cueDuck", "drums:180-450:3"), ("tune.cueDuck", "texture:180-450"), ("tune.cueDuck", "wet:450-180:3"),
        ("tune.cueDuck", "wet:180-450:13"), ("tune.cueDuck", ":180-450:3"), ("tune.cueDuck", "texture+chops:180-450:3"),
    ])
    func outOfRangeCueValuesAreRejected(key: String, value: String) {
        #expect(throws: LofiRenderTuning.ParseError.self) { try LofiRenderTuning.parse([key: value]) }
    }

    /// The app's tuning is the defaults; `off` hooks render the pre-D129 bass and texture/return.
    @Test func offHooksAreThePreviousBehaviour() throws {
        let off = try LofiRenderTuning.parse(["tune.bassCueDb": "off", "tune.cueDuck": "off"])
        #expect(off.bassCue == nil && off.cueDuck == nil && off.bass == .standard)
        #expect(LofiRenderTuning.standard.bassCue == LofiRenderTuning.defaultBassCue)
        #expect(LofiRenderTuning.standard.cueDuck == LofiRenderTuning.defaultCueDuck)
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
