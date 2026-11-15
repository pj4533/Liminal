import Foundation

/// A style sets palette, weights and biases (decisions D32, D64).
nonisolated struct MusicStyle {
    enum ID: String, CaseIterable, Sendable {
        case drift, glass, deep, garden
        var title: String { rawValue.capitalized }
    }

    let id: ID
    let palette: [ScaleType]
    let kindWeights: [SceneKind: Float]
    /// Probability weight of a layer being picked into a scene (1 = neutral, below 1 also thins it).
    let layerWeights: [LayerID: Float]
    let registerBias: Int
    let brightnessBias: Float
    let formTempo: Double            // multiplies scene durations
    /// Shimmer return multiplier.
    let shimmer: Float
    /// Keys preset weights: felt (1:1), warm (1:2), hollow (1:3).
    let keysPresets: [Float]
    /// Probability that a scene uses pentatonic-feeling open chord shapes (lower tension).
    let tensionBias: Float

    func weight(_ id: LayerID) -> Float { layerWeights[id] ?? 1 }

    // All four styles are relaxing (decision D103): they differ in palette, layer weights and register, inside
    // the same dark, slow range. Glass is soft hollow tones in a long tail, no longer bright glass.
    static let drift = MusicStyle(
        id: .drift,
        palette: [.major, .lydian, .mixolydian, .dorian, .minor],
        kindWeights: [.stillness: 1, .drift: 1, .bloom: 1, .constellation: 1, .tide: 1],
        layerWeights: [:],
        registerBias: 0, brightnessBias: 0, formTempo: 1,
        shimmer: 1, keysPresets: [1, 0.7, 0.4], tensionBias: 0)

    static let glass = MusicStyle(
        id: .glass,
        palette: [.lydian, .major, .pentatonicMajor],
        kindWeights: [.stillness: 0.8, .drift: 0.9, .bloom: 1.1, .constellation: 1.0, .tide: 0.7],
        layerWeights: [.keys: 1.3, .grains: 1.4, .drips: 1.2, .pad: 0.9, .air: 0.8, .pluck: 0.7, .lead: 0.9],
        registerBias: 1, brightnessBias: 0.08, formTempo: 1.0,
        shimmer: 1.2, keysPresets: [0.5, 0.8, 1.2], tensionBias: -0.05)

    static let deep = MusicStyle(
        id: .deep,
        palette: [.minor, .dorian, .phrygian],
        kindWeights: [.stillness: 1.5, .drift: 1, .bloom: 0.6, .constellation: 0.3, .tide: 1.8],
        layerWeights: [.drone: 1.5, .pad: 1.5, .air: 1.8, .grains: 0.5, .drips: 0.6, .pluck: 0.5, .keys: 0.8],
        registerBias: -2, brightnessBias: -0.15, formTempo: 1.25,
        shimmer: 0.7, keysPresets: [1, 1, 0.2], tensionBias: 0.05)

    static let garden = MusicStyle(
        id: .garden,
        palette: [.pentatonicMajor, .yo, .pentatonicEgyptian, .hirajoshi],
        kindWeights: [.stillness: 0.8, .drift: 1, .bloom: 0.9, .constellation: 0.9, .tide: 0.7],
        layerWeights: [.pluck: 1.3, .drips: 1.2, .keys: 1.2, .pad: 0.8, .lead: 1.1, .grains: 0.8],
        registerBias: 1, brightnessBias: 0.05, formTempo: 1.0,
        shimmer: 0.9, keysPresets: [1, 0.8, 0.5], tensionBias: -0.1)

    static func style(_ id: ID) -> MusicStyle {
        switch id {
        case .drift: return .drift
        case .glass: return .glass
        case .deep: return .deep
        case .garden: return .garden
        }
    }
}

/// One section of the macro-form (decision D24).
nonisolated struct MusicScene {
    var index: Int
    var kind: SceneKind
    var startTime: Double
    var duration: Double
    var peak: Float                       // already scaled by the session curve
    var riseFraction: Float
    var fallFraction: Float
    var layers: Set<LayerID>
    var thresholds: [LayerID: Float]
    var brightness: Float                 // -1...1 bias
    /// Brightness bias for the beds (drone, pad), on the pre-calm scale (decision D94): the pad keeps its
    /// old colour per scene kind while everything pointed gets the darker `brightness`.
    var bedBrightness: Float = 0
    var registerShift: Int                // -5...+7 semitones (moves register windows, never transposes)
    var tension: Float
    var pedalOnFifth: Bool
    var keyMoveAtEnd = false

    static let floor: Float = 0.12

    var endTime: Double { startTime + duration }
    /// When the next scene's emerge begins: 60 % through this scene's dissolve.
    var handoffTime: Double { startTime + duration * (1 - 0.4 * Double(fallFraction)) }

    func progress(at t: Double) -> Float { Float(min(max((t - startTime) / duration, 0), 1)) }

    func arc(at t: Double) -> Float {
        let u = progress(at: t)
        if u < riseFraction { return 0.5 - 0.5 * cos(Float.pi * u / riseFraction) }
        if u > 1 - fallFraction { return 0.5 + 0.5 * cos(Float.pi * (u - (1 - fallFraction)) / fallFraction) }
        return 1
    }

    /// Intensity 0...1: floor + (peak - floor) * raised-cosine arc.
    func intensity(at t: Double) -> Float {
        MusicScene.floor + (peak - MusicScene.floor) * arc(at: t)
    }

    func phase(at t: Double) -> ScenePhase {
        let u = progress(at: t)
        if u < riseFraction { return .emerge }
        if u > 1 - fallFraction { return .dissolve }
        return .bloom
    }
}

/// Picks the sequence of scenes (section 6).
nonisolated final class SceneDirector {
    private var rng: MusicRNG
    var style: MusicStyle
    private var count = 0

    init(rng: MusicRNG, style: MusicStyle) {
        self.rng = rng
        self.style = style
    }

    static let transitions: [SceneKind: [SceneKind: Float]] = [
        .stillness: [.drift: 0.4, .tide: 0.25, .constellation: 0.25, .bloom: 0.1],
        .drift: [.bloom: 0.35, .constellation: 0.25, .tide: 0.2, .stillness: 0.2, .drift: 0.05],
        .bloom: [.stillness: 0.45, .drift: 0.2, .tide: 0.2, .constellation: 0.15],
        .constellation: [.drift: 0.3, .bloom: 0.3, .tide: 0.2, .stillness: 0.2],
        .tide: [.drift: 0.3, .bloom: 0.3, .constellation: 0.25, .stillness: 0.15],
    ]

    static let thresholdRanges: [LayerID: ClosedRange<Float>] = [
        // Lead, grains and pluck lower than the plan (0.35-0.6, 0.55-0.8, 0.4-0.65): with the plan's ranges
        // they sounded 12-16 % of a 30-minute session against 50-60 % for keys and drips (decision D71).
        .drone: 0...0, .pad: 0.15...0.3, .lead: 0.28...0.5, .keys: 0.25...0.45, .drips: 0.2...0.4,
        .air: 0.05...0.4, .grains: 0.42...0.65, .pluck: 0.25...0.45,
    ]

    /// Session curve: 0.7 ... 1.0, periods of 437 s and 1151 s, so blooms vary over 7-19 minutes.
    /// (Plan: 0.5 ... 1.0; narrowed in PASS 2, decision D70, so early scenes reach their feature layers.)
    static func sessionCurve(_ t: Double) -> Float {
        Float(0.85 + 0.15 * (0.6 * sin(2 * .pi * t / 437) + 0.4 * sin(2 * .pi * t / 1151)))
    }

    /// The struck layers (keys, drips, pluck): at most one of them per scene (decision D101).
    static let struck: [LayerID] = [.keys, .drips, .pluck]

    /// Melodic layer that "features" a scene, used to avoid featuring the same one twice.
    static func feature(of layers: Set<LayerID>) -> LayerID? {
        [LayerID.lead, .keys, .pluck, .drips, .grains].first { layers.contains($0) }
    }

    static func jaccardDistance(_ a: Set<LayerID>, _ b: Set<LayerID>) -> Float {
        let u = a.union(b).count
        guard u > 0 else { return 0 }
        return 1 - Float(a.intersection(b).count) / Float(u)
    }

    func next(after previous: MusicScene?, sessionTime: Double, density: Float, mood: VisualMood,
              available: Set<LayerID>, sceneWeights: [SceneKind: Float] = [:]) -> MusicScene {
        defer { count += 1 }
        let kind = chooseKind(after: previous?.kind, extra: sceneWeights)
        var layers = Set<LayerID>()
        var best: (Set<LayerID>, Float) = ([], -1)
        for _ in 0..<10 {
            let cand = layerSet(for: kind, available: available).intersection(available)
            guard let prev = previous else { best = (cand, 1); break }
            var score = SceneDirector.jaccardDistance(cand, prev.layers)
            let f = SceneDirector.feature(of: cand)
            if f != nil && f == SceneDirector.feature(of: prev.layers) { score -= 0.2 }
            if score > best.1 { best = (cand, score) }
            if score >= 0.34 { break }
        }
        layers = best.0
        if layers.isEmpty { layers = Set<LayerID>([.drone]).intersection(available) }

        // Calm form (decision D101): scenes 2-5 minutes, lower peaks, darker brightness biases.
        let (peakR, durR, bright, tension): (ClosedRange<Float>, ClosedRange<Double>, Float, Float) = {
            switch kind {
            case .stillness: return (0.2...0.35, 120...210, -0.3, 0.2)
            case .drift: return (0.4...0.6, 180...300, -0.1, 0.35)
            case .bloom: return (0.55...0.8, 180...300, 0.15, 0.5)
            case .constellation: return (0.4...0.6, 150...240, 0.05, 0.45)
            case .tide: return (0.4...0.6, 180...300, -0.2, 0.3)
            }
        }()
        // The beds' bias per kind before the calm retune (stillness -0.3, drift 0, bloom 0.5, constellation 0.3,
        // tide -0.2, jitter +-0.3).
        let bedBright: Float = [.stillness: -0.3, .drift: 0, .bloom: 0.5, .constellation: 0.3, .tide: -0.2][kind] ?? 0
        let jitter = rng.rangeF(-0.2...0.2)
        var peak = rng.rangeF(peakR) + (density - 0.5) * 0.3
        peak = min(max(peak * SceneDirector.sessionCurve(sessionTime), 0.18), 1)

        var thresholds: [LayerID: Float] = [:]
        for id in LayerID.allCases {
            let r = SceneDirector.thresholdRanges[id] ?? 0...0
            // Keep every scene layer reachable: threshold at most 85 % of the way to the peak.
            let reach = MusicScene.floor + (peak - MusicScene.floor) * 0.85
            thresholds[id] = min(rng.rangeF(r), reach)
        }
        thresholds[.drone] = 0
        // The first scene brings the pad in right behind the drone, so the app never opens on one layer.
        if count == 0 { thresholds[.pad] = MusicScene.floor + 0.01 }

        let shifts = [-5, -3, -2, 0, 0, 0, 0, 2, 3, 5, 7]
        var shift = rng.pick(shifts) + style.registerBias
        if kind == .stillness || kind == .tide { shift = min(shift, 2) }
        if kind == .bloom || kind == .constellation { shift = max(shift, -2) }

        return MusicScene(
            index: count, kind: kind, startTime: sessionTime,
            duration: rng.range(durR) * style.formTempo,
            peak: peak,
            riseFraction: rng.rangeF(0.3...0.45), fallFraction: rng.rangeF(0.3...0.45),
            layers: layers, thresholds: thresholds,
            brightness: min(max(bright + jitter + style.brightnessBias, -1), 1),
            bedBrightness: min(max(bedBright + 1.5 * jitter + style.brightnessBias, -1), 1),
            registerShift: min(max(shift, -5), 7),
            tension: min(max(tension + rng.rangeF(-0.15...0.15), 0), 1),
            pedalOnFifth: count > 0 && rng.chance(0.2))
    }

    private func chooseKind(after prev: SceneKind?, extra: [SceneKind: Float]) -> SceneKind {
        guard let prev else { return .drift }      // the app always starts gently
        let table = SceneDirector.transitions[prev] ?? [:]
        let kinds = SceneKind.allCases
        let w = kinds.map { (table[$0] ?? 0) * (style.kindWeights[$0] ?? 1) * (extra[$0] ?? 1) }
        return kinds[rng.weighted(w)]
    }

    /// Weighted draw (style layer weights) without replacement.
    private func draw(_ pool: inout [LayerID]) -> LayerID? {
        guard !pool.isEmpty else { return nil }
        let i = rng.weighted(pool.map { style.weight($0) })
        return pool.remove(at: i)
    }

    /// A layer with weight below 1 is sometimes left out even when the kind calls for it.
    private func keep(_ id: LayerID) -> Bool { rng.chance(min(1, style.weight(id))) }

    /// One struck layer (keys, drips or pluck), style-weighted, or nil.
    private func pickStruck(_ available: Set<LayerID>) -> LayerID? {
        var pool = SceneDirector.struck.filter { available.contains($0) }
        return draw(&pool)
    }

    /// Layer sets (decision D101): drone and usually pad, then at most one struck layer, optionally the lead
    /// and the mist. Stillness and tide no longer force a pointed voice (reverses D84); constellation is "a
    /// few soft lights": one struck layer and the mist.
    private func layerSet(for kind: SceneKind, available: Set<LayerID>) -> Set<LayerID> {
        var s: Set<LayerID> = [.drone]
        switch kind {
        case .stillness:
            if rng.chance(0.8 * min(1, style.weight(.air))) { s.insert(.air) }
            if rng.chance(0.85 * min(1, style.weight(.pad))) { s.insert(.pad) }
            let r = rng.unit()
            if r < 0.35, let k = pickStruck(available) { s.insert(k) } else if r < 0.6 { s.insert(.lead) }
        case .drift:
            if keep(.pad) || rng.chance(0.5) { s.insert(.pad) }
            var pool: [LayerID] = [.lead, .grains] + (pickStruck(available).map { [$0] } ?? [])
            if let f = draw(&pool) { s.insert(f) }
            if rng.chance(0.55), let f = draw(&pool) { s.insert(f) }
            if rng.chance(0.45 * style.weight(.air)) { s.insert(.air) }
        case .bloom:
            if keep(.pad) || keep(.pad) { s.insert(.pad) }
            if rng.chance(0.75 * min(1.2, style.weight(.lead))) { s.insert(.lead) }
            if rng.chance(0.8), let k = pickStruck(available) { s.insert(k) }
            if rng.chance(0.45 * style.weight(.grains)) { s.insert(.grains) }
            if rng.chance(0.5 * style.weight(.air)) { s.insert(.air) }
        case .constellation:
            if let k = pickStruck(available) { s.insert(k) }
            if rng.chance(0.75 * min(1.2, style.weight(.grains))) { s.insert(.grains) }
            if rng.chance(0.7 * style.weight(.pad)) { s.insert(.pad) }
            if rng.chance(0.3 * style.weight(.lead)) { s.insert(.lead) }
            if rng.chance(0.3 * style.weight(.air)) { s.insert(.air) }
        case .tide:
            if rng.chance(0.75 * min(1, style.weight(.air))) { s.insert(.air) }
            if keep(.pad) || rng.chance(0.5) { s.insert(.pad) }
            if rng.chance(0.3 * style.weight(.grains)) { s.insert(.grains) }
            if rng.chance(0.35 * style.weight(.lead)) { s.insert(.lead) }
        }
        // The pad is in every scene (D101, D106): the user likes the beds, and a scene of drone and air alone sat
        // 10-15 dB below the rest (loudness range 13-16 dB on glass and garden renders).
        if available.contains(.pad) { s.insert(.pad) }
        return s
    }
}
