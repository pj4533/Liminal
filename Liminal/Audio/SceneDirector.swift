import Foundation

/// A style sets palette, weights and biases (decision D32). PASS 1 ships only Drift.
nonisolated struct MusicStyle {
    enum ID: String, CaseIterable, Sendable { case drift, glass, deep, garden }

    let id: ID
    let palette: [ScaleType]
    let kindWeights: [SceneKind: Float]
    let layerWeights: [LayerID: Float]
    let registerBias: Int
    let brightnessBias: Float
    let formTempo: Double            // multiplies scene durations

    static let drift = MusicStyle(
        id: .drift,
        palette: [.major, .lydian, .mixolydian, .dorian, .minor],
        kindWeights: [.stillness: 1, .drift: 1, .bloom: 1, .constellation: 1, .tide: 1],
        layerWeights: [:],
        registerBias: 0, brightnessBias: 0, formTempo: 1)

    static func style(_ id: ID) -> MusicStyle {
        switch id {
        case .drift, .glass, .deep, .garden: return .drift   // PASS 2 adds the other three
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
    private var rng: SeededRNG
    var style: MusicStyle
    private var count = 0

    init(rng: SeededRNG, style: MusicStyle) {
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
        .drone: 0...0, .pad: 0.15...0.3, .lead: 0.35...0.6, .keys: 0.3...0.55, .drips: 0.25...0.5,
        .air: 0.05...0.4, .grains: 0.55...0.8, .pluck: 0.4...0.65,
    ]

    /// Session curve: 0.5 ... 1.0, periods of 437 s and 1151 s, so blooms vary over 7-19 minutes.
    static func sessionCurve(_ t: Double) -> Float {
        Float(0.75 + 0.25 * (0.6 * sin(2 * .pi * t / 437) + 0.4 * sin(2 * .pi * t / 1151)))
    }

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
              available: Set<LayerID>) -> MusicScene {
        defer { count += 1 }
        let kind = chooseKind(after: previous?.kind)
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

        let (peakR, durR, bright, tension): (ClosedRange<Float>, ClosedRange<Double>, Float, Float) = {
            switch kind {
            case .stillness: return (0.2...0.35, 45...90, -0.3, 0.2)
            case .drift: return (0.4...0.6, 90...180, 0, 0.35)
            case .bloom: return (0.7...1.0, 120...240, 0.5, 0.6)
            case .constellation: return (0.5...0.7, 90...150, 0.3, 0.5)
            case .tide: return (0.4...0.65, 80...140, -0.2, 0.3)
            }
        }()
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

        let shifts = [-5, -3, -2, 0, 0, 0, 0, 2, 3, 5, 7]
        var shift = rng.pick(shifts) + style.registerBias
        if kind == .stillness || kind == .tide { shift = min(shift, 2) }
        if kind == .bloom || kind == .constellation { shift = max(shift, -2) }

        return MusicScene(
            index: count, kind: kind, startTime: sessionTime,
            duration: rng.range(durR) * style.formTempo,
            peak: peak,
            riseFraction: rng.rangeF(0.3...0.5), fallFraction: rng.rangeF(0.25...0.4),
            layers: layers, thresholds: thresholds,
            brightness: min(max(bright + rng.rangeF(-0.3...0.3) + style.brightnessBias, -1), 1),
            registerShift: min(max(shift, -5), 7),
            tension: min(max(tension + rng.rangeF(-0.15...0.15), 0), 1),
            pedalOnFifth: count > 0 && rng.chance(0.2))
    }

    private func chooseKind(after prev: SceneKind?) -> SceneKind {
        guard let prev else { return .drift }      // the app always starts gently
        let table = SceneDirector.transitions[prev] ?? [:]
        let kinds = SceneKind.allCases
        let w = kinds.map { (table[$0] ?? 0) * (style.kindWeights[$0] ?? 1) }
        return kinds[rng.weighted(w)]
    }

    private func layerSet(for kind: SceneKind, available: Set<LayerID>) -> Set<LayerID> {
        var features: [LayerID] = [.lead, .keys, .drips, .pluck, .grains].filter { available.contains($0) }
        if features.isEmpty { features = [.lead] }
        switch kind {
        case .stillness:
            var s: Set<LayerID> = [.drone, .air]
            if rng.chance(0.35) { s.insert(.drips) }
            return s
        case .drift:
            return [.drone, .pad, rng.pick(features)]
        case .bloom:
            var s: Set<LayerID> = [.drone, .pad]
            var pool: [LayerID] = [.lead, .keys, .drips, .air, .grains, .pluck].filter { available.contains($0) }
            for _ in 0..<rng.int(2...4) where !pool.isEmpty {
                s.insert(pool.remove(at: rng.int(0...(pool.count - 1))))
            }
            if rng.chance(0.6) { s.insert(.lead) }
            if rng.chance(0.5) { s.insert(.drips) }
            return s
        case .constellation:
            var s: Set<LayerID> = [.drone]
            var pool: [LayerID] = [.keys, .drips, .grains, .pluck].filter { available.contains($0) }
            for _ in 0..<rng.int(2...3) where !pool.isEmpty { s.insert(pool.remove(at: rng.int(0...(pool.count - 1)))) }
            s.insert(.drips)   // always at least one point source that exists in PASS 1
            if rng.chance(0.5) { s.insert(.pad) }
            return s
        case .tide:
            return [.drone, .pad, .air]
        }
    }
}
