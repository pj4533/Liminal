import Accelerate
import Foundation

/// Capture-only measurement of the drum bus tape stage (D121, plan mix-distortion 2.4): a null test
/// across `saturate`, so its products can be told apart from the take. Runs where `applyDrums` runs
/// (offline, off the audio thread) and only while `LofiCaptureHooks` is enabled; the audio is untouched.
nonisolated extension LofiStemChains {
    struct TapeNull: Sendable, Equatable {
        /// Residual a 5.3 ms block gain cannot explain, dB re the tape output.
        var residualDB: Float
        /// The same in 1 to 4 kHz (4-pole band-pass on residual and output), dB re the output's band.
        var band1to4kDB: Float
    }

    /// `output` against `input` (same length, aligned: the oversampling delay is compensated) with the
    /// gain model of `scripts/distortion-report.py`: weighted least-squares gains over 256-frame blocks,
    /// interpolated by a 50% overlap periodic Hann window.
    static func tapeNull(input: (left: [Float], right: [Float]), output left: UnsafePointer<Float>,
                         _ right: UnsafePointer<Float>, count: Int, sampleRate: Double) -> TapeNull? {
        let n = 256, hop = n / 2
        let blocks = count / hop
        guard blocks > 2, input.left.count >= count, input.right.count >= count else { return nil }
        var window = [Double](repeating: 0, count: n)
        for i in 0..<n { window[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n)) }
        var xy = [Double](repeating: 0, count: blocks), xx = [Double](repeating: 0, count: blocks)
        // Block k's gain weighs hop k with the rising half of the window and hop k + 1 with the falling half.
        for k in 0..<blocks {
            for i in 0..<hop {
                let f = k * hop + i
                let a = Double(input.left[f]) * Double(left[f]) + Double(input.right[f]) * Double(right[f])
                let b = Double(input.left[f]) * Double(input.left[f]) + Double(input.right[f]) * Double(input.right[f])
                xy[k] += a * window[i]
                xx[k] += b * window[i]
                if k > 0 {
                    xy[k - 1] += a * window[hop + i]
                    xx[k - 1] += b * window[hop + i]
                }
            }
        }
        var gain = [Double](repeating: 1, count: blocks)
        for k in 0..<blocks where xx[k] > 1e-10 { gain[k] = xy[k] / xx[k] }
        var residual = (left: [Float](repeating: 0, count: count), right: [Float](repeating: 0, count: count))
        for f in 0..<count {
            let k = min(f / hop, blocks - 1), i = f - k * hop
            let g = f < blocks * hop
                ? window[hop + i] * gain[max(0, k - 1)] + window[i] * gain[k]
                : gain[blocks - 1]
            residual.left[f] = left[f] - Float(g) * input.left[f]
            residual.right[f] = right[f] - Float(g) * input.right[f]
        }
        func energy(_ x: UnsafePointer<Float>, _ y: UnsafePointer<Float>) -> Double {
            var a: Float = 0, b: Float = 0
            vDSP_svesq(x, 1, &a, vDSP_Length(count))
            vDSP_svesq(y, 1, &b, vDSP_Length(count))
            return Double(a) + Double(b)
        }
        func ratioDB(_ num: Double, _ den: Double) -> Float { Float(10 * log10(max(num, 1e-30) / max(den, 1e-30))) }
        let outEnergy = energy(left, right)
        let overall = ratioDB(energy(residual.left, residual.right), outEnergy)
        let band: [LofiBiquad.Kind] = [.highpass(hz: 1_000, q: 0.541_196_100_146_197), .highpass(hz: 1_000, q: 1.306_562_964_876_377),
                                       .lowpass(hz: 4_000, q: 0.541_196_100_146_197), .lowpass(hz: 4_000, q: 1.306_562_964_876_377)]
        func banded(_ x: UnsafePointer<Float>) -> [Float] {
            var y = Array(UnsafeBufferPointer(start: x, count: count))
            var chain = LofiFilterChain(band, sampleRate: sampleRate)
            y.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: count) }
            return y
        }
        let rl = banded(residual.left), rr = banded(residual.right), yl = banded(left), yr = banded(right)
        return TapeNull(residualDB: overall, band1to4kDB: ratioDB(energy(rl, rr), energy(yl, yr)))
    }
}
