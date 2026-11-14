import AudioKit
import Foundation

/// Four band-limited additive wavetables for the pad's `MorphingOscillator`s (decision D18).
/// All stay below 12 harmonics, so a morph index anywhere in 0...3 never aliases in the pad register.
nonisolated enum PadTables {
    static let size = 4096

    /// harmonic number -> amplitude
    static func additive(_ partials: [(Int, Float)]) -> Table {
        var data = [Float](repeating: 0, count: size)
        for (n, a) in partials {
            let w = 2 * Float.pi * Float(n) / Float(size)
            for i in 0..<size { data[i] += a * sin(w * Float(i)) }
        }
        let peak = data.reduce(0) { max($0, abs($1)) }
        if peak > 0 { for i in 0..<size { data[i] /= peak } }
        return Table(data)
    }

    static let tables: [Table] = [
        additive([(1, 1)]),                                                     // 0 sine
        additive([(1, 1), (3, 1.0 / 9), (5, 1.0 / 25), (7, 1.0 / 49), (9, 1.0 / 81)]),   // 1 soft odd (1/n^2)
        additive((1...12).map { ($0, 1 / Float($0)) }),                         // 2 soft saw, 12 harmonics
        additive([(1, 0.7), (3, 0.5), (5, 0.6), (7, 0.22), (9, 0.08)]),         // 3 hollow with formant bump
    ]

    /// Soft drone table: fundamental with a little 2nd and 3rd.
    static let softDrone: Table = additive([(1, 1), (2, 0.18), (3, 0.07)])
}
