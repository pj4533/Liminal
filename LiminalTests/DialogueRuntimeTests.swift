import AVFoundation
import AudioKit
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
            FixtureTranscriptProvider(transcript, delay: .milliseconds(3000))
        }))
        let salience = DialogueSalienceIndex()
        director.configure { $0.salienceIndex = salience }
        let start = Self.uptime()
        // The second block starts 4.0 s from now, so a transcript is useful only until 2.7 s.
        let info = Self.info(origin: start + 4.0 - 16 * Self.beat)
        let window = (start + 0.2)..<(info.origin + 32 * Self.beat)
        let recorder = Recorder()
        let outcome = await run(director, info: info, window: window, recorder: recorder).value
        #expect(recorder.plans.count == 1)
        #expect(outcome.transcriptArrivedAt != nil)
        #expect(!outcome.transcriptUsed)
        let source = Self.fixture.source(contentID: "runtime", cueToken: 1)
        #expect(director.cachedTranscript(source) == transcript)
        #expect(!salience.entry(contentID: "runtime").spans.isEmpty, "late transcripts also populate the salience index")
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

    // MARK: Integration (handoff "Implementation phases and acceptance")

    @Test func aCueReplacedWhileItsPlanIsBuiltPostsOnlyTheNewCue() async throws {
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }, analysisDelay: .milliseconds(800)))
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.3, span: 8 * Self.bar, transport: info)
        let current = Mutex(1)
        let recorder = Recorder()
        let first = run(director, token: 1, info: info, window: window, current: { current.withLock { $0 == 1 } }, recorder: recorder)
        try await Task.sleep(for: .milliseconds(200))
        // The weaver replaces the piece: the old cue is no longer current, the new one starts.
        current.withLock { $0 = 2 }
        let second = run(director, token: 2, info: info, window: window, current: { current.withLock { $0 == 2 } }, recorder: recorder)
        let old = await first.value
        let new = await second.value
        #expect(old.discarded == "staleCue")
        #expect(new.discarded == nil)
        #expect(recorder.plans.map(\.token) == [2])
        #expect(director.memory.pieceCounter == 1, "only the posted cue advanced the memory")
    }

    @Test func stopThenRestartPlansAgainstTheNewTransport() async throws {
        let start = Self.uptime()
        let before = Self.info(origin: start, revision: 1)
        let window = DialogueCueCoordinator.window(due: start + 0.3, span: 8 * Self.bar, transport: before)
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        // Stop while analysing: the transport disappears.
        let gone = Transport(before, later: nil)
        let none = Recorder()
        let stopped = await run(director, info: before, window: window, transport: { gone.read() }, recorder: none).value
        #expect(stopped.discarded == "transportGone" && none.plans.isEmpty)
        // Restart: a new transport revision and origin; the cached analysis is reused.
        let restartOrigin = Self.uptime() + 0.2
        let after = Self.info(origin: restartOrigin, revision: 2)
        let restartWindow = DialogueCueCoordinator.window(due: restartOrigin, span: 8 * Self.bar, transport: after)
        let recorder = Recorder()
        let outcome = await run(director, token: 2, info: after, window: restartWindow, recorder: recorder).value
        let built = try #require(outcome.built.first)
        #expect(recorder.plans.count == 1)
        #expect(built.plan.transportRevision == 2)
        #expect(built.timings.analyzeMs == 0, "the analysis cached before the stop is reused")
        #expect(built.plan.events.allSatisfy { $0.startTime >= restartOrigin })
        #expect(director.memory.pieceCounter == 1)
    }

    @Test func aTempoChangeDuringRecognitionKeepsTheAnalysisAndRebuildsThePlan() async throws {
        let transcript = DialogueFixtures.transcript(Self.fixture)
        let director = DialogueDirector(.neutral(transcriptProvider: {
            FixtureTranscriptProvider(transcript, delay: .milliseconds(700))
        }))
        let start = Self.uptime()
        let first = Self.info(origin: start, revision: 1)
        // After the acoustic plan is posted the next take is committed at 80 BPM.
        let faster = LofiTransportInfo(revision: 2, takeIndex: 0, phraseAtTakeStart: 0, origin: start, beatDuration: 60.0 / 80,
                                       nextBeatDuration: nil, seed: 5, options: LofiOptions(tempo: 80), timing: nil)
        let window = DialogueCueCoordinator.window(due: start + 0.2, span: 8 * Self.bar, transport: first)
        let posted = Mutex(false)
        let recorder = Recorder()
        let source = Self.fixture.source(contentID: "runtime", cueToken: 1)
        let outcome = await Task.detached(priority: .utility) {
            await director.run(source: source, window: window, seed: 9,
                               transport: { posted.withLock { $0 } ? faster : first }, isCurrent: { true },
                               post: { recorder.add($0); posted.withLock { $0 = true } })
        }.value
        let plans = recorder.plans
        try #require(plans.count == 2, "acoustic plan, then the rebuilt one")
        #expect(plans[1].revision == 1)
        let rebuilt = try #require(outcome.built.last)
        #expect(rebuilt.plan.transportRevision == 2)
        #expect(rebuilt.timings.analyzeMs == 0, "the analysis is kept")
        #expect(plans[1].chops.allSatisfy { $0.event.startTime >= plans[1].replaceFrom })
        // Every accent of the rebuilt plan sits on the new 80 BPM sixteenth grid (plus the gesture offset).
        let sixteenth = 60.0 / 80 / 4
        for chop in plans[1].chops {
            let position = (chop.event.accentTime - start) / sixteenth
            let error = abs(position - position.rounded()) * sixteenth
            #expect(error <= DialogueTuning.gestureOffsetSeconds.upperBound + 1e-6, "accent \(error) s off the new grid")
        }
        #expect(director.memory.pieceCounter == 1, "the rebuilt plan replaces the cue's piece")
        #expect(director.cachedTranscript(source) == transcript)
    }

    @Test func aTransportThatNeverSettlesCommitsNothing() async throws {
        final class Moving: @unchecked Sendable {
            let n = Mutex<UInt32>(0)
            let origin: Double
            init(_ origin: Double) { self.origin = origin }
            func read() -> LofiTransportInfo? { DialogueRuntimeTests.info(origin: origin, revision: n.withLock { $0 += 1; return $0 }) }
        }
        let start = Self.uptime()
        let moving = Moving(start)
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.3, span: 8 * Self.bar, transport: info)
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        let recorder = Recorder()
        let outcome = await run(director, info: info, window: window, transport: { moving.read() }, recorder: recorder).value
        #expect(recorder.plans.isEmpty)
        #expect(outcome.discarded == "unsettledTransport")
        #expect(director.memory.pieceCounter == 0 && director.generation == 0, "no stale revision is committed")
    }

    @Test func aWindowAcrossTheTakeTurnUsesTheNextTakesTempo() throws {
        let origin = 200.0
        let next = 60.0 / 64
        let info = LofiTransportInfo(revision: 4, takeIndex: 0, phraseAtTakeStart: 0, origin: origin, beatDuration: Self.beat,
                                     nextBeatDuration: next, seed: 5, options: LofiOptions(tempo: Self.bpm), timing: nil)
        // A piece that starts eight bars before the turn and runs eight bars past it.
        let due = origin + 56 * Self.beat
        let turn = origin + 64 * Self.beat
        let window = due..<(turn + 32 * next)
        let source = Self.fixture.source(contentID: "turn")
        var memory = DialoguePerformanceMemory()
        var found = 0
        for seed in 0..<12 {
            let built = DialogueCueCoordinator.build(source: source, speech: [], transcript: nil, transport: info, window: window,
                                                     earliestStart: due, memory: memory, seed: UInt64(seed))
            memory = built.memory
            for e in built.plan.events where e.accentTime > turn + 0.05 {
                found += 1
                let position = (e.accentTime - turn) / (next / 4)
                let error = abs(position - position.rounded()) * next / 4
                #expect(error <= DialogueTuning.gestureOffsetSeconds.upperBound + 1e-6, "accent \(error) s off the next take's grid")
            }
            // The motif's turnaround may land one piece on the next loop's downbeat, inside the chop tail.
            #expect(built.plan.events.allSatisfy {
                $0.startTime >= due && $0.startTime < window.upperBound
                    && $0.endTime <= window.upperBound + DialogueMotifTuning.tailAfterBedSeconds + 1e-6
            })
        }
        #expect(found > 0, "some events fall in the next take")
    }

    @Test func identicalInputsGiveIdenticalPlansAndLogs() throws {
        let start = 300.0
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start, span: 8 * Self.bar, transport: info)
        func build() -> DialogueCueCoordinator.Built {
            DialogueCueCoordinator.build(source: Self.fixture.source(contentID: "same"), speech: [], transcript: nil, transport: info,
                                         window: window, earliestStart: start + 0.3, memory: DialoguePerformanceMemory(), seed: 21)
        }
        let a = build(), b = build()
        #expect(a.plan.bankID == b.plan.bankID && a.plan.analysisVersion == DialogueEngine.analysisVersion)
        #expect(a.plan.events == b.plan.events)
        #expect(a.plan.blocks.map(\.fingerprint) == b.plan.blocks.map(\.fingerprint))
        for (x, y) in zip(a.chops, b.chops) {
            let n = Int(x.buffer.frameLength)
            #expect(n == Int(y.buffer.frameLength))
            #expect(memcmp(x.buffer.floatChannelData![0], y.buffer.floatChannelData![0], n * 4) == 0, "chop buffers are bit-identical")
        }
        let logA = try JSONSerialization.data(withJSONObject: a.log, options: [.sortedKeys])
        let logB = try JSONSerialization.data(withJSONObject: b.log, options: [.sortedKeys])
        #expect(logA == logB)
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
        // The cached analysis and bank are reused; the motif bank cut from them is the same too.
        #expect(reused.bank?.bankID == bank.bankID && reused.plan.bankID == built.plan.bankID && reused.timings.analyzeMs == 0)
        for i in 1...DialogueDirector.cacheEntries {
            director.store(Self.fixture.source(contentID: "cache-\(i)"), analysis: built.analysis, bank: built.bank)
        }
        #expect(director.cacheCount == DialogueDirector.cacheEntries)
        #expect(director.cached(source) == nil, "the oldest entry is evicted")
        #expect(director.cached(Self.fixture.source(contentID: "cache-1")) != nil)
    }

    // MARK: Route recovery, cache key and cost (fix1-A)

    /// Sixteenth-grid error of every accent against a transport origin.
    private static func gridError(_ chops: [DialogueChop], origin: Double, beat: Double = beat) -> Double {
        let sixteenth = beat / 4
        return chops.map { chop in
            let position = (chop.event.accentTime - origin) / sixteenth
            return abs(position - position.rounded()) * sixteenth
        }.max() ?? 0
    }

    /// `GenerativeEngine.recoverStoppedGraph` re-arms the transport: a new revision on a new origin that is
    /// off the old sixteenth grid. A bump while the plan is built replans on the new grid; nothing is
    /// posted against the old revision.
    @Test func aRouteRecoveryRevisionBumpMidPlanReplansOnTheNewGrid() async throws {
        let start = Self.uptime()
        let old = Self.info(origin: start, revision: 1)
        // 0.37 s is 1.73 sixteenths at 70 BPM: no chop of the old grid fits the new one.
        let rearmed = Self.info(origin: start + 0.37, revision: 2)
        let window = DialogueCueCoordinator.window(due: start + 0.5, span: 8 * Self.bar, transport: old)
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        let bump = Transport(old, later: rearmed)
        let recorder = Recorder()
        let outcome = await run(director, info: old, window: window, transport: { bump.read() }, recorder: recorder).value
        try #require(recorder.plans.count == 1, "one plan, built on the re-armed transport")
        #expect(outcome.built.allSatisfy { $0.plan.transportRevision == 2 }, "no plan against the old revision")
        let built = try #require(outcome.built.first)
        #expect(built.snapshot.origin == rearmed.origin)
        let chops = recorder.plans[0].chops
        try #require(!chops.isEmpty)
        let slack = DialogueTuning.gestureOffsetSeconds.upperBound + 1e-6
        #expect(Self.gridError(chops, origin: rearmed.origin) <= slack, "chops sit on the re-armed grid")
        #expect(Self.gridError(chops, origin: old.origin) > slack, "and not on the stale one")
    }

    /// The same bump after the acoustic plan is posted (recovery while the transcript runs): the stale
    /// plan is replaced from the commit margin with revision 1 chops on the new grid only.
    @Test func aRouteRecoveryAfterThePlanIsPostedRebuildsItOnTheNewGrid() async throws {
        let transcript = DialogueFixtures.transcript(Self.fixture)
        let director = DialogueDirector(.neutral(transcriptProvider: {
            FixtureTranscriptProvider(transcript, delay: .milliseconds(700))
        }))
        let start = Self.uptime()
        let old = Self.info(origin: start, revision: 1)
        let rearmed = Self.info(origin: start + 0.37, revision: 2)
        let window = DialogueCueCoordinator.window(due: start + 0.2, span: 8 * Self.bar, transport: old)
        let posted = Mutex(false)
        let recorder = Recorder()
        let source = Self.fixture.source(contentID: "runtime", cueToken: 1)
        let outcome = await Task.detached(priority: .utility) {
            await director.run(source: source, window: window, seed: 9,
                               transport: { posted.withLock { $0 } ? rearmed : old }, isCurrent: { true },
                               post: { recorder.add($0); posted.withLock { $0 = true } })
        }.value
        let plans = recorder.plans
        try #require(plans.count == 2, "the stale plan, then its rebuild")
        #expect(plans[1].revision > plans[0].revision, "the rebuild outranks the stale plan")
        let rebuilt = try #require(outcome.built.last)
        #expect(rebuilt.plan.transportRevision == 2)
        #expect(plans[1].chops.allSatisfy { $0.event.startTime >= plans[1].replaceFrom })
        if !plans[1].chops.isEmpty {
            #expect(Self.gridError(plans[1].chops, origin: rearmed.origin) <= DialogueTuning.gestureOffsetSeconds.upperBound + 1e-6)
        }
    }

    /// End to end through `ArchiveVoice`: the director's plans from a route-recovery bump are replayed
    /// into an offline engine whose voice is reset at the re-arm (`recoverStoppedGraph` stops the
    /// conductor, whose restart resets the voice). The stale revision's chops before the re-arm play;
    /// after it nothing of that cue is stored, queued, audible or ducking: neither the stale plan
    /// delivered late (still in flight across the restart) nor the rebuild for the bed that is gone.
    @MainActor @Test func aRouteRecoveryRearmSchedulesNoChopFromTheStalePlan() async throws {
        let transcript = DialogueFixtures.transcript(Self.fixture)
        let director = DialogueDirector(.neutral(transcriptProvider: {
            FixtureTranscriptProvider(transcript, delay: .milliseconds(700))
        }))
        let start = Self.uptime()
        let old = Self.info(origin: start, revision: 1)
        let rearmed = Self.info(origin: start + 0.37, revision: 2)
        let window = DialogueCueCoordinator.window(due: start + 0.2, span: 8 * Self.bar, transport: old)
        let posted = Mutex(false)
        let recorder = Recorder()
        let source = Self.fixture.source(contentID: "runtime", cueToken: 1)
        _ = await Task.detached(priority: .utility) {
            await director.run(source: source, window: window, seed: 9,
                               transport: { posted.withLock { $0 } ? rearmed : old }, isCurrent: { true },
                               post: { recorder.add($0); posted.withLock { $0 = true } })
        }.value
        let plans = recorder.plans
        try #require(plans.count == 2, "the stale plan, then its rebuild")
        let stale = plans[0], rebuild = plans[1]
        try #require(stale.chops.count >= 2)

        // Offline the transport is conductor seconds: shift the plans so the first stale chop lands at
        // 1.0 s, with impulses for buffers so an onset is one sample.
        let engine = GenerativeEngine(seed: 21)
        let format = engine.archiveFormat
        let rate = format.sampleRate
        let impulse = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        impulse.frameLength = 64
        for c in 0..<Int(format.channelCount) {
            for i in 0..<64 { impulse.floatChannelData![c][i] = i == 0 ? 1 : 0 }
        }
        let bed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8 * rate)))
        bed.frameLength = bed.frameCapacity
        for c in 0..<Int(format.channelCount) { bed.floatChannelData![c].update(repeating: 0, count: Int(bed.frameLength)) }
        let firstStale = try #require(stale.chops.map(\.event.startTime).min())
        let shift = 1.0 - firstStale
        func moved(_ plan: ArchiveVoice.ChopPlan) -> ArchiveVoice.ChopPlan {
            let chops = plan.chops.map { chop -> DialogueChop in
                let e = chop.event
                let event = DialogueEvent(padID: e.padID, role: e.role, block: e.block, slot: e.slot,
                                          accentTime: e.accentTime + shift, startTime: e.startTime + shift,
                                          duration: 64 / rate, gainDB: 0, protected: false, chokeAt: nil, text: nil,
                                          transform: .native, padKey: e.padKey, snareLanded: false)
                return DialogueChop(event: event, buffer: impulse)
            }
            return .init(token: plan.token, revision: plan.revision, replaceFrom: plan.replaceFrom + shift,
                         chops: chops, bedDuck: plan.bedDuck)
        }
        let stalePlan = moved(stale), rebuildPlan = moved(rebuild)
        let first = 1.0, rearm = 1.4, seconds = 3.2
        let staleAfter = stalePlan.chops.map(\.event.startTime).filter { $0 > rearm + 0.05 && $0 < seconds - 0.1 }

        engine.engine.output = Mixer(engine.archive.strip.outputs.dry, engine.archive.chopOutput)
        var steps = Set<String>()
        func once(_ key: String, _ body: () -> Void) { if steps.insert(key).inserted { body() } }
        var queuedBefore = 0
        var countsAfter: (stored: Int, queued: Int)?
        var duckedAfterRearm = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rearm-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try engine.renderOffline(seconds: seconds, to: url, beatDuration: Self.beat) { t in
            if t >= 0.2 { once("bed") { engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "rearm", token: 1))) } }
            if t >= 0.3 { once("stale") { engine.post(.chops(stalePlan)) } }
            if t >= first + 0.1 { once("queued") { queuedBefore = engine.archive.chopCounts.queued } }
            if t >= rearm { once("rearm") { engine.archive.reset(now: t) } }
            // The stale plan was still in flight across the restart, then the rebuild arrives.
            if t >= rearm + 0.05 { once("late") { engine.post(.chops(stalePlan)) } }
            if t >= rearm + 0.1 { once("rebuild") { engine.post(.chops(rebuildPlan)) } }
            if t >= rearm + 0.3 { once("counts") { countsAfter = engine.archive.chopCounts } }
            if t > rearm + 0.05 && engine.archive.isMusicDucked { duckedAfterRearm = true }
        }
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let x = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        let threshold = 0.75 * ArchiveVoice.ChopBus.dryGain
        func onset(near time: Double) -> Int? {
            let lo = max(0, Int((time - 0.05) * rate)), hi = min(x.count, Int((time + 0.05) * rate))
            return (lo..<hi).first { abs(x[$0]) > threshold }
        }
        #expect(queuedBefore >= 1, "the stale plan was live before the re-arm")
        #expect(onset(near: first) != nil, "its chop before the re-arm plays")
        let counts = try #require(countsAfter)
        #expect(counts.stored == 0 && counts.queued == 0, "nothing of the cue is scheduled after the re-arm: \(counts)")
        #expect(!duckedAfterRearm, "no inaudible chop ducks the music")
        #expect(staleAfter.allSatisfy { onset(near: $0) == nil }, "no stale chop sounds after the re-arm")
        let tail = x[Int((rearm + 0.05) * rate)...]
        #expect(!tail.contains { abs($0) > threshold }, "the chop output stays below the dry line after the re-arm")
    }

    @Test func theBankCacheKeepsOneEntryPerPlaybackRate() throws {
        let director = DialogueDirector()
        let native = Self.fixture.source(contentID: "film", sourceStart: 12.5, rate: 1)
        let slowed = Self.fixture.source(contentID: "film", sourceStart: 12.5, rate: 0.985)
        for source in [native, slowed] {
            let analysis = DialogueEngine.analyze(source, speech: [])
            director.store(source, analysis: analysis, bank: DialogueEngine.bank(analysis, transcript: nil, seed: 4))
        }
        #expect(DialogueDirector.CacheKey(native) != DialogueDirector.CacheKey(slowed))
        #expect(director.cacheCount == 2, "two rates are two entries")
        #expect(try #require(director.cached(native)).analysis.clock.rate == 1)
        #expect(try #require(director.cached(slowed)).analysis.clock.rate == 0.985)
        // A rate that rounds to the same key but differs is still a miss (a different time base).
        #expect(director.cached(Self.fixture.source(contentID: "film", sourceStart: 12.5, rate: 1.0004)) == nil)
    }

    @Test func eachPlanLogsThermalStateFootprintAndCacheSize() async throws {
        let director = DialogueDirector(.neutral(transcriptProvider: { NullTranscriptProvider() }))
        let start = Self.uptime()
        let info = Self.info(origin: start)
        let window = DialogueCueCoordinator.window(due: start + 0.3, span: 8 * Self.bar, transport: info)
        let outcome = await run(director, info: info, window: window, recorder: Recorder()).value
        let built = try #require(outcome.built.first)
        let entry = built.timings.dictionary(cue: 1)
        for key in ["classifyMs", "analyzeMs", "bankMs", "planMs", "renderMs", "totalMs"] { #expect(entry[key] is Double, "\(key)") }
        let thermal = try #require(entry["thermalState"] as? String)
        #expect(["nominal", "fair", "serious", "critical"].contains(thermal))
        #expect(try #require(entry["residentMB"] as? Double) > 1)
        #expect(entry["cacheEntries"] as? Int == 1)
        #expect(try #require(entry["cacheBytes"] as? Int) > 1000)
        #expect(JSONSerialization.isValidJSONObject(entry))
        print("DIALOGUE-COST \(entry.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
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
                        analysisDelay: Swift.Duration = .zero, transcriptCap: Double = DialogueCueCoordinator.transcriptCap,
                        transcriptFirstWait: Double = 0) -> Self {
        var s = Self(transcriptProvider: transcriptProvider, analysisDelay: analysisDelay, transcriptCap: transcriptCap)
        s.classify = { _, _, _ in [] }
        // The two-revision flow (acoustic plan, then the refinement) unless a test asks for the first-plan wait (D124).
        s.transcriptFirstWait = transcriptFirstWait
        return s
    }
}
