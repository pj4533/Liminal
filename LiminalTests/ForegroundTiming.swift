import Foundation
import os
import Testing

/// Measures what a synchronous piece of work costs, for tests that hold code to a time budget.
///
/// Swift Testing runs the suite in parallel on the cooperative pool, one thread per core, and the
/// offline render suites keep every core busy for minutes. A budget test timed with a wall clock on
/// a pool thread then measures the machine, not the code: the dialogue stage budget read 212 ms
/// alone and 570-680 ms in the full suite. `.responsivePool` does not help with that, because it
/// only waits until the pool answers sleeps on time, and one free thread is enough for that.
///
/// Two things were measured on this machine (4 performance and 6 efficiency cores) and both are
/// handled here:
/// - Preemption and queueing. `measure` runs the work on its own thread at user-interactive quality
///   of service and reads that thread's CPU time, which leaves out time spent waiting for a core.
/// - Slower execution. Beside the render suites the same code also uses about twice the CPU time
///   (an efficiency core, shared caches and memory bandwidth), so CPU time alone still read 419 ms
///   for the 212 ms stages. `measure` therefore runs a fixed calibration workload on the same thread
///   straight before and after the work and divides the work's CPU time by how much slower than
///   its unloaded reference that workload ran (never less than 1).
///
/// Assert budgets on `Cost.seconds` (or `milliseconds`), the best of a few attempts. It is the
/// CPU cost the work would have on this machine when nothing else runs, which is what the budgets
/// were set against.
///
/// The work must be single-threaded for the CPU time to be the whole cost. Record expectations
/// outside the closure: the thread is not part of the test's task.
enum ForegroundTiming {
    struct Cost: Sendable, CustomStringConvertible {
        var wallSeconds: Double
        var cpuSeconds: Double
        /// How much slower than its unloaded reference the calibration workload ran around the work.
        var slowdown: Double
        /// CPU seconds corrected for the machine's load.
        var seconds: Double { cpuSeconds / slowdown }
        var milliseconds: Double { seconds * 1000 }

        static let unmeasured = Cost(wallSeconds: .infinity, cpuSeconds: .infinity, slowdown: 1)

        var description: String {
            String(format: "%.1f ms (CPU %.1f ms at slowdown %.2f, wall %.1f ms)",
                   milliseconds, cpuSeconds * 1000, slowdown, wallSeconds * 1000)
        }
    }

    /// CPU seconds of `calibrate()` in a Debug test build on an idle performance core of the machine
    /// the budgets were measured on (30 runs read 158-166 ms, 19 November 2026).
    static let calibrationReferenceSeconds = 0.158

    /// A fixed mix of the things the measured code does: float arithmetic with state, table reads
    /// and streaming through a buffer larger than the first-level cache. Returns its CPU seconds.
    static func calibrate() -> Double {
        let count = 1 << 18
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let a = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let b = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { a.deallocate(); b.deallocate() }
        var state: UInt32 = 0x9E37_79B9
        for i in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            a[i] = Float(state >> 8) * (1 / 8_388_608) - 1
        }
        var z1: Float = 0, z2: Float = 0, sum: Float = 0
        for pass in 0..<4 {
            let stride = 1 + 2 * pass
            for i in 0..<count {
                let x = a[i] + 0.25 * a[(i &* stride) & (count - 1)]
                let y = 0.2 * x + z1
                z1 = 0.3 * x - 0.5 * y + z2
                z2 = 0.1 * x + 0.2 * y
                b[i] = y
                sum += abs(y)
            }
            for i in 0..<count { a[i] = 0.5 * (a[i] + b[count - 1 - i]) }
        }
        precondition(sum.isFinite)
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
    }

    /// Holds the work and its outcome. The thread drops the work before it signals, because the
    /// `Thread` object can outlive `measure` and the closure must not escape it.
    private final class Box<T>: @unchecked Sendable {
        var work: (() throws -> T)?
        var result: Result<(T, Cost), any Error>?

        func run() {
            let before = ForegroundTiming.calibrate()
            let wall = DispatchTime.now().uptimeNanoseconds
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let outcome = Result { try work!() }
            let cpuSeconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e9
            let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - wall) / 1e9
            let after = ForegroundTiming.calibrate()
            let slowdown = max(1, 0.5 * (before + after) / ForegroundTiming.calibrationReferenceSeconds)
            let cost = Cost(wallSeconds: wallSeconds, cpuSeconds: cpuSeconds, slowdown: slowdown)
            result = outcome.map { ($0, cost) }
            work = nil
        }
    }

    static func measure<T>(_ work: () throws -> T) throws -> (value: T, cost: Cost) {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        withoutActuallyEscaping(work) { work in
            box.work = work
            let thread = Thread {
                box.run()
                done.signal()
            }
            thread.name = "liminal.tests.foreground-timing"
            thread.qualityOfService = .userInteractive
            thread.stackSize = 8 << 20
            thread.start()
            done.wait()
        }
        let (value, cost) = try box.result!.get()
        log(cost)
        return (value, cost)
    }

    /// Every measurement goes to the unified log with the calling test, to compare loaded and idle runs:
    /// `log show --last 30m --predicate 'subsystem == "com.saygoodnight.Liminal.tests"'`.
    private static let logger = Logger(subsystem: "com.saygoodnight.Liminal.tests", category: "timing")

    private static func log(_ cost: Cost) {
        let name = Test.current?.name ?? "?"
        logger.notice("TIMING \(name, privacy: .public) \(cost.description, privacy: .public)")
    }
}
