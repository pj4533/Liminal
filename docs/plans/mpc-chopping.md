# MPC-style dialogue chopping, per-bus mix and master: implementation plan

19 November 2026. Branch `feature/mpc-chopping` (local only, never pushed). Baseline commit `c42f1b5`.

Inputs: [handoff](../research/mpc-chopping-handoff.md), [craft notes](../research/mpc-chopping-craft.md), [mix engineering notes](../research/lofi-mix-engineering.md), [technical notes](../research/mpc-chopping-technical.md), and a code audit of the baseline. This plan implements handoff phases 1 to 3 in full and phase 4 only where a measured need appears (section 13 lists what is deferred and why).

Status: plan. Numbers marked *start* are tuning hypotheses exposed as named constants. Numbers in section 9 are acceptance criteria.

> **User direction, 19 November 2026 (binding; overrides 8.5, 8.6, C-B6 and C-B9 where they conflict).** The film bed and the dialogue chops are two different layers with different jobs.
>
> - **Dialogue chops are the forward layer, loud and very present.** They are part of the beat, woven into the drums, bass, mids and lead, and sit up front in the mix. Do not pull the chops back to make room for other layers. Fix any conflict with the theme return through placement (dialogue leaves the return's first bar free, see 5.2), not by lowering the chops overall.
> - **The film bed is background only, and it keeps its current effected sound.** It is the unchopped footage audio. The baseline chain at `c42f1b5` is already what the user wants and must be preserved, not made clearer:
>   - reverb and tape-delay sends at 1.3 × a 0.95–1.95 contour;
>   - the beat-locked phaser sweep at 0.36–0.58 wet;
>   - dark band-limiting (high-pass about 205–290 Hz, two low-pass stages at 2.1–3.2 kHz);
>   - tempo-linked delay.
>
>   Do **not** apply 8.6's "clarity" changes: no reduced sends, no opened second low-pass, no 10 kHz `MixBus` low-pass, no drier direct level. Tempo-synced effects may be added but never removed. The bed must stay audible, but it sits well under the beat: in gaps between chops it is at least 10 dB under the music plus chops (*start*).
> - **The bed never drives ducking.** Nothing is sidechained to or ducked by the film bed. Chops may still duck the bed, and the music may stay on top of it, but the bed is never a key signal.
> - **Criteria changes.** C-B9's "bed direct to wet at least +3 dB" and "roll-off at least 3 kHz" are dropped. They are replaced by "bed effects chain matches the baseline character (wet at least equal to direct)" and "bed at least 10 dB under the music plus chops in gaps, audibility index in gaps still at least 0.20". In C-B6, theme-return salience may be judged against mids, space and bed only. The chops are a featured layer, so failing to clear them is not a defect if the return's first bar is chop-free.

> **User direction on chopping, 19 November 2026 (binding; overrides section 5's families, rest blocks and occupancy budgets where they conflict).** The user heard a 32-bar render. It repeated whole lines ("when they want to investigate" four times, plus one slowed, unintelligible chunk) and left bars 8–17 empty.
>
> What the user wants is how a producer chops on an MPC:
> - **Pick one line per 16-bar loop.** That line is the motif.
> - **Split it into logical pieces.** Use words and word groups ("when they" | "want to" | "investigate"), and split long words at syllables ("invest" | "tigate").
> - **Drop the pieces on the beat, with pauses, so it's funky:**
>   - repeat pieces, back to back or with a gap ("when they… when they");
>   - split a piece with a pause ("when…..they");
>   - land pieces on downbeats ("…want to invest…..tigate");
>   - reorder pieces ("…want to invest….when they").
> - **Play the full line rarely**, at most twice in 16 bars.
> - **Keep the pieces on the grid and intelligible.** Native rate only; no slowed chunks. Effects are light.
> - **No gaps.** Every bar of every 16-bar loop has at least one piece onset, including the breakdown and the return.
> - **The chops stay loud and forward in the beat.**
>
> This is implemented by wave 4 package `chop-motif`. Mix calibration runs after it in wave 5.

> **User direction after the calibrated clips, 19 November 2026 (binding; supersedes "chops loud and forward" and C-B8's old bounds).**
>
> - **Fresh samples, always.** One line for 32 bars was a bug. Every 16-bar loop must lead with a fresh line. A film with no usable line must not make the loop repeat the previous one. Guard against it in tests and in the capture analyzer.
> - **Chops tucked into the mix.** The chops were "way too loud... they need to fit into the mids and melody better. They just stick out frequency wise." Blend them with level, EQ, compression and light, dark reverb, not by ducking the music under them.
> - **Heavy effects stay.** Echo with many repeats, reverse pickups and reverb, as approved before.
>
> See "Heavier chop effects and the line refresh" and "Tuck pass" in [the measurements](mpc-chopping-measurements.md).

> **User direction on chop effects and blend, 19 November 2026 (binding, for wave 5 `mix-calibration` and later rounds).** The user approved the word-piece motif chopping ("way better… definitely go with that") and asked for two changes. `mix-calibration` may edit the effect constants in `DialogueMotif.swift` and the chop chain and returns in `ArchiveVoice.swift` and `DialogueChopRenderer.swift`.
>
> 1. **Much heavier effects on the chops.**
>    - Tempo echo: more of it, with more feedback and repeats; echo throws on most cell endings and on stutters.
>    - Reverse: more frequent reversed pickups, about one per 2–4 bars.
>    - Reverb: more, with a clearly audible room or plate tail.
>    - Filtered repeats: more of them.
>    - The dry piece stays intelligible and on the grid. The effects carry the space between pieces.
> 2. **Chops glued into the mix.** In the 72 BPM render they stood out on top of the music. They need more compression and limiting so they sit inside the beat while staying forward and loud. That means a firmer chop-bus compressor and a peak limiter for a consistent level, and possibly a light, short duck of the music under the chops instead of more chop level. Chops should not read as a separate layer on top.
>
> The user's next clip should come from a capture that uses the transcript path when on-device Apple transcription assets are available, so pieces align with real words.

> **User direction on tight, gated chops and the 16-bar arc, 21 November 2026 (binding; supersedes craft note 1.5's "gating is for texture only" and the D125 rule that pieces play to their natural end).** After the D125 hook build on Vision Pro: "it still feels ... like the chops aren't tight enough ... you need to pay more attention to the waveform of the sample so that, when you trigger the sample, it immediately hits the word on beat. And they need to be shorter ... it only plays when you hold it ... let more of a waveform play if it hits on beat, but if it doesn't, you like stop it ... shorter chops that are always on beat but triggered, repeated, held ... as long as you're still telling the whole story." Each 16 bars should introduce the whole line, then chop it into a little beat (a word here, a word and a syllable there), build up, break down and close with an outro that plays the whole line again with some parts repeated, varied so it is never the same twice.
>
> 1. **Tight.** A chop's sound starts on its step: pads start at the waveform onset, the word's attack lands on the step, and the step follows the drummer's own hit, never a neighbour's (D126, done).
> 2. **Short and gated.** Every hit is held for a gate in sixteenths and cut before the next step, so the same pad can play as a stab, a syllable, a word or the whole phrase (D126, done for the D125 arrangement).
> 3. **The 16-bar arc.** Intro (the whole line on the downbeat), chop beat, build, breakdown and outro, varied by seed (D126 part 2, done; the gates' hold-through past a fragment and the C-D10 to C-D12 capture criteria remain).

## 1. Goals and non-goals

Goals

1. Dialogue from each incoming film becomes a small stable bank of related cuts ("pads") performed against AJ Hall's takes with a bounded grammar: anchor, echo, call-response, sparse-reorder, texture-fill, with rests and returns. A kept pattern changes one dimension at a time.
2. The dialogue performance changes at least every 16 bars (enforced in code, logged, and checked from captures).
3. Analysis never delays the film bed or the music. The bed is published as soon as it is decoded; the plan arrives later at a safe bar boundary.
4. Music work from the handoff: film bed clarity, theme-return recognition, louder and more varied mids that answer the melody, bass punch with three bounded voices, multiband drum attack landmarks and a sparse shared timing field.
5. Optional local transcription (SpeechAnalyzer and SpeechTranscriber) with conservative safe reordering. The acoustic path always remains.
6. Every section (drums, bass, mids, lead, dialogue chops, film bed) has its own effect chain and spectral slot. The master is loud and competitive, true-peak safe, with controlled crest and gain reduction and no pumping or distortion.
7. Verification that does not need ears: per-bus stems, multi-resolution spectrograms, band energy and masking, low-band mono and correlation, kick and bass windows, crest, LUFS, true peak, limiter gain reduction, intelligibility proxies and chop cadence, produced by one command and documented.

Non-goals: new user-facing style controls, cloud inference, handpicked dialogue, replacing AJ Hall's takes with reconstructed hits, an iOS target, changes to Ambient mode's sound.

## 2. Architecture

```text
footage piece (8 bars in Lo-Fi) ── decode ──► film bed cue (posted at its due time, never waits)
        │                                      └► ArchiveVoice bed chain ► MixBus ► master
        └─ DialogueCueCoordinator (utility task, cancellable, token + transport revision)
             native-rate source PCM ► DialogueAnalyzer ► DialogueHierarchy ► DialogueBankBuilder
             (+ SoundAnalysis speech windows, + optional transcript at a later block)
             LofiTransportInfo (revision, phrase, timing field, arrangement key)
             ► DialoguePerformer (grammar, cadence memory) ► DialogueChopRenderer
             ► MusicControl.archiveChops(plan) ► ArchiveVoice incremental sample-time scheduling
                                                 ► chop FX ► LofiBus ► master

drum take (64 beats) ► LofiDrumLandmarks ► LofiTimingField ─► LofiScore (bass accents, mid answers)
                     ► drum bus chain (offline)              └► dialogue stress placement
LofiScore ► LofiRenderer ► per-stem chains (offline: bass, lead, mids, space) ► LofiBus players
LofiBus + film path ► LofiMasterBus: [ambient: Apple glue + limiter] / [lofi: LofiMasterFinisher]
```

Design rules

- Music stems, drum takes and dialogue chops are rendered to buffers off the audio thread. Their effect chains run there in plain Swift (deterministic, testable, no realtime limits). Only the film bed chain, the chop echo and room, the bus duck faders and the master run in the live graph.
- The master finisher is the only custom realtime DSP. It is an in-process `AUAudioUnit` whose kernel owns preallocated memory and uses Accelerate block operations. No allocation, lock, I/O or inference on the render thread.
- New pure types are `nonisolated` and `Sendable` (the project default isolation is `MainActor`). New files are picked up by the file-system-synchronized Xcode groups; `project.pbxproj` is not edited.
- Ambient mode keeps its present master path bit for bit apart from a constant delay.

## 3. Frozen interfaces between work packages

These names are contracts. A package may add members; it may not rename or change the meaning of these.

### 3.1 Capture hooks (wave 1, package `verify-tooling`)

`Liminal/Audio/Lofi/LofiCaptureHooks.swift`

```swift
nonisolated enum LofiCaptureHooks {
    struct Tap { let name: String; let node: AVAudioNode }
    static var isEnabled: Bool { get }                       // false in the app
    static func begin(options: [String: String])              // harness only: enable, clear, store options
    static func end()
    static func option(_ key: String) -> String?
    static func tap(_ name: String, _ node: AVAudioNode)      // no-op unless enabled; name ^[a-z0-9][a-z0-9-]*$
    static func report(_ key: String, _ value: Any)           // JSON value, becomes manifest.diagnostics[key]
    static func appendReport(_ key: String, _ element: Any)   // manifest.diagnostics[key] is an array
    static func file(_ name: String, _ data: Data)            // extra artifact, name ends .json or .csv
    static func onFinish(_ body: @escaping @Sendable () -> Void) // run after the render, before the manifest
    static var taps: [Tap] { get }
    static var reports: [String: Any] { get }
    static var files: [String: Data] { get }
    static func runFinishers()
}
```

Lock-guarded, never touched on the render thread. Components register taps and reports in their initializers or offline code paths. The harness never needs editing to add a tap.

Options in use: `masterProfile` (`lofi` default in captures, `ambient`), `transcription` (`off` default, `fixture`, `apple`), `dialogue` (`engine` default from wave 2, `legacy`).

### 3.2 Capture manifest v2

`manifest.schema = "liminal-lofi-capture-v2"`. Existing keys stay. New keys:

| Key | Content |
|---|---|
| `sections` | `{"drums":["drums"],"bass":["bass"],"mids":["texture"],"lead":["dry"],"space":["wet"],"dialogue":["dialogue-chops"],"bed":["footage"]}` |
| `grid` | `{"beatFrames", "barFrames", "phraseFrames", "takeFrames"}` (floats) |
| `dialogueChops[]` | adds `durationFrames`; from wave 2 also `padID`, `role`, `family`, `block`, `protected`, `accentFrame`, `transform`, `text` |
| `dialogueTimings[]` | `{cue, classifyMs, analyzeMs, bankMs, planMs, renderMs, totalMs}` wall clock per cue |
| `diagnostics.dialoguePlans[]` | `{cue, sourceID, bankID, analysisVersion, seed, transportRevision, revision, usedTranscript, pads[], blocks[{phrase, section, family, variation, fingerprint, events[]}], rejections[{unit, reason}]}` |
| `diagnostics.masterDynamics` | `{profile, ceilingDbtp, latencyFrames, glue{meanDb,p95Db,maxDb}, clip{engagedFraction,maxDb}, limiter{meanDb,p95Db,maxDb,above3dbFraction}, traceFile, traceHopFrames}` |
| `diagnostics.landmarks[]` | `{take, name, kicks[{frame, peakFrame, strength, confidence}], snares[...]}` in capture frames |
| `diagnostics.stemChains[]` | `{phrase or take, bus, inPeakDb, outPeakDb, inRmsDb, outRmsDb, grMeanDb, grMaxDb}` |
| `diagnostics.bass[]` | `{phrase, voice, notes[{frame, attackFrame, alignedKickFrame}]}` |

Extra file `master-gr.csv`: `frame,glue_db,clip_db,limiter_db`, one row per `traceHopFrames` (64).

### 3.3 DSP toolkit and master finisher (wave 1, package `dsp-core`)

`Liminal/Audio/Lofi/DSP/`

```swift
nonisolated struct LofiBiquad: Sendable {
    enum Kind: Sendable, Equatable {
        case highpass(hz: Double, q: Double), lowpass(hz: Double, q: Double)
        case peak(hz: Double, q: Double, gainDB: Double)
        case lowShelf(hz: Double, gainDB: Double), highShelf(hz: Double, gainDB: Double)
        case bandpass(hz: Double, q: Double), allpass(hz: Double, q: Double)
    }
    init(_ kind: Kind, sampleRate: Double)
    mutating func process(_ x: Float) -> Float
    mutating func reset()
    func magnitudeDB(at hz: Double) -> Double
}
nonisolated struct LofiFilterChain: Sendable {            // offline, stereo, shared coefficients
    init(_ kinds: [LofiBiquad.Kind], sampleRate: Double)
    mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int)
}
nonisolated struct LofiCompressor: Sendable {
    struct Settings: Sendable, Equatable {
        var thresholdDB: Float, ratio: Float, kneeDB: Float, attack: Double, release: Double
        var makeupDB: Float = 0, sidechainHighpassHz: Double? = nil, rmsWindow: Double = 0
    }
    init(_ settings: Settings, sampleRate: Double)
    mutating func gain(detectorLeft: Float, detectorRight: Float) -> Float   // linked linear gain incl. makeup
    private(set) var reductionDB: Float
    struct Stats: Sendable { var meanDB: Float; var maxDB: Float }
    mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Stats
}
nonisolated struct LofiDeEsser: Sendable { init(band: ClosedRange<Double>, maxReductionDB: Float, sampleRate: Double); mutating func process(_ x: Float) -> Float }
nonisolated enum LofiSaturation {
    static func tape(_ x: Float, drive: Float) -> Float                    // odd, unity small-signal gain
    static func softClip(_ x: Float, threshold: Float, ceiling: Float) -> Float
    static func process(left:right:count:drive:oversampling:)               // offline, 2x or 4x
}
nonisolated enum LofiStereo {
    static func monoBelow(_ hz: Double, left:, right:, count:, sampleRate:)  // LR4 split, low band summed
    static func correlation(left:, right:, count:) -> Float
}
nonisolated enum LofiTruePeak { static func linear(_ samples: UnsafePointer<Float>, count: Int, factor: Int) -> Float }  // 4 or 16
nonisolated enum LofiLoudness {
    struct Result: Sendable { let integrated: Double; let shortTermMax: Double; let momentaryMax: Double; let range: Double }
    static func measure(left: [Float], right: [Float], sampleRate: Double) -> Result   // BS.1770-4 gating
}
nonisolated struct LofiMasterSettings: Sendable, Equatable {
    var inputGainDB: Float, highpassHz: Double
    var glue: LofiCompressor.Settings?
    var clipThresholdDB: Float?, ceilingDBTP: Float, lookahead: Double, releaseFast: Double, releaseSlow: Double
    static let passthrough: Self        // unity gain, latency only
    static let lofi: Self               // section 8.7
}
nonisolated struct LofiMasterMeters: Sendable { var glueDB, clipDB, limiterDB: (mean: Float, p95: Float, max: Float); var limiterAbove3dBFraction: Float; var clipEngagedFraction: Float; var frames: Int }
nonisolated struct LofiMasterTracePoint: Sendable { let frame: Int; let glueDB: Float; let clipDB: Float; let limiterDB: Float }
final class LofiMasterKernel { /* preallocated; process(inL,inR,outL,outR,count); latencyFrames */
    static func processOffline(left: [Float], right: [Float], settings: LofiMasterSettings, sampleRate: Double, blockSize: Int)
        -> (left: [Float], right: [Float], meters: LofiMasterMeters, trace: [LofiMasterTracePoint])
}
nonisolated final class LofiMasterFinisher: Node {
    init(_ input: Node, settings: LofiMasterSettings = .passthrough)
    func apply(_ settings: LofiMasterSettings, ramp: Double)
    var meters: LofiMasterMeters { get }; func resetMeters()
    func startTrace(capacity: Int); func takeTrace() -> [LofiMasterTracePoint]   // offline diagnostics
    var latency: Double { get }
}
```

### 3.4 Dialogue engine (wave 1, package `dialogue-core`)

`Liminal/Audio/Lofi/Dialogue/`

```swift
nonisolated struct DialogueSource: @unchecked Sendable {
    let contentID: String, cueToken: Int, buffer: AVAudioPCMBuffer   // immutable native-rate mono-duplicated PCM
    let sourceStart: Double, rate: Double                            // film seconds of frame 0; film seconds per buffer second
    func sourceSeconds(frame: Int) -> Double; func frame(sourceSeconds: Double) -> Int
}
nonisolated struct SpeechUnit: Sendable, Identifiable {
    enum Level: Int, Sendable { case utterance, phrase, wordGroup, stab, texture }
    let id: Int, parentID: Int?, level: Level, frames: Range<Int>
    let previousID: Int?, nextID: Int?
    var text: String?, tokenRange: Range<Int>?, recognitionConfidence: Float?
    let boundaryConfidence: Float, speechScore: Float, interferenceScore: Float
    let stressAnchors: [Int], protectedSpans: [Range<Int>], tail: Range<Int>
    let score: DialogueScore                                          // named components, logged
}
nonisolated struct DialoguePad: Sendable { enum Role { case anchor, head, answer, stab, sibling, texture }
    let padID: Int, unitID: Int, role: Role, frames: Range<Int>, transform: DialogueTransform, accentOffset: Double, duration: Double, protected: Bool, text: String? }
nonisolated enum DialogueTransform: Sendable, Hashable { case native, linkedRate(semitones: Double) }
nonisolated struct DialoguePadBank: Sendable { let bankID: UInt64, analysisVersion: Int, pads: [DialoguePad], anchorPadID: Int, siblingGroups: [[Int]] }
nonisolated struct DialogueTransportSnapshot: Sendable {
    var revision: UInt32, takeIndex: Int, origin: Double, beatDuration: Double, nextBeatDuration: Double?
    var phraseAtOrigin: Int                         // global phrase index of the take start
    var kicks: [DialogueLandmark], snares: [DialogueLandmark]   // take-relative beats, confidence
    var leadNotes: [ClosedRange<Double>]            // take-relative beats, may be empty
    func time(beat: Double) -> Double; func beat(time: Double) -> Double
}
nonisolated struct DialogueEvent: Sendable { let padID: Int, role: DialoguePad.Role, block: Int, slot: Int
    let accentTime: Double, startTime: Double, duration: Double, gainDB: Float, protected: Bool, chokeAt: Double?, text: String? }
nonisolated struct DialoguePerformancePlan: Sendable {
    let sourceID: String, cueToken: Int, bankID: UInt64, analysisVersion: Int, seed: UInt64
    let transportRevision: UInt32, revision: Int, usedTranscript: Bool
    let blocks: [DialogueBlock]                     // one per 4-bar phrase: family, variation, fingerprint, events
    let rejections: [DialogueRejection]
    var events: [DialogueEvent] { get }
}
nonisolated struct DialoguePerformanceMemory: Sendable { /* bounded: last 8 block fingerprints, family cycle, variation counter, anchor use counts, last bank */ }
nonisolated struct DialogueChop: @unchecked Sendable { let event: DialogueEvent; let buffer: AVAudioPCMBuffer }
nonisolated enum DialogueEngine {
    static let analysisVersion: Int
    static func analyze(_ source: DialogueSource, speech: [LofiSpeechFocus.Window]) -> DialogueAnalysis
    static func bank(_ analysis: DialogueAnalysis, transcript: DialogueTranscript?, seed: UInt64) -> DialoguePadBank?
    static func perform(_ bank: DialoguePadBank, snapshot: DialogueTransportSnapshot, window: Range<Double>,
                        earliestStart: Double, memory: inout DialoguePerformanceMemory, seed: UInt64) -> DialoguePerformancePlan
    static func render(_ plan: DialoguePerformancePlan, bank: DialoguePadBank, source: DialogueSource, analysis: DialogueAnalysis) -> [DialogueChop]
    static func log(_ plan: DialoguePerformancePlan, bank: DialoguePadBank?) -> [String: Any]   // diagnostics.dialoguePlans element
}
nonisolated struct DialogueTranscript: Sendable { struct Word: Sendable { let text: String; let start: Double; let end: Double; let confidence: Float? }
    let locale: String, modelVersion: String, words: [Word] }                                   // film seconds
protocol TranscriptProvider: Sendable { func transcript(for source: DialogueSource, deadline: ContinuousClock.Instant) async -> DialogueTranscript? }
nonisolated struct NullTranscriptProvider: TranscriptProvider
nonisolated struct FixtureTranscriptProvider: TranscriptProvider
nonisolated enum DialogueTranscription { static func makeProvider() -> any TranscriptProvider }   // Null in wave 1, Apple-backed in wave 2
```

### 3.5 Drum landmarks, timing field and bass voices (wave 1, package `rhythm-foundation`)

```swift
nonisolated struct LofiDrumLandmark: Sendable, Equatable { enum Kind: Int, Sendable { case kick, snare, hat, other }
    let kind: Kind, attackFrame: Int, peakFrame: Int, strength: Float, confidence: Float }
nonisolated struct LofiTimingField: Sendable {
    let landmarks: [LofiDrumLandmark]                     // sorted, take frames
    func kicks(phraseStartBeat: Int, minConfidence: Float) -> [Double]       // phrase-local beats of attacks
    func snares(phraseStartBeat: Int, minConfidence: Float) -> [Double]
    func nearestAttack(beat: Double, kind: LofiDrumLandmark.Kind, within: Double) -> (beat: Double, confidence: Float)?
    func offset(atBeat: Double) -> Double                 // sparse interpolated human offset in beats, 0 when unknown
}
extension LofiDrumTake { var landmarks: [LofiDrumLandmark] { get }; var timing: LofiTimingField { get } }   // `kicks` stays unchanged
nonisolated enum LofiBassVoice: Int, CaseIterable, Sendable { case classic, roundSub, pluck, longAnswer
    var attackLead: Double { get }                         // seconds from note start to the audible attack landmark
    static func add(_ note: LofiScore.Note, voice: LofiBassVoice, clock: LofiClock, left:, right:)
}
```

### 3.6 Runtime controls (wave 2, package `dialogue-runtime`)

```swift
extension ArchiveVoice { struct ChopPlan: @unchecked Sendable { let token: Int, revision: Int, replaceFrom: Double, chops: [DialogueChop], bedDuck: Bool } }
enum MusicControl { ... case archiveChops(ArchiveVoice.ChopPlan) }
nonisolated struct LofiTransportInfo: Sendable {   // published through MusicStateBus side channel, not inside MusicState
    let revision: UInt32, takeIndex: Int, phraseAtTakeStart: Int, origin: Double, beatDuration: Double, nextBeatDuration: Double?
    let seed: UInt64, options: LofiOptions, timing: LofiTimingField?
}
extension MusicStateBus { func setTransport(_ info: LofiTransportInfo?); func transport() -> LofiTransportInfo? }
```

### 3.7 Master bus (wave 2, package `master-bus`)

```swift
extension LofiMasterBus { enum Profile: String, Sendable { case ambient, lofi }
    func setProfile(_ profile: Profile, ramp: Double); var profile: Profile { get }; var finisher: LofiMasterFinisher { get } }
```

Default profile is `ambient` (legacy behavior). The engine selects `lofi` before Lo-Fi starts. Captures select it through the `masterProfile` hook option.

## 4. Dialogue: source to pad bank

### 4.1 Source and clocks

- The bed keeps the existing decode (`cue.rate`, normalisation to -26 dBFS RMS, soft clip at -9 dBFS).
- The dialogue source is native rate. When `cue.rate >= 0.97` the bed buffer is reused. When the cue is slowed (20 percent of pieces), the coordinator decodes the same film range a second time at rate 1 for analysis and chops, so chops are never pitch-dropped by the picture rate.
- `DialogueSource` holds the only conversion between film seconds and buffer frames. Transcript word times are film seconds. Plan times are transport seconds on the take grid clock. No other code mixes these.
- Only the first `min(32 s, cue span)` is analysed.

### 4.2 Analysis (10 ms hop)

1. Three-band envelopes as today (corners 145, 820, 3900 Hz; floor at the 20th percentile; gate `max(0.0025, 0.19 x p80)`).
2. Speech intensity contour in 300 to 3000 Hz (dB).
3. Syllable nuclei (de Jong and Wempe): local maxima above `p99 - 25 dB`, at least a 2 dB dip between neighbours, voiced (normalised autocorrelation peak above 0.3 for lags of 70 to 400 Hz in a 30 ms frame, or low zero-crossing rate).
4. Pauses: intensity below `noise + 6 dB` for at least 180 ms ends an utterance; 80 ms or more marks a pause group.
5. Onset type at each unit start: burst (rise under 15 ms) or gradual (fricative or vowel).
6. Clipping share (flat tops near the soft-clip ceiling) and per-unit band SNR.
7. Speech windows from `LofiSpeechFocus` (SoundAnalysis), with a 0.9 s budget. Without them, weights are neutral.

### 4.3 Hierarchy

| Level | Span (*start*) | Built from |
|---|---|---|
| utterance | 0.7 to 6 s, at least 3 nuclei | pause-delimited; longer spans split at the deepest inner pause |
| phrase | 0.7 to 3 s | pause groups or nuclei valleys inside an utterance |
| wordGroup | transcript only | recognised words or groups whose boundaries pass acoustic refinement |
| stab | 0.15 to 0.6 s, 1 or 2 nuclei | onset to next valley |
| texture | 60 to 150 ms | vowel core, non-semantic |

Each unit keeps its parent, its neighbours in source order, its stress anchors (onset of the strongest nuclei, at most three), protected spans and its natural tail.

Boundary refinement: move a cut to the nearest energy minimum within 30 ms; start 5 to 20 ms before a burst onset and 10 to 30 ms before a gradual onset; snap to a zero crossing within 2 ms; fade in 3 to 8 ms; release 8 to 20 ms after the valley and tail. `boundaryConfidence` maps valley depth (4 dB gives 0.2, 12 dB or more gives 1).

Invariants (tested): children lie inside parents; the children of a unit in source order cover it with no duplicated and no missing frames outside pauses; no read outside the buffer; no cut inside a protected span.

### 4.4 Ranking

Named components in 0 to 1, logged per unit: `speech`, `clarity`, `entrance`, `exit`, `stress`, `accentRegularity` (low variance of inter-stress intervals), `roleFit`; penalties `clipping`, `interference`, `boundaryUncertainty`.

```text
sound = speech * clarity^0.7 * (0.5 + 0.5 entrance) * (0.5 + 0.5 exit) * (0.7 + 0.3 stress)
        * (0.8 + 0.2 accentRegularity) * (1 - 0.6 clipping)
```

Rhythmic fit is evaluated only among the six best units by `sound`, and only breaks ties within 10 percent. Hard rejections carry a reason: `notSpeech`, `tooQuiet` (never amplified to pass), `tooShort`, `tooLong`, `uncertainBoundaries`, `clipped`, `overTransformed`.

### 4.5 Pad bank

8 to 12 pads (fewer when the film offers less), ordered by source time, stable ids:

| Role | Count | Rule |
|---|---|---|
| anchor | 1 | best utterance or phrase, native, protected ending |
| head | 1 or 2 | first clause of the anchor, or the best other phrase |
| answer | 1 or 2 | the unit that follows the head in source order |
| stab | 2 to 4 | stressed word or syllable group from the anchor; first phonemes differ where possible |
| sibling | 1 | one stab or head at a single linked-rate step, -2 to -4 semitones (rate 0.79 to 0.89) |
| texture | 0 or 1 | vowel core; may be +1 to +2 semitones; never a protected phrase |

`bankID` hashes the content id, source range, analysis version and pad list. Pads render once and are cached; repeats reuse the same buffer, so the first statements are bit-identical.

Bank cache: key `(contentID, sourceStart to 10 ms, length, analysisVersion, locale, modelVersion)`; four entries with PCM, twelve without.

### 4.6 Rendering one pad

Linked-rate resample (linear interpolation at the source rate; windowed sinc when the rate is below 1), per-band noise weighting as today but without the fixed -18 dB cut above 3.9 kHz, edges from 4.3, then the per-cut chain of section 8.5 (added in wave 3), then K-weighted levelling (`clipGain`, target 0.132, peak cap 0.44). Role trims: anchor 0 dB, head and answer -1 dB, stab -1 dB, sibling -1.5 dB, texture -5 dB.

## 5. Dialogue: the motif layer and cadence

Wave 4 package `chop-motif` replaced the block grammar with a motif layer, following the user's direction on chopping (top of this plan). The grammar's families, rest blocks and occupancy budgets remain only as the fallback for a session that has no usable line yet (5.6). Code: `Liminal/Audio/Lofi/Dialogue/DialogueMotif.swift`. Tuning constants: `DialogueMotifTuning`.

### 5.1 One line per 16-bar loop

- A loop is one drum take: 16 bars, 4 blocks, 256 sixteenths. Its index is the global phrase divided by 4.
- The first cue that reaches a loop chooses the motif line from its own analysis.
  - Candidates are utterance, phrase and word-group units with at least three syllable nuclei and 1.2 to 4.0 s long. When none qualifies, the range relaxes to 0.7 to 4.5 s. A line never spans more than 1.4 bars.
  - Rank: `sound × lineFit` (section 4.4). A transcribed line gets × 1.25. A line longer than 2.6 s loses up to 20 percent at 4 s.
- The loop keeps its line when the film changes at bar 9.
  - The motif (`DialogueMotif`) carries its source PCM and analysis in `DialoguePerformanceMemory.motif`.
  - The second cue renders its pieces from that source. The rendered buffers do not depend on the bed, so nothing in the architecture forbids this.
- A new loop chooses a new line.
  - A line may lead at most two loops (`lineUses`), and never two loops in a row.
  - A line that overlaps the previous loop's line by more than half also counts as the same line.
- When the loop's film has no bank (music-led or silent), the previous motif is carried with a new seeded arrangement, logged as `motif:carried`. Coverage wins over novelty here. The 16-bar change rule still holds through the new arrangement.

### 5.2 Pieces

The line is cut into pieces that tile it in source order, then into syllable halves.

- **Transcribed lines.** Pieces are word groups taken from the refined word spans ("when they" | "want to" | "investigate").
  - A group shorter than 0.25 s takes the next word. A group holds at most three words.
  - A pause of 120 ms or more always separates groups.
- **Acoustic lines.** Pieces follow the deepest and longest valleys between syllable nuclei.
  - Valleys are scored as depth in dB plus 40 × the time the envelope stays within 3 dB of the minimum, so a word gap beats a syllable dip.
  - Target: about one piece per 0.45 s, two to six per line. Each piece is at least 0.22 s.
  - A piece over 0.62 s is cut again at its deepest inner valley.
- **Syllable halves.** A piece of at least 0.26 s with two nuclei splits at the valley nearest its middle ("invest" | "tigate"). Each half keeps at least 28 percent of the piece and at least 120 ms.
  - Transcribed halves are labelled by whole words, or by letters when a single word is split ("invest-", "-igate").
- **Cut points.** Each cut moves to the quietest 1 ms frame within 60 ms, then to a zero crossing within 2 ms.
  - Fade-in is 3 ms after a burst (a rise of more than 10 dB within 15 ms) and 6 ms otherwise. Fade-out is 10 ms.
  - The line's outer edges keep the hierarchy's fades.
- **Native rate only.** The accent of a piece is the onset of its first syllable nucleus.
- **The motif bank.** The fragments become a `DialoguePadBank`: the line is `anchor` (0 dB, protected) and every piece and half is `stab` (-1 dB). The existing renderer, chain, levelling and choke play them unchanged.

### 5.3 Cells

The loop is built from eight 2-bar cells. Slots are sixteenths from the cell start.

- **Item placement.** An `at` item sits on its slot. If the slot is taken, it moves up to 2 sixteenths later; the first item of a late plan may move up to 6.
- An `after` item sits on the first sixteenth that leaves the given space after the previous piece. A space of 0 means back to back.

| Cell | Bars | Content (variants are seeded) |
|---|---|---|
| `statement` | 1-2 | The full line on the downbeat (or its "e"). The last piece follows with an echo throw, then the focal piece and a middle piece in bar 2. |
| `stutter` | | One piece repeated back to back or with a 1 to 3 sixteenth gap ("when they / when they"). A half-stutter ("wh-, wh-, when they") is one variant. Each variant includes one filtered repeat. |
| `splitPause` | | Syllable halves with a 3 or 4 sixteenth pause ("when ..... they", "invest ..... tigate"). The second half often gets an echo throw. Without halves, the shortest pair of neighbouring pieces stands in. |
| `reorder` | | Later pieces before earlier ones ("want to invest ..... when they"). This always runs against source order. For transcribed lines, it plays only when `DialogueReorderGuard.allowsPieceReorder` passes (no negation, number or "n't"); otherwise the cell is `callAnswer`. |
| `callAnswer` | | The focal piece, then an answering piece on the "and" of 3, in both bars. |
| `sparse` | 9-10 (breakdown) | One or two pieces per bar with a closing echo throw. In 45 percent of loops this cell is the second, and last, full-line `statement`. |
| `returnOpen` | 13-14 | One short piece 3 dB lower late in bar 13, so the lead's returning hook opens clear. Then the focal piece, back to back, with an answer. |
| `turnaround` | 15-16 | A run into the drum fill: the focal piece, a three-fold half-stutter, sometimes a reversed pickup, and the focal piece landing on the next loop's downbeat. |

- Cells 2 to 6 (bars 3 to 12) are a seeded order of `stutter`, `splitPause`, `reorder` (or `callAnswer`) and one more, plus the breakdown cell.
- Each block is logged under the family of its first cell (`DialogueFamily` gained the cell names). Neighbouring blocks therefore always differ in family.
- **Roles.** The focal piece X is usually the opening words (30 percent of loops pick an inner piece). Y is the closing piece and Z a middle one. All pieces recur across cells, so the motif stays recognisable.

### 5.4 Grid, coverage and effects

**Grid**

- The snapshot carries the drummer's offset at every sixteenth (`grooveOffsets`, from `LofiTimingField.offset(atBeat:)`).
- Each accent lands exactly on `gridTime(sixteenth:)`. The tests require an error under 2 ms. No gesture offset is applied in motif mode.
- Kick clearance does not apply: pieces sit on downbeats deliberately. C-D8 is a warning only.

**Coverage**

- After the cells are placed, every owned bar whose start is not before the earliest start must contain a piece onset (a start inside the bar).
- When a bar has none, the shortest recurring piece that fits is placed on sixteenth 8, 4, 12, 6 and so on. That repair piece may choke the previous piece (never the line) as long as 120 ms of it remains.
- There are no rest blocks.

**Voice and timing**

- There is one dry voice: overlaps choke with the existing 2 ms lead and 12 ms release.
- A plan ready by its window's start plus the commit margin starts with the window.
- A late plan drops what it missed and begins at the next bar (6.1). Transcript revisions replay the earlier blocks on the memory from before the cue (6.2). The loop keeps its line; its own source is re-cut by words.
- Pieces may run to the 8-bar boundary up to 1.75 s past the bed's end (`tailAfterBedSeconds`, inside `ArchiveVoice.chopTailSeconds`).

**Effects** (rendered offline into the piece buffer by `DialogueChopRenderer.apply`)

- *Echo throw*: two repeats every 0.75 beat at -7 and -13 dB, band-limited to 400 Hz to 3 kHz. The repeats sit inside the space before the next piece and run at most 1.6 beats. The event's duration includes the tail.
- *Filtered repeat*: a 600 Hz to 2.8 kHz band, loudness-matched to the dry piece with at most 8 dB of make-up.
- *Reversed pickup*: the piece played backwards, ending 30 ms before the slot it leads into.
- Nothing is slowed or pitched.
- Chop levels are not lowered (user direction). Only the return's first-bar piece is 3 dB down.

### 5.5 Cadence rule (the 16-bar requirement)

- A new loop has a new line, or, when carried, a new seeded arrangement. C-D1 compares position-tagged `(padKey, slot)` elements of consecutive 16-bar windows and requires a difference of at least 0.25. In both measured captures it is 1.00.
- **C-D9** (new; `scripts/mixlib/cadence.py` `measure_motif`) checks each complete loop:
  - no bar without a chop onset;
  - the full line at most twice;
  - at least 60 percent sub-line pieces (shorter than half the line);
  - `stutter` and `splitPause` cells present;
  - occupancy 0.30 to 0.62.
  - Its notes list the onsets per bar. C-D4 (rests) is skipped in motif mode.
- The C-B8 intelligibility proxy measures each chop's dry length (`dryFrames` in the capture manifest), because an echo throw's tail is an effect, not speech.

### 5.6 Fallback order

- A session with no motif line at all (no speech so far) uses the block grammar of the earlier waves (`DialoguePerformer`), whose own fallback order ends in rest.
- Once any loop has had a line, later loops without speech carry it (5.1).

### 5.7 Measured (19 November 2026, `--private-drums --film-reel --bars 32`)

| Case | Empty bars | Onsets/bar | Full line per loop | Sub-line share | Occupancy | C-B8 SII mean / p10 / 1-4 kHz SNR / spread |
|---|---|---|---|---|---|---|
| seed 2077, 72 BPM | 0 of 32 | 1 to 4 (mean 2.8) | 2, 1 | 0.96, 0.98 | 0.41, 0.36 | 0.64 / 0.51 / +5.3 dB / 2.78 LU |
| seed 4242, 82 BPM | 0 of 32 | 1 to 4 (mean 2.8) | 1, 1 | 0.98, 0.98 | 0.39, 0.31 | 0.59 / 0.54 / +7.0 dB / 1.00 LU |
| seed 2077, 72 BPM, `--transcribe` | 0 of 32 | 1 to 4 (mean 2.8) | 2, 1 | 0.96, 0.98 | 0.40, 0.60 | 0.64 / 0.56 / +6.8 dB / 1.39 LU |

- With `--transcribe` (on-device SpeechTranscriber 27.2.1, 0.3 to 0.8 s per cue), loop 1's line was "He's honored, accredited media," cut as "He's" | "honored," | "accredited" ("accre-" | "-dited") | "media,". Loop 2 took "whereas rigidity and hardness" from the Alan Watts cue, cut as "whereas" | "rigidity" ("rigi-" | "-dity") | "and hardness" ("and" | "hardness"). Loop 1 kept its line across the film change at bar 9.

- Before this package, the 72 BPM capture had 20 empty bars of 32, including bars 8 to 17. It played whole lines and one slowed chunk. Its occupancy was 0.17.
- 84 BPM was requested, but `check-lofi.sh` accepts 58 to 82 BPM, so the second case ran at 82.
- The 72 BPM spread of 2.78 LU comes from one 164 ms piece in loop 2, measured with its stutter gaps, and from the deliberately lower return piece. Dry pieces measure -14.6 to -15.7 LUFS.

## 6. Scheduling, deadlines and cancellation

### 6.1 Lead-time budget

At 58 to 82 BPM a bar is 4.14 to 2.93 s, a block 16.6 to 11.7 s, 16 bars 66.2 to 46.8 s.

| Step | When |
|---|---|
| weaver prepares the incoming piece | 3.0 s before its crossfade starts (poll adds up to 0.5 s) |
| `scheduleAudio` begins | at least 2.5 s before the piece start, about 2.2 s before the bed is due |
| bed posted | at its due time; path is decode then wait, nothing else |
| first dialogue accent allowed | boundary + 2 beats (1.46 to 2.07 s after the boundary) |
| plan commit margin | 0.30 s before each event |
| acoustic plan deadline for block 1 | at least 3.6 s after `scheduleAudio` begins (82 BPM worst case) |

Stage budgets (p95, logged per cue): decode 600 ms; native re-decode 600 ms; classification 900 ms (after that the analysis proceeds without it); envelopes, hierarchy and bank 150 ms; plan 30 ms; render 250 ms. Total 2.0 s or less against 3.6 s. Acceptance in section 9: total p95 at most 2000 ms, maximum 3000 ms, every committed event scheduled at least 0.30 s ahead.

A late plan drops whole gestures whose start is earlier than `now + 0.30 s` and begins at the next bar. It never moves audio that is already queued and never touches the bed.

Transcription has its own budget: it may refine block 2 and later. Timeout is `min(8 s, time to the block-2 commit - 1 s)`. A transcript that arrives late is cached with the bank for a later appearance of the same source.

### 6.2 Coordinator

`DialogueCueCoordinator` owns the dialogue work for one cue:

1. `scheduleAudio` decodes, then starts the coordinator task and continues to the existing wait-and-post loop with `chops: []`.
2. The task classifies (bounded), analyses, builds or fetches the bank, snapshots the transport, plans block by block, renders, checks the cue token and the transport revision, then posts `.archiveChops`.
3. If the revision changed (tempo or take change, restart), the analysis and bank are kept and the plan is rebuilt against the new snapshot, or discarded when the cue is gone.
4. When a transcript arrives in time, blocks that start after `now + 0.5 s` are replanned and posted with a higher `revision` and `replaceFrom` at that block's start.
5. Memory (fingerprints, family cycle, counters) lives in the coordinator's owner and is updated only for committed plans. Thread completion order never selects a phrase.

All of this runs at utility priority. Loops check cancellation. Nothing here runs on the conductor queue except the final post.

### 6.3 ArchiveVoice scheduling

- The chop player keeps one sample timeline per Lo-Fi session (started lazily, anchored once to the host clock; offline it starts at conductor time). It is stopped only on beat-lock off, reset or power down.
- A plan is stored, not queued whole. Every conductor tick schedules chops whose start is within the next 1.0 s and not yet queued, at `sampleTime = (start - anchor) x rate`. Replacing a plan from `replaceFrom` only swaps unscheduled chops.
- Chop gain follows the Footage audio setting and beat lock, with its own 50 ms ramp. It no longer follows the bed's fade-in.
- Drop windows for bed ducking and music ducking are derived from queued chops.

### 6.4 Transport revision

`LofiPlayback` increments `revision` on start, stop, route recovery and whenever a queued take changes tempo. It publishes `LofiTransportInfo` at each take start and when the next take is queued. The timing field for a take is published with it.

## 7. Local transcription and safe reordering

- Backend: `SpeechAnalyzer` with `SpeechTranscriber(locale: en_US, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])`, final results only, fed with `AnalyzerInput` buffers converted to `bestAvailableAudioFormat`, results consumed concurrently, `finalizeAndFinish(through:)` at the end, `cancelAndFinishNow()` on deadline. Wrapped in `#if canImport(Speech)` and availability checks.
- Gates, in order: mode setting; `SpeechTranscriber.isAvailable`; locale in `supportedLocales`; locale in `installedLocales`. Missing assets are downloaded only when the user chose "Download model" (`AssetInventory.assetInstallationRequest`), once, at idle. Any failure, timeout or thrown error is a normal state and leaves the acoustic plan in place. No server fallback exists in this path. Legacy `SFSpeechRecognizer` and Whisper backends are not built (section 13).
- Setting `archive.dialogueTranscription`: `off`, `installedOnly` (default), `allowDownload`. Debug flag `-LiminalDialogueTranscription <mode>`.
- Refinement: map words to source frames; snap boundaries to the nearest energy minimum within 60 ms; drop words shorter than 40 ms or longer than 2 s, regions with zero speech weight, speech rates above 7 words per second and any 3-gram repeated three times (hallucination guard). A unit is transcribed when coverage is at least 0.8 and mean confidence is at least 0.5 where confidence exists.
- Protected spans (NLTagger lexical classes and name types): negation with its predicate; names with their phrase; determiner with noun; pronoun with verb; number with noun. Uncertain spans are protected whole.
- Reorder templates, each requiring every involved unit to be transcribed: repeat a whole clause; omit a parenthetical bounded by pauses; move an intact leading or trailing adverbial; exchange two independent clauses (not when either starts with a subordinator such as if, when, because, unless, although, or with a pronoun whose referent is in the other clause, or when a negation crosses the join). If no template proves safe, the order is the source order.
- The plan log records the intended text, the original order and the arranged order for review.

## 8. Mix: spectral slots, per-bus chains and master

### 8.1 Slots

| Band | Owner | Others |
|---|---|---|
| 20 to 40 Hz | nobody | high-passed everywhere |
| 40 to 120 Hz | kick and bass (shared in time by ducking and attack alignment) | mids, lead, space, dialogue, bed at least 12 dB below |
| 120 to 500 Hz | bass harmonics, snare body, instrument warmth | 2 to 3 dB cuts on mids, lead, dialogue, bed |
| 500 Hz to 1 kHz | lead and mids body | bed shaped below them |
| 1 to 4 kHz | dialogue when it plays; lead otherwise | static 2 dB dip in space and bed; mids, lead and space duck under featured chops |
| 4 to 8 kHz | snare crack, hats, consonants | music buses rolled off |
| above 8 kHz | hats and air | lo-fi low-pass on lead, mids, space |

### 8.2 Drums (offline, per take, in `LofiDrumTake`)

Landmarks are detected before processing. Chain (*start*): mono below 100 Hz; HPF 32 Hz 12 dB per octave; bell -2.5 dB at 320 Hz Q 1.0; bus compressor 3:1, knee 6 dB, attack 20 ms, release 120 ms, threshold set from the take so peaks see 2 to 3 dB; parallel compressor 8:1, attack 2 ms, release 80 ms, 6 to 10 dB, blended at 20 percent; tape saturation for about 1.5 dB of peak rounding, 2x oversampled; high shelf -2 dB at 11 kHz; trim so the take peaks at or below -4 dBFS. Target crest 10 to 14 dB. Attack time of kick landmarks may grow by at most 20 percent.

### 8.3 Bass (offline, in `LofiRenderer` with `LofiBassVoice`)

Voices, loudness matched within 0.5 dB at MIDI 33:

| Voice | Recipe (*start*) | Use |
|---|---|---|
| `classic` | today's sine plus harmonics, bit-identical | comparison and fallback |
| `roundSub` | sine fundamental, 5 ms rise, pitch settles from +30 cents in 35 ms, 2nd harmonic 0.10, tanh 1.1, release 220 ms | theme, variation |
| `pluck` | fundamental plus a bright component (2nd to 4th harmonics, band-limited click of 3 ms at -20 dB) that decays in 90 ms over a stable body, release 180 ms | answer, pickups |
| `longAnswer` | round body, 12 ms rise, 2nd harmonic 0.16 decaying, release 420 ms with a controlled tail | return, breakdown |

One voice per phrase, chosen by section and seed, never per note. Chain: HPF 30 Hz; parallel saturation path high-passed at 120 Hz at 20 percent (harmonics at 150 to 800 Hz for small speakers); compressor 3.5:1, attack 20 ms, release 150 ms, 2 to 4 dB; bell -2 dB at 280 Hz; LPF 4.5 kHz; kick duck up to 3 dB (attack 3 ms, release 100 ms); mono.

Timing: structural accents (beats 0 and 8 of a phrase) align their audible attack to a confident kick attack within 0.12 beats: `noteStart = kickAttack - voice.attackLead`. Pickups keep the pocket offset and take the timing field's interpolated offset. No note is added or moved to an unrelated kick.

### 8.4 Lead, mids and space (offline, in `LofiRenderer`)

| Bus | Chain (*start*) |
|---|---|
| lead (`dry`) | HPF 180 Hz; bell -2 dB at 350 Hz; bell +1.5 dB at 2.8 kHz Q 0.8; compressor 2.5:1, attack 15 ms, release 150 ms, 2 to 3 dB; LPF 9 kHz |
| mids (`texture`) | HPF 160 Hz; bell -3 dB at 400 Hz; bell +1.5 dB at 1.6 kHz; LPF 7 kHz; lower and upper voice panned about 0.3 apart above 300 Hz; level so mids sit 3 to 8 dB under the lead when both play |
| space (`wet`) | HPF 350 Hz; LPF 4.5 kHz; bell -2 dB at 2.5 kHz; ducked 3 to 5 dB by the dry lead (attack 10 ms, release 250 ms); phrase level at least 3 dB under the lead |

Mids arrangement (in `LofiScore`): two to four shell events per non-breakdown phrase instead of one, chosen from three articulations by where the melody rests: an off-beat short stab (length 0.35, in a gap of at least 0.75 beats), a longer answer after the melody's landing note (length 1.6), or the rolled two-note shell (stagger 0.17). Velocity 0.50 to 0.66, bounded length and send variation, close voice leading kept. A breakdown has at most one soft answer.

Theme return (in `LofiScore` and `LofiRenderer`): the return uses the take's theme program, register, articulation stream and note velocities; its first two notes get +1.5 dB and a send reduced by 40 percent; the wet stem (the carried tail and the phrase's own returns) is lowered 6 dB from the downbeat until the second revealed note has sounded (at least two beats, released by beat 4); no mid event before beat 2; no virtual-record edit in the first cell; dialogue leaves bar 1 free (5.2).

### 8.5 Dialogue chops

Per cut, offline in `DialogueChopRenderer`: HPF 120 Hz 18 dB per octave; bell -2.5 dB at 300 Hz; bell +3 dB at 3 kHz Q 0.8; de-esser 5 to 8 kHz up to 6 dB; compressor 3:1, attack 8 ms, release 100 ms, 3 to 6 dB on peaks; LPF 7.5 kHz for speech pads and 5.5 kHz for texture; then levelling.

Live in `ArchiveVoice`: dry mono centre; tempo echo (0.75 beat, feedback 0.25) returned through a 400 Hz to 3 kHz band at about -16 dB under dry; small room (decay about 0.9 s, HPF 300 Hz, LPF 4 kHz) at about -20 dB under dry.

Ducking under a featured chop (0.5 s or longer): lead -2 dB, mids -3 dB, space -4 dB on the `LofiBus` faders; bed -3 dB. Attack 30 ms, release 300 ms. Drums and bass are not ducked.

### 8.6 Film bed (live, `ArchiveVoice` and `MixBus`, Lo-Fi only)

HPF 120 Hz; one LPF stage at 6.5 kHz (the second stage opened); static dip -2.5 dB at 2.2 kHz Q 0.7; phaser mix 0.10 to 0.18; dry gain -3 to 0 dB; reverb and echo sends 0.25 to 0.45 (about 10 to 20 percent wet); `MixBus` Lo-Fi voicing raises its master low-pass from 5.4 kHz to 10 kHz. The Footage audio control stays monotonic and zero stays silent. Ambient values are unchanged.

### 8.7 Master

Graph: `input -> glue (Apple, ambient only) -> trim -> limiter (Apple, ambient only) -> LofiMasterFinisher -> output`.

`ambient` profile: today's values, finisher in passthrough. `lofi` profile: the two Apple units are bypassed, the output fader is 0 dB, and the finisher runs (*start*): input gain about +6 dB (calibrated in wave 4); HPF 25 Hz; glue 1.7:1, knee 6 dB, attack 30 ms, release 180 ms, sidechain HPF 100 Hz, 1 to 2 dB on peaks; soft clip, 4x oversampled, at most 2 dB; true-peak limiter with 3 ms lookahead, 4x oversampled detection, min-hold and FIR-smoothed attack, dual release 80 and 350 ms, ceiling -1.0 dBTP with a 0.15 dB internal margin and a final clamp that should never engage.

Slow calibration aims at -12 LUFS, moves at most 1 dB per 16 bars inside -3 to +2 dB, and does not move up while the limiter's mean reduction exceeds 2.5 dB.

## 9. Verification

### 9.1 Commands

```sh
S=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad
# one capture plus the full report (JSON, Markdown, PNGs) and optional comparison
DD=$S/dd-<name> scripts/mix-report.sh --out $S/cap-<name> --private-drums --film-reel --bars 32 --seed 1042 --bpm 70 \
    --baseline $S/baseline/ref [--strict]
# analysis only, on an existing capture
python3 scripts/mix-report.py $S/cap-<name> --baseline $S/baseline/ref [--strict]
# the whole matrix
DD=$S/dd-<name> scripts/mix-matrix.sh --out $S/matrix-<name> --baseline $S/baseline [--strict]
python3 scripts/mix-report.py --self-test
```

Matrix cases (all `--private-drums`): `ref` film reel, 32 bars, seed 1042, 70 BPM; `long` film reel, 64 bars, seed 7, 62 BPM; `fast` film reel, 32 bars, seed 2025, 80 BPM; `same` one film repeated at the same offset (`--same-film`), 64 bars, seed 1042, 70 BPM; `nofilm` no footage, 16 bars.

The baseline of the unmodified audio code lives in `$S/baseline/<case>/` with its own report.

### 9.2 Measurements

Bands: 20-60, 60-120, 120-250, 250-500, 500-1k, 1-2k, 2-4k, 4-8k, 8-16k Hz. Sections map to stems through `manifest.sections`.

| Id | Measurement | Method |
|---|---|---|
| M1 | Loudness | BS.1770-4 K-weighting, 400 ms and 3 s windows, gating at -70 LUFS and -10 LU; integrated, momentary and short-term series, LRA; cross-checked with `ffmpeg ebur128` within 0.2 LU |
| M2 | True peak | ffmpeg `ebur128=peak=true` and an independent 16x windowed-sinc reconstruction |
| M3 | Crest, PLR, PSR | sample peak minus RMS per bus and master in 1 s windows and overall; true peak minus integrated; true peak minus short-term maximum |
| M4 | Gain reduction | engine trace `master-gr.csv` (glue, clip, limiter) and an inferred trace from `pre-master` and `master` envelopes (10 ms) |
| M5 | Pumping | RMS of the master gain in the 0.5 to 8 Hz modulation band; gain dip 20 to 80 ms after kick landmarks |
| M6 | Spectrograms | STFT at 4096, 1024 and 256 samples, log frequency, per section and master |
| M7 | Long-term spectrum | third-octave average per section and master; tilt by regression from 250 Hz to 8 kHz; band shares |
| M8 | Band energy and masking matrix | per band, each section's level minus the sum of the others, overall and in chop-active windows |
| M9 | Low-band mono | L/R correlation per band; mid/side ratio; loudness of `(L+R)/2` against stereo |
| M10 | Kick and bass | 0 to 120 ms after each kick landmark: 40 to 120 Hz RMS of drums, bass and their sum; onset lag between bass attack and kick attack at aligned accents; duck depth |
| M11 | Dialogue intelligibility | per featured chop: band SNR of dialogue against all other sections in octave bands 250 Hz to 8 kHz; SII proxy `sum(w_b * clamp((SNR_b + 15) / 30, 0, 1))` with weights 0.08, 0.14, 0.22, 0.30, 0.20, 0.06; per-chop loudness |
| M12 | Bed | direct to wet ratio; audibility index (same formula as M11) of the bed against the other sections in gaps between chops; 85 percent roll-off; loudness in gaps |
| M13 | Mids and lead | 400 Hz to 3 kHz levels of mids and lead in lead-active windows and in lead rests (from `score.json`); mid articulation count per 16 bars |
| M14 | Theme return | lead salience over the first two return notes (lead minus the sum of mids, space, dialogue, bed in 500 Hz to 4 kHz); onset-envelope correlation between the theme phrase and the return in the lead stem; same program |
| M15 | Chop cadence | fingerprints per block from scheduled events and from the plan log; 16-bar differences; rests; occupancy; overlaps; lead time and stage timings |
| M16 | Routing | stems sum to the Lo-Fi bus and to the pre-master within 2e-6 |

### 9.3 Acceptance criteria

`fail` criteria gate `--strict`. `warn` criteria are reported. Thresholds live in `scripts/mix-criteria.json`; a change needs a written reason in `docs/plans/mpc-chopping-measurements.md`.

Master (cases with footage)

| Id | Criterion | Level |
|---|---|---|
| C-M1 | integrated loudness -13.0 to -11.0 LUFS on `ref`; -14.0 to -10.5 on the other cases | fail |
| C-M2 | true peak at most -1.0 dBTP (ffmpeg) and at most -0.9 dBTP by the 16x reconstruction | fail |
| C-M3 | PLR 9 to 12.5 dB (below 8 fails) | fail |
| C-M4 | short-term maximum at most -8.5 LUFS; PSR at least 6 dB | warn |
| C-M5 | master crest 9 to 13 dB | warn |
| C-M6 | limiter reduction: mean at most 3.0 dB, p95 at most 5.0 dB, maximum at most 8.0 dB, above 3 dB for at most 10 percent of the time | fail |
| C-M7 | glue reduction: p95 at most 3 dB, mean 0.3 to 2.0 dB | warn |
| C-M8 | pumping index at most 0.8 dB; kick-synchronous dip at most 1.5 dB | fail |
| C-M9 | soft clip engaged on at most 3 percent of samples | fail |
| C-M10 | correlation below 120 Hz at least 0.8; full band at least 0.3; mono loss at most 3 LU | fail |
| C-M11 | energy below 25 Hz at least 50 dB under the total; tilt -3 to -6.5 dB per octave | warn |
| C-M12 | LRA 2 to 9 LU | warn |

Buses

| Id | Criterion | Level |
|---|---|---|
| C-B1 | in 20 to 120 Hz each of mids, lead, space, dialogue, bed is at least 12 dB under the louder of drums and bass | fail |
| C-B2 | aligned bass accents: median lag at most 5 ms, p90 at most 12 ms; kick plus bass sum at least -1 dB (median) and -3 dB (worst) against the louder part; duck depth 1.5 to 4.5 dB | fail |
| C-B3 | bass 60 to 250 Hz within -6 to +3 dB of drums in that band; bass 150 to 800 Hz at most 18 dB under its fundamental band | warn |
| C-B4 | drum bus crest 10 to 14 dB; peak at most -3 dBFS before the master; kick attack time at most 1.2 times the unprocessed take | warn |
| C-B5 | mids 3 to 8 dB under the lead when both play; mids at least 3 dB over the lead in lead rests where mids play; at least two mid articulations per 16 bars | fail |
| C-B6 | return salience at least +6 dB and not below the theme phrase's; theme and return onset correlation at least 0.8; same program | fail |
| C-B7 | space at least 3 dB under the lead in lead-active phrases | warn |
| C-B8 | Chops tucked into the music (user direction, 19 November 2026): SII proxy mean at least 0.30 and p10 at least 0.18 over featured chops; 1 to 4 kHz SNR mean -3 to +2.5 dB; per-chop loudness spread at most 2.5 LU | fail |
| C-B9 | bed direct to wet at least +3 dB; audibility index in gaps 0.20 to 0.55; bed at least 6 dB under dialogue in 1 to 4 kHz during chops; roll-off at least 3 kHz | fail |
| C-B10 | routing identities hold | fail |

Dialogue performance

| Id | Criterion | Level |
|---|---|---|
| C-D1 | every consecutive pair of 16-bar windows with dialogue differs by at least 0.25 | fail |
| C-D2 | family or bank changes at least every 8 bars | fail |
| C-D3 | consecutive blocks are not identical apart from declared repeats | warn |
| C-D4 | an empty bar in every 8; nothing in the last 2 beats before an 8-bar boundary; occupancy at most 0.55 per 8 bars | fail |
| C-D5 | no overlapping dry events | fail |
| C-D6 | stage timing total p95 at most 2000 ms and maximum 3000 ms; every committed event at least 0.30 s ahead | fail |
| C-D7 | the first two statements of a hook are the same pad and transform | warn |
| C-D8 | at least 90 percent of accents are 50 ms or more from a kick attack | warn |

The baseline is expected to fail C-M1, C-M3, C-B5, C-B9 and others. The report prints baseline and candidate side by side.

### 9.4 Reading the plots

A spectrogram cannot prove intelligibility or punch and a waveform match cannot prove recognition; the proxies above stand in for listening and the listening checks in section 12 remain a human step. `docs/mix-verification.md` (wave 4) explains each figure and criterion.

## 10. Tests (Swift Testing)

| Suite | Covers |
|---|---|
| `LofiDSPTests` | filter responses; compressor curve and timing; saturator symmetry and aliasing; de-esser; mono-below; true-peak meter on an fs/4 sine at 45 degrees (+3.01 dB); loudness meter on 997 Hz at -23 LUFS |
| `LofiMasterKernelTests` | ceiling under 16x reconstruction on bursts, phase-offset high tones, 57 Hz bass, antiphase stereo; block-size invariance; latency; passthrough null; THD at nominal level; meters and trace; AU node equals the kernel in manual rendering; realtime factor at least 10x in Debug |
| `DialogueEngineTests` | clock mappings; containment; source-order reconstruction; protected spans; stable bank and seeds; accent positions under rate; choke exclusivity; occupancy and rests; cadence property test over 200 seeds and 64 bars; exact repeats; kick spacing; silence, tone and choral inputs; reorder guards |
| `DialogueRuntimeTests` | bed posted on time with a 5 s analysis delay; late plan starts at the next bar; stale token and stale revision discarded or remapped; replace-from on transcript arrival; cue replacement, stop and restart, tempo change during recognition |
| `DialogueTranscriptionTests` | unavailable, not installed, timeout, thrown error and cancellation all return nil; fixture provider; time mapping; guards against hallucinated repeats |
| `LofiRhythmTests` | landmark timing within 2 ms on synthetic takes; ghosts and close doubles; kick, snare, hat classes; private takes required when present; timing field interpolation; bass voice loudness match, tuning, click-free edges, attack lead |
| `LofiArrangementTests`, `LofiCompositionTests` | bass alignment and unchanged other parts; one voice per phrase; mid answers lie in melody rests; return presentation equals the theme's notes with the planned accents |
| `LofiStemChainTests` | each chain's response and reduction bounds; drums attack preserved; low band mono; no nonfinite output; preparation time bound |
| `LofiMasterBusTests`, `LofiMasterCharacterizationTests` | ambient profile unchanged; Lo-Fi profile ceiling and loudness on a stress program; profile switch without discontinuity |
| `ArchiveVoiceRenderTests`, `LofiLiveBusTests` | incremental chop scheduling at sample accuracy; chop gain independent of the bed fade; ducking depth and timing; bed chain bandwidth and direct level; zero setting is silent |

Private drums: suites that measure real takes use an enabled-if trait on installed assets, and the acceptance commands confirm from the log that they ran.

## 11. Work packages

| Wave | Package | Model | Summary |
|---|---|---|---|
| 1 | `verify-tooling` | sonnet | capture hooks, harness v2, analysis library, single command, baseline |
| 1 | `dsp-core` | opus | DSP toolkit, master kernel and finisher unit |
| 1 | `dialogue-core` | opus | analysis, hierarchy, bank, grammar, renderer, transcript types and guards |
| 1 | `rhythm-foundation` | opus | drum landmarks, timing field, bass voices |
| 2 | `dialogue-runtime` | opus | bed and plan split, coordinator, incremental scheduling, transport info, harness on the new engine |
| 2 | `music-arrangement` | opus | bass timing and voices, mid answers, theme return |
| 2 | `transcription` | opus | Apple provider, assets, setting, qualification |
| 2 | `master-bus` | opus | profiles, finisher integration, calibration, meters |
| 3 | `stem-chains` | opus | offline chains for drums, bass, lead, mids, space |
| 3 | `live-bus-chains` | opus | bed chain, chop chain and returns, ducking, MixBus voicing |
| 3 | `dialogue-tuning` | opus | real-footage tuning, transcript path end to end, cadence and timing acceptance |
| 3 | `verify-extensions` | sonnet | analysis aligned with the real diagnostics, music metrics, matrix runner polish |
| 4 | `mix-calibration` | opus | joint balance to the criteria across the matrix, measurements record |
| 4 | `mix-verification-docs` | sonnet | how to run, read and interpret the verification |

Every package builds for macOS and the visionOS simulator with an explicit destination, uses its own derived data directory, copies the three ignored private paths into its worktree without committing them, and never launches the app without automation flags.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Pure Swift realtime unit is slow in Debug or unsafe on the render thread | Accelerate block operations; preallocated memory; realtime-factor test; fallback to the ambient chain if the unit cannot be created |
| Loudness target unreachable without audible limiting | crest is reduced at the source (drum bus, bass, levels) before the master; C-M6 and C-M8 gate; the target range may be lowered with a written reason |
| Offline chains make take or phrase preparation late | Accelerate biquads; timing test; the existing repeat-stems fallback stays |
| New analysis misjudges real film audio | real-footage probe in wave 1, tuning package in wave 3, rejection reasons logged |
| Transcription API differs from the notes or is absent in the simulator | provider behind a protocol; every failure is a nil result; fixture provider in tests |
| Parallel captures collide on the single config path | the capture script waits for the lock and the harness checks the checkout that owns the config |
| Thresholds are hypotheses | baseline measured first; thresholds in one JSON file; changes recorded |
| No ears in the loop | proxies plus loudness-matched audition files for the user; listening acceptance listed as a human step |

## 13. Deferred, with reasons

| Item (handoff phase 4 unless noted) | Reason |
|---|---|
| Pitch-preserving time stretch (WSOLA or phase vocoder) | native cadence with stress-anchor placement removes the need to fit durations; revisit if rejection logs show more than 20 percent of anchors lost to `overTransformed` or deadline misfit |
| Stem or speech separation | the handoff asks for escalation only after measured landmark or masking failures remain |
| Whisper backends, legacy `SFSpeechRecognizer`, `DictationTranscriber` | one Apple backend is qualified first; these follow only if it is unavailable or fails its budget on the targets |
| Sampled bass library | the three synthesized voices are compared first; licensing and tuning work follows a demonstrated palette gap |
| Additional reorder templates and other locales | English, narrow templates first |
| Hand-labelled drum attacks | an agent cannot produce hand labels; an independent reference detector and plotted spot checks stand in; hand labels remain a human follow-up |
| Physical Vision Pro timing, memory and thermal runs | needs hardware; the simulator build and the Mac measurements are done here |
| Listening acceptance | human step: compare the baseline and candidate `master.wav` at matched loudness and judge recognition, intelligibility and the theme return |

### Remaining human steps

- [ ] Listening acceptance at matched loudness (`baseline-master.wav` against `master.wav`), including bass density and the two-line rotation on a repeated film. The five checks are in [Listening checks for a person](mpc-chopping-measurements.md#listening-checks-for-a-person).
- [ ] Hand-labelled drum attacks to replace `scripts/drum-landmark-reference.py` (see [D110](../decisions/music.md)).
- [ ] The physical Vision Pro timing, memory and thermal run (D110).
- [ ] Optional brighter-bed A/B audition, off by default ([D107](../decisions/music.md)).
- [ ] Decide whether to schedule reversed pickups every two to four bars ([D109](../decisions/music.md)).
