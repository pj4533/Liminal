import Foundation

/// Time-ordered event queue on conductor time (seconds). Confined to the conductor's queue
/// (or the offline render thread). Binary min-heap ordered by (time, sequence).
nonisolated final class MusicScheduler {
    private struct Entry {
        let time: Double
        let seq: UInt64
        let block: () -> Void
        func before(_ o: Entry) -> Bool { time < o.time || (time == o.time && seq < o.seq) }
    }

    private(set) var now: Double = 0
    private var heap: [Entry] = []
    private var seq: UInt64 = 0

    init() { heap.reserveCapacity(256) }

    var pendingCount: Int { heap.count }

    func schedule(at time: Double, _ block: @escaping () -> Void) {
        seq &+= 1
        heap.append(Entry(time: max(time, now), seq: seq, block: block))
        siftUp(heap.count - 1)
    }

    func schedule(after delay: Double, _ block: @escaping () -> Void) {
        schedule(at: now + max(0, delay), block)
    }

    /// Runs every event due at or before `target`, in order. Events scheduled by events run too if due.
    func advance(to target: Double) {
        while let top = heap.first, top.time <= target {
            let e = pop()
            now = max(now, e.time)
            e.block()
        }
        now = max(now, target)
    }

    func cancelAll() { heap.removeAll(keepingCapacity: true) }

    /// Reset the clock (used when the conductor restarts).
    func reset(to time: Double) { cancelAll(); now = time }

    private func pop() -> Entry {
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty { heap[0] = last; siftDown(0) }
        return top
    }

    private func siftUp(_ i: Int) {
        var c = i
        while c > 0 {
            let p = (c - 1) / 2
            if heap[c].before(heap[p]) { heap.swapAt(c, p); c = p } else { return }
        }
    }

    private func siftDown(_ i: Int) {
        var p = i
        let n = heap.count
        while true {
            let l = 2 * p + 1, r = l + 1
            var m = p
            if l < n && heap[l].before(heap[m]) { m = l }
            if r < n && heap[r].before(heap[m]) { m = r }
            if m == p { return }
            heap.swapAt(p, m); p = m
        }
    }
}

/// Eno-style loop: a non-integer period that random-walks a few percent per cycle within bounds.
nonisolated struct LoopClock {
    var period: Double
    var driftPerCycle: Double = 0.04
    var bounds: ClosedRange<Double>

    init(bounds: ClosedRange<Double>, rng: inout SeededRNG, drift: Double = 0.04) {
        self.bounds = bounds
        self.driftPerCycle = drift
        self.period = rng.range(bounds)
    }

    /// Re-roll inside new bounds (per scene).
    mutating func reroll(bounds: ClosedRange<Double>, rng: inout SeededRNG) {
        self.bounds = bounds
        period = rng.range(bounds)
    }

    mutating func nextCycle(rng: inout SeededRNG) -> Double {
        period *= 1 + rng.range(-driftPerCycle...driftPerCycle)
        period = min(max(period, bounds.lowerBound), bounds.upperBound)
        return period
    }
}
