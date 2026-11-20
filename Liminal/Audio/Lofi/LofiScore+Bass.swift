import Foundation

nonisolated extension LofiScore {
    /// Structural bass accents look this far (in beats) for a played kick to lock to.
    static let bassAccentWindow = 0.12
    /// Kicks below this confidence never move a structural bass accent.
    static let bassAccentConfidence: Float = 0.6

    static func bassLine(harmony: Harmony, section: Section, random: MusicRNG, kickBeats: [Double],
                                 timing: LofiTimingField?, timingStartBeat: Int, voice: LofiBassVoice,
                                 beatSeconds: Double) -> (notes: [Note], anchors: [BassAnchor]) {
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
        guard let timing else {
            let notes = figures.map { figure in
                // Follow nearby played kicks, retaining the phrase's laid-back offset on pickups.
                // Distant fills and extra kicks never add notes or displace a structural bass entrance.
                let nearest = kickBeats.min { abs($0 - figure.beat) < abs($1 - figure.beat) }
                let anchor = nearest.flatMap { abs($0 - figure.beat) <= 0.075 ? $0 : nil } ?? figure.beat
                return Note(part: .bass, midi: figure.midi, beat: anchor + (figure.beat == 0 ? 0 : pocket),
                            length: figure.length, velocity: figure.strength, send: 0)
            }
            return (notes, [])
        }
        // Structural accents put their low-band rise on the low-band rise of a confident played kick
        // nearby. Everything else keeps the pocket and leans with the drummer's local timing.
        let kicks = kickRises(timing, phraseStartBeat: timingStartBeat)
        var anchors: [BassAnchor] = []
        var notes = figures.map { figure -> Note in
            let beat: Double
            if figure.beat == 0 || figure.beat == 8 {
                let kick = kicks.filter { abs($0.attack - figure.beat) <= bassAccentWindow }
                    .min { abs($0.attack - figure.beat) < abs($1.attack - figure.beat) }
                if let kick {
                    let lead = voice.lowRiseLead(midi: figure.midi) / beatSeconds
                    beat = max(0, kick.lowRise - lead)
                    anchors.append(.init(noteBeat: beat, kickBeat: kick.attack, kickLowRiseBeat: kick.lowRise,
                                         bassLowRiseBeats: lead))
                } else {
                    beat = figure.beat
                }
            } else {
                let lean = timing.offset(atBeat: Double(timingStartBeat) + figure.beat)
                beat = figure.beat + pocket + min(bassAccentWindow, max(-bassAccentWindow, lean))
            }
            return Note(part: .bass, midi: figure.midi, beat: beat, length: figure.length,
                        velocity: figure.strength, send: 0)
        }
        // A note running into an anchored accent smears its attack (a 7.5-beat pickup held 0.55 beats
        // still sounded under the downbeat): it ends early enough that its release has faded by then.
        let release = (voice == .classic ? 0.31 : voice.recipe.release) / beatSeconds
        let clearance = release + bassAccentClearance / beatSeconds
        for i in notes.indices {
            guard let next = anchors.first(where: { $0.noteBeat > notes[i].beat })?.noteBeat else { continue }
            let room = next - notes[i].beat - clearance
            if notes[i].length > room {
                let note = notes[i]
                notes[i] = Note(part: .bass, midi: note.midi, beat: note.beat, length: max(bassShortestLength, room),
                                velocity: note.velocity, send: 0)
            }
        }
        return (notes, anchors)
    }

    /// A structural accent's predecessor is silent this long (seconds) before the accent starts.
    static let bassAccentClearance = 0.030
    /// A shortened bass note keeps at least this many beats of sustain.
    static let bassShortestLength = 0.12

    /// Phrase-local beats of the attack and the low-band rise of each confident kick in the phrase,
    /// with the frame arithmetic of `LofiTimingField.kicks`.
    static func kickRises(_ timing: LofiTimingField, phraseStartBeat: Int) -> [(attack: Double, lowRise: Double)] {
        let fpb = timing.framesPerBeat
        guard fpb > 0 else { return [] }
        let start = Int((Double(phraseStartBeat) * fpb).rounded())
        let end = start + timing.phraseFrames
        return timing.landmarks.compactMap { landmark in
            guard landmark.kind == .kick, landmark.confidence >= bassAccentConfidence,
                  (start..<end).contains(landmark.attackFrame) else { return nil }
            return (Double(landmark.attackFrame - start) / fpb, Double(landmark.lowRiseFrame - start) / fpb)
        }
    }
}
