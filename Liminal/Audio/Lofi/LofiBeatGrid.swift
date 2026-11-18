import Foundation

/// Known-BPM 4/4 drum breaks. A multiband energy novelty curve checks the labeled grid
/// without straightening individual hits or deciding tempo from one loud snare.
nonisolated enum LofiBeatGrid {
    struct Measurement: Sendable {
        let beats: Int
        let framesPerBeat: Double
        let onsetPhaseMilliseconds: Double
        let beatSupport: Double
    }

    static func measure(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                        sampleRate: Double, bpm: Double) -> Measurement? {
        let expected = sampleRate * 60 / bpm
        let durationInBeats = Double(frames) / expected
        guard let beats = [4, 8, 16, 32, 64].min(by: { abs(Double($0) - durationInBeats) < abs(Double($1) - durationInBeats) }),
              abs(durationInBeats - Double(beats)) < 0.09 else { return nil }

        let hop = max(1, Int((sampleRate * 0.004).rounded()))
        let lowStep = Float(1 - exp(-2 * .pi * 155 / sampleRate))
        let midStep = Float(1 - exp(-2 * .pi * 2200 / sampleRate))
        var lo: Float = 0, mid: Float = 0
        var previous = SIMD3<Float>.zero
        var novelty: [Float] = []
        novelty.reserveCapacity(frames / hop)
        for start in stride(from: 0, to: frames - hop, by: hop) {
            var energy = SIMD3<Float>.zero
            for i in start..<(start + hop) {
                let x = (left[i] + right[i]) * 0.5
                lo += (x - lo) * lowStep
                mid += (x - mid) * midStep
                let bands = SIMD3(lo, mid - lo, x - mid)
                energy += bands * bands
            }
            let logEnergy = SIMD3(log1pf(1000 * energy.x / Float(hop)), log1pf(1000 * energy.y / Float(hop)),
                                  log1pf(1000 * energy.z / Float(hop)))
            let growth = logEnergy - previous
            novelty.append(max(0, growth.x) * 1.4 + max(0, growth.y) + max(0, growth.z) * 0.5)
            previous += (logEnergy - previous) * 0.5
        }
        guard let strongest = novelty.max(), strongest > 0.02 else { return nil }
        let framesPerBeat = Double(frames) / Double(beats)
        let radius = Int((0.052 * sampleRate / Double(hop)).rounded())
        func strength(near bin: Int, radius: Int) -> Float {
            let lo = max(0, bin - radius), hi = min(novelty.count - 1, bin + radius)
            return lo <= hi ? (novelty[lo...hi].max() ?? 0) : 0
        }
        let grid = (1..<beats).map { Int((Double($0) * framesPerBeat / Double(hop)).rounded()) }
        let phase = (-radius...radius).max { a, b in
            func score(_ phase: Int) -> Float {
                grid.reduce(0) { $0 + min(strength(near: $1 + phase, radius: 1), strongest * 0.50) }
            }
            return score(a) < score(b)
        } ?? 0
        let threshold = strongest * 0.13
        let support = Double(grid.filter { strength(near: $0, radius: radius) >= threshold }.count) / Double(grid.count)
        return .init(beats: beats, framesPerBeat: framesPerBeat,
                     onsetPhaseMilliseconds: Double(phase * hop) * 1000 / sampleRate, beatSupport: support)
    }
}
