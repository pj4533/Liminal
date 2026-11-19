import Foundation

/// Three bounded bass colors plus today's sound. A phrase uses one voice for all of its notes.
/// Every voice is mono, starts at zero phase with a smooth rise, sustains at the note's exact
/// pitch, and ends on the same 60 ms edge, so changing voice never adds a click or detunes.
/// The new voices are loudness matched to `classic` over a held note at MIDI 33.
nonisolated enum LofiBassVoice: Int, CaseIterable, Sendable {
    /// Today's sine with decaying second harmonic and tanh shaping, kept bit for bit.
    case classic
    /// Sine fundamental, 5 ms rise, pitch settling from +30 cents, light second harmonic.
    case roundSub
    /// Stable body under a bright 2nd to 4th harmonic burst and a 3 ms band-limited click.
    case pluck
    /// Round body with a slow decaying second harmonic and a long controlled release.
    case longAnswer

    /// Seconds from note start until the voice's envelope reaches 20 percent of its peak:
    /// the audible attack landmark that aligns with a kick attack (`noteStart = kick - attackLead`).
    /// Measured by `LofiRhythmTests`.
    var attackLead: Double {
        switch self {
        case .classic: 0.0085
        case .roundSub: 0.0016
        case .pluck: 0.0014
        case .longAnswer: 0.0038
        }
    }

    static func add(_ note: LofiScore.Note, voice: LofiBassVoice, clock: LofiClock,
                    left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        switch voice {
        case .classic: addClassic(note, clock: clock, left: left, right: right)
        case .roundSub, .pluck, .longAnswer: addShaped(note, recipe: voice.recipe, clock: clock, left: left, right: right)
        }
    }

    /// The bass branch of the original `LofiSynth.add`, unchanged in types and operation order.
    private static func addClassic(_ note: LofiScore.Note, clock: LofiClock,
                                   left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let start = clock.frame(at: note.beat)
        let span = clock.frame(at: note.length)
        let frequency = 440 * pow(2, Double(note.midi - 69) / 12)
        let rate = clock.sampleRate
        let omega = 2 * Double.pi * frequency / rate
        let attack: Double, release: Double, gain: Float, pan: Float
        (attack, release, gain, pan) = (0.018, 0.31, 0.337, 0)
        let tail = max(1, Int(rate * release))
        let count = min(left.count - start, span + tail)
        guard count > 0 else { return }
        let a = sqrtf(0.5 * (1 - pan)), b = sqrtf(0.5 * (1 + pan))
        let fade = min(count, max(1, Int(rate * 0.06)))
        for i in 0..<count {
            let t = Double(i) / rate
            let phase = Double(i) * omega
            let rise = min(1, t / attack)
            let fall = i < span ? 1 : max(0, 1 - Double(i - span) / Double(tail))
            let edge = min(1, Double(count - 1 - i) / Double(fade))
            let body = sin(phase) + (0.12 + 0.13 * exp(-t * 4)) * sin(2 * phase) + 0.04 * sin(3 * phase)
            let wave = tanh(1.15 * body)
            let value = Float(wave * rise * rise * fall * fall * edge) * gain * note.velocity
            left[start + i] += value * a
            right[start + i] += value * b
        }
    }

    struct Recipe: Sendable {
        /// Raised-cosine rise and release, in seconds.
        let rise: Double, release: Double
        /// Starting pitch offset in cents and the time it takes to settle exactly on the note.
        let glideCents: Double, glideTime: Double
        /// Sustained harmonics 2, 3 and 4 relative to the fundamental.
        let harmonics: (Double, Double, Double)
        /// Extra second harmonic that decays with `secondDecay` seconds time constant.
        let secondBurst: Double, secondDecay: Double
        /// Bright 2nd to 4th harmonics that fade out over `brightTime` seconds.
        let bright: Double, brightTime: Double
        /// Hann-windowed click: level relative to the body, duration and frequency.
        let click: Double, clickTime: Double, clickFrequency: Double
        let drive: Double
        let gain: Float
    }

    var recipe: Recipe {
        switch self {
        case .classic, .roundSub:
            Recipe(rise: 0.005, release: 0.22, glideCents: 30, glideTime: 0.035, harmonics: (0.10, 0, 0),
                   secondBurst: 0, secondDecay: 1, bright: 0, brightTime: 1, click: 0, clickTime: 0.003,
                   clickFrequency: 1_500, drive: 1.1, gain: 0.2777)
        case .pluck:
            Recipe(rise: 0.003, release: 0.18, glideCents: 0, glideTime: 0, harmonics: (0.12, 0.10, 0.05),
                   secondBurst: 0, secondDecay: 1, bright: 0.55, brightTime: 0.09, click: 0.1, clickTime: 0.003,
                   clickFrequency: 1_500, drive: 1.2, gain: 0.2680)
        case .longAnswer:
            Recipe(rise: 0.012, release: 0.42, glideCents: 0, glideTime: 0, harmonics: (0.04, 0, 0),
                   secondBurst: 0.12, secondDecay: 0.25, bright: 0, brightTime: 1, click: 0, clickTime: 0.003,
                   clickFrequency: 1_500, drive: 1.05, gain: 0.2797)
        }
    }

    /// Phase-accumulating renderer for the new voices. All envelope corners are raised cosines.
    private static func addShaped(_ note: LofiScore.Note, recipe r: Recipe, clock: LofiClock,
                                  left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let start = clock.frame(at: note.beat)
        let span = clock.frame(at: note.length)
        let rate = clock.sampleRate
        let omega = 2 * Double.pi * 440 * pow(2, Double(note.midi - 69) / 12) / rate
        let tail = max(1, Int(rate * r.release))
        let count = min(left.count - start, span + tail)
        guard count > 0, start >= 0 else { return }
        let fade = min(count, max(1, Int(rate * 0.06)))
        let level = Float(sqrtf(0.5)) * r.gain * note.velocity
        let normal = 1 / tanh(r.drive)
        let clickOmega = 2 * Double.pi * r.clickFrequency / rate
        // The bright burst follows exp(-t / tau) and reaches -40 dB at `brightTime`.
        let brightTau = r.brightTime / log(100)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            let rise = t < r.rise ? 0.5 - 0.5 * cos(Double.pi * t / r.rise) : 1
            let fall: Double
            if i < span {
                fall = 1
            } else {
                let u = min(1, Double(i - span) / Double(tail))
                fall = 0.5 + 0.5 * cos(Double.pi * u)
            }
            let edge = min(1, Double(count - 1 - i) / Double(fade))
            let second = r.harmonics.0 + r.secondBurst * exp(-t / r.secondDecay)
            var body = sin(phase) + second * sin(2 * phase) + r.harmonics.1 * sin(3 * phase)
                + r.harmonics.2 * sin(4 * phase)
            if r.bright > 0, t < r.brightTime * 1.5 {
                let b = r.bright * exp(-t / brightTau)
                body += b * (0.5 * sin(2 * phase) + 0.35 * sin(3 * phase) + 0.25 * sin(4 * phase))
            }
            var wave = tanh(r.drive * body) * normal
            if r.click > 0, t < r.clickTime {
                let window = 0.5 - 0.5 * cos(2 * Double.pi * t / r.clickTime)
                wave += r.click * window * sin(clickOmega * Double(i))
            }
            let value = Float(wave * rise * fall * edge) * level
            left[start + i] += value
            right[start + i] += value
            // Glide settles on the exact note with a raised-cosine curve, then stays there.
            let cents = t < r.glideTime ? r.glideCents * (0.5 + 0.5 * cos(Double.pi * t / r.glideTime)) : 0
            phase += omega * (cents == 0 ? 1 : pow(2, cents / 1200))
        }
    }
}
