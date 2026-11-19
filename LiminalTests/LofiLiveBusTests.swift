import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// The live Lo-Fi film bed, chop returns and music ducking (plan 8.5, 8.6), rendered offline through
/// the real graph like `ArchiveVoiceRenderTests`, plus the offline per-cut vocal chain.
@MainActor
struct LofiLiveBusTests {

    // MARK: Harness

    /// Records channel 0 of each tapped node on the render timeline.
    private final class Recorder: @unchecked Sendable {
        var samples: [[Float]]
        init(count: Int, frames: Int) { samples = Array(repeating: [Float](repeating: 0, count: frames), count: count) }
    }

    /// Renders `seconds` through `engine` (beat-locked when `beat` is set) and returns the taps' channel 0.
    private func render(_ engine: GenerativeEngine, seconds: Double, beat: Double?, taps: [Node],
                        output: Node? = nil, configure: ((GenerativeEngine) -> Void)? = nil,
                        onStep: @escaping (Double) -> Void) throws -> [[Float]] {
        let rate = engine.archiveFormat.sampleRate
        let frames = Int(seconds * rate)
        let recorder = Recorder(count: taps.count, frames: frames + 8192)
        if let output { engine.engine.output = output }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-bus-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("score.json"))
        }
        var installed = false
        try engine.renderOffline(seconds: seconds, to: url, archiveBeatDuration: beat, configure: configure, onStep: { t in
            if !installed {
                installed = true
                for (k, node) in taps.enumerated() {
                    node.avAudioNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
                        guard let data = buffer.floatChannelData?[0] else { return }
                        let start = Int(time.sampleTime)
                        for i in 0..<Int(buffer.frameLength) where start + i >= 0 && start + i < recorder.samples[k].count {
                            recorder.samples[k][start + i] = data[i]
                        }
                    }
                }
            }
            onStep(t)
        })
        for node in taps { node.avAudioNode.removeTap(onBus: 0) }
        return recorder.samples.map { Array($0.prefix(frames)) }
    }

    private func buffer(_ format: AVAudioFormat, seconds: Double, _ value: (Int, Double) -> Float) throws -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * format.sampleRate)
        let b = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n))
        b.frameLength = n
        let pcm = try #require(b.floatChannelData)
        for i in 0..<Int(n) {
            let v = value(i, Double(i) / format.sampleRate)
            for c in 0..<Int(format.channelCount) { pcm[c][i] = v }
        }
        return b
    }

    private func noise(_ format: AVAudioFormat, seconds: Double, amplitude: Float, seed: UInt64) throws -> AVAudioPCMBuffer {
        var rng = MusicRNG(seed: seed)
        return try buffer(format, seconds: seconds) { _, _ in amplitude * rng.rangeF(-1...1) }
    }

    private func rmsDB(_ x: [Float], _ a: Double, _ b: Double, rate: Double) -> Double {
        let i0 = max(0, Int(a * rate)), i1 = min(x.count, Int(b * rate))
        guard i1 > i0 else { return -200 }
        var s = 0.0
        for i in i0..<i1 { s += Double(x[i]) * Double(x[i]) }
        return 10 * log10(max(s / Double(i1 - i0), 1e-24))
    }

    private func layersSilent(_ e: GenerativeEngine) {
        for l in e.layers { l.allStrips.forEach { $0.trim = 0 } }
    }

    // MARK: Film bed (plan 8.6)

    /// Four tones through the Lo-Fi bed: 60 Hz, 1 kHz, 2.2 kHz and 4 kHz, 0.6 s each.
    @Test func lofiBedIsClearAndFreeOfRumble() throws {
        let engine = GenerativeEngine(seed: 11)
        let format = engine.archiveFormat
        let rate = format.sampleRate
        let tones = [60.0, 1000, 2200, 4000]
        let cue = try buffer(format, seconds: 3) { _, t in
            let k = min(tones.count - 1, Int(t / 0.6))
            return t < 2.4 ? 0.1 * Float(sin(2 * .pi * tones[k] * t)) : 0
        }
        var begun = false
        let taps = try render(engine, seconds: 3, beat: 0.8, taps: [engine.archive.presenceDip, engine.archive.spectralSweep],
                              configure: layersSilent) { t in
            if !begun, t >= 0.2 {
                begun = true
                engine.post(.archiveBegin(ArchiveVoice.Cue(buffer: cue, gain: 1, fadeIn: 0.1, label: "tones", token: 1)))
            }
        }
        // Cue time 0 is the first step at or after 0.2 s.
        let start = (0.2 / 0.02).rounded(.up) * 0.02
        func level(_ x: [Float], _ k: Int) -> Double { rmsDB(x, start + 0.6 * Double(k) + 0.25, start + 0.6 * Double(k) + 0.55, rate: rate) }
        let input = 20 * log10(0.1 / 2.0.squareRoot())
        let eq = taps[0], post = taps[1]
        let r60 = level(post, 0), r1k = level(post, 1), r4k = level(post, 3)
        // The previous bed (two low-pass stages at 2.1 to 3.2 kHz) put 4 kHz more than 30 dB under 1 kHz.
        #expect(r4k > r1k - 6, "4 kHz \(r4k - r1k) dB against 1 kHz")
        #expect(r60 < r1k - 10, "60 Hz \(r60 - r1k) dB against 1 kHz")
        // The dip: the measured 2.2 kHz level against the Butterworth stages alone.
        let butterworth = [LofiBiquad.Kind.highpass(hz: 120, q: 0.7071067811865476), .lowpass(hz: 6500, q: 0.7071067811865476),
                           .lowpass(hz: 16000, q: 0.7071067811865476)]
            .reduce(0.0) { $0 + LofiBiquad($1, sampleRate: rate).magnitudeDB(at: 2200) }
        let dip = level(eq, 2) - input - butterworth
        #expect(dip <= -2 && dip >= -3, "2.2 kHz dip \(dip) dB")
        // MixBus Lo-Fi voicing.
        #expect(engine.mix.lowpass.$cutoffFrequency.parameter?.value == MixBus.lofiLowpassHz)
    }

    @Test func lofiBedIsMostlyDirect() throws {
        let engine = GenerativeEngine(seed: 12)
        let format = engine.archiveFormat
        let cue = try noise(format, seconds: 7, amplitude: 0.1, seed: 4)
        var begun = false
        let mix = engine.mix
        let x = try render(engine, seconds: 6.5, beat: 0.8, taps: [mix.dryBus, mix.delayReturn, mix.reverbReturn],
                           configure: layersSilent) { t in
            if !begun, t >= 0.2 {
                begun = true
                engine.post(.archiveBegin(ArchiveVoice.Cue(buffer: cue, gain: 1, fadeIn: 0.1, label: "noise", token: 1)))
            }
        }
        let wet = zip(x[1], x[2]).map { $0 + $1 }
        let rate = format.sampleRate
        let ratio = rmsDB(x[0], 2, 6.4, rate: rate) - rmsDB(wet, 2, 6.4, rate: rate)
        #expect(ratio >= 3, "direct to wet \(ratio) dB")
    }

    /// Footage audio at 0, -6 dB, the default, +3.5 dB and the top: bed and chops never get quieter as
    /// the control rises, and zero is silent.
    @Test func footageAudioControlIsMonotonicAndZeroIsSilent() throws {
        var bed: [Double] = [], chops: [Double] = []
        for level: Float in [0, 0.25, 0.5, 0.75, 1] {
            let engine = GenerativeEngine(seed: 13)
            let format = engine.archiveFormat
            let rate = format.sampleRate
            let film = try noise(format, seconds: 4, amplitude: 0.1, seed: 5)
            let line = try noise(format, seconds: 0.6, amplitude: 0.1, seed: 6)
            let gain = ArchiveAudioCuePlan.gain(level: level) ?? 0
            let cue = ArchiveVoice.Cue(buffer: film, gain: gain, fadeIn: 0.1, label: "control",
                chops: [1.0, 2.2].map { .init(articulation: .phrase, time: $0, source: 0..<Int(line.frameLength), speed: 1, buffer: line) })
            var begun = false
            let x = try render(engine, seconds: 3.2, beat: 0.8, taps: [engine.mix.dryBus, engine.archive.chopOutput],
                               configure: layersSilent) { t in
                if !begun, t >= 0.2 { begun = true; engine.post(.archiveBegin(cue)) }
            }
            bed.append(rmsDB(x[0], 0.6, 3.2, rate: rate))
            chops.append(rmsDB(x[1], 0.6, 3.2, rate: rate))
        }
        #expect(bed[0] < -120 && chops[0] < -120, "zero: bed \(bed[0]) chops \(chops[0])")
        for k in 1..<bed.count {
            #expect(bed[k] > bed[k - 1] + 1, "bed \(bed)")
            #expect(chops[k] >= chops[k - 1] - 0.01, "chops \(chops)")
        }
        #expect(chops[1] > chops[0] + 60)
    }

    /// Ambient (not beat-locked) bed for a steady noise cue, in three bands, against the render of the
    /// previous code (the same test run on commit 2c85498, before the Lo-Fi bed values were added).
    @Test func ambientBedIsUnchanged() throws {
        let engine = GenerativeEngine(seed: 14)
        let format = engine.archiveFormat
        let rate = format.sampleRate
        let cue = try noise(format, seconds: 7, amplitude: 0.1, seed: 7)
        var begun = false
        let taps = try render(engine, seconds: 6.5, beat: nil, taps: [engine.mix.output], configure: layersSilent) { t in
            if !begun, t >= 0.2 {
                begun = true
                engine.post(.archiveBegin(ArchiveVoice.Cue(buffer: cue, gain: 1, fadeIn: 0.5, label: "ambient", token: 1)))
            }
        }
        let x = taps[0]
        func band(_ kinds: [LofiBiquad.Kind]) -> Double {
            var y = x
            var chain = LofiFilterChain(kinds, sampleRate: rate)
            y.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return rmsDB(y, 2, 6.4, rate: rate)
        }
        let q = 0.7071067811865476
        let levels = [band([.lowpass(hz: 300, q: q), .lowpass(hz: 300, q: q)]),
                      band([.highpass(hz: 300, q: q), .highpass(hz: 300, q: q), .lowpass(hz: 3000, q: q), .lowpass(hz: 3000, q: q)]),
                      band([.highpass(hz: 3000, q: q), .highpass(hz: 3000, q: q)])]
        print("Ambient bed bands dB: \(levels)")
        let reference = Self.ambientReference
        for k in levels.indices {
            #expect(abs(levels[k] - reference[k]) <= 0.5, "band \(k): \(levels[k]) dB, previous \(reference[k]) dB")
        }
        #expect(engine.mix.lowpass.$cutoffFrequency.parameter?.value == MixBus.ambientLowpassHz)
        #expect(!engine.archive.presenceDip.isStarted)
    }

    /// Measured by `ambientBedIsUnchanged` on the code before this change (see its comment): below 300 Hz,
    /// 300 Hz to 3 kHz and above 3 kHz. The candidate matched them to 1e-12 dB when this was written.
    static let ambientReference: [Double] = [-58.20619275983071, -47.34996955040118, -59.425362567094496]

    // MARK: Music ducking (plan 8.5)

    private func chop(_ start: Double, seconds: Double, role: DialoguePad.Role, format: AVAudioFormat) throws -> DialogueChop {
        let quiet = try buffer(format, seconds: seconds) { _, _ in 0 }
        let event = DialogueEvent(padID: 0, role: role, block: 0, slot: 0, accentTime: start, startTime: start,
                                  duration: seconds, gainDB: 0, protected: false, chokeAt: nil, text: nil,
                                  transform: .native, padKey: 1, snareLanded: false)
        return DialogueChop(event: event, buffer: quiet)
    }

    /// Three DC sources through stand-in lead, mids and space faders.
    @MainActor private struct DuckRig {
        let sources: [ArchiveVoice.BufferSource]
        let faders: [Fader]
        let dc: AVAudioPCMBuffer
        let output: Mixer

        init(_ engine: GenerativeEngine) throws {
            let format = engine.archiveFormat
            let n = AVAudioFrameCount(format.sampleRate)
            let b = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n))
            b.frameLength = n
            for c in 0..<Int(format.channelCount) { b.floatChannelData![c].update(repeating: 0.5, count: Int(n)) }
            dc = b
            sources = (0..<3).map { _ in ArchiveVoice.BufferSource() }
            faders = sources.map { Fader($0) }
            // The archive outputs stay pulled (silently) so its players run.
            output = Mixer(faders + [Fader(Mixer(engine.archive.strip.outputs.dry, engine.archive.chopOutput, engine.archive.bed), gain: 0)])
            engine.archive.attachMusicDuck(lead: faders[0], mids: faders[1], space: faders[2])
        }

        func play() {
            for s in sources {
                s.player.scheduleBuffer(dc, at: nil, options: .loops, completionHandler: nil)
                s.player.play()
            }
        }
    }

    /// Seconds at which `x` (a DC level of 0.5 times a gain) first crosses halfway between `from` and `to` dB after `after`.
    private func crossing(_ x: [Float], after: Double, from: Float, to: Float, rate: Double) -> Double? {
        let mid = 0.5 * (dbToGain(from) + dbToGain(to)) * 0.5
        let falling = to < from
        let i0 = Int(after * rate)
        guard i0 < x.count else { return nil }
        return (i0..<x.count).first { falling ? x[$0] <= mid : x[$0] >= mid }.map { Double($0) / rate }
    }

    @Test func featuredChopsDuckTheMusicAndTheBedButStabsAndTextureDoNot() throws {
        let engine = GenerativeEngine(seed: 15)
        let format = engine.archiveFormat
        let rate = format.sampleRate
        let rig = try DuckRig(engine)
        let film = try buffer(format, seconds: 5) { _, _ in 0.5 }
        let featured = 1.0, featuredLength = 0.8, stab = 3.0, texture = 2.3
        var step = 0
        let x = try render(engine, seconds: 4.2, beat: 0.8, taps: rig.faders + [engine.archive.bed], output: rig.output) { t in
            if step == 0 {
                rig.play()
                engine.post(.archiveBegin(ArchiveVoice.Cue(buffer: film, gain: 1, fadeIn: 0.1, label: "duck", token: 1)))
                engine.post(.archiveChops(.init(token: 1, revision: 0, chops: [
                    try! chop(featured, seconds: featuredLength, role: .anchor, format: format),
                    try! chop(texture, seconds: 0.6, role: .texture, format: format),
                    try! chop(stab, seconds: 0.3, role: .stab, format: format)])))
            }
            step += 1
        }
        let depths: [Float] = [ArchiveVoice.MusicDuck.leadDB, ArchiveVoice.MusicDuck.midsDB, ArchiveVoice.MusicDuck.spaceDB]
        for k in 0..<3 {
            let before = rmsDB(x[k], 0.5, 0.9, rate: rate), during = rmsDB(x[k], 1.15, 1.75, rate: rate)
            #expect(abs(during - before - Double(depths[k])) <= 1, "fader \(k): \(during - before) dB")
            // Attack starts 20 ms before the chop over 30 ms: halfway at about 5 ms before it.
            let down = try #require(crossing(x[k], after: 0.5, from: 0, to: depths[k], rate: rate))
            #expect(abs(down - (featured - 0.005)) <= 0.02, "fader \(k) attack halfway at \(down) s")
            let up = try #require(crossing(x[k], after: down + 0.1, from: depths[k], to: 0, rate: rate))
            #expect(abs(up - (featured + featuredLength + 0.15)) <= 0.02, "fader \(k) release halfway at \(up) s")
            // The texture fill and the 0.3 s stab leave the music alone.
            for start in [texture, stab] {
                let level = rmsDB(x[k], start + 0.05, start + 0.28, rate: rate)
                #expect(abs(level - before) < 0.1, "fader \(k) moved \(level - before) dB at \(start) s")
            }
            #expect(abs(rmsDB(x[k], 4.0, 4.2, rate: rate) - before) < 0.05)
        }
        // The bed: -3 dB under the featured line, 40 ms down, unchanged under the stab.
        let bed = x[3]
        let bedBefore = rmsDB(bed, 0.6, 0.9, rate: rate)
        #expect(abs(rmsDB(bed, 1.15, 1.75, rate: rate) - bedBefore + 3) <= 1)
        let bedDown = try #require(crossing(bed, after: 0.6, from: 0, to: -3, rate: rate))
        #expect(abs(bedDown - (featured - 0.02)) <= 0.02, "bed halfway at \(bedDown) s")
        #expect(abs(rmsDB(bed, stab + 0.05, stab + 0.28, rate: rate) - bedBefore) < 0.1)
    }

    @Test func faderReturnToUnityOnResetAndWhenBeatLockEnds() throws {
        for endBeatLock in [false, true] {
            let engine = GenerativeEngine(seed: 16)
            let format = engine.archiveFormat
            let rate = format.sampleRate
            let rig = try DuckRig(engine)
            let film = try buffer(format, seconds: 5) { _, _ in 0.5 }
            var step = 0
            var released = false
            let x = try render(engine, seconds: 2.2, beat: 0.8, taps: rig.faders, output: rig.output) { t in
                if step == 0 {
                    rig.play()
                    engine.post(.archiveBegin(ArchiveVoice.Cue(buffer: film, gain: 1, fadeIn: 0.1, label: "reset", token: 1)))
                    engine.post(.archiveChops(.init(token: 1, revision: 0, chops: [try! chop(0.8, seconds: 1.2, role: .head, format: format)])))
                }
                if !released, t >= 1.3 {
                    released = true
                    #expect(engine.archive.isMusicDucked)
                    if endBeatLock { engine.archive.setBeatLocked(false) } else { engine.archive.reset(now: t) }
                }
                step += 1
            }
            #expect(!engine.archive.isMusicDucked)
            for k in 0..<3 {
                let before = rmsDB(x[k], 0.3, 0.7, rate: rate)
                #expect(rmsDB(x[k], 1.0, 1.25, rate: rate) < before - 1)
                #expect(abs(rmsDB(x[k], 1.5, 1.95, rate: rate) - before) < 0.05, "fader \(k) after release")
            }
        }
    }

    // MARK: Chop returns (plan 8.5)

    @Test func chopReturnsAreBandLimitedAndUnderTheDryLine() throws {
        var echo: [Double: Double] = [:], room: [Double: Double] = [:], dry: [Double: Double] = [:]
        for hz in [100.0, 1000, 8000] {
            let engine = GenerativeEngine(seed: 17)
            let format = engine.archiveFormat
            let rate = format.sampleRate
            let film = try buffer(format, seconds: 4) { _, _ in 0 }
            let probe = try buffer(format, seconds: 0.4) { _, t in
                0.2 * Float(sin(2 * .pi * hz * t)) * Float(min(1, min(t, 0.4 - t) / 0.01))
            }
            let cue = ArchiveVoice.Cue(buffer: film, gain: 1, fadeIn: 0.1, label: "probe",
                chops: [.init(articulation: .phrase, time: 0.6, source: 0..<Int(probe.frameLength), speed: 1, buffer: probe)])
            var begun = false
            let archive = engine.archive
            let x = try render(engine, seconds: 3.4, beat: 0.8, taps: [archive.chopDry, archive.chopEchoReturn, archive.chopRoomReturn],
                               configure: layersSilent) { t in
                if !begun, t >= 0.2 { begun = true; engine.post(.archiveBegin(cue)) }
            }
            // Energies over the whole render (dB re the same reference).
            dry[hz] = rmsDB(x[0], 0, 3.4, rate: rate)
            echo[hz] = rmsDB(x[1], 0, 3.4, rate: rate)
            room[hz] = rmsDB(x[2], 0, 3.4, rate: rate)
        }
        print("chop returns dry \(dry) echo \(echo) room \(room)")
        for hz in [100.0, 8000] {
            #expect(echo[hz]! - dry[hz]! <= echo[1000]! - dry[1000]! - 12, "echo at \(hz) Hz")
            #expect(room[hz]! - dry[hz]! <= room[1000]! - dry[1000]! - 12, "room at \(hz) Hz")
        }
        let echoUnder = echo[1000]! - dry[1000]!, roomUnder = room[1000]! - dry[1000]!
        #expect(echoUnder >= -19 && echoUnder <= -13, "echo \(echoUnder) dB under dry")
        #expect(roomUnder >= -24 && roomUnder <= -16, "room \(roomUnder) dB under dry")
    }

    // MARK: Per-cut chain (plan 8.5)

    private static let rate = 48_000.0

    private func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Self.rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / Self.rate)) }
    }

    private func rms(_ x: [Float], _ a: Double, _ b: Double) -> Double { rmsDB(x, a, b, rate: Self.rate) }

    @Test func chopChainResponseMatchesItsDesign() {
        for texture in [false, true] {
            for hz in [100.0, 300, 3000, 9000] {
                var x = tone(hz, seconds: 0.6)
                let input = rms(x, 0.3, 0.6)
                DialogueChopChain.process(&x, texture: texture, sampleRate: Self.rate, dynamics: [])
                let measured = rms(x, 0.3, 0.6) - input
                let designed = DialogueChopChain.magnitudeDB(at: hz, texture: texture, sampleRate: Self.rate)
                #expect(abs(measured - designed) <= 1, "\(hz) Hz texture=\(texture): \(measured) vs \(designed) dB")
            }
        }
        let design = { DialogueChopChain.magnitudeDB(at: $0, texture: false, sampleRate: Self.rate) }
        #expect(design(60) < -15)                              // 18 dB per octave below 120 Hz
        #expect(design(300) < -1.5 && design(300) > -3.5)      // the boxiness cut
        #expect(design(3000) > 2 && design(3000) < 3.6)        // presence
        #expect(design(9000) < -3)                             // 7.5 kHz low-pass
        #expect(DialogueChopChain.magnitudeDB(at: 7000, texture: true, sampleRate: Self.rate) < design(7000) - 3)
    }

    @Test func chopDeEsserTakesThreeToSixDecibelsOffASibilant() {
        var plain = tone(6500, seconds: 0.4, amplitude: 0.3)
        var deEssed = plain
        DialogueChopChain.process(&plain, texture: false, sampleRate: Self.rate, dynamics: [])
        DialogueChopChain.process(&deEssed, texture: false, sampleRate: Self.rate, dynamics: [.deEsser])
        let reduction = rms(plain, 0.1, 0.4) - rms(deEssed, 0.1, 0.4)
        #expect(reduction >= 3 && reduction <= 6, "de-esser \(reduction) dB")
        // A vowel below the band is untouched.
        var vowel = tone(700, seconds: 0.4, amplitude: 0.3), vowelDeEssed = vowel
        DialogueChopChain.process(&vowel, texture: false, sampleRate: Self.rate, dynamics: [])
        DialogueChopChain.process(&vowelDeEssed, texture: false, sampleRate: Self.rate, dynamics: [.deEsser])
        #expect(abs(rms(vowel, 0.1, 0.4) - rms(vowelDeEssed, 0.1, 0.4)) < 0.3)
    }

    @Test func chopCompressorEvensTwoLevels() {
        let loud = tone(1000, seconds: 0.5, amplitude: 0.5), soft = tone(1000, seconds: 0.5, amplitude: 0.25)
        var x = loud + soft
        let before = rms(x, 0.2, 0.5) - rms(x, 0.7, 1.0)
        DialogueChopChain.process(&x, texture: false, sampleRate: Self.rate, dynamics: [.compressor])
        let after = rms(x, 0.2, 0.5) - rms(x, 0.7, 1.0)
        #expect(abs(before - 6.02) < 0.1)
        #expect(after <= 3 && after > 0, "two-level spread \(after) dB after compression")
    }

    /// A pad cut from the middle of continuous noise (the worst case for a click): its edges are applied
    /// after the chain, so the first and last millisecond stay under -60 dBFS.
    @Test func renderedPadEdgesStayClickFree() throws {
        let rate = Self.rate
        var rng = MusicRNG(seed: 21)
        let x = (0..<Int(rate * 3)).map { _ in 0.4 * rng.rangeF(-1...1) }
        let source = DialogueSource(contentID: "noise", cueToken: 1, buffer: DialogueFixtures.buffer(x, rate: rate),
                                    sourceStart: 0, rate: 1)
        let analysis = DialogueAnalysis(version: 1, contentID: "noise", cueToken: 1,
                                        clock: DialogueClock(sourceStart: 0, rate: 1, sampleRate: rate), bufferFrames: x.count,
                                        features: nil, speech: [], units: [], rejections: [])
        for role in [DialoguePad.Role.head, .texture] {
            let frames = 48_000..<96_000
            let pad = DialoguePad(padID: 0, unitID: 0, role: role, frames: frames, transform: .native, accentOffset: 0.1,
                                  duration: Double(frames.count) / rate, protected: false, text: nil, fadeIn: 2400, fadeOut: 2400,
                                  level: .phrase, score: DialogueScore(), padKey: 1)
            var level: Float?
            let buffer = try #require(DialogueChopRenderer.renderPad(pad, source: source, analysis: analysis, gainDB: 0, level: &level))
            let y = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
            let ms = Int(0.001 * rate)
            let head = y.prefix(ms).map { abs($0) }.max() ?? 1, tail = y.suffix(ms).map { abs($0) }.max() ?? 1
            #expect(20 * log10(max(head, 1e-12)) < -60, "\(role) first 1 ms peak \(head)")
            #expect(20 * log10(max(tail, 1e-12)) < -60, "\(role) last 1 ms peak \(tail)")
            #expect(y.max()! > 0.05, "the pad is audible")
        }
    }
}
