//
//  RecordingController.swift
//  Liminal
//
//  The Record control (docs/recording.md): starts FrameRecorder at the renderer's picture size,
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

    enum Phase: Equatable { case idle, recording(since: Date), finishing, saved(String), failed(String) }

    @Published private(set) var phase: Phase = .idle
    private weak var tappedMixer: AVAudioNode?
    /// Debug recordings (-LiminalRecordAt) keep the file and skip Photos.
    private var skipPhotos = false
    private var debugScheduled = false
    private var starting = false

    var isRecording: Bool { if case .recording = phase { return true }; return false }

    /// Recording picture size: the macOS drawable at its current size, or the visionOS shell
    /// texture scaled back to the picture's 3:2 (2048 x 1366).
    static var pictureSize: (width: Int, height: Int) {
        #if os(visionOS)
        return (2048, 1366)
        #else
        let size = EffectsMetalView.lastDrawableSize
        if size.width >= 2, size.height >= 2 { return (Int(size.width), Int(size.height)) }
        return (1920, 1280)
        #endif
    }

    static var recordingsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recordings", isDirectory: true)
    }

    func toggle(audio: GenerativeEngine) {
        switch phase {
        case .recording: stop()
        case .finishing: break
        default: start(audio: audio)
        }
    }

    func start(audio: GenerativeEngine) {
        guard !isRecording, phase != .finishing, !starting else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            LMLog.visual.error("🔴 Recording could not start: no Metal device"); return
        }
        let avEngine = audio.engine.avEngine
        // The final mix: never `avEngine.mainMixerNode` (AudioKit does not use it, and touching it
        // makes AVAudioEngine connect one while running, which throws).
        let mixer = audio.recordTap.avAudioNode
        let format = mixer.outputFormat(forBus: 0)
        // Read once: the device query is synchronous (CLAUDE.md audio contract).
        let latency = avEngine.outputNode.presentationLatency
        let stamp = Self.fileStamp.string(from: Date())
        let url = Self.recordingsFolder.appendingPathComponent("Liminal \(stamp).mov")
        let size = Self.pictureSize
        let folder = Self.recordingsFolder
        let askPhotos = !skipPhotos
        starting = true
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
                controller.starting = false
                switch result {
                case .success:
                    controller.tappedMixer = mixer
                    controller.phase = .recording(since: Date())
                    // Ask for add-only Photos access up front, so the save at the end does not wait on a prompt.
                    if askPhotos { Task { _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly) } }
                case .failure(let error):
                    LMLog.visual.error("🔴 Recording could not start: \(error.localizedDescription, privacy: .public)")
                    controller.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        phase = .finishing
        tappedMixer?.removeTap(onBus: 0)
        tappedMixer = nil
        FrameRecorder.shared.stop { result in
            Task { @MainActor in
                switch result {
                case .failure(let error): RecordingController.shared.phase = .failed(error.localizedDescription)
                case .success(let (url, stats)):
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
    func scheduleDebugRecording(audio: GenerativeEngine) {
        guard let plan = DebugLaunchOptions.recordAt, !debugScheduled else { return }
        debugScheduled = true
        Task { @MainActor [weak self, weak audio] in
            while let audio, !audio.isPlaybackReady { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(plan.start))
            guard let self, let audio else { return }
            skipPhotos = !DebugLaunchOptions.recordToPhotos
            start(audio: audio)
            LMLog.general.info("🧪 DEBUG FLAG applied: LiminalRecordAt (recording \(plan.seconds, format: .fixed(precision: 0)) s)")
            try? await Task.sleep(for: .seconds(plan.seconds))
            stop()
        }
    }

    /// Playback stopped: finish the file rather than leave it open.
    func playbackStopped() { if isRecording { stop() } }

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
