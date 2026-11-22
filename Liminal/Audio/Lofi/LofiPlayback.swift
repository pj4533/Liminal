import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Darwin
import OSLog

/// All stems start against one host time. The backing recording is queued once per 64 beats.
@MainActor
final class LofiPlayback {
    private let bus: LofiBus
    var output: Fader { bus.output }
    /// The faders the archive voice ducks under featured chops; this transport never writes them.
    var duckTargets: (lead: Fader, mids: Fader, space: Fader) { bus.duckTargets }
    nonisolated let stateBus = MusicStateBus()
    private let sampleRate: Double
    private let bank = LofiPhraseBank()
    private var loop: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var epoch = 0
    private var preparationID = 0
    private var preparingRequest: Request?
    private var prepared: (Request, LofiPhraseBank.Prepared)?
    private var rendered: [PlayingPhrase] = []
    private var queuedFrames: AVAudioFramePosition = 0
    private var transportOrigin: Double = 0
    private var outputLatency: Double = 0
    private var audibleStartSample: AVAudioFramePosition?
    private var onset: (time: Double, velocity: Float) = (-1000, 0)
    private var nextKickIndex = 0
    private var rng: MusicRNG
    private var seed: UInt64 = 0
    /// Plan 6.4: start, stop and a queued take at another tempo invalidate dialogue plans.
    private(set) var transportRevision: UInt32 = 0
    var options = LofiOptions()
    var onPhrase: ((Double, Int, UInt64) -> Void)?

    private struct PlayingPhrase {
        let request: Request
        let breakAudio: LofiPhraseBank.Take
        let music: LofiRenderer.Phrase
        let repeated: Bool
        let start: AVAudioFramePosition
    }

    nonisolated struct Request: Equatable, Sendable {
        let seed: UInt64
        let index: Int
        let options: LofiOptions
        var section: LofiScore.Section { LofiScore.section(at: index) }
        var drumBreakIndex: Int { index / LofiDrumTake.phraseCount }
        var drumPhraseIndex: Int { index % LofiDrumTake.phraseCount }
        var drumStartBeat: Int { drumPhraseIndex * Int(LofiClock.beats) }
        var compositionSeed: UInt64 {
            let arrangement = index / 8
            guard arrangement > 0 else { return seed }
            var rng = MusicRNG(seed: seed).fork(UInt64(arrangement) + 1000)
            return rng.next()
        }

        func next(options pending: LofiOptions) -> Self {
            let next = index + 1
            return .init(seed: seed, index: next, options: next.isMultiple(of: LofiDrumTake.phraseCount) ? pending : options)
        }
    }

    init(seed: UInt64, sampleRate: Double, dialogue: Fader) {
        bus = LofiBus(gain: 0, dialogue: dialogue)
        rng = MusicRNG(seed: seed)
        self.sampleRate = sampleRate
    }

    func start(onReady: @escaping (LofiClock, UInt64) -> Void, onFailure: @escaping () -> Void) {
        stop(immediately: true)
        let token = epoch
        transportRevision &+= 1
        seed = rng.next()
        loop = Task { [weak self] in
            guard let self else { return }
            do {
                let first = Request(seed: seed, index: 0, options: options)
                let next = try await bank.prepare(first, sampleRate: sampleRate)
                guard !Task.isCancelled, epoch == token else { return }
                enqueue(next.phrase, take: next.take, request: first)
                // This getter synchronously queries the audio device. The graph is
                // fixed for this transport and reacquires latency when the route restarts.
                outputLatency = bus.drums.player.outputPresentationLatency
                let lead = max(0.09, outputLatency + 0.025)
                let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
                let startNs = DispatchTime.now().uptimeNanoseconds + UInt64(lead * 1e9)
                transportOrigin = Double(startNs) / 1e9
                stateBus.setStartUptime(startNs)
                ParamRamp.setGain(output, 1, over: 0.035)
                for player in bus.players { player.play(at: start) }
                try await Task.sleep(for: .seconds(lead))
                guard !Task.isCancelled, epoch == token else { return }
                onReady(next.take.drums.clock, first.seed)
                LMLog.audio.info("Lo-Fi started at \(first.options.safeTempo) BPM, recorded drums=\(next.take.drums.name != nil)")
                #if DEBUG
                Self.trace("started BPM=\(first.options.safeTempo) recorded=\(next.take.drums.name != nil)")
                #endif
                planNext(token: token)
                while !Task.isCancelled, epoch == token {
                    tick(token: token)
                    try await Task.sleep(for: .milliseconds(40))
                }
            } catch is CancellationError {
                return
            } catch {
                guard epoch == token else { return }
                LMLog.audio.error("Lo-Fi preparation failed: \(error.localizedDescription)")
                onFailure()
            }
        }
    }

    func stop(immediately: Bool = false) {
        epoch += 1
        let token = epoch
        loop?.cancel()
        cancelPreparation()
        stopTask?.cancel()
        loop = nil
        prepared = nil
        rendered.removeAll(keepingCapacity: true)
        queuedFrames = 0
        audibleStartSample = nil
        onset = (-1000, 0)
        nextKickIndex = 0
        transportRevision &+= 1
        stateBus.setTransport(nil)
        stateBus.setStartUptime(0)
        stateBus.publish(MusicState())
        ParamRamp.setGain(output, 0, over: immediately ? 0 : 0.16)
        if immediately {
            for player in bus.players { player.stop() }
        } else {
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(170))
                guard !Task.isCancelled, let self, epoch == token else { return }
                for player in bus.players { player.stop() }
            }
        }
    }

    private func enqueue(_ phrase: LofiRenderer.Phrase, take: LofiPhraseBank.Take, request: Request,
                         repeated: Bool = false, wet: AVAudioPCMBuffer? = nil) {
        if request.drumPhraseIndex == 0 { bus.schedule(take.drums) }
        bus.schedule(phrase, wet: wet)
        let current = rendered.first
        rendered.append(.init(request: request, breakAudio: take, music: phrase, repeated: repeated, start: queuedFrames))
        queuedFrames += AVAudioFramePosition(take.drums.clock.frameCount)
        // The next take is committed: publish its tempo with the audible take (plan 6.4).
        if request.drumPhraseIndex == 0, let current, current.request.drumBreakIndex < request.drumBreakIndex {
            if take.drums.clock.beatDuration != current.breakAudio.drums.clock.beatDuration { transportRevision &+= 1 }
            publishTransport(current)
        }
    }

    /// The take that contains `current`, on the same origin as `lofiTakeGrid`, with the next
    /// queued take's tempo. Main actor; the footage worker reads it through `stateBus.transport()`.
    private func publishTransport(_ current: PlayingPhrase) {
        let take = current.breakAudio.drums
        let takeStart = current.start - Int64(current.request.drumPhraseIndex * take.clock.frameCount)
        let nextTake = rendered.last.flatMap { $0.request.drumBreakIndex > current.request.drumBreakIndex ? $0.breakAudio : nil }
        stateBus.setTransport(LofiTransportInfo(
            revision: transportRevision, takeIndex: current.request.drumBreakIndex,
            phraseAtTakeStart: current.request.drumBreakIndex * LofiDrumTake.phraseCount,
            origin: transportOrigin + Double(takeStart) / sampleRate + outputLatency,
            beatDuration: take.clock.beatDuration, nextBeatDuration: nextTake?.drums.clock.beatDuration,
            seed: current.request.seed, options: current.request.options, timing: take.timing))
    }

    private func cancelPreparation() {
        preparationID += 1
        preparation?.cancel()
        preparation = nil
        preparingRequest = nil
    }

    private func planNext(token: Int) {
        guard let last = rendered.last else { return }
        let target = last.request.next(options: options)
        if prepared?.0 == target || preparingRequest == target { return }
        cancelPreparation()
        let job = preparationID
        preparingRequest = target
        preparation = Task { [weak self] in
            guard let self else { return }
            defer {
                if preparationID == job {
                    preparation = nil
                    preparingRequest = nil
                }
            }
            do {
                #if DEBUG
                // Deterministic slow-producer test. Only the second take's preparation waits.
                if target.index == LofiDrumTake.phraseCount, Self.delayedTakeSeconds > 0 {
                    LMLog.audio.notice("QA delaying take preparation by \(Self.delayedTakeSeconds)s")
                    try await Task.sleep(for: .seconds(Self.delayedTakeSeconds))
                }
                #endif
                let next = try await bank.prepare(target, sampleRate: sampleRate, previous: last.breakAudio,
                                                  carry: last.repeated ? nil : last.music.tail)
                guard !Task.isCancelled, epoch == token, preparationID == job else { return }
                prepared = (target, next)
            } catch {
                if !Task.isCancelled { LMLog.audio.warning("Lo-Fi phrase preparation failed: \(error.localizedDescription)") }
            }
        }
    }

    private func tick(token: Int) {
        let player = bus.drums.player
        guard let renderTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: renderTime),
              let last = rendered.last else { return }
        let frame = max(0, playerTime.sampleTime)
        let remaining = Double(queuedFrames - frame) / sampleRate
        let target = last.request.next(options: options)
        // Queue the next interior phrase as soon as it is ready, then use the spare
        // phrase of runway to prepare the following one. Keep the four-second commit
        // window at take changes so pending tempo and scale edits still apply.
        let canQueue = remaining < 4 || (rendered.count == 1 && target.drumPhraseIndex != 0)
        if canQueue, let (key, phrase) = prepared, key == target {
            LMLog.audio.info("Lo-Fi queued phrase \(key.index) with \(remaining, format: .fixed(precision: 3)) s of audio remaining")
            enqueue(phrase.phrase, take: phrase.take, request: key)
            prepared = nil
        } else if remaining < 1 {
            // Carry a late worker across this boundary with existing, edge-tapered
            // performances on the committed grid. Let the outgoing effects decay once.
            let fallback = last.request.next(options: last.request.options)
            let wet = last.repeated ? last.breakAudio.rest : last.music.fallbackWet
            enqueue(last.music, take: last.breakAudio, request: fallback, repeated: true, wet: wet)
            prepared = nil
            LMLog.audio.warning("Lo-Fi repeated prepared stems for phrase \(fallback.index), frames=\(last.music.bass.frameLength) headroom=\(remaining, format: .fixed(precision: 3))s")
            #if DEBUG
            Self.trace("repeated-stems sample=\(queuedFrames) phrase=\(fallback.index)")
            #endif
        }
        planNext(token: token)

        while rendered.count > 1 && frame >= rendered[1].start { rendered.removeFirst() }
        guard let current = rendered.first else { return }
        if current.start != audibleStartSample {
            audibleStartSample = current.start
            if current.request.index > 0 {
                onPhrase?(current.breakAudio.drums.clock.beatDuration, current.request.index, current.request.seed)
            }
            LMLog.audio.info("Lo-Fi lead: \(current.music.score.preset.name, privacy: .public), sampled notes=\(current.music.leadSampleCount)")
            if current.request.drumPhraseIndex == 0 {
                publishTransport(current)
                nextKickIndex = 0
                LMLog.audio.info("Lo-Fi started 16-bar drum take \(current.request.drumBreakIndex), recorded=\(current.breakAudio.drums.name != nil)")
                #if DEBUG
                Self.trace("take=\(current.request.drumBreakIndex) sample=\(current.start) frames=\(current.breakAudio.drums.buffer.frameLength)")
                #endif
            }
        }
        publish(current, frame: frame)
    }

    #if DEBUG
    private static let delayedTakeSeconds = min(60, max(0, UserDefaults.standard.double(forKey: "LiminalDelaySecondTake")))
    private static let traceEnabled = UserDefaults.standard.bool(forKey: "LiminalTraceLofi")
    private static func trace(_ message: @autoclosure () -> String) {
        if traceEnabled { print("Liminal Lo-Fi QA \(message())") }
    }
    #endif

    private func publish(_ current: PlayingPhrase, frame: AVAudioFramePosition) {
        let now = stateBus.now()
        let take = current.breakAudio.drums
        let offset = max(0, frame - current.start)
        let takeFrame = current.request.drumPhraseIndex * take.clock.frameCount + Int(offset)
        while nextKickIndex < take.kicks.count, take.kicks[nextKickIndex].frame <= takeFrame {
            let kick = take.kicks[nextKickIndex]
            let age = Double(takeFrame - kick.frame) / sampleRate
            if age < 0.14 {
                // The bus clock starts at player sample zero. Polling discovers a hit, but
                // its audible time belongs to that sample even if the main actor wakes late.
                let phraseStartInTake = current.request.drumPhraseIndex * take.clock.frameCount
                let sample = current.start + Int64(kick.frame - phraseStartInTake)
                onset = (Double(sample) / sampleRate + outputLatency, kick.strength * 0.65)
            }
            nextKickIndex += 1
        }
        var state = MusicState()
        let section = current.request.section
        state.startUptime = UInt64(transportOrigin * 1e9)
        state.time = now
        state.phraseIndex = UInt32(truncatingIfNeeded: current.request.index)
        state.intensity = section == .breakdown ? 0.26 : 0.49
        state.brightness = 0.38
        let score = current.music.score
        state.tonic = UInt8(score.tonic)
        state.chordRoot = UInt8(score.chordRoot)
        let takeStart = current.start - Int64(current.request.drumPhraseIndex * take.clock.frameCount)
        let nextTake = rendered.last.flatMap { $0.request.drumBreakIndex > current.request.drumBreakIndex ? $0.breakAudio : nil }
        state.lofiTakeGrid = LofiTakeGrid(origin: transportOrigin + Double(takeStart) / sampleRate + outputLatency,
                                          beatDuration: take.clock.beatDuration, takeIndex: current.request.drumBreakIndex,
                                          nextBeatDuration: nextTake?.drums.clock.beatDuration)
        state.recordedBeatDuration = take.name == nil ? 0 : take.clock.beatDuration
        state.lastOnsetTime = onset.time
        state.lastOnsetVelocity = onset.velocity
        stateBus.publish(state)
    }
}

actor LofiPhraseBank {
    struct Take: @unchecked Sendable {
        let drums: LofiDrumTake
        let rest: AVAudioPCMBuffer
    }

    struct Prepared: Sendable {
        let take: Take
        let phrase: LofiRenderer.Phrase
    }

    private lazy var assets = LofiDrumLibrary.assets()

    func prepare(_ request: LofiPlayback.Request, sampleRate: Double, previous: Take? = nil,
                 carry: LofiRenderer.Tail? = nil, captureEffects: Bool = false) throws -> Prepared {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let take: Take
        if request.drumPhraseIndex != 0, let previous {
            take = previous
        } else {
            let tempo = request.options.safeTempo
            let sorted = assets.filter { $0.entry.beats == 64 }
                .sorted {
                    let left = abs($0.entry.bpm - tempo), right = abs($1.entry.bpm - tempo)
                    return left == right ? $0.entry.name < $1.entry.name : left < right
                }
            var rng = MusicRNG(seed: request.seed).fork(UInt64(request.drumBreakIndex) &+ 77)
            let nearby = sorted.first.map { best in
                sorted.prefix { abs($0.entry.bpm - tempo) <= abs(best.entry.bpm - tempo) + 4 }
            }.map(Array.init) ?? []
            // A fresh pool on every boundary preserves BPM proximity and avoids repeating
            // the previous filename even when changing BPM reshuffles the pool.
            let eligible = nearby.filter { $0.entry.name != previous?.drums.name }
            let alternatives = sorted.prefix { abs(tempo / $0.entry.bpm - 1) <= 0.15 }
                .filter { $0.entry.name != previous?.drums.name }
            let pool = eligible.isEmpty ? alternatives : eligible
            let choice = pool.isEmpty ? [] : [rng.pick(pool)]
            let candidates = choice + sorted.filter { !choice.contains($0) && $0.entry.name != previous?.drums.name }
                + sorted.filter { $0.entry.name == previous?.drums.name }
            var recording: LofiDrumLibrary.Break?
            for asset in candidates {
                try Task.checkCancellation()
                if let available = try? LofiDrumLibrary.load(asset) {
                    recording = available
                    break
                }
            }
            let clock = LofiClock(tempo: tempo, sampleRate: sampleRate)
            take = try .init(drums: LofiDrumTake(recording: recording, clock: clock),
                             rest: LofiRenderer.stereoBuffer(clock: clock))
        }
        let phrase = try LofiRenderer.render(seed: request.compositionSeed, section: request.section,
                                             options: request.options, sampleRate: sampleRate,
                                             drift: LofiDrift(seed: request.seed),
                                             startBeat: Double(request.index) * LofiClock.beats,
                                             drums: take.drums, drumStartBeat: request.drumStartBeat, carry: carry,
                                             captureEffects: captureEffects)
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        if seconds > 1 {
            LMLog.audio.info("Lo-Fi prepared phrase \(request.index) in \(seconds, format: .fixed(precision: 3)) s")
        }
        let strums = phrase.score.strumEvents
        if let first = strums.first {
            let cells = strums.map { "\($0.bar).\($0.step)\($0.thrown ? "T" : "")x\($0.strings.count)" }
            LMLog.audio.info("Lo-Fi strum hook phrase \(request.index): \(phrase.score.preset.name, privacy: .public) archetype \(first.archetype) events \(strums.count) [\(cells.joined(separator: " "), privacy: .public)]")
        }
        return .init(take: take, phrase: phrase)
    }
}
