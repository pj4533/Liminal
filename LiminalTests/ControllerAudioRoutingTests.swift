import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Testing
@testable import Liminal

@MainActor
@Suite(.serialized)
struct ControllerAudioRoutingTests {
    @Test func untouchedStripIsUnityAndGateDoesNotStopPlayer() async throws {
        let rig = LofiMasterBusTests.Rig()
        let strip = ControllerChannelStrip(rig.lofi)
        try rig.start(strip.output)
        defer { rig.stop() }
        let frames = Int(LofiMasterBusTests.rate * 0.3)
        let signal = LofiMasterBusTests.tone(frames * 3, amplitude: 0.05)
        try rig.schedule(rig.lofi, signal)
        let first = try await rig.render(frames)
        #expect(zip(first[0], signal[0]).allSatisfy { abs($0.0 - $0.1) < 0.000001 })
        let before = try #require(rig.lofi.player.lastRenderTime.flatMap { rig.lofi.player.playerTime(forNodeTime: $0) }).sampleTime
        strip.setAutomatic(false)
        let muted = try await rig.render(frames)
        #expect(muted[0].suffix(frames / 2).allSatisfy { abs($0) < 0.000001 })
        let after = try #require(rig.lofi.player.lastRenderTime.flatMap { rig.lofi.player.playerTime(forNodeTime: $0) }).sampleTime
        #expect(after > before)
        #expect(rig.lofi.player.isPlaying)
        strip.setAutomatic(true)
        let resumed = try await rig.render(frames)
        #expect(resumed[0].suffix(frames / 2).contains { abs($0) > 0.01 })
    }

    @Test func manualInputSurvivesAutomaticGateAndSharesUserMute() async throws {
        let rig = LofiMasterBusTests.Rig()
        let strip = ControllerChannelStrip(rig.lofi)
        strip.manualInput.addInput(rig.archive)
        try rig.start(strip.output)
        defer { rig.stop() }
        let frames = Int(LofiMasterBusTests.rate * 0.2)
        try rig.schedule(rig.lofi, LofiMasterBusTests.tone(frames * 3, amplitude: 0.08))
        try rig.schedule(rig.archive, LofiMasterBusTests.tone(frames * 3, amplitude: 0.03, hz: 490))
        strip.setAutomatic(false)
        let manual = try await rig.render(frames)
        #expect(manual[0].suffix(frames / 2).contains { abs($0) > 0.02 })
        #expect(strip.set(.gain, value: 0))
        let muted = try await rig.render(frames)
        #expect(muted[0].suffix(frames / 2).allSatisfy { abs($0) < 0.000001 })
        #expect(!strip.set(.gain, value: .nan))
        #expect(!strip.set(.echo, value: 1.01))
        #expect(strip.values[.gain] == 0)
    }

    @Test func independentControlsNeverWriteArchiveDuckTargets() {
        let bus = LofiBus(gain: 1, dialogue: Fader(Mixer()))
        ParamRamp.setGain(bus.dryFader, 0.43, over: 0)
        let original = bus.dryFader.leftGain
        #expect(bus.set(.drums, parameter: .gain, value: 0.2))
        #expect(bus.setAutomatic(.drums, enabled: false))
        #expect(bus.dryFader.leftGain == original)
        #expect(!bus.setAutomatic(.lofiSpace, enabled: false))
        #expect(!bus.setAutomatic(.chops, enabled: false))
        #expect(!LofiBus.isolatedPreparationQualified)
        #expect(!bus.setAutomatic(.lead, enabled: false))
        #expect(bus.strips[.lead]?.automatic == true)
    }

    @Test func isolatedBusMutesDryAndWetWithoutSuppressingOtherSources() async throws {
        let clock = LofiClock(tempo: 72, sampleRate: LofiMasterBusTests.rate)
        func buffer(_ value: Float) throws -> AVAudioPCMBuffer {
            let result = try LofiRenderer.stereoBuffer(clock: clock)
            let pcm = try #require(result.floatChannelData)
            for channel in 0..<2 { for frame in 0..<Int(result.frameLength) { pcm[channel][frame] = value } }
            return result
        }
        let score = LofiScore.make(seed: 1, section: .theme, drift: LofiDrift(seed: 1), startBeat: 0)
        let tail = LofiRenderer.Tail(clock: clock, left: [], right: [])
        let lanes = try [Float(0.01), 0.02, 0.03].map {
            LofiRenderer.IsolatedWet(buffer: try buffer($0), fallback: try buffer(0), tail: tail)
        }
        let phrase = try LofiRenderer.Phrase(bass: buffer(0.03), dry: buffer(0.01), texture: buffer(0.02),
                                             wet: buffer(0.5), fallbackWet: buffer(0), clock: clock,
                                             score: score, leadSampleCount: 0, tail: tail, effectReturns: [], isolatedWet: lanes)
        let bus = LofiBus(gain: 1, dialogue: Fader(Mixer()), isolatedPreparationEnabled: true)
        let rig = LofiMasterBusTests.Rig()
        try rig.start(bus.output)
        defer { rig.stop() }
        bus.schedule(phrase)
        for player in bus.players { player.play() }
        let frames = Int(clock.sampleRate * 0.15)
        _ = try await rig.render(frames)
        #expect(bus.setAutomatic(.lead, enabled: false))
        let leadOff = try await rig.render(frames)
        #expect(leadOff[0].suffix(frames / 2).allSatisfy { abs($0 - 0.10) < 0.00001 })
        #expect(bus.setAutomatic(.mids, enabled: false))
        let midsOff = try await rig.render(frames)
        #expect(midsOff[0].suffix(frames / 2).allSatisfy { abs($0 - 0.06) < 0.00001 })
        #expect(bus.setAutomatic(.bass, enabled: false))
        let allOff = try await rig.render(frames)
        #expect(allOff[0].suffix(frames / 2).allSatisfy { abs($0) < 0.00001 })
        #expect(bus.players.allSatisfy { $0.isPlaying })
    }

    /// Effects must suppress sampled grain anchors too; zeroing the ordinary send is insufficient.
    @Test func isolatedGrainsCannotReintroduceExcludedSampledAnchors() {
        let clock = LofiClock(tempo: 72, sampleRate: 8000)
        let score = LofiScore.make(seed: 19, section: .theme, drift: LofiDrift(seed: 7), startBeat: 0)
        let quiet = [Float](repeating: 0, count: clock.frameCount + Int(clock.sampleRate * 10))
        let grains = LofiEffects.granulate((quiet, quiet), score: score, clock: clock, frames: quiet.count,
                                           seed: 1, gesture: .tape, texture: (quiet, quiet), samples: .bundled,
                                           includeLead: false, includeMids: false)
        #expect(grains.left.allSatisfy { $0 == 0 })
        #expect(grains.right.allSatisfy { $0 == 0 })
    }

    @Test func optionalIsolatedPreparationPreservesLegacyPCMAndOwnsSeparateCarries() throws {
        func render(_ isolate: Bool, _ carry: [LofiRenderer.Tail] = []) throws -> LofiRenderer.Phrase {
            try LofiRenderer.render(seed: 37, section: .theme, options: LofiOptions(), sampleRate: 8000,
                                    drift: LofiDrift(seed: 2), startBeat: 0,
                                    prepareIsolatedWet: isolate, isolatedCarry: carry)
        }
        let original = try render(false), isolated = try render(true)
        #expect(original.isolatedWet.isEmpty)
        #expect(isolated.isolatedWet.count == 3)
        for (a, b) in [(original.bass, isolated.bass), (original.dry, isolated.dry),
                       (original.texture, isolated.texture), (original.wet, isolated.wet),
                       (original.fallbackWet, isolated.fallbackWet)] {
            let count = Int(a.frameLength)
            for channel in 0..<2 {
                let x = try #require(a.floatChannelData), y = try #require(b.floatChannelData)
                #expect(Array(UnsafeBufferPointer(start: x[channel], count: count)) == Array(UnsafeBufferPointer(start: y[channel], count: count)))
            }
        }
        let frames = Int(isolated.wet.frameLength)
        let carry = LofiRenderer.Tail(clock: isolated.clock, left: [Float](repeating: 0.01, count: frames), right: [Float](repeating: 0.01, count: frames))
        let withLeadCarry = try render(true, [carry])
        for index in [1, 2] {
            #expect(withLeadCarry.isolatedWet[index].tail.left == isolated.isolatedWet[index].tail.left)
            let x = try #require(withLeadCarry.isolatedWet[index].buffer.floatChannelData)
            let y = try #require(isolated.isolatedWet[index].buffer.floatChannelData)
            #expect(Array(UnsafeBufferPointer(start: x[0], count: frames)) == Array(UnsafeBufferPointer(start: y[0], count: frames)))
        }
    }
}
