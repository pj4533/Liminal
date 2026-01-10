import Foundation
import Combine

/// Observable mood state that drives both audio and visual systems.
/// Users shape the experience through these abstract parameters.
@MainActor
final class MoodState: ObservableObject {

    // MARK: - Mood Parameters (0.0 to 1.0)

    /// Brightness: dark/mysterious (0) to light/hopeful (1)
    /// Affects: scale choice, filter cutoff, visual palette
    @Published var brightness: Float = 0.5

    /// Tension: relaxed/peaceful (0) to tense/dramatic (1)
    /// Affects: dissonance, note intervals, visual complexity
    @Published var tension: Float = 0.3

    /// Density: sparse/minimal (0) to dense/layered (1)
    /// Affects: note frequency, reverb mix, visual busyness
    @Published var density: Float = 0.4

    /// Movement: static/meditative (0) to flowing/dynamic (1)
    /// Affects: note change rate, Markov transitions
    @Published var movement: Float = 0.5

    // MARK: - Derived Values

    /// Suggested scale type based on mood
    var suggestedScale: ScaleType {
        if brightness < 0.3 {
            return tension > 0.5 ? .minor : .pentatonicMinor
        } else if brightness > 0.7 {
            return tension > 0.5 ? .lydian : .pentatonicMajor
        } else {
            return tension > 0.5 ? .dorian : .major
        }
    }

    /// Note change interval multiplier (0.5x to 2x speed)
    var tempoMultiplier: Float {
        // Higher movement = faster (lower multiplier = shorter intervals)
        return 2.0 - (movement * 1.5)  // Range: 0.5 to 2.0
    }

    /// Reverb mix based on density (more density = less reverb to avoid mud)
    var reverbMix: Float {
        return 0.4 + (1.0 - density) * 0.4  // Range: 0.4 to 0.8
    }

    /// Delay feedback based on movement (more movement = less delay tail)
    var delayFeedback: Float {
        return 0.4 + (1.0 - movement) * 0.3  // Range: 0.4 to 0.7
    }

    /// Filter cutoff based on brightness (brighter = higher cutoff)
    var filterCutoff: Float {
        return 2000 + brightness * 6000  // Range: 2000 to 8000 Hz
    }

    /// Shimmer note gap based on density (more dense = shorter gaps)
    var shimmerGap: ClosedRange<Double> {
        let minGap = 1.0 + (1.0 - Double(density)) * 2.0   // 1.0 to 3.0
        let maxGap = 3.0 + (1.0 - Double(density)) * 4.0   // 3.0 to 7.0
        return minGap...maxGap
    }

    // MARK: - Presets

    static let calm = MoodState().apply {
        $0.brightness = 0.6
        $0.tension = 0.2
        $0.density = 0.3
        $0.movement = 0.3
    }

    static let mysterious = MoodState().apply {
        $0.brightness = 0.2
        $0.tension = 0.5
        $0.density = 0.4
        $0.movement = 0.4
    }

    static let energetic = MoodState().apply {
        $0.brightness = 0.7
        $0.tension = 0.4
        $0.density = 0.6
        $0.movement = 0.7
    }

    // MARK: - Helpers

    func apply(_ configure: (MoodState) -> Void) -> MoodState {
        configure(self)
        return self
    }
}
