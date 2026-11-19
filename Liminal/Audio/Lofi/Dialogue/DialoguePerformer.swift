import Foundation

/// Bounded performance grammar over 4-bar blocks on the drum take's grid (plan 5).
/// Pure and seeded: the same bank, snapshot, window, memory and seed give the same plan.
nonisolated enum DialoguePerformer {
    static let establishing: [DialogueFamily] = [.anchor, .echo, .callResponse]

    static func perform(_ bank: DialoguePadBank?, snapshot: DialogueTransportSnapshot, window: Range<Double>,
                        earliestStart: Double, memory: inout DialoguePerformanceMemory, seed: UInt64,
                        cueToken: Int = 0, revision: Int = 0) -> DialoguePerformancePlan {
        let firstBeat = snapshot.beat(time: window.lowerBound)
        let lastBeat = snapshot.beat(time: window.upperBound)
        let firstBlock = Int((firstBeat / 16 + 1e-9).rounded(.down))
        let lastBlock = Int((lastBeat / 16 - 1e-9).rounded(.up)) - 1
        var blocks: [DialogueBlock] = []
        if memory.cycleSeed == nil { memory.cycleSeed = seed }
        let piece = memory.pieceCounter
        if lastBlock >= firstBlock {
            for k in firstBlock...lastBlock where snapshot.phraseAtOrigin + k >= 0 {
                let phrase = snapshot.phraseAtOrigin + k
                if let bank, !bank.pads.isEmpty {
                    var planner = BlockPlanner(bank: bank, snapshot: snapshot, window: window, earliestStart: earliestStart,
                                               memory: memory, seed: seed, phrase: phrase, blockBeat: Double(16 * k),
                                               piece: piece, planned: blocks)
                    let (block, record, lead) = planner.plan()
                    blocks.append(block)
                    memory.remember(record)
                    if let lead { memory.useAnchor(lead, piece: piece, phrase: phrase) }
                    if !block.events.isEmpty { memory.lastDryEnd = max(memory.lastDryEnd ?? -.infinity, block.events.map(\.endTime).max()!) }
                    if phrase % 4 == 0 {
                        memory.familyCycleIndex += 1
                        memory.variationCounter += 1
                    }
                } else {
                    let block = DialogueBlock(phrase: phrase, section: LofiScore.section(at: phrase), family: .rest, variation: 0,
                                              fingerprint: fingerprint(.rest, []), events: [], forcedChange: false,
                                              noDialogue: true, change: "noDialogue")
                    blocks.append(block)
                    memory.remember(DialogueBlockRecord(phrase: phrase, bankID: 0, family: .rest, variation: 0,
                                                        fingerprint: block.fingerprint, elements: [], items: [], occupancy: 0,
                                                        nonNative: 0, events: 0, snareLanded: false, leadKey: nil))
                }
            }
        }
        if let bank {
            if memory.lastBankID != bank.bankID { memory.fallbackPieces = 0 }
            memory.lastBankID = bank.bankID
        }
        memory.pieceCounter += 1
        return DialoguePerformancePlan(sourceID: bank?.sourceID ?? "", cueToken: cueToken, bankID: bank?.bankID ?? 0,
                                       analysisVersion: bank?.analysisVersion ?? 0, seed: seed,
                                       transportRevision: snapshot.revision, revision: revision,
                                       usedTranscript: bank?.usedTranscript ?? false, blocks: blocks,
                                       rejections: bank?.rejections ?? [])
    }

    static func fingerprint(_ family: DialogueFamily, _ elements: [DialogueElement]) -> UInt64 {
        var h = DialogueHash()
        h.add(family.id)
        for e in elements {
            h.add(e.padKey)
            h.add(e.slot)
        }
        return h.value
    }

    /// Multiset intersection size of two element lists.
    static func shared(_ a: [DialogueElement], _ b: [DialogueElement]) -> Int {
        var counts: [DialogueElement: Int] = [:]
        for e in a { counts[e, default: 0] += 1 }
        var n = 0
        for e in b where (counts[e] ?? 0) > 0 {
            counts[e]! -= 1
            n += 1
        }
        return n
    }

    /// `1 - |F(n) ∩ F(n-1)| / max(|F(n)|, |F(n-1)|)` over position-tagged elements.
    static func windowDifference(_ a: [DialogueElement], _ b: [DialogueElement]) -> Double {
        let m = max(a.count, b.count)
        guard m > 0 else { return 1 }
        return 1 - Double(shared(a, b)) / Double(m)
    }
}

// MARK: - One block

private nonisolated struct Candidate {
    var family: DialogueFamily
    var variation: Int
    var items: [DialogueItem]
    var change: String
    var lead: DialoguePad?
}

private nonisolated struct Draft {
    var item: DialogueItem
    var pad: DialoguePad
    var accent: Double
    var start: Double
    var slot: Int
    var snare: Bool
    var end: Double { start + pad.duration }
}

private nonisolated struct BlockPlanner {
    let bank: DialoguePadBank
    let snapshot: DialogueTransportSnapshot
    let window: Range<Double>
    let earliestStart: Double
    let memory: DialoguePerformanceMemory
    let seed: UInt64
    let phrase: Int
    let blockBeat: Double
    let piece: Int
    let planned: [DialogueBlock]

    var section: LofiScore.Section { LofiScore.section(at: phrase) }
    var groupStart: Bool { phrase % 2 == 0 }
    var rng: MusicRNG { MusicRNG(seed: seed).fork(UInt64(bitPattern: Int64(phrase)) &* 0x9E37 &+ 17) }

    func record(_ p: Int) -> DialogueBlockRecord? {
        if let b = planned.last(where: { $0.phrase == p }) { return Self.record(b, bankID: bank.bankID, items: []) }
        return memory.record(phrase: p)
    }

    static func record(_ b: DialogueBlock, bankID: UInt64, items: [DialogueItem], lead: UInt64? = nil) -> DialogueBlockRecord {
        DialogueBlockRecord(phrase: b.phrase, bankID: bankID, family: b.family, variation: b.variation,
                            fingerprint: b.fingerprint,
                            elements: b.events.map { DialogueElement(padKey: $0.padKey, slot: $0.slot) },
                            items: items.isEmpty ? b.events.map { DialogueItem(padID: $0.padID, slot: $0.slot, gesture: 0) } : items,
                            occupancy: b.events.map(\.duration).reduce(0, +),
                            nonNative: b.events.filter { !$0.transform.isNative }.count, events: b.events.count,
                            snareLanded: b.events.contains { $0.snareLanded }, leadKey: lead)
    }

    // MARK: Pads

    var natives: [DialoguePad] {
        let lines = bank.pads.filter { $0.transform.isNative && [.anchor, .head, .answer].contains($0.role) }
        return [bank.anchor] + lines.filter { $0.padID != bank.anchorPadID }
            .sorted { ($0.score.sound, -$0.padID) > ($1.score.sound, -$1.padID) }
    }

    /// Leads in preference order: the anchor until it served two pieces in 64 bars, then the next line.
    var leads: [DialoguePad] {
        let all = natives
        let fresh = all.filter { memory.anchorPieces($0.padKey, before: piece, phrase: phrase) < DialogueTuning.anchorReusePieces }
        let first = fresh.first ?? all[0]
        return [first] + all.filter { $0.padID != first.padID }
    }

    var bar: Double { 4 * snapshot.beatLength(at: blockBeat) }
    var stabs: [DialoguePad] { bank.pads(.stab).sorted { ($0.score.sound, -$0.padID) > ($1.score.sound, -$1.padID) } }
    var sibling: DialoguePad? { bank.siblingGroups.first.flatMap { bank.pad($0[1]) } ?? bank.pads(.sibling).first }
    var texture: DialoguePad? { bank.pads(.texture).first }

    /// Short lines that repeat a bar apart without choking themselves.
    func echoHeads(excluding lead: DialoguePad) -> [DialoguePad] {
        let fits = { (p: DialoguePad) in p.duration <= bar - 0.1 && p.transform.isNative }
        let lines = (bank.pads(.head) + bank.pads(.answer)).filter(fits)
        let short = stabs.filter(fits)
        let ordered = lines.filter { $0.padID != lead.padID } + lines.filter { $0.padID == lead.padID } + short
        return ordered
    }

    func answer(for head: DialoguePad) -> DialoguePad? {
        let answers = bank.pads(.answer).filter { $0.padID != head.padID }
        if let unit = answers.first(where: { $0.frames.lowerBound >= head.frames.upperBound }) { return unit }
        return answers.first ?? stabs.first { $0.padID != head.padID }
    }

    // MARK: Templates

    func template(_ family: DialogueFamily, variant: Int, lead: DialoguePad) -> [DialogueItem]? {
        let s1 = stabs.first, s2 = stabs.dropFirst().first ?? stabs.first
        switch family {
        case .anchor:
            switch variant % 3 {
            case 0: return [DialogueItem(padID: lead.padID, slot: 8, gesture: 0)] + (s1.map { [DialogueItem(padID: $0.padID, slot: 39, gesture: 1)] } ?? [])
            case 1: return [DialogueItem(padID: lead.padID, slot: 16, gesture: 0)] + (s1.map { [DialogueItem(padID: $0.padID, slot: 39, gesture: 1)] } ?? [])
            default: return [DialogueItem(padID: lead.padID, slot: 8, gesture: 0)] + (s2.map { [DialogueItem(padID: $0.padID, slot: 43, gesture: 1)] } ?? [])
            }
        case .echo:
            let heads = echoHeads(excluding: lead)
            guard let h = heads.first else { return nil }
            let head = variant % 3 == 2 ? (heads.dropFirst().first ?? h) : h
            let third = variant % 3 == 2 ? s1 : (sibling ?? s1)
            var items = [DialogueItem(padID: head.padID, slot: 6, gesture: 0), DialogueItem(padID: head.padID, slot: 22, gesture: 0)]
            if let third, third.padID != head.padID { items.append(DialogueItem(padID: third.padID, slot: variant % 3 == 1 ? 43 : 38, gesture: 1)) }
            return items
        case .callResponse:
            let heads = bank.pads(.head).filter { $0.duration <= 1.5 * bar } + [lead]
            guard let head = variant % 2 == 1 && heads.count > 1 ? heads[1] : heads.first,
                  let reply = answer(for: head), reply.padID != head.padID else { return nil }
            // The answer's backbeat is chosen at placement so that 2 beats of space remain.
            let starts = [[20, 28, 36], [28, 36, 20], [36, 28, 20]][variant % 3]
            var items = [DialogueItem(padID: head.padID, slot: 5, gesture: 0),
                         DialogueItem(padID: reply.padID, slot: starts[0], gesture: 0)]
            if groupStart, section != .breakdown, variant % 2 == 0,
               let s = stabs.first(where: { $0.padID != reply.padID && $0.padID != head.padID }) {
                items.append(DialogueItem(padID: s.padID, slot: 49, gesture: 1))
            }
            return items
        case .sparseReorder:
            var first: DialoguePad?, second: DialoguePad?
            if case .arrangement(let ids, .exchangeClauses) = bank.reorder, ids.count == 2 {
                first = bank.pads.first { $0.unitID == ids[0] && $0.transform.isNative }
                second = bank.pads.first { $0.unitID == ids[1] && $0.transform.isNative }
            }
            if first == nil || second == nil {
                guard let head = bank.pads(.head).first ?? natives.dropFirst().first, let reply = answer(for: head) else { return nil }
                first = head
                second = reply
            }
            guard let a = first, let b = second, a.padID != b.padID else { return nil }
            return [DialogueItem(padID: a.padID, slot: 8, gesture: 0), DialogueItem(padID: b.padID, slot: 34, gesture: 0)]
        case .textureFill:
            guard let t = texture, let s = s1 else { return nil }
            var r = rng.fork(91 &+ UInt64(variant))
            let offbeats = [17, 19, 21, 23, 25, 27, 29, 31].shuffled(using: &r)
            let count = 2 + variant % 2
            var items = [DialogueItem(padID: s.padID, slot: 15, gesture: 0)]
            items += offbeats.prefix(count).sorted().map { DialogueItem(padID: t.padID, slot: $0, gesture: 1) }
            if let other = s2 { items.append(DialogueItem(padID: other.padID, slot: 47, gesture: 2)) }
            return items
        case .rest:
            return variant % 2 == 0 ? [] : [DialogueItem(padID: lead.padID, slot: 16, gesture: 0)]
        }
    }

    // MARK: Candidates

    func candidates() -> [Candidate] {
        var r = rng
        let allLeads = leads
        let lead = allLeads[0]
        var result: [Candidate] = []
        func add(_ family: DialogueFamily, variants: [Int], leads: [DialoguePad], change: String) {
            for l in leads {
                for v in variants {
                    if let items = template(family, variant: v, lead: l) {
                        result.append(Candidate(family: family, variation: v, items: items, change: change, lead: l))
                    }
                }
            }
        }
        let variants = [0, 1, 2].shuffled(using: &r)
        let cycle = MusicRNG(seed: memory.cycleSeed ?? seed)
        let primary = cycle.shuffledCycle(DialoguePerformer.establishing, index: memory.familyCycleIndex)
        let previousGroup = record(phrase - 2)
        func establishing(_ change: String) {
            let order = [primary] + DialoguePerformer.establishing.filter { $0 != primary }
            let fresh = order.filter { previousGroup?.family != $0 || previousGroup?.bankID != bank.bankID }
            for f in fresh { add(f, variants: variants, leads: [lead], change: change) }
            add(.textureFill, variants: variants, leads: [lead], change: change)
            for f in fresh { add(f, variants: variants, leads: Array(allLeads.dropFirst()), change: "forced:" + change) }
            add(.sparseReorder, variants: [0], leads: [lead], change: "forced:" + change)
        }

        switch phrase % 4 {
        case 0:
            establishing("establish")
        case 1:
            // The answer section sometimes opens with the gated texture fill (at most one block in four).
            if section == .answer, texture != nil, r.chance(DialogueTuning.textureFillChance) {
                add(.textureFill, variants: variants, leads: [lead], change: "fill")
            }
            if let base = record(phrase - 1), base.bankID == bank.bankID, !base.items.isEmpty, base.family != .rest {
                var changes = ["omit", "sibling", "shift", "answer"].shuffled(using: &r)
                if section == .answer { changes = ["answer"] + changes.filter { $0 != "answer" } }
                for change in changes { result += variations(of: base, change: change, lead: lead) }
            }
            if section == .answer, texture != nil {
                add(.textureFill, variants: variants, leads: [lead], change: "fill")
            }
            establishing("establish-late")
        case 2:
            // Breakdown: a sparse establish of at most two events, another family than the theme's.
            var order: [DialogueFamily] = [.anchor, .callResponse, .sparseReorder].shuffled(using: &r)
            if bank.reorder.template == .exchangeClauses { order = [.sparseReorder] + order.filter { $0 != .sparseReorder } }
            for f in order where !(previousGroup?.family == f && previousGroup?.bankID == bank.bankID) {
                add(f, variants: variants, leads: [lead], change: "breakdown")
            }
            add(.rest, variants: [1], leads: allLeads, change: "breakdown")
            for f in order { add(f, variants: variants, leads: Array(allLeads.dropFirst()), change: "forced:breakdown") }
        default:
            // Return: bar 1 empty, the anchor restated unchanged, one echo, last bar empty.
            let pool = ([echoHeads(excluding: lead).first] + stabs.map { Optional($0) } + [sibling])
                .compactMap { $0 }.filter { $0.padID != lead.padID }
            let slots = [38, 43, 36, 41].shuffled(using: &r)
            for l in allLeads {
                for p in pool {
                    for s in slots {
                        result.append(Candidate(family: .anchor, variation: s, items: [
                            DialogueItem(padID: l.padID, slot: 16, gesture: 0), DialogueItem(padID: p.padID, slot: s, gesture: 1),
                        ], change: l.padID == lead.padID ? "return" : "forced:return", lead: l))
                    }
                }
                result.append(Candidate(family: .anchor, variation: 9, items: [DialogueItem(padID: l.padID, slot: 16, gesture: 0)],
                                        change: l.padID == lead.padID ? "return" : "forced:return", lead: l))
            }
        }
        result.append(Candidate(family: .rest, variation: 0, items: [], change: "forced:rest", lead: nil))
        return result
    }

    /// The previous block's pattern with exactly one change.
    func variations(of base: DialogueBlockRecord, change: String, lead: DialoguePad) -> [Candidate] {
        let items = base.items.filter { bank.pad($0.padID) != nil }
        guard !items.isEmpty else { return [] }
        let leadID = base.items.first.map(\.padID)
        func candidate(_ items: [DialogueItem], family: DialogueFamily = base.family) -> Candidate {
            Candidate(family: family, variation: base.variation, items: items, change: change,
                      lead: leadID.flatMap { bank.pad($0) })
        }
        var out: [Candidate] = []
        switch change {
        case "omit":
            guard items.count >= 2 else { return [] }
            for i in items.indices.reversed() where i > 0 {
                var next = items
                next.remove(at: i)
                out.append(candidate(next))
            }
        case "sibling":
            for i in items.indices {
                let id = items[i].padID
                if let swap = bank.sibling(of: id) ?? bank.base(ofSibling: id) {
                    var next = items
                    next[i].padID = swap
                    out.append(candidate(next))
                }
            }
        case "shift":
            for i in items.indices.reversed() {
                for d in [1, -1] {
                    var next = items
                    next[i].slot += d
                    out.append(candidate(next))
                }
            }
        default:
            if let items = template(.callResponse, variant: base.variation, lead: lead) {
                out.append(Candidate(family: .callResponse, variation: base.variation, items: items, change: "answer", lead: lead))
            }
        }
        return out
    }

    // MARK: Placement

    func time(_ beat: Double) -> Double { snapshot.time(beat: beat) }

    func nearestKick(_ t: Double) -> Double? {
        snapshot.landmarkTimes(snapshot.kicks, around: snapshot.beat(time: t), within: 1).min { abs($0 - t) < abs($1 - t) }
    }

    /// Places a candidate's items with the dry-voice, rest and occupancy rules. Returns nil when
    /// nothing of a non-empty candidate survives.
    func realize(_ c: Candidate) -> [DialogueEvent]? {
        let groupBeat = groupStart ? blockBeat : blockBeat - 16
        var lowerBeat = blockBeat + (groupStart ? 2 : 0)
        if section == .returnTheme { lowerBeat = max(lowerBeat, blockBeat + 4) }
        let upperBeat = groupStart ? blockBeat + 16 : blockBeat + 12
        let firstAllowed = (snapshot.beat(time: earliestStart) / 4 - 1e-9).rounded(.up) * 4
        let hard = max(earliestStart, time(firstAllowed))
        var lower = max(time(lowerBeat), window.lowerBound)
        if let previous = planned.last?.events.last { lower = max(lower, previous.endTime + DialogueTuning.dryGapSeconds) }
        else if let end = memory.lastDryEnd { lower = max(lower, end + DialogueTuning.dryGapSeconds) }
        let upper = min(time(upperBeat), window.upperBound)
        var r = rng.fork(7)
        let offset = r.range(DialogueTuning.gestureOffsetSeconds)

        let groupRecord = groupStart ? nil : record(phrase - 1)
        let needsSnare = !(groupRecord?.snareLanded ?? false)
        let snareRoles: [DialoguePad.Role] = [.answer, .anchor, .head, .stab, .sibling]
        // A pattern whose first accent would sound inside the rest after a boundary moves as a
        // whole, keeping its internal spacing (the echo's bar, the call's space).
        var items = c.items.sorted(by: { $0.slot < $1.slot })
        if let first = items.first, let pad = bank.pad(first.padID) {
            var shift = 0
            while shift < 12, time(blockBeat + Double(first.slot + shift) / 4) + offset - pad.renderedAccentOffset < time(lowerBeat) {
                shift += 1
            }
            if shift > 0, items.allSatisfy({ $0.slot + shift < 64 }) {
                items = items.map { DialogueItem(padID: $0.padID, slot: $0.slot + shift, gesture: $0.gesture) }
            }
        }

        var drafts: [Draft] = []
        var dropped = Set<Int>()
        func place(_ item: DialogueItem, kicks: Bool, snareDuty: Bool) -> Draft? {
            guard let pad = bank.pad(item.padID) else { return nil }
            let previous = drafts.last
            var options: [(accent: Double, slot: Int, snare: Bool)] = []
            if snareDuty {
                let nominal = blockBeat + Double(item.slot) / 4
                let marks = snapshot.landmarkTimes(snapshot.snares, around: nominal, within: DialogueTuning.snareSnapBeats)
                let target = time(nominal)
                for t in marks.sorted(by: { abs($0 - target) < abs($1 - target) }) {
                    let slot = Int(((snapshot.beat(time: t) - blockBeat) * 4).rounded())
                    if (0..<64).contains(slot) { options.append((t, slot, true)) }
                }
            }
            for d in [0, 1, -1, 2] {
                let slot = item.slot + d
                guard (0..<64).contains(slot) else { continue }
                options.append((time(blockBeat + Double(slot) / 4) + offset, slot, false))
            }
            for (k, option) in options.enumerated() {
                if kicks, !option.snare, let kick = nearestKick(option.accent), abs(kick - option.accent) < DialogueTuning.kickClearanceSeconds { continue }
                let start = option.accent - pad.renderedAccentOffset
                let end = start + pad.duration
                // A gesture that would begin before the earliest start is dropped, never moved.
                if k == 0 || option.snare, start < hard { if !option.snare { return nil } else { continue } }
                guard start >= max(lower, hard), end <= upper else { continue }
                if let p = previous, p.end + DialogueTuning.dryGapSeconds > start {
                    if p.pad.protected { continue }
                    if start - p.start < DialogueTuning.minimumChokedSeconds + DialogueTuning.chokeLeadSeconds { continue }
                }
                return Draft(item: item, pad: pad, accent: option.accent, start: start, slot: option.slot, snare: option.snare)
            }
            return nil
        }
        let beat = snapshot.beatLength(at: blockBeat)
        for var item in items where !dropped.contains(item.gesture) {
            let snareDuty = needsSnare && !drafts.contains { $0.snare } && snareRoles.contains(bank.pad(item.padID)?.role ?? .texture)
            // Call and response: the answer takes the first backbeat that leaves 2 beats of space.
            if c.family == .callResponse, let head = drafts.first, drafts.count == 1, item.gesture == 0,
               let pad = bank.pad(item.padID) {
                let backbeats = [20, 28, 36]
                let first = backbeats.firstIndex(of: c.items.first { $0.padID == item.padID && $0.gesture == 0 && $0.slot >= 20 }?.slot ?? 20) ?? 0
                let order = Array(backbeats[first...] + backbeats[..<first])
                let space = DialogueTuning.callResponseSpaceBeats * beat
                guard let slot = order.first(where: { s in
                    time(blockBeat + Double(s) / 4) - pad.renderedAccentOffset >= head.end + space
                }) ?? backbeats.first(where: { s in time(blockBeat + Double(s) / 4) - pad.renderedAccentOffset >= head.end + space })
                else {
                    dropped.insert(item.gesture)
                    drafts.removeAll { $0.item.gesture == item.gesture }
                    continue
                }
                item.slot = slot
            }
            if let d = place(item, kicks: true, snareDuty: snareDuty) ?? place(item, kicks: false, snareDuty: snareDuty) {
                drafts.append(d)
            } else {
                dropped.insert(item.gesture)
                drafts.removeAll { $0.item.gesture == item.gesture }
            }
        }

        // Occupancy and transform budgets over the 8-bar group.
        let groupSeconds = time(groupBeat + 32) - time(groupBeat)
        let priorSeconds = groupRecord?.occupancy ?? 0
        let priorEvents = groupRecord?.events ?? 0
        let priorNonNative = groupRecord?.nonNative ?? 0
        let priority: [DialoguePad.Role] = [.texture, .sibling, .stab, .head, .answer, .anchor]
        while true {
            let events = chokes(drafts)
            let seconds = events.map(\.duration).reduce(0, +)
            let nonNative = events.filter { !$0.transform.isNative }.count
            let projected = priorEvents + events.count + (groupStart ? 2 : 0)
            let overBudget = priorSeconds + seconds > DialogueTuning.maximumOccupancy * groupSeconds
            let overTransformed = Double(priorNonNative + nonNative) > DialogueTuning.nonNativeShare * Double(max(projected, 1))
            let tooMany = events.count > (section == .breakdown ? DialogueTuning.breakdownEvents : DialogueTuning.eventsPerBlock.upperBound)
            guard overBudget || overTransformed || tooMany, !drafts.isEmpty else { return c.items.isEmpty || !events.isEmpty ? events : nil }
            let victims = overTransformed && !overBudget && !tooMany ? drafts.indices.filter { !drafts[$0].pad.transform.isNative } : Array(drafts.indices)
            guard let victim = victims.min(by: { a, b in
                let pa = priority.firstIndex(of: drafts[a].pad.role)!, pb = priority.firstIndex(of: drafts[b].pad.role)!
                return pa != pb ? pa < pb : drafts[a].start > drafts[b].start
            }) else { return nil }
            if drafts.count == 1 { return nil }
            drafts.remove(at: victim)
        }
    }

    /// One dry voice: a later event chokes the earlier one 2 ms before its start.
    func chokes(_ drafts: [Draft]) -> [DialogueEvent] {
        drafts.indices.map { i in
            let d = drafts[i]
            var duration = d.pad.duration
            var choke: Double?
            if i + 1 < drafts.count, d.end + DialogueTuning.dryGapSeconds > drafts[i + 1].start, !d.pad.protected {
                choke = drafts[i + 1].start
                duration = drafts[i + 1].start - DialogueTuning.chokeLeadSeconds - d.start
            }
            return DialogueEvent(padID: d.pad.padID, role: d.pad.role, block: phrase, slot: d.slot, accentTime: d.accent,
                                 startTime: d.start, duration: duration, gainDB: DialogueTuning.roleTrimDB(d.pad.role),
                                 protected: d.pad.protected, chokeAt: choke, text: d.pad.text, transform: d.pad.transform,
                                 padKey: d.pad.padKey, snareLanded: d.snare)
        }
    }

    // MARK: Checks

    func passes(_ c: Candidate, _ events: [DialogueEvent]) -> Bool {
        let elements = events.map { DialogueElement(padKey: $0.padKey, slot: $0.slot) }
        // Micro change: consecutive blocks differ.
        if let previous = record(phrase - 1), !previous.elements.isEmpty, !elements.isEmpty,
           DialoguePerformer.shared(previous.elements, elements) == elements.count, previous.elements.count == elements.count {
            return false
        }
        // 16-bar ceiling, per block so that every window pair differs by at least 0.25.
        if let earlier = record(phrase - 4), !earlier.elements.isEmpty, !elements.isEmpty {
            let limit = DialogueTuning.blockOverlapShare * Double(min(earlier.elements.count, elements.count))
            if Double(DialoguePerformer.shared(earlier.elements, elements)) > limit { return false }
        }
        // Macro change: the family or the bank changes every 8 bars.
        if groupStart, !events.isEmpty, let group = record(phrase - 2), group.events > 0,
           group.bankID == bank.bankID, group.family == c.family {
            return false
        }
        if c.family == .textureFill {
            for p in (phrase - DialogueTuning.textureFillEvery + 1)..<phrase where record(p)?.family == .textureFill { return false }
        }
        // One anchor or answer per 8 bars lands on the drummer's snare.
        if !groupStart, !snapshot.snares.isEmpty, let first = record(phrase - 1) {
            let any = first.events + events.count > 0
            if any, !first.snareLanded, !events.contains(where: { $0.snareLanded }) { return false }
        }
        return true
    }

    mutating func plan() -> (DialogueBlock, DialogueBlockRecord, UInt64?) {
        let all = candidates()
        var chosen: (Candidate, [DialogueEvent])?
        var forced = false
        for (index, c) in all.enumerated() {
            guard let events = realize(c), passes(c, events) else { continue }
            if c.family != .rest, events.isEmpty, !c.items.isEmpty { continue }
            chosen = (c, events)
            forced = index > 0 && c.change.hasPrefix("forced")
            break
        }
        let (c, events) = chosen ?? (Candidate(family: .rest, variation: 0, items: [], change: "forced:rest", lead: nil), [])
        if chosen == nil { forced = true }
        let family = events.isEmpty ? DialogueFamily.rest : c.family
        let elements = events.map { DialogueElement(padKey: $0.padKey, slot: $0.slot) }
        let print = DialoguePerformer.fingerprint(family, elements)
        let block = DialogueBlock(phrase: phrase, section: section, family: family, variation: c.variation, fingerprint: print,
                                  events: events, forcedChange: forced || c.change.hasPrefix("forced"), noDialogue: false,
                                  change: c.change)
        let items = events.map { DialogueItem(padID: $0.padID, slot: $0.slot, gesture: 0) }
        let leadKey = c.lead.flatMap { lead in events.contains { $0.padID == lead.padID } ? lead.padKey : nil }
        return (block, Self.record(block, bankID: bank.bankID, items: items, lead: leadKey), leadKey)
    }
}
