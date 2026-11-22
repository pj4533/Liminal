import Foundation

/// Guitar chord voicings from the phrase's own harmony (D128). Pitch classes come only from
/// `Harmony.notes(for: chordDegree, intervals: [0, 3, 7, 10, 14])`, which snaps every tone into the
/// phrase's scale, so a dorian IV becomes IV7/9 and a pentatonic iv a sus2 shape. No new harmony.
///
/// Rules every voicing keeps:
/// - adjacent strings 3 to 9 semitones apart, every pitch in `floor...ceiling` inside MIDI 45...72;
/// - three or more strings sound the third (or its scale substitute) and, when the chord has four
///   distinct classes, the seventh;
/// - no pitch class twice, except the root or fifth in a five-string voicing;
/// - never a plain major triad: a chord's major third always comes with its seventh or ninth, and the
///   strings never spell a bare major triad of their own;
/// - `avoid` (the melody pitch sounding then) is never doubled and the top string stays under it.
///
/// Candidates are enumerated and scored (closeness to the string count's shapes, compactness, top
/// note third > seventh > ninth, top near the ceiling); exact ties go to the seeded RNG.
nonisolated enum LofiStrumVoicing {
    /// Chord roles in `Harmony.notes` order.
    enum Role: Int, Sendable { case root, third, fifth, seventh, ninth }

    static let register = 45...72
    static let intervals = [0, 3, 7, 10, 14]
    static let gaps = 3...9

    /// Preferred shapes per string count, low to high, best first.
    static let shapes: [Int: [[Role]]] = [
        2: [[.seventh, .third], [.fifth, .root]],
        3: [[.third, .fifth, .seventh], [.fifth, .seventh, .third], [.root, .seventh, .third]],
        4: [[.root, .seventh, .third, .fifth], [.fifth, .seventh, .third, .fifth],
            [.root, .seventh, .third, .seventh], [.fifth, .root, .third, .seventh],
            [.root, .fifth, .seventh, .third], [.root, .seventh, .third, .ninth], [.fifth, .seventh, .third, .ninth]],
        5: [[.root, .fifth, .seventh, .third, .ninth], [.root, .fifth, .seventh, .third, .fifth],
            [.fifth, .root, .third, .seventh, .ninth], [.root, .seventh, .third, .fifth, .ninth]]
    ]

    /// The chord's distinct pitch classes, each with the first role it plays.
    static func classes(harmony: LofiScore.Harmony, chordDegree: Int) -> [(pitchClass: Int, role: Role)] {
        classes(fromRoleOrdered: harmony.notes(for: chordDegree, intervals: intervals))
    }

    /// Distinct classes of a role-ordered list (root, third, fifth, seventh, ninth; shorter is fine).
    static func classes(fromRoleOrdered tones: [Int]) -> [(pitchClass: Int, role: Role)] {
        var out: [(pitchClass: Int, role: Role)] = []
        for (index, tone) in tones.prefix(5).enumerated() {
            let pitchClass = ((tone % 12) + 12) % 12
            guard !out.contains(where: { $0.pitchClass == pitchClass }), let role = Role(rawValue: index) else { continue }
            out.append((pitchClass, role))
        }
        return out
    }

    /// MIDI pitches, low to high, or empty when no voicing of `strings` keeps every rule.
    static func voicing(harmony: LofiScore.Harmony, chordDegree: Int, strings: Int, floor: Int = 50,
                        ceiling: Int = 72, avoid: Int? = nil, random: inout MusicRNG) -> [Int] {
        voicing(classes: classes(harmony: harmony, chordDegree: chordDegree), strings: strings, floor: floor,
                ceiling: ceiling, avoid: avoid, random: &random)
    }

    static func voicing(classes chord: [(pitchClass: Int, role: Role)], strings: Int, floor: Int = 50,
                        ceiling: Int = 72, avoid: Int? = nil, random: inout MusicRNG) -> [Int] {
        guard (2...5).contains(strings), let rootClass = chord.first?.pitchClass else { return [] }
        let low = max(register.lowerBound, floor)
        var high = min(register.upperBound, ceiling)
        if let avoid { high = min(high, avoid - 1) }
        guard high - low >= 3 * (strings - 1) else { return [] }
        let roleOf = Dictionary(chord.map { ($0.pitchClass, $0.role) }, uniquingKeysWith: { first, _ in first })
        let pitches = (low...high).filter { roleOf[$0 % 12] != nil }
        let preferred = shapes[strings] ?? []
        var best: [[Int]] = []
        var bestCost = Double.infinity
        var current: [Int] = []

        func consider() {
            guard isValid(current, chord: chord, rootClass: rootClass, avoid: avoid) else { return }
            let roles = current.compactMap { roleOf[$0 % 12] }
            let rank = preferred.firstIndex(of: roles).map(Double.init) ?? 6
            let span = Double(current[current.count - 1] - current[0])
            let top: Double
            switch roles.last {
            case .third?: top = 0
            case .seventh?: top = 0.5
            case .ninth?: top = 1.0
            default: top = 1.6
            }
            let cost = 2 * rank + 0.15 * span + top + 0.25 * Double(high - current[current.count - 1])
            if cost < bestCost - 1e-9 {
                bestCost = cost
                best = [current]
            } else if abs(cost - bestCost) <= 1e-9 {
                best.append(current)
            }
        }

        func extend(from index: Int) {
            if current.count == strings { consider(); return }
            var j = index
            while j < pitches.count {
                let next = pitches[j]
                j += 1
                if let last = current.last {
                    let gap = next - last
                    if gap < gaps.lowerBound { continue }
                    if gap > gaps.upperBound { break }
                }
                current.append(next)
                extend(from: j)
                current.removeLast()
            }
        }
        extend(from: 0)
        guard !best.isEmpty else { return [] }
        return best.count == 1 ? best[0] : best[random.int(0...(best.count - 1))]
    }

    /// Whether `voicing` (low to high) keeps every rule for `chord`.
    static func isValid(_ voicing: [Int], chord: [(pitchClass: Int, role: Role)], rootClass: Int? = nil,
                        avoid: Int? = nil) -> Bool {
        guard voicing.count >= 2, let first = voicing.first, let last = voicing.last,
              register.contains(first), register.contains(last) else { return false }
        for (a, b) in zip(voicing, voicing.dropFirst()) where !gaps.contains(b - a) { return false }
        let roleOf = Dictionary(chord.map { ($0.pitchClass, $0.role) }, uniquingKeysWith: { first, _ in first })
        let roles = voicing.map { roleOf[$0 % 12] }
        guard roles.allSatisfy({ $0 != nil }) else { return false }
        let present = Set(roles.compactMap { $0 })
        if voicing.count >= 3 {
            guard present.contains(.third) || !chord.contains(where: { $0.role == .third }) else { return false }
            if chord.count >= 4, chord.contains(where: { $0.role == .seventh }), !present.contains(.seventh) {
                return false
            }
        }
        // No pitch class twice, except the root or fifth in a five-string voicing.
        var seen: [Int: Int] = [:]
        for pitch in voicing { seen[pitch % 12, default: 0] += 1 }
        for (pitchClass, count) in seen where count > 1 {
            let role = roleOf[pitchClass]
            guard voicing.count == 5, count == 2, role == .root || role == .fifth else { return false }
        }
        if isPlainMajorTriad(voicing) { return false }
        let root = rootClass ?? chord.first?.pitchClass ?? 0
        if let third = chord.first(where: { $0.role == .third }), (third.pitchClass - root + 12) % 12 == 4,
           present.contains(.third), !present.contains(.seventh), !present.contains(.ninth) {
            return false
        }
        if let avoid, voicing.contains(avoid) || last >= avoid { return false }
        return true
    }

    /// Whether the strings spell nothing but a major triad (any inversion or doubling).
    static func isPlainMajorTriad(_ voicing: [Int]) -> Bool {
        let set = Set(voicing.map { $0 % 12 })
        guard set.count == 3 else { return false }
        return set.contains { root in set == [root, (root + 4) % 12, (root + 7) % 12] }
    }

    /// The same chord one inversion lower: every string steps down to the next lower pitch of the
    /// voicing's own classes. If that leaves the gaps or `floor`, the top string moves under the others;
    /// failing both, the voicing is returned unchanged.
    static func inversionBelow(_ voicing: [Int], floor: Int = 50) -> [Int] {
        guard voicing.count >= 2 else { return voicing }
        let classes = Set(voicing.map { $0 % 12 })
        func fits(_ candidate: [Int]) -> Bool {
            guard let first = candidate.first, first >= max(floor, register.lowerBound) else { return false }
            return zip(candidate, candidate.dropFirst()).allSatisfy { gaps.contains($1 - $0) }
        }
        let stepped = voicing.map { pitch in
            ((pitch - 11)...(pitch - 1)).reversed().first { classes.contains(($0 % 12 + 12) % 12) } ?? pitch - 12
        }
        if fits(stepped) { return stepped }
        let rotated = [voicing[voicing.count - 1] - 12] + voicing.dropLast()
        if fits(rotated) { return rotated }
        return voicing
    }
}
