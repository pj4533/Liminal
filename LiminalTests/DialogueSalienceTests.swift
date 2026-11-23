import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Salient chops (D130 stage 2; user direction of 22 November 2026: "more weighting toward ... something
/// recognizable and interesting or cool ... the initials DMT are easy to catch, and then match to a
/// beat ... Less chopping of connective words."). Hits carry content words, a spelling word is spelled
/// one unit per step and then stated whole, syllables come only from salient multi-syllable words, and
/// a striking line is not passed over for a plain one.
struct DialogueSalienceTests {
    /// Speech whose second sentence holds a three-nucleus word the transcript writes as "DMT".
    static let spelled: SpeechFixture = DialogueFixtures.speech(DialogueFixtures.Options(seed: 8, sentences: [
        "nobody knows where the river goes.", "they took deemitee at night.", "keep your eyes on the road ahead.",
        "the psychedelic music played on and on.", "she runs to the station every morning.",
    ]))

    static func transcript(_ fixture: SpeechFixture) -> DialogueTranscript {
        var t = DialogueFixtures.transcript(fixture)
        t = DialogueTranscript(locale: t.locale, modelVersion: t.modelVersion, words: t.words.map {
            DialogueTranscript.Word(text: $0.text == "deemitee" ? "DMT" : $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
        })
        return t
    }

    struct Run: @unchecked Sendable {
        let plans: [DialogueMotifPlan]
        var parts: [(plan: DialoguePerformancePlan, motif: DialogueMotif)] { plans.flatMap(\.parts) }
    }

    /// Two 16-bar loops (four 8-bar cues) with the transcript at the first plan.
    static func run(_ fixture: SpeechFixture, transcript: DialogueTranscript, bpm: Double, seed: UInt64, id: String) -> Run {
        let source = fixture.source(contentID: id)
        let analysis = DialogueEngine.analyze(source, speech: [])
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
        return Run(plans: plans)
    }

    static let seeds: [UInt64] = [1, 2, 3, 5, 8]

    static func cases() -> [(SpeechFixture, DialogueTranscript, String)] {
        [(spelled, transcript(spelled), "spelled"),
         (DialogueWordCutTests.salient, DialogueFixtures.transcript(DialogueWordCutTests.salient), "salient"),
         (GateRun.corpus, DialogueFixtures.transcript(GateRun.corpus), "corpus")]
    }

    /// A weight-0 cut (a connective word) is heard only inside the whole line and the outro's in-order
    /// walk of the line, while the line has a content cut.
    @Test func noConnectiveHitOutsideTheLineStatements() throws {
        for (fixture, transcript, id) in Self.cases() {
            for seed in Self.seeds.prefix(3) {
                let run = Self.run(fixture, transcript: transcript, bpm: 72, seed: seed, id: "\(id)-\(seed)")
                try #require(!run.parts.isEmpty)
                for part in run.parts {
                    let motif = part.motif
                    guard motif.fragments.dropFirst().contains(where: { $0.weight > 0 }) else { continue }
                    for e in part.plan.events {
                        guard let p = e.piece, p != 0, motif.fragments[p].weight == 0 else { continue }
                        #expect(e.cell == .outro, "\(id) seed \(seed): '\(motif.fragments[p].text ?? "-")' in \(e.cell.map { "\($0)" } ?? "-") of '\(motif.text ?? "-")'")
                    }
                }
            }
        }
    }

    /// Syllable units come only from salient words of two or more syllables, letter units only from initialisms.
    @Test func unitsComeOnlyFromSalientWords() throws {
        for (fixture, transcript, id) in Self.cases() {
            let run = Self.run(fixture, transcript: transcript, bpm: 72, seed: 1, id: "\(id)-units")
            for part in run.parts {
                let motif = part.motif
                for fr in motif.fragments where fr.kind == .syllable || fr.kind == .letter {
                    let parent = try #require(fr.parent)
                    let text = motif.fragments[parent].text ?? ""
                    let tokens = text.split(separator: " ").map(String.init)
                    let salience = DialogueLineInterest.wordSalience(text)
                    if fr.kind == .letter {
                        #expect(salience.contains { $0.kind == .initialism }, "\(id): letter of '\(text)'")
                    } else {
                        let ok = tokens.indices.contains { salience[$0].weight >= DialogueMotifTuning.syllableWeight
                            && DialogueMotifCutter.textSyllables(tokens[$0]) >= 2 && salience[$0].kind != .initialism }
                        #expect(ok, "\(id): syllable '\(fr.text ?? "-")' of '\(text)'")
                    }
                }
            }
        }
    }

    /// "DMT" leads the loop, splits into its three letters and is spelled one letter per step in source
    /// order, then stated whole on the next beat (the build, the outro's tag); every run of one word's
    /// units that leads into the word plays in source order.
    @Test func aSpellingSignatureIsSpelledInOrderThenStatedWhole() throws {
        var figures = 0
        for seed in Self.seeds {
            let run = Self.run(Self.spelled, transcript: Self.transcript(Self.spelled), bpm: 72, seed: seed, id: "spell-\(seed)")
            for part in run.parts {
                let motif = part.motif
                guard let hook = motif.hook, let units = motif.halves[hook.signature], units.count >= 2,
                      units.allSatisfy({ motif.fragments[$0].kind == .letter || motif.fragments[$0].kind == .syllable }) else { continue }
                let events = part.plan.events.sorted { $0.startTime < $1.startTime }
                let loopStep = (DialogueMotif.loopBeat(motif.loop, snapshot: GateRun.swung(bpm: 72)) * 4).rounded()
                func step(_ e: DialogueEvent) -> Int { e.block * 64 + e.slot - Int(loopStep) }
                var i = 0
                while i < events.count {
                    var j = i
                    while j < events.count, let p = events[j].piece, motif.fragments[p].isUnit, motif.fragments[p].parent == hook.signature { j += 1 }
                    if j - i >= 2, j < events.count, events[j].piece == hook.signature {
                        // A run that leads into the whole word is a spell figure: in source order.
                        let ids = events[i..<j].compactMap(\.piece)
                        #expect(ids == ids.sorted() && Set(ids).count == ids.count, "seed \(seed): figure out of order \(ids)")
                        let steps = events[i..<j].map(step)
                        let strides = Set(zip(steps, steps.dropFirst()).map { $1 - $0 })
                        if j < events.count, events[j].piece == hook.signature, strides.count == 1, let d = strides.first, d <= 2,
                           ids == Array(units.prefix(ids.count)) {
                            let whole = step(events[j])
                            if whole % 4 == 0, whole - steps.last! <= 4 { figures += 1 }
                        }
                    }
                    i = max(j, i + 1)
                }
            }
        }
        #expect(figures >= 3, "spell figures found: \(figures)")
    }

    /// The first loop's line is within `linePoolInterest` of the most interesting ranked line.
    @Test func aStrikingLineIsNotPassedOver() throws {
        let film = DialogueLineInterestTests.mixedTranscribed
        let refined = DialogueHierarchy.refine(film.analysis, transcript: try #require(film.transcript))
        let ranked = DialogueMotif.rankLines(units: refined.units, rejections: refined.rejections, rate: film.analysis.sampleRate,
                                             maximum: DialogueLineInterestTests.maximum(), words: refined.words,
                                             weights: DialogueLineInterest.wordWeights(refined.words))
        let best = try #require(ranked.map(\.interest).max())
        for seed: UInt64 in [1, 2, 3, 5, 8, 13, 21] {
            let motif = try #require(DialogueMotif.make(loop: 0, source: film.source, analysis: film.analysis, transcript: film.transcript,
                                                        memory: DialoguePerformanceMemory(), seed: seed, beatDuration: DialogueLineInterestTests.beat))
            #expect(motif.interest >= best - DialogueMotifTuning.linePoolInterest - 1e-4, "seed \(seed): '\(motif.text ?? "-")' \(motif.interest) against \(best)")
        }
    }

    /// The same seed gives the same plan.
    @Test func theSameSeedGivesTheSamePlan() throws {
        let a = Self.run(Self.spelled, transcript: Self.transcript(Self.spelled), bpm: 72, seed: 4, id: "same")
        let b = Self.run(Self.spelled, transcript: Self.transcript(Self.spelled), bpm: 72, seed: 4, id: "same")
        let x = a.plans.flatMap(\.plan.events).map { [Double($0.piece ?? -1), $0.startTime, $0.duration] }
        let y = b.plans.flatMap(\.plan.events).map { [Double($0.piece ?? -1), $0.startTime, $0.duration] }
        #expect(!x.isEmpty && x == y)
    }
}
