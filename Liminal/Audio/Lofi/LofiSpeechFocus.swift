import AVFoundation
import SoundAnalysis
import Synchronization

/// Per-picture speech evidence. The footage worker owns each analyzer and only
/// processes the portion of the soundtrack which the sampler can actually use.
nonisolated final class LofiSpeechFocus: NSObject, SNResultsObserving {
    struct Window {
        let range: Range<Double>
        let speech: Double
        let music: Double
        let singing: Double
    }

    private let windows = Mutex<[Window]>([])
    private let finished = DispatchSemaphore(value: 0)

    static func classify(_ source: AVAudioPCMBuffer, seconds: Double) -> [Window] {
        let count = min(Int(source.frameLength), Int(max(0, min(32, seconds)) * source.format.sampleRate))
        guard count > 0, let channel = source.floatChannelData?[0],
              let mono = AVAudioFormat(standardFormatWithSampleRate: source.format.sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(count)),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: channel, count: count)
        let observer = LofiSpeechFocus()
        let analyzer = SNAudioStreamAnalyzer(format: mono)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        do { try analyzer.add(request, withObserver: observer) } catch { return [] }
        analyzer.analyze(input, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        _ = observer.finished.wait(timeout: .now() + 0.8)
        analyzer.removeAllRequests()
        return observer.windows.withLock { $0 }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        func confidence(_ id: String) -> Double { result.classification(forIdentifier: id)?.confidence ?? 0 }
        let start = result.timeRange.start.seconds
        let end = CMTimeRangeGetEnd(result.timeRange).seconds
        guard start.isFinite, end.isFinite, start < end else { return }
        let window = Window(range: start..<end, speech: confidence("speech"), music: confidence("music"),
                            singing: max(confidence("singing"), confidence("choir_singing")))
        windows.withLock { $0.append(window) }
    }

    func requestDidComplete(_ request: SNRequest) { finished.signal() }
    func request(_ request: SNRequest, didFailWithError error: Error) { finished.signal() }

    /// Duration-weighted confidence lets spoken words over a music bed survive.
    /// In ambiguous material retain the envelope-based candidate at lower priority.
    static func weight(_ frames: Range<Int>, rate: Double, windows: [Window]) -> Float {
        let start = Double(frames.lowerBound) / rate
        let end = Double(frames.upperBound) / rate
        var total = 0.0, speech = 0.0, interference = 0.0
        for w in windows {
            let overlap = min(end, w.range.upperBound) - max(start, w.range.lowerBound)
            guard overlap > 0 else { continue }
            total += overlap
            speech += w.speech * overlap
            interference += max(w.singing, w.music * 0.82) * overlap
        }
        guard total > 0 else { return 1 }
        speech /= total
        interference /= total
        if interference > 0.36 && interference > speech * 2.2 { return 0 }
        return Float(0.28 + 1.8 * speech / (0.22 + speech + interference))
    }
}
