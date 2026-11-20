import Accelerate
import Foundation

/// The held chord voice (D117): a granular "frozen" sustain of the phrase program's own sample, so the
/// pad stays in the lead's acoustic family but swells in and holds without re-attacks.
///
/// Overlapping Hann grains read the sample's body (0.18 to 1.4 s after its onset). Each grain starts a
/// whole number of the note's periods away from the stream's phase reference, near a read position that
/// wanders slowly through the region, so overlapping grains add in phase on the fundamental instead of
/// beating; each is normalized to the region's median grain level and a slow level hold keeps the
/// stream from pulsing. Left and right are independent grain streams on one phase reference. Offline only (phrase render), deterministic for a seed.
nonisolated enum LofiPadVoice {
    struct Settings: Sendable, Equatable {
        /// Raised-cosine swell and release (s). A return's pad swells in more slowly.
        var attack = 0.30
        var returnAttack = 0.45
        var release = LofiScore.padReleaseSeconds
        /// Grain length 420 ms plus or minus 60, hop a third of a grain plus or minus 15 percent.
        var grainSeconds = 0.42
        var grainJitterSeconds = 0.06
        var hopShare = 1.0 / 3
        var hopJitter = 0.15
        /// Source region after the sample's onset (s): past the attack, inside the body.
        var regionStart = 0.18
        var regionEnd = 1.4
        /// ...or earlier, where the sample has decayed this far under its level at the region's start.
        var regionDecayDB = 15.0
        /// Left against right detune. 0 (plan start 5): both streams share one phase reference, so at pitch
        /// their fundamentals stay in phase and the pad chain's mono fold below 300 Hz is clean; at plus and
        /// minus 5 cents the folded lows beat at 1 to 3 Hz, 9 to 30 dB deep (measured, 20 November 2026).
        /// The width comes from the independent streams' upper partials and read positions.
        var detuneCents = 0.0
        /// Slow tremolo, plus or minus 0.8 dB at 0.3 Hz, with a different phase per voice.
        var tremoloHz = 0.3
        var tremoloDB: Float = 0.8
        /// Two-pole low-pass in the voice.
        /// 2.0 kHz (plan start 2.4): at 2.4 a two-voice pad read brighter than a dark upright lead (spectral
        /// centroid 510 against 440 Hz).
        var lowpassHz = 2_000.0
        /// A gentle high-pass in the voice clears the samples' own body noise under the notes (a grand's
        /// region holds up to -17 dB of it below 150 Hz) before the pad chain's 220 Hz high-pass.
        var highpassHz = 150.0
        /// Linear output level at velocity 1 before the phrase's pad gain (the level is matched per phrase).
        var gain: Float = 0.5
        /// Every grain stream is brought to this RMS (median grain level of its region), so a quickly
        /// decaying pluck and a long piano note start the pad at the same level.
        var grainLevel = 0.1
        /// Smoothing of the stream's level hold (`holdLevel`).
        var levelHoldSeconds = 0.1
        /// The send's lift into the phrase edge (see `add`).
        var throwGain: Float = 2.5
        var throwSeconds = 1.5
        static let standard = Settings()
    }

    /// One rendered pad note from its start frame: the dry voice and its send (before `note.send`).
    struct Voice {
        var left: [Float]
        var right: [Float]
        var sendLeft: [Float]
        var sendRight: [Float]
        let start: Int
    }

    /// Adds one held note to `out` and its send to `send`, from the note's beat, holding to its end, then
    /// releasing. The release always ends before `limit` (the phrase edge): the hold is shortened if
    /// needed, so the stem is exactly zero at both edges. The send is the dry pad at `note.send`, except
    /// that it does not release with the dry voice: it holds through the release, rising by `throwGain`
    /// over the last `throwSeconds`, and closes in the last 30 ms, so the room carries the chord across
    /// the dry breath at the phrase edge (plan 3.7).
    static func add(_ note: LofiScore.Note, sample: LofiSampleBank.Sample?, preset: LofiPreset, clock: LofiClock,
                    attack: Double, voice: Int, seed: UInt64, limit: Int, settings: Settings = .standard,
                    into out: inout (left: [Float], right: [Float]), send: inout (left: [Float], right: [Float])) {
        guard let tone = render(note, sample: sample, preset: preset, clock: clock, attack: attack, voice: voice,
                                seed: seed, limit: min(limit, out.left.count), settings: settings) else { return }
        let count = vDSP_Length(tone.left.count)
        func accumulate(_ source: [Float], _ target: inout [Float], scale: Float) {
            var scale = scale
            target.withUnsafeMutableBufferPointer { target in
                let base = target.baseAddress! + tone.start
                vDSP_vsma(source, 1, &scale, base, 1, base, 1, count)
            }
        }
        accumulate(tone.left, &out.left, scale: 1)
        accumulate(tone.right, &out.right, scale: 1)
        accumulate(tone.sendLeft, &send.left, scale: note.send)
        accumulate(tone.sendRight, &send.right, scale: note.send)
    }

    /// The note's voice from its start frame, or nil when nothing sounds before `limit`.
    static func render(_ note: LofiScore.Note, sample: LofiSampleBank.Sample?, preset: LofiPreset, clock: LofiClock,
                       attack: Double, voice: Int, seed: UInt64, limit: Int, settings: Settings = .standard,
                       tremolo: Bool = true) -> Voice? {
        let rate = clock.sampleRate
        let start = max(0, clock.frame(at: note.beat))
        let releaseFrames = max(1, Int(settings.release * rate))
        let holdEnd = min(clock.frame(at: note.beat + note.length), limit - releaseFrames - 1)
        guard holdEnd > start else { return nil }
        let count = holdEnd - start + releaseFrames
        var rng = MusicRNG(seed: seed).fork(UInt64(voice) + 1_717)
        let detune = pow(2, settings.detuneCents / 1_200)
        var left: [Float], right: [Float]
        if let sample, let streams = grainStreams(sample, midi: note.midi, count: count, rate: rate,
                                                  detune: detune, settings: settings, rng: &rng) {
            (left, right) = streams
        } else {
            left = LofiSynth.padTone(midi: note.midi, count: count, rate: rate, detune: detune)
            right = LofiSynth.padTone(midi: note.midi, count: count, rate: rate, detune: 1 / detune)
        }
        // Envelope (raised-cosine swell and release, exact zero at both ends) with the tremolo; the send's
        // envelope holds through the release instead (see `add`).
        let attackFrames = max(1, min(holdEnd - start, Int(attack * rate)))
        let hold = holdEnd - start
        let phase = Double(voice) * 2.1 + Double(rng.unit()) * 0.6
        let depth = tremolo ? Double(settings.tremoloDB) / 20 * log(10) : 0
        let omega = 2 * Double.pi * settings.tremoloHz / rate
        // The grain streams hold a fixed level, so the program's sample gain is not applied again.
        let level = note.velocity * settings.gain
        let throwFrames = max(1, Int(settings.throwSeconds * rate)), close = max(1, Int(0.03 * rate))
        // Vector form (the render runs unoptimized in Debug): raised-cosine segments and the tremolo.
        var envelope = [Float](repeating: 1, count: count), sendEnvelope = envelope
        func raisedCosine(_ x: inout [Float], from start: Int, count n: Int, rising: Bool) {
            guard n > 0, start >= 0, start + n <= x.count else { return }
            var a: Float = 0, step = Float.pi / Float(n), half: Float = 0.5, sign: Float = rising ? -0.5 : 0.5
            var segment = [Float](repeating: 0, count: n)
            vDSP_vramp(&a, &step, &segment, 1, vDSP_Length(n))
            var length = Int32(n)
            vvcosf(&segment, segment, &length)
            vDSP_vsmsa(segment, 1, &sign, &half, &segment, 1, vDSP_Length(n))
            x.withUnsafeMutableBufferPointer { x in
                vDSP_vmul(x.baseAddress! + start, 1, segment, 1, x.baseAddress! + start, 1, vDSP_Length(n))
            }
        }
        raisedCosine(&envelope, from: 0, count: attackFrames, rising: true)
        raisedCosine(&sendEnvelope, from: 0, count: attackFrames, rising: true)
        raisedCosine(&envelope, from: hold, count: count - hold, rising: false)
        // The send's lift over the last `throwSeconds` of the hold, kept through the release.
        let liftStart = max(attackFrames, hold - throwFrames)
        if hold > liftStart {
            var lift = [Float](repeating: 1, count: hold - liftStart)
            raisedCosine(&lift, from: 0, count: lift.count, rising: true)
            var gain = settings.throwGain - 1, one: Float = 1
            vDSP_vsmsa(lift, 1, &gain, &one, &lift, 1, vDSP_Length(lift.count))
            sendEnvelope.withUnsafeMutableBufferPointer { e in
                vDSP_vmul(e.baseAddress! + liftStart, 1, lift, 1, e.baseAddress! + liftStart, 1, vDSP_Length(lift.count))
                var top = settings.throwGain
                vDSP_vsmul(e.baseAddress! + hold, 1, &top, e.baseAddress! + hold, 1, vDSP_Length(count - hold))
            }
        }
        let closing = min(close, count)
        var down: Float = 1, fall = -1 / Float(closing)
        var ramp = [Float](repeating: 0, count: closing)
        vDSP_vramp(&down, &fall, &ramp, 1, vDSP_Length(closing))
        sendEnvelope.withUnsafeMutableBufferPointer { e in
            vDSP_vmul(e.baseAddress! + count - closing, 1, ramp, 1, e.baseAddress! + count - closing, 1, vDSP_Length(closing))
        }
        var tremoloCurve = [Float](repeating: 0, count: count)
        var start0 = Float(phase), step = Float(omega), length = Int32(count)
        vDSP_vramp(&start0, &step, &tremoloCurve, 1, vDSP_Length(count))
        vvsinf(&tremoloCurve, tremoloCurve, &length)
        var scaled = Float(depth), levelValue = level
        vDSP_vsmul(tremoloCurve, 1, &scaled, &tremoloCurve, 1, vDSP_Length(count))
        vvexpf(&tremoloCurve, tremoloCurve, &length)
        vDSP_vsmul(tremoloCurve, 1, &levelValue, &tremoloCurve, 1, vDSP_Length(count))
        vDSP_vmul(envelope, 1, tremoloCurve, 1, &envelope, 1, vDSP_Length(count))
        vDSP_vmul(sendEnvelope, 1, tremoloCurve, 1, &sendEnvelope, 1, vDSP_Length(count))
        envelope[count - 1] = 0
        envelope[0] = 0
        sendEnvelope[count - 1] = 0
        sendEnvelope[0] = 0
        var lowpass = LofiFilterChain([.highpass(hz: settings.highpassHz, q: LofiStemChains.butterworthQ),
                                       .lowpass(hz: settings.lowpassHz, q: LofiStemChains.butterworthQ)],
                                      sampleRate: rate)
        lowpass.process(left: &left, right: &right)
        var sendLeft = left, sendRight = right
        vDSP_vmul(left, 1, envelope, 1, &left, 1, vDSP_Length(count))
        vDSP_vmul(right, 1, envelope, 1, &right, 1, vDSP_Length(count))
        vDSP_vmul(sendLeft, 1, sendEnvelope, 1, &sendLeft, 1, vDSP_Length(count))
        vDSP_vmul(sendRight, 1, sendEnvelope, 1, &sendRight, 1, vDSP_Length(count))
        return Voice(left: left, right: right, sendLeft: sendLeft, sendRight: sendRight, start: start)
    }

    // MARK: Grains

    /// Two independent grain streams (left sharp and right flat by `detune`), or nil when the sample is too
    /// short to hold a grain inside the region.
    private static func grainStreams(_ sample: LofiSampleBank.Sample, midi: Int, count: Int, rate: Double,
                                     detune: Double, settings: Settings,
                                     rng: inout MusicRNG) -> (left: [Float], right: [Float])? {
        let source = sample.rate
        let pcm = sample.pcm
        let speed = source / rate * pow(2, Double(midi - sample.recordedRoot) / 12)
        let guess = source / (440 * pow(2, Double(sample.recordedRoot - 69) / 12))
        var settings = settings
        var lo = Int(settings.regionStart * source)
        // Running energy for the region's decay limit and the per-grain level.
        var squares = [Double](repeating: 0, count: pcm.count + 1)
        squares.withUnsafeMutableBufferPointer { vDSP_vspdp(pcm, 1, $0.baseAddress! + 1, 1, vDSP_Length(pcm.count)) }
        vDSP_vsqD(squares, 1, &squares, 1, vDSP_Length(squares.count))
        var energy = [Double](repeating: 0, count: pcm.count + 1)
        var unit = 1.0
        vDSP_vrsumD(squares, 1, &unit, &energy, 1, vDSP_Length(squares.count))
        func rms(_ a: Double, _ span: Double) -> Double {
            let i = max(0, Int(a)), j = min(pcm.count, Int(a + span))
            return j > i ? ((energy[j] - energy[i]) / Double(j - i)).squareRoot() : 0
        }
        // The region ends where the sample has decayed `regionDecayDB` under its level at the region's
        // start, so a quickly decaying pluck lends only its sounding body (the grain level evens the rest).
        let step = 0.05 * source
        let reference = rms(Double(lo), step) * pow(10, -settings.regionDecayDB / 20)
        var hi = min(Int(settings.regionEnd * source), pcm.count - 2)
        while hi > lo + Int(4 * step), rms(Double(hi) - step, step) < reference { hi -= Int(step / 2) }
        func fits() -> Bool {
            let longest = (settings.grainSeconds + settings.grainJitterSeconds) * rate * speed * detune
            return hi - lo > Int(longest + 2 * guess) + 4
        }
        // Short plucked samples (under about 1 s): start the region earlier and shorten the grains, down
        // to 150 ms, before giving up on the sample.
        if !fits() {
            lo = Int(min(settings.regionStart, 0.08) * source)
            let room = (Double(hi - lo) - 2 * guess - 8) / (rate * speed * detune)
            settings.grainSeconds = min(settings.grainSeconds, room - settings.grainJitterSeconds * 0.5)
            settings.grainJitterSeconds *= 0.5
            guard settings.grainSeconds >= 0.15, fits() else { return nil }
        }
        let measured = Self.period(pcm, lo: lo, hi: hi, guess: guess)
        let period = abs(measured / guess - 1) < 0.03 ? measured : guess
        let nominal = settings.grainSeconds * rate * speed
        let probes = (0..<24).map { k in rms(Double(lo) + Double(k) / 23 * (Double(hi) - nominal - Double(lo)), nominal) }
        let median = probes.sorted()[probes.count / 2]
        guard median > 1e-7 else { return nil }
        var leftRNG = rng.fork(1), rightRNG = rng.fork(2)
        var left = stream(pcm, speed: speed * detune, count: count, rate: rate, lo: lo, hi: hi, period: period,
                          median: median, rms: rms, settings: settings, rng: &leftRNG)
        var right = stream(pcm, speed: speed / detune, count: count, rate: rate, lo: lo, hi: hi, period: period,
                           median: median, rms: rms, settings: settings, rng: &rightRNG)
        holdLevel(&left, rate: rate, target: Float(settings.grainLevel), settings: settings)
        holdLevel(&right, rate: rate, target: Float(settings.grainLevel), settings: settings)
        return (left, right)
    }

    /// A slow level hold on a grain stream: 25 ms RMS blocks, smoothed over `levelHoldSeconds`, divided out
    /// toward `target`. The grains still overlap partly out of phase on the upper partials and the read
    /// position wanders through a decaying sample; the hold keeps that from pulsing (3 to 5 dB peak to
    /// peak in 100 ms windows without it, under 1 dB with it).
    private static func holdLevel(_ x: inout [Float], rate: Double, target: Float, settings: Settings) {
        let hop = max(1, Int(0.025 * rate))
        let blocks = x.count / hop
        guard blocks > 1 else { return }
        var envelope = [Float](repeating: 0, count: blocks)
        x.withUnsafeBufferPointer { x in
            for b in 0..<blocks {
                var power: Float = 0
                vDSP_measqv(x.baseAddress! + b * hop, 1, &power, vDSP_Length(hop))
                envelope[b] = power.squareRoot()
            }
        }
        let width = max(1, Int(settings.levelHoldSeconds / 0.025))
        var smooth = [Float](repeating: 0, count: blocks)
        for b in 0..<blocks {
            let a = max(0, b - width / 2), z = min(blocks, a + width)
            var sum: Float = 0
            for k in a..<z { sum += envelope[k] }
            smooth[b] = sum / Float(z - a)
        }
        let floor = target * 0.05
        var gains = smooth.map { target / max($0, floor) }
        // Linear interpolation between block centres (vector form).
        var positions = [Float](repeating: 0, count: x.count)
        var first: Float = -0.5, step = 1 / Float(hop), low: Float = 0, high = Float(blocks - 1) - 0.0001
        vDSP_vramp(&first, &step, &positions, 1, vDSP_Length(x.count))
        vDSP_vclip(positions, 1, &low, &high, &positions, 1, vDSP_Length(x.count))
        gains.append(gains[blocks - 1])
        var curve = [Float](repeating: 0, count: x.count)
        vDSP_vlint(gains, positions, 1, &curve, 1, vDSP_Length(x.count), vDSP_Length(gains.count))
        vDSP_vmul(x, 1, curve, 1, &x, 1, vDSP_Length(x.count))
    }

    private static func stream(_ pcm: [Float], speed: Double, count: Int, rate: Double, lo: Int, hi: Int,
                               period: Double, median: Double, rms: (Double, Double) -> Double,
                               settings: Settings, rng: inout MusicRNG) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        // Hann grains overlapping at a third of their length sum to 1.5 on a coherent fundamental.
        let overlap = Float(settings.hopShare / 0.5)
        var t = -Int(settings.grainSeconds * rate * 0.67)
        // The read position wanders slowly through the region (two slow cycles with seeded phases), so
        // overlapping grains come from nearby source and stay coherent while the timbre keeps moving.
        let cycles = (rng.range(0...(2 * Double.pi)), rng.range(0...(2 * Double.pi)))
        // Grain lengths are kept to whole 512-frame steps so their Hann windows can be reused; scratch
        // buffers are allocated once (the render runs unoptimized in Debug).
        let longest = Int((settings.grainSeconds + settings.grainJitterSeconds) * rate) + 1_024
        var positions = [Float](repeating: 0, count: longest), grain = positions
        var windows: [Int: [Float]] = [:]
        pcm.withUnsafeBufferPointer { pcm in
            out.withUnsafeMutableBufferPointer { out in
                while t < count {
                    let raw = (settings.grainSeconds + settings.grainJitterSeconds * Double(rng.rangeF(-1...1))) * rate
                    let length = max(512, Int((raw / 512).rounded()) * 512)
                    let span = Double(length) * speed
                    // Phase reference: a grain placed at output frame t reads from lo + t * speed plus a
                    // whole number of periods, so every grain agrees in phase where they overlap.
                    let base = Double(lo) + Double(t) * speed
                    let kLow = Int(ceil((Double(lo) - base) / period))
                    let kHigh = Int(floor((Double(hi) - span - base) / period))
                    let seconds = Double(t) / rate
                    let wander = 0.5 + 0.3 * sin(2 * Double.pi * seconds / 7.3 + cycles.0)
                        + 0.2 * sin(2 * Double.pi * seconds / 11.9 + cycles.1)
                    let centre = Double(lo) + wander * max(0, Double(hi) - span - Double(lo))
                    let near = Int(((centre - base) / period).rounded()) + rng.int(-2...2)
                    let k = kHigh >= kLow ? min(kHigh, max(kLow, near)) : kLow
                    let from = base + Double(k) * period
                    let level = rms(from, span)
                    let gain = Float(min(4, max(0.25, median / max(level, 1e-9)))) * overlap
                    let first = max(0, -t), last = min(length, count - t)
                    if last > first, from >= 0, from + span < Double(pcm.count - 1) {
                        let n = last - first
                        let window = windows[length] ?? {
                            var w = [Float](repeating: 0, count: length)
                            vDSP_hann_window(&w, vDSP_Length(length), Int32(vDSP_HANN_DENORM))
                            windows[length] = w
                            return w
                        }()
                        var a = Float(from + Double(first) * speed), step = Float(speed)
                        vDSP_vramp(&a, &step, &positions, 1, vDSP_Length(n))
                        vDSP_vlint(pcm.baseAddress!, positions, 1, &grain, 1, vDSP_Length(n), vDSP_Length(pcm.count))
                        window.withUnsafeBufferPointer { w in
                            vDSP_vmul(grain, 1, w.baseAddress! + first, 1, &grain, 1, vDSP_Length(n))
                        }
                        var g = gain
                        let target = out.baseAddress! + t + first
                        vDSP_vsma(grain, 1, &g, target, 1, target, 1, vDSP_Length(n))
                    }
                    let hop = Double(length) * settings.hopShare * (1 + settings.hopJitter * Double(rng.rangeF(-1...1)))
                    t += max(16, Int(hop))
                }
            }
        }
        return out
    }

    /// The sample's period in source frames near `guess`, refined by normalized autocorrelation over 1,
    /// 8 and 32 periods. Any whole multiple of the true period also keeps the grains in phase.
    static func period(_ pcm: [Float], lo: Int, hi: Int, guess: Double) -> Double {
        var period = guess
        pcm.withUnsafeBufferPointer { x in
            guard let x = x.baseAddress else { return }
            for (periods, tolerance) in [(1.0, 0.03), (8.0, 0.006), (32.0, 0.0015)] {
                let centre = period * periods
                let lowLag = max(1, Int(centre * (1 - tolerance))), highLag = Int(centre * (1 + tolerance)) + 1
                let window = min(8_192, hi - lo - highLag - 1)
                guard window > 512, highLag > lowLag + 1 else { break }
                var e0: Float = 0
                vDSP_svesq(x + lo, 1, &e0, vDSP_Length(window))
                var scores: [Float] = []
                for lag in lowLag...highLag {
                    var dot: Float = 0, e1: Float = 0
                    vDSP_dotpr(x + lo, 1, x + lo + lag, 1, &dot, vDSP_Length(window))
                    vDSP_svesq(x + lo + lag, 1, &e1, vDSP_Length(window))
                    scores.append(dot / max(1e-12, (e0 * e1).squareRoot()))
                }
                guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { break }
                var offset = 0.0
                if best > 0, best + 1 < scores.count {
                    let a = Double(scores[best - 1]), b = Double(scores[best]), c = Double(scores[best + 1])
                    let curvature = a - 2 * b + c
                    if curvature < 0 { offset = 0.5 * (a - c) / curvature }
                }
                period = (Double(lowLag + best) + offset) / periods
            }
        }
        return period
    }
}
