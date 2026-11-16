import Testing
import Foundation
import AVFoundation
@testable import Liminal

/// Archive footage sound (docs/plans/archive-video.md 4): the cue timing against the picture, the level
/// mapping of "Footage audio", the sample maths of the decoder, and the voice in an offline render.
struct ArchiveAudioCueTests {

    static func plan(start: Double = 100, fadeIn: Double = 11, hold: Double = 40, fadeOut: Double = 13,
                     rate: Float = 0.7, segment: Double = 200) -> MomentPlan {
        MomentPlan(clipID: "x", segmentStart: segment, rate: rate, look: .window, seed: 0.3, start: start,
                   fadeIn: fadeIn, hold: hold, fadeOut: fadeOut)
    }

    @Test func soundEntersAfterThePictureAndLeavesBeforeIt() throws {
        let p = Self.plan()
        let c = try #require(ArchiveAudioCuePlan(plan: p, clipDuration: 1000))
        #expect(c.beginAt == 104)                     // 4 s after the picture starts to appear
        #expect(c.fadeIn == 12)
        #expect(c.fadeOutAt == p.fadeOutStart)        // with the picture's fade out
        #expect(c.fadeOut == 10)
        #expect(c.fadeOutAt + c.fadeOut <= p.end)     // gone before the picture
        // In step with the slowed picture: 4 s of moment = 2.8 s of source at rate 0.7.
        #expect(abs(c.sourceStart - (200 + 4 * 0.7)) < 1e-5)
        // Enough source for the whole sound plus a spare second.
        #expect(abs(c.sourceLength - (c.fadeOutAt + c.fadeOut + 1 - c.beginAt) * 0.7) < 1e-5)
    }

    @Test func shortAndEarlyEndingMoments() throws {
        // Picture fade out shorter than 10 s: the sound's fade is cut to it.
        let short = Self.plan(fadeIn: 5, hold: 8, fadeOut: 6)
        let c = try #require(ArchiveAudioCuePlan(plan: short, clipDuration: 1000))
        #expect(c.fadeOut == 6)
        #expect(c.fadeIn == short.fadeOutStart - c.beginAt)   // never longer than the time it has
        // Too short to be worth starting.
        #expect(ArchiveAudioCuePlan(plan: Self.plan(fadeIn: 4, hold: 4, fadeOut: 4), clipDuration: 1000) == nil)
        // The clip ends: the source length is clipped to it.
        let near = try #require(ArchiveAudioCuePlan(plan: Self.plan(segment: 220), clipDuration: 240))
        #expect(near.sourceStart + near.sourceLength <= 240 + 1e-9)
        // An early fade out (clip ran out, footage turned off) moves the sound's fade out with it.
        var early = Self.plan()
        early.fadeOutEarly(at: 130, duration: 2)
        let e = try #require(ArchiveAudioCuePlan(plan: early, clipDuration: 1000))
        #expect(e.fadeOutAt == 130 && e.fadeOut == 2)
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

    @Test func cuePlaysFadesAndStops() throws {
        let engine = GenerativeEngine(seed: 3)
        let fmt = engine.archiveFormat
        let sr = fmt.sampleRate
        let n = AVAudioFrameCount(8 * sr)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n))
        buf.frameLength = n
        for c in 0..<Int(fmt.channelCount) {
            for i in 0..<Int(n) { buf.floatChannelData![c][i] = 0.05 * sinf(2 * .pi * 400 * Float(i) / Float(sr)) }
        }
        let cue = ArchiveVoice.Cue(buffer: buf, gain: 1, fadeIn: 1, label: "tone")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-voice-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("score.json"))
        }
        var begun = false, ended = false
        var playingAt5 = false
        try engine.renderOffline(seconds: 14, to: url, configure: { e in
            for l in e.layers { l.allStrips.forEach { $0.trim = 0 } }   // the archive stem only
        }, onStep: { t in
            if !begun, t >= 1 { begun = true; engine.post(.archiveBegin(cue)) }
            if t >= 5, !playingAt5 { playingAt5 = engine.archive.isPlaying && engine.archive.level > 0.99 }
            if !ended, t >= 6 { ended = true; engine.post(.archiveEnd(fade: 1)) }
        })
        #expect(playingAt5)
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
