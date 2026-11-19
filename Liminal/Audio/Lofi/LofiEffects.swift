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
            case .cloud: 7.2
            case .resonance: 4.8
            case .tape: 5.6
            case .freeze: 7.8
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
    private var plate: Room
    private var room: Room
    private var motion: LofiMotion
    private var ensemble: Ensemble
    private var tapeL = TapeColor()
    private var tapeR = TapeColor()
    private var leadPresence: Float = 0
    private let profile: LofiPreset.Space
    private let gesture: Gesture
    /// Per-sample constants of the gesture, resolved once (the effect loop runs unoptimized in Debug).
    private let gains: (echo: Float, room: Float, color: Float)
    private let isTape: Bool
    private let beatStep: Float
    private var orbit: Float = 0

    init(clock: LofiClock, profile: LofiPreset.Space = .standard, tonic: Int = 0, seed: UInt64 = 0,
         gesture: Gesture = .cloud, scale: ScaleType = .minor) {
        self.profile = profile
        self.gesture = gesture
        gains = gesture.returnGains
        isTape = gesture == .tape
        beatStep = 1 / Float(clock.framesPerBeat)
        let taps = gesture.taps(for: profile)
        echoL = Delay(frames: clock.frame(at: taps.left), damping: 0.23)
        echoR = Delay(frames: clock.frame(at: taps.right), damping: 0.18)
        particleTap = Delay(frames: clock.frame(at: taps.right + 0.5), damping: 0.14)
        plate = Room(rate: clock.sampleRate, decay: 2.5, size: 0.63)
        room = Room(rate: clock.sampleRate, decay: gesture.roomDecay, size: 1.28)
        ensemble = Ensemble(rate: clock.sampleRate)
        motion = LofiMotion(clock: clock, tonic: tonic, scale: scale, seed: seed, gesture: gesture)
    }

    @_transparent
    mutating func processReturns(lead: Stereo, texture: Stereo, grains: Stereo, space: Float) -> Returns {
        let dryPeak = max(abs(lead.left), abs(lead.right))
        leadPresence += (dryPeak - leadPresence) * (dryPeak > leadPresence ? 0.00085 : 0.00010)
        let presence = min(1, 13 * leadPresence)
        let echoA = echoL.read()
        let echoB = echoR.read()
        let feedback = min(0.58, profile.feedback * 0.82 + 0.13 * space)
        let scatter = particleTap.read()
        let grainL = grains.left * profile.particles
        let grainR = grains.right * profile.particles
        echoL.write(tape(0.76 * lead.left + 0.37 * texture.right + 0.47 * grainR + echoB * feedback))
        echoR.write(tape(0.76 * lead.right + 0.37 * texture.left + 0.47 * grainL + echoA * feedback))
        particleTap.write(tape(0.27 * (grainL - grainR) + 0.24 * (echoA - echoB) + 0.30 * scatter))
        let animated = motion.process(lead: lead, texture: texture, grain: (grainL + 0.29 * echoA, grainR + 0.29 * echoB))
        orbit += beatStep
        let smear = ensemble.process(left: 0.55 * grainL + 0.54 * animated.left + 0.28 * texture.right,
                                     right: 0.55 * grainR + 0.54 * animated.right + 0.28 * texture.left, beat: orbit)
        let early = plate.process(1.05 * lead.left + 1.05 * texture.left + 0.27 * grainL,
                                  1.05 * lead.right + 1.05 * texture.right + 0.27 * grainR)
        let swell = 0.78 + 0.22 * cosf(orbit * .pi * 0.5)
        let toneL = 0.48 * echoA + 0.64 * grainL + smear.left + scatter
        let toneR = 0.48 * echoB + 0.64 * grainR + smear.right - scatter
        let late = room.process(0.73 * early.left + swell * toneL + 0.58 * lead.left + 0.45 * texture.left,
                                0.73 * early.right + swell * toneR + 0.58 * lead.right + 0.45 * texture.right)
        // Briefly make room for the attack, then let the space and repeats carry the phrase.
        let echoGain = gains.echo * (0.96 + 0.23 * space - 0.12 * presence)
        let roomGain = gains.room * profile.diffusion * (1.30 + 0.60 * space - 0.22 * presence)
        let echo = (echoGain * echoA, echoGain * echoB)
        let classic = (roomGain * (0.83 * early.left + 1.25 * late.left),
                       roomGain * (0.83 * early.right + 1.25 * late.right))
        // Cross-modulate the replay and feedback lightly. Keep both carriers audible.
        let colorL = gains.color * (0.74 * grainL + 0.75 * scatter + animated.left + 0.38 * smear.left
                                    + 0.34 * grainL * echoB)
        let colorR = gains.color * (0.74 * grainR - 0.75 * scatter + animated.right + 0.38 * smear.right
                                    + 0.34 * grainR * echoA)
        if isTape {
            // The saturation is a parallel return. Its half-sample linear delay does not touch the dry attack.
            let drive = 1.25 + 0.40 * space
            let l = echo.0 + 0.55 * colorL
            let r = echo.1 + 0.55 * colorR
            // Dark, alternating flutter on the color path leaves the beat taps stationary.
            let flutter = 0.88 + 0.12 * sinf(orbit * 2 * .pi)
            return Returns(echo: (echo.0 * 0.88, echo.1 * 0.88), room: classic,
                           color: (flutter * colorL + 0.24 * tapeL.process(l, drive: drive),
                                   (1.76 - flutter) * colorR + 0.24 * tapeR.process(r, drive: drive)))
        }
        return Returns(echo: echo, room: classic, color: (colorL, colorR))
    }

    @_transparent
    private func tape(_ x: Float) -> Float { x / (1 + 0.42 * abs(x)) }

    /// First-order antiderivative of a bounded tanh shaper. A midpoint limit avoids cancellation.
    struct TapeColor {
        private var previous: Float = 0
        private var previousIntegral: Float = 0

        @_transparent
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
        private let lines: (left: Line, right: Line)
        private let left: UnsafeMutablePointer<Float>
        private let right: UnsafeMutablePointer<Float>
        private let length: Int
        private var index = 0
        private let rate: Float

        init(rate: Double) {
            self.rate = Float(rate)
            let count = max(4, Int(rate * 0.023) + 2)
            lines = (Line(count: count), Line(count: count))
            left = lines.left.samples
            right = lines.right.samples
            length = count
        }

        @_transparent
        mutating func process(left inputL: Float, right inputR: Float, beat: Float) -> Stereo {
            left[index] = inputL
            right[index] = inputR
            let sway = sinf(beat * .pi * 0.5)
            let drift = sinf(beat * .pi / 3)
            let a = tap(left, seconds: 0.007 + 0.0028 * sway)
            let b = tap(right, seconds: 0.011 - 0.0035 * sway)
            let c = tap(left, seconds: 0.016 - 0.003 * drift)
            let d = tap(right, seconds: 0.018 + 0.003 * drift)
            index = (index + 1) % length
            return (0.57 * a + 0.43 * d, 0.57 * b + 0.43 * c)
        }

        @_transparent
        private func tap(_ storage: UnsafeMutablePointer<Float>, seconds: Float) -> Float {
            let position = Float(index + length) - seconds * rate
            let frame = Int(position)
            let u = position - Float(frame)
            let a = storage[frame % length]
            let b = storage[(frame + 1) % length]
            return a + (b - a) * u
        }
    }

    /// Pick the closest legal target to an intended interval. Octaves remain available
    /// even in sparse scales. Small upward moves are capped to keep the return mellow.
    static func targetPitch(source: Int, interval: Int, scale: ScaleType, tonic: Int) -> Int {
        guard interval != 0 else { return source }
        let mask = scale.pitchClassMask(tonic: tonic)
        let goal = source + interval
        let candidates = (45...76).filter {
            mask & (UInt16(1) << ($0 % 12)) != 0 && (interval > 0 ? $0 > source : $0 < source)
                && abs($0 - source) <= 12
        }
        return candidates.min { abs($0 - goal) < abs($1 - goal) } ?? source
    }

    /// Replay timed fragments through a second lane. Shifted grains use an isolated note
    /// when its sample is present. A polyphonic fallback moves only by octaves.
    static func granulate(_ lead: (left: [Float], right: [Float]), score: LofiScore,
                          clock: LofiClock, frames: Int, seed: UInt64, gesture: Gesture,
                          texture: (left: [Float], right: [Float]), samples: LofiSampleBank) -> (left: [Float], right: [Float]) {
        let silence = [Float](repeating: 0, count: frames)
        var result = (left: silence, right: silence)
        var rng = MusicRNG(seed: seed).fork(110)
        let leadNotes = score.notes.filter { $0.part == .lead }
        let mids = score.notes.filter { $0.part == .texture }
        let anchors = [leadNotes.first, leadNotes.last, mids.first].compactMap { $0 }
        for note in anchors {
            let sustained = note.part == .texture
            let duration = min(note.length * 0.68, sustained ? 0.64 : 0.53)
            let count = max(3, clock.frame(at: duration))
            let attack = clock.frame(at: 0.035)
            let source: (left: [Float], right: [Float])
            let offset: Int
            let recorded = samples.sample(for: score.preset, midi: note.midi, velocity: note.velocity)
            if let recorded {
                var l = [Float](repeating: 0, count: attack + count + 2), r = l
                let dryNote = LofiScore.Note(part: note.part, midi: note.midi, beat: 0, length: note.length,
                                             velocity: note.velocity * (sustained ? 0.77 : 0.86), color: note.color)
                l.withUnsafeMutableBufferPointer { left in
                    r.withUnsafeMutableBufferPointer { right in
                        LofiSampleBank.add(dryNote, from: recorded, preset: score.preset, clock: clock,
                                           left: left, right: right)
                    }
                }
                source = (l, r)
                offset = attack
            } else {
                source = sustained ? texture : lead
                offset = clock.frame(at: note.beat + 0.035)
            }
            let onGrid = (note.beat * 4).rounded() / 4
            let taps: [(wait: Double, shift: Int, reverse: Bool, gain: Float)]
            switch gesture {
            case .cloud: taps = [(-0.55, 0, true, 0.66), (0.75, 5, false, 0.59), (1.5, -12, true, 0.44), (2.25, 12, false, 0.28)]
            case .resonance: taps = [(0.5, -5, false, 0.63), (1, 0, true, 0.46), (1.75, 7, false, 0.50)]
            case .tape: taps = [(-0.48, -12, true, 0.69), (0.75, 0, true, 0.73), (1, 0, false, 0.43), (2, -7, true, 0.43)]
            case .freeze: taps = [(0.75, -12, false, 0.56), (1.25, 5, true, 0.63), (2.5, 12, false, 0.33)]
            }
            for tap in taps {
                let target = recorded == nil
                    ? note.midi + (abs(tap.shift) == 12 ? tap.shift : 0)
                    : targetPitch(source: note.midi, interval: tap.shift, scale: score.scale, tonic: score.tonic)
                let rate = pow(2, Double(target - note.midi) / 12)
                let pan = rng.rangeF(-0.56...0.56)
                let destination = clock.frame(at: max(0, onGrid + tap.wait))
                let gain = tap.gain * (sustained ? 0.80 : 1)
                replay(source, sourceStart: offset, sourceCount: count, into: &result,
                       destination: destination, rate: rate, reverse: tap.reverse, gain: gain, pan: pan)
            }
        }
        if gesture.holdLevel > 0, let note = leadNotes.last {
            LofiSpectralHold.add(from: lead, note: note, clock: clock, gain: gesture.holdLevel,
                                 to: &result, rng: &rng)
        }
        return result
    }

    /// Record a single window of the toned, mixed return. All destinations follow the
    /// capture window, so the replay can feed the rack without recording itself again.
    struct ReturnReplay {
        let window: Range<Int>
        private let destinations: [Int]
        private var captured: (left: [Float], right: [Float])

        init(lastBeat: Double, clock: LofiClock, gesture: Gesture) {
            let firstReplay = (lastBeat * 4).rounded() / 4 + 0.75
            let start = clock.frame(at: firstReplay + 0.12)
            let count = clock.frame(at: gesture == .freeze ? 0.37 : 0.22)
            window = start..<(start + count)
            destinations = [0.0, 0.625, 1.625].map { clock.frame(at: firstReplay + 1.25 + $0) }
            let empty = [Float](repeating: 0, count: count)
            captured = (empty, empty)
        }

        mutating func capture(_ sample: Stereo, at frame: Int, into grains: inout (left: [Float], right: [Float])) {
            record(sample, at: frame)
            guard frame + 1 == window.upperBound else { return }
            release(into: &grains)
        }

        /// Stores one sample of the window (`frame` inside `window`).
        mutating func record(_ sample: Stereo, at frame: Int) {
            let index = frame - window.lowerBound
            captured.left[index] = sample.left
            captured.right[index] = sample.right
        }

        /// Writes the recorded window to its destinations; call once after the window's last frame.
        func release(into grains: inout (left: [Float], right: [Float])) {
            for (i, destination) in destinations.enumerated() {
                LofiEffects.replay(captured, sourceStart: 0, sourceCount: window.count - 1, into: &grains,
                                   destination: destination, rate: i == 1 ? 1 : 0.5, reverse: i != 1,
                                   gain: 0.60 - 0.11 * Float(i), pan: i == 1 ? -0.64 : 0.62)
            }
        }
    }

    static func replay(_ source: (left: [Float], right: [Float]), sourceStart: Int, sourceCount: Int,
                       into output: inout (left: [Float], right: [Float]), destination: Int,
                       rate: Double, reverse: Bool, gain: Float, pan: Float) {
        guard sourceStart >= 0, destination >= 0, sourceCount >= 3,
              sourceStart + sourceCount < min(source.left.count, source.right.count) else { return }
        let length = Int(Double(sourceCount - 1) / rate) + 1
        let writable = min(length, min(output.left.count, output.right.count) - destination)
        guard writable > 2 else { return }
        let leftGain = gain * (0.84 - 0.48 * pan), rightGain = gain * (0.84 + 0.48 * pan)
        source.left.withUnsafeBufferPointer { sourceL in
        source.right.withUnsafeBufferPointer { sourceR in
        output.left.withUnsafeMutableBufferPointer { outL in
        output.right.withUnsafeMutableBufferPointer { outR in
            let last = Double(sourceCount - 1)
            for i in 0..<writable {
                let step = Double(i) * rate
                let travel = step < last ? step : last
                let position = reverse ? last - travel : travel
                let j = Int(position)
                let fraction = Float(position - Double(j))
                let base = sourceStart + j
                let window = sinf(.pi * Float(i) / Float(writable - 1))
                let l = sourceL[base] + fraction * (sourceL[base + 1] - sourceL[base])
                let r = sourceR[base] + fraction * (sourceR[base + 1] - sourceR[base])
                outL[destination + i] += (0.82 * l + 0.18 * r) * leftGain * window * window
                outR[destination + i] += (0.82 * r + 0.18 * l) * rightGain * window * window
            }
        }}}}
    }

    /// A preallocated line read and written through a raw pointer (fast in unoptimized builds too).
    /// Copies of a delay share the line, so each effect rack owns its delays and never copies them.
    final class Line: @unchecked Sendable {
        let samples: UnsafeMutablePointer<Float>
        let count: Int

        init(count: Int) {
            self.count = max(1, count)
            samples = .allocate(capacity: self.count)
            samples.initialize(repeating: 0, count: self.count)
        }

        deinit { samples.deallocate() }
    }

    private struct Delay {
        private let line: Line
        private let buffer: UnsafeMutablePointer<Float>
        private let length: Int
        private var cursor = 0
        private var low: Float = 0
        private let damping: Float

        init(frames: Int, damping: Float) {
            line = Line(count: frames)
            buffer = line.samples
            length = line.count
            self.damping = damping
        }

        @_transparent
        mutating func read() -> Float {
            low += damping * (buffer[cursor] - low)
            return low
        }

        @_transparent
        mutating func write(_ sample: Float) {
            buffer[cursor] = sample
            cursor += 1
            if cursor == length { cursor = 0 }
        }
    }

    /// Predelay leaves the piano attack exposed before the diffused four-line tail blooms.
    struct Room {
        private var preL: Delay, preR: Delay
        private var diffuseL: Delay, diffuseR: Delay
        private var a: Delay, b: Delay, c: Delay, d: Delay
        private let ga: Float, gb: Float, gc: Float, gd: Float

        init(rate: Double, decay: Double = 7.5, size: Double = 1) {
            preL = Delay(frames: Int(rate * 0.034), damping: 0.62)
            preR = Delay(frames: Int(rate * 0.041), damping: 0.62)
            diffuseL = Delay(frames: Int(rate * 0.0119), damping: 1)
            diffuseR = Delay(frames: Int(rate * 0.0167), damping: 1)
            let lengths = (0.0511 * size, 0.0677 * size, 0.0839 * size, 0.1061 * size)
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

        @_transparent
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
