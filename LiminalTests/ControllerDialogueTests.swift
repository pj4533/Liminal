import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Testing
@testable import Liminal

@Suite(.serialized)
struct ControllerDialogueTests {
    @Test func beatDurationsRespectGridAndStretchBounds() throws {
        for whole in [false, true] {
            for seconds in [0.45, 0.7, 1.9, 4.5] {
                let beats = try #require(ControllerDialogueBank.beatLength(seconds: seconds, beat: 0.8, whole: whole))
                let rate = seconds / (beats * 0.8)
                #expect((0.5...2).contains(rate))
                let steps = beats / (whole ? 1 : 0.25)
                #expect(abs(steps - steps.rounded()) < 1e-9)
            }
        }
        #expect(ControllerDialogueBank.beatLength(seconds: 0.15, beat: 0.8, whole: true) == nil)
        #expect(ControllerDialogueBank.beatLength(seconds: .nan, beat: 1, whole: true) == nil)
        #expect(ControllerDialogueBank.beatLength(seconds: 0, beat: 1, whole: false) == nil)
        #expect(ControllerDialogueBank.beatLength(seconds: 1, beat: 0, whole: false) == nil)
    }

    @Test func offlineStretchHasExactDurationAndPreservesPitch() throws {
        let rate = 48_000.0
        let samples = (0..<24_000).map { Float(0.15 * sin(2 * .pi * 440 * Double($0) / rate)) }
        let source = DialogueFixtures.buffer(samples, rate: rate)
        let stretched = try ControllerDialogueBank.stretch(source, frames: 48_000)
        #expect(stretched.frameLength == 48_000)
        let data = try #require(stretched.floatChannelData)
        let range = 12_000..<36_000
        let crossings = range.dropFirst().filter { data[0][$0 - 1] <= 0 && data[0][$0] > 0 }.count
        let frequency = Double(crossings) / (Double(range.count) / rate)
        #expect(abs(frequency - 440) < 8, "beat stretch must not halve pitch")
        #expect((0..<48_000).allSatisfy { data[0][$0].isFinite })
        #expect(data[0][0] == 0 && data[0][47_999] == 0)
    }

    @Test func offlineStretchCompensatesPrerollAndLatency() throws {
        let rate = 48_000.0
        let signal = (0..<24_000).map { i -> Float in
            i < 2_400 ? 0 : Float(0.15 * sin(2 * .pi * 440 * Double(i) / rate))
        }
        let output = try ControllerDialogueBank.stretch(DialogueFixtures.buffer(signal, rate: rate), frames: 48_000)
        let data = try #require(output.floatChannelData)
        let first = try #require((0..<48_000).first { abs(data[0][$0]) > 0.015 })
        #expect(abs(Double(first) / rate - 0.1) < 0.035, "the unit's warmup must not become pad latency")
    }

    @Test func renderedBankUsesPlayedMotifSourceAndHasAWholeAnchor() throws {
        var options = DialogueFixtures.Options()
        options.seconds = 8
        let speech = DialogueFixtures.speech(options)
        let original = speech.source(contentID: "remembered-film", cueToken: 1)
        let info = DialogueRuntimeTests.info(origin: 0)
        let first = DialogueCueCoordinator.build(source: original, speech: [], transcript: nil,
            transport: info, window: 0..<32, earliestStart: 0.3, memory: DialoguePerformanceMemory(), seed: 9)
        let silent = DialogueSource(contentID: "current-silent-film", cueToken: 2,
            buffer: DialogueFixtures.buffer([Float](repeating: 0, count: 384_000), rate: 48_000), sourceStart: 0, rate: 1)
        let built = DialogueCueCoordinator.build(source: silent, speech: [], transcript: nil,
            transport: info, window: 32..<54, earliestStart: 32, memory: first.memory, seed: 9)
        let motif = try #require(built.motif)
        #expect(motif.source.contentID == "remembered-film")
        let bank = try #require(ControllerDialogueBank.prepare(built, source: silent, activation: 32))
        #expect(bank.bankID == built.played?.bankID)
        #expect(bank.cueToken == 2)
        #expect(bank.pads.contains { $0.index == 63 && $0.role == "whole_line" })
        #expect(bank.pads.count <= 64)
        #expect(bank.bytes <= ControllerDialogueBank.byteLimit)
        let whole = try #require(bank.pads.first { $0.index == 63 })
        #expect(whole.beats == whole.beats.rounded())
        #expect(Int(whole.buffer.frameLength) == Int((whole.beats * built.snapshot.beatDuration * 48_000).rounded()))
    }

    @MainActor @Test func manualGateSuppressesQueuedAutoButKeepsItsPlayerAdvancing() async throws {
        let voice = ArchiveVoice()
        let rig = LofiMasterBusTests.Rig()
        try rig.start(voice.chopDry)
        defer { rig.stop() }
        let n = Int(LofiMasterBusTests.rate * 0.2)
        try rig.schedule(voice.chops, LofiMasterBusTests.tone(n * 4, amplitude: 0.1))
        _ = try await rig.render(n)
        let before = try #require(voice.chops.player.lastRenderTime.flatMap { voice.chops.player.playerTime(forNodeTime: $0) }).sampleTime
        voice.controllerSetAutomatic(false, now: 0)
        let quiet = try await rig.render(n)
        #expect(quiet[0].suffix(n / 2).allSatisfy { abs($0) < 0.000001 })
        let after = try #require(voice.chops.player.lastRenderTime.flatMap { voice.chops.player.playerTime(forNodeTime: $0) }).sampleTime
        #expect(after > before)
        #expect(voice.chops.player.isPlaying)
        try rig.schedule(voice.manualChops, LofiMasterBusTests.tone(n, amplitude: 0.1))
        ParamRamp.setGain(voice.manualChopGain, 1, over: 0)
        let manual = try await rig.render(n)
        #expect(manual[0].suffix(n / 2).contains { abs($0) > 0.001 })
    }

    @MainActor @Test func manualSuppressesAutomaticDuckWindowsAlreadyQueued() throws {
        let voice = ArchiveVoice()
        voice.attachMusicDuck(lead: Fader(Mixer()), mids: Fader(Mixer()), space: Fader(Mixer()))
        let rig = LofiMasterBusTests.Rig()
        try rig.start(Mixer(voice.chopOutput, voice.strip.outputs.dry))
        defer { rig.stop() }
        let rate = LofiMasterBusTests.rate
        let bed = DialogueFixtures.buffer([Float](repeating: 0, count: Int(rate * 4)), rate: rate)
        let chop = DialogueFixtures.buffer([Float](repeating: 0.1, count: Int(rate * 0.6)), rate: rate)
        voice.setBeatLocked(true)
        var cue = ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0, label: "test")
        cue.token = 1
        cue.chops = [.init(articulation: .wholeLine, time: 0.4, source: 0..<Int(chop.frameLength), speed: 1, buffer: chop)]
        voice.begin(cue, now: 0)
        voice.modulate(t: 0)
        #expect(voice.chopCounts.queued == 1)
        voice.updateDucks(at: 0.4)
        #expect(voice.isMusicDucked)
        voice.controllerSetAutomatic(false, now: 0)
        voice.updateDucks(at: 0.42)
        #expect(!voice.isMusicDucked)
        #expect(voice.chopCounts.queued == 1, "manual mode must not flush/re-origin the automatic timeline")
    }

    @MainActor @Test func announcedBanksActivateAtomicallyAndCannotExposeOldPadsWhenNextIsUnready() throws {
        let voice = ArchiveVoice()
        let rig = LofiMasterBusTests.Rig()
        try rig.start(Mixer(voice.chopOutput, voice.strip.outputs.dry))
        defer { rig.stop() }
        let rate = LofiMasterBusTests.rate
        let bed = DialogueFixtures.buffer([Float](repeating: 0, count: Int(rate * 6)), rate: rate)
        voice.setBeatLocked(true)
        var cue = ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0, label: "test")
        cue.token = 1
        voice.begin(cue, now: 0)
        var plan = ArchiveVoice.ChopPlan(token: 1, revision: 0, chops: [])
        plan.bankEpoch = .init(cueToken: "1", bankID: "9", planRevision: 0, transportRevision: 3)
        plan.bankActivation = 1; plan.bankEnd = 5
        voice.perform(plan, now: 0)
        let bank = ControllerDialogueBank(cueToken: 1, bankID: 9, planRevision: 0, transportRevision: 3,
            activation: 1, end: 5, pads: [.init(index: 63, role: "whole_line", beats: 1, buffer: bed)])
        voice.controllerPrepareBank(bank)
        voice.updateDucks(at: 0.5)
        #expect(voice.controllerDialogue.read().bank == nil)
        voice.controllerSetAutomatic(false, now: 0)
        voice.updateDucks(at: 1.01)
        #expect(voice.controllerDialogue.read().bank?.bankID == 9)
        let oldRevision = voice.controllerDialogue.read().revision
        try rig.schedule(voice.manualChops, LofiMasterBusTests.tone(48_000, amplitude: 0.1))
        ParamRamp.setGain(voice.manualChopGain, 1, over: 0)
        voice.controllerTrigger(bank: oldRevision, pad: 63, velocity: 1, start: 1.5, token: UUID(), now: 1.08)
        voice.updateDucks(at: 1.08)
        #expect(voice.manualChops.player.isPlaying, "a press between modulation ticks must preserve the old player during choke")
        voice.updateDucks(at: 1.099)
        #expect(voice.manualChops.player.isPlaying)
        voice.updateDucks(at: 1.101)
        var refined = ArchiveVoice.ChopPlan(token: 1, revision: 1, replaceFrom: 2, chops: [])
        refined.bankEpoch = .init(cueToken: "1", bankID: "10", planRevision: 1, transportRevision: 3)
        refined.bankActivation = 2; refined.bankEnd = 5
        voice.perform(refined, now: 1.1)
        voice.updateDucks(at: 1.9)
        #expect(voice.controllerDialogue.read().bank?.bankID == 9)
        voice.updateDucks(at: 2.01)
        #expect(voice.controllerDialogue.read().bank == nil)
        #expect(voice.controllerDialogue.read().revision > oldRevision)
        voice.controllerPrepareBank(bank)
        voice.updateDucks(at: 2.1)
        #expect(voice.controllerDialogue.read().bank == nil)
        voice.cancelChops(token: 1)
        voice.powerDown()
        voice.controllerPrepareBank(bank)
        voice.updateDucks(at: 2.2)
        #expect(voice.controllerDialogue.read().bank == nil)
    }

    @Test func bankPublicationRevisionRejectsRetiredEpochAndStalePress() {
        var gate = ControllerBankActivation()
        let old = ControllerBankEpoch(cueToken: "4", bankID: "9", planRevision: 0, transportRevision: 3)
        #expect(gate.prepare(old, cueToken: "4", transport: 3))
        #expect(!gate.accepts(revision: 0))
        #expect(gate.activate(old, cueToken: "4", transport: 3))
        let revision = gate.revision
        gate.retire(cueToken: "4")
        #expect(!gate.accepts(revision: revision))
        #expect(!gate.prepare(old, cueToken: "4", transport: 3))
        let next = ControllerBankEpoch(cueToken: "5", bankID: "10", planRevision: 1, transportRevision: 4)
        #expect(!gate.prepare(next, cueToken: "5", transport: 3))
        #expect(gate.prepare(next, cueToken: "5", transport: 4))
        #expect(!gate.activate(next, cueToken: "5", transport: 3))
        #expect(gate.activate(next, cueToken: "5", transport: 4))
        gate.invalidateTransport()
        #expect(!gate.accepts(revision: gate.revision - 1))
    }
    @MainActor @Test func betweenModulationTicksStopPreservesEntireChokeFade() async throws {
        let voice = ArchiveVoice()
        let rig = LofiMasterBusTests.Rig()
        try rig.start(voice.chopOutput)
        defer { rig.stop() }
        voice.setBeatLocked(true)
        voice.modulate(t: 0) // the old 10 Hz clock is stale when the command arrives
        try rig.schedule(voice.manualChops, LofiMasterBusTests.tone(48_000, amplitude: 0.1))
        ParamRamp.setGain(voice.manualChopGain, 1, over: 0)
        _ = try await rig.render(1024)
        voice.controllerStopManual(now: 0.08)
        voice.updateDucks(at: 0.08)
        #expect(voice.manualChops.player.isPlaying)
        voice.updateDucks(at: 0.099)
        #expect(voice.manualChops.player.isPlaying)
        voice.updateDucks(at: 0.101)
        #expect(!voice.manualChops.player.isPlaying)
    }

}
