import Foundation

/// Optional sound-only override. The caller still draws the original catalog start from its original
/// stream. This independent stream cannot perturb clip rotation or an empty-index playback sequence.
nonisolated enum FootageSalience {
    struct Pick: Sendable {
        let segmentStart: Double
        let line: DialogueSalienceIndex.Line
    }

    static func rng(contentID: String, piece: Int) -> MusicRNG {
        var hash = DialogueHash()
        hash.add(contentID)
        hash.add(piece)
        return MusicRNG(seed: hash.value ^ 0x5A11_EACE)
    }

    static func pick(lines: [DialogueSalienceIndex.Line], contentID: String, ledger: DialogueLineLedger,
                     shownStarts: [Double], duration: Double, sourceLength: Double, preroll: Double,
                     rate: Double, soundDelay: Double, dialogueLength: Double, sound: Bool,
                     rng: inout MusicRNG) -> Pick? {
        guard sound, rate > 0, dialogueLength > 0, duration >= sourceLength, rng.chance(0.65) else { return nil }
        let delay = soundDelay * rate
        // A line must fit in its entirety, after its 3...10 film-second lead-in. Check again after
        // clamping: near either edge a valid raw start can become an unusable cue.
        let candidates = lines.filter {
            $0.interest >= 0.6 && $0.end > $0.start && $0.end - $0.start + 3 <= dialogueLength
                && ledger.lastPlay(contentID: contentID, seconds: $0.seconds) == nil
        }.sorted { ($0.interest, -$0.start) > ($1.interest, -$1.start) }
        var feasible: [Pick] = []
        for line in candidates {
            let lead = rng.range(3...min(10, dialogueLength - (line.end - line.start)))
            let readStart = min(max(0, line.start - lead - delay - preroll), max(0, duration - sourceLength))
            let start = readStart + preroll
            let cueStart = start + delay
            guard line.start - cueStart >= 3, line.start - cueStart <= 10,
                  line.end <= min(duration, cueStart + dialogueLength),
                  shownStarts.allSatisfy({ abs($0 - start) >= 20 }) else { continue }
            feasible.append(Pick(segmentStart: start, line: line))
            if feasible.count == 5 { break }
        }
        guard !feasible.isEmpty else { return nil }
        return feasible[rng.weighted(feasible.map { $0.line.interest })]
    }
}
