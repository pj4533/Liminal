import Foundation
@testable import Liminal

/// Chop-beat variety and interplay with the drums (D127): how often the same piece fires twice in a
/// row, how many pieces a bar and two bars use, and where the hits sit against the take's kicks,
/// snares and ghost notes. Shared by `DialogueChopVarietyTests` and its probe.
enum DialogueChopMetrics {
    /// The take's drum steps over a 2-bar cell (0...31), read here from the snapshot's landmarks
    /// with a rule of the metrics' own (not `DialogueMotifDrums`): a step is a kick, snare or ghost
    /// step when a hit of that class lands on it in at least `share` of the take's 2-bar pairs.
    struct DrumSteps: Sendable {
        var kicks: Set<Int> = []
        var snares: Set<Int> = []
        var ghosts: Set<Int> = []

        static let ghostStrength: Float = 0.45

        init(kicks: Set<Int>, snares: Set<Int>, ghosts: Set<Int> = []) {
            self.kicks = kicks; self.snares = snares; self.ghosts = ghosts
        }

        init(_ snapshot: DialogueTransportSnapshot, share: Double = 0.5, ghostShare: Double = 0.375) {
            let pairs = Double(DialogueTransportSnapshot.takeBeats / 8)
            func modal(_ marks: [DialogueLandmark], _ share: Double, _ keep: (DialogueLandmark) -> Bool) -> Set<Int> {
                var counts = [Int](repeating: 0, count: 32)
                for m in marks where keep(m) {
                    let step = Int((m.beat * 4).rounded())
                    counts[((step % 32) + 32) % 32] += 1
                }
                return Set((0..<32).filter { Double(counts[$0]) >= share * pairs })
            }
            snares = modal(snapshot.snares, share) { $0.confidence >= 0.5 && $0.strength >= Self.ghostStrength }
            kicks = modal(snapshot.kicks, share) { $0.confidence >= 0.5 }.subtracting(snares)
            ghosts = modal(snapshot.snares, ghostShare) { $0.confidence >= 0.25 && $0.strength < Self.ghostStrength }
                .subtracting(snares).subtracting(kicks)
        }

        func row(bar: Int) -> String {
            (0..<16).map { k -> String in
                let s = bar * 16 + k
                return kicks.contains(s) ? "K" : (snares.contains(s) ? "S" : (ghosts.contains(s) ? "g" : "."))
            }.map { $0.padding(toLength: 5, withPad: " ", startingAt: 0) }.joined()
        }
    }

    struct Section {
        var hits = 0
        /// Consecutive hits with the same piece and the same gate, and with the same piece at any gate,
        /// as a share of consecutive pairs; `…Unmarked` leaves out hits marked as deliberate stutters.
        var samePieceGate = 0.0
        var samePiece = 0.0
        var samePieceGateUnmarked = 0.0
        var samePieceUnmarked = 0.0
        var stutters = 0
        /// Longest run of one piece.
        var longestRun = 0
        /// Mean distinct pieces per bar, and the mean and the least per 2-bar cell.
        var piecesPerBar = 0.0
        var piecesPer2Bars = 0.0
        var leastPer2Bars = 0
        /// Shares of hits on a kick step, a snare step, a ghost step and in the gaps (none of those).
        var onKick = 0.0
        var onSnare = 0.0
        var onGhost = 0.0
        var inGap = 0.0
        /// Hits on the swung "a" before a beat (step 3 of the beat) and on odd sixteenths.
        var onA = 0.0
        var offEighths = 0.0
        /// Feel offsets (ms) of quarter-step hits (must be 0) and of the others.
        var quarterFeelMs: [Double] = []
        var otherFeelMs: [Double] = []
    }

    static func placed(_ events: [DialogueEvent], loop: Int) -> [(s: Int, e: DialogueEvent)] {
        events.compactMap { e in
            let s = (e.block - loop * 4) * 64 + e.slot
            return s >= 0 && s < 256 ? (s, e) : nil
        }.sorted { $0.s < $1.s }
    }

    /// The metrics of bars `bars` (0-based bars of the loop) of one loop's events.
    static func section(_ events: [DialogueEvent], loop: Int, bars: Range<Int>, drums: DrumSteps) -> Section {
        var m = Section()
        let hits = placed(events, loop: loop).filter { bars.contains($0.s / 16) }
        m.hits = hits.count
        guard hits.count > 1 else { return m }
        let pairs = zip(hits, hits.dropFirst())
        let n = Double(hits.count - 1)
        func same(_ a: DialogueEvent, _ b: DialogueEvent, gate: Bool) -> Bool {
            a.piece == b.piece && (!gate || a.gateSteps == b.gateSteps)
        }
        m.samePieceGate = Double(pairs.filter { same($0.e, $1.e, gate: true) }.count) / n
        m.samePiece = Double(pairs.filter { same($0.e, $1.e, gate: false) }.count) / n
        m.samePieceGateUnmarked = Double(pairs.filter { !$1.e.stutter && same($0.e, $1.e, gate: true) }.count) / n
        m.samePieceUnmarked = Double(pairs.filter { !$1.e.stutter && same($0.e, $1.e, gate: false) }.count) / n
        m.stutters = hits.filter { $0.e.stutter }.count
        var run = 1
        for (a, b) in pairs {
            run = a.e.piece == b.e.piece ? run + 1 : 1
            m.longestRun = max(m.longestRun, run)
        }
        m.longestRun = max(m.longestRun, 1)
        let perBar = bars.map { b in Set(hits.filter { $0.s / 16 == b }.compactMap(\.e.piece)).count }
        m.piecesPerBar = Double(perBar.reduce(0, +)) / Double(max(1, perBar.count))
        let cells = stride(from: bars.lowerBound, to: bars.upperBound - 1, by: 2).map { b in
            Set(hits.filter { $0.s / 16 == b || $0.s / 16 == b + 1 }.compactMap(\.e.piece)).count
        }
        m.piecesPer2Bars = Double(cells.reduce(0, +)) / Double(max(1, cells.count))
        m.leastPer2Bars = cells.min() ?? 0
        let total = Double(hits.count)
        let cellSteps = hits.map { $0.s % 32 }
        m.onKick = Double(cellSteps.filter { drums.kicks.contains($0) }.count) / total
        m.onSnare = Double(cellSteps.filter { drums.snares.contains($0) }.count) / total
        m.onGhost = Double(cellSteps.filter { drums.ghosts.contains($0) }.count) / total
        m.inGap = Double(cellSteps.filter { !drums.kicks.contains($0) && !drums.snares.contains($0) && !drums.ghosts.contains($0) }.count) / total
        m.onA = Double(hits.filter { $0.s % 4 == 3 }.count) / total
        m.offEighths = Double(hits.filter { $0.s % 2 == 1 }.count) / total
        for (s, e) in hits {
            if s % 4 == 0 { m.quarterFeelMs.append(e.feelSeconds * 1000) } else { m.otherFeelMs.append(e.feelSeconds * 1000) }
        }
        return m
    }

    /// Jaccard of the (step, piece) hits of bars 3-4 against 5-6 before their last beat, and of bars
    /// 3-4 against bar 7 (the build's first bar replays the groove's call).
    static func recurrence(_ events: [DialogueEvent], loop: Int) -> Double {
        let bars = DialogueHookMetrics.loopHits(events, loop: loop)
        func cell(_ b: Int) -> Set<DialogueHookMetrics.Hit> {
            Set((bars[b] + bars[b + 1].map { .init(step: $0.step + 16, fragment: $0.fragment) }).filter { $0.step < 28 })
        }
        return DialogueHookMetrics.jaccard(cell(2), cell(4))
    }

    /// The loop's grid (fragment/gate per sixteenth, `~` marks a stutter) under the drums' rows.
    static func grid(_ events: [DialogueEvent], loop: Int, drums: DrumSteps, bars: Range<Int> = 0..<16) -> [String] {
        var rows = DialogueArcMetrics.grid(events, loop: loop)
        for (s, e) in placed(events, loop: loop) where e.stutter { rows[s / 16] += " ~\(s % 16)" }
        return ["drums A: " + drums.row(bar: 0), "drums B: " + drums.row(bar: 1)] + bars.map { rows[$0] }
    }
}
