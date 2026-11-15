import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation

/// Buses, shared effects and master chain (section 3, decisions D10-D14, D57, D58; calm retune D92).
///
///     strips -> dryBus --------------------------------------------------------------------------+
///     strips -> delayBus -> LPF (pre) -> VariableDelay (wow) -> LPF -> delayReturn ----------------+--> master
///                                                                       +-> Fader(0.5) -> reverbBus
///     strips -> reverbBus -> ZitaReverb (wet) -> LPF 4k -> reverbReturn ------------------------------+
///               reverbBus -> HPF 300 -> LPF 1.8k -> Costello (halo) -> shimmerReturn ----------------+
///     master -> HPF 28 Hz -> LPF 7 kHz -> masterTrim -> PeakLimiter -> -1.5 dB -> output
nonisolated final class MixBus {
    let dryBus = Mixer()
    let reverbBus = Mixer()
    let delayBus = Mixer()
    let delayPreFilter: LowPassButterworthFilter
    let delay: VariableDelay
    let delayFilter: LowPassButterworthFilter
    let delayReturn: Fader
    let delayToReverb: Fader
    let shimmerHP: HighPassButterworthFilter
    let shimmerLP: LowPassButterworthFilter
    let shimmerVerb: CostelloReverb
    let shimmerReturn: Fader
    let reverb: ZitaReverb
    let reverbLP: LowPassButterworthFilter
    let reverbReturn: Fader
    let master: Mixer
    let highpass: HighPassButterworthFilter
    let lowpass: LowPassButterworthFilter
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
        // Calm (decision D92): the delay input is low-passed before the loop so every repeat is dark (the
        // filter after the delay only darkened the output, the loop itself kept the attack's top end).
        delayPreFilter = LowPassButterworthFilter(delayBus, cutoffFrequency: 2000)
        delay = VariableDelay(delayPreFilter, time: delayTime, feedback: 0.4, maximumTime: 10, dryWetMix: 1)
        delayFilter = LowPassButterworthFilter(delay, cutoffFrequency: 2400)
        // Tape character is wow on the delay time only; TanhDistortion was measured at 5 % of the render
        // budget for no audible effect at the -20 dBFS levels the delay runs at (decision D58).
        delayReturn = Fader(delayFilter, gain: dbToGain(-10))
        delayToReverb = Fader(delayReturn, gain: 0.5)
        reverbBus.addInput(delayToReverb)
        reverb = ZitaReverb(reverbBus, predelay: 60, crossoverFrequency: 200, lowReleaseTime: 4.8,
                            midReleaseTime: 8, dampingFrequency: 2400, dryWetMix: 1)
        // A long, dark tail (D92): the return is low-passed at 4 kHz so nothing glassy comes back out of it.
        reverbLP = LowPassButterworthFilter(reverb, cutoffFrequency: 4000)
        reverbReturn = Fader(reverbLP, gain: dbToGain(-5))
        // Halo (D92, was the octave-up shimmer of D12/D57): the reverb send, band-limited to 300 Hz-1.8 kHz,
        // into its own long Costello tail. No pitch shifter: an octave up of every note was the opposite of calm.
        shimmerHP = HighPassButterworthFilter(reverbBus, cutoffFrequency: 300)
        shimmerLP = LowPassButterworthFilter(shimmerHP, cutoffFrequency: 1800)
        shimmerVerb = CostelloReverb(shimmerLP, balance: 1, feedback: 0.93, cutoffFrequency: 2500)
        shimmerReturn = Fader(shimmerVerb, gain: 0)
        master = Mixer(dryBus, reverbReturn, delayReturn, shimmerReturn)
        highpass = HighPassButterworthFilter(master, cutoffFrequency: 28)
        // Safety net (D92): nothing above 7 kHz belongs in this music.
        lowpass = LowPassButterworthFilter(highpass, cutoffFrequency: 7000)
        masterTrim = Fader(lowpass, gain: 0)
        limiter = PeakLimiter(masterTrim, attackTime: 0.01, decayTime: 0.06, preGain: 0)
        finalTrim = Fader(limiter, gain: dbToGain(-1.5))
    }

    /// Offline verification only: render with the limiter bypassed (must still peak at or below -3 dBFS).
    var limiterBypassed: Bool {
        get { limiter.avAudioNode.auAudioUnit.shouldBypassEffect }
        set { limiter.avAudioNode.auAudioUnit.shouldBypassEffect = newValue }
    }

    /// Space macro 0...1 (section 9, calm retune D92): reverb return -9...-1 dB, RT60 6 s up to Zita's 8 s
    /// ceiling (8 s from space 0.33), damping 1.8-3.2 kHz, delay feedback 0.3-0.55, halo return.
    func setSpace(_ s: Float, delayAmount d: Float, brightness b: Float, shimmerScale: Float = 1, over: Double) {
        space = min(max(s, 0), 1)
        delayAmount = min(max(d, 0), 1)
        let ret = dbToGain(-9 + 8 * space)
        let mid = min(8, 6 + 6 * space)
        // Low band decays faster than the mids so the stereo reverb tail does not smear the sub (D74).
        setReverb(returnGain: ret, midRT60: mid, lowRT60: max(1, 0.6 * mid), damping: expMap(b, 1800, 3200), over: over)
        let fb = 0.3 + 0.25 * (0.5 * space + 0.5 * delayAmount)
        setDelay(feedback: fb, returnGain: dbToGain(-10 + 5 * delayAmount), cutoff: expMap(b, 2000, 2800),
                 preCutoff: expMap(b, 1600, 2200), over: over)
        // Halo: -26 dB at space 0 to -12 dB at space 1, scaled by style and image; capped at -14 dB.
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

    func setDelay(feedback: Float, returnGain: Float, cutoff: Float, preCutoff: Float, over: Double) {
        ParamRamp.set(delay.$feedback, feedback, over: over)
        ParamRamp.set(delayPreFilter.$cutoffFrequency, preCutoff, over: over)
        ParamRamp.setGain(delayReturn, mutedReturns.contains("delay") ? 0 : returnGain, over: over)
        ParamRamp.set(delayFilter.$cutoffFrequency, cutoff, over: over)
    }

    /// Halo return target (linear), at or below -14 dB except during a bloom (up to -10 dB).
    func setShimmer(returnGain: Float, over: Double) {
        shimmerLevel = min(returnGain, dbToGain(-14))
    }

    /// Rare event: halo return rises toward -10 dB and back over `duration` seconds.
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
        let g = mutedReturns.contains("shimmer") ? 0 : shimmerLevel + (dbToGain(-10) - shimmerLevel) * b
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
