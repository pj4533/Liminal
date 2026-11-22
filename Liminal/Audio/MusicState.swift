import Foundation
import Synchronization

/// Snapshot of the music for the render loop, published by the Lo-Fi transport.
/// Fixed size, no heap references, safe to memcpy.
nonisolated struct MusicState: Sendable {
    var time: Double = 0
    var startUptime: UInt64 = 0
    /// Index of the playing 8-bar phrase; a change starts the visual phrase burst.
    var phraseIndex: UInt32 = 0
    var intensity: Float = 0
    var brightness: Float = 0.5
    var tonic: UInt8 = 0
    var chordRoot: UInt8 = 0
    var lastOnsetTime: Double = -1000
    var lastOnsetVelocity: Float = 0
    var lofiTakeGrid: LofiTakeGrid?
    var recordedBeatDuration: Double = 0  // the transport runs on the sample clock of a real recording

    /// Decaying envelope of the most recent onset: velocity * exp(-(now - onset)/decay).
    func pulse(at now: Double, decay: Double = 0.4) -> Float {
        let dt = now - lastOnsetTime
        guard dt >= 0 else { return 0 }
        return lastOnsetVelocity * Float(exp(-dt / decay))
    }
}

/// Single-writer, many-reader seqlock around a `MusicState`.
/// The writer (the Lo-Fi transport) never blocks; readers never lock.
nonisolated final class MusicStateBus: @unchecked Sendable {
    private let sequence = Atomic<UInt64>(0)
    private let startUptimeNs = Atomic<UInt64>(0)
    private let buffer: UnsafeMutablePointer<MusicState>
    /// Transport side channel. Variable-size data stays out of `MusicState`; this
    /// lock is taken by the main actor and the footage worker only, never by a render thread.
    private let transportInfo = Mutex<LofiTransportInfo?>(nil)

    init() {
        buffer = .allocate(capacity: 1)
        buffer.initialize(to: MusicState())
    }

    deinit {
        buffer.deinitialize(count: 1)
        buffer.deallocate()
    }

    func setStartUptime(_ ns: UInt64) { startUptimeNs.store(ns, ordering: .releasing) }

    /// Main actor (`LofiPlayback`). Nil clears the transport on stop.
    func setTransport(_ info: LofiTransportInfo?) { transportInfo.withLock { $0 = info } }

    /// Footage worker and dialogue coordinator. Not for render threads.
    func transport() -> LofiTransportInfo? { transportInfo.withLock { $0 } }

    /// The single writer (the Lo-Fi transport).
    func publish(_ state: MusicState) {
        let s = sequence.load(ordering: .relaxed)
        sequence.store(s &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        buffer.pointee = state
        sequence.store(s &+ 2, ordering: .releasing)
    }

    /// Any thread. Retries while a publish is in progress (the writer holds it for well under a microsecond).
    func read() -> MusicState {
        var copy = MusicState()
        for _ in 0..<64 {
            let s1 = sequence.load(ordering: .acquiring)
            if s1 & 1 == 1 { continue }
            copy = buffer.pointee
            atomicMemoryFence(ordering: .acquiring)
            if sequence.load(ordering: .relaxed) == s1 { return copy }
        }
        return copy
    }

    /// Seconds since the transport started on the host monotonic clock (0 before start).
    func now() -> Double {
        let start = startUptimeNs.load(ordering: .acquiring)
        let now = DispatchTime.now().uptimeNanoseconds
        guard start > 0, now >= start else { return 0 }
        return Double(now - start) / 1e9
    }
}
