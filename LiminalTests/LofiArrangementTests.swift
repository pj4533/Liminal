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

    @Test(arguments: [62.0, 70.0, 81.0])
    func structuralBassAccentsLandTheirAttackOnAConfidentKick(tempo: Double) throws {
        let clock = LofiClock(tempo: tempo, sampleRate: 48_000)
        var voices = Set<LofiBassVoice>()
        for seed in 0..<24 as Range<UInt64> {
            for phrase in 0..<8 {
                let start = Double((phrase % 4) * 16)
                // Late and early played kicks inside the window, plus an unrelated ghost.
                let timing = field([(start + 0.07, 0.9), (start + 3.3, 0.95), (start + 7.93, 0.8)], clock: clock)
                let current = score(phrase, seed: seed, timing: timing, clock: clock)
                let plain = score(phrase, seed: seed, clock: clock)
                voices.insert(current.bassVoice)
                let bass = part(current, .bass)
                #expect(bass.count == part(plain, .bass).count)
                #expect(bass.map(\.midi) == part(plain, .bass).map(\.midi))
                for (accent, kickBeat) in [(0.0, 0.07), (8.0, 7.93)] {
                    guard let note = bass.first(where: { abs($0.beat - accent) < 0.2 }) else { continue }
                    // The voice's own 40-160 Hz rise lands on the kick's (a synthetic landmark's low-band
                    // rise is its attack frame).
                    let lead = current.bassVoice.lowRiseLead(midi: note.midi) * clock.sampleRate
                    let kickFrame = Double(clock.frame(at: kickBeat))
                    let attack = Double(clock.frame(at: note.beat)) + lead
                    #expect(abs(attack - kickFrame) / clock.sampleRate < 0.002,
                            "seed \(seed) phrase \(phrase) accent \(accent): \(attack - kickFrame) frames")
                }
                #expect(current.notes.filter { $0.part != .bass } == plain.notes.filter { $0.part != .bass })
                #expect(bass.allSatisfy { $0.beat >= 0 && $0.beat + $0.length <= LofiClock.beats })
            }
        }
        #expect(voices == [.roundSub, .pluck, .longAnswer])
    }

    @Test func bassAccentsStayOnTheGridForDistantOrUnconfidentKicks() {
        let clock = LofiClock(tempo: 70, sampleRate: 48_000)
        for seed in 0..<24 as Range<UInt64> {
            for phrase in 0..<8 {
                let start = Double((phrase % 4) * 16)
                let distant = field([(start + 0.13, 0.95), (start + 8.2, 0.95)], clock: clock)
                let unsure = field([(start + 0.05, 0.59), (start + 8.04, 0.3)], clock: clock)
                for timing in [distant, unsure] {
                    let current = score(phrase, seed: seed, timing: timing, clock: clock)
                    let bass = part(current, .bass)
                    #expect(current.bassAnchors.isEmpty)
                    for accent in [0.0, 8.0] where LofiScore.section(at: phrase) != .breakdown || accent == 8 {
                        #expect(bass.contains { $0.beat == accent }, "seed \(seed) phrase \(phrase) beat \(accent)")
                    }
                    // Pickups keep their pocket and never move more than the window.
                    let plain = part(score(phrase, seed: seed, clock: clock), .bass)
                    for (a, b) in zip(bass, plain) { #expect(abs(a.beat - b.beat) <= LofiScore.bassAccentWindow + 1e-9) }
                }
            }
        }
    }

    @Test func eachPhraseHasOneBassVoiceChosenBySection() throws {
        var pluckedTakes = 0, takes = 0
        for seed in 0..<100 as Range<UInt64> {
            var statements: [Int: LofiBassVoice] = [:]
            for phrase in 0..<8 {
                let current = score(phrase, seed: seed)
                switch current.section {
                case .answer: #expect(current.bassVoice == .pluck)
                case .returnTheme, .breakdown: #expect(current.bassVoice == .longAnswer)
                case .theme, .variation:
                    #expect([.roundSub, .pluck].contains(current.bassVoice))
                    let take = phrase / 4
                    #expect(statements[take, default: current.bassVoice] == current.bassVoice)
                    statements[take] = current.bassVoice
                }
            }
            takes += statements.count
            pluckedTakes += statements.values.filter { $0 == .pluck }.count
        }
        let share = Double(pluckedTakes) / Double(takes)
        #expect((0.15...0.35).contains(share), "plucked statement share \(share)")

        // The renderer plays every bass note of the phrase with the score's single voice.
        let phrase = try LofiRenderer.render(seed: 5, section: .answer, options: .init(tempo: 70), sampleRate: 8_000,
                                             drift: .init(seed: 5), startBeat: 80)
        #expect(phrase.score.bassVoice == .pluck)
        let n = phrase.clock.frameCount
        var left = [Float](repeating: 0, count: n), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                for note in part(phrase.score, .bass) {
                    LofiBassVoice.add(note, voice: .pluck, clock: phrase.clock, left: l, right: r)
                }
                // Since the stem chains (plan 8.3) the rendered bass is the voice through the
                // offline bass chain; the comparison keeps its intent: one voice for every note.
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

    @Test func midsAnswerTheMelodyWithoutDoublingItsAttacks() {
        var everyTakeVaries = true
        for seed in 0..<100 as Range<UInt64> {
            var takeArticulations: [Int: Set<LofiScore.Articulation>] = [:]
            for phrase in 0..<8 {
                let current = score(phrase, seed: seed)
                let mids = part(current, .texture)
                let lead = part(current, .lead)
                #expect(mids.count.isMultiple(of: 2))
                let events = mids.count / 2
                if current.section == .breakdown {
                    #expect(events <= 1)
                    #expect(mids.allSatisfy { $0.articulation == .answer && $0.velocity == 0.42 })
                } else {
                    #expect((2...4).contains(events), "seed \(seed) phrase \(phrase): \(events)")
                    #expect(mids.allSatisfy { (0.50...0.66).contains($0.velocity) })
                    for kind in [LofiScore.Articulation.stab, .answer, .rolled] {
                        #expect(mids.filter { $0.articulation == kind }.count <= 4, "one articulation three times")
                    }
                    takeArticulations[phrase / 4, default: []].formUnion(mids.map(\.articulation))
                }
                for note in mids {
                    #expect(lead.allSatisfy { abs($0.beat - note.beat) >= LofiScore.midOnsetClearance - 1e-9 },
                            "seed \(seed) phrase \(phrase): mid at \(note.beat) doubles a lead attack")
                    #expect((45...62).contains(note.midi))
                    #expect((0.45...0.75).contains(note.send))
                    #expect(note.articulation != .normal)
                    #expect(note.beat + note.length <= LofiScore.midLatestEnd + 1e-9)
                    switch note.articulation {
                    case .stab:
                        #expect(note.length == 0.35)
                        #expect(abs(note.beat - note.beat.rounded()) > 1e-9, "stab on a downbeat")
                    case .answer: #expect(note.length == 1.6)
                    case .rolled: #expect(note.length == 1.30)
                    case .normal: break
                    }
                }
                // Each event is a close two-voice shell; rolled shells stagger by 0.17 beats.
                let lower = mids.map(\.midi).min() ?? 0, upper = mids.map(\.midi).max() ?? 0
                #expect(mids.isEmpty || (3...10).contains(upper - lower))
                #expect(Set(mids.map(\.midi)).count <= 2)
                for note in mids where note.articulation == .rolled && note.midi == upper {
                    #expect(mids.contains { $0.midi == lower && abs(note.beat - $0.beat - 0.17) < 1e-9 })
                }
            }
            if takeArticulations.values.contains(where: { $0.count < 2 }) { everyTakeVaries = false }
        }
        #expect(everyTakeVaries)
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
        #expect(perPhrase <= 1.3 * Self.referenceRenderMilliseconds)
    }
}
