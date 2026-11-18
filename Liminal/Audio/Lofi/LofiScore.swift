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

/// The fill resolves on the downbeat after eight bars, and again after the full take.
nonisolated enum LofiFill: Sendable {
    case halfway, turnaround

    static func ending(phrase: Int) -> Self? {
        switch phrase % 4 {
        case 1: .halfway
        case 3: .turnaround
        default: nil
        }
    }

    var buildBeats: Double { self == .halfway ? 2 : 4 }
    var dissolveBeats: Double { self == .halfway ? 0.75 : 0.375 }

    /// A smooth rise into one downbeat, followed by a much shorter release.
    func accent(beatsFromBoundary beat: Double) -> Float {
        let u = min(1, max(0, beat <= 0 ? 1 + beat / buildBeats : 1 - beat / 0.75))
        return Float(u * u * (3 - 2 * u))
    }
}

/// Origin and beat duration of the audible take, in seconds on the consumer's clock.
nonisolated struct LofiTakeGrid: Sendable {
    let origin: Double
    let beatDuration: Double

    var takeIndex = 0
    var nextBeatDuration: Double?

    func accent(at time: Double) -> Float {
        let beat = (time - origin) / beatDuration
        let halfway = 0.65 * LofiFill.halfway.accent(beatsFromBoundary: beat - 32)
        let turn = LofiFill.turnaround.accent(beatsFromBoundary: beat - 64)
        let arrival = takeIndex == 0 ? 0 : LofiFill.turnaround.accent(beatsFromBoundary: beat)
        return max(halfway, turn, arrival)
    }

    func nextBoundary(after time: Double) -> (time: Double, fill: LofiFill) {
        let halfway = origin + 32 * beatDuration
        let turn = origin + 64 * beatDuration
        if time < halfway { return (halfway, .halfway) }
        if time < turn { return (turn, .turnaround) }
        // An incoming film crosses the old downbeat and runs at the committed new tempo.
        let span = 32 * (nextBeatDuration ?? beatDuration)
        let half = Int(floor((time - turn) / span)) + 1
        return (turn + Double(half) * span, half.isMultiple(of: 2) ? .turnaround : .halfway)
    }
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
    let chordRoot: Int
    let scale: ScaleType
    let notes: [Note]
    let preset: LofiPreset
    /// The phrase's remaining beats after the last scored pitched note.
    let endingRest: ClosedRange<Double>
    let virtualRecord: LofiVirtualRecord.Edit?

    static let phrasesPerForm = 8

    /// Each intact sixteen-bar drum break has a call, open space, variation and actual return.
    static func section(at phrase: Int) -> Section {
        [.theme, .variation, .breakdown, .returnTheme,
         .theme, .answer, .breakdown, .returnTheme][phrase % phrasesPerForm]
    }

    static func make(seed: UInt64, section: Section, drift: LofiDrift, startBeat: Double,
                     pinnedScale: ScaleType? = nil, kickBeats: [Double] = []) -> Self {
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
        let theme = motif(harmony: harmony, random: motifRandom)
        let phraseRandom = root.fork(UInt64(position) + 618)
        let line: [Note]
        switch section {
        case .variation:
            line = vary(theme, harmony: harmony, random: phraseRandom)
        case .theme, .returnTheme:
            line = theme
        case .answer, .breakdown:
            line = answer(to: theme, harmony: harmony, short: section == .breakdown, random: phraseRandom)
        }
        let articulation = section == .returnTheme ? root.fork(UInt64(record * 4) + 618) : phraseRandom
        let lead = articulate(line, for: preset, random: articulation)

        let bass = bassLine(harmony: harmony, section: section, random: phraseRandom, kickBeats: kickBeats)
        let reply = section == .answer || section == .variation
        let chordDegree = reply ? harmony.nearest(5, in: scale.intervals) : 0
        let texture = shell(harmony: harmony, section: section, chordDegree: chordDegree, random: phraseRandom)
        let ending = (lead + texture).map { $0.beat + $0.length }.max() ?? 0
        let rest = ending...LofiClock.beats
        let notes = (bass + texture + lead).sorted { lhs, rhs in
            if lhs.beat != rhs.beat { return lhs.beat < rhs.beat }
            if lhs.part != rhs.part { return lhs.part.rawValue < rhs.part.rawValue }
            return lhs.midi < rhs.midi
        }
        var edits = phraseRandom.fork(945)
        let virtualRecord = LofiVirtualRecord.choose(from: lead, before: min(15.5, ending + 1.25), section: section,
                                                     program: preset.sampleGroup, seed: edits.next())
        return .init(section: section, tonic: tonic, chordRoot: (tonic + chordDegree) % 12, scale: scale, notes: notes,
                     preset: preset, endingRest: rest, virtualRecord: virtualRecord)
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

    private static func motif(harmony: Harmony, random: MusicRNG) -> [Note] {
        var rhythm = random.fork(77)
        var pitch = random.fork(88)
        // Each pattern has a short call, a gap, then a second cell with a longer landing.
        let onsets: [[Double]] = [
            [0.5, 1.25, 2.75, 5.5, 7, 10.25],
            [0.75, 2, 2.75, 6.5, 7.25, 10.5],
            [0.5, 1, 3.5, 6.75, 8.5, 11],
            [1.25, 2.75, 4, 7.5, 8.25, 10.5],
            [0.75, 2.5, 5.25, 7.75, 10.5]
        ]
        let lilt = rhythm.range(0.010...0.045)
        let beats = rhythm.pick(onsets).map { $0 + lilt }
        let contour = beats.count == 5
            ? pitch.pick([[-5, 0, 7, 4, 0], [7, 4, 0, 4, 0]])
            : pitch.pick([[0, 3, 7, 3, -2, 0], [7, 7, 3, -2, 3, 0],
                          [-5, -2, 0, 5, 3, 0], [3, 0, 3, 7, 3, 0]])
        let anchor = harmony.nearest(61, in: (57...68).filter { $0 % 12 == harmony.tonic })
        let choices = harmony.pitches(in: 53...72)
        let chord = harmony.notes(for: 0, intervals: [0, 3, 7])
        let candidates = contour.dropLast().enumerated().map { index, offset in
            let available = index == 0 ? choices.filter { chord.contains($0 % 12) } : choices
            return available.filter { abs($0 - (anchor + offset)) <= 7 }
        }
        let pitches = viablePitches(candidates, anchor: anchor, targets: contour.map { anchor + $0 })
            ?? contour.map { harmony.nearest(anchor + $0, in: choices) }
        return beats.indices.map { i in
            let landing = i == beats.count - 1
            return Note(part: .lead, midi: pitches[i], beat: beats[i],
                        length: landing ? 1.15 : (i.isMultiple(of: 3) ? 0.71 : 0.38),
                        velocity: landing ? 0.81 : (i.isMultiple(of: 3) ? 0.78 : 0.55),
                        color: 0.50, send: landing ? 0.78 : (i == 2 ? 0.49 : 0.29))
        }
    }

    /// Work backward from the terminal pitch before choosing any note. A candidate that
    /// cannot connect to the destination never enters the forward pass.
    private static func viablePitches(_ candidates: [[Int]], anchor: Int, targets: [Int]) -> [Int]? {
        var viable = [[anchor]]
        for (index, allowed) in candidates.enumerated().reversed() {
            let reach = index == candidates.count - 1 ? 5 : 7
            let next = viable.last ?? [anchor]
            viable.append(allowed.filter { note in next.contains { abs($0 - note) <= reach } })
        }
        var pitches: [Int] = []
        for (index, allowed) in viable.reversed().enumerated() {
            let eligible = allowed.filter { note in pitches.last.map { abs($0 - note) <= (index == candidates.count ? 5 : 7) } ?? true }
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
        let anchor = theme[theme.count - 1].midi
        var variation = random.fork(109)
        let direction = variation.pick([-1, 1])
        let register = harmony.pitches(in: 53...72)
        // Keep the first cell. Rephrase the answer with a shifted entry and a different route home.
        return theme.enumerated().map { i, note in
            guard i >= 3, i < theme.count - 1 else { return note }
            let target = anchor + direction * (i == 3 ? 6 : 3)
            let context = register.filter { $0 != note.midi && abs($0 - anchor) <= 7 }
            return .init(part: .lead, midi: harmony.nearest(target, in: context),
                         beat: note.beat + (i == 3 ? 0.25 : 0), length: note.length,
                         velocity: note.velocity, color: note.color, send: max(note.send, 0.40))
        }
    }

    private static func answer(to theme: [Note], harmony: Harmony, short: Bool, random: MusicRNG) -> [Note] {
        var rhythm = random.fork(314)
        let beats: [Double] = short ? rhythm.pick([[1.5, 2.5, 6.75, 10.75], [0.75, 2.25, 7.5, 11.25]])
                                    : rhythm.pick([[1, 2.75, 4, 7.5], [0.75, 3.5, 4.5, 8.75]])
        let register = harmony.pitches(in: 53...70)
        let final = theme[theme.count - 1]
        let targets = short ? [theme[0].midi, final.midi - 4, final.midi - 7, final.midi]
                            : [theme[0].midi, final.midi + 3, final.midi + 5, final.midi]
        return zip(beats, targets).enumerated().map { i, pair in
            let landing = i == beats.count - 1
            return .init(part: .lead, midi: harmony.nearest(pair.1, in: register), beat: pair.0 + 0.035,
                         length: landing ? 1.32 : 0.72, velocity: i == 0 || landing ? 0.77 : 0.63,
                         color: 0.47, send: landing ? 0.76 : 0.36)
        }
    }

    private static func articulate(_ line: [Note], for preset: LofiPreset, random: MusicRNG) -> [Note] {
        // Hold organ tones through their body, let piano ring, and keep plucks light.
        // Keep MIDI and onsets independent of the sample program so the hook remains recognizable.
        let length: Double
        let tone: Double
        switch preset.family {
        case .piano: (length, tone) = (1.0, 0.63)
        case .strings: (length, tone) = (0.61, 0.45)
        case .organ: (length, tone) = (1.42, 0.40)
        }
        var color = random.fork(913)
        return line.enumerated().map { i, note in
            let gap = i + 1 < line.count ? line[i + 1].beat - note.beat - 0.06 : 1.48
            return .init(part: .lead, midi: note.midi, beat: note.beat,
                         length: min(note.length * length, gap), velocity: note.velocity,
                         color: tone + color.range(-0.05...0.05), send: note.send)
        }
    }

    private static func bassLine(harmony: Harmony, section: Section, random: MusicRNG, kickBeats: [Double]) -> [Note] {
        var rhythm = random.fork(124)
        let related = rhythm.pick([3, 5, 7, 8, 10])
        let home = harmony.bass(0)
        let motion = harmony.bass(related, near: home)
        let fifth = harmony.bass(7, near: home - 2)
        let pocket = rhythm.range(0.017...0.045)
        let figures: [(beat: Double, length: Double, midi: Int, strength: Float)]
        switch section {
        case .breakdown:
            figures = [(2, 1.15, motion, 0.76), (8, 1.05, home, 0.73)]
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
            // Follow nearby played kicks, retaining the phrase's laid-back offset on pickups.
            // Distant fills and extra kicks never add notes or displace a structural bass entrance.
            let nearest = kickBeats.min { abs($0 - figure.beat) < abs($1 - figure.beat) }
            let anchor = nearest.flatMap { abs($0 - figure.beat) <= 0.075 ? $0 : nil } ?? figure.beat
            return .init(part: .bass, midi: figure.midi, beat: anchor + (figure.beat == 0 ? 0 : pocket),
                  length: figure.length, velocity: figure.strength, send: 0)
        }
    }

    private static func shell(harmony: Harmony, section: Section, chordDegree: Int, random: MusicRNG) -> [Note] {
        guard section != .breakdown else { return [] }
        var timing = random.fork(136)
        let home = voicing(for: 0, previous: (49, 55), harmony: harmony)
        let beat = timing.pick([4.25, 5.25, 8.75])
        let voices = chordDegree == 0 ? home : voicing(for: chordDegree, previous: home, harmony: harmony)
        return [voices.lower, voices.upper].enumerated().map { index, pitch in
            .init(part: .texture, midi: pitch, beat: beat + Double(index) * 0.17, length: 1.30,
                  velocity: timing.rangeF(0.37...0.47), color: 0.40, send: 0.73)
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
