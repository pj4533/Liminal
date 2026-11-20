import Accelerate
import Foundation

nonisolated extension LofiRenderer {
    /// The chord channel's dry voices and sends of one phrase, each phrase plus tail long: the two answer
    /// shell voices (played by the lead's sample), the held pad (`LofiPadVoice`), and their sends.
    struct TextureVoices {
        var lower: (left: [Float], right: [Float])
        var upper: (left: [Float], right: [Float])
        var pad: (left: [Float], right: [Float])
        var shellSend: (left: [Float], right: [Float])
        var padSend: (left: [Float], right: [Float])
        var padVoices = 0

        init(frames: Int) {
            let quiet = [Float](repeating: 0, count: frames)
            lower = (quiet, quiet)
            upper = (quiet, quiet)
            pad = (quiet, quiet)
            shellSend = (quiet, quiet)
            padSend = (quiet, quiet)
        }
    }

    /// The finished chord channel of one phrase before the instrument balance: the dry texture at its
    /// phrase level (shells plus the ducked pad), what the balance meters, and the pad's prepared send.
    struct TextureMix {
        var left: [Float]
        var right: [Float]
        var meteredLeft: [Float]
        var meteredRight: [Float]
        var padSend: (left: [Float], right: [Float])
        var shellGain: Float
        var padGain: Float
        var padDuckMeanDB: Float
        var stats: LofiStemChains.Stats
    }

    /// A chord-channel note. A shell renders with the lead's sample into its lower or upper voice and its
    /// send; a pad note renders through `LofiPadVoice` into the pad and its send (the dry pad scaled by
    /// `note.send`, not a second render).
    static func addTexture(_ note: LofiScore.Note, send: LofiScore.Note, sample: LofiSampleBank.Sample?,
                           samples: LofiSampleBank, score: LofiScore, clock: LofiClock, isUpper: Bool,
                           into voices: inout TextureVoices) {
        if note.articulation == .pad {
            voices.padVoices += 1
            let source = padSample(samples, preset: score.preset, midi: note.midi)
            let settings = LofiPadVoice.Settings.standard
            let entering = score.section == .returnTheme && note.beat < LofiScore.padRevoiceBeat - 1
            var hash = UInt64(truncatingIfNeeded: note.midi) &* 0x9E37_79B9_7F4A_7C15
            hash ^= UInt64(truncatingIfNeeded: Int((note.beat * 64).rounded())) &* 0xBF58_476D_1CE4_E5B9
            hash ^= UInt64(truncatingIfNeeded: score.tonic * 97 + score.section.rawValue) &* 0x94D0_49BB_1331_11EB
            LofiPadVoice.add(note, sample: source, preset: score.preset, clock: clock,
                             attack: entering ? settings.returnAttack : settings.attack, voice: voices.padVoices,
                             seed: hash, limit: clock.frameCount, settings: settings,
                             into: &voices.pad, send: &voices.padSend)
            return
        }
        let dryNote = LofiScore.Note(part: .texture, midi: note.midi, beat: note.beat, length: note.length,
                                     velocity: note.velocity * note.gain, color: note.color)
        if isUpper {
            addInstrument(dryNote, sample: sample, score: score, clock: clock, into: &voices.upper)
        } else {
            addInstrument(dryNote, sample: sample, score: score, clock: clock, into: &voices.lower)
        }
        addInstrument(send, sample: sample, score: score, clock: clock, into: &voices.shellSend)
    }

    /// The pad's source: the program's sample nearest the pitch (layer 2) that is long enough to lend a
    /// body (1.2 s); a short pizzicato note gives way to the nearest longer one, up to an octave away.
    static func padSample(_ samples: LofiSampleBank, preset: LofiPreset, midi: Int) -> LofiSampleBank.Sample? {
        let nearest = samples.sample(for: preset, midi: midi, velocity: 0.5)
        for offset in [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8, 8, -9, 9, -10, 10, -11, 11, -12, 12] {
            if let sample = samples.sample(for: preset, midi: midi + offset, velocity: 0.5),
               Double(sample.pcm.count) >= 1.2 * sample.rate { return sample }
        }
        return nearest
    }

    /// The texture stem: the mids at the phrase level plus the hiss, under the edge envelope.
    static func mixTexture(_ mids: [Float], level: inout Float, hiss: [Float], envelope: [Float],
                           into out: UnsafeMutablePointer<Float>, count: vDSP_Length) {
        vDSP_vsma(mids, 1, &level, hiss, 1, out, 1, count)
        vDSP_vmul(out, 1, envelope, 1, out, 1, count)
    }

    // MARK: Shell levels

    /// Nominal dry level of the sampled mid shells on the texture stem (the fixed trim was 0.31).
    /// Used when a phrase has too little lead and mid overlap to measure (`midsLevel`).
    /// Raised from 2.2 with the mids chain (plan 8.4), which takes about 2.7 dB off the shells
    /// (high-pass 160 Hz, -3 dB at 400 Hz): the nominal level is the same as before the chain.
    /// Mix calibration raised it from 3.0 (+1.6 dB): a breakdown's soft answer, the one phrase that keeps
    /// it, read 9 dB under the lead in the reference capture.
    static let midsTrim: Float = 3.6
    /// Where lead and shells sound together, the shells sit this far under the lead in 400 Hz to 3 kHz
    /// (M13 asks for 3 to 8 dB). Chosen by measurement on the reference captures.
    /// 5.5 read 6.1 to 8.2 dB on the matrix (long above 8; the bus ducks under featured chops take the
    /// mids 1 dB further down than the lead, and loud lead notes over decaying shells dominate the measure), so mix calibration set 3.5.
    /// 4.0 with the held pad (D117; plan range 3.5 to 4.5): the shell now answers over the pad.
    static let midsUnderLeadDB: Float = 4.0
    /// Shortest lead and mid overlap in a phrase that sets the matched level. 0.25 s left every phrase of
    /// the short-overlap first take at `midsTrim`, about 1 dB under the lead (mix calibration).
    static let midsMatchSeconds = 0.1
    /// The per-phrase mids gain stays within this factor of `midsTrim` either way.
    static let midsGainRange: Float = 2.5
    /// Plucked attacks never push the dry mids above -4.4 dBFS before the instrument balance. Mix
    /// calibration tried 1.0: C-B5 held, but plucked shells then peaked at 0 dBFS on the texture stem and
    /// the pre-master peak rose 2 dB, so the ceiling stayed.
    static let midsPeakCeiling: Float = 0.6
    /// The shells' contribution to `InstrumentBalance`, at the former 0.31 trim.
    static let midsMeterTrim: Float = 0.31

    // MARK: Pad levels (D117)

    /// Where lead and pad sound together, the ducked pad (with any shell) sits this far under the lead in
    /// 400 Hz to 3 kHz on the steep meter (C-B5 gate 5.0 to 7.5 dB). Plan start 6.5: the chords stem read
    /// -21.9 LUFS (gate -22 to -24); PADS chose 6.6 (C-B5 7.21 dB, -22.3 LUFS). With the bass merged the
    /// chords' whole-file 300 to 800 Hz stayed over its +2 dB gate, so the mix rebalance (D118) set 6.85
    /// and then 7.0: C-B5 7.47 dB, chords -23.6 LUFS, 300 to 800 Hz +1.75 dB (20 November 2026).
    static let padUnderLeadDB: Float = 7.0
    /// Nominal pad gain when a phrase has too little overlap to measure, and the factor it may move.
    static let padTrim: Float = 2.0
    static let padGainRange: Float = 8.0
    /// The held pad never peaks above -9 dBFS on the dry texture before the instrument balance.
    static let padPeakCeiling: Float = 0.35
    /// The pad's contribution to `InstrumentBalance`. The dry pad at this weight barely moves the balance;
    /// what does is the pad's reverb in the wet stem, which the balance meters in full: on the reference
    /// capture the two theme phrases come down 0.5 and 0.85 dB (plan gate 0.2; with the pad send off they
    /// move 0.06 and 0.22 dB). Open issue for MIX (D117).
    static let padMeterTrim: Float = 0.1
    /// The pad send's level at the phrase's pad gain, its band (280 Hz to 4 kHz) and pre-delay (45 ms).
    static let padSendTrim: Float = 0.37
    static let padSendBand = (low: 280.0, high: 4_000.0)
    /// The wet tone (`LofiWetTone`) keeps the space dark: above its 1.65 kHz crossover the return reads about
    /// 10 dB down. A brighter pad would bloom less in 400 Hz to 3 kHz than a darker one at the same send,
    /// so the send is lifted by the share of the dry pad's band that lies above the crossover.
    static let padSendAirShare = 0.1

    static func padSendTilt(_ pad: (left: [Float], right: [Float]), sampleRate: Double) -> Float {
        let q = LofiStemChains.butterworthQ
        // Four seconds from the middle of the phrase stand for the held chord.
        let span = min(pad.left.count, Int(4 * sampleRate)), from = max(0, (pad.left.count - span) / 2)
        func power(_ kinds: [LofiBiquad.Kind]) -> Double {
            var l = Array(pad.left[from..<(from + span)]), r = Array(pad.right[from..<(from + span)])
            var chain = LofiFilterChain(kinds, sampleRate: sampleRate)
            chain.process(left: &l, right: &r)
            var a: Float = 0, b: Float = 0
            vDSP_measqv(l, 1, &a, vDSP_Length(l.count))
            vDSP_measqv(r, 1, &b, vDSP_Length(r.count))
            return Double(a + b)
        }
        let low = power([.highpass(hz: 400, q: q), .highpass(hz: 400, q: q), .lowpass(hz: 1_650, q: q), .lowpass(hz: 1_650, q: q)])
        let high = power([.highpass(hz: 1_650, q: q), .highpass(hz: 1_650, q: q), .lowpass(hz: 3_000, q: q), .lowpass(hz: 3_000, q: q)])
        guard low + high > 1e-20 else { return 1 }
        return Float(((low + high) / (low + padSendAirShare * high)).squareRoot())
    }
    static let padSendDelay = 0.045
    static let padSendSway = (seconds: 0.003, hz: 0.4)
    /// Under the lead the dry pad dips 2 dB (attack 20 ms, hold 30 ms, release 300 ms): the space duck's
    /// follower with its own settings, at full depth while the lead sounds (no onset share).
    static let padDuck: LofiStemChains.Space = {
        var duck = LofiStemChains.Space()
        duck.duckDepthDB = 2
        duck.duckAttack = 0.020
        duck.duckHold = 0.030
        duck.duckRelease = 0.300
        duck.duckSustainShare = 1
        return duck
    }()

    /// Indices of the upper note of each two-note mid shell: a texture note whose partner (same
    /// articulation, lower pitch) starts at the same beat or up to the roll's stagger before it. Pad
    /// notes are never shell voices.
    static func upperShellVoices(_ score: LofiScore) -> Set<Int> {
        let mids = score.notes.indices.filter { score.notes[$0].part == .texture && score.notes[$0].articulation != .pad }
        return Set(mids.filter { i in
            let note = score.notes[i]
            return mids.contains { j in
                let other = score.notes[j]
                return j != i && other.articulation == note.articulation && other.midi < note.midi
                    && other.beat <= note.beat + 1e-9 && other.beat >= note.beat - 0.18
            }
        })
    }

    /// Chains, ducks and levels the chord channel of one phrase (D117), releasing the voice arrays:
    /// - shells: `applyMids`, then one gain per phrase `midsUnderLeadDB` under the lead (`midsLevel`);
    /// - pad: `applyPad`, the 2 dB lead-keyed duck, then one gain per phrase `padUnderLeadDB` under the
    ///   lead, metered after the duck where both sound, and `padPeakCeiling`;
    /// - pad send: the dry pad's send at the pad's phrase gain, band-limited and pre-delayed.
    static func finishTexture(_ voices: inout TextureVoices, lead: (left: [Float], right: [Float]), leadGain: Float,
                              score: LofiScore, clock: LofiClock) -> TextureMix {
        let rate = clock.sampleRate
        let n = clock.frameCount
        let shells = LofiStemChains.applyMids(lower: voices.lower, upper: voices.upper, sampleRate: rate)
        voices.lower = ([], [])
        voices.upper = ([], [])
        var pad = (left: Array(voices.pad.left.prefix(n)), right: Array(voices.pad.right.prefix(n)))
        voices.pad = ([], [])
        let padStats = LofiStemChains.applyPad(left: &pad.left, right: &pad.right, sampleRate: rate)
        let shellNotes = score.notes.filter { $0.part == .texture && $0.articulation != .pad }
        let padNotes = score.notes.filter { $0.part == .texture && $0.articulation == .pad }
        let shellGain = shellNotes.isEmpty ? midsTrim
            : matchedLevel(lead: lead, leadGain: leadGain, part: (shells.left, shells.right),
                           notes: shellNotes, score: score, clock: clock, underDB: midsUnderLeadDB,
                           trim: midsTrim, range: midsGainRange, ceiling: midsPeakCeiling)
        // The duck is scale invariant, so the dry lead before its gain keys it.
        var duckMean: Float = 0
        var send = voices.padSend
        voices.padSend = ([], [])
        if !padNotes.isEmpty {
            let duck = lead.left.withUnsafeBufferPointer { l in
                lead.right.withUnsafeBufferPointer { r in
                    LofiStemChains.spaceDuck(leadLeft: l.baseAddress!, leadRight: r.baseAddress!, count: n,
                                             sampleRate: rate, settings: padDuck)
                }
            }
            duckMean = duck.meanDB
            vDSP_vmul(pad.left, 1, duck.gain, 1, &pad.left, 1, vDSP_Length(n))
            vDSP_vmul(pad.right, 1, duck.gain, 1, &pad.right, 1, vDSP_Length(n))
            // The send is the dry pad, so it takes the same duck (the pad ends before the phrase edge).
            vDSP_vmul(send.left, 1, duck.gain, 1, &send.left, 1, vDSP_Length(n))
            vDSP_vmul(send.right, 1, duck.gain, 1, &send.right, 1, vDSP_Length(n))
        }
        let padGain = padNotes.isEmpty ? 0
            : matchedLevel(lead: lead, leadGain: leadGain, part: pad, notes: padNotes, score: score, clock: clock,
                           underDB: padUnderLeadDB, trim: padTrim, range: padGainRange, ceiling: padPeakCeiling,
                           alongside: shellNotes.isEmpty ? nil : (shells.left, shells.right, shellGain), steep: true)
        var left = [Float](repeating: 0, count: n), right = left
        var meteredLeft = left, meteredRight = left
        var gains = (shellGain, padGain, midsMeterTrim, padMeterTrim)
        let count = vDSP_Length(n)
        vDSP_vsmsma(shells.left, 1, &gains.0, pad.left, 1, &gains.1, &left, 1, count)
        vDSP_vsmsma(shells.right, 1, &gains.0, pad.right, 1, &gains.1, &right, 1, count)
        vDSP_vsmsma(shells.left, 1, &gains.2, pad.left, 1, &gains.3, &meteredLeft, 1, count)
        vDSP_vsmsma(shells.right, 1, &gains.2, pad.right, 1, &gains.3, &meteredRight, 1, count)
        // The pad send follows the pad's phrase level, band-limited and 45 ms late. The pre-delay sways by
        // `padSendSway` (sides in opposite phase), a slow chorus that walks the held partials across the
        // rack's sparse room modes, so a chord's bloom depends less on where its pitches fall.
        if !padNotes.isEmpty {
            let frames = send.left.count
            let level = padGain * padSendTrim * padSendTilt(pad, sampleRate: rate)
            var band = LofiFilterChain([.highpass(hz: padSendBand.low, q: LofiStemChains.butterworthQ),
                                        .lowpass(hz: padSendBand.high, q: LofiStemChains.butterworthQ)], sampleRate: rate)
            band.process(left: &send.left, right: &send.right)
            let centre = padSendDelay * rate, depth = padSendSway.seconds * rate
            let omega = 2 * Double.pi * padSendSway.hz / rate
            for channel in 0..<2 {
                // Read position i - centre - depth sin(omega i + phase), linear interpolation (vector form).
                var positions = [Float](repeating: 0, count: frames), sway = positions
                var phase = Float(channel == 0 ? 0 : Double.pi), step = Float(omega), length = Int32(frames)
                vDSP_vramp(&phase, &step, &sway, 1, vDSP_Length(frames))
                vvsinf(&sway, sway, &length)
                var first = Float(-centre), one: Float = 1, negativeDepth = Float(-depth)
                vDSP_vramp(&first, &one, &positions, 1, vDSP_Length(frames))
                vDSP_vsma(sway, 1, &negativeDepth, positions, 1, &positions, 1, vDSP_Length(frames))
                var low: Float = 0, high = Float(frames - 2)
                vDSP_vclip(positions, 1, &low, &high, &positions, 1, vDSP_Length(frames))
                var delayed = [Float](repeating: 0, count: frames)
                let source = channel == 0 ? send.left : send.right
                vDSP_vlint(source, positions, 1, &delayed, 1, vDSP_Length(frames), vDSP_Length(frames))
                var scale = level
                vDSP_vsmul(delayed, 1, &scale, &delayed, 1, vDSP_Length(frames))
                if channel == 0 { send.left = delayed } else { send.right = delayed }
            }
        } else {
            send = ([], [])
        }
        var stats = shells.stats
        var sumLeft = [Float](repeating: 0, count: n), sumRight = sumLeft
        vDSP_vadd(shells.left, 1, pad.left, 1, &sumLeft, 1, count)
        vDSP_vadd(shells.right, 1, pad.right, 1, &sumRight, 1, count)
        (stats.inPeakDb, stats.inRmsDb) = LofiStemChains.level(sumLeft, sumRight)
        (stats.outPeakDb, stats.outRmsDb) = LofiStemChains.level(left, right)
        stats.extra["padOutRmsDb"] = padStats.outRmsDb
        stats.extra["padDuckMeanDb"] = duckMean
        stats.extra["padGainDb"] = padGain > 0 ? 20 * log10f(padGain) : -120
        return TextureMix(left: left, right: right, meteredLeft: meteredLeft, meteredRight: meteredRight,
                          padSend: send, shellGain: shellGain, padGain: padGain, padDuckMeanDB: duckMean,
                          stats: stats)
    }

    /// One shell gain per phrase (`midsUnderLeadDB` under the lead where both sound).
    static func midsLevel(lead: (left: [Float], right: [Float]), leadGain: Float,
                          texture: (left: [Float], right: [Float]), score: LofiScore,
                          clock: LofiClock) -> Float {
        matchedLevel(lead: lead, leadGain: leadGain, part: texture,
                     notes: score.notes.filter { $0.part == .texture && $0.articulation != .pad },
                     score: score, clock: clock, underDB: midsUnderLeadDB, trim: midsTrim,
                     range: midsGainRange, ceiling: midsPeakCeiling)
    }

    /// One gain per phrase for a chord-channel part: meter the dry lead (after its gain) and the part in
    /// 400 Hz to 3 kHz where the score has both sounding (`notes` for the part), and set the part `underDB`
    /// under the lead, within `range` of `trim` either way, its peak at most `ceiling`. Every program and
    /// arrangement then keeps the same relation; the part never rides per note.
    static func matchedLevel(lead: (left: [Float], right: [Float]), leadGain: Float,
                             part: (left: [Float], right: [Float]), notes: [LofiScore.Note], score: LofiScore,
                             clock: LofiClock, underDB: Float, trim: Float, range: Float, ceiling: Float,
                             alongside: (left: [Float], right: [Float], gain: Float)? = nil,
                             steep: Bool = false) -> Float {
        // Breakdowns are matched too (19 November 2026): with the darker acoustic and guitar programs a
        // breakdown's shells at the nominal level sat over the lead (C-B5 lead minus mids read -1.6 dB).
        let n = clock.frameCount
        var leadOn = [Bool](repeating: false, count: n), midOn = leadOn
        func mark(_ note: LofiScore.Note, _ mask: inout [Bool]) {
            let range = max(0, clock.frame(at: note.beat))..<min(n, clock.frame(at: note.beat + note.length))
            guard !range.isEmpty else { return }
            mask.withUnsafeMutableBufferPointer { $0[range].update(repeating: true) }
        }
        for note in score.notes where note.part.playsLead { mark(note, &leadOn) }
        for note in notes { mark(note, &midOn) }
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
        var leadMeter = Meter(), midMeter = Meter(), otherMeter = Meter()
        var leadPower: Double = 0, midPower: Double = 0, otherPower: Double = 0
        var count = 0
        let frames = min(n, part.left.count, part.right.count)
        var peakL: Float = 0, peakR: Float = 0
        vDSP_maxmgv(part.left, 1, &peakL, vDSP_Length(frames))
        vDSP_maxmgv(part.right, 1, &peakR, vDSP_Length(frames))
        let peak = max(peakL, peakR)
        var leadMono = [Float](repeating: 0, count: n), midMono = leadMono
        var half: Float = 0.5
        vDSP_vasm(lead.left, 1, lead.right, 1, &half, &leadMono, 1, vDSP_Length(n))
        vDSP_vasm(part.left, 1, part.right, 1, &half, &midMono, 1, vDSP_Length(frames))
        var otherMono = [Float](repeating: 0, count: n), otherGain: Float = 0
        if let alongside {
            var scale = 0.5 * alongside.gain
            otherGain = alongside.gain
            let length = vDSP_Length(min(n, alongside.left.count, alongside.right.count))
            vDSP_vasm(alongside.left, 1, alongside.right, 1, &scale, &otherMono, 1, length)
        }
        if steep {
            var mask = [Float](repeating: 0, count: n)
            var one: Float = 1
            for note in notes {
                let a = max(0, clock.frame(at: note.beat)), b = min(n, clock.frame(at: note.beat + note.length))
                guard b > a else { continue }
                mask.withUnsafeMutableBufferPointer { vDSP_vfill(&one, $0.baseAddress! + a, 1, vDSP_Length(b - a)) }
            }
            var leadMask = [Float](repeating: 0, count: n)
            for note in score.notes where note.part.playsLead {
                let a = max(0, clock.frame(at: note.beat)), b = min(n, clock.frame(at: note.beat + note.length))
                guard b > a else { continue }
                leadMask.withUnsafeMutableBufferPointer { vDSP_vfill(&one, $0.baseAddress! + a, 1, vDSP_Length(b - a)) }
            }
            vDSP_vmul(mask, 1, leadMask, 1, &mask, 1, vDSP_Length(n))
            (leadPower, midPower, otherPower, count) = steepPowers(lead: lead, leadGain: leadGain, part: part,
                                                                   alongside: alongside, mask: mask,
                                                                   sampleRate: clock.sampleRate)
        } else {
        leadMono.withUnsafeBufferPointer { leadMono in
            midMono.withUnsafeBufferPointer { midMono in
            otherMono.withUnsafeBufferPointer { otherMono in
            leadOn.withUnsafeBufferPointer { leadOn in
            midOn.withUnsafeBufferPointer { midOn in
                var frame = -1
                while frame + 1 < n {
                    frame += 1
                    let l = leadMeter.band(leadMono[frame], high: high, low: low) * leadGain
                    let m = midMeter.band(midMono[frame], high: high, low: low)
                    let o = otherGain == 0 ? 0 : otherMeter.band(otherMono[frame], high: high, low: low)
                    guard leadOn[frame], midOn[frame] else { continue }
                    leadPower += Double(l * l)
                    midPower += Double(m * m)
                    otherPower += Double(o * o)
                    count += 1
                }
            }}}
            }
        }
        }
        var gain = trim
        if count >= Int(midsMatchSeconds * clock.sampleRate), midPower > 1e-14, leadPower > 1e-14 {
            // With a part already in the stem (`alongside`, at its gain), this part fills what is left of
            // the target so the two together sit `underDB` under the lead.
            let target = leadPower * pow(10, -Double(underDB) / 10)
            let matched = Float(sqrt(max(target * 0.05, target - otherPower) / midPower))
            gain = min(trim * range, max(trim / range, matched))
        }
        // Plucked programs meter quietly over a held part; never let their attacks overshoot.
        return peak > 0 ? min(gain, ceiling / peak) : gain
    }

    /// The steep meter of `matchedLevel` (the pad's): stereo power, (L^2 + R^2) / 2 as the analysis
    /// measures it, through two Butterworth sections each side of 400 Hz to 3 kHz, where both masks are set.
    /// The pad's fundamentals under 400 Hz leak through the one-pole meter, and its sides differ.
    private static func steepPowers(lead: (left: [Float], right: [Float]), leadGain: Float,
                                    part: (left: [Float], right: [Float]),
                                    alongside: (left: [Float], right: [Float], gain: Float)?,
                                    mask: [Float],
                                    sampleRate: Double) -> (Double, Double, Double, Int) {
        let n = mask.count
        let q = LofiStemChains.butterworthQ
        func banded(_ x: (left: [Float], right: [Float]), _ gain: Float) -> [Float] {
            var l = Array(x.left.prefix(n)), r = Array(x.right.prefix(n))
            if l.count < n { l += [Float](repeating: 0, count: n - l.count) }
            if r.count < n { r += [Float](repeating: 0, count: n - r.count) }
            var chain = LofiFilterChain([.highpass(hz: 400, q: q), .highpass(hz: 400, q: q),
                                         .lowpass(hz: 3_000, q: q), .lowpass(hz: 3_000, q: q)], sampleRate: sampleRate)
            chain.process(left: &l, right: &r)
            var power = [Float](repeating: 0, count: n)
            var scale = 0.5 * gain * gain
            vDSP_vmul(l, 1, l, 1, &l, 1, vDSP_Length(n))
            vDSP_vmul(r, 1, r, 1, &r, 1, vDSP_Length(n))
            vDSP_vadd(l, 1, r, 1, &power, 1, vDSP_Length(n))
            vDSP_vsmul(power, 1, &scale, &power, 1, vDSP_Length(n))
            return power
        }
        let leadPower = banded(lead, leadGain), partPower = banded(part, 1)
        let otherPower = alongside.map { banded(($0.left, $0.right), $0.gain) }
        var frames: Float = 0
        vDSP_sve(mask, 1, &frames, vDSP_Length(n))
        let count = Int(frames.rounded())
        func total(_ x: [Float]) -> Double {
            var sum: Float = 0
            vDSP_dotpr(x, 1, mask, 1, &sum, vDSP_Length(n))
            return Double(sum)
        }
        return (total(leadPower), total(partPower), otherPower.map(total) ?? 0, count)
    }

    /// Per-phrase gains of the instrument stems, for the stem-chain and balance work.
    static func reportMusicLevels(_ score: LofiScore, phrase: Int, levels: [String: Float]) {
        guard LofiCaptureHooks.isEnabled else { return }
        let mids = score.notes.filter { $0.part == .texture }
        var entry: [String: Any] = levels.mapValues { Double($0) }
        entry["phrase"] = phrase
        entry["section"] = String(describing: score.section)
        entry["program"] = score.preset.name
        entry["midEvents"] = mids.filter { $0.articulation != .pad }.count / 2
        entry["padVoices"] = mids.filter { $0.articulation == .pad }.count
        entry["midArticulations"] = mids.map { String(describing: $0.articulation) }
        LofiCaptureHooks.appendReport("musicLevels", entry)
    }
}
