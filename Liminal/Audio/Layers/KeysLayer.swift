import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Keys / bells (plan section 7, decisions D17, D59, D68). Six FM voices in three fixed pan groups
/// (-0.6, 0, +0.6, two voices each, panned by `Mixer.pan`), envelopes as amplitude ramps (a fast attack
/// then a three-segment approximately exponential decay). Presets are chosen per scene (style-weighted): soft keys (1:1), bell (1:3.5),
/// glass (1:7). The FM index decays over each note (the timbre morphs from bright attack to a pure
/// tail) and scales with brightness and image saturation. Plays single notes, dyads and rolled
/// three-note chords, short phrases and slow arpeggios from chord tones on a drifting 4-9 s loop (plan: 19-41 s, decisions
/// D59, D84); also voices the arpeggio cascade and
/// bell toll rare events.
nonisolated final class KeysLayer: BaseLayer {
    enum Preset: Int, CaseIterable { case soft, bell, glass }

    static let poolSize = 6
    static let groupPans: [Float] = [-0.6, 0, 0.6]
    private let oscs: [FMOscillator]
    private let filter: LowPassButterworthFilter
    private var loop: LoopClock
    private var preset: Preset = .soft
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
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 4000)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-14) * 1.414 / 0.5,
                               reverb: 0.6, delay: 0.35)
        var tmp = SeededRNG(seed: 0)
        loop = LoopClock(bounds: 4...9, rng: &tmp)
        super.init(id: .keys, strip: strip, entryThreshold: 0.4)
        generators = oscs
    }

    override func prepare(rng: SeededRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: 4...9, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(3...9), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: 4...9, rng: &rng)
        var w = ctx.style.keysPresets
        if scene.kind == .constellation { w[Preset.glass.rawValue] *= 1.5 }
        if scene.kind == .stillness || scene.kind == .tide { w[Preset.bell.rawValue] *= 1.4 }
        preset = Preset(rawValue: rng.weighted(w)) ?? .soft
    }

    private func range(_ ctx: LayerContext) -> ClosedRange<Int> {
        let s = max(-4, min(6, ctx.registerShift))
        return (57 + s)...(84 + s)
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.4 - 0.8 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        if rng.chance(0.14 - 0.08 * ctx.density) { return }
        let tones = ctx.field.chordTones(in: range(ctx))
        guard !tones.isEmpty else { return }
        let figure = rng.weighted([0.22, 0.18, 0.2 + 0.2 * ctx.intensity, 0.25 + 0.25 * ctx.density,
                                    0.15 + 0.25 * ctx.intensity])
        let pan = rng.rangeF(-0.6...0.6)
        switch figure {
        case 0:
            play(rng.pick(tones), velocity: rng.rangeF(0.55...0.95), pan: pan, preset: preset, ctx: ctx)
            // Sometimes an echo of the same note a few seconds later, softer, on the other side.
            if rng.chance(0.3) {
                let m = rng.pick(tones)
                after(rng.range(2...5), ctx: ctx) { [weak self] in
                    guard let self else { return }
                    self.play(m, velocity: self.rng.rangeF(0.35...0.6), pan: -pan, preset: self.preset, ctx: ctx)
                }
            }
        case 1:
            let i = rng.int(0...(tones.count - 1))
            let j = min(tones.count - 1, i + rng.int(1...2))
            // Both notes start in the same tick, so the first is not covered by the headroom sharing in
            // `play`; the dyad is pre-scaled by -3 dB instead (a dyad peaked the bypassed mix at -1.7 dBFS).
            play(tones[i], velocity: 0.71 * rng.rangeF(0.5...0.85), pan: pan - 0.15, preset: preset, ctx: ctx)
            play(tones[j], velocity: 0.71 * rng.rangeF(0.45...0.8), pan: pan + 0.15, preset: preset, ctx: ctx)
        case 3:
            // Short phrase: 3-5 neighbouring chord tones, unhurried.
            let n = min(rng.int(3...5), tones.count)
            var i = rng.int(0...(tones.count - 1))
            var t = 0.0
            for k in 0..<n {
                let m = tones[i]
                let vel = rng.rangeF(0.45...0.85) * (k == 0 ? 1 : 0.9)
                let p = min(max(pan + rng.rangeF(-0.3...0.3), -0.7), 0.7)
                after(t, ctx: ctx) { [weak self] in
                    guard let self else { return }
                    self.play(m, velocity: vel, pan: p, preset: self.preset, ctx: ctx)
                }
                t += rng.range(0.45...1.4)
                i = min(max(i + (rng.chance(0.5) ? 1 : -1) * rng.int(1...2), 0), tones.count - 1)
            }
        case 4:
            // Slow arpeggio (decision D84): 6-12 notes walking up and back down the chord, 0.25-0.5 s apart,
            // with a soft swell; the "music box" figure that keeps busier scenes animated.
            let n = rng.int(6...12)
            let step = rng.range(0.25...0.5)
            var i = rng.int(0...max(0, tones.count / 2))
            var dir = 1
            var t = 0.0
            for k in 0..<n {
                let m = tones[i]
                let arc = 0.6 + 0.4 * Float(sin(Double.pi * Double(k + 1) / Double(n + 1)))
                let vel = rng.rangeF(0.5...0.75) * arc
                let p = min(max(pan + 0.5 * (Float(k) / Float(n) - 0.5), -0.7), 0.7)
                after(t, ctx: ctx) { [weak self] in
                    guard let self else { return }
                    self.play(m, velocity: vel, pan: p, preset: self.preset, ctx: ctx)
                }
                t += step * rng.range(0.92...1.08)
                if i + dir < 0 || i + dir >= tones.count { dir = -dir }
                i = min(max(i + dir, 0), tones.count - 1)
            }
        default:
            let start = rng.int(0...max(0, tones.count - 3))
            let up = rng.chance(0.7)
            var t = 0.0
            for k in 0..<min(3, tones.count) {
                let m = tones[up ? start + k : start + 2 - k]
                let vel = rng.rangeF(0.5...0.85) * (1 - 0.1 * Float(k))
                let p = pan + Float(k - 1) * 0.2
                after(t, ctx: ctx) { [weak self] in
                    guard let self else { return }
                    self.play(m, velocity: vel, pan: p, preset: self.preset, ctx: ctx)
                }
                t += rng.range(0.06...0.18)
            }
        }
    }

    /// One FM note. Index envelope: start value decays to the preset floor over the preset time.
    /// Amplitude: attack ramp, then three ramps (to 45 %, 15 %, 0) approximating an exponential decay.
    func play(_ midi: Int, velocity: Float, pan: Float, preset: Preset, ctx: LayerContext) {
        let g = pan < -0.2 ? 0 : (pan > 0.2 ? 2 : 1)
        let (v, tok) = pool.take(preferring: [g, g + 3], now: ctx.time, minAge: 1.5)
        let osc = oscs[v]
        let fm = ctx.coupling.fmScale * (0.75 + 0.5 * ctx.brightness)
        let (ratio, idx0, idx1, idxTime, decay, attack): (Float, Float, Float, Double, Double, Double) = {
            switch preset {
            case .soft: return (1, 2, 0.2, 1.5, rng.range(2.5...4), 0.012)
            case .bell: return (3.5, 3, 0.5, 2.2, rng.range(4...6), 0.004)
            case .glass: return (7, 0.8, 0.15, 1.0, rng.range(2.2...3.5), 0.003)
            }
        }()
        // Higher notes a little quieter (keeps the top from getting piercing).
        let tilt = Float(1 - 0.015 * Double(max(0, midi - 72)))
        // Notes starting together (dyads, rolled chords, overlapping figures) share the headroom: each is scaled
        // by 1/sqrt(notes started in the last 0.5 s), so stacked attacks stay under the bypass peak gate (D84).
        let now = ctx.time
        let together = max(1, pool.lastUsed.filter { now - $0 < 0.5 }.count)
        let peak = amp * velocity * tilt / Float(together).squareRoot() * ctx.shareAttack(layer: .keys)
        // If the voice is still ringing, duck it before retuning.
        ParamRamp.set(osc.$amplitude, 0, over: ParamRamp.minimum)
        after(0.025, ctx: ctx) { [weak self] in
            guard let self, self.pool.isCurrent(v, tok) else { return }
            ParamRamp.set(osc.$baseFrequency, Scale.midiToFrequency(midi), over: ParamRamp.minimum)
            ParamRamp.set(osc.$modulatingMultiplier, ratio, over: ParamRamp.minimum)
            // Hammer transient (decision D85): the index starts above its attack value and falls back within
            // 0.12 s, so every note opens with a short burst of partials. Without it most notes rose by only
            // 4-5 MADs of spectral flux in the full mix and the onset detector missed them.
            let i0 = idx0 * fm * (0.6 + 0.4 * velocity)
            let hammer: Float = preset == .soft ? 1.9 : (preset == .bell ? 1.4 : 1.6)
            ParamRamp.set(osc.$modulationIndex, i0 * hammer, over: ParamRamp.minimum)
            self.after(0.022, ctx: ctx) { [weak self] in
                guard let self, self.pool.isCurrent(v, tok) else { return }
                ParamRamp.set(osc.$amplitude, peak, over: attack)
                ParamRamp.set(osc.$modulationIndex, i0, over: 0.12)
                self.after(0.12, ctx: ctx) { [weak self] in
                    guard let self, self.pool.isCurrent(v, tok) else { return }
                    ParamRamp.set(osc.$modulationIndex, idx1 * fm, over: idxTime)
                }
                ctx.emit(.noteOn, layer: .keys, midi: midi, velocity: velocity)
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
    }

    // MARK: Rare events and accents

    /// 10-16 notes up the chord, 140-280 ms apart, falling velocity. Returns the gesture length.
    @discardableResult
    func cascade(ctx: LayerContext) -> Double {
        let lo = 55 + max(-3, min(4, ctx.registerShift))
        let tones = ctx.field.chordTones(in: lo...(lo + 44))
        guard tones.count >= 3 else { return 0 }
        borrow(level: 0.85, attack: 0.5, ctx: ctx)
        let n = min(rng.int(10...16), tones.count)
        let gap = rng.range(0.14...0.28)
        let p: Preset = rng.chance(0.5) ? .glass : preset
        var t = 0.3
        let startPan = rng.rangeF(-0.6...(-0.2)) * (rng.chance(0.5) ? 1 : -1)
        for k in 0..<n {
            let m = tones[k]
            let vel = 1.0 - 0.6 * Float(k) / Float(n)
            let pan = startPan + (-2 * startPan) * Float(k) / Float(max(1, n - 1))
            after(t, ctx: ctx) { [weak self] in self?.play(m, velocity: vel, pan: pan, preset: p, ctx: ctx) }
            t += gap * rng.range(0.85...1.15)
        }
        after(t + 3, ctx: ctx) { [weak self] in
            guard let self else { return }
            self.releaseBorrow(over: 6, ctx: ctx)
        }
        return t + 6
    }

    /// Three low bells, 4-6 s apart, on the chord root and fifth.
    @discardableResult
    func toll(ctx: LayerContext) -> Double {
        let f = ctx.field
        let root = f.nearest(to: 48 + f.chordRootPitchClass, chordTonesOnly: true)
        let notes = [root, root, f.nearest(to: root + 7, chordTonesOnly: true)]
        borrow(level: 0.8, attack: 0.5, ctx: ctx)
        var t = 0.3
        for (k, m) in notes.enumerated() {
            let vel: Float = [0.95, 0.8, 0.7][k]
            let pan: Float = [-0.3, 0.3, 0][k]
            after(t, ctx: ctx) { [weak self] in self?.play(m, velocity: vel, pan: pan, preset: .bell, ctx: ctx) }
            t += rng.range(4...6)
        }
        after(t + 2, ctx: ctx) { [weak self] in self?.releaseBorrow(over: 8, ctx: ctx) }
        return t + 8
    }

    /// Single accent at an image change midpoint.
    func accent(ctx: LayerContext) {
        let tones = ctx.field.chordTones(in: range(ctx))
        guard !tones.isEmpty else { return }
        borrow(level: 0.7, attack: 0.2, ctx: ctx)
        let m = rng.pick(tones)
        after(0.25, ctx: ctx) { [weak self] in
            guard let self else { return }
            self.play(m, velocity: 0.7, pan: self.rng.rangeF(-0.5...0.5), preset: self.preset, ctx: ctx)
        }
        after(4, ctx: ctx) { [weak self] in self?.releaseBorrow(over: 5, ctx: ctx) }
    }

    override func update(dt: Double, ctx: LayerContext) {
        ParamRamp.set(filter.$cutoffFrequency, expMap(ctx.brightness, 1500, 7000), over: 0.12)
        strip.setSends(reverb: 0.6, delay: 0.35 * ctx.delayScale, over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        for o in oscs { ParamRamp.set(o.$amplitude, 0, over: max(0.05, fade)) }
    }
}
