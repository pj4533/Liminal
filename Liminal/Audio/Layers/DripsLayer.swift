import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// The original shimmer voice, now a four-voice round-robin FM pool so notes overlap (decision D16).
/// Clusters of 1-4 high chord tones on a 2.5-6 s loop (D84). Each note fires `.noteOn` for `.drips`, which the
/// facade forwards to `shimmerNotePlayed`.
nonisolated final class DripsLayer: BaseLayer {
    static let poolSize = 4

    static let voicePans: [Float] = [-0.8, -0.3, 0.3, 0.8]
    private let oscs: [FMOscillator]
    private var pool = VoicePool(DripsLayer.poolSize)
    private var loop: LoopClock
    private var chain = MarkovChain.highShimmer(degreeCount: 7)
    /// Mallet preset (1:4, index 1.5 to 0 in 150 ms, shorter decay) chosen per scene; else the sine blip.
    private var mallet = false

    init() {
        oscs = (0..<DripsLayer.poolSize).map { _ in
            FMOscillator(waveform: Table(.sine), baseFrequency: 880, carrierMultiplier: 1,
                         modulatingMultiplier: 2, modulationIndex: 0, amplitude: 0.5)
        }
        // Fixed per-voice pans via Mixer.pan; a note picks the voice nearest its random pan (D68).
        let o = oscs
        let mix = Mixer((0..<DripsLayer.poolSize).map { i -> Mixer in
            let m = Mixer(o[i]); m.pan = DripsLayer.voicePans[i]; return m
        })
        let strip = LayerStrip(source: mix, trim: dbToGain(-12.5) * 1.414 / 0.5, reverb: 0.7, delay: 0.6)
        var tmp = MusicRNG(seed: 0)
        loop = LoopClock(bounds: 2.5...6, rng: &tmp)
        super.init(id: .drips, strip: strip, entryThreshold: 0.35)
        generators = oscs
    }

    override func prepare(rng: MusicRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: 2.5...6, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(1...4), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: 2.5...6, rng: &rng)
        mallet = rng.chance(ctx.style.dripsMallet)
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
        if rng.chance(0.15 - 0.1 * ctx.density) { return }   // occasional empty cycle
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
        let want = rng.rangeF(-0.8...0.8)
        let nearest = (0..<DripsLayer.poolSize).sorted { abs(DripsLayer.voicePans[$0] - want) < abs(DripsLayer.voicePans[$1] - want) }
        let (v, tok) = pool.take(preferring: Array(nearest.prefix(2)), now: ctx.time, minAge: 1.2)
        let osc = oscs[v]
        let fm = ctx.coupling.fmScale
        // Brighter scenes give glassier, more inharmonic drips (ratio 1:3 or 1:3.5, more index).
        let ratio: Float = mallet ? 4 : (ctx.brightness > 0.55 && rng.chance(0.35) ? (rng.chance(0.5) ? 3 : 3.5) : 2)
        // Key-scaled FM index (decision D89): full below G5, falling to 40 % at the top of the range, as a
        // struck bar or string has fewer partials the higher it is. Unscaled, a ratio-3.5 drip at C7 put its
        // sidebands at 7-20 kHz and a bright scene's drips carried a third of their power above 4 kHz.
        let keyScale = Float(min(1, max(0.4, 1 - 0.028 * Double(midi - 79))))
        let index0: Float = (mallet ? 1.5 * fm : (0.4 + 1.3 * ctx.brightness) * velocity * fm) * keyScale
        // High drips a little quieter (about -1.5 dB per 2 semitones above C6).
        let now = ctx.time
        let together = Float(max(1, pool.lastUsed.filter { now - $0 < 0.3 }.count))
        let peak = 0.5 * velocity * Float(max(0.45, 1 - 0.035 * Double(max(0, midi - 84)))) / together.squareRoot()
            * ctx.shareAttack(layer: .drips, weight: 0.7)
        // Ramp envelope (D68): 8 ms attack, decay to 25 % (0.2 s mallet / 0.35 s blip), hold, release.
        let hold = mallet ? rng.range(0.03...0.08) : rng.range(0.05...0.15)
        let decay = mallet ? 0.2 : 0.35
        let release = mallet ? rng.range(0.5...1.0) : rng.range(0.8...1.8)
        let indexTime = mallet ? 0.15 : 0.7
        let isMallet = mallet
        ParamRamp.set(osc.$amplitude, 0, over: ParamRamp.minimum)
        after(0.025, ctx: ctx) { [weak self] in
            guard let self, self.pool.isCurrent(v, tok) else { return }
            ParamRamp.set(osc.$baseFrequency, Scale.midiToFrequency(midi), over: ParamRamp.minimum)
            ParamRamp.set(osc.$modulatingMultiplier, ratio, over: ParamRamp.minimum)
            // Strike transient (decision D85): +0.9 index for the first 60 ms.
            ParamRamp.set(osc.$modulationIndex, index0 + 0.9 * fm * keyScale, over: ParamRamp.minimum)
            self.after(0.022, ctx: ctx) { [weak self] in
                guard let self, self.pool.isCurrent(v, tok) else { return }
                ParamRamp.set(osc.$amplitude, peak, over: 0.008)
                ParamRamp.set(osc.$modulationIndex, index0, over: 0.06)
                self.after(0.06, ctx: ctx) { [weak self] in
                    guard let self, self.pool.isCurrent(v, tok) else { return }
                    ParamRamp.set(osc.$modulationIndex, isMallet ? 0 : 0.05, over: indexTime)
                }
                ctx.emit(.noteOn, layer: .drips, midi: midi, velocity: velocity)
                self.after(ParamRamp.nextTick, ctx: ctx) { [weak self] in
                    guard let self, self.pool.isCurrent(v, tok) else { return }
                    ParamRamp.set(osc.$amplitude, peak * 0.25, over: decay)
                }
                self.after(ParamRamp.nextTick + max(hold, decay), ctx: ctx) { [weak self] in
                    guard let self, self.pool.isCurrent(v, tok) else { return }
                    ParamRamp.set(osc.$amplitude, 0, over: release)
                }
            }
        }
    }

    /// Single accent at an image change midpoint (borrowed if the layer is not in the scene).
    func accent(ctx: LayerContext) {
        borrow(level: 0.8, attack: 0.2, ctx: ctx)
        after(0.25, ctx: ctx) { [weak self] in self?.play(velocity: 0.8, ctx: ctx) }
        after(3, ctx: ctx) { [weak self] in self?.releaseBorrow(over: 4, ctx: ctx) }
    }

    override func update(dt: Double, ctx: LayerContext) {
        strip.setSends(reverb: 0.7, delay: 0.6 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        for o in oscs { ParamRamp.set(o.$amplitude, 0, over: max(0.05, fade)) }
    }
}
