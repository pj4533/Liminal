import Foundation
import Testing
@testable import Liminal

/// The dialogue chops' step grid (D126): each step follows only its own kick or snare.
struct LofiTimingFieldTests {
    private func field(_ items: [(LofiDrumLandmark.Kind, Double, Float)], clock: LofiClock) -> LofiTimingField {
        LofiTimingField(landmarks: items.map { kind, beat, confidence in
            let frame = clock.frame(at: beat)
            return LofiDrumLandmark(kind: kind, attackFrame: frame, peakFrame: frame + 40, strength: 1, confidence: confidence)
        }, clock: clock)
    }

    let clock = LofiClock(tempo: 70, sampleRate: 48_000)

    @Test func aSwungPickupKickMovesItsOwnStepNotTheNextDownbeat() {
        let timing = field([(.kick, 2.873, 0.9)], clock: clock)
        let offsets = timing.sixteenthOffsets()
        #expect(offsets.count == 256)
        // 2.873 is the "a" of beat 2 (step 11), played 0.123 beat late.
        #expect(abs(offsets[11] - 0.123) < 0.002, "step 11 \(offsets[11])")
        // Beat 3 (step 12) has no hit of its own and keeps the straight grid.
        #expect(offsets[12] == 0)
        // The old field snapped beat 3 onto that kick, 0.127 beat early.
        #expect(timing.offset(atBeat: 3) < -0.1)
    }

    @Test func stepsWithoutAHitTakeTheMedianOfTheirPlaceInTheBeat() {
        var items: [(LofiDrumLandmark.Kind, Double, Float)] = []
        for beat in 0..<16 {
            items.append((.kick, Double(beat) + 0.01, 0.9))
            if beat.isMultiple(of: 2) { items.append((.snare, Double(beat) + 0.25 + 0.09, 0.9)) }
        }
        let offsets = field(items, clock: clock).sixteenthOffsets()
        // Odd steps of class 1 without a snare take the class median (0.09).
        #expect(abs(offsets[4 * 3 + 1] - 0.09) < 0.002)
        #expect(abs(offsets[4 * 3] - 0.01) < 0.002)
        // Classes 2 and 3 have no hits: straight.
        #expect(offsets[4 * 5 + 2] == 0 && offsets[4 * 5 + 3] == 0)
    }

    @Test func offsetsAreClampedAndStepTimesStrictlyIncrease() {
        var rng = MusicRNG(seed: 9)
        var items: [(LofiDrumLandmark.Kind, Double, Float)] = []
        for k in 0..<120 {
            items.append((k.isMultiple(of: 3) ? .snare : .kick, rng.range(0...63.9), Float(rng.range(0.4...1))))
        }
        let offsets = field(items, clock: clock).sixteenthOffsets()
        for s in 0..<256 {
            if s.isMultiple(of: 2) { #expect(abs(offsets[s]) <= 0.06 + 1e-9, "step \(s) \(offsets[s])") }
            else { #expect(offsets[s] >= -0.04 - 1e-9 && offsets[s] <= 0.19 + 1e-9, "step \(s) \(offsets[s])") }
            if s > 0 { #expect(Double(s) / 4 + offsets[s] > Double(s - 1) / 4 + offsets[s - 1], "step \(s) not after \(s - 1)") }
        }
    }

    @Test func anEmptyFieldIsStraight() {
        let offsets = field([], clock: clock).sixteenthOffsets()
        #expect(offsets.count == 256 && offsets.allSatisfy { $0 == 0 })
        // Hats and weak hits never shape the grid.
        let weak = field([(.hat, 1.1, 1), (.kick, 2.05, 0.3)], clock: clock).sixteenthOffsets()
        #expect(weak.allSatisfy { $0 == 0 })
    }
}
