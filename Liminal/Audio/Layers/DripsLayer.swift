import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// The original shimmer voice, now a four-voice round-robin FM pool so notes overlap (decision D16).
/// Clusters of 1-4 high chord tones on a 7-13 s loop. Each note fires `.noteOn` for `.drips`, which the
/// facade forwards to `shimmerNotePlayed`.
nonisolated final class DripsLayer: BaseLayer {
    static let poolSize = 4

    private let oscs: [FMOscillator]
    private let envs: [AmplitudeEnvelope]
    private let pans: [Panner]
    private var loop: LoopClock
    private var chain = MarkovChain.highShimmer(degreeCount: 7)
    private var next = 0

    init() {
        oscs = (0..<DripsLayer.poolSize).map { _ in
            FMOscillator(waveform: Table(.sine), baseFrequency: 880, carrierMultiplier: 1,
                         modulatingMultiplier: 2, modulationIndex: 0, amplitude: 0.5)
        }
        envs = oscs.map { AmplitudeEnvelope($0, attackDuration: 0.008, decayDuration: 0.35,
                                            sustainLevel: 0.25, releaseDuration: 1.2) }
        pans = envs.map { Panner($0, pan: 0) }
        let mix = Mixer(pans)
        let strip = LayerStrip(source: mix, trim: dbToGain(-17) * 1.414 / 0.5, reverb: 0.7, delay: 0.6)
        var tmp = SeededRNG(seed: 0)
        loop = LoopClock(bounds: 7...13, rng: &tmp)
        super.init(id: .drips, strip: strip, entryThreshold: 0.35)
        generators = oscs
    }

    override func prepare(rng: SeededRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: 7...13, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(1...4), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: 7...13, rng: &rng)
    }

    override func harmonyDidChange(_ change: HarmonyChange, ctx: LayerContext) {
        if case .key(let old, let new) = change, old.degreeCount != new.degreeCount {
            chain = MarkovChain.highShimmer(degreeCount: new.degreeCount)
        }
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.5 - 0.9 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        if rng.chance(0.25 - 0.15 * ctx.density) { return }   // occasional empty cycle
        let count = 1 + rng.weighted([0.35, 0.3, 0.2, 0.15].map { $0 * (0.6 + ctx.density) })
        var t = 0.0
        for i in 0..<count {
            let vel = rng.rangeF(0.5...1.0) * (i == 0 ? 1 : 0.85)
            after(t, ctx: ctx) { [weak self] in self?.play(velocity: vel, ctx: ctx) }
            t += rng.range(0.18...0.9) * Double(1.3 - 0.6 * ctx.density)
        }
    }

    private func play(velocity: Float, ctx: LayerContext) {
        let f = ctx.field
        if chain.count != f.degreeCount { chain = MarkovChain.highShimmer(degreeCount: f.degreeCount) }
        let degree = chain.next(using: &rng)
        let lo = 72 + max(-3, min(5, ctx.registerShift)), hi = lo + 24
        var midi = f.midi(degree: degree, octave: 5 + (rng.chance(0.4) ? 1 : 0))
        while midi > hi { midi -= 12 }
        while midi < lo { midi += 12 }
        if rng.chance(0.65) || !f.inScale(midi) { midi = f.nearest(to: midi, chordTonesOnly: true) }
        let v = next
        next = (next + 1) % DripsLayer.poolSize
        let osc = oscs[v]
        ParamRamp.set(osc.$baseFrequency, Scale.midiToFrequency(midi), over: ParamRamp.minimum)
        ParamRamp.set(osc.$amplitude, 0.5 * velocity, over: ParamRamp.minimum)
        // Brighter scenes give glassier, more inharmonic drips (ratio 1:3 or 1:3.5, more index).
        let ratio: Float = ctx.brightness > 0.55 && rng.chance(0.5) ? (rng.chance(0.5) ? 3 : 3.5) : 2
        ParamRamp.set(osc.$modulatingMultiplier, ratio, over: ParamRamp.minimum)
        ParamRamp.set(osc.$modulationIndex, (0.4 + 1.6 * ctx.brightness) * velocity, over: ParamRamp.minimum)
        ParamRamp.set(pans[v].$pan, rng.rangeF(-0.8...0.8), over: ParamRamp.minimum)
        let env = envs[v]
        let hold = rng.range(0.05...0.15)
        ParamRamp.set(env.$releaseDuration, rng.rangeF(0.8...1.8), over: ParamRamp.minimum)
        after(0.025, ctx: ctx) { [weak self] in
            guard let self else { return }
            env.openGate()
            ParamRamp.set(osc.$modulationIndex, 0.05, over: 0.7)
            ctx.emit(.noteOn, layer: .drips, midi: midi, velocity: velocity)
            self.after(hold, ctx: ctx) { env.closeGate() }
        }
    }

    override func update(dt: Double, ctx: LayerContext) {
        strip.setSends(reverb: 0.7, delay: 0.6 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) { envs.forEach { $0.closeGate() } }
}
