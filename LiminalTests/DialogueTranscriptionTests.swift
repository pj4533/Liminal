import AudioKit
import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Liminal

/// The on-device transcription provider (plan 7) over injected framework closures: every
/// failure is nil within the deadline plus 0.3 s, and analyzer time maps to film seconds.
@Suite(.serialized, .responsivePool) struct DialogueTranscriptionTests {
    private typealias Provider = AppleSpeechTranscriptProvider
    private static let slack: Swift.Duration = .milliseconds(300)

    private static let ready = DialogueSpeechEnvironment(isAvailable: { true }, supportedLocales: { ["en-US", "fr-FR"] },
                                                         installedLocales: { ["en-US"] })

    private static func source(seconds: Double = 2, sourceStart: Double = 0, rate: Double = 1) -> DialogueSource {
        let buffer = DialogueFixtures.buffer([Float](repeating: 0, count: Int(seconds * 48_000)), rate: 48_000)
        return DialogueSource(contentID: "transcription", cueToken: 1, buffer: buffer, sourceStart: sourceStart, rate: rate)
    }

    private static func words(_ list: [(String, Double, Double)]) -> Provider.Recognition {
        Provider.Recognition(words: list.map { Provider.TimedWord(text: $0.0, start: $0.1, end: $0.2, confidence: 0.8) },
                             modelVersion: "test")
    }

    /// Runs the provider with `deadline` from now; returns the result and how far past the deadline it came back.
    private static func run(_ provider: Provider, source: DialogueSource = source(),
                            deadline: Swift.Duration = .milliseconds(400)) async -> (DialogueTranscript?, Swift.Duration) {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        let result = await provider.transcript(for: source, deadline: end)
        return (result, clock.now - end)
    }

    /// Counts analysis calls, to prove the gates stop before analysis.
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func hit() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    // MARK: Failure modes

    @Test func unavailableIsNil() async {
        let calls = Counter()
        let env = DialogueSpeechEnvironment(isAvailable: { false }, supportedLocales: { ["en-US"] }, installedLocales: { ["en-US"] })
        let provider = Provider(environment: env) { _, _, _ in calls.hit(); return Self.words([("hi", 0.1, 0.3)]) }
        let (result, late) = await Self.run(provider)
        #expect(result == nil)
        #expect(late < Self.slack)
        #expect(calls.count == 0)
        #expect(await DialogueSpeechAssets.status(mode: .installedOnly, environment: env) == .unavailable)
    }

    @Test func unsupportedLocaleIsNil() async {
        let calls = Counter()
        let env = DialogueSpeechEnvironment(isAvailable: { true }, supportedLocales: { ["fr-FR"] }, installedLocales: { ["fr-FR"] })
        let provider = Provider(environment: env) { _, _, _ in calls.hit(); return Self.words([("hi", 0.1, 0.3)]) }
        let (result, late) = await Self.run(provider)
        #expect(result == nil)
        #expect(late < Self.slack)
        #expect(calls.count == 0)
        #expect(await DialogueSpeechAssets.status(mode: .installedOnly, environment: env) == .unsupportedLocale)
    }

    @Test func notInstalledIsNil() async {
        let calls = Counter()
        let env = DialogueSpeechEnvironment(isAvailable: { true }, supportedLocales: { ["en-US"] }, installedLocales: { [] })
        let provider = Provider(environment: env) { _, _, _ in calls.hit(); return Self.words([("hi", 0.1, 0.3)]) }
        let (result, late) = await Self.run(provider)
        #expect(result == nil)
        #expect(late < Self.slack)
        #expect(calls.count == 0)
        #expect(await DialogueSpeechAssets.status(mode: .installedOnly, environment: env) == .notInstalled)
        #expect(await DialogueSpeechAssets.status(mode: .allowDownload, environment: env, downloadProgress: 0.25)
            == .downloading(progress: 0.25))
        #expect(await DialogueSpeechAssets.status(mode: .off, environment: Self.ready) == .off)
        #expect(await DialogueSpeechAssets.status(mode: .installedOnly, environment: Self.ready) == .ready)
    }

    @Test func localesCompareAsBCP47() async {
        #expect(DialogueSpeechAssets.sameLocale("en_US", "en-US"))
        #expect(!DialogueSpeechAssets.sameLocale("en_GB", "en-US"))
        let env = DialogueSpeechEnvironment(isAvailable: { true }, supportedLocales: { ["en_US"] }, installedLocales: { ["en_US"] })
        #expect(await DialogueSpeechAssets.status(mode: .installedOnly, environment: env) == .ready)
    }

    @Test func thrownErrorIsNil() async {
        struct Boom: Error {}
        let provider = Provider(environment: Self.ready) { _, _, _ in throw Boom() }
        let (result, late) = await Self.run(provider)
        #expect(result == nil)
        #expect(late < Self.slack)
    }

    @Test func timeoutIsNilAtTheDeadline() async {
        let provider = Provider(environment: Self.ready) { _, _, _ in
            try await Task.sleep(for: .seconds(5))
            return Self.words([("late", 0.1, 0.3)])
        }
        let (result, late) = await Self.run(provider, deadline: .milliseconds(200))
        #expect(result == nil)
        #expect(late < Self.slack)
    }

    /// An analysis that ignores cancellation still cannot hold the caller past the deadline.
    @Test func uncooperativeAnalysisIsNilAtTheDeadline() async {
        let provider = Provider(environment: Self.ready) { _, _, _ in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.resume() }
            }
            return Self.words([("late", 0.1, 0.3)])
        }
        let (result, late) = await Self.run(provider, deadline: .milliseconds(200))
        #expect(result == nil)
        #expect(late < Self.slack)
    }

    /// A slow readiness query is inside the race too.
    @Test func slowGateIsNilAtTheDeadline() async {
        let env = DialogueSpeechEnvironment(isAvailable: { true }, supportedLocales: {
            try? await Task.sleep(for: .seconds(5))
            return ["en-US"]
        }, installedLocales: { ["en-US"] })
        let provider = Provider(environment: env) { _, _, _ in Self.words([("hi", 0.1, 0.3)]) }
        let (result, late) = await Self.run(provider, deadline: .milliseconds(200))
        #expect(result == nil)
        #expect(late < Self.slack)
    }

    @Test func cancellationIsNilPromptly() async {
        let provider = Provider(environment: Self.ready) { _, _, _ in
            try await Task.sleep(for: .seconds(5))
            return Self.words([("late", 0.1, 0.3)])
        }
        let clock = ContinuousClock()
        let source = Self.source()
        let task = Task { await provider.transcript(for: source, deadline: clock.now.advanced(by: .seconds(5))) }
        try? await Task.sleep(for: .milliseconds(50))
        let cancelled = clock.now
        task.cancel()
        let result = await task.value
        #expect(result == nil)
        #expect(clock.now - cancelled < Self.slack)
        // Already cancelled before the call.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await provider.transcript(for: source, deadline: clock.now.advanced(by: .seconds(5)))
        }
        #expect(await early.value == nil)
    }

    @Test func pastDeadlineIsNilWithoutAnalysis() async {
        let calls = Counter()
        let provider = Provider(environment: Self.ready) { _, _, _ in calls.hit(); return Self.words([("hi", 0.1, 0.3)]) }
        #expect(await provider.transcript(for: Self.source(), deadline: ContinuousClock().now) == nil)
        #expect(calls.count == 0)
    }

    // MARK: Film-second mapping

    @Test(arguments: [1.0, 0.8])
    func analyzerTimeMapsToFilmSeconds(rate: Double) async throws {
        let provider = Provider(environment: Self.ready) { _, _, _ in
            Self.words([("first", 0.5, 0.9), ("second", 1.0, 1.5)])
        }
        let (result, _) = await Self.run(provider, source: Self.source(sourceStart: 100, rate: rate), deadline: .seconds(2))
        let transcript = try #require(result)
        #expect(transcript.locale == "en-US")
        #expect(transcript.modelVersion == "test")
        #expect(transcript.words.map(\.text) == ["first", "second"])
        let second = transcript.words[1]
        #expect(abs(second.start - (100 + 1.0 * rate)) < 1e-6)
        #expect(abs(second.end - (100 + 1.5 * rate)) < 1e-6)
        #expect(second.confidence == 0.8)
    }

    @Test func wordsOutsideTheFedRangeAreDropped() async throws {
        // 2 s source: fed range 0...2 s.
        let provider = Provider(environment: Self.ready) { _, _, _ in
            Self.words([("before", -0.3, 0.2), ("inside", 0.4, 0.8), ("edge", 1.7, 2.01), ("after", 2.2, 2.6),
                        ("straddle", 1.9, 2.4), ("reversed", 1.0, 0.9), ("  ", 0.1, 0.2)])
        }
        let (result, _) = await Self.run(provider, deadline: .seconds(2))
        let transcript = try #require(result)
        #expect(transcript.words.map(\.text) == ["inside", "edge"])
        #expect(transcript.words[1].end <= 2.0 + 1e-9)
        // Nothing left is nil, not an empty transcript.
        let none = Provider(environment: Self.ready) { _, _, _ in Self.words([("after", 3, 3.5)]) }
        #expect(await Self.run(none, deadline: .seconds(2)).0 == nil)
    }

    @Test func atMostThirtySecondsAreFed() async throws {
        let fed = Mutex(0)
        let provider = Provider(environment: Self.ready) { _, frames, locale in
            fed.withLock { $0 = frames }
            #expect(locale == "en-US")
            return Self.words([("late", 31, 31.5), ("ok", 29, 29.5)])
        }
        let (result, _) = await Self.run(provider, source: Self.source(seconds: 40), deadline: .seconds(3))
        #expect(fed.withLock { $0 } == 30 * 48_000)
        #expect(try #require(result).words.map(\.text) == ["ok"])
    }

    // MARK: Mode and provider choice

    @Test func modeParsingAndDefaults() {
        typealias Mode = DialogueTranscriptionMode
        #expect(Mode.defaultsKey == "archive.dialogueTranscription")
        #expect(Mode.resolve(stored: nil, debugFlag: nil) == .installedOnly)
        #expect(Mode.resolve(stored: "garbage", debugFlag: nil) == .installedOnly)
        #expect(Mode.resolve(stored: "off", debugFlag: nil) == .off)
        #expect(Mode.resolve(stored: "allowDownload", debugFlag: nil) == .allowDownload)
        #expect(Mode.resolve(stored: "off", debugFlag: "allowDownload") == .allowDownload)
        #expect(Mode.resolve(stored: "allowDownload", debugFlag: "off") == .off)
        #expect(Mode.resolve(stored: "off", debugFlag: "nonsense") == .off)
        // Captures: off unless asked for the installed model, never a download.
        #expect(Mode.resolve(stored: "allowDownload", debugFlag: "allowDownload", inCapture: true) == .off)
        #expect(Mode.resolve(stored: nil, debugFlag: nil, inCapture: true, captureOption: "apple") == .installedOnly)
        #expect(Mode.resolve(stored: nil, debugFlag: nil, inCapture: true, captureOption: "fixture") == .off)
        #expect(Mode.resolve(stored: nil, debugFlag: nil, inCapture: true, captureOption: "off") == .off)
        #expect(Mode(argument: "installedOnly") == .installedOnly)
        #expect(Mode(argument: "INSTALLEDONLY") == .installedOnly)
        #expect(Mode(argument: "download") == .allowDownload)
        #expect(Mode(argument: "maybe") == nil)
        for mode in Mode.allCases { #expect(Mode(rawValue: mode.rawValue) == mode) }
    }

    @Test func makeProviderIsNullUnlessAllowedAndReady() {
        #expect(DialogueTranscription.makeProvider(mode: .off, status: .ready) is NullTranscriptProvider)
        for status: DialogueSpeechStatus? in [nil, .off, .unavailable, .unsupportedLocale, .notInstalled,
                                              .downloading(progress: 0.5)] {
            #expect(DialogueTranscription.makeProvider(mode: .installedOnly, status: status) is NullTranscriptProvider)
            #expect(DialogueTranscription.makeProvider(mode: .allowDownload, status: status) is NullTranscriptProvider)
        }
        #expect(DialogueTranscription.makeProvider(mode: .installedOnly, status: .ready) is AppleSpeechTranscriptProvider)
        // Inside a capture the default mode is off, so the provider is Null whatever the device has.
        let captured = DialogueTranscriptionMode.resolve(stored: "allowDownload", debugFlag: nil, inCapture: true)
        #expect(DialogueTranscription.makeProvider(mode: captured, status: .ready) is NullTranscriptProvider)
    }

    // MARK: Opt-in qualification probe

    nonisolated struct ProbeConfig: Decodable {
        let checkout: String
        var films: Int?
    }

    /// Runs only when /private/tmp/liminal-transcription-probe-<uid>.json names this checkout.
    /// Never downloads: a model that is not installed is reported and the probe stops.
    @Test func qualificationProbe() async throws {
        let path = URL(fileURLWithPath: "/private/tmp/liminal-transcription-probe-\(getuid()).json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let config = try JSONDecoder().decode(ProbeConfig.self, from: Data(contentsOf: path))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard root.standardizedFileURL.path == URL(fileURLWithPath: config.checkout).standardizedFileURL.path else { return }

        let environment = DialogueSpeechEnvironment.live
        let status = await DialogueSpeechAssets.status(mode: .installedOnly, environment: environment)
        let installed = await environment.installedLocales()
        let supportedEnglish = await environment.supportedLocales().filter { $0.hasPrefix("en") }
        Self.probe(["kind": "status", "status": status.name, "isAvailable": environment.isAvailable(),
                    "installedLocales": installed, "supportedEnglish": supportedEnglish,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString])
        guard status == .ready, let provider = AppleSpeechTranscriptProvider.live() else {
            Self.probe(["kind": "stop", "reason": "status \(status.name): real inference unqualified; choose Download model"])
            let after = await DialogueSpeechAssets.status(mode: .installedOnly, environment: environment)
            Self.probe(["kind": "statusAfter", "status": after.name, "installedLocales": await environment.installedLocales()])
            return
        }

        let directory = ArchiveClipStore.defaultDirectory()
        struct Catalog: Decodable { let clips: [ArchiveClip] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: directory.appending(path: "index.json")))
        let format = AudioKit.Settings.audioFormat
        var done = 0
        for clip in catalog.clips.filter(\.hasAudio).sorted(by: { $0.id < $1.id }) {
            guard done < (config.films ?? 3), clip.duration >= 40 else { continue }
            let offset = min(clip.duration * 0.25, clip.duration - 31)
            let url = directory.appending(path: clip.fileName)
            guard let buffer = try? await ArchiveAudioDecoder.decode(url: url, sourceStart: offset, sourceLength: 30,
                                                                    rate: 1, format: format) else { continue }
            done += 1
            let source = DialogueSource(contentID: clip.id, cueToken: done, buffer: buffer, sourceStart: offset, rate: 1)
            let seconds = Double(source.frameCount) / source.sampleRate
            let clock = ContinuousClock()
            let start = clock.now
            let transcript = await provider.transcript(for: source, deadline: start.advanced(by: .seconds(20)))
            let wall = clock.now - start
            let wallMs = Double(wall.components.seconds) * 1000 + Double(wall.components.attoseconds) / 1e15
            let words = transcript?.words ?? []
            let confidences = words.compactMap(\.confidence)
            let cancelDeadline = clock.now.advanced(by: .milliseconds(300))
            let cancelled = await provider.transcript(for: source, deadline: cancelDeadline)
            let over = clock.now - cancelDeadline
            let overMs = Double(over.components.seconds) * 1000 + Double(over.components.attoseconds) / 1e15
            Self.probe(["kind": "film", "title": clip.title, "id": clip.id, "audioSeconds": seconds,
                        "sourceStart": offset, "wallMs": wallMs.rounded(), "realTimeFactor": wallMs / 1000 / seconds,
                        "wordCount": words.count, "nilResult": transcript == nil,
                        "meanConfidence": confidences.isEmpty ? NSNull() : confidences.reduce(0, +) / Float(confidences.count),
                        "modelVersion": transcript?.modelVersion ?? "",
                        "firstWords": words.prefix(12).map { ["t": $0.text, "s": ($0.start * 100).rounded() / 100,
                                                              "e": ($0.end * 100).rounded() / 100] },
                        "forcedCancel": ["deadlineMs": 300, "msPastDeadline": overMs, "nil": cancelled == nil]])
        }
        if done == 0 { Self.probe(["kind": "stop", "reason": "no cached film of at least 40 s with audio"]) }
        let after = await DialogueSpeechAssets.status(mode: .installedOnly, environment: environment)
        Self.probe(["kind": "statusAfter", "status": after.name, "installedLocales": await environment.installedLocales()])
    }

    private static func probe(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        print("TRANSCRIPT-PROBE " + (String(data: data, encoding: .utf8) ?? "{}"))
    }
}
