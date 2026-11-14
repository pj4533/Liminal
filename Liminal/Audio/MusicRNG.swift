import Foundation

/// Deterministic SplitMix64 generator. One root per engine, forked per subsystem (decision D8),
/// so adding a layer never changes the random stream of the others.
nonisolated struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed ^ 0x6A09E667F3BCC909 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Independent stream derived from this generator's current state and a label. Does not advance self.
    func fork(_ label: UInt64) -> SeededRNG {
        var r = SeededRNG(seed: state ^ (label &* 0xD1B54A32D192ED03) ^ 0x5851F42D4C957F2D)
        _ = r.next()
        return r
    }

    /// 0..<1
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    /// 0..<1, double precision
    mutating func unitD() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * unitD() }
    mutating func rangeF(_ r: ClosedRange<Float>) -> Float { r.lowerBound + (r.upperBound - r.lowerBound) * unit() }
    mutating func int(_ r: ClosedRange<Int>) -> Int {
        let span = UInt64(r.upperBound - r.lowerBound + 1)
        return r.lowerBound + Int(next() % span)
    }
    mutating func chance(_ p: Float) -> Bool { unit() < p }
    /// Index chosen with probability proportional to weight. Returns 0 for empty/zero weights.
    mutating func weighted(_ weights: [Float]) -> Int {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return 0 }
        var x = unit() * total
        for (i, w) in weights.enumerated() where w > 0 {
            x -= w
            if x <= 0 { return i }
        }
        return weights.count - 1
    }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    /// Symmetric jitter: value * (1 +- amount)
    mutating func jitter(_ value: Double, _ amount: Double) -> Double { value * (1 + range(-amount...amount)) }
}
