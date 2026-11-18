import AVFoundation
import Foundation

/// Builds the dry rhythm and the wet instruments off the audio thread.
nonisolated enum LofiRenderer {
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
        let buffer: AVAudioPCMBuffer
        let musicBuffer: AVAudioPCMBuffer
        let clock: LofiClock
        let score: LofiScore
        let drumName: String?
        let leadSampleCount: Int
        let tail: Tail
    }

    static func render(seed: UInt64, section: LofiScore.Section, options: LofiOptions, sampleRate: Double,
                       drift: LofiDrift, startBeat: Double, recording: LofiDrumLibrary.Break?,
                       drumStartBeat: Int = 0, carry: Tail? = nil, samples: LofiSampleBank = .bundled) throws -> Phrase {
        let clock = LofiClock(tempo: options.safeTempo, sampleRate: sampleRate)
        let score = LofiScore.make(seed: seed, section: section, drift: drift, startBeat: startBeat)
        let n = clock.frameCount
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let musicBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let channels = buffer.floatChannelData,
              let music = musicBuffer.floatChannelData else { throw RenderError.buffer }
        buffer.frameLength = AVAudioFrameCount(n)
        musicBuffer.frameLength = AVAudioFrameCount(n)
        let left = UnsafeMutableBufferPointer(start: channels[0], count: n)
        let right = UnsafeMutableBufferPointer(start: channels[1], count: n)
        left.initialize(repeating: 0)
        right.initialize(repeating: 0)

        let tailCount = clock.frame(at: 6)
        let frames = n + tailCount
        let quiet = [Float](repeating: 0, count: frames)
        var lead = (left: quiet, right: quiet)
        var texture = (left: quiet, right: quiet)
        var leadSampleCount = 0
        for note in score.notes where note.velocity > 0 {
            try Task.checkCancellation()
            switch note.part {
            case .bass: LofiSynth.add(note, clock: clock, left: left, right: right)
            case .lead:
                guard let sample = samples.sample(for: score.preset, midi: note.midi) else { continue }
                leadSampleCount += 1
                lead.left.withUnsafeMutableBufferPointer { l in
                    lead.right.withUnsafeMutableBufferPointer { r in
                        LofiSampleBank.add(note, from: sample, preset: score.preset, clock: clock, left: l, right: r)
                    }
                }
            case .texture:
                texture.left.withUnsafeMutableBufferPointer { l in
                    texture.right.withUnsafeMutableBufferPointer { r in
                        LofiSynth.add(note, clock: clock, left: l, right: r)
                    }
                }

            }
        }
        let phrase = Int(startBeat / LofiClock.beats)
        let gesture = LofiEffects.Gesture.selection(seed: drift.seed, phrase: phrase)
        var effectRNG = MusicRNG(seed: drift.seed).fork(UInt64(phrase) + 450)
        let effectSeed = effectRNG.next()
        let grains = LofiEffects.granulate(lead, score: score, clock: clock, frames: frames, seed: effectSeed,
                                           gesture: gesture)
        let automation = (0...Int(LofiClock.beats + 6)).map { drift.at(startBeat + Double($0)) }
        if let recording {
            addDrums(recording, clock: clock, startBeat: drumStartBeat, levels: automation.map(\.drums),
                     left: left, right: right)
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
        for frame in 0..<frames {
            if frame.isMultiple(of: 8192) { try Task.checkCancellation() }
            let position = Double(frame) / clock.framesPerBeat
            let beat = Int(position)
            let u = Float(position - Double(beat))
            let space = lerp(automation[beat].space, automation[beat + 1].space, u)
            let dryLead = (lead.left[frame], lead.right[frame])
            let dryTexture = (texture.left[frame], texture.right[frame])
            let wet = wetTone.process(effects.process(lead: dryLead, texture: dryTexture,
                                                      grains: (grains.left[frame], grains.right[frame]), space: space))
            if frame < n {
                let dust = lerp(automation[beat].dust, automation[beat + 1].dust, u)
                hiss += 0.10 * (rng.rangeF(-1...1) - hiss)
                let previous: LofiEffects.Stereo = carry?.sample(frame, at: clock) ?? (0, 0)
                let envelope = min(1, Float(min(frame, n - 1 - frame)) / Float(edge))
                let musicScale: Float = 0.92
                music[0][frame] = musicScale * headroom(0.91 * dryLead.0 + 0.37 * dryTexture.0
                                       + wet.left + previous.left + hiss * 0.007 * dust) * envelope
                music[1][frame] = musicScale * headroom(0.91 * dryLead.1 + 0.37 * dryTexture.1
                                        + wet.right + previous.right + hiss * 0.007 * dust) * envelope
                left[frame] = headroom(left[frame]) * envelope
                right[frame] = headroom(right[frame]) * envelope
            } else {
                let fade = min(1, Float(frames - 1 - frame) / tailFade)
                tailL[frame - n] = wet.left * fade
                tailR[frame - n] = wet.right * fade
            }
        }
        return Phrase(buffer: buffer, musicBuffer: musicBuffer, clock: clock, score: score, drumName: recording?.entry.name,
                      leadSampleCount: leadSampleCount, tail: Tail(clock: clock, left: tailL, right: tailR))
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

    /// Native drum feel is preserved. Resample the whole stereo recording as a pair at a modest rate.
    /// Four consecutive phrases cover the original performance in order.
    private static func addDrums(_ asset: LofiDrumLibrary.Break, clock: LofiClock, startBeat: Int,
                                 levels: [Float], left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let sourcePerBeat = asset.entry.framesPerBeat
        let rate = sourcePerBeat / clock.framesPerBeat
        let step = min(16, asset.entry.beats)
        let segment = clock.frame(at: Double(step))
        let offset = startBeat % asset.entry.beats
        let end = left.count
        let edge = max(1, Int(clock.sampleRate * 0.003))
        let pole = Float(1 - exp(-2 * .pi * 8200 / clock.sampleRate))
        let sectionLevel = asset.gain
        var ml: Float = 0, mr: Float = 0
        for i in 0..<end {
            let local = i % segment
            let position = Double(offset) * sourcePerBeat + Double(local) * rate
            let j = Int(position)
            guard j + 1 < asset.left.count else { continue }
            let f = Float(position - Double(j))
            let a = asset.left[j] + (asset.left[j + 1] - asset.left[j]) * f
            let b = asset.right[j] + (asset.right[j + 1] - asset.right[j]) * f
            ml += (a - ml) * pole
            mr += (b - mr) * pole
            let edgeGain = min(1, Float(min(local, segment - local - 1, end - i - 1)) / Float(edge))
            let beatPosition = Double(i) / clock.framesPerBeat
            let beat = Int(beatPosition)
            let level = sectionLevel * lerp(levels[beat], levels[beat + 1], Float(beatPosition - Double(beat)))
            left[i] += ml * level * edgeGain
            right[i] += mr * level * edgeGain
        }
    }
}
