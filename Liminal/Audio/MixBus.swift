import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation

/// Buses, shared effects and master chain (section 3, decisions D10-D14, D57, D58).
///
///     strips -> dryBus --------------------------------------------------------------------+
///     strips -> delayBus -> VariableDelay (wow) -> LPF -> delayReturn ----------------------+--> master
///                                                                 +-> Fader(0.5) -> reverbBus
///     strips -> reverbBus -> ZitaReverb (wet) -> reverbReturn ----------------------------------+
///               reverbBus -> HPF 400 -> PitchShifter +12 -> LPF 5k -> Costello -> shimmerReturn -+
///     master -> HPF 28 Hz -> masterTrim -> PeakLimiter -> -1.5 dB -> output
nonisolated final class MixBus {
    let dryBus = Mixer()
    let reverbBus = Mixer()
    let delayBus = Mixer()
    let delay: VariableDelay
    let delayFilter: LowPassButterworthFilter
    let delayReturn: Fader
    let delayToReverb: Fader
    let shimmerHP: HighPassButterworthFilter
    let shimmerShift: PitchShifter
    let shimmerLP: LowPassButterworthFilter
    let shimmerVerb: CostelloReverb
    let shimmerReturn: Fader
    let reverb: ZitaReverb
    let reverbReturn: Fader
    let master: Mixer
    let highpass: HighPassButterworthFilter
    let masterTrim: Fader
    let limiter: PeakLimiter
    let finalTrim: Fader

    var output: Node { finalTrim }

    /// Base return gains before the space macro.
    private(set) var space: Float = 0.5
    private(set) var delayAmount: Float = 0.5

    private let baseDelayTime: Float
    /// Shimmer return (linear) before the bloom envelope; published as `MusicState.shimmerLevel`.
    private(set) var shimmerLevel: Float = 0
    private var shimmerBloom = SoftEnv(0)
    private var wowPhase = 0.0, flutterPhase = 0.0

    init(layers: [LayerStrip], delayTime: Float) {
        baseDelayTime = delayTime
        for s in layers {
            dryBus.addInput(s.outputs.dry)
            reverbBus.addInput(s.outputs.reverbSend)
            delayBus.addInput(s.outputs.delaySend)
        }
        delay = VariableDelay(delayBus, time: delayTime, feedback: 0.5, maximumTime: 10, dryWetMix: 1)
        delayFilter = LowPassButterworthFilter(delay, cutoffFrequency: 3500)
        // Tape character is wow on the delay time only; TanhDistortion was measured at 5 % of the render
        // budget for no audible effect at the -20 dBFS levels the delay runs at (decision D58).
        delayReturn = Fader(delayFilter, gain: dbToGain(-6))
        delayToReverb = Fader(delayReturn, gain: 0.5)
        reverbBus.addInput(delayToReverb)
        reverb = ZitaReverb(reverbBus, predelay: 60, crossoverFrequency: 200, lowReleaseTime: 5,
                            midReleaseTime: 6, dampingFrequency: 5000, dryWetMix: 1)
        reverbReturn = Fader(reverb, gain: dbToGain(-8))
        // Feed-forward shimmer (D12, D57): octave-up of the reverb send, high-passed first so the drone
        // and low pad do not smear through the pitch shifter, then its own long Costello tail.
        shimmerHP = HighPassButterworthFilter(reverbBus, cutoffFrequency: 400)
        shimmerShift = PitchShifter(shimmerHP, shift: 12, windowSize: 2048, crossfade: 1024, dryWetMix: 1)
        shimmerLP = LowPassButterworthFilter(shimmerShift, cutoffFrequency: 5000)
        shimmerVerb = CostelloReverb(shimmerLP, balance: 1, feedback: 0.9, cutoffFrequency: 6500)
        shimmerReturn = Fader(shimmerVerb, gain: 0)
        master = Mixer(dryBus, reverbReturn, delayReturn, shimmerReturn)
        highpass = HighPassButterworthFilter(master, cutoffFrequency: 28)
        masterTrim = Fader(highpass, gain: 0)
        limiter = PeakLimiter(masterTrim, attackTime: 0.01, decayTime: 0.06, preGain: 0)
        finalTrim = Fader(limiter, gain: dbToGain(-1.5))
    }

    /// Offline verification only: render with the limiter bypassed (must still peak at or below -3 dBFS).
    var limiterBypassed: Bool {
        get { limiter.avAudioNode.auAudioUnit.shouldBypassEffect }
        set { limiter.avAudioNode.auAudioUnit.shouldBypassEffect = newValue }
    }

    /// Space macro 0...1 (section 9): reverb return -12...-2 dB, RT60 3...8 s, delay send scale, feedback.
    func setSpace(_ s: Float, delayAmount d: Float, brightness b: Float, shimmerScale: Float = 1, over: Double) {
        space = min(max(s, 0), 1)
        delayAmount = min(max(d, 0), 1)
        let ret = dbToGain(-12 + 10 * space)
        let mid = 3 + 5 * space
        // Low band decays faster than the mids so the stereo reverb tail does not smear the sub (D74).
        setReverb(returnGain: ret, midRT60: mid, lowRT60: max(1, mid - 2.5), damping: expMap(b, 3000, 6500), over: over)
        let fb = 0.35 + 0.4 * (0.5 * space + 0.5 * delayAmount)
        setDelay(feedback: fb, returnGain: dbToGain(-9 + 6 * delayAmount), cutoff: expMap(b, 2500, 4200), over: over)
        // Shimmer: -26 dB at space 0 to -12 dB at space 1, scaled by style and image; capped at -12 dB.
        setShimmer(returnGain: dbToGain(-26 + 14 * space) * shimmerScale, over: over)
    }

    /// Scale for every layer's delay send (space x delay amount), 0.3 ... 1.4.
    var delaySendScale: Float { (0.3 + 0.7 * space) * (0.6 + 0.8 * delayAmount) }

    /// Offline diagnosis only (stem renders): returns named here ("reverb", "delay", "shimmer") stay at zero.
    var mutedReturns: Set<String> = []

    func setReverb(returnGain: Float, midRT60: Float, lowRT60: Float, damping: Float, over: Double) {
        ParamRamp.setGain(reverbReturn, mutedReturns.contains("reverb") ? 0 : returnGain, over: over)
        ParamRamp.set(reverb.$midReleaseTime, midRT60, over: over)
        ParamRamp.set(reverb.$lowReleaseTime, lowRT60, over: over)
        ParamRamp.set(reverb.$dampingFrequency, damping, over: over)
    }

    func setDelay(feedback: Float, returnGain: Float, cutoff: Float, over: Double) {
        ParamRamp.set(delay.$feedback, feedback, over: over)
        ParamRamp.setGain(delayReturn, mutedReturns.contains("delay") ? 0 : returnGain, over: over)
        ParamRamp.set(delayFilter.$cutoffFrequency, cutoff, over: over)
    }

    /// Shimmer return target (linear), at or below -12 dB except during a bloom (up to -8 dB).
    func setShimmer(returnGain: Float, over: Double) {
        shimmerLevel = min(returnGain, dbToGain(-12))
    }

    /// Rare event: shimmer return rises toward -8 dB and back over `duration` seconds.
    func bloomShimmer(duration: Double, now: Double) {
        shimmerBloom.go(to: 1, over: duration * 0.4, now: now)
        bloomEnd = now + duration * 0.45
        bloomRelease = duration * 0.55
    }
    private var bloomEnd = -1.0
    private var bloomRelease = 10.0

    /// Current shimmer return (linear), for MusicState.
    private(set) var shimmerOut: Float = 0

    /// 10 Hz: tape wow on the delay time (0.2 % at 0.41 Hz plus 0.06 % at 0.13 Hz), and the
    /// shimmer return with its bloom envelope.
    func modulate(t: Double, dt: Double) {
        if bloomEnd > 0 && t >= bloomEnd { shimmerBloom.go(to: 0, over: bloomRelease, now: t); bloomEnd = -1 }
        let b = shimmerBloom.tick(t)
        let g = mutedReturns.contains("shimmer") ? 0 : shimmerLevel + (dbToGain(-8) - shimmerLevel) * b
        if abs(g - shimmerOut) > 1e-5 { ParamRamp.setGain(shimmerReturn, g, over: 0.12); shimmerOut = g }
        wowPhase += dt * 2 * .pi * 0.41
        flutterPhase += dt * 2 * .pi * 0.13
        let wow = 0.002 * sin(wowPhase) + 0.0006 * sin(flutterPhase + 1)
        ParamRamp.set(delay.$time, baseDelayTime * Float(1 + wow), over: 0.11)
    }

    /// Start/stop fades.
    func setMaster(_ gain: Float, over: Double) {
        ParamRamp.setGain(masterTrim, gain, over: over)
    }
}
