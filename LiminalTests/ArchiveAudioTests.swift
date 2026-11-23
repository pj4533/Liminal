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
    @Test func fileDecoderSeeksInSourceFramesAndStopsAtEOF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 24_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 36_000))
        pcm.frameLength = pcm.frameCapacity
        let ch = try #require(pcm.floatChannelData)
        for i in 0..<Int(pcm.frameLength) {
            // An isolated pulse after a known seek on both channels.
            ch[0][i] = i == 30_000 ? 0.4 : 0
            ch[1][i] = ch[0][i]
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: pcm)
        }
        let samples = try ArchiveAudioDecoder.readFile(url, start: 1, length: 0.75, rate: 48_000)
        #expect(abs(samples.count - 24_000) <= 2)
        let peak = try #require(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) })
        #expect(abs(peak - 12_000) <= 2)
        #expect(samples[peak] > 0.1)
    }


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
        }
        var posted = false
        try engine.renderOffline(seconds: 6, to: url, beatDuration: grid.beatDuration, configure: { engine in
            engine.archiveMix.dryBus.volume = 0
            engine.archiveMix.mutedReturns = ["reverb", "shimmer"]
        }, onStep: { t in
            if !posted, t >= 1 { posted = true; engine.post(.begin(cue)) }
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

    @Test func softenedChopsLeaveAnEchoAndBothLayersFollowCueMute() throws {
        let engine = GenerativeEngine(seed: 7)
        let format = engine.archiveFormat
        let rate = format.sampleRate
        func tone(_ duration: Double, hz: Double, amplitude: Float) throws -> AVAudioPCMBuffer {
            let n = AVAudioFrameCount(duration * rate)
            let b = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n))
            b.frameLength = n
            let pcm = try #require(b.floatChannelData)
            for i in 0..<Int(n) {
                let value = amplitude * Float(sin(2 * .pi * hz * Double(i) / rate))
                pcm[0][i] = value
                pcm[1][i] = value
            }
            return b
        }
        // The bed and the cut use different tones so each layer is measured on its own.
        let bedHz = 400.0, chopHz = 1000.0
        let bed = try tone(4, hz: bedHz, amplitude: 0.1)
        let chop = try tone(0.6, hz: chopHz, amplitude: 0.1)
        let cue = ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "blend", token: 1)
        let chops = [1.4, 3.0].map { start in
            DialogueChop(event: DialogueEvent(padID: 0, role: .head, block: 0, slot: 0, accentTime: start, startTime: start,
                                              duration: 0.6, gainDB: 0, protected: false, chokeAt: nil, text: nil,
                                              transform: .native, padKey: 1, snareLanded: false), buffer: chop)
        }
        engine.engine.output = Mixer(engine.archive.strip.outputs.dry, engine.archive.chopOutput)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blend.wav")
        var started = false, muted = false
        try engine.renderOffline(seconds: 3.5, to: url, beatDuration: 0.8, onStep: { t in
            if !started && t >= 0.2 {
                started = true
                engine.post(.begin(cue))
                engine.post(.chops(.init(token: 1, revision: 0, chops: chops)))
            }
            if !muted && t >= 2.8 { muted = true; engine.post(.gain(0)) }
        })
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let pcm = try #require(buffer.floatChannelData)[0]
        func peak(at seconds: Double) -> Float {
            let start = Int(seconds * rate)
            return (start..<start + Int(0.1 * rate)).reduce(Float.zero) { max($0, abs(pcm[$1])) }
        }
        /// Amplitude of one tone over 0.1 s (a whole number of cycles of both tones).
        func level(at seconds: Double, hz: Double) -> Float {
            let start = Int(seconds * rate), n = Int(0.1 * rate)
            var re = 0.0, im = 0.0
            for i in 0..<n {
                let phase = 2 * Double.pi * hz * Double(i) / rate
                re += Double(pcm[start + i]) * cos(phase)
                im += Double(pcm[start + i]) * sin(phase)
            }
            return Float(2 * (re * re + im * im).squareRoot() / Double(n))
        }
        let bedBefore = level(at: 1.0, hz: bedHz), bedDuring = level(at: 1.7, hz: bedHz)
        let cut = level(at: 1.7, hz: chopHz), echo = level(at: 2.5, hz: chopHz)
        print("softened chops: bed before \(bedBefore) during \(bedDuring) cut \(cut) echo \(echo)")
        // A quiet direct film remains audible before the musical cut enters, and stays audible under it.
        // These are raw equal-level tones: the real chops are levelled far above their source, and the
        // bed's place in the mix (at least 10 dB under the music in gaps) is C-B9 on captures. The tuck
        // pass (19 November 2026) took the dry chop path from 0.72 to `ChopBus.dryGain`, so the raw cut
        // now sits near the bed's direct sound.
        #expect(bedBefore > cut * 0.3 && bedBefore < cut * 2.5, "bed before the cut \(bedBefore), cut \(cut)")
        #expect(bedDuring > bedBefore * 0.25, "bed under the cut \(bedDuring)")
        #expect(cut > 0.008 && cut < 0.04, "cut \(cut)")
        // The 0.6-second cut has stopped; its repeats and the long room are still clearly audible (echo
        // about 5 dB under the dry line with 0.55 feedback since the heavier-effects pass).
        #expect(echo > cut * 0.15 && echo < cut * 3, "echo \(echo) against the cut \(cut)")
        #expect(level(at: 1.0, hz: chopHz) < 0.0005)
        #expect(peak(at: 3.25) < 0.0001)
    }

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
        let cue = ArchiveVoice.Cue(buffer: buf, gain: 1, fadeIn: 1, label: "tone",
                                   activity: ArchiveAudioMath.activity(buf))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var begun = false, ended = false
        var playingAt5 = false
        var speechDetected = false
        let grid = LofiClock(tempo: 74, sampleRate: sr)
        try engine.renderOffline(seconds: 14, to: url, beatDuration: grid.beatDuration, onStep: { t in
            if !begun, t >= 1 { begun = true; engine.post(.begin(cue)) }
            if t >= 5, !playingAt5 { playingAt5 = engine.archive.isPlaying && engine.archive.level > 0.99 }
            if t >= 5, engine.conductor.archiveActivity > 0.3 { speechDetected = true }
            if !ended, t >= 6 { ended = true; engine.post(.end(fade: 1)) }
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

    // MARK: Incremental chop scheduling (plan 6.3)

    @MainActor private struct ChopProbe {
        let engine: GenerativeEngine
        let rate: Double
        let impulse: AVAudioPCMBuffer

        init(seed: UInt64) throws {
            engine = GenerativeEngine(seed: seed)
            let format = engine.archiveFormat
            rate = format.sampleRate
            impulse = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
            impulse.frameLength = 64
            for c in 0..<Int(format.channelCount) {
                for i in 0..<64 { impulse.floatChannelData![c][i] = i == 0 ? 1 : 0 }
            }
        }

        func silence(_ seconds: Double) throws -> AVAudioPCMBuffer {
            let n = AVAudioFrameCount(seconds * rate)
            let b = try #require(AVAudioPCMBuffer(pcmFormat: engine.archiveFormat, frameCapacity: n))
            b.frameLength = n
            for c in 0..<Int(b.format.channelCount) { b.floatChannelData![c].update(repeating: 0, count: Int(n)) }
            return b
        }

        func chop(at start: Double) -> DialogueChop {
            let event = DialogueEvent(padID: 0, role: .stab, block: 0, slot: 0, accentTime: start, startTime: start,
                                      duration: 64 / rate, gainDB: 0, protected: false, chokeAt: nil, text: nil,
                                      transform: .native, padKey: 1, snareLanded: false)
            return DialogueChop(event: event, buffer: impulse)
        }

        /// Renders the chop output (and the silent bed, so its player is attached) and returns channel 0.
        func render(seconds: Double, beat: Double = 0.8, onStep: @escaping (Double) -> Void) throws -> [Float] {
            engine.engine.output = Mixer(engine.archive.strip.outputs.dry, engine.archive.chopOutput)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("chop-probe-\(UUID().uuidString).wav")
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try engine.renderOffline(seconds: seconds, to: url, beatDuration: beat, onStep: onStep)
            let file = try AVAudioFile(forReading: url)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: pcm)
            return Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        }

        /// First sample above `threshold` within 50 ms of `time`.
        /// Default threshold: three quarters of the dry chop path, above its echo and room returns.
        func onset(_ x: [Float], near time: Double, threshold: Float = 0.75 * ArchiveVoice.ChopBus.dryGain) -> Int? {
            let lo = max(0, Int((time - 0.05) * rate)), hi = min(x.count, Int((time + 0.05) * rate))
            return (lo..<hi).first { abs(x[$0]) > threshold }
        }
    }

    @Test func planChopsLandWithinOneSampleAndAReplacementKeepsEarlierQueuedChops() throws {
        let probe = try ChopProbe(seed: 5)
        let bed = try probe.silence(6)
        let early = 1.234567, queued = 2.2, replaced = 3.5, replacement = 3.111, stale = 4.05
        var begun = false, planned = false, replacing = false, stalePosted = false
        let x = try probe.render(seconds: 4.6) { t in
            let engine = probe.engine
            if !begun, t >= 0.2 {
                begun = true
                engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "plan", token: 1)))
            }
            // Posted before the chop timeline has started.
            if !planned, t >= 0.3 {
                planned = true
                engine.post(.chops(.init(token: 1, revision: 0, chops: [early, queued, replaced].map(probe.chop))))
            }
            // Posted during playback, after the 2.2 s chop is queued and before 3.5 s is.
            if !replacing, t >= 2.3 {
                replacing = true
                engine.post(.chops(.init(token: 1, revision: 1, replaceFrom: 2.5, chops: [probe.chop(at: replacement)])))
            }
            if !stalePosted, t >= 2.4 {
                stalePosted = true
                engine.post(.chops(.init(token: 1, revision: 1, chops: [probe.chop(at: stale)])))
                engine.post(.chops(.init(token: 0, revision: 5, chops: [probe.chop(at: stale)])))
            }
        }
        for time in [early, queued, replacement] {
            let found = try #require(probe.onset(x, near: time), "no chop near \(time) s")
            let planned = Int((time * probe.rate).rounded())
            #expect(abs(found - planned) <= 1, "chop at \(time) s landed \(found - planned) samples off")
        }
        #expect(probe.onset(x, near: replaced) == nil, "the replaced chop is gone")
        #expect(probe.onset(x, near: stale) == nil, "stale revisions and tokens are ignored")
    }

    @Test func chopGainIsIndependentOfTheBedFadeIn() throws {
        let probe = try ChopProbe(seed: 6)
        let bed = try probe.silence(8)
        var begun = false, planned = false
        let x = try probe.render(seconds: 2) { t in
            if !begun, t >= 0.2 {
                begun = true
                // A slow 5 s fade-in: the old fade-coupled gain was about 0.05 of nominal at 1 s.
                probe.engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 5, label: "fade", token: 3)))
                planned = true
                probe.engine.post(.chops(.init(token: 3, revision: 0, chops: [probe.chop(at: 1.0)])))
            }
            _ = planned
        }
        let found = try #require(probe.onset(x, near: 1.0, threshold: 0.05))
        // The cue gain is 1 independently of the bed fade; the dialogue fader applies its balance trim.
        let dry = ArchiveVoice.ChopBus.dryGain * ArchiveVoice.ChopBus.outputTrim
        #expect(abs(x[found]) > dry * 0.9 && abs(x[found]) < dry * 1.11, "chop peak \(x[found])")
    }

    // MARK: Cue ownership of chops (fix1-A)

    /// A featured chop (at least 0.5 s): an impulse at sample 0, then silence.
    private func featured(_ probe: ChopProbe, at start: Double, seconds: Double = 0.6) throws -> DialogueChop {
        let n = AVAudioFrameCount(seconds * probe.rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: probe.engine.archiveFormat, frameCapacity: n))
        buffer.frameLength = n
        for c in 0..<Int(buffer.format.channelCount) {
            buffer.floatChannelData![c].update(repeating: 0, count: Int(n))
            buffer.floatChannelData![c][0] = 1
        }
        let event = DialogueEvent(padID: 0, role: .head, block: 0, slot: 0, accentTime: start, startTime: start,
                                  duration: seconds, gainDB: 0, protected: false, chokeAt: nil, text: nil,
                                  transform: .native, padKey: 2, snareLanded: false)
        return DialogueChop(event: event, buffer: buffer)
    }

    @Test func aLaterCuesPlanIsInertUntilItsBedBeginsThenPlaysNormally() throws {
        let probe = try ChopProbe(seed: 7)
        let bed = try probe.silence(6)
        let control = 0.7, early = 1.1, crossfade = 1.45, adopted = 2.4
        let earlyChop = try featured(probe, at: early), adoptedChop = try featured(probe, at: adopted)
        var steps = Set<String>()
        func once(_ key: String, _ body: () -> Void) { if steps.insert(key).inserted { body() } }
        var duckedBeforeAdoption = false, duckedAfterAdoption = false
        var countsWhileInert: (stored: Int, queued: Int)?
        let x = try probe.render(seconds: 3.2) { t in
            let engine = probe.engine
            if t >= 0.2 { once("bed1") { engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "one", token: 1))) } }
            // Cue 2's analysis finished before its bed: the plan reaches the voice while cue 1 plays.
            if t >= 0.3 { once("plan2") { engine.post(.chops(.init(token: 2, revision: 0, chops: [earlyChop, probe.chop(at: crossfade), adoptedChop]))) } }
            if t >= 0.35 { once("plan1") { engine.post(.chops(.init(token: 1, revision: 0, chops: [probe.chop(at: control)]))) } }
            if t >= 1.2 { once("counts") { countsWhileInert = engine.archive.chopCounts } }
            // Bed 2 is posted at 1.3 s and adopts its stored plan at once; it sounds after bed 1's 0.27 s fade.
            if t >= 1.3 { once("bed2") { engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "two", token: 2))) } }
            if t > early + 0.03 && t < early + 0.45 && engine.archive.isMusicDucked { duckedBeforeAdoption = true }
            if t > adopted + 0.05 && t < adopted + 0.5 && engine.archive.isMusicDucked { duckedAfterAdoption = true }
        }
        #expect(probe.onset(x, near: control) != nil, "cue 1's own chop plays")
        #expect(probe.onset(x, near: early) == nil, "cue 2's chop before its bed began stays silent")
        #expect(!duckedBeforeAdoption, "an inert chop opens no duck window")
        let counts = try #require(countsWhileInert)
        #expect(counts.stored == 3 && counts.queued == 1, "cue 2's chops wait stored, unqueued: \(counts)")
        #expect(probe.onset(x, near: crossfade) != nil, "cue 2's chop inside the bed crossfade plays")
        let found = try #require(probe.onset(x, near: adopted), "the adopted plan plays once bed 2 begins")
        #expect(abs(found - Int((adopted * probe.rate).rounded())) <= 1)
        #expect(duckedAfterAdoption, "the adopted featured chop ducks the music")
    }

    @Test func aCancelledCueIgnoresALatePlanAndQueuesNothing() throws {
        let probe = try ChopProbe(seed: 8)
        let bed = try probe.silence(6)
        let control = 1.0, first = 1.6, late = 1.9
        let firstChop = try featured(probe, at: first), lateChop = try featured(probe, at: late)
        var steps = Set<String>()
        func once(_ key: String, _ body: () -> Void) { if steps.insert(key).inserted { body() } }
        var countsAfterLatePlan: (stored: Int, queued: Int)?
        var ducked = false
        let x = try probe.render(seconds: 2.8) { t in
            let engine = probe.engine
            if t >= 0.2 { once("bed1") { engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "one", token: 1))) } }
            if t >= 0.25 { once("plan1") { engine.post(.chops(.init(token: 1, revision: 0, chops: [probe.chop(at: control)]))) } }
            if t >= 0.3 { once("plan2") { engine.post(.chops(.init(token: 2, revision: 0, chops: [firstChop]))) } }
            // The footage service abandons cue 2; its still-running analysis then posts a refinement.
            if t >= 0.5 { once("cancel") { engine.post(.cancelChops(token: 2)) } }
            if t >= 0.6 { once("late") { engine.post(.chops(.init(token: 2, revision: 1, replaceFrom: 1.7, chops: [lateChop]))) } }
            if t >= 0.8 { once("counts") { countsAfterLatePlan = engine.archive.chopCounts } }
            // Even a bed with that token (which the footage service never posts) cannot revive the plan.
            if t >= 1.2 { once("bed2") { engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "two", token: 2))) } }
            if t > first && t < late + 0.55 && engine.archive.isMusicDucked { ducked = true }
        }
        let counts = try #require(countsAfterLatePlan)
        #expect(counts.stored == 0, "the cancelled cue keeps no stored chops: \(counts)")
        #expect(counts.queued == 1, "only cue 1's chop is on the player")
        #expect(probe.onset(x, near: control) != nil)
        #expect(probe.onset(x, near: first) == nil && probe.onset(x, near: late) == nil, "nothing of cue 2 sounds")
        #expect(!ducked)
    }

    @Test func theThemeReturnDipsTheBedWithoutAnyDialoguePlan() throws {
        let probe = try ChopProbe(seed: 9)
        let rate = probe.rate
        let n = AVAudioFrameCount(6 * rate)
        let bed = try #require(AVAudioPCMBuffer(pcmFormat: probe.engine.archiveFormat, frameCapacity: n))
        bed.frameLength = n
        for c in 0..<Int(bed.format.channelCount) {
            for i in 0..<Int(n) { bed.floatChannelData![c][i] = 0.3 * Float(sin(2 * Double.pi * 900 * Double(i) / rate)) }
        }
        // The take's return phrase (phrase 3, beat 48) starts at 4.0 s; the dip opens 3 beats early (1.6 s).
        let beat = 0.8, returnStart = 4.0
        let info = LofiTransportInfo(revision: 1, takeIndex: 0, phraseAtTakeStart: 0, origin: returnStart - 48 * beat,
                                     beatDuration: beat, nextBeatDuration: nil, seed: 3, options: LofiOptions(), timing: nil)
        var begun = false
        let x = try probe.render(seconds: 3.4) { t in
            if !begun, t >= 0.2 {
                begun = true
                probe.engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "no speech", token: 1,
                                                                 transport: info)))
            }
        }
        func rms(_ a: Double, _ b: Double) -> Double {
            let slice = x[Int(a * rate)..<Int(b * rate)]
            return 10 * log10(max(slice.reduce(0) { $0 + Double($1 * $1) } / Double(slice.count), 1e-20))
        }
        let before = rms(0.9, 1.4), during = rms(2.4, 3.3)
        #expect(before > -60, "the bed is audible before the dip (\(before) dB)")
        #expect(during < before - 8, "the bed dips under the return with no chops: \(before) -> \(during) dB")
    }

    /// The live fallback when a cue carries no transport and no chop is ever planned: the conductor's
    /// phrase callback alone (`notePhrase`, polled from `LofiPlayback.onPhrase`) places the return.
    @Test func thePhraseCallbackAloneDipsTheBedUnderTheReturnWithNoChops() throws {
        let probe = try ChopProbe(seed: 10)
        let rate = probe.rate
        let n = AVAudioFrameCount(9 * rate)
        let bed = try #require(AVAudioPCMBuffer(pcmFormat: probe.engine.archiveFormat, frameCapacity: n))
        bed.frameLength = n
        for c in 0..<Int(bed.format.channelCount) {
            for i in 0..<Int(n) { bed.floatChannelData![c][i] = 0.3 * Float(sin(2 * Double.pi * 900 * Double(i) / rate)) }
        }
        // 150 BPM keeps the render short. Phrase 2 (the breakdown) becomes audible at 0.4 s, so the
        // return's downbeat is one phrase (16 beats, 6.4 s) later, at 6.8 s; the dip opens 3 beats early.
        let beat = 0.4, phraseAt = 0.4
        var begun = false, noted = false
        let x = try probe.render(seconds: 7.9, beat: beat) { t in
            if !begun, t >= 0.2 {
                begun = true
                probe.engine.post(.begin(ArchiveVoice.Cue(buffer: bed, gain: 1, fadeIn: 0.1, label: "no speech", token: 1)))
            }
            if !noted, t >= phraseAt {
                noted = true
                probe.engine.archive.notePhrase(2, beatDuration: beat, now: t)
            }
        }
        let counts = probe.engine.archive.chopCounts
        #expect(counts.stored == 0 && counts.queued == 0, "no chop at all")
        func rms(_ a: Double, _ b: Double) -> Double {
            let slice = x[Int(a * rate)..<Int(b * rate)]
            return 10 * log10(max(slice.reduce(0) { $0 + Double($1 * $1) } / Double(slice.count), 1e-20))
        }
        let returnAt = phraseAt + 16 * beat
        let before = rms(3.0, 4.5), during = rms(returnAt - 0.6, returnAt + 0.6)
        #expect(before > -60, "the bed is audible before the dip (\(before) dB)")
        #expect(during < before - 8, "the phrase callback alone dips the bed: \(before) -> \(during) dB")
    }
}

struct DialogueClipGainTests {
    @Test func perCutGainBringsDownALoudVoiceWithoutBoostingTheGaps() {
        let rate = 16_000.0
        let tone = (0..<6400).map { Float(0.15 * sin(2 * .pi * 1400 * Double($0) / rate)) }
        let loud = tone.map { $0 * 4 }
        func gain(_ samples: [Float]) -> Float {
            samples.withUnsafeBufferPointer { DialogueChopChain.clipGain($0.baseAddress!, count: $0.count, rate: rate) }
        }
        #expect(abs(gain(tone) - gain(loud) * 4) < 0.01)
        let padded = Array(repeating: Float(0), count: 12800) + loud + Array(repeating: Float(0), count: 12800)
        #expect(gain(padded) < gain(loud) * 1.04)
    }
}
