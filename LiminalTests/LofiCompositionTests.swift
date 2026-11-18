import Foundation
import Testing
@testable import Liminal

struct LofiCompositionTests {
    private func score(_ phrase: Int, seed: UInt64, scale: ScaleType? = nil) -> LofiScore {
        .make(seed: seed, section: LofiScore.section(at: phrase), drift: .init(seed: seed),
              startBeat: Double(phrase) * LofiClock.beats, pinnedScale: scale)
    }

    private func melody(_ score: LofiScore) -> [LofiScore.Note] {
        score.notes.filter { $0.part == .lead }
    }

    @Test func aReturnRecallsTheHookAndAVariationRephrasesItsAnswer() throws {
        for seed in 0..<24 as Range<UInt64> {
            let statement = melody(score(0, seed: seed))
            let varied = melody(score(1, seed: seed))
            for (opening, returning) in [(0, 3), (4, 7)] {
                let first = melody(score(opening, seed: seed))
                let reprise = melody(score(returning, seed: seed))
                #expect(first == reprise)
            }
            #expect(statement.prefix(3).map(\.midi) == varied.prefix(3).map(\.midi))
            #expect(statement.prefix(3).map(\.beat) == varied.prefix(3).map(\.beat))
            #expect(statement.dropFirst(3).map(\.beat) != varied.dropFirst(3).map(\.beat))
            #expect(statement.last?.midi == varied.last?.midi)
            let destination = try #require(statement.last)
            #expect(destination.midi % 12 == score(0, seed: seed).tonic)
            #expect(statement.dropLast().allSatisfy { $0.send < destination.send })
        }
    }

    @Test func harmonyAndArrangementRemainValidForEveryPinnedScale() throws {
        for mode in ScaleType.allCases {
            for phrase in 0..<LofiScore.phrasesPerForm {
                let current = score(phrase, seed: 462, scale: mode)
                #expect(current.tonic == 0)
                #expect(current.scale == mode)
                #expect(current.notes.allSatisfy { mode.intervals.contains($0.midi % 12) })
                let notes = melody(current)
                let mids = current.notes.filter { $0.part != .bass }
                #expect(mids.allSatisfy { $0.beat + $0.length <= current.endingRest.lowerBound })
                #expect(notes.allSatisfy { (53...72).contains($0.midi) })
                #expect(current.notes.filter { $0.part == .bass }.allSatisfy { (28...41).contains($0.midi) })
                #expect(zip(notes, notes.dropFirst()).allSatisfy { first, second in
                    second.beat - first.beat >= 0.49 && first.beat + first.length < second.beat
                })
                #expect((3...6).contains(notes.count))
                if current.section == .breakdown {
                    #expect(notes.count == 4)
                    #expect(notes.last?.beat ?? 0 > 10)
                } else {
                    #expect(mids.filter { $0.part == .texture }.count == 2)
                }
            }
        }
    }

    @Test func eachTakeContainsThreeInstrumentFamiliesAndPianoReturns() throws {
        let bank = LofiSampleBank.bundled
        let programs = (0..<48).map { LofiPreset.selection(seed: 32, phrase: $0) }
        #expect(Set(programs.map(\.name)).count == 8)
        for start in stride(from: 0, to: programs.count, by: 4) {
            let voices = Array(programs[start..<(start + 4)])
            #expect(voices[0].family == .piano && voices[0] == voices[3])
            #expect(Set(voices.map(\.family)).count == 3)
            #expect(voices.allSatisfy { bank.count(for: $0) >= 4 })
        }
        let grand = try #require(programs.first { $0.sampleGroup == "grand" })
        let pianoPhrase = try #require((0..<48).first { programs[$0] == grand })
        let playedLayers = Set(melody(score(pianoPhrase, seed: 32)).compactMap {
            bank.sample(for: grand, midi: $0.midi, velocity: $0.velocity)?.layer
        })
        #expect(playedLayers == [2, 3])
        for root in [48, 54, 58, 62, 64, 70, 72] {
            let soft = try #require(bank.sample(for: grand, midi: root, velocity: 0.53))
            let accented = try #require(bank.sample(for: grand, midi: root, velocity: 0.65))
            #expect(soft.root == root && accented.root == root)
            #expect(soft.layer == 2 && accented.layer == 3)
            #expect(soft.pcm != accented.pcm)
        }
    }

    @Test func bassFollowsNearbyPlayedKicksWithoutAddingOrMovingOtherParts() {
        func phrase(_ hits: [Double]) -> LofiScore {
            .make(seed: 42, section: .returnTheme, drift: .init(seed: 42), startBeat: 48, kickBeats: hits)
        }
        let grid = phrase([])
        let played = phrase([0.04, 2.5, 3.95, 8.24])
        let before = grid.notes.filter { $0.part == .bass }
        let after = played.notes.filter { $0.part == .bass }
        #expect(before.map(\.midi) == after.map(\.midi))
        #expect(abs(after[0].beat - before[0].beat - 0.04) < 1e-9)
        #expect(abs(after[1].beat - before[1].beat + 0.05) < 1e-9)
        #expect(after[2] == before[2])
        #expect(played.notes.filter { $0.part != .bass } == grid.notes.filter { $0.part != .bass })
    }

    @Test func quietOrganPlaysItsIntendedOctave() throws {
        let organ = try #require((0..<8).map { LofiPreset.selection(seed: 32, phrase: $0) }
            .first { $0.sampleGroup == "organ" })
        let sample = try #require(LofiSampleBank.bundled.sample(for: organ, midi: 60))
        let clock = LofiClock(tempo: 70, sampleRate: 16_000)
        let c4 = LofiScore.Note(part: .lead, midi: 60, beat: 0, length: 1, velocity: 0.62)
        var left = [Float](repeating: 0, count: 12_000)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                LofiSampleBank.add(c4, from: sample, preset: organ, clock: clock, left: l, right: r)
            }
        }
        func amplitude(near frequency: Double) -> Double {
            let slice = 3_000..<7_000
            var real = 0.0
            var imaginary = 0.0
            for frame in slice {
                let phase = 2 * Double.pi * frequency * Double(frame) / clock.sampleRate
                let position = Double(frame - slice.lowerBound) / Double(slice.count)
                let value = Double(left[frame]) * (0.5 - 0.5 * cos(2 * Double.pi * position))
                real += value * cos(phase)
                imaginary += value * sin(phase)
            }
            return hypot(real, imaginary)
        }
        #expect(amplitude(near: 261.63) > 5 * amplitude(near: 523.25))
    }

    @Test func virtualRecordsKeepTheirProvenanceAndEditOnlyThePlannedGap() throws {
        var styles = Set<LofiVirtualRecord.Edit.Style>()
        for seed in 0..<32 as Range<UInt64> {
            for phrase in 0..<8 {
                let current = score(phrase, seed: seed)
                guard let edit = current.virtualRecord else { continue }
                styles.insert(edit.style)
                #expect(current.section == .variation || current.section == .returnTheme)
                #expect(edit.program == current.preset.sampleGroup)
                #expect(edit.destinationBeat + edit.duration < min(15.5, current.endingRest.lowerBound + 1.25))
                let lead = melody(current)
                #expect(lead.contains { $0.midi == edit.sourceMIDI && $0.beat == edit.sourceBeat })
                #expect(lead.allSatisfy { note in
                    note.beat + note.length < edit.destinationBeat || note.beat > edit.destinationBeat + edit.duration
                })
                let encoded = try JSONEncoder().encode(edit)
                #expect(try JSONDecoder().decode(LofiVirtualRecord.Edit.self, from: encoded) == edit)
            }
        }
        #expect(styles.count == LofiVirtualRecord.Edit.Style.allCases.count)
    }

    @Test func virtualRecordSplicesHaveSoftEdgesAndPreserveTheDrySource() {
        let clock = LofiClock(tempo: 70, sampleRate: 8_000)
        let captureStart = clock.frame(at: 1.052)
        let sourceLeft = (0..<clock.frameCount).map { frame in
            min(0.6, max(0, Float(frame - captureStart) * 0.00022))
        }
        let source = (left: sourceLeft, right: sourceLeft.map { -0.5 * $0 })
        let quiet = [Float](repeating: 0, count: clock.frameCount)
        var earlyAmplitude: [LofiVirtualRecord.Edit.Style: Float] = [:]
        for style in LofiVirtualRecord.Edit.Style.allCases {
            let edit = LofiVirtualRecord.Edit(schema: 1, seed: 42, program: "grand", style: style,
                                              sourceMIDI: 60, sourceBeat: 1, sourceOffset: 0.052,
                                              duration: 0.40, destinationBeat: 4, gain: 0.32)
            var send = (left: quiet, right: quiet)
            LofiVirtualRecord.splice(edit, from: source, into: &send, clock: clock)
            let first = clock.frame(at: 4)
            let last = first + clock.frame(at: edit.duration) - 1
            #expect(send.left[0...first].allSatisfy { $0 == 0 })
            #expect(send.left[last...].allSatisfy { $0 == 0 })
            #expect((send.left[first...last].max() ?? 0) > 0.04)
            #expect((send.right[first...last].min() ?? 0) < -0.02)
            #expect(source.left == sourceLeft)
            earlyAmplitude[style] = send.left[first + (last - first) / 3]
        }
        #expect(earlyAmplitude[.reverse, default: 0] > earlyAmplitude[.replay, default: 0])
        #expect(earlyAmplitude[.replay, default: 0] > earlyAmplitude[.halfSpeed, default: 0])
    }

    @Test func oldTempoOnlySettingsStillDecode() throws {
        let options = try JSONDecoder().decode(LofiOptions.self, from: Data(#"{"tempo":71}"#.utf8))
        #expect(options.tempo == 71)
        #expect(options.scale == nil)
    }
}
