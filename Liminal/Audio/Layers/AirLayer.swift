import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Air (plan section 7, decision D60): pink noise through a band-pass whose centre sweeps 300 Hz-5 kHz
/// over 20-60 s. (The plan's Brownian rumble was dropped: panned with the air walk it decorrelated the
/// sub-120 Hz band below the 0.9 gate, and the drone already owns that register.) Level breathes on a slow
/// channel and the layer walks across the stereo field (+-0.7). Also the voice of image transitions and
/// of the air-swell rare event: a riser that opens the filter upward and then drops into the reverb.
nonisolated final class AirLayer: BaseLayer {
    private let pink: PinkNoise
    private let band: BandPassButterworthFilter
    private var sweep = ParameterDrift.Channel(period: 40, phase: 0)
    private var width = ParameterDrift.Channel(period: 30, phase: 0)
    private var breath = ParameterDrift.Channel(period: 37, phase: 0)
    private var panWalk = ParameterDrift.Channel(period: 45, phase: 0)
    /// 0...1 riser amount (image transitions, air swell).
    private var riser = SoftEnv(0)
    private var riserReverb = SoftEnv(0)

    init() {
        pink = PinkNoise(amplitude: 0)
        band = BandPassButterworthFilter(pink, centerFrequency: 1200, bandwidth: 800)
        let strip = LayerStrip(source: band, trim: dbToGain(-7) * 1.414, reverb: 0.4, delay: 0)
        super.init(id: .air, strip: strip, entryThreshold: 0.2)
        generators = [pink]
    }

    override func prepare(rng: SeededRNG) {
        super.prepare(rng: rng)
        reroll()
        panWalk = ParameterDrift.Channel(period: self.rng.range(35...70), phase: self.rng.range(0...6))
    }

    private func reroll() {
        sweep = ParameterDrift.Channel(period: rng.range(20...60), phase: rng.range(0...6))
        width = ParameterDrift.Channel(period: rng.range(15...40), phase: rng.range(0...6))
        breath = ParameterDrift.Channel(period: rng.range(22...55), phase: rng.range(0...6))
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) { reroll() }

    /// Rise over `rise` seconds. `cut`: drop back sharply at the top so the reverb carries the tail
    /// (air-swell rare event); otherwise decay over `decay` seconds (image transitions).
    func swell(rise: Double, decay: Double, cut: Bool, ctx: LayerContext) {
        borrow(level: 0.8, attack: min(rise, 3), ctx: ctx)
        riser.go(to: 1, over: rise, now: ctx.time)
        riserReverb.go(to: cut ? 1 : 0.5, over: rise, now: ctx.time)
        after(rise, ctx: ctx) { [weak self] in
            guard let self else { return }
            let fall = cut ? 0.35 : decay
            self.riser.go(to: 0, over: fall, now: ctx.time)
            self.releaseBorrow(over: cut ? 0.35 : decay, ctx: ctx)
            self.after(cut ? 1.5 : decay, ctx: ctx) { [weak self] in
                guard let self else { return }
                self.riserReverb.go(to: 0, over: 6, now: ctx.time)
            }
        }
    }

    override func update(dt: Double, ctx: LayerContext) {
        let t = ctx.time
        let r = riser.tick(t)
        let rv = riserReverb.tick(t)
        let pos = min(max(0.75 * sweep.unit(at: t) + 0.25 * ctx.brightness + 0.5 * r, 0), 1)
        let center = expMap(pos, 300, 5000)
        let bw = center * (0.35 + 0.6 * width.unit(at: t))
        ParamRamp.set(band.$centerFrequency, center, over: 0.12)
        ParamRamp.set(band.$bandwidth, bw, over: 0.12)
        let b = 0.55 + 0.45 * breath.unit(at: t)
        // Bandwidth-normalised so narrow bands are not much quieter than wide ones.
        let norm = min(2.2, sqrtf(1500 / max(bw, 150)))
        ParamRamp.set(pink.$amplitude, min(1, 0.5 * b * norm * (1 + 1.6 * r)), over: 0.12)
        strip.setPan(0.7 * panWalk.value(at: t) * (1 - r), over: 0.12)
        strip.setSends(reverb: 0.4 + 0.5 * rv, delay: 0, over: 0.12)
    }
}
