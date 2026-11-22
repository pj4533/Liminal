import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation
import Combine
import OSLog
import AVFoundation
import Synchronization

/// MainActor facade over the audio graph: the Lo-Fi transport and its stems, the film bed with its
/// conductor and mix bus, and the shared master. Builds the static graph once, starts and stops the
/// engine, recovers from route changes, and forwards controls to the conductor's queue without ever
/// waiting on it.
@MainActor
final class GenerativeEngine: ObservableObject {

    // MARK: - Audio Components

    let engine = AudioEngine()
    /// The archive film's sound strip.
    let archive: ArchiveVoice
    let archiveMix: ArchiveMixBus
    let conductor: ArchiveConductor
    let master: LofiMasterBus
    /// Unity mixer after the master chain, the graph's final node: the recorder taps it
    /// (docs/recording.md). The calibration keeps its own tap on `master.output`.
    let recordTap: Mixer
    let seed: UInt64
    private var configurationObserver: AnyCancellable?
    private var recovery: Task<Void, Never>?
    private let lofi: LofiPlayback

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published private(set) var isPlaybackReady = false

    /// Tempo and pinned scale (nil scale = Auto), read by the transport at its next take.
    var options = LofiOptions() {
        didSet { lofi.options = options }
    }

    // MARK: - Hooks for the render loop and the footage service

    nonisolated var musicState: MusicStateBus { lofi.stateBus }
    /// Posts a control from any thread (the archive footage service sends its sound this way).
    nonisolated func post(_ control: ArchiveControl) {
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
        let seed = seed ?? DebugLaunchOptions.musicSeed ?? UInt64.random(in: 1...UInt64.max)
        self.seed = seed
        let archive = ArchiveVoice()
        self.archive = archive
        archiveMix = ArchiveMixBus(strip: archive.strip, seed: seed)
        conductor = ArchiveConductor(mix: archiveMix, voice: archive)
        lofi = LofiPlayback(seed: seed ^ 0x4C4F4649, sampleRate: archive.format.sampleRate, dialogue: archive.chopOutput)
        let duck = lofi.duckTargets
        archive.attachMusicDuck(lead: duck.lead, mids: duck.mids, space: duck.space)
        master = LofiMasterBus(archive: archiveMix.output, lofi: lofi.output)
        lofi.onPhrase = { [weak conductor, weak master] duration, index, seed in
            conductor?.updateTempo(beatDuration: duration, phrase: index, seed: seed)
            master?.setCalibrationBeatDuration(duration)
        }
        recordTap = Mixer(master.output)
        engine.output = recordTap
        configurationObserver = NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange, object: engine.avEngine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recoverStoppedGraph() }
        let ms = Date().timeIntervalSince(t0) * 1000
        LMLog.audio.info("🎛️ Music graph built in \(String(format: "%.0f", ms)) ms, seed \(seed)")
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
        // Larger buffer for stability: visionOS prioritizes 90fps rendering, and the transport schedules ahead
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
            startTransport()
            LMLog.audio.info("🎵 Engine started")
        } catch {
            LMLog.audio.error("❌ Failed to start: \(error.localizedDescription)")
        }
    }

    /// A route reconfiguration can stop AVAudioEngine and discard the players' schedules.
    /// Re-arm the score and its visual clock together once the replacement route is ready.
    private func recoverStoppedGraph() {
        guard isRunning, !engine.avEngine.isRunning, recovery == nil else { return }
        LMLog.audio.warning("Audio route changed while playing; rebuilding playback schedules")
        isPlaybackReady = false
        lofi.stop(immediately: true)
        conductor.stop(fade: 0)
        master.stopCalibration()
        recovery = Task { [weak self] in
            for delay in [0.15, 0.4, 1.0] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, isRunning else { return }
                do {
                    if !engine.avEngine.isRunning { try engine.start() }
                    recovery = nil
                    startTransport()
                    RecordingController.shared.routeRecovered(audio: self)
                    LMLog.audio.info("Audio route recovered; playback restarted")
                    return
                } catch {
                    LMLog.audio.warning("Audio route restart failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            self?.stop()
        }
    }

    /// Fades out over 2 s; the audio engine keeps running so a restart is instant.
    func stop() {
        guard isRunning else { return }
        recovery?.cancel()
        recovery = nil
        conductor.stop(fade: 2.0)
        lofi.stop()
        master.stopCalibration()
        isPlaybackReady = false
        isRunning = false
        LMLog.audio.info("🛑 Engine stopped")
    }

    func shutdown() {
        recovery?.cancel()
        recovery = nil
        conductor.stop(fade: 0.05)
        lofi.stop(immediately: true)
        master.stopCalibration()
        isPlaybackReady = false
        isRunning = false
        engine.stop()
    }

    /// Arms the transport; the film's clock starts on its first audible downbeat.
    private func startTransport() {
        isPlaybackReady = false
        lofi.start(onReady: { [weak self] clock, seed in
            guard let self, isRunning else { return }
            conductor.start(beatDuration: clock.beatDuration, pattern: .choose(seed: seed, phrase: 0))
            master.setCalibrationBeatDuration(clock.beatDuration)
            master.startCalibration()
            isPlaybackReady = true
        }, onFailure: { [weak self] in self?.stop() })
    }
}
