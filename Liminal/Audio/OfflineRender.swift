import AudioKit
import AVFoundation
import Foundation

extension GenerativeEngine {

    /// Render the music to a 32-bit float stereo WAV as fast as the CPU allows (decision D5).
    /// The conductor is advanced directly every 20 ms of rendered audio, exactly as the realtime timer does.
    /// A score log JSON is written beside the WAV (`<name>.score.json`).
    /// - Parameters:
    ///   - limiterBypassed: verify gain staging without the safety limiter (section 11).
    ///   - configure: optional hook run before the render starts (set sliders, scale, etc.)
    ///   - onStep: optional hook called with the render time before every 20 ms step (timed controls, e.g.
    ///     the archive footage sound in `MusicRenderTests`).
    func renderOffline(seconds: Double, to url: URL, limiterBypassed: Bool = false, archiveBeatDuration: Double? = nil,
                       configure: ((GenerativeEngine) -> Void)? = nil,
                       onStep: ((Double) -> Void)? = nil) throws {
        configure?(self)
        outputCeiling.avAudioNode.auAudioUnit.shouldBypassEffect = limiterBypassed
        conductor.post(.limiterBypass(limiterBypassed))
        let log = ScoreLog()
        conductor.scoreLog = log
        let initialKey = conductor.field

        let av = engine.avEngine
        let format = AudioKit.Settings.audioFormat
        if av.isRunning { av.stop() }
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        av.reset()
        try engine.start()
        conductor.beginOffline(archiveBeatDuration: archiveBeatDuration)
        log.key(0, conductor.field)

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

        let stepFrames = AVAudioFrameCount((format.sampleRate * 0.02).rounded())   // 960 @ 48 kHz
        let stepSec = Double(stepFrames) / format.sampleRate
        let totalFrames = AVAudioFramePosition(seconds * format.sampleRate)
        var step = 0
        let t0 = Date()
        while av.manualRenderingSampleTime < totalFrames {
            onStep?(Double(step) * stepSec)
            conductor.advance(to: Double(step) * stepSec)
            let status = try av.renderOffline(stepFrames, to: buffer)
            if status == .success { try file.write(from: buffer) }
            step += 1
        }
        let wall = Date().timeIntervalSince(t0)
        av.stop()
        conductor.scoreLog = nil

        let ticks = conductor.tickStats
        let perf: [String: Any] = ["wall_s": wall, "realtime_factor": seconds / max(wall, 1e-6),
                                   "ticks": ticks.count, "tick_mean_ms": ticks.meanMs, "tick_max_ms": ticks.maxMs,
                                   "tick_max_at_s": ticks.maxAt, "ticks_over_2ms": ticks.slow]
        let scoreURL = url.deletingPathExtension().appendingPathExtension("score.json")
        try log.write(to: scoreURL, seed: seed, initialKey: initialKey, perf: perf)
    }
}

#if DEBUG
extension GenerativeEngine {
    /// Test hook: run the realtime conductor (its own queue and 20 ms timer) while rendering the graph in
    /// manual mode at wall-clock pace. Returns a one-line report.
    func realtimeSmoke(seconds: Double, pump: () -> Void) throws -> String {
        let av = engine.avEngine
        let format = AudioKit.Settings.audioFormat
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: av.manualRenderingFormat, frameCapacity: 4096) else { return "no buffer" }
        conductor.start()
        let t0 = Date()
        var peak: Float = 0
        var lastTime = -1.0, stalls = 0
        while Date().timeIntervalSince(t0) < seconds {
            let due = AVAudioFramePosition(Date().timeIntervalSince(t0) * format.sampleRate)
            while av.manualRenderingSampleTime < due {
                if try av.renderOffline(960, to: buffer) == .success, let ch = buffer.floatChannelData {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) }
                }
            }
            let st = musicState.read()
            if st.time == lastTime { stalls += 1 }
            lastTime = st.time
            pump()
        }
        let st = musicState.read()
        conductor.stop(fade: 0.2)
        Thread.sleep(forTimeInterval: 0.8)
        av.stop()
        let ok = st.time > seconds * 0.8 && peak > 0.001 && peak < 1
        return "\(ok ? "ok" : "FAIL") stateTime=\(String(format: "%.2f", st.time)) events=\(st.eventCount) " +
               "peak=\(String(format: "%.4f", peak)) loopsWithoutNewState=\(stalls) intensity=\(st.intensity)"
    }

}
#endif
