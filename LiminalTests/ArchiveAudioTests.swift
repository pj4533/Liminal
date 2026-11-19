import Testing
import Foundation
import AVFoundation
import AudioKit
@testable import Liminal

/// Archive footage sound (docs/plans/archive-video.md 4, A27): the cue timing against its piece, the level
/// mapping of "Footage audio", the sample maths of the decoder, and the voice in an offline render.
struct ArchiveAudioCueTests {

    static func piece(start: Double = 100, length: Double = 25, rate: Float = 0.7,
                      segment: Double = 200, seed: Float = 0.08) -> FootagePiece {
        FootagePiece(index: 3, slot: 1, clipID: "x", segmentStart: segment, rate: rate, recipe: .window, seed: seed,
                     warp: 0.6, level: 0.5, swell: 0, start: start, origin: start, fadeIn: 4, length: length,
                     fadeOutStart: nil, fadeOut: nil, sound: true)
    }

    @Test func soundComesAndGoesWithItsPiece() throws {
        let p = Self.piece()
        let c = try #require(ArchiveAudioCuePlan(piece: p, clipDuration: 1000))
        #expect(c.beginAt == 100.75)
        #expect(c.endAt == 125.25)
        #expect(c.fadeIn == 2.2 && c.fadeIn == c.fadeOut)
        #expect(c.fadeOutAt > c.beginAt + c.fadeIn)
        #expect(abs(c.sourceStart - (200 + 0.75 * 0.7)) < 1e-5)
        #expect(abs(c.sourceLength - (c.endAt + 1 - c.beginAt) * 0.7) < 1e-5)
        let short = try #require(ArchiveAudioCuePlan(piece: Self.piece(length: 12), clipDuration: 1000))
        #expect(abs(short.fadeIn - 11.5 * 0.17) < 1e-9)
    }

    @Test func catchUpSkipsElapsedAudioAndFadesTheNewEdge() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let input = try #require(buffer.floatChannelData)
        for i in 0..<8_000 {
            input[0][i] = Float(i) / 8_000
            input[1][i] = -input[0][i]
        }
        let trimmed = try #require(ArchiveAudioMath.catchUp(buffer, late: 0.25))
        let output = try #require(trimmed.floatChannelData)
        #expect(trimmed.frameLength == 6_000 && output[0][0] == 0)
        #expect(output[0][400] == input[0][2_400] && output[1][400] == input[1][2_400])
        #expect(ArchiveAudioMath.catchUp(buffer, late: 1.1) == nil)
    }

    @Test func originalSpeedUsesTheSameAnchorAndSlowsOnlyAsNeededNearClipEnd() throws {
        let piece = Self.piece(seed: 0.8)
        let original = try #require(ArchiveAudioCuePlan(piece: piece, clipDuration: 1000))
        let slowed = try #require(ArchiveAudioCuePlan(piece: piece, clipDuration: 220))
        #expect(original.rate == 1)
        #expect(slowed.rate > piece.rate && slowed.rate < 1)
        #expect(slowed.sourceStart + slowed.sourceLength <= 220)
        #expect(original.sourceStart == slowed.sourceStart)
        #expect(original.sourceLength == original.endAt - original.beginAt + 1)
    }

    @Test func heldPieceKeepsItsSoundInSync() throws {
        // A piece held 3 s (its decoder was late) keeps its origin: the sound stays on the picture's clock.
        var p = Self.piece()
        p.start += 3
        let c = try #require(ArchiveAudioCuePlan(piece: p, clipDuration: 1000))
        #expect(c.beginAt == 100.75)
        #expect(abs(c.sourceStart - (200 + 0.75 * 0.7)) < 1e-5)
    }

    @Test func shortPiecesAndClipEnds() throws {
        // Too short to be worth starting (sound span under 5 s).
        #expect(ArchiveAudioCuePlan(piece: Self.piece(length: 5), clipDuration: 1000) == nil)
        #expect(ArchiveAudioCuePlan(piece: Self.piece(length: 8), clipDuration: 1000) != nil)
        // The clip ends before the sound would: no cue (a sound is never cut off).
        #expect(ArchiveAudioCuePlan(piece: Self.piece(segment: 220), clipDuration: 235) == nil)
        let fits = try #require(ArchiveAudioCuePlan(piece: Self.piece(segment: 200), clipDuration: 240))
        #expect(fits.sourceStart + fits.sourceLength <= 240 + 1e-9)
    }

    @Test func footageAudioLevelMapping() {
        #expect(ArchiveAudioCuePlan.gain(level: 0) == nil)
        #expect(ArchiveAudioCuePlan.gain(level: 0.5) == 1)
        #expect(ArchiveAudioCuePlan.gain(level: 1) == 2)            // +6 dB at the top
        #expect(ArchiveAudioCuePlan.gain(level: 2) == 2)
        let g = ArchiveAudioCuePlan.gain(level: 0.25) ?? 0
        #expect(abs(20 * log10(g) + 6.02) < 0.01)                   // -6 dB at a quarter
    }
}

struct ArchiveAudioMathTests {

    @Test func resampleSlowsByTheRate() {
        let x = (0..<1000).map { Float($0) }
        let y = ArchiveAudioMath.resample(x, rate: 0.5)
        #expect(y.count == 1998)
        #expect(y[0] == 0 && y[1] == 0.5 && y[2] == 1)
        #expect(ArchiveAudioMath.resample(x, rate: 1).count == 999)
    }

    @Test func normalisationTargetsAndCaps() {
        #expect(ArchiveAudioMath.normalisation(rmsdB: -70) == nil)        // silent
        let g = ArchiveAudioMath.normalisation(rmsdB: -20) ?? 0
        #expect(abs(20 * log10(g) + 6) < 0.001)                           // -20 -> -26
        let quiet = ArchiveAudioMath.normalisation(rmsdB: -50) ?? 0
        #expect(abs(20 * log10(quiet) - 12) < 0.001)                      // at most +12 dB
    }

    @Test func softClipNeverExceedsTheCeiling() {
        let c: Float = powf(10, -9 / 20)
        for v in stride(from: Float(-4), through: 4, by: 0.01) {
            let y = ArchiveAudioMath.softClip(v, ceiling: c)
            #expect(abs(y) <= c + 1e-6)
            #expect((y >= 0) == (v >= 0) || v == 0)
        }
        #expect(ArchiveAudioMath.softClip(0.1, ceiling: c) == 0.1)        // linear below half the ceiling
    }

    @Test func prepareNormalisesAndFadesTheEdges() throws {
        let sr = 48000.0
        // 2 s of a 300 Hz tone at -40 dBFS RMS.
        let a = Float(0.01 * 2.0.squareRoot())
        let x = (0..<Int(2 * sr)).map { a * sinf(2 * .pi * 300 * Float($0) / Float(sr)) }
        let y = try #require(ArchiveAudioMath.prepare(x, sampleRate: sr, rate: 0.75))
        #expect(abs(Double(y.count) - 2 * sr / 0.75) <= 3)
        #expect(abs(ArchiveAudioMath.rmsdB(y) - (-28)) < 0.5)             // -40 + 12 (capped boost)
        #expect(abs(y[0]) < 1e-6 && abs(y[y.count - 1]) < 1e-6)
        #expect(ArchiveAudioMath.prepare([Float](repeating: 0, count: 48000), sampleRate: sr, rate: 0.7) == nil)
    }
}

/// The voice inside the real music graph, rendered offline: a posted cue sounds, fades and stops.
@MainActor
struct ArchiveVoiceRenderTests {

    @Test(arguments: [58.0, 63.0, 78.0, 82.0]) func footageEchoFollowsTheBeatGrid(bpm: Double) throws {
        let engine = GenerativeEngine(seed: 3)
        let format = engine.archiveFormat
        let rate = format.sampleRate
        let grid = LofiClock(tempo: bpm, sampleRate: rate)
        let length = AVAudioFrameCount(rate * 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length))
        buffer.frameLength = length
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<Int(length) {
                let t = Double(i) / rate
                buffer.floatChannelData![channel][i] = (0.5...0.56).contains(t)
                    ? 0.20 * Float(sin(2 * .pi * 540 * t)) : 0
            }
        }
        let cue = ArchiveVoice.Cue(buffer: buffer, gain: 1, fadeIn: 0.15, label: "echo probe")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-echo-\(UUID()).wav")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("score.json"))
        }
        var posted = false
        try engine.renderOffline(seconds: 6, to: url, archiveBeatDuration: grid.beatDuration, configure: { engine in
            engine.mix.dryBus.volume = 0
            engine.mix.mutedReturns = ["reverb", "shimmer"]
        }, onStep: { t in
            if !posted, t >= 1 { posted = true; engine.post(.archiveBegin(cue)) }
        })
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let channel = try #require(pcm.floatChannelData)[0]
        func peak(from: Double, to: Double) -> Float {
            (Int(from * rate)..<Int(to * rate)).reduce(0) { max($0, abs(channel[$1])) }
        }
        let repeatTime = 1.5 + grid.beatDuration * LofiClock.footageEchoBeats
        let earlier = peak(from: 1.4, to: repeatTime - 0.08)
        let firstEcho = peak(from: repeatTime - 0.04, to: repeatTime + 0.09)
        let secondEcho = peak(from: repeatTime * 2 - 1.55, to: repeatTime * 2 - 1.40)
        #expect(earlier < 0.0001)
        #expect(firstEcho > 0.001)
        #expect(secondEcho > 0.0005 && secondEcho < firstEcho)
    }

    @Test(arguments: [false, true]) func cuePlaysFadesAndStops(syncedToLofi: Bool) throws {
        let engine = GenerativeEngine(seed: 3)
        let fmt = engine.archiveFormat
        let sr = fmt.sampleRate
        let n = AVAudioFrameCount(8 * sr)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n))
        buf.frameLength = n
        for c in 0..<Int(fmt.channelCount) {
            for i in 0..<Int(n) { buf.floatChannelData![c][i] = 0.05 * sinf(2 * .pi * 400 * Float(i) / Float(sr)) }
        }
        let cue = ArchiveVoice.Cue(buffer: buf, gain: 1, fadeIn: 1, label: "tone",
                                   activity: ArchiveAudioMath.activity(buf))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-voice-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("score.json"))
        }
        var begun = false, ended = false
        var playingAt5 = false
        var speechDetected = false
        let grid = LofiClock(tempo: 74, sampleRate: sr)
        try engine.renderOffline(seconds: 14, to: url, archiveBeatDuration: syncedToLofi ? grid.beatDuration : nil, configure: { e in
            if !syncedToLofi {
                for l in e.layers { l.allStrips.forEach { $0.trim = 0 } }
            }
        }, onStep: { t in
            if !begun, t >= 1 { begun = true; engine.post(.archiveBegin(cue)) }
            if t >= 5, !playingAt5 { playingAt5 = engine.archive.isPlaying && engine.archive.level > 0.99 }
            if t >= 5, engine.conductor.archiveActivity > 0.3 { speechDetected = true }
            if !ended, t >= 6 { ended = true; engine.post(.archiveEnd(fade: 1)) }
        })
        #expect(playingAt5)
        #expect(speechDetected)
        #expect(engine.conductor.archiveActivity == 0)
        #expect(!engine.archive.isPlaying)          // stopped after its fade
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let ch = pcm.floatChannelData![0]
        func rms(_ a: Double, _ b: Double) -> Float {
            let i0 = Int(a * sr), i1 = Int(b * sr)
            var s: Float = 0
            for i in i0..<i1 { s += ch[i] * ch[i] }
            return 10 * log10(max(s / Float(i1 - i0), 1e-20))
        }
        let before = rms(0.2, 0.9), during = rms(3, 5), after = rms(13, 14)
        #expect(before < -100)
        #expect(during > -60 && during < -30)
        #expect(after < during - 25)                // the reverb tail is dying away
    }
}

struct LofiDialogueSamplerTests {
    private func soundtrack(rate: Double, syllables: Bool, amplitude: Float = 0.12) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let n = Int(12 * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
        buffer.frameLength = AVAudioFrameCount(n)
        let ch = try #require(buffer.floatChannelData)
        for i in 0..<n {
            let t = Double(i) / rate
            let p = t.truncatingRemainder(dividingBy: 1.4)
            var envelope = 1.0
            if syllables {
                envelope = 0
                for start in [0.12, 0.40, 0.63] where p >= start && p < start + 0.20 {
                    envelope = sin(.pi * (p-start) / 0.20)
                }
            }
            let carrier = sin(2 * .pi * 250 * t) + 0.65 * sin(2 * .pi * 750 * t)
            ch[0][i] = amplitude * Float(envelope * carrier)
            ch[1][i] = ch[0][i]
        }
        return buffer
    }

    @Test func syllablesRepeatOnTheTransportAcrossATempoChange() throws {
        let rate = 16_000.0
        let cue = try soundtrack(rate: rate, syllables: true)
        let grid = LofiTakeGrid(origin: 10, beatDuration: 0.8, nextBeatDuration: 0.92)
        let turn = grid.origin + 64 * grid.beatDuration
        let start = turn - 4.35
        let hits = LofiDialogueSampler.prepare(cue, grid: grid, cueStart: start, duration: 12, seed: 27)
        #expect(hits.count >= 3)
        #expect(Set(hits.map(\.source)).count < hits.count)
        #expect(hits.contains { $0.time < turn } && hits.contains { $0.time >= turn })
        for hit in hits {
            let beat = hit.time < turn ? (hit.time - grid.origin) / 0.8 : (hit.time - turn) / 0.92
            #expect(abs(beat * 2 - (beat * 2).rounded()) < 1e-8)
            #expect(hit.time >= start && hit.time + Double(hit.buffer.frameLength) / rate <= start + 12)
            let pcm = try #require(hit.buffer.floatChannelData?[0])
            #expect(pcm[0] == 0 && pcm[Int(hit.buffer.frameLength)-1] == 0)
        }
    }

    @Test func silenceAndSustainedTonesLeaveTheSoundtrackAlone() throws {
        for amplitude: Float in [0, 0.15] {
            let source = try soundtrack(rate: 16_000, syllables: false, amplitude: amplitude)
            #expect(LofiDialogueSampler.prepare(source, grid: .init(origin: 0, beatDuration: 0.8),
                                                 cueStart: 1.23, duration: 8, seed: 27).isEmpty)
        }
    }

    @Test func aLateLineCanCarryTheQuietOpeningOfTheSameShot() throws {
        let rate = 16_000.0
        let source = try soundtrack(rate: rate, syllables: true)
        let pcm = try #require(source.floatChannelData)
        for c in 0..<2 { pcm[c].update(repeating: 0, count: Int(7 * rate)) }
        let hits = LofiDialogueSampler.prepare(source, grid: .init(origin: 0, beatDuration: 0.8),
                                               cueStart: 0, duration: 12, seed: 1042)
        #expect(hits.count >= 4)
        #expect(hits.first.map { $0.time < 3 && $0.source.upperBound > Int(7 * rate) } == true)
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $1.time - $0.time <= 6 * 0.8 })
    }
}
