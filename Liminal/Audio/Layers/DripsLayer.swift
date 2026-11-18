import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Soft motes (decision D95; was the FM "drips" of D16, D84, D85, D89, which the user heard as "super high
/// pitched tinks"). A four-voice round-robin pool of near-sine FM voices (ratio 1, index at most 0.15, so a
/// trace of second harmonic) in C4-G5, swelling in over 120-350 ms and dying away over 2.5-5 s, low-passed at
/// 1.4-2.2 kHz and sent mostly to the reverb: small lights far away rather than struck glass. One or two notes
/// every 9-20 s. Each note still fires `.noteOn` for `.drips`, which the facade forwards to `shimmerNotePlayed`.
nonisolated final class DripsLayer: BaseLayer {
    static let poolSize = 4
    static let loopBounds: ClosedRange<Double> = 9...20

    static let voicePans: [Float] = [-0.8, -0.3, 0.3, 0.8]
    private let oscs: [FMOscillator]
    private let filter: LowPassButterworthFilter
    private var pool = VoicePool(DripsLayer.poolSize)
    private var loop: LoopClock
    private var chain = MarkovChain.highShimmer(degreeCount: 7)

    init() {
        oscs = (0..<DripsLayer.poolSize).map { _ in
            FMOscillator(waveform: Table(.sine), baseFrequency: 440, carrierMultiplier: 1,
                         modulatingMultiplier: 1, modulationIndex: 0, amplitude: 0)
        }
        // Fixed per-voice pans via Mixer.pan; a note picks the voice nearest its random pan (D68).
        let o = oscs
        let mix = Mixer((0..<DripsLayer.poolSize).map { i -> Mixer in
            let m = Mixer(o[i]); m.pan = DripsLayer.voicePans[i]; return m
        })
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 1800)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-22) * 1.414 / 0.5,
                               reverb: 1.0, delay: 0.5, dry: 0.3)
        var tmp = MusicRNG(seed: 0)
        loop = LoopClock(bounds: DripsLayer.loopBounds, rng: &tmp)
        super.init(id: .drips, strip: strip, entryThreshold: 0.35)
        generators = oscs
    }

    override func prepare(rng: MusicRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: DripsLayer.loopBounds, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(3...9), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: DripsLayer.loopBounds, rng: &rng)
    }

    override func harmonyDidChange(_ change: HarmonyChange, ctx: LayerContext) {
        if case .key(let old, let new) = change, old.degreeCount != new.degreeCount {
            chain = MarkovChain.highShimmer(degreeCount: new.degreeCount)
        }
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.3 - 0.6 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        if rng.chance(0.2 - 0.1 * ctx.density) { return }   // occasional empty cycle
        let count = 1 + rng.weighted([0.7, 0.3])
        var t = 0.0
        for i in 0..<count {
            let vel = rng.rangeF(0.55...0.9) * (i == 0 ? 1 : 0.8)
            after(t, ctx: ctx) { [weak self] in self?.play(velocity: vel, ctx: ctx) }
            t += rng.range(0.9...2.5)
        }
    }

    private func play(velocity: Float, ctx: LayerContext) {
        let f = ctx.field
        if chain.count != f.degreeCount { chain = MarkovChain.highShimmer(degreeCount: f.degreeCount) }
        let degree = chain.next(using: &rng)
        // C4-G5, the register window moving at most -3...+2 semitones with the scene.
        let lo = 60 + max(-3, min(2, ctx.registerShift)), hi = lo + 19
        var midi = f.midi(degree: degree, octave: 4 + (rng.chance(0.4) ? 1 : 0))
        while midi > hi { midi -= 12 }
        while midi < lo { midi += 12 }
        if rng.chance(0.65) || !f.inScale(midi) { midi = f.nearest(to: midi, chordTonesOnly: true) }
        if midi > hi { midi -= 12 }
        let want = rng.rangeF(-0.8...0.8)
        let nearest = (0..<DripsLayer.poolSize).sorted { abs(DripsLayer.voicePans[$0] - want) < abs(DripsLayer.voicePans[$1] - want) }
        let (v, tok) = pool.take(preferring: Array(nearest.prefix(2)), now: ctx.time, minAge: 3)
        let osc = oscs[v]
        // A trace of FM colour at most (index 0.15 at ratio 1 = a faint second harmonic), less in dark scenes.
        let index = min(0.15, (0.04 + 0.12 * ctx.brightness) * ctx.coupling.fmScale)
        // Higher motes a little quieter (about -1 dB per 3 semitones above G4).
        let tilt = Float(max(0.6, 1 - 0.035 * Double(max(0, midi - 67))))
        let peak = 0.5 * velocity * tilt * ctx.shareAttack(layer: .drips, weight: 0.5)
        let attack = rng.range(0.28...0.55)
        let decay = rng.range(2.5...5)
        ParamRamp.set(osc.$amplitude, 0, over: 0.08)
        after(0.1, ctx: ctx) { [weak self] in
            guard let self, self.pool.isCurrent(v, tok) else { return }
            ParamRamp.set(osc.$baseFrequency, Scale.midiToFrequency(midi), over: ParamRamp.minimum)
            ParamRamp.set(osc.$modulationIndex, index, over: ParamRamp.minimum)
            ParamRamp.set(osc.$amplitude, peak, over: attack)
            ctx.emit(.noteOn, layer: .drips, midi: midi, velocity: velocity)
            // Two-segment, roughly exponential fall: to 35 % over the first third, then to silence.
            self.after(max(attack, ParamRamp.nextTick), ctx: ctx) { [weak self] in
                guard let self, self.pool.isCurrent(v, tok) else { return }
                ParamRamp.set(osc.$amplitude, peak * 0.35, over: decay * 0.35)
                ParamRamp.set(osc.$modulationIndex, 0, over: decay * 0.5)
                self.after(decay * 0.35, ctx: ctx) { [weak self] in
                    guard let self, self.pool.isCurrent(v, tok) else { return }
                    ParamRamp.set(osc.$amplitude, 0, over: decay * 0.65)
                }
            }
        }
    }

    /// Single accent at an image change midpoint (borrowed if the layer is not in the scene).
    func accent(ctx: LayerContext) {
        borrow(level: 0.7, attack: 1, ctx: ctx)
        after(0.5, ctx: ctx) { [weak self] in self?.play(velocity: 0.45, ctx: ctx) }
        after(5, ctx: ctx) { [weak self] in self?.releaseBorrow(over: 6, ctx: ctx) }
    }

    override func update(dt: Double, ctx: LayerContext) {
        ParamRamp.set(filter.$cutoffFrequency, expMap(ctx.brightness, 1000, 1800), over: 0.12)
        strip.setSends(reverb: 1.0, delay: 0.5 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        for o in oscs { ParamRamp.set(o.$amplitude, 0, over: max(0.05, fade)) }
    }
}
