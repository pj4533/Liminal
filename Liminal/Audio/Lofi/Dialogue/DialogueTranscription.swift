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

nonisolated enum DialogueTranscription {
    /// Wave 2 replaces only this body with the Apple-backed provider.
    static func makeProvider() -> any TranscriptProvider { NullTranscriptProvider() }
}
