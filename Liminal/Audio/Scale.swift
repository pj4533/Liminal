import Foundation

/// Musical scale definitions for generative composition.
/// Scales constrain note selection to musically coherent sets.
enum ScaleType: String, CaseIterable {
    // MARK: - Western Modes
    case major = "Major (Ionian)"
    case dorian = "Dorian"
    case phrygian = "Phrygian"
    case lydian = "Lydian"
    case mixolydian = "Mixolydian"
    case minor = "Natural Minor (Aeolian)"
    case locrian = "Locrian"

    // MARK: - Harmonic & Melodic
    case harmonicMinor = "Harmonic Minor"
    case melodicMinor = "Melodic Minor"
    case harmonicMajor = "Harmonic Major"

    // MARK: - Pentatonic
    case pentatonicMajor = "Pentatonic Major"
    case pentatonicMinor = "Pentatonic Minor"
    case pentatonicBlues = "Blues Pentatonic"
    case pentatonicEgyptian = "Egyptian (Suspended)"
    case pentatonicChinese = "Chinese"
    case pentatonicPygmy = "Pygmy"

    // MARK: - Blues & Jazz
    case blues = "Blues"
    case bebopDominant = "Bebop Dominant"
    case bebopMajor = "Bebop Major"
    case lydianDominant = "Lydian Dominant"
    case altered = "Altered (Super Locrian)"

    // MARK: - Japanese
    case hirajoshi = "Hirajoshi"
    case iwato = "Iwato"
    case kumoi = "Kumoi"
    case insen = "In Sen"
    case yo = "Yo"

    // MARK: - Middle Eastern & Arabic
    case doubleHarmonic = "Double Harmonic (Byzantine)"
    case phrygianDominant = "Phrygian Dominant (Hijaz)"
    case persian = "Persian"
    case arabian = "Arabian"

    // MARK: - Eastern European
    case hungarianMinor = "Hungarian Minor (Gypsy)"
    case hungarianMajor = "Hungarian Major"
    case ukrainian = "Ukrainian Dorian"
    case romanian = "Romanian Minor"
    case neapolitanMinor = "Neapolitan Minor"
    case neapolitanMajor = "Neapolitan Major"

    // MARK: - Symmetric
    case wholeTone = "Whole Tone"
    case diminishedWH = "Diminished (W-H)"
    case diminishedHW = "Diminished (H-W)"
    case augmented = "Augmented"
    case chromatic = "Chromatic"

    // MARK: - Exotic & Experimental
    case enigmatic = "Enigmatic"
    case prometheus = "Prometheus"
    case tritone = "Tritone"
    case balinese = "Balinese (Pelog)"
    case javanese = "Javanese"
    case hindu = "Hindu (Aeolian Dominant)"
    case spanish8 = "Spanish 8-Tone"

    /// Semitone intervals from root (0 = root)
    var intervals: [Int] {
        switch self {
        // Western Modes
        case .major:
            return [0, 2, 4, 5, 7, 9, 11]           // C D E F G A B
        case .dorian:
            return [0, 2, 3, 5, 7, 9, 10]           // C D Eb F G A Bb
        case .phrygian:
            return [0, 1, 3, 5, 7, 8, 10]           // C Db Eb F G Ab Bb
        case .lydian:
            return [0, 2, 4, 6, 7, 9, 11]           // C D E F# G A B
        case .mixolydian:
            return [0, 2, 4, 5, 7, 9, 10]           // C D E F G A Bb
        case .minor:
            return [0, 2, 3, 5, 7, 8, 10]           // C D Eb F G Ab Bb
        case .locrian:
            return [0, 1, 3, 5, 6, 8, 10]           // C Db Eb F Gb Ab Bb

        // Harmonic & Melodic
        case .harmonicMinor:
            return [0, 2, 3, 5, 7, 8, 11]           // C D Eb F G Ab B
        case .melodicMinor:
            return [0, 2, 3, 5, 7, 9, 11]           // C D Eb F G A B
        case .harmonicMajor:
            return [0, 2, 4, 5, 7, 8, 11]           // C D E F G Ab B

        // Pentatonic
        case .pentatonicMajor:
            return [0, 2, 4, 7, 9]                  // C D E G A
        case .pentatonicMinor:
            return [0, 3, 5, 7, 10]                 // C Eb F G Bb
        case .pentatonicBlues:
            return [0, 3, 5, 6, 7, 10]              // C Eb F Gb G Bb
        case .pentatonicEgyptian:
            return [0, 2, 5, 7, 10]                 // C D F G Bb (suspended)
        case .pentatonicChinese:
            return [0, 4, 6, 7, 11]                 // C E F# G B
        case .pentatonicPygmy:
            return [0, 2, 3, 7, 10]                 // C D Eb G Bb

        // Blues & Jazz
        case .blues:
            return [0, 3, 5, 6, 7, 10]              // C Eb F Gb G Bb
        case .bebopDominant:
            return [0, 2, 4, 5, 7, 9, 10, 11]       // C D E F G A Bb B
        case .bebopMajor:
            return [0, 2, 4, 5, 7, 8, 9, 11]        // C D E F G Ab A B
        case .lydianDominant:
            return [0, 2, 4, 6, 7, 9, 10]           // C D E F# G A Bb
        case .altered:
            return [0, 1, 3, 4, 6, 8, 10]           // C Db Eb Fb Gb Ab Bb

        // Japanese
        case .hirajoshi:
            return [0, 2, 3, 7, 8]                  // C D Eb G Ab
        case .iwato:
            return [0, 1, 5, 6, 10]                 // C Db F Gb Bb
        case .kumoi:
            return [0, 2, 3, 7, 9]                  // C D Eb G A
        case .insen:
            return [0, 1, 5, 7, 10]                 // C Db F G Bb
        case .yo:
            return [0, 2, 5, 7, 9]                  // C D F G A

        // Middle Eastern & Arabic
        case .doubleHarmonic:
            return [0, 1, 4, 5, 7, 8, 11]           // C Db E F G Ab B
        case .phrygianDominant:
            return [0, 1, 4, 5, 7, 8, 10]           // C Db E F G Ab Bb
        case .persian:
            return [0, 1, 4, 5, 6, 8, 11]           // C Db E F Gb Ab B
        case .arabian:
            return [0, 2, 4, 5, 6, 8, 10]           // C D E F Gb Ab Bb

        // Eastern European
        case .hungarianMinor:
            return [0, 2, 3, 6, 7, 8, 11]           // C D Eb F# G Ab B
        case .hungarianMajor:
            return [0, 3, 4, 6, 7, 9, 10]           // C D# E F# G A Bb
        case .ukrainian:
            return [0, 2, 3, 6, 7, 9, 10]           // C D Eb F# G A Bb
        case .romanian:
            return [0, 2, 3, 6, 7, 9, 10]           // C D Eb F# G A Bb
        case .neapolitanMinor:
            return [0, 1, 3, 5, 7, 8, 11]           // C Db Eb F G Ab B
        case .neapolitanMajor:
            return [0, 1, 3, 5, 7, 9, 11]           // C Db Eb F G A B

        // Symmetric
        case .wholeTone:
            return [0, 2, 4, 6, 8, 10]              // C D E F# G# A#
        case .diminishedWH:
            return [0, 2, 3, 5, 6, 8, 9, 11]        // W-H pattern
        case .diminishedHW:
            return [0, 1, 3, 4, 6, 7, 9, 10]        // H-W pattern
        case .augmented:
            return [0, 3, 4, 7, 8, 11]              // C Eb E G Ab B
        case .chromatic:
            return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

        // Exotic & Experimental
        case .enigmatic:
            return [0, 1, 4, 6, 8, 10, 11]          // C Db E F# G# A# B
        case .prometheus:
            return [0, 2, 4, 6, 9, 10]              // C D E F# A Bb
        case .tritone:
            return [0, 1, 4, 6, 7, 10]              // C Db E Gb G Bb
        case .balinese:
            return [0, 1, 3, 7, 8]                  // C Db Eb G Ab
        case .javanese:
            return [0, 1, 3, 5, 7, 9, 10]           // C Db Eb F G A Bb
        case .hindu:
            return [0, 2, 4, 5, 7, 8, 10]           // C D E F G Ab Bb
        case .spanish8:
            return [0, 1, 3, 4, 5, 6, 8, 10]        // C Db Eb E F Gb Ab Bb
        }
    }
}

/// A musical scale rooted at a specific note.
struct Scale {
    let type: ScaleType
    let rootMIDI: Int  // MIDI note number (60 = middle C)

    /// Get all MIDI notes in this scale across a range of octaves
    func notesInRange(lowMIDI: Int, highMIDI: Int) -> [Int] {
        var notes: [Int] = []

        // Start from lowest octave that could contain notes
        let lowestOctaveRoot = (lowMIDI / 12) * 12

        for octaveRoot in stride(from: lowestOctaveRoot, through: highMIDI, by: 12) {
            for interval in type.intervals {
                let note = octaveRoot + (rootMIDI % 12) + interval
                if note >= lowMIDI && note <= highMIDI {
                    notes.append(note)
                }
            }
        }

        return notes.sorted()
    }

    /// Convert MIDI note to frequency in Hz
    static func midiToFrequency(_ midi: Int) -> Float {
        // A4 (MIDI 69) = 440 Hz
        return 440.0 * pow(2.0, Float(midi - 69) / 12.0)
    }

    /// Get frequency for a scale degree (0-indexed) in a specific octave
    func frequencyForDegree(_ degree: Int, octave: Int) -> Float {
        let intervals = type.intervals
        let octaveOffset = degree / intervals.count
        let degreeInOctave = degree % intervals.count

        let midi = rootMIDI + (octave * 12) + intervals[degreeInOctave] + (octaveOffset * 12)
        return Scale.midiToFrequency(midi)
    }

    /// Get a random note from the scale within a MIDI range
    func randomNote(lowMIDI: Int, highMIDI: Int) -> Int {
        let notes = notesInRange(lowMIDI: lowMIDI, highMIDI: highMIDI)
        return notes.randomElement() ?? rootMIDI
    }
}

// MARK: - Convenience

extension Scale {
    /// Common scales for ambient music
    static let cPentatonic = Scale(type: .pentatonicMajor, rootMIDI: 60)
    static let aPentatonicMinor = Scale(type: .pentatonicMinor, rootMIDI: 57)
    static let dDorian = Scale(type: .dorian, rootMIDI: 62)
    static let gMixolydian = Scale(type: .mixolydian, rootMIDI: 55)
}
