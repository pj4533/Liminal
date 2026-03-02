import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import OSLog

/// Effects chain for ambient processing: delay → filter → reverb
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

        // Filter
        var filterCutoff: Float = 8000       // Hz — sweeps 3000-12000
        var filterResonance: Float = 0.15    // Very low — no resonant peaks
    }

    // MARK: - Audio Nodes

    private var reverb: CostelloReverb?
    private var delay: VariableDelay?
    private var delayMixer: DryWetMixer?
    private var filter: MoogLadder?
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

        // MoogLadder filter between delay and reverb for spectral sweep
        filter = MoogLadder(
            delayMixer!,
            cutoffFrequency: config.filterCutoff,
            resonance: config.filterResonance
        )

        // Create reverb (feeds from filter)
        reverb = CostelloReverb(
            filter!,
            feedback: config.reverbFeedback,
            cutoffFrequency: 8000
        )

        // Final dry/wet mixer for reverb amount
        dryWetMixer = DryWetMixer(filter!, reverb!, balance: config.reverbMix)

        LMLog.audio.debug("✨ Effects: delay=\(config.delayTime)s fb=\(config.delayFeedback) mix=\(config.delayMix)")
        LMLog.audio.debug("✨ Effects: filter cutoff=\(config.filterCutoff)Hz res=\(config.filterResonance)")
        LMLog.audio.debug("✨ Effects: reverb fb=\(config.reverbFeedback) mix=\(config.reverbMix)")
    }

    // MARK: - Control
    // Note: Use AUParameter.value directly to avoid AudioKit's legacy
    // AudioUnitSetParameter C API path which triggers kAudioUnitErr_InvalidParameter
    // on AUv3 nodes. The AUv3 path works correctly.

    func setReverbMix(_ mix: Float) {
        config.reverbMix = mix
        dryWetMixer.$balance.parameter?.value = AUValue(mix)
    }

    func setDelayTime(_ time: Float) {
        config.delayTime = time
        delay?.$time.parameter?.value = AUValue(time)
    }

    func setDelayFeedback(_ feedback: Float) {
        config.delayFeedback = feedback
        delay?.$feedback.parameter?.value = AUValue(feedback)
    }

    func setDelayMix(_ mix: Float) {
        config.delayMix = mix
        delayMixer?.$balance.parameter?.value = AUValue(mix)
    }

    func setFilterCutoff(_ cutoff: Float) {
        config.filterCutoff = cutoff
        filter?.$cutoffFrequency.parameter?.value = AUValue(cutoff)
    }
}
