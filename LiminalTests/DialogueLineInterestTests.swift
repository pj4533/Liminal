import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Liminal

/// Interest-ranked line choice (D124): evocative lines ("Sally, this is mother.", "he took a large
/// dose of LSD.") lead loops before plain connective ones, without breaking the D123 ledger or the
/// acoustic fallback.
@Suite(.serialized)
struct DialogueLineInterestTests {
    struct Film { let source: DialogueSource; let analysis: DialogueAnalysis; let bank: DialoguePadBank?; let transcript: DialogueTranscript? }

    static func film(_ fixture: SpeechFixture, id: String, transcribed: Bool) -> Film {
        let source = fixture.source(contentID: id)
        let analysis = DialogueEngine.analyze(source, speech: [])
        let transcript = transcribed ? DialogueFixtures.transcript(fixture) : nil
        return Film(source: source, analysis: analysis, bank: DialogueEngine.bank(analysis, transcript: transcript, seed: 11),
                    transcript: transcript)
    }

    static let striking = ["Sally, this is mother.", "he took a large dose of LSD.", "I saw a flying saucer over the desert.",
                           "the marks of death are rigid.", "your mind is dreaming in color."]
    static let plain = ["what is it that you want to do.", "there is one of them over there.", "so that is what they have for us."]

    /// Plain and evocative lines side by side.
    static let mixed = DialogueFixtures.speech(DialogueFixtures.Options(seconds: 40, seed: 6, sentences: [
        "and then we went to the other one.", "Sally, this is mother.", "it did not work that way at all.",
        "he took a large dose of LSD.", "there is one of them over there.", "I saw a flying saucer over the desert.",
        "so that is what they have for us.", "the marks of death are rigid.", "what is it that you want to do.",
        "your mind is dreaming in color.",
    ]))
    static let investigate = DialogueFixtures.speech(DialogueFixtures.Options(seed: 4, sentences: [
        "when they want to investigate the house.", "the old car stood empty for years.",
        "listen to the rhythm of the city.", "she runs to the station every morning.",
    ]))
    static let mixedTranscribed = film(mixed, id: "interest-mixed", transcribed: true)
    static let beat = 60.0 / 84

    static func maximum() -> Double {
        min(DialogueMotifTuning.lineSeconds.upperBound, DialogueMotifTuning.lineMaximumBars * 4 * beat)
    }

    static func record(_ motif: DialogueMotif, in memory: inout DialoguePerformanceMemory) {
        memory.setMotif(motif, statements: 0)
        memory.ledger.record(contentID: motif.source.contentID,
                             seconds: motif.source.sourceSeconds(frame: motif.line.frames.lowerBound)
                                 ..< motif.source.sourceSeconds(frame: motif.line.frames.upperBound))
    }

    /// The lines that lead `loops` loops of one film, one after another, with the ledger recording each.
    static func led(_ film: Film, seed: UInt64, loops: Int) -> [DialogueMotif?] {
        var memory = DialoguePerformanceMemory()
        var out: [DialogueMotif?] = []
        for loop in 0..<loops {
            let motif = DialogueMotif.resolve(loop: loop, source: film.source, analysis: film.analysis, hasBank: film.bank != nil,
                                              transcript: film.transcript, memory: memory, seed: seed, beatDuration: beat)
            if let motif, !motif.carried { record(motif, in: &memory) }
            out.append(motif)
        }
        return out
    }

    // MARK: Text

    @Test func evocativeLinesOutscorePlainOnes() {
        let sally = DialogueLineInterest.interest("Sally, this is mother.")
        let lsd = DialogueLineInterest.interest("he took a large dose of LSD.")
        let connective = DialogueLineInterest.interest("and then we went to the")
        let flat = DialogueLineInterest.interest("it didn't work that way at all.")
        #expect(sally >= 0.75 && lsd >= 0.75, "sally \(sally) lsd \(lsd)")
        for strong in [sally, lsd] {
            #expect(strong - connective >= 0.4 && strong - flat >= 0.4, "\(strong) vs \(connective), \(flat)")
        }
        #expect(DialogueLineInterest.interest("what is it that you want to do.") <= 0.15)
        #expect(DialogueLineInterest.interest("Wake up, Tommy!") >= 0.75)
        #expect(DialogueLineInterest.interest("your mind is dreaming in color.") > DialogueLineInterest.interest("these are all broken."))
    }

    @Test func namesAndHotWordsWeighMostFunctionWordsNothing() {
        let sally = DialogueLineInterest.wordWeights("Sally, this is mother.")
        #expect(sally[0] >= 0.8 && sally[1] == 0 && sally[2] == 0 && sally[3] >= 0.7, "\(sally)")
        let lsd = DialogueLineInterest.wordWeights("he took a large dose of LSD.")
        #expect(lsd[6] >= 0.8 && lsd[4] >= 0.8 && lsd[2] == 0 && lsd[5] == 0, "\(lsd)")
        #expect(DialogueLineInterest.wordWeights("the")[0] == 0)
        // Prototype flaws: "minded" is not "mind", "runs" is not the imperative "run".
        #expect(DialogueLineInterest.lexiconWeight("minded") == 0)
        #expect(DialogueLineInterest.lexiconWeight("runs") == 0 && DialogueLineInterest.lexiconWeight("run") > 0)
        #expect(DialogueLineInterest.lexiconWeight("hallucinations") == 1 && DialogueLineInterest.lexiconWeight("dreaming") >= 0.9)
    }

    @Test func discourseMarkersAreNotNames() {
        for line in ["Yes, they do look on them as qualified observers.", "Well, I guess those questions were kind of",
                     "Thus, rigidity the marks of death.", "Hello, Doctor?", "Later, a new crop will be formed."] {
            #expect(DialogueLineInterest.wordWeights(line)[0] < 0.8, "\(line)")
        }
    }

    @Test func theSameInputGivesTheSameScore() {
        for line in Self.striking + Self.plain {
            #expect(DialogueLineInterest.interest(line) == DialogueLineInterest.interest(line))
            #expect(DialogueLineInterest.wordWeights(line) == DialogueLineInterest.wordWeights(line))
        }
    }

    // MARK: Ranking

    /// A sentence after one ending in a number ("the other one. Sally,") was a protected cut (D124, L0).
    @Test func aNameAfterASentenceEndingInANumberIsNotAProtectedCut() throws {
        let film = Self.mixedTranscribed
        let refined = DialogueHierarchy.refine(film.analysis, transcript: try #require(film.transcript))
        let rejected = Set(refined.rejections.map(\.unit))
        let sally = refined.units.filter { $0.text == "Sally, this is mother." }
        try #require(!sally.isEmpty)
        #expect(sally.contains { !rejected.contains($0.id) })
        let ranked = DialogueMotif.rankedLines(units: refined.units, rejections: refined.rejections, rate: film.analysis.sampleRate,
                                               maximum: Self.maximum(), words: refined.words)
        #expect(ranked.contains { $0.text == "Sally, this is mother." })
    }

    @Test func strikingLinesRankAheadOfPlainOnes() throws {
        let film = Self.mixedTranscribed
        let refined = DialogueHierarchy.refine(film.analysis, transcript: try #require(film.transcript))
        let ranked = DialogueMotif.rankedLines(units: refined.units, rejections: refined.rejections, rate: film.analysis.sampleRate,
                                               maximum: Self.maximum(), words: refined.words)
        func rank(_ text: String) -> Int { ranked.firstIndex { $0.text == text } ?? Int.max }
        let worstStriking = Self.striking.map(rank).max() ?? Int.max
        let bestPlain = Self.plain.map(rank).min() ?? Int.max
        #expect(worstStriking < Int.max, "every striking line ranks: \(ranked.compactMap(\.text))")
        #expect(worstStriking < bestPlain, "\(ranked.compactMap(\.text))")
    }

    @Test(arguments: [UInt64(1), 2, 3, 0xC0FF_EE12_3456_789A])
    func theFirstLoopsLeadWithStrikingLines(_ seed: UInt64) throws {
        let motifs = Self.led(Self.mixedTranscribed, seed: seed, loops: 4)
        for motif in motifs {
            let motif = try #require(motif)
            #expect(motif.interest >= 0.6, "seed \(seed): \(motif.text ?? "-") \(motif.interest)")
            #expect(motif.usedTranscript)
        }
        let first = try #require(motifs[0])
        #expect(first.fragments.contains { $0.weight >= 0.75 }, "a fragment carries the line's strongest word")
        #expect((first.log()["interest"] as? Double) != nil)
    }

    /// D123 holds: no line leads twice while unplayed lines remain, and plain lines come last.
    @Test(arguments: [UInt64(1), 2, 0xC0FF_EE12_3456_789A])
    func noLineRepeatsAndPlainLinesComeLast(_ seed: UInt64) throws {
        let motifs = Self.led(Self.mixedTranscribed, seed: seed, loops: 10).compactMap { $0 }.filter { !$0.carried }
        try #require(motifs.count >= 6)
        let texts = motifs.compactMap(\.text)
        #expect(Set(motifs.map(\.lineKey)).count == motifs.count, "seed \(seed): \(texts)")
        // A sentence the film says twice leads once while other lines remain.
        let firstSix = motifs.prefix(6).compactMap(\.text)
        #expect(Set(firstSix).count == firstSix.count, "seed \(seed): \(texts)")
        let plainAt = motifs.indices.filter { motifs[$0].interest < DialogueMotifTuning.plainInterest }
        let strikingAt = motifs.indices.filter { motifs[$0].interest >= DialogueMotifTuning.strikingInterest }
        if let firstPlain = plainAt.min(), let lastStriking = strikingAt.max() {
            #expect(lastStriking < firstPlain, "seed \(seed): \(texts)")
        }
    }

    // MARK: Acoustic fallback

    @Test func withoutATranscriptTheOrderIsTheAcousticOneAndEveryLoopHasALine() throws {
        let film = Self.film(Self.mixed, id: "interest-mixed-a", transcribed: false)
        let a = film.analysis
        let ranked = DialogueMotif.rankedLines(units: a.units, rejections: a.rejections, rate: a.sampleRate, maximum: Self.maximum())
        try #require(!ranked.isEmpty)
        // The pre-D124 value: sound times fit times length (the interest factor is the same for every line).
        let rejected = Dictionary(a.rejections.map { ($0.unit, $0.reason) }, uniquingKeysWith: { x, _ in x })
        func old(_ u: SpeechUnit) -> Float {
            let d = u.seconds(a.sampleRate)
            let length = d <= DialogueMotifTuning.preferredLineSeconds ? 1
                : max(0.8, 1 - 0.2 * Float((d - DialogueMotifTuning.preferredLineSeconds) / (DialogueMotifTuning.lineSeconds.upperBound - DialogueMotifTuning.preferredLineSeconds)))
            return u.score.sound * DialogueBankBuilder.lineFit(u, units: a.units, rejected: rejected) * length
        }
        let preferred = ranked.filter { DialogueMotifTuning.lineSeconds.contains($0.seconds(a.sampleRate)) }
        #expect(preferred.map(\.id) == preferred.sorted { (old($0), -$0.id) > (old($1), -$1.id) }.map(\.id))
        let motifs = Self.led(film, seed: 3, loops: 6)
        for (loop, motif) in motifs.enumerated() {
            let motif = try #require(motif, "loop \(loop)")
            #expect(motif.interest == DialogueMotifTuning.acousticInterest)
            #expect(motif.fragments.allSatisfy { $0.weight == 0 })
        }
    }

    // MARK: Crate

    /// A new loop whose cue has no transcript yet takes a striking transcribed line from the crate
    /// (a film heard in the last cues); with an empty crate it takes its own acoustic line.
    @Test func aCueWithoutATranscriptTakesAStrikingCrateLine() throws {
        let crateFilm = Self.mixedTranscribed
        let fresh = Self.film(Self.investigate, id: "interest-investigate-a", transcribed: false)
        var memory = DialoguePerformanceMemory()
        memory.addToCrate(DialogueMotifCrateEntry(source: crateFilm.source, analysis: crateFilm.analysis, transcript: crateFilm.transcript))
        let dug = try #require(DialogueMotif.resolve(loop: 1, source: fresh.source, analysis: fresh.analysis, hasBank: true,
                                                     transcript: nil, memory: memory, seed: 7, beatDuration: Self.beat))
        #expect(dug.source.contentID == crateFilm.source.contentID)
        #expect(dug.interest >= DialogueMotifTuning.strikingInterest, "\(dug.text ?? "-")")
        memory.motifCrate.removeAll()
        let own = try #require(DialogueMotif.resolve(loop: 1, source: fresh.source, analysis: fresh.analysis, hasBank: true,
                                                     transcript: nil, memory: memory, seed: 7, beatDuration: Self.beat))
        #expect(own.source.contentID == fresh.source.contentID)
        #expect(own.interest == DialogueMotifTuning.acousticInterest)
    }

    // MARK: Coordinator

    static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    static let runtimeFixture: SpeechFixture = {
        var o = DialogueFixtures.Options()
        o.seconds = 12
        o.sentences = ["the night was cold, the band played on.", "listen to the rhythm of the city.",
                       "keep your eyes on the road ahead."]
        return DialogueFixtures.speech(o)
    }()

    static func runCue(delay: Duration) async -> (outcome: DialogueDirector.Outcome, plans: [ArchiveVoice.ChopPlan]) {
        let transcript = DialogueFixtures.transcript(runtimeFixture)
        var settings = DialogueDirector.Settings(transcriptProvider: { FixtureTranscriptProvider(transcript, delay: delay) })
        settings.classify = { _, _, _ in [] }
        settings.ledger = DialogueLineLedger()
        settings.transcriptFirstWait = 1.2
        let director = DialogueDirector(settings)
        let start = uptime()
        let bpm = 70.0
        let info = LofiTransportInfo(revision: 1, takeIndex: 0, phraseAtTakeStart: 0, origin: start, beatDuration: 60 / bpm,
                                     nextBeatDuration: nil, seed: 5, options: LofiOptions(tempo: bpm), timing: nil)
        // The bed is due 3 s from now, as with the scheduling lead of a later cue.
        let window = DialogueCueCoordinator.window(due: start + 3.0, span: 32 * 60 / bpm, transport: info)
        let source = runtimeFixture.source(contentID: "interest-runtime")
        let posted = Mutex<[ArchiveVoice.ChopPlan]>([])
        let outcome = await Task.detached(priority: .utility) {
            await director.run(source: source, window: window, seed: 9, transport: { info }, isCurrent: { true },
                               post: { plan in posted.withLock { $0.append(plan) } })
        }.value
        return (outcome, posted.withLock { $0 })
    }

    @Test func aTranscriptReadyInTimeChoosesTheFirstPlansLine() async throws {
        let (outcome, plans) = await Self.runCue(delay: .milliseconds(50))
        try #require(plans.count == 1, "one plan: the first one already used the words")
        #expect(plans[0].revision == 0)
        #expect(outcome.transcriptUsed)
        let built = try #require(outcome.built.first)
        #expect(built.motif?.usedTranscript == true)
        #expect(built.plan.usedTranscript || built.motif?.usedTranscript == true)
    }

    @Test func aSlowTranscriptKeepsTheAcousticPlanThenRefines() async throws {
        let (outcome, plans) = await Self.runCue(delay: .milliseconds(1800))
        try #require(plans.count == 2, "acoustic plan, then the refinement")
        #expect(plans[0].revision == 0 && plans[1].revision == 1)
        #expect(outcome.built.first?.motif?.usedTranscript == false)
        #expect(outcome.transcriptUsed)
    }
}
