import Foundation

nonisolated extension LofiScore {
    /// Mid shells stay clear of every lead onset by this many beats. The pad's onsets keep it too.
    static let midOnsetClearance = 0.12
    /// Shells end before the fill's build into the next phrase. The held pad has its own end (`padEnd`).
    static let midLatestEnd = 14.5
    /// The held pad's register (C3 to D4) and its home voicing.
    static let padRegister = 48...62
    static let padCentre = [52, 57, 60]
    /// Voicings prefer every voice at or above this pitch (155 Hz), so the pad leaves the low mids to the bass.
    static let padLowFloor = 51
    /// The pad's release (`LofiPadVoice.Settings.release`): the score ends the hold this long before the
    /// phrase edge, so the dry release fades out inside the phrase and the next swell starts at beat 0.
    static let padReleaseSeconds = 0.85
    /// Where the moving pad voice changes note, and how long its two notes overlap (legato).
    static let padRevoiceBeat = 8.0
    static let padRevoiceOverlap = 0.25
    /// Chance that the second shell-eligible phrase of a take also gets an answer shell.
    static let secondShellChance: Float = 0.4

    /// Beat at which the pad's hold ends: its release then ends 0.02 beats before the phrase edge.
    static func padEnd(beatSeconds: Double) -> Double {
        LofiClock.beats - padReleaseSeconds / max(0.001, beatSeconds) - 0.02
    }

    /// The chord channel of one phrase (D117): a held pad on the phrase's chord, plus at most one answer
    /// shell played by the lead's sample after a landing note.
    ///
    /// The pad is three voices (third, seventh, and the ninth when the scale has it, else the fifth; two
    /// voices, third and seventh, in a breakdown), with no root, in MIDI 48...62 under the melody. Two
    /// voices hold from the downbeat to `padEnd`; the inner voice moves a scale step or two at bar 3 with
    /// a quarter beat of legato overlap. A return's pad enters at `quietUntil`.
    ///
    /// Shells (`answer`, `rolled`) only answer in theme, variation and answer phrases, after a landing lead
    /// note followed by at least two beats of rest. Per 16-bar take the phrase with the longest rest (the
    /// answer phrase, else the theme) always answers and the other eligible phrase answers 40 percent of
    /// the time, so a take holds one or two. Phrases are scored independently, so "longest rest" is the
    /// section's structural property: the answer's line lands at beat 7.5 or 8.75, a theme's at 10 or later.
    static func mids(lead: [Note], harmony: Harmony, section: Section, chordDegree: Int,
                     quietUntil: Double, extraOnsets: [Double] = [], phrase: Int = 0,
                     beatSeconds: Double = 60 / LofiOptions().safeTempo, random: MusicRNG) -> [Note] {
        var rng = random.fork(136)
        let onsets = lead.map(\.beat) + extraOnsets
        func clear(_ beat: Double) -> Bool {
            beat >= quietUntil && onsets.allSatisfy { abs($0 - beat) >= midOnsetClearance - 1e-9 }
        }
        let pad = padNotes(lead: lead, harmony: harmony, section: section, chordDegree: chordDegree,
                           quietUntil: quietUntil, clear: clear, beatSeconds: beatSeconds, random: &rng)
        let shells = shellNotes(lead: lead, harmony: harmony, section: section, chordDegree: chordDegree,
                                phrase: phrase, clear: clear, random: &rng)
        return (pad + shells).sorted { $0.beat == $1.beat ? $0.midi < $1.midi : $0.beat < $1.beat }
    }

    // MARK: Pad

    private static func padNotes(lead: [Note], harmony: Harmony, section: Section, chordDegree: Int,
                                 quietUntil: Double, clear: (Double) -> Bool, beatSeconds: Double,
                                 random rng: inout MusicRNG) -> [Note] {
        let voices = section == .breakdown ? 2 : 3
        let lowestLead = lead.map(\.midi).min() ?? 72
        // At least two semitones under the melody's lowest note where that leaves the top at 55 or higher.
        let ceiling = lowestLead - 2 >= 55 ? min(padRegister.upperBound, lowestLead - 2) : padRegister.upperBound
        let home = padVoicing(for: 0, voices: voices, previous: Array(padCentre.prefix(voices)),
                              harmony: harmony, ceiling: ceiling, lowestLead: lowestLead)
        let chord = chordDegree == 0 ? home
            : padVoicing(for: chordDegree, voices: voices, previous: home, harmony: harmony, ceiling: ceiling,
                         lowestLead: lowestLead)
        var start = max(0, quietUntil)
        while !clear(start), start < quietUntil + 4 { start += 0.125 }
        let end = padEnd(beatSeconds: beatSeconds)
        guard end - start > 2 else { return [] }
        let velocity: Float = section == .breakdown ? 0.46 : 0.52
        let send = rng.rangeF(0.60...0.75)
        func note(_ midi: Int, _ beat: Double, _ until: Double) -> Note {
            Note(part: .texture, midi: midi, beat: beat, length: until - beat, velocity: velocity, color: 0.40,
                 send: send, articulation: .pad)
        }
        // The inner voice of three (the upper of two) changes note at bar 3.
        let moving = 1
        let revoice = [padRevoiceBeat, padRevoiceBeat - 0.25, padRevoiceBeat + 0.25, padRevoiceBeat - 0.5,
                       padRevoiceBeat + 0.5].first { $0 > start + 1 && clear($0) }
        var notes: [Note] = []
        for (index, midi) in chord.enumerated() {
            if index == moving, let revoice,
               let next = revoicing(chord, moving: index, harmony: harmony, ceiling: ceiling, random: &rng) {
                notes.append(note(midi, start, revoice + padRevoiceOverlap))
                notes.append(note(next, revoice, end))
            } else {
                notes.append(note(midi, start, end))
            }
        }
        return notes
    }

    /// Pitch classes of the pad on `degree` (relative to the tonic): third, seventh, then the ninth when
    /// the scale has it, else the fifth. Two voices keep the third and seventh.
    static func padPitchClasses(for degree: Int, voices: Int, harmony: Harmony, ninth: Bool = true) -> [Int] {
        let relative = harmony.scale.intervals
        let colour = ninth && relative.contains((degree + 2) % 12) ? 2 : 7
        let classes = harmony.notes(for: degree, intervals: [3, 10, colour])
        return Array(classes.prefix(voices))
    }

    /// The pad's voicing on `degree`: one pitch per class, ascending, adjacent voices 3 to 7 semitones
    /// apart, the top voice at most `ceiling`. Cost is three times the motion from `previous` plus the
    /// distance from the home centre, as the shells' `voicing`, so chord changes keep common tones.
    static func padVoicing(for degree: Int, voices: Int, previous: [Int], harmony: Harmony,
                           ceiling: Int, lowestLead: Int = 72) -> [Int] {
        func search(_ count: Int, spacing: ClosedRange<Int>, top: Int, floor: Int) -> [Int]? {
            // The ninth sits a semitone or tone from the third, so when it does not fit the register with
            // the spacing, the fifth takes its place.
            first(count, spacing: spacing, top: top, floor: floor, ninth: true)
                ?? first(count, spacing: spacing, top: top, floor: floor, ninth: false)
        }
        func first(_ count: Int, spacing: ClosedRange<Int>, top: Int, floor: Int, ninth: Bool) -> [Int]? {
            let classes = padPitchClasses(for: degree, voices: count, harmony: harmony, ninth: ninth)
            let centre = Array(padCentre.prefix(count))
            let pool = padRegister.filter { $0 >= floor && $0 <= top && classes.contains($0 % 12) }
            var best: (cost: Int, voicing: [Int])?
            func extend(_ chosen: [Int]) {
                if chosen.count == count {
                    guard Set(chosen.map { $0 % 12 }) == Set(classes) else { return }
                    var cost = 0
                    for (index, pitch) in chosen.enumerated() {
                        let before = previous.indices.contains(index) ? previous[index] : centre[index]
                        cost += 3 * abs(pitch - before) + abs(pitch - centre[index])
                    }
                    if best.map({ cost < $0.cost }) ?? true { best = (cost, chosen) }
                    return
                }
                for pitch in pool where chosen.last.map({ spacing.contains(pitch - $0) }) ?? true {
                    extend(chosen + [pitch])
                }
            }
            extend([])
            return best?.voicing
        }
        // Every voice at or above `padLowFloor` (155 Hz: lower fundamentals are what the 220 Hz high-pass
        // cannot clear). Three voices under the ceiling, else with the top up to the melody's lowest note;
        // then the third and seventh alone under those; then 62; only last the full register.
        let floor = padLowFloor, bottom = padRegister.lowerBound
        let tops = [ceiling, max(ceiling, lowestLead)]
        var counts = [voices]
        if voices > 2 { counts.append(2) }
        for count in counts {
            for top in tops {
                if let voicing = search(count, spacing: 3...7, top: top, floor: floor)
                    ?? search(count, spacing: 2...9, top: top, floor: floor) { return voicing }
            }
        }
        for count in counts {
            if let voicing = search(count, spacing: 3...7, top: padRegister.upperBound, floor: floor)
                ?? search(count, spacing: 2...9, top: padRegister.upperBound, floor: floor) { return voicing }
        }
        let classes = padPitchClasses(for: degree, voices: voices, harmony: harmony)
        return search(voices, spacing: 3...7, top: ceiling, floor: bottom)
            ?? search(voices, spacing: 2...9, top: padRegister.upperBound, floor: bottom)
            ?? Array(padRegister.filter { classes.contains($0 % 12) }.prefix(voices))
    }

    /// The moving voice's second note: a scale step or two from where it was, at least two semitones from
    /// the held voices, between its neighbours, inside the register and under the ceiling.
    private static func revoicing(_ chord: [Int], moving: Int, harmony: Harmony, ceiling: Int,
                                  random rng: inout MusicRNG) -> Int? {
        let scale = harmony.pitches(in: (padRegister.lowerBound - 4)...(padRegister.upperBound + 4))
        guard let position = scale.firstIndex(of: chord[moving]) else { return nil }
        let held = chord.enumerated().filter { $0.offset != moving }.map(\.element)
        let below = chord.indices.contains(moving - 1) ? chord[moving - 1] : Int.min
        let above = chord.indices.contains(moving + 1) ? chord[moving + 1] : Int.max
        let options = [-2, -1, 1, 2].compactMap { step -> Int? in
            let index = position + step
            guard scale.indices.contains(index) else { return nil }
            let pitch = scale[index]
            guard padRegister.contains(pitch), pitch <= ceiling, pitch > below, pitch < above,
                  held.allSatisfy({ abs($0 - pitch) >= 2 }) else { return nil }
            return pitch
        }
        return options.isEmpty ? nil : options[rng.int(0...(options.count - 1))]
    }

    // MARK: Shells

    private static func shellNotes(lead: [Note], harmony: Harmony, section: Section, chordDegree: Int,
                                   phrase: Int, clear: (Double) -> Bool, random rng: inout MusicRNG) -> [Note] {
        guard [.theme, .answer, .variation].contains(section) else { return [] }
        let guaranteed = section == .answer || (section == .theme && phrase % phrasesPerForm < 4)
        guard guaranteed || rng.chance(secondShellChance) else { return [] }
        let home = voicing(for: 0, previous: (49, 55), harmony: harmony)
        let voices = chordDegree == 0 ? home : voicing(for: chordDegree, previous: home, harmony: harmony)
        // Landing notes: at least two beats of rest follow, before the next onset or the phrase end.
        var landings: [(beat: Double, rest: Double)] = []
        for (index, note) in lead.enumerated() {
            let next = index + 1 < lead.count ? lead[index + 1].beat : LofiClock.beats
            let rest = next - (note.beat + note.length)
            if rest >= 2 { landings.append((note.beat, rest)) }
        }
        let kinds: [Articulation] = rng.chance(0.5) ? [.answer, .rolled] : [.rolled, .answer]
        func span(_ kind: Articulation) -> Double { kind == .answer ? 1.6 : 0.17 + 1.3 }
        // Prefer the longest rest; within it, the first clear delay in a seeded order.
        for landing in landings.sorted(by: { $0.rest > $1.rest }) {
            for kind in kinds {
                for delay in [0.5, 0.75, 1.0].shuffled(using: &rng) {
                    let beat = landing.beat + delay
                    guard clear(beat), beat + span(kind) <= midLatestEnd + 1e-9,
                          kind != .rolled || clear(beat + 0.17) else { continue }
                    let velocity = rng.rangeF(0.50...0.66)
                    let send = kind == .answer ? rng.rangeF(0.62...0.75) : rng.rangeF(0.55...0.68)
                    return [voices.lower, voices.upper].enumerated().map { index, pitch in
                        let stagger = kind == .rolled ? Double(index) * 0.17 : 0
                        return Note(part: .texture, midi: pitch, beat: beat + stagger,
                                    length: kind == .answer ? 1.6 : 1.30, velocity: velocity, color: 0.40,
                                    send: send, articulation: kind)
                    }
                }
            }
        }
        return []
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
