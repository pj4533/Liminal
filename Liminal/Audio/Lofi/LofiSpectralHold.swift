import Foundation

/// Capture the actual sampled note's harmonic magnitudes and resynthesize a slow, bent shadow of it.
/// Keeping a few measured partials gives the freeze a tonal center without forcing a long dry note.
nonisolated enum LofiSpectralHold {
    typealias Stereo = (left: [Float], right: [Float])

    static func add(from lead: Stereo, note: LofiScore.Note, clock: LofiClock, gain: Float,
                    to result: inout Stereo, rng: inout MusicRNG) {
        let source = clock.frame(at: note.beat + 0.08)
        let size = min(clock.frame(at: 0.18), lead.left.count - source)
        guard size >= 32 else { return }
        let windows = (0..<size).map { i in 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(size - 1)) }
        let hz = 440 * pow(2, Double(note.midi - 69) / 12)
        let start = clock.frame(at: max(7.5, (note.beat * 4).rounded() / 4 + 1.5))
        let count = min(result.left.count - start, clock.frame(at: rng.range(5.4...7.8)))
        guard count > 32 else { return }
        for partial in 1...10 {
            let frequency = hz * Double(partial)
            guard frequency < 2_600 else { break }
            let omega = 2 * Double.pi * frequency / clock.sampleRate
            guard omega < .pi * 0.54 else { break }
            var real = 0.0, imag = 0.0
            for i in 0..<size {
                let v = Double(lead.left[source + i] + lead.right[source + i]) * windows[i]
                real += v * cos(omega * Double(i))
                imag += v * sin(omega * Double(i))
            }
            let air = 1 / (1 + pow(frequency / 1_230, 3))
            let color = Float((partial == 1 ? 0.62 : 1.10 / sqrt(Double(partial))) * air)
            let strength = Float(hypot(real, imag) * 2 / Double(size)) * color * gain
            guard strength > 0.0004 else { continue }
            let pan = rng.rangeF(0.19...0.81)
            let detune = rng.range(-0.003...0.003)
            let phase = rng.range(0...(2 * .pi))
            for i in 0..<count {
                let u = Double(i) / Double(count - 1)
                let window = sin(.pi * u)
                let bend = sin(u * (7 + Double(partial))) * 0.22
                let wave = Float(sin(omega * (1 + detune) * Double(i) + phase + bend) * window * window)
                let shimmer = frequency < 750
                    ? 0.34 * Float(sin(2 * omega * (1 - detune) * Double(i) - phase + bend) * window * window * window) : 0
                result.left[start + i] += strength * (wave * pan + shimmer * (1 - pan))
                result.right[start + i] += strength * (wave * (1 - pan) + shimmer * pan)
            }
        }
    }
}
