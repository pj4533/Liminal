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
        #expect(theme.notes == LofiScore.make(seed: 21, section: .returnTheme, drift: drift, startBeat: 0).notes)
        let later = LofiScore.make(seed: 21, section: .theme, drift: drift, startBeat: 16)
        #expect(later.tonic == theme.tonic && later.notes != theme.notes)
        #expect(theme.notes != LofiScore.make(seed: 22, section: .theme, drift: drift, startBeat: 0).notes)
        #expect((0..<8).map { LofiScore.section(at: $0) } ==
                [.theme, .theme, .answer, .answer, .breakdown, .returnTheme, .returnTheme, .answer])
        let evolved = LofiPlayback.Request(seed: 21, index: 8, options: LofiOptions())
        #expect(evolved.compositionSeed != 21)
    }

    @Test func melodicGroupsLeaveSpaceForWetAnswers() {
        for seed in 1...12 as ClosedRange<UInt64> {
            for phrase in 0..<8 {
                let score = LofiScore.make(seed: seed, section: LofiScore.section(at: phrase),
                                           drift: .init(seed: seed), startBeat: Double(phrase) * LofiClock.beats)
                let melody = score.notes.filter { $0.part == .lead }
                #expect((1...5).contains(melody.count) && melody.allSatisfy { $0.midi <= 68 })
                #expect(zip(melody, melody.dropFirst()).allSatisfy { $1.beat - $0.beat >= 1.40 })
                #expect(melody.allSatisfy { $0.beat + $0.length < 12 })
                #expect(score.notes.filter { $0.part == .bass }.allSatisfy { (28...39).contains($0.midi) })
                #expect(score.notes.allSatisfy { $0.beat + $0.length < 13 })
            }
        }
    }

    @Test func wetTonePreservesMidsAndTamesSharpPeaks() {
        func transfer(_ frequency: Double, amplitude: Float) -> Float {
            let rate = 48_000.0
            var tone = LofiWetTone(sampleRate: rate)
            var energy: Float = 0
            var source: Float = 0
            for i in 0..<Int(rate * 0.14) {
                let input = amplitude * Float(sin(Double(i) * 2 * .pi * frequency / rate))
                let output = tone.process((input, input)).left
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
    }

    @Test func everyFourBarsGetsANewSampledInstrumentFamily() throws {
        let drift = LofiDrift(seed: 312)
        let presets = (0..<12).map { LofiPreset.selection(seed: drift.seed, phrase: $0) }
        #expect(Set(presets.map(\.name)).count == 12)
        #expect(zip(presets, presets.dropFirst()).allSatisfy { $0.family != $1.family })
        let bank = LofiSampleBank.bundled
        var signatures = Set<[Float]>()
        for phrase in 0..<12 {
            let score = LofiScore.make(seed: 123, section: LofiScore.section(at: phrase),
                                       drift: drift, startBeat: Double(phrase) * LofiClock.beats)
            #expect(score.preset == presets[phrase])
            #expect(bank.count(for: score.preset) >= 3)
            let sample = try #require(bank.sample(for: score.preset, midi: 60))
            #expect(sample.pcm.contains { abs($0) >= 0.05 })
            signatures.insert(Array(sample.pcm[400..<440]))
        }
        #expect(signatures.count == 12)
    }

    @Test func instrumentAndEffectCyclesReshuffleWithoutBackToBackRepeats() {
        func instruments(_ seed: UInt64) -> [LofiPreset.Family] {
            (0..<48).map { LofiPreset.selection(seed: seed, phrase: $0).family }
        }
        func effects(_ seed: UInt64) -> [LofiEffects.Gesture] {
            (0..<48).map { LofiEffects.Gesture.selection(seed: seed, phrase: $0) }
        }
        let families = instruments(19)
        let gestures = effects(19)
        #expect(families != instruments(20))
        #expect(gestures != effects(20))
        #expect(Array(families.prefix(6)) != Array(families[6..<12]))
        #expect(Array(gestures.prefix(4)) != Array(gestures[4..<8]))
        for seed in 0..<20 as Range<UInt64> {
            let f = instruments(seed), e = effects(seed)
            #expect(zip(f, f.dropFirst()).allSatisfy { $0 != $1 })
            #expect(zip(e, e.dropFirst()).allSatisfy { $0 != $1 })
            for start in stride(from: 0, to: f.count, by: 6) {
                #expect(Set(f[start..<(start + 6)]).count == 6)
            }
            for start in stride(from: 0, to: e.count, by: 4) {
                #expect(Set(e[start..<(start + 4)]).count == 4)
            }
        }
    }

    @Test func aRenderedPhraseActuallyUsesTheSelectedSamples() throws {
        let drift = LofiDrift(seed: 312)
        for index in 0..<4 {
            let phrase = try LofiRenderer.render(seed: 123, section: LofiScore.section(at: index), options: .init(),
                                                 sampleRate: 8_000, drift: drift,
                                                 startBeat: Double(index) * LofiClock.beats, recording: nil)
            #expect(phrase.leadSampleCount == phrase.score.notes.filter { $0.part == .lead }.count)
            #expect(phrase.leadSampleCount > 0)
        }
    }

    @Test func roomAndEchoTailCarryIntoTheNextPhrase() throws {
        let options = LofiOptions()
        let drift = LofiDrift(seed: 21)
        let previous = try LofiRenderer.render(seed: 21, section: .theme, options: options, sampleRate: 8_000,
                                               drift: drift, startBeat: 0, recording: nil)
        let audible = try #require(previous.tail.left.indices.dropFirst(200).max {
            abs(previous.tail.left[$0]) < abs(previous.tail.left[$1])
        })
        #expect(abs(previous.tail.left[audible]) > 0.0001)
        #expect(previous.tail.left.last == 0)
        let next = try LofiRenderer.render(seed: 21, section: .answer, options: options, sampleRate: 8_000,
                                           drift: drift, startBeat: 16, recording: nil, carry: previous.tail)
        let dryJoin = try LofiRenderer.render(seed: 21, section: .answer, options: options, sampleRate: 8_000,
                                              drift: drift, startBeat: 16, recording: nil)
        let wet = try #require(next.musicBuffer.floatChannelData)[0]
        let dry = try #require(dryJoin.musicBuffer.floatChannelData)[0]
        let carry = previous.tail.sample(audible, at: next.clock)
        #expect(abs(wet[audible] - dry[audible] - 0.92 * carry.left) < 0.00001)
    }

    @Test func firstStereoRepeatsAreOnTheirBeatDivisions() {
        let clock = LofiClock(tempo: 74, sampleRate: 4_000)
        var fx = LofiEffects(clock: clock)
        let taps = LofiClock.musicEchoBeats
        var firstLeft: Int?
        var firstRight: Int?
        for i in 0...clock.frame(at: taps.right) {
            let pulse: Float = i == 0 ? 1 : 0
            let wet = fx.process(lead: (pulse, pulse), texture: (0, 0), grains: (0, 0), space: 0.5)
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

    @Test func beatAutomationVariesGraduallyAcrossPhrasesAndTakes() {
        let drift = LofiDrift(seed: 21)
        let values = (0...144).map { drift.at(Double($0)) }
        #expect(Set(values.map(\.drums)).count > 20)
        #expect(Set(values.map(\.space)).count > 20)
        #expect(Set(values.map(\.density)).count > 20)
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(abs(a.groove - b.groove) < 0.06)
            #expect(abs(a.density - b.density) < 0.05)
            #expect(abs(a.dust - b.dust) < 0.03)
            #expect(abs(a.space - b.space) < 0.04)
            #expect(abs(a.drums - b.drums) < 0.04)
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
        let drums = Set(wavs.filter { $0.lastPathComponent.hasPrefix("AJ_HALL_DRUM_BREAK_") })
        guard !drums.isEmpty else { return }
        let bundled = LofiDrumLibrary.assets().filter { drums.contains($0.url) }
        #expect(bundled.count == drums.count)
        #expect(bundled.allSatisfy { $0.entry.beats == 64 && $0.entry.framesPerBeat > 0 })
    }

    @Test func aPhraseWithNoDrumRecordingStillRendersBothMusicStems() throws {
        let phrase = try LofiRenderer.render(seed: 21, section: .theme, options: LofiOptions(), sampleRate: 22_050,
                                             drift: LofiDrift(seed: 21), startBeat: 0, recording: nil)
        let frames = Int(phrase.buffer.frameLength)
        let channels = try #require(phrase.buffer.floatChannelData)
        let pitched = try #require(phrase.musicBuffer.floatChannelData)
        #expect(phrase.drumName == nil)
        #expect(frames == phrase.clock.frameCount)
        let samples = UnsafeBufferPointer(start: channels[0], count: frames)
        #expect(samples.first == 0 && samples.last == 0)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) < 0.85 })
        #expect(samples.contains { abs($0) > 0.02 })
        #expect(UnsafeBufferPointer(start: pitched[0], count: frames).contains { abs($0) > 0.02 })
    }
}
