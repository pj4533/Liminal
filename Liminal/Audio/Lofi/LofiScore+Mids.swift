import Foundation

nonisolated extension LofiScore {
    /// Mid shells stay clear of every lead onset by this many beats.
    static let midOnsetClearance = 0.12
    /// Mids end before the fill's build into the next phrase.
    static let midLatestEnd = 14.5

    /// Two to four shell gestures placed where the melody rests or lands: an off-beat stab in a
    /// gap, a longer answer after a cell's landing note, or the rolled two-note shell. No mid
    /// onset doubles a lead attack. A breakdown keeps at most one soft answer.
    static func mids(lead: [Note], harmony: Harmony, section: Section, chordDegree: Int,
                             quietUntil: Double, extraOnsets: [Double] = [], random: MusicRNG) -> [Note] {
        var rng = random.fork(136)
        let home = voicing(for: 0, previous: (49, 55), harmony: harmony)
        let voices = chordDegree == 0 ? home : voicing(for: chordDegree, previous: home, harmony: harmony)
        let onsets = lead.map(\.beat) + extraOnsets
        func clear(_ beat: Double) -> Bool {
            beat >= quietUntil && onsets.allSatisfy { abs($0 - beat) >= midOnsetClearance - 1e-9 }
        }
        // Rests of the line: before the first note, between notes, and after the landing.
        var gaps: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for note in lead {
            if note.beat > cursor { gaps.append((cursor, note.beat)) }
            cursor = max(cursor, note.beat + note.length)
        }
        if cursor < midLatestEnd { gaps.append((cursor, midLatestEnd)) }

        struct Event { let articulation: Articulation; let beat: Double; var span: Double {
            switch articulation { case .stab: 0.35; case .answer: 1.6; case .rolled, .normal, .pad: 0.17 + 1.3 } } }
        var candidates: [Articulation: [Double]] = [.stab: [], .answer: [], .rolled: []]
        for gap in gaps {
            var beat = ceil(gap.start * 4 - 1e-9) / 4
            while beat + 0.35 <= gap.end + 1e-9 {
                let offBeat = abs(beat - beat.rounded()) > 1e-9
                if gap.end - gap.start >= 0.75, offBeat, clear(beat), beat + 0.35 <= midLatestEnd {
                    candidates[.stab, default: []].append(beat)
                }
                if gap.end - gap.start >= 0.5, beat + 0.17 < gap.end, clear(beat), clear(beat + 0.17),
                   beat + 0.17 + 1.3 <= midLatestEnd {
                    candidates[.rolled, default: []].append(beat)
                }
                beat += 0.25
            }
        }
        // Landing notes close a cell: the next onset is at least 1.5 beats away, or nothing follows.
        for (index, note) in lead.enumerated() {
            let next = index + 1 < lead.count ? lead[index + 1].beat : LofiClock.beats
            guard next - note.beat >= 1.5 else { continue }
            for delay in [0.5, 0.75, 1.0] where clear(note.beat + delay) && note.beat + delay + 1.6 <= midLatestEnd {
                candidates[.answer, default: []].append(note.beat + delay)
            }
        }

        var events: [Event] = []
        func fits(_ event: Event) -> Bool {
            events.allSatisfy { other in
                event.beat >= other.beat + other.span + 0.25 || other.beat >= event.beat + event.span + 0.25
            }
        }
        if section == .breakdown {
            if rng.chance(0.6), let beat = candidates[.answer]?.randomElement(using: &rng) {
                events.append(.init(articulation: .answer, beat: beat))
            }
        } else {
            let target = rng.int(2...4)
            let cycle: [Articulation] = [.stab, .answer, .rolled]
            var turn = rng.int(0...2)
            var misses = 0
            while events.count < target, misses < 3 {
                let kind = cycle[turn % 3]
                turn += 1
                let used = events.filter { $0.articulation == kind }.count
                let options = (candidates[kind] ?? []).filter { fits(.init(articulation: kind, beat: $0)) }
                guard used < 2, let beat = options.randomElement(using: &rng) else { misses += 1; continue }
                misses = 0
                events.append(.init(articulation: kind, beat: beat))
            }
        }
        return events.sorted { $0.beat < $1.beat }.flatMap { event -> [Note] in
            let soft = section == .breakdown
            let velocity: Float = soft ? 0.42 : rng.rangeF(0.50...0.66)
            let send: Float
            switch event.articulation {
            case .stab: send = rng.rangeF(0.45...0.56)
            case .rolled, .normal, .pad: send = rng.rangeF(0.55...0.68)
            case .answer: send = rng.rangeF(0.62...0.75)
            }
            return [voices.lower, voices.upper].enumerated().map { index, pitch in
                let stagger = event.articulation == .rolled ? Double(index) * 0.17 : 0
                let length: Double
                switch event.articulation {
                case .stab: length = 0.35
                case .answer: length = 1.6
                case .rolled, .normal, .pad: length = 1.30
                }
                return Note(part: .texture, midi: pitch, beat: event.beat + stagger, length: length,
                            velocity: velocity, color: event.articulation == .stab ? 0.46 : 0.40, send: send,
                            articulation: event.articulation)
            }
        }
    }

    static func voicing(for root: Int, previous: (lower: Int, upper: Int),
                                harmony: Harmony) -> (lower: Int, upper: Int) {
        let pitches = harmony.notes(for: root, intervals: [3, 7])
        let register = 45...62
        let choices = register.filter { pitches.contains($0 % 12) }
        let pairs = choices.flatMap { lower in
            choices.filter { $0 - lower >= 3 && $0 - lower <= 10 }.map { (lower: lower, upper: $0) }
        }
        func cost(_ pair: (lower: Int, upper: Int)) -> Int {
            3 * (abs(pair.lower - previous.lower) + abs(pair.upper - previous.upper))
                + abs(pair.lower - 49) + abs(pair.upper - 55) + 8 * max(0, 48 - pair.lower)
        }
        return pairs.min { cost($0) < cost($1) }
            ?? (choices.first ?? previous.lower, choices.last ?? previous.upper)
    }
}
