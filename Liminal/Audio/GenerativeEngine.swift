import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation
import Combine
import OSLog
import AVFoundation
import Synchronization

/// MainActor facade over `MusicConductor` (decision D3). Builds the static audio graph once, starts and
/// stops the engine, and forwards controls to the conductor's queue without ever waiting on it.
/// The public surface used by both UIs is unchanged from the three-voice engine.
@MainActor
final class GenerativeEngine: ObservableObject {

    // MARK: - Audio Components

    let engine = AudioEngine()
    let conductor: MusicConductor
    let mix: MixBus
    let master: LofiMasterBus
    var outputCeiling: PeakLimiter { master.limiter }
    let layers: [MusicLayer]
    /// The archive film's sound strip (docs/plans/archive-video.md 4).
    let archive: ArchiveVoice
    let seed: UInt64
    private let lofi: LofiPlayback
    nonisolated private let lofiActive = Atomic<Bool>(false)

    // MARK: - Events

    /// Fires on the main queue for every drips note (the former shimmer voice). New consumers should
    /// read `musicState` instead.
    let shimmerNotePlayed = PassthroughSubject<Int, Never>()

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published private(set) var isPlaybackReady = false
    @Published var musicMode: MusicMode = .ambient {
        didSet { if isRunning && oldValue != musicMode { activateMusicMode() } }
    }

    func applyLofi(_ options: LofiOptions) {
        lofi.options.tempo = options.tempo
        lofi.options.scale = pinnedScale
    }

    @Published var style: MusicStyle.ID = .drift {
        didSet { conductor.post(.style(style)) }
    }

    /// nil = "Auto (evolving)": key and mode wander within the style's palette. A scale pins the mode
    /// (tonic C) and disables key drift (decision D30).
    @Published var pinnedScale: ScaleType? = nil {
        didSet {
            guard pinnedScale != oldValue else { return }
            conductor.post(.pinScale(pinnedScale))
            lofi.options.scale = pinnedScale
            LMLog.audio.debug("🎼 Scale: \(self.pinnedScale?.rawValue ?? "auto")")
        }
    }

    /// Legacy scale property (PASS 1 UIs). Setting it pins that scale, except that the old default
    /// (Pentatonic Major) means Auto until another scale is chosen (decision D31). New code uses
    /// `pinnedScale`.
    @Published var currentScale: ScaleType = .pentatonicMajor {
        didSet {
            if currentScale != GenerativeEngine.autoScaleSentinel { scaleTouched = true }
            pinnedScale = scaleTouched ? currentScale : nil
        }
    }

    static let autoScaleSentinel: ScaleType = .pentatonicMajor
    private var scaleTouched = false

    // MARK: - Hooks for the render loop and the image pipeline (section 8)

    nonisolated var musicState: MusicStateBus {
        lofiActive.load(ordering: .relaxed) ? lofi.stateBus : conductor.stateBus
    }
    nonisolated func setVisualMood(_ mood: VisualMood) { conductor.post(.visualMood(mood)) }
    nonisolated func imageDidChange(transitionDuration: Double) { conductor.post(.imageDidChange(transition: transitionDuration)) }
    nonisolated func setVisualActivity(_ value: Float) { conductor.post(.visualActivity(value)) }
    /// Posts a control from any thread (the archive footage service sends its sound this way).
    nonisolated func post(_ control: MusicControl) {
        conductor.post(control)
    }
    /// Format of the archive voice's buffers (the engine's format when the graph was built).
    nonisolated var archiveFormat: AVAudioFormat { archive.format }

    // MARK: - Init

    /// - Parameter seed: nil = random per launch; offline renders pass a fixed seed.
    init(seed: UInt64? = nil) {
        #if DEBUG
        LofiProviderProbe.runIfRequested()
        #endif
        let t0 = Date()
        let seed = seed ?? UInt64.random(in: 1...UInt64.max)
        self.seed = seed
        let initialLofiSeed = seed ^ 0x4C4F4649
        let layers: [MusicLayer] = [DroneLayer(), PadLayer(), LeadLayer(), DripsLayer(),
                                    KeysLayer(), AirLayer(), GrainLayer(), PluckLayer()]
        self.layers = layers
        var r = MusicRNG(seed: seed ^ 0xDE1A7)
        let archive = ArchiveVoice()
        self.archive = archive
        mix = MixBus(layers: layers.flatMap(\.allStrips) + [archive.strip], delayTime: Float(r.range(1.3...2.1)))   // slow, dark echoes (D92)
        conductor = MusicConductor(layers: layers, mix: mix, seed: seed, pinned: nil, archive: archive)
        lofi = LofiPlayback(seed: initialLofiSeed, sampleRate: archive.format.sampleRate)
        master = LofiMasterBus(archiveAndAmbient: mix.output, lofi: lofi.output)
        lofi.onPhrase = { [weak conductor, weak master] duration, index, seed in
            conductor?.updateArchiveTempo(beatDuration: duration, phrase: index, seed: seed)
            master?.setCalibrationBeatDuration(duration)
        }
        engine.output = master.output
        conductor.onNote = GenerativeEngine.noteForwarder(shimmerNotePlayed)
        let ms = Date().timeIntervalSince(t0) * 1000
        LMLog.audio.info("🎛️ Music graph built in \(String(format: "%.0f", ms)) ms, seed \(seed)")
    }

    /// Built outside MainActor so the closure is not MainActor-isolated: it runs on the music queue.
    nonisolated private static func noteForwarder(_ subject: PassthroughSubject<Int, Never>) -> (LayerID, Int) -> Void {
        nonisolated(unsafe) let subject = subject
        return { layer, midi in
            guard layer == .drips else { return }
            DispatchQueue.main.async { subject.send(midi) }
        }
    }

    // MARK: - Audio Session (visionOS)

    #if os(visionOS)
    /// Configure audio session for visionOS stability
    /// visionOS requires larger buffers and explicit session config to avoid underruns
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(48000)
        try session.setIntendedSpatialExperience(.bypassed)
        // Larger buffer for stability - visionOS prioritizes 90fps rendering; latency irrelevant for ambient
        let requestedBuffer: TimeInterval = 0.1
        try session.setPreferredIOBufferDuration(requestedBuffer)
        try session.setActive(true)
        try session.setPreferredIOBufferDuration(requestedBuffer)
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
            if !engine.avEngine.isRunning { try engine.start() }
            isRunning = true
            activateMusicMode()
            LMLog.audio.info("🎵 Engine started")
        } catch {
            LMLog.audio.error("❌ Failed to start: \(error.localizedDescription)")
        }
    }

    /// Fades out over 2 s; the audio engine keeps running so a restart is instant.
    func stop() {
        guard isRunning else { return }
        conductor.stop(fade: 2.0)
        lofi.stop()
        master.stopCalibration()
        lofiActive.store(false, ordering: .relaxed)
        isPlaybackReady = false
        isRunning = false
        LMLog.audio.info("🛑 Engine stopped")
    }

    func shutdown() {
        conductor.stop(fade: 0.05)
        lofi.stop(immediately: true)
        master.stopCalibration()
        lofiActive.store(false, ordering: .relaxed)
        isPlaybackReady = false
        isRunning = false
        engine.stop()
    }

    private func activateMusicMode() {
        if musicMode == .ambient {
            lofi.stop()
            master.stopCalibration()
            lofiActive.store(false, ordering: .relaxed)
            conductor.start()
            isPlaybackReady = true
        } else {
            if isPlaybackReady { conductor.stop(fade: 0.18) }
            isPlaybackReady = false
            lofiActive.store(false, ordering: .relaxed)
            lofi.start(onReady: { [weak self] clock, seed in
                guard let self, isRunning, musicMode == .lofi else { return }
                conductor.start(archiveBeatDuration: clock.beatDuration, pattern: .choose(seed: seed, phrase: 0))
                master.setCalibrationBeatDuration(clock.beatDuration)
                lofiActive.store(true, ordering: .relaxed)
                master.startCalibration()
                isPlaybackReady = true
            }, onFailure: { [weak self] in self?.stop() })
        }
    }
}
