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
        // The hook's call, backbeat responses and spelling stay on their authored grid. Only
        // a shared fill may move, identically in both passes, inside its neighbours' free room.
        // Never translate a complete cell: a spelling turnaround can occur in only one pass.
        let chopCells = cells.filter { $0.kind == .chopBeat }
        var fillMoves: [Int: Int] = [:]
        var fillColour: (slot: Int, effect: Item.Effect)?
        if chopCells.count == 2 {
            let first = chopCells[0].items
            let second = chopCells[1].items
            let old = oldSlots(.chopBeat)
            let colours = first.filter { !$0.skeleton && !$0.stutter && !fragments[$0.fragment].isUnit
                && $0.slot < 28 && second.contains($0) }
            if !colours.isEmpty {
                let chosen = colours[rng.int(0...(colours.count - 1))]
                let oldFiltered = previous.first { $0.kind == .chopBeat }?.items.contains {
                    $0.slot == chosen.slot && $0.effect == .filtered
                } ?? false
                fillColour = (chosen.slot, oldFiltered ? .none : .filtered)
            }
            for item in first where !item.skeleton && !item.stutter && !fragments[item.fragment].isUnit && item.slot < 28 {
                guard second.contains(item) else { continue }
                let candidates = [item.slot - 2, item.slot, item.slot + 2].filter { slot in
                    guard slot > 0, slot < 28 else { return false }
                    return chopCells.allSatisfy { cell in
                        let neighbours = cell.items.filter { $0 != item }
                        let before = neighbours.last { $0.slot < item.slot }
                        let after = neighbours.first { $0.slot > item.slot }
                        guard slot > (before?.slot ?? -1), slot < (after?.slot ?? 32) else { return false }
                        let step = beatDuration > 0 ? beatDuration / 4 : 0.2
                        let own = Double(fragments[item.fragment].frames.count) / sampleRate
                        if own + DialogueMotifTuning.nextLeadSeconds > Double((after?.slot ?? 32) - slot) * step { return false }
                        if let before {
                            let length = Double(fragments[before.fragment].frames.count) / sampleRate
                            if length + DialogueMotifTuning.nextLeadSeconds > Double(slot - before.slot) * step { return false }
                        }
                        return true
                    }
                }
                let moved = candidates.filter { $0 != item.slot }
                // An unchanged legal slot is not a move. Keep looking when this fill is boxed
                // in, so an immovable first fill cannot prevent a later open pocket varying.
                if !moved.isEmpty {
                    fillMoves[item.slot] = draw(moved, avoiding: old)
                    break
                }
            }
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
            case .chopBeat:
                items = items.map { item in
                    var moved = Self.moved(item, to: fillMoves[item.slot] ?? item.slot)
                    if let colour = fillColour, item.slot == colour.slot { moved.effect = colour.effect }
                    return moved
                }
            case .build:
                // Shift a complete repeat gesture as one group; metrical shifts keep its shape, and
                // the performer drops conflicts whole instead of choking an earlier word. Spelling
                // figures keep their dedicated uniform grid and whole-word landing.
                if !items.contains(where: { fragments[$0.fragment].isUnit && fragments[$0.fragment].kind != .half }) {
                    let head = items.filter { $0.slot < 16 }.max { $0.slot < $1.slot }
                    let gesture = items.filter { $0.slot >= 16 }
                    if let first = gesture.min(by: { $0.slot < $1.slot }) {
                        let shifts = [-8, -4, 0].filter { shift in
                            guard let head else { return true }
                            let room = first.slot + shift - head.slot
                            return room > 0 && DialogueMotif.fitsRoom(head.fragment, steps: room,
                                fragments: fragments, sampleRate: sampleRate, beatDuration: beatDuration)
                        }
                        if !shifts.isEmpty {
                            let shift = shifts[rng.int(0...(shifts.count - 1))]
                            items = items.map { $0.slot >= 16 ? moved($0, to: $0.slot + shift) : $0 }
                        }
                    }
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
        for index in result.indices where [.intro, .chopBeat, .breakdown, .outro].contains(result[index].kind) {
            let cell = result[index]
            // A chop-beat pickup recurs in both passes of the hook, before the turnaround.
            if cell.kind == .chopBeat && cell.bar != 2 { continue }
            for slot in stride(from: 4, to: cell.bars * 16, by: 4) {
                let absolute = cell.bar * 16 + slot
                guard !oldReverses.contains(absolute), absolute < 256, slot - lead >= 0 else { continue }
                // Dynamic chains have unknown end positions; leave the outro's restatement alone.
                if cell.kind == .outro && slot >= 16 { continue }
                if cell.kind == .chopBeat && (slot >= 28 || oldReverses.contains(absolute + 32)) { continue }
                if cell.kind == .breakdown, !cell.items.contains(where: {
                    $0.slot / 16 == slot / 16 && !fragments[$0.fragment].isUnit
                }) { continue }
                if cell.items.contains(where: { $0.slot == slot && $0.after == nil && $0.follow == nil }) { continue }
                // A reverse begins before its accent. Check both neighbours in output time,
                // including the preceding cell, and require the same room in both hook passes.
                // Merely checking preceding local slots let a pickup steal the next call in pass
                // one while the previous response blocked that pickup in pass two.
                func clear(_ index: Int) -> Bool {
                    let candidate = result[index]
                    let accent = Double(candidate.bar * 16 + slot) * step
                    let start = accent - length - DialogueMotifTuning.reversedLeadSeconds
                    let end = accent - DialogueMotifTuning.reversedLeadSeconds
                    let replacement = candidate.kind == .breakdown ? candidate.items.first {
                        $0.slot / 16 == slot / 16 && !fragments[$0.fragment].isUnit
                    } : nil
                    for neighbour in result[max(0, index - 1)...min(result.count - 1, index + 1)] {
                        for item in neighbour.items where item.after == nil && item.follow == nil {
                            if neighbour.bar == candidate.bar, item == replacement { continue }
                            let fragment = fragments[item.fragment]
                            let offset = Double(fragment.accentFrame - fragment.frames.lowerBound) / sampleRate
                            let otherStart = Double(neighbour.bar * 16 + item.slot) * step - offset
                            let otherEnd = otherStart + Double(fragment.frames.count) / sampleRate
                            if start < otherEnd + DialogueTuning.dryGapSeconds && end + DialogueTuning.dryGapSeconds > otherStart {
                                return false
                            }
                        }
                    }
                    return true
                }
                guard clear(index) else { continue }
                if cell.kind == .chopBeat,
                   let repeatIndex = result.firstIndex(where: { $0.kind == .chopBeat && $0.bar == 4 }),
                   !clear(repeatIndex) { continue }
                candidates.append((index, slot))
            }
        }
        for _ in 0..<targetCount where !candidates.isEmpty {
            let chosen = candidates.remove(at: rng.int(0...(candidates.count - 1)))
            let cell = result[chosen.0]
            var items = cell.items
            // A sparse bar trades one forward word for its pickup instead of becoming as busy as
            // the chop beat. Split units stay together; candidate selection requires a whole word.
            if cell.kind == .breakdown, let replaced = items.firstIndex(where: {
                $0.slot / 16 == chosen.1 / 16 && !fragments[$0.fragment].isUnit
            }) { items.remove(at: replaced) }
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
            if cell.kind == .chopBeat, let repeatIndex = result.firstIndex(where: { $0.kind == .chopBeat && $0.bar == 4 }) {
                let repeated = result[repeatIndex]
                var repeatedItems = repeated.items + [reverse]
                repeatedItems.sort { $0.slot < $1.slot }
                result[repeatIndex] = Cell(kind: repeated.kind, bar: repeated.bar, bars: repeated.bars,
                    variant: repeated.variant, items: repeatedItems)
            }
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
