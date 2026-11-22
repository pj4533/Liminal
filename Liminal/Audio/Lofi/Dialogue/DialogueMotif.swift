import AVFoundation
import Foundation

// MPC motif chopping (docs/plans/mpc-chopping.md, section 5; user direction of 19 November 2026).
// One line per 16-bar loop is the motif. It is split into word and syllable pieces, and the pieces
// are sequenced on the drummer's sixteenth grid in 2-bar cells around one repeating hook cell (D125:
// the line's strongest word on fixed home steps, answered by a second piece), with variation only at
// the phrase ends, the drop-out and the return, so that every bar of the loop has a piece onset and
// the loop sounds like a hook rather than a shuffle. Pure and seeded; nothing here touches audio threads.

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
    /// A line leads one loop per session. Across sessions `DialogueLineLedger` keeps every played
    /// line, so a line only returns once the cue's film and the recent films have no unplayed line
    /// left (D123; before, two uses and an 8-line history let each film's best line return within minutes).
    static let lineUses = 1
    static let lineHistory = 512
    /// The motif picks among this many of the best unplayed lines (seeded), so a film's lines are
    /// explored rather than always its top-ranked one.
    static let linePool = 3
    /// Line interest (D124, `DialogueLineInterest`): a line's value is scaled by
    /// `interestFloor + (1 - interestFloor) * interest`, so a clear plain line still roughly ties a
    /// murky striking one.
    static let interestFloor: Float = 0.35
    /// Lines below this are plain: the own film's plain lines wait until the crate's striking ones are played.
    static let plainInterest: Float = 0.30
    /// A crate line at least this interesting beats the own film's plain or unknown lines.
    static let strikingInterest: Float = 0.60
    /// The interest of a line without text (no transcript): above `plainInterest`, so the acoustic
    /// choice is unchanged.
    static let acousticInterest: Float = 0.45
    /// The seeded pool holds only lines worth at least this share of the best unplayed line.
    static let linePoolShare: Float = 0.85
    /// Recent films the motif may dig a fresh line from when a loop's own film has none
    /// (19 November 2026: a narration-over-music film gave no line and one line held 32 bars).
    static let crateSize = 4
    /// The return's first bar: one short piece this much lower, so the lead's hook stays clear.
    static let returnPieceDB: Float = -3
    /// A worded return piece is at most this long (else the shortest piece plays).
    static let returnPieceSeconds = 0.35
    /// Echo throw: repeats every 0.75 beat at these levels, band-limited, inside the following space.
    static let echoDelayBeats = 0.75
    /// Five repeats (three at -6/-10/-15 dB, two before that; user direction of 19 November 2026:
    /// "echo more, more repeats").
    static let echoGainsDB: [Float] = [-3, -6, -9, -13, -17]
    static let echoTailBeats = 3.5
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
    /// Hook templates (D125): (role, step) in the 2-bar hook cell, bar B = steps 16 to 31. Roles are
    /// `s` the signature (the line's strongest word), `r` the response and `t` a third piece. One
    /// template holds for `hookLoops` loops (the words change every loop, the trigger rhythm with
    /// them less often), then the next one in a seeded rotation. Every template answers on the
    /// backbeat: the response sounds on a snare step (4, 12, 20 or 28) at least once per cell, the
    /// boom-bap call and response (docs/research/dialogue-chopping/craft.md section 4, "reserve one
    /// anchor to land on the snare"; verification pass of 21 November 2026).
    enum HookRole: String, Sendable { case s, r, t }
    static let hookTemplates: [[(HookRole, Int)]] = [
        // Push: the signature twice, answered on the backbeat. On 8ths since D126 part 2 (the D125
        // dotted push on steps 3 and 19 put a third of the chop beat's stabs on off-sixteenths).
        [(.s, 0), (.s, 6), (.r, 12), (.s, 16), (.t, 22), (.r, 28)],
        // Offbeat: the call on the "and", the answer on the fourth beat.
        [(.s, 2), (.r, 8), (.s, 18), (.t, 24), (.r, 28)],
        // Snare answer.
        [(.s, 0), (.r, 4), (.t, 12), (.s, 16), (.r, 20), (.s, 24)],
        // Late.
        [(.s, 6), (.r, 10), (.s, 22), (.t, 26), (.r, 28)],
    ]
    static let hookLoops = 2
    /// Echo tails end this long before the section's end.
    static let sectionTailLead = 0.3
    /// A section's pieces may start this long before its first downbeat when the cue window allows
    /// it (a piece's start sits its accent offset before the step it lands on).
    static let sectionPreRollSeconds = 0.28
    /// No piece starts this soon after its cue's window opens (the bed's start): the voice queues a
    /// cue's chops on its 0.1 s tick once the bed has begun, and drops any already past.
    static let bedStartLeadSeconds = 0.2
    /// The signature prefers a piece of this length (a word, not a syllable nor a clause).
    static let signatureSeconds: ClosedRange<Double> = 0.18...0.75
    /// The response is the next-strongest piece when its word weight is above this, else the line's ending.
    static let responseWeight: Float = 0.25
    /// Dry seconds of one 8-bar section stay under this share of it: a piece that would pass it is
    /// left out (coverage repair still fills an empty bar). A long line's long pieces at a slow tempo
    /// otherwise crowd the loop past the C-D9 band (D124: interest-ranked lines are longer on average).
    static let maximumSectionOccupancy = 0.56
    /// Dry pieces plus echo tails of one section stay under this share: echo tails are shortened
    /// (or left out below `minimumEchoTailSeconds`) once the section reaches it.
    static let maximumSectionOccupancyWithEcho = 0.60
    /// A gated hit ends this long before the step its gate reaches (D126), so a stutter's repeats
    /// never touch and the next trigger starts clean.
    static let gateLeadSeconds = 0.006
    /// A gate closes at a cut point (syllable valley or word end) this close before its step instead.
    static let valleySnapSeconds = 0.035
    /// A gated hit keeps at least this much after its attack.
    static let minimumGateSeconds = 0.060
    /// The gated release: a raised cosine of at most this length (a quarter of the gate when shorter).
    static let gateReleaseSeconds = 0.008
    /// The gate of a repaired bar's hit, in sixteenths.
    static let repairGate = 2
    /// A transcribed piece's start may sit this far into its first word (its consonant's ramp) before
    /// its weak first syllable becomes the beat.
    static let wordStartSlackSeconds = 0.040
    /// The first syllable of such a piece is the first peak within 12 dB of the loudest.
    static let weakLeadPeakShare: Float = 0.25
    /// A rendered pad's accent replaces the source one only within this many seconds of it.
    static let renderedAccentRange: ClosedRange<Double> = -0.050...0.020
    /// The line's statement tries these sixteenths after its slot, never an off-sixteenth (D126 part 2:
    /// the intro states the whole line on the downbeat so the listener understands it).
    static let lineSteps = [0, 4, 8, 16]
    /// Onsets per bar of the chop beat's groove cell (plan D126 section 3D: 5 to 7).
    static let grooveHits = 6
    /// A groove bar has at most this many onsets on consecutive sixteenths, and a beat without one.
    static let grooveRun = 3
    /// A groove cell has at most this many fill stabs on odd sixteenths (D127: the swung pickup into a
    /// downbeat and one ghost-note pocket; the chop beat stays on 8ths otherwise).
    static let grooveOffEighths = 2
    /// A groove bar whose drummer plays on at least this many of its sixteenths takes one stab less.
    static let busyBarSteps = 13
    /// The seeded spread of the fill sites' scores (D127): two loops on one template fill different steps.
    static let grooveJitter = 1.2
    /// The largest feel offset (`DialogueFeel`), inside the 25 ms a step may sit off the drummer's grid.
    static let maximumFeelSeconds = 0.025
    /// A ghost note: a snare at most this strong against the take's typical snare (`LofiDrumLandmark.strength`).
    static let ghostStrength: Float = 0.45
    /// Ghost notes count from this confidence (soft hits classify less clearly).
    static let ghostConfidence: Float = 0.25
    /// Variants per section of the 16-bar arc (intro, build, breakdown, outro; the groove is the hook template).
    static let arcVariants = 3
    /// Consecutive loops' arcs differ in at least this many of their five fields (C-D12).
    static let arcChange = 2
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
    var frames: Range<Int>
    /// Source frame of the first syllable's attack (`DialogueAttack.beatFrame`): the frame that
    /// lands on the slot. `frames` start at the waveform onset (D126), at most 30 ms before it for a
    /// piece and 120 ms for the line.
    var accentFrame: Int
    var fadeIn: Int
    let fadeOut: Int
    var text: String?
    /// The highest word weight inside the fragment (`DialogueLineInterest.wordWeights`); 0 for acoustic cuts.
    var weight: Float = 0
    /// A plosive or glottal attack (`DialogueOnset`): the pad starts on its burst.
    var hardOnset = false
    /// The first syllable is the beat even when it is up to 12 dB under the next one (a transcribed
    /// piece whose first word starts weakly: "re-MEM-ber" plays from "re", never "-member").
    var weakLead = false
    /// Source frames inside the fragment where a gate may close cleanly: the valleys between its
    /// syllables and its word ends (D126).
    var cutPoints: [Int] = []
}

/// A line that led a loop.
nonisolated struct DialogueMotifLineUse: Sendable, Equatable {
    let key: UInt64
    let loop: Int
    let contentID: String
    let frames: Range<Int>
    /// The line in film seconds (the ledger's key).
    var seconds: Range<Double> = 0..<0
    /// The line's words, lowercased, when it had a transcript: a film that says the same sentence
    /// twice offers it once per session (D124).
    var text: String? = nil
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
        /// A hook item: exactly on its step (no slot shift), or not at all, so every repeat of the
        /// hook is the same trigger pattern (D125).
        var fixed = false
        /// How long the pad is held, in sixteenths (D126, an MPC pad in note-on mode): the piece is
        /// cut `gateLeadSeconds` before the step `gate` steps after its own, or at a syllable valley
        /// just before that. nil plays the piece to its natural end (a one-shot).
        var gate: Int? = nil
        /// Exactly this many sixteenths after the previous placed hit (a stutter on consecutive
        /// sixteenths, which chokes the hit before it).
        var follow: Int? = nil
        /// With `after`: only 8th positions (the outro's restatement walks the line on the 8ths).
        var onEighths = false
        /// A hook template hit (D127): the groove's fixed skeleton, which holds for `hookLoops` loops.
        var skeleton = false
        /// A deliberate repeat of the hit before it (a roll in the build, a turnaround stutter): the only
        /// same-piece repeats the chop beat and build play (D127).
        var stutter = false
    }
    let kind: DialogueCell
    let bar: Int
    let bars: Int
    let variant: Int
    let items: [Item]
}

/// The loop's hook (D125): the template, the role pieces and the 2-bar cell they make.
nonisolated struct DialogueMotifHook: Sendable, Equatable {
    let template: Int
    /// Fragment ids of the signature, the response and the third piece.
    let signature: Int
    let response: Int
    let third: Int
    /// The hook cell's items (slots 0 to 31).
    let items: [DialogueMotifCell.Item]
}

/// The 16-bar arc of one loop (D126 part 2; user direction of 21 November 2026: "introduce the
/// sample in its entirety and then start messing with it ... build up, breakdown, outro ... never the
/// same twice"). Each field picks a section's variant; `groove` is the hook template the chop beat is built on.
nonisolated struct DialogueArc: Sendable, Equatable {
    var intro: Int
    var groove: Int
    var build: Int
    var breakdown: Int
    var outro: Int
    /// The chop beat's and build's microtiming feel (D127), an index into `DialogueFeel.variants`.
    var feel: Int = 0

    func differences(_ o: DialogueArc) -> Int {
        [intro != o.intro, groove != o.groove, build != o.build, breakdown != o.breakdown, outro != o.outro, feel != o.feel]
            .filter { $0 }.count
    }

    var name: String { "I\(intro) G\(groove) B\(build) K\(breakdown) O\(outro) F\(feel)" }
}

/// The take's modal kick, snare and ghost-note steps over a 2-bar cell (0...31): the steps a hit
/// of that class lands on in at least half of the take's 2-bar pairs. The chop beat's stabs play off
/// them (D127): in the gaps between kicks, answering the snare and in the ghost notes' pockets.
nonisolated struct DialogueMotifDrums: Sendable, Equatable {
    var kicks: [Int]
    /// Full snares (the backbeat and other accented snares).
    var snares: [Int]
    /// Soft snares (`DialogueMotifTuning.ghostStrength`) on steps without a kick or full snare.
    var ghosts: [Int] = []

    /// A boom-bap pattern for plans without landmarks.
    static let boomBap = DialogueMotifDrums(kicks: [0, 10, 16, 26], snares: [4, 12, 20, 28])

    init(kicks: [Int], snares: [Int], ghosts: [Int] = []) { self.kicks = kicks; self.snares = snares; self.ghosts = ghosts }

    init(snapshot: DialogueTransportSnapshot) {
        func modal(_ marks: [DialogueLandmark], _ keep: (DialogueLandmark) -> Bool) -> [Int] {
            var counts = [Int](repeating: 0, count: 32)
            for m in marks where keep(m) {
                let step = Int((m.beat * 4).rounded())
                counts[((step % 32) + 32) % 32] += 1
            }
            let pairs = max(1, Int(DialogueTransportSnapshot.takeBeats / 8))
            return (0..<32).filter { counts[$0] * 2 >= pairs }
        }
        let confident = DialogueTuning.landmarkConfidence
        // Before D127 every confident snare counted, so a take's ghost notes read as snare steps and the
        // response stabbed on them.
        let snares = modal(snapshot.snares) { $0.confidence >= confident && $0.strength > DialogueMotifTuning.ghostStrength }
        let kicks = modal(snapshot.kicks) { $0.confidence >= confident }.filter { !snares.contains($0) }
        let ghosts = modal(snapshot.snares) { $0.confidence >= DialogueMotifTuning.ghostConfidence && $0.strength <= DialogueMotifTuning.ghostStrength }
            .filter { !snares.contains($0) && !kicks.contains($0) }
        self = kicks.isEmpty && snares.isEmpty ? .boomBap : DialogueMotifDrums(kicks: kicks, snares: snares, ghosts: ghosts)
    }
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
    /// The line's interest (`DialogueLineInterest`), `acousticInterest` without text.
    var interest: Float = DialogueMotifTuning.acousticInterest
    /// The repeating hook cell; nil only for motifs built before D125.
    var hook: DialogueMotifHook? = nil
    /// Each fragment rendered once at full length and 0 dB (D126): every hit of the loop, at any gate,
    /// is a prefix of its pad's render, so a stab and the word it was cut from share one level and
    /// the renderer runs the chain once per pad rather than once per gate length.
    var renders: [Int: AVAudioPCMBuffer] = [:]
    /// The loop's arc, and the previous loop's (which a fresh line in the same loop must also avoid).
    var arc: DialogueArc? = nil
    var priorArc: DialogueArc? = nil

    var line: DialogueMotifFragment { fragments[0] }
    /// The chop beat's and build's feel (D127; the grid's own swing for motifs without an arc).
    var feel: DialogueFeel { DialogueFeel.variants[min(max(0, arc?.feel ?? 0), DialogueFeel.variants.count - 1)] }
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
                        beatDuration: Double, drums: DialogueMotifDrums = .boomBap) -> DialogueMotif? {
        if let current = memory.motif, current.loop == loop {
            if let transcript, !current.usedTranscript, current.source.contentID == source.contentID,
               current.source.sourceStart == source.sourceStart,
               let recut = make(loop: loop, source: source, analysis: analysis, transcript: transcript, memory: memory,
                                seed: current.seed, beatDuration: beatDuration, line: current.lineUnit, recutOf: current, drums: drums) {
                return recut
            }
            // A loop that only carried the previous line takes a fresh line from a later cue in the
            // same loop, so one film with no usable line cannot hold one line across two loops.
            if current.carried, current.source.contentID != source.contentID,
               let fresh = make(loop: loop, source: source, analysis: analysis, transcript: transcript, memory: memory,
                                seed: seed, beatDuration: beatDuration, drums: drums) {
                return fresh
            }
            return current
        }
        // A new loop (D124). The ledger blocks every played line at every step (D123); the tiers only
        // order the unplayed ones: the own film's lines that are not plain, a striking transcribed
        // line from the crate, any own line, any crate line. A cue with no transcript yet tries the
        // crate's striking lines first: a known striking line beats an unknown one. Without any
        // transcript every line is `acousticInterest`, so the order is the acoustic one of before.
        func own(_ minimum: Float) -> DialogueMotif? {
            make(loop: loop, source: source, analysis: analysis, transcript: transcript, memory: memory, seed: seed,
                 beatDuration: beatDuration, minimumInterest: minimum, drums: drums)
        }
        func striking() -> DialogueMotif? {
            fromCrate(loop: loop, excluding: source.contentID, memory: memory, seed: seed, beatDuration: beatDuration,
                      minimumInterest: DialogueMotifTuning.strikingInterest, transcribedOnly: true, drums: drums)
        }
        if transcript == nil, let dug = striking() { return dug }
        if let fresh = own(DialogueMotifTuning.plainInterest) { return fresh }
        if transcript != nil, let dug = striking() { return dug }
        // The motif ranks its own lines, so a cue whose pad bank is empty can still offer one.
        if let fresh = own(0) { return fresh }
        // This film has no usable line (music under the narration, say): dig a fresh line from the
        // crate of recent films, newest first, before ever repeating the last loop's line.
        if let dug = fromCrate(loop: loop, excluding: source.contentID, memory: memory, seed: seed, beatDuration: beatDuration, drums: drums) {
            return dug
        }
        // Every line of this film and the crate has been played (after many hours): reuse the line
        // played longest ago rather than carrying the last loop's line.
        if let recycled = make(loop: loop, source: source, analysis: analysis, transcript: transcript, memory: memory,
                               seed: seed, beatDuration: beatDuration, recycle: true, drums: drums) {
            return recycled
        }
        if let previous = memory.motif { return previous.carried(to: loop, seed: seed, memory: memory, drums: drums) }
        return nil
    }

    /// A fresh line from the crate of recent films (newest first), never this cue's own film.
    static func fromCrate(loop: Int, excluding contentID: String, memory: DialoguePerformanceMemory, seed: UInt64,
                          beatDuration: Double, minimumInterest: Float = 0, transcribedOnly: Bool = false,
                          drums: DialogueMotifDrums = .boomBap) -> DialogueMotif? {
        for entry in memory.motifCrate.reversed() where entry.source.contentID != contentID {
            if transcribedOnly, entry.transcript == nil { continue }
            if let dug = make(loop: loop, source: entry.source, analysis: entry.analysis, transcript: entry.transcript,
                              memory: memory, seed: seed, beatDuration: beatDuration, minimumInterest: minimumInterest,
                              transcribedOnly: transcribedOnly, drums: drums) {
                return dug
            }
        }
        return nil
    }

    /// The same line and pieces, arranged for another loop on another hook template.
    func carried(to loop: Int, seed: UInt64, memory: DialoguePerformanceMemory, drums: DialogueMotifDrums = .boomBap) -> DialogueMotif {
        let loopSeed = seed ^ UInt64(bitPattern: Int64(loop)) &* 0x9E37_79B9
        // The same line again: the groove changes (the template) and two more sections, so 16 bars
        // never repeat exactly (C-D1, C-D12).
        let arranged = Self.arrange(fragments: fragments, pieces: pieces, halves: halves, reorderAllowed: reorderAllowed,
                                    seed: loopSeed, lineSeconds: seconds(0), sampleRate: sampleRate,
                                    hookSeed: memory.cycleSeed ?? seed, loop: loop, avoidTemplate: hook?.template,
                                    drums: drums, avoidArc: arc, carried: true)
        return DialogueMotif(loop: loop, source: source, analysis: analysis, lineUnit: lineUnit, lineKey: lineKey,
                             fragments: fragments, pieces: pieces, halves: halves, bank: bank, usedTranscript: usedTranscript,
                             reorderAllowed: reorderAllowed, cells: arranged.cells, carried: true, seed: loopSeed, interest: interest,
                             hook: arranged.hook, renders: renders, arc: arranged.arc, priorArc: arc)
    }

    /// Chooses the best line (or `line` when given), cuts it into pieces and arranges the loop.
    static func make(loop: Int, source: DialogueSource, analysis: DialogueAnalysis, transcript: DialogueTranscript?,
                     memory: DialoguePerformanceMemory, seed: UInt64, beatDuration: Double, line wanted: Int? = nil,
                     recycle: Bool = false, minimumInterest: Float = 0, transcribedOnly: Bool = false,
                     recutOf previous: DialogueMotif? = nil, drums: DialogueMotifDrums = .boomBap) -> DialogueMotif? {
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
        let weights = DialogueLineInterest.wordWeights(words)
        let line: SpeechUnit
        if let wanted, let unit = units.first(where: { $0.id == wanted }) {
            line = unit
        } else {
            let ranked = rankLines(units: units, rejections: rejections, rate: rate, maximum: maximum, words: words, weights: weights)
                .filter { $0.interest >= minimumInterest && (!transcribedOnly || $0.unit.text != nil) }
            let used = memory.motifLines
            func filmSeconds(_ u: SpeechUnit) -> Range<Double> {
                source.sourceSeconds(frame: u.frames.lowerBound)..<source.sourceSeconds(frame: u.frames.upperBound)
            }
            func blockedThisSession(_ u: SpeechUnit) -> Bool {
                let key = lineKey(analysis.contentID, u.frames)
                if used.filter({ $0.key == key }).count >= DialogueMotifTuning.lineUses { return true }
                // Never the previous loop's line, nor a line overlapping it by more than half.
                return used.contains { use in
                    use.loop == loop - 1 && use.contentID == analysis.contentID
                        && overlapShare(use.frames, u.frames) > 0.5
                }
            }
            let open = ranked.filter { !blockedThisSession($0.unit) }
            let pick: SpeechUnit?
            if recycle {
                // Every line here has been played: go back to the one played longest ago.
                pick = open.min { a, b in
                    (memory.ledger.lastPlay(contentID: analysis.contentID, seconds: filmSeconds(a.unit))?.last ?? 0)
                        < (memory.ledger.lastPlay(contentID: analysis.contentID, seconds: filmSeconds(b.unit))?.last ?? 0)
                }?.unit
            } else {
                // Words this session already led with from this film: the same sentence said again, or
                // a phrase inside one ("this is mother." after "Sally, this is mother."), waits too.
                let said = used.filter { $0.contentID == analysis.contentID }.compactMap(\.text).map { " \($0) " }
                func alreadySaid(_ u: SpeechUnit) -> Bool {
                    guard let text = u.text else { return false }
                    let words = " \(Self.spokenText(text)) "
                    return said.contains { $0.contains(words) || words.contains($0) }
                }
                let fresh = open.filter {
                    memory.ledger.lastPlay(contentID: analysis.contentID, seconds: filmSeconds($0.unit)) == nil && !alreadySaid($0.unit)
                }
                // The seeded pool holds the best unplayed lines worth at least `linePoolShare` of the
                // leader, so a striking line is not a coin flip against a plain one (D124).
                let leader = fresh.first?.value ?? 0
                let pool = Array(fresh.prefix(DialogueMotifTuning.linePool).filter { $0.value >= DialogueMotifTuning.linePoolShare * leader })
                var rng = MusicRNG(seed: seed ^ (UInt64(bitPattern: Int64(loop)) &* 0xD6E8_FEB8_6659_FD93))
                pick = pool.isEmpty ? nil : pool[rng.int(0...(pool.count - 1))].unit
            }
            guard let pick else { return nil }
            line = pick
        }
        let count = min(source.frameCount, f.frameCount)
        guard line.frames.lowerBound >= 0, line.frames.upperBound <= count else { return nil }
        let lineIndices = words.indices.filter { line.frames.contains((words[$0].frames.lowerBound + words[$0].frames.upperBound) / 2) }
        let lineWords = lineIndices.map { words[$0] }
        var cutter = Cutter(f: f, samples: samples, count: count, rate: rate)
        guard let cut = cutter.cut(line, words: lineWords) else { return nil }
        // Fragment weights: the strongest word inside each cut (the hook layer's signature piece).
        var fragments = cut.fragments
        if !lineIndices.isEmpty {
            for k in fragments.indices {
                let frames = fragments[k].frames
                fragments[k].weight = lineIndices.filter { frames.contains((words[$0].frames.lowerBound + words[$0].frames.upperBound) / 2) }
                    .map { weights[$0] }.max() ?? 0
            }
        }
        let lineInterest = interest(of: line, words: words, weights: weights)
        let reorderAllowed = lineWords.count < 2 || DialogueReorderGuard.allowsPieceReorder(lineWords.map(\.text))
        // A re-cut keeps the loop's seeded choices (the breakdown cell).
        let loopSeed = previous?.seed ?? (seed ^ UInt64(bitPattern: Int64(loop)) &* 0x9E37_79B9)
        // A transcript re-cut keeps the hook: the new signature and response are the pieces that
        // overlap the old ones most.
        let anchors = previous?.hook.map { [previous!.fragments[$0.signature].frames, previous!.fragments[$0.response].frames] } ?? []
        // A re-cut keeps the arc; a new line avoids the previous loop's arc (or, replacing a carried
        // line inside its loop, the arc that one avoided).
        let prior = previous?.priorArc ?? memory.motif.flatMap { $0.loop == loop ? $0.priorArc : $0.arc }
        let arranged = arrange(fragments: fragments, pieces: cut.pieces, halves: cut.halves, reorderAllowed: reorderAllowed,
                               seed: loopSeed, lineSeconds: Double(line.frames.count) / rate, sampleRate: rate,
                               hookSeed: memory.cycleSeed ?? seed, loop: loop, anchors: anchors, drums: drums,
                               keepArc: previous?.arc, avoidArc: prior)
        // The arranged pieces (and the line) take their accents from their renders; a piece only coverage
        // repair may pick keeps its source accent and renders when played.
        let used = Set(arranged.cells.flatMap { $0.items.map(\.fragment) } + [0])
        let rendered = renderedAccents(fragments, line: line, source: source, analysis: analysis, only: used)
        fragments = rendered.fragments
        let key = lineKey(analysis.contentID, line.frames)
        let bank = motifBank(fragments, line: line, analysis: analysis, key: key, usedTranscript: lineWords.count >= 2)
        return DialogueMotif(loop: loop, source: source, analysis: analysis, lineUnit: line.id, lineKey: key,
                             fragments: fragments, pieces: cut.pieces, halves: cut.halves, bank: bank,
                             usedTranscript: lineWords.count >= 2, reorderAllowed: reorderAllowed, cells: arranged.cells,
                             carried: false, seed: loopSeed, interest: lineInterest, hook: arranged.hook, renders: rendered.renders,
                             arc: arranged.arc, priorArc: prior)
    }

    /// A line's words for the said-once rule: lowercased letters, digits and spaces.
    static func spokenText(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    /// A line's interest: from its words when it has text, else `acousticInterest`.
    static func interest(of u: SpeechUnit, words: [DialogueWordSpan], weights: [Float]) -> Float {
        guard u.text != nil, let r = u.tokenRange, r.lowerBound >= 0, r.upperBound <= words.count, weights.count == words.count,
              !r.isEmpty else { return DialogueMotifTuning.acousticInterest }
        return DialogueLineInterest.interest(words: words[r], weights: weights[r], text: u.text)
    }

    /// A candidate line with its value (sound, fit, length, transcript bonus and interest) and interest.
    struct RankedLine {
        let unit: SpeechUnit
        let value: Float
        let interest: Float
    }

    /// Whole lines in rank order: sound times line fit, transcribed lines first among equals.
    static func rankedLines(units: [SpeechUnit], rejections: [DialogueRejection], rate: Double, maximum: Double,
                            words: [DialogueWordSpan] = []) -> [SpeechUnit] {
        rankLines(units: units, rejections: rejections, rate: rate, maximum: maximum, words: words,
                  weights: DialogueLineInterest.wordWeights(words)).map(\.unit)
    }

    /// Whole lines in rank order with their values: sound times line fit times interest, transcribed
    /// lines first among equals. `weights` are `DialogueLineInterest.wordWeights(words)`.
    static func rankLines(units: [SpeechUnit], rejections: [DialogueRejection], rate: Double, maximum: Double,
                          words: [DialogueWordSpan], weights: [Float]) -> [RankedLine] {
        let rejected = Dictionary(rejections.map { ($0.unit, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let lines = units.filter {
            [.utterance, .phrase, .wordGroup].contains($0.level) && rejected[$0.id] == nil
                && $0.score.sound >= DialogueTuning.minimumPadSound && $0.nuclei >= DialogueMotifTuning.lineMinimumNuclei
        }
        var interests: [Int: Float] = [:]
        for u in lines { interests[u.id] = interest(of: u, words: words, weights: weights) }
        func value(_ u: SpeechUnit) -> Float {
            let interest = interests[u.id] ?? DialogueMotifTuning.acousticInterest
            let d = u.seconds(rate)
            let length = d <= DialogueMotifTuning.preferredLineSeconds ? 1
                : max(0.8, 1 - 0.2 * Float((d - DialogueMotifTuning.preferredLineSeconds) / (DialogueMotifTuning.lineSeconds.upperBound - DialogueMotifTuning.preferredLineSeconds)))
            return u.score.sound * DialogueBankBuilder.lineFit(u, units: units, rejected: rejected) * length
                * (u.text != nil ? DialogueMotifTuning.transcribedLineBonus : 1)
                * (DialogueMotifTuning.interestFloor + (1 - DialogueMotifTuning.interestFloor) * interest)
        }
        func within(_ r: ClosedRange<Double>) -> [RankedLine] {
            lines.filter { r.contains($0.seconds(rate)) && $0.seconds(rate) <= maximum }
                .map { RankedLine(unit: $0, value: value($0), interest: interests[$0.id] ?? DialogueMotifTuning.acousticInterest) }
                .sorted { ($0.value, -$0.unit.id) > ($1.value, -$1.unit.id) }
        }
        let preferred = within(DialogueMotifTuning.lineSeconds)
        let relaxed = within(DialogueMotifTuning.relaxedLineSeconds).filter { u in !preferred.contains { $0.unit.id == u.unit.id } }
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
        let pads = fragments.map { pad($0, line: line, analysis: analysis) }
        var hash = DialogueHash()
        hash.add(key)
        hash.add(analysis.version)
        for fr in fragments { hash.add(fr.frames.lowerBound); hash.add(fr.frames.upperBound) }
        let ids = [line.id]
        return DialoguePadBank(bankID: hash.value, analysisVersion: analysis.version, pads: pads, anchorPadID: 0, siblingGroups: [],
                               sourceID: analysis.contentID, clock: analysis.clock, rejections: [], usedTranscript: usedTranscript,
                               reorder: .sourceOrder, originalOrder: ids, arrangedOrder: ids, intendedText: line.text)
    }

    /// One fragment as a motif-bank pad.
    static func pad(_ fr: DialogueMotifFragment, line: SpeechUnit, analysis: DialogueAnalysis) -> DialoguePad {
        let rate = analysis.sampleRate
        let role: DialoguePad.Role = fr.kind == .line ? .anchor : .stab
        return DialoguePad(padID: fr.id, unitID: fr.kind == .line ? line.id : -1 - fr.id, role: role, frames: fr.frames,
                           transform: .native, accentOffset: Double(fr.accentFrame - fr.frames.lowerBound) / rate,
                           duration: Double(fr.frames.count) / rate, protected: fr.kind == .line, text: fr.text,
                           fadeIn: fr.fadeIn, fadeOut: fr.fadeOut,
                           level: fr.kind == .line ? line.level : (fr.kind == .piece ? .wordGroup : .stab),
                           score: line.score,
                           padKey: DialogueHash.padKey(sourceID: analysis.contentID, frames: fr.frames, transform: .native))
    }

    /// Accents read on the rendered pads (D126): the chop chain's 4:1 compressor (13 dB under the
    /// cut's peak) lifts a soft onset, so its rendered attack comes earlier than the source's, by
    /// 20 ms and more on a breathy "h" or "s" (a transcribed capture's signature pad read -23 ms).
    /// Every gate of a pad is a truncation of the same render, so the full pad's attack is every
    /// hit's attack. A rendered beat further than `renderedAccentRange` from the source one keeps
    /// the source one.
    static func renderedAccents(_ fragments: [DialogueMotifFragment], line: SpeechUnit, source: DialogueSource,
                                analysis: DialogueAnalysis, only: Set<Int>? = nil) -> (fragments: [DialogueMotifFragment], renders: [Int: AVAudioPCMBuffer]) {
        var renders: [Int: AVAudioPCMBuffer] = [:]
        let out = fragments.map { fr -> DialogueMotifFragment in
            if let only, !only.contains(fr.id) { return fr }
            var level: Float?
            guard let buffer = DialogueChopRenderer.renderPad(pad(fr, line: line, analysis: analysis), source: source,
                                                              analysis: analysis, gainDB: 0, level: &level),
                  let x = buffer.floatChannelData?[0] else { return fr }
            renders[fr.id] = buffer
            let n = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            // The attack needs the first 300 ms peak window and a little after it.
            let head = min(n, Int(0.45 * rate))
            let envelope = DialogueOnsetEnvelope(samples: x, count: n, rate: rate, span: 0..<head, filtered: false)
            let attack = DialogueOnset.attack(envelope, samples: x, count: n, rate: rate, search: 0..<head, line: fr.kind == .line,
                                              firstPeakShare: fr.weakLead ? DialogueMotifTuning.weakLeadPeakShare : 0.5)
            let beat = fr.frames.lowerBound + attack.beatFrame
            let range = DialogueMotifTuning.renderedAccentRange
            guard attack.beatFrame > 0, beat < fr.frames.upperBound,
                  Double(beat - fr.accentFrame) / rate >= range.lowerBound, Double(beat - fr.accentFrame) / rate <= range.upperBound
            else { return fr }
            var out = fr
            out.accentFrame = beat
            return out
        }
        return (out, renders)
    }

    /// The `motif` element of the plan log: the line, its pieces and the loop's cells.
    func log() -> [String: Any] {
        func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return [
            "loop": loop, "line": text as Any, "lineUnit": lineUnit, "lineKey": String(lineKey, radix: 16),
            "usedTranscript": usedTranscript, "reorderAllowed": reorderAllowed, "carried": carried,
            "interest": r3(Double(interest)),
            "fragments": fragments.map { fr -> [String: Any] in
                var e: [String: Any] = ["id": fr.id, "kind": fr.kind.rawValue, "order": fr.order,
                                        "source": [r3(source.sourceSeconds(frame: fr.frames.lowerBound)),
                                                   r3(source.sourceSeconds(frame: fr.frames.upperBound))],
                                        "duration": r3(seconds(fr.id)), "accentOffset": r3(accentOffset(fr.id)),
                                        "subLine": isSubLine(fr.id), "weight": r3(Double(fr.weight))]
                if let parent = fr.parent { e["parent"] = parent }
                if let t = fr.text { e["text"] = t }
                return e
            },
            "cells": cells.map { ["kind": $0.kind.rawValue, "bar": $0.bar, "bars": $0.bars, "variant": $0.variant,
                                  "items": $0.items.map { [$0.fragment, $0.slot] }] as [String: Any] },
            "arc": arc.map { ["intro": $0.intro, "groove": $0.groove, "build": $0.build, "breakdown": $0.breakdown,
                              "outro": $0.outro, "feel": $0.feel, "feelName": feel.name, "name": $0.name] as [String: Any] } as Any,
            "hook": hook.map { ["template": $0.template, "signature": $0.signature, "response": $0.response, "third": $0.third,
                                "items": $0.items.map { [$0.fragment, $0.slot] },
                                "skeleton": $0.items.filter(\.skeleton).map { [$0.fragment, $0.slot] }] as [String: Any] } as Any,
        ]
    }

    var text: String? { line.text }

    /// One log line: the line and its interest, the hook template and its S, R and T pieces, and per
    /// bar of the loop the steps and roles of `events` (`S`, `R`, `T`, `L` the line, `.` any other
    /// piece), e.g. `b3:0S,4R,8S`.
    func hookSummary(events: [DialogueEvent]) -> String {
        func quote(_ id: Int) -> String { "\"\(fragments.indices.contains(id) ? (fragments[id].text ?? "#\(id)") : "#\(id)")\"" }
        var out = "interest=\(String(format: "%.2f", interest)) line=\"\(text ?? "-")\""
        if let arc { out += " arc=\(arc.name.replacingOccurrences(of: " ", with: ",")) feel=\(feel.name)" }
        if let hook {
            out += " template=\(hook.template) S=\(quote(hook.signature)) R=\(quote(hook.response)) T=\(quote(hook.third))"
        }
        func role(_ piece: Int?) -> String {
            guard let piece else { return "?" }
            if piece == 0 { return "L" }
            if piece == hook?.signature { return "S" }
            if piece == hook?.response { return "R" }
            if piece == hook?.third { return "T" }
            // D127: the signature's and response's halves are `s` and `r`, any other cut `.`.
            if let h = hook, halves[h.signature]?.contains(piece) == true { return "s" }
            if let h = hook, halves[h.response]?.contains(piece) == true { return "r" }
            return "."
        }
        var bars: [Int: [String]] = [:]
        for e in events.sorted(by: { ($0.block, $0.slot) < ($1.block, $1.slot) }) {
            let s = (e.block - loop * 4) * 64 + e.slot
            guard s >= 0, s < 256 else { continue }
            // `/2` a hit held two sixteenths (D126), `/c` choked; a one-shot has no suffix.
            let gate = e.gateEnd == "choke" ? "/c" : (e.gateEnd == "natural" ? "" : e.gateSteps.map { "/\(Int($0))" } ?? "")
            bars[s / 16, default: []].append("\(s % 16)\(role(e.piece))\(gate)\(e.stutter ? "~" : "")")
        }
        out += " bars=" + bars.keys.sorted().map { "b\($0 + 1):" + bars[$0]!.joined(separator: ",") }.joined(separator: " ")
        // The chop beat's variety (D127): consecutive same-piece hits not marked as stutters, of all pairs.
        let chop = events.filter { $0.cell == .chopBeat }.sorted { $0.startTime < $1.startTime }
        if chop.count > 1 {
            let same = zip(chop, chop.dropFirst()).filter { $0.piece == $1.piece && !$1.stutter }.count
            out += " chopRepeat=\(same)/\(chop.count - 1) chopPieces=\(Set(chop.compactMap(\.piece)).count)"
        }
        return out
    }
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
            let (ta, tb) = Self.split(piece.text, at: Double(c - r.lowerBound) / Double(r.count),
                                      words: words.filter { r.contains(($0.frames.lowerBound + $0.frames.upperBound) / 2) }, cut: c)
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
        return Result(fragments: trimmed(fragments, words: words), pieces: pieces, halves: halves)
    }

    /// Every fragment starts at its waveform onset and lands its attack on the step (D126): the
    /// valley-started pads played breath, room tone and the consonant up to 130 ms before the step,
    /// and a weak first syllable put the heard attack up to 175 ms after it (D125 captures).
    func trimmed(_ fragments: [DialogueMotifFragment], words: [DialogueWordSpan]) -> [DialogueMotifFragment] {
        guard let line = fragments.first else { return fragments }
        let context = frames(0.2)
        let envelope = DialogueOnsetEnvelope(samples: samples, count: count, rate: rate,
                                             span: max(0, line.frames.lowerBound - context)..<min(count, line.frames.upperBound))
        let least = frames(DialogueMotifTuning.minimumPieceSeconds)
        let wordEnds = words.map(\.frames.upperBound)
        return fragments.map { fr in
            var out = fr
            var attack = DialogueOnset.attack(envelope, samples: samples, count: count, rate: rate, search: fr.frames,
                                              line: fr.kind == .line)
            // A transcribed piece never starts inside a word: a weak first syllable is then the beat (the
            // sound starts on the step) instead of being trimmed off. Whole weak lead words ("to the"
            // before "time") may still go.
            let slack = frames(DialogueMotifTuning.wordStartSlackSeconds)
            if fr.kind != .line, words.contains(where: { $0.frames.lowerBound >= fr.frames.lowerBound - slack
                    && attack.startFrame > max($0.frames.lowerBound, fr.frames.lowerBound) + slack
                    && attack.startFrame < $0.frames.upperBound - slack }) {
                attack = DialogueOnset.attack(envelope, samples: samples, count: count, rate: rate, search: fr.frames,
                                              firstPeakShare: DialogueMotifTuning.weakLeadPeakShare)
                out.weakLead = true
            }
            if fr.frames.upperBound - attack.startFrame >= least {
                // A weak lead word trimmed off a piece ("to the" before "time") leaves its text too.
                let dropped = words.filter { (fr.frames.lowerBound..<attack.startFrame).contains(($0.frames.lowerBound + $0.frames.upperBound) / 2) }.count
                if fr.kind != .line, dropped > 0, let text = fr.text {
                    let tokens = text.split(separator: " ")
                    if tokens.count > dropped { out.text = tokens.dropFirst(dropped).joined(separator: " ") }
                }
                out.frames = attack.startFrame..<fr.frames.upperBound
                out.accentFrame = attack.beatFrame
                out.fadeIn = attack.fadeIn
                out.hardOnset = attack.hard
            }
            let inner = out.accentFrame..<out.frames.upperBound
            out.cutPoints = Array(Set(valleys(out.frames).map(\.frame).filter { inner.contains($0) }
                + wordEnds.filter { inner.contains($0) && $0 < out.frames.upperBound - frames(0.01) })).sorted()
            return out
        }
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
        // With word timings, each half takes the words whose middles fall on its side of the cut
        // ("is" | "completed." was split by letter share before, D126).
        if words.count == parts.count, words.count > 1 {
            let k = words.filter { ($0.frames.lowerBound + $0.frames.upperBound) / 2 < cut }.count
            if k > 0, k < parts.count { return (parts[..<k].joined(separator: " "), parts[k...].joined(separator: " ")) }
        }
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
    /// The hook's role pieces (D125): the signature is the piece with the strongest word (the later
    /// one on ties; the first piece without text), the response the next-strongest when it carries a real word, else the
    /// line's ending; the third is the first other piece. A re-cut keeps the pieces that overlap the
    /// old signature and response (`anchors`). A line that may not be reordered keeps signature and
    /// response in source order.
    static func hookRoles(fragments: [DialogueMotifFragment], pieces: [Int], halves: [Int: [Int]], reorderAllowed: Bool,
                          sampleRate: Double, anchors: [Range<Int>] = []) -> (s: Int, r: Int, t: Int) {
        func seconds(_ id: Int) -> Double { Double(fragments[id].frames.count) / sampleRate }
        func overlap(_ id: Int, _ r: Range<Int>) -> Int {
            max(0, min(fragments[id].frames.upperBound, r.upperBound) - max(fragments[id].frames.lowerBound, r.lowerBound))
        }
        func best(_ list: [Int], latest: Bool = false, by key: (Int) -> Double) -> Int? {
            // Highest key; the earliest piece on ties, or the latest (`latest`).
            list.max { (key($0), latest ? fragments[$0].order : -fragments[$0].order) < (key($1), latest ? fragments[$1].order : -fragments[$1].order) }
        }
        let n = pieces.count
        var s: Int
        var r: Int
        let weighted = pieces.contains { fragments[$0].weight > 0 }
        // A re-cut keeps the old signature's words, unless they are only function words while the
        // line has a real word ("I you" in "I you know, the usual subject ..." of a 21 November 2026
        // run, where the acoustic first piece became 12 bars of "I you").
        let anchored = anchors.count == 2 ? best(pieces, by: { Double(overlap($0, anchors[0])) }).flatMap { a in
            overlap(a, anchors[0]) > 0 && (!weighted || fragments[a].weight > 0) ? a : nil
        } : nil
        if let a = anchored {
            s = a
            r = best(pieces.filter { $0 != a }, by: { Double(overlap($0, anchors[1])) }) ?? a
            if weighted, fragments[r].weight == 0, let other = best(pieces.filter { $0 != a }, by: { Double(fragments[$0].weight) }),
               fragments[other].weight > 0 {
                r = other
            }
        } else {
            if weighted {
                // Ties go to the later piece: English puts the sentence stress on its last content
                // word ("a large dose of LSD").
                s = best(pieces, latest: true) { p in
                    Double(fragments[p].weight) - (DialogueMotifTuning.signatureSeconds.contains(seconds(p)) ? 0 : 0.1)
                } ?? pieces[0]
            } else {
                s = pieces[0]
            }
            let others = pieces.filter { $0 != s }
            if let next = best(others, by: { Double(fragments[$0].weight) }), fragments[next].weight > DialogueMotifTuning.responseWeight {
                r = next
            } else if weighted {
                // The line's ending when it carries a word, else the strongest other piece; a line whose
                // other pieces are only function words answers with the signature itself ("than
                // marijuana." answered "marijuana.", not "than").
                let ending = pieces[n - 1]
                if ending != s, fragments[ending].weight > 0 {
                    r = ending
                } else if let next = best(others, by: { Double(fragments[$0].weight) }), fragments[next].weight > 0 {
                    r = next
                } else {
                    r = s
                }
            } else {
                r = pieces[n - 1] == s ? pieces[0] : pieces[n - 1]
            }
        }
        // Acoustic lines (no word weights) always answer with another piece.
        if r == s, n > 1, !weighted || anchored != nil { r = pieces.first { $0 != s }! }
        if !reorderAllowed, fragments[r].order < fragments[s].order { swap(&s, &r) }
        let sa = headHalf(s, fragments: fragments, halves: halves)
        // A line that may not be reordered takes the signature's head half as its third piece, so
        // each bar plays its new pieces in source order.
        // Otherwise the third is the strongest remaining piece (source order without text), so a
        // connective piece ("to the") is the third only when nothing else is left.
        let rest = pieces.filter { $0 != s && $0 != r }
        var t = reorderAllowed ? (best(rest, by: { Double(fragments[$0].weight) }) ?? (sa != s ? sa : r)) : (sa != s ? sa : r)
        // Nor a function-word third when the signature's head can stutter instead.
        if weighted, fragments[t].weight == 0, sa != s { t = sa }
        return (s, r, t)
    }

    /// The half of a piece its stutters repeat: the first half when the cut splits a word ("Sall-")
    /// or nothing carries text, else the half with the stronger word ("LSD." rather than "of").
    static func headHalf(_ piece: Int, fragments: [DialogueMotifFragment], halves: [Int: [Int]]) -> Int {
        guard let h = halves[piece], h.count == 2 else { return piece }
        let a = fragments[h[0]], b = fragments[h[1]]
        if a.text?.hasSuffix("-") == true || b.weight <= a.weight { return h[0] }
        return h[1]
    }

    /// The loop's arc (D126 part 2): seeded from the loop seed; a re-cut keeps `keep`. It differs
    /// from `avoid` (the previous loop's) in at least `arcChange` fields; a carried loop (the same
    /// line again) changes the groove and `arcChange` more.
    static func chooseArc(seed: UInt64, groove: Int, keep: DialogueArc?, avoid: DialogueArc?, carried: Bool) -> DialogueArc {
        if let keep {
            return DialogueArc(intro: keep.intro, groove: groove, build: keep.build, breakdown: keep.breakdown, outro: keep.outro, feel: keep.feel)
        }
        var rng = MusicRNG(seed: seed ^ 0xA2C0_0126)
        let n = DialogueMotifTuning.arcVariants
        var arc = DialogueArc(intro: rng.int(0...(n - 1)), groove: groove, build: rng.int(0...(n - 1)),
                              breakdown: rng.int(0...(n - 1)), outro: rng.int(0...(n - 1)))
        // The feel is drawn from its own stream, so D126's sections keep their seeded variants (D127).
        var feelRNG = MusicRNG(seed: seed ^ 0xD127_FEE1)
        let feels = DialogueFeel.variants.count
        arc.feel = feelRNG.int(0...(feels - 1))
        // Consecutive loops never share a feel, so the groove's pocket moves every loop.
        if let avoid, arc.feel == avoid.feel { arc.feel = (arc.feel + 1 + feelRNG.int(0...(feels - 2))) % feels }
        guard let avoid else { return arc }
        let needed = DialogueMotifTuning.arcChange + (carried ? 1 : 0)
        // Change the fields still equal to the previous arc, in a seeded order, until enough differ
        // (the feel already differs, so it counts as one).
        var order: [WritableKeyPath<DialogueArc, Int>] = [\.intro, \.build, \.breakdown, \.outro]
        for k in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(k, rng.int(0...k)) }
        for path in order where arc.differences(avoid) < needed + 1 && arc[keyPath: path] == avoid[keyPath: path] {
            arc[keyPath: path] = (arc[keyPath: path] + 1 + rng.int(0...(n - 2))) % n
        }
        return arc
    }

    /// The loop's 16-bar arc (D126 part 2; user direction of 21 November 2026), cells on the
    /// score's sections: the intro states the whole line on bar 1's downbeat with a seeded tag in bar
    /// 2; the chop beat plays the 2-bar groove cell twice (bars 3-6, the second with a new last
    /// beat); the build doubles the density into the halfway drop (bars 7-8); the breakdown holds one
    /// or two words a bar with echo throws (bars 9-12, a reversed pickup into bar 13); the outro keeps
    /// the return's one quiet piece in bar 13, restates the line in bars 14-15 with some parts
    /// repeated, and tags bar 16. Each section has seeded variants (`DialogueArc`), so no two
    /// consecutive loops play the same arc.
    static func arrange(fragments: [DialogueMotifFragment], pieces: [Int], halves: [Int: [Int]], reorderAllowed: Bool,
                        seed: UInt64, lineSeconds: Double, sampleRate: Double, hookSeed: UInt64, loop: Int,
                        anchors: [Range<Int>] = [], avoidTemplate: Int? = nil, drums: DialogueMotifDrums = .boomBap,
                        keepArc: DialogueArc? = nil, avoidArc: DialogueArc? = nil,
                        carried: Bool = false) -> (cells: [DialogueMotifCell], hook: DialogueMotifHook, arc: DialogueArc) {
        var rng = MusicRNG(seed: seed ^ 0x4D07_1F00)
        func seconds(_ id: Int) -> Double { Double(fragments[id].frames.count) / sampleRate }
        let roles = hookRoles(fragments: fragments, pieces: pieces, halves: halves, reorderAllowed: reorderAllowed,
                              sampleRate: sampleRate, anchors: anchors)
        let (s, r, t) = roles
        let sa = headHalf(s, fragments: fragments, halves: halves)
        let ra = halves[r]?[0] ?? r
        // The split piece: the longest piece that has halves; without halves, the shortest pair of
        // neighbouring pieces stands in (a word group heard as two words with a pause between).
        let split = halves.keys.sorted { (seconds($0), -$0) > (seconds($1), -$1) }.first
        let pair = zip(pieces, pieces.dropFirst()).min { seconds($0.0) + seconds($0.1) < seconds($1.0) + seconds($1.1) }
        let (splitA, splitB) = split.flatMap { halves[$0] }.map { ($0[0], $0[1]) } ?? pair.map { ($0.0, $0.1) } ?? (s, r)
        typealias Item = DialogueMotifCell.Item
        func at(_ f: Int, _ slot: Int, _ e: Item.Effect = .none, gain: Float = 0, gate: Int? = nil) -> Item {
            Item(fragment: f, slot: slot, gainDB: gain, effect: e, fixed: true, gate: gate)
        }
        /// An unfixed hit: it may move one 8th later when its step is taken or too early.
        func near(_ f: Int, _ slot: Int, _ e: Item.Effect = .none, gate: Int? = nil) -> Item {
            Item(fragment: f, slot: slot, effect: e, gate: gate)
        }
        /// The next 8th after the previous hit ends, played out.
        func chain(_ f: Int, from slot: Int, _ e: Item.Effect = .none, gate: Int? = nil) -> Item {
            Item(fragment: f, slot: slot, after: 0, effect: e, gate: gate, onEighths: true)
        }
        func follow(_ f: Int, _ steps: Int = 1, gate: Int? = 1) -> Item {
            Item(fragment: f, slot: 0, fixed: true, gate: gate, follow: steps)
        }
        /// A deliberate repeat of the hit before it (D127).
        func stutter(_ item: Item) -> Item { var i = item; i.stutter = true; return i }

        var mix = MusicRNG(seed: hookSeed ^ 0x600C_ED00)
        let offset = mix.int(0...(DialogueMotifTuning.hookTemplates.count - 1))
        var template = (offset + max(0, loop) / DialogueMotifTuning.hookLoops) % DialogueMotifTuning.hookTemplates.count
        // A carried loop (the same line again: the films have no fresh one) never keeps the trigger
        // rhythm too, or 16 bars repeat exactly (C-D1; the `same` matrix case read 0.04 difference).
        if template == avoidTemplate { template = (template + 1) % DialogueMotifTuning.hookTemplates.count }
        let arc = chooseArc(seed: seed, groove: template, keep: keepArc, avoid: avoidArc, carried: carried)
        let vocabulary = GrooveVocabulary(s: s, r: r, t: t, sa: sa, ra: ra, pieces: pieces, halves: halves)
        // The skeleton holds for the template's loops; the fill around it is drawn from this loop's seed (D127).
        let g = groove(template: DialogueMotifTuning.hookTemplates[template], vocabulary: vocabulary, drums: drums,
                       reorderAllowed: reorderAllowed, fragments: fragments, sampleRate: sampleRate, seed: seed)
        let barA = g.filter { $0.slot < 16 }
        let last = pieces.last ?? r
        // The return's short piece carries a real word when the line has a short one (it stays short:
        // at -3 dB a long piece reads as a quiet chop, C-B8's loudness spread).
        let shorts = [sa, s, splitB, ra] + pieces
        let worded = shorts.filter { fragments[$0].weight > 0 && seconds($0) <= DialogueMotifTuning.returnPieceSeconds }
        let short = (worded.isEmpty ? shorts : worded).min { seconds($0) < seconds($1) } ?? s

        // Intro (bars 1-2): the whole line on the downbeat, then a tag on bar 2's backbeat.
        let tag: [Item]
        switch arc.intro {
        case 0: tag = [near(last, 28, .echoThrow)]
        case 1: tag = [near(s, 24, gate: 2), near(s, 28, gate: 2)]
        default: tag = [near(r, 28, .filtered)]
        }
        let intro = [Item(fragment: 0, slot: 0)] + tag

        // Chop beat (bars 3-6): the groove twice; the second time its last beat turns.
        let turn: [Item]
        switch rng.int(0...2) {
        // The backbeat answer stays on step 28.
        case 0: turn = [at(r, 28, gate: 1), at(ra, 29, gate: 1), stutter(at(ra, 30, gate: 2))]
        case 1: turn = [at(r, 28, .echoThrow, gate: 2)]
        default: turn = [at(r, 28, gate: 2), at(vocabulary.sb != r ? vocabulary.sb : sa, 30, gate: 2)]
        }
        let second = g.filter { $0.slot < 28 } + turn

        // Build (bars 7-8): bar 7 is the groove's call with one more stab, bar 8 doubles it into the drop.
        var seven = barA
        if let free = stride(from: 0, to: 16, by: 2).first(where: { k in !seven.contains { abs($0.slot - k) <= 1 } }) {
            // A cut the hits around it do not play (D127).
            seven.append(at(freshCut([vocabulary.sb, sa, t, ra] + vocabulary.others, at: free, among: seven), free, gate: 1))
            seven.sort { $0.slot < $1.slot }
        }
        let eight: [Item]
        switch arc.build {
        case 0:
            // Halving: a quarter, two 8ths, then 16ths, answered on the last 8th. The repeats are the roll.
            eight = [at(s, 16, gate: 4), stutter(at(s, 20, gate: 2)), stutter(at(s, 22, gate: 2)), at(sa, 24, gate: 1)]
                + (25...29).map { stutter(at(sa, $0, gate: 1)) } + [at(r, 30, gate: 1)]
        case 1:
            // Ladder: the line's first words, one more each beat, in source order (the beat-2 restart is the ladder's stutter).
            let w = (0..<3).map { pieces[min($0, pieces.count - 1)] }
            eight = [at(w[0], 16, gate: 2), stutter(at(w[0], 20, gate: 1)), at(w[1], 22, gate: 2),
                     at(w[0], 24, gate: 1), at(w[1], 25, gate: 1), at(w[2], 26, gate: 2),
                     at(w[0], 28, gate: 1), at(w[1], 29, gate: 1), at(w[2], 30, gate: 1)]
        default:
            // Ping-pong: the signature's head and the response's on alternate 16ths in beats 3 and 4.
            eight = [at(s, 16, gate: 2), at(r, 20, gate: 2)] + (24...30).map { at($0 % 2 == 0 ? sa : ra, $0, gate: 1) }
        }
        // Every variant's last stab ends a sixteenth before the drop, so the breakdown's first word can
        // start its consonant just before bar 9's downbeat (the next cue's plan cannot choke it).
        let build = seven + eight

        // Breakdown (bars 9-12, one cell): a word or two a bar, held, with echo throws; the split
        // syllable with a pause in bar 11; a reversed pickup into bar 13.
        let first = pieces.first ?? s
        var breakdown: [Item]
        switch arc.breakdown {
        case 0: breakdown = [near(s, 0, .echoThrow), near(r, 24, .echoThrow), near(splitA, 40), near(splitB, 44, .echoThrow), near(t, 52)]
        case 1: breakdown = [near(s, 0, .echoThrow), near(r, 20, .filtered), near(splitA, 40), near(splitB, 44, .echoThrow), near(s, 48, .echoThrow)]
        default: breakdown = [near(first, 0, .echoThrow), near(s, 24, .echoThrow), near(splitA, 40), near(splitB, 44, .echoThrow), near(r, 52)]
        }
        breakdown.append(Item(fragment: ra, slot: 64, effect: .reversed, fixed: true))

        // Outro (bars 13-16, one cell): the return's quiet piece, the line again from bar 14, a tag.
        var outro = [at(short, 12, gain: DialogueMotifTuning.returnPieceDB)]
        switch arc.outro {
        case 0:
            // The line walked on the 8ths, the signature stuttered before it plays out.
            for (k, p) in pieces.enumerated() {
                if p == s {
                    outro.append(k == 0 ? Item(fragment: sa, slot: 16, fixed: true, gate: 1) : chain(sa, from: 16, gate: 1))
                    outro.append(follow(sa))
                    outro.append(follow(p, 1, gate: nil))
                } else {
                    outro.append(k == 0 ? Item(fragment: p, slot: 16) : chain(p, from: 16))
                }
            }
            // Then the signature once more, a 1/8 stab in bar 15 (or after a long line's walk).
            outro.append(chain(s, from: 36, gate: 2))
        case 1:
            // The clean line, then its last word twice, thrown.
            outro += [Item(fragment: 0, slot: 16), chain(last, from: 16, gate: 2), chain(last, from: 16, .echoThrow)]
        default:
            // The line, then its first words again.
            outro += [Item(fragment: 0, slot: 16), chain(first, from: 16), chain(pieces.count > 1 ? pieces[1] : s, from: 16),
                      chain(last, from: 36, gate: 2)]
        }
        // The tag's answer holds an 8th, so the next loop's line can start on its downbeat.
        outro += [at(sa, 56, gate: 1), at(sa, 57, gate: 1), at(sa, 58, gate: 1), at(r, 60, gate: 2)]

        let cells: [DialogueMotifCell] = [
            DialogueMotifCell(kind: .intro, bar: 0, bars: 2, variant: arc.intro, items: intro),
            DialogueMotifCell(kind: .chopBeat, bar: 2, bars: 2, variant: template, items: g),
            DialogueMotifCell(kind: .chopBeat, bar: 4, bars: 2, variant: template, items: second),
            DialogueMotifCell(kind: .build, bar: 6, bars: 2, variant: arc.build, items: build),
            DialogueMotifCell(kind: .breakdown, bar: 8, bars: 4, variant: arc.breakdown, items: breakdown),
            DialogueMotifCell(kind: .outro, bar: 12, bars: 4, variant: arc.outro, items: outro),
        ]
        return (cells, DialogueMotifHook(template: template, signature: s, response: r, third: t, items: g), arc)
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
        var gate: Int? = nil
        /// How the dry piece ends: `natural`, `gate`, `valley` or `choke`.
        var gateEnd = "natural"
        var stutter = false
        /// The loop's feel offset in the accent (D127).
        var feel: Double = 0
    }

    /// The end of a hit whose attack is on take sixteenth `s` and whose pad starts at `start` (D126):
    /// `gate` sixteenths on the drummer's grid less `gateLeadSeconds`, or a cut point of the piece up
    /// to `valleySnapSeconds` before that; never past the piece's natural end.
    static func gatedEnd(_ fragment: Int, start: Double, sixteenth s: Int, gate: Int?, motif: DialogueMotif,
                         snapshot: DialogueTransportSnapshot) -> (end: Double, kind: String) {
        let natural = start + motif.seconds(fragment)
        guard let gate, gate > 0, fragment != 0 else { return (natural, "natural") }
        let target = snapshot.gridTime(sixteenth: s + gate) - DialogueMotifTuning.gateLeadSeconds
        guard target < natural else { return (natural, "natural") }
        let fr = motif.fragments[fragment]
        let least = start + motif.accentOffset(fragment) + DialogueMotifTuning.minimumGateSeconds
        let valleys = fr.cutPoints.map { start + Double($0 - fr.frames.lowerBound) / motif.sampleRate }
            .filter { $0 <= target && $0 >= target - DialogueMotifTuning.valleySnapSeconds && $0 >= least }
        if let v = valleys.max() { return (v, "valley") }
        return (min(natural, max(target, least)), "gate")
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
        let budget = DialogueMotifTuning.maximumSectionOccupancy * (boundary - snapshot.time(beat: owned.lowerBound))
        func drySeconds() -> Double { placed.reduce(0) { $0 + ($1.end - $1.start) } }

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
                // The section's dry budget; the line statement, the turnaround's landing and the phrase-end
                // stutter (its repeats choke each other, so they cost little) always play.
                // The build's stutters and any follow-on repeat (they choke each other, so they cost little) always play.
                let stutterFill = (cell.kind == .stutter && item.slot >= 16) || cell.kind == .build || item.follow != nil
                let budgeted = item.fragment != 0 && !item.landing && !stutterFill
                if budgeted, item.gate == nil, drySeconds() + length > budget { continue }
                let shift = firstInCell && placed.isEmpty ? DialogueMotifTuning.lateSlotShift : DialogueMotifTuning.slotShift
                let candidates: [Int]
                if let follow = item.follow {
                    // Exactly `follow` sixteenths after the previous hit of this cell (a stutter), or not at all.
                    guard let previous = placed.last, previous.sixteenth >= cellStart else { continue }
                    candidates = [previous.sixteenth + follow].filter { $0 < cellEnd }
                } else if let gap = item.after {
                    // The first sixteenth (8th with `onEighths`) at or after `slot` that leaves `gap`
                    // sixteenths after the previous event.
                    let needed = prevEnd + DialogueTuning.dryGapSeconds + Double(gap) * sixteenthSeconds(base)
                    var s = base
                    while s < cellEnd, (item.onEighths && ((s % 2) + 2) % 2 != 0) || snapshot.gridTime(sixteenth: s) - offset < needed { s += 1 }
                    candidates = s < cellEnd ? [s] : []
                } else if item.fragment == 0 {
                    // The line is stated on a beat: its slot, a beat or two later, or the next bar (D126 part 2).
                    candidates = DialogueMotifTuning.lineSteps.map { base + $0 }.filter { $0 < cellEnd }
                } else if item.landing || item.fixed {
                    candidates = [base]
                } else {
                    // Never an off-sixteenth: a hit moves by 8ths (D126 part 2, "always on beat").
                    candidates = Array(stride(from: base, through: base + shift, by: 2)).filter { $0 < cellEnd }
                }
                var done = false
                // The loop's feel moves the chop beat's and build's offbeat stabs (D127); quarter steps stay on the grid.
                let feels = (cell.kind == .chopBeat || cell.kind == .build) && item.fragment != 0 && item.effect != .reversed
                for s in candidates {
                    let feel = feels ? motif.feel.offset(step: s) : 0
                    let accent = snapshot.gridTime(sixteenth: s) + feel
                    let start = accent - offset
                    let gated = item.effect == .reversed ? (end: start + length, kind: "natural")
                        : gatedEnd(item.fragment, start: start, sixteenth: s, gate: item.gate, motif: motif, snapshot: snapshot)
                    let end = gated.end
                    guard start >= floor else { continue }
                    if budgeted, item.gate != nil, drySeconds() + (end - start) > budget { break }
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
                        // A choke only shortens: a start inside the dry gap after the earlier piece's end
                        // must not stretch that piece past its pad (D124 seed-19 finding).
                        placed[placed.count - 1].end = min(placed[placed.count - 1].end, start - DialogueTuning.chokeLeadSeconds)
                        placed[placed.count - 1].choked = true
                        placed[placed.count - 1].gateEnd = "choke"
                    }
                    placed.append(Placed(fragment: item.fragment, cell: cell.kind, sixteenth: s, accent: accent, start: start, end: end,
                                         gainDB: item.gainDB, effect: item.effect, landing: item.landing, gate: item.gate,
                                         gateEnd: gated.kind, stutter: item.stutter, feel: feel))
                    prevEnd = end
                    if item.fragment == 0 { statements += 1 }
                    done = true
                    break
                }
                if done { firstInCell = false }
            }
        }
        placed = repair(placed, motif: motif, snapshot: snapshot, owned: owned, hard: hard, floor: floor, upper: upper)
        let events = finish(placed, motif: motif, snapshot: snapshot, upper: upper,
                            budget: DialogueMotifTuning.maximumSectionOccupancyWithEcho * (boundary - snapshot.time(beat: owned.lowerBound)))

        // Blocks touching the window, as the grammar logs them; each block is named by its first cell.
        // Not before the owned section: a window may open `sectionPreRollSeconds` before it.
        let firstBeat = max(snapshot.beat(time: window.lowerBound), owned.lowerBound)
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
            // A bar's onset is a hit's accent, the frame on its step: a downbeat hit starts its consonant
            // just before the bar line, and a reversed pickup swells through the bar before its own.
            // The bar is measured on the drummer's step grid, not the straight bar line: a downbeat
            // step the drummer plays ahead (a negative offset) has its accent just before `barStart`,
            // and counting it in the previous bar made the breakdown's downbeat word (and the intro
            // line) look missing, so repair added a stab on step 2 that choked it (live log, D126 check).
            let s0 = Int((bar * 4).rounded())
            let gridStart = snapshot.gridTime(sixteenth: s0), gridEnd = snapshot.gridTime(sixteenth: s0 + 16)
            if placed.contains(where: { $0.accent >= gridStart - 1e-6 && $0.accent < gridEnd - 1e-6 }) { continue }
            let barInLoop = Int(((bar - loopBeat) / 4).rounded())
            let returnBar = barInLoop == 12
            // The hook's own items for this bar first (same step, same piece), so a repaired bar is
            // on-pattern (D125); then recurring pieces on the generic slots, rotating so repairs do
            // not always pick the same cut.
            let hookItems = (motif.hook?.items ?? []).filter { $0.slot / 16 == ((barInLoop % 2) + 2) % 2 }
                .map { (slot: $0.slot % 16, fragment: $0.fragment) }
            let order = Array(candidates[(rotation % max(1, candidates.count))...] + candidates[..<(rotation % max(1, candidates.count))])
            rotation += 1
            let generic = DialogueMotifTuning.repairSlots.flatMap { slot in order.map { (slot: slot, fragment: $0) } }
            for (slot, f) in hookItems + generic {
                let accent = snapshot.gridTime(sixteenth: s0 + slot)
                let start = accent - motif.accentOffset(f)
                // A breakdown bar's repair holds its word (the section's own vocabulary); elsewhere a 1/8 stab.
                let repairGate: Int? = (8..<12).contains(barInLoop) ? nil : DialogueMotifTuning.repairGate
                let gated = gatedEnd(f, start: start, sixteenth: s0 + slot, gate: repairGate, motif: motif, snapshot: snapshot)
                var end = gated.end
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
                    placed[p].end = min(placed[p].end, start - DialogueTuning.chokeLeadSeconds)
                    placed[p].choked = true
                    placed[p].gateEnd = "choke"
                }
                var e = Placed(fragment: f, cell: .repair, sixteenth: s0 + slot, accent: accent, start: start, end: end,
                               gainDB: returnBar ? DialogueMotifTuning.returnPieceDB : 0, effect: .none, landing: false,
                               gate: repairGate, gateEnd: chokedSelf ? "choke" : gated.kind)
                e.choked = chokedSelf
                placed.insert(e, at: next ?? placed.count)
                break
            }
        }
        return placed
    }

    /// Events from placed pieces: effect tails inside the following space, blocks and slots.
    static func finish(_ placed: [Placed], motif: DialogueMotif, snapshot: DialogueTransportSnapshot, upper: Double,
                       budget: Double = .infinity) -> [DialogueEvent] {
        var out: [DialogueEvent] = []
        // Echo tails share what the dry pieces leave of the section's budget, first come first served.
        var spare = budget - placed.reduce(0) { $0 + ($1.end - $1.start) }
        let lastPhrase = snapshot.phraseAtOrigin + Int((snapshot.beat(time: upper - 1e-6) / 16).rounded(.down))
        for (i, p) in placed.enumerated() {
            let pad = motif.bank.pads[p.fragment]
            let nextStart = i + 1 < placed.count ? placed[i + 1].start : upper + snapshot.beatDuration
            var effect: DialogueChopEffect = .none
            var end = p.end
            switch p.effect {
            case .echoThrow where !p.choked:
                let beat = snapshot.beatLength(at: Double(p.sixteenth) / 4)
                // A tail stops `sectionTailLead` before the section's end, so the next cue's first hook
                // hit (on the downbeat, its accent a little after its start) is never blocked (D125).
                let tail = min(DialogueMotifTuning.echoTailBeats * beat, nextStart - DialogueTuning.dryGapSeconds - p.end,
                               max(0, upper - DialogueMotifTuning.sectionTailLead - p.end), max(0, spare))
                let delay = DialogueMotifTuning.echoDelayBeats * beat
                if tail >= max(DialogueMotifTuning.minimumEchoTailSeconds, delay + 0.05) {
                    effect = .echoThrow(delay: delay, tail: tail)
                    end = p.end + tail
                    spare -= tail
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
            event.gateSteps = p.gate.map(Double.init)
            event.gateEnd = p.gateEnd
            event.stutter = p.stutter
            event.feelSeconds = p.feel
            // The dry buffer is cut here (with the gate's short release, or the choke's) even when an
            // echo tail follows it: a gated stab thrown into its echo.
            if p.gateEnd != "natural" || p.choked { event.drySeconds = p.end - p.start }
            let sourceStart = motif.fragments[p.fragment].frames.lowerBound
            event.sourceFrames = sourceStart..<(sourceStart + Int(((p.end - p.start) * motif.sampleRate).rounded()))
            out.append(event)
        }
        return out
    }
}

/// One recent film the motif can dig a line from: its PCM, analysis and transcript.
nonisolated struct DialogueMotifCrateEntry: @unchecked Sendable {
    let source: DialogueSource
    let analysis: DialogueAnalysis
    let transcript: DialogueTranscript?
}

nonisolated extension DialoguePerformanceMemory {
    /// Full-line statements already played in `loop`.
    func motifStatements(loop: Int) -> Int { motif?.loop == loop ? motifLineStatements : 0 }

    /// Keeps the newest entry per film (a transcript revision replaces the acoustic one).
    mutating func addToCrate(_ entry: DialogueMotifCrateEntry) {
        guard entry.analysis.features != nil, !entry.analysis.units.isEmpty else { return }
        motifCrate.removeAll { $0.source.contentID == entry.source.contentID && $0.source.sourceStart == entry.source.sourceStart }
        motifCrate.append(entry)
        if motifCrate.count > DialogueMotifTuning.crateSize { motifCrate.removeFirst(motifCrate.count - DialogueMotifTuning.crateSize) }
    }

    mutating func setMotif(_ motif: DialogueMotif, statements: Int) {
        if self.motif?.loop != motif.loop || self.motif?.lineKey != motif.lineKey {
            let frames = motif.line.frames
            motifLines.append(DialogueMotifLineUse(key: motif.lineKey, loop: motif.loop, contentID: motif.source.contentID,
                                                   frames: frames,
                                                   seconds: motif.source.sourceSeconds(frame: frames.lowerBound)
                                                       ..< motif.source.sourceSeconds(frame: frames.upperBound),
                                                   text: motif.usedTranscript ? motif.text.map(DialogueMotif.spokenText) : nil))
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
        parts.flatMap { DialogueChopRenderer.render($0.plan, bank: $0.motif.bank, source: $0.motif.source, analysis: $0.motif.analysis,
                                                    prerendered: $0.motif.renders) }
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
            // A section's first piece may start a little before its downbeat (its consonant before the
            // accent on step 0) when the window opens earlier: the cue's bed starts before bar 9, and the
            // previous plan's pieces end by the boundary (its echo tails `sectionTailLead` before it).
            // Without this the hook's downbeat hit in bar 9 and the statement on bar 1 were dropped or
            // pushed late every loop (verification pass of 21 November 2026).
            // Nor in the bed's first `bedStartLeadSeconds`: a cue's chops queue only once its bed has begun
            // (`ArchiveVoice.queueDueChops`, a 0.1 s tick plus the route margin), so a piece right at the
            // bed's start was planned but silently dropped (the `long` capture's bar-9 hook hit, -200 LUFS).
            let lower = max(window.lowerBound + DialogueMotifTuning.bedStartLeadSeconds,
                            snapshot.time(beat: section.lowerBound) - DialogueMotifTuning.sectionPreRollSeconds)
            let upper = min(window.upperBound, snapshot.time(beat: section.upperBound))
            guard upper > lower else { continue }
            let loop = loopIndex(beat: section.lowerBound, snapshot: snapshot)
            guard let motif = resolve(loop: loop, source: source, analysis: analysis, hasBank: bank != nil, transcript: transcript,
                                      memory: trial, seed: seed, beatDuration: snapshot.beatLength(at: section.lowerBound),
                                      drums: DialogueMotifDrums(snapshot: snapshot))
            else { return nil }
            if trial.cycleSeed == nil { trial.cycleSeed = seed }
            let part = DialogueMotifPerformer.perform(motif, snapshot: snapshot, window: lower..<upper, owned: section,
                                                      earliestStart: earliestStart, memory: &trial, seed: seed,
                                                      cueToken: cueToken, revision: revision)
            parts.append((part, motif))
        }
        guard let last = parts.last else { return nil }
        trial.addToCrate(DialogueMotifCrateEntry(source: source, analysis: analysis, transcript: transcript))
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
