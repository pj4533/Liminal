import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Felt keys (decision D96; were the FM keys and bells of D17, D59, D68, D84, D85, which the user heard as
/// "the bell"). Six FM voices in three fixed pan groups (-0.6, 0, +0.6, two voices each, panned by
/// `Mixer.pan`), envelopes as amplitude ramps (an 80-140 ms swell, then a slow three-segment fall over 4-8 s).
/// Integer ratios only, the index never above 1, no hammer transient: presets felt (1:1), warm (1:2) and
/// hollow (1:3), chosen per scene (style-weighted). Low-passed at 0.9-2.6 kHz and mostly wet. Plays single
/// notes, dyads, slow rolls and 2-3 note phrases from chord tones in C3-E5, one figure every 14-30 s; also
/// voices the slow-fall and low-toll rare events.
nonisolated final class KeysLayer: BaseLayer {
    enum Preset: Int, CaseIterable { case felt, warm, hollow }

    static let poolSize = 6
    static let groupPans: [Float] = [-0.6, 0, 0.6]
    static let loopBounds: ClosedRange<Double> = 14...30
    private let oscs: [FMOscillator]
    private let filter: LowPassButterworthFilter
    private var loop: LoopClock
    private var preset: Preset = .felt
    private var pool = VoicePool(KeysLayer.poolSize)
    private let amp: Float = 0.5

    init() {
        oscs = (0..<KeysLayer.poolSize).map { _ in
            FMOscillator(waveform: Table(.sine), baseFrequency: 440, carrierMultiplier: 1,
                         modulatingMultiplier: 1, modulationIndex: 0, amplitude: 0)
        }
        let o = oscs
        let groups: [Mixer] = (0..<3).map { g in
            let m = Mixer(stride(from: g, to: KeysLayer.poolSize, by: 3).map { o[$0] })
            m.pan = KeysLayer.groupPans[g]
            return m
        }
        let mix = Mixer(groups)
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 1600)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-17) * 1.414 / 0.5,
                               reverb: 0.9, delay: 0.3, dry: 0.5)
        var tmp = MusicRNG(seed: 0)
        loop = LoopClock(bounds: KeysLayer.loopBounds, rng: &tmp)
        super.init(id: .keys, strip: strip, entryThreshold: 0.4)
        generators = oscs
    }

    override func prepare(rng: MusicRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: KeysLayer.loopBounds, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(4...12), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: KeysLayer.loopBounds, rng: &rng)
        var w = ctx.style.keysPresets
        if scene.kind == .constellation { w[Preset.hollow.rawValue] *= 1.4 }
        if scene.kind == .stillness || scene.kind == .tide { w[Preset.felt.rawValue] *= 1.4 }
        preset = Preset(rawValue: rng.weighted(w)) ?? .felt
    }

    private func range(_ ctx: LayerContext) -> ClosedRange<Int> {
        let s = max(-4, min(3, ctx.registerShift))
        return (48 + s)...(76 + s)
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.3 - 0.6 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        if rng.chance(0.15 - 0.08 * ctx.density) { return }
        let tones = ctx.field.chordTones(in: range(ctx))
        guard !tones.isEmpty else { return }
        // Single note, dyad, slow roll, short phrase.
        let figure = rng.weighted([0.34, 0.22, 0.22, 0.22])
        let pan = rng.rangeF(-0.6...0.6)
        switch figure {
        case 0:
            play(rng.pick(tones), velocity: rng.rangeF(0.45...0.7), pan: pan, preset: preset, ctx: ctx)
            // Sometimes an echo of another chord tone a few seconds later, softer, on the other side.
            if rng.chance(0.3) {
                let m = rng.pick(tones)
                after(rng.range(3...6), ctx: ctx) { [weak self] in
                    guard let self else { return }
                    self.play(m, velocity: self.rng.rangeF(0.35...0.5), pan: -pan, preset: self.preset, ctx: ctx)
                }
            }
        case 1:
            let i = rng.int(0...(tones.count - 1))
            let j = min(tones.count - 1, i + rng.int(1...2))
            // Both notes start in the same tick: pre-scaled by -3 dB (a dyad peaked the bypassed mix, D84).
            play(tones[i], velocity: 0.71 * rng.rangeF(0.5...0.7), pan: pan - 0.15, preset: preset, ctx: ctx)
            if j != i { play(tones[j], velocity: 0.71 * rng.rangeF(0.45...0.65), pan: pan + 0.15, preset: preset, ctx: ctx) }
        case 2:
            // Slow roll: three chord tones 250-500 ms apart, low to high (or high to low).
            let start = rng.int(0...max(0, tones.count - 3))
            let up = rng.chance(0.7)
            var t = 0.0
            for k in 0..<min(3, tones.count) {
                let m = tones[up ? start + k : start + min(2, tones.count - 1) - k]
                let vel = rng.rangeF(0.45...0.65) * (1 - 0.1 * Float(k))
                let p = pan + Float(k - 1) * 0.2
                after(t, ctx: ctx) { [weak self] in
                    guard let self else { return }
                    self.play(m, velocity: vel, pan: p, preset: self.preset, ctx: ctx)
                }
                t += rng.range(0.25...0.5)
            }
        default:
            // Short phrase: 2-3 neighbouring chord tones, 1.2-3 s apart.
            let n = min(rng.int(2...3), tones.count)
            var i = rng.int(0...(tones.count - 1))
            var t = 0.0
            for k in 0..<n {
                let m = tones[i]
                let vel = rng.rangeF(0.4...0.65) * (k == 0 ? 1 : 0.9)
                let p = min(max(pan + rng.rangeF(-0.3...0.3), -0.7), 0.7)
                after(t, ctx: ctx) { [weak self] in
                    guard let self else { return }
                    self.play(m, velocity: vel, pan: p, preset: self.preset, ctx: ctx)
                }
                t += rng.range(1.2...3)
                i = min(max(i + (rng.chance(0.5) ? 1 : -1) * rng.int(1...2), 0), tones.count - 1)
            }
        }
    }

    /// One FM note. Index envelope: start value (at most 1) decays to the preset floor over the preset time.
    /// Amplitude: a soft swell, then three ramps (to 45 %, 15 %, 0) approximating an exponential decay.
    func play(_ midi: Int, velocity: Float, pan: Float, preset: Preset, ctx: LayerContext) {
        let g = pan < -0.2 ? 0 : (pan > 0.2 ? 2 : 1)
        let (v, tok) = pool.take(preferring: [g, g + 3], now: ctx.time, minAge: 3)
        let osc = oscs[v]
        let fm = ctx.coupling.fmScale * (0.8 + 0.4 * ctx.brightness)
        let (ratio, idx0, idx1, idxTime, decay, attack): (Float, Float, Float, Double, Double, Double) = {
            switch preset {
            case .felt: return (1, 0.9, 0.1, 1.2, rng.range(4...7), 0.08)
            case .warm: return (2, 0.5, 0.05, 1.5, rng.range(5...8), 0.12)
            case .hollow: return (3, 0.25, 0, 1.5, rng.range(4...7), 0.14)
            }
        }()
        // Higher notes quieter (keeps the top soft).
        let tilt = Float(max(0.55, 1 - 0.02 * Double(max(0, midi - 64))))
        // Notes starting together share the headroom: each is scaled by 1/sqrt(notes started in the last 0.5 s) (D84).
        let now = ctx.time
        let together = max(1, pool.lastUsed.filter { now - $0 < 0.5 }.count)
        let vel = min(velocity, 0.7)
        let peak = amp * vel * tilt / Float(together).squareRoot() * ctx.shareAttack(layer: .keys)
        // If the voice is still ringing, let it go over 80 ms before retuning.
        ParamRamp.set(osc.$amplitude, 0, over: 0.08)
        after(0.1, ctx: ctx) { [weak self] in
            guard let self, self.pool.isCurrent(v, tok) else { return }
            ParamRamp.set(osc.$baseFrequency, Scale.midiToFrequency(midi), over: ParamRamp.minimum)
            ParamRamp.set(osc.$modulatingMultiplier, ratio, over: ParamRamp.minimum)
            let i0 = min(1, idx0 * fm * (0.7 + 0.3 * vel))
            ParamRamp.set(osc.$modulationIndex, i0, over: ParamRamp.minimum)
            ParamRamp.set(osc.$amplitude, peak, over: attack)
            ctx.emit(.noteOn, layer: .keys, midi: midi, velocity: vel)
            self.after(max(attack, ParamRamp.nextTick), ctx: ctx) { [weak self] in
                guard let self, self.pool.isCurrent(v, tok) else { return }
                ParamRamp.set(osc.$modulationIndex, idx1 * fm, over: idxTime)
            }
            let segs: [(Float, Double)] = [(0.45, 0.16), (0.15, 0.3), (0, 0.54)]
            var t = max(attack, ParamRamp.nextTick)
            for (level, frac) in segs {
                let dur = decay * frac
                self.after(t, ctx: ctx) { [weak self] in
                    guard let self, self.pool.isCurrent(v, tok) else { return }
                    ParamRamp.set(osc.$amplitude, peak * level, over: dur)
                }
                t += dur
            }
        }
    }

    // MARK: Rare events and accents

    /// Slow fall (D102, was the 10-16 note arpeggio cascade): 4-6 felt notes down the chord, 0.9-1.6 s apart,
    /// velocity at most 0.6. Returns the gesture length.
    @discardableResult
    func cascade(ctx: LayerContext) -> Double {
        let lo = 50 + max(-3, min(3, ctx.registerShift))
        let tones = ctx.field.chordTones(in: lo...(lo + 26))
        guard tones.count >= 3 else { return 0 }
        borrow(level: 0.75, attack: 2, ctx: ctx)
        let n = min(rng.int(4...6), tones.count)
        var t = 0.8
        let startPan = rng.rangeF(-0.5...(-0.2)) * (rng.chance(0.5) ? 1 : -1)
        for k in 0..<n {
            let m = tones[tones.count - 1 - k]
            let vel = 0.6 - 0.25 * Float(k) / Float(n)
            let pan = startPan + (-2 * startPan) * Float(k) / Float(max(1, n - 1))
            after(t, ctx: ctx) { [weak self] in self?.play(m, velocity: vel, pan: pan, preset: .felt, ctx: ctx) }
            t += rng.range(0.9...1.6)
        }
        after(t + 4, ctx: ctx) { [weak self] in
            guard let self else { return }
            self.releaseBorrow(over: 8, ctx: ctx)
        }
        return t + 8
    }

    /// Three low warm notes (D102, was the bell toll), 4-6 s apart, on the chord root and fifth.
    @discardableResult
    func toll(ctx: LayerContext) -> Double {
        let f = ctx.field
        let root = f.nearest(to: 48 + f.chordRootPitchClass, chordTonesOnly: true)
        let notes = [root, root, f.nearest(to: root + 7, chordTonesOnly: true)]
        borrow(level: 0.75, attack: 2, ctx: ctx)
        var t = 0.8
        for (k, m) in notes.enumerated() {
            let vel: Float = [0.6, 0.5, 0.45][k]
            let pan: Float = [-0.3, 0.3, 0][k]
            after(t, ctx: ctx) { [weak self] in self?.play(m, velocity: vel, pan: pan, preset: .warm, ctx: ctx) }
            t += rng.range(4...6)
        }
        after(t + 3, ctx: ctx) { [weak self] in self?.releaseBorrow(over: 8, ctx: ctx) }
        return t + 8
    }

    /// Single accent at an image change midpoint.
    func accent(ctx: LayerContext) {
        let tones = ctx.field.chordTones(in: range(ctx))
        guard !tones.isEmpty else { return }
        borrow(level: 0.7, attack: 1, ctx: ctx)
        let m = rng.pick(tones)
        after(0.5, ctx: ctx) { [weak self] in
            guard let self else { return }
            self.play(m, velocity: 0.45, pan: self.rng.rangeF(-0.5...0.5), preset: self.preset, ctx: ctx)
        }
        after(6, ctx: ctx) { [weak self] in self?.releaseBorrow(over: 6, ctx: ctx) }
    }

    override func update(dt: Double, ctx: LayerContext) {
        ParamRamp.set(filter.$cutoffFrequency, expMap(ctx.brightness, 900, 2600), over: 0.12)
        strip.setSends(reverb: 0.9, delay: 0.3 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        for o in oscs { ParamRamp.set(o.$amplitude, 0, over: max(0.05, fade)) }
    }
}
