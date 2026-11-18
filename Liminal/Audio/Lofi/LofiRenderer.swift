import AVFoundation
import Foundation

/// Prepares independently routable music stems off the audio thread.
nonisolated enum LofiRenderer {
    static let dryLeadGain: Float = 1.23
    static let wetGain: Float = 1.38

    struct Tail: Sendable {
        let clock: LofiClock
        let left: [Float]
        let right: [Float]

        /// Keep a carried echo on the new grid if the phrase changed tempo.
        func sample(_ frame: Int, at nextClock: LofiClock) -> LofiEffects.Stereo {
            let position = Double(frame) * clock.framesPerBeat / nextClock.framesPerBeat
            let i = Int(position)
            guard i + 1 < left.count else { return (0, 0) }
            let u = Float(position - Double(i))
            return (LofiRenderer.lerp(left[i], left[i + 1], u), LofiRenderer.lerp(right[i], right[i + 1], u))
        }
    }

    struct Phrase: @unchecked Sendable {
        let bass: AVAudioPCMBuffer
        let dry: AVAudioPCMBuffer
        let texture: AVAudioPCMBuffer
        let wet: AVAudioPCMBuffer
        let fallbackWet: AVAudioPCMBuffer
        let clock: LofiClock
        let score: LofiScore
        let leadSampleCount: Int
        let tail: Tail
        let effectReturns: [AVAudioPCMBuffer]
    }

    static func render(seed: UInt64, section: LofiScore.Section, options: LofiOptions, sampleRate: Double,
                       drift: LofiDrift, startBeat: Double, drums: LofiDrumTake? = nil,
                       drumStartBeat: Int = 0, carry: Tail? = nil, samples: LofiSampleBank = .bundled,
                       captureEffects: Bool = false) throws -> Phrase {
        let clock = drums?.clock ?? LofiClock(tempo: options.safeTempo, sampleRate: sampleRate)
        let score = LofiScore.make(seed: seed, section: section, drift: drift, startBeat: startBeat, pinnedScale: options.scale)
        let n = clock.frameCount
        let bass = try stereoBuffer(clock: clock)
        let dry = try stereoBuffer(clock: clock)
        let textureBuffer = try stereoBuffer(clock: clock)
        let wetBuffer = try stereoBuffer(clock: clock)
        let effectReturns = try captureEffects ? (0..<3).map { _ in try stereoBuffer(clock: clock) } : []
        let effectChannels = effectReturns.compactMap(\.floatChannelData)
        guard let bassChannels = bass.floatChannelData, let dryChannels = dry.floatChannelData,
              let textureChannels = textureBuffer.floatChannelData, let wetChannels = wetBuffer.floatChannelData
        else { throw RenderError.buffer }
        let left = UnsafeMutableBufferPointer(start: bassChannels[0], count: n)
        let right = UnsafeMutableBufferPointer(start: bassChannels[1], count: n)

        let tailBeats = 8.0
        let tailCount = clock.frame(at: tailBeats)
        let frames = n + tailCount
        let quiet = [Float](repeating: 0, count: frames)
        var lead = (left: quiet, right: quiet)
        var leadSend = (left: quiet, right: quiet)
        var texture = (left: quiet, right: quiet)
        var textureSend = (left: quiet, right: quiet)
        var leadSampleCount = 0
        for note in score.notes where note.velocity > 0 {
            try Task.checkCancellation()
            switch note.part {
            case .bass: LofiSynth.add(note, clock: clock, left: left, right: right)
            case .lead, .texture:
                let sample = samples.sample(for: score.preset, midi: note.midi, velocity: note.velocity)
                let send = LofiScore.Note(part: note.part, midi: note.midi, beat: note.beat, length: note.length,
                             velocity: note.velocity * note.send, color: note.color)
                if note.part == .lead {
                    if sample != nil { leadSampleCount += 1 }
                    addInstrument(note, sample: sample, score: score, clock: clock, into: &lead)
                    addInstrument(send, sample: sample, score: score, clock: clock, into: &leadSend)
                } else {
                    addInstrument(note, sample: sample, score: score, clock: clock, into: &texture)
                    addInstrument(send, sample: sample, score: score, clock: clock, into: &textureSend)
                }
            }
        }
        if let edit = score.virtualRecord {
            LofiVirtualRecord.splice(edit, from: lead, into: &leadSend, clock: clock)
        }
        let phrase = Int(startBeat / LofiClock.beats)
        let gesture = LofiEffects.Gesture.selection(seed: drift.seed, phrase: phrase)
        var effectRNG = MusicRNG(seed: drift.seed).fork(UInt64(phrase) + 450)
        let effectSeed = effectRNG.next()
        let filterPhase = effectRNG.rangeF(0...(2 * .pi))
        let filterRate = effectRNG.pick([Float.pi / 4, Float.pi / 6, Float.pi / 8])
        let grains = LofiEffects.granulate(leadSend, score: score, clock: clock, frames: frames, seed: effectSeed,
                                           gesture: gesture)
        let automation = (0...Int(LofiClock.beats + tailBeats)).map { drift.at(startBeat + Double($0)) }
        let drumChannels = drums?.buffer.floatChannelData
        let drumOffset = (drumStartBeat / Int(LofiClock.beats)) * n
        var kickDuck = LofiKickDuck(sampleRate: sampleRate)
        if let drumChannels, drumOffset > 0 {
            for frame in max(0, drumOffset - Int(sampleRate * 0.25))..<drumOffset {
                _ = kickDuck.gain(drumLeft: drumChannels[0][frame], drumRight: drumChannels[1][frame])
            }
        }

        var effects = LofiEffects(clock: clock, profile: score.preset.space, tonic: score.tonic,
                                  seed: effectSeed, gesture: gesture)
        var wetTone = LofiWetTone(sampleRate: sampleRate)
        let edge = max(1, Int(sampleRate * 0.004))
        let tailFade = Float(clock.frame(at: 1.25))
        var tailL = [Float](repeating: 0, count: tailCount)
        var tailR = tailL
        var rng = MusicRNG(seed: seed).fork(12)
        var hiss: Float = 0
        var foregroundWet: Float = 1
        let foregroundStep = Float(1 - exp(-1 / (sampleRate * 0.18)))
        for frame in 0..<frames {
            if frame.isMultiple(of: 8192) { try Task.checkCancellation() }
            let position = Double(frame) / clock.framesPerBeat
            let beat = Int(position)
            let u = Float(position - Double(beat))
            let space = lerp(automation[beat].space, automation[beat + 1].space, u)
            let dryLead = (lead.left[frame], lead.right[frame])
            let dryTexture = (texture.left[frame], texture.right[frame])
            let returns = effects.processReturns(lead: (leadSend.left[frame], leadSend.right[frame]),
                                                 texture: (textureSend.left[frame], textureSend.right[frame]),
                                                 grains: (grains.left[frame], grains.right[frame]),
                                                 space: space)
            if frame < n, !effectChannels.isEmpty {
                effectChannels[0][0][frame] = returns.echo.left
                effectChannels[0][1][frame] = returns.echo.right
                effectChannels[1][0][frame] = returns.room.left
                effectChannels[1][1][frame] = returns.room.right
                effectChannels[2][0][frame] = returns.color.left
                effectChannels[2][1][frame] = returns.color.right
            }
            let inForegroundRest = score.foregroundSpace.contains(position)
            foregroundWet += ((inForegroundRest ? 0.68 : 1) - foregroundWet) * foregroundStep
            let sweep = 0.5 + 0.5 * sinf(Float(position) * filterRate + filterPhase)
            let wet = wetTone.process(returns.mix, sweep: sweep, space: space)
            if frame < n {
                let dust = lerp(automation[beat].dust, automation[beat + 1].dust, u)
                hiss += 0.10 * (rng.rangeF(-1...1) - hiss)
                let previous: LofiEffects.Stereo = carry?.sample(frame, at: clock) ?? (0, 0)
                let envelope = min(1, Float(min(frame, n - 1 - frame)) / Float(edge))
                dryChannels[0][frame] = Self.dryLeadGain * dryLead.0 * envelope
                dryChannels[1][frame] = Self.dryLeadGain * dryLead.1 * envelope
                textureChannels[0][frame] = (0.31 * dryTexture.0 + hiss * 0.005 * dust) * envelope
                textureChannels[1][frame] = (0.31 * dryTexture.1 + hiss * 0.005 * dust) * envelope
                // The previous return already contains the sample at this boundary.
                wetChannels[0][frame] = Self.wetGain * wet.left * foregroundWet + previous.left
                wetChannels[1][frame] = Self.wetGain * wet.right * foregroundWet + previous.right
                let kickGain = drumChannels.map {
                    kickDuck.gain(drumLeft: $0[0][drumOffset + frame], drumRight: $0[1][drumOffset + frame])
                } ?? 1
                left[frame] = headroom(left[frame]) * envelope * kickGain
                right[frame] = headroom(right[frame]) * envelope * kickGain
            } else {
                let fade = min(1, Float(frames - 1 - frame) / tailFade)
                tailL[frame - n] = Self.wetGain * wet.left * fade * foregroundWet
                tailR[frame - n] = Self.wetGain * wet.right * fade * foregroundWet
            }
        }
        let fallbackWet = try stereoBuffer(clock: clock)
        if let channels = fallbackWet.floatChannelData {
            for i in 0..<min(n, tailCount) {
                channels[0][i] = tailL[i]
                channels[1][i] = tailR[i]
            }
        }
        return Phrase(bass: bass, dry: dry, texture: textureBuffer, wet: wetBuffer, fallbackWet: fallbackWet,
                      clock: clock, score: score, leadSampleCount: leadSampleCount,
                      tail: Tail(clock: clock, left: tailL, right: tailR), effectReturns: effectReturns)
    }

    static func stereoBuffer(clock: LofiClock, frames: Int? = nil) throws -> AVAudioPCMBuffer {
        let count = frames ?? clock.frameCount
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clock.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { throw RenderError.buffer }
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 { channels[channel].initialize(repeating: 0, count: count) }
        return buffer
    }

    private static func addInstrument(_ note: LofiScore.Note, sample: LofiSampleBank.Sample?, score: LofiScore,
                                clock: LofiClock, into stereo: inout (left: [Float], right: [Float])) {
        stereo.left.withUnsafeMutableBufferPointer { left in
            stereo.right.withUnsafeMutableBufferPointer { right in
                if let sample {
                    LofiSampleBank.add(note, from: sample, preset: score.preset, clock: clock, left: left, right: right)
                } else {
                    LofiSynth.add(note, clock: clock, left: left, right: right)
                }
            }
        }
    }

    enum RenderError: Error { case buffer }

    private static func lerp(_ start: Float, _ end: Float, _ progress: Float) -> Float {
        start + (end - start) * progress
    }

    private static func headroom(_ sample: Float) -> Float {
        let level = abs(sample)
        guard level > 0.74 else { return sample }
        let limited = 0.74 + 0.099 * tanhf((level - 0.74) / 0.099)
        return sample < 0 ? -limited : limited
    }

}
