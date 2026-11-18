import Foundation

nonisolated enum MusicMode: String, CaseIterable, Codable, Sendable {
    case ambient, lofi

    var title: String { self == .ambient ? "Ambient" : "Lo-Fi" }
}

nonisolated struct LofiOptions: Codable, Equatable, Sendable {
    var tempo = 69.0
    var scale: ScaleType? = nil

    static let tempos = 58.0...82.0

    var safeTempo: Double { tempo.isFinite ? min(max(tempo, Self.tempos.lowerBound), Self.tempos.upperBound) : 69 }
}

/// New targets every few bars, with each parameter following its own gradual curve.
/// Absolute beat positions keep both sides of a scheduled phrase boundary in sync.
nonisolated struct LofiDrift: Sendable {
    let seed: UInt64

    struct Values: Sendable, Equatable {
        let density: Float
        let dust: Float
        let space: Float
    }

    func at(_ beat: Double) -> Values {
        Values(density: curve(beat, every: 11, stream: 2, range: 0.32...0.61),
               dust: curve(beat, every: 17, stream: 3, range: 0.08...0.24),
               space: curve(beat, every: 15, stream: 4, range: 0.28...0.57))
    }

    private func curve(_ beat: Double, every span: Double, stream: UInt64, range: ClosedRange<Float>) -> Float {
        let position = beat / span
        let segment = UInt64(position)
        let fraction = Float(position - Double(segment))
        let weight = fraction * fraction * (3 - 2 * fraction)
        let root = MusicRNG(seed: seed).fork(stream)
        var start = root.fork(segment)
        var end = root.fork(segment + 1)
        let a = start.rangeF(range), b = end.rangeF(range)
        return a + (b - a) * weight
    }
}

/// Quantize the four-bar span once and use the same grid for every stem and repeat.
nonisolated struct LofiClock: Sendable {
    static let beats = 16.0
    static let footageEchoBeats = 1.0
    static let footageReflectionBeats = 0.5
    static let musicEchoBeats = (left: 0.75, right: 1.25)
    let frameCount: Int
    let sampleRate: Double
    var framesPerBeat: Double { Double(frameCount) / Self.beats }
    var beatDuration: Double { framesPerBeat / sampleRate }

    init(tempo: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        frameCount = Int((sampleRate * 60 / tempo * Self.beats).rounded())
    }

    func frame(at beat: Double) -> Int { Int((beat * framesPerBeat).rounded()) }
}

nonisolated struct LofiScore: Sendable, Equatable {
    enum Part: Int, Sendable { case texture, bass, lead }
    enum Section: Int, Sendable { case theme, answer, breakdown, returnTheme, variation }

    struct Note: Equatable, Sendable {
        let part: Part
        let midi: Int
        let beat: Double
        let length: Double
        let velocity: Float
        var color: Double = 0.5
        var send: Float = 0.35
    }

    let section: Section
    let tonic: Int
    let scale: ScaleType
    let notes: [Note]
    let preset: LofiPreset
    /// Dry foreground rests and new musical sends taper before this planned opening.
    let foregroundSpace: ClosedRange<Double>
    let virtualRecord: LofiVirtualRecord.Edit?

    static let phrasesPerForm = 8

    /// Each intact sixteen-bar drum break has a call, open space, variation and actual return.
    static func section(at phrase: Int) -> Section {
        [.theme, .breakdown, .variation, .returnTheme,
         .theme, .answer, .breakdown, .returnTheme][phrase % phrasesPerForm]
    }

    static func make(seed: UInt64, section: Section, drift: LofiDrift, startBeat: Double,
                     pinnedScale: ScaleType? = nil) -> Self {
        let phrase = Int(startBeat / LofiClock.beats)
        let position = phrase % phrasesPerForm
        let record = position / 4
        let root = MusicRNG(seed: seed)
        var harmonyRandom = root.fork(145)
        let tonic = pinnedScale == nil ? harmonyRandom.pick([0, 2, 3, 5, 7, 9]) : 0
        let scale = pinnedScale ?? harmonyRandom.pick([.minor, .minor, .dorian, .pentatonicMinor])
        let harmony = Harmony(tonic: tonic, scale: scale)
        let preset = LofiPreset.selection(seed: drift.seed, phrase: phrase)
        let motifRandom = root.fork(UInt64(record) + 206)
        let theme = motif(harmony: harmony, preset: preset, random: motifRandom)
        let phraseRandom = root.fork(UInt64(position) + 618)
        let space = section == .breakdown ? 2.0...15.5 : 9.0...15.5
        let lead: [Note]
        switch section {
        case .variation:
            lead = vary(theme, harmony: harmony, random: phraseRandom)
        case .theme, .returnTheme:
            lead = theme
        case .answer:
            lead = answer(to: theme, harmony: harmony)
        case .breakdown:
            lead = []
        }

        let bass = bassLine(harmony: harmony, section: section, random: phraseRandom)
        let texture = shell(harmony: harmony, section: section, firstLead: lead.first,
                            random: phraseRandom)
        let notes = (bass + texture + lead).sorted { lhs, rhs in
            if lhs.beat != rhs.beat { return lhs.beat < rhs.beat }
            if lhs.part != rhs.part { return lhs.part.rawValue < rhs.part.rawValue }
            return lhs.midi < rhs.midi
        }
        var edits = phraseRandom.fork(945)
        let virtualRecord = LofiVirtualRecord.choose(from: lead, before: space.lowerBound, section: section,
                                                     program: preset.sampleGroup, seed: edits.next())
        return .init(section: section, tonic: tonic, scale: scale, notes: notes,
                     preset: preset, foregroundSpace: space, virtualRecord: virtualRecord)
    }

    private struct Harmony {
        let tonic: Int
        let scale: ScaleType

        func pitches(in register: ClosedRange<Int>) -> [Int] {
            let classes = scale.pitchClassMask(tonic: tonic)
            return register.filter { classes & (1 << ($0 % 12)) != 0 }
        }

        func nearest(_ target: Int, in candidates: [Int]) -> Int {
            candidates.min { abs($0 - target) < abs($1 - target) } ?? target
        }

        func notes(for root: Int, intervals: [Int]) -> [Int] {
            let relative = scale.intervals
            return intervals.map { ideal in
                let pitchClass = (root + ideal) % 12
                let compatible = relative.filter { $0 != root || ideal == 0 }
                let matchingThird = ideal == 3 && relative.contains((root + 4) % 12) ? (root + 4) % 12 : pitchClass
                let target = relative.contains(pitchClass) ? pitchClass : matchingThird
                let pitch = compatible.min { chromaticDistance($0, target) < chromaticDistance($1, target) } ?? root
                return (tonic + pitch) % 12
            }
        }

        private func chromaticDistance(_ a: Int, _ b: Int) -> Int {
            min(abs(a - b), 12 - abs(a - b))
        }

        func bass(_ offset: Int, near center: Int = 34) -> Int {
            let pitchClass = (tonic + nearest(offset, in: scale.intervals)) % 12
            return nearest(center, in: (28...41).filter { $0 % 12 == pitchClass })
        }
    }

    private static func motif(harmony: Harmony, preset: LofiPreset, random: MusicRNG) -> [Note] {
        var rhythm = random.fork(77)
        var pitch = random.fork(88)
        var articulation = random.fork(99)
        let count = rhythm.pick([3, 4, 4])
        let rotation = rhythm.pick([0, 1, 2, 3, 5, 6, 7])
        // A rotated even distribution supplies candidates over two bars; the remaining bars
        // belong to the drummer, bass and effect returns. Slight shared lag leaves their feel intact.
        let slots = (0..<count).map { (1 + $0 * 16 / count + rotation) % 16 }.sorted()
        let lag = rhythm.range(0.015...0.050)
        let sync = rhythm.pick([0.0, 0.0, 0.25])
        let beats = slots.map { 0.5 + Double($0) * 0.5 + lag + sync }
        let anchor = harmony.nearest(61, in: (55...67).filter { $0 % 12 == harmony.tonic })
        let contour = count == 3
            ? pitch.pick([[7, 3, 0], [3, 5, 0], [5, 2, 0], [-5, -2, 0]])
            : pitch.pick([[7, 5, 3, 0], [3, 7, 5, 0], [5, 2, 3, 0], [-5, 0, 3, 0]])
        let choices = harmony.pitches(in: 50...69)
        let chord = harmony.notes(for: 0, intervals: [0, 3, 7])
        let candidates = contour.dropLast().enumerated().map { index, offset in
            let prefer = anchor + offset
            let available = index == 0 ? choices.filter { chord.contains($0 % 12) } : choices
            return available.filter { abs($0 - prefer) <= 6 }
        }
        let path = viablePitches(candidates, anchor: anchor, targets: contour.map { anchor + $0 })
        let pitches = path ?? Array(repeating: anchor, count: count)
        let plucked = preset.family == .strings
        return beats.indices.map { index in
            let arrival = index == beats.count - 1
            return .init(part: .lead, midi: pitches[index], beat: beats[index],
                         length: arrival ? articulation.range(0.44...0.69)
                             : articulation.range(plucked ? 0.25...0.47 : 0.36...0.62),
                         velocity: articulation.rangeF(arrival ? 0.57...0.66 : 0.48...0.65),
                         color: articulation.range(0.36...0.59),
                         send: arrival ? 0.77 : (index == 0 ? 0.43 : 0.24))
        }
    }

    /// Work backward from the terminal pitch before choosing any note. A candidate that
    /// cannot connect to the destination never enters the forward pass.
    private static func viablePitches(_ candidates: [[Int]], anchor: Int, targets: [Int]) -> [Int]? {
        var viable = [[anchor]]
        for (index, allowed) in candidates.enumerated().reversed() {
            let reach = index == candidates.count - 1 ? 4 : 5
            let next = viable.last ?? [anchor]
            viable.append(allowed.filter { note in next.contains { abs($0 - note) <= reach } })
        }
        var pitches: [Int] = []
        for (index, allowed) in viable.reversed().enumerated() {
            let eligible = allowed.filter { note in pitches.last.map { abs($0 - note) <= (index == candidates.count ? 4 : 5) } ?? true }
            guard let best = eligible.min(by: {
                pitchCost($0, target: targets[index], previous: pitches.last)
                    < pitchCost($1, target: targets[index], previous: pitches.last)
            }) else { return nil }
            pitches.append(best)
        }
        return pitches
    }

    private static func pitchCost(_ pitch: Int, target: Int, previous: Int?) -> Int {
        3 * abs(pitch - target) + (pitch == previous ? 4 : 0)
    }

    private static func vary(_ theme: [Note], harmony: Harmony, random: MusicRNG) -> [Note] {
        var memory = random.fork(109)
        var changed = theme
        let lastInterior = theme.count - 2
        let index = memory.int(1...lastInterior)
        let note = theme[index]
        let previous = theme[index - 1]
        let next = theme[index + 1]
        switch memory.int(0...2) {
        case 0:
            if abs(previous.midi - next.midi) <= (index == lastInterior ? 4 : 5) {
                changed.remove(at: index)
                return changed
            }
        case 1:
            let options = harmony.pitches(in: 50...69).filter {
                $0 != note.midi && abs($0 - note.midi) <= 3 && abs($0 - previous.midi) <= 5 &&
                    abs($0 - next.midi) <= (index == lastInterior ? 4 : 5)
            }
            if !options.isEmpty {
                changed[index] = .init(part: .lead, midi: memory.pick(options), beat: note.beat, length: note.length,
                                       velocity: note.velocity, color: note.color, send: note.send)
                return changed
            }
        default: break
        }
        // At least two eighths separate the theme's attacks, so a sixteenth shift preserves space.
        changed[index] = .init(part: .lead, midi: note.midi, beat: note.beat + 0.25, length: note.length,
                               velocity: note.velocity, color: note.color, send: note.send)
        return changed
    }

    private static func answer(to theme: [Note], harmony: Harmony) -> [Note] {
        let opening = theme[0]
        let arrival = theme[theme.count - 1]
        let low = harmony.nearest(arrival.midi - 5, in: harmony.pitches(in: 50...59))
        let approach = harmony.nearest(low + 3, in: harmony.pitches(in: 50...63).filter { $0 != low })
        return [
            .init(part: .lead, midi: approach, beat: opening.beat + 0.5, length: opening.length,
                  velocity: opening.velocity * 0.84, color: opening.color, send: 0.37),
            .init(part: .lead, midi: low, beat: min(8, arrival.beat), length: arrival.length,
                  velocity: arrival.velocity * 0.88, color: arrival.color, send: 0.64)
        ]
    }

    private static func bassLine(harmony: Harmony, section: Section, random: MusicRNG) -> [Note] {
        var rhythm = random.fork(124)
        let related = rhythm.pick([3, 5, 7, 8, 10])
        let home = harmony.bass(0)
        let motion = harmony.bass(related, near: home)
        let fifth = harmony.bass(7, near: home - 2)
        let pocket = rhythm.range(0.017...0.045)
        let figures: [(beat: Double, length: Double, midi: Int, strength: Float)]
        switch section {
        case .breakdown:
            figures = [(0, 1.65, motion, 0.76), (8, 1.05, home, 0.73)]
        case .answer:
            figures = [(0, 1.45, harmony.bass(5, near: home), 0.80), (4.5, 1.10, fifth, 0.72), (8, 1.35, home, 0.76)]
        case .returnTheme:
            figures = [(0, 1.8, home, 0.85), (4, 1.15, fifth, 0.75), (8, 1.60, home, 0.80)]
        case .theme, .variation:
            let pickup = rhythm.pick([5.5, 6.75, 7.5])
            figures = [(0, 1.7, home, 0.82), (pickup, 0.55, fifth, 0.63), (8, 1.45, home, 0.80)]
                + (section == .variation ? [(11.5, 0.65, motion, 0.67)] : [])
        }
        return figures.map { figure in
            .init(part: .bass, midi: figure.midi, beat: figure.beat + (figure.beat == 0 ? 0 : pocket),
                  length: figure.length, velocity: figure.strength, send: 0)
        }
    }

    private static func shell(harmony: Harmony, section: Section, firstLead: Note?,
                              random: MusicRNG) -> [Note] {
        guard section == .theme || section == .variation || section == .answer, let firstLead else { return [] }
        var timing = random.fork(136)
        let guide = (lower: 49, upper: 55)
        let home = voicing(for: 0, previous: guide, harmony: harmony)
        let root = harmony.nearest(5, in: harmony.scale.intervals)
        let voices = section == .answer ? voicing(for: root, previous: home, harmony: harmony) : home
        // Roll one short shell into the space before the melody. If the melody already
        // claims the entrance, leave that shell out instead of stacking more midrange.
        let duration = section == .variation ? 0.76 : 0.94
        let beat = 0.26
        guard beat + duration + 0.57 < firstLead.beat else { return [] }
        return [voices.lower, voices.upper].enumerated().map { index, pitch in
            .init(part: .texture, midi: pitch, beat: beat + Double(index) * 0.13, length: duration,
                  velocity: timing.rangeF(0.30...0.40), color: 0.40, send: 0.27)
        }
    }

    private static func voicing(for root: Int, previous: (lower: Int, upper: Int),
                                harmony: Harmony) -> (lower: Int, upper: Int) {
        let pitches = harmony.notes(for: root, intervals: [3, 7])
        let register = 45...62
        let choices = register.filter { pitches.contains($0 % 12) }
        let pairs = choices.flatMap { lower in
            choices.filter { $0 - lower >= 3 && $0 - lower <= 10 }.map { (lower: lower, upper: $0) }
        }
        func cost(_ pair: (lower: Int, upper: Int)) -> Int {
            3 * (abs(pair.lower - previous.lower) + abs(pair.upper - previous.upper))
                + abs(pair.lower - 49) + abs(pair.upper - 55)
        }
        return pairs.min { cost($0) < cost($1) }
            ?? (choices.first ?? previous.lower, choices.last ?? previous.upper)
    }
}
