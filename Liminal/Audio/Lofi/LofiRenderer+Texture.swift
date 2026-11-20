import Accelerate
import Foundation

nonisolated extension LofiRenderer {
    /// A mid-shell note: the dry voice into its lower or upper stem, and its send.
    static func addTexture(_ note: LofiScore.Note, send: LofiScore.Note, sample: LofiSampleBank.Sample?,
                           score: LofiScore, clock: LofiClock, isUpper: Bool,
                           lower: inout (left: [Float], right: [Float]), upper: inout (left: [Float], right: [Float]),
                           sendStem: inout (left: [Float], right: [Float])) {
        let dryNote = LofiScore.Note(part: .texture, midi: note.midi, beat: note.beat, length: note.length,
                                     velocity: note.velocity * note.gain, color: note.color)
        if isUpper {
            addInstrument(dryNote, sample: sample, score: score, clock: clock, into: &upper)
        } else {
            addInstrument(dryNote, sample: sample, score: score, clock: clock, into: &lower)
        }
        addInstrument(send, sample: sample, score: score, clock: clock, into: &sendStem)
    }

    /// The texture stem: the mids at the phrase level plus the hiss, under the edge envelope.
    static func mixTexture(_ mids: [Float], level: inout Float, hiss: [Float], envelope: [Float],
                           into out: UnsafeMutablePointer<Float>, count: vDSP_Length) {
        vDSP_vsma(mids, 1, &level, hiss, 1, out, 1, count)
        vDSP_vmul(out, 1, envelope, 1, out, 1, count)
    }

    /// Nominal dry level of the sampled mid shells on the texture stem (the fixed trim was 0.31).
    /// Used when a phrase has too little lead and mid overlap to measure (`midsLevel`).
    /// Raised from 2.2 with the mids chain (plan 8.4), which takes about 2.7 dB off the shells
    /// (high-pass 160 Hz, -3 dB at 400 Hz): the nominal level is the same as before the chain.
    /// Mix calibration raised it from 3.0 (+1.6 dB): a breakdown's soft answer, the one phrase that keeps
    /// it, read 9 dB under the lead in the reference capture.
    static let midsTrim: Float = 3.6
    /// Where lead and mids sound together, the mids sit this far under the lead in 400 Hz to 3 kHz
    /// (M13 asks for 3 to 8 dB). Chosen by measurement on the reference captures.
    /// 5.5 read 6.1 to 8.2 dB on the matrix (long above 8; the bus ducks under featured chops take the
    /// mids 1 dB further down than the lead, and loud lead notes over decaying shells dominate the measure), so mix calibration set 3.5.
    static let midsUnderLeadDB: Float = 3.5
    /// Shortest lead and mid overlap in a phrase that sets the matched level. 0.25 s left every phrase of
    /// the short-overlap first take at `midsTrim`, about 1 dB under the lead (mix calibration).
    static let midsMatchSeconds = 0.1
    /// The per-phrase mids gain stays within this factor of `midsTrim` either way.
    static let midsGainRange: Float = 2.5
    /// Plucked attacks never push the dry mids above -4.4 dBFS before the instrument balance. Mix
    /// calibration tried 1.0: C-B5 held, but plucked shells then peaked at 0 dBFS on the texture stem and
    /// the pre-master peak rose 2 dB, so the ceiling stayed.
    static let midsPeakCeiling: Float = 0.6
    /// The mids' contribution to `InstrumentBalance`, at the former 0.31 trim.
    static let midsMeterTrim: Float = 0.31

    /// Indices of the upper note of each two-note mid shell: a texture note whose partner (same
    /// articulation, lower pitch) starts at the same beat or up to the roll's stagger before it.
    static func upperShellVoices(_ score: LofiScore) -> Set<Int> {
        let mids = score.notes.indices.filter { score.notes[$0].part == .texture }
        return Set(mids.filter { i in
            let note = score.notes[i]
            return mids.contains { j in
                let other = score.notes[j]
                return j != i && other.articulation == note.articulation && other.midi < note.midi
                    && other.beat <= note.beat + 1e-9 && other.beat >= note.beat - 0.18
            }
        })
    }

    /// One mids gain per phrase: meter the dry lead (after its gain) and the dry mids in 400 Hz to
    /// 3 kHz where the score has both sounding, and set the mids `midsUnderLeadDB` under the lead.
    /// Every program and arrangement then keeps the same relation; the mids never ride per note.
    static func midsLevel(lead: (left: [Float], right: [Float]), leadGain: Float,
                                  texture: (left: [Float], right: [Float]), score: LofiScore,
                                  clock: LofiClock) -> Float {
        // Breakdowns are matched too (19 November 2026): with the darker acoustic and guitar programs a
        // breakdown's shells at the nominal level sat over the lead (C-B5 lead minus mids read -1.6 dB).
        let n = clock.frameCount
        var leadOn = [Bool](repeating: false, count: n), midOn = leadOn
        for note in score.notes where note.part != .bass {
            let range = max(0, clock.frame(at: note.beat))..<min(n, clock.frame(at: note.beat + note.length))
            guard !range.isEmpty else { continue }
            if note.part.playsLead {
                leadOn.withUnsafeMutableBufferPointer { $0[range].update(repeating: true) }
            } else {
                midOn.withUnsafeMutableBufferPointer { $0[range].update(repeating: true) }
            }
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
        var peakL: Float = 0, peakR: Float = 0
        vDSP_maxmgv(texture.left, 1, &peakL, vDSP_Length(n))
        vDSP_maxmgv(texture.right, 1, &peakR, vDSP_Length(n))
        let peak = max(peakL, peakR)
        var leadMono = [Float](repeating: 0, count: n), midMono = leadMono
        var half: Float = 0.5
        vDSP_vasm(lead.left, 1, lead.right, 1, &half, &leadMono, 1, vDSP_Length(n))
        vDSP_vasm(texture.left, 1, texture.right, 1, &half, &midMono, 1, vDSP_Length(n))
        leadMono.withUnsafeBufferPointer { leadMono in
            midMono.withUnsafeBufferPointer { midMono in
            leadOn.withUnsafeBufferPointer { leadOn in
            midOn.withUnsafeBufferPointer { midOn in
                for frame in 0..<n {
                    let l = leadMeter.band(leadMono[frame], high: high, low: low) * leadGain
                    let m = midMeter.band(midMono[frame], high: high, low: low)
                    guard leadOn[frame], midOn[frame] else { continue }
                    leadPower += Double(l * l)
                    midPower += Double(m * m)
                    count += 1
                }
            }}
            }
        }
        var gain = midsTrim
        if count >= Int(midsMatchSeconds * clock.sampleRate), midPower > 1e-14, leadPower > 1e-14 {
            let matched = Float(sqrt(leadPower / midPower)) * powf(10, -midsUnderLeadDB / 20)
            gain = min(midsTrim * midsGainRange, max(midsTrim / midsGainRange, matched))
        }
        // Plucked programs meter quietly over a held shell; never let their attacks overshoot.
        return peak > 0 ? min(gain, midsPeakCeiling / peak) : gain
    }

    /// Per-phrase gains of the instrument stems, for the stem-chain and balance work.
    static func reportMusicLevels(_ score: LofiScore, phrase: Int, levels: [String: Float]) {
        guard LofiCaptureHooks.isEnabled else { return }
        let mids = score.notes.filter { $0.part == .texture }
        var entry: [String: Any] = levels.mapValues { Double($0) }
        entry["phrase"] = phrase
        entry["section"] = String(describing: score.section)
        entry["program"] = score.preset.name
        entry["midEvents"] = mids.count / 2
        entry["midArticulations"] = mids.map { String(describing: $0.articulation) }
        LofiCaptureHooks.appendReport("musicLevels", entry)
    }
}
