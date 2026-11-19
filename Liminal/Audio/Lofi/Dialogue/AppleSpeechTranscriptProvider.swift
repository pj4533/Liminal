import AVFoundation
import Foundation
import OSLog
import Synchronization
#if canImport(Speech)
import CoreMedia
import Speech
#endif

/// On-device transcription behind `TranscriptProvider` (plan 7): readiness gates, then the
/// source's first `maximumSeconds` through an analysis function, raced against the deadline.
/// Every failure, timeout or cancellation is nil. The framework sits behind injected closures,
/// so tests exercise the gates, the deadline and the film-second mapping without it; `live()`
/// wires Apple's SpeechAnalyzer and SpeechTranscriber.
nonisolated struct AppleSpeechTranscriptProvider: TranscriptProvider {
    /// One recognized run, in seconds from the first fed sample (analyzer time).
    struct TimedWord: Sendable, Equatable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Float?
    }

    struct Recognition: Sendable {
        let words: [TimedWord]
        let modelVersion: String
    }

    /// Recognizes `frames` frames from frame 0 of the source in a BCP 47 locale. Must stop
    /// promptly when its task is cancelled; the provider returns at the deadline either way.
    typealias Analyze = @Sendable (_ source: DialogueSource, _ frames: Int, _ locale: String) async throws -> Recognition

    let environment: DialogueSpeechEnvironment
    let locale: String
    let maximumSeconds: Double
    let analyze: Analyze

    init(environment: DialogueSpeechEnvironment, locale: String = DialogueTranscription.localeIdentifier,
         maximumSeconds: Double = DialogueTranscription.maximumSeconds, analyze: @escaping Analyze) {
        self.environment = environment
        self.locale = locale
        self.maximumSeconds = maximumSeconds
        self.analyze = analyze
    }

    func transcript(for source: DialogueSource, deadline: ContinuousClock.Instant) async -> DialogueTranscript? {
        guard ContinuousClock().now < deadline, !Task.isCancelled else { return nil }
        let environment = environment, locale = locale, maximumSeconds = maximumSeconds, analyze = analyze
        return await Self.race(deadline: deadline) { () async -> DialogueTranscript? in
            let ready = await DialogueSpeechAssets.status(mode: .installedOnly, environment: environment, locale: locale)
            guard ready == .ready, !Task.isCancelled else { return nil }
            let frames = Self.fedFrames(source, maximumSeconds: maximumSeconds)
            guard frames > 0 else { return nil }
            let recognition: Recognition
            do {
                recognition = try await analyze(source, frames, locale)
            } catch is CancellationError {
                return nil
            } catch {
                Logger.transcription.info("Transcription failed: \(String(describing: error), privacy: .public)")
                return nil
            }
            guard !Task.isCancelled else { return nil }
            return Self.transcript(from: recognition, source: source, fedFrames: frames, locale: locale)
        }
    }

    static func fedFrames(_ source: DialogueSource, maximumSeconds: Double) -> Int {
        min(source.frameCount, Int((maximumSeconds * source.sampleRate).rounded(.down)))
    }

    /// Maps analyzer seconds to film seconds through the source clock. Words outside the fed
    /// range (with 20 ms of slack at the end), empty or reversed are dropped. No words is nil.
    static func transcript(from recognition: Recognition, source: DialogueSource, fedFrames: Int,
                           locale: String) -> DialogueTranscript? {
        let rate = source.sampleRate
        let fedSeconds = Double(fedFrames) / rate
        let words: [DialogueTranscript.Word] = recognition.words.compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.start.isFinite, word.end.isFinite, word.start >= 0, word.end > word.start,
                  word.start < fedSeconds, word.end <= fedSeconds + 0.02 else { return nil }
            let first = Int((word.start * rate).rounded())
            let last = min(fedFrames, Int((word.end * rate).rounded()))
            return DialogueTranscript.Word(text: text, start: source.sourceSeconds(frame: first),
                                           end: source.sourceSeconds(frame: last), confidence: word.confidence)
        }
        guard !words.isEmpty else { return nil }
        return DialogueTranscript(locale: locale, modelVersion: recognition.modelVersion, words: words)
    }

    /// Runs `body` at utility priority and returns its value, or nil at the deadline or when the
    /// caller is cancelled, whichever comes first. The losing work is cancelled and not awaited,
    /// so an analysis that is slow to stop cannot hold the caller past the deadline.
    static func race<T: Sendable>(deadline: ContinuousClock.Instant,
                                  _ body: @escaping @Sendable () async -> T?) async -> T? {
        let gate = RaceGate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                guard gate.install(continuation) else { return }
                let work = Task.detached(priority: .utility) { gate.finish(await body()) }
                let timer = Task.detached(priority: .utility) {
                    try? await ContinuousClock().sleep(until: deadline)
                    gate.finish(nil)
                }
                gate.track([work, timer])
            }
        } onCancel: {
            gate.finish(nil)
        }
    }
}

/// First caller of `finish` resumes the continuation; every tracked task is then cancelled.
private nonisolated final class RaceGate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var done = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// False when the race already ended (caller cancelled first); the continuation is resumed.
    func install(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        let ended = state.withLock { s -> Bool in
            if s.done { return true }
            s.continuation = continuation
            return false
        }
        if ended { continuation.resume(returning: nil) }
        return !ended
    }

    func track(_ tasks: [Task<Void, Never>]) {
        let ended = state.withLock { s -> Bool in
            if s.done { return true }
            s.tasks += tasks
            return false
        }
        if ended { tasks.forEach { $0.cancel() } }
    }

    func finish(_ value: T?) {
        let (continuation, tasks) = state.withLock { s -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) in
            guard !s.done else { return (nil, []) }
            s.done = true
            defer { s.continuation = nil; s.tasks = [] }
            return (s.continuation, s.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: value)
    }
}

private nonisolated extension Logger {
    static let transcription = Logger(subsystem: "com.saygoodnight.Liminal", category: "transcription")
}

#if canImport(Speech)
nonisolated extension AppleSpeechTranscriptProvider {
    /// The framework-backed provider, or nil where the OS has no SpeechAnalyzer.
    static func live() -> AppleSpeechTranscriptProvider? {
        guard #available(macOS 26, visionOS 26, *), let environment = liveEnvironment else { return nil }
        return AppleSpeechTranscriptProvider(environment: environment) { source, frames, locale in
            try await AppleSpeechRecognition.recognize(source, frames: frames, locale: locale)
        }
    }

    static var liveEnvironment: DialogueSpeechEnvironment? {
        guard #available(macOS 26, visionOS 26, *) else { return nil }
        return DialogueSpeechEnvironment(
            isAvailable: { SpeechTranscriber.isAvailable },
            supportedLocales: { await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) } },
            installedLocales: { await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) } })
    }

    /// Downloads and installs the transcriber's assets for `locale`. Only
    /// `DialogueSpeechAssets.requestInstallIfAllowed()` calls this.
    static func installModel(locale: String, progress: @escaping @Sendable (Double) -> Void) async {
        guard #available(macOS 26, visionOS 26, *) else { return }
        let transcriber = AppleSpeechRecognition.transcriber(locale: locale)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            let poll = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { poll.cancel() }
            Logger.transcription.info("Speech model download started for \(locale, privacy: .public)")
            try await request.downloadAndInstall()
            Logger.transcription.info("Speech model installed for \(locale, privacy: .public)")
        } catch {
            Logger.transcription.error("Speech model install failed: \(String(describing: error), privacy: .public)")
        }
    }
}

@available(macOS 26, visionOS 26, *)
nonisolated enum AppleSpeechRecognition {
    enum Failure: Error { case noAudioFormat, unsupportedBuffer, conversion }

    /// The framework exposes no transcriber model version; the OS build stands in for it.
    static var modelVersion: String { "SpeechTranscriber, \(ProcessInfo.processInfo.operatingSystemVersionString)" }

    private static let reserved = Mutex<Set<String>>([])

    /// Adds the installed locale to the app's reservations once per launch. Without it the
    /// framework logs "Cannot use modules with unallocated locales ... This will be an error in a
    /// future release" (macOS 27.2). Reserves an installed asset; the docs describe no download.
    static func reserveIfNeeded(locale: String) async {
        let first = reserved.withLock { $0.insert(locale).inserted }
        guard first else { return }
        do {
            try await AssetInventory.reserve(locale: Locale(identifier: locale))
        } catch {
            reserved.withLock { _ = $0.remove(locale) }
            Logger.transcription.info("Locale reservation failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func transcriber(locale: String) -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// Final results only, consumed concurrently from before the analysis starts. The input is
    /// one converted buffer fed through an AsyncStream, so analyzer time zero is source frame 0.
    static func recognize(_ source: DialogueSource, frames: Int, locale: String) async throws
        -> AppleSpeechTranscriptProvider.Recognition {
        await reserveIfNeeded(locale: locale)
        let transcriber = transcriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudioFormat
        }
        let audio = try convert(source, frames: frames, to: format)
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .lingering))
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [AppleSpeechTranscriptProvider.TimedWord].self) { group in
                group.addTask {
                    var words: [AppleSpeechTranscriptProvider.TimedWord] = []
                    for try await result in transcriber.results where result.isFinal {
                        words += Self.words(in: result)
                    }
                    return words
                }
                feed.yield(AnalyzerInput(buffer: audio))
                feed.finish()
                do {
                    if let last = try await analyzer.analyzeSequence(input) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                } catch {
                    await analyzer.cancelAndFinishNow()
                    group.cancelAll()
                    throw error
                }
                let words = try await group.next() ?? []
                try Task.checkCancellation()
                return AppleSpeechTranscriptProvider.Recognition(words: words, modelVersion: modelVersion)
            }
        } onCancel: {
            feed.finish()
            Task.detached(priority: .utility) { await analyzer.cancelAndFinishNow() }
        }
    }

    /// One word per attributed run that carries an audio time range.
    static func words(in result: SpeechTranscriber.Result) -> [AppleSpeechTranscriptProvider.TimedWord] {
        let text = result.text
        return text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return .init(text: word, start: range.start.seconds, end: range.end.seconds,
                         confidence: run.transcriptionConfidence.map { Float($0) })
        }
    }

    /// Channel 0 of the first `frames` frames, converted to the analyzer's format.
    static func convert(_ source: DialogueSource, frames: Int, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let rate = source.sampleRate
        guard frames > 0, let channel = source.buffer.floatChannelData?[0],
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = mono.floatChannelData?[0] else { throw Failure.unsupportedBuffer }
        let stride = source.buffer.stride
        for i in 0..<frames { out[i] = channel[i * stride] }
        mono.frameLength = AVAudioFrameCount(frames)
        guard let converter = AVAudioConverter(from: monoFormat, to: format),
              let converted = AVAudioPCMBuffer(pcmFormat: format,
                  frameCapacity: AVAudioFrameCount((Double(frames) * format.sampleRate / rate).rounded(.up)) + 4096)
        else { throw Failure.conversion }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, error == nil, converted.frameLength > 0 else { throw Failure.conversion }
        return converted
    }
}
#else
nonisolated extension AppleSpeechTranscriptProvider {
    static func live() -> AppleSpeechTranscriptProvider? { nil }
    static var liveEnvironment: DialogueSpeechEnvironment? { nil }
    static func installModel(locale: String, progress: @escaping @Sendable (Double) -> Void) async {}
}
#endif
