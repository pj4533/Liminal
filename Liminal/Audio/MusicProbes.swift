#if DEBUG || LIMINAL_BENCH
import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation

/// PASS 1 step 1 probes (docs/plans/music.md section 12/13). DEBUG only; run via
/// `scripts/render-music.sh probe` (mode=probe). Each probe renders a small graph offline to a WAV
/// that `scripts/analyze-probes.py` checks.
enum MusicProbes {

    /// Render `output` offline for `seconds`, calling `step(t)` every 20 ms of audio before rendering it.
    static func render(_ output: Node, seconds: Double, to url: URL, step: (Double) -> Void) throws {
        let engine = AudioEngine()
        engine.output = output
        let av = engine.avEngine
        let format = AudioKit.Settings.audioFormat
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: av.manualRenderingFormat, frameCapacity: 4096) else { return }
        let frames = AVAudioFrameCount(format.sampleRate * 0.02)
        let total = AVAudioFramePosition(seconds * format.sampleRate)
        var i = 0
        while av.manualRenderingSampleTime < total {
            step(Double(i) * 0.02)
            if try av.renderOffline(frames, to: buffer) == .success { try file.write(from: buffer) }
            i += 1
        }
        engine.stop()
    }

    /// Wall time to render 60 s of a few graphs (node cost estimates).
    static func bench(dir: URL) throws -> [String] {
        func time(_ name: String, _ build: () -> Node) throws -> String {
            let n = build()
            let t0 = Date()
            try render(n, seconds: 60, to: dir.appendingPathComponent("bench.wav")) { _ in }
            return "\(name): \(String(format: "%.2f", Date().timeIntervalSince(t0)))s"
        }
        var out: [String] = []
        out.append(try time("1 osc") { let o = Oscillator(); o.start(); return o })
        out.append(try time("22 osc, 1 mixer") { let os = (0..<22).map { _ in Oscillator(amplitude: 0.01) }; os.forEach { $0.start() }; return Mixer(os) })
        out.append(try time("22 osc, 22 mixers") { let os = (0..<22).map { _ in Oscillator(amplitude: 0.01) }; os.forEach { $0.start() }; return Mixer(os.map { Mixer($0) }) })
        out.append(try time("22 osc stopped, 1 mixer") { let os = (0..<22).map { _ in Oscillator(amplitude: 0.01) }; return Mixer(os) })
        out.append(try time("8 morph") { let os = (0..<8).map { _ in MorphingOscillator(waveformArray: PadTables.tables, amplitude: 0.01) }; os.forEach { $0.start() }; return Mixer(os) })
        out.append(try time("zita") { let o = Oscillator(); o.start(); return ZitaReverb(o) })
        out.append(try time("20 faders") { let o = Oscillator(); o.start(); var n: Node = o; for _ in 0..<20 { n = Fader(n) }; return n })
        out.append(try time("20 panners") { let o = Oscillator(); o.start(); var n: Node = o; for _ in 0..<20 { n = Panner(n) }; return n })
        out.append(try time("pitch shifter") { let o = Oscillator(); o.start(); return PitchShifter(o, shift: 12, windowSize: 2048, crossfade: 1024) })
        out.append(try time("costello") { let o = Oscillator(); o.start(); return CostelloReverb(o, balance: 1, feedback: 0.9) })
        out.append(try time("tanh") { let o = Oscillator(); o.start(); return TanhDistortion(o) })
        out.append(try time("6 fm + env") { let os = (0..<6).map { _ in FMOscillator(amplitude: 0.01) }; os.forEach { $0.start() }; return Mixer(os.map { AmplitudeEnvelope($0) }) })
        out.append(try time("8 env idle") { let os = (0..<8).map { _ in Oscillator(amplitude: 0.01) }; return Mixer(os.map { AmplitudeEnvelope($0) }) })
        out.append(try time("pink+bpf") { let n = PinkNoise(amplitude: 0.1); n.start(); return BandPassButterworthFilter(n) })
        out.append(try time("3 pluck") { let ps = (0..<3).map { _ in PluckedString() }; ps.forEach { $0.start() }; return Mixer(ps) })
        out.append(try time("full engine graph") { GenerativeEngineBench.graph() })
        // First-trigger latency of PluckedString (AudioKit MIDI path).
        do {
            let ps = PluckedString(); ps.start()
            var lines: [String] = []
            var k = 0
            try render(ps, seconds: 1, to: dir.appendingPathComponent("bench.wav")) { t in
                guard k < 3, t >= 0.2 + Double(k) * 0.2 else { return }
                k += 1
                let t0 = DispatchTime.now().uptimeNanoseconds
                let ev = MIDIEvent(noteOn: 64, velocity: 127, channel: 0)
                let t1 = DispatchTime.now().uptimeNanoseconds
                _ = ps.au.scheduleMIDIEventBlock
                let t2 = DispatchTime.now().uptimeNanoseconds
                ps.trigger(frequency: 220, amplitude: 0.5)
                let t3 = DispatchTime.now().uptimeNanoseconds
                lines.append("pluck trigger \(k): MIDIEvent \(Double(t1 - t0) / 1e6) ms, block \(Double(t2 - t1) / 1e6) ms, trigger \(Double(t3 - t2) / 1e6) ms, bytes \(ev.data.count)")
            }
            out += lines
        }
        return out
    }

    static func runAll(dir: URL) throws -> [String] {
        var out: [String] = []

        // A. Fan-out: one Panner feeding three Faders (1, 0.5, 0.25), each into its own Mixer.
        do {
            let osc = Oscillator(waveform: Table(.sine), frequency: 440, amplitude: 0.1)
            let pan = Panner(osc, pan: 0)
            let f1 = Fader(pan, gain: 1), f2 = Fader(pan, gain: 0.5), f3 = Fader(pan, gain: 0.25)
            let m1 = Mixer(f1), m2 = Mixer(f2), m3 = Mixer(f3)
            let master = Mixer(m1, m2, m3)
            osc.start()
            try render(master, seconds: 2, to: dir.appendingPathComponent("probe-fanout3.wav")) { _ in }
            let osc2 = Oscillator(waveform: Table(.sine), frequency: 440, amplitude: 0.1)
            let single = Mixer(Mixer(Fader(Panner(osc2, pan: 0), gain: 1)))
            osc2.start()
            try render(single, seconds: 2, to: dir.appendingPathComponent("probe-fanout1.wav")) { _ in }
            out.append("fanout")
        }

        // B. Ramps offline: 10 s gain ramp 0 -> 1, then a 4 s frequency ramp 220 -> 440.
        do {
            let osc = Oscillator(waveform: Table(.sine), frequency: 220, amplitude: 0.2)
            let fader = Fader(osc, gain: 0)
            osc.start()
            var did = (false, false)
            try render(fader, seconds: 18, to: dir.appendingPathComponent("probe-ramp.wav")) { t in
                if !did.0 { did.0 = true
                    fader.$leftGain.ramp(to: 1, duration: 10); fader.$rightGain.ramp(to: 1, duration: 10) }
                if t >= 12, !did.1 { did.1 = true; osc.$frequency.ramp(to: 440, duration: 4) }
            }
            out.append("ramp")
        }

        // C. ZitaReverb + PeakLimiter offline, driven hot.
        do {
            let osc = Oscillator(waveform: Table(.square), frequency: 110, amplitude: 1.5)
            let zita = ZitaReverb(osc, predelay: 60, crossoverFrequency: 200, lowReleaseTime: 5,
                                  midReleaseTime: 6, dampingFrequency: 5000, dryWetMix: 1)
            let mix = Mixer(osc, zita)
            let lim = PeakLimiter(mix, attackTime: 0.01, decayTime: 0.06, preGain: 0)
            osc.start()
            try render(lim, seconds: 6, to: dir.appendingPathComponent("probe-zita-limiter.wav")) { t in
                if t >= 3 { osc.$amplitude.ramp(to: 0, duration: 0.05) }
            }
            out.append("zita-limiter")
        }

        // D. MorphingOscillator with custom tables: frequency and index changes every 0.25 s.
        do {
            let morph = MorphingOscillator(waveformArray: PadTables.tables, frequency: 220, amplitude: 0.2, index: 0)
            morph.start()
            var rng = MusicRNG(seed: 7)
            var last = -1.0
            try render(morph, seconds: 8, to: dir.appendingPathComponent("probe-morph.wav")) { t in
                if t - last >= 0.25 { last = t
                    let midi = 48 + Int(rng.unit() * 24)
                    morph.$frequency.ramp(to: Scale.midiToFrequency(midi), duration: 0.3)
                    morph.$index.ramp(to: rng.unit() * 3, duration: 0.2)
                }
            }
            out.append("morph")
        }

        // E. Fixed pan via AVAudioMixing (Mixer.pan) into a downstream Mixer, and amplitude-ramp
        //    "envelopes" (attack 0.1 s, release 0.3 s) instead of AmplitudeEnvelope nodes.
        do {
            let a = Oscillator(waveform: Table(.sine), frequency: 440, amplitude: 0)
            let b = Oscillator(waveform: Table(.sine), frequency: 660, amplitude: 0.2)
            let ma = Mixer(a); ma.pan = -0.7
            let mb = Mixer(b); mb.pan = 1
            let out2 = Mixer(ma, mb)
            a.start(); b.start()
            var did = (false, false)
            try render(out2, seconds: 3, to: dir.appendingPathComponent("probe-mixerpan.wav")) { t in
                if t >= 1, !did.0 { did.0 = true; a.$amplitude.ramp(to: 0.2, duration: 0.1) }
                if t >= 2, !did.1 { did.1 = true; a.$amplitude.ramp(to: 0, duration: 0.3) }
            }
            out.append("mixerpan")
        }
        return out
    }
}

@MainActor enum GenerativeEngineBench {
    static func graph() -> Node {
        let layers: [MusicLayer] = [DroneLayer(), PadLayer(), LeadLayer(), DripsLayer(),
                                    KeysLayer(), AirLayer(), GrainLayer(), PluckLayer()]
        for l in layers { l.prepare(rng: MusicRNG(seed: 1)) }
        let mix = MixBus(layers: layers.flatMap(\.allStrips), delayTime: 1)
        return mix.output
    }
}
#endif
