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
                        #expect(e.cell == .outro && motif.arc?.outro == 0 && e.slot >= 16 && e.slot < 56, "\(id) seed \(seed): '\(motif.fragments[p].text ?? "-")' in \(e.cell.map { "\($0)" } ?? "-") of '\(motif.text ?? "-")'")
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
                           ids == units {
                            let whole = step(events[j])
                            if whole % 4 == 0, whole == (steps.last! / 4 + 1) * 4 { figures += 1 }
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

    @Test func trailingPunctuationDoesNotTurnOKIntoAnInitialism() {
        for text in ["OK", "OK.", "OK!"] { #expect(DialogueLineInterest.initialismLetters(text) == nil) }
        #expect(DialogueLineInterest.initialismLetters("U.F.O.") == "UFO")
    }

    @Test func aLateRecutWithOnlyOneContentPieceKeepsContentRolesAndTags() {
        let fragments = [
            DialogueMotifFragment(id: 0, kind: .line, order: -1, parent: nil, frames: 0..<1300, accentFrame: 0, fadeIn: 0, fadeOut: 0),
            DialogueMotifFragment(id: 1, kind: .piece, order: 0, parent: nil, frames: 0..<500, accentFrame: 0, fadeIn: 0, fadeOut: 0, text: "DMT", weight: 0.95),
            DialogueMotifFragment(id: 2, kind: .piece, order: 1, parent: nil, frames: 500..<1300, accentFrame: 500, fadeIn: 0, fadeOut: 0, text: "and the"),
        ]
        let roles = DialogueMotif.hookRoles(fragments: fragments, pieces: [1, 2], halves: [:], reorderAllowed: true,
                                          sampleRate: 1000, anchors: [0..<500, 500..<1300])
        #expect(roles.s == 1 && roles.r == 1 && roles.t == 1)
        for seed: UInt64 in 1...20 {
            let arranged = DialogueMotif.arrange(fragments: fragments, pieces: [1, 2], halves: [:], reorderAllowed: true,
                                                seed: seed, lineSeconds: 1.3, sampleRate: 1000, hookSeed: seed, loop: 0, beatDuration: 60 / 72)
            for cell in arranged.cells {
                for item in cell.items where item.fragment == 2 {
                    #expect(cell.kind == .outro && arranged.arc.outro == 0 && item.slot == 16)
                }
            }
        }
    }

    @Test func protectedOnsetKeepsTheFirstVoicedSample() throws {
        let source = Self.spelled.source(contentID: "protected-onset")
        let features = try #require(DialogueEngine.analyze(source, speech: []).features)
        let rate = source.sampleRate
        let coreStart = Int(0.05 * rate)
        let attack = Int(0.15 * rate)
        let count = Int(0.4 * rate)
        let word = DialogueWordSpan(index: 0, text: "LSD", frames: coreStart..<count, confidence: 1)
        // The nearest crossing sits one sample inside the voiced core. The later loud attack
        // triggers the protected-start clamp, as it did in the public aapb LSD landing.
        var samples = [Float](repeating: -0.00001, count: count)
        for i in (coreStart + 1)..<attack { samples[i] = 0.00001 }
        for i in attack..<count { samples[i] = Float(sin(Double(i - attack) * 2 * .pi * 400 / rate)) * 0.5 }
        let fragment = DialogueMotifFragment(id: 1, kind: .piece, order: 0, parent: nil,
            frames: 0..<count, accentFrame: attack, fadeIn: 0, fadeOut: 0, text: "LSD")
        samples.withUnsafeBufferPointer { pcm in
            let cutter = DialogueMotifCutter(f: features, samples: pcm.baseAddress!, count: count, rate: rate)
            let result = cutter.trimmed([fragment], words: [word], weights: [1])[0]
            #expect(result.frames.lowerBound == coreStart)
            #expect(result.frames.upperBound == fragment.frames.upperBound)
        }
    }

    @Test func longContentGroupOffersAWholeWordForTheHookAndKeepsItsParent() throws {
        let source = Self.spelled.source(contentID: "hook-word")
        let features = try #require(DialogueEngine.analyze(source, speech: []).features)
        let samples = try #require(source.buffer.floatChannelData?[0])
        let cutter = DialogueMotifCutter(f: features, samples: samples, count: source.frameCount, rate: source.sampleRate)
        let frames = [0..<84_000, 0..<35_000, 35_000..<84_000]
        let original = frames.enumerated().map { i, range in
            DialogueMotifFragment(id: i, kind: i == 0 ? .line : .piece, order: i - 1, parent: nil,
                                  frames: range, accentFrame: range.lowerBound, fadeIn: 0, fadeOut: 0)
        }
        let word = DialogueWordSpan(index: 2, text: "lies.", frames: 60_000..<83_000, confidence: 1)
        for token in ["it", "not"] {
            let words = [DialogueWordSpan(index: 0, text: "direction", frames: 0..<34_000, confidence: 1),
                         DialogueWordSpan(index: 1, text: token, frames: 35_000..<60_000, confidence: 1), word]
            var fragments = original
            cutter.addHookWords(to: &fragments, pieces: [1, 2], words: words, weights: [0.45, 0, 0.7])
            #expect(Array(fragments.prefix(3)) == original)
            if token == "it" {
                let alternate = try #require(fragments.dropFirst(3).first)
                #expect(alternate.parent == 2 && alternate.kind == .piece)
                #expect(alternate.text == word.text && alternate.frames == word.frames)
            } else {
                #expect(fragments.count == 3)
            }
        }
    }

    @Test func spacedLettersHaveOneParentAndOrderedUnits() throws {
        let source = Self.spelled.source(contentID: "spaced")
        let analysis = DialogueEngine.analyze(source, speech: [])
        let features = try #require(analysis.features)
        let samples = try #require(source.buffer.floatChannelData?[0])
        var cutter = DialogueMotifCutter(f: features, samples: UnsafePointer(samples), count: source.frameCount, rate: source.sampleRate)
        let rate = source.sampleRate
        let words = ["D", "M", "T"].enumerated().map { i, text in
            DialogueWordSpan(index: i, text: text, frames: Int(Double(i) * 0.30 * rate)..<Int(Double(i + 1) * 0.30 * rate), confidence: nil)
        }
        let groups = DialogueMotifCutter.wordGroups(words, weights: DialogueLineInterest.wordWeights(words), rate: rate)
        #expect(groups == [[0, 1, 2]])
        // A line with recognized spaced letters must retain that group as a single parent.
        let template = try #require(analysis.units.first)
        let line = SpeechUnit(id: template.id, parentID: nil, level: .wordGroup, frames: 0..<Int(0.9 * rate),
                              text: "D M T", boundaryConfidence: 1, speechScore: 1, interferenceScore: 0,
                              stressAnchors: [], protectedSpans: [], tail: 0..<0, score: template.score,
                              fadeIn: 0, fadeOut: 0, onset: .burst, nuclei: 3, bandSNR: .zero, peakEnergy: 1)
        let attempted = cutter.cut(line, words: words, weights: DialogueLineInterest.wordWeights(words), salience: DialogueLineInterest.wordSalience(words))
        let cut = try #require(attempted)
        #expect(cut.pieces.count == 1)
        let first = try #require(cut.pieces.first)
        let units = try #require(cut.halves[first])
        #expect(units.map { cut.fragments[$0].text ?? "" } == ["D", "M", "T"])
        #expect(units.allSatisfy { cut.fragments[$0].kind == .letter })
    }

    @Test func aFillCanSpellIntoALaterSignatureAfterTheStepZeroSignature() {
        func fragment(_ id: Int, _ parent: Int?, _ frames: Range<Int>, _ kind: DialogueMotifFragment.Kind) -> DialogueMotifFragment {
            DialogueMotifFragment(id: id, kind: kind, order: parent == nil ? id : parent!, parent: parent,
                                  frames: frames, accentFrame: frames.lowerBound, fadeIn: 0, fadeOut: 0, text: nil, weight: 0.95)
        }
        let fragments = [fragment(0, nil, 0..<500, .line), fragment(1, nil, 0..<300, .piece),
                         fragment(2, nil, 300..<400, .piece), fragment(3, 1, 0..<100, .letter),
                         fragment(4, 1, 100..<200, .letter), fragment(5, 1, 200..<300, .letter)]
        let vocabulary = DialogueMotif.GrooveVocabulary(s: 1, r: 2, t: 2, sa: 3, ra: 2,
                                                       pieces: [1, 2], halves: [1: [3, 4, 5]], fragments: fragments)
        var figures = 0
        for seed: UInt64 in 0..<200 {
            let items = DialogueMotif.groove(template: [(.s, 0), (.s, 16), (.r, 28)], vocabulary: vocabulary,
                                            drums: .boomBap, reorderAllowed: true, fragments: fragments,
                                            sampleRate: 1000, seed: seed, beatDuration: 60 / 72)
            for stride in [1, 2] {
                let slots = [16 - 3 * stride, 16 - 2 * stride, 16 - stride]
                if slots.enumerated().allSatisfy({ i, slot in items.contains { $0.slot == slot && $0.fragment == i + 3 } }) { figures += 1 }
            }
        }
        #expect(figures > 0, "the first signature at zero has no lead-in; try the later signature")
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
