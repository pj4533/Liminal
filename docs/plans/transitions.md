# Image transitions: plan

Goal (user): "Right now it sort of does this very intense distortion and then switches the image and
then comes back ... it feels like it's almost like a morph, which I do like. But the problem is that
it's the same every single time. I want you to figure out different ways of doing this sort of similar
transition, where it distorts the image, changes the image, and then when it comes back, it's a
different image ... really awesome ways to make these transitions much better and feel like they flow
better into the existing effects, so it's not like this separate thing."

Outcome: a family of 12 transition styles. Every one follows the same idea (distort, exchange the
pictures inside the distortion, resolve into the new picture), each is built from the effects that are
already running, they are picked without repetition, and they start from and settle back into the live
effects without a jump. Recognisability outside transitions, the 2048 x 2048 render and GPU cost do not
change.

Decisions and their reasons: `docs/decisions/transitions.md`. Status: implemented on both platforms
(round 0); deviations from this design and the measured results are T15-T26 there.

## 1. Tooling added for this work

| Tool | What it does |
|---|---|
| `scripts/shader-bench.sh --sequence --prev-image A --image B --out DIR` | Renders a transition on the app's own timeline with the real shader and uniform code: A alone, the crossfade (previous = A, source = B, linear `transitionProgress`, image age from the crossfade start, vibrance factors blended), then B alone through the fresh-image hold. Simulated at 60 fps with continuous feedback and ghost taps, written at 30 fps, plus `sequence.json` (time, phase, tp, age, uniforms per frame). `--seq-start/-duration/-pre/-post/-fps`, `--intensity`. `--seq-ref a\|b` renders the effect-free reference of the same timeline. `--tx-style/--tx-seed` are accepted and recorded; only `classic` exists until section 7 lands. |
| `scripts/tx-clip.sh --a A --b B --out DIR [--style S --seed N --intensity I --start T --duration D]` | One call: frames, both references, `clip.mp4`, `clip.gif`, `filmstrip.png` (18 labelled frames), `plot.png`, `metrics.csv`, `check.json`. |
| `scripts/tx-check.py score / sheet / plot` | Objective checks of a rendered transition (section 8.2), contact sheet, visibility plot. |

These run offline from the given pictures: they fetch nothing and do not launch the app.

## 2. How the transition works today

End to end, both platforms:

1. `VisualEngine` publishes a new image every 30 s (a drum-grid change in Lo-Fi).
2. macOS: `TimerDrivenCrossfade.transitionTo` sets `previousFrame` to the old image and `currentFrame` to
   the new one at once, and a 30 Hz timer moves `transitionProgress` linearly from 0 to 1 over
   a constant 1.5 s. visionOS: `CGImageTransitionState` in
   `ImmersiveDomeView` does the same from a start date. The duration is a constant on both.
3. In Lo-Fi the drum transport's downbeat decides when the pictures change.
4. `EffectsUniformsComputer.compute` adds a boost `sin(pi * tp)` on top of the live amounts: water
   +0.16 (0.05 / 0.40 at intensity 0 / 1), radial +0.006, crystalline noise +0.020, chromatic x4.
   `EffectLook.fresh()` takes the live amounts to their clear values over the first 1.5 s of the image's
   age, holds until 4.5 s and returns by 11 s.
5. Shader (`shadeEye`): both textures are sampled at the same warped UV (3 chromatic taps each) and mixed
   by one number for the whole frame, `mix(previous, source, easeInOutCubic(tp))`. Ghost taps are
   switched off while `tp > 0.001`. Bloom always samples the source texture.

So there is exactly one shape: one envelope, one duration, one blend rule, three warps boosted in a fixed
ratio.

### 2.1 Measured (2 fixture pairs, default intensity; `tx/current/` in the session scratchpad)

`scripts/tx-clip.sh` on romanesco -> hourglass at t = 113 s (p1) and flytrap -> accordion at t = 600 s
(p2), plus p1 at intensity 0 and 1.

| | p1 | p2 | p1, I = 0 | p1, I = 1 | wanted |
|---|---|---|---|---|---|
| swap_vis (how readable the pictures are while they exchange, 0...1) | 0.29 | 0.16 | 0.48 | 0.12 | <= 0.20 |
| double_exposure (both readable at once) | 0.26 | 0.14 | 0.43 | 0.11 | <= 0.18 |
| seam_in (first transition frame against the 0.25 s before) | 12 x | 24 x | 16 x | 11 x | <= 2.5 x |
| seam_out (first frame after against the 0.25 s after) | 9 x | 9 x | 9 x | 13 x | <= 2.5 x |
| largest frame step (mean luma change per 1/30 s) | 0.043 | 0.088 | 0.044 | 0.051 | <= 0.050 |

What the filmstrips and numbers show:

- The idea works when the warp is strong: at p2 and at intensity 1 the exchange is hidden. At the
  default on a calm moment (p1) and at low intensity it is a double exposure: both pictures are readable
  in the middle third.
- It starts with a pop. In the first frame the new image's bloom is screened over the old picture (bloom
  samples the source texture, which is already the new image), and on a frame with `tp` = 0 the ghost
  taps show the new image too. At p2 the dark flytrap scene turns hazy blue in one frame: a step of
  0.088 against 0.0035 before.
- It ends with a stop. `sin(pi * tp)` changes fastest at both ends, so the picture is still moving at
  full speed in the last frame (step 0.031) and is almost still in the next (0.003, the fresh-image
  hold). This and the pop are why it reads as a separate thing bolted on.
- It is the same every time: same 1.5 s, same water surge, same uniform dissolve.

## 3. Design overview

Three things vary per transition, and one thing is fixed.

- **Envelope E(tp)**: how strongly the style's effects are pushed. Zero value and zero slope at both
  ends, so it grows out of whatever the live effects are doing and hands over to the fresh-image hold.
- **Swap M(tp) and swap mask**: when and in what order pixels change from the old picture to the new.
  The swap happens in a short window around the envelope's peak, and it is ordered by a field (noise,
  luminance, radius, depth, the hue waves ...), not by one number for the whole frame.
- **Drive**: which existing uniforms the envelope pushes, and by how much at each intensity.
- Fixed: the rest of the pipeline. The hue, bloom, feedback and vibrance stages run on the mixed colour
  as today, so the transition is coloured and trailed by the live effects.

A transition is described by a small value, chosen once when it starts:

```swift
struct TransitionSpec { var style: TransitionStyle; var seed: Float; var duration: Float; var flip: Bool }
```

`EffectsUniformsComputer.compute(..., transitionProgress:, transition: TransitionSpec = .classic, ...)`
turns it into uniforms. With `tp` = 0 the output is bit-identical to today.

## 4. Envelopes

`tp` stays linear time, 0...1 over the style's duration. Per style three numbers: peak position `p`,
plateau half-width `h`, and the swap window `[s0, s1]`.

```
E(tp) = smoothstep(0, p - h, tp) * (1 - smoothstep(p + h, 1, tp))     effect envelope, C1 at both ends
M(tp) = smoothstep(s0, s1, tp)                                        swap progress
```

- Rise at least 0.5 s, fall at least 0.6 s at any duration (nothing fast enough to flash).
- The swap window lies inside the plateau (`p - h <= s0 < s1 <= p + h`), so pixels only change picture
  while the distortion is at its highest. Today the blend runs over the whole 1.5 s.
- Asymmetric shapes are part of the variety: a fast surge with a long resolve (`p` = 0.35) or a slow
  build with a quick snap back (`p` = 0.6).
- Music may swell E by at most +12 % through the slow onset follower (`pulseMotion`, 180 ms attack,
  900 ms release). M never depends on music, so the swap cannot move backwards.

Handover to the live effects:

- In: boosts are added to the live amounts (as today). While E rises over the first third, `fresh()`
  takes the live part down, so one continuous motion goes from "whatever was happening" to "the style".
- Out: `EffectLook` gets `transitionDuration` (default 1.5). The fresh windows become: fade over
  `min(1.5, 0.4 D)`, hold until `D + 3`, back by `D + 9.5`. For D = 1.5 these are today's 1.5 / 4.5 / 11,
  so the golden parity test and the judged look are unchanged. A 4 s transition still gets 3 s of clear
  picture after it.
- The fall of E is the resolve: the last frame of the transition has E = 0 and slope 0, and the first
  frame after it has the same uniforms.

## 5. Swap masks (shader)

Today: `color = mix(prev, source, eased)`. New: a per-pixel, per-channel weight.

```metal
half3 w = smoothstep(m - s, m + s, th + half3(c, 0.0h, -c));   // th = mix(-s, 1 + s, txMix)
half3 color = mix(prevColor.rgb, sourceColor.rgb, w);
```

`m` is the mask field in 0...1 (which pixels go first), `s` the edge softness, `c` a channel stagger
(only the Prism style; 0 otherwise). `m` comes from one `switch` on the style, taken only while a
transition is active. Every field is either already computed or one or two cheap operations:

| Mask | Field | Extra cost |
|---|---|---|
| uniform | 0.5 with large `s` (today's dissolve) | none |
| flow | the turbulence displacement that `distortedUV` already computed, projected on a seeded direction | one dot |
| crystal | `noiseX` of the crystalline warp (already computed when it is on) | none |
| luminance | luma of the old or of the new picture (both already sampled) | one dot |
| radial | distance from a seeded centre, in or out | one length |
| petals | angle inside the kaleidoscope wedge (already computed by the fold) | none |
| rainbow | the hue-wave field `spatialOffset` (moved before the blend; it depends only on UV and time) | none |
| depth | `depthTexture` (far first or near first); luminance when no depth map is bound | one r8 sample |
| drip | vertical position plus the flow field (columns go at different times) | one add |

Softness and stagger come in the uniform block. The mask edge is always hidden two ways: it lies inside
the warped, chromatically split, trailed picture, and its softness is at least 0.08.

Two fixes that every style needs (and that remove the measured pops):

- Bloom and ghost taps sample the picture the pixel is currently showing (`w.g < 0.5 ? previous :
  source`, explicit LOD 0; the textures have no mips). Bloom no longer flashes the new image over the old
  one at `tp` = 0, and ghost taps no longer have to be switched off and on. Same number of texture samples.
- The envelope is C1 (section 4).

## 6. The styles

Amounts are the peak of the additive boost at intensity 0 / 0.5 / 1 (piecewise-linear through the three
anchors, like every `EffectLook` constant), multiplied by E. "Water" = `distortionAmplitude`, "radial" =
`logSphereAmount`, "noise" = `fractalNoiseAmount`. Durations are in seconds before the scaling of
section 7.2. Shader cost is what the style adds to a transition frame; a frame outside a transition pays
nothing.

| # | Name | Family | Look | Drives (peak boost) | Swap mask, softness | p, window | Duration | Shader cost |
|---|---|---|---|---|---|---|---|---|
| 1 | Tide | flow | Today's water surge, kept as the familiar one, with the pops removed and the dissolve confined to the peak | water 0.05 / 0.16 / 0.40, radial 0 / 0.006 / 0.020, noise 0.004 / 0.020 / 0.060, chromatic x4 | uniform, 0.5 | 0.50, 0.32...0.68 | 1.6...2.2 | none |
| 2 | Undertow | flow | The new picture pours in along the crests of the water and the old one is carried off the other way | water 0.04 / 0.13 / 0.30, feedback mix +0.10 / 0.25 / 0.35, feedback warp x2 | flow (seeded direction), 0.18 | 0.45, 0.30...0.70 | 2.2...3.2 | one dot |
| 3 | Prism | colour | The picture splits into red, green and blue ghosts that drift apart; each one reassembles as the other picture at a different moment | chromatic +0.03 / 0.06 / 0.10, hue blend +0.15, water 0.02 / 0.06 / 0.12 | uniform 0.30 with channel stagger 0.10 / 0.18 / 0.25 (order R-G-B or B-G-R by seed) | 0.50, 0.25...0.75 | 2.0...3.0 | none |
| 4 | Rainbow front | colour | Rainbow bands thicken and sweep the frame; the new picture arrives band by band behind them, while the hue turns once around | hue waves up to 0.30 / 0.45 / 0.60 and hue blend to 0.5 / 0.8 / 0.9 (above the usual rainbow cap, during the plateau only), hue base +1 full turn over the transition, water 0.02 / 0.05 / 0.10 | rainbow, 0.12 | 0.50, 0.30...0.72 | 2.4...3.4 | none (reorder) |
| 5 | Kaleidoscope | geometric | The picture folds into a mandala of 6 or 8 mirrored wedges, the wedges turn into the new picture like petals opening, then it unfolds | fold amount E (UV mixed toward its mirror-folded position), radial 0.004 / 0.012 / 0.024, chromatic x2 | petals, 0.15 | 0.50, 0.38...0.62 | 2.6...3.6 | 1 atan2, 1 sincos |
| 6 | Whirlpool | geometric | The picture winds up around a seeded point like water down a drain, the centre goes first, and it unwinds as the new picture | swirl angle 0.6 / 1.6 / 3.2 rad at the centre falling to 0 at the edge (direction by seed), water 0.03 / 0.08 / 0.18, feedback mix +0.08 | radial outward from the swirl centre, 0.20 | 0.42, 0.30...0.60 | 2.4...3.4 | 1 sincos |
| 7 | Dive | geometric | The camera dives into the picture; the radial effect and the trails make a tunnel, and it comes out the far side in the new picture and eases back | Ken Burns scale x (1 + 0.5 / 1.2 / 2.2 E), radial 0.006 / 0.016 / 0.030, feedback mix +0.15 / 0.30 / 0.40, chromatic x3 | radial outward from the frame centre, 0.25 | 0.50, 0.38...0.64 | 2.2...3.0 | one length |
| 8 | Afterimage | temporal | The picture smears into its own trails like wet paint; the source changes underneath and the trails slowly become the new picture | feedback mix to 0.80 / 0.88 / 0.93, feedback warp x3, water 0.02 / 0.05 / 0.10, bloom +0.10 | uniform, 0.35, narrow window (the trails do the dissolving) | 0.40, 0.34...0.50 | 2.8...4.0 | none |
| 9 | Echo | temporal | Faint copies of the new picture drift in from the ghost-tap directions over the old one, the base gives way, and the copies converge onto it | ghost tap alpha x (1 + 0.6 / 1.4 / 2.2 E), ghost travel x (1 + 1.5 E), a ghost burst at the start, water 0.02 / 0.05 / 0.10 | luminance of the new picture (its highlights arrive first), 0.22; taps sample the new picture from the start | 0.50, 0.40...0.70 | 2.6...3.6 | none (the tap loop of a normal frame) |
| 10 | Depthwash | flow | The background becomes the new place first, then the change comes forward through the subject (or the reverse by seed); made for the Vision Pro, where it reads as depth | fractal hue +0.10 / 0.25 / 0.35, water 0.02 / 0.06 / 0.12, stereo offset x (1 + 0.8 E) where the renderer allows | depth, 0.15; luminance without a depth map | 0.50, 0.25...0.75 | 3.0...4.5 | one r8 sample |
| 11 | Embers | colour | Highlights flare and bleed; the new picture burns through the bright parts first and its shadows fill in last | bloom amount +0.15 / 0.35 / 0.50 and radius x2, contrast +0.15, noise 0.004 / 0.012 / 0.025 | luminance of the old picture, 0.20 | 0.45, 0.30...0.66 | 2.4...3.4 | one dot |
| 12 | Shatter | geometric | The crystalline noise breaks the picture into facets and the facets flip to the new picture one by one | noise 0.02 / 0.05 / 0.10, chromatic x3, water 0.02 / 0.05 / 0.10 | crystal, 0.08 | 0.50, 0.34...0.66 | 1.8...2.6 | none |

Notes per style:

- **Variation inside a style.** The seed sets direction, centre, wedge count, channel order and
  near-first or far-first, and `flip` reverses the mask order (edges in, darks first). Two Whirlpools in
  one session differ in centre and direction.
- **Budget.** Boosts are added after the strain budget, as today: a transition is the one place where
  the picture is allowed to be unreadable. The peak amounts at the default are chosen to reach the
  hidden-swap gate on a calm moment (the p1 case, where today's boost does not).
- **Rainbow front** returns the hue base to where it was by going once around (hue is periodic), so
  there is no step at the end. The music's hue phase is untouched.
- **Afterimage** depends on frame rate (feedback is per frame). The mix is specified at 60 fps and
  converted with `mix^(60 / fps)`; both renderers know their frame interval.
- **Echo** asks for a ghost burst at the start (`GhostTapManager.requestBurst`, already used for music
  scene changes) so there are taps to show.
- **Depthwash** on macOS has no depth texture bound, so it is not offered there (section 7.1). The depth
  map on visionOS belongs to whichever image the generator finished last; either works as a mask.
- **Kaleidoscope, Whirlpool, Dive** move UVs inside `distortedUV`, before the stereo split, so both eyes
  share them and the cost is paid once per pixel.

## 7. Selection, duration and music

### 7.1 Selection policy (`TransitionDirector`)

A small value type with a seeded generator and the history of the last picks. `next(time:, look:, music:,
hasDepth:)` is called once when a crossfade starts.

1. Eligible = all styles, minus the last 4 used (no style repeats within 5 transitions; with 12 styles
   and a 30 s interval a style returns after 2.5 minutes at the earliest), minus any style of the same
   family as the previous one (no two geometric ones in a row), minus Depthwash without a depth map.
2. Weight = base weight x fit to the moment:
   - clarity drive at the start (`look.drive(time:)`): wild stretch favours Kaleidoscope, Whirlpool, Dive,
     Shatter, Prism (x2); clear stretch favours Tide, Undertow, Depthwash, Embers, Afterimage (x2). The
     transition continues the mood the effects are already in.
   - intensity setting: below 0.25 only the soft styles are offered (Tide, Undertow, Afterimage,
     Depthwash, Embers, Rainbow front), with their I = 0 amounts; Kaleidoscope and Shatter enter at 0.25,
     and their weight rises to x1.5 at 1.
   - music energy (when sync is on): high energy favours the short styles, low energy the long ones.
   - base weights: 1 each, Tide 0.7 (the one the user has already seen a lot).
3. Seed and flip from the generator. The generator is seeded per session; DEBUG launch options
   `-LiminalTransitionStyle NAME` and `-LiminalTransitionSeed N` pin them for verification, and the bench
   takes `--tx-style / --tx-seed`.

### 7.2 Duration

`duration = lerp(range, seed2) * (1.15 - 0.30 * energy)`, limited to 1.5...4.5 s and to at most 20 % of
the 30 s hold (at most 6 s). Longer when the music is calm. The platform's
crossfade timer uses `spec.duration` instead of the constant.

### 7.3 Music coupling

- The envelope swells with the slow onset follower by at most +12 % (section 4). No per-onset flashes:
  the fast follower is not used, bloom and brightness boosts are envelope-only.

## 8. Evaluation

### 8.1 Renders

For every style: `scripts/tx-clip.sh` on 3 fixture pairs x 2 seeds at the default intensity, and one pair
at intensity 0.25 and 1.0. Pairs cover a calm start (t = 113 s, drive near 0), a wild start (t = 600 s)
and a dark-to-bright change (flytrap -> accordion). Each gives a clip, a GIF, a filmstrip and scores.

### 8.2 Objective checks (`scripts/tx-check.py score --gate`)

Frames are compared on luma at 384 x 256 with the effect-free render of A and of B at the same instant.
`vis_a` / `vis_b` are edge-map correlations rescaled so that 0 = as similar as the two clean pictures are
to each other and 1 = identical.

| Gate | Meaning | Limit | Today |
|---|---|---|---|
| swap_vis | max(vis_a, vis_b) around the frame where B overtakes A: the exchange is hidden | <= 0.20 (<= 0.45 below intensity 0.4) | 0.16...0.29 (0.48 at I = 0) |
| double_exposure | highest min(vis_a, vis_b): never two readable pictures at once | <= 0.18 (<= 0.40 below 0.4) | 0.14...0.26 (0.43) |
| pop | largest frame step over the median step of the 0.25 s around it: no hard cut, no layer switching on | <= 2.5 | 2.9...6.8 |
| seam_in, seam_out | step at the first transition frame / first frame after, against the 0.25 s before / after | <= 2.5 | 9...24 |
| step_max | largest mean luma change per 1/30 s | <= 0.050 | 0.043...0.088 |
| strobe | luma reversals over 0.012 per second inside the transition | <= 3 | 0...0.7 |
| resolve | vis_b at the end of the clip (3 s after the transition): the new picture is back | >= 0.55 (>= 0.70 below 0.4) | 0.69...0.92 |

Distinctness (styles must not look alike): for the same pair and seed, the mid-transition frames of any
two styles must differ by a mean absolute RGB difference of at least 0.06, and the vis curves are plotted
side by side. Reported, not a hard gate.

Unchanged outside transitions:

- `scripts/shader-bench.sh --compare` of the judge-set frames (`fx-judge-set.py --mode app`, all with
  `tp` = 0) before and after: maximum difference at most 1 of 255 (the hue-wave reorder may move rounding).
- The objective gates of `fx-judge-set.py` at 0.25 / 0.5 / 1.0 re-run and still pass.
- `EffectLookTests.goldenParityWithModel` passes; `fx_model.py` gets the new envelope so its rows with
  `tp` > 0 are regenerated, the rows with `tp` = 0 must not move.

GPU: `shader-bench.sh --shader-b` interleaved A/B against the shader on main. Non-transition scenarios
B/A within noise (<= 1.01). Each style as a scenario at `tp` = its peak: at most 1.05 x today's
`trans113`. The bench's `--scenarios` gets `tx_style` and `tx_seed` per scenario.

### 8.3 Judge protocol

Blind, with clips instead of frames (a transition is motion).

- Set: every style x 2 pairs x 1 seed at the default, plus today's transition as a hidden control twice,
  as GIFs with neutral names in shuffled order; a private key maps names to styles.
- Three judges who have not seen the plan, each alone. Per clip:
  1. Could you point at the moment the picture changed? (no / roughly / exactly) - hidden swap
  2. Any jump, flash or flicker? (none / slight / clear) - seams and strobing
  3. Does it feel like part of the picture's motion or like a separate effect laid on top? (1...5) - flow
  4. How striking is it? (1...5)
  5. One or two words for what it looked like.
- Then all clips of one pair side by side: sort them into groups that look the same. A style that judges
  put in one group with another style is not distinct enough.
- Pass: every style has "exactly" from at most one judge, no "clear" on question 2, flow mean >= 3.5 and
  above the control, striking mean >= 3.5, and at least 9 of the 12 styles land in groups of their own.
  Styles that fail are retuned or dropped; the family ships with at least 8.
- Last, in the visionOS 27.2 Simulator and on macOS with the debug flags: each style once, for seams on
  the real renderers, and a 10 minute run for the selection policy (log line per transition: style, seed,
  duration; check no repeat within 5 and no same family twice in a row).

## 9. Implementation

Ownership: the effect math is this workstream's. Presentation files of the visionOS spatial rebuild are
touched only where listed under "plumbing".

### 9.1 Uniforms

Six floats appended to `EffectsUniforms` after `blackPoint` (Swift and Metal, defaults 0 = no transition;
27 -> 33 floats, 132 bytes):

| Field | Meaning |
|---|---|
| `txStyle` | style index as a float (0 = uniform dissolve) |
| `txMix` | swap progress M, 0...1 |
| `txEnv` | envelope E, 0...1, for the shader-side moves (fold, swirl) and tap alpha |
| `txSeed` | 0...1, direction / centre / wedge count |
| `txSoft` | mask softness, negative = reversed order |
| `txStagger` | channel stagger of the Prism style |

`transitionProgress` stays (linear time; "a transition is active"). Everything else a style does goes
through existing uniforms: water, radial, noise, chromatic, hue waves and blend, hue base, bloom, feedback
mix and warp, Ken Burns scale, ghost travel.

### 9.2 Files

| File | Change |
|---|---|
| `Liminal/Visual/ImageTransition.swift` (new) | `TransitionStyle`, `TransitionSpec`, per-style table (p, h, window, duration range, boosts as intensity anchors), `envelope`, `swap`, `TransitionDirector` |
| `Liminal/Visual/EffectsUniformsComputer.swift` | `transition:` parameter; boosts from the style table times E; fills the six uniforms |
| `Liminal/Visual/EffectLook.swift` | `transitionDuration`; fresh windows anchored to it; boost constants move to the style table |
| `Liminal/EffectsUniforms.swift`, `Liminal/Shaders/EffectsRenderer.metal` | uniform block; mask switch and per-channel mix in `shadeEye`; fold and swirl in `distortedUV` inside one `txEnv > 0` branch; `distortedUV` also returns the flow and crystal fields; bloom and ghost taps sample the showing picture; tap gate removed |
| `Liminal/Visual/TimerDrivenCrossfade.swift`, `Liminal/ContentView.swift` | macOS: ask the director for a spec at `startCrossfade`, use `spec.duration`, pass the spec to `compute` |
| `Liminal/Visual/VisualEngine.swift` | owns the `TransitionDirector` (one per session) |
| plumbing: `Liminal/visionOS/ImmersiveDomeView.swift` | `CGImageTransitionState` stores a `TransitionSpec` and uses its duration (about 6 lines); `compute` gets `transition:`; the music post uses the swap-centred duration. If the spatial rebuild has replaced this file, the same three hooks go wherever `transitionProgress` is produced |
| plumbing: `Liminal/visionOS/OffscreenEffectsRenderer.swift`, `EffectsMetalView.swift` | nothing for the uniforms (the struct is copied whole); a ghost burst request for Echo; optional stereo-offset factor for Depthwash |
| `scripts/shader-bench.swift`, `scripts/fx_model.py`, `LiminalTests` | `--tx-style / --tx-seed` reach `compute`; model envelope; tests: envelope ends (value and slope 0), swap inside the plateau, `tp` = 0 uniforms identical to main for every style, director never repeats within 5 and never repeats a family, durations inside limits, same seed gives the same sequence |

### 9.3 Order of work

1. Seams first, no new look: C1 envelope, bloom and taps from the showing picture, `transitionDuration`
   in `EffectLook`. Gate: seam_in, seam_out, pop and step_max pass for Tide; judge frames identical.
2. Uniform block, mask switch, `TransitionSpec` through `compute` and the bench. Styles that need no new
   UV code: Tide, Undertow, Prism, Rainbow front, Afterimage, Embers, Shatter, Dive. Tune each to the
   gates on the 3 pairs.
3. UV styles and the rest: Kaleidoscope, Whirlpool, Echo, Depthwash. GPU A/B.
4. Director, variable duration, both platforms, music timing, debug flags, tests.
5. Clips for all styles, objective gates, blind judges, retune or drop, simulator and macOS verification,
   unchanged-outside-transitions checks, decisions written up.

### 9.4 Risks

| Risk | Handling |
|---|---|
| The hue-wave reorder or the wider uniform struct changes non-transition frames | parity compare of the judge frames (8.2); the reorder is dropped if it costs more than 1 of 255 |
| A mask edge is visible as a line | softness floor 0.08, and the edge always lies in the boosted warp; the "exactly" answers of judge question 1 catch it |
| Depth map belongs to the other image, or arrives mid-transition | the mask only needs some depth-like order; a map arriving mid-transition is a step in the mask, so Depthwash is offered only when a map is already bound and the upload during a transition is deferred to its end |
| Long transitions eat the clear time of short image intervals | 20 % limit (7.2), and the hold is anchored to the end of the transition |
| Brightness flashes (bloom, Embers) | envelope-only, rise >= 0.5 s, strobe and step_max gates |
| Merge with the spatial rebuild | effect math and uniforms are self-contained; the visionOS hook is three call sites |
| Dive magnifies the picture up to 3.2 x at intensity 1 | only for the plateau, under radial and trails; if judges see blur, the scale anchor comes down |
