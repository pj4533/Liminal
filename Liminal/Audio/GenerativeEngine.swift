import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation
import Combine
import OSLog
import AVFoundation

/// Coordinates multiple voice layers with generative note selection.
/// Three voices: bass drone, mid pad, high shimmer - each with own timing and behavior.
/// Simple controls: delay, reverb, notes - all apply immediately.
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
        let noteChangeInterval: ClosedRange<Double>
        let noteDuration: ClosedRange<Double>?
        let silenceGap: ClosedRange<Double>?
        let waveform: Table
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
    private var drift: ParameterDrift?
    private var driftTimer: Timer?

    // Mutable shimmer gap - controlled by notes slider
    private var shimmerGapRange: ClosedRange<Double> = 2.0...5.0

    /// Current musical scale - changes apply to new notes
    @Published var currentScale: ScaleType = .pentatonicMajor {
        didSet {
            scale = Scale(type: currentScale, rootMIDI: 48)
            rebuildMarkovChains()
            let name = currentScale.rawValue
            LMLog.audio.debug("🎼 Scale: \(name)")
        }
    }

    // MARK: - Events

    /// Fires when a shimmer note plays
    let shimmerNotePlayed = PassthroughSubject<Int, Never>()

    // MARK: - Published State

    @Published private(set) var isRunning = false

    /// Delay amount (0-1): higher = more delay/echo
    @Published var delay: Float = 0.5 {
        didSet {
            let feedback = 0.3 + delay * 0.5   // 0.3 to 0.8
            let mix = 0.2 + delay * 0.5        // 0.2 to 0.7
            effects?.setDelayFeedback(feedback)
            effects?.setDelayMix(mix)
            let pct = delay * 100
            LMLog.audio.debug("🎚️ Delay: \(String(format: "%.0f", pct))%")
        }
    }

    /// Reverb amount (0-1): higher = bigger reverb
    @Published var reverb: Float = 0.5 {
        didSet {
            let mix = 0.3 + reverb * 0.6  // 0.3 to 0.9
            effects?.setReverbMix(mix)
            let pct = reverb * 100
            LMLog.audio.debug("🎚️ Reverb: \(String(format: "%.0f", pct))%")
        }
    }

    /// Notes frequency (0-1): higher = more shimmer notes
    @Published var notes: Float = 0.5 {
        didSet {
            // Invert: high value = short gap (more notes)
            let minGap = 0.5 + (1.0 - Double(notes)) * 2.0   // 0.5 to 2.5
            let maxGap = 2.0 + (1.0 - Double(notes)) * 6.0   // 2.0 to 8.0
            shimmerGapRange = minGap...maxGap
            let pct = notes * 100
            LMLog.audio.debug("🎚️ Notes: \(String(format: "%.0f", pct))% (gap \(String(format: "%.1f", minGap))-\(String(format: "%.1f", maxGap))s)")
        }
    }

    // MARK: - Init

    init() {
        self.scale = Scale(type: .pentatonicMajor, rootMIDI: 48)
        setupVoices()
        setupEffects()
    }

    // MARK: - Setup

    private func setupVoices() {
        let configs = voiceConfigs()

        for (index, config) in configs.enumerated() {
            let voiceConfig = VoiceLayer.Config(
                oscillatorCount: config.oscillatorCount,
                detuneAmount: config.detuneAmount,
                attackTime: config.attackTime,
                releaseTime: config.releaseTime,
                amplitude: config.amplitude,
                waveform: config.waveform
            )
            let voice = VoiceLayer(config: voiceConfig)
            voices.append(voice)
            voiceMixer.addInput(voice.output)

            let degreeCount = scale.type.intervals.count
            let chain: MarkovChain
            switch index {
            case 0: chain = MarkovChain.bassDrone(degreeCount: degreeCount)
            case 1: chain = MarkovChain.midPad(degreeCount: degreeCount)
            default: chain = MarkovChain.highShimmer(degreeCount: degreeCount)
            }
            chains.append(chain)

            LMLog.audio.debug("🎹 Created \(config.name) voice")
        }
    }

    private func setupEffects() {
        let effectsConfig = EffectsChain.Config(
            reverbMix: 0.6,
            reverbFeedback: 0.92,
            delayTime: 0.5,
            delayFeedback: 0.55,
            delayMix: 0.45
        )
        effects = EffectsChain(input: voiceMixer, config: effectsConfig)
        engine.output = effects?.output ?? voiceMixer
    }

    private func rebuildMarkovChains() {
        let degreeCount = scale.type.intervals.count
        chains = [
            MarkovChain.bassDrone(degreeCount: degreeCount),
            MarkovChain.midPad(degreeCount: degreeCount),
            MarkovChain.highShimmer(degreeCount: degreeCount)
        ]
    }

    // MARK: - Audio Session (visionOS)

    #if os(visionOS)
    /// Configure audio session for visionOS stability
    /// visionOS requires larger buffers and explicit session config to avoid underruns
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Playback category with mix option (required for visionOS)
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])

        // visionOS prefers 48kHz - avoids resampling overhead
        try session.setPreferredSampleRate(48000)

        // Bypass spatial audio processing (we're doing stereo ambient)
        try session.setIntendedSpatialExperience(.bypassed)

        // Request larger buffer for stability - visionOS prioritizes 90fps rendering
        // Try 100ms for maximum stability (latency irrelevant for ambient)
        let requestedBuffer: TimeInterval = 0.1
        try session.setPreferredIOBufferDuration(requestedBuffer)

        // Activate AFTER setting preferences
        try session.setActive(true)

        // Some systems need buffer set again after activation
        try session.setPreferredIOBufferDuration(requestedBuffer)

        // Log actual values granted by the system
        let actualBuffer = session.ioBufferDuration
        let actualRate = session.sampleRate
        let bufferMatch = abs(actualBuffer - requestedBuffer) < 0.001 ? "✅" : "⚠️ MISMATCH"

        LMLog.audio.info("🎧 visionOS audio: requested=\(String(format: "%.3f", requestedBuffer))s, granted=\(String(format: "%.3f", actualBuffer))s \(bufferMatch), rate=\(actualRate)Hz")
    }
    #endif

    // MARK: - Control

    func start() {
        guard !isRunning else { return }

        do {
            #if os(visionOS)
            try configureAudioSession()
            #endif

            try engine.start()

            let configs = voiceConfigs()
            for (index, voice) in voices.enumerated() {
                let config = configs[index]
                let initialNote = scale.randomNote(lowMIDI: config.lowMIDI, highMIDI: config.highMIDI)
                voice.setFrequency(Scale.midiToFrequency(initialNote))

                if config.noteDuration == nil {
                    voice.start()
                    scheduleNoteChanges(voiceIndex: index, config: config)
                } else {
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
            startDrift()
            LMLog.audio.info("🎵 Engine started")
        } catch {
            LMLog.audio.error("❌ Failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopDrift()
        noteTimers.forEach { $0.invalidate() }
        noteTimers.removeAll()
        voices.forEach { $0.stop() }
        isRunning = false
        LMLog.audio.info("🛑 Engine stopped")
    }

    func shutdown() {
        stop()
        engine.stop()
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

    /// Consonant intervals in semitones for harmonic splitting
    private static let consonantIntervals: [Int] = [7, 12, 3, 4]  // P5, octave, m3, M3

    private func changeNote(voiceIndex: Int, config: VoiceConfig) {
        guard isRunning, voiceIndex < voices.count, voiceIndex < chains.count else { return }

        let chain = chains[voiceIndex]
        let degree = chain.next()

        let availableNotes = scale.notesInRange(lowMIDI: config.lowMIDI, highMIDI: config.highMIDI)
        guard !availableNotes.isEmpty else { return }

        let noteIndex = degree % availableNotes.count
        var newNote = availableNotes[noteIndex]

        // Octave displacement: ~10% chance for bass (0) or mid (1) voices
        if voiceIndex <= 1 && Double.random(in: 0...1) < 0.10 {
            let octaveShifted = newNote + 12
            // Only shift if it stays within a reasonable range
            if octaveShifted <= config.highMIDI + 12 {
                newNote = octaveShifted
                LMLog.audio.debug("🎵 Octave jump: \(config.name) MIDI \(newNote - 12) → \(newNote)")
            }
        }

        let frequency = Scale.midiToFrequency(newNote)
        let voice = voices[voiceIndex]

        if let noteDurationRange = config.noteDuration {
            // Staccato voice (shimmer)
            voice.setFrequency(frequency)
            voice.setIntervalFrequency(nil)
            voice.start()

            let noteDuration = Double.random(in: noteDurationRange)
            LMLog.audio.debug("✨ Shimmer: MIDI \(newNote)")

            if voiceIndex == 2 {
                shimmerNotePlayed.send(newNote)
            }

            let noteOffTimer = Timer.scheduledTimer(withTimeInterval: noteDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.voices[voiceIndex].stop()
                }
            }
            noteTimers.append(noteOffTimer)

            // Use current shimmerGapRange (controlled by notes slider)
            let silenceGap = Double.random(in: shimmerGapRange)
            let nextNoteDelay = noteDuration + silenceGap

            let nextTimer = Timer.scheduledTimer(withTimeInterval: nextNoteDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.changeNote(voiceIndex: voiceIndex, config: config)
                }
            }
            noteTimers.append(nextTimer)
        } else {
            // Sustained voice
            voice.setFrequency(frequency)

            // Harmonic intervals: ~25% chance for mid voice (index 1)
            if voiceIndex == 1 && Double.random(in: 0...1) < 0.25 {
                let interval = Self.consonantIntervals.randomElement() ?? 7
                let intervalNote = newNote + interval
                let intervalFreq = Scale.midiToFrequency(intervalNote)
                voice.setIntervalFrequency(intervalFreq)
                LMLog.audio.debug("🎶 Interval: Mid MIDI \(newNote) + \(interval) semitones")
            } else {
                voice.setIntervalFrequency(nil)
            }

            scheduleNoteChanges(voiceIndex: voiceIndex, config: config)
        }
    }

    // MARK: - Parameter Drift

    private var driftStartTime: Date = Date()

    private func startDrift() {
        drift = ParameterDrift()
        driftStartTime = Date()

        // Fire at 10Hz — smooth enough for parameter changes, light on CPU
        driftTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.applyDrift()
            }
        }
        LMLog.audio.debug("🌊 Parameter drift started")
    }

    private func stopDrift() {
        driftTimer?.invalidate()
        driftTimer = nil
        drift = nil
    }

    private func applyDrift() {
        guard let drift else { return }

        let t = Float(Date().timeIntervalSince(driftStartTime))

        // Effects parameter drift — modulate ±15% around slider center
        let reverbCenter = 0.3 + reverb * 0.6
        let driftedReverb = ParameterDrift.apply(center: reverbCenter, drift: drift.reverbMix.value(at: t), range: 0.15)
        effects?.setReverbMix(driftedReverb)

        let delayFbCenter = 0.3 + delay * 0.5
        let driftedDelayFb = ParameterDrift.apply(center: delayFbCenter, drift: drift.delayFeedback.value(at: t), range: 0.15)
        effects?.setDelayFeedback(driftedDelayFb)

        let delayMixCenter = 0.2 + delay * 0.5
        let driftedDelayMix = ParameterDrift.apply(center: delayMixCenter, drift: drift.delayMix.value(at: t), range: 0.15)
        effects?.setDelayMix(driftedDelayMix)

        // Filter cutoff sweep: 3000-12000Hz mapped from drift 0..1
        let filterDrift = (drift.filterCutoff.value(at: t) + 1.0) / 2.0  // normalize to 0..1
        let cutoff = 3000.0 + filterDrift * 9000.0
        effects?.setFilterCutoff(cutoff)

        // Voice amplitude breathing
        guard voices.count >= 3 else { return }
        let bassAmp = ParameterDrift.applyAmplitude(center: 0.25, drift: drift.bassAmplitude.value(at: t), low: 0.18, high: 0.28)
        voices[0].setAmplitude(bassAmp)

        let midAmp = ParameterDrift.applyAmplitude(center: 0.20, drift: drift.midAmplitude.value(at: t), low: 0.14, high: 0.23)
        voices[1].setAmplitude(midAmp)

        let shimmerAmp = ParameterDrift.applyAmplitude(center: 0.08, drift: drift.shimmerAmplitude.value(at: t), low: 0.05, high: 0.10)
        voices[2].setAmplitude(shimmerAmp)
    }

    // MARK: - Helpers

    private func voiceConfigs() -> [VoiceConfig] {
        [
            VoiceConfig(name: "Bass", oscillatorCount: 2, detuneAmount: 0.008,
                       attackTime: 4.0, releaseTime: 8.0, amplitude: 0.25,
                       lowMIDI: 36, highMIDI: 48, noteChangeInterval: 8.0...15.0,
                       noteDuration: nil, silenceGap: nil, waveform: Table(.sine)),
            VoiceConfig(name: "Mid", oscillatorCount: 4, detuneAmount: 0.015,
                       attackTime: 2.5, releaseTime: 6.0, amplitude: 0.2,
                       lowMIDI: 48, highMIDI: 72, noteChangeInterval: 4.0...8.0,
                       noteDuration: nil, silenceGap: nil, waveform: Table(.triangle)),
            VoiceConfig(name: "Shimmer", oscillatorCount: 1, detuneAmount: 0.0,
                       attackTime: 0.01, releaseTime: 0.3, amplitude: 0.08,
                       lowMIDI: 72, highMIDI: 84, noteChangeInterval: 3.0...6.0,
                       noteDuration: 0.05...0.15, silenceGap: nil, waveform: Table(.sine))
        ]
    }
}
