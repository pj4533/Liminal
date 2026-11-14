import AudioKit
import AVFoundation
import Foundation

/// Simulated clock used instead of `Timer` when rendering offline (faster than realtime).
/// Events fire in time order; `advance(to:)` runs everything due up to the given time.
@MainActor
final class OfflineClock {
    private struct Event { let time: Double; let seq: Int; let block: @MainActor () -> Void }
    private var events: [Event] = []
    private var seq = 0
    private(set) var now: Double = 0

    func schedule(after delay: Double, _ block: @escaping @MainActor () -> Void) {
        seq += 1
        events.append(Event(time: now + delay, seq: seq, block: block))
    }

    func advance(to target: Double) {
        while let idx = events.indices.min(by: { (events[$0].time, events[$0].seq) < (events[$1].time, events[$1].seq) }),
              events[idx].time <= target {
            let e = events.remove(at: idx)
            now = e.time
            e.block()
        }
        now = target
    }
}

extension GenerativeEngine {

    /// Render the generative engine to a 32-bit float stereo WAV, as fast as the CPU allows.
    /// Notes/drift run on a simulated clock stepped every 50 ms of audio (drift every 100 ms like realtime).
    /// Used by LiminalTests/MusicRenderTests and scripts/render-music.sh.
    /// - Parameters:
    ///   - configure: optional hook run after construction/before start (set sliders, scale, etc.)
    func renderOffline(seconds: Double, to url: URL, configure: ((GenerativeEngine) -> Void)? = nil) throws {
        let clock = OfflineClock()
        offlineClock = clock
        configure?(self)

        let av = engine.avEngine
        let format = AudioKit.Settings.audioFormat  // AudioKit default stereo float (48 kHz here)
        if av.isRunning { av.stop() }
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        av.reset()
        start()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: av.manualRenderingFormat, frameCapacity: 4096) else { return }

        let stepFrames: AVAudioFrameCount = 2400  // 50 ms @ 48k (step time derived from actual rate below)
        let stepSec = Double(stepFrames) / format.sampleRate
        let totalFrames = AVAudioFramePosition(seconds * format.sampleRate)
        var step = 0
        while av.manualRenderingSampleTime < totalFrames {
            clock.advance(to: Double(step) * stepSec)
            if step % 2 == 0 { applyDrift() }
            let status = try av.renderOffline(stepFrames, to: buffer)
            if status == .success { try file.write(from: buffer) }
            step += 1
        }
        stop()
        av.stop()
        offlineClock = nil
    }
}
