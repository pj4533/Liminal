//
//  SmoothOscillator.swift
//  Liminal
//
//  Smooth, organic oscillation using multi-sine with golden ratio frequencies.
//  Creates non-repeating patterns that feel random but remain continuously smooth.
//

import Foundation

enum SmoothOscillator {

    /// Returns a smooth value 0-1 that cycles organically over time.
    /// Uses golden ratio frequency multiples for non-repeating patterns.
    /// - Parameter time: Current time in seconds
    /// - Returns: Value between 0 and 1
    static func value(at time: Float) -> Float {
        let phi: Float = 1.618034  // Golden ratio

        // Multiple sine waves at irrational frequency ratios
        let wave1 = sin(time * 0.1)              // Very slow base
        let wave2 = sin(time * 0.1 * phi)        // Golden ratio offset
        let wave3 = sin(time * 0.1 * phi * phi)  // Phi squared
        let wave4 = sin(time * 0.037)            // Arbitrary slow cycle

        // Combine with decreasing weights and normalize to 0-1
        let combined = (wave1 + wave2 * 0.7 + wave3 * 0.5 + wave4 * 0.6) / 2.8
        return (combined + 1) / 2  // Normalize -1..1 to 0..1
    }
}
