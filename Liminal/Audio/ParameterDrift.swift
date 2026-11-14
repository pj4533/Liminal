import Foundation

/// Autonomous parameter drift using golden-ratio multi-sine oscillation.
/// Each channel drifts at incommensurable rates so channels never sync up.
/// Runs on conductor time (seconds, Double) so offline renders are exact.
nonisolated enum ParameterDrift {

    static let phi = 1.618033988749895

    /// A single drifting value with its own period and phase.
    struct Channel {
        let rate: Double          // radians per second of the fundamental
        let phase: Double

        /// - period: seconds of the fundamental; the two upper partials are at phi and phi^2 times faster.
        init(period: Double, phase: Double) {
            self.rate = 2 * Double.pi / max(0.01, period)
            self.phase = phase
        }

        /// -1...1 (approximately; the three partials sum to at most 1).
        func value(at time: Double) -> Float {
            let w1 = sin(time * rate + phase)
            let w2 = sin(time * rate * phi + phase * 2.3)
            let w3 = sin(time * rate * phi * phi + phase * 0.7)
            return Float((w1 + w2 * 0.6 + w3 * 0.4) / 2.0)
        }

        /// 0...1
        func unit(at time: Double) -> Float { 0.5 + 0.5 * value(at: time) }
    }

    /// `count` channels with periods spread over `periods` on a golden-ratio sequence, random phases.
    static func channels(_ count: Int, periods: ClosedRange<Double>, rng: inout SeededRNG) -> [Channel] {
        let span = periods.upperBound - periods.lowerBound
        let offset = rng.unitD()
        return (0..<count).map { i in
            let frac = (offset + Double(i) * (phi - 1)).truncatingRemainder(dividingBy: 1)
            return Channel(period: periods.lowerBound + span * frac, phase: rng.range(0...(2 * Double.pi)))
        }
    }

    /// Drift around a center value with a given range, clamped to 0...1.
    static func apply(center: Float, drift: Float, range: Float) -> Float {
        max(0, min(1, center + drift * range))
    }
}
