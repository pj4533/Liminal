import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Air (plan section 7, decisions D60, D83): white noise through two cascaded band-passes whose centre sweeps 450 Hz-6.5 kHz
/// over 20-60 s. (The plan's Brownian rumble was dropped: panned with the air walk it decorrelated the
/// sub-120 Hz band below the 0.9 gate, and the drone already owns that register.) Level breathes on a slow
/// channel and the layer walks across the stereo field (+-0.7). Also the voice of image transitions and
/// of the air-swell rare event: a riser that opens the filter upward and then drops into the reverb.
nonisolated final class AirLayer: BaseLayer {
    private let pink: WhiteNoise
    private let band: BandPassButterworthFilter
    private let band2: BandPassButterworthFilter
    private var sweep = ParameterDrift.Channel(period: 40, phase: 0)
    private var width = ParameterDrift.Channel(period: 30, phase: 0)
    private var breath = ParameterDrift.Channel(period: 37, phase: 0)
    private var panWalk = ParameterDrift.Channel(period: 45, phase: 0)
    /// 0...1 riser amount (image transitions, air swell).
    private var riser = SoftEnv(0)
    private var riserReverb = SoftEnv(0)

    init() {
        // White noise and two cascaded band-passes (decision D83). Pink noise through one 2nd-order band-pass
        // leaked half its power below 120 Hz (solo render: 50 % under 120 Hz, 5 % above 2 kHz), so the "air"
        // was mostly rumble; white noise through one band-pass has a -6 dB/oct tail to 20 kHz that read as
        // hiss and pushed the spectral centroid to 3-4 kHz. The cascade gives -12 dB/oct on both sides.
        pink = WhiteNoise(amplitude: 0)
        band = BandPassButterworthFilter(pink, centerFrequency: 1200, bandwidth: 800)
        band2 = BandPassButterworthFilter(band, centerFrequency: 1200, bandwidth: 800)
        let strip = LayerStrip(source: band2, trim: dbToGain(-19) * 1.414, reverb: 0.4, delay: 0)
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

    /// Scene colour 0...1 (decision D86): where in the 450 Hz-6.5 kHz range this scene's air sits. Tide is a
    /// low wind, constellation a high hiss. The sweep moves around it instead of covering the whole range in
    /// every scene, so sections differ in their top-end colour, not just in which notes play.
    private var colour = SoftEnv(0.5)

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        reroll()
        let r: ClosedRange<Float> = {
            switch scene.kind {
            case .tide: return 0.0...0.35
            case .stillness: return 0.15...0.55
            case .drift: return 0.15...0.85
            case .bloom: return 0.45...0.85
            case .constellation: return 0.55...0.9
            }
        }()
        colour.go(to: rng.rangeF(r), over: rng.range(15...30), now: ctx.time)
    }

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
        let c = colour.tick(t)
        let pos = min(max(0.35 * (sweep.unit(at: t) - 0.5) + c + 0.15 * (ctx.brightness - 0.5) + 0.5 * r, 0), 1)
        let center = expMap(pos, 450, 6500)
        let bw = center * (0.3 + 0.5 * width.unit(at: t))
        ParamRamp.set(band.$centerFrequency, center, over: 0.12)
        ParamRamp.set(band.$bandwidth, bw, over: 0.12)
        ParamRamp.set(band2.$centerFrequency, center, over: 0.12)
        ParamRamp.set(band2.$bandwidth, bw * 1.3, over: 0.12)
        // Gusts (decision D86): the breath channel takes the air from almost nothing to full, so it comes and
        // goes inside a scene. With a 0.55-1 range it was a constant hiss that gave every 10 s window the same
        // top octave (5-10 kHz shape correlation 0.81 on seed 22).
        let b = 0.04 + 0.96 * powf(breath.unit(at: t), 1.6)
        // Bandwidth-normalised so narrow bands are not much quieter than wide ones.
        let norm = min(2.2, sqrtf(1500 / max(bw, 150)))
        // High bands quieter (-5 dB at the top): white noise at 5 kHz reads much louder than at 500 Hz, and a
        // high air scene otherwise dominated the spectral centroid (D86).
        let tiltHigh = 1 - 0.45 * pos
        ParamRamp.set(pink.$amplitude, min(1, 0.5 * b * norm * tiltHigh * (1 + 1.6 * r)), over: 0.12)
        strip.setPan(0.7 * panWalk.value(at: t) * (1 - r), over: 0.12)
        strip.setSends(reverb: 0.4 + 0.5 * rv, delay: 0, over: 0.12)
    }
}
