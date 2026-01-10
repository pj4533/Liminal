import AudioKit
import SoundpipeAudioKit
import Foundation
import Combine
import OSLog

/// Coordinates multiple voice layers with generative note selection.
/// Three voices: bass drone, mid pad, high shimmer - each with own timing and behavior.
@MainActor
final class GenerativeEngine: ObservableObject {

    // MARK: - Voice Configuration

    struct VoiceConfig {
        let name: String
        let oscillatorCount: Int
        let detuneAmount: Float
        let attackTime: Float
        let releaseTime: Float
        let amplitude: Float
        let lowMIDI: Int
        let highMIDI: Int
        let noteChangeInterval: ClosedRange<Double>  // seconds between note changes
        let noteDuration: ClosedRange<Double>?       // for staccato voices (nil = sustained)
        let silenceGap: ClosedRange<Double>?         // silence between notes (nil = no gap)
    }

    // MARK: - Audio Components

    private let engine = AudioEngine()
    private var voices: [VoiceLayer] = []
    private var chains: [MarkovChain] = []
    private var effects: EffectsChain?
    private let voiceMixer = Mixer()

    // MARK: - Generative State

    private var scale: Scale
    private var noteTimers: [Timer] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Mood Integration

    let mood = MoodState()

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published var currentScale: ScaleType {
        didSet {
            scale = Scale(type: currentScale, rootMIDI: 48)  // C3
            LMLog.audio.info("Scale changed to \(self.currentScale.rawValue)")
        }
    }

    // MARK: - Init

    init() {
        self.scale = Scale(type: .pentatonicMajor, rootMIDI: 48)
        self.currentScale = .pentatonicMajor
        setupVoices()
        setupEffects()
        observeMoodChanges()
    }

    // MARK: - Setup

    private func setupVoices() {
        let configs: [VoiceConfig] = [
            // Bass drone: low, slow, sustained
            VoiceConfig(
                name: "Bass",
                oscillatorCount: 2,
                detuneAmount: 0.008,
                attackTime: 4.0,
                releaseTime: 8.0,
                amplitude: 0.25,
                lowMIDI: 36,
                highMIDI: 48,
                noteChangeInterval: 8.0...15.0,
                noteDuration: nil,
                silenceGap: nil
            ),
            // Mid pad: warmer, moderate movement
            VoiceConfig(
                name: "Mid",
                oscillatorCount: 4,
                detuneAmount: 0.015,
                attackTime: 2.5,
                releaseTime: 6.0,
                amplitude: 0.2,
                lowMIDI: 48,
                highMIDI: 72,
                noteChangeInterval: 4.0...8.0,
                noteDuration: nil,
                silenceGap: nil
            ),
            // Shimmer: short soft blips with heavy effects
            VoiceConfig(
                name: "Shimmer",
                oscillatorCount: 1,
                detuneAmount: 0.0,
                attackTime: 0.01,
                releaseTime: 0.3,
                amplitude: 0.08,
                lowMIDI: 72,
                highMIDI: 84,
                noteChangeInterval: 3.0...6.0,
                noteDuration: 0.05...0.15,
                silenceGap: 2.0...5.0
            )
        ]

        for (index, config) in configs.enumerated() {
            // Create voice layer
            let voiceConfig = VoiceLayer.Config(
                oscillatorCount: config.oscillatorCount,
                detuneAmount: config.detuneAmount,
                attackTime: config.attackTime,
                releaseTime: config.releaseTime,
                amplitude: config.amplitude
            )
            let voice = VoiceLayer(config: voiceConfig)
            voices.append(voice)
            voiceMixer.addInput(voice.output)

            // Create Markov chain
            let degreeCount = scale.type.intervals.count
            let chain: MarkovChain
            switch index {
            case 0: chain = MarkovChain.bassDrone(degreeCount: degreeCount)
            case 1: chain = MarkovChain.midPad(degreeCount: degreeCount)
            default: chain = MarkovChain.highShimmer(degreeCount: degreeCount)
            }
            chains.append(chain)

            LMLog.audio.debug("🎹 Created \(config.name) voice: MIDI \(config.lowMIDI)-\(config.highMIDI)")
        }
    }

    private func setupEffects() {
        // Heavy effects to turn short blips into ambient washes
        let effectsConfig = EffectsChain.Config(
            reverbMix: 0.75,          // lots of reverb
            reverbFeedback: 0.92,     // long decay
            delayTime: 0.5,           // half-second echoes
            delayFeedback: 0.65,      // more echo taps
            delayMix: 0.4             // prominent delay
        )
        effects = EffectsChain(input: voiceMixer, config: effectsConfig)
        engine.output = effects?.output ?? voiceMixer
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }

        do {
            try engine.start()

            // Start all voices with initial notes
            let configs = voiceConfigs()
            for (index, voice) in voices.enumerated() {
                let config = configs[index]
                let initialNote = scale.randomNote(lowMIDI: config.lowMIDI, highMIDI: config.highMIDI)
                voice.setFrequency(Scale.midiToFrequency(initialNote))

                // Staccato voices don't start continuously
                if config.noteDuration == nil {
                    voice.start()
                    scheduleNoteChanges(voiceIndex: index, config: config)
                } else {
                    // Schedule first note for staccato voices
                    let initialDelay = Double.random(in: 0.5...2.0)
                    let timer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
                        Task { @MainActor in
                            self?.changeNote(voiceIndex: index, config: config)
                        }
                    }
                    noteTimers.append(timer)
                }
            }

            isRunning = true
            LMLog.audio.info("🎵 Generative engine started with \(self.voices.count) voices")
        } catch {
            LMLog.audio.error("❌ Failed to start engine: \(error.localizedDescription)")
        }
    }

    func stop() {
        // Cancel all timers
        noteTimers.forEach { $0.invalidate() }
        noteTimers.removeAll()

        // Stop all voices
        voices.forEach { $0.stop() }

        isRunning = false
        LMLog.audio.info("🛑 Generative engine stopping")
    }

    func shutdown() {
        stop()
        engine.stop()
        LMLog.audio.info("🔇 Engine shutdown complete")
    }

    // MARK: - Generative Logic

    private func scheduleNoteChanges(voiceIndex: Int, config: VoiceConfig) {
        let interval = Double.random(in: config.noteChangeInterval)

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.changeNote(voiceIndex: voiceIndex, config: config)
            }
        }
        noteTimers.append(timer)
    }

    private func changeNote(voiceIndex: Int, config: VoiceConfig) {
        guard isRunning, voiceIndex < voices.count, voiceIndex < chains.count else { return }

        let chain = chains[voiceIndex]
        let degree = chain.next()

        // Get available notes and pick one near the degree
        let availableNotes = scale.notesInRange(lowMIDI: config.lowMIDI, highMIDI: config.highMIDI)
        guard !availableNotes.isEmpty else { return }

        // Map degree to actual note (wrapping within available range)
        let noteIndex = degree % availableNotes.count
        let newNote = availableNotes[noteIndex]
        let frequency = Scale.midiToFrequency(newNote)

        let voice = voices[voiceIndex]

        // Check if this is a staccato voice
        if let noteDurationRange = config.noteDuration,
           let silenceGapRange = config.silenceGap {
            // Staccato: play note for duration, then silence
            voice.setFrequency(frequency)
            voice.start()

            let noteDuration = Double.random(in: noteDurationRange)
            LMLog.audio.debug("✨ \(config.name): MIDI \(newNote) for \(String(format: "%.2f", noteDuration))s")

            // Schedule note off
            let noteOffTimer = Timer.scheduledTimer(withTimeInterval: noteDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.voices[voiceIndex].stop()
                }
            }
            noteTimers.append(noteOffTimer)

            // Schedule next note after silence gap
            let silenceGap = Double.random(in: silenceGapRange)
            let nextNoteDelay = noteDuration + silenceGap

            let nextTimer = Timer.scheduledTimer(withTimeInterval: nextNoteDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.changeNote(voiceIndex: voiceIndex, config: config)
                }
            }
            noteTimers.append(nextTimer)
        } else {
            // Sustained: just change frequency
            voice.setFrequency(frequency)
            LMLog.audio.debug("🎵 \(config.name): degree \(degree) → MIDI \(newNote) (\(String(format: "%.1f", frequency))Hz)")

            // Schedule next change
            scheduleNoteChanges(voiceIndex: voiceIndex, config: config)
        }
    }

    // MARK: - Mood Observation

    private func observeMoodChanges() {
        // Update effects when mood changes
        mood.$brightness.combineLatest(mood.$tension, mood.$density, mood.$movement)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.applyMoodToEffects()
            }
            .store(in: &cancellables)

        // Update scale when brightness/tension change significantly
        mood.$brightness.combineLatest(mood.$tension)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                let suggested = self.mood.suggestedScale
                if suggested != self.currentScale {
                    self.currentScale = suggested
                }
            }
            .store(in: &cancellables)
    }

    private func applyMoodToEffects() {
        effects?.setReverbMix(mood.reverbMix)
        effects?.setDelayFeedback(mood.delayFeedback)
        LMLog.audio.debug("🎨 Mood applied: reverb=\(self.mood.reverbMix), delay=\(self.mood.delayFeedback)")
    }

    // MARK: - Helpers

    private func voiceConfigs() -> [VoiceConfig] {
        [
            VoiceConfig(name: "Bass", oscillatorCount: 2, detuneAmount: 0.008,
                       attackTime: 4.0, releaseTime: 8.0, amplitude: 0.25,
                       lowMIDI: 36, highMIDI: 48, noteChangeInterval: 8.0...15.0,
                       noteDuration: nil, silenceGap: nil),
            VoiceConfig(name: "Mid", oscillatorCount: 4, detuneAmount: 0.015,
                       attackTime: 2.5, releaseTime: 6.0, amplitude: 0.2,
                       lowMIDI: 48, highMIDI: 72, noteChangeInterval: 4.0...8.0,
                       noteDuration: nil, silenceGap: nil),
            VoiceConfig(name: "Shimmer", oscillatorCount: 1, detuneAmount: 0.0,
                       attackTime: 0.01, releaseTime: 0.3, amplitude: 0.08,
                       lowMIDI: 72, highMIDI: 84, noteChangeInterval: 3.0...6.0,
                       noteDuration: 0.05...0.15, silenceGap: 2.0...5.0)
        ]
    }
}
