import Foundation

/// Parallel processes that color the wet signal. Dry leads and the rhythm never pass through these.
nonisolated struct LofiMotion {
    typealias Stereo = LofiEffects.Stereo

    private var leftA: Allpass
    private var leftB: Allpass
    private var rightA: Allpass
    private var rightB: Allpass
    private var fundamental: Resonance
    private var fifth: Resonance
    private var upper: Resonance
    private var foldedL: Float = 0
    private var foldedR: Float = 0
    private var held: Stereo = (0, 0)
    private var decimated: Stereo = (0, 0)
    private var tick = 0
    private var beat: Float
    private let step: Float
    private let colors: (Float, Float, Float)
    private let gesture: (diffusion: Float, ringing: Float, folding: Float, texture: Float)

    init(clock: LofiClock, tonic: Int, scale: ScaleType, seed: UInt64, gesture: LofiEffects.Gesture) {
        self.gesture = gesture.colors
        let rate = clock.sampleRate
        leftA = Allpass(rate, 0.0073)
        leftB = Allpass(rate, 0.0191)
        rightA = Allpass(rate, 0.0117)
        rightB = Allpass(rate, 0.0239)
        let root = 130.813 * pow(2, Double(tonic) / 12)
        fundamental = Resonance(hz: root, decay: 0.85, rate: rate)
        let degree = scale.intervals.filter { $0 != 0 }.min { abs($0 - 7) < abs($1 - 7) } ?? 0
        fifth = Resonance(hz: root * pow(2, Double(degree) / 12), decay: 0.57, rate: rate)
        upper = Resonance(hz: root * 2, decay: 0.33, rate: rate)
        step = 1 / Float(clock.framesPerBeat)
        var rng = MusicRNG(seed: seed).fork(872)
        beat = rng.rangeF(0...20)
        let picked = (0..<3).map { _ in rng.rangeF(0.36...1) }
        colors = (picked[0], picked[1], picked[2])
    }

    @_transparent
    mutating func process(lead: Stereo, texture: Stereo, grain: Stereo) -> Stereo {
        beat += step
        let drift = 0.5 + 0.5 * sinf(beat * 0.43)
        let drift2 = 0.5 + 0.5 * sinf(beat * 0.71 + sinf(beat * 0.23))
        let diffusionL = leftB.process(leftA.process(grain.left + 0.27 * texture.right))
        let diffusionR = rightB.process(rightA.process(grain.right + 0.27 * texture.left))
        let excitation = 0.5 * (grain.left + grain.right) + 0.16 * (texture.left + texture.right)
        let lo = fundamental.process(excitation)
        let hi = fifth.process(excitation)
        let shimmer = upper.process(excitation)
        // Crossfold the fragments against the moving swell and soften the new partials.
        foldedL += 0.10 * (fold(2.9 * grain.left + 0.7 * texture.right + 2.1 * grain.left * texture.right) - foldedL)
        foldedR += 0.10 * (fold(2.9 * grain.right + 0.7 * texture.left + 2.1 * grain.right * texture.left) - foldedR)
        if tick == 0 {
            held = (floorf(1_024 * grain.right + 0.5) / 1_024, floorf(1_024 * grain.left + 0.5) / 1_024)
        }
        tick = (tick + 1) % 5
        decimated.left += 0.13 * (held.left - decimated.left)
        decimated.right += 0.13 * (held.right - decimated.right)
        let ring = gesture.ringing * colors.0 * (0.32 + 0.68 * drift)
        let shape = gesture.folding * colors.1 * drift2 * (0.20 - min(0.09, abs(lead.left) + abs(lead.right)))
        let blur = gesture.diffusion * colors.2 * (0.42 + 0.4 * (1 - drift))
        let textureLevel = 0.19 * gesture.texture * drift
        return (blur * diffusionL + ring * (0.34 * lo + 0.38 * hi) + shape * foldedL + textureLevel * decimated.left,
                blur * diffusionR + ring * (0.36 * lo + 0.38 * shimmer) + shape * foldedR + textureLevel * decimated.right)
    }

    @_transparent
    private func fold(_ sample: Float) -> Float {
        let limit: Float = 0.18
        let x = min(3 * limit, abs(sample))
        let y = x <= limit ? x : 2 * limit - x
        return sample < 0 ? -y : y
    }

    /// Preallocated line through a raw pointer, so the per-sample path stays fast in Debug builds.
    private struct Allpass {
        private let line: LofiEffects.Line
        private let storage: UnsafeMutablePointer<Float>
        private let length: Int
        var index = 0

        init(_ rate: Double, _ seconds: Double) {
            line = LofiEffects.Line(count: max(1, Int(rate * seconds)))
            storage = line.samples
            length = line.count
        }

        @_transparent
        mutating func process(_ x: Float) -> Float {
            let delayed = storage[index]
            let y = delayed - 0.58 * x
            storage[index] = x + 0.58 * y
            index += 1
            if index == length { index = 0 }
            return y
        }
    }

    private struct Resonance {
        let a: Float
        let b: Float
        let gain: Float
        var z1: Float = 0
        var z2: Float = 0

        init(hz: Double, decay: Double, rate: Double) {
            let omega = 2 * Double.pi * min(hz / rate, 0.45)
            let r = exp(-1 / (decay * rate))
            a = Float(2 * r * cos(omega))
            b = Float(r * r)
            gain = Float(2 * (1 - r) * sin(omega))
        }

        @_transparent
        mutating func process(_ x: Float) -> Float {
            let y = a * z1 - b * z2 + gain * x
            z2 = z1
            z1 = y
            return y
        }
    }
}
