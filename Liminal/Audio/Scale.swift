import Foundation

/// Musical scale definitions for generative composition.
/// Scales constrain note selection to musically coherent sets.
enum ScaleType: String, CaseIterable {
    case pentatonicMajor = "Pentatonic Major"
    case pentatonicMinor = "Pentatonic Minor"
    case major = "Major"
    case minor = "Natural Minor"
    case dorian = "Dorian"
    case mixolydian = "Mixolydian"
    case lydian = "Lydian"

    /// Semitone intervals from root (0 = root)
    var intervals: [Int] {
        switch self {
        case .pentatonicMajor:
            return [0, 2, 4, 7, 9]           // C D E G A
        case .pentatonicMinor:
            return [0, 3, 5, 7, 10]          // C Eb F G Bb
        case .major:
            return [0, 2, 4, 5, 7, 9, 11]    // C D E F G A B
        case .minor:
            return [0, 2, 3, 5, 7, 8, 10]    // C D Eb F G Ab Bb
        case .dorian:
            return [0, 2, 3, 5, 7, 9, 10]    // C D Eb F G A Bb
        case .mixolydian:
            return [0, 2, 4, 5, 7, 9, 10]    // C D E F G A Bb
        case .lydian:
            return [0, 2, 4, 6, 7, 9, 11]    // C D E F# G A B
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
