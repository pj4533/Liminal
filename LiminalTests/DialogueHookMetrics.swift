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
        var fragmentTotal = 0
        for group in 0..<4 {
            var fragments = Set<Int>()
            for bar in (group * 4)..<(group * 4 + 4) {
                for hit in bars[bar] { fragments.insert(hit.fragment) }
            }
            fragmentTotal += fragments.count
        }
        m.fragmentsPer4 = Double(fragmentTotal) / 4
        m.distinctSteps = Set(all.map(\.step)).count
        return m
    }

    /// A 16-row trigger grid (row = bar, column = sixteenth, cell = fragment id).
    static func grid(_ bars: [[Hit]]) -> [String] {
        bars.enumerated().map { b, hits in
            let columns: [String] = (0..<16).map { step in
                guard let hit = hits.first(where: { $0.step == step }) else { return "." }
                return String(hit.fragment)
            }
            let label = String(format: "%2d", b + 1)
            return "bar \(label): " + columns.joined(separator: " ")
        }
    }
}

/// The 16-bar arc's measurements (D126 part 2, C-D11 and C-D12): onsets per bar and per section,
/// gate lengths, where the line is stated and how much of it the outro covers.
enum DialogueArcMetrics {
    /// Sections by bar of the loop: intro 1-2, chop beat 3-6, build 7-8, breakdown 9-12, outro 13-16.
    static let sections: [(name: String, bars: Range<Int>)] = [("intro", 0..<2), ("chopBeat", 2..<6), ("build", 6..<8),
                                                                ("breakdown", 8..<12), ("outro", 12..<16)]

    struct Metrics {
        var onsets = [Int](repeating: 0, count: 16)
        /// Mean onsets per bar of each section.
        var density: [String: Double] = [:]
        /// Onsets in the last two beats of bar 8.
        var buildTail = 0
        /// chopBeat and build hits with a gate of at most 2 and at most 1 sixteenth (one-shots count as long).
        var gateAtMost2 = 0.0
        var gateAtMost1 = 0.0
        /// Median sounding length of sub-line hits, in sixteenths.
        var medianSubLineSteps = 0.0
        /// chopBeat hits on 8th positions.
        var chopEighths = 0.0
        /// The line's first statement: bar and step (nil: none in bars 1-2).
        var introStep: Int?
        /// Share of the line's frames the outro's hits cover, in source order.
        var outroCoverage = 0.0
        var outroInOrder = false
        /// The restatement's (step, fragment, source start) hits.
        var outroWalk: [[Int]] = []
    }

    static func metrics(_ events: [DialogueEvent], loop: Int, motif: DialogueMotif?, sixteenth: Double) -> Metrics {
        var m = Metrics()
        var placed: [(s: Int, e: DialogueEvent)] = []
        for e in events {
            let s = (e.block - loop * 4) * 64 + e.slot
            guard s >= 0, s < 256 else { continue }
            placed.append((s, e))
            m.onsets[s / 16] += 1
        }
        placed.sort { $0.s < $1.s }
        for sec in sections { m.density[sec.name] = Double(sec.bars.map { m.onsets[$0] }.reduce(0, +)) / Double(sec.bars.count) }
        m.buildTail = placed.filter { $0.s >= 7 * 16 + 8 && $0.s < 8 * 16 }.count
        let busy = placed.filter { (2 * 16..<8 * 16).contains($0.s) && $0.e.piece != 0 }
        if !busy.isEmpty {
            m.gateAtMost2 = Double(busy.filter { ($0.e.gateSteps ?? 99) <= 2 }.count) / Double(busy.count)
            m.gateAtMost1 = Double(busy.filter { ($0.e.gateSteps ?? 99) <= 1 }.count) / Double(busy.count)
        }
        let chop = placed.filter { (2 * 16..<6 * 16).contains($0.s) }
        if !chop.isEmpty { m.chopEighths = Double(chop.filter { $0.s % 2 == 0 }.count) / Double(chop.count) }
        if let motif {
            let lengths = placed.filter { $0.e.piece.map(motif.isSubLine) ?? false }
                .map { ($0.e.drySeconds ?? motif.seconds($0.e.piece!)) / sixteenth }.sorted()
            if !lengths.isEmpty { m.medianSubLineSteps = lengths[lengths.count / 2] }
            let line = motif.line.frames
            let outro = placed.filter { $0.s >= 12 * 16 }
            var covered = IndexSet()
            for (_, e) in outro {
                if e.piece == 0 { covered.insert(integersIn: line) }
                else if let r = e.sourceFrames { covered.insert(integersIn: max(line.lowerBound, r.lowerBound)..<min(line.upperBound, max(line.lowerBound, r.upperBound))) }
            }
            // The share of the line's speech (its pieces: the line's own lead-in before its first onset and
            // the room tone each piece's onset trim leaves out are not speech) the outro plays.
            var speech = IndexSet()
            for p in motif.pieces { speech.insert(integersIn: motif.fragments[p].frames) }
            m.outroCoverage = Double(covered.intersection(speech).count) / Double(max(1, speech.count))
            // The restatement (bars 14 and 15, and bar 16 before its tag) walks the line in source order:
            // at most two steps back (a stutter of the signature's second half before the whole signature,
            // and one word repeated after the walk).
            let walk = outro.filter { (13 * 16..<15 * 16 + 8).contains($0.s) && $0.e.cell != .repair }
            let starts = walk.compactMap { $0.e.sourceFrames?.lowerBound ?? ($0.e.piece == 0 ? line.lowerBound : nil) }
            m.outroWalk = walk.map { [$0.s, $0.e.piece ?? -1, $0.e.sourceFrames?.lowerBound ?? -1] }
            m.outroInOrder = !starts.isEmpty && zip(starts, starts.dropFirst()).filter { $1 < $0 }.count <= 2
        }
        m.introStep = placed.first { $0.e.piece == 0 && $0.s < 32 }?.s
        return m
    }

    /// A 16-row trigger grid with gates: `4/2` fragment 4 held two sixteenths, `4` a one-shot, `4/c` choked.
    static func grid(_ events: [DialogueEvent], loop: Int) -> [String] {
        var cells = [[String]](repeating: [String](repeating: ".", count: 16), count: 16)
        for e in events {
            let s = (e.block - loop * 4) * 64 + e.slot
            guard s >= 0, s < 256 else { continue }
            let gate = e.gateEnd == "choke" ? "/c" : (e.gateEnd == "natural" ? "" : e.gateSteps.map { "/\(Int($0))" } ?? "")
            cells[s / 16][s % 16] = "\(e.piece ?? -1)\(gate)"
        }
        return cells.enumerated().map { b, row in "bar \(String(format: "%2d", b + 1)): " + row.map { $0.padding(toLength: 5, withPad: " ", startingAt: 0) }.joined() }
    }
}
