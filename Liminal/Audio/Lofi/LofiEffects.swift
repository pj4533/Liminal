import Foundation

/// Stereo repeats recirculate through darker filters. The two sides use different beat divisions.
nonisolated struct LofiEffects {
    typealias Stereo = (left: Float, right: Float)

    enum Gesture: CaseIterable, Hashable, Sendable {
        case cloud, resonance, tape, freeze

        static func selection(seed: UInt64, phrase: Int) -> Self {
            MusicRNG(seed: seed).fork(966).shuffledCycle(allCases, index: phrase)
        }

        // Each phrase emphasizes a different wet process. Its other returns stay in the mix.
        var colors: (diffusion: Float, ringing: Float, folding: Float, texture: Float) {
            switch self {
            case .cloud: (1.23, 0.67, 0.55, 0.68)
            case .resonance: (0.82, 1.42, 0.68, 0.71)
            case .tape: (0.88, 0.71, 1.32, 1.33)
            case .freeze: (0.79, 1.06, 0.57, 0.62)
            }
        }

        var holdLevel: Float { self == .freeze ? 1.35 : (self == .tape ? 0.55 : 0.85) }
    }

    private var echoL: Delay
    private var echoR: Delay
    private var particleTap: Delay
    private var room: Room
    private var motion: LofiMotion
    private var leadPresence: Float = 0
    private let profile: LofiPreset.Space
    private let beatStep: Float
    private var orbit: Float = 0

    init(clock: LofiClock, profile: LofiPreset.Space = .standard, tonic: Int = 0, seed: UInt64 = 0,
         gesture: Gesture = .cloud) {
        self.profile = profile
        beatStep = 1 / Float(clock.framesPerBeat)
        let taps = profile.taps
        echoL = Delay(frames: clock.frame(at: taps.left), damping: 0.23)
        echoR = Delay(frames: clock.frame(at: taps.right), damping: 0.18)
        particleTap = Delay(frames: clock.frame(at: taps.right + 0.5), damping: 0.14)
        room = Room(rate: clock.sampleRate)
        motion = LofiMotion(clock: clock, tonic: tonic, seed: seed, gesture: gesture)
    }

    mutating func process(lead: Stereo, texture: Stereo, grains: Stereo, space: Float) -> Stereo {
        let dryPeak = max(abs(lead.left), abs(lead.right))
        leadPresence += (dryPeak - leadPresence) * (dryPeak > leadPresence ? 0.00085 : 0.00010)
        let presence = min(1, 13 * leadPresence)
        let echoA = echoL.read()
        let echoB = echoR.read()
        let feedback = min(0.56, profile.feedback * 0.68 + 0.14 * space)
        let scatter = particleTap.read()
        let grainL = grains.left * profile.particles
        let grainR = grains.right * profile.particles
        echoL.write(tape(lead.left * 0.76 + grainR * 0.32 + echoB * feedback))
        echoR.write(tape(lead.right * 0.76 + grainL * 0.32 + echoA * feedback))
        particleTap.write(tape(0.36 * (grainL - grainR) + 0.28 * scatter))
        let animated = motion.process(lead: lead, texture: texture, grain: (grainL, grainR))
        let wash = room.process(
            texture.left + 0.23 * lead.left + 0.39 * echoA + 0.72 * grainL + scatter + 0.61 * animated.left,
            texture.right + 0.23 * lead.right + 0.39 * echoB + 0.72 * grainR - scatter + 0.61 * animated.right
        )
        // Keep the attack legible, then let repeats and grains become the foreground.
        let echoGain = 0.57 + 0.19 * space - 0.15 * presence
        let roomGain = profile.diffusion * (0.68 + 0.74 * space - 0.18 * presence)
        orbit += beatStep
        let pan = 0.21 * profile.stereo * (sinf(orbit * 0.73) + 0.42 * sinf(orbit * 2.39))
        return (echoGain * echoA + roomGain * wash.left + (0.54 + pan) * grainL + scatter + animated.left,
                echoGain * echoB + roomGain * wash.right + (0.54 - pan) * grainR - scatter + animated.right)
    }

    private func tape(_ x: Float) -> Float { x / (1 + 0.42 * abs(x)) }

    /// Replay staggered pieces of the last note of each group. Reverse grains make a swell
    /// and half-speed adds an octave-down answer without adding an unrelated melody.
    static func granulate(_ lead: (left: [Float], right: [Float]), score: LofiScore,
                          clock: LofiClock, frames: Int, seed: UInt64, gesture: Gesture) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        var rng = MusicRNG(seed: seed).fork(110)
        let notes = score.notes.filter { $0.part == .lead }
        let endings = notes.indices.filter { index in
            index + 1 == notes.count || notes[index + 1].beat - notes[index].beat >= 2.6
        }
        for index in endings {
            let note = notes[index]
            let from = clock.frame(at: note.beat + 0.04)
            let span = clock.frame(at: 0.4)
            let answer = (note.beat * 4).rounded() / 4 + 0.75
            // With no late dry reply, reprise the original note as a softer cloud.
            let clouds = endings.count == 1 && note.beat < 8 ? [answer, rng.pick([9.75, 10.5, 11.25])] : [answer]
            for (layer, start) in clouds.enumerated() {
                for grain in 0..<(layer == 0 ? 7 : 5) {
                    let destination = clock.frame(at: start + Double(grain) * 0.375)
                    let backwards = grain.isMultiple(of: 2)
                    let lifted = grain == 5 && gesture == .cloud && note.midi <= 61
                    let speed = backwards ? 0.5 : (lifted ? 1.5 : 1.0)
                    let count = min(frames - destination, clock.frame(at: rng.range(0.34...0.82)), Int(Double(span) / speed))
                    guard count > 1 else { continue }
                    let balance = rng.rangeF(0.16...0.84)
                    let gain = rng.rangeF(0.40...0.68) * (1 - 0.07 * Float(grain))
                        * (layer == 0 ? 1 : 0.77) * (lifted ? 0.40 : 1)
                    for i in 0..<count {
                        let p = min(Double(span - 1), Double(i) * speed)
                        let source = Double(from) + (backwards ? Double(span - 1) - p : p)
                        let j = Int(source)
                        guard j >= 0, j + 1 < lead.left.count else { continue }
                        let u = Float(source - Double(j))
                        let window = sinf(.pi * Float(i) / Float(count - 1))
                        let a = lead.left[j] + (lead.left[j + 1] - lead.left[j]) * u
                        let b = lead.right[j] + (lead.right[j + 1] - lead.right[j]) * u
                        left[destination + i] += (balance * b + 0.35 * a) * gain * window * window
                        right[destination + i] += ((1 - balance) * a + 0.35 * b) * gain * window * window
                    }
                }
            }
        }
        var result = (left: left, right: right)
        if let note = notes.first {
            LofiSpectralHold.add(from: lead, note: note, clock: clock, gain: gesture.holdLevel, to: &result, rng: &rng)
        }
        return result
    }

    private struct Delay {
        private var buffer: [Float]
        private var cursor = 0
        private var low: Float = 0
        private let damping: Float

        init(frames: Int, damping: Float) {
            buffer = [Float](repeating: 0, count: max(1, frames))
            self.damping = damping
        }

        mutating func read() -> Float {
            low += damping * (buffer[cursor] - low)
            return low
        }

        mutating func write(_ sample: Float) {
            buffer[cursor] = sample
            cursor += 1
            if cursor == buffer.count { cursor = 0 }
        }
    }

    /// A four-line Hadamard feedback delay network. Independent decay gains give the
    /// unequal paths the same nominal reverb time and the dampers soften each pass.
    private struct Room {
        private var a: Delay, b: Delay, c: Delay, d: Delay
        private let ga: Float, gb: Float, gc: Float, gd: Float

        init(rate: Double) {
            let lengths = (0.0383, 0.0537, 0.0679, 0.0881)
            a = Delay(frames: Int(lengths.0 * rate), damping: 0.24)
            b = Delay(frames: Int(lengths.1 * rate), damping: 0.20)
            c = Delay(frames: Int(lengths.2 * rate), damping: 0.23)
            d = Delay(frames: Int(lengths.3 * rate), damping: 0.19)
            ga = Float(pow(0.001, lengths.0 / 6.6))
            gb = Float(pow(0.001, lengths.1 / 6.6))
            gc = Float(pow(0.001, lengths.2 / 6.6))
            gd = Float(pow(0.001, lengths.3 / 6.6))
        }

        mutating func process(_ left: Float, _ right: Float) -> Stereo {
            let w = a.read(), x = b.read(), y = c.read(), z = d.read()
            a.write(0.31 * left + 0.5 * ga * (w + x + y + z))
            b.write(0.31 * right + 0.5 * gb * (w - x + y - z))
            c.write(0.24 * left + 0.5 * gc * (w + x - y - z))
            d.write(-0.24 * right + 0.5 * gd * (w - x - y + z))
            return (0.4 * (w + x - 0.65 * y), 0.4 * (y - z + 0.65 * x))
        }
    }
}
