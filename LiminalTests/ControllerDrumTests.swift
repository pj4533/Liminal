import AudioKit
import AVFoundation
import Foundation
import Testing
@testable import Liminal

@MainActor @Suite(.serialized)
struct ControllerDrumTests {
    @Test func barBoundaryIncludesRenderLeadAndDoesNotResetTakePhase() {
        let boundary = ControllerDrumPerformance.boundary(now: 112.1, origin: 100, beat: 0.5, margin: 0.2)
        #expect(boundary.time == 114)
        #expect(boundary.beat == 28)
        #expect(ControllerDrumPerformance.offset(beat: boundary.beat, frames: 64_000) == 28_000)
        #expect(ControllerDrumPerformance.offset(beat: 68, frames: 64_000) == 4_000)
        let late = ControllerDrumPerformance.boundary(now: 113.95, origin: 100, beat: 0.5, margin: 0.2)
        #expect(late.time == 116 && late.beat == 32)
    }

    @Test func rotatedLoopWrapsWithoutChangingItsLengthOrStereoPosition() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        let src = try #require(buffer.floatChannelData)
        for i in 0..<64 { src[0][i] = Float(i); src[1][i] = -Float(i) }
        let rotated = try ControllerDrumPerformance.rotate(buffer, offset: 28)
        let out = try #require(rotated.floatChannelData)
        #expect(rotated.frameLength == buffer.frameLength)
        for i in 0..<64 { #expect(out[0][i] == Float((i + 28) % 64)); #expect(out[1][i] == -out[0][i]) }
    }

    @Test func generatedFallbackHasRealFiniteAudioOnTheTakeGrid() throws {
        let clock = LofiClock(tempo: 72, sampleRate: 24_000)
        let buffer = try ControllerDrumPerformance.generated(clock: clock)
        #expect(Int(buffer.frameLength) == clock.frameCount * 4)
        let data = try #require(buffer.floatChannelData)
        let values = (0..<Int(buffer.frameLength)).map { data[0][$0] }
        #expect(values.allSatisfy(\.isFinite))
        #expect(values.contains { abs($0) > 0.01 })
        #expect(values.allSatisfy { abs($0) <= 1 })
    }

    @Test func tempoChangeInvalidatesPendingRenderAndRetainsSilentManualSelection() async throws {
        let bus = LofiBus(gain: 1, dialogue: Fader(Mixer()))
        let performance = ControllerDrumPerformance(bus: bus)
        defer { performance.stop() }
        performance.discover()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while performance.choices.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!performance.choices.isEmpty)
        performance.setAutomatic(false)
        let first = DialogueRuntimeTests.info(origin: ProcessInfo.processInfo.systemUptime)
        performance.tick(info: first, name: nil)
        let request = try performance.select("generated", info: first)
        let next = LofiTransportInfo(revision: first.revision + 1, takeIndex: first.takeIndex + 1,
            phraseAtTakeStart: first.phraseAtTakeStart + 4, origin: first.origin + first.beatDuration * 64,
            beatDuration: first.beatDuration * 0.9, nextBeatDuration: nil,
            seed: first.seed, options: first.options, timing: nil)
        performance.tick(info: next, name: nil)
        #expect(performance.pending?.request != request)
        #expect(performance.pending?.choice == "generated")
        #expect(performance.pending?.status == "preparing")
        #expect(performance.current == nil)
        #expect(performance.readyChoices.isEmpty)
    }

    @Test func returningAutoDoesNotStopOrSeekAutomaticPlayer() async throws {
        let bus = LofiBus(gain: 1, dialogue: Fader(Mixer()))
        let rig = LofiMasterBusTests.Rig()
        try rig.start(bus.output)
        defer { rig.stop() }
        let n = Int(LofiMasterBusTests.rate * 0.1)
        try rig.schedule(bus.drums, LofiMasterBusTests.tone(n * 4, amplitude: 0.03))
        _ = try await rig.render(n)
        let before = try #require(bus.drums.player.lastRenderTime.flatMap { bus.drums.player.playerTime(forNodeTime: $0) }).sampleTime
        let performance = ControllerDrumPerformance(bus: bus)
        #expect(bus.setAutomatic(.drums, enabled: false))
        performance.setAutomatic(false)
        _ = try await rig.render(n)
        performance.setAutomatic(true)
        #expect(bus.setAutomatic(.drums, enabled: true))
        _ = try await rig.render(n)
        let after = try #require(bus.drums.player.lastRenderTime.flatMap { bus.drums.player.playerTime(forNodeTime: $0) }).sampleTime
        #expect(after > before)
        #expect(bus.drums.player.isPlaying)
        #expect(performance.pending == nil)
    }
    @Test func supersedingQueuedSwapOnlyReusesInactivePlayer() async throws {
        let bus = LofiBus(gain: 1, dialogue: Fader(Mixer()))
        let rig = LofiMasterBusTests.Rig()
        try rig.start(bus.output)
        defer { rig.stop() }
        let performance = ControllerDrumPerformance(bus: bus)
        defer { performance.stop() }
        performance.discover()
        let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while performance.choices.isEmpty, ContinuousClock.now < discoveryDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        performance.setAutomatic(false)
        let info = DialogueRuntimeTests.info(origin: ProcessInfo.processInfo.systemUptime)
        performance.tick(info: info, name: nil)
        // Repeated ready selection exercises A -> B -> A without private drum assets.
        _ = try performance.select("generated", info: info, launch: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while performance.current == nil, ContinuousClock.now < deadline {
            performance.tick(info: info, name: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(performance.current == "generated")
        let audible = performance.audibleLane
        _ = try await rig.render(4096)
        let player = bus.performanceDrums[audible].player
        let before = try #require(player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }).sampleTime
        for _ in 0..<2 {
            _ = try performance.select("generated", info: info, launch: true)
            let queuedDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while performance.scheduledLane == nil, ContinuousClock.now < queuedDeadline {
                performance.tick(info: info, name: nil)
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(performance.scheduledLane == 1 - audible)
            #expect(performance.audibleLane == audible)
            #expect(performance.current == "generated")
        }
        _ = try await rig.render(4096)
        let after = try #require(player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }).sampleTime
        #expect(player.isPlaying)
        #expect(after > before, "superseding queued PCM must not stop/reset the audible player")
    }

}
