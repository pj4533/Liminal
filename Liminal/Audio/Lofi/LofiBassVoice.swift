import Accelerate
import Foundation
import Synchronization

/// The bass tone of a phrase (plan bass-tone-redo 2, rotation D120): the three tones take turns, a new
/// one at each sixteen-bar drum break (every four phrases, the form's big change), never the same tone
/// twice in a row. The order is seeded, so a seed replays the same tones. Captures may pin one tone with
/// the `bassTone` hook; the hooks are inert in the app.
nonisolated enum LofiBassTone: String, CaseIterable, Sendable {
    /// Flatwound electric with the tone rolled off; a real string pluck as the strike.
    case round
    /// Onset-trimmed upright, darker, with a soft synthesized thump.
    case upright
    /// No samples: the sub's harmonic series continued, with a synthesized strike.
    case synth

    /// The first block's fallback and the tone the tests treat as the reference.
    static let standard: LofiBassTone = .round
    /// Phrases per tone: one sixteen-bar drum break.
    static let phrasesPerTone = 4

    /// The capture hook's pinned tone, if any.
    static var pinned: LofiBassTone? {
        LofiCaptureHooks.option("bassTone").flatMap(LofiBassTone.init(rawValue:))
    }

    /// The tone `phrase` plays for `seed`: block `phrase / phrasesPerTone` takes a seeded tone that differs
    /// from the block before it.
    static func tone(seed: UInt64, phrase: Int) -> LofiBassTone {
        if let pinned { return pinned }
        let block = max(0, phrase) / phrasesPerTone
        let all = allCases
        var random = MusicRNG(seed: seed).fork(0xBA55_70E5)
        var index = Int(random.next() % UInt64(all.count))
        for _ in 0..<block { index = (index + 1 + Int(random.next() % UInt64(all.count - 1))) % all.count }
        return all[index]
    }

    var voice: LofiBassVoice {
        switch self {
        case .round: .flatwound
        case .upright: .upright
        case .synth: .synth
        }
    }
}

/// The bass voice of a phrase. `classic` is the original sine, kept bit for bit. The other three are one
/// design (plan bass-tone-redo 2): everything below 160 Hz is an additive, phase-exact sub (fundamental
/// and real 2nd to 4th harmonics, weighted by a zero-phase 160 Hz crossover), and everything above comes
/// from one dark layer: a sample high-passed at the same 160 Hz with the complementary zero-phase slope and
/// low-passed at a few hundred hertz, or (`synth`) the sub's series continued. A note with `strike` gets a
/// short bright strike layer (gone by 80 to 100 ms), a brief opening of the body's low-pass and a level
/// accent; a note without one is a plain warm tone. No drive, no click, no pitch drop.
/// Mono, all envelope corners raised cosines, exactly zero after the release.
nonisolated enum LofiBassVoice: Int, CaseIterable, Sendable {
    /// The original sine with decaying second harmonic and tanh shaping, kept bit for bit.
    case classic
    /// Sub under onset-trimmed Karoryfer Sneakybass finger notes, low-passed at 350 Hz.
    case upright
    /// Sub under Karoryfer Swagbass flatwound notes, low-passed at 420 Hz; flatwound pluck as the strike.
    case flatwound
    /// Sub and its harmonic series continued to the 12th partial; no samples.
    case synth

    var kit: LofiBassSamples.Kit? {
        switch self {
        case .classic, .synth: nil
        case .upright: .upright
        case .flatwound: .flatwound
        }
    }

    /// Seconds from note start until the voice's envelope reaches 20 percent of its peak (a `walk`):
    /// the audible attack landmark the capture diagnostics place `attackFrame` on. Placement on a kick
    /// uses `lowRiseLead`.
    var attackLead: Double {
        switch self {
        case .classic: 0.0085
        case .upright, .flatwound, .synth: 0.0012
        }
    }

    // MARK: Strokes

    struct Shape: Sendable {
        /// Raised-cosine rise and release of the voice, seconds.
        let rise: Double, release: Double
        /// Level change across the held part, dB per second.
        let decayDBPerSecond: Double
        /// Prepared sample articulation of the body.
        let body: LofiBassSamples.Stroke
    }

    static func shape(_ stroke: LofiScore.BassStroke) -> Shape {
        switch stroke {
        case .thump, .walk: Shape(rise: 0.004, release: 0.070, decayDBPerSecond: 3, body: .long)
        case .hold: Shape(rise: 0.005, release: 0.140, decayDBPerSecond: 2, body: .long)
        case .ghost: Shape(rise: 0.004, release: 0.050, decayDBPerSecond: 0, body: .ghost)
        }
    }

    /// The release of a note whose successor is struck or anchored: short, so the strike is a re-pluck
    /// and the low band dips the 6 dB that C-B2 times (with `LofiScore.bassAccentClearance`).
    static let strikeRelease = 0.045

    /// Seconds of release after the held part of a note of this voice and stroke.
    func release(_ stroke: LofiScore.BassStroke, beforeStrike: Bool = false) -> Double {
        guard self != .classic else { return 0.31 }
        let normal = Self.shape(stroke).release
        return beforeStrike ? min(normal, Self.strikeRelease) : normal
    }

    // MARK: Levels (plan bass-tone-redo 2, start values)

    /// Fundamental amplitude of the sub at velocity 1, before the chain.
    static let subGain: Float = 0.30
    /// Sub partials 1 to 4, dB re the fundamental, before the crossover weight.
    static let subPartialsDB: [Double] = [0, -14, -17, -21]
    /// The crossover between the sub and the upper layer.
    static let crossover = 160.0
    /// Magnitude of a 2-pole Butterworth low-pass at `crossover` run forward and backward; the upper layer
    /// gets 1 minus this, so the two sum flat.
    static func subWeight(_ f: Double) -> Double { 1 / (1 + pow(f / crossover, 4)) }
    static let slideTime = 0.045

    /// The sampled body is held this far under the steady sub's RMS (`steadySubRMS`) through the note.
    static func bodyUnderSubDB(_ voice: LofiBassVoice) -> Float { voice == .upright ? 12.5 : 13 }
    /// The body's levelling never raises a quiet stretch more than this over its loudest point.
    static let bodyMaxBoostDB: Float = 24
    /// The body rises over this long (raised cosine): an unstruck note has no pluck, and on a struck one the
    /// strike layer, not the sample's own second-period pluck, is the brightest moment.
    static let plainBodyRise = 0.030
    static let struckBodyRise = 0.040
    /// A second zero-phase high-pass on the body (4-pole, forward and backward), under the crossover,
    /// keeps the sample's fundamental out of the sub's band (-0.2 dB at 160 Hz, -9 dB at 87 Hz).
    static let bodyLeakHighpass = 110.0
    /// Fixed 24 dB per octave low-pass of the sampled body (two sections: at 12 dB per octave the flatwound's
    /// own pluck brightness, as strong at 300-1500 Hz as its fundamental, stayed in the sustain and masked
    /// the strike).
    static func bodyLowpass(_ voice: LofiBassVoice) -> Double { voice == .upright ? 360 : 400 }
    /// On a struck note the body's low-pass opens by `strike` times this and closes with `strikeOpenTime`.
    static let strikeOpening = 300.0
    static let strikeOpenTime = 0.008
    /// The breakdown sweep moves the body's low-pass across this range.
    static let sweepRange = 150.0...450.0
    /// The synth body's level against the series it continues, dB.
    static let synthBodyGainDB: Float = 0

    /// Strike layer per voice: peak level re the sub's peak (dB, times `strike`), decay time constant and
    /// the time it reaches exactly zero.
    static func strikeLevelDB(_ voice: LofiBassVoice) -> Float {
        switch voice {
        case .upright: -5
        case .synth: -3
        default: -2
        }
    }
    static func strikeDecay(_ voice: LofiBassVoice) -> Double { 0.010 }
    static func strikeEnd(_ voice: LofiBassVoice) -> Double { voice == .upright ? 0.100 : 0.080 }
    static let strikeLowpass = 650.0
    /// The strike layer's peak sits about this long after its start (its 1 ms rise).
    static let strikePeakTime = 0.001
    /// The strike's energy sits above this (zero-phase 2-pole high-pass, or the same weight on synthesized
    /// partials), so it reads as a bright slap rather than more low end.
    static let strikeHighpass = 300.0
    static func strikeWeight(_ f: Double) -> Double {
        let r = pow(f / strikeHighpass, 4)
        return r / (1 + r) / sqrt(1 + pow(f / strikeLowpass, 8))
    }
    /// Level accent of a struck note: `1 + accent strike e^(-t / accentTime)`.
    static let accent = 0.4
    static let accentTime = 0.040

    // MARK: Low-band rise

    private struct LeadKey: Hashable { let voice: Int, stroke: Int, midi: Int, rate: Double, struck: Bool }
    private static let leadCache = Mutex<[LeadKey: Double]>([:])

    /// Seconds from note start until the voice's C-B2 rise (`smoothLowRise`: the -6 dB point of the
    /// 40-160 Hz Hilbert envelope, the measure of scripts/mixlib/lowend.py), on the complete voice at
    /// `midi`. An anchored note starts this far before its kick's rise, so the two bodies rise together.
    /// Everything below 160 Hz is the synthesized sub, so the lead depends on stroke, pitch and strike
    /// only. Cached per (voice, stroke, midi, sample rate, struck); called off the audio thread only (the
    /// lock is taken on the render worker).
    func lowRiseLead(midi: Int, stroke: LofiScore.BassStroke = .walk, struck: Bool = false,
                     sampleRate: Double = 48_000) -> Double {
        let key = LeadKey(voice: rawValue, stroke: stroke.rawValue, midi: midi, rate: sampleRate, struck: struck)
        if let cached = Self.leadCache.withLock({ $0[key] }) { return cached }
        let value = uncachedLowRiseLead(midi: midi, stroke: stroke, struck: struck, sampleRate: sampleRate)
        Self.leadCache.withLock { $0[key] = value }
        return value
    }

    func uncachedLowRiseLead(midi: Int, stroke: LofiScore.BassStroke = .walk, struck: Bool = false,
                             sampleRate: Double = 48_000) -> Double {
        // A tenth of a second of silence first, as for a note inside a phrase after its clearance.
        let clock = LofiClock(tempo: 60, sampleRate: sampleRate)
        let preroll = clock.frame(at: 0.1)
        let frames = Int(0.5 * sampleRate)
        var left = [Float](repeating: 0, count: frames), right = left
        var note = LofiScore.Note(part: .bass, midi: midi, beat: 0.1, length: 0.3, velocity: 0.8, send: 0)
        note.stroke = stroke
        note.strike = struck ? 1 : 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in Self.add(note, voice: self, clock: clock, left: l, right: r) }
        }
        // At the bottom of the register (MIDI 28 sits at the measure's 40 Hz corner) the envelope's peak in
        // the window can come from a later swell: the sub alone then gives the rise, else a typical 2 ms.
        func lead(_ x: [Float]) -> Double? {
            Self.smoothLowRise(x, from: preroll, sampleRate: sampleRate).map { Double($0 - preroll) / sampleRate }
        }
        if let full = lead(left), full <= Self.maximumLead { return full }
        if self != .classic {
            var sub = Self.render(note, voice: self, clock: clock, limit: frames - preroll, layers: .sub)
            sub = [Float](repeating: 0, count: preroll) + sub + [Float](repeating: 0, count: max(0, frames - preroll - sub.count))
            if let alone = lead(sub), alone <= Self.maximumLead { return alone }
        }
        return 0.002
    }

    /// A rise later than this after note start is a later swell, not the note's attack.
    static let maximumLead = 0.020

    // MARK: Smooth low-band rise (the C-B2 measure)

    /// The C-B2 rise of a signal (scripts/mixlib/lowend.py): the 40-160 Hz band (4th-order Butterworth
    /// high- and low-pass, forward then backward), its analytic (Hilbert) envelope, a centred 2 ms
    /// average, then in `[from - 30 ms, from + 80 ms)` the last frame more than 6 dB under the window's
    /// peak before that peak, plus one. Unlike the 2 ms power of `LofiDrumLandmarks.lowBandRise`, this
    /// envelope does not ripple with a low note's waveform, so the frame is stable across pitches.
    static func smoothLowRise(_ input: [Float], from center: Int, sampleRate: Double) -> Int? {
        let count = input.count
        guard count > 16 else { return nil }
        var band = input
        let q = (0.541_196_100_146_197, 1.306_562_964_876_377)
        let kinds: [LofiBiquad.Kind] = [.highpass(hz: 40, q: q.0), .highpass(hz: 40, q: q.1),
                                        .lowpass(hz: 160, q: q.0), .lowpass(hz: 160, q: q.1)]
        band.withUnsafeMutableBufferPointer { b in
            var forward = LofiFilterChain(kinds, sampleRate: sampleRate)
            forward.process(b.baseAddress!, count: count)
            vDSP_vrvrs(b.baseAddress!, 1, vDSP_Length(count))
            var backward = LofiFilterChain(kinds, sampleRate: sampleRate)
            backward.process(b.baseAddress!, count: count)
            vDSP_vrvrs(b.baseAddress!, 1, vDSP_Length(count))
        }
        // Analytic signal by FFT: negative frequencies removed, positive doubled.
        let log2n = vDSP_Length(ceil(log2(Double(count))))
        let n = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n), imag = [Float](repeating: 0, count: n)
        real.replaceSubrange(0..<count, with: band)
        var envelope = [Float](repeating: 0, count: n)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                for k in 1..<(n / 2) { r[k] *= 2; i[k] *= 2 }
                for k in (n / 2 + 1)..<n { r[k] = 0; i[k] = 0 }
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                vDSP_zvabs(&split, 1, &envelope, 1, vDSP_Length(n))
            }
        }
        // Centred 2 ms average.
        let w = max(1, Int((0.002 * sampleRate).rounded()))
        var sums = [Double](repeating: 0, count: count + 1)
        for k in 0..<count { sums[k + 1] = sums[k] + Double(envelope[k]) }
        func smooth(_ k: Int) -> Double {
            let lo = min(count, max(0, k - w / 2)), hi = min(count, max(0, k - w / 2 + w))
            return hi > lo ? (sums[hi] - sums[lo]) / Double(hi - lo) : 0
        }
        let a = max(0, center - Int(0.030 * sampleRate)), b = min(count, center + Int(0.080 * sampleRate))
        guard b - a >= 4 else { return nil }
        let values = (a..<b).map(smooth)
        guard let peakIndex = values.indices.max(by: { values[$0] < values[$1] }), values[peakIndex] > 1e-9 else { return nil }
        let threshold = values[peakIndex] * pow(10, -6.0 / 20)
        guard let below = values[0...peakIndex].lastIndex(where: { $0 < threshold }) else { return nil }
        return a + below + 1
    }

    // MARK: Rendering

    /// Adds one note to both channels. `sweep`, when present, moves the body low-pass across
    /// `sweepRange` over those phrase beats (dub filter movement in a breakdown). `beforeStrike` gives the
    /// note the short release it needs before a struck or anchored successor. `strikeShift` places the
    /// strike layer that many frames from the note start (negative: earlier), so on an anchored note the
    /// slap lands on the kick's broadband attack while the sub's rise stays on the kick's low rise.
    /// `cue` and `cueOut`, when both are given, also render the note's clean cue partials (`Cue`, D129) into
    /// the separate mono `cueOut` buffer (same frames as `left`), which the bass chain adds after its
    /// parallel harmonics and compressor.
    static func add(_ note: LofiScore.Note, voice: LofiBassVoice, clock: LofiClock,
                    left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>,
                    samples: LofiBassSamples = .bundled, sweep: ClosedRange<Double>? = nil, beforeStrike: Bool = false,
                    strikeShift: Int = 0, cue: Cue? = nil, cueOut: UnsafeMutableBufferPointer<Float>? = nil) {
        guard voice != .classic else {
            addClassic(note, clock: clock, left: left, right: right)
            return
        }
        let start = clock.frame(at: note.beat)
        guard start >= 0, start < left.count else { return }
        let parts = renderParts(note, voice: voice, clock: clock, limit: left.count - start, samples: samples,
                                sweep: sweep, layers: .all, beforeStrike: beforeStrike,
                                cue: cueOut == nil ? nil : cue, cueOnset: note.strike > 0 ? strikeShift : 0)
        func mix(_ x: [Float], at position: Int, into out: UnsafeMutableBufferPointer<Float>) {
            let skip = max(0, -position), at = max(0, position)
            let n = min(x.count - skip, out.count - at)
            guard n > 0 else { return }
            x.withUnsafeBufferPointer { m in
                vDSP_vadd(out.baseAddress! + at, 1, m.baseAddress! + skip, 1, out.baseAddress! + at, 1, vDSP_Length(n))
            }
        }
        for out in [left, right] {
            mix(parts.tone, at: start, into: out)
            mix(parts.strike, at: start + strikeShift, into: out)
        }
        if let cueOut, !parts.cue.isEmpty { mix(parts.cue, at: start, into: cueOut) }
    }

    enum Layers: Sendable { case all, sub, body, strike }

    /// One note as a mono buffer that starts on the note's first frame, at most `limit` frames long (the
    /// strike layer unshifted).
    static func render(_ note: LofiScore.Note, voice: LofiBassVoice, clock: LofiClock, limit: Int,
                       samples: LofiBassSamples = .bundled, sweep: ClosedRange<Double>? = nil,
                       layers: Layers = .all, beforeStrike: Bool = false) -> [Float] {
        let parts = renderParts(note, voice: voice, clock: clock, limit: limit, samples: samples, sweep: sweep,
                                layers: layers, beforeStrike: beforeStrike)
        guard layers == .all, !parts.strike.isEmpty else { return layers == .strike ? parts.strike : parts.tone }
        var mono = parts.tone
        parts.strike.withUnsafeBufferPointer { s in
            vDSP_vadd(mono, 1, s.baseAddress!, 1, &mono, 1, vDSP_Length(min(s.count, mono.count)))
        }
        return mono
    }

    /// The note's tone (the layers asked for among sub and body) and its strike layer (empty when unstruck
    /// or not asked for), both starting on the note's first frame.
    private static func renderParts(_ note: LofiScore.Note, voice: LofiBassVoice, clock: LofiClock, limit: Int,
                                    samples: LofiBassSamples, sweep: ClosedRange<Double>?, layers: Layers,
                                    beforeStrike: Bool, cue: Cue? = nil,
                                    cueOnset: Int = 0) -> (tone: [Float], strike: [Float], cue: [Float]) {
        guard voice != .classic else { return ([], [], []) }
        let shape = shape(note.stroke)
        let rate = clock.sampleRate
        let span = max(1, clock.frame(at: note.length))
        let tail = max(1, Int(rate * voice.release(note.stroke, beforeStrike: beforeStrike)))
        let count = min(limit, span + tail)
        guard count > 0 else { return ([], [], []) }
        let strike = Double(max(0, min(1, note.strike)))
        let envelope = envelope(shape: shape, span: span, tail: tail, count: count, rate: rate, accent: accent * strike)
        let sub = renderSub(note, envelope: envelope, rate: rate)
        if layers == .sub { return (sub, [], []) }
        var subPeak: Float = 0
        vDSP_maxmgv(sub, 1, &subPeak, vDSP_Length(count))
        var tone = layers == .all ? sub : [Float](repeating: 0, count: count)
        if layers == .all || layers == .body {
            let body = voice == .synth
                ? synthBody(note, envelope: envelope, rate: rate)
                : sampledBody(note, voice: voice, sub: sub, envelope: envelope, clock: clock, samples: samples,
                              sweep: sweep, strike: strike)
            vDSP_vadd(tone, 1, body, 1, &tone, 1, vDSP_Length(count))
        }
        var layer: [Float] = []
        if layers == .all || layers == .strike, strike > 0 {
            layer = strikeLayer(note, voice: voice, count: count, rate: rate, samples: samples,
                                peak: Float(strike) * subPeak * powf(10, strikeLevelDB(voice) / 20))
        }
        let cuePartials = cue.map {
            cuePartials(note, voice: voice, envelope: envelope, rate: rate, onset: cueOnset, cue: $0, sub: sub, tone: tone)
        } ?? []
        return (tone, layer, cuePartials)
    }

    /// Raised-cosine rise, the stroke's per-second decay times the strike accent, raised-cosine release
    /// to exactly zero (vectorized).
    private static func envelope(shape: Shape, span: Int, tail: Int, count: Int, rate: Double, accent: Double) -> [Float] {
        var e = [Float](repeating: 0, count: count)
        let hold = min(span, count)
        // Held part: 10^(-dB(t) / 20) = exp(-ln(10) / 20 * rate_dB * t), one vector exp.
        var start: Float = 0, step = Float(-log(10.0) / 20 * shape.decayDBPerSecond / rate)
        var n = Int32(hold)
        if hold > 0 {
            vDSP_vramp(&start, &step, &e, 1, vDSP_Length(hold))
            vvexpf(&e, e, &n)
        }
        if accent > 0, hold > 0 {
            // 1 + accent e^(-t / 40 ms): the strike is the note's loudest moment.
            var a0: Float = 0, da = Float(-1 / (accentTime * rate))
            var bump = [Float](repeating: 0, count: hold)
            vDSP_vramp(&a0, &da, &bump, 1, vDSP_Length(hold))
            var hn = Int32(hold)
            vvexpf(&bump, bump, &hn)
            var scale = Float(accent), one: Float = 1
            vDSP_vsmsa(bump, 1, &scale, &one, &bump, 1, vDSP_Length(hold))
            vDSP_vmul(e, 1, bump, 1, &e, 1, vDSP_Length(hold))
        }
        let last = hold > 0 ? e[hold - 1] : 1
        if span < count {
            // Release: last * (0.5 + 0.5 cos(pi u)), u = (i - span + 1) / tail, exactly zero at u >= 1.
            let releaseCount = min(count - span, tail - 1)
            if releaseCount > 0 {
                var u0 = Float(Double.pi / Double(tail)), du = Float(Double.pi / Double(tail))
                var r = [Float](repeating: 0, count: releaseCount)
                vDSP_vramp(&u0, &du, &r, 1, vDSP_Length(releaseCount))
                var m = Int32(releaseCount)
                vvcosf(&r, r, &m)
                var a = 0.5 * last, b = 0.5 * last
                vDSP_vsmsa(r, 1, &a, &b, &r, 1, vDSP_Length(releaseCount))
                e.withUnsafeMutableBufferPointer { out in
                    r.withUnsafeBufferPointer { out.baseAddress!.advanced(by: span).update(from: $0.baseAddress!, count: releaseCount) }
                }
            }
        }
        applyRise(&e, frames: max(1, Int(shape.rise * rate)))
        return e
    }

    /// Multiplies the first `frames` of `x` by a raised-cosine rise from zero.
    private static func applyRise(_ x: inout [Float], frames: Int) {
        let riseFrames = min(x.count, frames)
        guard riseFrames > 0 else { return }
        var r0: Float = 0, dr = Float(Double.pi / Double(frames))
        var rise = [Float](repeating: 0, count: riseFrames)
        vDSP_vramp(&r0, &dr, &rise, 1, vDSP_Length(riseFrames))
        var rn = Int32(riseFrames)
        vvcosf(&rise, rise, &rn)
        var a: Float = -0.5, b: Float = 0.5
        vDSP_vsmsa(rise, 1, &a, &b, &rise, 1, vDSP_Length(riseFrames))
        vDSP_vmul(x, 1, rise, 1, &x, 1, vDSP_Length(riseFrames))
    }

    /// The note's phase in [0, 2 pi), zero at the first frame: the `slide` glide is a raised-cosine pitch
    /// curve that ends exactly on the note, then an exact ramp.
    private static func phase(_ note: LofiScore.Note, count: Int, rate: Double) -> [Float] {
        let omega = 2 * Double.pi * frequency(note.midi) / rate
        let slide = Double(max(0, note.slide))
        let bend = min(count, slide > 0 ? Int(slideTime * rate) + 1 : 0)
        var phase = [Double](repeating: 0, count: count)
        var acc = 0.0
        var i = 0
        while i < bend {
            phase[i] = acc
            let t = Double(i) / rate
            let semitones = t < slideTime ? -slide * (0.5 + 0.5 * cos(Double.pi * t / slideTime)) : 0
            acc += semitones == 0 ? omega : omega * pow(2, semitones / 12)
            i += 1
        }
        if bend < count {
            var base = acc, step = omega
            phase.withUnsafeMutableBufferPointer { vDSP_vrampD(&base, &step, $0.baseAddress! + bend, 1, vDSP_Length(count - bend)) }
        }
        var tau = [Double](repeating: 2 * Double.pi, count: count)
        var n = Int32(count)
        vvremainder(&tau, phase, tau, &n)
        var p = [Float](repeating: 0, count: count)
        vDSP_vdpsp(tau, 1, &p, 1, vDSP_Length(count))
        return p
    }

    static func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    /// Sum of `amplitudes[k]` sin((k + first) phase) over the partials, zero above 0.45 of the rate.
    private static func partials(_ p: [Float], first: Int, amplitudes: [Double], f0: Double, rate: Double) -> [Float] {
        let count = p.count
        var out = [Float](repeating: 0, count: count)
        var work = [Float](repeating: 0, count: count)
        var n = Int32(count)
        var k = 0
        while k < amplitudes.count {
            let harmonic = k + first
            if amplitudes[k] != 0, f0 * Double(harmonic) < 0.45 * rate {
                var h = Float(harmonic)
                vDSP_vsmul(p, 1, &h, &work, 1, vDSP_Length(count))
                vvsinf(&work, work, &n)
                var a = Float(amplitudes[k])
                vDSP_vsma(work, 1, &a, out, 1, &out, 1, vDSP_Length(count))
            }
            k += 1
        }
        return out
    }

    /// RMS of the steady sub at `midi` per unit of `subGain` times velocity (before the envelope): the
    /// reference the body is levelled against, the same for every note length.
    static func steadySubRMS(_ midi: Int) -> Double {
        let f0 = frequency(midi)
        let power = subPartialsDB.indices.reduce(0.0) { sum, k in
            let a = pow(10, subPartialsDB[k] / 20) * subWeight(f0 * Double(k + 1))
            return sum + a * a / 2
        }
        return power.squareRoot()
    }

    /// Additive sub: partials 1 to 4 in sine phase, zero start phase, each weighted by the crossover.
    private static func renderSub(_ note: LofiScore.Note, envelope: [Float], rate: Double) -> [Float] {
        let f0 = frequency(note.midi)
        let amplitudes = subPartialsDB.indices.map { k in pow(10, subPartialsDB[k] / 20) * subWeight(f0 * Double(k + 1)) }
        var out = partials(phase(note, count: envelope.count, rate: rate), first: 1, amplitudes: amplitudes, f0: f0, rate: rate)
        var level = subGain * note.velocity
        vDSP_vsmul(out, 1, &level, &out, 1, vDSP_Length(out.count))
        vDSP_vmul(out, 1, envelope, 1, &out, 1, vDSP_Length(out.count))
        return out
    }

    // MARK: Cue partials (D129)

    /// Clean pitch-tracking cue partials (bass translation, D129): the note's own harmonics from `lowHz` up,
    /// in phase with the sub, so a speaker that reproduces nothing under 150-250 Hz still hears the bass
    /// line as its harmonic series instead of a separate voice. The first partial at or above `lowHz` sits
    /// `levelDB` under the fundamental, each next one `slopeDB` lower, weighted by the complement of the
    /// 160 Hz crossover and a 4-pole roll-off at `highHz`; the `synth` tone (which already continues its
    /// series to the 12th partial) takes `synthOffsetDB` more. The layer follows the note's envelope and
    /// velocity but is zero at the strike (or the note start) and rises over `onset` seconds (raised cosine),
    /// so the strike stays the brightest moment and the slap still lines up with the kick.
    struct Cue: Sendable, Equatable {
        var levelDB: Double = -15
        var lowHz: Double = 180
        var highHz: Double = 300
        var slopeDB: Double = 4
        var onset: Double = 0.090
        var synthOffsetDB: Double = -4
        /// Each partial takes the phase of the tone's own component at that harmonic (`alignedPartials`), so
        /// it adds to a sampled body's harmonics instead of cancelling them. The synth tone's series is already
        /// in sine phase with the sub, so it is never aligned.
        var alignToTone = true
        static let standard = Cue()
    }

    /// The cue layer of one note (`Cue`), starting on the note's first frame. `onset` is the ramp's start in
    /// frames from the note start (the strike's shift on a struck note, else 0).
    private static func cuePartials(_ note: LofiScore.Note, voice: LofiBassVoice, envelope: [Float], rate: Double,
                                    onset: Int, cue: Cue, sub: [Float] = [], tone: [Float] = []) -> [Float] {
        let count = envelope.count
        let f0 = frequency(note.midi)
        let first = max(2, Int((cue.lowHz / f0).rounded(.up)))
        let level = cue.levelDB + (voice == .synth ? cue.synthOffsetDB : 0)
        var amplitudes: [Double] = []
        var k = first
        while f0 * Double(k) < min(0.45 * rate, 4 * cue.highHz) {
            let f = f0 * Double(k)
            let weight = (1 - subWeight(f)) / sqrt(1 + pow(f / cue.highHz, 8))
            amplitudes.append(pow(10, (level - cue.slopeDB * Double(k - first)) / 20) * weight)
            k += 1
        }
        guard !amplitudes.isEmpty, count > 0 else { return [] }
        let p = phase(note, count: count, rate: rate)
        var out: [Float]
        if cue.alignToTone, voice != .synth, tone.count == count, sub.count == count {
            // The body alone is measured: the sub's partials are in sine phase by construction, so they join as
            // a known in-phase term.
            var body = [Float](repeating: 0, count: count)
            vDSP_vsub(sub, 1, tone, 1, &body, 1, vDSP_Length(count))
            let known = amplitudes.indices.map { i -> Double in
                let k = i + first
                return k <= subPartialsDB.count ? pow(10, subPartialsDB[k - 1] / 20) * subWeight(f0 * Double(k)) : 0
            }
            out = alignedPartials(p, body: body, known: known, envelope: envelope, gain: subGain * note.velocity,
                                  first: first, amplitudes: amplitudes, f0: f0, rate: rate)
        } else {
            out = partials(p, first: first, amplitudes: amplitudes, f0: f0, rate: rate)
            var gain = subGain * note.velocity
            vDSP_vsmul(out, 1, &gain, &out, 1, vDSP_Length(count))
            vDSP_vmul(out, 1, envelope, 1, &out, 1, vDSP_Length(count))
        }
        // Onset: zero up to the strike (or the note start), then 0.5 - 0.5 cos(pi u) over `onset` seconds.
        let rampFrames = max(1, Int((cue.onset * rate).rounded()))
        let start = max(0, onset)
        let silent = min(count, start)
        if silent > 0 { out.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(silent)) } }
        // A strike shifted before the note (negative onset) still starts the ramp from zero at the note's first
        // frame: an aligned partial can start at any phase, so a ramp already part-way up would click.
        let rampEnd = min(count, start + rampFrames)
        if rampEnd > start {
            let length = rampEnd - start
            var u0: Float = 0, du = Float(Double.pi / Double(rampFrames))
            var ramp = [Float](repeating: 0, count: length)
            vDSP_vramp(&u0, &du, &ramp, 1, vDSP_Length(length))
            var m = Int32(length)
            vvcosf(&ramp, ramp, &m)
            var a: Float = -0.5, b: Float = 0.5
            vDSP_vsmsa(ramp, 1, &a, &b, &ramp, 1, vDSP_Length(length))
            out.withUnsafeMutableBufferPointer { o in
                vDSP_vmul(o.baseAddress! + start, 1, ramp, 1, o.baseAddress! + start, 1, vDSP_Length(length))
            }
        }
        return out
    }

    /// Cue partials whose phase follows the body's own component at each harmonic (`Cue.alignToTone`): a
    /// sampled body carries its own harmonics with the recording's phase, and a partial in sine phase with the
    /// sub can land against them and cancel (round body, MIDI 39: h3 and h4 about 2 dB lower with the cue on,
    /// D129). For each partial k the body is projected on sin and cos of k times the note's phase over the
    /// whole note, and the partial takes that one phase for the note, so it stays exactly harmonic (no phase
    /// modulation, nothing new off the series) and adds to the body's locked harmonic; a partial the body
    /// lets drift averages out. The sub's own partial at k (sine phase) joins as a known in-phase term, and a
    /// quarter of the cue's own amplitude biases toward sine phase, so a harmonic the body lacks keeps the
    /// sub's phase. The amplitude is exactly the unaligned partial's. Includes gain and envelope.
    private static func alignedPartials(_ p: [Float], body: [Float], known: [Double], envelope: [Float], gain: Float,
                                        first: Int, amplitudes: [Double], f0: Double, rate: Double) -> [Float] {
        let count = p.count
        var out = [Float](repeating: 0, count: count)
        guard count > 0, body.count == count, envelope.count == count else { return out }
        var s = [Float](repeating: 0, count: count), c = s, x = s
        var n = Int32(count)
        var meanEnvelope: Float = 0
        vDSP_meanv(envelope, 1, &meanEnvelope, vDSP_Length(count))
        let phaseBias = 0.25
        for (index, amplitude) in amplitudes.enumerated() where amplitude != 0 {
            let harmonic = index + first
            guard f0 * Double(harmonic) < 0.45 * rate else { continue }
            var h = Float(harmonic)
            vDSP_vsmul(p, 1, &h, &x, 1, vDSP_Length(count))
            vvsincosf(&s, &c, x, &n)
            // 2 mean(body sin) = B cos(theta), 2 mean(body cos) = B sin(theta) for a component B sin(k phase + theta).
            var sinPart: Float = 0, cosPart: Float = 0
            vDSP_dotpr(body, 1, s, 1, &sinPart, vDSP_Length(count))
            vDSP_dotpr(body, 1, c, 1, &cosPart, vDSP_Length(count))
            let scale = 2 / Double(count)
            let reference = Double(gain) * Double(meanEnvelope)
            let u = Double(sinPart) * scale + (phaseBias * amplitude + known[index]) * reference
            let v = Double(cosPart) * scale
            let length = (u * u + v * v).squareRoot()
            let (cosTheta, sinTheta) = length > 1e-12 ? (u / length, v / length) : (1.0, 0.0)
            // out += a e (cos(theta) sin(k phase) + sin(theta) cos(k phase))
            var ws = Float(amplitude * cosTheta) * gain, wc = Float(amplitude * sinTheta) * gain
            vDSP_vsmul(s, 1, &ws, &s, 1, vDSP_Length(count))
            vDSP_vsma(c, 1, &wc, s, 1, &s, 1, vDSP_Length(count))
            vDSP_vma(s, 1, envelope, 1, out, 1, &out, 1, vDSP_Length(count))
        }
        return out
    }

    /// The `synth` upper layer: partials 2 to 12 continue the sub's series (`-13 - 4 (k - 2)` dB re the
    /// fundamental), rolled off at 500 Hz and weighted by the complementary crossover, so sub plus body is
    /// one flat series through 160 Hz.
    private static func synthBody(_ note: LofiScore.Note, envelope: [Float], rate: Double) -> [Float] {
        let f0 = frequency(note.midi)
        let amplitudes = (2...12).map { k -> Double in
            let f = f0 * Double(k)
            return pow(10, (-13 - 4 * Double(k - 2)) / 20) / sqrt(1 + pow(f / 500, 4)) * (1 - subWeight(f))
        }
        var out = partials(phase(note, count: envelope.count, rate: rate), first: 2, amplitudes: amplitudes, f0: f0, rate: rate)
        var level = subGain * note.velocity * powf(10, synthBodyGainDB / 20)
        vDSP_vsmul(out, 1, &level, &out, 1, vDSP_Length(out.count))
        vDSP_vmul(out, 1, envelope, 1, &out, 1, vDSP_Length(out.count))
        return out
    }

    /// A sample at the note's pitch from its onset, linear interpolation, at most `count` frames.
    private static func read(_ sample: LofiBassSamples.Sample, midi: Int, count: Int, rate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let speed = sample.rate / rate * pow(2, Double(midi - sample.root) / 12)
        sample.pcm.withUnsafeBufferPointer { pcm in
            out.withUnsafeMutableBufferPointer { o in
                var position = Double(sample.onset)
                let last = pcm.count - 1
                var i = 0
                while i < count {
                    let j = Int(position)
                    guard j < last else { break }
                    let f = Float(position - Double(j))
                    o[i] = pcm[j] + f * (pcm[j + 1] - pcm[j])
                    position += speed
                    i += 1
                }
            }
        }
        return out
    }

    /// 2-pole Butterworth run forward then backward: the zero-phase slope matched to the sub's weight.
    private static func zeroPhase(_ x: inout [Float], _ kind: LofiBiquad.Kind, rate: Double) {
        let count = x.count
        guard count > 0 else { return }
        x.withUnsafeMutableBufferPointer { b in
            var forward = LofiFilterChain([kind], sampleRate: rate)
            forward.process(b.baseAddress!, count: count)
            vDSP_vrvrs(b.baseAddress!, 1, vDSP_Length(count))
            var backward = LofiFilterChain([kind], sampleRate: rate)
            backward.process(b.baseAddress!, count: count)
            vDSP_vrvrs(b.baseAddress!, 1, vDSP_Length(count))
        }
    }

    private static let butterworthQ = 0.707_106_781_186_547_5

    /// The sampled body: the long (or ghost) note at pitch from its onset, no drive, high-passed at the
    /// crossover (zero phase), then the 12 dB per octave low-pass that opens on a strike. Level: its RMS over
    /// the first 250 ms (at the fixed cutoff, after the envelope) sits `bodyUnderSubDB` under the sub's.
    private static func sampledBody(_ note: LofiScore.Note, voice: LofiBassVoice, sub: [Float], envelope: [Float],
                                    clock: LofiClock, samples: LofiBassSamples, sweep: ClosedRange<Double>?,
                                    strike: Double) -> [Float] {
        let count = envelope.count
        let rate = clock.sampleRate
        guard let kit = voice.kit else { return [Float](repeating: 0, count: count) }
        let hash = UInt64(truncatingIfNeeded: note.midi &* 7_919 &+ Int((note.beat * 64).rounded()) &* 104_729)
        let wanted = shape(note.stroke).body
        // The upright has no pitched ghost recordings: its ghost is the long note at ghost velocity.
        let stroke: LofiBassSamples.Stroke = samples.has(kit: kit, stroke: wanted) ? wanted : .long
        guard let sample = samples.sample(kit: kit, stroke: stroke, midi: note.midi, hash: hash) else {
            return [Float](repeating: 0, count: count)
        }
        var body = read(sample, midi: note.midi, count: count, rate: rate)
        zeroPhase(&body, .highpass(hz: crossover, q: butterworthQ), rate: rate)
        zeroPhase(&body, .highpass(hz: bodyLeakHighpass, q: 0.541_196_100_146_197), rate: rate)
        zeroPhase(&body, .highpass(hz: bodyLeakHighpass, q: 1.306_562_964_876_377), rate: rate)
        let cutoff = bodyLowpass(voice)
        // Level: a plucked sample decays (the flatwound long note falls 15 dB in its first half second), so
        // the body is levelled to a steady `bodyUnderSubDB` under the steady sub's RMS: its
        // 50 ms RMS envelope, measured at the fixed cutoff so a strike or a sweep never changes it, is
        // divided out (at most `bodyMaxBoostDB`). The timbre stays the sample's; the strike layer, not the
        // sample's own pluck, makes the attack.
        var probe = body
        probe.withUnsafeMutableBufferPointer { p in
            var lowpass = LofiFilterChain([.lowpass(hz: cutoff, q: butterworthQ), .lowpass(hz: cutoff, q: butterworthQ)],
                                          sampleRate: rate)
            lowpass.process(p.baseAddress!, count: count)
        }
        let target = Float(steadySubRMS(note.midi)) * powf(10, -bodyUnderSubDB(voice) / 20)
        let level = steadyGain(probe, target: target, rate: rate)
        vDSP_vmul(body, 1, level, 1, &body, 1, vDSP_Length(count))
        var velocity = subGain * note.velocity
        vDSP_vsmul(body, 1, &velocity, &body, 1, vDSP_Length(count))
        movingLowpass(&body, base: cutoff, strike: strike, startBeat: note.beat, clock: clock, sweep: sweep)
        // The envelope goes on last, so the body is exactly zero after the release.
        vDSP_vmul(body, 1, envelope, 1, &body, 1, vDSP_Length(count))
        applyRise(&body, frames: max(1, Int((strike == 0 ? plainBodyRise : struckBodyRise) * rate)))
        return body
    }

    /// Per-frame gain that brings `x`'s centred 50 ms RMS to `target`, never above `bodyMaxBoostDB` over
    /// the gain at the loudest point and never boosting what lies 40 dB under that point.
    private static func steadyGain(_ x: [Float], target: Float, rate: Double) -> [Float] {
        let count = x.count
        guard count > 0 else { return [] }
        var square = [Float](repeating: 0, count: count)
        vDSP_vsq(x, 1, &square, 1, vDSP_Length(count))
        var sums = [Double](repeating: 0, count: count + 1)
        var i = 0
        var acc = 0.0
        while i < count { acc += Double(square[i]); i += 1; sums[i] = acc }
        let half = max(1, Int(0.025 * rate))
        var envelope = [Float](repeating: 0, count: count)
        i = 0
        while i < count {
            let lo = max(0, i - half), hi = min(count, i + half)
            envelope[i] = Float(((sums[hi] - sums[lo]) / Double(hi - lo)).squareRoot())
            i += 1
        }
        var loudest: Float = 0
        vDSP_maxv(envelope, 1, &loudest, vDSP_Length(count))
        guard loudest > 1e-9 else { return [Float](repeating: 0, count: count) }
        // Floor: the envelope never reads under its maximum less the boost cap, so nothing is raised more.
        var floor = loudest * powf(10, -bodyMaxBoostDB / 20)
        vDSP_vthr(envelope, 1, &floor, &envelope, 1, vDSP_Length(count))
        var gain = [Float](repeating: 0, count: count)
        var t = target
        vDSP_svdiv(&t, envelope, 1, &gain, 1, vDSP_Length(count))
        return gain
    }

    /// 24 dB per octave low-pass without resonance (two state-variable sections, Q 0.707) whose cutoff is
    /// `base + strikeOpening strike e^(-t / strikeOpenTime)` Hz, the base following the breakdown sweep
    /// across `sweepRange` when there is one. The coefficients follow the cutoff every 16 frames.
    private static func movingLowpass(_ x: inout [Float], base fixed: Double, strike: Double, startBeat: Double,
                                      clock: LofiClock, sweep: ClosedRange<Double>?) {
        let rate = clock.sampleRate
        let k: Float = 2 * 0.707_106_781_186_547_5 // 1 / Q
        var ic1: Float = 0, ic2: Float = 0, jc1: Float = 0, jc2: Float = 0
        let beatFrames = clock.framesPerBeat
        var a1: Float = 0, a2: Float = 0, a3: Float = 0
        x.withUnsafeMutableBufferPointer { b in
            guard let p = b.baseAddress else { return }
            var i = 0
            let count = b.count
            while i < count {
                let t = Double(i) / rate
                var base = fixed
                if let sweep, sweep.upperBound > sweep.lowerBound {
                    let beat = startBeat + Double(i) / beatFrames
                    if sweep.contains(beat) {
                        let u = (beat - sweep.lowerBound) / (sweep.upperBound - sweep.lowerBound)
                        base = sweepRange.lowerBound + (sweepRange.upperBound - sweepRange.lowerBound) * u
                    }
                }
                let cutoff = min(0.45 * rate, base + strikeOpening * strike * exp(-t / strikeOpenTime))
                let g = Float(tan(Double.pi * cutoff / rate))
                a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
                let end = min(count, i + 16)
                while i < end {
                    let v3 = p[i] - ic2
                    let v1 = a1 * ic1 + a2 * v3
                    let v2 = ic2 + a2 * ic1 + a3 * v3
                    ic1 = 2 * v1 - ic1
                    ic2 = 2 * v2 - ic2
                    let w3 = v2 - jc2
                    let w1 = a1 * jc1 + a2 * w3
                    let w2 = jc2 + a2 * jc1 + a3 * w3
                    jc1 = 2 * w1 - jc1
                    jc2 = 2 * w2 - jc2
                    p[i] = w2
                    i += 1
                }
            }
        }
    }

    /// The strike: brightest in its first milliseconds, between the crossover and about 1.2 kHz, exactly
    /// zero from `strikeEnd` on, its peak at `peak`. `flatwound` plucks the flatwound `short` note at pitch;
    /// `upright` is a soft synthesized burst of partials 3 to 6; `synth` partials 2 to 8.
    private static func strikeLayer(_ note: LofiScore.Note, voice: LofiBassVoice, count: Int, rate: Double,
                                    samples: LofiBassSamples, peak: Float) -> [Float] {
        let frames = min(count, Int(strikeEnd(voice) * rate))
        guard frames > 1, peak > 0 else { return [] }
        let f0 = frequency(note.midi)
        var layer: [Float]
        switch voice {
        case .flatwound:
            let hash = UInt64(truncatingIfNeeded: note.midi &* 7_919 &+ Int((note.beat * 64).rounded()) &* 104_729)
            guard let sample = samples.sample(kit: .flatwound, stroke: .short, midi: note.midi, hash: hash) else { return [] }
            layer = read(sample, midi: note.midi, count: frames, rate: rate)
            zeroPhase(&layer, .highpass(hz: strikeHighpass, q: butterworthQ), rate: rate)
            layer.withUnsafeMutableBufferPointer { l in
                var lowpass = LofiFilterChain([.lowpass(hz: strikeLowpass, q: 0.541_196_100_146_197),
                                               .lowpass(hz: strikeLowpass, q: 1.306_562_964_876_377)], sampleRate: rate)
                lowpass.process(l.baseAddress!, count: frames)
            }
        case .upright:
            let amplitudes = (3...6).map { k in strikeWeight(f0 * Double(k)) / Double(k) }
            layer = partials(phase(note, count: frames, rate: rate), first: 3, amplitudes: amplitudes, f0: f0, rate: rate)
        case .synth:
            let amplitudes = (2...8).map { k -> Double in
                let f = f0 * Double(k)
                return (1 - subWeight(f)) * strikeWeight(f)
            }
            layer = partials(phase(note, count: frames, rate: rate), first: 2, amplitudes: amplitudes, f0: f0, rate: rate)
        case .classic:
            return []
        }
        // 1 ms raised-cosine rise, e^(-t / decay), and a raised-cosine fade over the last quarter to zero.
        var decay = [Float](repeating: 0, count: frames)
        var d0: Float = 0, dd = Float(-1 / (strikeDecay(voice) * rate))
        vDSP_vramp(&d0, &dd, &decay, 1, vDSP_Length(frames))
        var n = Int32(frames)
        vvexpf(&decay, decay, &n)
        vDSP_vmul(layer, 1, decay, 1, &layer, 1, vDSP_Length(frames))
        applyRise(&layer, frames: max(1, Int(0.001 * rate)))
        let fade = max(2, frames / 4)
        var u0: Float = 0, du = Float(Double.pi / Double(fade))
        var r = [Float](repeating: 0, count: fade)
        vDSP_vramp(&u0, &du, &r, 1, vDSP_Length(fade))
        var fn = Int32(fade)
        vvcosf(&r, r, &fn)
        var a: Float = 0.5, b: Float = 0.5
        vDSP_vsmsa(r, 1, &a, &b, &r, 1, vDSP_Length(fade))
        layer.withUnsafeMutableBufferPointer { l in
            vDSP_vmul(l.baseAddress! + frames - fade, 1, r, 1, l.baseAddress! + frames - fade, 1, vDSP_Length(fade))
        }
        layer[frames - 1] = 0
        var top: Float = 0
        vDSP_maxmgv(layer, 1, &top, vDSP_Length(frames))
        var gain = top > 1e-9 ? peak / top : 0
        vDSP_vsmul(layer, 1, &gain, &layer, 1, vDSP_Length(frames))
        return layer
    }

    /// The bass branch of the original `LofiSynth.add`, unchanged in types and operation order.
    private static func addClassic(_ note: LofiScore.Note, clock: LofiClock,
                                   left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let start = clock.frame(at: note.beat)
        let span = clock.frame(at: note.length)
        let frequency = 440 * pow(2, Double(note.midi - 69) / 12)
        let rate = clock.sampleRate
        let omega = 2 * Double.pi * frequency / rate
        let attack: Double, release: Double, gain: Float, pan: Float
        (attack, release, gain, pan) = (0.018, 0.31, 0.337, 0)
        let tail = max(1, Int(rate * release))
        let count = min(left.count - start, span + tail)
        guard count > 0 else { return }
        let a = sqrtf(0.5 * (1 - pan)), b = sqrtf(0.5 * (1 + pan))
        let fade = min(count, max(1, Int(rate * 0.06)))
        for i in 0..<count {
            let t = Double(i) / rate
            let phase = Double(i) * omega
            let rise = min(1, t / attack)
            let fall = i < span ? 1 : max(0, 1 - Double(i - span) / Double(tail))
            let edge = min(1, Double(count - 1 - i) / Double(fade))
            let body = sin(phase) + (0.12 + 0.13 * exp(-t * 4)) * sin(2 * phase) + 0.04 * sin(3 * phase)
            let wave = tanh(1.15 * body)
            let value = Float(wave * rise * rise * fall * fall * edge) * gain * note.velocity
            left[start + i] += value * a
            right[start + i] += value * b
        }
    }
}
