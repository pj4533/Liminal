import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Six partials on the pedal: sub, two beating roots, fifth, octave and one roaming partial,
/// each breathing on its own golden-ratio LFO (section 7, decision D21).
nonisolated final class DroneLayer: BaseLayer {
    private enum P: Int, CaseIterable { case sub, rootA, rootB, fifth, octave, roam }

    private let oscs: [Oscillator]
    private let filter: LowPassButterworthFilter
    private var lfos: [ParameterDrift.Channel] = []
    private var beatLFO = ParameterDrift.Channel(period: 47, phase: 0)
    /// Base amplitude per partial (sum about 1; the strip trim sets the layer peak).
    private let base: [Float] = [0.22, 0.22, 0.22, 0.10, 0.08, 0.10]
    private var pedal: Int = 0                // MIDI currently sounding
    private var glide = SoftEnv(1)            // dip during pedal moves
    private var roamEnv = SoftEnv(0)
    private var roamOffset = 19               // semitones above pedal (3f)
    private var gliding = false
    /// Sub swell multiplier for the sub-pulse rare event (1 = none, +4 dB peak).
    private var subPulseEnv = SoftEnv(1)
    /// Scene weight of the drone (decision D86): it leads in stillness and tide and recedes under the busy
    /// scenes, so the pedal stops colouring every chord the same way and the bed changes between sections.
    private var sceneGain = SoftEnv(1)

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        let db: Float = {
            switch scene.kind {
            case .stillness: return 4
            case .tide: return 2.5
            case .drift: return -3
            case .bloom: return -6
            case .constellation: return -8
            }
        }()
        sceneGain.go(to: dbToGain(db), over: rng.range(18...30), now: ctx.time)
    }

    /// Rare event: the sub partial swells +4 dB over 6 s and back over 6 s.
    func subPulse(ctx: LayerContext) {
        subPulseEnv.go(to: dbToGain(4), over: 6, now: ctx.time)
        after(6.5, ctx: ctx) { [weak self] in
            guard let self else { return }
            self.subPulseEnv.go(to: 1, over: 6, now: ctx.time)
        }
    }

    init() {
        let soft = PadTables.softDrone
        oscs = P.allCases.map { p in
            let table = (p == .rootA || p == .rootB || p == .fifth) ? soft : Table(.sine)
            return Oscillator(waveform: table, frequency: 110, amplitude: 0)
        }
        let mix = Mixer(oscs)
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 500)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-29) * 1.414 / 0.45,
                               reverb: 0.25, delay: 0)
        super.init(id: .drone, strip: strip, entryThreshold: 0)
        generators = oscs
        motionDepth = 2
    }

    override func prepare(rng: MusicRNG) {
        super.prepare(rng: rng)
        lfos = ParameterDrift.channels(P.allCases.count, periods: 31...67, rng: &self.rng)
        beatLFO = ParameterDrift.Channel(period: self.rng.range(40...80), phase: self.rng.range(0...6))
    }

    override func didActivate(ctx: LayerContext) {
        if pedal == 0 { pedal = ctx.field.pedalMIDI; retune(over: ParamRamp.minimum, ctx: ctx) }
        ensureLoop { scheduleRoam(ctx: ctx, first: true) }
    }

    private func freq(_ p: P, pedal: Int, beat: Float) -> Float {
        let f0 = Scale.midiToFrequency(pedal)
        switch p {
        case .sub: return f0 / 2
        case .rootA: return f0
        case .rootB: return f0 + beat
        case .fifth: return Scale.midiToFrequency(pedal + fifthOffset)
        case .octave: return f0 * 2
        case .roam: return Scale.midiToFrequency(pedal + roamOffset)
        }
    }

    private var fifthOffset = 7

    private func retune(over: Double, ctx: LayerContext) {
        let f = ctx.field
        fifthOffset = f.inScale(pedal + 7) ? 7 : 12
        let beat = 0.05 + 0.25 * beatLFO.unit(at: ctx.time)
        for p in P.allCases {
            ParamRamp.set(oscs[p.rawValue].$frequency, freq(p, pedal: pedal, beat: beat), over: over)
        }
    }

    /// Every 30-70 s the roaming partial fades out, picks a new in-scale partial and fades back.
    private func scheduleRoam(ctx: LayerContext, first: Bool) {
        if first { roamEnv.go(to: 1, over: 8, now: ctx.time) }
        after(rng.range(30...70), ctx: ctx) { [weak self] in
            guard let self else { return }
            self.roamEnv.go(to: 0, over: 5, now: ctx.time)
            self.after(5.5, ctx: ctx) { [weak self] in
                guard let self else { return }
                let f = ctx.field
                let options = [19, 28, 14, 24, 26].filter { f.inScale(self.pedal + $0) }
                self.roamOffset = options.isEmpty ? 24 : self.rng.pick(options)
                ParamRamp.set(self.oscs[P.roam.rawValue].$frequency,
                              Scale.midiToFrequency(self.pedal + self.roamOffset), over: 0.05)
                self.roamEnv.go(to: 1, over: self.rng.range(6...12), now: ctx.time)
                self.scheduleRoam(ctx: ctx, first: false)
            }
        }
    }

    /// Pedal move: dip to 25 % over 2-3 s, glide over 1.5-3 s, swell back (5-10 s total). The dip is
    /// deeper and the glide shorter than PASS 1 because the pedal now also follows chord roots (D73).
    private func movePedal(to target: Int, ctx: LayerContext) {
        guard target != pedal, !gliding else { return }
        gliding = true
        let dip = rng.range(2...3), move = rng.range(1.5...3)
        glide.go(to: 0.25, over: dip, now: ctx.time)
        after(dip, ctx: ctx) { [weak self] in
            guard let self else { return }
            self.pedal = target
            self.retune(over: move, ctx: ctx)
            self.after(move * 0.6, ctx: ctx) { [weak self] in
                guard let self else { return }
                self.glide.go(to: 1, over: self.rng.range(3...5), now: ctx.time)
                self.gliding = false
            }
        }
    }

    override func update(dt: Double, ctx: LayerContext) {
        let t = ctx.time
        if !gliding && ctx.field.pedalMIDI != pedal {
            if pedal == 0 { pedal = ctx.field.pedalMIDI; retune(over: ParamRamp.minimum, ctx: ctx) }
            else { movePedal(to: ctx.field.pedalMIDI, ctx: ctx) }
        }
        let g = glide.tick(t) * sceneGain.tick(t)
        let roam = roamEnv.tick(t)
        let depth = 0.3 + 0.4 * ctx.intensity
        for p in P.allCases {
            let lfo = lfos.isEmpty ? 0.5 : lfos[p.rawValue].unit(at: t)
            var a = base[p.rawValue] * (1 - depth + depth * lfo) * g
            if p == .roam { a *= roam }
            if p == .sub { a *= (0.8 + 0.4 * (1 - ctx.brightness)) * subPulseEnv.tick(t) }   // darker = more sub
            ParamRamp.set(oscs[p.rawValue].$amplitude, a, over: 0.12)
        }
        if !gliding {
            let beat = 0.05 + 0.25 * beatLFO.unit(at: t)
            ParamRamp.set(oscs[P.rootB.rawValue].$frequency, Scale.midiToFrequency(pedal) + beat, over: 0.12)
        }
        ParamRamp.set(filter.$cutoffFrequency, expMap(ctx.brightness, 220, 1100), over: 0.12)
    }

    override func didSilence(fade: Double, ctx: LayerContext) {
        gliding = false
        glide = SoftEnv(1)
    }
}
