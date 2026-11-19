import AVFoundation
import Foundation
import os

/// Dialogue work for one footage cue (plan 6.2). The film bed never waits for any of this: the
/// footage service posts the bed at its due time and this runs beside it at utility priority.
/// `build` is the pure, synchronous core shared by the live task and the offline capture.
nonisolated enum DialogueCueCoordinator {
    /// No event is committed closer than this to its start (plan 6.1).
    static let commitMargin = 0.30
    /// SoundAnalysis speech windows: after this the analysis proceeds with what arrived.
    static let classifyBudget = 0.9
    /// Transcription's own cap (plan 6.1).
    static let transcriptCap = 8.0
    /// A transcript replans only blocks that start at least this far after its arrival.
    static let transcriptReplanMargin = 0.5
    /// A transcript must arrive this long before the second block's commit to be used.
    static let transcriptCommitGap = 1.0

    struct Timings: Sendable, Equatable {
        var classifyMs: Double = 0
        var analyzeMs: Double = 0
        var bankMs: Double = 0
        var planMs: Double = 0
        var renderMs: Double = 0
        var totalMs: Double { classifyMs + analyzeMs + bankMs + planMs + renderMs }

        /// The manifest's `dialogueTimings[]` element (plan 3.2).
        func dictionary(cue: Int) -> [String: Any] {
            var result: [String: Any] = ["cue": cue]
            for (key, value) in [("classifyMs", classifyMs), ("analyzeMs", analyzeMs), ("bankMs", bankMs),
                                 ("planMs", planMs), ("renderMs", renderMs), ("totalMs", totalMs)] {
                result[key] = (value * 10).rounded() / 10
            }
            return result
        }
    }

    /// An analysis and bank already computed for this source (bank cache or an earlier attempt).
    struct Reuse: @unchecked Sendable {
        let analysis: DialogueAnalysis
        let bank: DialoguePadBank?
        var transcript: DialogueTranscript? = nil
    }

    struct Built: @unchecked Sendable {
        let analysis: DialogueAnalysis
        /// The bank as built (what the cache keeps).
        let bank: DialoguePadBank?
        /// The bank as this piece played it (`DialoguePerformer.bankForPiece`: a recurring bank may
        /// hand its anchor role to a fresh line); the plan, chops and log refer to it.
        var played: DialoguePadBank? = nil
        let plan: DialoguePerformancePlan
        let chops: [DialogueChop]
        /// The performance memory after this plan; the owner commits it only when the plan is posted.
        let memory: DialoguePerformanceMemory
        let timings: Timings
        let snapshot: DialogueTransportSnapshot
        let window: Range<Double>
        let earliestStart: Double
        /// `DialogueEngine.log(plan, bank:)`, the `diagnostics.dialoguePlans` element.
        let log: [String: Any]

        var firstStart: Double? { chops.map(\.event.startTime).min() }
    }

    // MARK: Transport

    /// The take's timing field as take-relative beats with confidence, and the lead's notes for
    /// the phrases the window covers (from the pure score, so no audio is touched).
    static func snapshot(_ info: LofiTransportInfo, window: Range<Double>) -> DialogueTransportSnapshot {
        var kicks: [DialogueLandmark] = [], snares: [DialogueLandmark] = []
        if let timing = info.timing {
            for landmark in timing.landmarks {
                let mark = DialogueLandmark(beat: timing.beat(ofFrame: landmark.attackFrame), confidence: landmark.confidence)
                switch landmark.kind {
                case .kick: kicks.append(mark)
                case .snare: snares.append(mark)
                default: break
                }
            }
        }
        var snapshot = DialogueTransportSnapshot(revision: info.revision, takeIndex: info.takeIndex, origin: info.origin,
                                                 beatDuration: info.beatDuration, nextBeatDuration: info.nextBeatDuration,
                                                 phraseAtOrigin: info.phraseAtTakeStart, kicks: kicks, snares: snares)
        snapshot.leadNotes = leadNotes(info, blocks: blocks(snapshot, window: window))
        return snapshot
    }

    /// Take-relative block indices (4-bar phrases) that `window` touches.
    static func blocks(_ snapshot: DialogueTransportSnapshot, window: Range<Double>) -> ClosedRange<Int> {
        let first = Int((snapshot.beat(time: window.lowerBound) / 16 + 1e-9).rounded(.down))
        let last = max(first, Int((snapshot.beat(time: window.upperBound) / 16 - 1e-9).rounded(.up)) - 1)
        return first...last
    }

    static func leadNotes(_ info: LofiTransportInfo, blocks: ClosedRange<Int>) -> [ClosedRange<Double>] {
        var notes: [ClosedRange<Double>] = []
        for k in blocks {
            let phrase = info.phraseAtTakeStart + k
            guard phrase >= 0 else { continue }
            let request = LofiPlayback.Request(seed: info.seed, index: phrase, options: info.options)
            let score = LofiScore.make(seed: request.compositionSeed, section: request.section, drift: LofiDrift(seed: info.seed),
                                       startBeat: Double(phrase) * LofiClock.beats, pinnedScale: info.options.scale)
            let base = Double(k) * LofiClock.beats
            notes += score.notes.filter { $0.part == .lead }.map { (base + $0.beat)...(base + $0.beat + $0.length) }
        }
        return notes
    }

    /// The cue's transport window, ending at the 8-bar fill boundary that closes its piece, so a
    /// bed tail past the boundary never opens another block.
    static func window(due: Double, span: Double, transport info: LofiTransportInfo) -> Range<Double> {
        let grid = DialogueTransportSnapshot(revision: info.revision, takeIndex: info.takeIndex, origin: info.origin,
                                             beatDuration: info.beatDuration, nextBeatDuration: info.nextBeatDuration,
                                             phraseAtOrigin: info.phraseAtTakeStart, kicks: [], snares: [])
        let beat = grid.beat(time: due)
        let boundary = ((beat + 2) / 32).rounded(.down) * 32 + 32
        let end = min(due + max(0, span), grid.time(beat: boundary))
        return due..<max(due, end)
    }

    // MARK: Core

    /// Builds one plan: analysis (or reuse), bank, performance against the transport, render.
    /// Pure and synchronous; the memory is returned, never committed here.
    static func build(source: DialogueSource, speech: [LofiSpeechFocus.Window], transcript: DialogueTranscript?,
                      transport: LofiTransportInfo, window: Range<Double>, earliestStart: Double,
                      memory: DialoguePerformanceMemory, seed: UInt64, revision: Int = 0, classifyMs: Double = 0,
                      reuse: Reuse? = nil) -> Built {
        let clock = ContinuousClock()
        var timings = Timings(classifyMs: classifyMs)
        var t = clock.now
        let analysis = reuse?.analysis ?? DialogueEngine.analyze(source, speech: speech)
        if reuse == nil { timings.analyzeMs = ms(clock.now - t) }
        t = clock.now
        let bank: DialoguePadBank?
        if let reuse { bank = reuse.bank } else { bank = DialogueEngine.bank(analysis, transcript: transcript, seed: seed) }
        if reuse == nil { timings.bankMs = ms(clock.now - t) }
        t = clock.now
        let snapshot = snapshot(transport, window: window)
        var memory = memory
        let played = DialoguePerformer.bankForPiece(bank, snapshot: snapshot, window: window, memory: memory)
        let plan = DialogueEngine.perform(played, snapshot: snapshot, window: window, earliestStart: earliestStart,
                                          memory: &memory, seed: seed, cueToken: source.cueToken, revision: revision)
        timings.planMs = ms(clock.now - t)
        t = clock.now
        let chops = played.map { DialogueEngine.render(plan, bank: $0, source: source, analysis: analysis) } ?? []
        timings.renderMs = ms(clock.now - t)
        return Built(analysis: analysis, bank: bank, played: played, plan: plan, chops: chops, memory: memory, timings: timings,
                     snapshot: snapshot, window: window, earliestStart: earliestStart, log: DialogueEngine.log(plan, bank: played))
    }

    /// The transcript-refined plan for the blocks from `from` (a block start): the acoustic blocks
    /// before it are replayed on `memoryBefore` (same seed, so the same blocks and records), then the
    /// refined bank plans the rest. Nil when the transcript gives no bank.
    static func replan(_ acoustic: Built, memoryBefore: DialoguePerformanceMemory, source: DialogueSource,
                       transcript: DialogueTranscript, from: Double, seed: UInt64, revision: Int) -> Built? {
        let clock = ContinuousClock()
        var timings = Timings()
        var t = clock.now
        guard let refined = DialogueEngine.bank(acoustic.analysis, transcript: transcript, seed: seed) else { return nil }
        timings.bankMs = ms(clock.now - t)
        t = clock.now
        var memory = memoryBefore
        // The piece keeps the anchor choice it started with (decided on the memory before the cue).
        let rotated = DialoguePerformer.bankForPiece(refined, snapshot: acoustic.snapshot, window: acoustic.window, memory: memoryBefore) ?? refined
        if from > acoustic.window.lowerBound {
            _ = DialogueEngine.perform(acoustic.played ?? acoustic.bank, snapshot: acoustic.snapshot, window: acoustic.window.lowerBound..<from,
                                       earliestStart: acoustic.earliestStart, memory: &memory, seed: seed,
                                       cueToken: source.cueToken, revision: 0)
            memory.pieceCounter -= 1
        }
        let window = from..<acoustic.window.upperBound
        let plan = DialogueEngine.perform(rotated, snapshot: acoustic.snapshot, window: window,
                                          earliestStart: max(acoustic.earliestStart, from), memory: &memory, seed: seed,
                                          cueToken: source.cueToken, revision: revision)
        timings.planMs = ms(clock.now - t)
        t = clock.now
        let chops = DialogueEngine.render(plan, bank: rotated, source: source, analysis: acoustic.analysis)
        timings.renderMs = ms(clock.now - t)
        return Built(analysis: acoustic.analysis, bank: refined, played: rotated, plan: plan, chops: chops, memory: memory, timings: timings,
                     snapshot: acoustic.snapshot, window: window, earliestStart: max(acoustic.earliestStart, from),
                     log: DialogueEngine.log(plan, bank: rotated))
    }

    /// One log line per plan, and the capture report when the offline harness is running.
    static func report(_ built: Built, cue: Int, lead: Double?) {
        let families = built.plan.blocks.map(\.family.rawValue).joined(separator: ",")
        let t = built.timings
        let leadText = lead.map { String(format: "%.2f", $0) } ?? "-"
        LMLog.audio.info("Lo-Fi dialogue plan cue=\(cue) rev=\(built.plan.revision) bank=\(String(built.plan.bankID, radix: 16), privacy: .public) families=\(families, privacy: .public) events=\(built.chops.count) classify=\(t.classifyMs, format: .fixed(precision: 0))ms analyze=\(t.analyzeMs, format: .fixed(precision: 0))ms bank=\(t.bankMs, format: .fixed(precision: 0))ms plan=\(t.planMs, format: .fixed(precision: 0))ms render=\(t.renderMs, format: .fixed(precision: 0))ms lead=\(leadText, privacy: .public)s")
        if LofiCaptureHooks.isEnabled {
            var log = built.log
            log["timings"] = t.dictionary(cue: cue)
            if let lead { log["leadSeconds"] = (lead * 1000).rounded() / 1000 }
            LofiCaptureHooks.appendReport("dialoguePlans", log)
        }
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

/// Owner of the dialogue performance memory and the bank cache (plan 4.5, 6.2), held by the
/// footage service. Lock-guarded; thread completion order never selects a phrase because memory
/// is committed only for posted plans and checked against a generation counter.
nonisolated final class DialogueDirector: @unchecked Sendable {
    /// Entries that keep the source PCM, and entries kept in all (plan 4.5).
    static let cacheWithPCM = 4
    static let cacheEntries = 12

    struct CacheKey: Hashable, Sendable {
        let contentID: String
        /// Source start to 10 ms.
        let start: Int
        let frames: Int
        let analysisVersion: Int

        init(_ source: DialogueSource) {
            contentID = source.contentID
            start = Int((source.sourceStart * 100).rounded())
            frames = min(source.frameCount, Int(DialogueTuning.analysisSeconds * source.sampleRate))
            analysisVersion = DialogueEngine.analysisVersion
        }
    }

    private struct Entry {
        let key: CacheKey
        let analysis: DialogueAnalysis
        let acoustic: DialoguePadBank?
        /// Transcript-refined banks keyed by `locale|modelVersion`.
        var refined: [String: DialoguePadBank] = [:]
        var transcript: DialogueTranscript?
        /// PCM retained only by the newest `cacheWithPCM` entries.
        var source: DialogueSource?
    }

    private struct State {
        var memory = DialoguePerformanceMemory()
        var generation = 0
        /// Most recently used first.
        var cache: [Entry] = []
    }

    /// What one `run` did (tests and logs).
    struct Outcome: @unchecked Sendable {
        var posted: [ArchiveVoice.ChopPlan] = []
        var built: [DialogueCueCoordinator.Built] = []
        /// Transport seconds when the acoustic plan was ready to post.
        var readyAt: Double?
        var discarded: String?
        var transcriptArrivedAt: Double?
        var transcriptUsed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let settings: OSAllocatedUnfairLock<Settings>

    struct Settings: Sendable {
        var transcriptProvider: @Sendable () -> any TranscriptProvider = { DialogueTranscription.makeProvider() }
        /// Test seam: extra time spent after classification, standing in for slow analysis.
        var analysisDelay: Duration = .zero
        var transcriptCap = DialogueCueCoordinator.transcriptCap
        var now: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
        /// Bounded SoundAnalysis classification (buffer, seconds, budget). Tests may inject fixed windows.
        var classify: @Sendable (AVAudioPCMBuffer, Double, Double) async -> [LofiSpeechFocus.Window] = {
            await LofiSpeechFocus.classify($0, seconds: $1, budget: $2)
        }
    }

    init(_ settings: Settings = Settings()) {
        self.settings = OSAllocatedUnfairLock(initialState: settings)
    }

    func configure(_ body: (inout Settings) -> Void) { settings.withLock { body(&$0) } }

    var memory: DialoguePerformanceMemory { state.withLock { $0.memory } }
    var generation: Int { state.withLock { $0.generation } }
    var cacheCount: (entries: Int, withPCM: Int) {
        state.withLock { s in (s.cache.count, s.cache.filter { $0.source != nil }.count) }
    }

    func resetMemory() { state.withLock { $0.memory = DialoguePerformanceMemory(); $0.generation += 1 } }

    // MARK: Bank cache

    /// The cached analysis and bank for this source, with the transcript-refined bank when a
    /// transcript is cached for it.
    func cached(_ source: DialogueSource) -> DialogueCueCoordinator.Reuse? {
        let key = CacheKey(source)
        return state.withLock { s -> DialogueCueCoordinator.Reuse? in
            guard let index = s.cache.firstIndex(where: { $0.key == key }) else { return nil }
            var entry = s.cache.remove(at: index)
            if entry.source == nil { entry.source = source }
            s.cache.insert(entry, at: 0)
            Self.trim(&s.cache)
            if let transcript = entry.transcript, let refined = entry.refined[Self.model(transcript)] {
                return .init(analysis: entry.analysis, bank: refined, transcript: transcript)
            }
            return .init(analysis: entry.analysis, bank: entry.acoustic, transcript: entry.transcript)
        }
    }

    func store(_ source: DialogueSource, analysis: DialogueAnalysis, bank: DialoguePadBank?) {
        let key = CacheKey(source)
        state.withLock { s in
            if let index = s.cache.firstIndex(where: { $0.key == key }) {
                var entry = s.cache.remove(at: index)
                entry.source = source
                s.cache.insert(entry, at: 0)
            } else {
                s.cache.insert(Entry(key: key, analysis: analysis, acoustic: bank, source: source), at: 0)
            }
            Self.trim(&s.cache)
        }
    }

    /// A transcript (in time or late) and its refined bank, kept for a later appearance of the source.
    func store(_ source: DialogueSource, transcript: DialogueTranscript, refined: DialoguePadBank?) {
        let key = CacheKey(source)
        state.withLock { s in
            guard let index = s.cache.firstIndex(where: { $0.key == key }) else { return }
            s.cache[index].transcript = transcript
            if let refined { s.cache[index].refined[Self.model(transcript)] = refined }
        }
    }

    func cachedTranscript(_ source: DialogueSource) -> DialogueTranscript? {
        let key = CacheKey(source)
        return state.withLock { s in s.cache.first { $0.key == key }?.transcript }
    }

    func cachedBankID(_ source: DialogueSource) -> UInt64? {
        let key = CacheKey(source)
        return state.withLock { s in s.cache.first { $0.key == key }.flatMap { $0.acoustic?.bankID } }
    }

    private static func model(_ t: DialogueTranscript) -> String { "\(t.locale)|\(t.modelVersion)" }

    private static func trim(_ cache: inout [Entry]) {
        if cache.count > cacheEntries { cache.removeLast(cache.count - cacheEntries) }
        for i in cache.indices where i >= cacheWithPCM { cache[i].source = nil }
    }

    // MARK: Memory

    /// Memory and its generation, read before a build.
    func memorySnapshot() -> (memory: DialoguePerformanceMemory, generation: Int) {
        state.withLock { ($0.memory, $0.generation) }
    }

    /// Commits a posted plan's memory when nothing else committed since `generation`.
    @discardableResult
    func commit(_ memory: DialoguePerformanceMemory, expecting generation: Int) -> Int? {
        state.withLock { s -> Int? in
            guard s.generation == generation else { return nil }
            s.memory = memory
            s.generation += 1
            return s.generation
        }
    }

    // MARK: Live task

    /// The coordinator task for one cue: bounded classification, build, token and revision checks,
    /// post; then the optional transcript refinement. Runs at the caller's (utility) priority and
    /// checks cancellation between stages. `post` is the only thing that touches the conductor.
    func run(source: DialogueSource, window: Range<Double>, seed: UInt64,
             transport: @escaping @Sendable () -> LofiTransportInfo?, isCurrent: @escaping @Sendable () -> Bool,
             post: @escaping @Sendable (ArchiveVoice.ChopPlan) -> Void) async -> Outcome {
        let config = settings.withLock { $0 }
        let now = config.now
        var outcome = Outcome()
        guard var info = transport() else { outcome.discarded = "noTransport"; return outcome }
        let started = now()

        // Transcription runs beside the acoustic path. It may refine the second block and later.
        var reuse = cached(source)
        let firstSnapshot = DialogueCueCoordinator.snapshot(info, window: window)
        let firstBlock = DialogueCueCoordinator.blocks(firstSnapshot, window: window).lowerBound
        let secondBlockStart = firstSnapshot.time(beat: Double(16 * (firstBlock + 1)))
        let useDeadline = min(started + config.transcriptCap,
                              secondBlockStart - DialogueCueCoordinator.commitMargin - DialogueCueCoordinator.transcriptCommitGap)
        var transcriptTask: Task<DialogueTranscript?, Never>?
        if reuse?.transcript == nil {
            let provider = config.transcriptProvider()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(config.transcriptCap * 1000)))
            transcriptTask = Task(priority: .utility) { await provider.transcript(for: source, deadline: deadline) }
        }
        func finish(_ reason: String?) -> Outcome {
            transcriptTask?.cancel()
            outcome.discarded = reason
            return outcome
        }

        var classifyMs = 0.0
        var speech = reuse?.analysis.speech ?? []
        if reuse == nil {
            let c0 = ContinuousClock.now
            speech = await config.classify(source.buffer, DialogueTuning.analysisSeconds,
                                           DialogueCueCoordinator.classifyBudget)
            classifyMs = DialogueCueCoordinator.ms(ContinuousClock.now - c0)
        }
        if config.analysisDelay > .zero { try? await Task.sleep(for: config.analysisDelay) }
        guard !Task.isCancelled else { return finish("cancelled") }

        // Build, then verify the cue token and the transport revision. A changed transport keeps
        // the analysis and bank and plans again; a vanished one discards the plan.
        var built: DialogueCueCoordinator.Built?
        var committedGeneration: Int?
        var memoryBefore = DialoguePerformanceMemory()
        for _ in 0..<4 {
            let (memory, generation) = memorySnapshot()
            memoryBefore = memory
            let earliest = now() + DialogueCueCoordinator.commitMargin
            let candidate = DialogueCueCoordinator.build(source: source, speech: speech, transcript: reuse?.transcript,
                                                         transport: info, window: window, earliestStart: earliest,
                                                         memory: memory, seed: seed, revision: 0, classifyMs: classifyMs,
                                                         reuse: reuse)
            if reuse == nil { store(source, analysis: candidate.analysis, bank: candidate.bank) }
            reuse = reuse ?? .init(analysis: candidate.analysis, bank: candidate.bank)
            classifyMs = 0
            guard !Task.isCancelled else { return finish("cancelled") }
            guard isCurrent() else { return finish("staleCue") }
            guard let latest = transport() else { return finish("transportGone") }
            if latest.revision != info.revision {
                LMLog.audio.info("Lo-Fi dialogue cue=\(source.cueToken) transport revision \(info.revision) -> \(latest.revision): replanning")
                info = latest
                continue
            }
            // Never schedule earlier than the commit margin: gestures the build overran are dropped whole.
            let ready = now()
            let chops = candidate.chops.filter { $0.event.startTime >= ready + DialogueCueCoordinator.commitMargin }
            outcome.readyAt = ready
            post(ArchiveVoice.ChopPlan(token: source.cueToken, revision: 0, chops: chops))
            committedGeneration = commit(candidate.memory, expecting: generation)
            if committedGeneration == nil {
                LMLog.audio.warning("Lo-Fi dialogue cue=\(source.cueToken) memory moved on during the build; not committed")
            }
            built = candidate
            outcome.posted.append(ArchiveVoice.ChopPlan(token: source.cueToken, revision: 0, chops: chops))
            outcome.built.append(candidate)
            DialogueCueCoordinator.report(candidate, cue: source.cueToken,
                                          lead: candidate.firstStart.map { $0 - (outcome.readyAt ?? 0) })
            break
        }
        guard let acoustic = built else { return finish(outcome.discarded ?? "unsettledTransport") }

        // Transcript refinement: only blocks starting after its arrival plus 0.5 s, posted with a
        // higher revision and `replaceFrom` at that block's start. A late transcript is only cached.
        guard let transcriptTask else { return outcome }
        let transcript = await withTaskCancellationHandler { await transcriptTask.value } onCancel: { transcriptTask.cancel() }
        let arrived = now()
        if transcript != nil { outcome.transcriptArrivedAt = arrived }

        // The transport moved on while recognition ran (tempo change, restart): the posted plan sits on
        // a stale grid. The analysis and bank are kept (refined when a transcript came) and the plan
        // is rebuilt against the new snapshot from the commit margin on, replacing unqueued chops.
        if !Task.isCancelled, isCurrent(), let latest = transport(), latest.revision != info.revision,
           let generation = committedGeneration {
            let refined = transcript.flatMap { DialogueEngine.bank(acoustic.analysis, transcript: $0, seed: seed) }
            if let transcript { store(source, transcript: transcript, refined: refined) }
            let from = now() + DialogueCueCoordinator.commitMargin
            let rebuilt = DialogueCueCoordinator.build(source: source, speech: speech, transcript: nil, transport: latest,
                                                       window: window, earliestStart: from, memory: memoryBefore, seed: seed,
                                                       revision: 1, reuse: .init(analysis: acoustic.analysis, bank: refined ?? acoustic.bank))
            guard !Task.isCancelled, isCurrent(), transport()?.revision == latest.revision,
                  state.withLock({ $0.generation }) == generation else { return outcome }
            LMLog.audio.info("Lo-Fi dialogue cue=\(source.cueToken) transport revision \(info.revision) -> \(latest.revision) during recognition: plan rebuilt")
            let plan = ArchiveVoice.ChopPlan(token: source.cueToken, revision: 1, replaceFrom: from,
                                             chops: rebuilt.chops.filter { $0.event.startTime >= from })
            post(plan)
            commit(rebuilt.memory, expecting: generation)
            outcome.posted.append(plan)
            outcome.built.append(rebuilt)
            outcome.transcriptUsed = refined != nil
            DialogueCueCoordinator.report(rebuilt, cue: source.cueToken, lead: rebuilt.firstStart.map { $0 - now() })
            return outcome
        }
        guard let transcript else { return outcome }
        guard arrived <= useDeadline, !Task.isCancelled, isCurrent(), transport()?.revision == info.revision,
              let generation = committedGeneration else {
            let refined = DialogueEngine.bank(acoustic.analysis, transcript: transcript, seed: seed)
            store(source, transcript: transcript, refined: refined)
            LMLog.audio.info("Lo-Fi dialogue cue=\(source.cueToken) transcript arrived too late; cached")
            return outcome
        }
        let blocks = DialogueCueCoordinator.blocks(acoustic.snapshot, window: acoustic.window)
        let from = blocks.map { acoustic.snapshot.time(beat: Double(16 * $0)) }
            .first { $0 > arrived + DialogueCueCoordinator.transcriptReplanMargin && $0 < acoustic.window.upperBound }
        guard let from, let refined = DialogueCueCoordinator.replan(acoustic, memoryBefore: memoryBefore, source: source,
                                                                     transcript: transcript, from: from, seed: seed,
                                                                     revision: 1) else {
            store(source, transcript: transcript, refined: nil)
            return outcome
        }
        store(source, transcript: transcript, refined: refined.bank)
        guard !Task.isCancelled, isCurrent(), state.withLock({ $0.generation }) == generation else { return outcome }
        let plan = ArchiveVoice.ChopPlan(token: source.cueToken, revision: 1, replaceFrom: from, chops: refined.chops)
        post(plan)
        commit(refined.memory, expecting: generation)
        outcome.posted.append(plan)
        outcome.built.append(refined)
        outcome.transcriptUsed = true
        DialogueCueCoordinator.report(refined, cue: source.cueToken, lead: refined.firstStart.map { $0 - now() })
        return outcome
    }
}
