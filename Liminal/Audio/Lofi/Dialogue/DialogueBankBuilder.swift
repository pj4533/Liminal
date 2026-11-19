import Foundation

/// Ranks units by sound, then builds a small stable bank of related pads (plan 4.4, 4.5).
nonisolated enum DialogueBankBuilder {
    static func build(_ analysis: DialogueAnalysis, transcript: DialogueTranscript?, seed: UInt64) -> DialoguePadBank? {
        guard analysis.features != nil, !analysis.units.isEmpty else { return nil }
        var units = analysis.units
        var rejections = analysis.rejections
        var words: [DialogueWordSpan] = []
        if let transcript {
            let refined = DialogueHierarchy.refine(analysis, transcript: transcript)
            units = refined.units
            rejections = refined.rejections
            words = refined.words
        }
        let rate = analysis.sampleRate
        // A cue led by music or singing gives no bank, whatever its envelopes look like.
        if !analysis.speech.isEmpty {
            let spoken = analysis.speech.filter { $0.speech > max(0.3, $0.singing, $0.music) }.count
            guard Double(spoken) >= DialogueTuning.minimumSpokenShare * Double(analysis.speech.count) else { return nil }
        }
        let rejected = Set(rejections.map(\.unit))
        for i in units.indices { units[i].score.rhythmicFit = rhythmicFit(units[i], rate: rate) }
        let valid = units.filter { !rejected.contains($0.id) && $0.score.sound >= DialogueTuning.minimumPadSound }
        func seconds(_ u: SpeechUnit) -> Double { u.seconds(rate) }

        /// Sound first. Rhythmic fit only breaks ties within 10 percent among the best six.
        func best(_ pool: [SpeechUnit]) -> SpeechUnit? {
            let ranked = pool.sorted { ($0.score.sound, -$0.id) > ($1.score.sound, -$1.id) }
            guard let leader = ranked.first else { return nil }
            let tied = ranked.prefix(DialogueTuning.rhythmicFitPool)
                .filter { $0.score.sound >= leader.score.sound * (1 - DialogueTuning.rhythmicTieShare) }
            return tied.max { ($0.score.rhythmicFit, $0.score.sound, -$0.id) < ($1.score.rhythmicFit, $1.score.sound, -$1.id) }
        }

        // Fallback order (plan 5.5): an original-order line, a shorter phrase, one stab.
        let lines = valid.filter { [.utterance, .phrase].contains($0.level) && seconds($0) <= DialogueTuning.anchorMaximumSeconds }
        guard let anchor = best(lines.filter { $0.level == .utterance }) ?? best(lines) ?? best(valid.filter { $0.level == .stab })
        else { return nil }
        guard anchor.score.sound >= DialogueTuning.minimumAnchorSound else { return nil }

        var reorder = DialogueReorder.sourceOrder
        let usedTranscript = units.contains { $0.text != nil }
        if usedTranscript {
            reorder = DialogueReorderGuard.arrange(words: words, units: units, analysis: analysis, excluded: rejected)
        }

        var chosen: [(SpeechUnit, DialoguePad.Role, DialogueTransform)] = [(anchor, .anchor, .native)]
        func overlaps(_ u: SpeechUnit, _ v: SpeechUnit) -> Bool { u.frames.overlaps(v.frames) }
        func taken(_ u: SpeechUnit) -> Bool { chosen.contains { $0.0.frames == u.frames } }
        let phrases = valid.filter { [.phrase, .wordGroup].contains($0.level) && seconds($0) <= DialogueTuning.headMaximumSeconds }

        // Heads: the first clause of the anchor, or the best other phrase; answers follow them.
        var heads: [SpeechUnit] = []
        if case .arrangement(let ids, .exchangeClauses) = reorder, ids.count == 2,
           let first = units.first(where: { $0.id == ids[1] }), let second = units.first(where: { $0.id == ids[0] }),
           !taken(first), !taken(second) {
            heads.append(first)
            chosen.append((first, .head, .native))
            chosen.append((second, .answer, .native))
        }
        if heads.isEmpty {
            let children = phrases.filter { $0.parentID == anchor.id && $0.level == .phrase }.sorted { $0.frames.lowerBound < $1.frames.lowerBound }
            if anchor.level == .utterance, children.count >= 2 { heads.append(children[0]) }
            else if let other = best(phrases.filter { !overlaps($0, anchor) && $0.level == .phrase }) { heads.append(other) }
            if let h = heads.first {
                chosen.append((h, .head, .native))
                if let answer = follower(h, in: units, valid: valid, rate: rate), !taken(answer) { chosen.append((answer, .answer, .native)) }
            }
        }
        if let first = heads.first, DialogueTuning.headCount > 1,
           let second = best(phrases.filter { u in !taken(u) && !overlaps(u, first) && !overlaps(u, anchor) && u.level == .phrase }),
           second.score.sound >= first.score.sound * 0.6 {
            chosen.append((second, .head, .native))
            if chosen.filter({ $0.1 == .answer }).count < DialogueTuning.answerCount,
               let answer = follower(second, in: units, valid: valid, rate: rate), !taken(answer) {
                chosen.append((answer, .answer, .native))
            }
        }

        // Stabs: stressed syllable groups, from the anchor first, with varied entrances.
        var stabs: [SpeechUnit] = []
        let stabPool = valid.filter { $0.level == .stab && !taken($0) }
            .sorted { a, b in
                let ia = anchor.frames.contains(a.frames.lowerBound), ib = anchor.frames.contains(b.frames.lowerBound)
                return ia != ib ? ia : (a.score.sound, -a.id) > (b.score.sound, -b.id)
            }
        let fromAnchor = stabPool.filter { anchor.frames.contains($0.frames.lowerBound) }
        for (pool, limit) in [(fromAnchor, 3), (stabPool, DialogueTuning.stabCount.upperBound)] {
            while stabs.count < limit {
                let options = pool.filter { s in !stabs.contains { overlaps($0, s) } }
                guard let pick = options.max(by: { a, b in
                    func value(_ s: SpeechUnit) -> Float {
                        s.score.sound * (stabs.contains { $0.onset == s.onset } ? 0.85 : 1)
                    }
                    return (value(a), -a.id) < (value(b), -b.id)
                }) else { break }
                stabs.append(pick)
            }
        }
        for s in stabs where chosen.count < DialogueTuning.bankSize.upperBound - 2 { chosen.append((s, .stab, .native)) }

        // One sibling at a single linked-rate step; one texture slice.
        // Transforms are seeded by the content and source range, so each film gets its own sibling.
        var identity = DialogueHash()
        identity.add(analysis.contentID)
        identity.add(Int((analysis.clock.sourceStart * 100).rounded()))
        var rng = MusicRNG(seed: seed ^ identity.value ^ 0xD1A1_0C0E)
        let siblingBase = chosen.first { $0.1 == .stab }?.0 ?? heads.first
        var siblingSemitones: Double?
        if let base = siblingBase {
            let semitones = rng.pick(DialogueTuning.siblingSemitones)
            if DialogueTuning.transformSemitones.contains(semitones) {
                chosen.append((base, .sibling, .linkedRate(semitones: semitones)))
                siblingSemitones = semitones
            } else {
                rejections.append(DialogueRejection(unit: base.id, reason: .overTransformed))
            }
        }
        let chosenStabs = Set(chosen.filter { $0.1 == .stab }.map(\.0.id))
        let textures = valid.filter { $0.level == .texture }
        let texture = best(textures.filter { $0.parentID.map(chosenStabs.contains) ?? false }) ?? best(textures)
        if let texture, chosen.count < DialogueTuning.bankSize.upperBound {
            let semitones = rng.pick(DialogueTuning.textureSemitones)
            chosen.append((texture, .texture, semitones == 0 ? .native : .linkedRate(semitones: semitones)))
        }

        // Chronological pads, stable ids.
        let roleOrder = DialoguePad.Role.allCases
        chosen.sort { a, b in
            if a.0.frames.lowerBound != b.0.frames.lowerBound { return a.0.frames.lowerBound < b.0.frames.lowerBound }
            if a.0.frames.upperBound != b.0.frames.upperBound { return a.0.frames.upperBound > b.0.frames.upperBound }
            return roleOrder.firstIndex(of: a.1)! < roleOrder.firstIndex(of: b.1)!
        }
        var seen = Set<String>()
        chosen = chosen.filter { seen.insert("\($0.0.frames)|\($0.2.name)").inserted }
        var pads: [DialoguePad] = []
        for (index, entry) in chosen.enumerated() {
            let (unit, role, transform) = entry
            let accent = unit.stressAnchors.first ?? unit.frames.lowerBound
            pads.append(DialoguePad(
                padID: index, unitID: unit.id, role: role, frames: unit.frames, transform: transform,
                accentOffset: Double(accent - unit.frames.lowerBound) / rate,
                duration: Double(unit.frames.count) / rate / transform.playbackRate,
                protected: role == .anchor || role == .answer, text: unit.text,
                fadeIn: unit.fadeIn, fadeOut: unit.fadeOut, level: unit.level, score: unit.score,
                padKey: DialogueHash.padKey(sourceID: analysis.contentID, frames: unit.frames, transform: transform)))
        }
        guard let anchorPad = pads.first(where: { $0.role == .anchor }) else { return nil }
        var groups: [[Int]] = []
        if siblingSemitones != nil, let sibling = pads.first(where: { $0.role == .sibling }),
           let base = pads.first(where: { $0.role != .sibling && $0.frames == sibling.frames && $0.transform == .native }) {
            groups.append([base.padID, sibling.padID])
        }
        var hash = DialogueHash()
        hash.add(analysis.contentID)
        hash.add(Int((analysis.clock.sourceStart * 100).rounded()))
        hash.add(analysis.bufferFrames)
        hash.add(analysis.version)
        for pad in pads {
            hash.add(pad.unitID)
            hash.add(pad.role.rawValue)
            hash.add(pad.frames.lowerBound)
            hash.add(pad.frames.upperBound)
            hash.add(pad.transform)
        }
        let starts = Dictionary(units.map { ($0.id, $0.frames.lowerBound) }, uniquingKeysWith: { a, _ in a })
        let original = Array(Set(pads.map(\.unitID))).sorted { (starts[$0] ?? 0, $0) < (starts[$1] ?? 0, $1) }
        let arranged = reorder.units.isEmpty ? original : reorder.units
        let text: String? = usedTranscript
            ? arranged.compactMap { id in units.first { $0.id == id }?.text }.joined(separator: " / ")
            : nil
        return DialoguePadBank(bankID: hash.value, analysisVersion: analysis.version, pads: pads,
                               anchorPadID: anchorPad.padID, siblingGroups: groups, sourceID: analysis.contentID,
                               clock: analysis.clock, rejections: rejections, usedTranscript: usedTranscript,
                               reorder: reorder, originalOrder: original, arrangedOrder: arranged,
                               intendedText: text?.isEmpty == true ? nil : text)
    }

    /// The unit that follows `head` in source order at the same level, when usable.
    private static func follower(_ head: SpeechUnit, in units: [SpeechUnit], valid: [SpeechUnit], rate: Double) -> SpeechUnit? {
        guard let next = head.nextID, let unit = valid.first(where: { $0.id == next }),
              unit.seconds(rate) <= DialogueTuning.headMaximumSeconds else { return nil }
        // Only a nearby continuation answers the head (within 2 s of its end).
        guard Double(unit.frames.lowerBound - head.frames.upperBound) / rate < 2 else { return nil }
        return unit
    }

    /// Fit to a 1 to 4.4 s span (two bars at the fastest tempo) and regular stress spacing.
    static func rhythmicFit(_ unit: SpeechUnit, rate: Double) -> Float {
        let d = unit.seconds(rate)
        let span: Double = switch unit.level {
        case .utterance, .phrase, .wordGroup: d < 1 ? d : d <= 4.4 ? 1 : max(0, 1 - (d - 4.4) / 3)
        case .stab: d <= 0.45 ? 1 : max(0, 1 - (d - 0.45) / 0.3)
        case .texture: 1
        }
        return Float(span) * (0.5 + 0.5 * unit.score.accentRegularity)
    }
}
