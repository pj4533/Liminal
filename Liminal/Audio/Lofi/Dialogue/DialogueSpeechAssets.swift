import Foundation
import Synchronization

/// Readiness of the on-device speech model (plan 7).
nonisolated enum DialogueSpeechStatus: Sendable, Equatable {
    /// The "Dialogue understanding" setting is Off (checked before the device).
    case off
    /// The framework or this device has no transcriber.
    case unavailable
    /// The transcriber does not support the footage locale.
    case unsupportedLocale
    /// Supported, but the model is not on this device.
    case notInstalled
    /// A download this app started is in progress (0...1).
    case downloading(progress: Double)
    case ready

    var title: String {
        switch self {
        case .off: return "Off"
        case .unavailable: return "Unavailable on this device"
        case .unsupportedLocale: return "English is not supported on this device"
        case .notInstalled: return "Not installed"
        case .downloading(let p): return p > 0 ? "Downloading, \(Int((p * 100).rounded()))%" : "Downloading"
        case .ready: return "Ready"
        }
    }

    /// Compact form for logs and the qualification probe.
    var name: String {
        switch self {
        case .off: return "off"
        case .unavailable: return "unavailable"
        case .unsupportedLocale: return "unsupportedLocale"
        case .notInstalled: return "notInstalled"
        case .downloading: return "downloading"
        case .ready: return "ready"
        }
    }
}

/// The framework queries behind the readiness checks, injectable for tests. Locale lists are
/// BCP 47 identifiers.
nonisolated struct DialogueSpeechEnvironment: Sendable {
    var isAvailable: @Sendable () -> Bool
    var supportedLocales: @Sendable () async -> [String]
    var installedLocales: @Sendable () async -> [String]

    /// No framework: every check fails at availability.
    static let unavailable = DialogueSpeechEnvironment(isAvailable: { false }, supportedLocales: { [] },
                                                       installedLocales: { [] })

    /// The real framework where it exists and the OS supports it.
    static var live: DialogueSpeechEnvironment { AppleSpeechTranscriptProvider.liveEnvironment ?? .unavailable }
}

/// Model asset lifecycle: distinct readiness checks and the one user-requested download.
nonisolated enum DialogueSpeechAssets {
    private struct State {
        var lastStatus: DialogueSpeechStatus?
        var installRequested = false
        var downloadProgress: Double?
    }

    private static let state = Mutex(State())

    /// Same identifier in any spelling (`en_US`, `en-US`).
    static func sameLocale(_ a: String, _ b: String) -> Bool {
        Locale(identifier: a).identifier(.bcp47).lowercased() == Locale(identifier: b).identifier(.bcp47).lowercased()
    }

    /// Checks in order: mode, availability, supported locale, installed locale. A download this
    /// app started reports its progress in place of notInstalled.
    static func status(mode: DialogueTranscriptionMode, environment: DialogueSpeechEnvironment,
                       locale: String = DialogueTranscription.localeIdentifier,
                       downloadProgress: Double? = nil) async -> DialogueSpeechStatus {
        guard mode != .off else { return .off }
        guard environment.isAvailable() else { return .unavailable }
        guard await environment.supportedLocales().contains(where: { sameLocale($0, locale) }) else {
            return .unsupportedLocale
        }
        guard await environment.installedLocales().contains(where: { sameLocale($0, locale) }) else {
            if let downloadProgress { return .downloading(progress: downloadProgress) }
            return .notInstalled
        }
        return .ready
    }

    /// The live status for the current mode, remembered for `makeProvider()`.
    @discardableResult
    static func status() async -> DialogueSpeechStatus {
        let progress = state.withLock { $0.downloadProgress }
        let s = await status(mode: DialogueTranscriptionMode.current, environment: .live, downloadProgress: progress)
        state.withLock { $0.lastStatus = s }
        return s
    }

    /// The status from the most recent check, or nil before the first.
    static var lastKnownStatus: DialogueSpeechStatus? { state.withLock { $0.lastStatus } }

    /// Refreshes the remembered status on a utility task.
    static func refreshStatus() {
        Task.detached(priority: .utility) { await status() }
    }

    /// Starts the model download, only when the mode is allowDownload, at most once per launch,
    /// on a utility task. The only code path that downloads; never called from a cue.
    static func requestInstallIfAllowed() {
        guard DialogueTranscriptionMode.current == .allowDownload else { return }
        let first = state.withLock { s -> Bool in
            guard !s.installRequested else { return false }
            s.installRequested = true
            return true
        }
        guard first else { return }
        Task.detached(priority: .utility) {
            guard await status() == .notInstalled else { return }
            state.withLock { $0.downloadProgress = 0 }
            await AppleSpeechTranscriptProvider.installModel(locale: DialogueTranscription.localeIdentifier) { fraction in
                state.withLock { $0.downloadProgress = fraction }
            }
            state.withLock { $0.downloadProgress = nil }
            await status()
        }
    }
}
