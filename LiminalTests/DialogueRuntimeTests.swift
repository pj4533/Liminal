import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Liminal

/// The dialogue coordinator beside the film bed (plan 6.2): the bed never waits, plans arrive at
/// safe boundaries, stale cues and transports are discarded or replanned, transcripts refine only
/// later blocks, and memory advances only for posted plans.
@Suite(.serialized, .responsivePool)
struct DialogueRuntimeTests {
    static let bpm = 70.0
    static var beat: Double { 60 / bpm }
    static var bar: Double { 4 * beat }

    static let fixture: SpeechFixture = {
        var o = DialogueFixtures.Options()
        o.seconds = 12
        o.sentences = ["the night was cold, the band played on.", "listen to the rhythm of the city.",
                       "keep your eyes on the road ahead."]
        return DialogueFixtures.speech(o)
    }()

    static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    static func info(origin: Double, revision: UInt32 = 1) -> LofiTransportInfo {
        LofiTransportInfo(revision: revision, takeIndex: 0, phraseAtTakeStart: 0, origin: origin, beatDuration: beat,
                          nextBeatDuration: nil, seed: 5, options: LofiOptions(tempo: bpm), timing: nil)
    }

    /// Posts in arrival order with their uptime.
    final class Recorder: @unchecked Sendable {
        private let items = Mutex<[(time: Double, plan: ArchiveVoice.ChopPlan)]>([])
        func add(_ plan: ArchiveVoice.ChopPlan) { items.withLock { $0.append((DialogueRuntimeTests.uptime(), plan)) } }
        var plans: [ArchiveVoice.ChopPlan] { items.withLock { $0.map(\.plan) } }
    }

    /// Counts transport reads and switches to another revision (or to nil) after the first.
    final class Transport: @unchecked Sendable {
        private let calls = Mutex(0)
        let first: LofiTransportInfo
        let later: LofiTransportInfo?
        init(_ first: LofiTransportInfo, later: LofiTransportInfo?) { self.first = first; self.later = later }
        func read() -> LofiTransportInfo? {
            calls.withLock { n in
                n += 1
                return n == 1 ? first : later
            }
        }
    }

    struct HangingProvider: TranscriptProvider {
        func transcript(for source: DialogueSource, deadline: ContinuousClock.Instant) async -> DialogueTranscript? {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
    }

    private func run(_ director: DialogueDirector, token: Int = 1, info: LofiTransportInfo, window: Range<Double>,
                     transport: (@Sendable () -> LofiTransportInfo?)? = nil, current: @escaping @Sendable () -> Bool = { true },
                     recorder: Recorder) -> Task<DialogueDirector.Outcome, Never> {
        let source = Self.fixture.source(contentID: "runtime", cueToken: token)
        let read = transport ?? { info }
        return Task.detached(priority: .utility) {
            await director.run(source: source, window: window, seed: 9, transport: read, isCurrent: current,
                               post: { recorder.add($0) })
        }
    }

    // MARK: Deadlines

    @Test func bedIsPostedOnTimeWhileASlowAnalysisRunsAndThePlanStartsAtTheNextBar() async throws {
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }, analysisDelay: .seconds(5)))
        // Synthesize the shared fixture before the clock starts, so its cost is not counted as lateness.
        _ = Self.fixture
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let due = start + 0.6
        let window = DialogueCueCoordinator.window(due: due, span: 8 * Self.bar, transport: info)
        let recorder = Recorder()
        let task = run(director, info: info, window: window, recorder: recorder)
        // The footage service's wait-and-post loop runs beside the coordinator task.
        while Self.uptime() < due { try await Task.sleep(for: .milliseconds(4)) }
        let bedLateness = Self.uptime() - due
        #expect(bedLateness < 0.05, "bed posted \(bedLateness) s late")
        #expect(recorder.plans.isEmpty, "no plan before the analysis finishes")
        let outcome = await task.value
        let ready = try #require(outcome.readyAt)
        #expect(ready - start >= 5)
        let plan = try #require(recorder.plans.first)
        let first = try #require(plan.chops.map(\.event.startTime).min())
        let earliest = ready + DialogueCueCoordinator.commitMargin
        let nextBar = info.origin + ((earliest - info.origin) / Self.bar - 1e-9).rounded(.up) * Self.bar
        #expect(first >= nextBar - 1e-6, "first chop \(first - start) s, next bar \(nextBar - start) s")
        #expect(plan.chops.allSatisfy { $0.event.startTime >= earliest })
        #expect(director.memory.pieceCounter == 1)
    }

    @Test func aStaleCueTokenPostsNothingAndLeavesMemoryAlone() async throws {
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.5, span: 8 * Self.bar, transport: info)
        let recorder = Recorder()
        let outcome = await run(director, info: info, window: window, current: { false }, recorder: recorder).value
        #expect(recorder.plans.isEmpty)
        #expect(outcome.discarded == "staleCue")
        #expect(director.memory.pieceCounter == 0)
        #expect(director.generation == 0)
    }

    @Test func aTransportRevisionChangeRebuildsOrDiscards() async throws {
        let start = Self.uptime()
        let first = Self.info(origin: start, revision: 1)
        let window = DialogueCueCoordinator.window(due: start + 0.5, span: 8 * Self.bar, transport: first)
        // Tempo change while analysing: the analysis and bank are kept and the plan is rebuilt.
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        let changed = Transport(first, later: Self.info(origin: start, revision: 2))
        let recorder = Recorder()
        let outcome = await run(director, info: first, window: window, transport: { changed.read() }, recorder: recorder).value
        #expect(recorder.plans.count == 1)
        let rebuilt = try #require(outcome.built.first)
        #expect(rebuilt.plan.transportRevision == 2)
        #expect(rebuilt.timings.analyzeMs == 0 && rebuilt.timings.bankMs == 0, "analysis and bank reused")
        // Stop while analysing: the transport is gone and nothing is posted.
        let stopped = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        let gone = Transport(first, later: nil)
        let none = Recorder()
        let discarded = await run(stopped, info: first, window: window, transport: { gone.read() }, recorder: none).value
        #expect(none.plans.isEmpty)
        #expect(discarded.discarded == "transportGone")
        #expect(stopped.memory.pieceCounter == 0)
    }

    // MARK: Transcripts

    @Test func aTranscriptBeforeTheSecondBlockReplacesOnlyLaterChops() async throws {
        let transcript = DialogueFixtures.transcript(Self.fixture)
        let director = DialogueDirector(.neutral(transcriptProvider: {
            FixtureTranscriptProvider(transcript, delay: .milliseconds(300))
        }))
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.2, span: 8 * Self.bar, transport: info)
        let recorder = Recorder()
        let outcome = await run(director, info: info, window: window, recorder: recorder).value
        let plans = recorder.plans
        try #require(plans.count == 2, "acoustic plan then the refined one")
        #expect(plans[0].revision == 0 && plans[1].revision == 1)
        let secondBlock = info.origin + 16 * Self.beat
        #expect(abs(plans[1].replaceFrom - secondBlock) < 1e-6)
        #expect(plans[1].chops.allSatisfy { $0.event.startTime >= plans[1].replaceFrom })
        #expect(outcome.transcriptUsed)
        #expect(outcome.built.last?.bank?.usedTranscript == true)
        #expect(director.memory.pieceCounter == 1, "the refined plan keeps the cue's piece")
        #expect(director.generation == 2)
    }

    @Test func aLateTranscriptChangesNothingButIsCached() async throws {
        let transcript = DialogueFixtures.transcript(Self.fixture)
        let director = DialogueDirector(.neutral(transcriptProvider: {
            FixtureTranscriptProvider(transcript, delay: .milliseconds(2000))
        }))
        let start = Self.uptime()
        // The second block starts 2.7 s from now, so a transcript is useful only until 1.4 s.
        let info = Self.info(origin: start + 2.7 - 16 * Self.beat)
        let window = (start + 0.2)..<(info.origin + 32 * Self.beat)
        let recorder = Recorder()
        let outcome = await run(director, info: info, window: window, recorder: recorder).value
        #expect(recorder.plans.count == 1)
        #expect(outcome.transcriptArrivedAt != nil)
        #expect(!outcome.transcriptUsed)
        let source = Self.fixture.source(contentID: "runtime", cueToken: 1)
        #expect(director.cachedTranscript(source) == transcript)
        #expect(director.cached(source)?.bank?.usedTranscript == true, "a later appearance starts from the refined bank")
    }

    @Test(arguments: ["nil", "timeout", "cancel"]) func providerFailuresLeaveTheAcousticPlan(_ mode: String) async throws {
        let transcript = DialogueFixtures.transcript(Self.fixture)
        let provider: @Sendable () -> any TranscriptProvider = switch mode {
        case "nil": { FixtureTranscriptProvider(nil) }
        case "timeout": { FixtureTranscriptProvider(transcript, delay: .seconds(3)) }
        default: { HangingProvider() }
        }
        let director = DialogueDirector(.neutral(transcriptProvider: provider, transcriptCap: 1))
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.2, span: 8 * Self.bar, transport: info)
        let recorder = Recorder()
        let task = run(director, info: info, window: window, recorder: recorder)
        if mode == "cancel" {
            while recorder.plans.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            task.cancel()
        }
        let began = Self.uptime()
        let outcome = await task.value
        #expect(Self.uptime() - began < 2.5)
        #expect(recorder.plans.count == 1)
        #expect(recorder.plans.first?.revision == 0)
        #expect(!outcome.transcriptUsed)
        #expect(director.memory.pieceCounter == 1)
    }

    // MARK: Cancellation and memory

    @Test func cueReplacementAndStopCancelTheTask() async throws {
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }, analysisDelay: .seconds(3)))
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.5, span: 8 * Self.bar, transport: info)
        let recorder = Recorder()
        let task = run(director, info: info, window: window, recorder: recorder)
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let began = Self.uptime()
        let outcome = await task.value
        #expect(Self.uptime() - began < 1)
        #expect(recorder.plans.isEmpty)
        #expect(outcome.discarded == "cancelled")
        #expect(director.memory.pieceCounter == 0)
    }

    @Test func memoryAdvancesOnlyForPostedPlans() async throws {
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.5, span: 8 * Self.bar, transport: info)
        _ = await run(director, token: 1, info: info, window: window, current: { false }, recorder: Recorder()).value
        #expect(director.memory.pieceCounter == 0)
        let recorder = Recorder()
        let outcome = await run(director, token: 2, info: info, window: window, recorder: recorder).value
        #expect(recorder.plans.count == 1)
        #expect(director.memory.pieceCounter == 1)
        let built = try #require(outcome.built.first)
        #expect(director.memory.blocks.map(\.fingerprint) == built.memory.blocks.map(\.fingerprint))
    }

    // MARK: Cache and transport

    @Test func bankCacheReturnsTheSameBankAndEvictsBeyondItsSize() throws {
        let director = DialogueDirector()
        let source = Self.fixture.source(contentID: "cache-0")
        let start = 100.0
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start, span: 8 * Self.bar, transport: info)
        let built = DialogueCueCoordinator.build(source: source, speech: [], transcript: nil, transport: info, window: window,
                                                 earliestStart: start + 0.3, memory: DialoguePerformanceMemory(), seed: 4)
        let bank = try #require(built.bank)
        director.store(source, analysis: built.analysis, bank: built.bank)
        let hit = try #require(director.cached(Self.fixture.source(contentID: "cache-0", cueToken: 9)))
        #expect(hit.bank?.bankID == bank.bankID)
        let reused = DialogueCueCoordinator.build(source: source, speech: [], transcript: nil, transport: info, window: window,
                                                  earliestStart: start + 0.3, memory: DialoguePerformanceMemory(), seed: 4,
                                                  reuse: hit)
        #expect(reused.plan.bankID == bank.bankID && reused.timings.analyzeMs == 0)
        for i in 1...DialogueDirector.cacheEntries {
            director.store(Self.fixture.source(contentID: "cache-\(i)"), analysis: built.analysis, bank: built.bank)
        }
        let counts = director.cacheCount
        #expect(counts.entries == DialogueDirector.cacheEntries)
        #expect(counts.withPCM == DialogueDirector.cacheWithPCM)
        #expect(director.cached(source) == nil, "the oldest entry is evicted")
        #expect(director.cached(Self.fixture.source(contentID: "cache-1")) != nil)
    }

    @Test func transportSnapshotAndWindowFollowTheTake() throws {
        let clock = LofiClock(tempo: Self.bpm, sampleRate: 48_000)
        let landmarks = (0..<16).flatMap { bar -> [LofiDrumLandmark] in
            let b = Double(bar * 4)
            return [LofiDrumLandmark(kind: .kick, attackFrame: clock.frame(at: b), peakFrame: clock.frame(at: b) + 40,
                                     strength: 1, confidence: 0.9),
                    LofiDrumLandmark(kind: .snare, attackFrame: clock.frame(at: b + 1), peakFrame: clock.frame(at: b + 1) + 40,
                                     strength: 1, confidence: 0.8)]
        }
        let timing = LofiTimingField(landmarks: landmarks, clock: clock)
        let info = LofiTransportInfo(revision: 3, takeIndex: 2, phraseAtTakeStart: 8, origin: 50, beatDuration: Self.beat,
                                     nextBeatDuration: nil, seed: 5, options: LofiOptions(tempo: Self.bpm), timing: timing)
        // A bed tail past the fill boundary never opens another block.
        let window = DialogueCueCoordinator.window(due: 50 + 32 * Self.beat, span: 32 * Self.beat + 0.25, transport: info)
        #expect(abs(window.upperBound - (50 + 64 * Self.beat)) < 1e-9)
        let snapshot = DialogueCueCoordinator.snapshot(info, window: window)
        #expect(snapshot.phraseAtOrigin == 8 && snapshot.revision == 3)
        #expect(snapshot.kicks.count == 16 && snapshot.snares.count == 16)
        #expect(abs(snapshot.snares[3].beat - 13) < 1e-3)
        #expect(DialogueCueCoordinator.blocks(snapshot, window: window) == 2...3)
        #expect(!snapshot.leadNotes.isEmpty)
        #expect(snapshot.leadNotes.allSatisfy { $0.lowerBound >= 32 && $0.lowerBound < 64 })
    }
}

/// The synthetic voice is not reliably classified as speech by SoundAnalysis; these tests are about
/// scheduling, so classification returns no windows (neutral weights), as when it times out.
extension DialogueDirector.Settings {
    static func neutral(transcriptProvider: @escaping @Sendable () -> any TranscriptProvider,
                        analysisDelay: Duration = .zero, transcriptCap: Double = DialogueCueCoordinator.transcriptCap) -> Self {
        var s = Self(transcriptProvider: transcriptProvider, analysisDelay: analysisDelay, transcriptCap: transcriptCap)
        s.classify = { _, _, _ in [] }
        return s
    }
}
