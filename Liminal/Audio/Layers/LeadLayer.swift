import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Soft melodic voice playing developing motifs on a drifting 17-29 s loop (section 7).
/// Two `VoiceLayer`s alternate so release tails overlap instead of being retuned. The answer voice
/// (PASS 2) will reuse the second voice's role.
nonisolated final class LeadLayer: BaseLayer {
    private let voices: [VoiceLayer]
    private let filter: LowPassButterworthFilter
    private var loop: LoopClock
    private var developer = MotifDeveloper()
    private var nextVoice = 0
    private var panLFO = ParameterDrift.Channel(period: 53, phase: 0)
    private let peak: Float = 0.5

    init() {
        let cfg = VoiceLayer.Config(oscillatorCount: 2, detuneAmount: 0.0015, attackTime: 0.8, releaseTime: 4,
                                    amplitude: 0.5, waveforms: [Table(.sine), Table(.triangle)], mix: [1, 0.6])
        voices = [VoiceLayer(config: cfg), VoiceLayer(config: cfg)]
        let mix = Mixer(voices.map(\.output))
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 3000)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-15) * 1.414 / 0.5,
                               reverb: 0.6, delay: 0.45)
        var tmp = SeededRNG(seed: 0)
        loop = LoopClock(bounds: 17...29, rng: &tmp)
        super.init(id: .lead, strip: strip, entryThreshold: 0.45)
        generators = voices.flatMap(\.oscillators)
    }

    override func prepare(rng: SeededRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: 17...29, rng: &self.rng)
        panLFO = ParameterDrift.Channel(period: self.rng.range(40...70), phase: self.rng.range(0...6))
    }

    private func center(_ ctx: LayerContext) -> Int { 69 + ctx.registerShift }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(2...6), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: 17...29, rng: &rng)
        developer.sceneChanged(rng: &rng)
        let attack = rng.rangeF(0.4...1.5), release = rng.rangeF(3...5)
        voices.forEach { $0.setEnvelope(attack: attack, release: release) }
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.4 - 0.8 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        developer.degreeCount = ctx.field.degreeCount
        developer.restProbability = 0.5 - 0.15 * ctx.density
        guard let motif = developer.next(rng: &rng, field: ctx.field, center: center(ctx)) else { return }
        var t = 0.0
        for i in 0..<motif.degrees.count {
            let degree = motif.degrees[i], dur = motif.durations[i]
            let vel = rng.rangeF(0.6...1.0) * (i == 0 ? 1 : 0.9)
            after(t, ctx: ctx) { [weak self] in self?.play(degree: degree, duration: dur, velocity: vel, ctx: ctx) }
            t += motif.gaps[i]
        }
    }

    private func play(degree: Int, duration: Double, velocity: Float, ctx: LayerContext) {
        let f = ctx.field
        var midi = f.midi(degree: degree, octave: 4)
        while midi > 88 { midi -= 12 }
        while midi < 55 { midi += 12 }
        // A long note a semitone from a chord tone moves onto it.
        if duration > 1.5 && !f.isChordTone(midi) {
            let near = f.nearest(to: midi, chordTonesOnly: true)
            if abs(near - midi) <= 2 { midi = near }
        }
        let v = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        v.setFrequency(Scale.midiToFrequency(midi), glide: 0.08)
        v.setAmplitude(peak * velocity, over: 0.05)
        after(0.06, ctx: ctx) { [weak self] in
            guard self != nil else { return }
            v.openGate()
            ctx.emit(.noteOn, layer: .lead, midi: midi, velocity: velocity)
        }
        after(0.06 + duration, ctx: ctx) { v.closeGate() }
    }

    override func update(dt: Double, ctx: LayerContext) {
        ParamRamp.set(filter.$cutoffFrequency, expMap(ctx.brightness, 1200, 6000), over: 0.12)
        strip.setPan(0.5 * panLFO.value(at: ctx.time), over: 0.12)
        strip.setSends(reverb: 0.6, delay: 0.45 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) { voices.forEach { $0.closeGate() } }
}
