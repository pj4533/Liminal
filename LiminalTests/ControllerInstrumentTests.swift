import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Testing
@testable import Liminal

@Suite(.serialized)
struct ControllerInstrumentTests {
    @Test func completeWindowKeepsStillwaterDuplicatesAndGeneralizesTonicAnchor() throws {
        let pitches = try #require(ControllerPadWindow.pitches(base: 38, tonic: 2, intervals: ScaleType.dorian.intervals))
        #expect(pitches.count == 64)
        #expect(pitches[0] == 38)
        #expect(pitches[3] == pitches[8])
        #expect(pitches[7] == 50)
        #expect(pitches[63] == 86)
        let pentatonic = try #require(ControllerPadWindow.pitches(base: 38, tonic: 2, intervals: ScaleType.pentatonicMinor.intervals))
        #expect(pentatonic[0] == 38)
        #expect(pentatonic[5] == 50)
        #expect(pentatonic[3] == pentatonic[8])
        #expect(ControllerPadWindow.pitches(base: 37, tonic: 2, intervals: ScaleType.dorian.intervals) == nil)
        #expect(ControllerPadWindow.pitches(base: 98, tonic: 2, intervals: ScaleType.dorian.intervals) == nil)
        #expect(ControllerPadWindow.pitches(base: 0, tonic: 0, intervals: []) == nil)
    }

    @Test func bassLastNotePriorityDoesNotReleaseReplacement() {
        var pool = ControllerVoiceAllocation()
        let first = pool.take(channel: .bass, now: 0)
        let second = pool.take(channel: .bass, now: 1)
        #expect(second.1 == [first.0])
        #expect(pool.voices == [second.0])
        #expect(pool.release(first.0.token) == nil)
        #expect(pool.voices == [second.0])
    }

    @Test func perChannelAndGlobalLimitsStealOldestCapturedToken() {
        var pool = ControllerVoiceAllocation()
        var first: UUID?
        for i in 0..<8 {
            let (voice, removed) = pool.take(channel: .keys, now: Double(i))
            #expect(removed.isEmpty)
            if first == nil { first = voice.token }
        }
        #expect(pool.take(channel: .keys, now: 8).1.first?.token == first)
        for (i, channel) in [ControllerChannel.drips, .pluck, .grains, .pad, .drone, .ambientLead].enumerated() {
            for j in 0..<8 { _ = pool.take(channel: channel, now: 10 + Double(i * 8 + j)) }
        }
        #expect(pool.voices.count == 48)
        #expect(pool.voices.first?.channel == .drips)
        #expect(pool.expire(now: 200).count == 48)
        #expect(pool.voices.isEmpty)
    }

    @Test func stolenOnsetCannotStopSameNoteIDReusedInAnotherProgram() throws {
        var onsets = ControllerOnsets()
        let original = ControllerOnsets.Onset(session: "a", noteID: "pad", channel: .keys,
            instrumentRevision: 7, bankRevision: nil, voiceToken: UUID())
        try onsets.insert(original)
        #expect(onsets.release(token: original.voiceToken) == original)
        let replacement = ControllerOnsets.Onset(session: "a", noteID: "pad", channel: .pluck,
            instrumentRevision: 12, bankRevision: nil, voiceToken: UUID())
        try onsets.insert(replacement)
        #expect(onsets.release(token: original.voiceToken) == nil)
        #expect(onsets.onset(session: "a", noteID: "pad") == replacement)
        #expect(onsets.releaseAll(session: "other").isEmpty)
        #expect(onsets.releaseAll(session: "a") == [replacement])
    }

    @Test func budgetCountsRetiredReferencesAndRejectsBeforeAllocation() throws {
        let before = ControllerPCMReservation.liveBytes
        var held: ControllerPCMReservation? = try .init(count: 1024)
        #expect(ControllerPCMReservation.liveBytes == before + 1024)
        #expect(throws: ControllerWire.Failure.overloaded) {
            _ = try ControllerPCMReservation(count: ControllerPCMReservation.limit)
        }
        withExtendedLifetime(held) {}
        held = nil
        #expect(ControllerPCMReservation.liveBytes == before)
    }

    @Test func bassCacheUsesEachActualVoiceAndHasSustainInsteadOfRetriggerLoop() throws {
        let clock = LofiClock(tempo: 72, sampleRate: 8000)
        var score = LofiScore.make(seed: 37, section: .theme, drift: .init(seed: 37), startBeat: 0)
        var signatures: [Double] = []
        for voice in [LofiBassVoice.flatwound, .upright, .synth] {
            score.bassVoice = voice
            let pcm = try ControllerLofiCache.render(.bass, midi: 36, instrument: .init(score: score, clock: clock))
            let sustain = try #require(pcm.sustain)
            #expect(pcm.attack.frameLength == 5600)
            #expect(sustain.frameLength > 1000)
            #expect(pcm.release == voice.release(.hold))
            #expect(pcm.decayDBPerSecond == LofiBassVoice.shape(.hold).decayDBPerSecond)
            let samples = try #require(pcm.attack.floatChannelData)[0]
            #expect((0..<Int(pcm.attack.frameLength)).allSatisfy { samples[$0].isFinite })
            signatures.append((0..<Int(pcm.attack.frameLength)).reduce(0) { $0 + Double(abs(samples[$1])) })
        }
        #expect(Set(signatures).count == 3)
    }

    @Test func completeCurrentNextCacheContainsEveryPublishedPitch() async throws {
        let worker = ControllerLofiCache()
        let clock = LofiClock(tempo: 72, sampleRate: 8000)
        var score = LofiScore.make(seed: 37, section: .theme, drift: .init(seed: 37), startBeat: 0)
        score.bassVoice = .synth
        let bases: [ControllerChannel: Int] = [.bass: 24 + score.tonic, .lead: 36 + score.tonic, .mids: 36 + score.tonic]
        let bank = try await worker.prepare(.init(score: score, clock: clock), bases: bases)
        for channel in [ControllerChannel.bass, .lead, .mids] {
            let pitches = try #require(ControllerPadWindow.pitches(base: bases[channel]!, tonic: score.tonic,
                                                                 intervals: score.scale.intervals))
            #expect(Set(bank.notes[channel]!.keys) == Set(pitches))
            #expect(bank.notes[channel]!.values.allSatisfy { $0.attack.frameLength > 0 })
        }
        let same = try await worker.prepare(.init(score: score, clock: clock), bases: bases)
        #expect(same.notes[.bass]![bases[.bass]!] === bank.notes[.bass]![bases[.bass]!])
        #expect(ControllerPCMReservation.liveBytes <= ControllerPCMReservation.limit)
    }

    @Test func cacheIdentityTracksActualScoreRatherThanNominalPhrase() {
        let clock = LofiClock(tempo: 72, sampleRate: 8000)
        var score = LofiScore.make(seed: 37, section: .theme, drift: .init(seed: 37), startBeat: 0)
        let original = ControllerLofiInstrument(score: score, clock: clock)
        // The fallback reuses score and clock even when the transport phrase number advances.
        #expect(original.key == ControllerLofiInstrument(score: score, clock: clock).key)
        score.bassVoice = score.bassVoice == .synth ? .upright : .synth
        #expect(original.key != ControllerLofiInstrument(score: score, clock: clock).key)
        #expect(original.key != ControllerLofiInstrument(score: original.score, clock: .init(tempo: 72, sampleRate: 48000)).key)
    }

    @MainActor @Test func realAmbientVoicePressureAndReleaseUseOriginalCapturedToken() async throws {
        let rig = LofiMasterBusTests.Rig()
        let strip = ControllerChannelStrip(rig.lofi)
        let timbres = ControllerAmbientTimbres()
        timbres.publish([.pluck: .init(name: "Soft harp", cutoff: 1200, attack: 0.16,
                                     release: 0.07, decay: 3.25, trim: 0.1)])
        let pool = ControllerVoiceBank(inputs: [.pluck: strip.manualInput], timbres: timbres)
        try rig.start(strip.output)
        defer { rig.stop() }
        strip.setAutomatic(false)
        let revision = pool.instrument(.pluck).revision
        let voice = try pool.noteOn(channel: .pluck, midi: 60, velocity: 0.7,
                                   revision: revision, now: 0)
        let frames = Int(LofiMasterBusTests.rate * 0.3)
        let ringing = try await rig.render(frames)
        #expect(ringing[0].suffix(frames / 2).contains { abs($0) > 0.001 })
        pool.pressure(UUID(), value: 0) // Unknown IDs cannot affect the captured voice.
        pool.pressure(voice.token, value: 0)
        let quiet = try await rig.render(frames)
        #expect(quiet[0].suffix(frames / 2).allSatisfy { abs($0) < 0.00001 })
        pool.release(voice.token, now: 0.6)
        pool.pressure(voice.token, value: 1) // A stale pressure cannot resurrect the release.
        _ = pool.tick(now: 1)
        #expect(pool.instrument(.pluck).revision == revision)
        #expect(strip.automatic == false)
        #expect(strip.values[.gain] == 0.5)
    }
}
