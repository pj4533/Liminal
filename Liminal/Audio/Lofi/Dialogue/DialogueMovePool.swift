import Foundation

/// Seeded phrase gestures. The previous loop is passed even when its source line changed. A transcript
/// revision reuses that same history, so it does not consume a new draw or avoid its own first plan.
nonisolated enum DialogueMovePool {
    typealias Cell = DialogueMotifCell
    typealias Item = Cell.Item

    static func positions(_ cells: [Cell], where keep: (Item) -> Bool) -> Set<Int> {
        Set(cells.flatMap { cell in cell.items.filter(keep).map { cell.bar * 16 + $0.slot } })
    }

    static func arrange(_ cells: [Cell], fragments: [DialogueMotifFragment], signature: Int,
                        sampleRate: Double, beatDuration: Double, seed: UInt64, avoiding previous: [Cell]) -> [Cell] {
        var rng = MusicRNG(seed: seed ^ 0xFE31_2026)
        let oldStutters = positions(previous) { $0.stutter }
        let oldReverses = positions(previous) { $0.effect == .reversed }
        // Quiet entrance and split-pause locations are intentional moves, distinct from every empty
        // sixteenth. Preserve the arc and spell runs: move groups together, never shuffle their units.
        func oldSlots(_ kind: DialogueCell, firstOnly: Bool = false) -> Set<Int> {
            let items = previous.first { $0.kind == kind }?.items.filter { $0.fragment != 0 && $0.effect != .reversed } ?? []
            return Set(firstOnly ? items.prefix(1).map(\.slot) : items.map(\.slot))
        }
        func draw(_ pool: [Int], avoiding old: Set<Int>) -> Int {
            let fresh = pool.filter { !old.contains($0) }
            let choices = fresh.isEmpty ? pool : fresh
            return choices[rng.int(0...(choices.count - 1))]
        }
        var result: [Cell] = []
        for cell in cells {
            var items = cell.items
            switch cell.kind {
            case .intro:
                let tag = items.filter { $0.fragment != 0 }
                let origin = tag.map(\.slot).min() ?? 24
                let span = (tag.map(\.slot).max() ?? origin) - origin
                let targets = [18, 20, 22, 24, 26, 28].filter { $0 + span < 32 }
                let target = draw(targets, avoiding: oldSlots(.intro))
                items = items.map { item in
                    item.fragment == 0 ? item : moved(item, to: target + item.slot - origin)
                }
            case .breakdown:
                // Draw word/answer positions per bar; preserve the two contiguous split pieces as a
                // group. The old static bar-11 split and bar-13 reverse are no longer landmarks.
                var shifted: [Item] = []
                for item in items {
                    let bar = item.slot / 16
                    let candidates: [Int]
                    switch bar {
                    case 0: candidates = [0, 4, 8]
                    case 1: candidates = [16, 20, 24, 28]
                    case 2: candidates = [32, 36, 40, 44]
                    default: candidates = [48, 52, 56, 60]
                    }
                    if item.slot == 44, let head = shifted.last, items.contains(where: { $0.slot == 40 }) {
                        shifted.append(moved(item, to: head.slot + 4))
                    } else {
                        shifted.append(moved(item, to: draw(candidates, avoiding: oldSlots(.breakdown))))
                    }
                }
                items = shifted
            case .build:
                // Shift a complete repeat gesture as one group; metrical shifts keep its shape, and
                // the performer drops conflicts whole instead of choking an earlier word. Spelling
                // figures keep their dedicated uniform grid and whole-word landing.
                if !items.contains(where: { fragments[$0.fragment].isUnit && fragments[$0.fragment].kind != .half }) {
                    let shift = [-8, -4, 0][rng.int(0...2)]
                    items = items.map { $0.slot >= 16 ? moved($0, to: $0.slot + shift) : $0 }
                }
            case .outro:
                if let index = items.firstIndex(where: { $0.slot < 16 && $0.fragment != 0 }) {
                    items[index] = moved(items[index], to: draw([0, 4, 8, 12], avoiding: oldSlots(.outro, firstOnly: true)))
                }
                // Move the complete closing tag together; letters/syllables retain contiguity/order.
                let tag = items.filter { $0.slot >= 52 && $0.after == nil && $0.follow == nil }
                if let start = tag.map(\.slot).min(), let end = tag.map(\.slot).max() {
                    let targets = [44, 48, 52, 56].filter { $0 + end - start < 63 }
                    let oldStart = previous.first { $0.kind == .outro }?.items
                        .filter { $0.slot >= 44 && $0.after == nil && $0.follow == nil && $0.effect != .reversed }
                        .map(\.slot).min()
                    let target = draw(targets, avoiding: Set(oldStart.map { [$0] } ?? []))
                    items = items.map { item in tag.contains(item) ? moved(item, to: target + item.slot - start) : item }
                }
            default: break
            }
            // A deliberate repeat may be omitted rather than repeat the last loop's gesture. Spell
            // figures are not stutters and are kept complete; new word onsets are never shortened.
            items.removeAll { $0.stutter && oldStutters.contains(cell.bar * 16 + $0.slot) }
            if cell.kind == .build || cell.kind == .chopBeat {
                let ordered = items.sorted { $0.slot < $1.slot }
                items.removeAll { item in
                    guard item.stutter, let index = ordered.firstIndex(of: item) else { return false }
                    let next = index + 1 < ordered.count ? ordered[index + 1].slot : cell.bars * 16
                    guard DialogueMotif.fitsRoom(item.fragment, steps: next - item.slot, fragments: fragments,
                                                sampleRate: sampleRate, beatDuration: beatDuration) else { return true }
                    if index > 0 {
                        let head = ordered[index - 1]
                        return !DialogueMotif.fitsRoom(head.fragment, steps: item.slot - head.slot, fragments: fragments,
                                                      sampleRate: sampleRate, beatDuration: beatDuration)
                    }
                    return false
                }
            }
            result.append(Cell(kind: cell.kind, bar: cell.bar, bars: cell.bars, variant: cell.variant,
                               items: cell.kind == .outro ? items : items.sorted { $0.slot < $1.slot }))
        }
        // Pickups into downbeats across the intro, sparse breakdown and return. Prefer the whole
        // signature (highest salience), never reverse just one letter out of its spelling figure.
        let step = beatDuration > 0 ? beatDuration / 4 : 0.2
        let length = Double(fragments[signature].frames.count) / sampleRate
        let lead = Int(ceil((length + DialogueMotifTuning.reversedLeadSeconds + 0.04) / step))
        let targetCount = rng.int(2...3)
        var candidates: [(Int, Int)] = []
        for index in result.indices where [.intro, .breakdown, .outro].contains(result[index].kind) {
            let cell = result[index]
            for slot in stride(from: 4, through: cell.bars * 16, by: 4) {
                let absolute = cell.bar * 16 + slot
                guard !oldReverses.contains(absolute), absolute < 256, slot - lead >= 0 else { continue }
                // Dynamic chains have unknown end positions; leave the outro's restatement alone.
                if cell.kind == .outro && slot >= 16 { continue }
                if cell.items.contains(where: { $0.slot == slot && $0.after == nil && $0.follow == nil }) { continue }
                let clear = !cell.items.contains { item in
                    let end = item.slot + Int(ceil(Double(fragments[item.fragment].frames.count) / sampleRate / step))
                    return item.slot < slot && end > slot - lead
                }
                if clear { candidates.append((index, slot)) }
            }
        }
        for _ in 0..<targetCount where !candidates.isEmpty {
            let chosen = candidates.remove(at: rng.int(0...(candidates.count - 1)))
            let cell = result[chosen.0]
            var items = cell.items
            let reverse = Item(fragment: signature, slot: chosen.1, effect: .reversed, fixed: true)
            if cell.kind == .outro {
                // Only the quiet entrance participates; keep the line/after/follow execution chain
                // in its authored order even though a follow item stores a relative slot of zero.
                let index = items.firstIndex { $0.fragment == 0 || $0.slot > chosen.1 } ?? items.endIndex
                items.insert(reverse, at: index)
            } else {
                items.append(reverse)
                items.sort { $0.slot < $1.slot }
            }
            result[chosen.0] = Cell(kind: cell.kind, bar: cell.bar, bars: cell.bars, variant: cell.variant,
                                   items: items)
            candidates.removeAll { $0.0 == chosen.0 }
        }
        return result
    }

    private static func moved(_ item: Item, to slot: Int) -> Item {
        Item(fragment: item.fragment, slot: slot, after: item.after, gainDB: item.gainDB, effect: item.effect,
             landing: item.landing, fixed: item.fixed, gate: item.gate, follow: item.follow,
             onEighths: item.onEighths, skeleton: item.skeleton, stutter: item.stutter)
    }
}
