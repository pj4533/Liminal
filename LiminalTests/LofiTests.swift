import AVFoundation
import Foundation
import Testing
@testable import Liminal

struct LofiTests {
    @Test func barClockRoundsAbsolutePositionsAndKeepsTheRepeatExact() {
        for tempo in [63.0, 69, 73, 77] {
            let clock = LofiClock(tempo: tempo, sampleRate: 48_000)
            #expect(clock.frame(at: 16) == clock.frameCount)
            #expect(abs(Double(clock.frameCount) - 48_000 * 60 / tempo * 16) <= 0.5)
            for subdivision in 0..<64 {
                let beat = Double(subdivision) * 0.25
                #expect(abs(Double(clock.frame(at: beat)) - beat * clock.framesPerBeat) <= 0.5)
            }
        }
    }

    @Test func compositionVariesWithinItsHarmonicFieldAndEvolvesToAnotherTake() {
        let drift = LofiDrift(seed: 21)
        let theme = LofiScore.make(seed: 21, section: .theme, drift: drift, startBeat: 0)
        #expect(theme == LofiScore.make(seed: 21, section: .theme, drift: drift, startBeat: 0))
        let reprise = LofiScore.make(seed: 21, section: .returnTheme, drift: drift, startBeat: 48)
        #expect(theme.notes.filter { $0.part == .lead }.map(\.midi) == reprise.notes.filter { $0.part == .lead }.map(\.midi))
        let later = LofiScore.make(seed: 21, section: .theme, drift: drift, startBeat: 16)
        #expect(later.tonic == theme.tonic && later.notes != theme.notes)
        #expect(theme.notes != LofiScore.make(seed: 22, section: .theme, drift: drift, startBeat: 0).notes)
        #expect((0..<8).map { LofiScore.section(at: $0) } ==
                [.theme, .variation, .breakdown, .returnTheme, .theme, .answer, .breakdown, .returnTheme])
        let evolved = LofiPlayback.Request(seed: 21, index: 8, options: LofiOptions())
        #expect(evolved.compositionSeed != 21)
    }

    @Test func melodicGroupsLeaveSpaceForWetAnswers() {
        for seed in 1...12 as ClosedRange<UInt64> {
            for phrase in 0..<8 {
                let score = LofiScore.make(seed: seed, section: LofiScore.section(at: phrase),
                                           drift: .init(seed: seed), startBeat: Double(phrase) * LofiClock.beats)
                let melody = score.notes.filter { $0.part == .lead }
                #expect((3...6).contains(melody.count))
                #expect(melody.allSatisfy { $0.beat + $0.length <= score.endingRest.lowerBound })
                #expect(score.notes.filter { $0.part == .bass }.allSatisfy { (27...43).contains($0.midi) })
                #expect(score.notes.allSatisfy { $0.beat + $0.length <= LofiClock.beats })
            }
        }
    }

    @Test func wetTonePreservesMidsAndTamesSharpPeaks() {
        func transfer(_ frequency: Double, amplitude: Float, sweep: Float = 0.5) -> Float {
            let rate = 48_000.0
            var tone = LofiWetTone(sampleRate: rate)
            var energy: Float = 0
            var source: Float = 0
            for i in 0..<Int(rate * 0.14) {
                let input = amplitude * Float(sin(Double(i) * 2 * .pi * frequency / rate))
                let output = tone.process((input, input), sweep: sweep).left
                if i > 1500 {
                    energy += output * output
                    source += input * input
                }
            }
            return sqrtf(energy / source)
        }
        let mids = transfer(780, amplitude: 0.20)
        let loudAir = transfer(5_500, amplitude: 0.20)
        let softAir = transfer(5_500, amplitude: 0.025)
        #expect(mids > 0.85)
        #expect(loudAir < 0.5 * mids)
        #expect(softAir > loudAir)
        #expect(transfer(5_500, amplitude: 0.20, sweep: 1) < 0.5 * mids)
        #expect(transfer(1_450, amplitude: 0.05, sweep: 1) >
                transfer(1_450, amplitude: 0.05, sweep: 0))
    }

    @Test func effectCyclesReshuffleWithoutBackToBackRepeats() {
        func effects(_ seed: UInt64) -> [LofiEffects.Gesture] {
            (0..<48).map { LofiEffects.Gesture.selection(seed: seed, phrase: $0) }
        }
        let gestures = effects(19)
        #expect(gestures != effects(20))
        #expect(Array(gestures.prefix(4)) != Array(gestures[4..<8]))
        for seed in 0..<20 as Range<UInt64> {
            let events = effects(seed)
            #expect(zip(events, events.dropFirst()).allSatisfy { $0 != $1 })
            for start in stride(from: 0, to: events.count, by: 4) {
                #expect(Set(events[start..<(start + 4)]).count == 4)
            }
        }
    }

    @Test func roomBloomsAfterTheAttackAndHasASustainedTail() {
        let rate = 8_000.0
        var room = LofiEffects.Room(rate: rate)
        var lateEnergy: Float = 0
        var heardBeforePredelay = false
        for frame in 0..<Int(rate * 3.0) {
            let signal = frame < 640 ? sinf(2 * .pi * 420 * Float(frame) / Float(rate)) * 0.1 : 0
            let wet = room.process(signal, signal * 0.6)
            if frame < Int(rate * 0.034) && (wet.left != 0 || wet.right != 0) {
                heardBeforePredelay = true
            }
            if frame >= Int(rate * 1.5) { lateEnergy += wet.left * wet.left + wet.right * wet.right }
        }
        #expect(!heardBeforePredelay)
        #expect(lateEnergy > 0.00001)
    }

    @Test func aRenderedPhraseActuallyUsesTheSelectedSamples() throws {
        let drift = LofiDrift(seed: 312)
        for index in 0..<4 {
            let phrase = try LofiRenderer.render(seed: 123, section: LofiScore.section(at: index), options: .init(),
                                                 sampleRate: 8_000, drift: drift,
                                                 startBeat: Double(index) * LofiClock.beats)
            #expect(phrase.leadSampleCount == phrase.score.notes.filter { $0.part == .lead }.count)
            #expect(phrase.leadSampleCount >= 3)
        }
    }

    @Test func sustainedOrganAndItsReturnsStayInsideTheInstrumentMix() throws {
        let phrase = try LofiRenderer.render(seed: 1042, section: .variation, options: .init(tempo: 70),
                                             sampleRate: 48_000, drift: .init(seed: 1042), startBeat: 16)
        let dry = try #require(phrase.dry.floatChannelData)
        let wet = try #require(phrase.wet.floatChannelData)
        let texture = try #require(phrase.texture.floatChannelData)
        #expect(phrase.score.preset.family == .organ)
        let window = 19_200
        var energy = [Double](repeating: 0, count: window)
        var sum = 0.0
        var strongest = 0.0
        for i in 0..<phrase.clock.frameCount {
            let l = dry[0][i] + texture[0][i] + wet[0][i]
            let r = dry[1][i] + texture[1][i] + wet[1][i]
            let power = Double(l * l + r * r) * 0.5
            let slot = i % window
            sum += power - energy[slot]
            energy[slot] = power
            strongest = max(strongest, sum / Double(window))
        }
        #expect(sqrt(strongest) < 0.15)
        #expect(sqrt(strongest) > 0.09)
    }

    @Test func roomAndEchoTailCarryIntoTheNextPhrase() throws {
        let options = LofiOptions()
        let drift = LofiDrift(seed: 21)
        let previous = try LofiRenderer.render(seed: 21, section: .theme, options: options, sampleRate: 8_000,
                                               drift: drift, startBeat: 0)
        let audible = try #require(previous.tail.left.indices.dropFirst(200).max {
            abs(previous.tail.left[$0]) < abs(previous.tail.left[$1])
        })
        // The arrangement leaves several beats of space before the join. The tail
        // should be faint, but its remaining samples must still cross the boundary.
        #expect(abs(previous.tail.left[audible]) > 0.0000001)
        #expect(previous.tail.left.last == 0)
        let next = try LofiRenderer.render(seed: 21, section: .answer, options: options, sampleRate: 8_000,
                                           drift: drift, startBeat: 16, carry: previous.tail)
        let dryJoin = try LofiRenderer.render(seed: 21, section: .answer, options: options, sampleRate: 8_000,
                                              drift: drift, startBeat: 16)
        let wet = try #require(next.wet.floatChannelData)[0]
        let dry = try #require(dryJoin.wet.floatChannelData)[0]
        let carry = previous.tail.sample(audible, at: next.clock)
        #expect(abs(wet[audible] - dry[audible] - carry.left) < 0.00000002)
    }

    @Test func outgoingTailRetainsItsPitchWhenTheNextTakeChangesTempo() {
        let slow = LofiClock(tempo: 58, sampleRate: 8_000)
        let fast = LofiClock(tempo: 82, sampleRate: 8_000)
        let left = (0..<1024).map { Float(sin(2 * .pi * 220 * Double($0) / slow.sampleRate)) }
        let tail = LofiRenderer.Tail(clock: slow, left: left, right: left.map { -$0 })
        for frame in left.indices {
            let value = tail.sample(frame, at: fast)
            #expect(value.left == left[frame] && value.right == -left[frame])
        }
        #expect(tail.sample(left.count, at: fast).left == 0)
    }

    @Test func firstStereoRepeatsAreOnTheirBeatDivisions() {
        let clock = LofiClock(tempo: 74, sampleRate: 4_000)
        var fx = LofiEffects(clock: clock)
        let taps = LofiClock.musicEchoBeats
        var firstLeft: Int?
        var firstRight: Int?
        for i in 0...clock.frame(at: taps.right) {
            let pulse: Float = i == 0 ? 1 : 0
            let wet = fx.processReturns(lead: (pulse, pulse), texture: (0, 0), grains: (0, 0), space: 0.5).echo
            if firstLeft == nil && abs(wet.left) > 0.052 { firstLeft = i }
            if firstRight == nil && abs(wet.right) > 0.052 { firstRight = i }
        }
        #expect(firstLeft == clock.frame(at: taps.left))
        #expect(firstRight == clock.frame(at: taps.right))
    }

    @Test func aBreakPlaysFourConsecutivePhrasesBeforeRotation() {
        let requests = (0..<9).map { LofiPlayback.Request(seed: 21, index: $0, options: .init()) }
        #expect(requests.map(\.drumBreakIndex) == [0, 0, 0, 0, 1, 1, 1, 1, 2])
        #expect(requests.map(\.drumStartBeat) == [0, 16, 32, 48, 0, 16, 32, 48, 0])
    }

    @Test func takePreservesEverySampleIncludingTheThreeInteriorJoins() throws {
        let clock = LofiClock(tempo: 80, sampleRate: 4_000)
        let frames = clock.frameCount * 4
        let ramp = (0..<frames).map { Float($0 % 113) * 0.002 + 0.19 }
        let entry = LofiDrumLibrary.Entry(name: "fixture", sha256: "", bpm: 80, beats: 64,
                                           sampleRate: 4_000, channels: 2, frameCount: frames,
                                           framesPerBeat: clock.framesPerBeat,
                                           onsetPhaseMilliseconds: 0, beatSupport: 1)
        let take = try LofiDrumTake(recording: .init(entry: entry, left: ramp, right: ramp.map { -$0 }, gain: 0.5),
                                   clock: clock)
        #expect(take.buffer.frameLength == frames)
        let channels = try #require(take.buffer.floatChannelData)
        for frame in [0, frames - 1] + (1...3).flatMap({
            let boundary = clock.frameCount * $0
            return [boundary - 1, boundary, boundary + 1]
        }) {
            #expect(channels[0][frame] == ramp[frame] * 0.5)
            #expect(channels[1][frame] == ramp[frame] * -0.5)
        }
    }

    @Test func recordedKicksAnchorTheCorrectFourBarsOfAnIntactTake() throws {
        let clock = LofiClock(tempo: 70, sampleRate: 8_000)
        let total = clock.frameCount * LofiDrumTake.phraseCount
        var channel = [Float](repeating: 0, count: total)
        // Start the take at a transient and lay the next four-bar downbeat slightly late.
        for start in [0, clock.frame(at: 16.05)] {
            for i in 0..<960 {
                let t = Double(i) / clock.sampleRate
                channel[start + i] = Float(0.8 * cos(2 * .pi * 72 * t) * exp(-36 * t))
            }
        }
        let entry = LofiDrumLibrary.Entry(name: "groove fixture", sha256: "", bpm: 70, beats: 64,
                                          sampleRate: clock.sampleRate, channels: 2, frameCount: total,
                                          framesPerBeat: clock.framesPerBeat, onsetPhaseMilliseconds: 0, beatSupport: 1)
        let take = try LofiDrumTake(recording: .init(entry: entry, left: channel, right: channel.map { -$0 },
                                                    gain: 1), clock: clock)
        let first = take.bassAnchors(startBeat: 0)
        #expect(first.count == 1 && first.first == 0)
        let second = take.bassAnchors(startBeat: 16)
        let played = try #require(second.first)
        #expect(second.count == 1 && abs(played - 0.05) < 0.015)
        #expect(take.bassAnchors(startBeat: 32).isEmpty)
        let phrase = try LofiRenderer.render(seed: 3, section: .answer, options: .init(tempo: 70),
                                             sampleRate: clock.sampleRate, drift: .init(seed: 3), startBeat: 16,
                                             drums: take, drumStartBeat: 16)
        #expect(phrase.score.notes.first { $0.part == .bass }?.beat == played)
    }

    @Test func aTempoRequestWaitsForTheFollowingFullBreak() {
        let initial = LofiOptions(tempo: 63)
        let pending = LofiOptions(tempo: 81, scale: .dorian)
        var phrase = LofiPlayback.Request(seed: 12, index: 0, options: initial)
        for _ in 1...3 {
            phrase = phrase.next(options: pending)
            #expect(phrase.options == initial)
        }
        phrase = phrase.next(options: pending)
        #expect(phrase.index == 4)
        #expect(phrase.options == pending)
    }

    @Test func beatAutomationVariesGraduallyAcrossPhrasesAndTakes() {
        let drift = LofiDrift(seed: 21)
        let values = (0...144).map { drift.at(Double($0)) }
        #expect(Set(values.map(\.space)).count > 20)
        #expect(Set(values.map(\.density)).count > 20)
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(abs(a.density - b.density) < 0.05)
            #expect(abs(a.dust - b.dust) < 0.03)
            #expect(abs(a.space - b.space) < 0.04)
        }
        #expect(drift.at(128) != LofiDrift(seed: 22).at(128))
    }

    @Test func packNamesAndGridValidation() {
        #expect(LofiDrumLibrary.tempo(in: "AJ_HALL_DRUM_BREAK_ROCHESTER_69_BPM") == 69)
        #expect(LofiDrumLibrary.tempo(in: "ROOM#30.5") == nil)
        let sampleRate = 8_000.0
        var samples = [Float](repeating: 0, count: 8 * 4_000)
        for i in 0..<8 {
            samples.replaceSubrange((i * 4_000)..<(i * 4_000 + 30), with: [Float](repeating: 0.8, count: 30))
        }
        samples.withUnsafeBufferPointer { buffer in
            let p = buffer.baseAddress!
            let grid = LofiBeatGrid.measure(left: p, right: p, frames: buffer.count, sampleRate: sampleRate, bpm: 120)
            #expect(grid?.beats == 8)
            #expect(grid?.beatSupport == 1)
            #expect(LofiBeatGrid.measure(left: p, right: p, frames: buffer.count, sampleRate: sampleRate, bpm: 98) == nil)
        }
    }

    @Test func bundledBreaksCanBeDiscoveredFromTheRecordings() {
        let wavs = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? []
        let drums = Set(wavs.filter { $0.lastPathComponent.hasPrefix("AJ_HALL_DRUM_BREAK_") }
            .map { $0.standardizedFileURL.path })
        guard !drums.isEmpty else { return }
        let bundled = LofiDrumLibrary.assets().filter { drums.contains($0.url.standardizedFileURL.path) }
        #expect(bundled.count == drums.count)
        #expect(bundled.allSatisfy { $0.entry.beats == 64 && $0.entry.framesPerBeat > 0 })
    }

    @Test func aPhraseWithNoDrumRecordingStillRendersTheMusicStems() throws {
        let phrase = try LofiRenderer.render(seed: 21, section: .theme, options: LofiOptions(), sampleRate: 22_050,
                                             drift: LofiDrift(seed: 21), startBeat: 0)
        let frames = Int(phrase.bass.frameLength)
        let channels = try #require(phrase.bass.floatChannelData)
        let pitched = try #require(phrase.dry.floatChannelData)
        #expect(frames == phrase.clock.frameCount)
        let samples = UnsafeBufferPointer(start: channels[0], count: frames)
        #expect(samples.first == 0 && samples.last == 0)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) < 0.85 })
        #expect(samples.contains { abs($0) > 0.02 })
        #expect(UnsafeBufferPointer(start: pitched[0], count: frames).contains { abs($0) > 0.02 })
    }
}
