import Foundation

/// Optional sound-only override. The caller still draws the original catalog start from its original
/// stream. This independent stream cannot perturb clip rotation or an empty-index playback sequence.
nonisolated enum FootageSalience {
    struct Selection {
        let clip: ArchiveClip
        let piece: FootagePiece
        let preroll: Double
        let readStart: Double
        let sourceLength: Double
        let catalogStart: Double
        /// Only recorded by the paired diagnostic, including when the random path was drawn.
        let measuredFeasible: Bool?
        let targeted: Bool
        let salientLine: DialogueSalienceIndex.Line?
    }

    /// Shared by the live decoder and the paired verification: eligibility, original RNG draws,
    /// source-vs-playback cue math and final cue containment all use one policy.
    static func prepare(_ r: FootageWeaver.Request, clips: [ArchiveClip],
                        weaver: inout FootageWeaver, rng: inout MusicRNG, elapsed: Double,
                        index: DialogueSalienceIndex, ledger: DialogueLineLedger,
                        indexed: Bool = true, measureOpportunity: Bool = false) -> Selection? {
        let rate = Double(r.rate)
        let preroll = max(r.start - elapsed + 0.5, 0) * rate
        func segment(for clip: ArchiveClip) -> (length: Double, sourceLength: Double) {
            let usable = max(clip.duration - 1, 1)
            let visible = (usable - preroll) / rate
            let length = min(r.length, max(r.fadeIn + 2, visible - 1))
            let margin = min(27, max(visible - length, 2))
            return (length, min(preroll + (length + margin) * rate, usable))
        }

        let different = clips.filter { $0.id != weaver.current?.clipID }
        let pool = r.fill != nil && !different.isEmpty ? different : clips
        let sufficient = pool.filter { $0.duration >= (r.length + 2) * rate + preroll + 1 }
        let candidates = sufficient.isEmpty ? pool : sufficient
        let audioClips = r.sound ? candidates.filter(\.hasAudio) : []
        let eligible = audioClips.isEmpty ? candidates : audioClips
        let boost: [String: Float] = indexed && r.sound ? Dictionary(uniqueKeysWithValues: eligible.map {
            ($0.id, 1 + min(1, Float(index.unplayed(contentID: $0.id, ledger: ledger).count) / 6))
        }) : [:]
        guard let clip = weaver.chooseClipForPlayback(eligible, boost: boost, rng: &rng) else { return nil }
        let plan = segment(for: clip)
        var readStart = ArchiveCatalog.segmentStart(duration: clip.duration, length: plan.sourceLength,
                                                    avoid: clip.shownStarts.map { $0 - preroll }, rng: &rng)
        var targeted = false
        var salientLine: DialogueSalienceIndex.Line?
        var segStart = readStart + preroll
        let catalogStart = segStart
        var measuredFeasible: Bool? = measureOpportunity ? false : nil
        var salienceRNG = FootageSalience.rng(contentID: clip.id, piece: r.index)
        let preliminary = r.piece(clipID: clip.id, segmentStart: segStart, length: plan.length)
        if indexed, r.sound, clip.hasAudio, let cue = ArchiveAudioCuePlan(piece: preliminary, clipDuration: clip.duration),
           let pick = FootageSalience.pick(lines: index.entry(contentID: clip.id).lines, contentID: clip.id,
                                           ledger: ledger, shownStarts: clip.shownStarts, duration: clip.duration,
                                           sourceLength: plan.sourceLength, preroll: preroll, rate: rate,
                                           soundDelay: r.fill == nil ? FootageWeaver.soundDelay : 0,
                                           dialogueLength: ArchiveDialogueSource.containedSeconds(cue), sound: true,
                                           rng: &salienceRNG, measureOpportunity: measureOpportunity) {
            let candidate = r.piece(clipID: clip.id, segmentStart: pick.segmentStart, length: plan.length)
            if let actual = ArchiveAudioCuePlan(piece: candidate, clipDuration: clip.duration),
               pick.line.start >= actual.sourceStart + 3,
               pick.line.end <= actual.sourceStart + ArchiveDialogueSource.containedSeconds(actual) {
                if measureOpportunity { measuredFeasible = true }
                if pick.overrideDraw {
                    segStart = pick.segmentStart
                    readStart = segStart - preroll
                    targeted = true
                    salientLine = pick.line
                }
            }
        }
        let sourceLength = min(plan.sourceLength, clip.duration - readStart)
        let length = plan.length
        var piece = r.piece(clipID: clip.id, segmentStart: segStart, length: length, sound: false)
        let wantsSound = r.sound && clip.hasAudio
        if wantsSound, ArchiveAudioCuePlan(piece: piece, clipDuration: clip.duration) != nil {
            piece.sound = true
        }
        return Selection(clip: clip, piece: piece, preroll: preroll, readStart: readStart, sourceLength: sourceLength,
                         catalogStart: catalogStart, measuredFeasible: measuredFeasible, targeted: targeted, salientLine: salientLine)
    }

    struct Pick: Sendable {
        let overrideDraw: Bool
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
                     rng: inout MusicRNG, measureOpportunity: Bool = false) -> Pick? {
        guard sound, rate > 0, dialogueLength > 0, duration >= sourceLength else { return nil }
        let overrideDraw = rng.chance(0.65)
        guard overrideDraw || measureOpportunity else { return nil }
        let delay = soundDelay * rate
        // A line must fit in its entirety, after its 3...10 film-second lead-in. Check again after
        // clamping: near either edge a valid raw start can become an unusable cue.
        let candidates = lines.filter {
            $0.interest >= 0.6 && $0.end > $0.start && $0.end - $0.start + 3 <= dialogueLength
                && ledger.lastPlay(contentID: contentID, seconds: $0.seconds) == nil
        }.sorted { ($0.interest, -$0.start) > ($1.interest, -$1.start) }
        let sortedStarts = shownStarts.sorted()
        var feasible: [Pick] = []
        for line in candidates {
            // Intersect the entire legal start interval with the film and shown-start limits.
            // Testing a single drawn lead can discard a line even though another lead fits.
            let latest = min(line.start - delay - 3, duration - sourceLength + preroll)
            let earliest = max(preroll, line.start - delay - 10, line.end - delay - dialogueLength)
            guard earliest <= latest else { continue }
            let ranges = ArchiveCatalog.freshRanges(in: earliest...latest, shown: sortedStarts, separation: 20)
            let start: Double
            if ranges.isEmpty {
                // freshRanges returns positive lengths. A single exact legal endpoint also fits.
                let edges = [earliest, latest] + shownStarts.flatMap { [$0 - 20, $0 + 20] }
                guard let edge = edges.first(where: { value in
                    (earliest...latest).contains(value) && shownStarts.allSatisfy { abs($0 - value) >= 20 }
                }) else { continue }
                start = edge
            } else {
                let interval = ranges.count == 1 ? ranges[0] : ranges[rng.weighted(ranges.map { Float($0.upperBound - $0.lowerBound) })]
                // Preserve the direction of the seeded lead-in draw.
                start = interval.upperBound - rng.range(0...(interval.upperBound - interval.lowerBound))
            }
            feasible.append(Pick(overrideDraw: overrideDraw, segmentStart: start, line: line))
            if feasible.count == 5 { break }
        }
        guard !feasible.isEmpty else { return nil }
        return feasible[rng.weighted(feasible.map { $0.line.interest })]
    }
}
