import Accelerate
import Foundation
import Testing
@testable import Liminal

/// The riddim bass line of plan 2.5: density, rests, stroke mix and pitch shares, the two-bar cell and
/// its repeat, one cell per take, kick safety, drop-outs and throws.
@Suite(.serialized)
struct LofiBassLineTests {
    static let clock = LofiClock(tempo: 72, sampleRate: 48_000)

    static func score(_ phrase: Int, seed: UInt64, timing: LofiTimingField? = nil,
                      clock: LofiClock = Self.clock) -> LofiScore {
        .make(seed: seed, section: LofiScore.section(at: phrase), drift: .init(seed: seed),
              startBeat: Double(phrase) * LofiClock.beats, timing: timing,
              timingStartBeat: (phrase % LofiDrumTake.phraseCount) * Int(LofiClock.beats), beatSeconds: clock.beatDuration)
    }

    static func bass(_ score: LofiScore) -> [LofiScore.Note] { score.notes.filter { $0.part == .bass } }

    /// A boom-bap take of 64 beats: kicks on 1, the "and of 2" and 3 of each bar, a pickup kick in every
    /// second bar, snares on 2 and 4, a few ghosts, with seeded human timing (up to 0.04 beats).
    static func take(seed: UInt64, clock: LofiClock = Self.clock) -> LofiTimingField {
        var r = MusicRNG(seed: seed).fork(99)
        var marks: [LofiDrumLandmark] = []
        for bar in 0..<16 {
            let base = Double(bar * 4)
            var kicks = [0, 1.5, 2.5]
            if bar % 2 == 1 { kicks.append(3.75) }
            for k in kicks {
                let beat = base + k + r.range(-0.03...0.04)
                let frame = Int((beat * clock.framesPerBeat).rounded())
                marks.append(LofiDrumLandmark(kind: .kick, attackFrame: frame, peakFrame: frame + 240, strength: 1,
                                              confidence: r.rangeF(0.65...1), lowRiseFrame: frame + 300))
            }
            for s in [1.0, 3.0] {
                let frame = Int(((base + s + r.range(-0.02...0.02)) * clock.framesPerBeat).rounded())
                marks.append(LofiDrumLandmark(kind: .snare, attackFrame: frame, peakFrame: frame + 100, strength: 1,
                                              confidence: 0.9))
            }
            let ghost = Int(((base + 2.25) * clock.framesPerBeat).rounded())
            marks.append(LofiDrumLandmark(kind: .kick, attackFrame: ghost, peakFrame: ghost + 200, strength: 0.2,
                                          confidence: 0.3))
        }
        return LofiTimingField(landmarks: marks, clock: clock)
    }

    static func release(_ note: LofiScore.Note, _ score: LofiScore, clock: LofiClock = Self.clock) -> Double {
        score.bassVoice.release(note.stroke) / clock.beatDuration
    }

    // MARK: Density, rests, stroke mix and pitch

    @Test func densityRestsStrokeMixAndPitchSharesMeetThePlan() {
        var strokes: [LofiScore.BassStroke: Int] = [:]
        var degrees: [String: Int] = [:]
        var total = 0
        var sounding: [Double] = []
        for seed in 0..<100 as Range<UInt64> {
            let timing = seed.isMultiple(of: 2) ? Self.take(seed: seed) : nil
            for phrase in 0..<8 {
                let current = Self.score(phrase, seed: seed, timing: timing)
                let notes = Self.bass(current)
                let bars = (0..<4).map { bar in notes.filter { LofiScore.bassBar($0.beat) == bar } }
                let counts = bars.map(\.count)
                let label = "seed \(seed) phrase \(phrase) \(current.section) bars \(counts) " + notes.map { "\(String(format: "%.2f", $0.beat))\(String(describing: $0.stroke).prefix(1))" }.joined(separator: " ")
                switch current.section {
                case .theme, .variation, .returnTheme:
                    #expect(counts.allSatisfy { (3...5).contains($0) }, "\(label)")
                case .answer:
                    #expect(counts.prefix(2).allSatisfy { (3...5).contains($0) }, "\(label)")
                    #expect(counts.suffix(2).allSatisfy { (2...3).contains($0) }, "\(label)")
                case .breakdown:
                    #expect(counts.prefix(3).allSatisfy { (1...2).contains($0) }, "\(label)")
                    #expect(counts[3] <= 2, "\(label)")
                }
                for bar in bars { #expect(bar.reduce(0) { $0 + $1.length } <= 2.6 + 1e-9, "\(label) bar sounding") }
                let phraseSounding = notes.reduce(0) { $0 + $1.length }
                if [.theme, .variation, .returnTheme].contains(current.section) {
                    sounding.append(phraseSounding)
                    #expect((6.5 - 1e-9...9.5 + 1e-9).contains(phraseSounding), "\(label) sounding \(phraseSounding)")
                }
                #expect(notes.filter { $0.stroke == .ghost }.count <= 2)
                for note in notes { strokes[note.stroke, default: 0] += 1 }
                guard current.section != .answer else { continue }
                let tonic = current.tonic
                for note in notes {
                    let interval = ((note.midi - tonic) % 12 + 12) % 12
                    let name = note.midi > 41 ? (interval == 0 ? "octave" : "high") :
                        (interval == 0 ? "root" : (interval == 7 || interval == 6 || interval == 8 ? "fifth" : "other"))
                    degrees[name, default: 0] += 1
                    total += 1
                }
            }
        }
        let all = Double(strokes.values.reduce(0, +))
        func share(_ s: LofiScore.BassStroke) -> Double { Double(strokes[s, default: 0]) / all }
        func pitchShare(_ s: String) -> Double { Double(degrees[s, default: 0]) / Double(total) }
        BassReport.log(String(format: "BASSLINE strokes thump %.2f walk %.2f hold %.2f ghost %.2f; root %.2f fifth %.2f octave %.2f other %.2f high %.2f; sounding mean %.2f min %.2f max %.2f",
                     share(.thump), share(.walk), share(.hold), share(.ghost), pitchShare("root"), pitchShare("fifth"),
                     pitchShare("octave"), pitchShare("other"), pitchShare("high"),
                     sounding.reduce(0, +) / Double(sounding.count), sounding.min() ?? 0, sounding.max() ?? 0))
        #expect((0.35...0.65).contains(share(.thump)))
        #expect((0.15...0.45).contains(share(.walk)))
        #expect((0.08...0.30).contains(share(.hold)))
        #expect((0.42...0.60).contains(pitchShare("root")))
        #expect((0.15...0.30).contains(pitchShare("fifth")))
        #expect(pitchShare("octave") <= 0.10)
        #expect(pitchShare("other") + pitchShare("high") <= 0.22)
    }

    // MARK: Cell

    /// Bars 3-4 repeat bars 1-2 (same pitches, offsets and strokes), except in bar 4.
    @Test func barsThreeAndFourRepeatTheCellExceptBarFour() {
        for seed in 0..<100 as Range<UInt64> {
            for phrase in [0, 1, 4] {
                let notes = Self.bass(Self.score(phrase, seed: seed))
                let first = notes.filter { $0.beat < 4 }.map { "\($0.midi) \(String(format: "%.4f", $0.beat)) \($0.stroke)" }
                let third = notes.filter { $0.beat >= 8 && $0.beat < 12 }
                    .map { "\($0.midi) \(String(format: "%.4f", $0.beat - 8)) \($0.stroke)" }
                #expect(first == third, "seed \(seed) phrase \(phrase): \(first) vs \(third)")
                let second = notes.filter { $0.beat >= 4 && $0.beat < 8 }.map { "\($0.midi) \(String(format: "%.4f", $0.beat - 4))" }
                let fourth = notes.filter { $0.beat >= 12 }.map { "\($0.midi) \(String(format: "%.4f", $0.beat - 12))" }
                #expect(second != fourth, "seed \(seed) phrase \(phrase): bar 4 should change")
            }
        }
    }

    /// One cell per take: the theme and the variation of a take share bars 1 to 3; the next take's
    /// cell is a different figure for most seeds.
    @Test func oneCellPerTakeAndTakesDiffer() {
        var differing = 0
        for seed in 0..<100 as Range<UInt64> {
            let theme = Self.bass(Self.score(0, seed: seed)).filter { $0.beat < 12 }
            let variation = Self.bass(Self.score(1, seed: seed)).filter { $0.beat < 12 }
            #expect(theme.map(\.midi) == variation.map(\.midi) && theme.map(\.beat) == variation.map(\.beat),
                    "seed \(seed)")
            let next = Self.bass(Self.score(4, seed: seed)).filter { $0.beat < 8 }
            let here = theme.filter { $0.beat < 8 }
            let shape = { (n: [LofiScore.Note]) in n.map { "\(String(format: "%.3f", $0.beat)) \($0.stroke) \($0.midi - n[0].midi)" } }
            if shape(here) != shape(next) { differing += 1 }
        }
        BassReport.log("BASSLINE cells differing across takes: \(differing) of 100")
        #expect(differing >= 70)
    }

    // MARK: Kicks

    /// No note that is not anchored starts within 0.20 beats of a confident kick, and most notes on the
    /// take's kicks are anchored (C-B2 gets at least 24 aligned accents per 32 bars).
    @Test func unanchoredNotesKeepClearOfConfidentKicks() {
        var anchoredPer32 = [Int]()
        for seed in 0..<100 as Range<UInt64> {
            let timing = Self.take(seed: seed)
            var anchored = 0
            for phrase in 0..<8 {
                let current = Self.score(phrase, seed: seed, timing: timing)
                let start = (phrase % 4) * 16
                let kicks = timing.kicks(phraseStartBeat: start, minConfidence: LofiScore.bassAccentConfidence)
                let anchorBeats = Set(current.bassAnchors.map(\.noteBeat))
                anchored += current.bassAnchors.count
                for note in Self.bass(current) where !anchorBeats.contains(note.beat) {
                    let nearest = kicks.map { abs($0 - note.beat) }.min() ?? .infinity
                    #expect(nearest > LofiScore.bassKickSafety - 1e-9,
                            "seed \(seed) phrase \(phrase): unanchored note at \(note.beat), kick \(nearest) away")
                }
                #expect(current.bassAnchors.allSatisfy { a in Self.bass(current).contains { $0.beat == a.noteBeat } })
            }
            anchoredPer32.append(anchored)
        }
        BassReport.log("BASSLINE anchored per 32 bars: min \(anchoredPer32.min() ?? 0) median \(anchoredPer32.sorted()[50])")
        #expect((anchoredPer32.min() ?? 0) >= 24)
    }

    /// Every note ends, release included, by beat 16 (by the drop-out in a breakdown) and starts at or
    /// after 0; notes never overlap; an anchored note's predecessor is silent 30 ms before it.
    @Test func notesAreMonoTightAndInsideThePhrase() {
        for seed in 0..<100 as Range<UInt64> {
            let timing = seed.isMultiple(of: 3) ? nil : Self.take(seed: seed)
            for phrase in 0..<8 {
                let current = Self.score(phrase, seed: seed, timing: timing)
                let notes = Self.bass(current)
                for (i, note) in notes.enumerated() {
                    #expect(note.beat >= 0)
                    let end = note.beat + note.length + Self.release(note, current)
                    #expect(end <= LofiClock.beats + 1e-9, "seed \(seed) phrase \(phrase) note at \(note.beat) ends \(end)")
                    if i + 1 < notes.count {
                        let next = notes[i + 1]
                        let anchored = current.bassAnchors.contains { $0.noteBeat == next.beat }
                        let gap = anchored ? LofiScore.bassAccentClearance / Self.clock.beatDuration : 0
                        #expect(end <= next.beat - gap + 1e-9, "seed \(seed) phrase \(phrase) overlap at \(note.beat)")
                    }
                }
                #expect(notes.filter { $0.slide != 0 }.count <= 1)
                for note in notes where note.slide != 0 {
                    #expect((2...5).contains(note.slide))
                    #expect(note.stroke == .walk || note.stroke == .hold)
                    #expect(!current.bassAnchors.contains { $0.noteBeat == note.beat })
                }
                #expect(notes.allSatisfy { (28...53).contains($0.midi) })
                for high in notes where high.midi > 41 { #expect(!current.bassAnchors.contains { $0.noteBeat == high.beat }) }
            }
        }
    }

    // MARK: Sections, drop-outs and throws

    @Test func everyBreakdownDropsOutAndTheReturnSlamsBack() {
        for seed in 0..<100 as Range<UInt64> {
            for phrase in [2, 6] {
                let breakdown = Self.score(phrase, seed: seed)
                let notes = Self.bass(breakdown)
                let last = try! #require(notes.last)
                let end = last.beat + last.length + Self.release(last, breakdown)
                #expect(end <= LofiClock.beats - 2 + 1e-9, "seed \(seed) phrase \(phrase): sounds until \(end)")
                #expect(last.send > 0, "the note before the drop-out is thrown")
                #expect((breakdown.bassSweep != nil) == (phrase == 6))
                let back = Self.bass(Self.score(phrase + 1, seed: seed))
                #expect(back.first?.beat == 0 && back.first?.stroke == .hold && back.first?.velocity == 0.90)
            }
        }
    }

    @Test func throwsAreRareAndNeverConsecutive() {
        var thrown = 0, phrases = 0
        for seed in 0..<100 as Range<UInt64> {
            for phrase in 0..<8 {
                let notes = Self.bass(Self.score(phrase, seed: seed))
                let thrownNotes = notes.filter { $0.send > 0 }
                #expect(thrownNotes.count <= 1)
                thrown += thrownNotes.count
                phrases += 1
                if phrase % 4 == 0 { #expect(thrownNotes.isEmpty) }
            }
        }
        let perEightBars = Double(thrown) / Double(phrases) * 2
        BassReport.log(String(format: "BASSLINE throws per 8 bars %.2f", perEightBars))
        #expect((0.6...1.2).contains(perEightBars))
    }
}

/// Test measurements: printed and attached to the test result (xcodebuild does not show a sandboxed
/// host's standard output; `xcresulttool export attachments` reads them back).
enum BassReport {
    static func log(_ line: String) {
        print(line)
        Attachment.record(line, named: "bass-report.txt")
    }
}
