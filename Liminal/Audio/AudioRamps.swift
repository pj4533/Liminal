import AudioKit
import AudioKitEX
import Foundation
import AudioToolbox

/// Every parameter write goes through here: sample-accurate `scheduleParameterBlock` ramps when the
/// parameter can ramp (all AudioKit/Soundpipe DSP parameters), else a direct value.
nonisolated enum ParamRamp {
    static let minimum: Double = 0.02

    static func set(_ p: NodeParameter, _ value: Float, over: Double) {
        guard let param = p.parameter else { return }
        let v = min(max(value, param.minValue), param.maxValue)
        if param.flags.contains(.flag_CanRamp) {
            p.ramp(to: v, duration: Float(max(minimum, over)))
        } else {
            param.value = v
        }
    }

    static func setGain(_ f: Fader, _ gain: Float, over: Double) {
        set(f.$leftGain, gain, over: over)
        set(f.$rightGain, gain, over: over)
    }
}

/// A software envelope advanced at the 10 Hz modulation rate and written to the audio graph as short
/// ramps. Used for fades that are longer than a ramp should be overridden by other writers.
nonisolated struct SoftEnv {
    private(set) var value: Float
    private var from: Float
    private var to: Float
    private var start: Double = 0
    private var duration: Double = 0

    init(_ v: Float = 0) { value = v; from = v; to = v }

    var target: Float { to }

    mutating func go(to v: Float, over: Double, now: Double) {
        from = value; to = v; start = now; duration = max(0, over)
        if duration == 0 { value = v }
    }

    /// Smoothstep-shaped progress so fades start and end gently.
    @discardableResult
    mutating func tick(_ now: Double) -> Float {
        guard value != to else { return value }
        let u = duration > 0 ? min(max((now - start) / duration, 0), 1) : 1
        let s = Float(u * u * (3 - 2 * u))
        value = u >= 1 ? to : from + (to - from) * s
        return value
    }
}

/// Exponential map of brightness 0...1 into a frequency range.
@inline(__always) nonisolated func expMap(_ b: Float, _ lo: Float, _ hi: Float) -> Float {
    lo * powf(hi / lo, min(max(b, 0), 1))
}

@inline(__always) nonisolated func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }
