import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Strum primitives (D128 stage 3): chord voicings from the phrase's harmony, the notes of one
/// strummed event, choked notes in the sampler, and `.strum` notes rendered beside the melody
/// without touching its level.
struct LofiStrumTests {
    private static let scales: [ScaleType] = [.minor, .dorian, .pentatonicMinor]

    /// Every tonic, Lo-Fi scale and both chord degrees a phrase can use (tonic and the reply's fifth).
    private static func chords() -> [(harmony: LofiScore.Harmony, degree: Int)] {
        scales.flatMap { scale in
            (0..<12).flatMap { tonic -> [(harmony: LofiScore.Harmony, degree: Int)] in
                let harmony = LofiScore.Harmony(tonic: tonic, scale: scale)
                return [0, harmony.nearest(5, in: scale.intervals)].map { (harmony, $0) }
            }
        }
    }

    /// The S6 rules, checked independently of `LofiStrumVoicing.isValid`.
    private static func checkRules(_ voicing: [Int], harmony: LofiScore.Harmony, degree: Int, floor: Int,
                                   ceiling: Int, avoid: Int?) {
        let tones = harmony.notes(for: degree, intervals: [0, 3, 7, 10, 14])
        let root = tones[0], third = tones[1], seventh = tones[3], ninth = tones[4]
        let distinct = Set(tones)
        let mask = harmony.scale.pitchClassMask(tonic: harmony.tonic)
        let classes = voicing.map { $0 % 12 }
        for pitch in voicing {
            #expect(mask & (1 << (pitch % 12)) != 0)
            #expect(distinct.contains(pitch % 12))
            #expect((45...72).contains(pitch))
        }
        #expect(voicing.first.map { $0 >= floor } ?? false)
        #expect(voicing.last.map { $0 <= ceiling } ?? false)
        for (low, high) in zip(voicing, voicing.dropFirst()) { #expect((3...9).contains(high - low)) }
        if voicing.count >= 3 {
            #expect(classes.contains(third))
            if distinct.count >= 4 { #expect(classes.contains(seventh)) }
        }
        var counts: [Int: Int] = [:]
        for pitchClass in classes { counts[pitchClass, default: 0] += 1 }
        for (pitchClass, count) in counts where count > 1 {
            #expect(voicing.count == 5 && count == 2 && (pitchClass == root || pitchClass == tones[2]))
        }
        // Never a plain major triad: no bare major-triad spelling, and a major third brings its 7th or 9th.
        let set = Set(classes)
        #expect(!(set.count == 3 && set.contains { set == [$0, ($0 + 4) % 12, ($0 + 7) % 12] }))
        if (third - root + 12) % 12 == 4, set.contains(third) {
            #expect(set.contains(seventh) || set.contains(ninth))
        }
        if let avoid {
            #expect(!voicing.contains(avoid))
            #expect(voicing.last.map { $0 < avoid } ?? false)
        }
    }

    @Test func voicingsKeepEveryChordRule() {
        let windows: [(floor: Int, ceiling: Int, avoid: Int?)] = [
            (50, 72, nil), (45, 72, nil), (50, 67, nil), (45, 64, 67), (50, 72, 70), (45, 62, 65), (50, 72, 61)
        ]
        var built = 0, sevenths = 0, open = 0, missing = 0
        for (harmony, degree) in Self.chords() {
            for strings in 2...5 {
                for window in windows {
                    var rng = MusicRNG(seed: UInt64(harmony.tonic * 31 + degree * 7 + strings))
                    let voicing = LofiStrumVoicing.voicing(harmony: harmony, chordDegree: degree, strings: strings,
                                                           floor: window.floor, ceiling: window.ceiling,
                                                           avoid: window.avoid, random: &rng)
                    if window.avoid == nil && window.ceiling == 72 {
                        // The whole register always has a two- or three-string voicing; a few pentatonic
                        // four-class chords have no four- or five-string one that keeps every rule.
                        open += 1
                        if voicing.isEmpty { missing += 1 }
                        if strings <= 3 { #expect(voicing.count == strings, "\(harmony.scale) \(harmony.tonic) \(degree)") }
                    }
                    guard !voicing.isEmpty else { continue }
                    #expect(voicing.count == strings)
                    Self.checkRules(voicing, harmony: harmony, degree: degree, floor: window.floor,
                                    ceiling: window.ceiling, avoid: window.avoid)
                    built += 1
                    let seventh = harmony.notes(for: degree, intervals: [0, 3, 7, 10, 14])[3]
                    if voicing.contains(where: { $0 % 12 == seventh }) { sevenths += 1 }
                    // Same seed, same voicing.
                    var again = MusicRNG(seed: UInt64(harmony.tonic * 31 + degree * 7 + strings))
                    #expect(LofiStrumVoicing.voicing(harmony: harmony, chordDegree: degree, strings: strings,
                                                     floor: window.floor, ceiling: window.ceiling,
                                                     avoid: window.avoid, random: &again) == voicing)
                }
            }
        }
        #expect(missing * 50 <= open)
        #expect(built > 600)
        #expect(sevenths > built / 2)
    }

    @Test func inversionBelowKeepsTheChordAndMovesDown() {
        var moved = 0
        for (harmony, degree) in Self.chords() {
            for strings in 3...4 {
                var rng = MusicRNG(seed: 11)
                let voicing = LofiStrumVoicing.voicing(harmony: harmony, chordDegree: degree, strings: strings,
                                                       floor: 55, random: &rng)
                let lower = LofiStrumVoicing.inversionBelow(voicing)
                #expect(lower.count == voicing.count)
                #expect(Set(lower.map { $0 % 12 }) == Set(voicing.map { $0 % 12 }))
                guard lower != voicing else { continue }
                moved += 1
                #expect(lower.last! < voicing.last!)
                #expect(lower.first! >= 50)
                for (low, high) in zip(lower, lower.dropFirst()) { #expect((3...9).contains(high - low)) }
            }
        }
        #expect(moved > 40)
    }

    @Test func strumNotesFollowTheirKind() throws {
        let harmony = LofiScore.Harmony(tonic: 9, scale: .minor)
        let beatSeconds = 60.0 / 72
        for kind in LofiStrum.Kind.allCases {
            let shape = LofiStrum.Tuning.shape(kind)
            for strings in shape.strings {
                for down in [true, false] {
                    for thrown in [false, true] {
                        var rng = MusicRNG(seed: UInt64(kind.rawValue * 10 + strings))
                        let voicing = LofiStrumVoicing.voicing(harmony: harmony, chordDegree: 0, strings: strings,
                                                               floor: 50, random: &rng)
                        try #require(voicing.count == strings)
                        let spread = (shape.spreadMs.lowerBound + shape.spreadMs.upperBound) / 2
                        let length = shape.length.upperBound
                        let event = LofiStrum.Event(bar: 1, step: 6, beat: 5.5, kind: kind, down: down, strings: voicing,
                                                    spreadMs: spread, length: length, thrown: thrown, site: .answer,
                                                    archetype: 0)
                        let notes = LofiStrum.notes(for: event, tone: 0.42, beatSeconds: beatSeconds)
                        #expect(notes.count == strings)
                        #expect(notes.allSatisfy { $0.part == .strum })
                        #expect(notes.first?.beat == 5.5)
                        // String order follows the stroke, one spread apart.
                        let step = spread / 1000 / beatSeconds
                        for (a, b) in zip(notes, notes.dropFirst()) {
                            #expect(abs(b.beat - a.beat - step) < 1e-9)
                            #expect(down ? b.midi > a.midi : b.midi < a.midi)
                        }
                        // Every string stops together; the summed power is the event's level.
                        #expect(notes.allSatisfy { abs($0.beat + $0.length - (5.5 + length)) < 1e-9 })
                        let power = sqrtf(notes.reduce(0) { $0 + $1.velocity * $1.velocity })
                        #expect(abs(power - shape.level) <= 0.05 * shape.level, "\(kind) \(strings) \(down)")
                        // Down-strokes lean on the low strings, up-strokes on the high ones.
                        let low = notes.min { $0.midi < $1.midi }!, high = notes.max { $0.midi < $1.midi }!
                        #expect(down ? low.velocity > high.velocity : high.velocity > low.velocity)
                        #expect(notes.allSatisfy { $0.send == (thrown ? 0.90 : 0.10) && $0.gain == 1 })
                        #expect(notes.allSatisfy { $0.damp == shape.damp })
                        if kind == .dead {
                            #expect(notes.allSatisfy { $0.color == 0 })
                        } else {
                            #expect(notes.allSatisfy { abs($0.color - (0.42 + shape.color)) < 1e-9 })
                        }
                    }
                }
            }
            // S11: short strokes are choked and at most half a beat long; holds and rolls ring.
            switch kind {
            case .stab, .dyad, .up, .dead:
                #expect(shape.length.upperBound <= 0.5)
                #expect((0.015...0.035).contains(shape.damp))
            case .hold, .roll:
                #expect(shape.damp == 0)
            }
        }
        // The table's spread ranges (plan 2.3).
        #expect(LofiStrum.Tuning.stab.spreadMs == 6...11)
        #expect(LofiStrum.Tuning.roll.spreadMs == 40...70)
        #expect(LofiStrum.Tuning.hold.spreadMs == 18...30)
    }

    @Test func aDampedNoteIsChokedAfterItsHold() throws {
        let preset = try #require(LofiPreset.guitar(named: "Hollowbody Soul"))
        let bank = LofiSampleBank.bundled
        let sample = try #require(bank.sample(for: preset, midi: 57, velocity: 0.4))
        let clock = LofiClock(tempo: 72, sampleRate: 48_000)
        func render(damp: Double) -> [Float] {
            var left = [Float](repeating: 0, count: clock.frameCount), right = left
            var note = LofiScore.Note(part: .strum, midi: 57, beat: 1, length: 0.25, velocity: 0.4)
            note.damp = damp
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    LofiSampleBank.add(note, from: sample, preset: preset, clock: clock, left: l, right: r)
                }
            }
            return left
        }
        let after = clock.frame(at: 1) + clock.frame(at: 0.25) + Int(0.040 * clock.sampleRate)
        let damped = render(damp: 0.025), ringing = render(damp: 0)
        #expect(damped[clock.frame(at: 1)...].contains { abs($0) > 1e-3 })
        #expect(damped[after...].allSatisfy { $0 == 0 })
        #expect(ringing[after...].contains { abs($0) > 1e-4 })
    }

    @Test func aStrumRendersBesideTheMelodyWithoutMovingIt() throws {
        let audition = LofiScore.Audition(guitarProgram: "Hollowbody Soul", guitarSlot: 2)
        let tempo = 72.0, rate = 32_000.0
        func render(_ revise: ((LofiScore) -> LofiScore)?) throws -> LofiRenderer.Phrase {
            try LofiRenderer.render(seed: 1042, section: LofiScore.section(at: 2), options: .init(tempo: tempo),
                                    sampleRate: rate, drift: .init(seed: 1042), startBeat: 2 * LofiClock.beats,
                                    audition: audition, revise: revise)
        }
        let off = try render(nil)
        #expect(off.score.preset.name == "Hollowbody Soul")
        let harmony = LofiScore.Harmony(tonic: off.score.tonic, scale: off.score.scale)
        var rng = MusicRNG(seed: 5)
        let degree = (off.score.chordRoot - off.score.tonic + 12) % 12
        let voicing = LofiStrumVoicing.voicing(harmony: harmony, chordDegree: degree, strings: 3, floor: 50,
                                               ceiling: 67, random: &rng)
        try #require(voicing.count == 3)
        let event = LofiStrum.Event(bar: 1, step: 6, beat: 5.5, kind: .stab, down: true, strings: voicing,
                                    spreadMs: 8, length: 0.25, thrown: true, site: .answer, archetype: 0)
        let on = try render { $0.addingStrum([event], tone: 0.42, beatSeconds: 60 / tempo) }
        #expect(on.score.notes.filter { $0.part == .strum }.count == 3)
        #expect(on.score.strumEvents == [event])
        #expect(on.score.notes.filter { $0.part != .strum } == off.score.notes)
        // The melody's gain is measured without the strum.
        #expect(on.leadGain == off.leadGain)

        let dryOn = try #require(on.dry.floatChannelData), dryOff = try #require(off.dry.floatChannelData)
        let clock = on.clock
        let start = clock.frame(at: event.beat)
        let end = clock.frame(at: event.beat + event.length) + Int(0.025 * rate) + Int(0.25 * rate)
        var peak: Float = 0, outside: Float = 0, inside: Float = 0
        for channel in 0..<2 {
            for frame in 0..<clock.frameCount {
                let a = dryOn[channel][frame] / on.instrumentTrim, b = dryOff[channel][frame] / off.instrumentTrim
                peak = max(peak, abs(b))
                if frame >= start && frame < end {
                    inside = max(inside, abs(a - b))
                } else {
                    outside = max(outside, abs(a - b))
                }
            }
        }
        #expect(peak > 0.01)
        #expect(inside > 0.002 * peak)
        #expect(outside <= 1e-5 * peak, "outside \(outside) peak \(peak)")
    }
}
