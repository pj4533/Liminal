# Drop transitions: plan

Goal (user, 20 November 2026): in Lo-Fi the image change should be a hit. The transition starts when
the outgoing drum take's fill starts, gets more broken up through the fill, and is completely done at
the first drum hit of the new loop. "Fade out, but no fade in." "Some sort of glitchy transition. Boom,
new drum loop." Many different kinds of transition out.

Status: built on 20 November 2026; what changed from this plan and the measurements are in
`docs/decisions/transitions.md` T44-T50 (among them: k = 2.5 / 1.5, the old framing held until the cut,
the fresh calm under the last quarter second, dive dropped from the outs, per-drop pipeline
specializations, and the relaxed tail and build gates).

## 1. What is wrong today

The swap already completes on the downbeat (`LofiImageReveal.start = downbeat - s1 * D`, T43). What
continues after the downbeat is everything else:

| Still moving after the downbeat | Where | How long |
|---|---|---|
| Effect envelope decay over `[s1, 1]` | `ImageTransition.swift` `envelope` | 24-42 % of D, 0.6-1.6 s |
| Feedback trails of the old picture | `EffectsUniformsComputer` feedback boost to 0.72 | about 14 frames at the peak |
| visionOS relief morph and relief dip | `DepthReliefField.weight`, `ShellLayout.reliefStrength` | to the end of D |
| Vibrance lerp between the two pictures | both renderers | to the end of D |
| Fresh-image fade of the base effects | `EffectLook.fresh()` | `max(1.5, 0.4 D)` from the start |
| Footage piece crossfade, centred on the downbeat | `FootageWeaver.swift:299-307` | half of 0.375-0.75 beats |
| Visual `fillAccent` release (bloom, vibrance) | `LofiFill.accent` | 0.75 beats |
| macOS boosts from the 30 Hz compute | `EffectsMetalView.swift:438-448` | up to 33 ms stale |

Image changes happen every 8 bars (beat 32 and beat 64 of each 64-beat take), not every 16. Only beat
64 starts a new take.

## 2. Design summary

1. A second transition shape, the **drop**, used by every Lo-Fi drum-timed change. Ambient mode and
   any change that is not on the drum grid keep the existing surge, swap and settle family unchanged.
2. A drop has one clock: `p = (tPresent - tS) / (tD - tS)`, where `tS` is the fill start, `tD` the
   audible downbeat and `tPresent` the time the frame reaches the display. For `p < 1` only the
   outgoing picture is on screen and it breaks up with intensity `a(p)`, which rises monotonically and
   peaks on the last frame. From `p >= 1` the frame is exactly a normal non-transition frame of the new
   picture.
3. No impact frame after the cut. The finisher (whiteout, blackout, invert, collapse) is the last part
   of the build, so the frame before the cut is the peak and the frame at the cut is clean. Research
   allows a flash of at most 33 ms after the cut; we take the stricter option because the user asked
   for no fade in at all. Revisit only if the user finds the cut too dry.
4. Fourteen new glitch styles, each combined with one of five colour layers and one of five finishers
   picked from the seeded director, plus six existing warps run as "outs" (surge without the settle).
5. Both drum boundaries are drops. The turnaround (beat 64, new take) runs at full strength. The
   halfway change (beat 32, same take) runs at 0.7 strength with no finisher flash. An ease-back after
   any downbeat would bring the old complaint back at half the changes, and `perf-run.sh --lofi` keeps
   its 8-bar reveal count. This is the one design choice the user did not state; it is easy to change
   (section 4.6) after they have watched it.

## 3. Timing

### 3.1 Where the fill starts

There is no measured fill data, and the beat grid JSON is gitignored, so fill starts are detected at
runtime from the landmarks each take already has.

New `Liminal/Audio/Lofi/LofiFillDetector.swift` (nonisolated, Foundation only, pure):

```swift
nonisolated struct LofiTakeFills: Sendable, Equatable {
    var halfwayStartBeat: Double      // in take beats, < 32
    var turnaroundStartBeat: Double   // in take beats, < 64
    var halfwayDetected: Bool, turnaroundDetected: Bool
    /// Attack beats inside each fill, strongest 32 at most, ascending.
    var halfwayHits: [Double], turnaroundHits: [Double]
}
nonisolated enum LofiFillDetector {
    static func detect(landmarks: [LofiDrumLandmark], framesPerBeat: Double) -> LofiTakeFills
}
```

Method, for the boundary at beat B (32 or 64):

1. Activity per beat `d[b]` = sum over landmarks whose attack falls in beat b of a kind weight (kick 1,
   snare 1, other 1, hat 0.5) times `0.5 + 0.5 * strength`.
2. Baseline per position in the bar: `m[j]` = median of `d[b]` over the groove beats with `b mod 4 == j`.
   Groove beats are 0-23 and 32-55 (the two bars before each boundary are left out). This removes the
   take's own backbeat pattern, which made the naive threshold walk in the code map noisy.
3. Excess `x[b] = d[b] - m[b mod 4] - tau`, with `tau = max(1.0, 0.3 * median(d))`.
4. The fill is the suffix ending at B with the largest sum of `x`, searched over starts `B-8 ... B-1`.
   A positive best sum means a fill was detected; a quiet beat inside a fill does not end it.
5. The start is the first landmark attack inside the starting beat, or the beat line if there is none.
6. Not detected, or no landmarks (no private drum takes): 2 beats before beat 32, 4 beats before beat
   64. These are `LofiFill.buildBeats`, which the audio fill accent and filter sweep already use.

Clamps on the build length `T = tD - tS`: at least 1 beat, at most 8 beats, and at most 6 s (then the
largest whole number of beats that fits). At the library's tempi (58-75 BPM) that is 0.8 s to 6 s.

`tau` and the weights are calibrated in phase 1 against the 25 private takes with a local-only test
(skipped when the takes are absent). Only aggregate results are written to the decisions doc; take
names and per-take numbers stay out of git. Committed tests use synthetic landmark fixtures.

The detector runs where landmarks are built (`LofiDrumTake` preparation in `LofiPhraseBank.prepare`,
off the audio thread) and its result is published on the existing side channel as
`LofiTransportInfo.fills`. Nothing on a realtime path changes, and no audio output changes.

### 3.2 Where the cut lands

- `tD` is `LofiTakeGrid.nextBoundary(...).time`. It already includes the output latency read once
  when the transport was armed. The new take's recorded first hit is 4-8 ms after it.
- Each renderer evaluates the reveal at the frame's presentation time, `tPresent = tDraw + lead`:

  | Platform | `lead` | Basis |
  |---|---|---|
  | macOS | measured draw-to-present latency + half a frame; starting value 25 ms | `MTLDrawable.addPresentedHandler` in phase 4 |
  | visionOS | 28 ms (two 90 Hz frames + half a frame) | estimate; the Simulator cannot measure it, so it is unverified until checked on a device |

  With an exact latency and the half-frame bias, the first clean frame is presented between half a
  frame before `tD` and half a frame after it (±8.3 ms at 60 Hz, ±5.5 ms at 90 Hz). Sound after
  picture is tolerated far better than picture after sound, so errors should fall early.
- The clock is continuous (uptime, the same base as `transportOrigin`). A dropped frame makes `p` jump
  forward; the cut is the first frame with `p >= 1` and cannot be skipped. The build holds its peak
  until then.

### 3.3 `LofiImageReveal`, drop form

```swift
nonisolated struct LofiImageReveal: Sendable {
    let downbeat: Double            // tD, audible
    let fillStart: Double           // tS
    let spec: TransitionSpec        // spec.drop != nil, spec.duration == Float(downbeat - fillStart)
    let hits: [Double]              // uptime of the fill's attacks, ascending, at most 32
    let fill: LofiFill
    var start: Double { fillStart - 0.15 }                 // pre-roll: texture pickup before p > 0
    func progress(presentedAt t: Double) -> Double         // clamp((t - fillStart) / (downbeat - fillStart))
    func frame(presentedAt t: Double) -> DropFrame         // progress, done, kick, step
}
nonisolated struct DropFrame: Sendable, Equatable {
    var progress: Float   // 0...1
    var done: Bool        // progress >= 1: render a normal frame of the new picture
    var kick: Float       // 0...1, max over hits h <= t of exp(-(t - h) / 0.07)
    var step: Float       // integer-valued: hits so far + floor(T * (4 p + 10 p^2)), a 4 -> 24 Hz clock
}
```

`beatAligned` and the `s1` arithmetic go away for drops. The 150 ms pre-roll moves the image pickup
and upload (the T39 hitch) ahead of the first visible change; during it the shader shows the old
picture untouched.

### 3.4 Intensity

`a(p) = (exp(k p) - 1) / (exp(k) - 1)` for `p < 1`, and 0 from `p = 1`. `k = 4` when `T >= 1.2 s`,
`k = 2.5` for shorter builds so they are visible sooner. The halfway change multiplies by 0.7. The
per-hit `kick` and the `step` counter make the picture jolt with the drummer's own hits and re-hash
faster toward the cut. Finishers ramp separately over the last part of the build (section 4.3).

### 3.5 What changes at the cut frame

On the first frame with `done`:

| Item | Before the cut | At and after the cut |
|---|---|---|
| Pictures | previous = old, source = new, swap 0 (or the Bleed leak) | previous dropped; source only |
| `transitionProgress`, all `tx*` uniforms | build values | 0, the no-transition path |
| Every `TransitionBoost` | times `a(p)` | not computed (`inTransition` false) |
| Feedback | up to 0.72 | **0 for this one frame** (history treated as invalid, as when no previous output exists), then the base value. Without this the wrecked old picture ghosts for 3-4 frames at the base mix of 0.10-0.34 |
| Vibrance factors | old picture's | new picture's (a step, no lerp) |
| visionOS relief weight | 0 (old relief) | 1 (new relief) |
| visionOS relief strength | `1 - 0.6 a(p)`: the shell flattens as the picture breaks up | 1 |
| Fresh hold | fade over `min(max(1.5, 0.4 T), T)` from `tS`, so the base effects are fully calm by the cut | held; the base look returns later on its existing slow schedule |
| Ken Burns | old crop held through `outgoingZoomScale` | new picture's zoom, already running unseen since `tS` |
| Visual `fillAccent` | rises over the build | 0 (release removed for the visual reader only) |
| Footage piece change | fades in over `dissolveBeats`, ending at the cut | complete |

The footage dip and its slow return (`VideoComposite.settled`) stay as they are. Footage is already
low when the cut happens, and its return over the following seconds is the film weaving back in, not
part of the transition. Geometry glitches move the picture only; colour layers and finishers run after
the footage composite, so a whiteout, blackout or crush covers the footage too.

### 3.6 Cases

| Case | Behaviour |
|---|---|
| Short fill (1 beat) | `T` = 1 beat (0.8-1.0 s), `k = 2.5`. |
| Long fill (a bar or more) | Up to 8 beats and 6 s. The exponential keeps the first half subtle. |
| No fill detected, no landmarks, Lo-Fi without drum takes | Default 2 / 4 beats, no kicks, the step clock alone. Strength 0.7 without drum takes (no hit to match). |
| Take repeats (late-phrase fallback) | Nothing special. The boundary time depends only on the current take, the repeated take starts with the same hit, and `nextBeatDuration` is not needed by a drop. |
| Tempo extremes | Tests cover 58, 69, 75 and 82 BPM. The clamps are in beats and seconds. |
| First play | No drop into the first downbeat: there is no outgoing fill and the first picture appears as today. The first drop is at beat 32. |
| Planning late (Play close to a boundary) | If `tD - now >= 0.6 s`, `tS = max(tS, now + 0.15)`. Otherwise this boundary is skipped and the picture stays. Late is worse than missing. |
| No staged image at `start` | Standby image as today; if none, skip. |
| Stop | The scheduling task is cancelled. A drop in flight runs out on the uptime clock and cuts at its planned time. |
| Route recovery (`recoverStoppedGraph`) | The grid origin changes. Before firing, `scheduleFills` re-reads the grid; if the origin moved by more than 1 ms and it is not the expected next take, the cue is discarded and re-planned. A drop already in flight finishes on its old clock (6 s at most). Output latency is re-read once on re-arm, as today. |
| Dropped or skipped frame at the cut | The cut is the next submitted frame. |
| Ambient mode, manual or timer advances | Unchanged bell family and director sequence. The conductor still lands its chord on the swap (T13). |

## 4. Styles

### 4.1 Geometry styles (new `TransitionStyle` cases, raw values 13-26)

All are stateless and single pass, and sample only textures the shader already binds. `a` is `txEnv`,
`n` is `txStep`, `kick` is `txKick`, `seed` is `txSeed`, and `amt` is `txAmount` (from intensity
through `EffectLook.tri`). "Stage A" is `distortedUV`, inside the `txEnv > 0` block.

| # | Name | Family | Recipe | Parameters |
|---|---|---|---|---|
| 13 | tear | scan | Rows grouped into strips; a strip shifts sideways when its hash passes the gate. `strip = floor(y * mix(6, 48, a))`, `h = hash(strip, n)`, `x += step(1 - 0.8 a, h) * (h - 0.5) * amt * a`, mirrored at the edges. | `amt` 0.15 / 0.30 / 0.45; seed sets vertical or horizontal |
| 14 | blocks | block | Macroblock displacement. Grid cell `mix(1/12, 1/40, a)` of the frame; gated cells sample from an offset `(hash2 - 0.5) * amt * a`, and their UV is quantised to 8 sub-cells so they go chunky. | `amt` 0.10 / 0.20 / 0.30 |
| 15 | mosh | block | Datamosh from the feedback texture, which is already paid for. Feedback mix pulled to 0.72 by `a`; the feedback UV gets a per-block drift vector that changes with `n`, so held blocks slide and smear. | drift 0.02 / 0.05 / 0.08 |
| 16 | crush | block | Resolution crush: `cells = mix(512, 20, a^2)`, `uv = (floor(uv * cells) + 0.5) / cells`. Forces the posterize colour layer. | floor cell count 40 / 24 / 14 |
| 17 | vhs | scan | A tracking band of height `0.08 + 0.15 a` rolling down the frame with a sine tear inside it, plus a vertical roll `y = fract(y + a^3 * 0.5 * hash(n))` and chroma delayed by 1 % of the width. | roll 0.2 / 0.5 / 0.8 |
| 18 | sort | scan | Pixel-sort look: where luma passes `mix(0.9, 0.3, a)`, the pixel takes the brightest of 4 taps stepped along one axis over a reach of `amt * a`. The taps replace the three new-picture samples a drop does not take (section 6). | reach 0.08 / 0.16 / 0.24; seed sets the axis |
| 19 | punch | cut | Zoom punch: `scale = 1 + amt * a^2 + 0.08 kick` about a seeded centre, with a 4-tap radial streak. | `amt` 0.20 / 0.35 / 0.50 |
| 20 | slitscan | scan | Rows sheared by a travelling wave, strongest at one edge: `x += sin(y * 9 + time * 5) * amt * a * y'`, with the wave number stepped by `n`. | `amt` 0.05 / 0.10 / 0.16 |
| 21 | jumpcut | cut | Stutter edit. On each step the picture jumps to a seeded crop: offset up to `amt * a`, zoom 1-1.6, sometimes mirrored. Held between steps. | `amt` 0.10 / 0.20 / 0.30 |
| 22 | fracture | cut | The Kaleidoscope fold with the wedge count stepping 2, 4, 6, 8 as `a` rises and the fold axis turning a notch on each hit. Reuses the existing fold code. | fold 0.5 / 0.8 / 1.0 |
| 23 | shutter | cut | Venetian bars close over the picture: `N = 6 + floor(seed * 10)` bars, black where `fract(coord * N) < a`, with a channel split on the bar edges. Its own finisher (the bars are shut at the cut). | bar axis from seed |
| 24 | static | block | Blocky coloured noise takes cells over: `gate = step(1 - a, hash(cell, n))`, gated cells show per-channel noise mixed 0.85. Cell size falls as `a` rises. | coverage at the peak 0.6 / 0.8 / 0.95 |
| 25 | bleed | block | Blocks of the new picture pre-echo in, displaced. The swap field is the block hash and `txMix = 0.35 a`; old-picture blocks get the `blocks` displacement. The only style that shows the new picture before the cut. | leak at the peak 0.20 / 0.30 / 0.35 |
| 26 | scramble | block | Tile shuffle: the frame is cut into `g x g` tiles (`g` steps 2, 3, 4, 6, 8) and a share `a` of the tiles trade places by a hashed permutation. | none beyond `a` |

Six existing styles also run as outs in a drop: whirlpool, kaleidoscope, dive, melt, shatter and
facets. Their UV moves and boosts are driven by `a(p)` instead of the bell, their swap stays at 0, and
they pick a colour layer and a finisher like the rest. They have a director weight of 0.5. Rainbow,
afterimage, tide, ripple, prism and solarize are not offered in a drop: their identity is the gradual
exchange or the settle.

### 4.2 Colour layers (stage B, inside the transition branch, on the blended colour)

| Id | Name | Recipe |
|---|---|---|
| 0 | none | |
| 1 | split | `chromOffset += dir(n) * 0.03 * a^2`, direction re-drawn on each step. No extra samples. |
| 2 | posterize | `levels = mix(32, 4, a^2)`; `c = floor(c * levels) / levels`. |
| 3 | falsecolour | Per block and step, channels rotate (rgb to gbr or brg) on gated blocks; gate share `0.5 a`. |
| 4 | grain | Per-channel block noise mixed in by `0.5 a^3`. |
| 5 | scanlines | Every second line darkened by `0.6 a`, saturation down by `0.5 a`. |

### 4.3 Finishers (`txFinish` = ramp 0-1 over the last part of the build)

| Id | Name | Window (share of the build, and at least 2 frames) | Recipe |
|---|---|---|---|
| 0 | none | | The cut is from the peak glitch. |
| 1 | whiteout | last 18 % | Exposure `c *= 1 + 6 f^3`, then toward white by `f^2`. The last frame is at least 90 % white. |
| 2 | blackout | last 12 % | `c *= 1 - f^2`. |
| 3 | invert | last 2 frames | Luma inverted, hue kept. |
| 4 | collapse | last 15 % | CRT power-off: the picture squeezes to a bright horizontal line (`y' = 0.5 + (y - 0.5) / (1 - f)`, black outside), brightness up by `2 f`. |

Photosensitivity: a finisher is one flash per transition, at least 20 s apart. No style alternates
the full field. The clip gate `flash_rate` (section 8.2) enforces at most 3 full-field luminance
reversals of 10 % or more in any second (WCAG 2.3.1).

### 4.4 Spec and director

```swift
nonisolated enum DropColour: Int, CaseIterable, Sendable { case none, split, posterize, falsecolour, grain, scanlines }
nonisolated enum DropFinisher: Int, CaseIterable, Sendable { case none, whiteout, blackout, invert, collapse }
nonisolated struct DropPlan: Sendable, Equatable {
    var colour: DropColour
    var finisher: DropFinisher
    var curve: Float      // k
    var strength: Float   // 1 turnaround, 0.7 halfway or no drum takes
}
// TransitionSpec gains: var drop: DropPlan? = nil
```

- `TransitionSpec.envelope` and `swap` branch on `drop`: `a(tp) * strength` and the leak (Bleed only),
  both 0 at `tp >= 1`. Bell specs are untouched, so every existing test of them stands.
- `TransitionStyle.dropFamily` = the 14 new cases plus the six outs. `family` (the bell pool) is
  redefined as the existing 12 and no longer derived from `allCases`.
- New `TransitionFamily` cases `scan`, `block`, `cut`. The recency rule (not within the last 4) and
  the family rule (not the same family twice running) apply across both pools through the shared
  history.
- `TransitionDirector.next(..., mode: .bell | .drop(fill: LofiFill, buildSeconds: Float))`. In drop
  mode it draws the style from `dropFamily`, then the colour layer and the finisher. A finisher never
  repeats back to back, and the halfway change never draws whiteout or invert. The extra random draws
  happen only in drop mode, so the bell sequence for a given seed does not change.
- Gentle set below intensity 0.25: tear, crush, vhs, slitscan, shutter, melt, each with blackout or
  collapse so the swap stays hidden at small amounts.
- Weights: wild stretch (`drive` high) favours blocks, mosh, static, scramble, jumpcut, fracture,
  punch; clear stretch favours tear, vhs, slitscan, crush, shutter, sort. Short builds (under 1.5 s)
  double the weight of punch, jumpcut, shutter and static, which read in a beat.

### 4.5 Debug flags

`-LiminalTransitionStyle` accepts the new names. New: `-LiminalDropColour <name>`,
`-LiminalDropFinisher <name>`, `-LiminalDropLead <ms>` (overrides the display lead),
`-LiminalDropOff YES` (the T43 behaviour, for A/B). All four join
`DebugLaunchOptions.blocksImageGeneration` and the flag table in `docs/development.md`.

### 4.6 If the halfway drop is too much

One constant, `LofiFill.halfway` strength (0.7), and one switch in `LofiImageReveal.next` choosing
drop or bell per fill. Setting halfway to the bell restores T43 for beat 32 only.

## 5. Uniform contract

Four fields appended at the end of `EffectsUniforms` (Swift) and the Metal struct, in this order.
The struct grows from 61 to 65 floats. Defaults of 0 mean no drop.

| Field | Meaning |
|---|---|
| `txStep` | Integer-valued re-hash counter (`DropFrame.step`). |
| `txKick` | Per-hit transient, 0-1. |
| `txLayers` | `colour + 8 * finisher` (small exact integers). |
| `txFinish` | Finisher ramp, 0-1. |

Existing fields in a drop: `txStyle` (13-26, or an out's own value), `txEnv` = `a(p) * strength`,
`txMix` = leak (0 except Bleed), `txSeed`, `txSoft` (0.02 for hard block edges), `txAmount`.

`EffectsUniformsComputer.compute` gains one parameter, `drop: DropFrame? = nil`, and stays the single
source of truth. With `drop?.done == true` it takes the no-transition path. Both renderers keep
passing constants with `setFragmentBytes`.

## 6. GPU budget

- One pass, no new textures or render targets, 2048 x 2048 on visionOS unchanged.
- Geometry glitches sit in stage A inside the existing `txEnv > 0` block. Colour layers and finishers
  sit in stage B inside the existing `transitionProgress > 0` block, in half precision.
- In a drop the new picture is not visible (except Bleed), so the three `sourceTexture` samples are
  skipped for drop styles other than Bleed. Sort and punch spend that saving on their 4 taps of
  `previousTexture`. No style takes more than 4 extra taps.
- Shared helpers (`hash`, block gate) are small `static inline` half-precision functions.
- If the non-transition gate (1.01) fails because of register pressure behind the branch (T19, T21),
  the fallback is a function constant `kDropTx`: the drop code is compiled only into drop variants
  of the pipelines, which are built at renderer start so that entering a drop never compiles a
  pipeline. Try the in-branch form first.

## 7. Files

| File | Change |
|---|---|
| `Liminal/Audio/Lofi/LofiFillDetector.swift` (new) | Section 3.1. |
| `Liminal/Audio/Lofi/LofiDrumTake.swift`, `LofiTransportInfo.swift`, `LofiPlayback.swift` (`publishTransport`) | Compute `fills` with the landmarks; publish on the side channel. |
| `Liminal/Audio/Lofi/LofiScore.swift` | `LofiFill.accent(beatsFromBoundary:release:)`; `LofiTakeGrid.visualAccent(at:)` with no release. The audio renderer's own accent is not touched. |
| `Liminal/Visual/MusicReactor.swift` | Read `visualAccent`. |
| `Liminal/Visual/ImageTransition.swift` | New styles, families, `DropColour`, `DropFinisher`, `DropPlan`, drop envelope and swap, boosts for the new styles and the outs, director drop mode. Stays Foundation-only (shader bench compiles it). |
| `Liminal/Visual/VisualEngine.swift` | `LofiImageReveal` drop form, `DropFrame`, `scheduleFills` reads `bus.transport()?.fills`, pre-roll, late-plan and grid-change rules. Keeps the log line "Lo-Fi image reveal at downbeat" (perf-run counts it). |
| `Liminal/Visual/EffectsUniformsComputer.swift` | `drop:` parameter, new fields, feedback pull for mosh. |
| `Liminal/Visual/EffectLook.swift` | Fresh fade capped at `T` for a drop. |
| `Liminal/EffectsUniforms.swift`, `Liminal/Shaders/EffectsRenderer.metal` | Four fields; `TX_*` constants 13-26; stage A and stage B code. |
| `Liminal/Visual/EffectsMetalView.swift`, `ContentView.swift`, `TimerDrivenCrossfade.swift` | macOS: while a reveal is pending, uniforms are computed at draw time from the frame inputs with `reveal.frame(presentedAt: now + lead)`. On `done` the draw binds the source as previous and zeroes feedback for one frame, without waiting for the 30 Hz timer to clear `previousFrame`. Log "Lo-Fi drop cut presented … ms from downbeat" from the presented handler. |
| `Liminal/visionOS/ImmersiveDomeView.swift`, `OffscreenEffectsRenderer.swift` | `CGImageTransitionState` uses `frame(presentedAt:)`; vibrance step; one-frame feedback invalidation on the cut for both eyes; log the cut frame start against `tD - lead`. |
| `Liminal/Visual/Spatial/DepthReliefField.swift`, `ShellLayout.swift` | Drop variants of the weight (step) and strength (section 3.5). |
| `Liminal/Archive/FootageWeaver.swift` | Lo-Fi piece change: `start = boundary.time - fade`. |
| `Liminal/Utils/DebugLaunchOptions.swift` | Section 4.5. |
| `scripts/shader-bench.swift`, `shader-bench.sh`, `tx-clip.sh` | `--drop --fill <s> --hits <list> --tx-colour --tx-finisher`; `sequence.json` records `downbeatFrame`; scenarios accept the drop fields. Add `LofiFillDetector.swift` to the compile list only if the bench needs it. |
| `scripts/tx-check.py` | `score --drop` with the gates in section 8.2. The bell gates are unchanged. |
| `scripts/perf-run.sh` | `--lofi` also fails on a late cut (section 8.4). |
| `scripts/drop-sync.py` (new) | Section 8.3. |
| Tests | Section 8.1. |
| Docs | `docs/decisions/transitions.md` T44 onward (timing, fill detector with aggregate calibration, library, uniforms, measurements, GPU); `docs/experience.md:45, :77`; `docs/architecture.md:27`; `docs/development.md` flags; `docs/README.md` index; repository maps in `CLAUDE.md` and `AGENTS.md` for the new file. |

### Work packages

| Phase | Package | Depends on |
|---|---|---|
| 1 | A. Fill detector, publication, synthetic and local-only tests | |
| 1 | B. Spec, drop timing, `LofiImageReveal`, director, timing tests | |
| 1 | C. `tx-check.py --drop` gates and `drop-sync.py` | |
| 2 | D. Uniforms, shader styles, boosts, shader-bench `--drop`; clips and GPU per style | B |
| 3 | E. macOS renderer and scheduling | A, B, D |
| 3 | F. visionOS renderer, relief, perf-run check | A, B, D |
| 3 | G. Footage change and visual accent | B |
| 4 | H. Verification runs (section 8), tuning from the clips, docs | all |

A, B and C touch disjoint files. D owns `ImageTransition.swift` after B. E and F touch disjoint
platform files; `VisualEngine.swift` belongs to E.

## 8. Verification and acceptance gates

### 8.1 Unit tests (Swift Testing)

| Test | Gate |
|---|---|
| Drop is done at the downbeat | For every drop style, 58 / 69 / 75 / 82 BPM, fills of 1, 2, 4 and 8 beats: `frame(presentedAt: tD).done`; `compute(drop:)` at `tD` equals `compute` with no transition, field for field. |
| Peak at the cut | At `tD - 1/60 s`, `txEnv >= 0.9 * strength`. `a(p)` is non-decreasing over 200 samples. |
| Starts at the fill | `fillStart` equals the detector's start mapped to uptime within 1 ms; build length within 1-8 beats and at most 6 s. |
| Swap frame | For frame times on a 60 Hz and a 90 Hz grid at 16 phase offsets, the first `done` frame is presented in `[tD - period/2, tD + period/2)` given an exact lead. |
| Late planning | `tD - now` of 0.5 s skips; 0.7 s gives a build of 0.55 s. |
| Fill detector | Synthetic takes with fills of 0, 1, 2, 4 and 8 beats: detected start within half a beat; the 0-beat case returns the defaults; a busy backbeat without a fill is not detected. |
| Fill detector, local only | On the private takes: a turnaround fill of 1-8 beats detected in at least 20 of 25; every result inside the clamps. |
| Director, drop mode | 48 drops: no `.classic`, no bell-only style, no style within the last 4, no family twice running, no finisher twice running, at least 12 distinct styles and 4 finishers. Halfway never draws whiteout or invert. |
| Director, bell mode unchanged | The first 64 bell picks for seeds 0-3 are identical before and after the change (values captured from `main`). |
| Uniform layout | `MemoryLayout<EffectsUniforms>.size == 65 * 4`, stride the same, `offset(of: \.txStep) == 61 * 4`; the Swift field names in order equal the Metal struct's field names parsed from `EffectsRenderer.metal`. Update the existing check in `ArchiveFootageTests`. |
| Golden parity | `EffectLookTests.goldenParityWithModel` passes with no row edited. |
| Existing tests | `lofiImageIsFullyInOnTheFillDownbeat` and `lofiRevealsVaryTheirTransitionStyle` are rewritten for the drop; `ImageTransitionTests` bell tests are untouched. |

### 8.2 Offline clips (`tx-clip.sh --drop`, 60 fps, two fixture pairs, intensity 0.5 and 1.0)

One clip per geometry style (20), each with its heaviest colour layer and each finisher at least once.
`d` is the downbeat frame.

| Gate | Value |
|---|---|
| `cut_frame` | The first frame showing the new picture is `d` exactly. |
| `clean_from_cut` | `vis_b[d] >= 0.95 *` median of `vis_b[d+30 ... d+90]`. |
| `tail` | Largest frame step in `d+1 ... d+12` at most 1.5 times the median step of `d+30 ... d+90`. |
| `old_residue` | `vis_a[d]` no more than 0.05 above its median over `d+30 ... d+90`. |
| `peak_at_cut` | Minimum `vis_a` over the last 3 build frames at most 0.25 (0.45 below intensity 0.4). |
| `build_monotonic` | 5-frame median of `vis_a` never rises by more than 0.05 from 40 % of the build to the cut. |
| `pre_leak` | `vis_b` before the cut at most 0.20 (0.40 for Bleed). |
| `seam_in` | At most 2.5 (unchanged definition). |
| `flash_rate` | At most 3 full-field mean-luma reversals of 0.10 or more in any 1 s. |
| `distinct` | For every pair of styles on the same fixture and seed, SSIM of the frames at `p = 0.9` at most 0.85. |
| Bell regression | Three bell styles rendered with the old and the new shader differ by at most 1/255 per channel. |

Deliverable for the user: one contact sheet per style and a reel of all 20 against a click, kept in
the scratchpad (not committed).

### 8.3 Sync against real audio

1. `scripts/check-lofi.sh ... --wait-lock 3600` with `-LiminalTraceLofi YES` and a fixed
   `-LiminalMusicSeed`, long enough to cross one turnaround. Keep the WAV in the session `share/tx/`
   folder. The trace gives the boundary's sample index.
2. `drop-sync.py` finds the first audio onset at or after the boundary (spectral flux, 1 ms hop), runs
   the fill detector's output for that take into `tx-clip.sh --drop --fill T --hits ...`, muxes the
   60 fps frames with the audio so the clip's `tD` is the boundary sample, and measures the cut frame
   from the frames themselves.

| Gate | Value |
|---|---|
| Cut frame start against the audio onset | Between 17 ms before and 8 ms after. |
| Build start against the first fill onset in the audio | Within 60 ms. |

This checks the timing chain and the clip. It does not measure the display, so the live runs below
carry the real gate.

### 8.4 Live runs (one app instance at a time, under the lock, automation flags only)

| Run | Gate |
|---|---|
| macOS: `-LiminalAutoPlay YES -audio.musicMode lofi -LiminalTestImage <dir> -LiminalMusicSeed <n>`, at least 8 drops | "drop cut presented" between 17 ms before and 8 ms after `tD` for at least 90 % of cuts; none later than 25 ms. No "Slow Mac frame" within 0.5 s of a cut. Screenshot one frame at `tD + 50 ms`: clean new picture. |
| visionOS Simulator: `scripts/perf-run.sh --lofi` | Passes as today (no frame of 100 ms or more, no missed drum or picture change, 8-bar reveal count). New check: no cut whose frame start is more than 1.5 frames after `tD - lead`. |
| visionOS device | Not available to automation. The 28 ms lead and device GPU cost are recorded as unverified. |

### 8.5 GPU (`shader-bench.sh --shader-b NEW --shader REF`, interleaved, 2048 x 2048 MRT stereo)

| Gate | Value |
|---|---|
| Non-transition frames (t = 47, 113, 600, 2000) | New / current at most 1.01. |
| Each drop style at `p = 0.98` with its heaviest colour layer and finisher | At most 1.05 times the classic transition frame (`trans113`). |
| Mean over the 20 drop styles | At most 1.02 times `trans113`. |
| The cut frame | Equal to a non-transition frame within noise (it is one). |

### 8.6 Builds

`xcodebuild -scheme Liminal -destination 'platform=macOS' build`, the visionOS Simulator build, and
`-only-testing:LiminalTests/ImageTransitionTests`, `ImageStoreTests`, `EffectLookTests`,
`ArchiveFootageTests` and the new fill detector suite, all green.

## 9. Risks

| Risk | Handling |
|---|---|
| Fill detection is wrong for some takes | Defaults equal today's build lengths; clamps bound the damage; the local-only test reports coverage. |
| The display lead is a guess on visionOS | Biased early, overridable with `-LiminalDropLead`, flagged unverified. |
| Stage B register pressure slows normal frames | `kDropTx` function-constant variants (section 6). |
| A geometry step in the visionOS shell at the cut is uncomfortable | The shell flattens to 40 % relief by the cut, so the step is small. Check in the Simulator; fall back to a 2-frame relief ramp if it reads as a jolt. |
| The halfway drop is too frequent | Section 4.6. |
| The hard cut reads dry without any after-flash | Decision 3 in section 2 can be reopened with a 2-frame (33 ms) overlay; it would need its own gate. |

## 10. Sources

Research notes and the code map for this plan are in the session scratchpad (`transitions/research-glitch.md`,
`transitions/codemap.md`). The sync tolerances come from secondary summaries of ITU-R BT.1359 and the
audiovisual simultaneity literature; the 20-30 ms figure for percussive transients is approximate.
