import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Grains (plan section 7, decisions D33, D61): a pool of short sine grains on chord tones in 72-96
/// with +-1 octave spread and +-6 cents jitter, in four fixed pan groups (-0.7, -0.25, 0.25, 0.7).
/// The rate follows how far intensity is above the layer's entry threshold (0.5 to about 10 grains/s),
/// scaled by density and image energy. Each grain start is a scheduled event; the 20 ms tick jitter is
/// part of the texture. Pool of 8 (the plan's first shrink step), measured to be enough at 10/s.
/// Envelopes are linear amplitude ramps on the oscillators and the groups are panned by `Mixer.pan`
/// (decision D68): no envelope or panner nodes.
nonisolated final class GrainLayer: BaseLayer {
    static let poolSize = 8
    static let groupPans: [Float] = [-0.7, -0.25, 0.25, 0.7]

    private let oscs: [Oscillator]
    private var pool = VoicePool(GrainLayer.poolSize)
    private var cloud = ParameterDrift.Channel(period: 23, phase: 0)
    private let amp: Float = 0.5

    init() {
        oscs = (0..<GrainLayer.poolSize).map { _ in Oscillator(waveform: Table(.sine), frequency: 880, amplitude: 0) }
        let o = oscs
        let groups: [Mixer] = (0..<4).map { g in
            let m = Mixer(stride(from: g, to: GrainLayer.poolSize, by: 4).map { o[$0] })
            m.pan = GrainLayer.groupPans[g]
            return m
        }
        let mix = Mixer(groups)
        let strip = LayerStrip(source: mix, trim: dbToGain(-16) * 1.414 / 0.5, reverb: 0.8, delay: 0.2)
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
        let r = (0.5 + 9.5 * above * c) * (0.6 + 0.8 * ctx.density) * ctx.coupling.energyScale
        return max(0.3, Double(r * max(level, 0.15)))
    }

    private func tick(ctx: LayerContext) {
        let r = rate(ctx)
        // Exponential inter-onset times (Poisson cloud), clamped.
        let gap = min(max(-log(max(rng.unitD(), 1e-4)) / r, 0.04), 4)
        after(gap, ctx: ctx) { [weak self] in self?.tick(ctx: ctx) }
        guard isActive || strip.targetLevel > 0.05 else { return }
        grain(ctx: ctx)
    }

    private func grain(ctx: LayerContext) {
        let shift = max(-3, min(6, ctx.registerShift))
        let tones = ctx.field.chordTones(in: (74 + shift)...(98 + shift))
        guard !tones.isEmpty else { return }
        var m = rng.pick(tones)
        let o = rng.unit()
        if o < 0.12 { m -= 12 } else if o > 0.78 { m += 12 }
        m = min(max(m, 64), 106)
        let cents = Double(rng.rangeF(-6...6))
        let (v, tok) = pool.take(now: ctx.time)
        let osc = oscs[v]
        let vel = rng.rangeF(0.35...1.0)
        // 30 % "glints": sharper attack and shorter tail, so the cloud has audible points in it.
        let glint = rng.chance(0.3)
        let attack = glint ? rng.range(0.012...0.03) : rng.range(0.06...0.15)
        let release = glint ? rng.range(0.25...0.6) : rng.range(0.15...0.4)
        let tilt = Float(1 - 0.012 * Double(max(0, m - 76)))
        // Constant-loudness cloud (decision D84): above 2 grains/s each grain is scaled by sqrt(2 / rate), so
        // thick clouds add texture rather than level (overlapping grains peaked the bypassed mix at -0.4 dBFS).
        let peak = amp * vel * tilt * Float(min(1, (2 / rate(ctx)).squareRoot())) * ctx.shareAttack(layer: .grains, weight: 0.5)
        let hold = max(attack, ParamRamp.minimum) + ParamRamp.nextTick + rng.range(0...0.08)
        ParamRamp.set(osc.$amplitude, 0, over: ParamRamp.minimum)
        after(0.025, ctx: ctx) { [weak self] in
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
        strip.setSends(reverb: 0.8, delay: 0.2 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        for o in oscs { ParamRamp.set(o.$amplitude, 0, over: max(0.05, fade)) }
    }
}
