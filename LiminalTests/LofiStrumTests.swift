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
        // The scored hook is off, so the hand-made event is the phrase's only strum.
        let audition = LofiScore.Audition(guitarProgram: "Hollowbody Soul", guitarSlot: 2, hook: false)
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

// MARK: - The hook line (D128 stage 4)

extension LofiStrumTests {
    /// One drum condition of the S1-S12 checks: the timing field (nil: none) and its tempo.
    struct DrumCondition {
        let name: String
        let timing: LofiTimingField?
        let beatSeconds: Double
        let seeds: [UInt64]
    }

    struct Scored {
        let seed: UInt64
        let phrase: Int
        let score: LofiScore
        let condition: DrumCondition
        var position: Int { phrase % 4 }
        var start: Int { position * 16 }
    }

    /// A boom-bap take at 72 BPM: kicks on 1 and the "and" of 3 (plus a pickup kick on the "a" of 2 in
    /// odd bars), full snares on 2 and 4, ghost notes on the "a"s, and odd sixteenths 0.08 beat late.
    static func boomBap() -> LofiTimingField {
        let clock = LofiClock(tempo: 72, sampleRate: 48_000)
        var landmarks: [LofiDrumLandmark] = []
        var rng = MusicRNG(seed: 77)
        func add(_ kind: LofiDrumLandmark.Kind, bar: Int, step: Int, strength: Float, confidence: Float) {
            let beat = Double(bar * 4) + Double(step) / 4 + (step.isMultiple(of: 2) ? 0 : 0.08) + rng.range(-0.008...0.008)
            let frame = Int((beat * clock.framesPerBeat).rounded())
            landmarks.append(.init(kind: kind, attackFrame: frame, peakFrame: frame + 40, strength: strength,
                                   confidence: confidence))
        }
        for bar in 0..<16 {
            add(.kick, bar: bar, step: 0, strength: 1, confidence: 0.9)
            add(.kick, bar: bar, step: 10, strength: 0.9, confidence: 0.85)
            if bar % 2 == 1 { add(.kick, bar: bar, step: 7, strength: 0.7, confidence: 0.7) }
            add(.snare, bar: bar, step: 4, strength: 1, confidence: 0.9)
            add(.snare, bar: bar, step: 12, strength: 1, confidence: 0.9)
            if bar % 2 == 0 { add(.snare, bar: bar, step: 7, strength: 0.3, confidence: 0.4) }
            add(.snare, bar: bar, step: 15, strength: 0.28, confidence: 0.35)
        }
        return LofiTimingField(landmarks: landmarks, clock: clock)
    }

    static func conditions(installed: Bool) throws -> [DrumCondition] {
        var out = [DrumCondition(name: "none", timing: nil, beatSeconds: 60.0 / 72, seeds: Array(0..<48)),
                   DrumCondition(name: "boom-bap", timing: boomBap(), beatSeconds: 60.0 / 72, seeds: Array(0..<48))]
        guard installed else { return out }
        for (k, asset) in LofiDrumLibrary.assets().enumerated() {
            let clock = LofiClock(tempo: asset.entry.bpm, sampleRate: asset.entry.sampleRate)
            let take = try LofiDrumTake(recording: try LofiDrumLibrary.load(asset), clock: clock, chain: nil)
            guard !take.landmarks.isEmpty else { continue }
            // Four seeds per take, so every take and every seed is played.
            out.append(.init(name: asset.entry.name, timing: take.timing, beatSeconds: clock.beatDuration,
                             seeds: (0..<4).map { UInt64((k * 4 + $0) % 48) }))
        }
        return out
    }

    static func score(seed: UInt64, phrase: Int, condition: DrumCondition, hook: Bool = true) -> LofiScore {
        LofiScore.make(seed: seed, section: LofiScore.section(at: phrase), drift: .init(seed: seed),
                       startBeat: Double(phrase) * LofiClock.beats, timing: condition.timing,
                       timingStartBeat: (phrase % 4) * 16, beatSeconds: condition.beatSeconds,
                       audition: .init(hook: hook))
    }

    static func scores(_ condition: DrumCondition) -> [Scored] {
        condition.seeds.flatMap { seed in
            (0..<16).map { Scored(seed: seed, phrase: $0, score: score(seed: seed, phrase: $0, condition: condition),
                                  condition: condition) }
        }
    }

    /// A gesture: a stab, dyad, hold or roll; its up-stroke and dead-stroke pickup count with it.
    static func gestures(_ events: [LofiStrum.Event]) -> [LofiStrum.Event] {
        events.filter { $0.kind != .up && $0.kind != .dead }
    }

    /// Drum attack beats read independently of `LofiStrumDrums`: confident kicks, and full snares.
    static func attacks(_ scored: Scored) -> (kicks: [Double], snares: [Double]) {
        guard let timing = scored.condition.timing else {
            let bars = (0..<4).map { Double($0 * 4) }
            return (bars.flatMap { [$0, $0 + 2.5] }, bars.flatMap { [$0 + 1, $0 + 3] })
        }
        let beats = timing.landmarks.map { (landmark: $0, beat: timing.beat(ofFrame: $0.attackFrame) - Double(scored.start)) }
        return (beats.filter { $0.landmark.kind == .kick && $0.landmark.confidence >= 0.5 }.map(\.beat),
                beats.filter { $0.landmark.kind == .snare && $0.landmark.confidence >= 0.5
                    && $0.landmark.strength > DialogueMotifTuning.ghostStrength }.map(\.beat))
    }

    /// Checks S1-S11 on one condition's scores and returns the bar share and string statistics.
    static func checkHook(_ condition: DrumCondition) -> (bars: Int, hookBars: Int, events: [LofiStrum.Event]) {
        let all = scores(condition)
        let offsets = condition.timing?.sixteenthOffsets()
        var hookBars = 0
        var events: [LofiStrum.Event] = []
        for scored in all {
            let score = scored.score
            let strum = score.notes.filter { $0.part == .strum }
            let name = "\(condition.name) seed \(scored.seed) phrase \(scored.phrase)"
            // S1: deterministic.
            #expect(Self.score(seed: scored.seed, phrase: scored.phrase, condition: condition) == score, "\(name)")
            // S2: only strumming programs, never pianos or pizzicato.
            if score.preset.strum == .none {
                #expect(strum.isEmpty && score.strumEvents.isEmpty, "\(name)")
                continue
            }
            // S3: the hook off leaves every other note, the ending rest and the record edit.
            let off = Self.score(seed: scored.seed, phrase: scored.phrase, condition: condition, hook: false)
            #expect(off.notes == score.notes.filter { $0.part != .strum }, "\(name)")
            #expect(off.endingRest == score.endingRest && off.virtualRecord == score.virtualRecord, "\(name)")
            #expect(off.strumEvents.isEmpty)
            let hook = score.strumEvents
            #expect(strum.count == hook.reduce(0) { $0 + $1.strings.count }, "\(name)")
            guard !hook.isEmpty else { continue }
            events += hook
            #expect((1...2).contains(scored.position), "\(name)")
            // S4: 2-5 gestures, at most 2 a bar, bar 3 empty.
            let gestures = Self.gestures(hook)
            #expect((2...5).contains(gestures.count), "\(name) \(gestures.count) gestures")
            let bars = Set(hook.map(\.bar))
            hookBars += bars.count
            #expect(!bars.contains(3) && bars.count <= 3, "\(name)")
            for bar in bars { #expect(gestures.filter { $0.bar == bar }.count <= 2, "\(name)") }
            // S6: voicings.
            let tones = LofiScore.Harmony(tonic: score.tonic, scale: score.scale)
                .notes(for: (score.chordRoot - score.tonic + 12) % 12, intervals: [0, 3, 7, 10, 14])
            let mask = score.scale.pitchClassMask(tonic: score.tonic)
            for event in hook {
                let classes = event.strings.map { $0 % 12 }
                #expect(event.strings == event.strings.sorted(), "\(name)")
                for pitch in event.strings {
                    #expect(mask & (1 << (pitch % 12)) != 0 && (45...72).contains(pitch), "\(name)")
                }
                if [.stab, .dyad, .up, .dead].contains(event.kind) { #expect(event.strings[0] >= 50, "\(name)") }
                for (a, b) in zip(event.strings, event.strings.dropFirst()) { #expect((3...9).contains(b - a), "\(name)") }
                var counts: [Int: Int] = [:]
                for c in classes { counts[c, default: 0] += 1 }
                for (c, n) in counts where n > 1 {
                    #expect(event.strings.count == 5 && n == 2 && (c == tones[0] || c == tones[2]), "\(name)")
                }
                let set = Set(classes)
                #expect(!(set.count == 3 && set.contains { set == [$0, ($0 + 4) % 12, ($0 + 7) % 12] }), "\(name) \(event.strings)")
                if (tones[1] - tones[0] + 12) % 12 == 4, set.contains(tones[1]) {
                    #expect(set.contains(tones[3]) || set.contains(tones[4]), "\(name) \(event.strings)")
                }
                // S5: spread inside the kind's range.
                let range = LofiStrum.Tuning.shape(event.kind).spreadMs
                #expect((range.lowerBound - 1e-9...range.upperBound + 1e-9).contains(event.spreadMs), "\(name)")
                // S7: the drums.
                #expect((1...14).contains(event.step), "\(name)")
                let index = scored.start * 4 + event.bar * 16 + event.step
                let grid = Double(event.bar * 4) + Double(event.step) / 4 + (offsets.map { index < $0.count ? $0[index] : 0 } ?? 0)
                #expect(abs(event.beat - grid) * condition.beatSeconds < 0.001, "\(name)")
                if scored.position == 1 {
                    #expect(event.site == .withKick || event.site == .gap, "\(name)")
                }
            }
            let drums = Self.attacks(scored)
            let beatSeconds = condition.beatSeconds
            for event in hook {
                #expect(drums.snares.allSatisfy { abs($0 - event.beat) * beatSeconds >= 0.040 - 1e-9 }, "\(name) snare")
            }
            for note in strum where note.midi < 52 {
                #expect(drums.kicks.allSatisfy { abs($0 - note.beat) * beatSeconds >= 0.030 - 1e-9 }, "\(name) kick")
            }
            // S8: the scored parts keep their space.
            let lead = score.notes.filter { $0.part == .lead }
            let shells = score.notes.filter { $0.part == .texture && $0.articulation != .pad }
            let ornaments = score.notes.filter { $0.part == .ornament }
            for note in strum {
                #expect(lead.allSatisfy { abs($0.beat - note.beat) >= 0.25 - 1e-9 }, "\(name) lead")
                #expect(shells.allSatisfy { abs($0.beat - note.beat) >= 0.25 - 1e-9 }, "\(name) shell")
                #expect(ornaments.allSatisfy { abs($0.beat - note.beat) >= 0.12 - 1e-9 }, "\(name) ornament")
            }
            for event in hook {
                #expect(lead.filter { Int(($0.beat / 4).rounded(.down)) == event.bar }.count < 3, "\(name) busy bar")
            }
            // S9: exact repeats, one throw on the last event.
            for a in hook {
                for b in hook where a.kind == b.kind && a.length == b.length && a.bar != b.bar {
                    #expect(a.step == b.step && a.strings == b.strings && a.spreadMs == b.spreadMs, "\(name) repeat")
                    #expect(LofiStrum.notes(for: a, tone: 0.4, beatSeconds: 1).map(\.velocity)
                            == LofiStrum.notes(for: b, tone: 0.4, beatSeconds: 1).map(\.velocity))
                }
            }
            let thrown = hook.filter(\.thrown)
            #expect(thrown.count <= 1, "\(name)")
            if let throwEvent = thrown.first {
                #expect(throwEvent == hook.max { $0.beat < $1.beat }, "\(name)")
                #expect(throwEvent.beat <= 10.5 + 1e-9, "\(name)")
            }
            #expect(strum.filter { $0.send >= 0.8 }.count == thrown.first.map { $0.strings.count } ?? 0, "\(name)")
            #expect(strum.allSatisfy { $0.send >= 0.8 || $0.send <= 0.2 })
            // S10: the hook window; position 1 is the thinnest.
            let end = min(12.5, score.endingRest.lowerBound)
            #expect(strum.allSatisfy { $0.beat >= 1 - 1e-9 && $0.beat + $0.length <= end + 1e-9 }, "\(name) window")
            if scored.position == 1 {
                #expect(hook.count <= 2, "\(name)")
                #expect(hook.allSatisfy { $0.kind != .up && $0.kind != .dead && $0.bar <= 2 }, "\(name)")
            }
            // S11: short strokes are choked and short.
            for note in strum where note.damp > 0 {
                #expect((0.015...0.035).contains(note.damp))
            }
            for event in hook where [.stab, .dyad, .up, .dead].contains(event.kind) {
                #expect(event.length <= 0.5 + 1e-9, "\(name)")
            }
            #expect(strum.count <= 28, "\(name)")
            #expect(strum.filter { $0.damp == 0 }.allSatisfy { $0.length > 0.5 }, "\(name) ringing")
        }
        return (all.count * 4, hookBars, events)
    }

    static func checkAmounts(_ name: String, bars: Int, hookBars: Int, events: [LofiStrum.Event]) {
        let share = Double(hookBars) / Double(max(1, bars))
        #expect((0.08...0.22).contains(share), "\(name): \(hookBars) of \(bars) bars")
        let strings = events.map(\.strings.count)
        let threePlus = Double(strings.filter { $0 >= 3 }.count) / Double(max(1, strings.count))
        let mean = Double(strings.reduce(0, +)) / Double(max(1, strings.count))
        let up = Double(events.filter { $0.kind == .up }.count) / Double(max(1, events.count))
        #expect(threePlus >= 0.60, "\(name): \(threePlus) of events with 3+ strings")
        #expect(mean >= 3.0, "\(name): mean strings \(mean)")
        #expect(up <= 0.35, "\(name): up share \(up)")
    }

    /// S12: consecutive takes that both play a hook never play the same archetype.
    static func checkArchetypes(_ condition: DrumCondition) {
        for seed in condition.seeds {
            let takes = (0..<12).map { take in
                Set((0..<4).flatMap { score(seed: seed, phrase: take * 4 + $0, condition: condition).strumEvents.map(\.archetype) })
            }
            for (a, b) in zip(takes, takes.dropFirst()) where !a.isEmpty && !b.isEmpty {
                #expect(a.isDisjoint(with: b), "\(condition.name) seed \(seed): \(a) then \(b)")
            }
        }
    }

    @Test func theHookPlaysOffStraightDrums() throws {
        let condition = try Self.conditions(installed: false)[0]
        let result = Self.checkHook(condition)
        Self.checkAmounts(condition.name, bars: result.bars, hookBars: result.hookBars, events: result.events)
        Self.checkArchetypes(condition)
    }

    @Test func theHookPlaysOffASwungBoomBap() throws {
        let condition = try Self.conditions(installed: false)[1]
        let result = Self.checkHook(condition)
        Self.checkAmounts(condition.name, bars: result.bars, hookBars: result.hookBars, events: result.events)
        Self.checkArchetypes(condition)
        // The swung grid is the drummer's: a hook on an odd sixteenth lands late with the take.
        #expect(result.events.contains { !$0.step.isMultiple(of: 2) })
    }

    @Test(.enabled(if: !LofiDrumLibrary.assets().isEmpty), .responsivePool)
    func theHookPlaysOffEveryInstalledTake() throws {
        var bars = 0, hookBars = 0
        var events: [LofiStrum.Event] = []
        for condition in try Self.conditions(installed: true).dropFirst(2) {
            let result = Self.checkHook(condition)
            bars += result.bars
            hookBars += result.hookBars
            events += result.events
        }
        Self.checkAmounts("installed", bars: bars, hookBars: hookBars, events: events)
    }

    /// Stage 5 tuning (D128): harps roll only in the breakdown, and a hook in take bars 5-8 (the chop
    /// beat) plays at `variationGain` while the breakdown's plays at unity.
    @Test func harpsRollOnlyInTheBreakdownAndTheChopBeatHookIsQuieter() throws {
        var variationHooks = 0
        for condition in try Self.conditions(installed: false) {
            for scored in Self.scores(condition) {
                let strums = scored.score.notes.filter { $0.part == .strum }
                guard !strums.isEmpty else { continue }
                let name = "\(condition.name) seed \(scored.seed) phrase \(scored.phrase)"
                if scored.score.preset.strum == .roll { #expect(scored.position == 2, "\(name)") }
                if scored.position == 1 { variationHooks += 1 }
                let gain: Float = scored.position == 1 ? LofiStrumHook.Tuning.variationGain : 1
                #expect(strums.allSatisfy { $0.gain == gain }, "\(name)")
            }
        }
        #expect(LofiStrumHook.Tuning.harpChance.variation == 0)
        #expect(variationHooks > 0)
    }

    /// Archetype B answers its call: the bar-1 stab is another voicing of the chord (an inversion lower,
    /// or a lower top string when the call sits on the floor), not a repeat of the call.
    @Test func theCallAndAnswerHookAnswersWithAnotherVoicing() throws {
        var statements = 0, repeated = 0
        for condition in try Self.conditions(installed: false) {
            for scored in Self.scores(condition) {
                let events = scored.score.strumEvents
                guard events.first?.archetype == LofiStrumHook.Archetype.callAndAnswer.rawValue,
                      let call = events.first(where: { $0.bar == 0 }), let answer = events.first(where: { $0.bar == 1 })
                else { continue }
                statements += 1
                if answer.strings == call.strings { repeated += 1 }
                #expect(answer.strings.last! <= call.strings.last!, "\(condition.name) seed \(scored.seed) phrase \(scored.phrase)")
            }
        }
        print("STRUM call and answer: \(statements) statements, \(repeated) answers repeat the call")
        #expect(statements > 0)
        #expect(Double(repeated) <= 0.1 * Double(statements))
    }

    @Test func theHookStaysOutOfPianoAndPizzicatoAndCanBeSwitchedOff() {
        let condition = DrumCondition(name: "none", timing: nil, beatSeconds: 60.0 / 72, seeds: [3])
        // A forced guitar in the breakdown always strums; the same phrase without the hook has none.
        let audition = LofiScore.Audition(guitarProgram: "Hollowbody Soul", guitarSlot: 2)
        var played = 0
        for seed in 0..<16 as Range<UInt64> {
            let score = LofiScore.make(seed: seed, section: LofiScore.section(at: 2), drift: .init(seed: seed),
                                       startBeat: 2 * LofiClock.beats, beatSeconds: condition.beatSeconds,
                                       audition: audition)
            #expect(score.preset.name == "Hollowbody Soul")
            if !score.strumEvents.isEmpty { played += 1 }
            var off = audition
            off.hook = false
            let silent = LofiScore.make(seed: seed, section: LofiScore.section(at: 2), drift: .init(seed: seed),
                                        startBeat: 2 * LofiClock.beats, beatSeconds: condition.beatSeconds, audition: off)
            #expect(silent.notes == score.notes.filter { $0.part != .strum })
        }
        #expect(played >= 12)
        let pizz = LofiScore.Audition(pluckProgram: "Pizzicato Viola", guitarSlot: 1)
        for seed in 0..<16 as Range<UInt64> {
            let score = LofiScore.make(seed: seed, section: LofiScore.section(at: 2), drift: .init(seed: seed),
                                       startBeat: 2 * LofiClock.beats, beatSeconds: condition.beatSeconds, audition: pizz)
            #expect(score.preset.name == "Pizzicato Viola")
            #expect(score.notes.allSatisfy { $0.part != .strum })
        }
    }
}
