import AVFoundation
import Foundation

/// Prepares independently routable music stems off the audio thread.
nonisolated enum LofiRenderer {
    static let wetGain: Float = 2.25

    struct Tail: Sendable {
        let clock: LofiClock
        let left: [Float]
        let right: [Float]

        /// Existing echoes ring out at their original pitch and spacing across tempo changes.
        func sample(_ frame: Int, at nextClock: LofiClock) -> LofiEffects.Stereo {
            if clock.sampleRate == nextClock.sampleRate {
                return frame < left.count ? (left[frame], right[frame]) : (0, 0)
            }
            let position = Double(frame) * clock.sampleRate / nextClock.sampleRate
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
        let score = LofiScore.make(seed: seed, section: section, drift: drift, startBeat: startBeat,
                                   pinnedScale: options.scale, kickBeats: drums?.bassAnchors(startBeat: drumStartBeat) ?? [])
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

        let tailBeats = max(8.0, 9.0 / clock.beatDuration)
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
                             velocity: note.velocity * (note.part == .lead ? 0.44 + 0.72 * note.send : note.send), color: note.color)
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
        let dryLeadGain = leadGain(for: lead, frames: n, sampleRate: sampleRate)
        let sendGain = min(1.6, sqrtf(dryLeadGain / 1.23))
        let phrase = Int(startBeat / LofiClock.beats)
        let gesture = LofiEffects.Gesture.selection(seed: drift.seed, phrase: phrase)
        var effectRNG = MusicRNG(seed: drift.seed).fork(UInt64(phrase) + 450)
        let effectSeed = effectRNG.next()
        let filterPhase = effectRNG.rangeF(0...(2 * .pi))
        let filterRate = effectRNG.pick([Float.pi / 4, Float.pi / 6, Float.pi / 8])
        var grains = LofiEffects.granulate(leadSend, score: score, clock: clock, frames: frames, seed: effectSeed,
                                           gesture: gesture, texture: textureSend, samples: samples)
        let fill = LofiFill.ending(phrase: phrase)
        if let fill, let landing = score.notes.last(where: { $0.part == .lead }) {
            // Read the cadence backwards into the fill and forwards out of it. Stretch
            // the build by layering two octave-related pickups on the full-take turn.
            let body = clock.frame(at: landing.beat + 0.09)
            let rise = clock.frame(at: fill.buildBeats)
            let release = clock.frame(at: 0.75)
            for frame in (n - rise)..<(n + release) {
                let distance = abs(frame - n)
                let offset = distance / 2
                let strength = fill.accent(beatsFromBoundary: Double(frame - n) / clock.framesPerBeat)
                let level = strength * (fill == .halfway ? 0.72 : 0.95)
                grains.left[frame] += level * lead.left[body + offset]
                grains.right[frame] += level * lead.right[body + offset]
                if fill == .turnaround {
                    grains.left[frame] += 0.38 * level * lead.right[body + distance]
                    grains.right[frame] += 0.38 * level * lead.left[body + distance]
                }
            }
        }
        var replay = score.notes.last(where: { $0.part == .lead }).map {
            LofiEffects.ReturnReplay(lastBeat: $0.beat, clock: clock, gesture: gesture)
        }
        let captureWindow = replay?.window ?? 0..<0
        let automation = (0...Int(ceil(LofiClock.beats + tailBeats))).map { drift.at(startBeat + Double($0)) }
        let drumChannels = drums?.buffer.floatChannelData
        let drumOffset = (drumStartBeat / Int(LofiClock.beats)) * n
        var kickDuck = LofiKickDuck(sampleRate: sampleRate)
        if let drumChannels, drumOffset > 0 {
            for frame in max(0, drumOffset - Int(sampleRate * 0.25))..<drumOffset {
                _ = kickDuck.gain(drumLeft: drumChannels[0][frame], drumRight: drumChannels[1][frame])
            }
        }

        var effects = LofiEffects(clock: clock, profile: score.preset.space, tonic: score.tonic,
                                  seed: effectSeed, gesture: gesture, scale: score.scale)
        var wetTone = LofiWetTone(sampleRate: sampleRate)
        let edge = max(1, Int(sampleRate * 0.004))
        let tailFade = Float(clock.frame(at: 1.25))
        var tailL = [Float](repeating: 0, count: tailCount)
        var tailR = tailL
        var rng = MusicRNG(seed: seed).fork(12)
        var hiss: Float = 0
        var balance = InstrumentBalance(sampleRate: sampleRate)
        for frame in 0..<frames {
            if frame.isMultiple(of: 8192) { try Task.checkCancellation() }
            let position = Double(frame) / clock.framesPerBeat
            let beat = Int(position)
            let u = Float(position - Double(beat))
            let accent = fill?.accent(beatsFromBoundary: position - LofiClock.beats) ?? 0
            let space = 0.25 * accent + lerp(automation[beat].space, automation[beat + 1].space, u)
            let dryLead = (lead.left[frame], lead.right[frame])
            let dryTexture = (texture.left[frame], texture.right[frame])
            let returns = effects.processReturns(lead: (sendGain * leadSend.left[frame], sendGain * leadSend.right[frame]),
                                                 texture: (textureSend.left[frame], textureSend.right[frame]),
                                                 grains: (sendGain * grains.left[frame], sendGain * grains.right[frame]),
                                                 space: space)
            if frame < n, !effectChannels.isEmpty {
                effectChannels[0][0][frame] = returns.echo.left
                effectChannels[0][1][frame] = returns.echo.right
                effectChannels[1][0][frame] = returns.room.left
                effectChannels[1][1][frame] = returns.room.right
                effectChannels[2][0][frame] = returns.color.left
                effectChannels[2][1][frame] = returns.color.right
            }
            let sweep = 0.5 + 0.5 * sinf(Float(position) * filterRate + filterPhase)
            let filtered = wetTone.process(returns.mix, sweep: min(1, sweep + accent * 0.35), space: space)
            if captureWindow.contains(frame) {
                replay?.capture(filtered, at: frame, into: &grains)
            }
            if frame < n {
                let dust = lerp(automation[beat].dust, automation[beat + 1].dust, u)
                hiss += 0.10 * (rng.rangeF(-1...1) - hiss)
                let envelope = min(1, Float(min(frame, n - 1 - frame)) / Float(edge))
                dryChannels[0][frame] = dryLeadGain * dryLead.0 * envelope
                dryChannels[1][frame] = dryLeadGain * dryLead.1 * envelope
                textureChannels[0][frame] = (0.31 * dryTexture.0 + hiss * 0.005 * dust) * envelope
                textureChannels[1][frame] = (0.31 * dryTexture.1 + hiss * 0.005 * dust) * envelope
                wetChannels[0][frame] = Self.wetGain * filtered.left
                wetChannels[1][frame] = Self.wetGain * filtered.right
                balance.observe(dryChannels[0][frame] + textureChannels[0][frame] + wetChannels[0][frame],
                                dryChannels[1][frame] + textureChannels[1][frame] + wetChannels[1][frame])
                let kickGain = drumChannels.map {
                    kickDuck.gain(drumLeft: $0[0][drumOffset + frame], drumRight: $0[1][drumOffset + frame])
                } ?? 1
                left[frame] = headroom(left[frame]) * envelope * kickGain
                right[frame] = headroom(right[frame]) * envelope * kickGain
            } else {
                // Store pre-limit samples so an overlapping tail goes through the linked knee only once.
                let fade = min(1, Float(frames - 1 - frame) / tailFade)
                tailL[frame - n] = Self.wetGain * filtered.left * fade
                tailR[frame - n] = Self.wetGain * filtered.right * fade
                balance.observe(tailL[frame - n], tailR[frame - n])
            }
        }
        let trim = balance.gain
        for frame in 0..<n {
            let previous: LofiEffects.Stereo = carry?.sample(frame, at: clock) ?? (0, 0)
            let wet = boundedWet((wetChannels[0][frame] * trim + previous.left,
                                  wetChannels[1][frame] * trim + previous.right))
            for channel in 0..<2 {
                dryChannels[channel][frame] *= trim
                textureChannels[channel][frame] *= trim
            }
            wetChannels[0][frame] = wet.left
            wetChannels[1][frame] = wet.right
        }
        for i in tailL.indices {
            tailL[i] *= trim
            tailR[i] *= trim
        }
        let fallbackWet = try stereoBuffer(clock: clock)
        if let channels = fallbackWet.floatChannelData {
            for i in 0..<min(n, tailCount) {
                let wet = boundedWet((tailL[i], tailR[i]))
                channels[0][i] = wet.left
                channels[1][i] = wet.right
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

    /// Use the strongest 75 ms body window, so deliberate rests do not drive the gain.
    /// One gain per phrase preserves note accents, with a separate peak reserve before mixing.
    private static func leadGain(for lead: (left: [Float], right: [Float]), frames: Int, sampleRate: Double) -> Float {
        let window = max(1, Int(sampleRate * 0.075))
        var strongest: Float = 0
        var peak: Float = 0
        for start in stride(from: 0, to: frames, by: window) {
            let end = min(start + window, frames)
            var power: Float = 0
            for frame in start..<end {
                let left = lead.left[frame], right = lead.right[frame]
                power += 0.5 * (left * left + right * right)
                peak = max(peak, abs(left), abs(right))
            }
            strongest = max(strongest, power / Float(end - start))
        }
        guard peak > 0.0001 else { return 1 }
        let bodyGain = 0.155 / max(0.018, sqrtf(strongest))
        return min(4.4, 0.43 / peak, bodyGain)
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

    /// Meter this instrument and its produced returns together. One downward gain
    /// for the entire performance (including its future tail) preserves articulation.
    private struct InstrumentBalance {
        let blockFrames: Int
        var power: Double = 0
        var count = 0
        var history = [Double](repeating: 0, count: 60)
        var position = 0
        var shortSum: Double = 0
        var longSum: Double = 0
        var maxShort: Double = 0
        var maxLong: Double = 0
        var peak: Float = 0

        init(sampleRate: Double) { blockFrames = max(1, Int((sampleRate * 0.05).rounded())) }

        mutating func observe(_ left: Float, _ right: Float) {
            peak = max(peak, abs(left), abs(right))
            power += Double(left * left + right * right) * 0.5
            count += 1
            guard count == blockFrames else { return }
            let block = power / Double(count)
            shortSum += block - history[(position + 52) % 60]
            longSum += block - history[position]
            history[position] = block
            position = (position + 1) % 60
            maxShort = max(maxShort, shortSum / 8)
            maxLong = max(maxLong, longSum / 60)
            power = 0
            count = 0
        }

        // 400 ms catches a foreground note, three seconds catches a sustained wash.
        var gain: Float {
            min(1, 0.143 / max(0.001, Float(sqrt(maxShort))),
                0.098 / max(0.001, Float(sqrt(maxLong))), 0.44 / max(0.001, peak))
        }
    }

    private static func boundedWet(_ signal: LofiEffects.Stereo) -> LofiEffects.Stereo {
        let peak = max(abs(signal.left), abs(signal.right))
        guard peak > 0.25 else { return signal }
        let gain = (0.25 + 0.13 * tanhf((peak - 0.25) / 0.13)) / peak
        return (signal.left * gain, signal.right * gain)
    }

    private static func headroom(_ sample: Float) -> Float {
        let level = abs(sample)
        guard level > 0.74 else { return sample }
        let limited = 0.74 + 0.099 * tanhf((level - 0.74) / 0.099)
        return sample < 0 ? -limited : limited
    }

}
