import Accelerate
import Foundation

/// Stereo utilities for offline chains and analysis.
nonisolated enum LofiStereo {
    /// Linkwitz-Riley 4th-order crossover at `hz`: the low band is summed to mono and added back to the
    /// untouched high bands. Low plus high of an LR4 pair is an all-pass, so the sum stays flat.
    static func monoBelow(_ hz: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                          count: Int, sampleRate: Double) {
        guard count > 0, hz > 0 else { return }
        let q = 0.7071067811865476
        var low = LofiFilterChain([.lowpass(hz: hz, q: q), .lowpass(hz: hz, q: q)], sampleRate: sampleRate)
        var high = LofiFilterChain([.highpass(hz: hz, q: q), .highpass(hz: hz, q: q)], sampleRate: sampleRate)
        let lowL = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let lowR = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { lowL.deallocate(); lowR.deallocate() }
        lowL.update(from: left, count: count)
        lowR.update(from: right, count: count)
        low.process(left: lowL, right: lowR, count: count)
        high.process(left: left, right: right, count: count)
        // mono = (lowL + lowR) / 2
        var half: Float = 0.5
        vDSP_vadd(lowL, 1, lowR, 1, lowL, 1, vDSP_Length(count))
        vDSP_vsmul(lowL, 1, &half, lowL, 1, vDSP_Length(count))
        vDSP_vadd(left, 1, lowL, 1, left, 1, vDSP_Length(count))
        vDSP_vadd(right, 1, lowL, 1, right, 1, vDSP_Length(count))
    }

    static func monoBelow(_ hz: Double, left: inout [Float], right: inout [Float], sampleRate: Double) {
        let count = min(left.count, right.count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                monoBelow(hz, left: l.baseAddress!, right: r.baseAddress!, count: count, sampleRate: sampleRate)
            }
        }
    }

    /// Pearson correlation of the two channels about zero (-1 to 1). Returns 0 when either is silent.
    static func correlation(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var lr: Float = 0, ll: Float = 0, rr: Float = 0
        vDSP_dotpr(left, 1, right, 1, &lr, vDSP_Length(count))
        vDSP_svesq(left, 1, &ll, vDSP_Length(count))
        vDSP_svesq(right, 1, &rr, vDSP_Length(count))
        let denominator = (ll * rr).squareRoot()
        guard denominator > 1e-30, denominator.isFinite else { return 0 }
        return max(-1, min(1, lr / denominator))
    }

    static func correlation(left: [Float], right: [Float]) -> Float {
        let count = min(left.count, right.count)
        return left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in correlation(left: l.baseAddress!, right: r.baseAddress!, count: count) }
        }
    }
}
