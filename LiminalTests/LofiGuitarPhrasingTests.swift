import Foundation
import Testing
@testable import Liminal

/// Guitar programs play guitar figures around the scored melody (D114): strums, fingerpicked
/// broken chords, double stops and grace notes, without changing the melody or the bass.
struct LofiGuitarPhrasingTests {
    private let beatSeconds = 60.0 / 72

    private func score(_ phrase: Int, seed: UInt64) -> LofiScore {
        .make(seed: seed, section: LofiScore.section(at: phrase), drift: .init(seed: seed),
              startBeat: Double(phrase) * LofiClock.beats, beatSeconds: beatSeconds)
    }

    private func guitarScores(seeds: Range<UInt64>) -> [LofiScore] {
        seeds.flatMap { seed in (0..<16).map { score($0, seed: seed) } }.filter { $0.preset.family == .guitar }
    }

    @Test func onlyGuitarProgramsAddOrnamentsAndTheyStayInsideThePhrase() {
        var guitars = 0
        for seed in 0..<24 as Range<UInt64> {
            for phrase in 0..<16 {
                let current = score(phrase, seed: seed)
                let ornaments = current.notes.filter { $0.part == .ornament }
                guard current.preset.family == .guitar else {
                    #expect(ornaments.isEmpty)
                    continue
                }
                guitars += 1
                let mask = current.scale.pitchClassMask(tonic: current.tonic)
                for note in ornaments {
                    #expect(mask & (1 << (note.midi % 12)) != 0)
                    #expect(note.midi >= LofiGuitarPhrasing.lowestPitch && note.midi <= 72)
                    #expect(note.beat >= 0 && note.beat + note.length <= LofiScore.midLatestEnd + 1e-9)
                    #expect(note.beat + note.length <= current.endingRest.lowerBound + 1e-9)
                    #expect(note.velocity > 0 && note.velocity < 0.65)
                }
                // Mid shells never double an ornament attack either.
                for shell in current.notes where shell.part == .texture {
                    #expect(ornaments.allSatisfy { abs($0.beat - shell.beat) >= LofiScore.midOnsetClearance - 1e-9 })
                }
            }
        }
        #expect(guitars > 40)
    }

    @Test func ornamentsLeaveTheMelodyAndBassExactlyAsScored() {
        // The same phrase scored for a non-guitar program shares melody and bass with the guitar one:
        // compare a guitar phrase with the melody the score would hand any program.
        for current in guitarScores(seeds: 0..<16) {
            let lead = current.notes.filter { $0.part == .lead }
            #expect((3...6).contains(lead.count))
            #expect(zip(lead, lead.dropFirst()).allSatisfy { $0.beat + $0.length < $1.beat })
            for note in current.notes where note.part == .ornament {
                // No ornament sounds the melody's own pitch at the melody's own onset.
                #expect(!lead.contains { $0.midi == note.midi && abs($0.beat - note.beat) < 1e-9 })
            }
        }
    }

    @Test func guitarsStrumPickAndOrnamentDeterministically() {
        var down = 0, up = 0, arpeggios = 0, graces = 0, doubleStops = 0
        let spread = (LofiGuitarPhrasing.strumSpread.lowerBound / 1000 / beatSeconds - 1e-9)...(LofiGuitarPhrasing.strumSpread.upperBound / 1000 / beatSeconds + 1e-9)
        for current in guitarScores(seeds: 0..<32) {
            let lead = current.notes.filter { $0.part == .lead }
            let ornaments = current.notes.filter { $0.part == .ornament }
            for note in lead {
                let under = ornaments.filter { $0.midi < note.midi && abs($0.beat - note.beat) <= 0.12 && $0.length > 0.2 }
                    .sorted { $0.midi > $1.midi }
                if under.count >= 2 {
                    // Adjacent strings are one stagger apart, low to high (down) or high to low (up).
                    let gaps = zip(under, under.dropFirst()).map { $0.beat - $1.beat }
                    if gaps.allSatisfy({ spread.contains($0) }) { down += 1 }
                    if gaps.allSatisfy({ spread.contains(-$0) }) { up += 1 }
                } else if under.count == 1, under[0].beat == note.beat {
                    doubleStops += 1
                }
                if ornaments.contains(where: { $0.beat < note.beat && note.beat - $0.beat < 0.2 && $0.length < 0.2
                    && (1...2).contains(note.midi - $0.midi) }) {
                    graces += 1
                }
            }
            let rising = ornaments.filter { o in lead.allSatisfy { abs($0.beat - o.beat) > 0.3 } }
            if rising.count >= 2, zip(rising, rising.dropFirst()).contains(where: { $1.midi > $0.midi }) { arpeggios += 1 }
        }
        #expect(down > 10)
        #expect(up > 2)
        #expect(arpeggios > 10)
        #expect(graces > 10)
        #expect(doubleStops > 3)
        // Same seed, same figures.
        #expect(guitarScores(seeds: 3..<5) == guitarScores(seeds: 3..<5))
    }
}
