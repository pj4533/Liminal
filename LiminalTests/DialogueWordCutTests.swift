import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Whole words in the motif's chops (D130; user direction of 22 November 2026: "less chopping of
/// connective words. Or partial words. It almost sounds like a bug maybe sometimes."). On fixture speech
/// with a transcript: pieces carry a content word and are cut only between words, only a salient
/// multi-syllable word splits (into syllables) and an initialism only into letters, gates play to a
/// word end, chokes never land inside a content word and an onset trim never eats a word's start.
struct DialogueWordCutTests {
    static let salient = DialogueFixtures.speech(DialogueFixtures.Options(seed: 6, sentences: [
        "they took a dose of mescaline at night.", "the psychedelic music played on and on.",
        "it was a strange machine in the sky.", "nobody knows where the river goes.",
        "she dreamed of the ocean every morning.", "keep your eyes on the road ahead.",
    ]))

    struct Run: @unchecked Sendable {
        let snapshot: DialogueTransportSnapshot
        let plans: [DialogueMotifPlan]
        let words: [DialogueWordSpan]
        let weights: [Float]
        var events: [DialogueEvent] { plans.flatMap(\.plan.events).sorted { $0.startTime < $1.startTime } }
        var parts: [(plan: DialoguePerformancePlan, motif: DialogueMotif)] { plans.flatMap(\.parts) }
    }

    /// Two 16-bar loops (four 8-bar cues) of motif plans with the transcript at the first plan.
    static func run(_ fixture: SpeechFixture, bpm: Double, seed: UInt64, id: String) -> Run {
        let source = fixture.source(contentID: id)
        let analysis = DialogueEngine.analyze(source, speech: [])
        let transcript = DialogueFixtures.transcript(fixture)
        let bank = DialogueEngine.bank(analysis, transcript: transcript, seed: 11)
        let snapshot = GateRun.swung(bpm: bpm)
        var memory = DialoguePerformanceMemory()
        var plans: [DialogueMotifPlan] = []
        for piece in 0..<4 {
            let window = snapshot.time(beat: Double(32 * piece))..<snapshot.time(beat: Double(32 * (piece + 1)))
            if let plan = DialogueMotif.plan(source: source, analysis: analysis, bank: bank, transcript: transcript, snapshot: snapshot,
                                             window: window, earliestStart: window.lowerBound, memory: &memory,
                                             seed: seed &+ UInt64(piece), cueToken: piece + 1, revision: 0) {
                plans.append(plan)
            }
        }
        let words = DialogueHierarchy.refine(analysis, transcript: transcript).words
        return Run(snapshot: snapshot, plans: plans, words: words, weights: DialogueLineInterest.wordWeights(words))
    }

    static let cases: [(SpeechFixture, Double, String)] = [
        (salient, 72, "salient"), (salient, 84, "salient-84"), (GateRun.corpus, 72, "corpus"), (GateRun.investigate, 62, "investigate"),
    ]

    static func tolerance(_ rate: Double) -> Int { Int(0.030 * rate) }

    /// The accepted word whose core `frame` lies more than 30 ms inside.
    static func word(at frame: Int, in words: [DialogueWordSpan], rate: Double) -> Int? {
        let t = tolerance(rate)
        return words.indices.first { words[$0].frames.lowerBound + t < frame && frame < words[$0].frames.upperBound - t }
    }

    @Test func groupsCarryAContentWordAndRideWithTheirNeighbour() throws {
        func spans(_ text: String, gaps: [Int: Double] = [:]) -> [DialogueWordSpan] {
            var t = 0.0
            return text.split(separator: " ").enumerated().map { i, w in
                let start = t
                // About 14 letters a second, the pace of the films' narration.
                t += 0.06 * Double(w.count) + 0.03 + (gaps[i] ?? 0)
                return DialogueWordSpan(index: i, text: String(w), frames: Int(start * 48_000)..<Int((start + 0.06 * Double(w.count) + 0.03) * 48_000),
                                        confidence: nil)
            }
        }
        for line in ["It's a dose of LSD.", "and the house of the river is", "the kids today are into electronics.",
                     "that marijuana will be legal"] {
            let words = spans(line)
            let weights = DialogueLineInterest.wordWeights(words)
            let groups = DialogueMotifCutter.wordGroups(words, weights: weights, rate: 48_000)
            #expect(groups.flatMap { $0 } == Array(words.indices), "\(line): \(groups)")
            for g in groups {
                #expect(g.contains { weights[$0] > 0 }, "'\(line)': function-only group \(g.map { words[$0].text })")
                #expect(g.count <= DialogueMotifTuning.groupWordLimit)
            }
        }
        // A long run of function words ("Yes, they do look on them as") gives up only its far end: groups
        // stay small, and a function-only group lies inside that run, never next to nothing but content.
        let long = spans("Yes, they do look on them as qualified observers.")
        let longWeights = DialogueLineInterest.wordWeights(long)
        let longGroups = DialogueMotifCutter.wordGroups(long, weights: longWeights, rate: 48_000)
        #expect(longGroups.flatMap { $0 } == Array(long.indices))
        #expect(longGroups.allSatisfy { $0.count <= DialogueMotifTuning.groupWordLimit + 1 }, "\(longGroups)")
        let firstContent = try #require(long.indices.first { longWeights[$0] > 0 })
        for g in longGroups where !g.contains(where: { longWeights[$0] > 0 }) {
            #expect(g.allSatisfy { $0 < firstContent }, "\(longGroups)")
        }
        // A pause after a function word sends it back to the word before it.
        let paused = spans("the river of time", gaps: [1: 0.0, 2: 0.3])
        let groups = DialogueMotifCutter.wordGroups(paused, weights: DialogueLineInterest.wordWeights(paused), rate: 48_000)
        #expect(groups.first?.contains(2) == true, "\(groups)")
        // A line of function words only still groups.
        let none = spans("and then it was")
        #expect(!DialogueMotifCutter.wordGroups(none, weights: DialogueLineInterest.wordWeights(none), rate: 48_000).isEmpty)
    }

    @Test func syllablesAndLettersComeFromTheText() {
        #expect(DialogueMotifCutter.textSyllables("psilocybin") == 4)
        #expect(DialogueMotifCutter.textSyllables("trip") == 1)
        #expect(DialogueMotifCutter.textSyllables("frogs") == 1)
        #expect(DialogueMotifCutter.textSyllables("machine") == 2)
        #expect(DialogueMotifCutter.textSyllables("table") == 2)
        #expect(DialogueMotifCutter.syllableTexts("psilocybin", count: 4) == ["psi-", "-lo-", "-cy-", "-bin"])
        #expect(DialogueMotifCutter.syllableTexts("marijuana.", count: 2).count == 2)
        #expect(DialogueMotifCutter.initialism("LSD.") == "LSD")
        #expect(DialogueMotifCutter.initialism("U.F.O.") == "UFO")
        #expect(DialogueMotifCutter.initialism("DMT") == "DMT")
        #expect(DialogueMotifCutter.initialism("OK") == nil)
        #expect(DialogueMotifCutter.initialism("I") == nil)
        #expect(DialogueMotifCutter.initialism("Harvard") == nil)
    }

    @Test func fragmentEdgesSitBetweenWordsAndSplitsAreWholeUnits() throws {
        var fragments = 0, units = 0
        for (fixture, bpm, id) in Self.cases {
            for seed: UInt64 in [1, 2] {
                let run = Self.run(fixture, bpm: bpm, seed: seed, id: "\(id)-\(seed)")
                #expect(!run.plans.isEmpty)
                let rate = fixture.sampleRate
                for motif in run.parts.map(\.motif) where motif.usedTranscript {
                    for fr in motif.fragments where fr.kind != .line {
                        fragments += 1
                        let text = fr.text ?? "-"
                        if fr.isUnit {
                            units += 1
                            // A split unit lies inside one salient word of two or more syllables (or an initialism).
                            let parent = try #require(fr.parent)
                            let k = try #require(run.words.indices.first { run.words[$0].frames.overlaps(fr.frames)
                                && run.words[$0].frames.lowerBound <= fr.frames.lowerBound + Self.tolerance(rate)
                                && fr.frames.upperBound <= run.words[$0].frames.upperBound + Self.tolerance(rate) },
                                "unit '\(text)' of '\(motif.fragments[parent].text ?? "-")' spans words")
                            let w = run.words[k]
                            #expect(run.weights[k] >= DialogueMotifTuning.syllableWeight, "'\(w.text)' split at weight \(run.weights[k])")
                            #expect(!DialogueLineInterest.functionWords.contains(DialogueLineInterest.normalize(w.text)))
                            if fr.kind == .letter {
                                #expect(DialogueMotifCutter.initialism(w.text) != nil)
                            } else {
                                #expect(fr.kind == .syllable && DialogueMotifCutter.textSyllables(w.text) >= 2, "'\(w.text)' split as \(fr.kind)")
                            }
                            continue
                        }
                        // A piece's edges are not inside a word's core (beyond the 30 ms tolerance).
                        for edge in [fr.frames.lowerBound, fr.frames.upperBound] {
                            if let k = Self.word(at: edge, in: run.words, rate: rate) {
                                Issue.record("'\(motif.text ?? "-")' piece '\(text)' edge \(Double(edge - run.words[k].frames.lowerBound) / rate) s inside '\(run.words[k].text)'")
                            }
                        }
                    }
                }
            }
        }
        #expect(fragments > 40)
        print("WORDCUT fragments \(fragments) units \(units)")
    }

    @Test func noFunctionOnlyPieceWhenTheLineHasAContentWord() {
        for (fixture, bpm, id) in Self.cases {
            let run = Self.run(fixture, bpm: bpm, seed: 1, id: "fn-\(id)")
            for motif in run.parts.map(\.motif) where motif.usedTranscript && motif.pieces.contains(where: { motif.fragments[$0].weight > 0 }) {
                for p in motif.pieces {
                    #expect(motif.fragments[p].weight > 0, "'\(motif.text ?? "-")': function-only piece '\(motif.fragments[p].text ?? "-")'")
                }
            }
        }
    }

    @Test func hitsEndAtWordEndsAndChokesSpareContentWords() {
        var ended = 0, inside = 0
        for (fixture, bpm, id) in Self.cases {
            for seed: UInt64 in [1, 2] {
                let run = Self.run(fixture, bpm: bpm, seed: seed, id: "end-\(id)-\(seed)")
                let rate = fixture.sampleRate
                for part in run.parts where part.motif.usedTranscript {
                    let motif = part.motif
                    for e in part.plan.events {
                        guard let p = e.piece, p != 0, e.effect != .reversed, !e.stutter, let played = e.sourceFrames,
                              !motif.fragments[p].isUnit else { continue }
                        ended += 1
                        // The end of the dry part is not inside a content word (a unit's end is its syllable edge).
                        if let k = Self.word(at: played.upperBound, in: run.words, rate: rate), run.weights[k] > 0,
                           played.upperBound < motif.fragments[p].frames.upperBound - Self.tolerance(rate) {
                            inside += 1
                            Issue.record("'\(motif.fragments[p].text ?? "-")' (\(e.gateEnd), gate \(e.gateSteps ?? -1), \(e.cell?.rawValue ?? "-") slot \(e.slot)) ends inside '\(run.words[k].text)'")
                        }
                        if e.gateEnd == "word" {
                            #expect(motif.fragments[p].cutPoints.contains(played.upperBound) || abs(played.upperBound - motif.fragments[p].frames.upperBound) < Self.tolerance(rate))
                        }
                    }
                }
            }
        }
        #expect(ended > 40)
        #expect(inside == 0)
    }

    @Test func aPieceNeverStartsPastItsFirstContentWord() {
        for (fixture, bpm, id) in Self.cases {
            let run = Self.run(fixture, bpm: bpm, seed: 1, id: "start-\(id)")
            let slack = Int(DialogueMotifTuning.wordStartSlackSeconds * fixture.sampleRate) + 2
            for motif in run.parts.map(\.motif) where motif.usedTranscript {
                for p in motif.pieces {
                    let fr = motif.fragments[p]
                    guard let k = run.words.indices.first(where: { run.words[$0].frames.upperBound > fr.frames.lowerBound + slack }),
                          run.weights[k] > 0 else { continue }
                    #expect(fr.frames.lowerBound <= run.words[k].frames.lowerBound + slack,
                            "'\(fr.text ?? "-")' starts \(Double(fr.frames.lowerBound - run.words[k].frames.lowerBound) / fixture.sampleRate) s into '\(run.words[k].text)'")
                }
            }
        }
    }

    @Test func theSameSeedGivesTheSamePlan() {
        let a = Self.run(Self.salient, bpm: 72, seed: 5, id: "same")
        let b = Self.run(Self.salient, bpm: 72, seed: 5, id: "same")
        #expect(a.events.map { [$0.piece ?? -1, $0.slot, $0.block] } == b.events.map { [$0.piece ?? -1, $0.slot, $0.block] })
        #expect(a.events.map(\.startTime) == b.events.map(\.startTime))
    }
}
