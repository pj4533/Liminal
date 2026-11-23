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
        // Snare answer with room for complete slow words. A one-beat call-to-response gap
        // dropped both answers after a long signature; the second call also waits for the
        // first answer to finish. This grid still holds across both lines of the template.
        [(.s, 0), (.t, 6), (.r, 12), (.s, 18), (.t, 24), (.r, 28)],
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

    // MARK: Whole words (D130; user direction of 22 November 2026: "less chopping of connective words.
    // Or partial words. It almost sounds like a bug maybe sometimes.")

    /// A word group holds at most this many words and about this long (a function word rides with its
    /// content word, so a group is "of LSD" or "the old house", never "It's a").
    static let groupWordLimit = 4
    static let groupMaximumSeconds = 0.9
    /// A boundary between word groups (or an acoustic valley cut) is cut only where the sound really
    /// dips: this far under the lower neighbouring peak, or a quiet run this long (and `realDipRunDB` under
    /// it). Co-articulated words with no dip between them stay together.
    static let realDipDB: Float = 9
    static let realDipRunSeconds = 0.015
    static let realDipRunDB: Float = 4
    /// A boundary between two words is searched this far into each word's core (a dip further in is
    /// inside the word; with no dip near the boundary the words stay together).
    static let wordTimingSeconds = 0.025
    /// A piece that merged past this is cut at its deepest word boundary anyway.
    static let mergedPieceSeconds = 1.1
    /// An edge more than this inside a word's voiced core cuts the word (the salience probe's 30 ms, less a margin).
    static let wordCoreToleranceSeconds = 0.025
    /// Only a word at least this heavy, with two or more syllables by text and nuclei, splits into
    /// syllables; an initialism splits into letters when its nuclei match its letters.
    static let syllableWeight: Float = 0.7
    static let maximumUnits = 4
    /// A syllable or letter unit keeps at least this much.
    static let minimumUnitSeconds = 0.060
    /// A gate that would close inside a word ends at the next word end (or real dip) within this, else
    /// at the last one before it.
    static let gateExtendSeconds = 0.30
    /// The chop beat's share of a bar's dry budget its groove may fill (the line statement, the tags and
    /// the build share the rest of the section).
    static let grooveBudgetShare = 0.85
    /// A cut fits the room before the next hit within this, less the next hit's typical lead.
    static let fitToleranceSeconds = 0.020
    static let nextLeadSeconds = 0.030
    /// An untexted line's interest when the cue has a transcript (under `plainInterest`): it leads only
    /// when no transcribed line is left.
    static let untextedInterest: Float = 0.15
    /// A clamped start may sit at most this far before the accent (a weak first consonant).
    static let maximumLeadSeconds = 0.090

    // MARK: Salience (D130 stage 2; user direction of 22 November 2026: "more stuff like" the
    // "psilocybin" / "DMT" chop, "less chopping of connective words")

    /// The seeded line pool keeps only lines within this much interest of the most interesting unplayed line.
    static let linePoolInterest: Float = 0.10
    /// A line whose strongest word weighs this much may be short: `shortLineSeconds` and `shortLineNuclei`.
    static let shortLineWeight: Float = 0.85
    static let shortLineSeconds: ClosedRange<Double> = 0.45...0.7
    static let shortLineNuclei = 2
    /// Each whole content word and spell unit a line offers adds this to its rank value, up to the cap.
    static let choppabilityWeight: Float = 0.02
    static let choppabilityCap = 6
    static let singleCutFactor: Float = 0.5
    /// A word splits into syllables only at this weight (a lexicon word, not a name: "Mi-" of "Miliaris,"
    /// was heard as nothing), into at most this many.
    static let syllableSplitWeight: Float = 0.7
    static let maximumSyllableUnits = 4
    static let minimumSyllableShare = 0.3
}

/// One playable cut of the motif line.
nonisolated struct DialogueMotifFragment: Sendable, Equatable {
    /// `half`: a split of a piece at a real dip (no transcript); `syllable`: a syllable of a salient
    /// multi-syllable word; `letter`: a letter of an initialism (D130).
    enum Kind: String, Sendable { case line, piece, half, syllable, letter }
    /// A transcript word inside the fragment: its voiced core (source frames) and weight.
    struct Word: Sendable, Equatable {
        let frames: Range<Int>
        let weight: Float
    }
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
    /// Source frames inside the fragment where a gate may close cleanly: its word ends with a
    /// transcript, its real dips without one (D130; before, any syllable valley, D126).
    var cutPoints: [Int] = []
    /// The transcript words the fragment overlaps (empty without a transcript).
    var words: [Word] = []
    /// The loudest 1 ms level inside the fragment (the acoustic "still sounding" test, D130).
    var peakLevel: Float = 0
    /// A split unit: the end of the source frames is the next unit's start, so the unit's own end is a
    /// syllable or letter boundary by design.
    var isUnit: Bool { kind == .half || kind == .syllable || kind == .letter }

    /// The word core `frame` lies inside by more than `wordCoreToleranceSeconds`, if any.
    func word(containing frame: Int, rate: Double, contentOnly: Bool = false) -> Word? {
        let tolerance = Int(DialogueMotifTuning.wordCoreToleranceSeconds * rate)
        return words.first { (!contentOnly || $0.weight > 0) && $0.frames.lowerBound + tolerance < frame && frame < $0.frames.upperBound - tolerance }
    }
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
        var fragment: Int
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
    /// The beat the loop was arranged at (D130: a hit takes a cut that fits the steps before the next one).
    var beatDuration: Double = 0
    /// One linked speed/pitch transform per source line; source frame coordinates stay native.
    var transform: DialogueTransform = .native
    /// Previous loop shape, retained through same-loop transcript revisions.
    var priorCells: [DialogueMotifCell] = []

    var line: DialogueMotifFragment { fragments[0] }
    /// The chop beat's and build's feel (D127; the grid's own swing for motifs without an arc).
    var feel: DialogueFeel { DialogueFeel.variants[min(max(0, arc?.feel ?? 0), DialogueFeel.variants.count - 1)] }
    var sampleRate: Double { source.sampleRate }
    var playbackSampleRate: Double { sampleRate * transform.playbackRate }
    func seconds(_ id: Int) -> Double { Double(fragments[id].frames.count) / playbackSampleRate }
    func accentOffset(_ id: Int) -> Double { Double(fragments[id].accentFrame - fragments[id].frames.lowerBound) / playbackSampleRate }
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
                                    seed: loopSeed, lineSeconds: seconds(0), sampleRate: playbackSampleRate,
                                    hookSeed: memory.cycleSeed ?? seed, loop: loop, avoidTemplate: hook?.template,
                                    drums: drums, avoidArc: arc, carried: true, beatDuration: beatDuration, avoidCells: cells)
        return DialogueMotif(loop: loop, source: source, analysis: analysis, lineUnit: lineUnit, lineKey: lineKey,
                             fragments: fragments, pieces: pieces, halves: halves, bank: bank, usedTranscript: usedTranscript,
                             reorderAllowed: reorderAllowed, cells: arranged.cells, carried: true, seed: loopSeed, interest: interest,
                             hook: arranged.hook, renders: renders, arc: arranged.arc, priorArc: arc, beatDuration: beatDuration, transform: transform, priorCells: cells)
    }

    /// Chooses the best line (or `line` when given), cuts it into pieces and arranges the loop.
    static func make(loop: Int, source: DialogueSource, analysis: DialogueAnalysis, transcript: DialogueTranscript?,
                     memory: DialoguePerformanceMemory, seed: UInt64, beatDuration: Double, line wanted: Int? = nil,
                     recycle: Bool = false, minimumInterest: Float = 0, transcribedOnly: Bool = false,
                     recutOf previous: DialogueMotif? = nil, drums: DialogueMotifDrums = .boomBap,
                     transform overrideTransform: DialogueTransform? = nil) -> DialogueMotif? {
        guard let f = analysis.features, !analysis.units.isEmpty, analysis.contentID == source.contentID,
              let samples = source.buffer.floatChannelData?[0] else { return nil }
        var units = analysis.units
        var rejections = analysis.rejections
        var words: [DialogueWordSpan] = []
        if let transcript {
            let refined = DialogueHierarchy.refine(analysis, transcript: transcript)
            units = refined.units
            rejections = refined.rejections
            // A transcript that transcribed no unit changes nothing (D130's word rules included).
            words = refined.units.contains { $0.text != nil } ? refined.words : []
        }
        let rate = analysis.sampleRate
        let maximum = min(DialogueMotifTuning.lineSeconds.upperBound, DialogueMotifTuning.lineMaximumBars * 4 * beatDuration)
        let salience = DialogueLineInterest.wordSalience(words)
        let weights = salience.map(\.weight)
        let line: SpeechUnit
        if let wanted, let unit = units.first(where: { $0.id == wanted }) {
            line = unit
        } else {
            let ranked = rankLines(units: units, rejections: rejections, rate: rate, maximum: maximum, words: words, weights: weights,
                                   salience: salience)
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
                // leader, so a striking line is not a coin flip against a plain one (D124), and (D130
                // stage 2) only lines within `linePoolInterest` of the most interesting unplayed line: a
                // striking line is no longer passed over for a plain one that sounds cleaner.
                let topInterest = fresh.map(\.interest).max() ?? 0
                let close = fresh.filter { $0.interest >= topInterest - DialogueMotifTuning.linePoolInterest - 1e-6 }
                let leader = close.first?.value ?? 0
                let pool = Array(close.prefix(DialogueMotifTuning.linePool).filter { $0.value >= DialogueMotifTuning.linePoolShare * leader })
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
        var cutter = DialogueMotifCutter(f: f, samples: samples, count: count, rate: rate)
        guard let cut = cutter.cut(line, words: lineWords, weights: lineIndices.map { weights.indices.contains($0) ? weights[$0] : 0 },
                                   salience: lineIndices.map { salience[$0] }) else { return nil }
        // Fragment weights: the strongest word inside each cut (the hook layer's signature piece); a
        // syllable or letter carries its word's weight.
        var fragments = cut.fragments
        if !lineIndices.isEmpty {
            for k in fragments.indices {
                let frames = fragments[k].frames
                // D130 stage 2: a word counts when the fragment holds its middle or most of it ("dead" of
                // "Here's a dead" weighed nothing when the cut sat just before its middle).
                let inside = lineIndices.filter { k in
                    let w = words[k].frames
                    let overlap = max(0, min(w.upperBound, frames.upperBound) - max(w.lowerBound, frames.lowerBound))
                    return frames.contains((w.lowerBound + w.upperBound) / 2) || 2 * overlap >= w.count
                }
                let overlapping = lineIndices.filter { words[$0].frames.overlaps(frames) }
                fragments[k].weight = (inside.isEmpty && fragments[k].isUnit ? overlapping : inside).map { weights[$0] }.max() ?? 0
            }
        }
        let lineInterest = interest(of: line, words: words, weights: weights, salience: salience)
        let reorderAllowed = lineWords.count < 2 || DialogueReorderGuard.allowsPieceReorder(lineWords.map(\.text))
        // A re-cut keeps the loop's seeded choices (the breakdown cell).
        let loopSeed = previous?.seed ?? (seed ^ UInt64(bitPattern: Int64(loop)) &* 0x9E37_79B9)
        // A transcript re-cut keeps the hook: the new signature and response are the pieces that
        // overlap the old ones most.
        let anchors = previous?.hook.map { [previous!.fragments[$0.signature].frames, previous!.fragments[$0.response].frames] } ?? []
        // A re-cut keeps the arc; a new line avoids the previous loop's arc (or, replacing a carried
        // line inside its loop, the arc that one avoided).
        let prior = previous?.priorArc ?? memory.motif.flatMap { $0.loop == loop ? $0.priorArc : $0.arc }
        let transform = previous?.transform ?? overrideTransform ?? DialogueVarispeed.transform(line: line, features: f, sampleRate: rate, beatDuration: beatDuration)
        let playbackSampleRate = rate * transform.playbackRate
        let priorCells = previous?.priorCells ?? memory.motif.map { $0.loop == loop ? $0.priorCells : $0.cells } ?? []
        // Measure every cut once, including repair candidates and units a later carried-loop
        // arrangement may choose. Those loops can reuse the converted buffers and measured attacks.
        let rendered = renderedAccents(fragments, line: line, source: source, analysis: analysis, transform: transform)
        fragments = rendered.fragments
        // Room and pickup decisions use exactly the rendered attacks the performer schedules.
        let arranged = arrange(fragments: fragments, pieces: cut.pieces, halves: cut.halves, reorderAllowed: reorderAllowed,
                               seed: loopSeed, lineSeconds: Double(line.frames.count) / playbackSampleRate, sampleRate: playbackSampleRate,
                               hookSeed: memory.cycleSeed ?? seed, loop: loop, anchors: anchors, drums: drums,
                               keepArc: previous?.arc, avoidArc: prior, beatDuration: beatDuration, avoidCells: priorCells)
        let key = lineKey(analysis.contentID, line.frames)
        let bank = motifBank(fragments, line: line, analysis: analysis, key: key, usedTranscript: lineWords.count >= 2, transform: transform)
        return DialogueMotif(loop: loop, source: source, analysis: analysis, lineUnit: line.id, lineKey: key,
                             fragments: fragments, pieces: cut.pieces, halves: cut.halves, bank: bank,
                             usedTranscript: lineWords.count >= 2, reorderAllowed: reorderAllowed, cells: arranged.cells,
                             carried: false, seed: loopSeed, interest: lineInterest, hook: arranged.hook, renders: rendered.renders,
                             arc: arranged.arc, priorArc: prior, beatDuration: beatDuration, transform: transform, priorCells: priorCells)
    }

    /// A line's words for the said-once rule: lowercased letters, digits and spaces.
    static func spokenText(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    /// A line's interest: from its words when it has text; without text `acousticInterest` when the cue
    /// has no transcript, else `untextedInterest` (D130: an untexted unit led a quarter of the transcribed
    /// loops over plain transcribed lines, and its pieces were cut with no word boundaries).
    static func interest(of u: SpeechUnit, words: [DialogueWordSpan], weights: [Float],
                         salience: [DialogueLineInterest.WordSalience]? = nil) -> Float {
        guard u.text != nil, let r = u.tokenRange, r.lowerBound >= 0, r.upperBound <= words.count, weights.count == words.count,
              !r.isEmpty else { return words.isEmpty ? DialogueMotifTuning.acousticInterest : DialogueMotifTuning.untextedInterest }
        let x = salience.flatMap { $0.count == words.count ? $0[r] : nil }
        return DialogueLineInterest.interest(words: words[r], weights: weights[r], text: u.text, salience: x)
    }

    /// The highest word weight of a transcribed unit (0 without text).
    static func peakWeight(of u: SpeechUnit, weights: [Float]) -> Float {
        guard u.text != nil, let r = u.tokenRange, r.lowerBound >= 0, r.upperBound <= weights.count, !r.isEmpty else { return 0 }
        return weights[r].max() ?? 0
    }

    /// How many whole content cuts and spell units a transcribed unit offers the chop beat (D130 stage 2):
    /// its content words, plus the letters of its initialisms and the syllables of its salient words.
    static func choppability(of u: SpeechUnit, salience: [DialogueLineInterest.WordSalience]) -> Int {
        guard u.text != nil, let r = u.tokenRange, r.lowerBound >= 0, r.upperBound <= salience.count else { return 0 }
        return salience[r].reduce(0) { n, x in
            guard x.weight > 0 else { return n }
            if x.kind == .initialism, let letters = x.letters, letters.count >= 2 { return n + 1 + min(letters.count, DialogueMotifTuning.maximumUnits) }
            if x.weight >= DialogueMotifTuning.syllableSplitWeight, x.kind == .lexicon, x.syllables >= 2 {
                return n + 1 + min(x.syllables, DialogueMotifTuning.maximumSyllableUnits)
            }
            return n + 1
        }
    }

    /// A transcribed line's rank value inside its tier (D130 stage 2): compressed sound times `base` (fit,
    /// length and the transcript bonus) times `(0.2 + 0.8 interest)^2`, plus the capped choppability term.
    static func lineValue(sound: Float, base: Float, interest: Float, choppability: Int) -> Float {
        let i = 0.2 + 0.8 * interest
        let chop = Float(min(DialogueMotifTuning.choppabilityCap, choppability))
        // A line with one content word and nothing to spell gives the chop beat one cut to repeat ("So
        // drugged," played eleven times in a row): it ranks lower inside its tier.
        let single: Float = choppability <= 1 ? DialogueMotifTuning.singleCutFactor : 1
        return sqrtf(max(0, sound)) * base * i * i * (1 + DialogueMotifTuning.choppabilityWeight * chop) * single
    }

    /// The rank tier of a line's interest: striking, not plain, plain (D130 stage 2: interest sorts first).
    static func tier(_ interest: Float) -> Int {
        interest >= DialogueMotifTuning.strikingInterest - 1e-6 ? 2 : (interest >= DialogueMotifTuning.plainInterest - 1e-6 ? 1 : 0)
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

    /// Whole lines in rank order with their values. D130 stage 2: by interest tier first (striking, then
    /// not plain, then plain), then by a value in which interest outweighs sound: with a transcript the
    /// sound is compressed (its square root) and interest enters as `(0.2 + 0.8 interest)^2`, with a
    /// small capped term for how many whole words and spell units the line offers. Without any transcript
    /// every line has the same interest, so the order is the acoustic one of before (sound, fit, length).
    /// `weights` are `DialogueLineInterest.wordWeights(words)`.
    static func rankLines(units: [SpeechUnit], rejections: [DialogueRejection], rate: Double, maximum: Double,
                          words: [DialogueWordSpan], weights: [Float], salience: [DialogueLineInterest.WordSalience]? = nil) -> [RankedLine] {
        let rejected = Dictionary(rejections.map { ($0.unit, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let salience = salience ?? (words.isEmpty ? [] : DialogueLineInterest.wordSalience(words))
        let weights = weights.count == words.count ? weights : salience.map(\.weight)
        // A short striking line ("LSD.", "psilocybin") may be a line on two nuclei (D130 stage 2).
        func striking(_ u: SpeechUnit) -> Bool { peakWeight(of: u, weights: weights) >= DialogueMotifTuning.shortLineWeight }
        let lines = units.filter {
            [.utterance, .phrase, .wordGroup].contains($0.level) && rejected[$0.id] == nil
                && $0.score.sound >= DialogueTuning.minimumPadSound
                && ($0.nuclei >= DialogueMotifTuning.lineMinimumNuclei || ($0.nuclei >= DialogueMotifTuning.shortLineNuclei && striking($0)))
        }
        var interests: [Int: Float] = [:]
        for u in lines { interests[u.id] = interest(of: u, words: words, weights: weights, salience: salience) }
        let worded = !words.isEmpty
        func value(_ u: SpeechUnit) -> Float {
            let interest = interests[u.id] ?? DialogueMotifTuning.acousticInterest
            let d = u.seconds(rate)
            let length = d <= DialogueMotifTuning.preferredLineSeconds ? 1
                : max(0.8, 1 - 0.2 * Float((d - DialogueMotifTuning.preferredLineSeconds) / (DialogueMotifTuning.lineSeconds.upperBound - DialogueMotifTuning.preferredLineSeconds)))
            let base = DialogueBankBuilder.lineFit(u, units: units, rejected: rejected) * length
                * (u.text != nil ? DialogueMotifTuning.transcribedLineBonus : 1)
            guard worded else {
                return u.score.sound * base * (DialogueMotifTuning.interestFloor + (1 - DialogueMotifTuning.interestFloor) * interest)
            }
            return lineValue(sound: u.score.sound, base: base, interest: interest, choppability: choppability(of: u, salience: salience))
        }
        func within(_ r: ClosedRange<Double>, _ keep: (SpeechUnit) -> Bool = { _ in true }) -> [RankedLine] {
            lines.filter { r.contains($0.seconds(rate)) && $0.seconds(rate) <= maximum && keep($0) }
                .map { RankedLine(unit: $0, value: value($0), interest: interests[$0.id] ?? DialogueMotifTuning.acousticInterest) }
        }
        let preferred = within(DialogueMotifTuning.lineSeconds)
        var seen = Set(preferred.map(\.unit.id))
        let relaxed = within(DialogueMotifTuning.relaxedLineSeconds).filter { seen.insert($0.unit.id).inserted }
        let short = within(DialogueMotifTuning.shortLineSeconds, striking).filter { seen.insert($0.unit.id).inserted }
        // Tier first, then preferred lengths before relaxed and short ones, then value.
        func key(_ l: RankedLine, _ band: Int) -> (Int, Float, Int) { (tier(l.interest), l.value, -l.unit.id) }
        let all = preferred.map { ($0, 2) } + relaxed.map { ($0, 1) } + short.map { ($0, 0) }
        return all.sorted { key($0.0, $0.1) > key($1.0, $1.1) }.map(\.0)
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
                          usedTranscript: Bool, transform: DialogueTransform = .native) -> DialoguePadBank {
        let pads = fragments.map { pad($0, line: line, analysis: analysis, transform: transform) }
        var hash = DialogueHash()
        hash.add(key)
        hash.add(analysis.version)
        hash.add(transform.playbackRate.bitPattern)
        for fr in fragments { hash.add(fr.frames.lowerBound); hash.add(fr.frames.upperBound) }
        let ids = [line.id]
        return DialoguePadBank(bankID: hash.value, analysisVersion: analysis.version, pads: pads, anchorPadID: 0, siblingGroups: [],
                               sourceID: analysis.contentID, clock: analysis.clock, rejections: [], usedTranscript: usedTranscript,
                               reorder: .sourceOrder, originalOrder: ids, arrangedOrder: ids, intendedText: line.text)
    }

    /// One fragment as a motif-bank pad.
    static func pad(_ fr: DialogueMotifFragment, line: SpeechUnit, analysis: DialogueAnalysis, transform: DialogueTransform = .native) -> DialoguePad {
        let rate = analysis.sampleRate
        let role: DialoguePad.Role = fr.kind == .line ? .anchor : .stab
        return DialoguePad(padID: fr.id, unitID: fr.kind == .line ? line.id : -1 - fr.id, role: role, frames: fr.frames,
                           transform: transform, accentOffset: Double(fr.accentFrame - fr.frames.lowerBound) / rate,
                           duration: Double(fr.frames.count) / (rate * transform.playbackRate), protected: fr.kind == .line, text: fr.text,
                           fadeIn: fr.fadeIn, fadeOut: fr.fadeOut,
                           level: fr.kind == .line ? line.level : (fr.kind == .piece ? .wordGroup : .stab),
                           score: line.score,
                           padKey: DialogueHash.padKey(sourceID: analysis.contentID, frames: fr.frames, transform: transform))
    }

    /// Accents read on the rendered pads (D126): the chop chain's 4:1 compressor (13 dB under the
    /// cut's peak) lifts a soft onset, so its rendered attack comes earlier than the source's, by
    /// 20 ms and more on a breathy "h" or "s" (a transcribed capture's signature pad read -23 ms).
    /// Every gate of a pad is a truncation of the same render, so the full pad's attack is every
    /// hit's attack. A rendered beat further than `renderedAccentRange` from the source one keeps
    /// the source one.
    static func renderedAccents(_ fragments: [DialogueMotifFragment], line: SpeechUnit, source: DialogueSource,
                                analysis: DialogueAnalysis, only: Set<Int>? = nil, transform: DialogueTransform = .native) -> (fragments: [DialogueMotifFragment], renders: [Int: AVAudioPCMBuffer]) {
        var renders: [Int: AVAudioPCMBuffer] = [:]
        let out = fragments.map { fr -> DialogueMotifFragment in
            if let only, !only.contains(fr.id) { return fr }
            var level: Float?
            guard let buffer = DialogueChopRenderer.renderPad(pad(fr, line: line, analysis: analysis, transform: transform), source: source,
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
            let beat = fr.frames.lowerBound + Int((Double(attack.beatFrame) * transform.playbackRate).rounded())
            let range = DialogueMotifTuning.renderedAccentRange
            // At native rate the bound rejects a different syllable picked by levelling. Linked
            // playback can change which rise survives the spectral chain: its rendered attack is
            // authoritative, even when it moved farther than the native-only correction window.
            let correction = Double(beat - fr.accentFrame) / (rate * transform.playbackRate)
            guard attack.beatFrame > 0, beat < fr.frames.upperBound,
                  !transform.isNative || range.contains(correction) else { return fr }
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
            "interest": r3(Double(interest)), "playbackRate": transform.playbackRate,
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

/// Splits a line into word-group pieces, each with a content word, cut only at real dips, and splits a
/// salient word into its syllables or an initialism into its letters (plan 5, motif; D130).
nonisolated struct DialogueMotifCutter {
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

    /// The loudest 1 ms level inside `range`, in dB.
    func peakDB(_ range: Range<Int>) -> Float {
        let lo = f.fineIndex(frame: max(0, range.lowerBound)), hi = f.fineIndex(frame: max(range.lowerBound, range.upperBound - 1))
        return dB(hi >= lo ? (f.fine[lo...hi].max() ?? 0) : level(range.lowerBound))
    }

    /// The time the 1 ms envelope stays within 3 dB of its level at `frame`, inside `bounds`.
    func quietRun(_ frame: Int, bounds: Range<Int>) -> Double {
        let floor = dB(level(frame)) + 3
        let lo = f.fineIndex(frame: bounds.lowerBound), hi = f.fineIndex(frame: max(bounds.lowerBound, bounds.upperBound - 1))
        var a = f.fineIndex(frame: frame), b = a
        while a > lo, dB(f.fine[a - 1]) <= floor { a -= 1 }
        while b < hi, dB(f.fine[b + 1]) <= floor { b += 1 }
        return Double((b - a + 1) * f.fineHop) / rate
    }

    /// A real dip between two sounds (D130): `realDipDB` under the lower neighbouring peak, or a quiet
    /// run of `realDipRunSeconds` at least `realDipRunDB` under it. A syllable dip inside a
    /// co-articulated word is neither.
    static func isRealDip(depth: Float, run: Double) -> Bool {
        depth >= DialogueMotifTuning.realDipDB
            || (run >= DialogueMotifTuning.realDipRunSeconds && depth >= DialogueMotifTuning.realDipRunDB)
    }

    /// A real dip without a transcript. A stricter rule (12 dB for 25 ms, or a 60 ms pause) halved the
    /// acoustic plan's hits and left bars empty on the cached films (salience probe, 23 November 2026).
    static func isAcousticGap(depth: Float, run: Double) -> Bool { isRealDip(depth: depth, run: run) }

    /// The zero crossing nearest `frame` within 2 ms, inside `bounds`.
    func zero(_ frame: Int, bounds: Range<Int>) -> Int {
        let z = frames(DialogueMotifTuning.zeroCrossingSeconds)
        var best = frame, distance = Int.max
        let lo = max(max(1, bounds.lowerBound), frame - z), hi = min(min(count, bounds.upperBound), frame + z)
        guard hi > lo else { return frame }
        for i in lo..<hi where (samples[i - 1] <= 0) != (samples[i] <= 0) {
            if abs(i - frame) < distance { distance = abs(i - frame); best = i }
        }
        return best
    }

    /// The boundary between two neighbouring words: the quietest frame between their cores, searched
    /// only `wordTimingSeconds` into each word (never past its middle), how deep it dips under the
    /// quieter word's peak, and whether that is a real dip.
    func boundary(_ a: DialogueWordSpan, _ b: DialogueWordSpan) -> (frame: Int, depth: Float, real: Bool) {
        let slack = frames(DialogueMotifTuning.wordTimingSeconds)
        let midA = (a.frames.lowerBound + a.frames.upperBound) / 2, midB = (b.frames.lowerBound + b.frames.upperBound) / 2
        let lo = max(midA, min(a.frames.upperBound, b.frames.lowerBound) - slack)
        let hi = min(midB, max(b.frames.lowerBound, a.frames.upperBound) + slack)
        guard hi > lo + 1 else { return ((a.frames.upperBound + b.frames.lowerBound) / 2, 0, false) }
        let q = quietest(lo..<hi)
        let depth = min(peakDB(a.frames), peakDB(b.frames)) - dB(level(q))
        let real = Self.isRealDip(depth: depth, run: quietRun(q, bounds: lo..<hi))
        return (zero(q, bounds: lo..<hi), depth, real)
    }

    /// Word groups that each carry a content word (D130): a function word rides with the next content
    /// word, or the previous one when a pause of `groupPauseSeconds` follows it (the largest pause of a
    /// run of function words decides) or the line ends; a group shorter than `groupJoinSeconds` takes
    /// its neighbour while it stays within `groupWordLimit` words and `groupMaximumSeconds`. A line of
    /// function words only groups by length as before.
    static func wordGroups(_ words: [DialogueWordSpan], weights: [Float], rate: Double) -> [[Int]] {
        let n = words.count
        guard n > 0 else { return [] }
        func pause(_ i: Int) -> Double {
            i + 1 < n ? Double(words[i + 1].frames.lowerBound - words[i].frames.upperBound) / rate : .infinity
        }
        func length(_ g: [Int]) -> Double { Double(words[g.last!].frames.upperBound - words[g.first!].frames.lowerBound) / rate }
        var head = (0..<n).map { weights.indices.contains($0) && weights[$0] > 0 ? $0 : -1 }
        var groups: [[Int]] = []
        if head.allSatisfy({ $0 < 0 }) {
            groups = [[0]]
            for i in 1..<n {
                let g = groups[groups.count - 1]
                if length(g) < DialogueMotifTuning.groupJoinSeconds, g.count < DialogueMotifTuning.groupMaximumWords,
                   pause(g.last!) < DialogueMotifTuning.groupPauseSeconds {
                    groups[groups.count - 1].append(i)
                } else {
                    groups.append([i])
                }
            }
            return groups
        }
        var i = 0
        while i < n {
            guard head[i] < 0 else { i += 1; continue }
            var j = i
            while j < n, head[j] < 0 { j += 1 }
            // Function words i..<j between content words i - 1 and j: the ones before the largest
            // pause (when it is a real pause) ride back, the rest forward.
            let split: Int
            if i == 0 { split = 0 } else if j == n { split = n } else {
                let widest = ((i - 1)..<j).max { pause($0) < pause($1) }!
                split = pause(widest) >= DialogueMotifTuning.groupPauseSeconds ? widest + 1 : i
            }
            for k in i..<j { head[k] = k < split ? head[i - 1] : j }
            i = j
        }
        for k in 0..<n {
            if let last = groups.last, head[last.last!] == head[k] { groups[groups.count - 1].append(k) } else { groups.append([k]) }
        }
        // A group past the limits keeps its content word with up to `groupWordLimit` words around it
        // (the word before it first: "of LSD"); the function words left over group by length.
        func lengthGroups(_ run: [Int]) -> [[Int]] {
            var out: [[Int]] = []
            for i in run {
                if let g = out.last, length(g) < DialogueMotifTuning.groupJoinSeconds, g.count < DialogueMotifTuning.groupMaximumWords,
                   pause(g.last!) < DialogueMotifTuning.groupPauseSeconds {
                    out[out.count - 1].append(i)
                } else {
                    out.append([i])
                }
            }
            return out
        }
        groups = groups.flatMap { g -> [[Int]] in
            guard g.count > DialogueMotifTuning.groupWordLimit || (g.count > 1 && length(g) > DialogueMotifTuning.groupMaximumSeconds),
                  let c = g.first(where: { head[$0] == $0 }) else { return [g] }
            var lo = c, hi = c
            func fitsWindow(_ a: Int, _ b: Int) -> Bool {
                b - a + 1 <= DialogueMotifTuning.groupWordLimit && length(Array(a...b)) <= DialogueMotifTuning.groupMaximumSeconds
            }
            var grew = true
            while grew {
                grew = false
                if lo > g.first!, pause(lo - 1) < DialogueMotifTuning.groupPauseSeconds, fitsWindow(lo - 1, hi) { lo -= 1; grew = true }
                if hi < g.last!, pause(hi) < DialogueMotifTuning.groupPauseSeconds, fitsWindow(lo, hi + 1) { hi += 1; grew = true }
            }
            let before = g.filter { $0 < lo }, after = g.filter { $0 > hi }
            return (before.isEmpty ? [] : lengthGroups(before)) + [Array(lo...hi)] + (after.isEmpty ? [] : lengthGroups(after))
        }
        // Short groups join a neighbour (the next one first) inside the limits.
        // A group of function words only may join up to `mergedPieceSeconds` (better a long piece than a
        // connective one); two content groups up to `groupMaximumSeconds`.
        func joinable(_ a: [Int], _ b: [Int]) -> Bool {
            let connective = a.allSatisfy { head[$0] != $0 } || b.allSatisfy { head[$0] != $0 }
            return a.count + b.count <= DialogueMotifTuning.groupWordLimit + (connective ? 1 : 0)
                && length(a + b) <= (connective ? DialogueMotifTuning.mergedPieceSeconds : DialogueMotifTuning.groupMaximumSeconds)
                && pause(a.last!) < DialogueMotifTuning.groupPauseSeconds
        }
        var k = 0
        while k < groups.count {
            if length(groups[k]) < DialogueMotifTuning.groupJoinSeconds || groups[k].allSatisfy({ head[$0] != $0 }) {
                if k + 1 < groups.count, joinable(groups[k], groups[k + 1]) {
                    let next = groups.remove(at: k + 1)
                    groups[k] += next
                    continue
                }
                if k > 0, joinable(groups[k - 1], groups[k]) {
                    let this = groups.remove(at: k)
                    groups[k - 1] += this
                    k -= 1
                    continue
                }
            }
            k += 1
        }
        let runs = DialogueLineInterest.spelledRuns(words.map(\.text))
        var merged: [[Int]] = []
        for group in groups {
            if let previous = merged.last, let a = previous.last, let b = group.first,
               runs.contains(a), runs.contains(b), b == a + 1 {
                merged[merged.count - 1] += group
            } else { merged.append(group) }
        }
        return merged
    }

    /// The vowel groups of a word, counting a silent final "e" out: "psilocybin" 4, "trip" 1, "frogs" 1.
    static func textSyllables(_ word: String) -> Int { syllableSpans(word).count }

    private static func syllableSpans(_ word: String) -> [Range<Int>] {
        let letters = Array(word.lowercased().filter(\.isLetter))
        func vowel(_ c: Character) -> Bool { "aeiouy".contains(c) }
        var groups: [Range<Int>] = []
        var k = 0
        while k < letters.count {
            if vowel(letters[k]) {
                var e = k
                while e < letters.count, vowel(letters[e]) { e += 1 }
                groups.append(k..<e)
                k = e
            } else { k += 1 }
        }
        if groups.count > 1, let last = groups.last, last.count == 1, letters[last.lowerBound] == "e",
           last.upperBound == letters.count, letters.count >= 3, !(letters[letters.count - 2] == "l" && !vowel(letters[letters.count - 3])) {
            groups.removeLast()
        }
        return groups
    }

    /// A word's text in `count` syllable parts, hyphenated ("psi-", "-lo-", "-cy-", "-bin").
    static func syllableTexts(_ word: String, count: Int) -> [String] {
        let letters = Array(word)
        let index = letters.indices.filter { letters[$0].isLetter }
        let groups = syllableSpans(word)
        guard count >= 2, groups.count >= 2, !index.isEmpty else { return [word] }
        // Letter positions where a syllable starts: before the last consonant between two vowel groups.
        var starts: [Int] = []
        for (a, b) in zip(groups, groups.dropFirst()) {
            let consonants = b.lowerBound - a.upperBound
            starts.append(consonants <= 1 ? a.upperBound : a.upperBound + 1)
        }
        // Keep `count - 1` evenly spread starts.
        let picked = (1..<count).map { starts[min(starts.count - 1, ($0 * starts.count) / count)] }
        var parts: [String] = []
        var from = 0
        for s in Array(Set(picked)).sorted() + [index.count] where s > from {
            let lo = index[from], hi = s < index.count ? index[s] : letters.count
            parts.append(String(letters[lo..<hi]))
            from = s
        }
        guard parts.count >= 2 else { return [word] }
        return parts.enumerated().map { k, p in (k > 0 ? "-" : "") + p + (k < parts.count - 1 ? "-" : "") }
    }

    /// The letters of an initialism ("LSD", "UFO.", "U.F.O.", "TV"), else nil.
    static func initialism(_ raw: String) -> String? {
        let letters = raw.filter(\.isLetter)
        guard (2...5).contains(letters.count), letters.allSatisfy(\.isUppercase), letters != "OK",
              raw.allSatisfy({ $0.isLetter || ".,!?;:'\u{2019}-".contains($0) }) else { return nil }
        return String(letters)
    }

    /// The spell units of a salient word inside `r` (D130): an initialism's letters when it has one
    /// nucleus per letter, a salient multi-syllable word's syllables at the valleys between its nuclei;
    /// a spelled run of letter tokens ("D M T") by its tokens. The heaviest such word of the range (the
    /// later one on ties). Nil when none splits.
    func spellUnits(_ r: Range<Int>, words: [DialogueWordSpan], weights: [Float],
                    salience: [DialogueLineInterest.WordSalience]) -> (units: [(frames: Range<Int>, text: String?)], kind: DialogueMotifFragment.Kind)? {
        let leastUnit = frames(DialogueMotifTuning.minimumUnitSeconds)
        var best: (weight: Float, units: [(frames: Range<Int>, text: String?)], kind: DialogueMotifFragment.Kind)?
        func mid(_ w: DialogueWordSpan) -> Int { (w.frames.lowerBound + w.frames.upperBound) / 2 }
        func letters(_ k: Int) -> String? {
            salience.indices.contains(k) ? salience[k].letters : Self.initialism(words[k].text)
        }
        // A spelled run of single-letter tokens inside the range: one unit per token, cut at the boundaries between them.
        var k = 0
        while k < words.count {
            guard let l = letters(k), l.count == 1, r.contains(mid(words[k])) else { k += 1; continue }
            var j = k
            while j < words.count, letters(j)?.count == 1, r.contains(mid(words[j])) { j += 1 }
            if j - k >= 2, j - k <= DialogueMotifTuning.maximumUnits + 1 {
                var bounds = [max(r.lowerBound, words[k].frames.lowerBound)]
                for i in k..<(j - 1) { bounds.append(boundary(words[i], words[i + 1]).frame) }
                bounds.append(min(r.upperBound, words[j - 1].frames.upperBound))
                if zip(bounds, bounds.dropFirst()).allSatisfy({ $1 - $0 >= leastUnit }) {
                    let units = (k..<j).enumerated().map { (n, i) in (frames: bounds[n]..<bounds[n + 1], text: Optional(words[i].text)) }
                    let w = weights[k..<j].max() ?? 0
                    if best == nil || w >= best!.weight { best = (w, units, .letter) }
                }
            }
            k = j
        }
        for k in words.indices where weights[k] >= DialogueMotifTuning.syllableWeight && r.contains(mid(words[k])) {
            let w = words[k]
            guard !DialogueLineInterest.functionWords.contains(DialogueLineInterest.normalize(w.text)) else { continue }
            let core = max(w.frames.lowerBound, r.lowerBound)..<min(w.frames.upperBound, r.upperBound)
            let inner = valleys(core)
            let n = nuclei(core).count
            var cutFrames: [Int] = []
            var parts: [String] = []
            let unitKind: DialogueMotifFragment.Kind
            if let l = letters(k) {
                guard l.count >= 2, n == l.count, inner.count == n - 1 else { continue }
                cutFrames = inner.map(\.frame)
                parts = l.map(String.init)
                unitKind = .letter
            } else {
                // D130 stage 2: only a lexicon-strong word ("psilocybin", "mescaline"), never a name or a plain
                // noun, and in at most `maximumSyllableUnits` so each syllable still says some of the word.
                guard weights[k] >= DialogueMotifTuning.syllableSplitWeight,
                      salience.isEmpty || salience[k].kind != .initialism else { continue }
                let syllables = Self.textSyllables(w.text)
                // Each syllable keeps at least `minimumSyllableShare` of the word, so it still says some of it:
                // fewer, longer syllables when the deepest valleys leave a sliver.
                var units = min(syllables, n, DialogueMotifTuning.maximumSyllableUnits)
                guard syllables >= 2, units >= 2, inner.count >= units - 1 else { continue }
                let share = Int(DialogueMotifTuning.minimumSyllableShare * Double(core.count))
                while units >= 2 {
                    let c = inner.sorted { $0.depth > $1.depth }.prefix(units - 1).map(\.frame).sorted()
                    let edges = [core.lowerBound] + c + [core.upperBound]
                    if zip(edges, edges.dropFirst()).allSatisfy({ $1 - $0 >= share }) { cutFrames = c; break }
                    units -= 1
                }
                guard units >= 2, !cutFrames.isEmpty else { continue }
                parts = Self.syllableTexts(w.text, count: units)
                unitKind = .syllable
            }
            let bounds = [core.lowerBound] + cutFrames.sorted().map { zero($0, bounds: core) } + [core.upperBound]
            guard zip(bounds, bounds.dropFirst()).allSatisfy({ $1 - $0 >= leastUnit }) else { continue }
            let ranges = zip(bounds, bounds.dropFirst()).map { $0..<$1 }
            let candidate = ranges.enumerated().map { (frames: $1, text: parts.count == ranges.count ? Optional(parts[$0]) : nil) }
            // The heaviest such word of the piece; the later one on ties (the sentence stress).
            if best == nil || weights[k] >= best!.weight { best = (weights[k], candidate, unitKind) }
        }
        return best.map { ($0.units, $0.kind) }
    }

    mutating func cut(_ line: SpeechUnit, words: [DialogueWordSpan], weights: [Float],
                      salience: [DialogueLineInterest.WordSalience] = []) -> Result? {
        let span = line.frames
        let minimum = frames(DialogueMotifTuning.minimumCutSeconds)
        var cuts: [Int] = []
        var texts: [String?] = []
        let weights = words.indices.map { weights.indices.contains($0) ? weights[$0] : 0 }
        let salience = salience.count == words.count ? salience : []
        // D130 stage 2: a line that is one salient word, or one word group around one, stays one piece when
        // that piece spells (letters or syllables): "LSD." is "L", "S", "D" and the word, never "of" | "LSD.".
        var single = false
        if !words.isEmpty, spellUnits(span, words: words, weights: weights, salience: salience) != nil {
            single = words.count == 1 || Self.wordGroups(words, weights: weights, rate: rate).count == 1
        }
        // One word of a transcribed line is never cut by the acoustic valleys (they split "LSD," in two): it
        // is one piece. An untexted unit that overlaps one word keeps the acoustic cut.
        if words.count == 1, line.text != nil { single = true }
        // A one-group line splits at its deepest word boundary that leaves a content word on both sides (a
        // line needs two pieces); D130 stage 2: with no such boundary ("you find", "on its back,") it stays
        // one piece rather than leave a connective one ("you" | "find").
        var groups = words.count >= 2 && !single ? Self.wordGroups(words, weights: weights, rate: rate) : []
        if groups.count == 1 {
            let content = weights.contains { $0 > 0 }
            let options = (0..<(words.count - 1)).filter { k in
                !content || (weights[0...k].contains { $0 > 0 } && weights[(k + 1)...].contains { $0 > 0 })
            }
            if let k = options.max(by: { boundary(words[$0], words[$0 + 1]).depth < boundary(words[$1], words[$1 + 1]).depth }) {
                groups = [Array(0...k), Array((k + 1)..<words.count)]
            } else {
                single = true
            }
        }
        if single {
            texts = [words.map(\.text).joined(separator: " ")]
        } else if words.count >= 2 {
            let bounds = zip(groups, groups.dropFirst()).map { a, b in boundary(words[a.last!], words[b.first!]) }
            var cutAt = bounds.map(\.real)
            // A merged piece longer than `mergedPieceSeconds` is cut at its deepest boundary anyway.
            var changed = true
            while changed {
                changed = false
                var first = 0
                for k in 0...bounds.count where k == bounds.count || cutAt[k] {
                    let lo = words[groups[first].first!].frames.lowerBound, hi = words[groups[k].last!].frames.upperBound
                    let inner = (first..<k).filter { !cutAt[$0] }
                    if Double(hi - lo) / rate > DialogueMotifTuning.mergedPieceSeconds,
                       let deepest = inner.max(by: { bounds[$0].depth < bounds[$1].depth }) {
                        cutAt[deepest] = true
                        changed = true
                        break
                    }
                    first = k + 1
                }
            }
            // At least one cut, so the line has pieces.
            if !cutAt.contains(true), let deepest = bounds.indices.max(by: { bounds[$0].depth < bounds[$1].depth }) { cutAt[deepest] = true }
            cuts = bounds.indices.filter { cutAt[$0] }.map { bounds[$0].frame }
            var current: [String] = []
            for (k, g) in groups.enumerated() {
                current += g.map { words[$0].text }
                if k == groups.count - 1 || cutAt[k] { texts.append(current.joined(separator: " ")); current = [] }
            }
        } else {
            // Acoustic: the deepest and longest real dips between syllable nuclei, about one cut per 0.4 s
            // (D130: only real dips; before, any valley, which split words in two).
            let seconds = Double(span.count) / rate
            let target = min(DialogueMotifTuning.pieceCount.upperBound,
                             max(DialogueMotifTuning.pieceCount.lowerBound, Int((seconds / DialogueMotifTuning.pieceSeconds).rounded())))
            let all = valleys(span).sorted { ($0.depth + 40 * Float($0.run)) > ($1.depth + 40 * Float($1.run)) }
            let real = all.filter { Self.isAcousticGap(depth: $0.depth, run: $0.run) }
            for v in (real.isEmpty ? Array(all.prefix(1)) : real) where cuts.count < target - 1 {
                let c = zero(v.frame, bounds: span)
                if c - span.lowerBound >= minimum, span.upperBound - c >= minimum, cuts.allSatisfy({ abs($0 - c) >= minimum }) {
                    cuts.append(c)
                }
            }
            // A piece that is still long is cut again at its deepest inner real dip.
            var changed = true
            while changed {
                changed = false
                let edges = [span.lowerBound] + cuts.sorted() + [span.upperBound]
                for (lo, hi) in zip(edges, edges.dropFirst()) where Double(hi - lo) / rate > DialogueMotifTuning.maximumPieceSeconds {
                    let inner = valleys(lo..<hi).filter { Self.isAcousticGap(depth: $0.depth, run: $0.run) }
                        .map { (zero($0.frame, bounds: lo..<hi), $0.depth) }
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
        guard !kept.isEmpty || single else { return nil }
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
        // Split units (D130). With a transcript only a salient word of two or more syllables splits, into
        // its syllables at the valleys between its nuclei, and an initialism into its letters when it has
        // one nucleus per letter; never a function word, a one-syllable word, or across words. Without
        // one, a long piece splits in two only at a real dip (a word or syllable gap). Before D130 every
        // piece of 0.26 s or more was halved at the valley nearest its middle ("tr-" | "-ip", "UF-" | "-O").
        var halves: [Int: [Int]] = [:]
        let least = frames(DialogueMotifTuning.minimumPieceSeconds)
        for id in pieces {
            let piece = fragments[id]
            let r = piece.frames
            var units: [(frames: Range<Int>, text: String?)] = []
            var kind = DialogueMotifFragment.Kind.half
            if !words.isEmpty {
                if let spelled = spellUnits(r, words: words, weights: weights, salience: salience) { units = spelled.units; kind = spelled.kind }
            } else if Double(r.count) / rate >= DialogueMotifTuning.splitPieceSeconds {
                let mid = Double(r.lowerBound + r.upperBound) / 2
                let side = max(least, Int(DialogueMotifTuning.minimumHalfShare * Double(r.count)))
                let options = valleys(r).filter { $0.frame - r.lowerBound >= side && r.upperBound - $0.frame >= side
                    && Self.isAcousticGap(depth: $0.depth, run: $0.run) }
                func value(_ v: (frame: Int, depth: Float, run: Double)) -> Float {
                    v.depth - 24 * Float(abs(Double(v.frame) - mid) / Double(r.count))
                }
                if let best = options.max(by: { value($0) < value($1) }) {
                    let c = zero(best.frame, bounds: (r.lowerBound + least)..<(r.upperBound - least))
                    units = [(r.lowerBound..<c, nil), (c..<r.upperBound, nil)]
                }
            }
            guard units.count >= 2 else { continue }
            var ids: [Int] = []
            for (j, u) in units.enumerated() {
                let first = u.frames.lowerBound == r.lowerBound, last = u.frames.upperBound == r.upperBound
                let unit = DialogueMotifFragment(
                    id: fragments.count, kind: kind, order: piece.order, parent: id, frames: u.frames, accentFrame: accent(u.frames),
                    fadeIn: first ? piece.fadeIn : fadeIn(at: u.frames.lowerBound),
                    fadeOut: last && j == units.count - 1 ? piece.fadeOut : min(fadeOut, u.frames.count / 4), text: u.text)
                fragments.append(unit)
                ids.append(unit.id)
            }
            halves[id] = ids
        }
        return Result(fragments: trimmed(fragments, words: words, weights: weights), pieces: pieces, halves: halves)
    }

    /// Every fragment starts at its waveform onset and lands its attack on the step (D126): the
    /// valley-started pads played breath, room tone and the consonant up to 130 ms before the step,
    /// and a weak first syllable put the heard attack up to 175 ms after it (D125 captures). D130: a
    /// transcribed fragment never starts inside a word; a start that would is clamped to the word's
    /// start, the detected attack staying the accent unless that leaves more than `maximumLeadSeconds`
    /// before it, when the word's first syllable is the beat instead.
    func trimmed(_ fragments: [DialogueMotifFragment], words: [DialogueWordSpan], weights: [Float]) -> [DialogueMotifFragment] {
        guard let line = fragments.first else { return fragments }
        let context = frames(0.2)
        let envelope = DialogueOnsetEnvelope(samples: samples, count: count, rate: rate,
                                             span: max(0, line.frames.lowerBound - context)..<min(count, line.frames.upperBound))
        let least = frames(DialogueMotifTuning.minimumPieceSeconds)
        let slack = frames(DialogueMotifTuning.wordStartSlackSeconds)
        let wordEnds = words.map(\.frames.upperBound)
        return fragments.map { fr in
            var out = fr
            var attack = DialogueOnset.attack(envelope, samples: samples, count: count, rate: rate, search: fr.frames,
                                              line: fr.kind == .line)
            // A transcribed piece never starts inside a word: a weak first syllable is then the beat (the
            // sound starts on the step) instead of being trimmed off. Whole weak lead words ("to the"
            // before "time") may still go.
            if fr.kind != .line, words.contains(where: { $0.frames.lowerBound >= fr.frames.lowerBound - slack
                    && attack.startFrame > max($0.frames.lowerBound, fr.frames.lowerBound) + slack
                    && attack.startFrame < $0.frames.upperBound - slack }) {
                attack = DialogueOnset.attack(envelope, samples: samples, count: count, rate: rate, search: fr.frames,
                                              firstPeakShare: DialogueMotifTuning.weakLeadPeakShare)
                out.weakLead = true
            }
            if fr.frames.upperBound - attack.startFrame >= least {
                var start = attack.startFrame
                var beat = attack.beatFrame
                var fade = attack.fadeIn
                // D130: the start never sits more than the slack inside a word (the onset trim took the
                // "P" of "Pure cane" and the "con" of "consciousness"). A unit's own start is its syllable edge.
                let core = frames(DialogueMotifTuning.wordCoreToleranceSeconds)
                if fr.kind != .line, !fr.isUnit || fr.kind == .half,
                   let w = words.first(where: { $0.frames.overlaps(fr.frames) && $0.frames.lowerBound + core < start
                       && start < $0.frames.upperBound - core }) {
                    let clamped = zero(max(fr.frames.lowerBound, w.frames.lowerBound), bounds: fr.frames)
                    if Double(beat - clamped) / rate > DialogueMotifTuning.maximumLeadSeconds {
                        beat = min(max(clamped, accent(clamped..<fr.frames.upperBound)), fr.frames.upperBound - 1)
                        out.weakLead = true
                    }
                    start = clamped
                    fade = fadeIn(at: clamped)
                }
                // A weak lead word trimmed off a piece ("to the" before "time") leaves its text too.
                let dropped = words.filter { (fr.frames.lowerBound..<start).contains(($0.frames.lowerBound + $0.frames.upperBound) / 2) }.count
                if fr.kind != .line, dropped > 0, let text = fr.text {
                    let tokens = text.split(separator: " ")
                    if tokens.count > dropped { out.text = tokens.dropFirst(dropped).joined(separator: " ") }
                }
                out.frames = start..<fr.frames.upperBound
                out.accentFrame = max(start, beat)
                out.fadeIn = fade
                out.hardOnset = start == attack.startFrame && attack.hard
            }
            let lo = f.fineIndex(frame: out.frames.lowerBound), hi = f.fineIndex(frame: max(out.frames.lowerBound, out.frames.upperBound - 1))
            out.peakLevel = hi >= lo ? (f.fine[lo...hi].max() ?? 0) : 0
            out.words = words.indices.filter { words[$0].frames.overlaps(out.frames) }
                .map { DialogueMotifFragment.Word(frames: words[$0].frames, weight: weights.indices.contains($0) ? weights[$0] : 0) }
            let inner = out.accentFrame..<out.frames.upperBound
            // Where a gate may close: word ends with a transcript, real dips without one (D130).
            let ends = words.isEmpty
                ? valleys(out.frames).filter { Self.isAcousticGap(depth: $0.depth, run: $0.run) }.map(\.frame)
                : wordEnds
            out.cutPoints = Array(Set(ends.filter { inner.contains($0) && $0 < out.frames.upperBound - frames(0.01) })).sorted()
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
}

// MARK: - Arrangement

nonisolated extension DialogueMotif {
    /// The source frame a hit of fragment `id` reaches after `seconds` of play.
    func frame(_ id: Int, after seconds: Double) -> Int {
        fragments[id].frames.lowerBound + Int((seconds * playbackSampleRate).rounded())
    }

    /// Whether ending fragment `id` at source `frame` cuts a word (D130): with a transcript, the frame
    /// lies more than `wordCoreToleranceSeconds` inside a word's voiced core (any word, or only content
    /// words with `contentOnly`); without one, the sound is still within 20 dB of the fragment's peak
    /// and no cut point (a real dip) is near.
    func cutsWord(_ id: Int, at frame: Int, contentOnly: Bool = false) -> Bool {
        let fr = fragments[id]
        guard frame > fr.frames.lowerBound, frame < fr.frames.upperBound else { return false }
        if !fr.words.isEmpty { return fr.word(containing: frame, rate: sampleRate, contentOnly: contentOnly) != nil }
        guard let f = analysis.features, !f.fine.isEmpty else { return false }
        let tolerance = Int(DialogueMotifTuning.wordCoreToleranceSeconds * sampleRate)
        if fr.cutPoints.contains(where: { abs($0 - frame) <= tolerance }) { return false }
        return f.fine[f.fineIndex(frame: frame)] > 0.1 * fr.peakLevel
    }

    /// Whether a hit of fragment `id` that started at `start` and is ended at `time` would end inside a
    /// word, or before its first content word is whole (D130 stage 2: "can" of "can breathe.").
    func endsShort(_ id: Int, start: Double, at time: Double) -> Bool {
        if cutsWord(id, at: frame(id, after: time - start)) { return true }
        let fr = fragments[id]
        guard !fr.isUnit, let content = fr.words.first(where: { $0.weight > 0 && $0.frames.upperBound > fr.accentFrame }) else { return false }
        let end = start + Double(min(content.frames.upperBound, fr.frames.upperBound) - fr.frames.lowerBound) / playbackSampleRate
        return time < end - DialogueMotifTuning.wordCoreToleranceSeconds && time > start + accentOffset(id)
    }

    /// The last clean end of a hit of fragment `id` that started at `start` (accent `accent`), at or
    /// before `time`: a cut point (word end or real dip) after its first content word and at least
    /// `minimumGateSeconds` after the accent. Nil when none exists (D130: a hit that would choke the
    /// one before it inside a word ends that one at its last word end instead, or is skipped).
    func cleanEnd(_ id: Int, start: Double, accent: Double, before time: Double) -> Double? {
        let fr = fragments[id]
        guard !fr.isUnit else { return nil }
        var floor = accent + DialogueMotifTuning.minimumGateSeconds
        if let content = fr.words.first(where: { $0.weight > 0 && $0.frames.upperBound > fr.accentFrame }) {
            floor = max(floor, start + Double(content.frames.upperBound - fr.frames.lowerBound) / playbackSampleRate - DialogueMotifTuning.wordCoreToleranceSeconds)
        }
        return fr.cutPoints.map { start + Double($0 - fr.frames.lowerBound) / playbackSampleRate }.filter { $0 <= time && $0 >= floor }.max()
    }

    /// Seconds from a fragment's accent to its first clean end (D130): its first content word played
    /// whole, then the next word end (or real dip) at or after it, else its natural end. A syllable or
    /// letter plays to its own end.
    static func cleanSeconds(_ id: Int, fragments: [DialogueMotifFragment], sampleRate: Double) -> Double {
        let fr = fragments[id]
        var floor = fr.accentFrame + Int(DialogueMotifTuning.minimumGateSeconds * sampleRate)
        if let content = fr.words.first(where: { $0.weight > 0 && $0.frames.upperBound > fr.accentFrame }) {
            floor = max(floor, min(content.frames.upperBound, fr.frames.upperBound))
        }
        let tolerance = Int(DialogueMotifTuning.wordCoreToleranceSeconds * sampleRate)
        let end = fr.isUnit ? fr.frames.upperBound : (fr.cutPoints.filter { $0 >= floor - tolerance }.min() ?? fr.frames.upperBound)
        return Double(max(0, min(end, fr.frames.upperBound) - fr.accentFrame)) / sampleRate
    }

    /// A cut fits `steps` sixteenths when its clean end comes before the next hit (within
    /// `fitToleranceSeconds`); every cut fits when the beat is unknown (0).
    static func fitsRoom(_ id: Int, steps: Int, fragments: [DialogueMotifFragment], sampleRate: Double, beatDuration: Double) -> Bool {
        guard beatDuration > 0 else { return true }
        // The next hit starts its consonant a little before its step (and the choke lead before that).
        return cleanSeconds(id, fragments: fragments, sampleRate: sampleRate) + DialogueMotifTuning.nextLeadSeconds
            <= Double(steps) * beatDuration / 4 + DialogueMotifTuning.fitToleranceSeconds
    }

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
            if weighted, fragments[r].weight == 0 { r = s }
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
        // Acoustic lines (no word weights) always answer with another piece; a worded one with another
        // content piece (D130 stage 2: the response never weighs 0 while the line has a content cut).
        if r == s, n > 1, !weighted || anchored != nil {
            r = pieces.first { $0 != s && (!weighted || fragments[$0].weight > 0) } ?? (weighted ? s : pieces.first { $0 != s }!)
        }
        // A signature answered by itself (a one-word line, or one whose other pieces are only function
        // words) is answered by its last spell unit when it spells ("psilocybin" ... "-bin"), so the hook
        // does not fire one cut twice in a row.
        if r == s, let units = halves[s], units.count >= 2, units.allSatisfy({ fragments[$0].kind != .half }) { r = units[units.count - 1] }
        if !reorderAllowed, fragments[r].order < fragments[s].order { swap(&s, &r) }
        let sa = headHalf(s, fragments: fragments, halves: halves)
        // A line that may not be reordered takes the signature's head half as its third piece, so
        // each bar plays its new pieces in source order.
        // Otherwise the third is the strongest remaining piece (source order without text), so a
        // connective piece ("to the") is the third only when nothing else is left.
        let rest = pieces.filter { $0 != s && $0 != r }
        var t = reorderAllowed ? (best(rest, by: { Double(fragments[$0].weight) }) ?? (sa != s ? sa : r)) : (sa != s ? sa : r)
        // Nor a function-word third when the signature's head can stutter instead, nor when the
        // response or signature carries a word (D130 stage 2).
        if weighted, fragments[t].weight == 0 { t = sa != s ? sa : (fragments[r].weight > 0 ? r : s) }
        return (s, r, t)
    }

    /// The unit of a piece its stutters repeat: the first syllable or letter of a split word ("psi-",
    /// "L"); of two halves the first when the cut splits a word ("Sall-") or nothing carries text, else
    /// the half with the stronger word ("LSD." rather than "of").
    static func headHalf(_ piece: Int, fragments: [DialogueMotifFragment], halves: [Int: [Int]]) -> Int {
        guard let h = halves[piece], h.count >= 2 else { return piece }
        if fragments[h[0]].kind != .half || h.count > 2 { return h[0] }
        let a = fragments[h[0]], b = fragments[h[1]]
        if a.text?.hasSuffix("-") == true || b.weight <= a.weight { return h[0] }
        return h[1]
    }

    /// A spell figure of `piece` (D130 stage 2; user direction of 22 November 2026: "the initials DMT are
    /// easy to catch, and then match to a beat"): its letters (an initialism) or syllables (a salient
    /// multi-syllable word) one per step in source order from `from`, on 8ths, or on 16ths when every
    /// unit fits a sixteenth, then the piece whole on the next beat, all before `end`. With
    /// `wholeOptional`, a figure whose whole statement does not fit ends on its last unit. Nil when the
    /// piece does not spell or its units do not fit their steps.
    static func spellFigure(_ piece: Int, from: Int, end: Int, fragments: [DialogueMotifFragment], halves: [Int: [Int]],
                            sampleRate: Double, beatDuration: Double, wholeOptional: Bool = false) -> [DialogueMotifCell.Item]? {
        guard let units = halves[piece], units.count >= 2,
              units.allSatisfy({ fragments[$0].kind == .letter || fragments[$0].kind == .syllable }) else { return nil }
        func fits(_ f: Int, _ steps: Int) -> Bool {
            fitsRoom(f, steps: steps, fragments: fragments, sampleRate: sampleRate, beatDuration: beatDuration)
        }
        for step in [1, 2] where units.allSatisfy({ fits($0, step) }) {
            let after = from + units.count * step
            let whole = (after + 3) / 4 * 4
            guard after <= end else { continue }
            var items = units.enumerated().map { k, u in
                DialogueMotifCell.Item(fragment: u, slot: from + k * step, fixed: true, gate: step)
            }
            if whole < end, fits(piece, end - whole) || beatDuration <= 0 {
                items.append(DialogueMotifCell.Item(fragment: piece, slot: whole, fixed: true, gate: end - whole))
            } else if !wholeOptional {
                continue
            }
            return items
        }
        return nil
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
    /// or two words a bar with echo throws (bars 9-12); seeded reverse pickups lead into downbeats. The outro keeps
    /// the return's one quiet piece in bar 13, restates the line in bars 14-15 with some parts
    /// repeated, and tags bar 16. Each section has seeded variants (`DialogueArc`), so no two
    /// consecutive loops play the same arc.
    static func arrange(fragments: [DialogueMotifFragment], pieces: [Int], halves: [Int: [Int]], reorderAllowed: Bool,
                        seed: UInt64, lineSeconds: Double, sampleRate: Double, hookSeed: UInt64, loop: Int,
                        anchors: [Range<Int>] = [], avoidTemplate: Int? = nil, drums: DialogueMotifDrums = .boomBap,
                        keepArc: DialogueArc? = nil, avoidArc: DialogueArc? = nil,
                        carried: Bool = false, beatDuration: Double = 0, avoidCells: [DialogueMotifCell] = []) -> (cells: [DialogueMotifCell], hook: DialogueMotifHook, arc: DialogueArc) {
        var rng = MusicRNG(seed: seed ^ 0x4D07_1F00)
        func seconds(_ id: Int) -> Double { Double(fragments[id].frames.count) / sampleRate }
        /// D130: a cut fits `steps` sixteenths when it reaches a clean end (its first content word whole)
        /// before the next hit; without a known beat every cut fits.
        func fits(_ f: Int, _ steps: Int) -> Bool {
            fitsRoom(f, steps: steps, fragments: fragments, sampleRate: sampleRate, beatDuration: beatDuration)
        }
        let roles = hookRoles(fragments: fragments, pieces: pieces, halves: halves, reorderAllowed: reorderAllowed,
                              sampleRate: sampleRate, anchors: anchors)
        let (s, r, t) = roles
        let sa = headHalf(s, fragments: fragments, halves: halves)
        let ra = halves[r]?[0] ?? r
        // The split piece: the longest piece that has halves; without halves, the shortest pair of
        // neighbouring pieces stands in (a word group heard as two words with a pause between).
        let split = halves.keys.sorted { (seconds($0), -$0) > (seconds($1), -$1) }.first
        // D130: the walks through the line's pieces (the stand-in pair, the build's ladder, the breakdown's
        // first word) take its content pieces when it has two or more, not its connective ones.
        let content = pieces.filter { fragments[$0].weight > 0 }
        let walk = content.isEmpty ? pieces : content
        let pair = zip(walk, walk.dropFirst()).min { seconds($0.0) + seconds($0.1) < seconds($1.0) + seconds($1.1) }
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
        let vocabulary = GrooveVocabulary(s: s, r: r, t: t, sa: sa, ra: ra, pieces: pieces, halves: halves, fragments: fragments)
        // The skeleton holds for the template's loops; the fill around it is drawn from this loop's seed (D127).
        let g = groove(template: DialogueMotifTuning.hookTemplates[template], vocabulary: vocabulary, drums: drums,
                       reorderAllowed: reorderAllowed, fragments: fragments, sampleRate: sampleRate, seed: seed,
                       beatDuration: beatDuration)
        // Cuts a hit that does not fit its room may take instead (content words first); a line that may
        // not be reordered only drops such a hit (D130).
        // D130 stage 2: never a weight-0 cut while the line has a content one.
        let anyContent = fragments.dropFirst().contains { $0.weight > 0 }
        // A letter or syllable stands in for nothing: units sound only in source order (spell figures and runs).
        func spellUnit(_ f: Int) -> Bool { fragments[f].kind == .letter || fragments[f].kind == .syllable }
        let roomAlternatives = reorderAllowed
            ? (([sa, ra, vocabulary.sb, vocabulary.rb, t, s, r] + vocabulary.others + pieces).filter { fragments[$0].weight > 0 }
                + (anyContent ? [] : ([sa, ra, vocabulary.sb, vocabulary.rb, t] + vocabulary.others + pieces).filter { fragments[$0].weight == 0 }))
                .filter { !spellUnit($0) }
            : []
        /// Fixed hits on close steps (the turn, the build, the outro tag): each takes a cut that fits the
        /// steps before the next hit, else drops. A stutter repeats its head's cut and goes with it.
        func fitted(_ items: [Item], end: Int, rolls: Bool = true, keep: Set<Int> = [], after: Int? = nil) -> [Item] {
            var out: [Item] = []
            // The hit before the first item (the bar before it), so the first item is not its repeat.
            let before = after
            var replaced: [Int: Int?] = [:]
            // A kept hit (the turn's backbeat response) that does not fit drops the hits after it until it does.
            var items = items
            for slot in keep.sorted() {
                guard let k = items.firstIndex(where: { $0.slot == slot }) else { continue }
                while k + 1 < items.count, !fits(items[k].fragment, (items[k + 1].slot) - slot) { items.remove(at: k + 1) }
            }
            for (k, item) in items.enumerated() {
                guard item.follow == nil, item.after == nil, item.effect != .reversed else { out.append(item); continue }
                if keep.contains(item.slot) { replaced[item.fragment] = item.fragment; out.append(item); continue }
                var it = item
                let next = items[(k + 1)...].first { $0.follow == nil && $0.after == nil && $0.slot > item.slot }?.slot ?? end
                let room = max(1, next - item.slot)
                if item.stutter {
                    if let r = replaced[item.fragment] {
                        guard let r else { continue }
                        it.fragment = r
                    }
                    // D130 stage 2: a stutter repeats only a cut that is whole in its room (a letter, a
                    // syllable of a salient word or a short word); a longer word's repeat is left out.
                    guard fits(it.fragment, room) else { continue }
                    out.append(it)
                    continue
                }
                let previous = out.last?.fragment ?? before
                if fits(item.fragment, room), item.fragment != previous || (rolls && out.last != nil) {
                    replaced[item.fragment] = item.fragment
                    // A repeat of the hit before it is a roll (the build's and turn's), marked as one.
                    if item.fragment == previous { it.stutter = true }
                    out.append(it)
                    continue
                }
                if let alt = roomAlternatives.first(where: { $0 != previous && fits($0, room) }) {
                    replaced[item.fragment] = alt
                    it.fragment = alt
                    out.append(it)
                } else {
                    replaced[item.fragment] = .some(nil)
                }
            }
            return out
        }
        let barA = g.filter { $0.slot < 16 }
        let last = walk.last ?? r
        // The return's short piece carries a real word when the line has a short one (it stays short:
        // at -3 dB a long piece reads as a quiet chop, C-B8's loudness spread).
        let shorts = [sa, s, splitB, ra] + pieces
        let worded = shorts.filter { fragments[$0].weight > 0 && seconds($0) <= DialogueMotifTuning.returnPieceSeconds }
        let short = (worded.isEmpty ? (anyContent ? shorts.filter { fragments[$0].weight > 0 } : shorts) : worded).min { seconds($0) < seconds($1) } ?? s

        // Intro (bars 1-2): the whole line on the downbeat, then a tag on bar 2's backbeat.
        let tag: [Item]
        switch arc.intro {
        case 0: tag = [near(last, 28, .echoThrow)]
        case 1: tag = [near(s, 24, gate: 2), near(s, 28, gate: 2)]
        default: tag = [near(r, 28, .filtered)]
        }
        // The tag ends before the chop beat's downbeat hit (D130).
        let intro = [Item(fragment: 0, slot: 0)] + fitted(tag, end: 32, rolls: false)

        // Chop beat (bars 3-6): the groove twice; the second time its last beat turns.
        let turn: [Item]
        switch rng.int(0...2) {
        // The backbeat answer stays on step 28.
        case 0: turn = [at(r, 28, gate: 1), at(ra, 29, gate: 1), stutter(at(ra, 30, gate: 2))]
        case 1: turn = [at(r, 28, .echoThrow, gate: 2)]
        default: turn = [at(r, 28, gate: 2), at(vocabulary.sb != r ? vocabulary.sb : sa, 30, gate: 2)]
        }
        let second = g.filter { $0.slot < 28 } + fitted(turn, end: 32, keep: [28])

        // Build (bars 7-8): bar 7 is the groove's call with one more stab, bar 8 doubles it into the drop.
        var seven = barA
        if let free = stride(from: 0, to: 16, by: 2).first(where: { k in !seven.contains { abs($0.slot - k) <= 1 } }) {
            // A cut the hits around it do not play (D127), that fits before the next hit while the hit
            // before it still fits (D130).
            let before = seven.last { $0.slot < free }
            let room = (seven.first { $0.slot > free }?.slot ?? 16) - free
            let choices = ([vocabulary.sb, sa, t, ra] + vocabulary.others)
                .filter { !spellUnit($0) && (beatDuration <= 0 || fits($0, room)) && (!anyContent || fragments[$0].weight > 0) }
            if !choices.isEmpty, before.map({ fits($0.fragment, free - $0.slot) }) ?? true {
                seven.append(at(freshCut(choices, at: free, among: seven), free, gate: 1))
                seven.sort { $0.slot < $1.slot }
            }
        }
        // The signature's (or the response's) spell units, when it spells (D130 stage 2). A figure ends a
        // sixteenth before the drop, like every build variant.
        let spellS = spellFigure(s, from: 20, end: 31, fragments: fragments, halves: halves, sampleRate: sampleRate, beatDuration: beatDuration)
            .map { [at(s, 16, gate: 4)] + $0 }
            ?? spellFigure(s, from: 16, end: 31, fragments: fragments, halves: halves, sampleRate: sampleRate, beatDuration: beatDuration)
        let eight: [Item]
        switch arc.build {
        case 0 where spellS != nil:
            // Halving into a spell figure: the signature held a beat, then spelled letter by letter (or
            // syllable by syllable) and stated whole on the next beat ("L-S-D, LSD"), replacing the
            // pre-D130 hammer of its head half.
            eight = spellS!
        case 0 where fragments[sa].kind == .half:
            eight = [at(s, 16, gate: 4), stutter(at(s, 20, gate: 2)), stutter(at(s, 22, gate: 2)), at(sa, 24, gate: 1)]
                + (25...29).map { stutter(at(sa, $0, gate: 1)) } + [at(r, 30, gate: 1)]
        case 0:
            // A signature that does not spell: whole content pieces alternate with rests (no 1-step stab
            // of a longer word).
            let others = walk.filter { $0 != s }
            let x = others.first ?? r, y = others.count > 1 ? others[1] : r
            eight = [at(s, 16, gate: 4), at(x, 20, gate: 2), at(s, 24, gate: 2), at(y, 28, gate: 2)]
        case 1:
            // Ladder: the line's first words, one more each beat, in source order (the beat-2 restart is the ladder's stutter).
            let w = (0..<3).map { walk[min($0, walk.count - 1)] }
            eight = [at(w[0], 16, gate: 2), stutter(at(w[0], 20, gate: 1)), at(w[1], 22, gate: 2),
                     at(w[0], 24, gate: 1), at(w[1], 25, gate: 1), at(w[2], 26, gate: 2),
                     at(w[0], 28, gate: 1), at(w[1], 29, gate: 1), at(w[2], 30, gate: 1)]
        default:
            // Ping-pong: the signature and the response, then a spell figure of the response (or the
            // signature) in beats 3 and 4; without one, the two alternate whole with rests between.
            let spellR = spellFigure(r, from: 24, end: 31, fragments: fragments, halves: halves, sampleRate: sampleRate, beatDuration: beatDuration)
                ?? spellFigure(s, from: 24, end: 31, fragments: fragments, halves: halves, sampleRate: sampleRate, beatDuration: beatDuration)
                ?? spellFigure(r, from: 20, end: 31, fragments: fragments, halves: halves, sampleRate: sampleRate, beatDuration: beatDuration)
                ?? spellFigure(s, from: 20, end: 31, fragments: fragments, halves: halves, sampleRate: sampleRate, beatDuration: beatDuration)
            if let spell = spellR {
                // A slower whole-word landing needs an earlier lead-in. Reserve that complete
                // figure instead of falling through to a row of close steps no word can fit.
                let prefix = [at(s, 16, gate: 2), at(r, 20, gate: 2)].filter { $0.slot < (spell.first?.slot ?? 24) }
                eight = prefix + spell
            } else if fragments[sa].kind == .half || fragments[ra].kind == .half {
                eight = [at(s, 16, gate: 2), at(r, 20, gate: 2)] + (24...30).map { at($0 % 2 == 0 ? sa : ra, $0, gate: 1) }
            } else {
                eight = [at(s, 16, gate: 2), at(r, 20, gate: 2), at(s, 24, gate: 2), at(r, 28, gate: 2)]
            }
        }
        // Every variant's last stab ends a sixteenth before the drop, so the breakdown's first word can
        // start its consonant just before bar 9's downbeat (the next cue's plan cannot choke it).
        let build = seven + fitted(eight, end: 32, after: seven.last?.fragment)

        // Breakdown (bars 9-12, one cell): a word or two a bar, held, with echo throws; the split
        // syllable with a pause; the move pool varies these sites and adds reverse pickups.
        let first = walk.first ?? s
        var breakdown: [Item]
        switch arc.breakdown {
        case 0: breakdown = [near(s, 0, .echoThrow), near(r, 24, .echoThrow), near(splitA, 40), near(splitB, 44, .echoThrow), near(t, 52)]
        case 1: breakdown = [near(s, 0, .echoThrow), near(r, 20, .filtered), near(splitA, 40), near(splitB, 44, .echoThrow), near(s, 48, .echoThrow)]
        default: breakdown = [near(first, 0, .echoThrow), near(s, 24, .echoThrow), near(splitA, 40), near(splitB, 44, .echoThrow), near(r, 52)]
        }

        // Outro (bars 13-16, one cell): the return's quiet piece, the line again from bar 14, a tag.
        var outro = [at(short, 12, gain: DialogueMotifTuning.returnPieceDB)]
        switch arc.outro {
        case 0:
            // The line walked on the 8ths, the signature stuttered before it plays out.
            for (k, p) in pieces.enumerated() {
                // D130: the 1/16 stutter only with a cut that is whole at one step (a letter, a syllable or
                // a short word); else the signature is walked whole like the rest.
                if p == s, fits(sa, 1) {
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
            outro += [Item(fragment: 0, slot: 16), chain(first, from: 16), chain(walk.count > 1 ? walk[1] : s, from: 16),
                      chain(last, from: 36, gate: 2)]
        }
        // The tag (D130 stage 2): the signature spelled from step 56 and stated whole when it fits before
        // the next loop's downbeat; else the signature and the response whole. The tag's answer holds an
        // 8th, so the next loop's line can start on its downbeat.
        // It ends a sixteenth before the next loop, whose line starts its consonant before the downbeat.
        func tagSpell(_ from: Int, _ optional: Bool) -> [Item]? {
            spellFigure(s, from: from, end: 63, fragments: fragments, halves: halves, sampleRate: sampleRate,
                        beatDuration: beatDuration, wholeOptional: optional)
        }
        if let spell = tagSpell(56, false) ?? tagSpell(52, false)  {
            outro += fitted(spell, end: 63, rolls: false)
        } else if fragments[sa].kind == .half {
            outro += fitted([at(sa, 56, gate: 1), at(sa, 57, gate: 1), at(sa, 58, gate: 1), at(r, 60, gate: 2)], end: 64, rolls: false)
        } else {
            outro += fitted([at(s, 56, gate: 2), at(r, 60, gate: 2)], end: 63, rolls: false)
        }

        let baseCells: [DialogueMotifCell] = [
            DialogueMotifCell(kind: .intro, bar: 0, bars: 2, variant: arc.intro, items: intro),
            DialogueMotifCell(kind: .chopBeat, bar: 2, bars: 2, variant: template, items: g),
            DialogueMotifCell(kind: .chopBeat, bar: 4, bars: 2, variant: template, items: second),
            DialogueMotifCell(kind: .build, bar: 6, bars: 2, variant: arc.build, items: build),
            DialogueMotifCell(kind: .breakdown, bar: 8, bars: 4, variant: arc.breakdown, items: breakdown),
            DialogueMotifCell(kind: .outro, bar: 12, bars: 4, variant: arc.outro, items: outro),
        ]
        let cells = DialogueMovePool.arrange(baseCells, fragments: fragments, signature: s, sampleRate: sampleRate,
                                             beatDuration: beatDuration, seed: seed, avoiding: avoidCells)
        // Repair and diagnostics must use the hook that is actually performed, including its
        // seeded fill moves, rather than the pre-arrangement grid.
        let hookItems = cells.first { $0.kind == .chopBeat }?.items ?? g
        return (cells, DialogueMotifHook(template: template, signature: s, response: r, third: t, items: hookItems), arc)
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
        let points = fr.cutPoints.map { start + Double($0 - fr.frames.lowerBound) / motif.playbackSampleRate }
        // D130: a gate that would close inside a word (or mid-sound with no cut point) plays on to the
        // next word end or real dip within `gateExtendSeconds` (the piece's end counts), else stops at
        // the last one before it, never before the fragment's first content word is whole. Only when
        // neither exists does the D126 gate cut. Before, gates of 0.2 s cut "LSD" and "marijuana" mid-word.
        var floor = least
        if !fr.isUnit, let content = fr.words.first(where: { $0.weight > 0 && $0.frames.upperBound > fr.accentFrame }) {
            floor = max(floor, start + Double(min(content.frames.upperBound, fr.frames.upperBound) - fr.frames.lowerBound) / motif.playbackSampleRate
                - DialogueMotifTuning.wordCoreToleranceSeconds)
        }
        // D130 stage 2: a gate that closes before the fragment's first content word is whole (between
        // "can" and "breathe.") plays on like one inside a word, so a hit is never only its connective.
        if motif.cutsWord(fragment, at: motif.frame(fragment, after: target - start)) || target < floor {
            if let after = (points + [natural]).filter({ $0 >= max(target, floor) && $0 <= target + DialogueMotifTuning.gateExtendSeconds }).min() {
                return (after, after >= natural - 1e-9 ? "natural" : "word")
            }
            if let before = points.filter({ $0 < target && $0 >= floor }).max() { return (before, "valley") }
            // A word longer than the reach plays to its end: a whole word over a gate (the D126 gate
            // only cuts where no word is cut).
            if let after = (points + [natural]).filter({ $0 >= max(target, floor) }).min() {
                return (after, after >= natural - 1e-9 ? "natural" : "word")
            }
        }
        let valleys = points.filter { $0 <= target && $0 >= target - DialogueMotifTuning.valleySnapSeconds && $0 >= least }
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
            // A spelling figure is one gesture: dynamic after/follow chains can occupy its
            // drawn start. Roll back the complete figure (including any choke it attempted)
            // unless every ordered unit and its whole-word landing can be placed.
            var figures: [Int: Int] = [:]
            var index = 0
            while index < cell.items.count {
                let fragment = motif.fragments[cell.items[index].fragment]
                guard fragment.isUnit, fragment.kind != .half, let parent = fragment.parent else { index += 1; continue }
                let first = index
                while index < cell.items.count,
                      motif.fragments[cell.items[index].fragment].parent == parent { index += 1 }
                if index < cell.items.count, cell.items[index].fragment == parent {
                    index += 1
                }
                figures[first] = index - 1
            }
            var figure: (start: Int, end: Int, placed: [Placed], prevEnd: Double, first: Bool, statements: Int)?
            var figureShift = 0
            for (itemIndex, item) in cell.items.enumerated() {
                if let end = figures[itemIndex] {
                    if cell.kind == .outro {
                        let group = cell.items[itemIndex...end]
                        // The preceding restatement is a dynamic whole-word chain. Its actual
                        // end can overrun the tag's drawn start. Move the complete figure by
                        // beats into remaining space, retaining its unit order, spacing and
                        // whole-word landing instead of discarding it or cutting the chain.
                        if group.allSatisfy({ $0.after == nil && $0.follow == nil }) {
                            figureShift = stride(from: 0, to: cell.bars * 16 - item.slot, by: 4).first { shift in
                                var lastEnd = max(prevEnd + DialogueTuning.dryGapSeconds, floor)
                                for part in group {
                                    let step = cellStart + part.slot + shift
                                    let start = snapshot.gridTime(sixteenth: step) - accentOffset(part)
                                    guard start >= lastEnd else { return false }
                                    let end = gatedEnd(part.fragment, start: start, sixteenth: step, gate: part.gate,
                                                       motif: motif, snapshot: snapshot).end
                                    guard end <= min(upper, snapshot.gridTime(sixteenth: cellEnd - 1)) else { return false }
                                    lastEnd = end + DialogueTuning.dryGapSeconds
                                }
                                return true
                            } ?? 0
                        }
                    }
                    figure = (itemIndex, end, placed, prevEnd, firstInCell, statements)
                }
                defer {
                    if let saved = figure, itemIndex == saved.end {
                        let expected = cell.items[saved.start...saved.end].map(\.fragment)
                        if Array(placed.dropFirst(saved.placed.count).map(\.fragment)) != expected {
                            placed = saved.placed
                            prevEnd = saved.prevEnd
                            firstInCell = saved.first
                            statements = saved.statements
                        }
                        figure = nil
                        figureShift = 0
                    }
                }
                if item.fragment == 0 {
                    guard statements < DialogueMotifTuning.maximumLineStatements else { continue }
                }
                let base = cellStart + item.slot + figureShift
                let offset = accentOffset(item)
                let length = duration(item.fragment)
                // The section's dry budget; the line statement, the turnaround's landing and the phrase-end
                // stutter (its repeats choke each other, so they cost little) always play.
                // The build's stutters and any follow-on repeat (they choke each other, so they cost little) always play.
                // D130: the build's whole-word hits count (before, its 1/16 stabs were too short to matter).
                let stutterFill = (cell.kind == .stutter && item.slot >= 16) || item.stutter || item.follow != nil
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
                // D130: a hit skipped before it (a choke inside a word) must not leave the same cut twice in a
                // row in the chop beat or build unless it is a marked roll (D127).
                if (cell.kind == .chopBeat || cell.kind == .build), !item.stutter, !item.skeleton, item.follow == nil,
                   let last = placed.last, last.fragment == item.fragment, last.cell == cell.kind { continue }
                // D130 stage 2: nor a skeleton hit off the bar's downbeat that would repeat the hit before it (a
                // line with one content cut fired it on every hook step); the hook keeps its steps, and the
                // downbeat call stays.
                if cell.kind == .chopBeat, item.skeleton, item.slot % 16 != 0, let last = placed.last, last.cell == .chopBeat,
                   last.fragment == item.fragment { continue }
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
                        // D130: never inside a word of the earlier piece; an unfixed hit moves on by 8ths, a
                        // fixed one drops if no whole-word end fits, including a deliberate stutter.
                        let chokeAt = start - DialogueTuning.chokeLeadSeconds
                        if chokeAt < last.end, motif.endsShort(last.fragment, start: last.start, at: chokeAt) {
                            // The earlier piece ends at its last word end before the hit instead, if it has one; a
                            // repeat is skipped when there is no clean end, including marked stutters.
                            let clean = motif.cleanEnd(last.fragment, start: last.start, accent: last.accent, before: chokeAt)
                            if clean == nil { continue }
                        }
                        if chokeAt < last.end, motif.endsShort(last.fragment, start: last.start, at: chokeAt),
                           let clean = motif.cleanEnd(last.fragment, start: last.start, accent: last.accent, before: chokeAt) {
                            placed[placed.count - 1].end = clean
                            placed[placed.count - 1].gateEnd = "word"
                            if start >= clean + DialogueTuning.dryGapSeconds {
                                placed.append(Placed(fragment: item.fragment, cell: cell.kind, sixteenth: s, accent: accent, start: start, end: end,
                                                     gainDB: item.gainDB, effect: item.effect, landing: item.landing, gate: item.gate,
                                                     gateEnd: gated.kind, stutter: item.stutter, feel: feel))
                                prevEnd = end
                                if item.fragment == 0 { statements += 1 }
                                done = true
                                break
                            }
                        }
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
                                                occupancy: own.map(\.duration).reduce(0, +), nonNative: own.filter { !$0.transform.isNative }.count, events: own.count,
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
        // D130: a whole content piece (the shortest first), then the line's other pieces; never a split unit.
        let content = motif.pieces.filter { motif.fragments[$0].weight > 0 }
        let candidates = (content.isEmpty ? motif.pieces : content).sorted { (motif.seconds($0), $0) < (motif.seconds($1), $1) }
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
            let hookItems = (motif.hook?.items ?? []).filter { $0.effect != .reversed && $0.slot / 16 == ((barInLoop % 2) + 2) % 2 }
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
                var shortenPrevious: Double?
                if let p = previous, placed[p].end + DialogueTuning.dryGapSeconds > start {
                    guard placed[p].fragment != 0, placed[p].effect != .reversed,
                          start - DialogueTuning.chokeLeadSeconds - placed[p].start >= DialogueMotifTuning.minimumPieceSeconds else { continue }
                    // Never inside a word of the earlier piece (D130): it ends at its last word end before, or the slot is skipped.
                    let chokeAt = start - DialogueTuning.chokeLeadSeconds
                    if chokeAt < placed[p].end, motif.endsShort(placed[p].fragment, start: placed[p].start, at: chokeAt) {
                        guard let clean = motif.cleanEnd(placed[p].fragment, start: placed[p].start, accent: placed[p].accent, before: chokeAt)
                        else { continue }
                        shortenPrevious = clean
                    }
                    chokePrevious = shortenPrevious == nil
                }
                var chokedSelf = false
                if let q = next, end + DialogueTuning.dryGapSeconds > placed[q].start {
                    let cut = placed[q].start - DialogueTuning.chokeLeadSeconds
                    guard cut - start >= DialogueMotifTuning.minimumPieceSeconds,
                          !motif.endsShort(f, start: start, at: cut) else { continue }
                    end = cut
                    chokedSelf = true
                }
                guard end <= upper else { continue }
                if let clean = shortenPrevious, let p = previous {
                    placed[p].end = clean
                    placed[p].gateEnd = "word"
                }
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
                                      chokeAt: choke, text: pad.text, transform: pad.transform, padKey: pad.padKey,
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
            event.sourceFrames = sourceStart..<(sourceStart + Int(((p.end - p.start) * motif.playbackSampleRate).rounded()))
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
