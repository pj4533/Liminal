import Foundation

/// Guitar idioms around a scored melody (D114). The melody keeps every pitch, onset and length;
/// these are the extra strings a guitarist would sound with it, scored as `.ornament` notes:
///
/// - strums: chord tones under a melody note, staggered 8 to 25 ms. A down-strum (low to high)
///   anticipates the beat so the melody string still speaks on its onset; an occasional up-strum
///   (high to low) starts on the melody and trails the lower strings after it.
/// - fingerpicking: a low chord tone plucked with the first note, and broken-chord figures that
///   rise through the gap after a landing note.
/// - double stops: one chord tone a third to a sixth under the melody.
/// - grace notes: a quick lower scale neighbour hammered or slid into a melody note.
///
/// Every choice comes from the phrase's own RNG fork, so a seed always plays the same figures.
/// Ornaments stay in the phrase's scale, end before the fill build (`LofiScore.midLatestEnd`) and
/// never move the bass or drums.
nonisolated enum LofiGuitarPhrasing {
    /// Strum spread between adjacent strings, in milliseconds.
    static let strumSpread = 8.0...25.0
    /// Lowest pitch a guitar ornament uses (A2 would be MIDI 45; keep under the lead but above the bass).
    static let lowestPitch = 45
    /// Ornament level relative to the melody note it decorates.
    static let innerVoice: ClosedRange<Float> = 0.56...0.70
    static let graceLevel: Float = 0.52

    static func ornaments(lead: [LofiScore.Note], section: LofiScore.Section, chord: [Int], scale: [Int],
                          fingerstyle: Double, beatSeconds: Double, random: MusicRNG) -> [LofiScore.Note] {
        guard !lead.isEmpty, !chord.isEmpty else { return [] }
        var rng = random.fork(2_406)
        let beat = max(0.05, beatSeconds)
        func beats(ms: Double) -> Double { ms / 1000 / beat }
        let fingerpicked = rng.chance(Float(fingerstyle))
        let sparse = section == .breakdown
        let latest = LofiScore.midLatestEnd
        var out: [LofiScore.Note] = []

        func chordTones(below top: Int, count: Int) -> [Int] {
            // Guitar-like spacing: each lower string at least a minor third under the one above.
            var tones: [Int] = []
            var ceiling = top - 3
            while tones.count < count, ceiling >= lowestPitch {
                guard let pitch = (lowestPitch...ceiling).reversed().first(where: { chord.contains($0 % 12) })
                else { break }
                tones.append(pitch)
                ceiling = pitch - 3
            }
            return tones
        }

        func add(_ midi: Int, at onset: Double, length: Double, level: Float, from note: LofiScore.Note) {
            let start = max(0, onset)
            let end = min(start + length, latest)
            guard end - start > 0.05 else { return }
            out.append(.init(part: .ornament, midi: midi, beat: start, length: end - start,
                             velocity: note.velocity * level, color: note.color - 0.04, send: note.send))
        }

        func strum(_ note: LofiScore.Note, ring: Double, previousEnd: Double, strings: Int) {
            let tones = chordTones(below: note.midi, count: strings)
            guard !tones.isEmpty else { return }
            let spread = beats(ms: rng.range(strumSpread))
            let up = rng.chance(0.25)
            for (k, pitch) in tones.enumerated() {
                // tones[0] is the string next to the melody; tones.last the lowest.
                let level = rng.rangeF(innerVoice)
                if up {
                    add(pitch, at: note.beat + Double(k + 1) * spread, length: ring, level: level, from: note)
                } else {
                    let onset = note.beat - Double(k + 1) * spread
                    if onset >= previousEnd - 0.2 {
                        add(pitch, at: onset, length: ring + Double(k + 1) * spread, level: level, from: note)
                    }
                }
            }
        }

        func arpeggio(after note: LofiScore.Note, next: Double) {
            // Rising broken chord in the landing's space, low string first.
            let tones = chordTones(below: note.midi, count: sparse ? 2 : 3).reversed()
            let step = rng.pick([0.5, 0.5, 0.75])
            var onset = note.beat + rng.pick([0.5, 0.75])
            let stop = min(next - 0.12, latest)
            for pitch in tones {
                guard onset + 0.3 <= stop else { break }
                let length = min(stop - onset, 1.25)
                add(pitch, at: onset, length: length, level: rng.rangeF(innerVoice) * (sparse ? 0.85 : 1), from: note)
                onset += step
            }
        }

        for (index, note) in lead.enumerated() {
            let next = index + 1 < lead.count ? lead[index + 1].beat : LofiClock.beats
            let previousEnd = index > 0 ? lead[index - 1].beat + 0.25 : 0
            let landing = index == lead.count - 1 || next - note.beat >= 1.5
            let ring = min(note.length, next - note.beat - 0.06)

            // Grace note: a scale step below, about 55 to 85 ms ahead, into a non-opening note.
            if index > 0, rng.chance(sparse ? 0.30 : 0.24),
               let neighbour = scale.last(where: { $0 < note.midi && note.midi - $0 <= 2 }) {
                let ahead = max(0.06, beats(ms: rng.range(55...85)))
                if note.beat - ahead >= previousEnd {
                    add(neighbour, at: note.beat - ahead, length: ahead * 0.9, level: graceLevel, from: note)
                    continue
                }
            }

            if sparse {
                // A breakdown keeps one quiet broken chord after its landing.
                if index == lead.count - 1 { arpeggio(after: note, next: next) }
                continue
            }

            if fingerpicked {
                if index == 0, let low = chordTones(below: note.midi - 5, count: 3).last {
                    // Thumb on a low chord tone with the opening note.
                    add(low, at: note.beat, length: max(ring, 0.9), level: rng.rangeF(innerVoice), from: note)
                } else if landing {
                    arpeggio(after: note, next: next)
                } else if rng.chance(0.30), let third = chordTones(below: note.midi, count: 1).first,
                          note.midi - third <= 9 {
                    add(third, at: note.beat, length: ring, level: rng.rangeF(innerVoice), from: note)
                }
            } else {
                if index == 0 || landing || rng.chance(0.30) {
                    strum(note, ring: ring, previousEnd: previousEnd, strings: index == 0 || landing ? 3 : 2)
                } else if rng.chance(0.45), let third = chordTones(below: note.midi, count: 1).first,
                          note.midi - third <= 9 {
                    add(third, at: note.beat, length: ring, level: rng.rangeF(innerVoice), from: note)
                }
            }
        }
        return out.sorted { $0.beat == $1.beat ? $0.midi < $1.midi : $0.beat < $1.beat }
    }
}
