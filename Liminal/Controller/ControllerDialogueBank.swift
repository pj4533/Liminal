import AVFoundation
import Foundation
import os

/// Immutable preparation result. No decoding, DSP or buffer allocation occurs on pad-on.
nonisolated struct ControllerDialogueBank: @unchecked Sendable {
    struct Pad: @unchecked Sendable {
        let index: Int
        let role: String
        let beats: Double
        let buffer: AVAudioPCMBuffer
    }
    let cueToken: Int
    let bankID: UInt64
    let planRevision: Int
    let transportRevision: UInt32
    let activation: Double
    let end: Double
    let pads: [Pad]
    static let byteLimit = 32 * 1024 * 1024
    var bytes: Int { pads.reduce(0) { $0 + Int($1.buffer.frameLength) * Int($1.buffer.format.channelCount) * 4 } }

    /// Nearest grid duration whose pitch-preserving stretch rate stays in 0.5...2.
    static func beatLength(seconds: Double, beat: Double, whole: Bool) -> Double? {
        guard seconds.isFinite, seconds > 0, beat.isFinite, beat > 0 else { return nil }
        let step = whole ? 1.0 : 0.25
        let low = max(1, Int(ceil(seconds / (2 * beat * step))))
        let high = Int(floor(seconds * 2 / (beat * step)))
        guard high >= low else { return nil }
        return Double(min(high, max(low, Int((seconds / beat / step).rounded())))) * step
    }

    static func prepare(_ built: DialogueCueCoordinator.Built, source incoming: DialogueSource,
                        activation: Double) -> Self? {
        guard let bank = built.played, !bank.pads.isEmpty else { return nil }
        // A remembered film's pad ranges must never index the current film's PCM.
        let source = built.motif?.source ?? incoming
        let analysis = built.motif?.analysis ?? built.analysis
        guard bank.sourceID == source.contentID else { return nil }
        var result: [Pad] = [], bytes = 0
        let items = (bank.pads.indices.contains(bank.anchorPadID) ? [(63, bank.anchor, true)] : [])
            + Array(bank.pads.prefix(63).enumerated().map { ($0.offset, $0.element, false) })
        for (index, pad, whole) in items {
            if Task.isCancelled { return nil }
            var level: Float?
            guard let dry = DialogueChopRenderer.renderPad(pad, source: source, analysis: analysis, gainDB: 0, level: &level),
                  let beats = beatLength(seconds: Double(dry.frameLength) / dry.format.sampleRate,
                                         beat: built.snapshot.beatDuration, whole: whole),
                  Int((beats * built.snapshot.beatDuration * dry.format.sampleRate).rounded()) * Int(dry.format.channelCount) * 4 <= byteLimit - bytes,
                  let stretched = try? stretch(dry, frames: Int((beats * built.snapshot.beatDuration * dry.format.sampleRate).rounded()))
            else { continue }
            let size = Int(stretched.frameLength) * Int(stretched.format.channelCount) * 4
            guard bytes + size <= byteLimit else { continue }
            bytes += size
            result.append(Pad(index: index, role: whole ? "whole_line" : pad.role.rawValue, beats: beats, buffer: stretched))
        }
        guard !result.isEmpty else { return nil }
        return Self(cueToken: incoming.cueToken, bankID: bank.bankID, planRevision: built.plan.revision,
                    transportRevision: built.snapshot.revision, activation: activation,
                    end: built.window.upperBound, pads: result.sorted { $0.index < $1.index })
    }

    /// Offline Apple time/pitch unit; pitch stays zero. Leading silence warms the unit;
    /// its reported latency plus stretched preroll is removed, then exact grid frames are copied.
    static func stretch(_ input: AVAudioPCMBuffer, frames: Int) throws -> AVAudioPCMBuffer {
        guard frames > 1, let src = input.floatChannelData else { throw Failure.render }
        let sr = input.format.sampleRate, count = Int(input.frameLength)
        let rate = Double(count) / Double(frames)
        guard (0.5...2).contains(rate) else { throw Failure.render }
        let preroll = Int(sr * 0.15)
        guard let padded = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(count + 2 * preroll)),
              let p = padded.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(frames)) else { throw Failure.render }
        padded.frameLength = padded.frameCapacity
        for ch in 0..<Int(input.format.channelCount) {
            p[ch].initialize(repeating: 0, count: Int(padded.frameLength))
            p[ch].advanced(by: preroll).update(from: src[ch], count: count)
        }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(rate); pitch.pitch = 0
        engine.attach(player); engine.attach(pitch)
        engine.connect(player, to: pitch, format: input.format)
        engine.connect(pitch, to: engine.mainMixerNode, format: input.format)
        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: 4096)
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        try engine.start()
        player.scheduleBuffer(padded); player.play()
        let skip = Int((Double(preroll) / rate + pitch.auAudioUnit.latency * sr).rounded())
        guard let block = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: 4096),
              let dst = output.floatChannelData else { throw Failure.render }
        var rendered = 0, copied = 0, attempts = 0
        while copied < frames, attempts < (skip + frames) / 4096 + 128 {
            attempts += 1
            try Task.checkCancellation()
            let status = try engine.renderOffline(4096, to: block)
            guard status == .success || status == .insufficientDataFromInputNode else {
                if status == .cannotDoInCurrentContext { continue }
                throw Failure.render
            }
            let n = Int(block.frameLength), start = max(0, skip - rendered)
            let take = min(max(0, n - start), frames - copied)
            if take > 0, let data = block.floatChannelData {
                for ch in 0..<Int(input.format.channelCount) { dst[ch].advanced(by: copied).update(from: data[ch].advanced(by: start), count: take) }
                copied += take
            }
            rendered += n
        }
        guard copied == frames else { throw Failure.render }
        output.frameLength = AVAudioFrameCount(frames)
        let fade = min(frames / 2, Int(sr * 0.006))
        for ch in 0..<Int(input.format.channelCount) {
            for i in 0..<fade {
                let gain = Float(i) / Float(max(1, fade - 1))
                dst[ch][i] *= gain; dst[ch][frames - 1 - i] *= gain
            }
        }
        return output
    }
    enum Failure: Error { case render }
}

/// Cross-queue publication. Only the conductor activates banks; prepared next cues are inert.
nonisolated final class ControllerDialogueState: @unchecked Sendable {
    struct Snapshot { var bank: ControllerDialogueBank?; var revision: Int64 = 0; var film = false }
    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    func read() -> Snapshot { state.withLock { $0 } }
    func publish(_ bank: ControllerDialogueBank?) { state.withLock { s in s.bank = bank; s.revision += 1 } }
    func film(_ available: Bool) { state.withLock { $0.film = available } }
}

/// One serial utility renderer and one supersedable request per director, never a task per pad.
nonisolated final class ControllerDialoguePreparation: @unchecked Sendable {
    private actor Lane {
        func render(_ built: DialogueCueCoordinator.Built, source: DialogueSource, activation: Double) -> ControllerDialogueBank? {
            guard !Task.isCancelled else { return nil }
            return ControllerDialogueBank.prepare(built, source: source, activation: activation)
        }
    }
    private let lane = Lane()
    private let work = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    func submit(_ built: DialogueCueCoordinator.Built, source: DialogueSource, activation: Double,
                valid: @escaping @Sendable () -> Bool, post: @escaping @Sendable (ControllerDialogueBank) -> Void) {
        work.withLock { task in
            task?.cancel()
            task = Task.detached(priority: .utility) { [lane] in
                guard !Task.isCancelled, valid(),
                      let bank = await lane.render(built, source: source, activation: activation),
                      !Task.isCancelled, valid() else { return }
                post(bank)
            }
        }
    }
}
