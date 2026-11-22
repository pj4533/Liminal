import AudioKit
import AVFoundation
import Foundation

extension GenerativeEngine {

    /// Test hook: render the graph to a 32-bit float stereo WAV as fast as the CPU allows. The film's
    /// conductor is advanced directly every 20 ms of rendered audio, exactly as its realtime timer does.
    /// - Parameters:
    ///   - beatDuration: the echo tempo the film bed starts on.
    ///   - configure: optional hook run before the render starts.
    ///   - onStep: optional hook called with the render time before every 20 ms step (timed controls,
    ///     e.g. the archive footage sound).
    func renderOffline(seconds: Double, to url: URL, beatDuration: Double,
                       configure: ((GenerativeEngine) -> Void)? = nil,
                       onStep: ((Double) -> Void)? = nil) throws {
        configure?(self)
        let av = engine.avEngine
        let format = AudioKit.Settings.audioFormat
        if av.isRunning { av.stop() }
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        av.reset()
        try engine.start()
        conductor.beginOffline(beatDuration: beatDuration)

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
        while av.manualRenderingSampleTime < totalFrames {
            onStep?(Double(step) * stepSec)
            conductor.advance(to: Double(step) * stepSec)
            let status = try av.renderOffline(stepFrames, to: buffer)
            if status == .success { try file.write(from: buffer) }
            step += 1
        }
        av.stop()
    }
}
