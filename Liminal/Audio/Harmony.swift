import Foundation

/// Chord templates in scale-degree steps (decision D20). They work in any scale: a candidate is
/// accepted only if no two of its pitch classes are a semitone apart and none is a tritone over the pedal.
nonisolated enum ChordShape: UInt8, CaseIterable {
    case triad, sus2, sus4, add9, seventh, quartal, sixNine, openFifth

    var steps: [Int] {
        switch self {
        case .triad: return [0, 2, 4]
        case .sus2: return [0, 1, 4]
        case .sus4: return [0, 3, 4]
        case .add9: return [0, 2, 4, 8]
        case .seventh: return [0, 2, 4, 6]
        case .quartal: return [0, 3, 6]
        case .sixNine: return [0, 2, 4, 5, 8]
        case .openFifth: return [0, 4]
        }
    }

    /// Weight at low tension (index = rawValue) and at high tension.
    static let lowTension: [Float] = [1.1, 1.2, 0.8, 1.2, 0.4, 0.5, 0.4, 0.5]
    static let highTension: [Float] = [0.9, 0.6, 0.6, 1.0, 1.3, 1.1, 1.2, 0.15]
}

nonisolated struct Chord: Equatable {
    var rootDegree: Int
    var shape: ChordShape
    var steps: [Int] { shape.steps }
}

/// The shared harmony every layer reads (decision D19).
nonisolated struct HarmonicField: Equatable {
    private(set) var tonic: Int          // pitch class 0-11
    private(set) var mode: ScaleType
    var chord: Chord
    var pedalMIDI: Int                   // drone root
    private(set) var intervals: [Int]

    init(tonic: Int, mode: ScaleType, chord: Chord, pedalMIDI: Int) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.mode = mode
        self.chord = chord
        self.pedalMIDI = pedalMIDI
        self.intervals = mode.intervals
    }

    var degreeCount: Int { intervals.count }

    func pitchClass(degree: Int) -> Int {
        let n = intervals.count
        let o = Scale.floorDiv(degree, n)
        return (tonic + intervals[degree - o * n]) % 12
    }

    /// True scale degree to MIDI; octave 4 puts degree 0 at 60 + tonic.
    func midi(degree: Int, octave: Int) -> Int {
        let n = intervals.count
        let o = Scale.floorDiv(degree, n)
        return 12 * (octave + 1) + tonic + intervals[degree - o * n] + 12 * o
    }

    var scaleMask: UInt16 { mode.pitchClassMask(tonic: tonic) }

    /// Chord pitch classes in template order, deduplicated.
    var chordPitchClasses: [Int] { Self.pitchClasses(of: chord, tonic: tonic, intervals: intervals) }

    var chordMask: UInt16 {
        var m: UInt16 = 0
        for pc in chordPitchClasses { m |= 1 << UInt16(pc) }
        return m
    }

    var chordRootPitchClass: Int { pitchClass(degree: chord.rootDegree) }

    static func pitchClasses(of chord: Chord, tonic: Int, intervals: [Int]) -> [Int] {
        let n = intervals.count
        var out: [Int] = []
        for s in chord.steps {
            let d = chord.rootDegree + s
            let o = Scale.floorDiv(d, n)
            let pc = (tonic + intervals[d - o * n]) % 12
            if !out.contains(pc) { out.append(pc) }
        }
        return out
    }

    static func has(_ mask: UInt16, _ midi: Int) -> Bool { mask & (1 << UInt16(((midi % 12) + 12) % 12)) != 0 }

    func chordTones(in range: ClosedRange<Int>) -> [Int] {
        let m = chordMask
        return range.filter { Self.has(m, $0) }
    }

    func scaleTones(in range: ClosedRange<Int>) -> [Int] {
        let m = scaleMask
        return range.filter { Self.has(m, $0) }
    }

    func inScale(_ midi: Int) -> Bool { Self.has(scaleMask, midi) }
    func isChordTone(_ midi: Int) -> Bool { Self.has(chordMask, midi) }

    /// Nearest note in the chord (or scale); ties go down.
    func nearest(to midi: Int, chordTonesOnly: Bool) -> Int {
        let m = chordTonesOnly ? chordMask : scaleMask
        for d in 0...12 {
            if Self.has(m, midi - d) { return midi - d }
            if Self.has(m, midi + d) { return midi + d }
        }
        return midi
    }

    /// Scale degree (relative to degree 0 at octave 4) of the scale note nearest `midi`.
    func degree(nearest midi: Int) -> Int {
        let target = nearest(to: midi, chordTonesOnly: false)
        let n = intervals.count
        let rel = target - (60 + tonic)
        let o = Scale.floorDiv(rel, 12)
        let pcOffset = rel - o * 12
        let idx = intervals.firstIndex(of: pcOffset) ?? 0
        return o * n + idx
    }
}

nonisolated enum HarmonyChange {
    case chord(old: Chord, new: Chord)
    case key(old: HarmonicField, new: HarmonicField)
}

/// Chords, key wander and voice leading (decisions D20-D23).
nonisolated final class HarmonyEngine {
    private var rng: SeededRNG
    private(set) var palette: [ScaleType]
    private(set) var pinned: ScaleType?
    private(set) var field: HarmonicField
    private var roots: MarkovChain
    private var recentKeys: [(Int, ScaleType)] = []
    private(set) var pedalOnFifth = false

    init(rng: SeededRNG, palette: [ScaleType], pinned: ScaleType?) {
        var r = rng
        self.palette = palette.isEmpty ? [.major] : palette
        self.pinned = pinned
        let mode = pinned ?? r.pick(self.palette)
        let tonic = pinned != nil ? 0 : r.pick([0, 2, 5, 7, 9, 10, 3])
        self.rng = r
        let f = HarmonicField(tonic: tonic, mode: mode, chord: Chord(rootDegree: 0, shape: .openFifth),
                              pedalMIDI: HarmonyEngine.pedal(for: tonic))
        self.field = f
        self.roots = MarkovChain.chordRoots(degreeCount: mode.intervals.count)
        self.field.chord = tonicChord(in: f)
        recentKeys = [(tonic, mode)]
    }

    static func pedal(for pc: Int) -> Int { 36 + ((pc % 12) + 12) % 12 }   // 36...47

    func isValid(_ chord: Chord, in f: HarmonicField) -> Bool {
        let pcs = HarmonicField.pitchClasses(of: chord, tonic: f.tonic, intervals: f.intervals)
        guard pcs.count >= 2 else { return false }
        let pedal = f.pedalMIDI % 12
        for (i, a) in pcs.enumerated() {
            if (a - pedal + 12) % 12 == 6 { return false }
            for b in pcs[(i + 1)...] {
                let ic = min((a - b + 12) % 12, (b - a + 12) % 12)
                if ic == 1 { return false }
            }
        }
        return true
    }

    private func shapeWeights(_ tension: Float) -> [Float] {
        let t = min(max(tension, 0), 1)
        return (0..<ChordShape.allCases.count).map { ChordShape.lowTension[$0] * (1 - t) + ChordShape.highTension[$0] * t }
    }

    private func tonicChord(in f: HarmonicField) -> Chord {
        for shape in [ChordShape.add9, .sus2, .triad, .openFifth, .quartal] {
            let c = Chord(rootDegree: 0, shape: shape)
            if isValid(c, in: f) { return c }
        }
        return Chord(rootDegree: 0, shape: .openFifth)
    }

    /// Roots of the last chords in this key (newest last), for the anti-repetition rule below.
    private var recentRoots: [Int] = []

    /// Next chord: Markov root motion plus tension-weighted shape, filtered by the clash rule. A root used in
    /// the last three chords is refused 60 % of the time (decision D86), so the progression keeps visiting new
    /// degrees instead of circling one family of chords (seed 11 spent six minutes on V, vi and iii).
    func nextChord(tension: Float) -> Chord {
        let weights = shapeWeights(tension)
        for attempt in 0..<16 {
            let root = roots.next(using: &rng)
            if attempt < 12 && recentRoots.suffix(3).contains(root) && rng.chance(0.6) {
                roots.reset(to: field.chord.rootDegree)
                continue
            }
            let shape = ChordShape(rawValue: UInt8(rng.weighted(weights))) ?? .triad
            let c = Chord(rootDegree: root, shape: shape)
            if c != field.chord && isValid(c, in: field) { return c }
        }
        // Fallback: any valid shape on a different root, then the tonic chord.
        for root in 0..<field.degreeCount where root != field.chord.rootDegree {
            for shape in ChordShape.allCases {
                let c = Chord(rootDegree: root, shape: shape)
                if isValid(c, in: field) { return c }
            }
        }
        return tonicChord(in: field)
    }

    @discardableResult
    func apply(chord: Chord) -> HarmonyChange {
        let old = field.chord
        field.chord = chord
        roots.reset(to: chord.rootDegree)
        recentRoots.append(chord.rootDegree)
        if recentRoots.count > 4 { recentRoots.removeFirst() }
        return .chord(old: old, new: chord)
    }

    /// Mode brightness used to bias key moves (0 dark ... 1 bright).
    static func brightness(of mode: ScaleType) -> Float {
        switch mode {
        case .lydian: return 1.0
        case .major, .pentatonicMajor: return 0.8
        case .mixolydian, .yo: return 0.6
        case .dorian: return 0.4
        case .pentatonicMinor, .minor: return 0.2
        case .phrygian: return 0.0
        default: return 0.5
        }
    }

    /// Every (tonic, mode) of the palette that differs by at most one swapped note, weighted by the
    /// brightness bias (-1...1) and away from the last three keys. nil when pinned or nothing fits.
    func proposeKeyMove(brightnessBias: Float) -> HarmonicField? {
        guard pinned == nil else { return nil }
        let cur = field.scaleMask
        var cands: [(Int, ScaleType)] = []
        var weights: [Float] = []
        for mode in palette {
            for tonic in 0..<12 {
                if tonic == field.tonic && mode == field.mode { continue }
                let m = mode.pitchClassMask(tonic: tonic)
                // One changed note (2 bits) as before, or two (4 bits) at lower weight (decision D86): with only
                // one-note neighbours a 10-minute session stayed inside one family of keys and every minute
                // shared most of its pitch content with every other.
                let diff = (m ^ cur).nonzeroBitCount
                if diff > 4 { continue }
                var w = expf(1.6 * brightnessBias * (HarmonyEngine.brightness(of: mode) - 0.5) * 2)
                if diff > 2 { w *= 0.85 }
                if recentKeys.contains(where: { $0.0 == tonic && $0.1 == mode }) { w *= 0.15 }
                // The pedal moving is the more audible change (x2.5, was x1.2, decision D86): same-tonic modal
                // shifts kept a whole 10-minute render on one tonic.
                if tonic != field.tonic { w *= 2.5 }
                cands.append((tonic, mode)); weights.append(w)
            }
        }
        // Off-palette (style change) or stranded: move to the nearest palette keys instead.
        if cands.isEmpty || !palette.contains(field.mode) {
            cands.removeAll(); weights.removeAll()
            var best = Int.max
            for mode in palette {
                for tonic in 0..<12 where !(tonic == field.tonic && mode == field.mode) {
                    let d = (mode.pitchClassMask(tonic: tonic) ^ cur).nonzeroBitCount + (tonic == field.tonic ? 0 : 1)
                    if d < best { best = d; cands.removeAll(); weights.removeAll() }
                    if d == best { cands.append((tonic, mode)); weights.append(1) }
                }
            }
        }
        guard !cands.isEmpty else { return nil }
        let (tonic, mode) = cands[rng.weighted(weights)]
        var f = HarmonicField(tonic: tonic, mode: mode, chord: Chord(rootDegree: 0, shape: .openFifth),
                              pedalMIDI: HarmonyEngine.pedal(for: tonic))
        f.chord = tonicChord(in: f)
        return f
    }

    @discardableResult
    func apply(field new: HarmonicField) -> HarmonyChange {
        let old = field
        field = new
        pedalOnFifth = false
        roots = MarkovChain.chordRoots(degreeCount: new.degreeCount)
        roots.reset(to: new.chord.rootDegree)
        recentRoots = [new.chord.rootDegree]
        recentKeys.append((new.tonic, new.mode))
        if recentKeys.count > 3 { recentKeys.removeFirst() }
        return .key(old: old, new: field)
    }

    /// New style palette. Takes effect at the next key move; returns true if the current mode is not in it
    /// (the conductor then schedules a move at the next scene boundary).
    func setPalette(_ p: [ScaleType]) -> Bool {
        palette = p.isEmpty ? [.major] : p
        return pinned == nil && !palette.contains(field.mode)
    }

    /// Pin (or unpin with nil). Pinning moves to C <mode>. Returns the key change if the field changed.
    func setPinned(_ scale: ScaleType?) -> HarmonyChange? {
        pinned = scale
        guard let scale, scale != field.mode || field.tonic != 0 else { return nil }
        var f = HarmonicField(tonic: 0, mode: scale, chord: Chord(rootDegree: 0, shape: .openFifth), pedalMIDI: 36)
        f.chord = tonicChord(in: f)
        return apply(field: f)
    }

    /// Pedal on a given pitch class (the chord root, decision D73). Returns true if the pedal changed.
    func setPedal(pitchClass pc: Int) -> Bool {
        let target = HarmonyEngine.pedal(for: pc)
        pedalOnFifth = false
        guard target != field.pedalMIDI else { return false }
        field.pedalMIDI = target
        return true
    }

    /// Drone pedal on the tonic or (if in scale and harmless for the current chord) on the fifth.
    /// Returns true if the pedal changed.
    func setPedal(onFifth: Bool) -> Bool {
        let tonicPedal = HarmonyEngine.pedal(for: field.tonic)
        var target = tonicPedal
        if onFifth {
            let fifthPC = (field.tonic + 7) % 12
            var f = field
            f.pedalMIDI = HarmonyEngine.pedal(for: fifthPC)
            if HarmonicField.has(field.scaleMask, fifthPC) && isValid(field.chord, in: f) { target = f.pedalMIDI }
        }
        pedalOnFifth = target != tonicPedal
        guard target != field.pedalMIDI else { return false }
        field.pedalMIDI = target
        return true
    }

    /// Minimal-motion voice leading (decision D22): strictly ascending voices (no crossing), each moving at
    /// most 5 semitones if possible, preferring to cover every chord pitch class and the root.
    func voiceLead(from current: [Int], to chord: Chord, range: ClosedRange<Int>) -> [Int] {
        var f = field
        f.chord = chord
        let cands = f.chordTones(in: range)
        let k = current.count
        guard k > 0, cands.count >= k else { return current.map { f.nearest(to: $0, chordTonesOnly: true) } }
        let cur = current.sorted()
        let pcs = f.chordPitchClasses
        let rootPC = f.chordRootPitchClass
        for maxMove in [5, 7, 36] {
            var best: [Int] = []
            var bestCost = Double.infinity
            var pick = [Int](repeating: 0, count: k)
            func search(_ v: Int, _ start: Int, _ cost: Double) {
                if cost >= bestCost { return }
                if v == k {
                    var c = cost
                    var covered = Set<Int>()
                    for i in 0..<k { covered.insert(cands[pick[i]] % 12) }
                    let want = min(k, pcs.count)
                    c += 3.0 * Double(max(0, want - covered.count))
                    if !covered.contains(rootPC) { c += 2.0 }
                    for i in 1..<k {
                        let gap = cands[pick[i]] - cands[pick[i - 1]]
                        if gap < 3 { c += cands[pick[i - 1]] < 57 ? 4.0 : 1.5 }
                    }
                    if c < bestCost { bestCost = c; best = pick.map { cands[$0] } }
                    return
                }
                if start >= cands.count { return }
                for j in start..<cands.count {
                    if cands.count - j < k - v { break }
                    let move = abs(cands[j] - cur[v])
                    if move > maxMove { if cands[j] > cur[v] { break } else { continue } }
                    pick[v] = j
                    search(v + 1, j + 1, cost + Double(move))
                }
            }
            search(0, 0, 0)
            if !best.isEmpty { return best }
        }
        return cur.map { f.nearest(to: $0, chordTonesOnly: true) }
    }
}
