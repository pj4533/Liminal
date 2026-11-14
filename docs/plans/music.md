# Liminal music system: design and build plan

Status: design, nothing below is built yet. Baseline and current engine: `docs/plans/music-current.md`. Techniques: `docs/research/generative-ambient-music.md`. Every choice here has an entry in `docs/decisions/music.md` (D3 onward).

## 1. Goals and shape

Keep the ambient feel (slow, consonant, reverberant, no beat) and replace the three independent voices with a small ensemble that is conducted: eight layers on a shared harmony, entering and leaving along scene arcs, in a key that drifts over tens of minutes. All sound is synthesized with AudioKit / SoundpipeAudioKit nodes. No samples, no services.

Three ideas carry the design:

1. **One conductor, off the main thread.** A `MusicConductor` on its own serial queue owns time, randomness, harmony, scenes and layers. Nothing on the music path touches MainActor (visionOS starves it at 90 fps). The same `advance(to:)` call drives realtime and offline renders.
2. **Shared harmony, independent clocks.** Every layer reads one `HarmonicField` (tonic, mode, chord) but runs its own loop on a non-integer period. Consonance is guaranteed by the field; variety comes from the clocks never lining up.
3. **Form is an intensity curve.** Scenes set an intensity arc (sparse, bloom, dissolve). Layers have entry thresholds on that curve, so the ensemble thickens and thins without scripted cues.

## 2. Threading and time

| Thread | Runs | Rules |
|---|---|---|
| Audio render (system) | AudioKit/Soundpipe DSP only | No Swift callbacks, no taps, no `CallbackInstrument`. |
| `liminal.music` serial queue, QoS `.userInitiated` | `MusicConductor.advance(to:)` from a `DispatchSourceTimer` (20 ms, 5 ms leeway) | Only writer of AU parameters and of `MusicState`. No allocation in the steady-state tick beyond the event heap. |
| MainActor | `GenerativeEngine` facade: graph construction at init, `start/stop`, `@Published` controls | Controls are forwarded with `conductor.post(_:)`; never waits on the queue. |
| Render loop / any thread | `MusicStateBus.read()` | Wait-free copy of a POD struct. |

- Time source: realtime uses `DispatchTime.now().uptimeNanoseconds - startUptime` (monotonic, not `Date`). Offline: `renderOffline` calls `conductor.advance(to:)` directly every 20 ms of rendered audio (960 frames at 48 kHz). `OfflineClock` and the `schedule(after:)` Timer path are removed.
- Two rates inside `advance`: events (note on/off, scene steps) are dispatched at their exact due time order on every 20 ms tick; continuous modulation (`modulate(dt:)`) runs every fifth tick (10 Hz) and writes ramps of 0.1 s so parameters are continuous.
- Parameter writes: `ParamRamp.set(_ p: NodeParameter, to:, over:)` uses `NodeParameter.ramp(to:duration:)` (`scheduleParameterBlock`, sample-accurate on the audio thread) when the parameter can ramp, otherwise `AUParameter.value`. Gains, cutoffs, pans and frequencies are always ramped (minimum 20 ms) so there are no zipper steps or clicks.
- The graph is built once in `GenerativeEngine.init` and never changes while playing. Inactive layers sit at gain 0 with their generators' amplitude at 0.

## 3. Signal graph

```
each layer:  sources -> [layer filter] -> Fader(level) -> Panner(pan) --+--> dryBus
                                                                        +--> Fader(reverbSend) -> reverbBus
                                                                        +--> Fader(delaySend)  -> delayBus

delayBus  -> VariableDelay(max 10 s) -> LowPassButterworth(2.5-5 kHz) -> TanhDistortion(light, PASS 2) -> delayReturn Fader --+--> master
                                                                                                                             +--> Fader(0.5) -> reverbBus
reverbBus -> ZitaReverb(dryWet 1) -> reverbReturn Fader -> master
reverbBus -> PitchShifter(+12) -> LowPassButterworth(5 kHz) -> CostelloReverb(fb 0.9) -> shimmerReturn Fader -> master   (PASS 2)
master Mixer -> HighPassButterworth(28 Hz) -> Fader(masterTrim) -> PeakLimiter(attack 10 ms, decay 80 ms, preGain 0) -> Fader(-1.5 dB) -> engine.output
```

- Sends are fan-out connections from the layer's `Panner` into three mixers (AudioKit 5 supports one node feeding several inputs; verified first thing in PASS 1, see risks).
- Shimmer is feed-forward (send, octave up, lowpass, its own small reverb). AudioKit graphs cannot contain cycles, so a true feedback shimmer is not possible; feed-forward also cannot run away.
- `VariableDelay` feedback is internal, so the loop cannot be filtered. The lowpass and saturation sit after the delay; the reverb after it does the blurring.
- ZitaReverb limits (from the pinned source): predelay 10-100 ms, RT60 1-8 s low and mid, damping 1.5 kHz and up. Defaults: predelay 60 ms, crossover 200 Hz, low RT60 5 s, mid RT60 6 s, damping 5 kHz. The research doc's 2-3 s predelay is not available; long pre-echo comes from the delay bus instead.
- The final -1.5 dB fader after the limiter guarantees true peak at or below -1 dBFS.

### Node budget

| Layer | Generators | Other nodes | Pass |
|---|---|---|---|
| Drone | 6 `Oscillator` (custom soft tables) | LPF | 1 |
| Pad | 8 `MorphingOscillator` (4 voices x detuned pair) | `MoogLadder` | 1 |
| Lead + Answer | 4 `Oscillator` (2 voices x sine+triangle) | 2 `AmplitudeEnvelope`, LPF, 2 strips | 1 |
| Drips / mallets | 4 `FMOscillator` | 4 `AmplitudeEnvelope` | 1 |
| Keys / bells | 6 `FMOscillator` | 6 `AmplitudeEnvelope`, LPF | 2 |
| Air | `PinkNoise`, `BrownianNoise` | BPF, LPF | 2 |
| Grains | 12 `Oscillator` (sine) | 12 `AmplitudeEnvelope`, 4 fixed-pan group mixers | 2 |
| Pluck | 2 `PluckedString` | LPF | 2 |

Totals: 44 generators, 24 envelopes, 9 layer strips (4 nodes each), about 14 bus nodes: roughly 125 nodes, 2 reverbs, 1 pitch shifter, 1 delay. PASS 1 alone is 22 generators and about 60 nodes. The cost is dominated by per-node render overhead, so the budget is enforced by measurement (section 11), and the grain pool is the first thing to shrink (12 to 8) if it is over.

Cheapness rules: one filter per layer, never per voice; no per-voice reverb; layers at level 0 for more than 5 s also get generator amplitudes set to 0; modulation at 10 Hz; no taps.

### Gain staging (peak targets, pre-limiter)

| Source | Peak dBFS | Reverb send | Delay send | Pan |
|---|---|---|---|---|
| Drone | -14 | 0.25 | 0 | centre, sub mono |
| Pad | -13 | 0.5 | 0.1 | pairs spread +-0.35, slow walk |
| Lead / Answer | -18 | 0.6 | 0.45 | walk +-0.5, answer mirrored |
| Keys | -17 | 0.6 | 0.35 | per-note +-0.6 |
| Drips | -22 | 0.7 | 0.6 | per-note +-0.8 |
| Air | -30 | 0.4 | 0 | walk +-0.7 |
| Grains | -24 | 0.8 | 0.2 | 4 fixed groups -0.7/-0.25/0.25/0.7 |
| Pluck | -20 | 0.6 | 0.4 | per-phrase +-0.5 |

Reverb return -8 dB, shimmer return at or below -12 dB, delay return -6 dB. The limiter is a safety net: a render with the limiter bypassed must still peak at or below -3 dBFS.

## 4. Files and types

New files under `Liminal/Audio/` (the project uses file-system-synchronized groups, so no project file edits):

| File | Contents | Pass |
|---|---|---|
| `MusicRNG.swift` | `SeededRNG` | 1 |
| `MusicState.swift` | `MusicState`, `MusicEvent`, `MusicStateBus`, `VisualMood`, `LayerID`, `SceneKind`, `ScenePhase` | 1 |
| `MusicScheduler.swift` | `MusicScheduler`, `LoopClock` | 1 |
| `Harmony.swift` | `HarmonicField`, `Chord`, `HarmonyEngine` | 1 |
| `SceneDirector.swift` | `Scene`, `SceneDirector`, `MusicStyle` | 1 (one style), 2 (four) |
| `MusicConductor.swift` | `MusicConductor`, `MusicControl` | 1 |
| `MixBus.swift` | `MixBus` (buses, reverb, delay, master, limiter) | 1; shimmer and tape in 2 |
| `Layers/MusicLayer.swift` | `MusicLayer`, `LayerStrip`, `LayerContext`, `ParamRamp` | 1 |
| `Layers/DroneLayer.swift`, `PadLayer.swift`, `LeadLayer.swift`, `DripsLayer.swift` | | 1 |
| `Motif.swift` | `Motif`, `MotifDeveloper` | 1 |
| `Layers/KeysLayer.swift`, `AirLayer.swift`, `GrainLayer.swift`, `PluckLayer.swift` | | 2 |
| `MusicEvents.swift` | `RareEventDirector` | 2 |
| `VisualCoupling.swift` | mood smoothing, mood-word table, image-change behaviour | hooks in 1, mapping in 2 |

Changed: `GenerativeEngine.swift` (becomes a facade), `OfflineRender.swift`, `Scale.swift` (true degree mapping), `MarkovChain.swift` (seeded, new presets), `ParameterDrift.swift` (generic channels on conductor time), `VoiceLayer.swift` (reused by `LeadLayer`, ramped frequency). Removed: `EffectsChain.swift` (replaced by `MixBus`), `AudioEngine.swift` (unused prototype, removed in PASS 2 cleanup).

### Core signatures

```swift
struct SeededRNG: RandomNumberGenerator {          // SplitMix64
    init(seed: UInt64)
    mutating func next() -> UInt64
    func fork(_ label: UInt64) -> SeededRNG         // independent stream per layer/subsystem
    mutating func unit() -> Float                   // 0..<1
    mutating func range(_ r: ClosedRange<Double>) -> Double
    mutating func chance(_ p: Float) -> Bool
    mutating func weighted(_ weights: [Float]) -> Int
}

final class MusicScheduler {                       // conductor-queue confined
    private(set) var now: Double
    func schedule(at time: Double, _ block: @escaping () -> Void)
    func schedule(after delay: Double, _ block: @escaping () -> Void)
    func advance(to target: Double)                 // runs due events in (time, seq) order; binary heap
    func cancelAll()
}

struct LoopClock {                                 // Eno loop: non-integer period with slow drift
    var period: Double                              // seconds
    var driftPerCycle: Double = 0.04                // +-4 % random walk, clamped to bounds
    var bounds: ClosedRange<Double>
    mutating func nextCycle(rng: inout SeededRNG) -> Double
}

enum LayerID: UInt8, CaseIterable { case drone, pad, lead, keys, drips, air, grains, pluck }

struct LayerContext {                              // passed by reference to layers each call
    let scheduler: MusicScheduler
    var field: HarmonicField
    var intensity: Float                            // 0...1
    var brightness: Float                           // 0...1
    var density: Float                              // 0...1 (user control x scene x visual energy)
    var registerShift: Int                          // semitones, -5...+7
    var mood: VisualMood                            // smoothed
    func emit(_ event: MusicEvent)                  // to MusicState
}

protocol MusicLayer: AnyObject {
    var id: LayerID { get }
    var strip: LayerStrip { get }                   // output to MixBus
    var entryThreshold: Float { get }               // default intensity at which the layer enters
    func prepare(rng: SeededRNG)                    // once, after graph build
    func setActive(_ active: Bool, fade: Double, ctx: LayerContext)
    func sceneDidChange(_ scene: Scene, ctx: LayerContext)
    func harmonyDidChange(_ change: HarmonyChange, ctx: LayerContext)
    func modulate(dt: Double, ctx: LayerContext)    // 10 Hz
    func silence(fade: Double)                      // stop(): close gates, ramp to 0
}

final class LayerStrip {
    init(source: Node, filter: Node? = nil)
    var outputs: (dry: Node, reverbSend: Node, delaySend: Node)
    func setLevel(_ linear: Float, over: Double)
    func setPan(_ pan: Float, over: Double)         // -1...1
    func setSends(reverb: Float, delay: Float, over: Double)
    private(set) var targetLevel: Float             // published in MusicState.layerLevels
}

final class MixBus {
    init(layers: [LayerStrip])
    var output: Node
    func setSpace(_ s: Float)                       // 0...1 macro, see section 9
    func setReverb(returnGain: Float, midRT60: Float, lowRT60: Float, damping: Float, over: Double)
    func setDelay(time: Float, feedback: Float, returnGain: Float, over: Double)
    func setShimmer(returnGain: Float, over: Double)            // PASS 2
    func setMaster(_ gain: Float, over: Double)                 // used for start/stop fades
    var limiterBypassed: Bool                                   // offline verification only
}

enum MusicControl {
    case density(Float), space(Float), delayAmount(Float), style(MusicStyle.ID)
    case pinScale(ScaleType?)                       // nil = auto (evolving)
    case visualMood(VisualMood), imageDidChange(transition: Double), visualActivity(Float)
}

final class MusicConductor: @unchecked Sendable {
    init(layers: [MusicLayer], mix: MixBus, seed: UInt64)
    let stateBus: MusicStateBus
    func start()                                    // realtime: creates the timer on the music queue
    func stop(fade: Double = 2.0)
    func post(_ control: MusicControl)              // any thread; lock-protected inbox drained in advance()
    func advance(to time: Double)                   // offline entry point; realtime timer calls it too
    var scoreLog: ScoreLog?                         // offline only: scene/layer/chord/event timeline as JSON
}
```

`GenerativeEngine` keeps its name, `@MainActor ObservableObject`, `isRunning`, `start/stop/shutdown`, `delay/reverb/notes/currentScale` and `shimmerNotePlayed`, so both UIs compile unchanged after PASS 1. It gains:

```swift
nonisolated var musicState: MusicStateBus { get }                       // for the render loop
nonisolated func setVisualMood(_ mood: VisualMood)
nonisolated func imageDidChange(transitionDuration: Double)
nonisolated func setVisualActivity(_ value: Float)                      // optional, <= 1 Hz
@Published var density: Float; @Published var space: Float; @Published var style: MusicStyle.ID
@Published var pinnedScale: ScaleType?                                   // PASS 2
init(seed: UInt64? = nil)                                               // nil = random seed per launch
func renderOffline(seconds:to:seed:limiterBypassed:configure:) throws
```

## 5. Harmony

```swift
struct HarmonicField {
    var tonic: Int                 // pitch class 0-11
    var mode: ScaleType
    var chord: Chord
    var pedalMIDI: Int             // drone root, 33...45
    func midi(degree: Int, octave: Int) -> Int          // true scale degree (fixes the range-filter bug)
    func nearest(to midi: Int, chordTonesOnly: Bool) -> Int
    func chordTones(in range: ClosedRange<Int>) -> [Int]
    var scaleMask: UInt16; var chordMask: UInt16        // 12-bit pitch-class sets
}

struct Chord { var rootDegree: Int; var steps: [Int]; var name: ChordShape }   // steps in scale degrees
enum ChordShape: UInt8 { case triad, sus2, sus4, add9, seventh, quartal, sixNine, openFifth }

enum HarmonyChange { case chord(old: Chord, new: Chord), key(old: HarmonicField, new: HarmonicField) }

final class HarmonyEngine {
    init(rng: SeededRNG, palette: [ScaleType], pinned: ScaleType?)
    private(set) var field: HarmonicField
    func nextChord(tension: Float) -> Chord                       // Markov over root degrees + shape weights
    func proposeKeyMove(brightnessBias: Float) -> HarmonicField?  // nil if pinned
    func voiceLead(from current: [Int], to chord: Chord, range: ClosedRange<Int>) -> [Int]
}
```

- **Chord shapes** are templates in scale-degree steps (triad `[0,2,4]`, sus2 `[0,1,4]`, sus4 `[0,3,4]`, add9 `[0,2,4,8]`, seventh `[0,2,4,6]`, quartal `[0,3,6]`, sixNine `[0,2,4,5,8]`, openFifth `[0,4]`). A candidate is rejected if any two of its pitch classes are a semitone apart, or if it puts a tritone over the pedal. This one rule keeps every scale in `ScaleType` usable, including the exotic ones, without hand-written tables.
- **Root motion** reuses `MarkovChain` with a new preset `chordRoots(degreeCount:)` favouring I, IV, V, vi, ii (for seven-note modes) and steps of a fourth or a second. Shape weights follow tension: low tension prefers openFifth, sus2, add9; high tension prefers seventh, sixNine, quartal.
- **Pedal**: the drone holds the tonic (20 % of scenes: the fifth) for 40-120 s under the moving chords, and moves only on key moves or at a scene boundary.
- **Harmonic rhythm**: chord length 18-60 s, `lerp(55, 20, intensity)` with +-25 % jitter. That is 1-3 real changes per minute.
- **Voice leading**: the four pad voices (register 48-76) take the assignment of new chord tones that minimises total semitone motion, with no voice moving more than 5 semitones and no crossing. Voices change one at a time, staggered over 4-12 s: dip to 20 % over 1.5-3 s, retune with a 0.3 s frequency ramp, swell back over 3-8 s. The other three voices sound throughout, so a chord change is a slow cross-fade and never a gap.
- **Key and mode drift**: every 3-8 minutes, only at a scene boundary during a dissolve, `proposeKeyMove` lists every (tonic, mode) in the style palette whose pitch-class set differs from the current one by at most one swapped note. That covers parallel mode steps (C Ionian to C Lydian), relative moves (C Ionian to A Aeolian, zero notes change, pedal moves) and fifth moves (C to G). Candidates are weighted by the brightness bias (visual mood and scene) and by distance from the last three keys, so the piece wanders without ping-ponging. Sounding notes that leave the scale are re-voiced by the normal voice-leading path over 10-20 s.
- **Pinned scale**: if the user pins a scale, key moves are disabled, tonic stays at C, and chords are still generated by the template rule.
- Melodic layers store notes as scale degrees and resolve them through the field at play time, so they follow chord and key changes for free. A long note (over 1.5 s) that would sit a semitone from a chord tone is moved to the nearest chord tone.

## 6. Macro-form

```swift
enum SceneKind: UInt8 { case stillness, drift, bloom, constellation, tide }
enum ScenePhase: UInt8 { case emerge, bloom, dissolve }

struct Scene {
    var kind: SceneKind
    var duration: Double            // seconds
    var peak: Float                 // peak intensity
    var riseFraction: Float         // 0.3...0.5
    var fallFraction: Float         // 0.25...0.4
    var layers: Set<LayerID>
    var thresholds: [LayerID: Float]   // entry point on the intensity curve, re-rolled per scene
    var brightness: Float           // -1...1 bias
    var registerShift: Int          // -5...+7 semitones
    var tension: Float              // chord-shape bias
    var keyMoveAtEnd: Bool
    func intensity(at t: Double) -> Float
}

final class SceneDirector {
    init(rng: SeededRNG, style: MusicStyle)
    func next(after previous: Scene?, sessionTime: Double, density: Float, mood: VisualMood) -> Scene
}
```

| Kind | Layers | Peak | Length | Character |
|---|---|---|---|---|
| stillness | drone, air (+ rare drips) | 0.20-0.35 | 45-90 s | near-empty, breathing |
| drift | drone, pad + 1 feature layer | 0.40-0.60 | 90-180 s | default state |
| bloom | 4-6 layers | 0.70-1.00 | 120-240 s | full ensemble, brightest |
| constellation | drone + 2-3 of keys, drips, grains, pluck; pad thin or absent | 0.50-0.70 | 90-150 s | points of light |
| tide | drone, pad, air; no melody | 0.40-0.65 | 80-140 s | slow swells |

- **Intensity** `I(t) = 0.12 + (scenePeak - 0.12) * arc(t)`, where `arc` is a raised cosine up over `riseFraction`, flat, then down over `fallFraction`. `scenePeak` is the scene's peak scaled by a session curve `0.75 + 0.25 * (0.6 sin(2 pi t / 437 s) + 0.4 sin(2 pi t / 1151 s))`, so blooms themselves vary in size over 7-19 minutes.
- **Layer entry**: a layer is active when it is in the scene's set and `I(t)` exceeds its threshold (with 0.05 hysteresis). Thresholds are re-rolled per scene from per-layer ranges (drone 0, pad 0.15-0.3, lead 0.35-0.6, keys 0.3-0.55, drips 0.25-0.5, air 0.05-0.4, grains 0.55-0.8, pluck 0.4-0.65), so the order of entry changes scene to scene. Fades are 8-30 s in, 10-40 s out.
- **Continuity**: the floor of 0.12, the drone or air, and the reverb tail carry across boundaries. The next scene's emerge starts when the current scene's dissolve is 60 % done. There is no hard cut and no intended silence.
- **Sequencing**: a weighted transition table (no two blooms in a row; stillness follows a bloom 45 % of the time; first scene is always drift so the app starts gently). A new scene's layer set must differ from the previous one (Jaccard distance at least 0.34) and feature a different lead layer. Durations, peaks, thresholds, register and brightness are continuous random draws, so no scene is ever repeated exactly.
- **Brightness** `B = clamp(0.5 + 0.25 scene.brightness + 0.2 (I - 0.4) + 0.2 (mood.brightness - 0.5) + 0.1 drift)`. Cutoffs are exponential in B: pad `350 * 2^(3.8 B)` Hz (350-4900), drone 180-900 Hz, lead 1.2-6 kHz, keys 1.5-7 kHz, delay return 2.5-5 kHz, Zita damping 3-8 kHz.

## 7. Layers

All periods are re-rolled per scene from the ranges below and then random-walk +-4 % per cycle.

**Drone (PASS 1).** Six oscillators on the pedal: sub (pedal - 12, sine), root x2 (beating 0.05-0.3 Hz apart), fifth, octave, and one roaming partial (3f, 5f or the ninth, re-chosen every 30-70 s at zero amplitude). Each partial has its own amplitude LFO from `ParameterDrift` (periods 31-67 s, golden-ratio spaced), depth scaled by intensity. Pedal moves glide over 6-10 s through a dip to 40 %. LPF 180-900 Hz from brightness.

**Pad (PASS 1).** Four voices, each a pair of `MorphingOscillator`s detuned +-4 to +-9 cents, the detune itself on a slow LFO (beat rate 0.05-0.5 Hz). Wavetables are four band-limited additive tables (sine; 1/n^2 odd; 1/n all, 12 harmonics; hollow 1,3,5 with a formant bump), so the morph index 0-3 never aliases. Index drifts on a 40-90 s channel plus brightness. Voice leading as in section 5. One `MoogLadder` (resonance 0.1) on the layer. Voice count used: 2 at intensity below 0.3, 3 below 0.55, else 4.

**Lead and Answer (PASS 1; answer in PASS 2).** Two soft voices (sine + triangle through `AmplitudeEnvelope`, attack 0.4-1.5 s, release 3-5 s), reusing `VoiceLayer` with ramped frequency. Loop period 17-29 s. Material is a `Motif`:

```swift
struct Motif { var degrees: [Int]; var durations: [Double]; var gaps: [Double] }   // 3-5 notes
struct MotifDeveloper {
    mutating func next(rng: inout SeededRNG) -> Motif?   // nil = rest this cycle (35-50 %)
    // ops: transpose +-1/2 degrees, invert, retrograde, drop a note, augment x2, octave shift,
    //      return to original (25 %), recall one of the last 4 motifs at scene change (30 %)
}
```

New motifs are a weighted random walk (70 % steps, 20 % thirds, 10 % leaps of a fourth or fifth, starts and ends on chord tones). The answer voice replies 40 % of the time after 2-6 s with the transposed or inverted contour, 6 dB quieter, panned opposite.

**Drips / mallets (PASS 1).** The current shimmer voice, kept because it is the sound of the existing app and it feeds `shimmerNotePlayed`. Four `FMOscillator` voices, round-robin, so notes can overlap. Index 0 gives the current sine blip; PASS 2 adds a mallet preset (ratio 1:4, index 1.5 decaying to 0 in 150 ms). Pitches from `MarkovChain.highShimmer` over chord tones in 72-96. Notes come in clusters of 1-4 on a 7-13 s loop, with the gap scaled by density.

**Keys / bells (PASS 2).** Six `FMOscillator` + envelope voices. Presets: soft keys (1:1, index 2 to 0.2 over 1.5 s, decay 2.5-4 s), bell (1:3.5, index 3 to 0.5, decay 4-6 s), glass (1:7, index 0.8). Plays single notes, dyads and three-note rolled chords from chord tones in 55-84 on a 19-41 s loop. The preset is chosen per scene; the index scales with visual saturation.

**Air (PASS 2).** `PinkNoise` through a band-pass with the centre swept 300 Hz-5 kHz over 20-60 s, plus `BrownianNoise` under a 200 Hz low-pass as a faint rumble. Level follows a slow swell. Also the voice of image transitions (section 8).

**Grains (PASS 2).** Twelve sine voices with envelopes (attack 60-150 ms, release 150-400 ms) in four fixed pan groups. Density 0.5-12 grains/s, proportional to `(I - threshold)`. Pitches are chord tones in 72-96 with +-1 octave spread and +-6 cents jitter. Grain starts are scheduled events; with a 20 ms tick the jitter is part of the texture.

**Pluck (PASS 2).** Two `PluckedString` voices. A broken chord of 3-5 notes, 250-600 ms apart, every 23-47 s, rising or falling, low-passed at 3 kHz and sent mostly to the delay.

**Rare events (PASS 2).** `RareEventDirector` fires one event every 120-360 s, with a per-kind cooldown of 8 minutes and an allowed intensity window:

| Event | What | Window |
|---|---|---|
| arpeggioCascade | 10-16 keys notes up the chord, 140-280 ms apart, falling velocity | I > 0.5 |
| shimmerBloom | shimmer return 0 to -8 dB and back over 20 s, pad brightness +0.2 | I > 0.4 |
| airSwell | noise riser over 8 s, then cut into the reverb | any |
| subPulse | drone sub swells +4 dB over 6 s and back | I < 0.6 |
| bellToll | three low bells 4-6 s apart | I < 0.5 |
| hush | all layers but drone and air duck 12 dB for 20-40 s, then return | I > 0.6 |

## 8. MusicState and visual coupling

### Output: lock-free state for the render loop

```swift
struct MusicEvent {                      // POD
    var sequence: UInt32                 // monotonically increasing; reader tracks the last one seen
    var kind: Kind                       // noteOn, chordChange, keyChange, sceneChange, layerEnter, layerExit, rareEvent
    var layer: LayerID
    var midi: UInt8                      // note, or rare-event id
    var velocity: Float                  // 0...1
    var time: Double                     // conductor seconds
}

struct MusicState {                      // POD, fixed size, no heap references
    var time: Double                     // conductor seconds at publish
    var startUptime: UInt64              // lets a reader compute "now" on the same clock
    var sceneIndex: UInt32
    var sceneKind: SceneKind
    var scenePhase: ScenePhase
    var sceneProgress: Float             // 0...1
    var intensity: Float                 // 0...1
    var brightness: Float                // 0...1
    var density: Float                   // 0...1 effective
    var tonic: UInt8                     // pitch class
    var modeIndex: UInt16                // index into ScaleType.allCases
    var scaleMask: UInt16                // 12-bit pitch-class set
    var chordMask: UInt16
    var chordRoot: UInt8
    var chordChangeCount: UInt32
    var keyChangeCount: UInt32
    var layerLevels: (Float, Float, Float, Float, Float, Float, Float, Float)   // by LayerID.rawValue
    var shimmerLevel: Float
    var lastOnsetTime: Double            // any note onset
    var lastOnsetVelocity: Float
    var events: (MusicEvent, ... x8)     // ring of the most recent 8
    func level(_ id: LayerID) -> Float
    func pulse(at now: Double, decay: Double = 0.4) -> Float    // decaying onset envelope
    func events(after sequence: UInt32) -> [MusicEvent]         // convenience; allocation, not for the hot path
}

final class MusicStateBus: @unchecked Sendable {
    func publish(_ state: MusicState)    // conductor queue only (single writer)
    func read() -> MusicState            // any thread, wait-free in practice
    func now() -> Double                 // conductor seconds, from uptime
}
```

`MusicStateBus` is a seqlock: an `Atomic<UInt64>` (`Synchronization`, available on the macOS 26 / visionOS 26 targets) is incremented to odd, the struct is copied into a preallocated buffer, then incremented to even. A reader copies and retries if the counter moved (at most three tries, then returns its previous copy). The writer never blocks and readers never take a lock. Published at 10 Hz and immediately on every event. Layer levels are the conductor's target levels, not measured audio, so no taps are needed.

`shimmerNotePlayed` (Combine) still fires for drips notes, posted with `DispatchQueue.main.async`. Nothing subscribes to it today; new consumers should read `MusicState`.

### Input: hooks for the image pipeline

```swift
struct VisualMood: Sendable {
    var brightness: Float = 0.5      // mean luminance 0...1
    var warmth: Float = 0.5          // 0 cool (blue/teal) ... 1 warm (red/orange)
    var saturation: Float = 0.5
    var energy: Float = 0.5          // contrast / edge energy
    var palette: [SIMD3<Float>] = [] // up to 5 dominant colours, linear RGB (reserved for later use)
    var moodWords: [String] = []     // free text from image metadata or prompt
}
```

- `setVisualMood` posts to the conductor, which low-passes every scalar with an 8 s time constant. Influence is capped so the user's Style and Density stay in charge.

| Input | Effect | Range |
|---|---|---|
| brightness | brightness macro; register shift; key-move bias toward Lydian/Ionian (bright) or Aeolian/Dorian (dark) | +-0.1 on B; 0 to +4 semitones |
| warmth | warm: close voicings, more drone, less air. Cool: quartal and sus shapes, more air and shimmer | +-3 dB on drone/air |
| saturation | FM index on keys and drips, shimmer return | x0.7-1.4 |
| energy | density multiplier, grain rate | x0.7-1.4 |
| moodWords | keyword table to (valence, energy) nudges added to brightness and energy, and to next-scene weights (e.g. "calm, serene, still" favours stillness and tide; "vast, cosmic" favours bloom and shimmer; "dark, ominous" darkens the mode; "playful, bright" favours constellation) | same caps |

- `imageDidChange(transitionDuration:)`, ignored if called within 10 s of the last one: an air swell rises over the transition and decays after; the chord advances at the midpoint if the current chord is older than 8 s; one to three pad voices re-bloom on the new chord; 35 % chance of a single keys or drips accent at the midpoint. The result is that image changes and harmonic changes tend to coincide.
- `setVisualActivity` is an optional slow (at most 1 Hz) scalar the renderer may send (distortion amount, ghost-tap intensity). It maps to pad detune spread and delay send, +-15 %.
- PASS 1 defines all three hooks, stores and smooths the values, and wires brightness and `imageDidChange`'s chord advance. PASS 2 implements the full table. Calling the hooks from the image pipeline and reading `MusicState` in the shaders belong to a later integration step outside this workstream.

## 9. Controls and UI

Today: Delay, Reverb, Notes sliders and a 50-entry Scale picker. Target (PASS 2), same on macOS and visionOS:

| Control | Type | Effect |
|---|---|---|
| Style | picker: Drift (default), Glass, Deep, Garden | `MusicStyle`: mode palette, layer weights, scene-kind weights, register and brightness bias, form tempo |
| Density | slider 0-1 | rest probabilities, loop periods x(1.4 - 0.8 D), scene peak +-0.15, max active layers 3 + round(3 D) |
| Space | slider 0-1 | reverb return -12 to -2 dB, RT60 3-8 s, delay send x0.3-1.0, delay feedback 0.35-0.75, shimmer return up to -12 dB |
| Scale | picker: "Auto (evolving)" first, then the existing list | pins the scale and disables key drift |

Styles: **Drift** (Ionian, Lydian, Mixolydian, Dorian, Aeolian; all layers; balanced). **Glass** (Lydian, Ionian, pentatonic major; keys, grains, drips and shimmer weighted up; +3 semitones; more constellation scenes). **Deep** (Aeolian, Dorian, Phrygian; drone, pad, air weighted up; -4 semitones; longer scenes; more tide and stillness). **Garden** (pentatonic major, yo, Egyptian, hirajoshi; pluck, drips, keys weighted up; sparse pad).

Settings: `audio.notes` becomes Density and `audio.reverb` becomes Space (same keys, so saved values carry over); `audio.delay` is no longer shown; new keys `audio.style` and `audio.scaleAuto` (default true, so existing users get the evolving harmony). PASS 1 changes no UI: Notes drives density, Reverb drives space, Delay scales delay send and feedback, and the Scale picker pins the scale, except that the default "Pentatonic Major" is treated as Auto until the picker is touched.

## 10. Variation and seeding

- One `SeededRNG` per engine, forked per subsystem (harmony, scenes, each layer, events) so adding a layer does not change the others' streams. Realtime seed is random per launch; offline seed comes from the render config, so renders are reproducible and comparable.
- Sources of non-repetition, from fast to slow: note-level rests and mutations; loop periods that never align and drift; partial and timbre LFOs on golden-ratio periods; chords (18-60 s); scenes (45-240 s, continuous parameters, no immediate repeats); session curve (7-19 min); key wander (3-8 min per move). Motif recall is the only deliberate long-range repetition.

## 11. Acceptance criteria

Measured by `scripts/render-music.sh` on fixed seeds 1, 2, 3 (5-minute renders) plus one 30-minute render. All seeds must pass. Baseline values in brackets.

**Safety**
- True peak at or below -1.0 dBFS [-0.14]; zero samples at or above 0.999; zero NaN.
- Limiter-bypassed render peaks at or below -3 dBFS.
- No silence longer than 4 s (1 s RMS below -60 dBFS); minimum 1 s RMS at or above -50 dBFS.

**Loudness and dynamics**
- Mean RMS between -27 and -19 dBFS [-24.8].
- RMS standard deviation over time 2.5-6 dB [8.6, erratic]; the per-30 s RMS trace spans at least 5 dB.

**Timbre**
- Spectral centroid mean 450-1400 Hz [285]; standard deviation at least 250 Hz [132]; p95 at least 1500 Hz [507].
- Per-30 s centroid max/min at least 2.0 [2.6 but all under 430 Hz].
- Energy share above 2 kHz at least 1.5 % overall, and each of the bands below 120, 120-500, 500-2k, 2k-8k Hz exceeds 3 % in at least one minute.
- Spectral novelty between consecutive minutes: median at least 0.006 [0.0017], three times baseline or better.

**Harmony and events**
- Analyzer chord changes per minute 2-8 [8.6, mostly melodic noise]; at least 10 distinct chords per 5 minutes [15].
- Pitch classes above 5 %: 5-8 per 5 minutes [6]; entropy 2.6-3.3 bits [2.99].
- 30-minute render: at least 9 pitch classes above 3 % overall and at least 3 key changes in the score log.
- Chroma novelty between minutes: median 0.10-0.45 [0.19-0.46].
- Onsets 150-600 per 5 minutes [95]; per-30 s onset count max/min at least 3.

**Form and non-repetition**
- 10 s self-similarity, mean off-diagonal at or below 0.65 [0.75]; minimum at or below 0.35 [0.51].
- Score log, 10 minutes: at least 6 distinct layers each active (level above 0.2) for 30 s or more after PASS 2 (at least 4 after PASS 1); 2-6 layers active at any time; at least 4 scene changes.
- 30 minutes: autocorrelation of the 1 s RMS envelope has no peak above 0.5 for lags 20-600 s; median chroma distance between all minute pairs at least 0.15.
- Same seed twice gives an identical score log.

**Stereo**
- Side/mid between -12 and -4 dB [-5.4]; L/R correlation 0.2-0.8 [0.55]; correlation below 120 Hz at least 0.9.

**Performance**
- Offline render at least 15x realtime on the dev Mac and no more than 4x the baseline engine's wall time for the same duration (record the baseline first).
- Conductor tick: mean under 0.2 ms, max under 2 ms (counted inside `advance`, reported in the score log).
- No MainActor hop anywhere under `advance` (debug `dispatchPrecondition(.notOnQueue(.main))` in realtime).
- Graph construction under 250 ms on macOS.
- Listening check on visionOS hardware is out of scope for this workstream; the realtime macOS run must show no dropouts in a 10-minute session.

PASS 1 must meet Safety, Loudness, Stereo, Performance, determinism, chord rate, self-similarity mean, centroid mean and standard deviation. The remaining timbre, onset, layer-count and 30-minute criteria are PASS 2 gates.

## 12. Build plan

### PASS 1: core architecture

1. Probes (half a day, before anything else): fan-out sends from one node to three mixers; `NodeParameter.ramp` in offline manual-rendering mode including 10 s ramps; `ZitaReverb` and `PeakLimiter` in offline mode; `MorphingOscillator` with custom tables for clicks. Each has a fallback (see risks).
2. `SeededRNG`, `MusicScheduler`, `LoopClock`, `MusicState`, `MusicStateBus`; seed `MarkovChain`; true degree mapping in `Scale`.
3. `LayerStrip`, `ParamRamp`, `MixBus` (dry, Zita reverb, delay, master high-pass, limiter, trim).
4. `HarmonyEngine` (chords, voice leading, key moves).
5. `SceneDirector` with the five scene kinds and the Drift style; intensity and brightness macros.
6. `MusicConductor` on its queue; `GenerativeEngine` reduced to a facade with the existing public surface plus the new hooks.
7. Layers: Drone, Pad, Lead (motifs, no answer yet), Drips.
8. Harness: `OfflineRender` drives `conductor.advance`; seed and limiter-bypass in the render config; score log JSON beside the WAV. Analyzer: max silence gap, band energy shares, sub-120 Hz stereo correlation, RMS-envelope autocorrelation, onset max/min, and a PASS/FAIL table read from `scripts/music-criteria.json`.
9. Render seeds 1-3, tune to the PASS 1 gates, build both platforms, commit.

### PASS 2: more layers, textures, events, polish, UI

1. Keys, Air, Grains, Pluck; Lead answer voice; mallet preset for Drips.
2. Shimmer bus; tape character on the delay (time wow 0.3 % at 0.4 Hz via ramps, `TanhDistortion`).
3. `RareEventDirector`.
4. Visual coupling: full mood mapping, mood-word table, `imageDidChange` behaviour.
5. Four styles; Style / Density / Space / Scale-Auto controls in `ControlsView.swift` and `ContentView.swift`; settings keys.
6. Remove `AudioEngine.swift` and `EffectsChain.swift`; update `docs/plans/music-current.md` to describe the new engine.
7. 30-minute render, all gates, CPU check, both builds, commit.

## 13. Risks and fallbacks

| Risk | Fallback |
|---|---|
| Fan-out from one node to several mixers misbehaves | Give each strip three `Fader`s fed from a small `Mixer` copy, or drop per-layer delay sends and send the dry bus |
| `ramp(to:duration:)` unreliable offline or for long durations | Conductor-side glides: step `AUParameter.value` at 50 Hz from a preallocated glide list |
| 125 nodes cost too much on visionOS | Shrink grains 12 to 8, keys 6 to 4, drop the Air rumble, merge Lead and Answer strips; PASS 1's 60 nodes is the known-good floor |
| `MorphingOscillator` clicks on index or frequency change | Two fixed-table `Oscillator`s per voice cross-faded by amplitude |
| `PitchShifter` artifacts on the shimmer | Lower return, longer window, or replace with octave-up sine doubling in the Pad |
| `PeakLimiter` pumping | Lower layer gains; the bypass test keeps the limiter idle by construction |
| Graph build time on launch | Build on a background task before `start()` is enabled |
| `Panner` on mono-summed stereo sources narrows the pad | Pan the two oscillators of each pair separately before the layer mixer |
