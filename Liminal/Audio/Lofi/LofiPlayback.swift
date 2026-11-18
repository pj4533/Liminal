import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Darwin
import OSLog

/// All stems start against one host time. The backing recording is queued once per 64 beats.
@MainActor
final class LofiPlayback {
    private let bus = LofiBus(gain: 0)
    private var speechDucker = LofiForegroundDucker()
    private var lastDryGain: Float = 1
    private var lastWetGain: Float = 1
    var archiveActivity: (() -> Float)?
    var output: Fader { bus.output }
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
    private var audibleStartSample: AVAudioFramePosition?
    private var audibleBeatDuration: Double?
    private var onset: (time: Double, velocity: Float) = (-1000, 0)
    private var nextKickIndex = 0
    private var previousTick: AVAudioFramePosition?
    private var rng: MusicRNG
    private var seed: UInt64 = 0
    var options = LofiOptions()
    var onBeatDurationChange: ((Double) -> Void)?

    private struct PlayingPhrase {
        let request: Request
        let breakAudio: LofiPhraseBank.Take
        let music: LofiRenderer.Phrase?
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

    init(seed: UInt64, sampleRate: Double) {
        rng = MusicRNG(seed: seed)
        self.sampleRate = sampleRate
    }

    func start(onReady: @escaping () -> Void) {
        stop(immediately: true)
        let token = epoch
        seed = rng.next()
        loop = Task { [weak self] in
            guard let self else { return }
            do {
                let first = Request(seed: seed, index: 0, options: options)
                let next = try await bank.prepare(first, sampleRate: sampleRate)
                guard !Task.isCancelled, epoch == token else { return }
                enqueue(next.phrase, take: next.take, request: first)
                reportTempo(next.take.drums.clock)
                let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.075))
                for player in bus.players { player.play(at: start) }
                stateBus.setStartUptime(DispatchTime.now().uptimeNanoseconds)
                onReady()
                ParamRamp.setGain(output, 1, over: 0.35)
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
        audibleBeatDuration = nil
        speechDucker = LofiForegroundDucker()
        lastDryGain = 1
        lastWetGain = 1
        ParamRamp.setGain(bus.dryFader, 1, over: 0.20)
        ParamRamp.setGain(bus.textureFader, 1, over: 0.20)
        ParamRamp.setGain(bus.wetFader, 1, over: 0.20)
        onset = (-1000, 0)
        nextKickIndex = 0
        previousTick = nil
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

    private func enqueue(_ phrase: LofiRenderer.Phrase?, take: LofiPhraseBank.Take, request: Request,
                         fallbackWet override: AVAudioPCMBuffer? = nil) {
        if request.drumPhraseIndex == 0 { bus.schedule(take.drums) }
        if let phrase {
            bus.schedule(phrase)
        } else {
            for player in [bus.bass.player, bus.dry.player, bus.texture.player] {
                player.scheduleBuffer(take.rest)
            }
            bus.wet.player.scheduleBuffer(override ?? take.rest)
        }
        rendered.append(.init(request: request, breakAudio: take, music: phrase, start: queuedFrames))
        queuedFrames += AVAudioFramePosition(take.drums.clock.frameCount)
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
                let next = try await bank.prepare(target, sampleRate: sampleRate, previous: last.breakAudio,
                                                  carry: last.music?.tail)
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
        if remaining < 4, let (key, phrase) = prepared, key == target {
            enqueue(phrase.phrase, take: phrase.take, request: key)
            prepared = nil
        } else if remaining < 1 {
            // The current recording is already queued. If a take misses its deadline,
            // use a whole take at the next boundary and reserve a timed musical rest.
            let fallback = last.request.next(options: last.request.options)
            enqueue(nil, take: last.breakAudio, request: fallback, fallbackWet: last.music?.fallbackWet)
            prepared = nil
            LMLog.audio.warning("Lo-Fi prepared a timed rest while filling the upcoming phrase")
            #if DEBUG
            Self.trace("timed-rest sample=\(queuedFrames) phrase=\(fallback.index)")
            #endif
        }
        planNext(token: token)

        while rendered.count > 1 && frame >= rendered[1].start { rendered.removeFirst() }
        guard let current = rendered.first else { return }
        if current.start != audibleStartSample {
            audibleStartSample = current.start
            reportTempo(current.breakAudio.drums.clock)
            if let score = current.music?.score {
                LMLog.audio.info("Lo-Fi lead: \(score.preset.name, privacy: .public), sampled notes=\(current.music?.leadSampleCount ?? 0)")
            }
            if current.request.drumPhraseIndex == 0 {
                nextKickIndex = 0
                LMLog.audio.info("Lo-Fi started 16-bar drum take \(current.request.drumBreakIndex), recorded=\(current.breakAudio.drums.name != nil)")
                #if DEBUG
                Self.trace("take=\(current.request.drumBreakIndex) sample=\(current.start) frames=\(current.breakAudio.drums.buffer.frameLength)")
                #endif
            }
        }
        let interval = previousTick.map { Double(max(0, frame - $0)) / sampleRate } ?? 0.04
        previousTick = frame
        updateDucking(interval: interval)
        publish(current, frame: frame, outputLatency: player.outputPresentationLatency)
    }

    #if DEBUG
    private static let traceEnabled = UserDefaults.standard.bool(forKey: "LiminalTraceLofi")
    private static func trace(_ message: @autoclosure () -> String) {
        if traceEnabled { print("Liminal Lo-Fi QA \(message())") }
    }
    #endif

    private func updateDucking(interval: Double) {
        let gains = speechDucker.update(activity: archiveActivity?() ?? 0, interval: interval)
        if abs(gains.dry - lastDryGain) > 0.004 {
            ParamRamp.setGain(bus.dryFader, gains.dry, over: 0.075)
            ParamRamp.setGain(bus.textureFader, gains.dry, over: 0.075)
            lastDryGain = gains.dry
        }
        if abs(gains.wet - lastWetGain) > 0.004 {
            ParamRamp.setGain(bus.wetFader, gains.wet, over: 0.075)
            lastWetGain = gains.wet
        }
    }

    private func reportTempo(_ clock: LofiClock) {
        guard clock.beatDuration != audibleBeatDuration else { return }
        audibleBeatDuration = clock.beatDuration
        onBeatDurationChange?(clock.beatDuration)
    }

    private func publish(_ current: PlayingPhrase, frame: AVAudioFramePosition, outputLatency: Double) {
        let now = stateBus.now()
        let take = current.breakAudio.drums
        let offset = max(0, frame - current.start)
        let beat = Double(offset) / take.clock.framesPerBeat
        let takeFrame = current.request.drumPhraseIndex * take.clock.frameCount + Int(offset)
        while nextKickIndex < take.kicks.count, take.kicks[nextKickIndex].frame <= takeFrame {
            let kick = take.kicks[nextKickIndex]
            let age = Double(takeFrame - kick.frame) / sampleRate
            if age < 0.14 { onset = (max(0, now + outputLatency - age), kick.strength * 0.65) }
            nextKickIndex += 1
        }
        var state = MusicState()
        let section = current.request.section
        state.time = now
        state.sceneIndex = UInt32(truncatingIfNeeded: current.request.index)
        state.sceneKind = section == .breakdown ? .stillness : .drift
        state.scenePhase = .bloom
        state.sceneProgress = Float(min(1, beat / LofiClock.beats))
        state.intensity = section == .breakdown ? 0.26 : 0.49
        state.brightness = 0.38
        let absoluteBeat = Double(current.request.index) * LofiClock.beats + beat
        state.density = LofiDrift(seed: current.request.seed).at(absoluteBeat).density * 0.65
        if let score = current.music?.score {
            state.tonic = UInt8(score.tonic)
            state.scaleMask = score.scale.pitchClassMask(tonic: score.tonic)
            let notes = score.notes.filter { $0.beat <= beat && beat < $0.beat + $0.length }
            state.chordMask = notes.reduce(0) { $0 | (UInt16(1) << ($1.midi % 12)) }
            state.setLevel(.pad, notes.contains { $0.part == .texture } ? 0.42 : 0)
            state.setLevel(.drone, notes.contains { $0.part == .bass } ? 0.40 : 0)
            state.setLevel(.lead, notes.contains { $0.part == .lead } ? 0.26 : 0)
        }
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
        return .init(take: take, phrase: phrase)
    }
}
