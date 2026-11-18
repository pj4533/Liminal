import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Darwin
import OSLog

/// Single producer for the player. Only the player renders on the audio thread.
@MainActor
final class LofiPlayback {
    private let source: ArchiveVoice.BufferSource
    private let musicSource: ArchiveVoice.BufferSource
    private let musicFader: Fader
    private var duck: Float = 0
    private var lastDuckGain: Float = 1
    var archiveActivity: (() -> Float)?
    let output: Fader
    nonisolated let stateBus = MusicStateBus()
    private let sampleRate: Double
    private let bank = LofiPhraseBank()
    private var loop: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var epoch = 0
    private var prepared: (Request, LofiRenderer.Phrase)?
    private var rendered: [PlayingPhrase] = []
    private var queuedFrames: AVAudioFramePosition = 0
    private var audibleStartSample: AVAudioFramePosition?
    private var audibleBeatDuration: Double?
    private var audibleDrumName: String?
    private var onset: (time: Double, velocity: Float) = (-1000, 0)
    private var lastBeat = -1
    private var rng: MusicRNG
    private var seed: UInt64 = 0
    var options = LofiOptions()
    var onBeatDurationChange: ((Double) -> Void)?

    private struct PlayingPhrase {
        var request: Request
        var phrase: LofiRenderer.Phrase
        var start: AVAudioFramePosition
    }

    nonisolated struct Request: Equatable, Sendable {
        private static let phrasesPerBreak = 4
        let seed: UInt64
        let index: Int
        let options: LofiOptions
        var section: LofiScore.Section { LofiScore.section(at: index) }
        var drumBreakIndex: Int { index / Self.phrasesPerBreak }
        var drumStartBeat: Int { (index % Self.phrasesPerBreak) * Int(LofiClock.beats) }
        var compositionSeed: UInt64 {
            let arrangement = index / 8
            guard arrangement > 0 else { return seed }
            var rng = MusicRNG(seed: seed).fork(UInt64(arrangement) + 1000)
            return rng.next()
        }
    }

    init(seed: UInt64, sampleRate: Double) {
        rng = MusicRNG(seed: seed)
        self.sampleRate = sampleRate
        let source = ArchiveVoice.BufferSource()
        self.source = source
        let musicSource = ArchiveVoice.BufferSource()
        self.musicSource = musicSource
        musicFader = Fader(musicSource, gain: 1)
        output = Fader(Mixer(source, musicFader), gain: 0)
    }

    func start(onReady: @escaping () -> Void) {
        stop(immediately: true)
        let token = epoch
        seed = rng.next()
        loop = Task { [weak self] in
            guard let self else { return }
            do {
                let first = request(after: nil)
                let phrase = try await bank.render(first, sampleRate: sampleRate)
                guard !Task.isCancelled, epoch == token else { return }
                enqueue(phrase, request: first)
                reportTempo(phrase.clock)
                // Start both stems on the same hardware clock, even if render begins between calls.
                let leadTime = 0.075
                let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadTime))
                source.player.play(at: start)
                musicSource.player.play(at: start)
                let now = DispatchTime.now().uptimeNanoseconds
                stateBus.setStartUptime(now)
                onReady()
                ParamRamp.setGain(output, 1, over: 0.35)
                LMLog.audio.info("🎛️ Lo-Fi started at \(first.options.safeTempo) BPM, recorded drums=\(phrase.drumName != nil)")
                planNext(token: token)
                while !Task.isCancelled, epoch == token {
                    tick(token: token)
                    try await Task.sleep(for: .milliseconds(100))
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
        preparation?.cancel()
        stopTask?.cancel()
        loop = nil
        preparation = nil
        prepared = nil
        rendered.removeAll(keepingCapacity: true)
        queuedFrames = 0
        audibleStartSample = nil
        audibleBeatDuration = nil
        audibleDrumName = nil
        duck = 0
        lastDuckGain = 1
        ParamRamp.setGain(musicFader, 1, over: 0.20)
        lastBeat = -1
        onset = (-1000, 0)
        stateBus.setStartUptime(0)
        stateBus.publish(MusicState())
        ParamRamp.setGain(output, 0, over: immediately ? 0 : 0.16)
        if immediately {
            source.player.stop()
            musicSource.player.stop()
        } else {
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(170))
                guard !Task.isCancelled, let self, epoch == token else { return }
                source.player.stop()
                musicSource.player.stop()
            }
        }
    }

    private func request(after previous: Request?) -> Request {
        .init(seed: seed, index: (previous?.index ?? -1) + 1, options: options)
    }

    private func enqueue(_ phrase: LofiRenderer.Phrase, request: Request) {
        // A nil time appends to the player's sample timeline, including before play().
        source.player.scheduleBuffer(phrase.buffer)
        musicSource.player.scheduleBuffer(phrase.musicBuffer)
        rendered.append(.init(request: request, phrase: phrase, start: queuedFrames))
        queuedFrames += AVAudioFramePosition(phrase.buffer.frameLength)
    }

    private func planNext(token: Int) {
        let target = request(after: rendered.last?.request)
        if prepared?.0 == target || preparation != nil { return }
        let carry = rendered.last?.phrase.tail
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == token { preparation = nil } }
            do {
                let phrase = try await bank.render(target, sampleRate: sampleRate, carry: carry)
                guard !Task.isCancelled, epoch == token, request(after: rendered.last?.request) == target else { return }
                prepared = (target, phrase)
            } catch {
                if !Task.isCancelled { LMLog.audio.warning("Lo-Fi phrase preparation failed: \(error.localizedDescription)") }
            }
        }
    }

    private func tick(token: Int) {
        guard let renderTime = source.player.lastRenderTime,
              let playerTime = source.player.playerTime(forNodeTime: renderTime),
              let last = rendered.last else { return }
        let frame = max(0, playerTime.sampleTime)
        let remaining = Double(queuedFrames - frame) / sampleRate
        let target = request(after: last.request)
        if remaining < 4, let (key, phrase) = prepared, key == target {
            enqueue(phrase, request: key)
            prepared = nil
        } else if remaining < 1 {
            enqueue(last.phrase, request: last.request)
            LMLog.audio.info("Lo-Fi used a prepared repeat while the next phrase was still getting ready")
        }
        planNext(token: token)

        while rendered.count > 1 && frame >= rendered[1].start { rendered.removeFirst() }
        guard let current = rendered.first else { return }
        if current.start != audibleStartSample {
            audibleStartSample = current.start
            reportTempo(current.phrase.clock)
            let preset = current.phrase.score.preset.name
            LMLog.audio.info("🎹 Lo-Fi lead: \(preset, privacy: .public), sampled notes=\(current.phrase.leadSampleCount)")
            if current.phrase.drumName != audibleDrumName {
                audibleDrumName = current.phrase.drumName
                if let audibleDrumName {
                    LMLog.audio.info("🥁 Lo-Fi drum break: \(audibleDrumName, privacy: .public)")
                }
            }
            lastBeat = -1
        }
        let targetDuck = archiveActivity?() ?? 0
        duck += (targetDuck - duck) * (targetDuck > duck ? 0.46 : 0.145)
        let gain = dbToGain(-4.3 * duck)
        if abs(gain - lastDuckGain) > 0.004 {
            ParamRamp.setGain(musicFader, gain, over: 0.11)
            lastDuckGain = gain
        }
        publish(current, frame: frame)
    }

    private func reportTempo(_ clock: LofiClock) {
        guard clock.beatDuration != audibleBeatDuration else { return }
        audibleBeatDuration = clock.beatDuration
        onBeatDurationChange?(clock.beatDuration)
    }

    private func publish(_ current: PlayingPhrase, frame: AVAudioFramePosition) {
        let now = stateBus.now()
        let beat = max(0, Double(frame - current.start) / current.phrase.clock.framesPerBeat)
        let section = current.phrase.score.section
        if Int(beat) != lastBeat && Int(beat) % 2 == 0 {
            onset = (now, section == .breakdown ? 0.23 : (Int(beat) % 4 == 0 ? 0.52 : 0.33))
        }
        lastBeat = Int(beat)
        var state = MusicState()
        state.time = now
        state.sceneIndex = UInt32(truncatingIfNeeded: current.start / AVAudioFramePosition(current.phrase.clock.frameCount))
        state.sceneKind = section == .breakdown ? .stillness : .drift
        state.scenePhase = .bloom
        state.sceneProgress = Float(min(1, beat / 16))
        state.intensity = section == .breakdown ? 0.26 : 0.49
        state.brightness = 0.38
        let absoluteBeat = Double(current.request.index) * LofiClock.beats + beat
        state.density = LofiDrift(seed: current.request.seed).at(absoluteBeat).density * 0.65
        state.tonic = UInt8(current.phrase.score.tonic)
        let notes = current.phrase.score.notes.filter { $0.beat <= beat && beat < $0.beat + $0.length }
        state.chordMask = notes.reduce(0) { $0 | (UInt16(1) << ($1.midi % 12)) }
        state.setLevel(.pad, notes.contains { $0.part == .texture } ? 0.42 : 0)
        state.setLevel(.drone, notes.contains { $0.part == .bass } ? 0.40 : 0)
        state.setLevel(.lead, notes.contains { $0.part == .lead } ? 0.26 : 0)
        state.lastOnsetTime = onset.time
        state.lastOnsetVelocity = onset.velocity
        stateBus.publish(state)
    }
}

/// Keeps just the recording for the current take decoded.
actor LofiPhraseBank {
    private var recording: LofiDrumLibrary.Break?
    private lazy var assets = LofiDrumLibrary.assets()

    func render(_ request: LofiPlayback.Request, sampleRate: Double, carry: LofiRenderer.Tail? = nil) throws -> LofiRenderer.Phrase {
        try Task.checkCancellation()
        let tempo = request.options.safeTempo
        let candidates = assets.filter { abs(tempo / $0.entry.bpm - 1) <= 0.15 }
            .sorted { abs($0.entry.bpm - tempo) < abs($1.entry.bpm - tempo) }
        let near = candidates.first.map { best in
            Array(candidates.prefix { abs($0.entry.bpm - tempo) <= abs(best.entry.bpm - tempo) + 3 })
        } ?? []
        var rng = MusicRNG(seed: request.seed).fork(77)
        let entry = near.isEmpty ? nil : near[(rng.int(0...(near.count - 1)) + request.drumBreakIndex) % near.count]
        if recording?.entry != entry?.entry {
            recording = entry.flatMap { try? LofiDrumLibrary.load($0) }
        }
        return try LofiRenderer.render(seed: request.compositionSeed, section: request.section, options: request.options,
                                       sampleRate: sampleRate, drift: LofiDrift(seed: request.seed),
                                       startBeat: Double(request.index) * LofiClock.beats, recording: recording,
                                       drumStartBeat: request.drumStartBeat, carry: carry)
    }
}
