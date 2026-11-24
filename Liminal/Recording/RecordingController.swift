//
//  RecordingController.swift
//  Liminal
//
//  The Record control (docs/recording.md): starts FrameRecorder at a 16:9 picture size,
//  taps the engine's main mixer (the final mix, after the master chain) and, when stopped, keeps the
//  movie in Documents/Recordings and adds it to the Photos library (add-only permission).
//

import AVFoundation
import AudioKit
import Combine
import Foundation
import Metal
import Photos
import OSLog

@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum Phase: Equatable { case idle, preparing, recording(since: Date), finishing, saved(String), failed(String) }

    @Published private(set) var phase: Phase = .idle
    private weak var tappedMixer: AVAudioNode?
    /// Debug recordings (-LiminalRecordAt) keep the file and skip Photos.
    private var skipPhotos = false
    private var debugScheduled = false
    private var stopAfterPreparation = false
    /// The engine being recorded (for the Lo-Fi grid in the finished log).
    private weak var recordingAudio: GenerativeEngine?

    var isRecording: Bool { if case .recording = phase { return true }; return false }

    /// The movie keeps its dimensions when the Mac window is resized during recording.
    static var pictureSize: (width: Int, height: Int) {
        if let size = DebugLaunchOptions.recordSize,
           let fitted = fittedPictureSize(width: size.width, height: size.height) { return fitted }
        #if os(visionOS)
        return (2048, 1152)
        #else
        let size = EffectsMetalView.lastDrawableSize
        return fittedPictureSize(width: Int(size.width), height: Int(size.height)) ?? (1920, 1080)
        #endif
    }

    /// Largest exact 16:9 size inside the bounds, with both dimensions even for the encoder.
    nonisolated static func fittedPictureSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        let widthStep = 2 * ImageFraming.displayAspectWidth
        let heightStep = 2 * ImageFraming.displayAspectHeight
        let scale = min(width / widthStep, height / heightStep)
        guard scale > 0 else { return nil }
        return (scale * widthStep, scale * heightStep)
    }

    static var recordingsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recordings", isDirectory: true)
    }

    func toggle(audio: GenerativeEngine) {
        switch phase {
        case .recording: stop()
        case .preparing, .finishing: break
        default: start(audio: audio)
        }
    }

    func start(audio: GenerativeEngine) {
        guard !isRecording, phase != .finishing, phase != .preparing else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            LMLog.visual.error("🔴 Recording could not start: no Metal device"); return
        }
        phase = .preparing
        stopAfterPreparation = false
        let askPhotos = !skipPhotos
        Task { @MainActor [weak self, weak audio] in
            // Ask for add-only Photos access before the recording, never during it: a first-run prompt
            // in the middle of a recording held up the first frame for seconds (D47).
            if askPhotos, PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }
            guard let self else { return }
            guard let audio, !stopAfterPreparation else {
                phase = .idle
                return
            }
            begin(audio: audio, device: device)
        }
    }

    private func begin(audio: GenerativeEngine, device: MTLDevice) {
        // The final mix: never `avEngine.mainMixerNode` (AudioKit does not use it, and touching it
        // makes AVAudioEngine connect one while running, which throws).
        let mixer = audio.recordTap.avAudioNode
        let format = mixer.outputFormat(forBus: 0)
        // Tap host time to heard: the latency downstream of the tapped node, the same mapping the Lo-Fi
        // transport uses (player.outputPresentationLatency). Read once: the device query is synchronous
        // (CLAUDE.md audio contract); routeRecovered() reads it again.
        let latency = mixer.outputPresentationLatency
        LMLog.visual.info("🔴 Recording audio latency \(latency * 1000, format: .fixed(precision: 1)) ms (output node \(audio.engine.avEngine.outputNode.presentationLatency * 1000, format: .fixed(precision: 1)) ms), \(format.sampleRate, format: .fixed(precision: 0)) Hz")
        let stamp = Self.fileStamp.string(from: Date())
        let url = Self.recordingsFolder.appendingPathComponent("Liminal \(stamp).mov")
        let size = Self.pictureSize
        let folder = Self.recordingsFolder
        recordingAudio = audio
        // Writer, encoder session and the copy pipeline are built off the main actor: on macOS the
        // main thread draws the frames, and this setup took about 0.4 s (2026-11-21).
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error>
            do {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FrameRecorder.shared.start(url: url, width: size.width, height: size.height, device: device,
                                               audioLatency: latency, sampleRate: format.sampleRate)
                let recorder = FrameRecorder.shared
                mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in recorder.audioTap(buffer, when) }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                let controller = RecordingController.shared
                switch result {
                case .success:
                    controller.tappedMixer = mixer
                    controller.phase = .recording(since: Date())
                    if controller.stopAfterPreparation { controller.stop() }
                case .failure(let error):
                    LMLog.visual.error("🔴 Recording could not start: \(error.localizedDescription, privacy: .public)")
                    controller.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// GenerativeEngine rebuilt the route while recording: the output latency may have changed.
    func routeRecovered(audio: GenerativeEngine) {
        guard isRecording else { return }
        let latency = audio.recordTap.avAudioNode.outputPresentationLatency
        FrameRecorder.shared.updateAudioLatency(latency)
        LMLog.visual.info("🔴 Recording: route recovered, audio latency \(latency * 1000, format: .fixed(precision: 1)) ms")
    }

    func stop() {
        guard isRecording else { return }
        phase = .finishing
        // The tap stays until the recorder has the audio up to the last frame (FrameRecorder.stop);
        // no recording can start while finishing, so `tappedMixer` is still this recording's.
        // The audible Lo-Fi grid (uptime of the take's downbeat as heard), to check the movie against.
        let grid = recordingAudio?.musicState.read().lofiTakeGrid
        recordingAudio = nil
        FrameRecorder.shared.stop { result in
            Task { @MainActor in
                RecordingController.shared.tappedMixer?.removeTap(onBus: 0)
                RecordingController.shared.tappedMixer = nil
                switch result {
                case .failure(let error): RecordingController.shared.phase = .failed(error.localizedDescription)
                case .success(let (url, stats)):
                    if let grid, let origin = stats.movieTime(uptime: grid.origin) {
                        LMLog.visual.info("⏹️ Recording clock: Lo-Fi take downbeat at movie \(origin, format: .fixed(precision: 4)) s, beat \(grid.beatDuration, format: .fixed(precision: 5)) s, T0 uptime \(stats.t0 ?? 0, format: .fixed(precision: 4)), drift \(stats.driftSeconds * 1000, format: .fixed(precision: 2)) ms")
                    }
                    if RecordingController.shared.skipPhotos {
                        LMLog.visual.info("⏹️ Debug recording kept at \(url.path, privacy: .public)")
                        RecordingController.shared.phase = .saved("Saved in Recordings")
                    } else {
                        RecordingController.shared.phase = await RecordingController.saveToPhotos(url, stats: stats)
                    }
                }
            }
        }
    }

    /// DEBUG: -LiminalRecordAt start,seconds. Called when the controls appear.
    func scheduleDebugRecording(audio: GenerativeEngine, pictureAvailable: @escaping @MainActor () -> Bool = { true }) {
        guard let plan = DebugLaunchOptions.recordAt, !debugScheduled else { return }
        debugScheduled = true
        Task { @MainActor [weak self, weak audio] in
            while let audio, !audio.isPlaybackReady, pictureAvailable() {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(plan.start))
            guard let self, let audio, audio.isPlaybackReady, pictureAvailable() else { return }
            skipPhotos = !DebugLaunchOptions.recordToPhotos
            start(audio: audio)
            LMLog.general.info("🧪 DEBUG FLAG applied: LiminalRecordAt (recording \(plan.seconds, format: .fixed(precision: 0)) s)")
            try? await Task.sleep(for: .seconds(plan.seconds))
            stop()
        }
    }

    /// Finish the file when playback stops or the immersive renderer disappears.
    func playbackStopped() {
        if phase == .preparing { stopAfterPreparation = true }
        if isRecording { stop() }
    }

    private static func saveToPhotos(_ url: URL, stats: FrameRecorder.Stats) async -> Phase {
        let minutes = Int(stats.seconds) / 60, seconds = Int(stats.seconds) % 60
        let length = String(format: "%d:%02d", minutes, seconds)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            LMLog.visual.warning("⏹️ Photos access \(status.rawValue): recording kept at \(url.path, privacy: .public)")
            return .saved("\(length) saved in Recordings (Photos access was not allowed)")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            LMLog.visual.info("⏹️ Recording added to Photos: \(url.lastPathComponent, privacy: .public)")
            return .saved("\(length) saved to Photos")
        } catch {
            LMLog.visual.error("⏹️ Photos save failed: \(error.localizedDescription, privacy: .public)")
            return .saved("\(length) saved in Recordings (Photos: \(error.localizedDescription))")
        }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}
