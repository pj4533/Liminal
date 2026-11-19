import AVFoundation
import SoundAnalysis
import Synchronization

/// Per-picture speech evidence. The footage worker owns each analyzer and only
/// processes the portion of the soundtrack which the sampler can actually use.
nonisolated final class LofiSpeechFocus: NSObject, SNResultsObserving, @unchecked Sendable {
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

    /// Bounded classification for the dialogue coordinator (plan 4.2 step 7). The analysis runs on a
    /// utility queue; whatever windows have arrived when `budget` seconds pass (or the task is
    /// cancelled) are returned at once, without blocking a thread on a semaphore.
    static func classify(_ source: AVAudioPCMBuffer, seconds: Double, budget: Double) async -> [Window] {
        let count = min(Int(source.frameLength), Int(max(0, min(32, seconds)) * source.format.sampleRate))
        guard count > 0, budget > 0, let channel = source.floatChannelData?[0],
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
        let delivery = Delivery()
        let work = Analysis(analyzer: analyzer, input: input)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[Window], Never>) in
                delivery.arm(continuation)
                observer.onComplete = { [observer] in delivery.resume(observer.windows.withLock { $0 }) }
                if Task.isCancelled { delivery.resume(observer.windows.withLock { $0 }) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget) { [observer] in
                    delivery.resume(observer.windows.withLock { $0 })
                }
                DispatchQueue.global(qos: .utility).async {
                    work.analyzer.analyze(work.input, atAudioFramePosition: 0)
                    work.analyzer.completeAnalysis()
                    work.analyzer.removeAllRequests()
                }
            }
        } onCancel: { [observer] in
            delivery.resume(observer.windows.withLock { $0 })
        }
    }

    /// Resumes a continuation exactly once, from whichever of completion, budget or cancellation comes first.
    private final class Delivery: @unchecked Sendable {
        private let state = Mutex<(continuation: CheckedContinuation<[Window], Never>?, pending: [Window]?)>((nil, nil))

        func arm(_ continuation: CheckedContinuation<[Window], Never>) {
            let early = state.withLock { s -> [Window]? in
                if let pending = s.pending { return pending }
                s.continuation = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        func resume(_ windows: [Window]) {
            let continuation = state.withLock { s -> CheckedContinuation<[Window], Never>? in
                defer { s.continuation = nil }
                if s.continuation == nil, s.pending == nil { s.pending = windows }
                return s.continuation
            }
            continuation?.resume(returning: windows)
        }
    }

    private struct Analysis: @unchecked Sendable {
        let analyzer: SNAudioStreamAnalyzer
        let input: AVAudioPCMBuffer
    }

    private let completion = Mutex<(@Sendable () -> Void)?>(nil)
    private var onComplete: (@Sendable () -> Void)? {
        get { completion.withLock { $0 } }
        set { completion.withLock { $0 = newValue } }
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

    func requestDidComplete(_ request: SNRequest) {
        finished.signal()
        onComplete?()
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        finished.signal()
        onComplete?()
    }

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
