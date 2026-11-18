import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Soft harp (decision D97; was the Karplus-Strong pluck and ostinato of D62, D84, which carried half of the
/// "tinks"). Three voices, each an `Oscillator` on a soft table (mostly fundamental with a little second and
/// third harmonic), with ramp envelopes: a 160-320 ms swell and a 2.5-4 s fall. Phrases of 2-4 chord tones
/// in C3-C5, 0.8-1.8 s apart, every 20-45 s. Low-passed at 0.6-1.45 kHz and sent mostly to the reverb and delay.
nonisolated final class PluckLayer: BaseLayer {
    static let poolSize = 3
    static let loopBounds: ClosedRange<Double> = 20...45
    static let table: Table = PadTables.additive([(1, 1), (2, 0.16), (3, 0.045)])
    private let oscs: [Oscillator]
    private let filter: LowPassButterworthFilter
    private var loop: LoopClock
    private var pool = VoicePool(PluckLayer.poolSize)
    private let amp: Float = 0.5

    init() {
        oscs = (0..<PluckLayer.poolSize).map { _ in Oscillator(waveform: PluckLayer.table, frequency: 220, amplitude: 0) }
        let mix = Mixer(oscs)
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 1200)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-19) * 1.414 / 0.5,
                               reverb: 0.8, delay: 0.5, dry: 0.25)
        var tmp = MusicRNG(seed: 0)
        loop = LoopClock(bounds: PluckLayer.loopBounds, rng: &tmp)
        super.init(id: .pluck, strip: strip, entryThreshold: 0.5)
        generators = oscs
    }

    override func prepare(rng: MusicRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: PluckLayer.loopBounds, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(4...12), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: PluckLayer.loopBounds, rng: &rng)
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.3 - 0.6 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        if rng.chance(0.12 - 0.06 * ctx.density) { return }
        phrase(ctx: ctx)
    }

    private func phrase(ctx: LayerContext) {
        let s = max(-4, min(3, ctx.registerShift))
        let tones = ctx.field.chordTones(in: (48 + s)...(72 + s))
        guard tones.count >= 2 else { return }
        let n = min(rng.int(2...4), tones.count)
        let start = rng.int(0...(tones.count - n))
        var notes = Array(tones[start..<(start + n)])
        if rng.chance(0.45) { notes.reverse() }
        strip.setPan(rng.rangeF(-0.5...0.5), over: 2)
        var t = 0.0
        for (k, m) in notes.enumerated() {
            let vel = rng.rangeF(0.5...0.75) * (k == 0 ? 1 : 0.9)
            after(t, ctx: ctx) { [weak self] in self?.pluck(m, velocity: vel, ctx: ctx) }
            t += rng.range(0.8...1.8)
        }
    }

    private func pluck(_ midi: Int, velocity: Float, ctx: LayerContext) {
        let (v, tok) = pool.take(now: ctx.time)
        let osc = oscs[v]
        let tilt = Float(max(0.6, 1 - 0.02 * Double(max(0, midi - 60))))
        let peak = amp * velocity * tilt * ctx.shareAttack(layer: .pluck)
        let attack = rng.range(0.16...0.32)
        let decay = rng.range(2.5...4)
        ParamRamp.set(osc.$amplitude, 0, over: 0.08)
        after(0.1, ctx: ctx) { [weak self] in
            guard let self, self.pool.isCurrent(v, tok) else { return }
            ParamRamp.set(osc.$frequency, Scale.midiToFrequency(midi), over: ParamRamp.minimum)
            ParamRamp.set(osc.$amplitude, peak, over: attack)
            ctx.emit(.noteOn, layer: .pluck, midi: midi, velocity: velocity)
            self.after(max(attack, ParamRamp.nextTick), ctx: ctx) { [weak self] in
                guard let self, self.pool.isCurrent(v, tok) else { return }
                ParamRamp.set(osc.$amplitude, peak * 0.3, over: decay * 0.3)
                self.after(decay * 0.3, ctx: ctx) { [weak self] in
                    guard let self, self.pool.isCurrent(v, tok) else { return }
                    ParamRamp.set(osc.$amplitude, 0, over: decay * 0.7)
                }
            }
        }
    }

    override func update(dt: Double, ctx: LayerContext) {
        ParamRamp.set(filter.$cutoffFrequency, expMap(ctx.brightness, 600, 1450), over: 0.12)
        strip.setSends(reverb: 0.8, delay: 0.5 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        for o in oscs { ParamRamp.set(o.$amplitude, 0, over: max(0.05, fade)) }
    }
}
