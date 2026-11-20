import Foundation
import Testing

/// Holds a wall-clock test back until the Swift concurrency pool answers on time, and runs such
/// tests one at a time.
///
/// Swift Testing starts every test at once on the cooperative pool, which has one thread per
/// core. The synchronous render tests keep those threads busy for seconds, so a `Task.sleep` or
/// deadline wakeup in another test comes back seconds late and a deadline assertion measures the
/// harness, not the code. A test with this trait first takes a process-wide turn, so two timed
/// tests never load each other, then waits until short sleeps return on time several times in a
/// row, which means the pool's backlog has drained, and only then runs.
///
/// Put it on any test or suite that asserts on elapsed wall-clock time: `@Test(.responsivePool)`
/// or `@Suite(.serialized, .responsivePool)`. On a suite it applies to each test in it.
struct ResponsivePoolTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await Turn.shared.take()
        do {
            await Self.waitUntilResponsive()
            try await function()
        } catch {
            await Turn.shared.pass()
            throw error
        }
        await Turn.shared.pass()
    }

    /// A first-come, first-served turn shared by every timed test in the process.
    private actor Turn {
        static let shared = Turn()
        private var taken = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func take() async {
            guard taken else { taken = true; return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func pass() {
            if waiting.isEmpty { taken = false } else { waiting.removeFirst().resume() }
        }
    }

    /// Returns once `calmProbes` consecutive `probe` sleeps each overshoot by less than
    /// `tolerance`, or after `limit` so a permanently busy machine still runs (and reports) the test.
    static func waitUntilResponsive(probe: Duration = .milliseconds(5), tolerance: Duration = .milliseconds(8),
                                    calmProbes: Int = 10, limit: Duration = .seconds(300)) async {
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: limit)
        var calm = 0
        while calm < calmProbes, clock.now < giveUp {
            let started = clock.now
            try? await Task.sleep(for: probe)
            let overshoot = clock.now - started - probe
            calm = overshoot < tolerance ? calm + 1 : 0
        }
    }
}

extension Trait where Self == ResponsivePoolTrait {
    /// Run only once the concurrency pool is answering on time. See `ResponsivePoolTrait`.
    static var responsivePool: Self { Self() }
}
