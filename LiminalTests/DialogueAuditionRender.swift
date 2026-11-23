import AudioKit
import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Replays the probe's exact cue and rendered events through the same public drum fixture,
/// music stems, archive ducks/returns, and master graph as the mix verification capture.
enum DialogueAuditionRender {
    @MainActor static func mix(source: DialogueSource, chops: [DialogueChop], seed: UInt64,
                               bpm: Double, due: Double, start: Double, seconds: Double) throws -> AVAudioPCMBuffer {
        let format = source.buffer.format
        let previous = AudioKit.Settings.audioFormat
        AudioKit.Settings.audioFormat = format
        defer { AudioKit.Settings.audioFormat = previous }
        let audio = AudioEngine()
        let archive = ArchiveVoice(format: format)
        let bus = LofiBus(gain: 1, dialogue: archive.chopOutput)
        let duck = bus.duckTargets
        archive.attachMusicDuck(lead: duck.lead, mids: duck.mids, space: duck.space)
        let archiveMix = ArchiveMixBus(strip: archive.strip, seed: seed)
        let master = LofiMasterBus(archive: archiveMix.output, lofi: bus.output)
        audio.output = master.output
        try audio.avEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let rate = format.sampleRate
        let clock = LofiClock(tempo: bpm, sampleRate: rate)
        let drums = try LofiDrumTake(recording: LofiMixRenderTests().drumFixture(clock: clock), clock: clock)
        let first = Int((start * rate).rounded()), count = Int((seconds * rate).rounded())
        let end = first + count
        let cueFrame = Int((due * rate).rounded())
        var tail: LofiRenderer.Tail?
        for i in 0...((end - 1) / clock.frameCount) {
            let request = LofiPlayback.Request(seed: seed, index: i, options: .init(tempo: bpm))
            if request.drumPhraseIndex == 0 { bus.schedule(drums) }
            let phrase = try LofiRenderer.render(seed: request.compositionSeed, section: request.section,
                options: request.options, sampleRate: rate, drift: .init(seed: seed),
                startBeat: Double(i) * LofiClock.beats, drums: drums, drumStartBeat: request.drumStartBeat, carry: tail)
            tail = phrase.tail
            bus.schedule(phrase)
        }
        let work = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        let result = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        result.frameLength = AVAudioFrameCount(count)
        let src = try #require(work.floatChannelData), dst = try #require(result.floatChannelData)
        try audio.start()
        defer { audio.stop() }
        let conductor = ArchiveConductor(mix: archiveMix, voice: archive)
        conductor.beginOffline(beatDuration: clock.beatDuration, pattern: .choose(seed: seed, phrase: 0))
        for player in bus.players { player.play() }
        var cursor = 0, retries = 0
        let control = Int((rate * 0.02).rounded())
        var posted = false
        while cursor < end {
            let time = Double(cursor) / rate
            if cursor == cueFrame && !posted {
                archive.begin(.init(buffer: source.buffer, gain: 0.9, fadeIn: 0.5, label: source.contentID,
                                    activity: ArchiveAudioMath.activity(source.buffer), token: source.cueToken), now: time)
                archive.perform(.init(token: source.cueToken, revision: 0, chops: chops), now: time)
                posted = true
            }
            if cursor.isMultiple(of: clock.frameCount), cursor > 0 {
                archiveMix.syncEcho(beatDuration: clock.beatDuration, pattern: .choose(seed: seed, phrase: cursor / clock.frameCount), now: time)
            }
            if cursor.isMultiple(of: control) { conductor.advance(to: time) }
            var size = min(1024, end - cursor, control - cursor % control, clock.frameCount - cursor % clock.frameCount)
            if cursor < cueFrame { size = min(size, cueFrame - cursor) }
            let status = try audio.avEngine.renderOffline(AVAudioFrameCount(size), to: work)
            guard status == .success, work.frameLength > 0 else {
                retries += 1
                try #require(retries < 8, "Audition master stopped advancing")
                continue
            }
            retries = 0
            let next = cursor + Int(work.frameLength), lo = max(first, cursor)
            if next > lo {
                for c in 0..<Int(format.channelCount) {
                    dst[c].advanced(by: lo - first).update(from: src[c].advanced(by: lo - cursor), count: next - lo)
                }
            }
            cursor = next
        }
        return result
    }

    static func dryPlan(_ plan: DialoguePerformancePlan) -> DialoguePerformancePlan {
        let blocks = plan.blocks.map { block in
            let dry = block.events.map { event in
                var copy = event
                copy.effect = .none
                return copy
            }
            return DialogueBlock(phrase: block.phrase, section: block.section, family: block.family,
                variation: block.variation, fingerprint: block.fingerprint, events: dry, forcedChange: block.forcedChange,
                noDialogue: block.noDialogue, change: block.change)
        }
        return DialoguePerformancePlan(sourceID: plan.sourceID, cueToken: plan.cueToken, bankID: plan.bankID,
            analysisVersion: plan.analysisVersion, seed: plan.seed, transportRevision: plan.transportRevision,
            revision: plan.revision, usedTranscript: plan.usedTranscript, blocks: blocks, rejections: plan.rejections)
    }

    /// Dry cuts keep the plan's gates, levels, linked-rate render and timing, with piece FX bypassed.
    static func stem(chops: [DialogueChop], format: AVAudioFormat, start: Double, seconds: Double) throws -> AVAudioPCMBuffer {
        let n = Int((seconds * format.sampleRate).rounded())
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
        let output = try #require(audio.floatChannelData)
        audio.frameLength = AVAudioFrameCount(n)
        for c in 0..<Int(format.channelCount) { output[c].update(repeating: 0, count: n) }
        for chop in chops {
            let input = try #require(chop.buffer.floatChannelData)
            let at = Int((chop.event.startTime * format.sampleRate).rounded()) - Int((start * format.sampleRate).rounded())
            let lo = max(0, -at), hi = min(Int(chop.buffer.frameLength), n - at)
            if hi <= lo { continue }
            for c in 0..<Int(format.channelCount) {
                for i in lo..<hi { output[c][at + i] += input[c][i] }
            }
        }
        return audio
    }
}
