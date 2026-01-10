import AudioKit
import SoundpipeAudioKit
import AVFoundation
import Combine
import OSLog

/// The main audio engine for Liminal.
/// Manages voice layers, effects, and the audio graph.
@MainActor
final class LiminalAudioEngine: ObservableObject {

    // MARK: - Audio Components

    private let engine = AudioEngine()
    private var voice: VoiceLayer?
    private var effects: EffectsChain?

    // MARK: - State

    @Published private(set) var isRunning = false

    // MARK: - Init

    init() {
        setupAudio()
    }

    // MARK: - Setup

    private func setupAudio() {
        // Soft pad voice with detuned oscillators
        let voiceConfig = VoiceLayer.Config(
            oscillatorCount: 4,
            detuneAmount: 0.015,      // 1.5% spread for gentle chorusing
            attackTime: 2.5,          // slow fade in
            releaseTime: 6.0,         // long fade out
            amplitude: 0.25
        )

        let padVoice = VoiceLayer(config: voiceConfig)
        padVoice.setFrequency(220)    // A3
        self.voice = padVoice

        // Effects chain (reverb + delay)
        let effectsConfig = EffectsChain.Config(
            reverbMix: 0.5,           // 50% reverb
            reverbFeedback: 0.85,     // Long decay
            delayTime: 0.35,          // 350ms delay
            delayFeedback: 0.4,       // Moderate feedback
            delayMix: 0.25            // Subtle delay
        )

        let effectsChain = EffectsChain(input: padVoice.output, config: effectsConfig)
        self.effects = effectsChain
        engine.output = effectsChain.output
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }

        do {
            try engine.start()
            voice?.start()
            isRunning = true
            LMLog.audio.info("🎵 Engine started with soft pad + reverb/delay")
        } catch {
            LMLog.audio.error("❌ Failed to start engine: \(error.localizedDescription)")
        }
    }

    func stop() {
        voice?.stop()
        // Don't stop the engine - just close the envelope gate
        // The envelope will fade to silence naturally
        // Engine stays running (common for ambient apps that need instant restart)
        isRunning = false
        LMLog.audio.info("🛑 Voice stopping (envelope release phase)")
    }

    /// Fully shutdown the audio engine (call when app terminates)
    func shutdown() {
        voice?.stop()
        engine.stop()
        isRunning = false
        LMLog.audio.info("🔇 Engine shutdown complete")
    }

    // MARK: - Parameters

    func setFrequency(_ freq: Float) {
        voice?.setFrequency(freq)
    }

    func setAmplitude(_ amp: Float) {
        voice?.setAmplitude(amp)
    }
}
