import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Soft melodic voice playing developing motifs on a drifting 13-23 s loop (section 7; plan 17-29 s, decision D65).
/// Two `VoiceLayer`s alternate so release tails overlap instead of being retuned. The answer voice
/// (PASS 2, decision D65) has its own pair and its own strip, replies 40 % of the time 2-6 s after the
/// motif with the transposed or inverted contour, 6 dB quieter, panned opposite the lead.
nonisolated final class LeadLayer: BaseLayer {
    private let voices: [VoiceLayer]
    private let answers: [VoiceLayer]
    private let answerStrip: LayerStrip
    private var nextAnswer = 0
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
        var acfg = cfg
        acfg.waveforms = [Table(.sine), Table(.sine)]
        acfg.detuneAmount = 0.003
        answers = [VoiceLayer(config: acfg), VoiceLayer(config: acfg)]
        let mix = Mixer(voices.map(\.output))
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 3000)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-17) * 1.414 / 0.5,
                               reverb: 0.6, delay: 0.45)
        var tmp = SeededRNG(seed: 0)
        loop = LoopClock(bounds: 13...23, rng: &tmp)
        answerStrip = LayerStrip(source: Mixer(answers.map(\.output)), trim: dbToGain(-18) * 1.414 / 0.5,
                                 reverb: 0.75, delay: 0.55)
        super.init(id: .lead, strip: strip, entryThreshold: 0.45)
        extraStrips = [answerStrip]
        generators = voices.flatMap(\.oscillators) + answers.flatMap(\.oscillators)
    }

    override func prepare(rng: SeededRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: 13...23, rng: &self.rng)
        panLFO = ParameterDrift.Channel(period: self.rng.range(40...70), phase: self.rng.range(0...6))
    }

    private func center(_ ctx: LayerContext) -> Int { 69 + ctx.registerShift }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(2...6), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: 13...23, rng: &rng)
        developer.sceneChanged(rng: &rng)
        let attack = rng.rangeF(0.4...1.5), release = rng.rangeF(3...5)
        voices.forEach { $0.setEnvelope(attack: attack, release: release) }
        answers.forEach { $0.setEnvelope(attack: attack * 1.3, release: release * 1.2) }
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.4 - 0.8 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        developer.degreeCount = ctx.field.degreeCount
        developer.restProbability = 0.42 - 0.15 * ctx.density
        guard let motif = developer.next(rng: &rng, field: ctx.field, center: center(ctx)) else { return }
        var t = 0.0
        for i in 0..<motif.degrees.count {
            let degree = motif.degrees[i], dur = motif.durations[i]
            let vel = rng.rangeF(0.6...1.0) * (i == 0 ? 1 : 0.9)
            after(t, ctx: ctx) { [weak self] in self?.play(degree: degree, duration: dur, velocity: vel, ctx: ctx) }
            t += motif.gaps[i]
        }
        // Answer: transposed or inverted contour after a pause.
        if rng.chance(0.4) {
            let a = motif.degrees.first ?? 0
            let shift = rng.pick([-2, -1, 1, 2, 3])
            let invert = rng.chance(0.4)
            let degrees = motif.degrees.map { invert ? 2 * a - $0 + shift : $0 + shift }
            var ta = t + rng.range(2...6)
            for i in 0..<degrees.count {
                let d = degrees[i], dur = motif.durations[i] * 1.2
                let vel = rng.rangeF(0.55...0.9)
                after(ta, ctx: ctx) { [weak self] in self?.answer(degree: d, duration: dur, velocity: vel, ctx: ctx) }
                ta += motif.gaps[i] * rng.range(1.0...1.3)
            }
        }
    }

    private func resolve(_ degree: Int, duration: Double, f: HarmonicField) -> Int {
        var midi = f.midi(degree: degree, octave: 4)
        while midi > 88 { midi -= 12 }
        while midi < 55 { midi += 12 }
        if duration > 1.5 && !f.isChordTone(midi) {
            let near = f.nearest(to: midi, chordTonesOnly: true)
            if abs(near - midi) <= 2 { midi = near }
        }
        return midi
    }

    private func answer(degree: Int, duration: Double, velocity: Float, ctx: LayerContext) {
        let midi = resolve(degree, duration: duration, f: ctx.field)
        let v = answers[nextAnswer]
        nextAnswer = (nextAnswer + 1) % answers.count
        v.setFrequency(Scale.midiToFrequency(midi), glide: 0.08)
        v.setAmplitude(peak * velocity * 0.5, over: 0.05)   // -6 dB
        after(0.06, ctx: ctx) { [weak self] in
            guard self != nil else { return }
            v.openGate()
            ctx.emit(.noteOn, layer: .lead, midi: midi, velocity: velocity * 0.5)
        }
        after(0.06 + duration, ctx: ctx) { v.closeGate() }
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
        let pan = 0.5 * panLFO.value(at: ctx.time)
        strip.setPan(pan, over: 0.12)
        answerStrip.setPan(-pan - (pan >= 0 ? 0.15 : -0.15), over: 0.12)
        strip.setSends(reverb: 0.6, delay: 0.45 * ctx.delayScale, over: 0.12)
        answerStrip.setSends(reverb: 0.75, delay: 0.55 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        voices.forEach { $0.closeGate() }
        answers.forEach { $0.closeGate() }
    }
}
