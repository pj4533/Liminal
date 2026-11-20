import Accelerate
import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Arrangement contracts: bass accents on the drummer's kicks with one voice per phrase,
/// mid shells that answer the melody, and a recognizable theme return.
///
/// Serialized because the full-length renders are CPU heavy: run in parallel they fill the
/// cooperative pool and starve the wall-clock deadline tests in the dialogue suites.
@Suite(.serialized)
struct LofiArrangementTests {
    private func score(_ phrase: Int, seed: UInt64, scale: ScaleType? = nil, timing: LofiTimingField? = nil,
                       clock: LofiClock = LofiClock(tempo: 70, sampleRate: 48_000)) -> LofiScore {
        .make(seed: seed, section: LofiScore.section(at: phrase), drift: .init(seed: seed),
              startBeat: Double(phrase) * LofiClock.beats, pinnedScale: scale, timing: timing,
              timingStartBeat: (phrase % LofiDrumTake.phraseCount) * Int(LofiClock.beats), beatSeconds: clock.beatDuration)
    }

    private func part(_ score: LofiScore, _ part: LofiScore.Part) -> [LofiScore.Note] {
        score.notes.filter { $0.part == part }
    }

    /// Kicks at the given take beats (absolute within the 64-beat take).
    private func field(_ hits: [(beat: Double, confidence: Float)], clock: LofiClock) -> LofiTimingField {
        LofiTimingField(landmarks: hits.map { hit in
            let frame = Int((hit.beat * clock.framesPerBeat).rounded())
            return LofiDrumLandmark(kind: .kick, attackFrame: frame, peakFrame: frame + 240, strength: 1,
                                    confidence: hit.confidence)
        }, clock: clock)
    }

    // MARK: Bass

    /// Rewritten for the riddim line (plan 2.8): every anchored note, not only beats 0 and 8, puts its
    /// 40-160 Hz rise within 2 ms of its kick's low rise; the other parts are identical with and without
    /// the timing field.
    @Test(arguments: [62.0, 70.0, 72.0, 81.0])
    func everyAnchoredBassNoteLandsItsRiseOnItsKick(tempo: Double) throws {
        let clock = LofiClock(tempo: tempo, sampleRate: 48_000)
        var voices = Set<LofiBassVoice>()
        var anchored = 0
        for seed in 0..<24 as Range<UInt64> {
            let timing = LofiBassLineTests.take(seed: seed, clock: clock)
            for phrase in 0..<8 {
                let current = score(phrase, seed: seed, timing: timing, clock: clock)
                let plain = score(phrase, seed: seed, clock: clock)
                voices.insert(current.bassVoice)
                let bass = part(current, .bass)
                for anchor in current.bassAnchors {
                    let note = try #require(bass.first { $0.beat == anchor.noteBeat })
                    let lead = current.bassVoice.lowRiseLead(midi: note.midi, stroke: note.stroke,
                                                             struck: note.strike > 0) * clock.sampleRate
                    let kickFrame = anchor.kickLowRiseBeat * clock.framesPerBeat
                    // A note whose rise is longer than its kick's offset into the phrase starts on frame 0.
                    if lead > kickFrame {
                        #expect(note.beat == 0)
                        continue
                    }
                    let rise = Double(clock.frame(at: note.beat)) + lead
                    #expect(abs(rise - kickFrame) / clock.sampleRate < 0.002,
                            "seed \(seed) phrase \(phrase) note \(note.beat): \(rise - kickFrame) frames, \(current.bassVoice)")
                    anchored += 1
                }
                #expect(current.notes.filter { $0.part != .bass } == plain.notes.filter { $0.part != .bass })
                #expect(bass.allSatisfy { $0.beat >= 0 && $0.beat + $0.length <= LofiClock.beats })
            }
        }
        BassReport.log("ARRANGEMENT anchored bass notes at \(tempo) BPM: \(anchored)")
        #expect(voices == [LofiBassTone.standard.voice])
    }

    /// Rewritten for the riddim line (plan 2.8): unconfident kicks never anchor, a note is never left
    /// within 0.20 beats of a confident kick (it moves onto it), and the downbeat stays on the grid when no
    /// confident kick is near it.
    @Test func bassNotesIgnoreUnconfidentKicksAndKeepClearOfConfidentOnes() {
        let clock = LofiClock(tempo: 70, sampleRate: 48_000)
        for seed in 0..<24 as Range<UInt64> {
            for phrase in 0..<8 {
                let start = Double((phrase % 4) * 16)
                let distant = field([(start + 0.3, 0.95), (start + 8.35, 0.95)], clock: clock)
                let unsure = field([(start + 0.05, 0.59), (start + 8.04, 0.3)], clock: clock)
                for (name, timing) in [("distant", distant), ("unsure", unsure)] {
                    let current = score(phrase, seed: seed, timing: timing, clock: clock)
                    let bass = part(current, .bass)
                    if name == "unsure" { #expect(current.bassAnchors.isEmpty) }
                    #expect(bass.first?.beat == 0, "seed \(seed) phrase \(phrase) \(name): downbeat at \(bass.first?.beat ?? -1)")
                    let kicks = timing.kicks(phraseStartBeat: Int(start), minConfidence: LofiScore.bassAccentConfidence)
                    for note in bass where !current.bassAnchors.contains(where: { $0.noteBeat == note.beat }) {
                        #expect(kicks.allSatisfy { abs($0 - note.beat) > LofiScore.bassKickSafety - 1e-9 })
                    }
                }
            }
        }
    }

    /// Rewritten for the bass tones (plan bass-tone-redo 7): every phrase plays `LofiBassTone.standard`,
    /// and the rendered bass stem equals `addBass` plus the chain sample for sample.
    @Test func everyPhrasePlaysTheStandardToneAndTheStemIsTheVoiceThroughTheChain() throws {
        for seed in 0..<100 as Range<UInt64> {
            for phrase in 0..<8 {
                #expect(score(phrase, seed: seed).bassVoice == LofiBassTone.standard.voice)
            }
        }

        let phrase = try LofiRenderer.render(seed: 5, section: .answer, options: .init(tempo: 70), sampleRate: 8_000,
                                             drift: .init(seed: 5), startBeat: 80)
        let n = phrase.clock.frameCount
        var left = [Float](repeating: 0, count: n), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                for note in part(phrase.score, .bass) {
                    LofiRenderer.addBass(note, score: phrase.score, clock: phrase.clock, samples: .bundled, left: l, right: r)
                }
                vDSP_vadd(l.baseAddress!, 1, r.baseAddress!, 1, l.baseAddress!, 1, vDSP_Length(n))
                var half: Float = 0.5
                vDSP_vsmul(l.baseAddress!, 1, &half, l.baseAddress!, 1, vDSP_Length(n))
                _ = LofiStemChains.applyBass(l.baseAddress!, count: n, sampleRate: phrase.clock.sampleRate)
            }
        }
        let rendered = try #require(phrase.bass.floatChannelData)
        let edge = Int(8_000 * 0.004) + 1
        for frame in edge..<(n - edge) where abs(left[frame]) < 0.7 {
            #expect(abs(rendered[0][frame] - left[frame]) < 1e-6)
        }
    }

    // MARK: Mids

    /// Rewritten for the held pad (D117, plan 3.1): the chord channel is a held two- or three-voice pad
    /// with one legato revoicing, plus at most one answer shell per phrase and one or two per take. The old
    /// invariants (two to four shell gestures, stabs, pairs only) described the sparse shells it replaces.
    @Test func midsHoldAPadAndAnswerTheMelodyWithoutDoublingItsAttacks() {
        let clock = LofiClock(tempo: 70, sampleRate: 48_000)
        let end = LofiScore.padEnd(beatSeconds: clock.beatDuration)
        var threeVoices = 0, pads = 0
        for seed in 0..<100 as Range<UInt64> {
            var takeShells: [Int: Int] = [:]
            var takeArticulations: [Int: Set<LofiScore.Articulation>] = [:]
            for phrase in 0..<8 {
                let current = score(phrase, seed: seed, clock: clock)
                let mids = part(current, .texture)
                let lead = part(current, .lead)
                let pad = mids.filter { $0.articulation == .pad }
                let shells = mids.filter { $0.articulation != .pad }
                let label: Comment = "seed \(seed) phrase \(phrase)"
                // Pad: voices from its first beat, one revoicing note later, every voice in the register.
                let start = pad.map(\.beat).min() ?? 0
                let held = pad.filter { abs($0.beat - start) < 1e-9 }.sorted { $0.midi < $1.midi }
                let moved = pad.filter { $0.beat > start + 1e-9 }
                pads += 1
                if held.count == 3 { threeVoices += 1 }
                if current.section == .breakdown {
                    #expect(held.count == 2, "seed \(seed) phrase \(phrase): \(held.count) breakdown voices")
                } else {
                    #expect((2...3).contains(held.count), "seed \(seed) phrase \(phrase): \(held.count) voices")
                }
                #expect(moved.count <= 1, label)
                #expect(pad.allSatisfy { LofiScore.padRegister.contains($0.midi) }, label)
                #expect(zip(held, held.dropFirst()).allSatisfy { (2...9).contains($1.midi - $0.midi) }, label)
                if let next = moved.first {
                    // The inner voice hands over with a quarter beat of overlap.
                    #expect(pad.contains { abs($0.beat + $0.length - (next.beat + LofiScore.padRevoiceOverlap)) < 1e-9 }, label)
                    #expect(abs(next.beat - LofiScore.padRevoiceBeat) <= 0.5 + 1e-9, label)
                }
                // The release ends inside the phrase.
                #expect(pad.allSatisfy { $0.beat + $0.length <= end + 1e-9 }, label)
                #expect(end + LofiScore.padReleaseSeconds / clock.beatDuration <= LofiClock.beats)
                #expect(pad.filter { abs($0.beat - start) < 1e-9 }.contains { abs($0.beat + $0.length - end) < 1e-9 }, label)
                #expect(pad.allSatisfy { (0.60...0.75).contains($0.send) }, label)
                // Shells: at most one gesture, only after a landing, in the shell-eligible sections.
                #expect(shells.count == 0 || shells.count == 2, label)
                if [.breakdown, .returnTheme].contains(current.section) { #expect(shells.isEmpty, label) }
                for note in mids {
                    #expect(lead.allSatisfy { abs($0.beat - note.beat) >= LofiScore.midOnsetClearance - 1e-9 },
                            "seed \(seed) phrase \(phrase): mid at \(note.beat) doubles a lead attack")
                }
                for note in shells {
                    #expect((45...62).contains(note.midi))
                    #expect((0.50...0.66).contains(note.velocity))
                    #expect((0.55...0.75).contains(note.send))
                    #expect(note.beat + note.length <= LofiScore.midLatestEnd + 1e-9)
                    switch note.articulation {
                    case .answer: #expect(note.length == 1.6)
                    case .rolled: #expect(note.length == 1.30)
                    default: Issue.record("seed \(seed) phrase \(phrase): shell articulation \(note.articulation)")
                    }
                }
                if let upper = shells.map(\.midi).max(), let lower = shells.map(\.midi).min() {
                    #expect((3...10).contains(upper - lower))
                    for note in shells where note.articulation == .rolled && note.midi == upper {
                        #expect(shells.contains { $0.midi == lower && abs(note.beat - $0.beat - 0.17) < 1e-9 })
                    }
                }
                takeShells[phrase / 4, default: 0] += shells.count / 2
                takeArticulations[phrase / 4, default: []].formUnion(mids.map(\.articulation))
            }
            for (take, count) in takeShells {
                #expect((1...2).contains(count), "seed \(seed) take \(take): \(count) shells")
            }
            #expect(takeArticulations.values.allSatisfy { $0.count >= 2 }, "seed \(seed)")
        }
        // Three voices wherever the register under the melody allows it.
        #expect(Double(threeVoices) / Double(pads) >= 0.4, "\(threeVoices) of \(pads)")
    }

    // MARK: Return

    @Test func theReturnRestatesTheThemeAndRevealsItsFirstNotes() throws {
        var edits = 0
        for seed in 0..<100 as Range<UInt64> {
            for (opening, returning) in [(0, 3), (4, 7)] {
                let theme = score(opening, seed: seed)
                let reprise = score(returning, seed: seed)
                #expect(theme.preset == reprise.preset)
                #expect(theme.preset.family == .piano)
                let a = part(theme, .lead), b = part(reprise, .lead)
                #expect(a.map(\.midi) == b.map(\.midi))
                #expect(a.map(\.beat) == b.map(\.beat))
                #expect(a.map(\.velocity) == b.map(\.velocity))
                #expect(a.map(\.color) == b.map(\.color))
                for (i, (t, r)) in zip(a, b).enumerated() {
                    if i < 2 {
                        #expect(r.gain == LofiScore.returnRevealGain)
                        #expect(abs(r.send - t.send * 0.6) < 1e-6)
                    } else {
                        #expect(r.gain == 1 && r.send == t.send)
                    }
                    #expect(t.gain == 1)
                }
                #expect(abs(20 * log10(LofiScore.returnRevealGain) - 3) < 0.001)
                #expect(part(reprise, .texture).allSatisfy { $0.beat >= 2 })
                let boundary = LofiScore.firstCellBoundary(b)
                #expect(boundary >= b[1].beat)
                if let edit = reprise.virtualRecord {
                    edits += 1
                    #expect(edit.destinationBeat >= boundary)
                }
                #expect(reprise.endingRest.upperBound == LofiClock.beats)
            }
        }
        #expect(edits > 10)
    }

    @Test func theCarriedTailDipsSmoothlyUnderTheReturn() {
        #expect(LofiRenderer.returnCarryGain(beat: 0) == 1)
        // At least 6 dB down (9 dB since mix calibration).
        #expect(20 * log10(LofiRenderer.returnCarryFloor) <= -6)
        #expect(abs(LofiRenderer.returnCarryGain(beat: 1) - LofiRenderer.returnCarryFloor) < 1e-5)
        #expect(abs(LofiRenderer.returnCarryGain(beat: 1.99) - LofiRenderer.returnCarryFloor) < 1e-5)
        #expect(LofiRenderer.returnCarryGain(beat: 2.5) == 1)
        #expect(LofiRenderer.returnCarryGain(beat: 8) == 1)
        // A later second note holds the dip until it has sounded.
        #expect(abs(LofiRenderer.returnCarryGain(beat: 3.2, hold: 3.25) - LofiRenderer.returnCarryFloor) < 1e-5)
        #expect(LofiRenderer.returnCarryGain(beat: 3.75, hold: 3.25) == 1)
        var previous: Float = 1
        for step in 0...3000 {
            let gain = LofiRenderer.returnCarryGain(beat: Double(step) / 1000)
            #expect(abs(gain - previous) < 0.004)
            previous = gain
        }
    }

    /// Dry lead level over the wet and mid stems (dB, roughly 500 Hz to 4 kHz) while the phrase's
    /// first two lead notes sound: the part of the return's salience (M14) the music stems own.
    private func openingSalience(_ phrase: LofiRenderer.Phrase) throws -> Float {
        let clock = phrase.clock, n = clock.frameCount
        let rate = Float(clock.sampleRate)
        let high = expf(-2 * .pi * 500 / rate), low = 1 - expf(-2 * .pi * 4_000 / rate)
        func band(_ buffers: [AVAudioPCMBuffer]) throws -> [Float] {
            let channels = try buffers.map { try #require($0.floatChannelData) }
            var x: Float = 0, hp: Float = 0, lp: Float = 0
            return (0..<n).map { frame in
                let input = channels.reduce(Float(0)) { $0 + 0.5 * ($1[0][frame] + $1[1][frame]) }
                hp = high * (hp + input - x)
                x = input
                lp += (hp - lp) * low
                return lp
            }
        }
        let lead = try band([phrase.dry]), rivals = try band([phrase.wet, phrase.texture])
        var leadPower: Float = 0, rivalPower: Float = 0
        for note in part(phrase.score, .lead).prefix(2) {
            let start = clock.frame(at: note.beat)
            for frame in start..<min(n, clock.frame(at: note.beat + min(note.length, 1 / clock.beatDuration))) {
                leadPower += lead[frame] * lead[frame]
                rivalPower += rivals[frame] * rivals[frame]
            }
        }
        return 10 * log10(max(leadPower, 1e-12) / max(rivalPower, 1e-12))
    }

    @Test(arguments: [(1042, 70.0), (7, 62.0), (462, 81.0)] as [(UInt64, Double)])
    func theReturnsFirstNotesStandClearOfTheMusicAroundThem(seed: UInt64, tempo: Double) throws {
        for take in 0..<2 {
            var tail: LofiRenderer.Tail?
            var saliences: [Float] = []
            for phrase in (take * 4)..<(take * 4 + 4) {
                let rendered = try LofiRenderer.render(seed: seed, section: LofiScore.section(at: phrase),
                                                       options: .init(tempo: tempo), sampleRate: 16_000,
                                                       drift: .init(seed: seed), startBeat: Double(phrase) * LofiClock.beats,
                                                       carry: tail)
                tail = rendered.tail
                saliences.append(try openingSalience(rendered))
            }
            print("LOFI_RETURN_SALIENCE seed \(seed) take \(take) theme \(saliences[0]) return \(saliences[3])")
            #expect(saliences[3] >= 10)
            #expect(saliences[3] >= saliences[0] + 6)
        }
    }

    // MARK: Rendering

    @Test func everyPinnedScaleStillRendersEveryPhrase() throws {
        for mode in ScaleType.allCases {
            var tail: LofiRenderer.Tail?
            for phrase in [0, 1, 2, 3, 5] {  // every section, with the breakdown tail carried into the return
                let rendered = try LofiRenderer.render(seed: 462, section: LofiScore.section(at: phrase),
                                                       options: .init(tempo: 70, scale: mode), sampleRate: 8_000,
                                                       drift: .init(seed: 462), startBeat: Double(phrase) * 16,
                                                       carry: tail)
                tail = rendered.tail
                let current = rendered.score
                #expect(current.notes.allSatisfy { mode.intervals.contains($0.midi % 12) })
                let n = rendered.clock.frameCount
                for buffer in [rendered.bass, rendered.dry, rendered.texture, rendered.wet] {
                    let channels = try #require(buffer.floatChannelData)
                    let samples = UnsafeBufferPointer(start: channels[0], count: n)
                    #expect(samples.allSatisfy { $0.isFinite && abs($0) < 1 })
                }
                if current.section != .breakdown {
                    let texture = try #require(rendered.texture.floatChannelData)
                    #expect(UnsafeBufferPointer(start: texture[0], count: n).contains { abs($0) > 0.01 })
                }
            }
        }
    }

    @Test func aFixedSeedRendersIdentically() throws {
        func render() throws -> LofiRenderer.Phrase {
            try LofiRenderer.render(seed: 1042, section: .returnTheme, options: .init(tempo: 70), sampleRate: 8_000,
                                    drift: .init(seed: 1042), startBeat: 48)
        }
        let a = try render(), b = try render()
        #expect(a.score == b.score)
        for (x, y) in [(a.bass, b.bass), (a.dry, b.dry), (a.texture, b.texture), (a.wet, b.wet)] {
            let p = try #require(x.floatChannelData), q = try #require(y.floatChannelData)
            for channel in 0..<2 {
                #expect(Array(UnsafeBufferPointer(start: p[channel], count: Int(x.frameLength)))
                        == Array(UnsafeBufferPointer(start: q[channel], count: Int(y.frameLength))))
            }
        }
    }

    /// Debug-build reference from this machine before the arrangement change (seed 1042, 70 BPM,
    /// 48 kHz, eight phrases, best of three): 2210 ms per phrase.
    static let referenceRenderMilliseconds = 2210.0

    @Test(.responsivePool) func phraseRenderTimeStaysWithinBudget() throws {
        var best = Double.infinity
        for _ in 0..<3 {
            // Load-corrected CPU time, so the parallel suite does not inflate it (see `ForegroundTiming`).
            let cost = try ForegroundTiming.measure {
                for index in 0..<8 {
                    _ = try LofiRenderer.render(seed: 1042, section: LofiScore.section(at: index), options: .init(tempo: 70),
                                                sampleRate: 48_000, drift: .init(seed: 1042),
                                                startBeat: Double(index) * LofiClock.beats)
                }
            }.cost
            best = min(best, cost.seconds)
        }
        let perPhrase = best / 8 * 1000
        print("LOFI_RENDER_TIME_PER_PHRASE_MS \(perPhrase) reference \(Self.referenceRenderMilliseconds)")
        BassReport.log(String(format: "LOFI_RENDER_TIME_PER_PHRASE_MS %.1f reference %.0f", perPhrase, Self.referenceRenderMilliseconds))
        #expect(perPhrase <= 1.3 * Self.referenceRenderMilliseconds)
    }
}
