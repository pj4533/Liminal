import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation
import AudioToolbox

/// Pluck (plan section 7, decision D62): broken chords of 3-5 notes, 250-600 ms apart, every 15-31 s (plan 23-47 s),
/// rising or falling, from `PluckedString` (Karplus-Strong) voices. Low-passed at 3 kHz and sent mostly
/// to the delay, so the tape echoes carry the phrase. Three voices (plan: two) so each note rings for at
/// least two following notes before its string is re-plucked.
nonisolated final class PluckLayer: BaseLayer {
    static let poolSize = 3
    private let strings: [PluckedString]
    private let filter: LowPassButterworthFilter
    private var loop: LoopClock
    private var next = 0
    private let amp: Float = 0.6

    init() {
        strings = (0..<PluckLayer.poolSize).map { _ in PluckedString(frequency: 220, amplitude: 0, lowestFrequency: 110) }
        let mix = Mixer(strings)
        filter = LowPassButterworthFilter(mix, cutoffFrequency: 3000)
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-12) * 1.414 / 0.6,
                               reverb: 0.6, delay: 0.4)
        var tmp = SeededRNG(seed: 0)
        loop = LoopClock(bounds: 15...31, rng: &tmp)
        super.init(id: .pluck, strip: strip, entryThreshold: 0.5)
        generators = strings
    }

    override func prepare(rng: SeededRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: 15...31, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(2...8), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: 15...31, rng: &rng)
    }

    private func cycle(ctx: LayerContext) {
        let period = loop.nextCycle(rng: &rng) * Double(1.4 - 0.8 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        if rng.chance(0.2 - 0.1 * ctx.density) { return }
        phrase(ctx: ctx)
    }

    private func phrase(ctx: LayerContext) {
        let s = max(-4, min(5, ctx.registerShift))
        let tones = ctx.field.chordTones(in: (52 + s)...(81 + s))
        guard tones.count >= 3 else { return }
        let n = min(rng.int(3...5), tones.count)
        let start = rng.int(0...(tones.count - n))
        var notes = Array(tones[start..<(start + n)])
        if rng.chance(0.45) { notes.reverse() }
        // Occasionally a scale passing tone between two chord tones.
        if n >= 3 && rng.chance(0.25) {
            let i = rng.int(1...(n - 1))
            let mid = ctx.field.nearest(to: (notes[i - 1] + notes[i]) / 2, chordTonesOnly: false)
            if mid != notes[i - 1] && mid != notes[i] { notes.insert(mid, at: i) }
        }
        strip.setPan(rng.rangeF(-0.5...0.5), over: 0.5)
        let gap = rng.range(0.25...0.6)
        var t = 0.0
        for (k, m) in notes.enumerated() {
            let vel = rng.rangeF(0.6...0.95) * (k == 0 ? 1 : 0.9)
            after(t, ctx: ctx) { [weak self] in self?.pluck(m, velocity: vel, ctx: ctx) }
            t += gap * rng.range(0.8...1.25)
        }
    }

    private func pluck(_ midi: Int, velocity: Float, ctx: LayerContext) {
        let v = next
        next = (next + 1) % PluckLayer.poolSize
        let m = max(midi, 46)          // the string's delay line is sized for 110 Hz and up
        PluckLayer.trigger(strings[v], frequency: Scale.midiToFrequency(m), amplitude: amp * velocity)
        ctx.emit(.noteOn, layer: .pluck, midi: m, velocity: velocity)
    }

    /// `PluckedString.trigger` builds an AudioKit `MIDIEvent`, whose first construction costs about 300 ms
    /// (lazy framework setup) and stalled the conductor tick. Send the three note-on bytes straight to the
    /// AU's MIDI block instead (decision D69).
    private static func trigger(_ s: PluckedString, frequency: Float, amplitude: Float) {
        s.frequency = frequency
        s.amplitude = amplitude
        guard let block = s.au.scheduleMIDIEventBlock else { return }
        var bytes: (UInt8, UInt8, UInt8) = (0x90, 64, 127)
        withUnsafeBytes(of: &bytes) { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            block(AUEventSampleTime(AUEventSampleTimeImmediate), 0, 3, p)
        }
    }

    override func update(dt: Double, ctx: LayerContext) {
        ParamRamp.set(filter.$cutoffFrequency, expMap(ctx.brightness, 1800, 4000), over: 0.12)
        strip.setSends(reverb: 0.6, delay: 0.4 * ctx.delayScale, over: 0.12)
    }
}
