//
//  SeededRNG.swift
//  Liminal
//
//  Deterministic SplitMix64 generator, so a seeded picture rotation can be
//  reproduced (unit tests, -LiminalImageAPISeed).
//

import Foundation

nonisolated struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

nonisolated enum RandomDraw {
    /// Uniform Double in [0, 1). Uses 53 high bits, independent of stdlib internals.
    static func unit<R: RandomNumberGenerator>(_ rng: inout R) -> Double {
        Double(rng.next() >> 11) * 0x1p-53
    }

    /// Uniform Int in range.
    static func int<R: RandomNumberGenerator>(in range: ClosedRange<Int>, _ rng: inout R) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(rng.next() % span)
    }

    /// Picks one element. Array must be non-empty.
    static func element<T, R: RandomNumberGenerator>(_ items: [T], _ rng: inout R) -> T {
        items[Int(rng.next() % UInt64(items.count))]
    }

    /// Weighted choice. `weight` may return 0 for "excluded unless nothing else is left":
    /// if every weight is 0, `relaxed` is used instead so a draw always succeeds.
    static func weighted<T, R: RandomNumberGenerator>(
        _ items: [T],
        _ rng: inout R,
        weight: (T) -> Double,
        relaxed: (T) -> Double
    ) -> T {
        precondition(!items.isEmpty, "weighted draw from empty pool")
        var weights = items.map { max(0, weight($0)) }
        if weights.reduce(0, +) <= 0 {
            weights = items.map { max(0, relaxed($0)) }
        }
        let total = weights.reduce(0, +)
        if total <= 0 {
            return element(items, &rng)
        }
        var r = unit(&rng) * total
        for (index, w) in weights.enumerated() {
            r -= w
            if r < 0 { return items[index] }
        }
        return items[items.count - 1]
    }

    /// UUID built from the generator, so seeded batches are fully reproducible.
    static func uuid<R: RandomNumberGenerator>(_ rng: inout R) -> UUID {
        let a = rng.next(), b = rng.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((a >> (UInt64(i) * 8)) & 0xFF)
            bytes[i + 8] = UInt8((b >> (UInt64(i) * 8)) & 0xFF)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
