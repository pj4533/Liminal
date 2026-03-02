import Foundation

/// Autonomous parameter drift using golden-ratio multi-sine oscillation.
/// Each parameter drifts at incommensurable rates so they never sync up.
/// Produces values in 0...1 range that modulate around a center point.
final class ParameterDrift {

    /// A single drifting parameter with its own phase offsets and rates.
    struct Channel {
        let baseRate: Float       // Fundamental oscillation rate
        let phaseOffset: Float    // Unique phase offset

        /// Returns a drift value in -1...1 at the given time.
        func value(at time: Float) -> Float {
            let phi: Float = 1.618034

            let w1 = sin(time * baseRate + phaseOffset)
            let w2 = sin(time * baseRate * phi + phaseOffset * 2.3)
            let w3 = sin(time * baseRate * phi * phi + phaseOffset * 0.7)

            return (w1 + w2 * 0.6 + w3 * 0.4) / 2.0
        }
    }

    // MARK: - Channels

    /// Reverb mix drift — very slow, ±15%
    let reverbMix = Channel(baseRate: 0.07, phaseOffset: 0.0)

    /// Delay feedback drift — slow, ±15%
    let delayFeedback = Channel(baseRate: 0.05, phaseOffset: 1.7)

    /// Delay mix drift — slow, ±15%
    let delayMix = Channel(baseRate: 0.06, phaseOffset: 3.1)

    /// Filter cutoff drift — medium, drives spectral sweep
    let filterCutoff = Channel(baseRate: 0.04, phaseOffset: 5.3)

    /// Per-voice amplitude drift (bass, mid, shimmer) — prime-period based
    let bassAmplitude = Channel(baseRate: Float.pi / 17.0, phaseOffset: 0.0)
    let midAmplitude = Channel(baseRate: Float.pi / 23.0, phaseOffset: 2.1)
    let shimmerAmplitude = Channel(baseRate: Float.pi / 31.0, phaseOffset: 4.7)

    // MARK: - Helpers

    /// Apply drift around a center value with a given range.
    /// When center is 0, returns 0 (no drift when slider is off).
    static func apply(center: Float, drift: Float, range: Float) -> Float {
        guard center > 0.001 else { return 0 }
        return max(0, min(1, center + drift * range))
    }

    /// Apply drift for amplitude with custom min/max bounds.
    static func applyAmplitude(center: Float, drift: Float, low: Float, high: Float) -> Float {
        let halfRange = (high - low) / 2.0
        let mid = (high + low) / 2.0
        return max(low, min(high, mid + drift * halfRange))
    }
}
