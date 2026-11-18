import Foundation

nonisolated enum MusicMode: String, CaseIterable, Codable, Sendable {
    case ambient, lofi

    var title: String { self == .ambient ? "Ambient" : "Lo-Fi" }
}

nonisolated struct LofiOptions: Codable, Equatable, Sendable {
    var tempo = 69.0

    static let tempos = 58.0...82.0

    var safeTempo: Double { tempo.isFinite ? min(max(tempo, Self.tempos.lowerBound), Self.tempos.upperBound) : 69 }
}

/// New targets every few bars, with each parameter following its own gradual curve.
/// Absolute beat positions keep both sides of a scheduled phrase boundary in sync.
nonisolated struct LofiDrift: Sendable {
    let seed: UInt64

    struct Values: Sendable, Equatable {
        let groove: Float
        let density: Float
        let dust: Float
        let space: Float
        let drums: Float
    }

    func at(_ beat: Double) -> Values {
        Values(groove: curve(beat, every: 13, stream: 1, range: 0.25...0.70),
               density: curve(beat, every: 11, stream: 2, range: 0.32...0.61),
               dust: curve(beat, every: 17, stream: 3, range: 0.08...0.24),
               space: curve(beat, every: 15, stream: 4, range: 0.28...0.57),
               drums: curve(beat, every: 9, stream: 5, range: 0.53...0.73))
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
    enum Section: Int, Sendable { case theme, answer, breakdown, returnTheme }

    struct Note: Equatable, Sendable {
        let part: Part
        let midi: Int
        let beat: Double
        let length: Double
        let velocity: Float
        var color: Double = 0.5
    }

    let section: Section
    let tonic: Int
    let notes: [Note]
    let preset: LofiPreset

    /// A repeating theme and answer, with a short breakdown and a familiar return.
    static func section(at phrase: Int) -> Section {
        [.theme, .theme, .answer, .answer, .breakdown, .returnTheme, .returnTheme, .answer][phrase % 8]
    }

    static func make(seed: UInt64, section: Section, drift: LofiDrift, startBeat: Double) -> Self {
        var harmony = MusicRNG(seed: seed)
        let tonic = harmony.pick([0, 2, 3, 5, 7, 9])
        let minor = harmony.chance(0.7)
        let progressions = minor
            ? [[0, 5, 10, 0], [0, 8, 3, 5], [0, 10, 5, 3]]
            : [[0, 5, 2, 0], [0, 9, 5, 2], [0, 4, 9, 5]]
        let progression = harmony.pick(progressions)
        let phrase = Int(startBeat / LofiClock.beats) % 8
        var variation = harmony.fork(UInt64(phrase) + 5)
        let root = progression[(phrase / 2) % progression.count]
        let nextRoot = progression[(phrase / 2 + 1) % progression.count]
        let breakdown = section == .breakdown
        let center = 48 + tonic
        let scale = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        var notes: [Note] = []

        // Voice the same harmonic field in different registers and leave whole phrases with one swell.
        let swells: [(start: Double, length: Double, root: Int)] = breakdown
            ? [(1.5, 7.5, root)]
            : variation.pick([
                [(0.5, 6.7, root), (9, 3.1, nextRoot)],
                [(2, 8.4, root)],
                [(0, 6.4, root), (8, 4.2, nextRoot)]
            ])
        for swell in swells {
            let degree = scale.firstIndex(of: swell.root) ?? 0
            let voices = variation.pick([[0, 4, 8], [0, 2, 6], [2, 4, 7], [0, 3, 7], [0, 4]])
            for (index, voice) in voices.enumerated() {
                let step = degree + voice
                let midi = center + scale[step % 7] + 12 * (step / 7)
                let offset = Double(index) * 0.19
                notes.append(.init(part: .texture, midi: midi, beat: swell.start + offset,
                                   length: swell.length - offset, velocity: variation.rangeF(0.31...0.53)))
            }
        }

        let bass: [(beat: Double, length: Double, degree: Int)] = breakdown
            ? [(0, 2.2, root), (8.5, 1.5, root)]
            : variation.pick([
                [(0, 2.5, root), (5.75, 0.50, root + 7), (8.0, 2.10, nextRoot)],
                [(0.5, 2.75, root), (6.5, 1.0, root), (9.5, 1.9, nextRoot), (12.0, 0.55, nextRoot + 7)],
                [(0, 3.1, root), (7.5, 0.45, nextRoot), (9.0, 2.8, nextRoot)],
                [(0, 1.7, root), (4.75, 1.8, root), (10.5, 1.6, nextRoot)]
            ])
        for note in bass {
            let feel = drift.at(startBeat + note.beat)
            let behind = note.beat == 0 ? 0 : Double(feel.groove) * 0.065
            let midi = 28 + (tonic + note.degree - 28 % 12 + 12) % 12
            notes.append(.init(part: .bass, midi: midi, beat: note.beat + behind, length: note.length,
                               velocity: note.length > 1.5 ? 0.79 : 0.45 + 0.24 * feel.density))
        }

        // Change lead recording and pattern at each four-bar phrase.
        let leadPhrase = Int(startBeat / LofiClock.beats)
        let preset = LofiPreset.selection(seed: drift.seed, phrase: leadPhrase)
        var melody = MusicRNG(seed: seed).fork(UInt64(leadPhrase) + 808)
        let strings = preset.family == .strings
        let contour = melody.pick(strings
            ? [[0, 4, 2], [2, 0, 1], [4, 2, 0], [0, 2, 4]]
            : [[0, 2, 1, 4, 2], [4, 2, 3, 0, 1], [1, 3, 4, 2, 0], [0, 4, 2, 1, 3]])
        let call = melody.pick(strings
            ? [[0.5, 2, 4], [1, 2.75, 4.75], [1.5, 3.5], [2]]
            : [[1.5, 3], [0.75, 2.25, 3.75], [1, 2.5], [2.25]])
        let reply = melody.pick(strings ? [[8.5, 10.25], [9.0], [8.25, 10.0], [9.75]]
                                        : [[8.5, 10.25], [9.25], [8.25, 10.5], [9.5]])
        let groups = breakdown ? [[6.75, 9.0]] : (melody.chance(0.80) ? [call, reply] : [call])
        for (group, events) in groups.enumerated() {
            let degree = scale.firstIndex(of: group == 0 ? root : nextRoot) ?? 0
            for (step, beat) in events.enumerated() {
                let offset = contour[(step + group) % contour.count]
                let pitch = center + scale[(degree + offset) % 7] + 12 * ((degree + offset) / 7)
                let midi = pitch > 68 ? pitch - 12 : pitch
                let feel = drift.at(startBeat + beat)
                let length = melody.range(strings ? 0.23...0.48 : 0.32...0.68)
                let color = Double(feel.space * 0.70 + feel.density * 0.30)
                notes.append(.init(part: .lead, midi: midi, beat: beat + Double(feel.groove) * 0.042,
                                   length: length, velocity: (step == 0 ? 0.61 : 0.51) + 0.14 * feel.density,
                                   color: color))
            }
        }
        return .init(section: section, tonic: tonic, notes: notes, preset: preset)
    }
}
