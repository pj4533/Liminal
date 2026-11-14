import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation

/// One gated voice: a few detuned oscillators (optionally of different waveforms) through an
/// `AmplitudeEnvelope`. Used by `LeadLayer`. All frequency and amplitude changes are ramped (D7).
nonisolated final class VoiceLayer {

    struct Config {
        var oscillatorCount: Int = 2
        var detuneAmount: Float = 0.002      // fraction, spread -d...+d
        var attackTime: Float = 1.0
        var releaseTime: Float = 4.0
        var amplitude: Float = 0.15
        /// Waveform per oscillator (cycled). Default all sine.
        var waveforms: [Table] = [Table(.sine)]
        /// Relative level per oscillator (cycled).
        var mix: [Float] = [1]
    }

    // Note: Using Oscillator (not DynamicOscillator) - DynamicOscillator has
    // wavetable discontinuity clicks when multiple oscillators' phases align
    private(set) var oscillators: [Oscillator] = []
    let envelope: AmplitudeEnvelope
    private let mixer = Mixer()
    private let config: Config
    private(set) var frequency: Float = 220
    private(set) var amplitude: Float

    var output: Node { envelope }

    init(config: Config = Config()) {
        self.config = config
        self.amplitude = config.amplitude
        for i in 0..<config.oscillatorCount {
            let osc = Oscillator(waveform: config.waveforms[i % config.waveforms.count])
            oscillators.append(osc)
            mixer.addInput(osc)
        }
        envelope = AmplitudeEnvelope(mixer, attackDuration: config.attackTime, decayDuration: 0.1,
                                     sustainLevel: 1.0, releaseDuration: config.releaseTime)
        for (i, osc) in oscillators.enumerated() {
            osc.frequency = frequency * detuneFactor(i)
            osc.amplitude = config.amplitude * oscMix(i)
        }
    }

    private func detuneFactor(_ i: Int) -> Float {
        let pos = Float(i) / Float(max(1, config.oscillatorCount - 1))
        return 1.0 + (pos * 2 - 1) * config.detuneAmount
    }

    private func oscMix(_ i: Int) -> Float {
        let total = (0..<config.oscillatorCount).reduce(Float(0)) { $0 + config.mix[$1 % config.mix.count] }
        return config.mix[i % config.mix.count] / max(total, 0.0001)
    }

    func openGate() { envelope.openGate() }
    func closeGate() { envelope.closeGate() }

    func setFrequency(_ freq: Float, glide: Double = ParamRamp.minimum) {
        frequency = freq
        for (i, osc) in oscillators.enumerated() {
            ParamRamp.set(osc.$frequency, freq * detuneFactor(i), over: glide)
        }
    }

    func setAmplitude(_ amp: Float, over: Double = ParamRamp.minimum) {
        amplitude = amp
        for (i, osc) in oscillators.enumerated() {
            ParamRamp.set(osc.$amplitude, amp * oscMix(i), over: over)
        }
    }

    func setEnvelope(attack: Float, release: Float) {
        ParamRamp.set(envelope.$attackDuration, attack, over: ParamRamp.minimum)
        ParamRamp.set(envelope.$releaseDuration, release, over: ParamRamp.minimum)
    }
}
