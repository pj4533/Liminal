import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Mist (decision D98; were the grains of D33, D61, D84 with 12-30 ms "glints" up to MIDI 106). A pool of
/// slow sine swells on chord tones in C4-G5 (octave drops only), +-6 cents jitter, in four fixed pan groups
/// (-0.7, -0.25, 0.25, 0.7). Each swell rises over 280-560 ms and fades over 0.8-2 s; at most 1.5 starts per
/// second, scaled by how far intensity is above the layer's threshold, density and image energy. Mostly wet.
/// Envelopes are linear amplitude ramps on the oscillators and the groups are panned by `Mixer.pan` (D68).
nonisolated final class GrainLayer: BaseLayer {
    static let poolSize = 8
    static let groupPans: [Float] = [-0.7, -0.25, 0.25, 0.7]

    private let oscs: [Oscillator]
    private var pool = VoicePool(GrainLayer.poolSize)
    private var cloud = ParameterDrift.Channel(period: 23, phase: 0)
    private let amp: Float = 0.5

    init() {
        oscs = (0..<GrainLayer.poolSize).map { _ in GrainLayer.makeOscillator() }
        let o = oscs
        let groups: [Mixer] = (0..<4).map { g in
            let m = Mixer(stride(from: g, to: GrainLayer.poolSize, by: 4).map { o[$0] })
            m.pan = GrainLayer.groupPans[g]
            return m
        }
        let mix = Mixer(groups)
        let strip = LayerStrip(source: mix, trim: dbToGain(-24) * 1.414 / 0.5, reverb: 1.0, delay: 0.2, dry: 0.25)
        super.init(id: .grains, strip: strip, entryThreshold: 0.65)
        generators = oscs
    }

    override func prepare(rng: MusicRNG) {
        super.prepare(rng: rng)
        cloud = ParameterDrift.Channel(period: self.rng.range(15...35), phase: self.rng.range(0...6))
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(0.5...2), ctx: ctx) { [weak self] in self?.tick(ctx: ctx) } }
    }

    /// Grains per second now.
    private func rate(_ ctx: LayerContext) -> Double {
        let thr = ctx.scene?.thresholds[.grains] ?? entryThreshold
        let above = min(max((ctx.intensity - thr + 0.05) / 0.35, 0), 1)
        let level = strip.targetLevel
        // A slow "cloud" channel makes the texture thicken and thin within a scene.
        let c = 0.5 + 0.5 * cloud.unit(at: ctx.time)
        let r = (0.3 + 1.0 * above * c) * (0.6 + 0.8 * ctx.density) * ctx.coupling.energyScale
        return min(1.5, max(0.2, Double(r * max(level, 0.15))))
    }

    private func tick(ctx: LayerContext) {
        let r = rate(ctx)
        // Exponential inter-onset times (Poisson cloud), clamped.
        let gap = min(max(-log(max(rng.unitD(), 1e-4)) / r, 0.25), 6)
        after(gap, ctx: ctx) { [weak self] in self?.tick(ctx: ctx) }
        guard isActive || strip.targetLevel > 0.05 else { return }
        grain(ctx: ctx)
    }

    private func grain(ctx: LayerContext) {
        let shift = max(-3, min(3, ctx.registerShift))
        let tones = ctx.field.chordTones(in: (62 + shift)...(79 + shift))
        guard !tones.isEmpty else { return }
        var m = rng.pick(tones)
        if rng.unit() < 0.25 { m -= 12 }
        m = min(max(m, 58), 79)
        let cents = Double(rng.rangeF(-6...6))
        let (v, tok) = pool.take(now: ctx.time)
        let osc = oscs[v]
        let vel = rng.rangeF(0.35...0.9)
        let attack = rng.range(0.28...0.56)
        let release = rng.range(0.8...2)
        let tilt = Float(max(0.6, 1 - 0.02 * Double(max(0, m - 67))))
        // Constant-loudness cloud (decision D84): above 1 start/s each swell is scaled by sqrt(1 / rate).
        let peak = amp * vel * tilt * Float(min(1, (1 / rate(ctx)).squareRoot())) * ctx.shareAttack(layer: .grains, weight: 0.3)
        let hold = attack + ParamRamp.nextTick + rng.range(0.1...0.5)
        ParamRamp.set(osc.$amplitude, 0, over: 0.08)
        after(0.1, ctx: ctx) { [weak self] in
            guard let self, self.pool.isCurrent(v, tok) else { return }
            ParamRamp.set(osc.$frequency, Scale.midiToFrequency(Double(m) + cents / 100), over: ParamRamp.minimum)
            ParamRamp.set(osc.$amplitude, peak, over: attack)
            ctx.emit(.noteOn, layer: .grains, midi: m, velocity: vel * 0.5)
            self.after(hold, ctx: ctx) { [weak self] in
                guard let self, self.pool.isCurrent(v, tok) else { return }
                ParamRamp.set(osc.$amplitude, 0, over: release)
            }
        }
    }

    override func update(dt: Double, ctx: LayerContext) {
        strip.setSends(reverb: 1.0, delay: 0.2 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        for o in oscs { ParamRamp.set(o.$amplitude, 0, over: max(0.05, fade)) }
    }
    override func controllerTimbre(ctx: LayerContext) -> ControllerAmbientTimbre? {
        .init(name: "Mist swell", attack: 0.42, release: 1.4, decay: 2.0, trim: strip.trim)
    }
    static func makeOscillator() -> Oscillator {
        Oscillator(waveform: Table(.sine), frequency: 880, amplitude: 0)
    }

}
