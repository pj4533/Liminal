import Foundation

/// A short melodic idea in scale degrees, resolved through the HarmonicField at play time, so it
/// follows chord and key changes for free (section 7, decision D26).
nonisolated struct Motif: Equatable {
    var degrees: [Int]          // relative to degree 0 at octave 4 (tonic near middle C)
    var durations: [Double]     // seconds the gate is held
    var gaps: [Double]          // seconds from this onset to the next onset (last entry unused)

    var totalLength: Double { zip(durations, gaps).dropLast().reduce(0) { $0 + $1.1 } + (durations.last ?? 0) }
}

/// Develops motifs over time: transposition, inversion, retrograde, dropped notes, augmentation,
/// octave shifts, returns to the original and recalls of older motifs.
nonisolated struct MotifDeveloper {
    private(set) var original: Motif?
    private(set) var current: Motif?
    private var history: [Motif] = []
    /// Probability of resting a whole cycle (35-50 %, lower when dense).
    var restProbability: Float = 0.42
    /// Degree count of the current mode (7 or 5 typically).
    var degreeCount = 7

    /// Fresh motif: weighted random walk (70 % steps, 20 % thirds, 10 % fourths/fifths), 3-5 notes,
    /// starting and ending on chord tones.
    mutating func fresh(rng: inout MusicRNG, field: HarmonicField, center: Int) -> Motif {
        let n = rng.int(3...5)
        var d = field.degree(nearest: field.nearest(to: center, chordTonesOnly: true))
        var degrees: [Int] = [d]
        let third = 2, fourth = degreeCount >= 7 ? 3 : 2
        for i in 1..<n {
            let r = rng.unit()
            let step = r < 0.7 ? 1 : (r < 0.9 ? third : (rng.chance(0.5) ? fourth : fourth + 1))
            var dir = rng.chance(0.5) ? 1 : -1
            // Lean back toward the centre of the register.
            let m = field.midi(degree: d, octave: 4)
            if m > center + 7 { dir = -1 } else if m < center - 7 { dir = 1 }
            d += dir * step
            if i == n - 1 {
                // End on a chord tone.
                let mm = field.midi(degree: d, octave: 4)
                d = field.degree(nearest: field.nearest(to: mm, chordTonesOnly: true))
            }
            degrees.append(d)
        }
        let durations = (0..<n).map { _ in rng.chance(0.3) ? rng.range(1.8...3.2) : rng.range(0.6...1.6) }
        let gaps = durations.map { $0 + rng.range(0.15...1.2) }
        let m = Motif(degrees: degrees, durations: durations, gaps: gaps)
        original = m
        return m
    }

    mutating func next(rng: inout MusicRNG, field: HarmonicField, center: Int) -> Motif? {
        if rng.chance(restProbability) { return nil }
        guard let cur = current, let orig = original else {
            let m = fresh(rng: &rng, field: field, center: center)
            remember(m); return m
        }
        let r = rng.unit()
        var m: Motif
        switch r {
        case ..<0.25: m = orig                                         // return to the original
        case ..<0.42: m = transpose(cur, by: rng.pick([-2, -1, 1, 2]))
        case ..<0.52: m = invert(cur)
        case ..<0.60: m = retrograde(cur)
        case ..<0.70: m = drop(cur, rng: &rng)
        case ..<0.78: m = augment(cur)
        case ..<0.86: m = transpose(cur, by: rng.chance(0.5) ? degreeCount : -degreeCount)
        default:
            m = fresh(rng: &rng, field: field, center: center)
        }
        // Keep it in register.
        let mid = m.degrees.map { field.midi(degree: $0, octave: 4) }.reduce(0, +) / max(1, m.degrees.count)
        if mid > center + 9 { m = transpose(m, by: -degreeCount) } else if mid < center - 9 { m = transpose(m, by: degreeCount) }
        remember(m)
        return m
    }

    /// At a scene change: 30 % chance to recall one of the last four motifs as the new original.
    mutating func sceneChanged(rng: inout MusicRNG) {
        if history.count > 1 && rng.chance(0.3) {
            let m = history[rng.int(0...(history.count - 1))]
            original = m; current = m
        } else if rng.chance(0.5) {
            original = nil; current = nil      // start a fresh idea
        }
    }

    private mutating func remember(_ m: Motif) {
        current = m
        if history.last != m { history.append(m) }
        if history.count > 4 { history.removeFirst() }
    }

    private func transpose(_ m: Motif, by k: Int) -> Motif {
        Motif(degrees: m.degrees.map { $0 + k }, durations: m.durations, gaps: m.gaps)
    }
    private func invert(_ m: Motif) -> Motif {
        let a = m.degrees.first ?? 0
        return Motif(degrees: m.degrees.map { 2 * a - $0 }, durations: m.durations, gaps: m.gaps)
    }
    private func retrograde(_ m: Motif) -> Motif {
        Motif(degrees: m.degrees.reversed(), durations: m.durations.reversed(), gaps: m.gaps.reversed())
    }
    private func drop(_ m: Motif, rng: inout MusicRNG) -> Motif {
        guard m.degrees.count > 2 else { return m }
        var c = m
        let i = rng.int(1...(m.degrees.count - 1))
        c.degrees.remove(at: i); c.durations.remove(at: i); c.gaps.remove(at: i)
        return c
    }
    private func augment(_ m: Motif) -> Motif {
        Motif(degrees: m.degrees, durations: m.durations.map { min($0 * 2, 5) }, gaps: m.gaps.map { min($0 * 2, 6) })
    }
}
