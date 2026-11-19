import Accelerate
import Foundation

/// Kaiser-windowed sinc designs shared by the oversamplers, the true-peak meter and the master kernel.
nonisolated enum LofiFIRDesign {
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let half = x / 2
        for k in 1..<64 {
            term *= (half / Double(k)) * (half / Double(k))
            sum += term
            if term < 1e-17 * sum { break }
        }
        return sum
    }

    static func kaiser(_ n: Int, length: Int, beta: Double) -> Double {
        guard length > 1 else { return 1 }
        let r = 2 * Double(n) / Double(length - 1) - 1
        return besselI0(beta * max(0, 1 - r * r).squareRoot()) / besselI0(beta)
    }

    @inline(__always)
    static func sinc(_ x: Double) -> Double {
        abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
    }

    /// Linear-phase low-pass of odd length `factor * halfTaps * 2 + 1` at the oversampled rate with
    /// DC gain 1. `cutoff` is a fraction of the base-rate Nyquist (1 = the full band).
    static func oversamplingLowpass(factor: Int, tapsPerPhase k: Int, cutoff: Double, beta: Double) -> [Double] {
        let length = factor * k + 1
        let center = Double(length - 1) / 2
        let fc = 0.5 * cutoff / Double(factor)   // cycles per oversampled sample
        var h = (0..<length).map { n -> Double in
            2 * fc * sinc(2 * fc * (Double(n) - center)) * kaiser(n, length: length, beta: beta)
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h
    }

    /// Fractional-delay interpolators for phases 1..<factor (radius taps on each side), each normalized
    /// to unit DC gain, laid out for correlation (`vDSP_conv`) against a signal padded by `radius`.
    static func fractionalPhases(factor: Int, radius: Int, beta: Double) -> [[Float]] {
        let taps = 2 * radius + 1
        return (1..<max(2, factor)).map { phase in
            let fraction = Double(phase) / Double(factor)
            var kernel = (0..<taps).map { tap -> Double in
                let delta = Double(tap - radius) - fraction
                // Window centred on the fractional position.
                let r = delta / Double(radius + 1)
                let w = besselI0(beta * max(0, 1 - r * r).squareRoot()) / besselI0(beta)
                return sinc(delta) * w
            }
            let total = kernel.reduce(0, +)
            kernel = kernel.map { $0 / total }
            // Correlation C[n] = sum A[n + t] F[t]; output n estimates x(n + fraction) when F[t] weights
            // x[n + t - radius] by the kernel at offset (t - radius) - fraction, i.e. the kernel as is.
            return kernel.map(Float.init)
        }
    }
}

/// Inter-sample peak measurement by polyphase windowed-sinc reconstruction (offline use).
nonisolated enum LofiTruePeak {
    static let radius = 32
    static let beta = 9.0

    /// Largest reconstructed magnitude, linear. `factor` is 4 or 16 (any value of at least 1 works).
    static func linear(_ samples: UnsafePointer<Float>, count: Int, factor: Int) -> Float {
        guard count > 0 else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        guard factor > 1 else { return peak }
        let radius = Self.radius
        let padded = UnsafeMutablePointer<Float>.allocate(capacity: count + 2 * radius + 1)
        defer { padded.deallocate() }
        padded.initialize(repeating: 0, count: count + 2 * radius + 1)
        (padded + radius).update(from: samples, count: count)
        for i in 0..<count where !samples[i].isFinite { padded[radius + i] = 0 }
        let output = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { output.deallocate() }
        for kernel in LofiFIRDesign.fractionalPhases(factor: factor, radius: radius, beta: beta) {
            kernel.withUnsafeBufferPointer { k in
                vDSP_conv(padded, 1, k.baseAddress!, 1, output, 1, vDSP_Length(count), vDSP_Length(k.count))
            }
            var m: Float = 0
            vDSP_maxmgv(output, 1, &m, vDSP_Length(count))
            peak = max(peak, m)
        }
        return peak
    }

    static func linear(_ samples: [Float], factor: Int) -> Float {
        samples.withUnsafeBufferPointer { linear($0.baseAddress!, count: $0.count, factor: factor) }
    }

    /// Stereo true peak in dBTP.
    static func dbtp(left: [Float], right: [Float], factor: Int = 16) -> Float {
        let peak = max(linear(left, factor: factor), linear(right, factor: factor))
        return 20 * log10f(max(peak, 1e-12))
    }
}
