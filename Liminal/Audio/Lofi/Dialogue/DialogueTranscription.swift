import Foundation

/// Optional local transcription (plan 7). Every failure, timeout or cancellation is a nil
/// result, which leaves the acoustic plan in place.
nonisolated protocol TranscriptProvider: Sendable {
    func transcript(for source: DialogueSource, deadline: ContinuousClock.Instant) async -> DialogueTranscript?
}

/// No transcription: the acoustic path only.
nonisolated struct NullTranscriptProvider: TranscriptProvider {
    func transcript(for source: DialogueSource, deadline: ContinuousClock.Instant) async -> DialogueTranscript? { nil }
}

/// Returns a supplied transcript, optionally after a delay. A delay that would pass the
/// deadline, or a cancelled task, returns nil at the deadline.
nonisolated struct FixtureTranscriptProvider: TranscriptProvider {
    let result: DialogueTranscript?
    var delay: Duration = .zero

    init(_ result: DialogueTranscript?, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func transcript(for source: DialogueSource, deadline: ContinuousClock.Instant) async -> DialogueTranscript? {
        let clock = ContinuousClock()
        let ready = clock.now.advanced(by: delay)
        if ready > deadline {
            try? await clock.sleep(until: deadline)
            return nil
        }
        if delay > .zero {
            do { try await clock.sleep(until: ready) } catch { return nil }
        }
        return Task.isCancelled ? nil : result
    }
}

/// "Dialogue understanding" (setting `archive.dialogueTranscription`, plan 7).
nonisolated enum DialogueTranscriptionMode: String, CaseIterable, Sendable {
    /// Acoustic analysis only.
    case off
    /// Use the on-device model when the system already has it. The default.
    case installedOnly
    /// As installedOnly, and the user allowed one model download.
    case allowDownload

    static let defaultsKey = "archive.dialogueTranscription"
    static let defaultMode: DialogueTranscriptionMode = .installedOnly

    /// Accepts the raw values plus a few spellings a person may type on the command line.
    init?(argument: String) {
        let lowered = argument.trimmingCharacters(in: .whitespaces).lowercased()
        switch lowered {
        case "off", "no", "none": self = .off
        case "installedonly", "installed", "ifinstalled": self = .installedOnly
        case "allowdownload", "download": self = .allowDownload
        default: return nil
        }
    }

    /// Precedence: a capture hook option (offline harness), then the debug flag, then the
    /// stored setting, then the default. Inside a capture the default is off: `apple` uses an
    /// installed model only (a capture never downloads) and `fixture` leaves the provider to the
    /// test, so `makeProvider()` stays Null.
    static func resolve(stored: String?, debugFlag: String?, inCapture: Bool = false,
                        captureOption: String? = nil) -> DialogueTranscriptionMode {
        if inCapture {
            return captureOption?.lowercased() == "apple" ? .installedOnly : .off
        }
        if let flag = debugFlag.flatMap(DialogueTranscriptionMode.init(argument:)) { return flag }
        if let stored = stored.flatMap(DialogueTranscriptionMode.init(rawValue:)) { return stored }
        return defaultMode
    }

    /// The mode in effect now. Safe from any thread.
    static var current: DialogueTranscriptionMode {
        let inCapture = LofiCaptureHooks.isEnabled
        return resolve(stored: UserDefaults.standard.string(forKey: defaultsKey),
                       debugFlag: DebugLaunchOptions.dialogueTranscription, inCapture: inCapture,
                       captureOption: inCapture ? LofiCaptureHooks.option("transcription") : nil)
    }
}

nonisolated enum DialogueTranscription {
    /// The English locale the footage is transcribed in (BCP 47).
    static let localeIdentifier = "en-US"
    /// At most this much of a source is transcribed, from its first frame.
    static let maximumSeconds = 30.0

    /// The coordinator's provider. The Apple-backed provider only when the mode allows it and
    /// the last known asset status is ready; otherwise Null. An unknown status starts a utility
    /// refresh and returns Null, so a later cue can use the model.
    static func makeProvider() -> any TranscriptProvider {
        let mode = DialogueTranscriptionMode.current
        let status = DialogueSpeechAssets.lastKnownStatus
        if status == nil && mode != .off { DialogueSpeechAssets.refreshStatus() }
        return makeProvider(mode: mode, status: status)
    }

    static func makeProvider(mode: DialogueTranscriptionMode, status: DialogueSpeechStatus?) -> any TranscriptProvider {
        guard mode != .off, status == .ready, let live = AppleSpeechTranscriptProvider.live() else {
            return NullTranscriptProvider()
        }
        return live
    }
}
