import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Four voices, each a detuned pair of `MorphingOscillator`s on custom band-limited tables, through one
/// `MoogLadder`. Chord changes are voice-led one voice at a time (sections 5 and 7, decisions D18, D22).
nonisolated final class PadLayer: BaseLayer {
    static let voiceCount = 4
    static let baseRange = 48...76

    private struct Voice {
        var midi: Int = 60
        var pitch: Double = 60          // fractional MIDI actually sounding (glides)
        var pitchFrom: Double = 60
        var pitchStart: Double = 0
        var pitchDur: Double = 0
        var env = SoftEnv(0)            // per-voice swell / dip
        var count = SoftEnv(0)          // voice-count gate (intensity dependent)
        var detuneLFO = ParameterDrift.Channel(period: 20, phase: 0)
        var indexLFO = ParameterDrift.Channel(period: 60, phase: 0)
        var breathLFO = ParameterDrift.Channel(period: 30, phase: 0)
        var busy = false                // in the middle of a re-voice
    }

    private let left: [MorphingOscillator]
    private let right: [MorphingOscillator]
    private let ladder: MoogLadder
    private var voices = [Voice](repeating: Voice(), count: PadLayer.voiceCount)
    private var widthLFO = ParameterDrift.Channel(period: 90, phase: 0)
    private var panLFO = ParameterDrift.Channel(period: 120, phase: 0)
    private var voiced = false
    private let perOsc: Float = 0.11

    init() {
        left = (0..<PadLayer.voiceCount).map { _ in MorphingOscillator(waveformArray: PadTables.tables, amplitude: 0) }
        right = (0..<PadLayer.voiceCount).map { _ in MorphingOscillator(waveformArray: PadTables.tables, amplitude: 0) }
        // Fixed pair spread via Mixer.pan (no Panner nodes, decision D68).
        let lp = Mixer(left); lp.pan = -0.6
        let rp = Mixer(right); rp.pan = 0.6
        let mix = Mixer(lp, rp)
        ladder = MoogLadder(mix, cutoffFrequency: 1200, resonance: 0.1)
        let strip = LayerStrip(source: mix, filter: ladder, trim: dbToGain(-7) * 1.414 / 0.5,
                               reverb: 0.5, delay: 0.1)
        super.init(id: .pad, strip: strip, entryThreshold: 0.2)
        generators = left + right
    }

    override func prepare(rng: SeededRNG) {
        super.prepare(rng: rng)
        let det = ParameterDrift.channels(PadLayer.voiceCount, periods: 14...37, rng: &self.rng)
        let idx = ParameterDrift.channels(PadLayer.voiceCount, periods: 40...90, rng: &self.rng)
        let br = ParameterDrift.channels(PadLayer.voiceCount, periods: 18...41, rng: &self.rng)
        for v in 0..<PadLayer.voiceCount { voices[v].detuneLFO = det[v]; voices[v].indexLFO = idx[v]; voices[v].breathLFO = br[v] }
        widthLFO = ParameterDrift.Channel(period: self.rng.range(70...130), phase: self.rng.range(0...6))
        panLFO = ParameterDrift.Channel(period: self.rng.range(90...160), phase: self.rng.range(0...6))
    }

    private func range(_ ctx: LayerContext) -> ClosedRange<Int> {
        let s = max(-5, min(5, ctx.registerShift))
        // Never below C3: the detuned pair is split left/right, and below 120 Hz that decorrelates the
        // sub band (stereo gate, decision D74).
        return max(48, PadLayer.baseRange.lowerBound + s)...(PadLayer.baseRange.upperBound + s)
    }

    /// Fresh voicing (first activation or after a power-down): evenly spread seeds, voice-led onto the chord.
    private func initialVoicing(ctx: LayerContext) {
        let r = range(ctx)
        let span = Double(r.upperBound - r.lowerBound)
        let seeds = (0..<PadLayer.voiceCount).map { r.lowerBound + Int(span * (0.12 + 0.25 * Double($0))) }
        let notes = ctx.harmony.voiceLead(from: seeds, to: ctx.field.chord, range: r)
        for v in 0..<PadLayer.voiceCount {
            voices[v].midi = notes[v]
            voices[v].pitch = Double(notes[v]); voices[v].pitchFrom = voices[v].pitch; voices[v].pitchDur = 0
            voices[v].busy = false
            voices[v].env = SoftEnv(0)
            voices[v].env.go(to: 1, over: rng.range(2...6), now: ctx.time)
        }
        voiced = true
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { initialVoicing(ctx: ctx) }
    }

    override func harmonyDidChange(_ change: HarmonyChange, ctx: LayerContext) {
        guard voiced, generators.first?.isStarted == true else { voiced = false; return }
        revoice(ctx: ctx, slow: { if case .key = change { return true } else { return false } }())
    }

    /// Re-voice one voice at a time: dip to 20 %, retune with a short glide, swell back.
    /// The other voices keep sounding, so a chord change is a slow cross-fade (section 5).
    func revoice(ctx: LayerContext, slow: Bool) {
        let targets = ctx.harmony.voiceLead(from: voices.map(\.midi), to: ctx.field.chord, range: range(ctx))
        let order = (0..<PadLayer.voiceCount).filter { voices[$0].midi != targets[$0] }
        var offset = 0.0
        let spread = slow ? rng.range(10...20) : rng.range(4...12)
        for (k, v) in order.shuffled(using: &rng).enumerated() {
            let target = targets[v]
            let start = k == 0 ? 0 : offset
            offset += spread / Double(max(1, order.count))
            after(start, ctx: ctx) { [weak self] in self?.revoiceVoice(v, to: target, ctx: ctx) }
        }
    }

    private func revoiceVoice(_ v: Int, to target: Int, ctx: LayerContext) {
        guard !voices[v].busy else { voices[v].midi = target; startGlide(v, ctx: ctx); return }
        voices[v].busy = true
        let dip = rng.range(1.5...3)
        voices[v].env.go(to: 0.2, over: dip, now: ctx.time)
        after(dip, ctx: ctx) { [weak self] in
            guard let self else { return }
            self.voices[v].midi = target
            self.startGlide(v, ctx: ctx)
            self.voices[v].env.go(to: 1, over: self.rng.range(3...8), now: ctx.time)
            self.voices[v].busy = false
        }
    }

    private func startGlide(_ v: Int, ctx: LayerContext) {
        voices[v].pitchFrom = voices[v].pitch
        voices[v].pitchStart = ctx.time
        voices[v].pitchDur = 0.3
    }

    /// Re-bloom 1-3 voices (used by imageDidChange).
    func rebloom(ctx: LayerContext) {
        guard voiced else { return }
        let n = rng.int(1...3)
        for v in Array((0..<PadLayer.voiceCount).shuffled(using: &rng).prefix(n)) where !voices[v].busy {
            voices[v].env.go(to: 0.35, over: 1.5, now: ctx.time)
            after(1.6, ctx: ctx) { [weak self] in
                guard let self else { return }
                self.voices[v].env.go(to: 1, over: self.rng.range(4...7), now: ctx.time)
            }
        }
    }

    override func update(dt: Double, ctx: LayerContext) {
        guard voiced else { if isActive { initialVoicing(ctx: ctx) }; return }
        let t = ctx.time
        let active = ctx.intensity < 0.2 ? 2 : (ctx.intensity < 0.4 ? 3 : 4)
        let b = min(1, ctx.brightness + ctx.padBrightnessBoost)
        let width = 0.7 + 0.3 * widthLFO.unit(at: t) + 0.15 * (ctx.activity - 0.5)
        let baseIndex = min(max(0.2 + 2.6 * b, 0), 3)
        for v in 0..<PadLayer.voiceCount {
            // Voice count: drop the outer voices first (top, then bottom).
            let rank = [2, 1, 3, 0][v]   // priority: voice 2 and 1 always, then 3, then 0
            let want: Float = rank < active ? 1 : 0
            if voices[v].count.target != want { voices[v].count.go(to: want, over: 6, now: t) }
            let gate = voices[v].count.tick(t)
            let env = voices[v].env.tick(t)

            if voices[v].pitchDur > 0 {
                let u = min((t - voices[v].pitchStart) / voices[v].pitchDur, 1)
                voices[v].pitch = voices[v].pitchFrom + (Double(voices[v].midi) - voices[v].pitchFrom) * u
                if u >= 1 { voices[v].pitchDur = 0 }
            } else {
                voices[v].pitch = Double(voices[v].midi)
            }
            let cents = Double((4 + 5 * voices[v].detuneLFO.unit(at: t)) * Float(width))
            let fl = Scale.midiToFrequency(voices[v].pitch - cents / 100)
            let fr = Scale.midiToFrequency(voices[v].pitch + cents / 100)
            // Gentle level tilt: higher voices a little quieter.
            let tilt = Float(1.0 - 0.012 * (voices[v].pitch - 60))
            // Each voice breathes on its own slow LFO (deeper when the scene is calm).
            let breathDepth = 0.45 - 0.25 * ctx.intensity
            let breath = 1 - breathDepth + breathDepth * voices[v].breathLFO.unit(at: t)
            let a = perOsc * gate * env * tilt * breath
            let idx = min(max(baseIndex + 1.0 * voices[v].indexLFO.value(at: t), 0), 3)
            ParamRamp.set(left[v].$frequency, fl, over: 0.12)
            ParamRamp.set(right[v].$frequency, fr, over: 0.12)
            ParamRamp.set(left[v].$amplitude, a, over: 0.12)
            ParamRamp.set(right[v].$amplitude, a, over: 0.12)
            ParamRamp.set(left[v].$index, idx, over: 0.12)
            ParamRamp.set(right[v].$index, min(idx + 0.15, 3), over: 0.12)
        }
        ParamRamp.set(ladder.$cutoffFrequency, expMap(b, 450, 6000), over: 0.12)
        strip.setPan(0.15 * panLFO.value(at: t), over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) { voiced = false }
}
