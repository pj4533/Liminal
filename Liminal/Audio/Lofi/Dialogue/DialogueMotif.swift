import AVFoundation
import Foundation

// MPC motif chopping (docs/plans/mpc-chopping.md, section 5; user direction of 19 November 2026).
// One line per 16-bar loop is the motif. It is split into word and syllable pieces, and the pieces
// are sequenced on the drummer's sixteenth grid in 2-bar cells (statement, repeat-stutter, split
// with a pause, reorder, call and answer, a sparse breakdown, the return and a turnaround), so that
// every bar of the loop has a piece onset. Pure and seeded; nothing here touches audio threads.

/// Tuning of the motif layer. Values are *start* hypotheses (plan section 5).
nonisolated enum DialogueMotifTuning {
    /// Motif line length, and the relaxed range when no line of that length exists.
    static let lineSeconds: ClosedRange<Double> = 1.2...4.0
    static let relaxedLineSeconds: ClosedRange<Double> = 0.7...4.5
    /// A line never spans more than this many bars, so a piece can follow it in the cell's second bar.
    static let lineMaximumBars = 1.4
    static let lineMinimumNuclei = 3
    /// Transcribed lines rank this much higher (the user's preference).
    static let transcribedLineBonus: Float = 1.25
    /// Acoustic pieces aim at this length (a word group such as "when they"), two to six per line;
    /// syllable halves then split them ("when" | "they", "invest" | "tigate").
    static let pieceSeconds = 0.45
    /// Acoustic pieces longer than this are cut again at their deepest inner valley.
    static let maximumPieceSeconds = 0.62
    /// Lines up to this long rank fully; longer ones lose up to 20 percent at the 4 s limit.
    static let preferredLineSeconds = 2.6
    /// Each syllable half keeps at least this share of its piece.
    static let minimumHalfShare = 0.28
    static let pieceCount: ClosedRange<Int> = 2...6
    static let minimumPieceSeconds = 0.12
    /// Acoustic word-group cuts keep at least this much on each side (a word, not a syllable;
    /// syllable halves may be as short as `minimumPieceSeconds`).
    static let minimumCutSeconds = 0.22
    /// A word group shorter than this takes the next word; groups hold at most three words and
    /// break at a pause of at least `groupPauseSeconds`.
    static let groupJoinSeconds = 0.25
    static let groupMaximumWords = 3
    static let groupPauseSeconds = 0.12
    /// Pieces at least this long with two syllable nuclei also get syllable halves ("invest" | "tigate").
    static let splitPieceSeconds = 0.26
    /// Cut points move to the quietest 1 ms frame within this distance, then to a zero crossing.
    static let cutSnapSeconds = 0.060
    static let zeroCrossingSeconds = 0.002
    static let burstFadeInSeconds = 0.003
    static let fadeInSeconds = 0.006
    static let fadeOutSeconds = 0.010
    /// A fragment shorter than half the line counts as a sub-line piece.
    static let subLineShare = 0.5
    /// The full line plays at most this often per loop.
    static let maximumLineStatements = 2
    /// A line leads at most this many loops (the first time and one return), never two in a row.
    static let lineUses = 2
    static let lineHistory = 8
    /// The return's first bar: one short piece this much lower, so the lead's hook stays clear.
    static let returnPieceDB: Float = -3
    /// Echo throw: repeats every 0.75 beat at these levels, band-limited, inside the following space.
    static let echoDelayBeats = 0.75
    /// Three repeats (two at -7 and -13 dB before; user direction of 19 November 2026: more echo).
    static let echoGainsDB: [Float] = [-6, -10, -15]
    static let echoTailBeats = 2.4
    static let minimumEchoTailSeconds = 0.25
    static let echoBand = (low: 400.0, high: 3000.0)
    /// The filtered repeat: a 600 Hz to 2.8 kHz band, loudness-matched to the dry piece with at most this make-up.
    static let filteredBand = (low: 600.0, high: 2800.0)
    static let filteredMakeupDB: Float = 8
    /// The reversed pickup ends this long before the slot it leads into.
    static let reversedLeadSeconds = 0.030
    static let reversedChance: Float = 0.5
    /// A piece may move this many sixteenths later when its slot is taken or too early.
    static let slotShift = 2
    /// Pieces may sound this long after the bed ends: the chop fader closes `ArchiveVoice.chopTailSeconds`
    /// after the cue, less a margin for the release.
    static let tailAfterBedSeconds = 1.75
    /// The first piece of a late plan may move this far to stay in its bar.
    static let lateSlotShift = 6
    /// A statement in the breakdown (the second and last full line) with this chance.
    static let secondStatementChance: Float = 0.45
    /// Coverage repair tries these sixteenths of an empty bar, in order.
    static let repairSlots = [8, 4, 12, 6, 10, 14, 2, 1, 3, 5, 7, 9, 11, 13, 15]
}

/// One playable cut of the motif line.
nonisolated struct DialogueMotifFragment: Sendable, Equatable {
    enum Kind: String, Sendable { case line, piece, half }
    /// Pad id in the motif bank.
    let id: Int
    let kind: Kind
    /// Source-order position of the piece (a half keeps its parent's).
    let order: Int
    /// The piece a half was cut from.
    let parent: Int?
    let frames: Range<Int>
    /// Source frame of the first syllable onset: the frame that lands on the slot.
    let accentFrame: Int
    let fadeIn: Int
    let fadeOut: Int
    let text: String?
}

/// A line that led a loop.
nonisolated struct DialogueMotifLineUse: Sendable, Equatable {
    let key: UInt64
    let loop: Int
    let contentID: String
    let frames: Range<Int>
}

/// A 2-bar cell of pieces. Slots are sixteenths from the cell start; an `after` item sits on the
/// first sixteenth (at or after `slot`) that leaves `after` sixteenths of space after the previous event.
nonisolated struct DialogueMotifCell: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        enum Effect: String, Sendable { case none, echoThrow, filtered, reversed }
        let fragment: Int
        let slot: Int
        var after: Int? = nil
        var gainDB: Float = 0
        var effect: Effect = .none
        /// Places only when the window reaches the next loop (the turnaround's landing).
        var landing = false
    }
    let kind: DialogueCell
    let bar: Int
    let bars: Int
    let variant: Int
    let items: [Item]
}

/// The motif of one 16-bar loop.
nonisolated struct DialogueMotif: @unchecked Sendable {
    let loop: Int
    /// The PCM and analysis the line was cut from (kept so the loop's second film piece still plays it).
    let source: DialogueSource
    let analysis: DialogueAnalysis
    let lineUnit: Int
    let lineKey: UInt64
    /// `[0]` is the line, then the pieces in source order, then the halves.
    let fragments: [DialogueMotifFragment]
    let pieces: [Int]
    /// Piece id to its two syllable halves.
    let halves: [Int: [Int]]
    let bank: DialoguePadBank
    let usedTranscript: Bool
    let reorderAllowed: Bool
    let cells: [DialogueMotifCell]
    /// Carried over from an earlier loop because this loop's film offered no line.
    let carried: Bool
    let seed: UInt64

    var line: DialogueMotifFragment { fragments[0] }
    var sampleRate: Double { source.sampleRate }
    func seconds(_ id: Int) -> Double { Double(fragments[id].frames.count) / sampleRate }
    func accentOffset(_ id: Int) -> Double { Double(fragments[id].accentFrame - fragments[id].frames.lowerBound) / sampleRate }
    /// Sub-line: shorter than half the line.
    func isSubLine(_ id: Int) -> Bool { id != 0 && seconds(id) < DialogueMotifTuning.subLineShare * seconds(0) }

    /// The loop of a take-relative beat: global phrase / 4 (floor).
    static func loopIndex(beat: Double, snapshot: DialogueTransportSnapshot) -> Int {
        let phrase = snapshot.phraseAtOrigin + Int((beat / 16 + 1e-9).rounded(.down))
        return Int((Double(phrase) / 4).rounded(.down))
    }

    /// Take-relative beat of a loop's first bar.
    static func loopBeat(_ loop: Int, snapshot: DialogueTransportSnapshot) -> Double {
        Double(loop * 4 - snapshot.phraseAtOrigin) * 16
    }

    /// The 8-bar span a cue window owns: from the fill boundary at or before its start (within the
    /// two-beat lead-in a cue may begin with) to the next one.
    static func ownedBeats(_ window: Range<Double>, snapshot: DialogueTransportSnapshot) -> Range<Double> {
        let start = ((snapshot.beat(time: window.lowerBound) + 2) / 32).rounded(.down) * 32
        return start..<(start + 32)
    }

    // MARK: Building

    /// The loop's motif: the stored one for this loop (re-cut by words when its own transcript
    /// arrives), a new line from this cue, or the previous loop's line with a new arrangement when
    /// this film offers none. Nil when there is no line at all.
    static func resolve(loop: Int, source: DialogueSource, analysis: DialogueAnalysis, hasBank: Bool,
                        transcript: DialogueTranscript?, memory: DialoguePerformanceMemory, seed: UInt64,
                        beatDuration: Double) -> DialogueMotif? {
        if let current = memory.motif, current.loop == loop {
            if let transcript, !current.usedTranscript, current.source.contentID == source.contentID,
               current.source.sourceStart == source.sourceStart,
               let recut = make(loop: loop, source: source, analysis: analysis, transcript: transcript, memory: memory,
                                seed: current.seed, beatDuration: beatDuration, line: current.lineUnit) {
                return recut
            }
            return current
        }
        if hasBank, let fresh = make(loop: loop, source: source, analysis: analysis, transcript: transcript, memory: memory,
                                     seed: seed, beatDuration: beatDuration) {
            return fresh
        }
        if let previous = memory.motif { return previous.carried(to: loop, seed: seed, memory: memory) }
        return nil
    }

    /// The same line and pieces, arranged for another loop.
    func carried(to loop: Int, seed: UInt64, memory: DialoguePerformanceMemory) -> DialogueMotif {
        let loopSeed = seed ^ UInt64(bitPattern: Int64(loop)) &* 0x9E37_79B9
        let cells = Self.arrange(fragments: fragments, pieces: pieces, halves: halves, reorderAllowed: reorderAllowed,
                                 seed: loopSeed, lineSeconds: seconds(0), sampleRate: sampleRate)
        return DialogueMotif(loop: loop, source: source, analysis: analysis, lineUnit: lineUnit, lineKey: lineKey,
                             fragments: fragments, pieces: pieces, halves: halves, bank: bank, usedTranscript: usedTranscript,
                             reorderAllowed: reorderAllowed, cells: cells, carried: true, seed: loopSeed)
    }

    /// Chooses the best line (or `line` when given), cuts it into pieces and arranges the loop.
    static func make(loop: Int, source: DialogueSource, analysis: DialogueAnalysis, transcript: DialogueTranscript?,
                     memory: DialoguePerformanceMemory, seed: UInt64, beatDuration: Double, line wanted: Int? = nil) -> DialogueMotif? {
        guard let f = analysis.features, !analysis.units.isEmpty, analysis.contentID == source.contentID,
              let samples = source.buffer.floatChannelData?[0] else { return nil }
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
        let maximum = min(DialogueMotifTuning.lineSeconds.upperBound, DialogueMotifTuning.lineMaximumBars * 4 * beatDuration)
        let line: SpeechUnit
        if let wanted, let unit = units.first(where: { $0.id == wanted }) {
            line = unit
        } else {
            let ranked = rankedLines(units: units, rejections: rejections, rate: rate, maximum: maximum)
            let used = memory.motifLines
            func blocked(_ u: SpeechUnit) -> Bool {
                let key = lineKey(analysis.contentID, u.frames)
                if used.filter({ $0.key == key }).count >= DialogueMotifTuning.lineUses { return true }
                // Never the previous loop's line, nor a line overlapping it by more than half.
                return used.contains { use in
                    use.loop == loop - 1 && use.contentID == analysis.contentID
                        && overlapShare(use.frames, u.frames) > 0.5
                }
            }
            guard let pick = ranked.first(where: { !blocked($0) }) else { return nil }
            line = pick
        }
        let count = min(source.frameCount, f.frameCount)
        guard line.frames.lowerBound >= 0, line.frames.upperBound <= count else { return nil }
        let lineWords = words.filter { line.frames.contains(($0.frames.lowerBound + $0.frames.upperBound) / 2) }
        var cutter = Cutter(f: f, samples: samples, count: count, rate: rate)
        guard let cut = cutter.cut(line, words: lineWords) else { return nil }
        let reorderAllowed = lineWords.count < 2 || DialogueReorderGuard.allowsPieceReorder(lineWords.map(\.text))
        let loopSeed = seed ^ UInt64(bitPattern: Int64(loop)) &* 0x9E37_79B9
        let cells = arrange(fragments: cut.fragments, pieces: cut.pieces, halves: cut.halves, reorderAllowed: reorderAllowed,
                            seed: loopSeed, lineSeconds: Double(line.frames.count) / rate, sampleRate: rate)
        let key = lineKey(analysis.contentID, line.frames)
        let bank = motifBank(cut.fragments, line: line, analysis: analysis, key: key, usedTranscript: lineWords.count >= 2)
        return DialogueMotif(loop: loop, source: source, analysis: analysis, lineUnit: line.id, lineKey: key,
                             fragments: cut.fragments, pieces: cut.pieces, halves: cut.halves, bank: bank,
                             usedTranscript: lineWords.count >= 2, reorderAllowed: reorderAllowed, cells: cells,
                             carried: false, seed: loopSeed)
    }

    /// Whole lines in rank order: sound times line fit, transcribed lines first among equals.
    static func rankedLines(units: [SpeechUnit], rejections: [DialogueRejection], rate: Double, maximum: Double) -> [SpeechUnit] {
        let rejected = Dictionary(rejections.map { ($0.unit, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let lines = units.filter {
            [.utterance, .phrase, .wordGroup].contains($0.level) && rejected[$0.id] == nil
                && $0.score.sound >= DialogueTuning.minimumPadSound && $0.nuclei >= DialogueMotifTuning.lineMinimumNuclei
        }
        func value(_ u: SpeechUnit) -> Float {
            let d = u.seconds(rate)
            let length = d <= DialogueMotifTuning.preferredLineSeconds ? 1
                : max(0.8, 1 - 0.2 * Float((d - DialogueMotifTuning.preferredLineSeconds) / (DialogueMotifTuning.lineSeconds.upperBound - DialogueMotifTuning.preferredLineSeconds)))
            return u.score.sound * DialogueBankBuilder.lineFit(u, units: units, rejected: rejected) * length
                * (u.text != nil ? DialogueMotifTuning.transcribedLineBonus : 1)
        }
        func within(_ r: ClosedRange<Double>) -> [SpeechUnit] {
            lines.filter { r.contains($0.seconds(rate)) && $0.seconds(rate) <= maximum }
                .sorted { (value($0), -$0.id) > (value($1), -$1.id) }
        }
        let preferred = within(DialogueMotifTuning.lineSeconds)
        let relaxed = within(DialogueMotifTuning.relaxedLineSeconds).filter { u in !preferred.contains { $0.id == u.id } }
        return preferred + relaxed
    }

    static func lineKey(_ contentID: String, _ frames: Range<Int>) -> UInt64 {
        DialogueHash.padKey(sourceID: contentID, frames: frames, transform: .native)
    }

    static func overlapShare(_ a: Range<Int>, _ b: Range<Int>) -> Double {
        let overlap = max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        return Double(overlap) / Double(max(1, min(a.count, b.count)))
    }

    /// The fragments as pads, so the existing renderer plays them unchanged.
    static func motifBank(_ fragments: [DialogueMotifFragment], line: SpeechUnit, analysis: DialogueAnalysis, key: UInt64,
                          usedTranscript: Bool) -> DialoguePadBank {
        let rate = analysis.sampleRate
        let pads = fragments.map { fr -> DialoguePad in
            let role: DialoguePad.Role = fr.kind == .line ? .anchor : .stab
            return DialoguePad(padID: fr.id, unitID: fr.kind == .line ? line.id : -1 - fr.id, role: role, frames: fr.frames,
                               transform: .native, accentOffset: Double(fr.accentFrame - fr.frames.lowerBound) / rate,
                               duration: Double(fr.frames.count) / rate, protected: fr.kind == .line, text: fr.text,
                               fadeIn: fr.fadeIn, fadeOut: fr.fadeOut,
                               level: fr.kind == .line ? line.level : (fr.kind == .piece ? .wordGroup : .stab),
                               score: line.score,
                               padKey: DialogueHash.padKey(sourceID: analysis.contentID, frames: fr.frames, transform: .native))
        }
        var hash = DialogueHash()
        hash.add(key)
        hash.add(analysis.version)
        for fr in fragments { hash.add(fr.frames.lowerBound); hash.add(fr.frames.upperBound) }
        let ids = [line.id]
        return DialoguePadBank(bankID: hash.value, analysisVersion: analysis.version, pads: pads, anchorPadID: 0, siblingGroups: [],
                               sourceID: analysis.contentID, clock: analysis.clock, rejections: [], usedTranscript: usedTranscript,
                               reorder: .sourceOrder, originalOrder: ids, arrangedOrder: ids, intendedText: line.text)
    }

    /// The `motif` element of the plan log: the line, its pieces and the loop's cells.
    func log() -> [String: Any] {
        func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return [
            "loop": loop, "line": text as Any, "lineUnit": lineUnit, "lineKey": String(lineKey, radix: 16),
            "usedTranscript": usedTranscript, "reorderAllowed": reorderAllowed, "carried": carried,
            "fragments": fragments.map { fr -> [String: Any] in
                var e: [String: Any] = ["id": fr.id, "kind": fr.kind.rawValue, "order": fr.order,
                                        "source": [r3(source.sourceSeconds(frame: fr.frames.lowerBound)),
                                                   r3(source.sourceSeconds(frame: fr.frames.upperBound))],
                                        "duration": r3(seconds(fr.id)), "accentOffset": r3(accentOffset(fr.id)),
                                        "subLine": isSubLine(fr.id)]
                if let parent = fr.parent { e["parent"] = parent }
                if let t = fr.text { e["text"] = t }
                return e
            },
            "cells": cells.map { ["kind": $0.kind.rawValue, "bar": $0.bar, "bars": $0.bars, "variant": $0.variant,
                                  "items": $0.items.map { [$0.fragment, $0.slot] }] as [String: Any] },
        ]
    }

    var text: String? { line.text }
}

// MARK: - Cutting

/// Splits a line into word-group pieces and syllable halves at energy minima (plan 5, motif).
private nonisolated struct Cutter {
    let f: DialogueFeatures
    let samples: UnsafePointer<Float>
    let count: Int
    let rate: Double

    struct Result {
        let fragments: [DialogueMotifFragment]
        let pieces: [Int]
        let halves: [Int: [Int]]
    }

    func frames(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }
    func level(_ frame: Int) -> Float { f.fine[f.fineIndex(frame: frame)] }
    func dB(_ x: Float) -> Float { 20 * log10f(max(x, 1e-9)) }

    /// The quietest 1 ms frame in `range` (clamped to the analysed span).
    func quietest(_ range: Range<Int>) -> Int {
        let lo = f.fineIndex(frame: max(0, range.lowerBound)), hi = f.fineIndex(frame: max(range.lowerBound, range.upperBound - 1))
        guard hi > lo else { return range.lowerBound }
        var best = lo
        for k in lo...hi where f.fine[k] < f.fine[best] { best = k }
        return min(max(range.lowerBound, best * f.fineHop + f.fineHop / 2), range.upperBound - 1)
    }

    /// A cut moved to the quietest frame within 60 ms (inside `bounds`), then to a zero crossing within 2 ms.
    func snap(_ frame: Int, bounds: Range<Int>) -> Int {
        let r = frames(DialogueMotifTuning.cutSnapSeconds)
        let lo = max(bounds.lowerBound, frame - r), hi = min(bounds.upperBound, frame + r)
        guard hi > lo else { return frame }
        let q = quietest(lo..<hi)
        let z = frames(DialogueMotifTuning.zeroCrossingSeconds)
        var best = q
        var distance = Int.max
        for i in max(1, q - z)..<min(count, q + z) where (samples[i - 1] <= 0) != (samples[i] <= 0) {
            if abs(i - q) < distance { distance = abs(i - q); best = i }
        }
        return min(max(bounds.lowerBound, best), bounds.upperBound)
    }

    /// Nuclei whose peak lies inside `range`, in time order.
    func nuclei(_ range: Range<Int>) -> [DialogueNucleus] {
        f.nuclei.filter { range.contains($0.peakFrame) }.sorted { $0.peakFrame < $1.peakFrame }
    }

    /// Valleys between neighbouring nuclei: frame, depth in dB under the lower peak, and the time the
    /// envelope stays within 3 dB of the valley (a word gap rather than a syllable dip).
    func valleys(_ range: Range<Int>) -> [(frame: Int, depth: Float, run: Double)] {
        let n = nuclei(range)
        guard n.count >= 2 else { return [] }
        var out: [(Int, Float, Double)] = []
        for (a, b) in zip(n, n.dropFirst()) where b.peakFrame > a.peakFrame + 1 {
            let v = quietest(a.peakFrame..<b.peakFrame)
            let floor = dB(level(v))
            let depth = min(dB(level(a.peakFrame)), dB(level(b.peakFrame))) - floor
            var lo = f.fineIndex(frame: v), hi = lo
            let limit = floor + 3
            while lo > f.fineIndex(frame: a.peakFrame), dB(f.fine[lo - 1]) <= limit { lo -= 1 }
            while hi < f.fineIndex(frame: b.peakFrame), dB(f.fine[hi + 1]) <= limit { hi += 1 }
            out.append((v, depth, Double((hi - lo + 1) * f.fineHop) / rate))
        }
        return out
    }

    /// Accent: the onset of the first syllable inside the cut.
    func accent(_ range: Range<Int>) -> Int {
        guard let first = nuclei(range).first else { return range.lowerBound }
        return min(max(range.lowerBound, first.onsetFrame), range.upperBound - 1)
    }

    /// Fade-in: short when the envelope jumps right after the cut (a burst), longer otherwise.
    func fadeIn(at frame: Int) -> Int {
        let after = level(min(count - 1, frame + frames(DialogueTuning.burstRiseSeconds)))
        let burst = dB(after) - dB(level(frame)) > 10
        return frames(burst ? DialogueMotifTuning.burstFadeInSeconds : DialogueMotifTuning.fadeInSeconds)
    }

    mutating func cut(_ line: SpeechUnit, words: [DialogueWordSpan]) -> Result? {
        let span = line.frames
        let minimum = frames(DialogueMotifTuning.minimumCutSeconds)
        var cuts: [Int] = []
        var texts: [String?] = []
        if words.count >= 2 {
            // Word groups: a short group takes the next word (three at most) unless a pause separates them.
            var groups: [[DialogueWordSpan]] = [[words[0]]]
            for w in words.dropFirst() {
                let g = groups[groups.count - 1]
                let length = Double(g.last!.frames.upperBound - g.first!.frames.lowerBound) / rate
                let pause = Double(w.frames.lowerBound - g.last!.frames.upperBound) / rate
                if length < DialogueMotifTuning.groupJoinSeconds, g.count < DialogueMotifTuning.groupMaximumWords,
                   pause < DialogueMotifTuning.groupPauseSeconds {
                    groups[groups.count - 1].append(w)
                } else {
                    groups.append([w])
                }
            }
            for (a, b) in zip(groups, groups.dropFirst()) {
                let lo = a.last!.frames.upperBound, hi = b.first!.frames.lowerBound
                let guess = hi > lo ? quietest(lo..<hi) : (lo + hi) / 2
                cuts.append(snap(guess, bounds: (a.first!.frames.lowerBound + 1)..<max(a.first!.frames.lowerBound + 2, b.last!.frames.upperBound - 1)))
            }
            texts = groups.map { $0.map(\.text).joined(separator: " ") }
        } else {
            // Acoustic: the deepest and longest valleys between syllable nuclei, about one cut per 0.4 s.
            let seconds = Double(span.count) / rate
            let target = min(DialogueMotifTuning.pieceCount.upperBound,
                             max(DialogueMotifTuning.pieceCount.lowerBound, Int((seconds / DialogueMotifTuning.pieceSeconds).rounded())))
            let ranked = valleys(span).sorted { ($0.depth + 40 * Float($0.run)) > ($1.depth + 40 * Float($1.run)) }
            for v in ranked where cuts.count < target - 1 {
                let c = snap(v.frame, bounds: span)
                if c - span.lowerBound >= minimum, span.upperBound - c >= minimum, cuts.allSatisfy({ abs($0 - c) >= minimum }) {
                    cuts.append(c)
                }
            }
            // A piece that is still long is cut again at its deepest inner valley.
            var changed = true
            while changed {
                changed = false
                let edges = [span.lowerBound] + cuts.sorted() + [span.upperBound]
                for (lo, hi) in zip(edges, edges.dropFirst()) where Double(hi - lo) / rate > DialogueMotifTuning.maximumPieceSeconds {
                    let inner = valleys(lo..<hi).map { (snap($0.frame, bounds: lo..<hi), $0.depth) }
                        .filter { $0.0 - lo >= minimum && hi - $0.0 >= minimum }
                    if let best = inner.max(by: { $0.1 < $1.1 }) { cuts.append(best.0); changed = true; break }
                }
            }
        }
        cuts = Array(Set(cuts)).sorted().filter { $0 - span.lowerBound >= frames(DialogueMotifTuning.minimumPieceSeconds)
            && span.upperBound - $0 >= frames(DialogueMotifTuning.minimumPieceSeconds) }
        // Drop cuts that leave a piece under the minimum.
        var kept: [Int] = []
        for c in cuts where c - (kept.last ?? span.lowerBound) >= frames(DialogueMotifTuning.minimumPieceSeconds) { kept.append(c) }
        if let last = kept.last, span.upperBound - last < frames(DialogueMotifTuning.minimumPieceSeconds) { kept.removeLast() }
        guard !kept.isEmpty else { return nil }
        if texts.count != kept.count + 1 { texts = words.count >= 2 ? Self.texts(words, edges: [span.lowerBound] + kept + [span.upperBound]) : [] }

        let fadeOut = frames(DialogueMotifTuning.fadeOutSeconds)
        var fragments = [DialogueMotifFragment(id: 0, kind: .line, order: -1, parent: nil, frames: span,
                                               accentFrame: accent(span), fadeIn: line.fadeIn, fadeOut: line.fadeOut, text: line.text)]
        let edges = [span.lowerBound] + kept + [span.upperBound]
        var pieces: [Int] = []
        for k in 0..<(edges.count - 1) {
            let r = edges[k]..<edges[k + 1]
            let id = fragments.count
            fragments.append(DialogueMotifFragment(
                id: id, kind: .piece, order: k, parent: nil, frames: r, accentFrame: accent(r),
                fadeIn: k == 0 ? line.fadeIn : fadeIn(at: r.lowerBound),
                fadeOut: k == edges.count - 2 ? line.fadeOut : min(fadeOut, r.count / 4),
                text: texts.indices.contains(k) ? texts[k] : nil))
            pieces.append(id)
        }
        // Syllable halves of long pieces: the valley between nuclei closest to the middle, both sides >= 120 ms.
        var halves: [Int: [Int]] = [:]
        let least = frames(DialogueMotifTuning.minimumPieceSeconds)
        for id in pieces {
            let piece = fragments[id]
            let r = piece.frames
            guard Double(r.count) / rate >= DialogueMotifTuning.splitPieceSeconds else { continue }
            let mid = Double(r.lowerBound + r.upperBound) / 2
            let side = max(least, Int(DialogueMotifTuning.minimumHalfShare * Double(r.count)))
            let options = valleys(r).filter { $0.frame - r.lowerBound >= side && r.upperBound - $0.frame >= side }
            func value(_ v: (frame: Int, depth: Float, run: Double)) -> Float {
                v.depth - 24 * Float(abs(Double(v.frame) - mid) / Double(r.count))
            }
            guard let best = options.max(by: { value($0) < value($1) }) else { continue }
            let c = snap(best.frame, bounds: (r.lowerBound + least)..<(r.upperBound - least))
            let (ta, tb) = Self.split(piece.text, at: Double(c - r.lowerBound) / Double(r.count), words: words, cut: c)
            let a = DialogueMotifFragment(id: fragments.count, kind: .half, order: piece.order, parent: id,
                                          frames: r.lowerBound..<c, accentFrame: accent(r.lowerBound..<c),
                                          fadeIn: piece.fadeIn, fadeOut: min(fadeOut, (c - r.lowerBound) / 4), text: ta)
            fragments.append(a)
            let b = DialogueMotifFragment(id: fragments.count, kind: .half, order: piece.order, parent: id,
                                          frames: c..<r.upperBound, accentFrame: accent(c..<r.upperBound),
                                          fadeIn: fadeIn(at: c), fadeOut: piece.fadeOut, text: tb)
            fragments.append(b)
            halves[id] = [a.id, b.id]
        }
        return Result(fragments: fragments, pieces: pieces, halves: halves)
    }

    /// Text per piece from the words whose middles fall inside it.
    static func texts(_ words: [DialogueWordSpan], edges: [Int]) -> [String?] {
        (0..<(edges.count - 1)).map { k in
            let inside = words.filter { (edges[k]..<edges[k + 1]).contains(($0.frames.lowerBound + $0.frames.upperBound) / 2) }
            return inside.isEmpty ? nil : inside.map(\.text).joined(separator: " ")
        }
    }

    /// Text of two halves: whole words on each side, a word cut inside split by letters ("invest-", "-igate").
    static func split(_ text: String?, at share: Double, words: [DialogueWordSpan], cut: Int) -> (String?, String?) {
        guard let text else { return (nil, nil) }
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count > 1 else {
            let letters = Array(text)
            let k = min(letters.count - 1, max(1, Int((Double(letters.count) * share).rounded())))
            return (String(letters[..<k]) + "-", "-" + String(letters[k...]))
        }
        let k = min(parts.count - 1, max(1, Int((Double(parts.count) * share).rounded())))
        return (parts[..<k].joined(separator: " "), parts[k...].joined(separator: " "))
    }
}

// MARK: - Arrangement

nonisolated extension DialogueMotif {
    /// The loop's eight 2-bar cells: a statement, then repeat-stutter, split with a pause, reorder
    /// (or call and answer) and one more in a seeded order, a sparse breakdown (sometimes the second
    /// full line), the return and the turnaround.
    static func arrange(fragments: [DialogueMotifFragment], pieces: [Int], halves: [Int: [Int]], reorderAllowed: Bool,
                        seed: UInt64, lineSeconds: Double, sampleRate: Double) -> [DialogueMotifCell] {
        var rng = MusicRNG(seed: seed ^ 0x4D07_1F00)
        func seconds(_ id: Int) -> Double { Double(fragments[id].frames.count) / sampleRate }
        let n = pieces.count
        // Focal piece X (usually the opening words), the closing piece Y and a middle piece Z.
        var x = pieces[0]
        if n > 2, rng.chance(0.3) { x = pieces[rng.int(1...(n - 2))] }
        let y = pieces[n - 1] == x ? pieces[0] : pieces[n - 1]
        let z = pieces.first { $0 != x && $0 != y } ?? y
        // The split piece: the longest piece that has halves; without halves, the shortest pair of
        // neighbouring pieces stands in (a word group heard as two words with a pause between).
        func next(_ p: Int) -> Int { pieces.firstIndex(of: p).map { $0 + 1 < n ? pieces[$0 + 1] : pieces[max(0, $0 - 1)] } ?? p }
        let split = halves.keys.sorted { (seconds($0), -$0) > (seconds($1), -$1) }.first
        let pair = zip(pieces, pieces.dropFirst()).min { seconds($0.0) + seconds($0.1) < seconds($1.0) + seconds($1.1) }
        let (sa, sb) = split.flatMap { halves[$0] }.map { ($0[0], $0[1]) } ?? pair.map { ($0.0, $0.1) } ?? (x, z)
        let xa = halves[x]?[0] ?? x, xb = halves[x]?[1] ?? next(x)
        let ya = halves[y]?[0] ?? y
        typealias Item = DialogueMotifCell.Item
        func at(_ f: Int, _ s: Int, _ e: Item.Effect = .none, gain: Float = 0) -> Item { Item(fragment: f, slot: s, gainDB: gain, effect: e) }
        func after(_ f: Int, _ gap: Int, min s: Int = 0, _ e: Item.Effect = .none) -> Item { Item(fragment: f, slot: s, after: gap, effect: e) }

        let first = pieces[0], last = pieces[n - 1], second = n > 1 ? pieces[1] : pieces[0]
        let secondHead = halves[second]?[0] ?? second
        func items(_ kind: DialogueCell, _ v: Int) -> [Item] {
            switch kind {
            case .statement:
                // The whole line once, its last words thrown into the echo, the focal piece answering.
                return [at(0, v % 2 == 0 ? 0 : 2), after(y, 2, min: 0, .echoThrow), after(x, 1, min: 20), after(z, 1, min: 26)]
            case .stutter:
                switch v % 3 {
                case 0: return [at(x, 0), after(x, 0), at(y, 10), at(x, 16), after(x, 0), at(z, 24), after(z, 1, min: 28, .filtered)]
                case 1: return [at(x, 0), at(x, 6), at(z, 10), at(x, 16), after(x, 1), after(x, 1, .filtered), at(y, 28)]
                default: return [at(xa, 0), after(xa, 0), after(x, 0), at(y, 10), at(z, 16), after(z, 2, .filtered), at(y, 26)]
                }
            case .splitPause:
                switch v % 3 {
                case 0: return [at(xa, 0), after(xb, 3), at(z, 12), at(sa, 16), after(sb, 3, .echoThrow)]
                case 1: return [at(sa, 0), after(sb, 4), at(x, 12), at(xa, 16), after(xb, 2), at(z, 28)]
                default: return [at(z, 2), at(sa, 8), after(sb, 3), at(sa, 16), after(sa, 1), after(sb, 3), after(x, 1, min: 28)]
                }
            case .reorder:
                // Later words before earlier ones ("...want to invest... when they"), always against the source order.
                switch v % 3 {
                case 0: return [at(secondHead, 0), after(sa, 0), after(first, 3), at(last, 16), at(first, 22), after(second, 1, min: 26)]
                case 1: return [at(last, 0), after(first, 2), at(second, 10), at(second, 16), after(first, 1), at(ya, 28)]
                default: return [at(last, 0), after(sa, 2), at(first, 10), at(second, 16), after(first, 2, .echoThrow)]
                }
            case .callAnswer:
                return v % 2 == 0 ? [at(x, 0), at(y, 10), at(x, 16), at(z, 22), after(y, 1, min: 26)]
                    : [at(z, 2), at(x, 10), at(z, 18), at(y, 26, .echoThrow)]
            case .sparse:
                return v % 2 == 0 ? [at(sa, 4), at(x, 10), at(sb, 20, .echoThrow)] : [at(x, 8), at(z, 16), at(y, 24, .echoThrow)]
            case .returnOpen:
                // The return's first bar carries one short, lower piece late in the bar (the lead's hook
                // opens it); the second bar restates the focal piece.
                let short = ([xa, x, sb, ya] + pieces).min { seconds($0) < seconds($1) } ?? x
                return [at(short, v % 2 == 0 ? 12 : 14, gain: DialogueMotifTuning.returnPieceDB), at(x, 16), after(x, 0), at(z, 22), at(y, 26)]
            case .turnaround:
                var list = [at(x, 0), at(z, 6), at(x, 10)]
                if v % 2 == 1 { list.append(Item(fragment: ya, slot: 16, effect: .reversed)) }
                list += [at(xa, 16), after(xa, 0), after(xa, 0), at(y, 24), Item(fragment: x, slot: 32, landing: true)]
                return list
            case .repair:
                return []
            }
        }
        let r: DialogueCell = reorderAllowed ? .reorder : .callAnswer
        var middle: [DialogueCell] = [.stutter, .splitPause, r, rng.pick([DialogueCell.callAnswer, .stutter, .splitPause].filter { $0 != r })]
        middle.shuffle(using: &rng)
        let breakdown: DialogueCell = rng.chance(DialogueMotifTuning.secondStatementChance) ? .statement : .sparse
        let kinds: [DialogueCell] = [.statement, middle[0], middle[1], middle[2], breakdown, middle[3], .returnOpen, .turnaround]
        var used: [DialogueCell: Set<Int>] = [:]
        var cells: [DialogueMotifCell] = []
        for (k, kind) in kinds.enumerated() {
            let variants = [.stutter, .splitPause, .reorder].contains(kind) ? 3 : 2
            var v = rng.int(0...(variants - 1))
            while used[kind, default: []].contains(v % variants), used[kind, default: []].count < variants { v += 1 }
            v %= variants
            used[kind, default: []].insert(v)
            cells.append(DialogueMotifCell(kind: kind, bar: 2 * k, bars: 2, variant: v, items: items(kind, v)))
        }
        return cells
    }
}

// MARK: - Performance

/// Realises a motif's cells on the drummer's grid for the bars a cue window owns.
nonisolated enum DialogueMotifPerformer {
    struct Placed {
        var fragment: Int
        var cell: DialogueCell
        var sixteenth: Int
        var accent: Double
        var start: Double
        var end: Double
        var gainDB: Float
        var effect: DialogueMotifCell.Item.Effect
        var landing: Bool
        var choked = false
    }

    /// The plan for the motif's bars inside `window`, from `earliestStart` on.
    static func perform(_ motif: DialogueMotif, snapshot: DialogueTransportSnapshot, window: Range<Double>, owned: Range<Double>,
                        earliestStart: Double, memory: inout DialoguePerformanceMemory, seed: UInt64, cueToken: Int,
                        revision: Int) -> DialoguePerformancePlan {
        let loopBeat = DialogueMotif.loopBeat(motif.loop, snapshot: snapshot)
        let loopSixteenth = Int((loopBeat * 4).rounded())
        // A plan ready by its window's start (plus the commit margin) starts with the window; a late
        // plan drops what it missed and begins at the next bar (plan 6.1).
        var hard = max(earliestStart, window.lowerBound)
        if earliestStart > window.lowerBound + DialogueCueCoordinator.commitMargin + 1e-3 {
            let bar = (snapshot.beat(time: earliestStart) / 4 - 1e-9).rounded(.up) * 4
            hard = max(hard, snapshot.time(beat: bar))
        }
        // Nothing starts before the earliest start, nor before the previous plan's last piece ends.
        let floor = max(hard, (memory.lastDryEnd ?? -.infinity) + DialogueTuning.dryGapSeconds)
        // Pieces run to the 8-bar boundary even when the bed ends a little before it (the chop fader
        // stays open after the cue); the turnaround lands on the next loop only when the window reaches it.
        let boundary = snapshot.time(beat: owned.upperBound)
        let upper = min(boundary, window.upperBound + DialogueMotifTuning.tailAfterBedSeconds)
        var placed: [Placed] = []
        var prevEnd = memory.lastDryEnd ?? -.infinity
        func sixteenthSeconds(_ s: Int) -> Double { snapshot.beatLength(at: Double(s) / 4) / 4 }
        func duration(_ f: Int) -> Double { motif.seconds(f) }
        func accentOffset(_ item: DialogueMotifCell.Item) -> Double {
            item.effect == .reversed ? duration(item.fragment) + DialogueMotifTuning.reversedLeadSeconds : motif.accentOffset(item.fragment)
        }
        let lineStatements = memory.motifStatements(loop: motif.loop)
        var statements = lineStatements

        for cell in motif.cells {
            let cellBeat = loopBeat + Double(cell.bar * 4)
            guard owned.contains(cellBeat) else { continue }
            let cellStart = loopSixteenth + cell.bar * 16
            let cellEnd = cellStart + cell.bars * 16
            var firstInCell = true
            for item in cell.items {
                if item.fragment == 0 {
                    guard statements < DialogueMotifTuning.maximumLineStatements else { continue }
                }
                let base = cellStart + item.slot
                let offset = accentOffset(item)
                let length = duration(item.fragment)
                let shift = firstInCell && placed.isEmpty ? DialogueMotifTuning.lateSlotShift : DialogueMotifTuning.slotShift
                let candidates: [Int]
                if let gap = item.after {
                    // The first sixteenth at or after `slot` that leaves `gap` sixteenths after the previous event.
                    let needed = prevEnd + DialogueTuning.dryGapSeconds + Double(gap) * sixteenthSeconds(base)
                    var s = base
                    while s < cellEnd, snapshot.gridTime(sixteenth: s) - offset < needed { s += 1 }
                    candidates = s < cellEnd ? [s] : []
                } else if item.landing {
                    candidates = [base]
                } else {
                    candidates = Array(base...(base + shift)).filter { $0 < cellEnd }
                }
                var done = false
                for s in candidates {
                    let accent = snapshot.gridTime(sixteenth: s)
                    let start = accent - offset
                    let end = start + length
                    guard start >= floor else { continue }
                    if item.landing {
                        // The landing piece sits on the next loop's downbeat only when this window reaches it.
                        guard start < upper, end <= upper + snapshot.beatLength(at: Double(s) / 4), item.slot >= cell.bars * 16 else { continue }
                    } else {
                        guard end <= upper else { continue }
                    }
                    if start < prevEnd + DialogueTuning.dryGapSeconds {
                        // One dry voice: the earlier piece is choked (never the line), else the slot moves on.
                        guard let last = placed.last, last.fragment != 0, last.effect != .reversed,
                              start - DialogueTuning.chokeLeadSeconds - last.start >= DialogueMotifTuning.minimumPieceSeconds else { continue }
                        placed[placed.count - 1].end = start - DialogueTuning.chokeLeadSeconds
                        placed[placed.count - 1].choked = true
                    }
                    placed.append(Placed(fragment: item.fragment, cell: cell.kind, sixteenth: s, accent: accent, start: start, end: end,
                                         gainDB: item.gainDB, effect: item.effect, landing: item.landing))
                    prevEnd = end
                    if item.fragment == 0 { statements += 1 }
                    done = true
                    break
                }
                if done { firstInCell = false }
            }
        }
        placed = repair(placed, motif: motif, snapshot: snapshot, owned: owned, hard: hard, floor: floor, upper: upper)
        let events = finish(placed, motif: motif, snapshot: snapshot, upper: upper)

        // Blocks touching the window, as the grammar logs them; each block is named by its first cell.
        let firstBeat = snapshot.beat(time: window.lowerBound)
        let lastBeat = snapshot.beat(time: window.upperBound)
        let firstBlock = Int((firstBeat / 16 + 1e-9).rounded(.down))
        let lastBlock = max(firstBlock, Int((lastBeat / 16 - 1e-9).rounded(.up)) - 1)
        var blocks: [DialogueBlock] = []
        for k in firstBlock...lastBlock where snapshot.phraseAtOrigin + k >= 0 {
            let phrase = snapshot.phraseAtOrigin + k
            let blockSixteenth = 64 * k
            let own = events.filter { $0.block == phrase }
            let barInLoop = (blockSixteenth - loopSixteenth) / 16
            let cell = motif.cells.first { $0.bar == barInLoop }
            let family = own.isEmpty ? DialogueFamily.rest : (cell.flatMap { DialogueFamily(rawValue: $0.kind.rawValue) } ?? .stutter)
            let elements = own.map { DialogueElement(padKey: $0.padKey, slot: $0.slot) }
            let print = DialoguePerformer.fingerprint(family, elements)
            let change = motif.carried ? "motif:carried" : (barInLoop == 0 ? "motif:new" : "motif")
            let block = DialogueBlock(phrase: phrase, section: LofiScore.section(at: phrase), family: family,
                                      variation: cell?.variant ?? 0, fingerprint: print, events: own, forcedChange: false,
                                      noDialogue: false, change: change)
            blocks.append(block)
            memory.remember(DialogueBlockRecord(phrase: phrase, bankID: motif.bank.bankID, family: family, variation: block.variation,
                                                fingerprint: print, elements: elements,
                                                items: own.map { DialogueItem(padID: $0.padID, slot: $0.slot, gesture: 0) },
                                                occupancy: own.map(\.duration).reduce(0, +), nonNative: 0, events: own.count,
                                                snareLanded: own.contains { $0.snareLanded }, leadKey: nil))
        }
        if let end = events.map(\.endTime).max() { memory.lastDryEnd = max(memory.lastDryEnd ?? -.infinity, end) }
        memory.setMotif(motif, statements: statements)
        memory.lastBankID = motif.bank.bankID
        return DialoguePerformancePlan(sourceID: motif.bank.sourceID, cueToken: cueToken, bankID: motif.bank.bankID,
                                       analysisVersion: motif.bank.analysisVersion, seed: seed, transportRevision: snapshot.revision,
                                       revision: revision, usedTranscript: motif.usedTranscript, blocks: blocks, rejections: [])
    }

    /// Every owned bar that starts at or after the earliest start gets a piece onset (the bar that
    /// contains it gets one when one fits): a short piece on a free sixteenth, choking the earlier
    /// piece (never the line) when that keeps at least 120 ms of it.
    static func repair(_ events: [Placed], motif: DialogueMotif, snapshot: DialogueTransportSnapshot, owned: Range<Double>,
                       hard: Double, floor: Double, upper: Double) -> [Placed] {
        var placed = events.sorted { $0.start < $1.start }
        let loopBeat = DialogueMotif.loopBeat(motif.loop, snapshot: snapshot)
        let candidates = (motif.pieces + motif.halves.keys.sorted().flatMap { motif.halves[$0]! })
            .sorted { (motif.seconds($0), $0) < (motif.seconds($1), $1) }
        var bar = owned.lowerBound
        var rotation = 0
        while bar < owned.upperBound {
            let barStart = snapshot.time(beat: bar), barEnd = snapshot.time(beat: bar + 4)
            defer { bar += 4 }
            guard barEnd > hard, barStart < upper else { continue }
            if placed.contains(where: { $0.start >= barStart && $0.start < barEnd }) { continue }
            let barInLoop = Int(((bar - loopBeat) / 4).rounded())
            let returnBar = barInLoop == 12
            let s0 = Int((bar * 4).rounded())
            var done = false
            // Recurring pieces first, rotating so repairs do not always pick the same cut.
            let order = Array(candidates[(rotation % max(1, candidates.count))...] + candidates[..<(rotation % max(1, candidates.count))])
            rotation += 1
            for slot in DialogueMotifTuning.repairSlots where !done {
                for f in order {
                    let accent = snapshot.gridTime(sixteenth: s0 + slot)
                    let start = accent - motif.accentOffset(f)
                    var end = start + motif.seconds(f)
                    guard start >= barStart, start < barEnd, start >= max(hard, floor) else { continue }
                    let previous = placed.lastIndex { $0.start < start }
                    let next = placed.firstIndex { $0.start >= start }
                    var chokePrevious = false
                    if let p = previous, placed[p].end + DialogueTuning.dryGapSeconds > start {
                        guard placed[p].fragment != 0, placed[p].effect != .reversed,
                              start - DialogueTuning.chokeLeadSeconds - placed[p].start >= DialogueMotifTuning.minimumPieceSeconds else { continue }
                        chokePrevious = true
                    }
                    var chokedSelf = false
                    if let q = next, end + DialogueTuning.dryGapSeconds > placed[q].start {
                        let cut = placed[q].start - DialogueTuning.chokeLeadSeconds
                        guard cut - start >= DialogueMotifTuning.minimumPieceSeconds else { continue }
                        end = cut
                        chokedSelf = true
                    }
                    guard end <= upper else { continue }
                    if chokePrevious, let p = previous {
                        placed[p].end = start - DialogueTuning.chokeLeadSeconds
                        placed[p].choked = true
                    }
                    var e = Placed(fragment: f, cell: .repair, sixteenth: s0 + slot, accent: accent, start: start, end: end,
                                   gainDB: returnBar ? DialogueMotifTuning.returnPieceDB : 0, effect: .none, landing: false)
                    e.choked = chokedSelf
                    placed.insert(e, at: next ?? placed.count)
                    done = true
                    break
                }
            }
        }
        return placed
    }

    /// Events from placed pieces: effect tails inside the following space, blocks and slots.
    static func finish(_ placed: [Placed], motif: DialogueMotif, snapshot: DialogueTransportSnapshot, upper: Double) -> [DialogueEvent] {
        var out: [DialogueEvent] = []
        let lastPhrase = snapshot.phraseAtOrigin + Int((snapshot.beat(time: upper - 1e-6) / 16).rounded(.down))
        for (i, p) in placed.enumerated() {
            let pad = motif.bank.pads[p.fragment]
            let nextStart = i + 1 < placed.count ? placed[i + 1].start : upper + snapshot.beatDuration
            var effect: DialogueChopEffect = .none
            var end = p.end
            switch p.effect {
            case .echoThrow where !p.choked:
                let beat = snapshot.beatLength(at: Double(p.sixteenth) / 4)
                let tail = min(DialogueMotifTuning.echoTailBeats * beat, nextStart - DialogueTuning.dryGapSeconds - p.end,
                               max(0, upper - p.end))
                let delay = DialogueMotifTuning.echoDelayBeats * beat
                if tail >= max(DialogueMotifTuning.minimumEchoTailSeconds, delay + 0.05) {
                    effect = .echoThrow(delay: delay, tail: tail)
                    end = p.end + tail
                }
            case .filtered: effect = .filtered
            case .reversed: effect = .reversed
            default: break
            }
            var phrase = snapshot.phraseAtOrigin + Int((Double(p.sixteenth) / 64).rounded(.down))
            // The landing on the next loop's downbeat is logged with the turnaround's block.
            if p.landing { phrase = min(phrase, lastPhrase) }
            let slot = p.sixteenth - 64 * (phrase - snapshot.phraseAtOrigin)
            let choke = p.choked && i + 1 < placed.count ? placed[i + 1].start : nil
            var event = DialogueEvent(padID: pad.padID, role: pad.role, block: phrase, slot: slot, accentTime: p.accent,
                                      startTime: p.start, duration: end - p.start,
                                      gainDB: DialogueTuning.roleTrimDB(pad.role) + p.gainDB, protected: pad.protected,
                                      chokeAt: choke, text: pad.text, transform: .native, padKey: pad.padKey,
                                      snareLanded: [4, 12].contains(((p.sixteenth % 16) + 16) % 16))
            event.cell = p.cell
            event.piece = p.fragment
            event.effect = effect
            out.append(event)
        }
        return out
    }
}

nonisolated extension DialoguePerformanceMemory {
    /// Full-line statements already played in `loop`.
    func motifStatements(loop: Int) -> Int { motif?.loop == loop ? motifLineStatements : 0 }

    mutating func setMotif(_ motif: DialogueMotif, statements: Int) {
        if self.motif?.loop != motif.loop || self.motif?.lineKey != motif.lineKey {
            motifLines.append(DialogueMotifLineUse(key: motif.lineKey, loop: motif.loop, contentID: motif.source.contentID,
                                                   frames: motif.line.frames))
            if motifLines.count > DialogueMotifTuning.lineHistory { motifLines.removeFirst(motifLines.count - DialogueMotifTuning.lineHistory) }
        }
        self.motif = motif
        motifLineStatements = statements
    }
}

// MARK: - Entry point

/// A motif plan for one cue window: one part per 8-bar section (a window that crosses a loop
/// boundary plays each loop's own motif), merged into one plan for logs and posting.
nonisolated struct DialogueMotifPlan: @unchecked Sendable {
    let plan: DialoguePerformancePlan
    let parts: [(plan: DialoguePerformancePlan, motif: DialogueMotif)]
    var motif: DialogueMotif { parts[parts.count - 1].motif }
    var motifs: [DialogueMotif] { parts.map(\.motif) }

    /// Chops of every part, each rendered from its own motif's source.
    func render() -> [DialogueChop] {
        parts.flatMap { DialogueEngine.render($0.plan, bank: $0.motif.bank, source: $0.motif.source, analysis: $0.motif.analysis) }
            .sorted { $0.event.startTime < $1.event.startTime }
    }

    var log: [String: Any] {
        var result = DialogueEngine.log(plan, bank: motif.bank, motif: motif)
        if parts.count > 1 { result["motifs"] = parts.map { $0.motif.log() } }
        return result
    }
}

nonisolated extension DialogueMotif {
    /// The 8-bar sections a window owns: from the fill boundary at or before its start (within the
    /// two-beat lead-in) to the boundary at or after its end.
    static func sections(_ window: Range<Double>, snapshot: DialogueTransportSnapshot) -> [Range<Double>] {
        let first = ownedBeats(window, snapshot: snapshot).lowerBound
        let end = snapshot.beat(time: window.upperBound)
        var out: [Range<Double>] = []
        var b = first
        repeat {
            out.append(b..<(b + 32))
            b += 32
        } while b < end - 1e-9
        return out
    }

    /// Motif plan for a cue: nil when no motif exists (the grammar's fallback order then applies).
    static func plan(source: DialogueSource, analysis: DialogueAnalysis, bank: DialoguePadBank?, transcript: DialogueTranscript?,
                     snapshot: DialogueTransportSnapshot, window: Range<Double>, earliestStart: Double,
                     memory: inout DialoguePerformanceMemory, seed: UInt64, cueToken: Int, revision: Int) -> DialogueMotifPlan? {
        guard window.upperBound > window.lowerBound else { return nil }
        var trial = memory
        var parts: [(plan: DialoguePerformancePlan, motif: DialogueMotif)] = []
        for section in sections(window, snapshot: snapshot) {
            let lower = max(window.lowerBound, snapshot.time(beat: section.lowerBound))
            let upper = min(window.upperBound, snapshot.time(beat: section.upperBound))
            guard upper > lower else { continue }
            let loop = loopIndex(beat: section.lowerBound, snapshot: snapshot)
            guard let motif = resolve(loop: loop, source: source, analysis: analysis, hasBank: bank != nil, transcript: transcript,
                                      memory: trial, seed: seed, beatDuration: snapshot.beatLength(at: section.lowerBound))
            else { return nil }
            if trial.cycleSeed == nil { trial.cycleSeed = seed }
            let part = DialogueMotifPerformer.perform(motif, snapshot: snapshot, window: lower..<upper, owned: section,
                                                      earliestStart: earliestStart, memory: &trial, seed: seed,
                                                      cueToken: cueToken, revision: revision)
            parts.append((part, motif))
        }
        guard let last = parts.last else { return nil }
        trial.pieceCounter += 1
        memory = trial
        let merged = DialoguePerformancePlan(sourceID: last.plan.sourceID, cueToken: cueToken, bankID: last.plan.bankID,
                                             analysisVersion: last.plan.analysisVersion, seed: seed,
                                             transportRevision: snapshot.revision, revision: revision,
                                             usedTranscript: last.plan.usedTranscript, blocks: parts.flatMap(\.plan.blocks),
                                             rejections: [])
        return DialogueMotifPlan(plan: merged, parts: parts)
    }
}
