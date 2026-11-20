import Accelerate
import Foundation

/// The throw send of the D116 bass voice, frozen (plan bass-tone-redo 2.4): the dub throws keep the sound
/// they had when the bass was rebuilt, so the reverb-echo stem does not change character with the voice.
/// This is the D116 two-layer render (tanh sub with the thump pitch drop, driven sample body high-passed at
/// 180 Hz, velocity low-pass, 1 kHz click) copied unchanged in operations and order. It is used only by
/// `LofiBassThrow`; it is not dead code and not the bass the stem plays (that is `LofiBassVoice`).
nonisolated enum LofiBassThrowSend {
    struct Shape: Sendable {
        /// Raised-cosine rise and release of the voice, seconds.
        let rise: Double, release: Double
        /// Level change across the held part: dB over the whole note (`thump`) plus dB per second (`hold`).
        let decayDBAcrossNote: Double, decayDBPerSecond: Double
        /// The sub starts this many semitones above the note and falls onto it over `dropTime`.
        let dropSemitones: Double, dropTime: Double
        /// Prepared sample articulation of the body.
        let body: LofiBassSamples.Stroke
        /// Hann click at 1 kHz, linear level against the body.
        let click: Double
        /// Attack accent: the level starts `accent` above the sustain and settles with a 40 ms time
        /// constant. It makes the note's strike its loudest moment, so the C-B2 rise is read on the strike
        /// rather than on a later ripple of the low band (a steady note's envelope beats with its harmonics).
        var accent: Double = 0
    }

    static func shape(_ stroke: LofiScore.BassStroke) -> Shape {
        switch stroke {
        case .thump:
            Shape(rise: 0.0015, release: 0.060, decayDBAcrossNote: 10, decayDBPerSecond: 0, dropSemitones: 12,
                  dropTime: 0.008, body: .short, click: 0.1)
        case .walk:
            Shape(rise: 0.003, release: 0.090, decayDBAcrossNote: 0, decayDBPerSecond: 0, dropSemitones: 0,
                  dropTime: 0, body: .long, click: 0, accent: 0.4)
        case .hold:
            Shape(rise: 0.004, release: 0.160, decayDBAcrossNote: 0, decayDBPerSecond: 3, dropSemitones: 0,
                  dropTime: 0, body: .long, click: 0, accent: 0.4)
        case .ghost:
            Shape(rise: 0.003, release: 0.050, decayDBAcrossNote: 0, decayDBPerSecond: 0, dropSemitones: 0,
                  dropTime: 0, body: .ghost, click: 0)
        }
    }

    static let subGain: Float = 0.30
    static let subDrive = 1.2
    static let subHarmonics = (second: 0.20, third: 0.10)
    static let bodyUnderSubDB: Float = 11
    static let bodyHighpass = 180.0
    static func bodyDrive(_ kit: LofiBassSamples.Kit) -> Float { kit == .upright ? 4 : 2 }
    static let bodyMaxBoostDB: Float = 30
    static let slideTime = 0.045

    /// The kit of a thrown note: the D116 per-take rule (one kit per sixteen-bar take, seeded).
    static func kit(seed: UInt64, phrase: Int) -> LofiBassSamples.Kit {
        var take = MusicRNG(seed: seed).fork(UInt64(max(0, phrase) / LofiDrumTake.phraseCount) + 733)
        return take.chance(0.5) ? .upright : .flatwound
    }

    enum Layers: Sendable { case both, sub, body }

    /// One note as a mono buffer that starts on the note's first frame, at most `limit` frames long.
    static func render(_ note: LofiScore.Note, kit: LofiBassSamples.Kit, clock: LofiClock, limit: Int,
                       samples: LofiBassSamples = .bundled, sweep: ClosedRange<Double>? = nil,
                       layers: Layers = .both) -> [Float] {
        let shape = shape(note.stroke)
        let rate = clock.sampleRate
        let span = max(1, clock.frame(at: note.length))
        let tail = max(1, Int(rate * shape.release))
        let count = min(limit, span + tail)
        guard count > 0 else { return [] }
        let envelope = envelope(shape: shape, span: span, tail: tail, count: count, rate: rate)
        let sub = renderSub(note, shape: shape, envelope: envelope, rate: rate)
        if layers == .sub { return sub }
        var body = renderBody(note, kit: kit, shape: shape, count: count, rate: rate, samples: samples)
        // Body level: `bodyUnderSubDB` under the sub's RMS over the sounding note, measured before the
        // velocity low-pass, so a soft note is darker as well as quieter.
        var shaped = [Float](repeating: 0, count: count)
        vDSP_vmul(body, 1, envelope, 1, &shaped, 1, vDSP_Length(count))
        var subRMS: Float = 0, bodyRMS: Float = 0
        vDSP_rmsqv(sub, 1, &subRMS, vDSP_Length(count))
        vDSP_rmsqv(shaped, 1, &bodyRMS, vDSP_Length(count))
        let target = subRMS * powf(10, -bodyUnderSubDB / 20)
        var gain = bodyRMS > 1e-9 ? min(powf(10, bodyMaxBoostDB / 20), target / bodyRMS) : 0
        velocityLowpass(&body, velocity: Double(note.velocity), startBeat: note.beat, clock: clock, sweep: sweep)
        // The envelope goes on last, so the body is exactly zero after the release.
        vDSP_vmul(body, 1, envelope, 1, &body, 1, vDSP_Length(count))
        vDSP_vsmul(body, 1, &gain, &body, 1, vDSP_Length(count))
        if shape.click > 0 {
            // 3 ms Hann click at 1 kHz, 20 dB under the body.
            let clickFrames = min(count, Int(0.003 * rate))
            let amplitude = Float(shape.click) * target * sqrtf(2)
            let omega = 2 * Double.pi * 1_000 / rate
            for i in 0..<clickFrames {
                let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(clickFrames))
                body[i] += amplitude * Float(window * sin(omega * Double(i)))
            }
        }
        if layers == .body { return body }
        var mono = sub
        vDSP_vadd(mono, 1, body, 1, &mono, 1, vDSP_Length(count))
        return mono
    }

    /// Raised-cosine rise, the stroke's sustain shape, raised-cosine release to exactly zero (vectorized).
    private static func envelope(shape: Shape, span: Int, tail: Int, count: Int, rate: Double) -> [Float] {
        var e = [Float](repeating: 0, count: count)
        let spanSeconds = Double(span) / rate
        let hold = min(span, count)
        // Held part: 10^(-dB(t) / 20) = exp(-ln(10) / 20 * rate_dB * t), one vector exp.
        let dbPerFrame = (shape.decayDBAcrossNote / spanSeconds + shape.decayDBPerSecond) / rate
        var start: Float = 0, step = Float(-log(10.0) / 20 * dbPerFrame)
        var n = Int32(hold)
        if hold > 0 {
            vDSP_vramp(&start, &step, &e, 1, vDSP_Length(hold))
            vvexpf(&e, e, &n)
        }
        if shape.accent > 0, hold > 0 {
            // 1 + accent e^(-t / 40 ms), normalized so the sustain keeps its level.
            var a0: Float = 0, da = Float(-1 / (0.040 * rate))
            var accent = [Float](repeating: 0, count: hold)
            vDSP_vramp(&a0, &da, &accent, 1, vDSP_Length(hold))
            var hn = Int32(hold)
            vvexpf(&accent, accent, &hn)
            var scale = Float(shape.accent), one: Float = 1
            vDSP_vsmsa(accent, 1, &scale, &one, &accent, 1, vDSP_Length(hold))
            vDSP_vmul(e, 1, accent, 1, &e, 1, vDSP_Length(hold))
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
        let riseFrames = min(count, max(1, Int(shape.rise * rate)))
        var r0: Float = 0, dr = Float(Double.pi / Double(max(1, Int(shape.rise * rate))))
        var rise = [Float](repeating: 0, count: riseFrames)
        vDSP_vramp(&r0, &dr, &rise, 1, vDSP_Length(riseFrames))
        var rn = Int32(riseFrames)
        vvcosf(&rise, rise, &rn)
        var a: Float = -0.5, b: Float = 0.5
        vDSP_vsmsa(rise, 1, &a, &b, &rise, 1, vDSP_Length(riseFrames))
        vDSP_vmul(e, 1, rise, 1, &e, 1, vDSP_Length(riseFrames))
        return e
    }

    /// Phase-accumulating sine with 2nd and 3rd harmonics through a tanh, zero start phase. The `thump`
    /// drop and the `slide` glide are raised-cosine pitch curves that end exactly on the note. The 3rd
    /// harmonic is in the phase a tanh makes, so the chain's parallel harmonics add to it.
    private static func renderSub(_ note: LofiScore.Note, shape: Shape, envelope: [Float], rate: Double) -> [Float] {
        let count = envelope.count
        let omega = 2 * Double.pi * 440 * pow(2, Double(note.midi - 69) / 12) / rate
        let slide = Double(max(0, note.slide))
        // Phase: the pitch curves accumulated over their first frames, then an exact ramp.
        let bend = min(count, max(shape.dropTime > 0 ? Int(shape.dropTime * rate) + 1 : 0,
                                  slide > 0 ? Int(slideTime * rate) + 1 : 0))
        var phase = [Double](repeating: 0, count: count)
        var acc = 0.0
        for i in 0..<bend {
            phase[i] = acc
            let t = Double(i) / rate
            var semitones = 0.0
            if shape.dropTime > 0, t < shape.dropTime {
                semitones += shape.dropSemitones * (0.5 + 0.5 * cos(Double.pi * t / shape.dropTime))
            }
            if slide > 0, t < slideTime { semitones -= slide * (0.5 + 0.5 * cos(Double.pi * t / slideTime)) }
            acc += semitones == 0 ? omega : omega * pow(2, semitones / 12)
        }
        if bend < count {
            var base = acc, step = omega
            phase.withUnsafeMutableBufferPointer { vDSP_vrampD(&base, &step, $0.baseAddress! + bend, 1, vDSP_Length(count - bend)) }
        }
        // Reduce to [0, 2 pi) in double precision, then to float.
        var tau = [Double](repeating: 2 * Double.pi, count: count)
        var n = Int32(count)
        vvremainder(&tau, phase, tau, &n)
        var p1 = [Float](repeating: 0, count: count)
        vDSP_vdpsp(tau, 1, &p1, 1, vDSP_Length(count))
        var p2 = p1, p3 = p1
        var two: Float = 2, three: Float = 3
        vDSP_vsmul(p1, 1, &two, &p2, 1, vDSP_Length(count))
        vDSP_vsmul(p1, 1, &three, &p3, 1, vDSP_Length(count))
        vvsinf(&p1, p1, &n)
        vvsinf(&p2, p2, &n)
        vvsinf(&p3, p3, &n)
        var second = Float(subHarmonics.second), third = Float(-subHarmonics.third)
        vDSP_vsma(p2, 1, &second, p1, 1, &p1, 1, vDSP_Length(count))
        vDSP_vsma(p3, 1, &third, p1, 1, &p1, 1, vDSP_Length(count))
        var drive = Float(subDrive)
        vDSP_vsmul(p1, 1, &drive, &p1, 1, vDSP_Length(count))
        vvtanhf(&p1, p1, &n)
        var level = Float(1 / tanh(subDrive)) * subGain * note.velocity
        vDSP_vsmul(p1, 1, &level, &p1, 1, vDSP_Length(count))
        vDSP_vmul(p1, 1, envelope, 1, &p1, 1, vDSP_Length(count))
        return p1
    }

    /// The sampled body at the note's pitch, driven, then high-passed at 150 Hz (24 dB per octave).
    /// Without a sample: the bright 2nd to 4th harmonic burst of the former `pluck`, fading over 90 ms.
    private static func renderBody(_ note: LofiScore.Note, kit: LofiBassSamples.Kit, shape: Shape, count: Int,
                                   rate: Double, samples: LofiBassSamples) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let hash = UInt64(truncatingIfNeeded: note.midi &* 7_919 &+ Int((note.beat * 64).rounded()) &* 104_729)
        // Upright has no ghost recordings (they are unpitched): its ghost uses the short finger note.
        let stroke: LofiBassSamples.Stroke = samples.has(kit: kit, stroke: shape.body) ? shape.body : .short
        if let sample = samples.sample(kit: kit, stroke: stroke, midi: note.midi, hash: hash) {
            let speed = sample.rate / rate * pow(2, Double(note.midi - sample.root) / 12)
            let drive = bodyDrive(kit)
            var peak: Float = 0
            vDSP_maxmgv(sample.pcm, 1, &peak, vDSP_Length(sample.pcm.count))
            let bias: Float = 0.05
            var used = 0
            sample.pcm.withUnsafeBufferPointer { pcm in
                out.withUnsafeMutableBufferPointer { o in
                    var position = 0.0
                    let last = pcm.count - 1
                    var i = 0
                    while i < count {
                        let j = Int(position)
                        guard j < last else { break }
                        let f = Float(position - Double(j))
                        o[i] = pcm[j] + f * (pcm[j + 1] - pcm[j])
                        position += speed
                        used = i + 1
                        i += 1
                    }
                }
            }
            if used > 0 {
                // y = (tanh(drive (x / peak + bias)) - tanh(drive bias)) / tanh(drive). A little bias adds
                // even harmonics to the odd ones of the tanh.
                var a = drive / max(1e-6, peak), b = drive * bias, n = Int32(used)
                vDSP_vsmsa(out, 1, &a, &b, &out, 1, vDSP_Length(used))
                vvtanhf(&out, out, &n)
                var c = -tanhf(drive * bias), scale = 1 / tanhf(drive)
                vDSP_vsadd(out, 1, &c, &out, 1, vDSP_Length(used))
                vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(used))
            }
        } else {
            let omega = 2 * Double.pi * 440 * pow(2, Double(note.midi - 69) / 12) / rate
            let tau = 0.09 / log(100.0)
            for i in 0..<count {
                let t = Double(i) / rate
                guard t < 0.135 else { break }
                let p = omega * Double(i)
                out[i] = Float(exp(-t / tau) * (0.5 * sin(2 * p) + 0.35 * sin(3 * p) + 0.25 * sin(4 * p)))
            }
        }
        let q = (0.541_196_100_146_197, 1.306_562_964_876_377)
        var highpass = LofiFilterChain([.highpass(hz: bodyHighpass, q: q.0), .highpass(hz: bodyHighpass, q: q.1)],
                                       sampleRate: rate)
        out.withUnsafeMutableBufferPointer { highpass.process($0.baseAddress!, count: count) }
        return out
    }

    /// 12 dB per octave low-pass without resonance (state-variable, Q 0.707) whose cutoff is
    /// `base + 1100 v e^(-t / 0.04)` Hz, base `650 + 300 v` or the breakdown sweep. The coefficients
    /// follow the cutoff every 16 frames.
    private static func velocityLowpass(_ x: inout [Float], velocity v: Double, startBeat: Double, clock: LofiClock,
                                        sweep: ClosedRange<Double>?) {
        let rate = clock.sampleRate
        let k: Float = 2 * 0.707_106_781_186_547_5 // 1 / Q
        var ic1: Float = 0, ic2: Float = 0
        let normal = 650 + 300 * v
        let beatFrames = clock.framesPerBeat
        var a1: Float = 0, a2: Float = 0, a3: Float = 0
        x.withUnsafeMutableBufferPointer { b in
            guard let p = b.baseAddress else { return }
            var i = 0
            let count = b.count
            while i < count {
                let t = Double(i) / rate
                var base = normal
                if let sweep, sweep.upperBound > sweep.lowerBound {
                    let beat = startBeat + Double(i) / beatFrames
                    if sweep.contains(beat) {
                        base = 250 + 650 * (beat - sweep.lowerBound) / (sweep.upperBound - sweep.lowerBound)
                    }
                }
                let cutoff = min(0.45 * rate, base + 1_100 * v * exp(-t / 0.04))
                let g = Float(tan(Double.pi * cutoff / rate))
                a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
                let end = min(count, i + 16)
                while i < end {
                    let v3 = p[i] - ic2
                    let v1 = a1 * ic1 + a2 * v3
                    let v2 = ic2 + a2 * ic1 + a3 * v3
                    ic1 = 2 * v1 - ic1
                    ic2 = 2 * v2 - ic2
                    p[i] = v2
                    i += 1
                }
            }
        }
    }
}
