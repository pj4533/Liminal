import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Darwin

/// A separate performance player. The algorithm's drum timeline is never stopped or re-originated.
@MainActor
final class ControllerDrumPerformance {
    struct Choice: Sendable { let id: String; let label: String; let bpm: Double; let asset: LofiDrumLibrary.Asset? }
    nonisolated struct PCM: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
    struct Pending { let request: String; let choice: String; var status: String; var beat: Double? }
    private actor Preparation {
        private var cache: [(id: String, beat: Double, rate: Double, pcm: PCM)] = []
        func ready(beat: Double, rate: Double) -> [String] { cache.filter { $0.beat == beat && $0.rate == rate }.map(\.id) }
        func render(_ choice: Choice, clock: LofiClock) throws -> PCM {
            try Task.checkCancellation()
            if let existing = cache.first(where: { $0.id == choice.id && $0.beat == clock.beatDuration && $0.rate == clock.sampleRate }) { return existing.pcm }
            let pcm: PCM
            if let asset = choice.asset { pcm = PCM(buffer: try LofiDrumTake(recording: LofiDrumLibrary.load(asset), clock: clock).buffer) }
            else { pcm = PCM(buffer: try ControllerDrumPerformance.generated(clock: clock)) }
            try Task.checkCancellation()
            cache.append((choice.id, clock.beatDuration, clock.sampleRate, pcm))
            if cache.count > 2 { cache.removeFirst(cache.count - 2) }
            return pcm
        }
        func rotate(_ pcm: PCM, beat: Double) throws -> PCM {
            try Task.checkCancellation()
            return PCM(buffer: try ControllerDrumPerformance.rotate(pcm.buffer,
                offset: ControllerDrumPerformance.offset(beat: beat, frames: Int(pcm.buffer.frameLength))))
        }
    }
    private let renderer = Preparation()
    private let sampleRate: Double
    private let bus: LofiBus
    private var worker: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var generation = 0
    private var prepared: (id: String, buffer: AVAudioPCMBuffer, revision: UInt32, start: Double, beat: Double)?
    private var queued: (id: String, start: Double, beat: Double, lane: Int)?
    private(set) var audibleLane = 0
    var scheduledLane: Int? { queued?.lane }
    private var lastTake: Int?
    private var manual = false
    private var latched = false
    private var selected: String?
    private(set) var current: String?
    private(set) var pending: Pending?
    private(set) var choices: [Choice] = []
    private(set) var readyChoices: Set<String> = []
    private var preparedBeat: Double?
    private var automaticName: String?
    private var automaticBPM = 0.0

    init(bus: LofiBus, sampleRate: Double = Settings.audioFormat.sampleRate) { self.bus = bus; self.sampleRate = sampleRate }
    /// Discovery stays on the preparation worker, never a note command or the audio thread.
    func discover() {
        guard choices.isEmpty, worker == nil else { return }
        worker = Task { [weak self] in
            let assets = await Task.detached(priority: .utility) { Array(LofiDrumLibrary.assets().prefix(63)) }.value
            guard let self, !Task.isCancelled else { return }
            choices = assets.enumerated().map { Choice(id: "take-\($0.offset)", label: $0.element.entry.name, bpm: $0.element.entry.bpm, asset: $0.element) }
            choices.append(Choice(id: "generated", label: "Generated break", bpm: 72, asset: nil))
            worker = nil
        }
    }
    nonisolated static func boundary(now: Double, origin: Double, beat: Double, margin: Double) -> (time: Double, beat: Double) {
        let next = ceil((now + margin - origin) / (4 * beat)) * 4
        return (origin + next * beat, next)
    }
    nonisolated static func offset(beat: Double, frames: Int) -> Int {
        let phase = beat.truncatingRemainder(dividingBy: 64)
        return ((Int((phase / 64 * Double(frames)).rounded()) % frames) + frames) % frames
    }
    func select(_ id: String?, info: LofiTransportInfo, launch: Bool = false) throws -> String {
        guard !choices.isEmpty else { throw ControllerWire.Failure.not_ready }
        let choice: Choice
        if let id { guard let found = choices.first(where: { $0.id == id }) else { throw ControllerWire.Failure.out_of_range }; choice = found }
        else {
            let i = choices.firstIndex { $0.id == (selected ?? current) } ?? -1
            choice = choices[(i + 1) % choices.count]
        }
        selected = choice.id
        let shouldSound = !manual || launch || latched
        worker?.cancel(); boundaryTask?.cancel(); queued = nil; prepared = nil; generation += 1
        let token = generation, request = UUID().uuidString
        let rate = sampleRate
        pending = Pending(request: request, choice: choice.id, status: "preparing", beat: nil)
        let margin = max(0.12, bus.drums.player.outputPresentationLatency + 0.08)
        worker = Task { [weak self] in
            do {
                guard let self else { return }
                let buffer = try await renderer.render(choice, clock: LofiClock(tempo: 60 / info.beatDuration, sampleRate: rate))
                guard !Task.isCancelled, generation == token else { return }
                readyChoices = Set(await renderer.ready(beat: LofiClock(tempo: 60 / info.beatDuration, sampleRate: rate).beatDuration, rate: rate))
                if !shouldSound {
                    pending?.status = "selected"; pending?.beat = nil; worker = nil
                    return
                }
                let boundary = Self.boundary(now: ProcessInfo.processInfo.systemUptime, origin: info.origin, beat: info.beatDuration, margin: margin)
                // Rotation is preparation work too: pad-on only selects an already constructed command.
                let rotated = try await renderer.rotate(buffer, beat: boundary.beat)
                guard !Task.isCancelled, generation == token else { return }
                readyChoices = Set(await renderer.ready(beat: LofiClock(tempo: 60 / info.beatDuration, sampleRate: rate).beatDuration, rate: rate))
                prepared = (choice.id, rotated.buffer, info.revision, boundary.time, boundary.beat)
                pending?.status = "queued"; pending?.beat = boundary.beat
                worker = nil
            } catch {
                guard let self, generation == token else { return }
                pending?.status = "failed"; worker = nil
            }
        }
        return request
    }
    func setAutomatic(_ enabled: Bool) {
        manual = !enabled
        stop()
    }
    func stop() {
        generation += 1; worker?.cancel(); boundaryTask?.cancel(); boundaryTask = nil; worker = nil; prepared = nil; queued = nil; latched = false
        for gain in bus.performanceDrumGains { ParamRamp.setGain(gain, 0, over: 0.03) }
        ParamRamp.setGain(bus.automaticDrumGain, 1, over: 0.03)
        current = nil; pending = nil
        // Players may continue silently until reuse; stopping does not affect the original timeline.
    }
    func tick(info: LofiTransportInfo?, name: String?) {
        guard let info else { return }
        automaticName = name; automaticBPM = 60 / info.beatDuration
        let now = ProcessInfo.processInfo.systemUptime
        if preparedBeat != info.beatDuration {
            let changed = preparedBeat != nil
            let resume = manual && (latched || current != nil || queued != nil)
            let replacing = pending?.status == "preparing" || pending?.status == "queued"
            preparedBeat = info.beatDuration; readyChoices.removeAll()
            if changed {
                // A retained loop belongs to its rendered tempo. Never carry it into a new
                // audible take at the old rate; keep the manual latch, reprepare on its grid.
                let choice = selected
                stop()
                if let choice, manual || replacing {
                    _ = try? select(choice, info: info, launch: resume)
                }
            }
        }
        if readyChoices.isEmpty, worker == nil, pending == nil, !choices.isEmpty {
            let candidates = Array(choices.prefix(2)), token = generation
            let clock = LofiClock(tempo: 60 / info.beatDuration, sampleRate: sampleRate)
            worker = Task { [weak self] in
                guard let self else { return }
                for choice in candidates {
                    guard !Task.isCancelled, generation == token else { return }
                    _ = try? await renderer.render(choice, clock: clock)
                }
                guard !Task.isCancelled, generation == token else { return }
                readyChoices = Set(await renderer.ready(beat: clock.beatDuration, rate: sampleRate))
                worker = nil
            }
        }
        if let prepared {
            if prepared.revision != info.revision { self.prepared = nil; pending?.status = "failed" }
            else if prepared.start - now < bus.drums.player.outputPresentationLatency + 0.025 {
                // Missed render lead. Same bar phase repeats after 64 beats; reprepare for a safe bar.
                self.prepared = nil
                _ = try? select(prepared.id, info: info, launch: manual)
            } else {
                let lane = 1 - audibleLane
                let player = bus.performanceDrums[lane].player
                player.stop(); player.scheduleBuffer(prepared.buffer, at: nil, options: .loops)
                player.play(at: AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: prepared.start - now - player.outputPresentationLatency)))
                queued = (prepared.id, prepared.start, prepared.beat, lane)
                let token = generation
                boundaryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, prepared.start - ProcessInfo.processInfo.systemUptime))) } catch { return }
                    guard let self, generation == token else { return }
                    applyQueued()
                }
                self.prepared = nil
            }
        }
        if lastTake != info.takeIndex {
            if lastTake != nil, !manual, (current != nil || pending != nil) { stop() }
            lastTake = info.takeIndex
        }
    }
    private func applyQueued() {
        guard let queued else { return }
        ParamRamp.setGain(bus.automaticDrumGain, 0, over: 0.025)
        for i in bus.performanceDrumGains.indices { ParamRamp.setGain(bus.performanceDrumGains[i], i == queued.lane ? 1 : 0, over: 0.025) }
        audibleLane = queued.lane
        current = queued.id; latched = manual
        pending?.status = "applied"; pending?.beat = queued.beat
        self.queued = nil
    }
    var wire: ControllerWire.Value {
        .object(["choices": .array(choices.map { .object(["id": .string($0.id), "label": .string($0.label), "ready": .bool(readyChoices.contains($0.id)), "bpm": .number($0.bpm)]) }),
                 "current_id": .string(current ?? choices.first(where: { $0.asset?.entry.name == automaticName })?.id ?? "automatic-silence"), "current_label": .string(current.flatMap { id in choices.first { $0.id == id }?.label } ?? automaticName ?? "Automatic (no recording)"),
                 "bpm": .number(automaticBPM),
                 "pending": pending.map { .object(["request_id": .string($0.request), "choice_id": .string($0.choice), "status": .string($0.status), "effective_beat": $0.beat.map(ControllerWire.Value.number) ?? .null]) } ?? .null])
    }
    /// Bounded synthetic fallback, using the standard drum bus before the loop is exposed.
    nonisolated static func generated(clock: LofiClock) throws -> AVAudioPCMBuffer {
        let buffer = try LofiRenderer.stereoBuffer(clock: clock, frames: clock.frameCount * 4)
        guard let c = buffer.floatChannelData else { throw ControllerDialogueBank.Failure.render }
        let n = Int(buffer.frameLength), sr = clock.sampleRate
        var rng = MusicRNG(seed: 0x505553484452554D)
        for step in 0..<128 {
            try Task.checkCancellation()
            let start = Int((Double(step) * 0.5 * clock.framesPerBeat).rounded())
            let kick = step % 8 == 0 || step % 8 == 5, snare = step % 8 == 2 || step % 8 == 6
            for i in 0..<min(Int(sr * 0.22), n - start) {
                let t = Double(i) / sr
                let noise = Float(rng.range(-1...1))
                var x = noise * Float(exp(-t * 75)) * 0.018
                if kick { x += Float(sin(2 * .pi * (48 * t + 2.4 * (1 - exp(-t * 35)))) * exp(-t * 22)) * 0.25 }
                if snare { x += noise * Float(exp(-t * 25)) * 0.10 }
                c[0][start + i] += x; c[1][start + i] += x
            }
        }
        _ = LofiStemChains.applyDrums(left: c[0], right: c[1], count: n, sampleRate: sr, settings: .standard)
        return buffer
    }
    nonisolated static func rotate(_ buffer: AVAudioPCMBuffer, offset: Int) throws -> AVAudioPCMBuffer {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { throw ControllerDialogueBank.Failure.render }
        let n = Int(buffer.frameLength)
        out.frameLength = buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<n {
                if i.isMultiple(of: 8192) { try Task.checkCancellation() }
                dst[ch][i] = src[ch][(i + offset) % n]
            }
        }
        return out
    }
}
