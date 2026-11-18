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

        var holdLevel: Float { self == .freeze ? 1.24 : (self == .cloud ? 0.34 : 0) }

        func taps(for profile: LofiPreset.Space) -> (left: Double, right: Double) {
            switch self {
            case .cloud: profile.taps
            case .resonance: (0.5, 0.75)
            case .tape: (1, 1.5)
            case .freeze: (0.75, 1.25)
            }
        }

        var roomDecay: Double {
            switch self {
            case .cloud: 4.7
            case .resonance: 1.6
            case .tape: 2.45
            case .freeze: 3.65
            }
        }

        var returnGains: (echo: Float, room: Float, color: Float) {
            switch self {
            case .cloud: (0.95, 1.27, 0.84)
            case .resonance: (1.02, 0.75, 1.11)
            case .tape: (1.28, 0.82, 0.66)
            case .freeze: (0.78, 1.01, 0.94)
            }
        }
    }

    struct Returns {
        let echo: Stereo
        let room: Stereo
        let color: Stereo

        var mix: Stereo {
            (echo.left + room.left + color.left, echo.right + room.right + color.right)
        }
    }

    private var echoL: Delay
    private var echoR: Delay
    private var particleTap: Delay
    private var room: Room
    private var motion: LofiMotion
    private var ensemble: Ensemble
    private var tapeL = TapeColor()
    private var tapeR = TapeColor()
    private var leadPresence: Float = 0
    private let profile: LofiPreset.Space
    private let gesture: Gesture
    private let beatStep: Float
    private var orbit: Float = 0

    init(clock: LofiClock, profile: LofiPreset.Space = .standard, tonic: Int = 0, seed: UInt64 = 0,
         gesture: Gesture = .cloud) {
        self.profile = profile
        self.gesture = gesture
        beatStep = 1 / Float(clock.framesPerBeat)
        let taps = gesture.taps(for: profile)
        echoL = Delay(frames: clock.frame(at: taps.left), damping: 0.23)
        echoR = Delay(frames: clock.frame(at: taps.right), damping: 0.18)
        particleTap = Delay(frames: clock.frame(at: taps.right + 0.5), damping: 0.14)
        room = Room(rate: clock.sampleRate, decay: gesture.roomDecay)
        ensemble = Ensemble(rate: clock.sampleRate)
        motion = LofiMotion(clock: clock, tonic: tonic, seed: seed, gesture: gesture)
    }

    mutating func process(lead: Stereo, texture: Stereo, grains: Stereo, space: Float) -> Stereo {
        processReturns(lead: lead, texture: texture, grains: grains, space: space).mix
    }

    mutating func processReturns(lead: Stereo, texture: Stereo, grains: Stereo, space: Float) -> Returns {
        let dryPeak = max(abs(lead.left), abs(lead.right))
        leadPresence += (dryPeak - leadPresence) * (dryPeak > leadPresence ? 0.00085 : 0.00010)
        let presence = min(1, 13 * leadPresence)
        let echoA = echoL.read()
        let echoB = echoR.read()
        let feedback = min(0.59, profile.feedback * 0.75 + 0.15 * space)
        let scatter = particleTap.read()
        let grainL = grains.left * profile.particles
        let grainR = grains.right * profile.particles
        echoL.write(tape(lead.left * 0.76 + grainR * 0.32 + echoB * feedback))
        echoR.write(tape(lead.right * 0.76 + grainL * 0.32 + echoA * feedback))
        particleTap.write(tape(0.36 * (grainL - grainR) + 0.28 * scatter))
        let animated = motion.process(lead: lead, texture: texture, grain: (grainL, grainR))
        orbit += beatStep
        let cloud = ensemble.process(left: 0.72 * grainL + 0.55 * animated.left,
                                     right: 0.72 * grainR + 0.55 * animated.right, beat: orbit)
        // Two slow rhythmic swells trade places, leaving the dry instrument centered.
        let pulseL = 0.74 + 0.26 * cosf(2 * .pi * orbit / 1.5)
        let pulseR = 0.74 + 0.26 * cosf(2 * .pi * orbit - .pi * 0.5)
        let bloomL = pulseL * cloud.left
        let bloomR = pulseR * cloud.right
        let wash = room.process(
            0.72 * texture.left + 0.57 * lead.left + 0.47 * echoA + 0.61 * grainL + scatter + bloomL,
            0.72 * texture.right + 0.57 * lead.right + 0.47 * echoB + 0.61 * grainR - scatter + bloomR
        )
        // Keep the attack legible, then let repeats and grains become the foreground.
        let gains = gesture.returnGains
        let echoGain = gains.echo * (0.77 + 0.24 * space - 0.18 * presence)
        let roomGain = gains.room * profile.diffusion * (1.03 + 0.70 * space - 0.30 * presence)
        let pan = 0.21 * profile.stereo * (sinf(orbit * 0.73) + 0.42 * sinf(orbit * 2.39))
        let echo = (echoGain * echoA, echoGain * echoB)
        let classic = (roomGain * wash.left, roomGain * wash.right)
        let colorL = gains.color * ((0.49 + pan) * grainL + scatter + animated.left + 0.25 * bloomL)
        let colorR = gains.color * ((0.49 - pan) * grainR - scatter + animated.right + 0.25 * bloomR)
        if gesture == .tape {
            // The saturation is a parallel return. Its half-sample linear delay does not touch the dry attack.
            let drive = 1.25 + 0.40 * space
            let l = echo.0 + 0.55 * colorL
            let r = echo.1 + 0.55 * colorR
            return Returns(echo: (echo.0 * 0.88, echo.1 * 0.88), room: classic,
                           color: (colorL + 0.18 * tapeL.process(l, drive: drive),
                                   colorR + 0.18 * tapeR.process(r, drive: drive)))
        }
        return Returns(echo: echo, room: classic, color: (colorL, colorR))
    }

    private func tape(_ x: Float) -> Float { x / (1 + 0.42 * abs(x)) }

    /// First-order antiderivative of a bounded tanh shaper. A midpoint limit avoids cancellation.
    struct TapeColor {
        private var previous: Float = 0
        private var previousIntegral: Float = 0

        mutating func process(_ sample: Float, drive: Float) -> Float {
            let x = min(4, max(-4, sample * drive))
            let integral = logf(coshf(x))
            let delta = x - previous
            let shaped = abs(delta) > 0.003
                ? (integral - previousIntegral) / delta : tanhf(0.5 * (x + previous))
            previous = x
            previousIntegral = integral
            return shaped / drive
        }
    }

    /// Short moving read heads smear the grain cloud ahead of the room. Their modulation follows the bar clock.
    private struct Ensemble {
        private var left: [Float]
        private var right: [Float]
        private var index = 0
        private let rate: Float

        init(rate: Double) {
            self.rate = Float(rate)
            left = [Float](repeating: 0, count: max(4, Int(rate * 0.023) + 2))
            right = left
        }

        mutating func process(left inputL: Float, right inputR: Float, beat: Float) -> Stereo {
            left[index] = inputL
            right[index] = inputR
            let sway = sinf(beat * .pi * 0.5)
            let drift = sinf(beat * .pi / 3)
            let a = tap(left, seconds: 0.007 + 0.0028 * sway)
            let b = tap(right, seconds: 0.011 - 0.0035 * sway)
            let c = tap(left, seconds: 0.016 - 0.003 * drift)
            let d = tap(right, seconds: 0.018 + 0.003 * drift)
            index = (index + 1) % left.count
            return (0.57 * a + 0.43 * d, 0.57 * b + 0.43 * c)
        }

        private func tap(_ storage: [Float], seconds: Float) -> Float {
            let position = Float(index + storage.count) - seconds * rate
            let frame = Int(position)
            let u = position - Float(frame)
            let a = storage[frame % storage.count]
            let b = storage[(frame + 1) % storage.count]
            return a + (b - a) * u
        }
    }

    /// Replay staggered pieces of the last note of each group. Reverse grains make a swell
    /// and half-speed adds an octave-down answer without adding an unrelated melody.
    static func granulate(_ lead: (left: [Float], right: [Float]), score: LofiScore,
                          clock: LofiClock, frames: Int, seed: UInt64, gesture: Gesture) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        var rng = MusicRNG(seed: seed).fork(110)
        let notes = score.notes.filter { $0.part == .lead && $0.velocity > 0 && $0.send >= 0.34 }
        let endings = notes.indices.filter { index in
            index + 1 == notes.count || notes[index + 1].beat - notes[index].beat >= 2.6
        }
        for index in endings {
            let note = notes[index]
            let from = clock.frame(at: note.beat + 0.04)
            let span = clock.frame(at: 0.4)
            let answer = (note.beat * 4).rounded() / 4 + 0.75
            let countPerAnswer = gesture == .cloud ? 7 : (gesture == .tape ? 3 : 5)
            for grain in 0..<countPerAnswer {
                let destination = clock.frame(at: answer + Double(grain) * 0.375)
                let backwards = grain.isMultiple(of: 2)
                let lifted = grain == 5 && gesture == .cloud && note.midi <= 61
                let speed = backwards ? 0.5 : (lifted ? 1.5 : 1.0)
                let count = min(frames - destination, clock.frame(at: rng.range(0.34...0.82)), Int(Double(span) / speed))
                guard count > 1 else { continue }
                let balance = rng.rangeF(0.16...0.84)
                let gain = rng.rangeF(0.40...0.68) * (1 - 0.07 * Float(grain))
                    * (lifted ? 0.40 : 1)
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
        var result = (left: left, right: right)
        if gesture.holdLevel > 0, let note = notes.max(by: { $0.send < $1.send }) {
            LofiSpectralHold.add(from: lead, note: note, clock: clock, gain: gesture.holdLevel,
                                 to: &result, rng: &rng)
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

    /// Predelay leaves the piano attack exposed before the diffused four-line tail blooms.
    struct Room {
        private var preL: Delay, preR: Delay
        private var diffuseL: Delay, diffuseR: Delay
        private var a: Delay, b: Delay, c: Delay, d: Delay
        private let ga: Float, gb: Float, gc: Float, gd: Float

        init(rate: Double, decay: Double = 7.5) {
            preL = Delay(frames: Int(rate * 0.034), damping: 0.62)
            preR = Delay(frames: Int(rate * 0.041), damping: 0.62)
            diffuseL = Delay(frames: Int(rate * 0.0119), damping: 1)
            diffuseR = Delay(frames: Int(rate * 0.0167), damping: 1)
            let lengths = (0.0511, 0.0677, 0.0839, 0.1061)
            a = Delay(frames: Int(lengths.0 * rate), damping: 0.47)
            b = Delay(frames: Int(lengths.1 * rate), damping: 0.42)
            c = Delay(frames: Int(lengths.2 * rate), damping: 0.45)
            d = Delay(frames: Int(lengths.3 * rate), damping: 0.39)
            let t60 = min(8.0, max(0.8, decay))
            ga = Float(pow(0.001, lengths.0 / t60))
            gb = Float(pow(0.001, lengths.1 / t60))
            gc = Float(pow(0.001, lengths.2 / t60))
            gd = Float(pow(0.001, lengths.3 / t60))
        }

        mutating func process(_ left: Float, _ right: Float) -> Stereo {
            let inputL = preL.read(), inputR = preR.read()
            preL.write(left)
            preR.write(right)
            let l = diffuseL.read() - 0.61 * inputL
            let r = diffuseR.read() - 0.61 * inputR
            diffuseL.write(inputL + 0.61 * l)
            diffuseR.write(inputR + 0.61 * r)
            let w = a.read(), x = b.read(), y = c.read(), z = d.read()
            a.write(0.36 * l + 0.5 * ga * (w + x + y + z))
            b.write(0.36 * r + 0.5 * gb * (w - x + y - z))
            c.write(0.29 * (l + 0.2 * r) + 0.5 * gc * (w + x - y - z))
            d.write(-0.29 * (r + 0.2 * l) + 0.5 * gd * (w - x - y + z))
            return (0.48 * (w + x - 0.62 * y), 0.48 * (y - z + 0.64 * x))
        }
    }
}
