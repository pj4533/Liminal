import Accelerate
import Foundation

/// One drum hit in a full take, in take frames. `attackFrame` is where the hit starts to sound,
/// `peakFrame` is the loudest sample of its band. AJ Hall's audio is never moved by these.
nonisolated struct LofiDrumLandmark: Sendable, Equatable {
    enum Kind: Int, Sendable, CaseIterable { case kick, snare, hat, other }
    let kind: Kind
    let attackFrame: Int
    let peakFrame: Int
    /// Band peak relative to the take's typical hit of the same kind, 0...1.
    let strength: Float
    /// How clearly the spectrum after the attack matches `kind`, 0...1.
    let confidence: Float
    /// Kicks: where the 40-160 Hz body reaches half its amplitude (`LofiDrumLandmarks.lowBandRise`),
    /// 7 to 15 ms after the broadband `attackFrame` on AJ Hall's takes. The bass aligns its own low-band
    /// rise to this frame. Other kinds, and kicks without a measurable body, use `attackFrame`.
    let lowRiseFrame: Int

    init(kind: Kind, attackFrame: Int, peakFrame: Int, strength: Float, confidence: Float, lowRiseFrame: Int? = nil) {
        self.kind = kind
        self.attackFrame = attackFrame
        self.peakFrame = peakFrame
        self.strength = strength
        self.confidence = confidence
        self.lowRiseFrame = lowRiseFrame ?? attackFrame
    }
}

/// Multiband superflux onset detector for full drum takes. It runs once per take, off the audio
/// thread, on the resampled buffer before the splice taper. Every band picks its own peaks
/// before merging, so a quiet hat under a loud kick survives. Attacks are refined in the time
/// domain with zero-phase band filters, so the stored frame has no filter or window delay.
nonisolated enum LofiDrumLandmarks {
    struct Band: Sendable {
        let low: Double, high: Double
        /// Minimum distance between two peaks of this band, in seconds.
        let gap: Double
    }

    enum Constants {
        /// Window length at 44.1 and 48 kHz; lower rates keep about the same duration.
        static let window = 1024
        static let hopDivisor = 8
        static let compression: Float = 300
        static let kick = Band(low: 30, high: 150, gap: 0.050)
        static let snareBody = Band(low: 150, high: 3_000, gap: 0.060)
        static let crack = Band(low: 3_000, high: 8_000, gap: 0.060)
        static let hat = Band(low: 6_000, high: 16_000, gap: 0.025)
        /// Adaptive threshold: local median over `medianSpan` seconds times lambda, plus delta
        /// times the band's largest novelty.
        static let medianSpan = 0.15
        static let lambda: Float = 1.5
        static let delta: Float = 0.05
        /// Frames on each side that a novelty peak must dominate.
        static let peakRadius = 3
        /// Attack is where the band envelope crosses this share of its rise above the local floor.
        static let attackShare: Float = 0.15
        /// Hits of different bands closer than this belong to one physical event.
        static let coincidence = 0.020
        /// Classification window after the attack. Longer than a hat needs because a kick's low
        /// body builds for 20 to 40 ms after its click; in 30 ms many real kicks still read as snares.
        static let featureSpan = 0.060
        static let kickFraction: Float = 0.6
        /// Below this low-band share a hit above the kick band is a snare; above it, a kick's click.
        static let clickFraction: Float = 0.5
        /// A kick without a coincident click must rise this far above the `freshWindow` before it.
        /// A low swell inside a ringing kick, with no broadband transient, is beating, not a hit.
        static let freshRise: Float = 2
        static let freshWindow = 0.060
        /// Clicks and snares must reach this share of what their band held just before, so ripples
        /// in a decay are not new hits while a double or a flam still is.
        static let reattack: Float = 0.5
        /// How far a kick's click may precede the onset of its low body.
        static let clickLead = 0.045
        static let hatFraction: Float = 0.6
        static let hatDecay = 0.15
    }

    private enum Role: Int { case kick, snareBody, crack, hat }

    private struct Candidate {
        let role: Role
        let attack: Int
        let peak: Int
        let amplitude: Float
        /// Largest band level in the `freshWindow` before the onset.
        let prior: Float
        let decay: Double
    }

    private struct Features {
        let low: Float, mid: Float, upper: Float, air: Float
        var total: Float { low + mid + upper + air }
        var lowFraction: Float { total > 0 ? low / total : 0 }
        /// Share of 6-16 kHz among everything above the kick band.
        var airFraction: Float { let above = mid + upper + air; return above > 0 ? air / above : 0 }
        var broadFraction: Float { total > 0 ? (mid + upper + air) / total : 0 }
        /// Share of 3-16 kHz noise among everything above the kick band.
        var crackFraction: Float { let above = mid + upper + air; return above > 0 ? (upper + air) / above : 0 }
    }

    static func detect(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int,
                       sampleRate: Double) throws -> [LofiDrumLandmark] {
        guard count > 0, sampleRate > 0 else { return [] }
        var mono = [Float](repeating: 0, count: count)
        vDSP_vadd(left, 1, right, 1, &mono, 1, vDSP_Length(count))
        var half: Float = 0.5
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(count))
        return try mono.withUnsafeBufferPointer { try detect(mono: $0, sampleRate: sampleRate) }
    }

    static func detect(mono: UnsafeBufferPointer<Float>, sampleRate: Double) throws -> [LofiDrumLandmark] {
        let count = mono.count
        guard count > 0, let x = mono.baseAddress else { return [] }
        let size = sampleRate >= 32_000 ? Constants.window
            : max(64, 1 << Int((log2(sampleRate * Double(Constants.window) / 44_100)).rounded()))
        let hop = size / Constants.hopDivisor
        let roles: [(Role, Band)] = [(.kick, Constants.kick), (.snareBody, Constants.snareBody),
                                     (.crack, Constants.crack), (.hat, Constants.hat)]
        let novelty = try spectralFlux(x, count: count, size: size, hop: hop, sampleRate: sampleRate,
                                       bands: roles.map(\.1))
        var candidates: [Candidate] = []
        for (index, (role, band)) in roles.enumerated() {
            guard let curve = novelty[index] else { continue }
            let peaks = try pick(curve, hop: hop, sampleRate: sampleRate, gap: band.gap)
            let refiner = Refiner(role: role, sampleRate: sampleRate)
            defer { refiner.destroy() }
            for (i, frame) in peaks.enumerated() {
                if i.isMultiple(of: 64) { try Task.checkCancellation() }
                if let hit = refiner.refine(x, count: count, windowEnd: frame * hop, size: size) {
                    candidates.append(hit)
                }
            }
        }
        try Task.checkCancellation()
        let classified = classify(candidates, x, count: count, sampleRate: sampleRate)
        let kickAttacks = classified.filter { $0.kind == .kick }.map(\.attackFrame)
        return try classified.map { landmark in
            guard landmark.kind == .kick else { return landmark }
            try Task.checkCancellation()
            // The body of a kick never rises before its own click; one closer than that is the ring
            // of an earlier hit (a double), so the attack itself is kept. The search stops at the next
            // kick, whose body would otherwise be the window's maximum in a fast double.
            let next = kickAttacks.first { $0 > landmark.attackFrame }
            let rise = lowBandRise(x, count: count, around: landmark.attackFrame, sampleRate: sampleRate, until: next)
                .flatMap { $0 >= landmark.attackFrame ? $0 : nil }
            return LofiDrumLandmark(kind: landmark.kind, attackFrame: landmark.attackFrame, peakFrame: landmark.peakFrame,
                                    strength: landmark.strength, confidence: landmark.confidence, lowRiseFrame: rise)
        }
    }

    // MARK: Low-band rise

    enum LowRise {
        /// Band of the kick body and the bass fundamental: 4th-order Butterworth high- and low-pass.
        static let low = 40.0, high = 160.0
        /// The rise is searched from `before` to `after` seconds around the hit's attack.
        static let before = 0.030, after = 0.080
        /// Filter run-in on each side of the search window, so the zero-phase pass starts settled.
        static let margin = 0.080
        /// RMS window of the band envelope.
        static let rmsSeconds = 0.002
        /// Share of the window's envelope maximum that marks the rise (-6 dB).
        static let share: Float = 0.5
    }

    /// The frame in `[center - before, center + after)` where the zero-phase 40-160 Hz envelope (2 ms
    /// RMS) rises through `share` (default half) of its maximum over that window on the way to that
    /// maximum, or nil when the band is silent. `until` ends the window earlier (the next kick). The same measure
    /// is used for a kick in a take and for a bass voice's own attack, so the two can be aligned. Runs on
    /// a short segment around `center`, off the audio thread.
    static func lowBandRise(_ x: UnsafePointer<Float>, count: Int, around center: Int, sampleRate: Double,
                            share: Float = LowRise.share, until limit: Int? = nil) -> Int? {
        guard count > 0, sampleRate > 0 else { return nil }
        let margin = Int(LowRise.margin * sampleRate)
        let windowStart = max(0, center - Int(LowRise.before * sampleRate))
        let windowEnd = min(count, center + Int(LowRise.after * sampleRate), limit ?? count)
        guard windowEnd > windowStart else { return nil }
        let start = max(0, windowStart - margin), end = min(count, windowEnd + margin)
        var band = Array(UnsafeBufferPointer(start: x + start, count: end - start))
        let q = (0.541_196_100_146_197, 1.306_562_964_876_377)
        let kinds: [LofiBiquad.Kind] = [.highpass(hz: LowRise.low, q: q.0), .highpass(hz: LowRise.low, q: q.1),
                                        .lowpass(hz: LowRise.high, q: q.0), .lowpass(hz: LowRise.high, q: q.1)]
        // Forward, then backward: zero phase, so the rise frame carries no filter delay.
        band.withUnsafeMutableBufferPointer { b in
            var forward = LofiFilterChain(kinds, sampleRate: sampleRate)
            forward.process(b.baseAddress!, count: b.count)
            b.reverse()
            var backward = LofiFilterChain(kinds, sampleRate: sampleRate)
            backward.process(b.baseAddress!, count: b.count)
            b.reverse()
        }
        // Centered running power over `rmsSeconds` (Accelerate: squares, then a sliding sum), compared
        // as power so no square root is needed: half the amplitude is a quarter of the power.
        let w = max(1, Int(LowRise.rmsSeconds * sampleRate))
        let lo = windowStart - start, hi = windowEnd - start
        let first = max(0, lo - w / 2), last = min(band.count, hi - w / 2 + w)
        guard last - first >= w else { return nil }
        var squares = [Float](repeating: 0, count: last - first)
        band.withUnsafeBufferPointer { b in
            vDSP_vsq(b.baseAddress! + first, 1, &squares, 1, vDSP_Length(last - first))
        }
        let sums = max(1, squares.count - w + 1)
        var power = [Float](repeating: 0, count: sums)
        vDSP_vswsum(squares, 1, &power, 1, vDSP_Length(sums), vDSP_Length(w))
        // power[k] covers [first + k, first + k + w), centered on frame first + k + w / 2.
        let k0 = max(0, lo - w / 2 - first), k1 = min(sums, hi - w / 2 - first)
        guard k1 > k0 else { return nil }
        var peak: Float = 0
        power.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + k0, 1, &peak, vDSP_Length(k1 - k0)) }
        guard peak > 1e-14 * Float(w) else { return nil }
        // The crossing on the rise into the window's maximum: walk back from the peak to the last frame
        // under the threshold. A first-crossing search would stop on an earlier note still ringing at the
        // window's start.
        let threshold = share * share * peak
        var top = k0
        for k in k0..<k1 where power[k] >= peak { top = k; break }
        var k = top
        while k > k0, power[k - 1] >= threshold { k -= 1 }
        return start + first + k + w / 2
    }

    // MARK: Novelty

    /// Log-compressed half-wave rectified superflux per band. Frame `k` covers the samples
    /// `[k * hop - size, k * hop)`, so the first frame sees silence and an onset at frame zero counts.
    private static func spectralFlux(_ x: UnsafePointer<Float>, count: Int, size: Int, hop: Int,
                                     sampleRate: Double, bands: [Band]) throws -> [[Float]?] {
        let log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return bands.map { _ in nil } }
        defer { vDSP_destroy_fftsetup(setup) }
        let bins = size / 2
        let resolution = sampleRate / Double(size)
        let ranges: [ClosedRange<Int>?] = bands.map { band in
            let lo = max(1, Int((band.low / resolution).rounded()))
            let hi = min(bins - 2, Int((min(band.high, sampleRate * 0.47) / resolution).rounded()))
            return lo <= hi ? lo...hi : nil
        }
        let frames = (count + size) / hop + 1
        var curves = ranges.map { $0 == nil ? nil : [Float](repeating: 0, count: frames) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        var frame = [Float](repeating: 0, count: size)
        var real = [Float](repeating: 0, count: bins), imag = [Float](repeating: 0, count: bins)
        var magnitude = [Float](repeating: 0, count: bins)
        var previous = [Float](repeating: 0, count: bins)
        var pairMax = [Float](repeating: 0, count: bins)
        var spread = [Float](repeating: 0, count: bins)
        var rise = [Float](repeating: 0, count: bins)
        var scale = Float(2) / Float(size) * Constants.compression
        var zero: Float = 0
        var bins32 = Int32(bins)
        for k in 0..<frames {
            if k.isMultiple(of: 512) { try Task.checkCancellation() }
            let start = k * hop - size
            let lo = max(0, start), hi = min(count, start + size)
            vDSP_vclr(&frame, 1, vDSP_Length(size))
            if hi > lo {
                frame.withUnsafeMutableBufferPointer { f in
                    (f.baseAddress! + (lo - start)).update(from: x + lo, count: hi - lo)
                }
                vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(size))
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(bins))
                }
            }
            magnitude[0] = abs(real[0])
            // log(1 + C |X|) with |X| scaled so a full-scale sine reads 1.
            vDSP_vsmul(magnitude, 1, &scale, &magnitude, 1, vDSP_Length(bins))
            vvlog1pf(&magnitude, magnitude, &bins32)
            // Superflux: compare against the previous frame's maximum over neighbouring bins.
            previous.withUnsafeBufferPointer { p in
                pairMax.withUnsafeMutableBufferPointer { m in
                    vDSP_vmax(p.baseAddress!, 1, p.baseAddress! + 1, 1, m.baseAddress!, 1, vDSP_Length(bins - 1))
                }
            }
            pairMax.withUnsafeBufferPointer { m in
                spread.withUnsafeMutableBufferPointer { s in
                    vDSP_vmax(m.baseAddress!, 1, m.baseAddress! + 1, 1, s.baseAddress! + 1, 1, vDSP_Length(bins - 2))
                }
            }
            vDSP_vsub(spread, 1, magnitude, 1, &rise, 1, vDSP_Length(bins))
            vDSP_vthr(rise, 1, &zero, &rise, 1, vDSP_Length(bins))
            rise.withUnsafeBufferPointer { r in
                for (band, range) in ranges.enumerated() {
                    guard let range else { continue }
                    var sum: Float = 0
                    vDSP_sve(r.baseAddress! + range.lowerBound, 1, &sum, vDSP_Length(range.count))
                    curves[band]![k] = sum
                }
            }
            swap(&previous, &magnitude)
        }
        return curves
    }

    /// Peaks above a local-median threshold, at least `gap` seconds apart (the stronger wins).
    private static func pick(_ curve: [Float], hop: Int, sampleRate: Double, gap: Double) throws -> [Int] {
        guard let largest = curve.max(), largest > 1e-4 else { return [] }
        let n = curve.count
        let radius = max(1, Int((Constants.medianSpan * 0.5 * sampleRate / Double(hop)).rounded()))
        let stride = 4
        var threshold = [Float](repeating: 0, count: n)
        var scratch = [Float](repeating: 0, count: 2 * radius + 1)
        let floor = Constants.delta * largest
        for center in Swift.stride(from: 0, to: n, by: stride) {
            let lo = max(0, center - radius), hi = min(n, center + radius + 1)
            let width = hi - lo
            scratch.withUnsafeMutableBufferPointer { s in
                curve.withUnsafeBufferPointer { c in s.baseAddress!.update(from: c.baseAddress! + lo, count: width) }
                vDSP_vsort(s.baseAddress!, vDSP_Length(width), 1)
            }
            let value = Constants.lambda * scratch[width / 2] + floor
            for i in center..<min(n, center + stride) { threshold[i] = value }
        }
        try Task.checkCancellation()
        let spacing = Int(gap * sampleRate / Double(hop))
        let r = Constants.peakRadius
        var peaks: [Int] = []
        for k in 0..<n where curve[k] > threshold[k] {
            var isPeak = true
            for j in max(0, k - r)..<min(n, k + r + 1) where j != k {
                if j < k ? curve[j] >= curve[k] : curve[j] > curve[k] { isPeak = false; break }
            }
            guard isPeak else { continue }
            if let last = peaks.last, k - last < spacing {
                if curve[k] > curve[last] { peaks[peaks.count - 1] = k }
            } else {
                peaks.append(k)
            }
        }
        return peaks
    }

    // MARK: Attack refinement

    /// Zero-phase band filter plus a trailing maximum envelope. The trailing maximum rises at the
    /// first sample that exceeds it, so the envelope adds no onset delay.
    private final class Refiner {
        let role: Role
        let sampleRate: Double
        let setup: vDSP_biquad_Setup?
        let sections: Int
        let hold: Int
        var input: [Float] = [], output: [Float] = [], envelope: [Float] = [], slope: [Float] = [], delay: [Float] = []

        init(role: Role, sampleRate: Double) {
            self.role = role
            self.sampleRate = sampleRate
            let nyquist = sampleRate * 0.45
            var coefficients: [Double] = []
            switch role {
            case .kick:
                coefficients += Biquad.lowpass(300, sampleRate: sampleRate)
                hold = Int(sampleRate * 0.010)
            case .snareBody, .crack:
                coefficients += Biquad.highpass(150, sampleRate: sampleRate)
                if 8_000 < nyquist { coefficients += Biquad.lowpass(8_000, sampleRate: sampleRate) }
                hold = Int(sampleRate * 0.005)
            case .hat:
                coefficients += Biquad.highpass(min(5_000, nyquist * 0.8), sampleRate: sampleRate)
                coefficients += Biquad.highpass(min(5_000, nyquist * 0.8), sampleRate: sampleRate)
                hold = Int(sampleRate * 0.002)
            }
            sections = coefficients.count / 5
            setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sections))
            delay = [Float](repeating: 0, count: 2 * sections + 2)
        }

        func destroy() { if let setup { vDSP_biquad_DestroySetup(setup) } }

        func refine(_ x: UnsafePointer<Float>, count: Int, windowEnd: Int, size: Int) -> Candidate? {
            guard let setup else { return nil }
            let ms = sampleRate / 1000
            let regionLo = max(0, windowEnd - size - Int(10 * ms))
            let regionHi = min(count - 1, windowEnd + Int(25 * ms))
            guard regionHi > regionLo else { return nil }
            let span = Int(25 * ms), prior = Int(Constants.freshWindow * sampleRate)
            let pad = Int(30 * ms) + hold
            let decaySpan = role == .hat ? Int(Constants.hatDecay * sampleRate) * 2 : 0
            let segmentLo = max(0, regionLo - pad - prior)
            let segmentHi = min(count, regionHi + span + decaySpan + pad)
            let n = segmentHi - segmentLo
            let w = max(1, hold)
            guard n > w + 2 else { return nil }
            if input.count < n {
                input = [Float](repeating: 0, count: n)
                output = input
                envelope = input
                slope = input
            }
            input.withUnsafeMutableBufferPointer { i in i.baseAddress!.update(from: x + segmentLo, count: n) }
            filter(setup, n: n)
            vDSP_vrvrs(&output, 1, vDSP_Length(n))
            swap(&input, &output)
            filter(setup, n: n)
            vDSP_vrvrs(&output, 1, vDSP_Length(n))
            vDSP_vabs(output, 1, &output, 1, vDSP_Length(n))
            // envelope[i] = max |y| over [i - hold + 1, i]
            output.withUnsafeBufferPointer { o in
                envelope.withUnsafeMutableBufferPointer { e in
                    vDSP_vswmax(o.baseAddress!, 1, e.baseAddress! + (w - 1), 1, vDSP_Length(n - w + 1), vDSP_Length(w))
                }
            }
            for i in 0..<(w - 1) { envelope[i] = envelope[w - 1] }
            // The steepest rise of the envelope inside the region is the onset.
            let step = max(1, Int(2 * ms))
            let lo = max(step, regionLo - segmentLo), hi = min(n - 1, regionHi - segmentLo)
            guard hi > lo else { return nil }
            var steepest: Float = 0, index: vDSP_Length = 0
            envelope.withUnsafeBufferPointer { e in
                slope.withUnsafeMutableBufferPointer { d in
                    let base = e.baseAddress!
                    vDSP_vsub(base + lo - step, 1, base + lo, 1, d.baseAddress!, 1, vDSP_Length(hi - lo + 1))
                    vDSP_maxvi(d.baseAddress!, 1, &steepest, &index, vDSP_Length(hi - lo + 1))
                }
            }
            guard steepest > 0 else { return nil }
            let rise = lo + Int(index)
            var peakLevel: Float = 0, peakIndex: vDSP_Length = 0
            var floorLevel: Float = 0, priorLevel: Float = 0
            let peakEnd = min(n - 1, rise + span)
            let floorStart = max(0, rise - span)
            output.withUnsafeBufferPointer { o in
                vDSP_maxvi(o.baseAddress! + rise, 1, &peakLevel, &peakIndex, vDSP_Length(peakEnd - rise + 1))
            }
            envelope.withUnsafeBufferPointer { e in
                vDSP_minv(e.baseAddress! + floorStart, 1, &floorLevel, vDSP_Length(rise - floorStart + 1))
            }
            let threshold = floorLevel + Constants.attackShare * (peakLevel - floorLevel)
            var f = rise
            while f > floorStart, envelope[f - 1] > threshold { f -= 1 }
            let priorStart = max(0, f - prior), priorEnd = max(0, f - Int(2 * ms))
            if priorEnd > priorStart {
                output.withUnsafeBufferPointer { o in
                    vDSP_maxv(o.baseAddress! + priorStart, 1, &priorLevel, vDSP_Length(priorEnd - priorStart))
                }
            }
            let peak = rise + Int(peakIndex)
            // Time to fall 20 dB below the peak, for telling closed hats from sizzling snares.
            var decay = 0.0
            if decaySpan > 0 {
                var end = peak
                let target = peakLevel * 0.1
                let stride = max(1, Int(ms))
                while end + stride < n, end - peak < decaySpan, envelope[end] > target { end += stride }
                decay = Double(end - peak) / sampleRate
            }
            return Candidate(role: role, attack: segmentLo + f, peak: segmentLo + peak,
                             amplitude: peakLevel - floorLevel, prior: priorLevel, decay: decay)
        }

        private func filter(_ setup: vDSP_biquad_Setup, n: Int) {
            vDSP_vclr(&delay, 1, vDSP_Length(delay.count))
            vDSP_biquad(setup, &delay, input, 1, &output, 1, vDSP_Length(n))
        }
    }

    /// Butterworth sections (RBJ cookbook), normalized as b0, b1, b2, a1, a2.
    enum Biquad {
        static func lowpass(_ frequency: Double, sampleRate: Double, q: Double = 0.7071) -> [Double] {
            let w = 2 * Double.pi * frequency / sampleRate, alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha
            return [(1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0]
        }

        static func highpass(_ frequency: Double, sampleRate: Double, q: Double = 0.7071) -> [Double] {
            let w = 2 * Double.pi * frequency / sampleRate, alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha
            return [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0]
        }
    }

    // MARK: Classification

    private static func features(_ x: UnsafePointer<Float>, count: Int, at attack: Int, sampleRate: Double,
                                 setup: FFTSetup) -> Features {
        let span = max(8, Int(Constants.featureSpan * sampleRate))
        let size = 1 << Int(ceil(log2(Double(span))))
        let log2n = vDSP_Length(log2(Double(size)))
        var frame = [Float](repeating: 0, count: size)
        let available = max(0, min(span, count - attack))
        if available > 0 {
            frame.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: x + attack, count: available) }
        }
        // Fade the last quarter so the window edge does not leak low energy upward.
        let fade = max(1, available / 4)
        for i in 0..<fade where available - 1 - i >= 0 {
            frame[available - 1 - i] *= Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)))
        }
        let bins = size / 2
        var real = [Float](repeating: 0, count: bins), imag = [Float](repeating: 0, count: bins)
        var power = [Float](repeating: 0, count: bins)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(bins))
            }
        }
        power[0] = 0
        let resolution = sampleRate / Double(size)
        func energy(_ low: Double, _ high: Double) -> Float {
            let lo = max(1, Int((low / resolution).rounded()))
            let hi = min(bins - 1, Int((min(high, sampleRate * 0.47) / resolution).rounded()))
            guard lo <= hi else { return 0 }
            var sum: Float = 0
            power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo + 1)) }
            return sum
        }
        return Features(low: energy(30, 150), mid: energy(150, 3_000), upper: energy(3_000, 6_000),
                        air: energy(6_000, 16_000))
    }

    private static func classify(_ candidates: [Candidate], _ x: UnsafePointer<Float>, count: Int,
                                 sampleRate: Double) -> [LofiDrumLandmark] {
        let near = Int(Constants.coincidence * sampleRate)
        let sorted = candidates.sorted { $0.attack < $1.attack }
        let span = max(8, Int(Constants.featureSpan * sampleRate))
        let log2n = vDSP_Length(ceil(log2(Double(span))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        // The body and crack bands describe one snare: keep the earlier attack and the louder body.
        var snares: [Candidate] = []
        for c in sorted where c.role == .snareBody || c.role == .crack {
            if let last = snares.last, c.attack - last.attack <= near {
                let body = last.role == .snareBody ? last : (c.role == .snareBody ? c : last)
                snares[snares.count - 1] = Candidate(role: .snareBody, attack: min(last.attack, c.attack),
                                                     peak: body.peak, amplitude: max(last.amplitude, c.amplitude),
                                                     prior: body.prior, decay: max(last.decay, c.decay))
            } else {
                snares.append(Candidate(role: .snareBody, attack: c.attack, peak: c.peak, amplitude: c.amplitude,
                                        prior: c.prior, decay: c.decay))
            }
        }
        let kicks = sorted.filter { $0.role == .kick }
        let hats = sorted.filter { $0.role == .hat }
        func close(_ c: Candidate, _ list: [Candidate]) -> Bool { list.contains { abs($0.attack - c.attack) <= near } }

        var raw: [(kind: LofiDrumLandmark.Kind, c: Candidate, confidence: Float)] = []
        var snareFeatures: [Features] = []
        for c in snares {
            let f = features(x, count: count, at: c.attack, sampleRate: sampleRate, setup: setup)
            snareFeatures.append(f)
        }
        // A kick starts with its beater click, which lands in the snare bands slightly before the
        // low body builds. Pair each low-dominated click with the kick-band onset that follows it.
        let before = Int(Constants.clickLead * sampleRate)
        var claimed = Set<Int>()
        for (c, f) in zip(snares, snareFeatures) where f.lowFraction >= Constants.clickFraction {
            // Ripples inside a ringing kick are not a new click.
            guard c.amplitude >= Constants.reattack * c.prior else { continue }
            let body = kicks.indices.first { !claimed.contains($0)
                && kicks[$0].attack - c.attack >= -near && kicks[$0].attack - c.attack <= before }
            if let body { claimed.insert(body) }
            let peak = body.map { kicks[$0].peak } ?? c.peak
            let amplitude = body.map { kicks[$0].amplitude } ?? c.amplitude
            let low = f.lowFraction
            let confidence = low >= Constants.kickFraction
                ? 0.5 + 0.5 * min(1, (low - Constants.kickFraction) / 0.3)
                : 0.2 + 0.3 * (low - Constants.clickFraction) / (Constants.kickFraction - Constants.clickFraction)
            raw.append((.kick, Candidate(role: .kick, attack: min(c.attack, body.map { kicks[$0].attack } ?? c.attack),
                                         peak: peak, amplitude: amplitude, prior: c.prior, decay: 0), confidence))
        }
        for (index, c) in kicks.enumerated() where !claimed.contains(index) {
            // Without a click a kick must rise from quiet. Low-band beating in a long decay does not.
            guard c.amplitude >= Constants.freshRise * c.prior else { continue }
            let f = features(x, count: count, at: c.attack, sampleRate: sampleRate, setup: setup)
            let low = f.lowFraction
            if low >= Constants.kickFraction {
                raw.append((.kick, c, 0.5 + 0.5 * min(1, (low - Constants.kickFraction) / 0.3)))
            } else if low >= Constants.clickFraction {
                raw.append((.kick, c, 0.2 + 0.3 * (low - Constants.clickFraction) / (Constants.kickFraction - Constants.clickFraction)))
            } else if !close(c, snares) && !close(c, hats) {
                raw.append((.other, c, 0.3))
            }
        }
        let brightHats = hats.filter { $0.decay <= Constants.hatDecay }
        for (c, f) in zip(snares, snareFeatures) where f.lowFraction < Constants.clickFraction {
            // A hat also excites the crack band: a bright, short event is the hat alone.
            if f.airFraction >= Constants.hatFraction, close(c, brightHats) { continue }
            guard c.amplitude >= Constants.reattack * c.prior else { continue }
            let broad = f.broadFraction
            raw.append((.snare, c, 0.5 + 0.5 * min(1, (broad - (1 - Constants.clickFraction)) / 0.35)))
        }
        for c in hats {
            let f = features(x, count: count, at: c.attack, sampleRate: sampleRate, setup: setup)
            let bright = f.airFraction
            let short = c.decay <= Constants.hatDecay
            if bright >= Constants.hatFraction, short {
                raw.append((.hat, c, 0.5 + 0.5 * min(1, (bright - Constants.hatFraction) / 0.3)))
            } else if close(c, snares) || close(c, kicks) {
                continue
            } else if bright >= 0.35 {
                raw.append((.hat, c, 0.3))
            } else {
                raw.append((.other, c, 0.25))
            }
        }
        // Per-kind strength relative to the take's loud hits, then one landmark per gap.
        var result: [LofiDrumLandmark] = []
        for kind in LofiDrumLandmark.Kind.allCases {
            let hits = raw.filter { $0.kind == kind }.sorted { $0.c.attack < $1.c.attack }
            guard !hits.isEmpty else { continue }
            let levels = hits.map(\.c.amplitude).sorted()
            let reference = max(1e-9, levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))])
            let gap: Double = switch kind {
            case .kick: Constants.kick.gap
            case .snare: Constants.snareBody.gap
            case .hat: Constants.hat.gap
            case .other: Constants.hat.gap
            }
            let spacing = Int(gap * sampleRate)
            var kept: [LofiDrumLandmark] = []
            for hit in hits {
                let landmark = LofiDrumLandmark(kind: kind, attackFrame: hit.c.attack, peakFrame: hit.c.peak,
                                                strength: min(1, hit.c.amplitude / reference),
                                                confidence: min(1, max(0, hit.confidence)))
                if let last = kept.last, landmark.attackFrame - last.attackFrame < spacing {
                    // A later peak inside the gap replaces the first only when clearly stronger,
                    // so a swell in a ringing decay cannot displace the attack that started it.
                    if landmark.strength > 2 * last.strength { kept[kept.count - 1] = landmark }
                } else {
                    kept.append(landmark)
                }
            }
            result += kept
        }
        return result.sorted { $0.attackFrame == $1.attackFrame ? $0.kind.rawValue < $1.kind.rawValue
            : $0.attackFrame < $1.attackFrame }
    }
}
