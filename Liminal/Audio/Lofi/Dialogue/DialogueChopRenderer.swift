import Accelerate
import AVFoundation
import Foundation

/// Renders pads to dry chops (plan 4.6, 8.5): linked-rate resample, per-band noise weighting,
/// the per-cut vocal chain, refined edges, choke truncation, K-weighted levelling and role trims. Offline only.
nonisolated enum DialogueChopRenderer {
    private struct Key: Hashable { let pad: Int; let frames: Int; let gain: UInt32; let effect: DialogueChopEffect }

    /// One buffer per (pad, choke length, gain, effect) inside a call, so exact repeats share an instance.
    static func render(_ plan: DialoguePerformancePlan, bank: DialoguePadBank, source: DialogueSource,
                       analysis: DialogueAnalysis) -> [DialogueChop] {
        var cache: [Key: AVAudioPCMBuffer] = [:]
        var levels: [Int: Float] = [:]
        var chops: [DialogueChop] = []
        for event in plan.events {
            guard let pad = bank.pad(event.padID) else { continue }
            let full = outputCount(pad)
            var frames = event.chokeAt == nil ? full : min(full, Int((event.duration * source.sampleRate).rounded()))
            var total = frames
            if case .echoThrow = event.effect {
                frames = full
                total = max(full, Int((event.duration * source.sampleRate).rounded()))
            }
            guard frames > 1 else { continue }
            let key = Key(pad: pad.padID, frames: total, gain: event.gainDB.bitPattern, effect: event.effect)
            if let buffer = cache[key] {
                chops.append(DialogueChop(event: event, buffer: buffer))
                continue
            }
            guard var rendered = renderPad(pad, source: source, analysis: analysis, frames: frames,
                                           gainDB: event.gainDB, level: &levels[pad.padID]) else { continue }
            if event.effect != .none, let processed = apply(event.effect, to: rendered, frames: total) { rendered = processed }
            cache[key] = rendered
            chops.append(DialogueChop(event: event, buffer: rendered))
        }
        return chops
    }

    // MARK: Piece effects (motif mode)

    /// A light effect on a rendered piece: an echo throw rendered into the following space, a
    /// band-passed repeat, or the piece reversed as a pickup. Offline; returns a new buffer.
    static func apply(_ effect: DialogueChopEffect, to buffer: AVAudioPCMBuffer, frames total: Int) -> AVAudioPCMBuffer? {
        guard let input = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        let sr = buffer.format.sampleRate
        var dry = Array(UnsafeBufferPointer(start: input, count: n))
        var out: [Float]
        func band(_ x: [Float], _ low: Double, _ high: Double) -> [Float] {
            var hp = LofiBiquad(.highpass(hz: low, q: 0.7071067811865476), sampleRate: sr)
            var lp = LofiBiquad(.lowpass(hz: high, q: 0.7071067811865476), sampleRate: sr)
            return x.map { lp.process(hp.process($0)) }
        }
        switch effect {
        case .none:
            return buffer
        case .reversed:
            out = dry.reversed()
        case .filtered:
            out = band(dry, DialogueMotifTuning.filteredBand.low, DialogueMotifTuning.filteredBand.high)
            // Loudness-matched to the dry piece (RMS, at most `filteredMakeupDB`), so the repeat is a colour, not a drop.
            func rms(_ x: [Float]) -> Float { var v: Float = 0; vDSP_rmsqv(x, 1, &v, vDSP_Length(x.count)); return v }
            let match = rms(out) > 1e-9 ? rms(dry) / rms(out) : 1
            let makeup = min(match, powf(10, DialogueMotifTuning.filteredMakeupDB / 20))
            for i in out.indices { out[i] = LofiSaturation.softClip(out[i] * makeup, threshold: DialogueChopChain.peakKnee,
                                                                    ceiling: DialogueChopChain.peakCeiling) }
            ramp(&out, from: max(0, n - min(n / 2, Int(0.008 * sr))), length: min(n / 2, Int(0.008 * sr)), rising: false)
        case .echoThrow(let delay, _):
            let count = max(n, total)
            out = [Float](repeating: 0, count: count)
            for i in 0..<n { out[i] = dry[i] }
            let wet = band(dry, DialogueMotifTuning.echoBand.low, DialogueMotifTuning.echoBand.high)
            let step = Int((delay * sr).rounded())
            for (k, db) in DialogueMotifTuning.echoGainsDB.enumerated() {
                let g = powf(10, db / 20), offset = (k + 1) * step
                guard offset < count else { break }
                for i in 0..<min(n, count - offset) { out[offset + i] += g * wet[i] }
            }
            let fade = min(count / 3, Int(0.030 * sr))
            ramp(&out, from: count - fade, length: fade, rising: false)
        }
        if !out.isEmpty { out[out.count - 1] = 0 }
        dry.removeAll()
        let count = out.count
        guard count > 1, let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let channels = result.floatChannelData else { return nil }
        result.frameLength = AVAudioFrameCount(count)
        for ch in 0..<Int(buffer.format.channelCount) {
            out.withUnsafeBufferPointer { channels[ch].update(from: $0.baseAddress!, count: count) }
        }
        return result
    }

    /// Output frames of an unchoked pad.
    static func outputCount(_ pad: DialoguePad) -> Int {
        Int(Double(pad.frames.count - 1) / pad.transform.playbackRate)
    }

    /// Source position read for an output frame (0 is the pad start).
    static func readPosition(_ pad: DialoguePad, outputFrame: Int) -> Double {
        Double(pad.frames.lowerBound) + Double(outputFrame) * pad.transform.playbackRate
    }

    /// Renders one pad. `frames` below the full length truncates for a choke with a 12 ms release.
    /// `level` caches the levelling gain of the full-length render so choked copies match it.
    static func renderPad(_ pad: DialoguePad, source: DialogueSource, analysis: DialogueAnalysis, frames requested: Int? = nil,
                          gainDB: Float, level: inout Float?) -> AVAudioPCMBuffer? {
        let rate = pad.transform.playbackRate
        let sr = source.sampleRate
        let n = source.frameCount
        let full = outputCount(pad)
        guard full > 1, pad.frames.lowerBound >= 0, pad.frames.upperBound <= n,
              let input = source.buffer.floatChannelData?[0] else { return nil }
        let count = min(full, requested ?? full)
        guard count > 1 else { return nil }
        // Warm the band filters on a little of the preceding source.
        let warmSource = min(pad.frames.lowerBound, Int(DialogueTuning.filterWarmupSeconds * sr))
        let warm = Int(Double(warmSource) / rate)
        let total = warm + full
        let origin = Double(pad.frames.lowerBound) - Double(warm) * rate
        var x = [Float](repeating: 0, count: total)
        resample(input, frames: n, origin: origin, rate: rate, into: &x)

        // Per-band noise weighting, as the sampler applies it, without the fixed high-band cut.
        let corners = [150.0, 820.0, 3900.0]
        let l0 = DialogueAnalyzer.onePole(x, hz: corners[0], rate: sr)
        let l1 = DialogueAnalyzer.onePole(x, hz: corners[1], rate: sr)
        let l2 = DialogueAnalyzer.onePole(x, hz: corners[2], rate: sr)
        let a = DialogueAnalyzer.subtract(l1, l0), b = DialogueAnalyzer.subtract(l2, l1), c = DialogueAnalyzer.subtract(x, l2)
        var targetA = [Float](repeating: 0.5, count: total), targetB = targetA, targetC = targetA
        var trim = [Float](repeating: 1, count: total)
        if let f = analysis.features {
            var i = 0
            while i < total {
                let position = origin + Double(i) * rate
                let window = min(max(0, Int(position) / f.hop), f.hops - 1)
                // Output frames until the read position leaves this hop.
                let next = Double((window + 1) * f.hop)
                let span = max(1, min(total - i, Int(((next - position) / rate).rounded(.up))))
                let power = f.bands[window]
                var values = SIMD3<Float>.zero
                for k in 0..<3 {
                    values[k] = max(DialogueTuning.bandWeightFloor, 1 - 1.4 * f.floor[k] / max(power[k], 1e-10))
                }
                let presence = 1 - 0.27 * min(1, power.y / max(1e-9, power.x + power.y) * 1.7)
                fill(&targetA, i, span, values.x)
                fill(&targetB, i, span, values.y)
                fill(&targetC, i, span, values.z)
                fill(&trim, i, span, presence)
                i += span
            }
        }
        let wA = smoothed(targetA), wB = smoothed(targetB), wC = smoothed(targetC)
        var y = [Float](repeating: 0, count: total)
        var t = [Float](repeating: 0, count: total)
        vDSP_vmul(a, 1, wA, 1, &y, 1, vDSP_Length(total))
        vDSP_vmul(b, 1, wB, 1, &t, 1, vDSP_Length(total))
        vDSP_vmul(t, 1, trim, 1, &t, 1, vDSP_Length(total))
        vDSP_vadd(y, 1, t, 1, &y, 1, vDSP_Length(total))
        vDSP_vma(c, 1, wC, 1, y, 1, &y, 1, vDSP_Length(total))
        // The vocal chain runs over the warm-up too, so its filters and detectors have settled at the
        // pad start; its group delay is taken back so the accent stays on its sample (plan 8.5).
        DialogueChopChain.process(&y, from: warm, texture: pad.role == .texture, sampleRate: sr)
        let shift = DialogueChopChain.delayFrames
        var out = [Float](repeating: 0, count: full)
        for i in 0..<full where warm + shift + i < total { out[i] = y[warm + shift + i] }

        // Edges from the hierarchy: fade in, natural release.
        let fadeIn = max(2, Int(Double(pad.fadeIn) / rate))
        let fadeOut = max(2, Int(Double(pad.fadeOut) / rate))
        ramp(&out, from: 0, length: min(fadeIn, full / 2), rising: true)
        ramp(&out, from: full - min(fadeOut, full / 2), length: min(fadeOut, full / 2), rising: false)
        out[full - 1] = 0
        // Level the full statement once; a choked copy keeps the same gain. The statement is levelled
        // by loudness, and a soft shoulder then holds the few peaks above it under the ceiling.
        var levelling: Float
        if let cached = level {
            levelling = cached
        } else {
            levelling = out.withUnsafeBufferPointer {
                LofiDialogueSampler.clipGain($0.baseAddress!, count: full, rate: sr, level: DialogueChopChain.levelTarget,
                                             peak: DialogueChopChain.rawPeakLimit, maxGain: DialogueChopChain.maxLevelGain)
            }
            level = levelling
        }
        if !levelling.isFinite { levelling = 0 }
        vDSP_vsmul(out, 1, &levelling, &out, 1, vDSP_Length(full))
        for i in 0..<full {
            out[i] = LofiSaturation.softClip(out[i], threshold: DialogueChopChain.peakKnee, ceiling: DialogueChopChain.peakCeiling)
        }
        var gain = powf(10, gainDB / 20)
        if !gain.isFinite { gain = 0 }
        if count < full {
            out.removeLast(full - count)
            let release = min(count / 2, Int(DialogueTuning.chokeReleaseSeconds * sr))
            ramp(&out, from: count - release, length: release, rising: false)
            out[count - 1] = 0
        }
        vDSP_vsmul(out, 1, &gain, &out, 1, vDSP_Length(count))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        for ch in 0..<Int(source.buffer.format.channelCount) {
            out.withUnsafeBufferPointer { channels[ch].update(from: $0.baseAddress!, count: count) }
        }
        return buffer
    }

    // MARK: Resampling

    /// Native copies directly; faster rates use linear interpolation; slower rates a
    /// Hann-windowed sinc. Every read is clamped inside the buffer.
    static func resample(_ src: UnsafePointer<Float>, frames n: Int, origin: Double, rate: Double, into out: inout [Float]) {
        let total = out.count
        guard n > 1, total > 0 else { return }
        if rate == 1, origin == origin.rounded() {
            let start = Int(origin)
            for i in 0..<total {
                let j = start + i
                out[i] = j >= 0 && j < n ? src[j] : 0
            }
            return
        }
        if rate > 1 {
            var positions = (0..<total).map { Float(min(max(0, origin + Double($0) * rate), Double(n - 2))) }
            positions.withUnsafeMutableBufferPointer { p in
                vDSP_vlint(src, p.baseAddress!, 1, &out, 1, vDSP_Length(total), vDSP_Length(n))
            }
            return
        }
        let half = DialogueTuning.sincHalfTaps, taps = 2 * half
        let table = sincTable
        let phases = DialogueTuning.sincPhases
        let window = UnsafeMutablePointer<Float>.allocate(capacity: taps)
        defer { window.deallocate() }
        table.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<total {
                    let p = origin + Double(i) * rate
                    let j = Int(p.rounded(.down))
                    let fraction = p - Double(j)
                    let phase = min(phases - 1, Int(fraction * Double(phases)))
                    let first = j - half + 1
                    let weights = t.baseAddress! + phase * taps
                    var value: Float = 0
                    if first >= 0, first + taps <= n {
                        vDSP_dotpr(src + first, 1, weights, 1, &value, vDSP_Length(taps))
                    } else {
                        for k in 0..<taps { window[k] = src[min(max(0, first + k), n - 1)] }
                        vDSP_dotpr(window, 1, weights, 1, &value, vDSP_Length(taps))
                    }
                    o[i] = value
                }
            }
        }
    }

    /// `phases x taps` Hann-windowed sinc weights, each phase normalised to unity gain.
    static let sincTable: [Float] = {
        let half = DialogueTuning.sincHalfTaps, taps = 2 * half, phases = DialogueTuning.sincPhases
        var table = [Float](repeating: 0, count: phases * taps)
        for phase in 0..<phases {
            let fraction = (Double(phase) + 0.5) / Double(phases)
            var row = [Double](repeating: 0, count: taps)
            for k in 0..<taps {
                let x = Double(k - half + 1) - fraction
                let sinc = abs(x) < 1e-9 ? 1 : sin(.pi * x) / (.pi * x)
                let hann = 0.5 + 0.5 * cos(.pi * x / Double(half))
                row[k] = sinc * max(0, hann)
            }
            let sum = row.reduce(0, +)
            for k in 0..<taps { table[phase * taps + k] = Float(row[k] / sum) }
        }
        return table
    }()

    // MARK: Helpers

    private static func fill(_ x: inout [Float], _ start: Int, _ count: Int, _ value: Float) {
        var v = value
        x.withUnsafeMutableBufferPointer { p in vDSP_vfill(&v, p.baseAddress! + start, 1, vDSP_Length(count)) }
    }

    /// `w += (target - w) * 0.012` from 0.5, as the sampler smooths its band weights.
    private static func smoothed(_ target: [Float]) -> [Float] {
        let a = DialogueTuning.bandWeightSmoothing
        var padded = [Float](repeating: 0, count: target.count + 2)
        padded.withUnsafeMutableBufferPointer { p in
            target.withUnsafeBufferPointer { (p.baseAddress! + 2).update(from: $0.baseAddress!, count: target.count) }
        }
        var output = [Float](repeating: 0.5, count: target.count + 2)
        var coefficients: [Float] = [a, 0, 0, -(1 - a), 0]
        vDSP_deq22(padded, 1, &coefficients, &output, 1, vDSP_Length(target.count))
        return Array(output[2...])
    }

    /// Raised-cosine ramp from (or to) zero.
    private static func ramp(_ x: inout [Float], from start: Int, length: Int, rising: Bool) {
        guard length > 0, start >= 0, start + length <= x.count else { return }
        for k in 0..<length {
            let phase = Float(k) / Float(length)
            let g = 0.5 - 0.5 * cosf(.pi * (rising ? phase : 1 - phase))
            x[start + k] *= g
        }
    }
}

/// The per-cut vocal chain (plan 8.5), offline: HPF 120 Hz at 18 dB per octave, a -2.5 dB bell at 300 Hz,
/// a +3 dB presence bell at 3 kHz, a 5-8 kHz de-esser, a 3:1 compressor taking 3 to 6 dB off the peaks,
/// then a low-pass at 7.5 kHz for speech pads and 5.5 kHz for texture. Levelling follows in the renderer.
nonisolated enum DialogueChopChain {
    struct Dynamics: OptionSet, Sendable {
        let rawValue: Int
        static let deEsser = Dynamics(rawValue: 1)
        static let compressor = Dynamics(rawValue: 2)
        static let all: Dynamics = [.deEsser, .compressor]
    }

    static let highpassHz = 120.0
    static let mudHz = 300.0, mudQ = 1.0, mudDB = -2.5
    static let presenceHz = 3000.0, presenceQ = 0.8, presenceDB = 3.0
    static let deEssBand = 5_000.0...8_000.0
    static let deEssMaxDB: Float = 5.5
    static let ratio: Float = 3, kneeDB: Float = 6, attack = 0.008, release = 0.100
    /// Threshold below the cut's own peak: the loudest syllables see about 6 dB at 3:1, the body 0 to 3 dB.
    static let thresholdBelowPeakDB: Float = 9
    static let speechLowpassHz = 7_500.0, textureLowpassHz = 5_500.0
    /// Low-frequency group delay of the chain in whole samples (mostly the low-pass), removed by the renderer.
    static let delayFrames = 1

    /// Levelling after the chain (the renderer's `clipGain` call). The K-weighted level of the loud
    /// syllables is the target; the legacy sampler's 0.132 with a hard 0.44 peak cap left featured lines
    /// 2 dB under the drums in 1 to 4 kHz, and the cap, not the level, set most gains (spread 2.2 LU).
    /// 0.28 is about 7 dB above that. Peaks are 9 to 12 dB over the level after the compressor, so the
    /// loudest fraction of a percent of samples meets a soft shoulder from `peakKnee` to `peakCeiling`
    /// (under 1 percent of samples, residual below -35 dB in the reference capture) instead of
    /// setting the gain. `rawPeakLimit` bounds how far a single spike may be pushed into the shoulder.
    static let levelTarget: Float = 0.28
    static let peakKnee: Float = 0.7
    static let peakCeiling: Float = 1.0
    static let rawPeakLimit: Float = 1.5
    static let maxLevelGain: Float = 10

    /// The linear stages before the dynamics.
    static func preFilters(sampleRate: Double) -> [LofiBiquad.Kind] {
        // 3rd-order Butterworth high-pass: a 1st-order section (below) and a Q 1 biquad.
        [.highpass(hz: highpassHz, q: 1.0), .peak(hz: mudHz, q: mudQ, gainDB: mudDB),
         .peak(hz: presenceHz, q: presenceQ, gainDB: presenceDB)]
    }

    static func lowpass(texture: Bool) -> LofiBiquad.Kind {
        .lowpass(hz: texture ? textureLowpassHz : speechLowpassHz, q: 0.7071067811865476)
    }

    /// 1st-order bilinear high-pass at `highpassHz`.
    static func firstOrderHighpass(sampleRate: Double) -> LofiBiquad.Coefficients {
        let k = tan(Double.pi * highpassHz / sampleRate)
        let b0 = 1 / (1 + k)
        return LofiBiquad.Coefficients(b0: b0, b1: -b0, b2: 0, a1: (k - 1) / (k + 1), a2: 0)
    }

    /// Designed magnitude of the linear stages (dynamics idle).
    static func magnitudeDB(at hz: Double, texture: Bool, sampleRate: Double) -> Double {
        let kinds = preFilters(sampleRate: sampleRate) + [lowpass(texture: texture)]
        return kinds.reduce(LofiBiquad.magnitudeDB(firstOrderHighpass(sampleRate: sampleRate), at: hz, sampleRate: sampleRate)) {
            $0 + LofiBiquad($1, sampleRate: sampleRate).magnitudeDB(at: hz)
        }
    }

    /// Processes `x` in place. `from` marks the start of the cut proper (earlier samples only warm the
    /// filters); the compressor threshold is set from the cut's peak after the EQ and de-esser.
    static func process(_ x: inout [Float], from: Int = 0, texture: Bool, sampleRate: Double, dynamics: Dynamics = .all) {
        guard !x.isEmpty else { return }
        let n = x.count
        let first = firstOrderHighpass(sampleRate: sampleRate)
        var filters = preFilters(sampleRate: sampleRate).map { LofiBiquad($0, sampleRate: sampleRate) }
        var deEsser = LofiDeEsser(band: deEssBand, maxReductionDB: deEssMaxDB, sampleRate: sampleRate)
        var x1 = 0.0, y1 = 0.0
        for i in 0..<n {
            let input = Double(x[i])
            let hp = first.b0 * input + first.b1 * x1 - first.a1 * y1
            x1 = input
            y1 = abs(hp) < 1e-30 ? 0 : hp
            var v = Float(hp)
            for k in filters.indices { v = filters[k].process(v) }
            if dynamics.contains(.deEsser) { v = deEsser.process(v) }
            x[i] = v
        }
        if dynamics.contains(.compressor) {
            var peak: Float = 0
            for i in min(from, n)..<n { peak = max(peak, abs(x[i])) }
            if peak > 1e-6 {
                let settings = LofiCompressor.Settings(thresholdDB: 20 * log10f(peak) - thresholdBelowPeakDB, ratio: ratio,
                                                       kneeDB: kneeDB, attack: attack, release: release)
                var compressor = LofiCompressor(settings, sampleRate: sampleRate)
                for i in 0..<n { x[i] *= compressor.gain(detectorLeft: x[i], detectorRight: x[i]) }
            }
        }
        var lp = LofiBiquad(lowpass(texture: texture), sampleRate: sampleRate)
        for i in 0..<n { x[i] = lp.process(x[i]) }
    }
}
