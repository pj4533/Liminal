import AVFoundation
import Foundation

// Value types shared by the dialogue engine (plan docs/plans/mpc-chopping.md, section 3.4).
// Everything here is pure, `nonisolated` and `Sendable`. Times are named by their clock:
// film seconds (transcripts), source frames (buffer positions) and transport seconds (plans).

/// Every tuning number of the dialogue engine. Values marked *start* in the plan are hypotheses;
/// a change needs a reason in the commit or in `docs/plans/mpc-chopping-measurements.md`.
nonisolated enum DialogueTuning {
    // MARK: Analysis (plan 4.2)
    static let analysisSeconds = 32.0
    static let hopSeconds = 0.010
    static let fineHopSeconds = 0.001
    static let bandCornersHz: [Double] = [145, 820, 3900]
    static let floorPercentile = 0.20
    static let gateMinimum: Float = 0.0025
    static let gateFraction: Float = 0.19
    static let intensityLowHz = 300.0
    static let intensityHighHz = 3000.0
    static let noisePercentile = 0.10
    static let nucleusRangeDB: Float = 25
    static let nucleusDipDB: Float = 2
    static let voicingThreshold: Float = 0.3
    static let voicingLowHz = 70.0
    static let voicingHighHz = 400.0
    static let voicingFrameSeconds = 0.030
    static let voicingDecimatedRate = 8000.0
    /// Zero crossings per second below which a nucleus counts as voiced without a pitch peak.
    static let voicedZeroCrossingsPerSecond = 900.0
    static let pauseMarginDB: Float = 6
    static let utterancePauseSeconds = 0.180
    static let pauseGroupSeconds = 0.080
    static let burstRiseSeconds = 0.015
    /// A flat top is a run of at least this many samples within `clipFlatness` of the cue peak.
    static let clipRunSamples = 3
    static let clipFlatness: Float = 0.985
    /// Peak level (linear) above which flat tops are counted as soft-clip plateaus.
    static let clipMinimumPeak: Float = 0.25

    // MARK: Hierarchy (plan 4.3)
    static let utteranceSeconds: ClosedRange<Double> = 0.7...6
    static let utteranceMinimumNuclei = 3
    /// Syllable rate a spoken utterance must reach. Sung or choral material runs below it (addition).
    static let utteranceSyllableRate: ClosedRange<Double> = 1.8...9
    /// Median dip between syllable nuclei an utterance needs (addition; choirs and tones stay above it).
    static let syllableDipDB: Float = 5
    static let phraseSeconds: ClosedRange<Double> = 0.7...3
    static let stabSeconds: ClosedRange<Double> = 0.15...0.6
    static let stabMaximumNuclei = 2
    /// Second nucleus joins a stab only when it follows within this interval.
    static let stabPairSeconds = 0.26
    static let textureSeconds: ClosedRange<Double> = 0.06...0.15
    static let textureCoreDB: Float = 3
    static let stressAnchorCount = 3
    static let refineSearchSeconds = 0.030
    static let burstPrerollSeconds = 0.012
    static let gradualPrerollSeconds = 0.020
    static let zeroCrossingSearchSeconds = 0.002
    static let burstFadeInSeconds = 0.003
    static let gradualFadeInSeconds = 0.008
    static let releaseSeconds = 0.015
    static let tailMaximumSeconds = 0.150
    static let boundaryLowDepthDB: Float = 4
    static let boundaryHighDepthDB: Float = 12
    static let boundaryLowConfidence: Float = 0.2
    // Real-footage tuning (wave 3, docs/plans/mpc-chopping-measurements.md, "Dialogue tuning").
    /// A short phrase fragment joins the following segment unless that pause is this much longer.
    static let forwardMergeBias = 1.5
    /// A short last fragment joins the previous segment only across a pause up to this long.
    static let trailingMergePauseSeconds = 0.12
    /// Silence before and after a line, up to this long, raises its entrance and exit scores.
    static let linePauseContextSeconds = 0.40
    /// A valley that stays within `valleyRunDB` of its minimum this long is preferred as a split.
    static let wordGapSeconds = 0.07
    static let valleyRunDB: Float = 3

    // MARK: Transcript refinement (plan 7)
    static let wordSnapSeconds = 0.060
    static let wordSeconds: ClosedRange<Double> = 0.040...2
    static let maximumWordsPerSecond = 7.0
    static let hallucinationGram = 3
    static let hallucinationRepeats = 3
    static let transcribedCoverage = 0.8
    static let transcribedConfidence: Float = 0.5
    static let clausePauseSeconds = 0.120
    /// A unit edge this close to a protected span's edge does not count as cutting it.
    static let protectedCutToleranceSeconds = 0.030

    // MARK: Ranking and bank (plan 4.4, 4.5)
    static let rhythmicFitPool = 6
    static let rhythmicTieShare: Float = 0.10
    static let tooQuietEnergy: Float = 0.006
    static let tooQuietSNRDB: Float = 6
    static let clippedShare: Float = 0.05
    static let uncertainBoundary: Float = 0.2
    static let bankSize: ClosedRange<Int> = 8...12
    static let headCount = 2
    static let answerCount = 2
    static let stabCount: ClosedRange<Int> = 2...4
    static let siblingSemitones: [Double] = [-2, -3, -4]
    static let textureSemitones: [Double] = [0, 1, 2]
    static let transformSemitones: ClosedRange<Double> = -4...2
    static let anchorMaximumSeconds = 6.0
    /// `LofiSpeechFocus.weight` reaches about 1.75 for clean speech; the component divides by it.
    static let speechWeightScale: Float = 1.75
    /// Probe tuning: a music-led cue (under 15 percent spoken windows) or a best line below
    /// this sound gives no bank; weaker pads than `minimumPadSound` are left out.
    static let minimumSpokenShare = 0.15
    static let minimumAnchorSound: Float = 0.2
    static let minimumPadSound: Float = 0.12
    static let headMaximumSeconds = 3.0
    /// Stab choice: loudness of the stab's syllable over its phrase's mean syllable, in dB, that
    /// counts as fully prominent, and how much prominence weighs against `sound`.
    static let stabProminenceDB: Float = 6
    static let stabProminenceWeight: Float = 0.45
    /// Transcribed stabs that are only function words lose this share of their value.
    static let functionWordStabFactor: Float = 0.6
    /// Transcribed line endings: a sentence end, a clause end, an open end, an ellipsis, a
    /// function word. Acoustic lines rank by `sound` alone.
    static let lineFitSentenceEnd: Float = 1.0
    static let lineFitClauseEnd: Float = 0.92
    static let lineFitOpenEnd: Float = 0.85
    static let lineFitEllipsis: Float = 0.7
    static let lineFitFunctionWord: Float = 0.65
    /// An utterance whose last phrase is a lone fragment (the next sentence's first word) ranks lower.
    static let fragmentTailFactor: Float = 0.8
    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "from", "with", "by", "as",
        "is", "was", "are", "were", "be", "been", "have", "has", "had", "it", "it's", "its", "that", "this", "there",
        "we", "i", "you", "he", "she", "they", "them", "him", "her", "my", "your", "our", "their", "if", "then",
        "uh", "um", "oh", "well", "very", "do", "does", "did", "into", "than", "which", "who", "what",
    ]

    // MARK: Rendering (plan 4.6)
    static let chokeLeadSeconds = 0.002
    static let chokeReleaseSeconds = 0.012
    static let sincHalfTaps = 8
    static let sincPhases = 256
    static let bandWeightFloor: Float = 0.18
    static let bandWeightSmoothing: Float = 0.012
    static let filterWarmupSeconds = 0.010
    static func roleTrimDB(_ role: DialoguePad.Role) -> Float {
        switch role {
        // Mix calibration: stabs as loud as the line (-1 dB before), so a motif's pieces and its full line
        // land at one level (C-B8 per-chop spread; user direction of 19 November 2026: consistent, forward).
        case .anchor, .stab: 0
        case .head, .answer: -1
        case .sibling: -1.5
        case .texture: -5
        }
    }

    // MARK: Performance (plan 5)
    static let gestureOffsetSeconds: ClosedRange<Double> = -0.020...0.025
    static let kickClearanceSeconds = 0.050
    static let landmarkConfidence: Float = 0.5
    static let snareSnapBeats = 1.0
    static let snareToleranceSeconds = 0.015
    static let maximumOccupancy = 0.55
    static let nonNativeShare = 0.40
    static let eventsPerBlock: ClosedRange<Int> = 2...5
    static let breakdownEvents = 2
    static let protectedEndSeconds = 0.080
    static let minimumChokedSeconds = 0.080
    static let dryGapSeconds = 0.004
    static let callResponseSpaceBeats = 2.0
    static let anchorReusePieces = 2
    static let anchorReusePhrases = 16
    /// A line shorter than this never takes over the anchor role from a recurring bank's anchor.
    static let rotatedAnchorMinimumSeconds = 0.7
    static let windowDifference = 0.25
    /// Sixteenths a pattern may move as a whole: out of the rest after a boundary, or (a late
    /// plan) to begin at the next bar.
    static let restShiftSlots = 12
    /// Accent slots of a take-opening anchor hook: the line, then the same line again in bar 3.
    static let hookSlots: [(Int, Int)] = [(8, 40), (16, 44), (8, 36)]
    static let lateShiftSlots = 20
    /// Per-block share that guarantees the 16-bar window difference (|∩| <= 0.75 min).
    static let blockOverlapShare = 0.75
    static let memoryBlocks = 8
    static let memoryAnchorUses = 16
    static let textureFillEvery = 4
    static let textureFillChance: Float = 0.35
}

// MARK: - Source and clocks

/// The only conversion between film seconds and buffer frames (plan 4.1).
nonisolated struct DialogueSource: @unchecked Sendable {
    let contentID: String
    let cueToken: Int
    /// Immutable native-rate PCM, the mono signal duplicated to every channel. Never mutated.
    let buffer: AVAudioPCMBuffer
    /// Film seconds of frame 0.
    let sourceStart: Double
    /// Film seconds per buffer second (1 for a native-rate decode, 0.8 for a slowed decode).
    let rate: Double

    var sampleRate: Double { buffer.format.sampleRate }
    var frameCount: Int { Int(buffer.frameLength) }

    func sourceSeconds(frame: Int) -> Double { sourceStart + Double(frame) / sampleRate * rate }
    func frame(sourceSeconds: Double) -> Int { Int(((sourceSeconds - sourceStart) / rate * sampleRate).rounded()) }
}

/// Film-second mapping without the PCM, kept by the cacheable analysis.
nonisolated struct DialogueClock: Sendable, Equatable {
    let sourceStart: Double
    let rate: Double
    let sampleRate: Double

    func sourceSeconds(frame: Int) -> Double { sourceStart + Double(frame) / sampleRate * rate }
    func frame(sourceSeconds: Double) -> Int { Int(((sourceSeconds - sourceStart) / rate * sampleRate).rounded()) }
}

// MARK: - Units and scores

/// Named ranking components in 0...1 (plan 4.4). Logged per unit.
nonisolated struct DialogueScore: Sendable, Equatable {
    var speech: Float = 1
    var clarity: Float = 0
    var entrance: Float = 0
    var exit: Float = 0
    var stress: Float = 0
    var accentRegularity: Float = 0.5
    var roleFit: Float = 0
    var clipping: Float = 0
    var interference: Float = 0
    var boundaryUncertainty: Float = 1
    var rhythmicFit: Float = 0

    var sound: Float {
        speech * powf(max(0, clarity), 0.7) * (0.5 + 0.5 * entrance) * (0.5 + 0.5 * exit)
            * (0.7 + 0.3 * stress) * (0.8 + 0.2 * accentRegularity) * (1 - 0.6 * clipping)
    }

    var components: [String: Double] {
        ["speech": Double(speech), "clarity": Double(clarity), "entrance": Double(entrance),
         "exit": Double(exit), "stress": Double(stress), "accentRegularity": Double(accentRegularity),
         "roleFit": Double(roleFit), "clipping": Double(clipping), "interference": Double(interference),
         "boundaryUncertainty": Double(boundaryUncertainty), "rhythmicFit": Double(rhythmicFit),
         "sound": Double(sound)].mapValues { ($0 * 1000).rounded() / 1000 }
    }
}

nonisolated struct SpeechUnit: Sendable, Identifiable, Equatable {
    enum Level: Int, Sendable, CaseIterable {
        case utterance, phrase, wordGroup, stab, texture
        var name: String { ["utterance", "phrase", "wordGroup", "stab", "texture"][rawValue] }
    }
    enum Onset: Int, Sendable { case burst, gradual }

    let id: Int
    let parentID: Int?
    let level: Level
    /// Refined playable frames (pre-roll, zero crossings and release included).
    let frames: Range<Int>
    var previousID: Int?
    var nextID: Int?
    var text: String?
    var tokenRange: Range<Int>?
    var recognitionConfidence: Float?
    let boundaryConfidence: Float
    let speechScore: Float
    let interferenceScore: Float
    /// Source frames of the onsets of the strongest nuclei, at most three, in time order.
    let stressAnchors: [Int]
    var protectedSpans: [Range<Int>]
    let tail: Range<Int>
    var score: DialogueScore
    // Additions used by rendering and ranking.
    let fadeIn: Int
    let fadeOut: Int
    let onset: Onset
    let nuclei: Int
    /// Mean band SNR in dB (low, mid, high bands).
    let bandSNR: SIMD3<Float>
    let peakEnergy: Float

    func seconds(_ sampleRate: Double) -> Double { Double(frames.count) / sampleRate }
}

nonisolated struct DialogueRejection: Sendable, Equatable {
    enum Reason: String, Sendable {
        case notSpeech, tooQuiet, tooShort, tooLong, uncertainBoundaries, clipped, overTransformed
        case protectedCut, duplicate
    }
    let unit: Int
    let reason: Reason
}

// MARK: - Pads

nonisolated enum DialogueTransform: Sendable, Hashable {
    case native
    case linkedRate(semitones: Double)

    /// Source frames read per output frame.
    var playbackRate: Double {
        switch self {
        case .native: 1
        case .linkedRate(let semitones): pow(2, semitones / 12)
        }
    }
    var isNative: Bool { self == .native }
    var name: String {
        switch self {
        case .native: "native"
        case .linkedRate(let s): "linkedRate(\(s))"
        }
    }
}

nonisolated struct DialoguePad: Sendable, Equatable {
    enum Role: String, Sendable, CaseIterable { case anchor, head, answer, stab, sibling, texture }

    let padID: Int
    let unitID: Int
    let role: Role
    let frames: Range<Int>
    let transform: DialogueTransform
    /// Source seconds from the pad start to its stress accent at native rate.
    let accentOffset: Double
    /// Rendered seconds at the pad's transform.
    let duration: Double
    let protected: Bool
    let text: String?
    // Additions.
    let fadeIn: Int
    let fadeOut: Int
    let level: SpeechUnit.Level
    let score: DialogueScore
    /// Hash of the source id, the unit frames and the transform (plan 5.4 `padKey`).
    let padKey: UInt64

    /// Rendered seconds from the buffer start to the accent.
    var renderedAccentOffset: Double { accentOffset / transform.playbackRate }
}

nonisolated enum DialogueReorder: Sendable, Equatable {
    enum Template: String, Sendable { case repeatClause, omitParenthetical, moveAdverbial, exchangeClauses }
    case sourceOrder
    case arrangement(units: [Int], template: Template)

    var template: Template? {
        if case .arrangement(_, let t) = self { return t }
        return nil
    }
    var units: [Int] {
        if case .arrangement(let u, _) = self { return u }
        return []
    }
}

nonisolated struct DialoguePadBank: Sendable {
    let bankID: UInt64
    let analysisVersion: Int
    /// Ordered by source time; `padID` is the index.
    let pads: [DialoguePad]
    let anchorPadID: Int
    /// `[base, sibling]` pad ids.
    let siblingGroups: [[Int]]
    // Additions.
    let sourceID: String
    let clock: DialogueClock
    let rejections: [DialogueRejection]
    let usedTranscript: Bool
    let reorder: DialogueReorder
    /// Unit ids in source order and as arranged by the guard (equal without a safe template).
    let originalOrder: [Int]
    let arrangedOrder: [Int]
    let intendedText: String?

    func pad(_ id: Int) -> DialoguePad? { pads.indices.contains(id) ? pads[id] : nil }
    func pads(_ role: DialoguePad.Role) -> [DialoguePad] { pads.filter { $0.role == role } }
    var anchor: DialoguePad { pads[anchorPadID] }
    /// The native pad a sibling was derived from.
    func base(ofSibling id: Int) -> Int? { siblingGroups.first { $0.count == 2 && $0[1] == id }?[0] }
    func sibling(of id: Int) -> Int? { siblingGroups.first { $0.count == 2 && $0[0] == id }?[1] }
}

// MARK: - Transport

nonisolated struct DialogueLandmark: Sendable, Equatable {
    /// Take-relative beats.
    let beat: Double
    let confidence: Float
}

nonisolated struct DialogueTransportSnapshot: Sendable {
    var revision: UInt32
    var takeIndex: Int
    /// Transport seconds of beat 0 of the take.
    var origin: Double
    var beatDuration: Double
    /// Beat length after beat 64, when the next take is already committed at another tempo.
    var nextBeatDuration: Double?
    /// Global phrase index of the take start.
    var phraseAtOrigin: Int
    var kicks: [DialogueLandmark]
    var snares: [DialogueLandmark]
    var leadNotes: [ClosedRange<Double>] = []
    /// The drummer's human offset in beats at each sixteenth of the take (256 values, from
    /// `LofiTimingField.sixteenthOffsets`); empty means a straight grid. The motif's slots follow it.
    var grooveOffsets: [Double] = []

    static let takeBeats = 64.0
    static let takeSixteenths = 256

    /// Transport seconds of a take-relative sixteenth on the drummer's grid (the take's own swing
    /// and push). Sixteenths past the take repeat the same groove on the next take.
    func gridTime(sixteenth s: Int) -> Double {
        let beat = Double(s) / 4
        guard !grooveOffsets.isEmpty else { return time(beat: beat) }
        let n = grooveOffsets.count
        return time(beat: beat + grooveOffsets[((s % n) + n) % n])
    }

    var turn: Double { origin + Self.takeBeats * beatDuration }

    func time(beat: Double) -> Double {
        beat < Self.takeBeats ? origin + beat * beatDuration
            : turn + (beat - Self.takeBeats) * (nextBeatDuration ?? beatDuration)
    }

    func beat(time: Double) -> Double {
        time < turn ? (time - origin) / beatDuration
            : Self.takeBeats + (time - turn) / (nextBeatDuration ?? beatDuration)
    }

    /// Seconds per beat at a take-relative beat.
    func beatLength(at beat: Double) -> Double { beat < Self.takeBeats ? beatDuration : (nextBeatDuration ?? beatDuration) }

    /// Confident landmark times near `beat`. Landmarks repeat every take, so a plan that
    /// crosses beat 64 uses the same drummer pattern on the next take.
    func landmarkTimes(_ marks: [DialogueLandmark], around beat: Double, within beats: Double) -> [Double] {
        var result: [Double] = []
        let base = (beat / Self.takeBeats).rounded(.down) * Self.takeBeats
        for take in [base - Self.takeBeats, base, base + Self.takeBeats] {
            for mark in marks where mark.confidence >= DialogueTuning.landmarkConfidence {
                let b = take + mark.beat
                if abs(b - beat) <= beats { result.append(time(beat: b)) }
            }
        }
        return result.sorted()
    }
}

// MARK: - Plans

nonisolated struct DialogueEvent: Sendable, Equatable {
    let padID: Int
    let role: DialoguePad.Role
    /// Global phrase index of the block.
    let block: Int
    /// Sixteenth slot of the accent inside the block, 0...63.
    let slot: Int
    let accentTime: Double
    let startTime: Double
    /// Dry seconds actually played (shortened when choked).
    let duration: Double
    let gainDB: Float
    let protected: Bool
    /// The later event's start when this one is choked; the buffer ends 2 ms earlier.
    let chokeAt: Double?
    let text: String?
    // Additions.
    let transform: DialogueTransform
    let padKey: UInt64
    let snareLanded: Bool
    // Motif additions (wave 4 `chop-motif`). `duration` includes an echo throw's tail.
    var cell: DialogueCell? = nil
    /// Motif fragment id (the pad id in the motif bank).
    var piece: Int? = nil
    var effect: DialogueChopEffect = .none
    // Gate additions (D126). `gateSteps` is the hit's gate in sixteenths (nil: a one-shot);
    // `gateEnd` how the dry piece ended (`natural`, `gate`, `valley` or `choke`); `drySeconds` the
    // dry length the renderer cuts to (nil: the whole pad, or `duration` for a legacy choke);
    // `sourceFrames` the source actually played.
    var gateSteps: Double? = nil
    var gateEnd = "natural"
    var drySeconds: Double? = nil
    var sourceFrames: Range<Int>? = nil

    var endTime: Double { startTime + duration }
}

/// A light per-piece effect rendered into the chop buffer (motif mode; intelligibility first).
nonisolated enum DialogueChopEffect: Sendable, Hashable {
    case none
    /// Band-limited repeats of the piece at `delay` seconds, rendered into `tail` seconds after the dry piece.
    case echoThrow(delay: Double, tail: Double)
    /// A band-passed repeat ("telephone").
    case filtered
    /// The piece played backwards as a pickup; its end lands just before the next slot.
    case reversed

    var name: String {
        switch self {
        case .none: "none"
        case .echoThrow: "echoThrow"
        case .filtered: "filtered"
        case .reversed: "reversed"
        }
    }
}

/// Cell kinds of the motif layer (docs/plans/mpc-chopping.md, section 5).
nonisolated enum DialogueCell: String, Sendable, CaseIterable {
    // `reorder`, `callAnswer` and `sparse` are no longer arranged (D125: the hook form) but stay so old logs parse.
    case statement, stutter, splitPause, reorder, callAnswer, sparse, returnOpen, turnaround, repair
    /// The loop's repeating 2-bar hook cell (D125).
    case hook
    /// The 16-bar arc's sections (D126 part 2): the whole line, the chop beat, the build into the
    /// halfway drop, the breakdown and the outro's restatement.
    case intro, chopBeat, build, breakdown, outro
}

nonisolated enum DialogueFamily: String, Sendable, CaseIterable {
    case anchor, echo, callResponse, sparseReorder, textureFill, rest
    // Motif blocks are named after the cell that opens them.
    case statement, stutter, splitPause, reorder, callAnswer, sparse, returnOpen, turnaround
    // Appended last: ids are indices, mirrored in scripts/mixlib/cadence.py (D125).
    case hook
    // D126 part 2, appended in the same way.
    case intro, chopBeat, build, breakdown, outro
    var id: UInt64 { UInt64(Self.allCases.firstIndex(of: self)!) }
}

nonisolated struct DialogueBlock: Sendable {
    let phrase: Int
    let section: LofiScore.Section
    let family: DialogueFamily
    let variation: Int
    let fingerprint: UInt64
    let events: [DialogueEvent]
    let forcedChange: Bool
    let noDialogue: Bool
    /// What changed against the previous block ("establish", "omit", "sibling", "shift", ...).
    let change: String
}

nonisolated struct DialoguePerformancePlan: Sendable {
    let sourceID: String
    let cueToken: Int
    let bankID: UInt64
    let analysisVersion: Int
    let seed: UInt64
    let transportRevision: UInt32
    let revision: Int
    let usedTranscript: Bool
    let blocks: [DialogueBlock]
    let rejections: [DialogueRejection]

    var events: [DialogueEvent] { blocks.flatMap(\.events) }
}

/// Element of a block fingerprint: the pad key and accent slot.
nonisolated struct DialogueElement: Sendable, Hashable {
    let padKey: UInt64
    let slot: Int
}

/// One committed block, kept by the bounded memory.
nonisolated struct DialogueBlockRecord: Sendable {
    let phrase: Int
    let bankID: UInt64
    let family: DialogueFamily
    let variation: Int
    let fingerprint: UInt64
    let elements: [DialogueElement]
    /// `(padID, slot)` of the realised events, for one-change variations of the same bank.
    let items: [DialogueItem]
    let occupancy: Double
    let nonNative: Int
    let events: Int
    let snareLanded: Bool
    let leadKey: UInt64?
}

nonisolated struct DialogueItem: Sendable, Equatable {
    var padID: Int
    var slot: Int
    var gesture: Int
}

/// Bounded memory of committed performance (plan 5.3, 5.4).
nonisolated struct DialoguePerformanceMemory: Sendable {
    struct AnchorUse: Sendable, Equatable { let padKey: UInt64; let piece: Int; let phrase: Int }

    private(set) var blocks: [DialogueBlockRecord] = []
    var familyCycleIndex = 0
    var variationCounter = 0
    private(set) var anchorUses: [AnchorUse] = []
    var lastBankID: UInt64?
    var pieceCounter = 0
    var cycleSeed: UInt64?
    /// Transport seconds at which the last committed dry event ends.
    var lastDryEnd: Double?
    /// Pieces already served by the previous bank in the fallback order (plan 5.5).
    var fallbackPieces = 0
    /// The motif of the current (or last) 16-bar loop, with its source PCM so the second piece of
    /// the loop keeps playing the same line when the film changes at bar 9.
    var motif: DialogueMotif?
    /// Lines that led a loop, newest last (bounded).
    var motifLines: [DialogueMotifLineUse] = []
    /// Full-line statements the motif's loop has played so far.
    var motifLineStatements = 0
    /// Recent films heard by the dialogue layer, newest last (bounded by `DialogueMotifTuning.crateSize`):
    /// when a loop's own film has no usable line, the motif digs a fresh line from one of these.
    var motifCrate: [DialogueMotifCrateEntry] = []
    /// Lines played in earlier sessions and cues (D123). In memory unless the coordinator hands in
    /// `DialogueLineLedger.shared`; shared by reference, written only on commit.
    var ledger = DialogueLineLedger()

    init() {}

    init(ledger: DialogueLineLedger) { self.ledger = ledger }

    func record(phrase: Int) -> DialogueBlockRecord? { blocks.last { $0.phrase == phrase } }

    mutating func remember(_ record: DialogueBlockRecord) {
        blocks.removeAll { $0.phrase == record.phrase }
        blocks.append(record)
        blocks.sort { $0.phrase < $1.phrase }
        if blocks.count > DialogueTuning.memoryBlocks { blocks.removeFirst(blocks.count - DialogueTuning.memoryBlocks) }
    }

    mutating func useAnchor(_ key: UInt64, piece: Int, phrase: Int) {
        let use = AnchorUse(padKey: key, piece: piece, phrase: phrase)
        guard !anchorUses.contains(use) else { return }
        anchorUses.append(use)
        if anchorUses.count > DialogueTuning.memoryAnchorUses {
            anchorUses.removeFirst(anchorUses.count - DialogueTuning.memoryAnchorUses)
        }
    }

    /// Distinct earlier pieces that stated `key` as their lead within the last 64 bars.
    func anchorPieces(_ key: UInt64, before piece: Int, phrase: Int) -> Int {
        Set(anchorUses.filter {
            $0.padKey == key && $0.piece < piece && phrase - $0.phrase < DialogueTuning.anchorReusePhrases
        }.map(\.piece)).count
    }
}

/// A rendered statement. The buffer is never mutated after rendering.
nonisolated struct DialogueChop: @unchecked Sendable {
    let event: DialogueEvent
    let buffer: AVAudioPCMBuffer
}

// MARK: - Transcript

nonisolated struct DialogueTranscript: Sendable, Equatable {
    struct Word: Sendable, Equatable {
        let text: String
        /// Film seconds.
        let start: Double
        let end: Double
        let confidence: Float?
    }
    let locale: String
    let modelVersion: String
    let words: [Word]
}

// MARK: - Hashing

/// FNV-1a, stable across launches (Swift's `Hasher` is randomly seeded).
nonisolated struct DialogueHash {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    mutating func add(_ x: UInt64) {
        for i in 0..<8 {
            value ^= (x >> (8 * UInt64(i))) & 0xff
            value &*= 0x100000001b3
        }
    }
    mutating func add(_ x: Int) { add(UInt64(bitPattern: Int64(x))) }
    mutating func add(_ x: Double) { add(x.bitPattern) }
    mutating func add(_ s: String) {
        for byte in s.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        add(UInt64(s.utf8.count))
    }
    mutating func add(_ t: DialogueTransform) {
        switch t {
        case .native: add(0 as UInt64)
        case .linkedRate(let s): add(1 as UInt64); add(s)
        }
    }

    static func padKey(sourceID: String, frames: Range<Int>, transform: DialogueTransform) -> UInt64 {
        var h = DialogueHash()
        h.add(sourceID)
        h.add(frames.lowerBound)
        h.add(frames.upperBound)
        h.add(transform)
        return h.value
    }
}
