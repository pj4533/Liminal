import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import OSLog

/// A single voice layer with multiple detuned oscillators for rich, ambient pads.
/// Each voice has its own envelope for smooth attack/release.
final class VoiceLayer {

    // MARK: - Configuration

    struct Config {
        var oscillatorCount: Int = 4
        var detuneAmount: Float = 0.02      // 2% detune spread
        var attackTime: Float = 2.0          // seconds
        var releaseTime: Float = 8.0         // seconds
        var amplitude: Float = 0.15
    }

    // MARK: - Audio Nodes

    // Note: Using Oscillator (not DynamicOscillator) - DynamicOscillator has
    // wavetable discontinuity clicks when multiple oscillators' phases align
    private var oscillators: [Oscillator] = []
    private var envelope: AmplitudeEnvelope?
    private let mixer = Mixer()

    // MARK: - State

    private var baseFrequency: Float = 220
    private let config: Config

    /// The output node to connect to the audio graph
    var output: Node { envelope ?? mixer }

    // MARK: - Init

    init(config: Config = Config()) {
        self.config = config
        setupOscillators()
        setupEnvelope()
    }

    // MARK: - Setup

    private func setupOscillators() {
        // Create sine wavetable
        let sineTable = Table(.sine)

        // Create multiple oscillators with slight detuning
        for i in 0..<config.oscillatorCount {
            let osc = Oscillator(waveform: sineTable)

            // Spread detune: -detune to +detune
            let detuneRange = config.detuneAmount
            let normalizedPosition = Float(i) / Float(max(1, config.oscillatorCount - 1))
            let detuneFactor = 1.0 + (normalizedPosition * 2 - 1) * detuneRange

            osc.frequency = baseFrequency * detuneFactor
            osc.amplitude = config.amplitude / Float(config.oscillatorCount)

            oscillators.append(osc)
            mixer.addInput(osc)
        }

        LMLog.audio.debug("🎹 Created \(self.config.oscillatorCount) Oscillators (non-dynamic)")
    }

    private func setupEnvelope() {
        envelope = AmplitudeEnvelope(
            mixer,
            attackDuration: config.attackTime,
            decayDuration: 0.1,
            sustainLevel: 1.0,
            releaseDuration: config.releaseTime
        )
        LMLog.audio.debug("📈 Envelope: attack=\(self.config.attackTime)s, release=\(self.config.releaseTime)s")
    }

    // MARK: - Control

    func start() {
        // Log oscillator frequencies before starting
        for (i, osc) in oscillators.enumerated() {
            LMLog.audio.debug("🔊 Osc[\(i)] freq=\(osc.frequency), amp=\(osc.amplitude)")
        }

        oscillators.forEach { $0.start() }
        envelope?.openGate()
        LMLog.audio.info("🎵 Voice started at \(self.baseFrequency)Hz")
    }

    func stop() {
        envelope?.closeGate()
        // Oscillators keep running but envelope fades out
        LMLog.audio.info("🛑 Voice stopping (release phase)")
    }

    func setFrequency(_ freq: Float) {
        baseFrequency = freq

        // Update all oscillators with detune spread
        for (i, osc) in oscillators.enumerated() {
            let normalizedPosition = Float(i) / Float(max(1, oscillators.count - 1))
            let detuneFactor = 1.0 + (normalizedPosition * 2 - 1) * config.detuneAmount
            osc.frequency = AUValue(freq * detuneFactor)
        }
    }

    func setAmplitude(_ amp: Float) {
        let perOscAmp = amp / Float(oscillators.count)
        oscillators.forEach { $0.amplitude = AUValue(perOscAmp) }
    }
}
