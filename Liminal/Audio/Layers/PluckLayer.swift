import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation
import AudioToolbox

/// Pluck (plan section 7, decisions D62, D84): broken chords of 3-5 notes, 250-600 ms apart, every 9-18 s (plan 23-47 s),
/// or, in "ostinato" scenes, a steady 4-6 step chord-tone pulse (0.42-1.05 s per step) that mutates between runs;
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
        let strip = LayerStrip(source: mix, filter: filter, trim: dbToGain(-10) * 1.414 / 0.6,
                               reverb: 0.6, delay: 0.4)
        var tmp = MusicRNG(seed: 0)
        loop = LoopClock(bounds: 9...18, rng: &tmp)
        super.init(id: .pluck, strip: strip, entryThreshold: 0.5)
        generators = strings
    }

    override func prepare(rng: MusicRNG) {
        super.prepare(rng: rng)
        loop = LoopClock(bounds: 9...18, rng: &self.rng)
    }

    override func didActivate(ctx: LayerContext) {
        ensureLoop { after(rng.range(2...8), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) } }
    }

    override func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {
        loop.reroll(bounds: 9...18, rng: &rng)
        // Ostinato scenes (decision D84): a steady, slowly mutating chord-tone pulse instead of broken chords.
        let p: Float = {
            switch scene.kind {
            case .bloom: return 0.7
            case .constellation: return 0.65
            case .tide: return 0.55
            case .drift: return 0.5
            case .stillness: return 0
            }
        }()
        ostinato = rng.chance(p)
        pulse = scene.kind == .tide ? rng.range(0.7...1.05) : rng.range(0.42...0.8)
        pattern = PluckLayer.makePattern(rng: &rng)
    }

    // MARK: Ostinato

    private var ostinato = false
    private var pulse = 0.6
    private var pattern: [Int] = [0, 2, 1, 3]

    /// A 4-6 step walk over chord-tone indices 0...4 (index into the current chord tones, so the figure
    /// follows every chord change without re-planning).
    private static func makePattern(rng: inout MusicRNG) -> [Int] {
        let n = rng.int(4...6)
        var i = rng.int(0...2)
        var out: [Int] = []
        for _ in 0..<n {
            out.append(i)
            i = min(max(i + rng.pick([-2, -1, 1, 1, 2]), 0), 4)
        }
        return out
    }

    /// One run of the pulse: 12-32 steps with a swell arc and an accent on each pattern start. Returns its length.
    private func ostinatoRun(ctx: LayerContext) -> Double {
        let steps = rng.int(16...40)
        let step = pulse * Double(1.15 - 0.3 * ctx.density)
        let base = rng.rangeF(0.5...0.7)
        let pat = pattern
        strip.setPan(rng.rangeF(-0.6...0.6), over: 2)
        var t = 0.0
        for k in 0..<steps {
            if k > 0 && rng.chance(0.1) { t += step; continue }        // a dropped step breathes
            let arc = 0.55 + 0.45 * Float(sin(Double.pi * Double(k + 1) / Double(steps + 1)))
            let accent: Float = k % pat.count == 0 ? 1.25 : rng.rangeF(0.9...1.05)
            let vel = min(1, base * arc * accent)
            let idx = pat[k % pat.count]
            after(t, ctx: ctx) { [weak self] in
                guard let self, self.isActive else { return }
                let s = max(-4, min(5, ctx.registerShift))
                let tones = ctx.field.chordTones(in: (55 + s)...(79 + s))
                guard !tones.isEmpty else { return }
                self.pluck(tones[min(idx, tones.count - 1)], velocity: vel, ctx: ctx)
            }
            t += step * rng.range(0.97...1.03)
        }
        // The figure mutates one step between runs.
        if rng.chance(0.6) {
            let i = rng.int(0...(pattern.count - 1))
            pattern[i] = min(max(pattern[i] + rng.pick([-1, 1, 2]), 0), 4)
        }
        return t
    }

    private func cycle(ctx: LayerContext) {
        if isActive && ostinato {
            let len = ostinatoRun(ctx: ctx)
            after(len + rng.range(1.5...5) * Double(1.4 - 0.8 * ctx.density), ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
            return
        }
        let period = loop.nextCycle(rng: &rng) * Double(1.4 - 0.8 * ctx.density)
        after(period, ctx: ctx) { [weak self] in self?.cycle(ctx: ctx) }
        guard isActive else { return }
        if rng.chance(0.12 - 0.06 * ctx.density) { return }
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
        PluckLayer.trigger(strings[v], frequency: Scale.midiToFrequency(m), amplitude: amp * velocity * ctx.shareAttack(layer: .pluck))
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
