import AVFoundation
import Foundation
import os

/// Test-harness registry for extra capture taps, diagnostics and artifacts. It is disabled in
/// the app: every mutator returns immediately unless the offline harness called `begin`.
/// State sits behind an unfair lock and nothing here may be called from a render thread.
nonisolated enum LofiCaptureHooks {
    struct Tap: @unchecked Sendable {
        let name: String
        let node: AVAudioNode
    }

    private struct State {
        var enabled = false
        var options: [String: String] = [:]
        var taps: [Tap] = []
        var reports: [String: Any] = [:]
        var files: [String: Data] = [:]
        var finishers: [@Sendable () -> Void] = []
    }

    private static let state = OSAllocatedUnfairLock(uncheckedState: State())

    static var isEnabled: Bool { state.withLockUnchecked { $0.enabled } }

    /// Harness only: enable, clear any earlier registrations and store the options.
    static func begin(options: [String: String]) {
        state.withLockUnchecked {
            $0 = State()
            $0.enabled = true
            $0.options = options
        }
    }

    /// Disable and clear everything.
    static func end() {
        state.withLockUnchecked { $0 = State() }
    }

    static func option(_ key: String) -> String? {
        state.withLockUnchecked { $0.enabled ? $0.options[key] : nil }
    }

    /// Names match `^[a-z0-9][a-z0-9-]*$`; they become `<name>.wav` in the capture.
    static func tap(_ name: String, _ node: AVAudioNode) {
        guard isEnabled else { return }
        guard validTapName(name) else {
            assertionFailureDebug("Invalid capture tap name \(name)")
            return
        }
        state.withLockUnchecked { $0.taps.append(Tap(name: name, node: node)) }
    }

    /// `value` must be JSON-serializable. It becomes `manifest.diagnostics[key]`.
    static func report(_ key: String, _ value: Any) {
        state.withLockUnchecked { if $0.enabled { $0.reports[key] = value } }
    }

    /// Appends to an array report, creating it when absent.
    static func appendReport(_ key: String, _ element: Any) {
        state.withLockUnchecked {
            guard $0.enabled else { return }
            var list = $0.reports[key] as? [Any] ?? []
            list.append(element)
            $0.reports[key] = list
        }
    }

    /// Extra artifact written next to the manifest. The name matches
    /// `^[a-z0-9][a-z0-9-]*\.(json|csv)$`, the set the capture receiver accepts.
    static func file(_ name: String, _ data: Data) {
        guard isEnabled else { return }
        guard validFileName(name) else {
            assertionFailureDebug("Invalid capture file name \(name)")
            return
        }
        state.withLockUnchecked { $0.files[name] = data }
    }

    /// Runs after the render finishes and before the manifest is written.
    static func onFinish(_ body: @escaping @Sendable () -> Void) {
        state.withLockUnchecked { if $0.enabled { $0.finishers.append(body) } }
    }

    static var taps: [Tap] { state.withLockUnchecked { $0.taps } }
    static var reports: [String: Any] { state.withLockUnchecked { $0.reports } }
    static var files: [String: Data] { state.withLockUnchecked { $0.files } }

    /// Runs and consumes the finishers outside the lock so they may register reports and files.
    static func runFinishers() {
        let pending = state.withLockUnchecked { state -> [@Sendable () -> Void] in
            let list = state.finishers
            state.finishers = []
            return list
        }
        for body in pending { body() }
    }

    private static func validTapName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil
    }

    private static func validFileName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9-]*\.(json|csv)/) != nil
    }

    private static func assertionFailureDebug(_ message: String) {
        #if DEBUG
        assertionFailure(message)
        #endif
    }
}
