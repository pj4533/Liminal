import Foundation
@testable import Liminal

/// Hook metrics of one 16-bar motif loop (D125): which fragment sounds on which sixteenth, and how
/// much of that trigger pattern repeats. Shared by `DialogueMotifTests` and `DialogueHookProbeTests`.
enum DialogueHookMetrics {
    struct Hit: Hashable { let step: Int; let fragment: Int }

    /// One loop's hits by bar (0...15), steps 0...15 in the bar, from the events' block and slot.
    /// `loop` is the loop index (phrase / 4) of the loop's first block.
    static func loopHits(_ events: [DialogueEvent], loop: Int) -> [[Hit]] {
        var bars = Array(repeating: [Hit](), count: 16)
        for e in events {
            let s = (e.block - loop * 4) * 64 + e.slot
            guard s >= 0, s < 256 else { continue }
            bars[s / 16].append(Hit(step: s % 16, fragment: e.piece ?? -1))
        }
        return bars.map { $0.sorted { ($0.step, $0.fragment) < ($1.step, $1.fragment) } }
    }

    static func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        a.isEmpty && b.isEmpty ? 1 : Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    struct Metrics {
        /// Mean Jaccard of (step-in-cell, fragment) hits between each 2-bar cell and the previous one.
        var cellRepeat = 0.0
        /// The same, steps only.
        var cellRhythm = 0.0
        /// Mean over cells 2 to 8 of the best Jaccard against any earlier cell.
        var cellVsBest = 0.0
        /// Mean Jaccard between consecutive 4-bar groups.
        var fourBarRepeat = 0.0
        /// Share of bars 3 to 16 whose hit set equals bar-2's or bar-4's.
        var exactBarRepeats = 0.0
        /// Share of the 8 cells holding the most common (step-in-cell, fragment) hit.
        var signatureShare = 0.0
        /// Share of the most played fragment's hits on its modal step-in-bar.
        var focalConsistency = 0.0
        /// Distinct per-bar step sets (at most 16).
        var distinctRhythms = 0
        /// Mean distinct fragments per 4 bars.
        var fragmentsPer4 = 0.0
        /// Distinct step-in-bar positions used.
        var distinctSteps = 0
        var hits = 0
    }

    static func metrics(_ bars: [[Hit]]) -> Metrics {
        var m = Metrics()
        func cell(_ k: Int) -> Set<Hit> { Set(bars[2 * k] + bars[2 * k + 1].map { Hit(step: $0.step + 16, fragment: $0.fragment) }) }
        func group(_ g: Int) -> Set<Hit> { Set((0..<4).flatMap { b in bars[4 * g + b].map { Hit(step: $0.step + 16 * b, fragment: $0.fragment) } }) }
        let cells = (0..<8).map(cell)
        m.cellRepeat = (1..<8).map { jaccard(cells[$0], cells[$0 - 1]) }.reduce(0, +) / 7
        m.cellRhythm = (1..<8).map { jaccard(Set(cells[$0].map(\.step)), Set(cells[$0 - 1].map(\.step))) }.reduce(0, +) / 7
        m.cellVsBest = (1..<8).map { k in (0..<k).map { jaccard(cells[k], cells[$0]) }.max() ?? 0 }.reduce(0, +) / 7
        m.fourBarRepeat = (1..<4).map { jaccard(group($0), group($0 - 1)) }.reduce(0, +) / 3
        var exact = 0
        for b in 2..<16 where !bars[b].isEmpty && (Set(bars[b]) == Set(bars[b - 2]) || (b >= 4 && Set(bars[b]) == Set(bars[b - 4]))) { exact += 1 }
        m.exactBarRepeats = Double(exact) / 14
        var counts: [Hit: Int] = [:]
        for c in cells { for h in c { counts[h, default: 0] += 1 } }
        m.signatureShare = Double(counts.values.max() ?? 0) / 8
        let all = bars.flatMap { $0 }
        m.hits = all.count
        let byFragment = Dictionary(grouping: all, by: \.fragment)
        if let focal = byFragment.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }) {
            let modal = Dictionary(grouping: focal.value, by: \.step).values.map(\.count).max() ?? 0
            m.focalConsistency = Double(modal) / Double(focal.value.count)
        }
        m.distinctRhythms = Set(bars.map { $0.map(\.step) }).count
        m.fragmentsPer4 = (0..<4).map { g in Double(Set((0..<4).flatMap { bars[4 * g + $0].map(\.fragment) }).count) }.reduce(0, +) / 4
        m.distinctSteps = Set(all.map(\.step)).count
        return m
    }

    /// A 16-row trigger grid (row = bar, column = sixteenth, cell = fragment id).
    static func grid(_ bars: [[Hit]]) -> [String] {
        bars.enumerated().map { b, hits in
            "bar \(String(format: "%2d", b + 1)): " + (0..<16).map { s in hits.first { $0.step == s }.map { String($0.fragment) } ?? "." }.joined(separator: " ")
        }
    }
}
