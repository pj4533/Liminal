import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation

/// Buses, shared effects and master chain (section 3, decisions D10, D11, D14). Replaces `EffectsChain`.
///
///     strips -> dryBus ------------------------------------------------------------+
///     strips -> delayBus -> VariableDelay -> LPF -> delayReturn ----------------------+--> master
///                                                          +-> Fader(0.5) -> reverbBus
///     strips -> reverbBus -> ZitaReverb (wet) -> reverbReturn -------------------------+
///     master -> HPF 28 Hz -> masterTrim -> PeakLimiter -> -1.5 dB -> output
nonisolated final class MixBus {
    let dryBus = Mixer()
    let reverbBus = Mixer()
    let delayBus = Mixer()
    let delay: VariableDelay
    let delayFilter: LowPassButterworthFilter
    let delayReturn: Fader
    let delayToReverb: Fader
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

    init(layers: [LayerStrip], delayTime: Float) {
        for s in layers {
            dryBus.addInput(s.outputs.dry)
            reverbBus.addInput(s.outputs.reverbSend)
            delayBus.addInput(s.outputs.delaySend)
        }
        delay = VariableDelay(delayBus, time: delayTime, feedback: 0.5, maximumTime: 10, dryWetMix: 1)
        delayFilter = LowPassButterworthFilter(delay, cutoffFrequency: 3500)
        delayReturn = Fader(delayFilter, gain: dbToGain(-6))
        delayToReverb = Fader(delayReturn, gain: 0.5)
        reverbBus.addInput(delayToReverb)
        reverb = ZitaReverb(reverbBus, predelay: 60, crossoverFrequency: 200, lowReleaseTime: 5,
                            midReleaseTime: 6, dampingFrequency: 5000, dryWetMix: 1)
        reverbReturn = Fader(reverb, gain: dbToGain(-8))
        master = Mixer(dryBus, reverbReturn, delayReturn)
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
    func setSpace(_ s: Float, delayAmount d: Float, brightness b: Float, over: Double) {
        space = min(max(s, 0), 1)
        delayAmount = min(max(d, 0), 1)
        let ret = dbToGain(-12 + 10 * space)
        let mid = 3 + 5 * space
        setReverb(returnGain: ret, midRT60: mid, lowRT60: max(1, mid - 1), damping: expMap(b, 3000, 8000), over: over)
        let fb = 0.35 + 0.4 * (0.5 * space + 0.5 * delayAmount)
        setDelay(feedback: fb, returnGain: dbToGain(-9 + 6 * delayAmount), cutoff: expMap(b, 2500, 5000), over: over)
    }

    /// Scale for every layer's delay send (space x delay amount), 0.3 ... 1.4.
    var delaySendScale: Float { (0.3 + 0.7 * space) * (0.6 + 0.8 * delayAmount) }

    func setReverb(returnGain: Float, midRT60: Float, lowRT60: Float, damping: Float, over: Double) {
        ParamRamp.setGain(reverbReturn, returnGain, over: over)
        ParamRamp.set(reverb.$midReleaseTime, midRT60, over: over)
        ParamRamp.set(reverb.$lowReleaseTime, lowRT60, over: over)
        ParamRamp.set(reverb.$dampingFrequency, damping, over: over)
    }

    func setDelay(feedback: Float, returnGain: Float, cutoff: Float, over: Double) {
        ParamRamp.set(delay.$feedback, feedback, over: over)
        ParamRamp.setGain(delayReturn, returnGain, over: over)
        ParamRamp.set(delayFilter.$cutoffFrequency, cutoff, over: over)
    }

    /// Start/stop fades.
    func setMaster(_ gain: Float, over: Double) {
        ParamRamp.setGain(masterTrim, gain, over: over)
    }
}
