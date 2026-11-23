import Accelerate
import Foundation

/// The cue duck (bass translation, D129): a band reduction of the competing texture and wet return in the
/// bass's cue band, keyed by the finished bass stem, so the bass's harmonic cue reads on speakers that lose
/// everything under 150-250 Hz without thinning the pad and the space when the bass rests.
///
/// Phrase render only (forward and backward filters use the whole phrase; never a realtime path). The
/// detector is the finished, mono bass band-passed to the duck's band (the cue band, not the sub), followed
/// with a 10 ms attack and a 120 ms release. The reduction is `maxDB` at the phrase's median detector level
/// while the bass sounds and scales linearly with the detector below that, so it is 0 dB when the bass
/// rests. A ducked signal is `x - (1 - g) band(x)`: exactly `x` where `g` is 1.
nonisolated struct LofiCueDuck: Sendable, Equatable {
    var texture = true
    var wet = true
    var lowHz: Double = 180
    var highHz: Double = 450
    var maxDB: Float = 3
    var attack = 0.010
    var release = 0.120
    static let standard = LofiCueDuck()

    /// The detector counts frames within this of its loudest as "the bass sounds" for the median.
    static let sounding: Float = -40
    /// The reduction fades in and out over this at both ends of a buffer that is cut at the phrase edge.
    static let edgeTaper = 0.010

    /// 4th-order Butterworth band (two high-pass and two low-pass sections), run forward and backward.
    private var band: [LofiBiquad.Kind] {
        let q = (0.541_196_100_146_197, 1.306_562_964_876_377)
        return [.highpass(hz: lowHz, q: q.0), .highpass(hz: lowHz, q: q.1),
                .lowpass(hz: highHz, q: q.0), .lowpass(hz: highHz, q: q.1)]
    }

    /// Zero-phase band of `x`, with odd-reflected padding at both ends so a buffer that does not start or end
    /// in silence has no filter start-up at its edges.
    func bandOf(_ x: [Float], sampleRate: Double) -> [Float] {
        let count = x.count
        guard count > 1 else { return [Float](repeating: 0, count: count) }
        let pad = min(count - 1, Int(0.050 * sampleRate))
        var padded = [Float](repeating: 0, count: count + 2 * pad)
        for i in 0..<pad {
            padded[pad - 1 - i] = 2 * x[0] - x[i + 1]
            padded[pad + count + i] = 2 * x[count - 1] - x[count - 2 - i]
        }
        padded.replaceSubrange(pad..<(pad + count), with: x)
        let total = padded.count
        padded.withUnsafeMutableBufferPointer { p in
            var forward = LofiFilterChain(band, sampleRate: sampleRate)
            forward.process(p.baseAddress!, count: total)
            vDSP_vrvrs(p.baseAddress!, 1, vDSP_Length(total))
            var backward = LofiFilterChain(band, sampleRate: sampleRate)
            backward.process(p.baseAddress!, count: total)
            vDSP_vrvrs(p.baseAddress!, 1, vDSP_Length(total))
        }
        return Array(padded[pad..<(pad + count)])
    }

    /// The per-frame reduction `1 - g` (0 when the bass rests, at most `1 - 10^(-maxDB / 20)`), `frames`
    /// long, from the finished mono bass (`count` frames; silence after it, so past the phrase the
    /// reduction follows the detector's release).
    func reduction(bass: UnsafePointer<Float>, count: Int, frames: Int, sampleRate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        guard count > 1, frames > 0, maxDB > 0 else { return out }
        let detector = bandOf(Array(UnsafeBufferPointer(start: bass, count: count)), sampleRate: sampleRate)
        let a = Float(1 - exp(-1 / (attack * sampleRate))), r = Float(1 - exp(-1 / (release * sampleRate)))
        var envelope = [Float](repeating: 0, count: frames)
        var level: Float = 0
        for i in 0..<frames {
            let x = i < count ? abs(detector[i]) : 0
            level += (x > level ? a : r) * (x - level)
            envelope[i] = level
        }
        var loudest: Float = 0
        vDSP_maxv(envelope, 1, &loudest, vDSP_Length(frames))
        guard loudest > 1e-7 else { return out }
        let floor = loudest * powf(10, Self.sounding / 20)
        let sounding = envelope.filter { $0 > floor }.sorted()
        guard !sounding.isEmpty else { return out }
        let median = sounding[sounding.count / 2]
        let deepest = 1 - powf(10, -maxDB / 20)
        for i in 0..<frames where envelope[i] > floor {
            let depthDB = maxDB * min(1, envelope[i] / median)
            out[i] = min(deepest, 1 - powf(10, -depthDB / 20))
        }
        return out
    }

    /// `x - reduction * band(x)` in place; `taper` fades the reduction in and out at both ends of `x`.
    func apply(_ reduction: [Float], to x: inout [Float], sampleRate: Double, taper: Bool) {
        let count = min(x.count, reduction.count)
        guard count > 1, reduction.contains(where: { $0 > 0 }) else { return }
        var depth = Array(reduction.prefix(count))
        if taper {
            let edge = min(count / 2, max(1, Int(Self.edgeTaper * sampleRate)))
            for i in 0..<edge {
                let w = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(edge)))
                depth[i] *= w
                depth[count - 1 - i] *= w
            }
        }
        var b = bandOf(Array(x.prefix(count)), sampleRate: sampleRate)
        vDSP_vmul(b, 1, depth, 1, &b, 1, vDSP_Length(count))
        x.withUnsafeMutableBufferPointer { p in
            vDSP_vsub(b, 1, p.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(count))
        }
    }

    /// Mean and largest reduction in dB over the frames the duck acts on.
    static func stats(_ reduction: [Float]) -> (meanDB: Float, maxDB: Float) {
        let active = reduction.filter { $0 > 1e-6 }
        guard !active.isEmpty else { return (0, 0) }
        let db = active.map { -20 * log10f(1 - $0) }
        return (db.reduce(0, +) / Float(db.count), db.max() ?? 0)
    }
}
