import AVFoundation
import Foundation

/// Prepares independently routable music stems off the audio thread.
nonisolated enum LofiRenderer {
    static let wetGain: Float = 2.25
    /// Nominal dry level of the sampled mid shells on the texture stem (the fixed trim was 0.31).
    /// Used when a phrase has too little lead and mid overlap to measure (`midsLevel`).
    static let midsTrim: Float = 2.2
    /// Where lead and mids sound together, the mids sit this far under the lead in 400 Hz to 3 kHz
    /// (M13 asks for 3 to 8 dB). Chosen by measurement on the reference captures.
    static let midsUnderLeadDB: Float = 5.5
    /// The per-phrase mids gain stays within this factor of `midsTrim` either way.
    static let midsGainRange: Float = 2.5
    /// Plucked attacks never push the dry mids above -4.4 dBFS before the instrument balance.
    static let midsPeakCeiling: Float = 0.6
    /// The mids' contribution to `InstrumentBalance`, at the former 0.31 trim.
    static let midsMeterTrim: Float = 0.31
    /// The wet stem under a return's opening notes, -6 dB: the carried tail and the phrase's own
    /// returns dip together, so the room of the first notes blooms after them instead of over them.
    static let returnCarryFloor: Float = 0.501_187
    /// The dip is released by the start of the second bar at the latest.
    static let returnRevealLatestHold = 3.5

    /// How long (in beats) a return holds its wet stem down: through the first two beats, or to
    /// the end of the second revealed note (at most one second of it) when that falls later.
    static func returnRevealHold(_ score: LofiScore, clock: LofiClock) -> Double {
        let second = score.notes.last { $0.part == .lead && $0.gain == LofiScore.returnRevealGain }
        let end = second.map { $0.beat + min($0.length, 1 / clock.beatDuration) } ?? 0
        return max(2, min(returnRevealLatestHold, end))
    }

    /// Smoothly lowers the wet stem as the return enters: down over the first quarter beat (under
    /// the downbeat), held to `hold`, back up half a beat later.
    static func returnCarryGain(beat: Double, hold: Double = 2) -> Float {
        func smooth(_ u: Double) -> Float { let x = Float(min(1, max(0, u))); return x * x * (3 - 2 * x) }
        let down = smooth(beat / 0.25), up = smooth((beat - hold) / 0.5)
        return 1 - (1 - returnCarryFloor) * down * (1 - up)
    }

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
        // A take with landmarks drives bass placement through its timing field; otherwise the old kicks.
        let timing = drums.flatMap { $0.landmarks.isEmpty ? nil : $0.timing }
        let score = LofiScore.make(seed: seed, section: section, drift: drift, startBeat: startBeat,
                                   pinnedScale: options.scale, kickBeats: drums?.bassAnchors(startBeat: drumStartBeat) ?? [],
                                   timing: timing, timingStartBeat: drumStartBeat, beatSeconds: clock.beatDuration)
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
        // A note's extra gain is kept apart until the phrase's lead gain is measured, so a revealed
        // note stands out instead of turning the whole phrase down.
        var leadAccent: (left: [Float], right: [Float])?
        for note in score.notes where note.velocity > 0 {
            try Task.checkCancellation()
            switch note.part {
            case .bass: LofiBassVoice.add(note, voice: score.bassVoice, clock: clock, left: left, right: right)
            case .lead, .texture:
                let sample = samples.sample(for: score.preset, midi: note.midi, velocity: note.velocity)
                // A revealed return note scales its whole send, the fixed part included, so the
                // score's 40 percent reduction is a 40 percent lower send level.
                let floor: Float = note.gain == LofiScore.returnRevealGain ? 0.44 * LofiScore.returnRevealSend : 0.44
                let send = LofiScore.Note(part: note.part, midi: note.midi, beat: note.beat, length: note.length,
                             velocity: note.velocity * (note.part == .lead ? floor + 0.72 * note.send : note.send), color: note.color)
                if note.part == .lead {
                    if sample != nil { leadSampleCount += 1 }
                    addInstrument(note, sample: sample, score: score, clock: clock, into: &lead)
                    addInstrument(send, sample: sample, score: score, clock: clock, into: &leadSend)
                    if note.gain != 1 {
                        var accent = leadAccent ?? (quiet, quiet)
                        let extra = LofiScore.Note(part: .lead, midi: note.midi, beat: note.beat, length: note.length,
                                                   velocity: note.velocity * (note.gain - 1), color: note.color)
                        addInstrument(extra, sample: sample, score: score, clock: clock, into: &accent)
                        leadAccent = accent
                    }
                } else {
                    let dryNote = LofiScore.Note(part: .texture, midi: note.midi, beat: note.beat, length: note.length,
                                                 velocity: note.velocity * note.gain, color: note.color)
                    addInstrument(dryNote, sample: sample, score: score, clock: clock, into: &texture)
                    addInstrument(send, sample: sample, score: score, clock: clock, into: &textureSend)
                }
            }
        }
        if let edit = score.virtualRecord {
            LofiVirtualRecord.splice(edit, from: lead, into: &leadSend, clock: clock)
        }
        let dryLeadGain = leadGain(for: lead, frames: n, sampleRate: sampleRate)
        if let leadAccent {
            for frame in 0..<frames {
                lead.left[frame] += leadAccent.left[frame]
                lead.right[frame] += leadAccent.right[frame]
            }
        }
        let sendGain = min(1.6, sqrtf(dryLeadGain / 1.23))
        let midsGain = midsLevel(lead: lead, leadGain: dryLeadGain, texture: texture, score: score, clock: clock)
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
                textureChannels[0][frame] = (midsGain * dryTexture.0 + hiss * 0.005 * dust) * envelope
                textureChannels[1][frame] = (midsGain * dryTexture.1 + hiss * 0.005 * dust) * envelope
                wetChannels[0][frame] = Self.wetGain * filtered.left
                wetChannels[1][frame] = Self.wetGain * filtered.right
                // The balance meters the mids at their former level, so raising them never
                // turns the lead down with them.
                let metered = (Self.midsMeterTrim * dryTexture.0, Self.midsMeterTrim * dryTexture.1)
                balance.observe(dryChannels[0][frame] + metered.0 + wetChannels[0][frame],
                                dryChannels[1][frame] + metered.1 + wetChannels[1][frame])
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
        report(score, clock: clock, phrase: Int(startBeat / LofiClock.beats),
               levels: ["leadGain": dryLeadGain, "sendGain": sendGain, "midsGain": midsGain, "balanceTrim": trim])
        let reveal = score.section == .returnTheme
        let hold = returnRevealHold(score, clock: clock)
        for frame in 0..<n {
            let previous: LofiEffects.Stereo = carry?.sample(frame, at: clock) ?? (0, 0)
            let revealed = reveal ? Self.returnCarryGain(beat: Double(frame) / clock.framesPerBeat, hold: hold) : 1
            let wet = boundedWet((revealed * (wetChannels[0][frame] * trim + previous.left),
                                  revealed * (wetChannels[1][frame] * trim + previous.right)))
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

    /// One mids gain per phrase: meter the dry lead (after its gain) and the dry mids in 400 Hz to
    /// 3 kHz where the score has both sounding, and set the mids `midsUnderLeadDB` under the lead.
    /// Every program and arrangement then keeps the same relation; the mids never ride per note.
    private static func midsLevel(lead: (left: [Float], right: [Float]), leadGain: Float,
                                  texture: (left: [Float], right: [Float]), score: LofiScore,
                                  clock: LofiClock) -> Float {
        // A breakdown's single soft answer keeps its nominal, quieter level.
        guard score.section != .breakdown else { return midsTrim }
        let n = clock.frameCount
        var leadOn = [Bool](repeating: false, count: n), midOn = leadOn
        for note in score.notes where note.part != .bass {
            let range = max(0, clock.frame(at: note.beat))..<min(n, clock.frame(at: note.beat + note.length))
            guard !range.isEmpty else { continue }
            if note.part == .lead { for f in range { leadOn[f] = true } } else { for f in range { midOn[f] = true } }
        }
        let rate = Float(clock.sampleRate)
        let high = expf(-2 * .pi * 400 / rate), low = 1 - expf(-2 * .pi * 3_000 / rate)
        struct Meter {
            var x: Float = 0, hp: Float = 0, lp: Float = 0
            mutating func band(_ input: Float, high: Float, low: Float) -> Float {
                hp = high * (hp + input - x)
                x = input
                lp += (hp - lp) * low
                return lp
            }
        }
        var leadMeter = Meter(), midMeter = Meter()
        var leadPower: Double = 0, midPower: Double = 0
        var count = 0
        var peak: Float = 0
        for frame in 0..<n {
            peak = max(peak, abs(texture.left[frame]), abs(texture.right[frame]))
            let l = leadMeter.band(0.5 * (lead.left[frame] + lead.right[frame]), high: high, low: low) * leadGain
            let m = midMeter.band(0.5 * (texture.left[frame] + texture.right[frame]), high: high, low: low)
            guard leadOn[frame], midOn[frame] else { continue }
            leadPower += Double(l * l)
            midPower += Double(m * m)
            count += 1
        }
        var gain = midsTrim
        if count >= Int(0.25 * clock.sampleRate), midPower > 1e-14, leadPower > 1e-14 {
            let matched = Float(sqrt(leadPower / midPower)) * powf(10, -midsUnderLeadDB / 20)
            gain = min(midsTrim * midsGainRange, max(midsTrim / midsGainRange, matched))
        }
        // Plucked programs meter quietly over a held shell; never let their attacks overshoot.
        return peak > 0 ? min(gain, midsPeakCeiling / peak) : gain
    }

    /// Capture-only: one `diagnostics.bass` element per phrase, frames on the capture timeline
    /// (phrase index times phrase frames). `attackFrame` is the note start plus the voice's attack lead.
    private static func report(_ score: LofiScore, clock: LofiClock, phrase: Int, levels: [String: Float]) {
        guard LofiCaptureHooks.isEnabled else { return }
        let origin = phrase * clock.frameCount
        let lead = Int((score.bassVoice.attackLead * clock.sampleRate).rounded())
        let notes: [[String: Any]] = score.notes.filter { $0.part == .bass }.map { note in
            let frame = origin + clock.frame(at: note.beat)
            let kick = score.bassAnchors.first { $0.noteBeat == note.beat }
            return ["frame": frame, "attackFrame": frame + lead, "midi": note.midi,
                    "alignedKickFrame": kick.map { origin + clock.frame(at: $0.kickBeat) as Any } ?? NSNull()]
        }
        LofiCaptureHooks.appendReport("bass", ["phrase": phrase, "voice": String(describing: score.bassVoice),
                                               "notes": notes] as [String: Any])
        // Per-phrase gains of the instrument stems, for the stem-chain and balance work.
        let mids = score.notes.filter { $0.part == .texture }
        var entry: [String: Any] = levels.mapValues { Double($0) }
        entry["phrase"] = phrase
        entry["section"] = String(describing: score.section)
        entry["program"] = score.preset.name
        entry["midEvents"] = mids.count / 2
        entry["midArticulations"] = mids.map { String(describing: $0.articulation) }
        LofiCaptureHooks.appendReport("musicLevels", entry)
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
