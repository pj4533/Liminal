import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import OSLog

/// Effects chain for ambient processing: reverb + delay
/// Creates spacious, ethereal sound from the dry voice input.
final class EffectsChain {

    // MARK: - Configuration

    struct Config {
        // Reverb
        var reverbMix: Float = 0.6           // 60% wet
        var reverbFeedback: Float = 0.9      // Long decay

        // Delay
        var delayTime: Float = 0.4           // 400ms
        var delayFeedback: Float = 0.5       // 50% feedback
        var delayMix: Float = 0.3            // 30% wet
    }

    // MARK: - Audio Nodes

    private var reverb: CostelloReverb?
    private var delay: VariableDelay?
    private var delayMixer: DryWetMixer?
    private let dryWetMixer: DryWetMixer

    // MARK: - State

    private var config: Config
    private let input: Node

    /// The output node to connect to the audio graph
    var output: Node { dryWetMixer }

    // MARK: - Init

    init(input: Node, config: Config = Config()) {
        self.input = input
        self.config = config

        // Create delay (VariableDelay has time and feedback)
        delay = VariableDelay(input, time: config.delayTime, feedback: config.delayFeedback)

        // Mix delay wet/dry
        delayMixer = DryWetMixer(input, delay!, balance: config.delayMix)

        // Create reverb (feeds from delay mix)
        reverb = CostelloReverb(
            delayMixer!,
            feedback: config.reverbFeedback,
            cutoffFrequency: 8000
        )

        // Final dry/wet mixer for reverb amount
        dryWetMixer = DryWetMixer(delayMixer!, reverb!, balance: config.reverbMix)

        LMLog.audio.debug("✨ Effects: delay=\(config.delayTime)s fb=\(config.delayFeedback) mix=\(config.delayMix)")
        LMLog.audio.debug("✨ Effects: reverb fb=\(config.reverbFeedback) mix=\(config.reverbMix)")
    }

    // MARK: - Control

    func setReverbMix(_ mix: Float) {
        config.reverbMix = mix
        dryWetMixer.balance = AUValue(mix)
    }

    func setDelayTime(_ time: Float) {
        config.delayTime = time
        delay?.time = AUValue(time)
    }

    func setDelayFeedback(_ feedback: Float) {
        config.delayFeedback = feedback
        delay?.feedback = AUValue(feedback)
    }

    func setDelayMix(_ mix: Float) {
        config.delayMix = mix
        delayMixer?.balance = AUValue(mix)
    }
}
