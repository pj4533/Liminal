import Accelerate
import AVFoundation
import Foundation

/// Renders pads to dry chops (plan 4.6): linked-rate resample, per-band noise weighting,
/// refined edges, choke truncation, K-weighted levelling and role trims. Offline only.
nonisolated enum DialogueChopRenderer {
    private struct Key: Hashable { let pad: Int; let frames: Int; let gain: UInt32 }

    /// One buffer per (pad, choke length, gain) inside a call, so exact repeats share an instance.
    static func render(_ plan: DialoguePerformancePlan, bank: DialoguePadBank, source: DialogueSource,
                       analysis: DialogueAnalysis) -> [DialogueChop] {
        var cache: [Key: AVAudioPCMBuffer] = [:]
        var levels: [Int: Float] = [:]
        var chops: [DialogueChop] = []
        for event in plan.events {
            guard let pad = bank.pad(event.padID) else { continue }
            let full = outputCount(pad)
            let frames = event.chokeAt == nil ? full : min(full, Int((event.duration * source.sampleRate).rounded()))
            guard frames > 1 else { continue }
            let key = Key(pad: pad.padID, frames: frames, gain: event.gainDB.bitPattern)
            if let buffer = cache[key] {
                chops.append(DialogueChop(event: event, buffer: buffer))
                continue
            }
            guard let rendered = renderPad(pad, source: source, analysis: analysis, frames: frames,
                                           gainDB: event.gainDB, level: &levels[pad.padID]) else { continue }
            cache[key] = rendered
            chops.append(DialogueChop(event: event, buffer: rendered))
        }
        return chops
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
        var out = Array(y[warm...])

        // Edges from the hierarchy: fade in, natural release.
        let fadeIn = max(2, Int(Double(pad.fadeIn) / rate))
        let fadeOut = max(2, Int(Double(pad.fadeOut) / rate))
        ramp(&out, from: 0, length: min(fadeIn, full / 2), rising: true)
        ramp(&out, from: full - min(fadeOut, full / 2), length: min(fadeOut, full / 2), rising: false)
        out[full - 1] = 0
        // Level the full statement once; a choked copy keeps the same gain.
        let levelling: Float
        if let cached = level {
            levelling = cached
        } else {
            levelling = out.withUnsafeBufferPointer { LofiDialogueSampler.clipGain($0.baseAddress!, count: full, rate: sr) }
            level = levelling
        }
        var gain = levelling * powf(10, gainDB / 20)
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
