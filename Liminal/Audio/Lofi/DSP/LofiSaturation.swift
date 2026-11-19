import Accelerate
import Foundation

/// Memoryless saturators and an offline oversampled block path.
nonisolated enum LofiSaturation {
    /// Odd, monotonic tape-style curve with unity small-signal gain: tanh(drive x) / drive.
    @inline(__always)
    static func tape(_ x: Float, drive: Float) -> Float {
        guard drive > 1e-4 else { return x }
        return tanhf(drive * x) / drive
    }

    /// Identity up to `threshold`, then a C1-continuous tanh shoulder that approaches `ceiling`
    /// and never exceeds it.
    @inline(__always)
    static func softClip(_ x: Float, threshold: Float, ceiling: Float) -> Float {
        let t = max(0, min(threshold, ceiling))
        let a = abs(x)
        guard a > t else { return x }
        let span = ceiling - t
        let shaped = span > 0 ? min(ceiling, t + span * tanhf((a - t) / span)) : ceiling
        return x < 0 ? -shaped : shaped
    }

    /// Oversampling filter: 32 taps per phase, passband to about 0.84 of the base Nyquist.
    static let tapsPerPhase = 32
    static let cutoff = 0.88
    static let beta = 8.0

    /// Tape saturation of a stereo block in place, 1x, 2x or 4x oversampled. The resampling filters'
    /// delay is compensated, so the output stays aligned with the input.
    static func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int,
                        drive: Float, oversampling: Int) {
        for channel in [left, right] {
            oversampled(channel, count: count, factor: oversampling) { buffer, n in
                for i in 0..<n { buffer[i] = tape(buffer[i], drive: drive) }
            }
        }
    }

    static func process(left: inout [Float], right: inout [Float], drive: Float, oversampling: Int) {
        let count = min(left.count, right.count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                process(left: l.baseAddress!, right: r.baseAddress!, count: count, drive: drive, oversampling: oversampling)
            }
        }
    }

    /// Runs `shape` on an upsampled copy of `buffer` and writes the aligned, downsampled result back.
    static func oversampled(_ buffer: UnsafeMutablePointer<Float>, count: Int, factor requested: Int,
                            _ shape: (UnsafeMutablePointer<Float>, Int) -> Void) {
        guard count > 0 else { return }
        let factor = requested >= 4 ? 4 : (requested >= 2 ? 2 : 1)
        guard factor > 1 else { shape(buffer, count); return }
        let k = tapsPerPhase
        let h = LofiFIRDesign.oversamplingLowpass(factor: factor, tapsPerPhase: k, cutoff: cutoff, beta: beta)
        let taps = h.count                       // factor * k + 1
        let down = h.map(Float.init)
        let up = h.map { Float($0 * Double(factor)) }
        // Base delay is k / 2 for each filter; pad the input so the tail flushes.
        let delay = k
        let total = count + delay
        let stuffedCount = total * factor
        let stuffed = UnsafeMutablePointer<Float>.allocate(capacity: stuffedCount + taps)
        defer { stuffed.deallocate() }
        stuffed.initialize(repeating: 0, count: stuffedCount + taps)
        // Zero-stuff after `taps - 1` leading zeros so correlation becomes causal convolution.
        let lead = taps - 1
        for i in 0..<count { stuffed[lead + i * factor] = buffer[i].isFinite ? buffer[i] : 0 }
        let high = UnsafeMutablePointer<Float>.allocate(capacity: stuffedCount + taps)
        defer { high.deallocate() }
        high.initialize(repeating: 0, count: stuffedCount + taps)
        up.withUnsafeBufferPointer { f in
            vDSP_conv(stuffed, 1, f.baseAddress!, 1, high + lead, 1, vDSP_Length(stuffedCount), vDSP_Length(taps))
        }
        shape(high + lead, stuffedCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: total)
        defer { output.deallocate() }
        down.withUnsafeBufferPointer { f in
            vDSP_desamp(high, vDSP_Stride(factor), f.baseAddress!, output, vDSP_Length(total), vDSP_Length(taps))
        }
        // output[i] is centred on high index i * factor + (taps - 1) / 2 - lead, which is base time i - k.
        buffer.update(from: output + delay, count: count)
    }
}
