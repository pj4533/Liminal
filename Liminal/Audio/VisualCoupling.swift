import Foundation

/// Image-to-music mapping (plan section 8, decisions D29 and D63). Holds the smoothed `VisualMood`
/// and turns it into capped nudges that layers and the conductor read. The user's Style and Density
/// stay in charge: every nudge is bounded (brightness +-0.1 plus +-0.08 from words, density x0.7-1.4,
/// FM index x0.7-1.4, +-3 dB warmth tilt).
nonisolated struct VisualCoupling {
    /// Smoothed mood (8 s time constant on every scalar).
    private(set) var mood = VisualMood()
    private var target = VisualMood()
    /// Valence / energy nudges from mood words (-1...1), smoothed with the same time constant.
    private(set) var wordValence: Float = 0
    private(set) var wordEnergy: Float = 0
    private var wordTargetValence: Float = 0
    private var wordTargetEnergy: Float = 0
    /// Scene-kind weight multipliers from the current mood words (1 = neutral).
    private(set) var sceneWeights: [SceneKind: Float] = [:]
    /// Shimmer multiplier from mood words ("vast", "cosmic", ...), 1 = neutral.
    private(set) var wordShimmer: Float = 1

    mutating func setTarget(_ m: VisualMood) {
        target = m
        if m.moodWords != mood.moodWords {
            mood.moodWords = m.moodWords
            let r = VisualCoupling.interpret(m.moodWords)
            wordTargetValence = r.valence
            wordTargetEnergy = r.energy
            sceneWeights = r.scenes
            wordShimmer = r.shimmer
        }
    }

    /// 10 Hz.
    mutating func smooth(dt: Double) {
        let a = Float(1 - exp(-dt / 8))
        mood.brightness += (target.brightness - mood.brightness) * a
        mood.warmth += (target.warmth - mood.warmth) * a
        mood.saturation += (target.saturation - mood.saturation) * a
        mood.energy += (target.energy - mood.energy) * a
        wordValence += (wordTargetValence - wordValence) * a
        wordEnergy += (wordTargetEnergy - wordEnergy) * a
    }

    // MARK: Derived nudges

    /// Effective visual brightness 0...1 (luminance plus word valence).
    var brightness: Float { min(max(mood.brightness + 0.4 * wordValence * 0.5, 0), 1) }

    /// Added to the brightness macro: +-0.1 from luminance, +-0.08 from words.
    var brightnessNudge: Float { 0.2 * (mood.brightness - 0.5) + 0.08 * wordValence }

    /// Register shift 0...+4 semitones for bright images.
    var registerNudge: Int { Int((8 * max(0, brightness - 0.5)).rounded()) }

    /// Density multiplier x0.7-1.4 from contrast energy and word energy.
    var energyScale: Float {
        let e = min(max(mood.energy + 0.25 * wordEnergy, 0), 1)
        return e < 0.5 ? 0.7 + 0.6 * e : 1.0 + 0.8 * (e - 0.5)
    }

    /// FM index multiplier x0.7-1.4 from saturation (keys, drips).
    var fmScale: Float {
        let s = mood.saturation
        return s < 0.5 ? 0.7 + 0.6 * s : 1.0 + 0.8 * (s - 0.5)
    }

    /// Shimmer return multiplier: saturation, coolness and words (0.6 ... 1.6).
    var shimmerScale: Float {
        let cool = 1 - mood.warmth
        return min(max((0.8 + 0.4 * mood.saturation) * (0.8 + 0.4 * cool) * wordShimmer, 0.6), 1.6)
    }

    /// Warm images: drone up to +3 dB, air down; cool images the reverse (dB, -3...+3).
    var warmthDb: Float { 6 * (mood.warmth - 0.5) }

    /// Cool images favour open, suspended and quartal shapes: subtracted from chord tension.
    var coolness: Float { max(0, 0.5 - mood.warmth) * 2 }

    /// Key-move brightness bias contribution (-1...1).
    var keyBias: Float { min(max(1.2 * (brightness - 0.5) + 0.3 * wordValence, -1), 1) }

    // MARK: Mood words

    struct WordEffect {
        var valence: Float = 0
        var energy: Float = 0
        var scenes: [SceneKind: Float] = [:]
        var shimmer: Float = 1
    }

    /// Keyword table (lowercased substrings). Values are summed and capped, so several words reinforce.
    static let table: [(words: [String], valence: Float, energy: Float, scenes: [SceneKind: Float], shimmer: Float)] = [
        (["calm", "serene", "still", "quiet", "peace", "tranquil", "gentle", "soft", "mist", "fog"],
         0.1, -0.5, [.stillness: 1.6, .tide: 1.5, .bloom: 0.7], 1),
        (["vast", "cosmic", "space", "infinite", "galaxy", "nebula", "star", "sky", "ethereal", "heaven"],
         0.2, 0.2, [.bloom: 1.6, .constellation: 1.3], 1.4),
        (["dark", "ominous", "shadow", "night", "gloom", "storm", "abyss", "haunt", "melanchol", "somber"],
         -0.7, 0.1, [.tide: 1.4, .stillness: 1.2, .constellation: 0.8], 0.9),
        (["playful", "bright", "joy", "sun", "golden", "warm", "vivid", "bloom", "flower", "garden", "spring"],
         0.6, 0.4, [.constellation: 1.6, .bloom: 1.2, .stillness: 0.8], 1.1),
        (["ocean", "sea", "water", "wave", "river", "rain", "tide", "flow"],
         0, 0, [.tide: 1.7, .drift: 1.2], 1),
        (["crystal", "glass", "ice", "frost", "snow", "shimmer", "glow", "light"],
         0.3, 0.1, [.constellation: 1.4], 1.3),
        (["chaos", "energy", "electric", "fire", "wild", "dynamic", "intense"],
         0, 0.7, [.bloom: 1.5, .stillness: 0.6], 1.1),
        (["dream", "liminal", "surreal", "memory", "nostalg", "drift", "float"],
         0, -0.2, [.drift: 1.4, .tide: 1.2], 1.2),
    ]

    static func interpret(_ words: [String]) -> WordEffect {
        var out = WordEffect()
        guard !words.isEmpty else { return out }
        let text = words.joined(separator: " ").lowercased()
        var hits = 0
        for row in table where row.words.contains(where: { text.contains($0) }) {
            hits += 1
            out.valence += row.valence
            out.energy += row.energy
            out.shimmer *= row.shimmer
            for (k, w) in row.scenes { out.scenes[k, default: 1] *= w }
        }
        guard hits > 0 else { return out }
        out.valence = min(max(out.valence, -1), 1)
        out.energy = min(max(out.energy, -1), 1)
        out.shimmer = min(max(out.shimmer, 0.7), 1.5)
        for (k, w) in out.scenes { out.scenes[k] = min(max(w, 0.4), 2.5) }
        return out
    }
}
