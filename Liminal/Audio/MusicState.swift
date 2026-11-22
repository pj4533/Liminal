import Foundation
import Synchronization

/// Layer identity. Raw values index `MusicState.layerLevels`.
nonisolated enum LayerID: UInt8, CaseIterable, Sendable {
    case drone, pad, lead, keys, drips, air, grains, pluck
}

nonisolated enum SceneKind: UInt8, CaseIterable, Sendable {
    case stillness, drift, bloom, constellation, tide
}

nonisolated enum ScenePhase: UInt8, Sendable {
    case emerge, bloom, dissolve
}

/// One musical event, plain data.
nonisolated struct MusicEvent: Sendable {
    enum Kind: UInt8, Sendable { case none, noteOn, chordChange, keyChange, sceneChange, layerEnter, layerExit, rareEvent }
    var sequence: UInt32 = 0         // monotonically increasing; 0 = empty slot
    var kind: Kind = .none
    var layer: LayerID = .drone
    var midi: UInt8 = 0              // note, or scene kind / rare-event id
    var velocity: Float = 0          // 0...1
    var time: Double = 0             // conductor seconds
}

typealias MusicEventRing = (MusicEvent, MusicEvent, MusicEvent, MusicEvent, MusicEvent, MusicEvent, MusicEvent, MusicEvent)
typealias LayerLevels = (Float, Float, Float, Float, Float, Float, Float, Float)

/// Snapshot of the music for the render loop. Fixed size, no heap references, safe to memcpy.
nonisolated struct MusicState: Sendable {
    var time: Double = 0
    var startUptime: UInt64 = 0
    var sceneIndex: UInt32 = 0
    var sceneKind: SceneKind = .drift
    var scenePhase: ScenePhase = .emerge
    var sceneProgress: Float = 0
    var intensity: Float = 0
    var brightness: Float = 0.5
    var density: Float = 0.5
    var tonic: UInt8 = 0
    var modeIndex: UInt16 = 0
    var scaleMask: UInt16 = 0
    var chordMask: UInt16 = 0
    var chordRoot: UInt8 = 0
    var chordChangeCount: UInt32 = 0
    var keyChangeCount: UInt32 = 0
    var layerLevels: LayerLevels = (0, 0, 0, 0, 0, 0, 0, 0)
    var shimmerLevel: Float = 0
    var lastOnsetTime: Double = -1000
    var lastOnsetVelocity: Float = 0
    var lofiTakeGrid: LofiTakeGrid?
    var recordedBeatDuration: Double = 0  // Lo-Fi runs on the sample clock of a real recording
    var events: MusicEventRing = (MusicEvent(), MusicEvent(), MusicEvent(), MusicEvent(),
                                  MusicEvent(), MusicEvent(), MusicEvent(), MusicEvent())
    /// Total events pushed; the newest is in slot (eventCount - 1) % 8.
    var eventCount: UInt32 = 0

    static let ringSize = 8

    func level(_ id: LayerID) -> Float {
        withUnsafeBytes(of: layerLevels) { $0.bindMemory(to: Float.self)[Int(id.rawValue)] }
    }

    mutating func setLevel(_ id: LayerID, _ v: Float) {
        withUnsafeMutableBytes(of: &layerLevels) { $0.bindMemory(to: Float.self)[Int(id.rawValue)] = v }
    }

    func event(slot: Int) -> MusicEvent {
        withUnsafeBytes(of: events) { $0.bindMemory(to: MusicEvent.self)[slot & 7] }
    }

    mutating func push(_ e: MusicEvent) {
        let slot = Int(eventCount & 7)
        withUnsafeMutableBytes(of: &events) { $0.bindMemory(to: MusicEvent.self)[slot] = e }
        eventCount &+= 1
    }

    /// Decaying envelope of the most recent onset: velocity * exp(-(now - onset)/decay).
    func pulse(at now: Double, decay: Double = 0.4) -> Float {
        let dt = now - lastOnsetTime
        guard dt >= 0 else { return 0 }
        return lastOnsetVelocity * Float(exp(-dt / decay))
    }

    /// Events newer than `sequence`, oldest first. Allocates; not for the hot path.
    func events(after sequence: UInt32) -> [MusicEvent] {
        var out: [MusicEvent] = []
        for i in 0..<Self.ringSize {
            let e = event(slot: i)
            if e.kind != .none && e.sequence > sequence { out.append(e) }
        }
        return out.sorted { $0.sequence < $1.sequence }
    }
}

/// Single-writer, many-reader seqlock around a `MusicState`.
/// The writer (the Lo-Fi transport) never blocks; readers never lock.
nonisolated final class MusicStateBus: @unchecked Sendable {
    private let sequence = Atomic<UInt64>(0)
    private let startUptimeNs = Atomic<UInt64>(0)
    private let buffer: UnsafeMutablePointer<MusicState>
    /// Lo-Fi transport side channel (plan 3.6). Variable-size data stays out of `MusicState`; this
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
