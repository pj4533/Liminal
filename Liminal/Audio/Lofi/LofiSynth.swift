import Foundation

/// Synthesizes the bass and background swells. The lead is rendered from recordings.
nonisolated enum LofiSynth {
    static func add(_ note: LofiScore.Note, clock: LofiClock,
                    left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        if note.part == .bass {
            LofiBassVoice.add(note, voice: .classic, clock: clock, left: left, right: right)
            return
        }
        let start = clock.frame(at: note.beat)
        let span = clock.frame(at: note.length)
        let frequency = 440 * pow(2, Double(note.midi - 69) / 12)
        let rate = clock.sampleRate
        let omega = 2 * Double.pi * frequency / rate
        let attack: Double, release: Double, gain: Float, pan: Float
        switch note.part {
        case .texture: (attack, release, gain, pan) = (1.35, 2.7, 0.076, Float(note.midi % 5 - 2) * 0.28)
        case .lead, .bass: (attack, release, gain, pan) = (0.020, 0.45, 0.105, 0) // bass returned above
        }
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
            let wave: Double
            switch note.part {
            case .texture:
                let swell = 0.5 + 0.5 * sin(t * 0.72 + Double(note.midi))
                let p = phase + 0.22 * sin(t * 3.2)
                let harmonic = sin(p) + sin(p * 1.004) + sin(p * 0.997)
                let air = sin(2.008 * p) + 0.32 * sin(3.01 * p + sin(t * 1.9))
                wave = harmonic * 0.25 + air * (0.08 + 0.15 * swell)
            case .lead, .bass: wave = (sin(phase) + 0.15 * sin(2 * phase) * exp(-t * 5)) * exp(-t * 0.8)
            }
            let value = Float(wave * rise * rise * fall * fall * edge) * gain * note.velocity
            left[start + i] += value * a
            right[start + i] += value * b
        }
    }

}
