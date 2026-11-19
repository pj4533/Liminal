import Foundation

/// ITU-R BS.1770-4 loudness of a stereo program (offline), with EBU Tech 3342 loudness range.
nonisolated enum LofiLoudness {
    struct Result: Sendable {
        /// Gated integrated loudness in LUFS (-infinity when nothing passes the absolute gate).
        let integrated: Double
        /// Largest 3 s short-term loudness.
        let shortTermMax: Double
        /// Largest 400 ms momentary loudness.
        let momentaryMax: Double
        /// Loudness range in LU (10th to 95th percentile of gated short-term values).
        let range: Double
    }

    private static func loudness(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    /// Per-100 ms hop sums of K-weighted channel power (left + right).
    static func hopEnergies(left: [Float], right: [Float], sampleRate: Double) -> (energies: [Double], hop: Int) {
        let hop = max(1, Int((sampleRate * 0.1).rounded()))
        let count = min(left.count, right.count)
        var lw = LofiKWeighting(sampleRate: sampleRate), rw = lw
        var energies = [Double]()
        energies.reserveCapacity(count / hop + 1)
        var accumulated = 0.0
        var inHop = 0
        for i in 0..<count {
            let a = left[i].isFinite ? Double(left[i]) : 0
            let b = right[i].isFinite ? Double(right[i]) : 0
            let l = lw.process(a), r = rw.process(b)
            accumulated += l * l + r * r
            inHop += 1
            if inHop == hop {
                energies.append(accumulated)
                accumulated = 0
                inHop = 0
            }
        }
        return (energies, hop)
    }

    /// Mean square of each window of `hops` consecutive 100 ms hops, advancing one hop at a time.
    private static func windows(_ energies: [Double], hops: Int, hop: Int) -> [Double] {
        guard energies.count >= hops else { return [] }
        var result = [Double]()
        result.reserveCapacity(energies.count - hops + 1)
        var running = energies[0..<hops].reduce(0, +)
        result.append(running / Double(hops * hop))
        for i in hops..<energies.count {
            running += energies[i] - energies[i - hops]
            result.append(max(0, running) / Double(hops * hop))
        }
        return result
    }

    static func measure(left: [Float], right: [Float], sampleRate: Double) -> Result {
        let (energies, hop) = hopEnergies(left: left, right: right, sampleRate: sampleRate)
        let momentary = windows(energies, hops: 4, hop: hop)
        let shortTerm = windows(energies, hops: 30, hop: hop)
        let absoluteGate = pow(10, (-70 + 0.691) / 10)

        // Integrated: 400 ms blocks with 75 percent overlap, absolute then relative (-10 LU) gate.
        let open = momentary.filter { $0 > absoluteGate }
        var integrated = -Double.infinity
        if !open.isEmpty {
            let relative = open.reduce(0, +) / Double(open.count) * pow(10, -10.0 / 10)
            let gated = open.filter { $0 > relative }
            if !gated.isEmpty { integrated = loudness(gated.reduce(0, +) / Double(gated.count)) }
        }

        // Range: short-term values, absolute gate, relative gate -20 LU, 10th to 95th percentile.
        var range = 0.0
        let stOpen = shortTerm.filter { $0 > absoluteGate }
        if !stOpen.isEmpty {
            let relative = stOpen.reduce(0, +) / Double(stOpen.count) * pow(10, -20.0 / 10)
            let values = stOpen.filter { $0 > relative }.map(loudness).sorted()
            if values.count > 1 {
                func percentile(_ p: Double) -> Double {
                    let position = p * Double(values.count - 1)
                    let lower = Int(position.rounded(.down)), upper = min(values.count - 1, lower + 1)
                    return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
                }
                range = percentile(0.95) - percentile(0.10)
            }
        }
        return Result(integrated: integrated,
                      shortTermMax: shortTerm.max().map(loudness) ?? -.infinity,
                      momentaryMax: momentary.max().map(loudness) ?? -.infinity,
                      range: range)
    }
}
