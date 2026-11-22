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
                // Same notes, onsets, velocities and articulation; only the reveal of the first two differs.
                #expect(first.map(\.midi) == reprise.map(\.midi))
                #expect(first.map(\.beat) == reprise.map(\.beat))
                #expect(first.map(\.velocity) == reprise.map(\.velocity))
                #expect(first.map(\.length) == reprise.map(\.length))
                #expect(first.map(\.articulation) == reprise.map(\.articulation))
                #expect(Array(first.dropFirst(2)) == Array(reprise.dropFirst(2)))
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
                // The held pad sounds under the ending rest (D117); everything else ends before it.
                let mids = current.notes.filter { $0.part != .bass }
                #expect(mids.filter { $0.articulation != .pad }.allSatisfy { $0.beat + $0.length <= current.endingRest.lowerBound })
                #expect(notes.allSatisfy { (53...72).contains($0.midi) })
                // Rewritten for the riddim line (plan 2.8): structural notes in 28...41, octave ornaments up to 53.
                let bassNotes = current.notes.filter { $0.part == .bass }
                #expect(bassNotes.allSatisfy { (28...53).contains($0.midi) })
                #expect(bassNotes.filter { $0.midi > 41 }.allSatisfy { $0.stroke == .thump || $0.stroke == .ghost })
                #expect(bassNotes.filter { $0.midi > 41 }.count <= 2)
                #expect(zip(notes, notes.dropFirst()).allSatisfy { first, second in
                    second.beat - first.beat >= 0.49 && first.beat + first.length < second.beat
                })
                #expect((3...6).contains(notes.count))
                if current.section == .breakdown {
                    #expect(notes.count == 4)
                    #expect(notes.last?.beat ?? 0 > 10)
                } else {
                    // Rewritten for the held pad (D117): two or three held voices and one revoicing, plus at
                    // most one two-note answer shell (it was two to four shell pairs).
                    let shells = mids.filter { $0.part == .texture && $0.articulation != .pad }.count
                    let pad = mids.filter { $0.articulation == .pad }.count
                    #expect(shells == 0 || shells == 2)
                    #expect((2...4).contains(pad))
                }
            }
        }
    }

    @Test func eachTakeContainsThreeInstrumentFamiliesAndPianoReturns() throws {
        let bank = LofiSampleBank.bundled
        let programs = (0..<48).map { LofiPreset.selection(seed: 32, phrase: $0) }
        #expect(Set(programs.prefix(16).map(\.name)).count == 12)
        // D114 groups are named by measured concert pitch.
        let concertRoots = [
            "kawai": [48, 52, 56, 60, 64, 68, 72],
            "folkharp": [48, 52, 56, 60, 64, 68, 72],
            "nylon": [48, 52, 55, 59, 62, 65, 69, 71],
            "osiris": [48, 52, 57, 60, 64, 69, 72],
            "uprightkw": [48, 54, 57, 60, 63, 66, 69, 72],
            "steel": [46, 52, 55, 58, 61, 64, 68],
            "archtop": [45, 48, 54, 57, 60, 63, 66, 72],
            "jazzbox": [45, 48, 54, 57, 60, 63, 66, 72],
            "flatwound": [45, 51, 57, 60, 63, 66, 72]
        ]
        let everyProgram = (0..<400).map { LofiPreset.selection(seed: 32, phrase: $0) }
        #expect(Set(everyProgram.map(\.name)).count == 20)
        #expect(Set(everyProgram.map(\.family)) == [.piano, .strings, .guitar])
        let removed: Set<String> = ["fmkeys", "vibes", "marimba", "organ", "bassrec", "psaltery"]
        #expect(everyProgram.allSatisfy { !removed.contains($0.sampleGroup) })
        for (group, roots) in concertRoots {
            let preset = try #require(everyProgram.first { $0.sampleGroup == group })
            for root in roots {
                let sample = try #require(bank.sample(for: preset, midi: root))
                #expect(sample.root == root && sample.recordedRoot == root)
            }
        }
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

    /// Rewritten for the riddim line (plan 2.8). Legacy path: without a timing field, notes on the kick
    /// grid snap to played kicks within 0.075 beats and nothing else moves. Timing-field path: an
    /// unconfident kick never anchors; a confident one anchors its note by its low-band rise; no other
    /// part moves.
    @Test func bassFollowsNearbyPlayedKicksWithoutAddingOrMovingOtherParts() throws {
        func phrase(_ hits: [Double]) -> LofiScore {
            .make(seed: 42, section: .returnTheme, drift: .init(seed: 42), startBeat: 48, kickBeats: hits)
        }
        let played = phrase([0.04, 2.5, 3.95, 8.24])
        let grid = phrase([0, 2.5, 4, 8.25])
        let after = played.notes.filter { $0.part == .bass }
        let before = grid.notes.filter { $0.part == .bass }
        #expect(after.map(\.midi) == before.map(\.midi))
        #expect(abs(after[0].beat - 0.04) < 1e-9)
        for (a, b) in zip(after, before) { #expect(abs(a.beat - b.beat) <= 0.075 + 1e-9) }
        #expect(played.notes.filter { $0.part != .bass } == grid.notes.filter { $0.part != .bass })

        let clock = LofiClock(tempo: 70, sampleRate: 48_000)
        func field(_ hits: [(Double, Float)]) -> LofiTimingField {
            LofiTimingField(landmarks: hits.map { beat, confidence in
                let frame = 48 * clock.frameCount / 16 + clock.frame(at: beat)
                return LofiDrumLandmark(kind: .kick, attackFrame: frame, peakFrame: frame + 200,
                                        strength: 1, confidence: confidence)
            }, clock: clock)
        }
        func timed(_ hits: [(Double, Float)]) -> LofiScore {
            .make(seed: 42, section: .returnTheme, drift: .init(seed: 42), startBeat: 48, kickBeats: [0.04, 8.24],
                  timing: field(hits), timingStartBeat: 48, beatSeconds: clock.beatDuration)
        }
        let locked = timed([(0.10, 0.9), (2.5, 0.9), (8.3, 0.4)])
        let bass = locked.notes.filter { $0.part == .bass }
        // A synthetic landmark's low-band rise is its attack; the voice's own low-band rise leads it.
        let lead = locked.bassVoice.lowRiseLead(midi: bass[0].midi, stroke: bass[0].stroke,
                                                struck: bass[0].strike > 0) / clock.beatDuration
        #expect(abs(bass[0].beat - max(0, Double(clock.frame(at: 0.10)) / clock.framesPerBeat - lead)) < 1e-9)
        #expect(locked.bassAnchors.count >= 1 && locked.bassAnchors.first?.noteBeat == bass[0].beat)
        #expect(!locked.bassAnchors.contains { abs($0.kickBeat - 8.3) < 0.01 })
        // The held pad's end follows the beat length (D117), and `grid` is scored at the default tempo while
        // `locked` passes 70 BPM, so the pad is compared apart from its length.
        func unmoved(_ score: LofiScore) -> [LofiScore.Note] {
            score.notes.filter { $0.part != .bass }.map { note in
                note.articulation == .pad
                    ? LofiScore.Note(part: note.part, midi: note.midi, beat: note.beat, length: 0, velocity: note.velocity,
                                     color: note.color, send: note.send, articulation: .pad) : note
            }
        }
        #expect(unmoved(locked) == unmoved(grid))
    }

    @Test(arguments: ["kawai", "osiris", "uprightkw", "nylon", "steel", "archtop", "jazzbox", "flatwound", "upright"])
    func sampledProgramsPlayTheirIntendedOctave(group: String) throws {
        let program = try #require((0..<400).map { LofiPreset.selection(seed: 32, phrase: $0) }
            .first { $0.sampleGroup == group })
        let sample = try #require(LofiSampleBank.bundled.sample(for: program, midi: 60))
        let clock = LofiClock(tempo: 70, sampleRate: 16_000)
        let c4 = LofiScore.Note(part: .lead, midi: 60, beat: 0, length: 1, velocity: 0.55)
        var left = [Float](repeating: 0, count: 12_000)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                LofiSampleBank.add(c4, from: sample, preset: program, clock: clock, left: l, right: r)
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
        // C4 must be present; an octave error would leave 261.63 Hz near silent.
        #expect(amplitude(near: 261.63) > 0.3 * amplitude(near: 523.25), "\(group)")
        #expect(amplitude(near: 261.63) > 5 * amplitude(near: 130.81), "\(group)")
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
}
