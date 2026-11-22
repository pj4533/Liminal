import Accelerate
import AVFoundation
import Foundation

/// Prepares independently routable music stems off the audio thread.
nonisolated enum LofiRenderer {
    /// Space return level after the space chain (plan 8.4). The chain's 350 Hz high-pass and
    /// 4.5 kHz low-pass took about 3 dB off the wash (2.25 before); this restores half of it, so
    /// the space stays at least 3 dB under the lead (C-B7) and the wash stays present.
    static let wetGain: Float = 2.7
    /// The wet stem under a return's opening notes, -9 dB (-6 dB before mix calibration): the carried tail
    /// and the phrase's own returns dip together, so the room of the first notes blooms after them instead
    /// of over them. The deeper dip keeps a low-register hook salient (C-B6, case `long`).
    static let returnCarryFloor: Float = 0.354_813
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
        /// The phrase's dry lead gain (`leadGain(for:)`, melody and ornaments only) and the instrument
        /// balance times the program trim that follows it.
        var leadGain: Float = 1
        var instrumentTrim: Float = 1
    }

    static func render(seed: UInt64, section: LofiScore.Section, options: LofiOptions, sampleRate: Double,
                       drift: LofiDrift, startBeat: Double, drums: LofiDrumTake? = nil,
                       drumStartBeat: Int = 0, carry: Tail? = nil, samples: LofiSampleBank = .bundled,
                       captureEffects: Bool = false, audition: LofiScore.Audition = .none,
                       revise: ((LofiScore) -> LofiScore)? = nil) throws -> Phrase {
        let clock = drums?.clock ?? LofiClock(tempo: options.safeTempo, sampleRate: sampleRate)
        // A take with landmarks drives bass placement through its timing field; otherwise the old kicks.
        let timing = drums.flatMap { $0.landmarks.isEmpty ? nil : $0.timing }
        let made = LofiScore.make(seed: seed, section: section, drift: drift, startBeat: startBeat,
                                   pinnedScale: options.scale, kickBeats: drums?.bassAnchors(startBeat: drumStartBeat) ?? [],
                                   timing: timing, timingStartBeat: drumStartBeat, beatSeconds: clock.beatDuration,
                                   audition: audition)
        // `revise` is a test seam (a hand-made strum on a scored phrase); nil in the app.
        let score = revise?(made) ?? made
        // Capture-only render tuning (`tune.*` hooks), resolved once per phrase here on the render worker;
        // `.standard` in the app.
        let tuning = LofiRenderTuning.capture()
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
        // The two shell voices render apart so the mids chain can place them (plan 8.4); the held pad
        // and the sends render beside them (D117).
        var textureVoices = TextureVoices(frames: frames)
        var leadSampleCount = 0
        // A note's extra gain is kept apart until the phrase's lead gain is measured, so a revealed
        // note stands out instead of turning the whole phrase down.
        var leadAccent: (left: [Float], right: [Float])?
        // The strummed hook's dry strings (D128): the accent buffer's path, kept apart so the phrase
        // balance meters the phrase without them.
        var strumDry: (left: [Float], right: [Float])?
        let upperVoices = Self.upperShellVoices(score)
        for (index, note) in score.notes.enumerated() where note.velocity > 0 {
            try Task.checkCancellation()
            switch note.part {
            case .bass: addBass(note, score: score, clock: clock, samples: samples, left: left, right: right)
            case .strum:
                // The strummed hook (D128) renders beside the melody in the accent buffer: the lead's
                // filters and gain curve and the phrase's lead gain, but never the gain measurement or
                // the compressor's reference, so the melody's level is the same with the hook or without.
                // Its send is mostly its own: a plain stab sends little, a thrown one about 15 dB more.
                let sample = samples.sample(for: score.preset, midi: note.midi, velocity: note.velocity)
                let level = note.velocity * note.gain
                let dryNote = Self.strumString(note, velocity: level)
                let send = Self.strumString(note, velocity: level * (Self.strumSendFloor + Self.strumSendScale * note.send))
                var strings = strumDry ?? (quiet, quiet)
                addInstrument(dryNote, sample: sample, score: score, clock: clock, into: &strings)
                strumDry = strings
                addInstrument(send, sample: sample, score: score, clock: clock, into: &leadSend)
            case .lead, .texture, .ornament:
                let sample = samples.sample(for: score.preset, midi: note.midi, velocity: note.velocity)
                // A revealed return note scales its whole send, the fixed part included, so the
                // score's 40 percent reduction is a 40 percent lower send level.
                let floor: Float = note.gain == LofiScore.returnRevealGain ? 0.44 * LofiScore.returnRevealSend : 0.44
                var send = LofiScore.Note(part: note.part, midi: note.midi, beat: note.beat, length: note.length,
                             velocity: note.velocity * (note.part.playsLead ? floor + 0.72 * note.send : note.send), color: note.color)
                send.damp = note.damp
                if note.part.playsLead {
                    if note.part == .lead, sample != nil { leadSampleCount += 1 }
                    addInstrument(note, sample: sample, score: score, clock: clock, into: &lead)
                    addInstrument(send, sample: sample, score: score, clock: clock, into: &leadSend)
                    if note.gain != 1 {
                        var accent = leadAccent ?? (quiet, quiet)
                        var extra = LofiScore.Note(part: .lead, midi: note.midi, beat: note.beat, length: note.length,
                                                   velocity: note.velocity * (note.gain - 1), color: note.color)
                        extra.damp = note.damp
                        addInstrument(extra, sample: sample, score: score, clock: clock, into: &accent)
                        leadAccent = accent
                    }
                } else {
                    addTexture(note, send: send, sample: sample, samples: samples, score: score, clock: clock,
                               isUpper: upperVoices.contains(index), into: &textureVoices)
                }
            }
        }
        if let edit = score.virtualRecord {
            LofiVirtualRecord.splice(edit, from: lead, into: &leadSend, clock: clock)
        }
        let phrase = Int(startBeat / LofiClock.beats)
        // Lead and mids chains on the full phrase-plus-tail arrays, from silence, before any edge.
        let leadStats = LofiStemChains.applyLead(left: &lead.left, right: &lead.right, accent: &leadAccent,
                                                 strum: &strumDry, sampleRate: sampleRate)
        let dryLeadGain = leadGain(for: lead, frames: n, sampleRate: sampleRate)
        if let leadAccent {
            vDSP_vadd(lead.left, 1, leadAccent.left, 1, &lead.left, 1, vDSP_Length(frames))
            vDSP_vadd(lead.right, 1, leadAccent.right, 1, &lead.right, 1, vDSP_Length(frames))
        }
        let sendGain = min(1.6, sqrtf(dryLeadGain / 1.23))
        // The mids are matched to and ducked under the melody alone, so the hook never moves their level.
        let mids = finishTexture(&textureVoices, lead: lead, leadGain: dryLeadGain, score: score, clock: clock)
        if let strumDry {
            vDSP_vadd(lead.left, 1, strumDry.left, 1, &lead.left, 1, vDSP_Length(frames))
            vDSP_vadd(lead.right, 1, strumDry.right, 1, &lead.right, 1, vDSP_Length(frames))
        }
        let textureSend = textureVoices.shellSend
        textureVoices.shellSend = ([], [])
        let padSend = mids.padSend.left.isEmpty ? (left: quiet, right: quiet) : mids.padSend
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
        var spaceL = quiet, spaceR = quiet
        // Per-frame automation, fill accent and filter sweep, computed ahead of the effect loop.
        var spaceTrack = Self.automationTrack(automation.map(\.space), frames: frames, clock: clock)
        var sweepTrack = [Float](repeating: 0, count: frames)
        do {
            // 0.5 + 0.5 sin(position * rate + phase), position in beats.
            var start = filterPhase, step = Float(1 / clock.framesPerBeat) * filterRate, half: Float = 0.5
            var length = Int32(frames)
            vDSP_vramp(&start, &step, &sweepTrack, 1, vDSP_Length(frames))
            vvsinf(&sweepTrack, sweepTrack, &length)
            vDSP_vsmsa(sweepTrack, 1, &half, &half, &sweepTrack, 1, vDSP_Length(frames))
        }
        spaceTrack.withUnsafeMutableBufferPointer { space in
            sweepTrack.withUnsafeMutableBufferPointer { sweep in
                if let fill {
                    let start = max(0, n - clock.frame(at: fill.buildBeats)), end = min(frames, n + clock.frame(at: 0.75))
                    for frame in start..<end {
                        let accent = fill.accent(beatsFromBoundary: Double(frame) / clock.framesPerBeat - LofiClock.beats)
                        space[frame] += 0.25 * accent
                        sweep[frame] += accent * 0.35
                    }
                }
                var one: Float = 1
                vDSP_vclip(sweep.baseAddress!, 1, [-1], &one, sweep.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        // Raw pointers keep the per-sample effect loop fast in unoptimized builds; the arrays are not
        // resized while these are in use. The replay writes into `grains` once, between two runs.
        let sendL = leadSend.left, sendR = leadSend.right, texSendL = textureSend.left, texSendR = textureSend.right
        let padSendL = padSend.left, padSendR = padSend.right
        func run(_ range: Range<Int>) throws {
            guard !range.isEmpty else { return }
            let grainL = grains.left, grainR = grains.right
            try sendL.withUnsafeBufferPointer { sendL in
            try sendR.withUnsafeBufferPointer { sendR in
            try texSendL.withUnsafeBufferPointer { texSendL in
            try texSendR.withUnsafeBufferPointer { texSendR in
            try padSendL.withUnsafeBufferPointer { padSendL in
            try padSendR.withUnsafeBufferPointer { padSendR in
            try grainL.withUnsafeBufferPointer { grainL in
            try grainR.withUnsafeBufferPointer { grainR in
            try spaceTrack.withUnsafeBufferPointer { spaceTrack in
            try sweepTrack.withUnsafeBufferPointer { sweepTrack in
            try spaceL.withUnsafeMutableBufferPointer { outL in
            try spaceR.withUnsafeMutableBufferPointer { outR in
                let captureStart = captureWindow.lowerBound, captureEnd = captureWindow.upperBound
                let wetGain = Self.wetGain, capturing = !effectChannels.isEmpty
                // A `while` loop: `for in` over a range goes through the generic iterator in Debug builds.
                var frame = range.lowerBound
                while frame < range.upperBound {
                    defer { frame += 1 }
                    if frame & 8191 == 0 { try Task.checkCancellation() }
                    let space = spaceTrack[frame]
                    let returns = effects.processReturns(
                        lead: (sendGain * sendL[frame], sendGain * sendR[frame]),
                        texture: (texSendL[frame], texSendR[frame]),
                        pad: (padSendL[frame], padSendR[frame]),
                        grains: (sendGain * grainL[frame], sendGain * grainR[frame]),
                        space: space)
                    if capturing, frame < n {
                        effectChannels[0][0][frame] = returns.echo.left
                        effectChannels[0][1][frame] = returns.echo.right
                        effectChannels[1][0][frame] = returns.room.left
                        effectChannels[1][1][frame] = returns.room.right
                        effectChannels[2][0][frame] = returns.color.left
                        effectChannels[2][1][frame] = returns.color.right
                    }
                    let filtered = wetTone.process(returns.mix, sweep: sweepTrack[frame], space: space)
                    if frame >= captureStart, frame < captureEnd {
                        replay?.record(filtered, at: frame)
                    }
                    outL[frame] = wetGain * filtered.left
                    outR[frame] = wetGain * filtered.right
                }
            }}}}}}}}}}}}
        }
        let release = captureWindow.upperBound
        if replay != nil, release > 0, release <= frames {
            try run(0..<release)
            replay?.release(into: &grains)
            try run(release..<frames)
        } else {
            try run(0..<frames)
        }
        // Space: filtered once over phrase plus tail, so the carried tail is never filtered again,
        // then ducked under the dry lead. The duck applies to this phrase's frames (own and carried).
        addBassThrow(score: score, clock: clock, frames: frames, spaceLeft: &spaceL, spaceRight: &spaceR)
        let spaceStats = LofiStemChains.applySpace(left: &spaceL, right: &spaceR, sampleRate: sampleRate)
        let duck = Self.spaceDuck(lead: lead, gain: dryLeadGain, frames: n, sampleRate: sampleRate,
                                  onsets: Self.leadOnsets(score, clock: clock))
        guard let bassL = left.baseAddress, let bassR = right.baseAddress else { throw RenderError.buffer }

        // Stems of the phrase: edge envelope, hiss after the mids chain, duck on the space.
        var envelope = [Float](repeating: 1, count: n)
        for i in 0..<min(edge, n) {
            let e = min(1, Float(i) / Float(edge))
            envelope[i] = min(envelope[i], e)
            envelope[n - 1 - i] = min(envelope[n - 1 - i], e)
        }
        var hissTrack = Self.automationTrack(automation.map(\.dust), frames: n, clock: clock)
        var rng = MusicRNG(seed: seed).fork(12)
        var hiss: Float = 0
        hissTrack.withUnsafeMutableBufferPointer { track in
            var frame = 0
            while frame < n {
                hiss += 0.10 * (rng.rangeF(-1...1) - hiss)
                track[frame] *= hiss * 0.005
                frame += 1
            }
        }
        let count = vDSP_Length(n)
        var leadLevel = dryLeadGain, mixLevel: Float = 1, meter: Float = 1
        var spaceTrim = LofiStemChains.Space.standard.outputGain
        for channel in 0..<2 {
            let source = channel == 0 ? lead.left : lead.right
            let chords = channel == 0 ? mids.left : mids.right
            let space = channel == 0 ? spaceL : spaceR
            vDSP_vsmul(source, 1, &leadLevel, dryChannels[channel], 1, count)
            vDSP_vmul(dryChannels[channel], 1, envelope, 1, dryChannels[channel], 1, count)
            mixTexture(chords, level: &mixLevel, hiss: hissTrack, envelope: envelope, into: textureChannels[channel], count: count)
            vDSP_vmul(space, 1, duck.gain, 1, wetChannels[channel], 1, count)
            vDSP_vsmul(wetChannels[channel], 1, &spaceTrim, wetChannels[channel], 1, count)
        }
        // The balance meters the mids at their former level, so raising them never turns the
        // lead down with them; it then follows the tail.
        var balance = InstrumentBalance(sampleRate: sampleRate)
        var meteredL = [Float](repeating: 0, count: n), meteredR = meteredL
        vDSP_vsma(mids.meteredLeft, 1, &meter, dryChannels[0], 1, &meteredL, 1, count)
        vDSP_vadd(meteredL, 1, wetChannels[0], 1, &meteredL, 1, count)
        vDSP_vsma(mids.meteredRight, 1, &meter, dryChannels[1], 1, &meteredR, 1, count)
        vDSP_vadd(meteredR, 1, wetChannels[1], 1, &meteredR, 1, count)
        // The hook sits 3 to 10 dB under the melody (D128); metering it would let one stab turn the
        // whole phrase, melody included, down by up to 3 dB, so the balance meters the phrase without it.
        if let strumDry {
            var level = -dryLeadGain
            for channel in 0..<2 {
                var strings = [Float](repeating: 0, count: n)
                vDSP_vsmul(channel == 0 ? strumDry.left : strumDry.right, 1, &level, &strings, 1, count)
                vDSP_vmul(strings, 1, envelope, 1, &strings, 1, count)
                if channel == 0 { vDSP_vadd(meteredL, 1, strings, 1, &meteredL, 1, count) }
                else { vDSP_vadd(meteredR, 1, strings, 1, &meteredR, 1, count) }
            }
        }
        balance.observe(meteredL, meteredR)
        // Store pre-limit samples so an overlapping tail goes through the linked knee only once.
        // fade = min(1, (tailCount - 1 - i) / tailFade)
        var fade = [Float](repeating: 0, count: tailCount)
        for i in 0..<tailCount { fade[i] = Float(tailCount - 1 - i) / tailFade }
        var one: Float = 1, zero: Float = 0
        vDSP_vclip(fade, 1, &zero, &one, &fade, 1, vDSP_Length(tailCount))
        spaceL.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + n, 1, fade, 1, &tailL, 1, vDSP_Length(tailCount)) }
        spaceR.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + n, 1, fade, 1, &tailR, 1, vDSP_Length(tailCount)) }
        // The carried tail takes the space trim here, as this phrase's own space did above.
        vDSP_vsmul(tailL, 1, &spaceTrim, &tailL, 1, vDSP_Length(tailCount))
        vDSP_vsmul(tailR, 1, &spaceTrim, &tailR, 1, vDSP_Length(tailCount))
        balance.observe(tailL, tailR)
        var bassStats = finishBass(left: left, right: right, frames: n, sampleRate: sampleRate, envelope: envelope,
                                   drums: drums, drumOffset: drumOffset,
                                   anchoredKicks: score.bassAnchors.map { drumOffset + clock.frame(at: $0.kickBeat) },
                                   kickDuck: &kickDuck, settings: tuning.bass)
        // The program's loudness-match trim (D114) follows the balance, which only turns phrases down:
        // a plucked program held under the 400 ms and peak ceilings can still come up to the grand.
        let programTrim = powf(10, score.preset.levelDB / 20)
        let trim = balance.gain * programTrim
        reportBass(score, clock: clock, phrase: phrase, bass: UnsafePointer(bassL))
        reportMusicLevels(score, phrase: phrase,
               levels: ["leadGain": dryLeadGain, "sendGain": sendGain, "midsGain": mids.shellGain, "padGain": mids.padGain,
                        "padDuckMeanDb": mids.padDuckMeanDB, "balanceTrim": balance.gain,
                        "programTrim": programTrim])
        if LofiCaptureHooks.isEnabled {
            var space = spaceStats
            space.grMeanDb = duck.meanDB
            space.grMaxDb = duck.maxDB
            for (stats, bus) in [(bassStats, "bass"), (leadStats, "dry"), (mids.stats, "texture"), (space, "wet")] {
                LofiStemChains.report(stats, bus: bus, phrase: phrase)
            }
        }
        let reveal = score.section == .returnTheme
        let hold = returnRevealHold(score, clock: clock)
        var level = trim
        for channel in 0..<2 {
            vDSP_vsmul(dryChannels[channel], 1, &level, dryChannels[channel], 1, count)
            vDSP_vsmul(textureChannels[channel], 1, &level, textureChannels[channel], 1, count)
        }
        // The carried tail on this phrase's clock (resampled only across a tempo change).
        var carryL = [Float](repeating: 0, count: n), carryR = carryL
        if let carry {
            if carry.clock.sampleRate == clock.sampleRate {
                let count = min(n, carry.left.count)
                carryL.replaceSubrange(0..<count, with: carry.left[0..<count])
                carryR.replaceSubrange(0..<count, with: carry.right[0..<count])
            } else {
                for frame in 0..<n {
                    let previous = carry.sample(frame, at: clock)
                    carryL[frame] = previous.left
                    carryR[frame] = previous.right
                }
            }
        }
        duck.gain.withUnsafeBufferPointer { ducked in
            carryL.withUnsafeBufferPointer { carryL in
                carryR.withUnsafeBufferPointer { carryR in
                    let wetL = wetChannels[0], wetR = wetChannels[1]
                    var frame = 0
                    while frame < n {
                        let revealed = reveal ? Self.returnCarryGain(beat: Double(frame) / clock.framesPerBeat, hold: hold) : 1
                        let wet = boundedWet((revealed * (wetL[frame] * trim + ducked[frame] * carryL[frame]),
                                              revealed * (wetR[frame] * trim + ducked[frame] * carryR[frame])))
                        wetL[frame] = wet.left
                        wetR[frame] = wet.right
                        frame += 1
                    }
                }
            }
        }
        vDSP_vsmul(tailL, 1, &level, &tailL, 1, vDSP_Length(tailCount))
        vDSP_vsmul(tailR, 1, &level, &tailR, 1, vDSP_Length(tailCount))
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
                      tail: Tail(clock: clock, left: tailL, right: tailR), effectReturns: effectReturns,
                      leadGain: dryLeadGain, instrumentTrim: trim)
    }

    /// A per-beat automation value interpolated linearly to every frame (the value at beat `b`
    /// is `values[b]`), one vector ramp per beat.
    static func automationTrack(_ values: [Float], frames: Int, clock: LofiClock) -> [Float] {
        var track = [Float](repeating: 0, count: frames)
        let fpb = clock.framesPerBeat
        track.withUnsafeMutableBufferPointer { out in
            var beat = 0
            while beat + 1 < values.count {
                let start = min(frames, Int((Double(beat) * fpb).rounded(.up)))
                let end = min(frames, Int((Double(beat + 1) * fpb).rounded(.up)))
                if start >= frames { break }
                if end > start {
                    var u0 = Float(Double(start) / fpb - Double(beat)), step = Float(1 / fpb)
                    vDSP_vramp(&u0, &step, out.baseAddress! + start, 1, vDSP_Length(end - start))
                    var slope = values[beat + 1] - values[beat], base = values[beat]
                    vDSP_vsmsa(out.baseAddress! + start, 1, &slope, &base, out.baseAddress! + start, 1, vDSP_Length(end - start))
                }
                beat += 1
            }
        }
        return track
    }

    /// The space duck of a phrase (`LofiStemChains.spaceDuck`) keyed by its dry lead at `gain`.
    /// Scale invariant, so the dry stem itself reproduces it.
    /// Phrase-local start frames of the scored lead notes: the onsets that key the space duck.
    /// Send level of a `.strum` note: `velocity * (strumSendFloor + strumSendScale * send)`. A plain
    /// stab (send 0.10) sends 0.065, a thrown one (0.90) 0.329, 14 dB more (D128: the thrown stab's
    /// first echo 6-12 dB under the stab, a plain stab's at least 18 dB under). Lead and ornament notes
    /// keep `0.44 + 0.72 * send`.
    static let strumSendFloor: Float = 0.032
    static let strumSendScale: Float = 0.33

    /// One string of a strum at `velocity`, with its damp and colour and no extra gain.
    private static func strumString(_ note: LofiScore.Note, velocity: Float) -> LofiScore.Note {
        var string = LofiScore.Note(part: .strum, midi: note.midi, beat: note.beat, length: note.length,
                                    velocity: velocity, color: note.color, send: note.send)
        string.damp = note.damp
        return string
    }

    /// Melody onsets only: the strummed hook and the ornaments never key the space duck's onsets.
    static func leadOnsets(_ score: LofiScore, clock: LofiClock) -> [Int] {
        score.notes.filter { $0.part == .lead }.map { clock.frame(at: $0.beat) }
    }

    static func spaceDuck(lead: (left: [Float], right: [Float]), gain: Float, frames n: Int,
                          sampleRate: Double, onsets: [Int]? = nil) -> (gain: [Float], meanDB: Float, maxDB: Float) {
        var l = Array(lead.left.prefix(n)), r = Array(lead.right.prefix(n))
        var g = gain
        vDSP_vsmul(l, 1, &g, &l, 1, vDSP_Length(l.count))
        vDSP_vsmul(r, 1, &g, &r, 1, vDSP_Length(r.count))
        return l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                LofiStemChains.spaceDuck(leadLeft: lp.baseAddress!, leadRight: rp.baseAddress!, count: min(lp.count, rp.count),
                                         sampleRate: sampleRate, onsets: onsets)
            }
        }
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
            var l: Float = 0, r: Float = 0, pl: Float = 0, pr: Float = 0
            let length = vDSP_Length(end - start)
            lead.left.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &l, length) }
            lead.right.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &r, length) }
            lead.left.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + start, 1, &pl, length) }
            lead.right.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + start, 1, &pr, length) }
            let power = 0.5 * (l + r)
            peak = max(peak, pl, pr)
            strongest = max(strongest, power / Float(end - start))
        }
        guard peak > 0.0001 else { return 1 }
        let bodyGain = 0.155 / max(0.018, sqrtf(strongest))
        return min(4.4, 0.43 / peak, bodyGain)
    }

    static func addInstrument(_ note: LofiScore.Note, sample: LofiSampleBank.Sample?, score: LofiScore,
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
            if count == blockFrames { flush() }
        }

        /// Block form of `observe`, vectorized per 50 ms block.
        mutating func observe(_ left: [Float], _ right: [Float]) {
            let total = min(left.count, right.count)
            left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    guard let l = l.baseAddress, let r = r.baseAddress else { return }
                    var i = 0
                    while i < total {
                        let take = min(blockFrames - count, total - i)
                        var pl: Float = 0, pr: Float = 0, ml: Float = 0, mr: Float = 0
                        vDSP_svesq(l + i, 1, &pl, vDSP_Length(take))
                        vDSP_svesq(r + i, 1, &pr, vDSP_Length(take))
                        vDSP_maxmgv(l + i, 1, &ml, vDSP_Length(take))
                        vDSP_maxmgv(r + i, 1, &mr, vDSP_Length(take))
                        peak = max(peak, ml, mr)
                        power += Double(pl + pr) * 0.5
                        count += take
                        i += take
                        if count == blockFrames { flush() }
                    }
                }
            }
        }

        private mutating func flush() {
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

    @_transparent
    static func boundedWet(_ signal: LofiEffects.Stereo) -> LofiEffects.Stereo {
        let peak = max(abs(signal.left), abs(signal.right))
        guard peak > 0.25 else { return signal }
        let gain = (0.25 + 0.13 * tanhf((peak - 0.25) / 0.13)) / peak
        return (signal.left * gain, signal.right * gain)
    }

    @_transparent
    static func headroom(_ sample: Float) -> Float {
        let level = abs(sample)
        guard level > 0.74 else { return sample }
        let limited = 0.74 + 0.099 * tanhf((level - 0.74) / 0.099)
        return sample < 0 ? -limited : limited
    }

}

