# Image transitions: decisions

Decision log for the transitions workstream. Plan with all numbers: `docs/plans/transitions.md`.
Request: the transition between images (distort, switch, come back) is liked but is the same every time;
make a family of them that flows out of and back into the live effects.

Status: implemented on both platforms (T15-T26), round 0 judged blind, round 1 tuned and rendered
(T27-T32; Echo and Embers replaced by Ripple and Melt). Round 1 judging and the simulator / macOS run
of plan 8.3 are next.

## Tooling and diagnosis

### T1. Render transitions offline on the app's own timeline
- What: `scripts/shader-bench.sh --sequence` renders image A -> image B frame by frame with the real
  shader and `EffectsUniformsComputer`: A alone, the crossfade, B alone through the fresh-image hold,
  simulated at 60 fps with continuous feedback and ghost taps. `scripts/tx-clip.sh` makes the clip, GIF,
  filmstrip and scores.
- Why: a transition is motion over 1.5 s and happens once per 30 s in the simulator on a random image
  pair. Offline it is deterministic, repeatable per style and seed, and costs no image generation.
- The image age, vibrance blend and texture bindings follow what both renderers do, so start and end
  seams are in the clip.

### T2. Score visibility of each picture against its own effect-free render
- What: `scripts/tx-check.py` compares every frame with the clean render of A and of B at the same
  instant (edge-map correlation on luma, the `edge` metric of the effects-balance work), rescaled so that
  0 = as similar as the two clean pictures are to each other.
- Why rescaled: two unrelated photos with a centred subject correlate at 0.25 to 0.37 raw, which would
  hide the difference between "gone" and "faintly there".
- Why edge and not HOG: HOG's range is too compressed to separate two pictures; it is still written to the CSV.

### T3. Baseline of the shipped transition
Romanesco -> hourglass at t = 113 s (p1), flytrap -> accordion at t = 600 s (p2), default intensity, and
p1 at intensity 0 and 1:

| | p1 | p2 | p1, I = 0 | p1, I = 1 |
|---|---|---|---|---|
| swap_vis | 0.29 | 0.16 | 0.48 | 0.12 |
| double_exposure | 0.26 | 0.14 | 0.43 | 0.11 |
| seam_in | 12 x | 24 x | 16 x | 11 x |
| seam_out | 9 x | 9 x | 9 x | 13 x |
| step_max | 0.043 | 0.088 | 0.044 | 0.051 |

- The hidden swap works only when the warp is strong; on a calm moment at the default and at low
  intensity it is a double exposure.
- Start pop: bloom samples the source texture, which is the new image from the first frame, so the new
  image's glow is screened over the old picture in one frame (and the ghost taps show it too on a frame
  with `tp` = 0).
- End stop: `sin(pi * tp)` has its steepest slope at both ends; motion goes from 0.031 per frame to 0.003
  in one frame.
- These two seams are the measurable part of "feels like a separate thing".

## Design

### T4. Three things vary (envelope, swap order, drive); the pipeline after the blend stays
- Why: the request is variety inside one idea. Keeping hue, bloom, feedback and vibrance running on the
  mixed colour means every style is coloured and trailed by the live effects.
- Rejected: separate transition passes or a second render target (GPU cost, and it would be a separate
  thing by construction).

### T5. Envelope with zero value and zero slope at both ends; swap confined to the plateau
- What: `E = smoothstep(0, p - h, tp) * (1 - smoothstep(p + h, 1, tp))`, `M = smoothstep(s0, s1, tp)`
  with the swap window inside the plateau.
- Why: removes the end stop (T3), and pixels change picture only at peak distortion. Today the dissolve
  runs over the whole duration, which is where the double exposure comes from.

### T6. Per-pixel, per-channel swap weight from fields the shader already has
- What: `w = smoothstep(m - s, m + s, th + stagger)`, `m` from one switch on the style: uniform, flow
  (turbulence displacement), crystal noise, luminance, radius, kaleidoscope wedge angle, hue-wave field,
  depth, drip.
- Why: ordering the swap by a field is what turns a dissolve into a morph, and every field is free or
  one operation. No extra pass, no extra texture except one r8 depth sample in one style.
- Rejected: optical-flow or feature morphing between the two images (needs analysis per pair and more
  passes; the warp already hides the exchange).

### T7. Bloom and ghost taps sample the picture the pixel is showing
- Why: removes the start pop (T3) and the need to switch ghost taps off during a transition and back on
  after it (the second half of seam_out). Same number of samples. Textures have no mips, so an explicit
  LOD 0 sample inside the branch is exact.

### T8. Twelve styles in four families
Tide, Undertow, Depthwash (flow); Prism, Rainbow front, Embers (colour); Kaleidoscope, Whirlpool, Dive,
Shatter (geometric); Afterimage, Echo (temporal). Table in plan section 6.
- Why these: each takes one effect the user already sees (water, chromatic fringing, hue waves, bloom,
  radial, crystalline noise, feedback trails, ghost taps, depth) and makes it the carrier of the swap, so
  a transition looks like the live effects surging, not like a new effect.
- Tide is today's transition with the seams fixed, kept because the user likes it.
- Only three styles add UV code (Kaleidoscope: atan2 + sincos; Whirlpool: sincos; Dive: none, it is the
  Ken Burns scale). All of it sits in one branch that is skipped outside transitions.
- At least 8 must survive judging; more than 8 are designed so that weak ones can be dropped.

### T9. Six appended uniforms, everything else through existing ones
- What: `txStyle, txMix, txEnv, txSeed, txSoft, txStagger` after `blackPoint`; defaults 0.
- Why appended: the Swift and Metal structs must match exactly and the renderers copy the struct whole,
  so no renderer code changes. `transitionProgress` keeps its meaning.

### T10. `TransitionSpec` chosen once per crossfade by a `TransitionDirector`
- What: no style within the last 4, no same family twice in a row, weights from the clarity drive, the
  intensity setting, music energy and whether a depth map exists; seed and flip vary direction, centre,
  order. Seeded per session; debug flags pin style and seed.
- Why weights from the live state: a wild stretch gets a geometric transition and a clear stretch a soft
  one, so the transition continues the mood (the "flows into the existing effects" part of the request).
- Why a director object and not a pure function of the image counter: the weights need the effect time
  and the history. It lives in `VisualEngine` so both platforms share one.

### T11. Durations 1.5 to 4.5 s per style, at most 20 % of the image interval
- Why: duration is the cheapest variety there is, and slow styles (Depthwash, Afterimage) need the room.
  The limit protects short intervals.
- `EffectLook.transitionDuration` anchors the fresh-image hold to the end of the transition (fade
  `min(1.5, 0.4 D)`, hold to `D + 3`, back by `D + 9.5`). For D = 1.5 this is today's 1.5 / 4.5 / 11, so
  the judged look and the golden test do not move.

### T12. Intensity: amounts through the same three anchors, and the style set narrows at the low end
- Why: "subtler at low, wilder at high". Below 0.25 only soft styles are offered; the swap gates are
  relaxed there (a subtle transition may show more of both pictures).

### T13. Music: chord change on the swap, slow swell only, no flashes
- What: the duration posted to the conductor is twice the swap-centre time, so its existing "chord at
  half the duration" lands on the exchange for every style. The slow onset follower may swell the
  envelope by at most 12 %. The swap progress never depends on music.
- Why: coupling without strobing; nothing in the conductor changes.
- Deferred: delaying an image change to meet a music scene change (optional, last).

### T14. Acceptance: objective gates per clip, then blind judges on clips
- Gates (plan 8.2): swap_vis, double_exposure, pop, seam_in, seam_out, step_max, strobe, resolve, with
  limits set from the baseline (T3): today's transition fails the seam and pop gates everywhere and the
  swap gates on the calm pair.
- Outside transitions: judge-set frames compared before and after (at most 1 of 255), the objective gates
  of `fx-judge-set.py` re-run, GPU A/B within noise for non-transition scenarios.
- Judges watch GIFs with neutral names, today's transition included as a hidden control, and answer:
  could you see the moment of the change, any jump or flicker, part of the motion or laid on top,
  how striking; then sort the clips of one pair into look-alike groups (distinctness).

## Implementation (round 0)

Code: `Liminal/Visual/ImageTransition.swift` (styles, spec, envelope, swap, boosts, director),
`EffectsUniformsComputer.compute(transition:)`, `EffectLook.transitionDuration`, six uniforms appended
to `EffectsUniforms` (`txStyle, txMix, txEnv, txSeed, txSoft, txAmount`), shader stage A (UV moves and
swap fields) and `swapWeight` in stage B. Tests: `LiminalTests/ImageTransitionTests.swift`.

### T15. `classic` stays as style 0 and is the default of `compute`
- What: the pre-family crossfade (sin boost, whole-frame eased dissolve over 1.5 s) as
  `TransitionStyle.classic`. The director never picks it.
- Why: the golden test row with `tp` = 0.5 and every caller that passes no spec keep their exact
  output, and the judge sets get today's transition as a hidden control from the same code.

### T16. Swap progress is linear inside the window, not a smoothstep
- What: `M = clamp((tp - s0) / (s1 - s0))`. The mask's own smoothstep makes each pixel's change C1.
- Why: with a smoothstep sweep the first Tide render exchanged the whole calm pair in 0.15 s (step
  0.052, pop 8.4); the linear sweep spreads it over the window (pop 2.9).

### T17. The envelope plateau is the swap window
- What: `E = smoothstep(0, s0, tp) * (1 - smoothstep(s1, 1, tp))`: the plan's `p` and `h` collapse to
  the window, so the pixels change picture only while the distortion is at full strength.

### T18. Fresh hold: fade over max(1.5, 0.4 D), not min
- The plan's `min(1.5, 0.4 D)` gives 0.6 s at D = 1.5, contradicting its own "today's 1.5 / 4.5 / 11";
  max keeps the judged timings at 1.5 s and lengthens the fade for long transitions. Hold to D + 3,
  back by D + 9.5, both still scaled for short image intervals (and never before the transition ends).

### T19. Mask fields are computed in stage A, one float crosses into stage B
- What: Tide, Undertow, Prism (flow), Shatter (crystal), Rainbow (the strongest hue-wave terms),
  Dive (radius), Depthwash (one depth sample), Kaleidoscope (petal), Whirlpool (radius) set
  `WarpOut.field` inside a `transitionProgress > 0` branch of `distortedUV`; Echo and Embers finish it
  with luma in stage B. `swapWeight` is a small half-precision function.
- Why: GPU A/B. Carrying the flow vector and noise field into stage B, sampling depth there and
  moving the hue waves before the blend each cost about 1 % on frames without a transition, even
  behind a uniform branch (register pressure counts against every frame). Depth is now sampled once
  for both eyes.
- The hue waves stay where they were, so non-transition frames are bit-identical to main
  (max difference 0 of 255 over 22 frames at intensity 0.25 / 0.5 / 1).

### T20. The new picture is sampled only inside the transition branch
- Outside a transition `previousTexture` is the source (both renderers' fallback) and `w` = 0, so
  the three source samples moved into the branch. On a `tp` = 0 start frame (macOS) the old picture
  is shown, as before.

### T21. Bloom and taps use one texture handle chosen per pixel; Echo lives in the same tap loop
- What: `shownTexture = showNew ? source : previous` for bloom and taps. Echo fades its taps out,
  switches them to the new picture at zero alpha (E = 0.15), then brings them back up to
  1 + `txAmount` times stronger.
- Why: a second tap loop for Echo (old-to-new mix per tap) cost about 1.5 % on every frame; a
  duplicated loop with a static handle for normal frames cost more, not less (1.03).

### T22. Luma and depth orders are spread by the flow term
- What: Embers, Echo: `0.55 (1 - sqrt(luma)) + 0.45 flow`; Depthwash: `0.7 depth + 0.3 flow`.
- Why: on the dark flytrap (p2) nearly all luma was near 0, so Embers swapped the whole frame in one
  frame (step 0.115, pop 11.6); a flat background did the same to Depthwash (step 0.080). After:
  0.054 / 3.9 and 0.040 / 3.0.

### T23. Prism and Tide get a loose flow order too, and wider windows
- Whole-frame swaps (Prism 0.5 everywhere, Tide 0.5 +- 0.2) popped (pop 7.0 / 8.4). Flow +-0.35 / +-0.4
  and windows 0.26-0.76 / 0.28-0.72 bring them to 2.3-2.9.

### T24. Echo burst, Depthwash stereo boost, Afterimage fps conversion and the depth-upload deferral are not built
- Echo: the normal taps (delay 0.5 gives several) are enough once their gain rises with E; a burst
  request needs renderer plumbing in the file the spatial workstream rebuilds.
- Depthwash: B's depth map is generated about 31 ms after B arrives, long before the swap window
  (>= 0.78 s in), so the mask uses B's map without deferring the upload. Stereo boost left out.
- Afterimage: both renderers run at 60 fps, where its feedback mix is specified.

### T25. Measured, round 0 (default intensity, seed 0; `tx/round0` in the session scratchpad)
| | p1 calm (romanesco -> hourglass, t = 113) | p2 (flytrap -> accordion, t = 600) |
|---|---|---|
| seam_in (gate <= 2.5) | 0.98 every style (control 11.7) | 0.95 every style (control 23.5) |
| seam_out | 1.0-2.8; Tide 2.8 the only one above 2.5 (control 9.2) | 1.0-2.6 (control 9.3) |
| step_max (<= 0.050) | 0.016-0.051; Kaleidoscope 0.063 | 0.021-0.058; Kaleidoscope 0.058, Embers 0.054 |
| swap_vis / double exposure | Afterimage, Dive, Kaleidoscope, Shatter, Undertow, Whirlpool pass; Tide 0.23 / 0.16; Depthwash, Prism, Rainbow, Embers, Echo 0.24-0.34 / 0.21-0.30 (control 0.29 / 0.26) | all but Echo and Prism pass (control 0.16 / 0.14) |
| resolve (>= 0.55) | 0.74 every style | 0.68-0.71 |
- The seams that made the old transition feel bolted on are gone in every style. The calm pair is still
  a partial double exposure for the colour and temporal styles: their carriers (hue, bloom, taps) do
  not hide edges the way the warps do. Next round: judges first, then more water for those five if the
  judges see the swap.
- Effects-balance gates (`fx-judge-set.py --mode app`, 180 frames): PASS at 0.25 / 0.5 / 1.0
  (hog loss mean 0.065 / 0.091 / 0.122).

### T26. GPU (shader-bench interleaved A/B against main's shader, 2048^2 MRT stereo)
- Frames without a transition: B/A 1.008-1.019 over five runs (mean about 1.015); A/A of main against
  itself 0.990-0.998 in the same session. So about +1.5 %, just over the 1.01 target, with another
  workstream's simulator sharing the GPU. Main's three source samples per eye are gone (T20); what is
  left is the per-pixel texture handle for bloom and taps (T21) and the mask call's registers.
- Transition frames: each style is 1.02-1.09 x the new classic transition frame (gate 1.05: Dive,
  Echo, Embers, Kaleidoscope, Rainbow and Whirlpool are 1.05-1.09). Against main's transition frame
  they are 1.12-1.22 x: main switched the ghost taps off during a transition, and taps now run through
  it (T7). Worth a check on device: a transition lasts 2-4 s of every image interval.

## Tuning round 1

### T27. Round 0 blind scores per style
Two blind judges, 26 clips (each style on both pairs, today's transition twice as the hidden control),
1-5 per axis, mean of the 4 ratings per style (d = distinct from the others, s = smooth, h = swap
hidden, f = flows into the effects, a = awesome):

| style | d | s | h | f | a | judges' words | round 1 |
|---|---|---|---|---|---|---|---|
| classic (control) | 2.75 | 4.00 | 3.25 | 3.50 | 3.00 | "clearly a dissolve, bland" | unchanged, never picked |
| Tide | 3.00 | 3.75 | 3.75 | 3.75 | 3.75 | "sheared liquid smear, similar to others", "oil slick" | unchanged (today's look, liked by the user) |
| Undertow | 3.00 | 3.75 | 4.00 | 3.75 | 3.50 | "near-duplicate of Tide" | reworked (T28) |
| Prism | 2.50 | 4.00 | 3.75 | 3.75 | 3.00 | "fringed liquid warp, like 03/09", "crossfade visible" | reworked (T28) |
| Rainbow front | 3.50 | 3.75 | 4.00 | 4.25 | 4.25 | "grows out of and settles into the trippy look" | unchanged |
| Kaleidoscope | 4.75 | 3.50 | 4.50 | 3.50 | 4.75 | "very distinct and striking", "frame jumps between mirror states" | slower release (T29) |
| Whirlpool | 3.25 | 4.00 | 4.00 | 3.50 | 3.75 | "swap totally hidden in the vortex" (its two clips judged alike) | unchanged |
| Dive | 4.00 | 3.75 | 2.50 | 3.50 | 3.25 | "ghosted double image of both photos at the midpoint" | retuned (T29) |
| Afterimage | 3.25 | 4.00 | 4.25 | 3.25 | 3.25 | "zoom into a flat blurry orange field, middle plain" | retuned (T29) |
| Echo | 2.25 | 4.25 | 3.00 | 3.50 | 2.75 | "flame-like ghost dissolve, plain crossfade visible" | replaced by Ripple (T30) |
| Depthwash | 2.75 | 4.00 | 3.75 | 4.50 | 3.50 | "neon hue melt, similar to Rainbow" | reworked (T28) |
| Embers | 2.25 | 3.25 | 2.75 | 2.75 | 2.50 | "abrupt jump between frames 4 and 5", "generic" | replaced by Melt (T30) |
| Shatter | 3.75 | 3.50 | 4.00 | 3.75 | 4.25 | "water-caustic shatter, slightly harsh/abrupt" | softer edge (T29) |

- What the scores say: the styles whose carrier is a UV move (Kaleidoscope, Whirlpool, Shatter) or a
  strong colour field (Rainbow) were seen as distinct; every style that is "the live warp, a bit more,
  plus a mask" (Tide, Undertow, Prism, Depthwash, Echo, Embers) collapsed into one look-alike group
  ("liquid smear with fringing"). The fix is a different *geometry* per style, not stronger amounts.

### T28. Undertow, Prism, Depthwash: each gets its own movement
- Undertow: a one-way current. The picture is pulled along the seed direction in streaks (two sines
  across the direction), up to `txAmount` = 0.05 / 0.10 / 0.16 at the three intensity anchors; the
  turbulence amount drops a little so the current, not the water, is the look.
- Prism: a wide straight RGB split along the seed direction (`0.35 txAmount E`, about 0.06 of the frame
  at the plateau, on top of the radial fringing), and the swap is a light sweep along the same
  direction (`0.7 dot(uv, dir) + 0.25 flow`) with the channel stagger, so the new picture arrives
  red, then green, then blue across the frame. One uniform branch in stage B (`txEnv > 0`).
- Depthwash (visionOS only, needs depth): near things swell toward the viewer (`uv` scaled about the
  centre by `1 + txAmount E depth`), the far ones hold still, and the swap stays far-to-near. The
  fractal hue boost that made it look like Rainbow is cut to a third.

### T29. Smoothness and the visible double exposure
- Kaleidoscope: the fast frame steps were in the unfold (tp 0.79-0.90), not at the swap. Plateau
  0.30-0.60 and 3.2-4.2 s give the unfold 40 % of a longer transition; mask softness 0.15 -> 0.22.
  step_max 0.063 -> 0.059 / 0.062 (still above 0.050: the unfold is large motion by design).
- Dive: the double exposure was the feedback trails (feedbackAdd 0.30) dragging the old picture over
  the new at the deepest zoom. Trails 0.06 / 0.12 / 0.18, zoom 1 + 0.5 / 1.0 / 1.8, mask 0.22 -> 0.16,
  window 0.34-0.58, 2.6-3.4 s. seam_out 2.28 / 2.58 -> 1.69 / 1.87 (both under the gate now).
- Afterimage: the trails cycle colour (hue blend +0.25 E, hue base +0.18 E, chromatic x(1 + 2E)) and
  the feedback target is lower (0.82 at the default, was 0.88) so the smear keeps streaks of detail
  instead of a flat field. Its swap window widens to 0.30-0.60: with less feedback the narrow window
  popped (2.7 -> 2.0).
- Shatter: mask softness 0.08 -> 0.14, window 0.32-0.68 ("slightly harsh").

### T30. Echo and Embers replaced by Ripple and Melt
- Both kept the raw value (9 and 11) so uniforms and the director's tables only rename.
- Why replaced and not tuned: both used a carrier that cannot hide edges (ghost taps, bloom), so the
  swap read as a dissolve whatever the amounts; judges grouped them with the generic liquid styles.
  Removing Echo's tap-gain code also takes the per-frame tap alpha select out of every frame's loop
  (the tap loop is the same as main's again).
- Ripple (geometric, gentle): a drop in a pond. Concentric rings (`sin(30 r - 6 t)`, radial UV push of
  0.015 / 0.035 / 0.055) travel out from a seeded point and the new picture rides the expanding front
  (`r / 0.75 + 0.08 ring`).
- Melt (flow, gentle): the picture drips. Narrow drips (sine peaks to the 6th and 4th power) on a slow
  sag pull the picture downward, stretching more toward the bottom; drip length 0.12 / 0.24 / 0.36. The
  new picture arrives from the top down along the drip-shaped front.
- Families now: flow = Tide, Undertow, Depthwash, Melt; colour = Prism, Rainbow; geometric =
  Kaleidoscope, Whirlpool, Dive, Shatter, Ripple; temporal = Afterimage. Ripple and Melt are offered at
  low intensity and favoured in clear stretches.

### T31. Measured, round 1 (default intensity, seed 0; `tx/round1` in the session scratchpad)
| style | p1 swap_vis / double | p2 swap_vis / double | pop p1 / p2 | seam_out p1 / p2 | step_max p1 / p2 |
|---|---|---|---|---|---|
| Undertow | 0.16 / 0.12 | 0.17 / 0.14 | 1.4 / 1.3 | 1.27 / 1.38 | 0.023 / 0.026 |
| Prism | 0.26 / 0.22 | 0.23 / 0.19 | 1.9 / 1.7 | 1.52 / 1.40 | 0.024 / 0.027 |
| Kaleidoscope | 0.04 / 0.11 | 0.09 / 0.11 | 1.2 / 1.3 | 1.61 / 1.82 | 0.059 / 0.062 |
| Dive | -0.22 / 0.10 | -0.06 / 0.06 | 1.3 / 1.5 | 1.69 / 1.87 | 0.050 / 0.044 |
| Afterimage | 0.19 / 0.16 | -0.05 / 0.06 | 2.0 / 2.4 | 1.06 / 1.02 | 0.016 / 0.029 |
| Ripple | 0.32 / 0.27 | 0.15 / 0.13 | 1.4 / 2.1 | 1.06 / 1.07 | 0.037 / 0.054 |
| Depthwash | 0.23 / 0.21 | 0.05 / 0.05 | 2.3 / 3.0 | 1.03 / 1.04 | 0.022 / 0.039 |
| Melt | 0.19 / 0.16 | 0.11 / 0.08 | 1.1 / 1.3 | 1.20 / 1.38 | 0.024 / 0.023 |
| Shatter | 0.18 / 0.16 | -0.41 / 0.05 | 2.1 / 1.7 | 1.51 / 1.60 | 0.027 / 0.034 |
- Unchanged styles measure as in round 0 (Tide still pops on the calm pair, 2.9 / 3.6, and its
  seam_out is 2.8 / 2.5; left alone because it is the user's liked look).
- Still visible on the calm pair: Prism and Ripple (and Rainbow, unchanged). Both now have a clear
  geometric front (a spectral sweep, an expanding ring), which is different from a whole-frame
  dissolve; whether the judges still read it as a visible swap is round 1's question.
- Outside transitions: frames against main's shader differ by at most 1 of 255 in under 0.001 % of
  pixels (compiler rounding; r2-04 and r2-07 at t = 47 / 160 / 330 / 600, both eyes). The
  effects-balance gates (`fx-judge-set.py --mode app`, 150 frames) PASS at 0.25 / 0.5 / 1.0 (hog loss
  mean 0.068 / 0.095 / 0.127).

### T32. GPU, round 1 (interleaved A/B, 2048^2 MRT stereo, the other workstream's simulator running)
- Non-transition frames, round 1 against round 0: B/A 1.009 and 0.994 overall (per scenario
  1.003-1.017); main against itself in the same session 0.993 (0.970-1.004). Within noise; the Prism
  branch in stage B is the only new code on the normal path and Echo's tap select left it.
- Against main: 1.020 / 1.020 overall in this (noisier) session, round 0 measured about 1.015.
- Transition frames against round 0's: 0.94-1.07 per style (Melt 1.07 and Kaleidoscope 1.06 the
  highest, Prism and Tide cheaper), single runs, so only "no style became much heavier".

## Tuning round 2

### T33. Round 1 blind scores per style
Two blind judges, 26 clips (`tx/round1/blind`, key `tx/round1-key.json`), mean of the 4 ratings per
style (axes as in T27); "< 3.5" marks what round 2 had to fix.

| style | d | s | h | f | a | judges' words | round 2 |
|---|---|---|---|---|---|---|---|
| classic (control) | 3.50 | 4.00 | 4.00 | 4.75 | 4.25 | "melts well", "near the classic baseline" | unchanged, never picked |
| Tide | 3.00 | 3.75 | 3.75 | 3.75 | 3.25 | "diagonal swept liquid warp, similar to several others" | reworked (T34) |
| Undertow | 2.75 | 3.75 | 3.50 | 3.75 | 3.25 | "gentle wavy smear, near the classic" | replaced by Facets (T35) |
| Prism | 3.00 | 3.75 | 4.00 | 4.50 | 3.50 | "RGB explosion" (one judge) / "generic rainbow-fringe wash" (other) | twist added (T34) |
| Rainbow | 3.50 | 3.75 | 3.50 | 4.00 | 3.50 | "rainbow aurora colour wash", "colour gradient blobs" | unchanged |
| Kaleidoscope | 5.00 | 3.25 | 3.50 | 3.25 | 4.75 | "very distinct, gorgeous; slightly canned, first frames snap" | smoother fold (T34) |
| Whirlpool | 3.75 | 4.00 | 4.00 | 4.00 | 4.00 | "swap disguised in the spin" | unchanged |
| Dive | 3.75 | 3.50 | 3.00 | 3.75 | 3.50 | "zoom-through, new image visible early, zoom-dissolve" | retuned (T34) |
| Afterimage | 3.50 | 3.50 | 3.75 | 3.50 | 3.25 | "flat purple wash, loses detail", "dim and muddy middle" | retuned (T34) |
| Ripple | 3.75 | 3.75 | 3.75 | 3.75 | 3.75 | "pond-surface caustics, distinct" | unchanged |
| Depthwash | 2.50 | 3.75 | 3.25 | 3.75 | 3.00 | "magenta warp blend, similar to others", "busy" | replaced by Solarize (T35) |
| Melt | 4.00 | 4.00 | 3.75 | 4.00 | 4.00 | "vertical drip, distinct direction", "wave-fold stripes" | unchanged |
| Shatter | 3.50 | 3.25 | 3.50 | 4.00 | 3.75 | "caustic shatter; somewhat messy, noisy fragments" | softer (T34) |

- Melt and Ripple (round 1's replacements) landed in the distinct group; Kaleidoscope, Whirlpool and
  Melt carried the "awesome" axis. The look-alike group shrank to Tide, Undertow, Depthwash (and Prism
  on the busy pair): all three still read as "a stronger live warp".
- Scores per style: `tx/r2work/round1-style-scores.json` in the session scratchpad.

### T34. Reworked and retuned
- Tide: keeps today's water surge (the user's liked look, a little lower: water 0.05 / 0.13 / 0.26)
  and adds a breaking wave that rolls across the frame along the seed direction. The wave is a band
  (Gaussian, about 0.3 of the frame wide) of strong push along the direction with crest ripples
  across it, and its centre sits exactly on the swap threshold (stage A recomputes swapWeight's
  threshold), so the new picture is left behind the wave. Mask softness 0.50 -> 0.14, window
  0.26-0.74, 2.0-2.8 s. The pop (2.9 / 3.6) and the exit jolt (2.8 / 2.5) are gone: 1.3 / 1.3 and
  1.77 / 1.57.
- Prism: the straight split gets a twist (red turns one way about the centre, blue the other,
  `0.7 txAmount E`), so the plateau is a spectral pinwheel rather than a sideways fringe.
- Kaleidoscope: fold 0.78 -> 0.72 at the default, 3.6-4.5 s, window 0.32-0.60, softness 0.24.
  A slow spin of the wedges was tried and dropped: sweeping the fold seams across detail raised the
  frame steps to 0.072. A centre-out "blossom" of the fold also measured worse (0.083: the ramp got
  steeper). Without them step_max is 0.055 / 0.055 (round 1 0.059 / 0.062).
- Dive: trails 0.12 -> 0.03 at the default and a ragged (flow-shifted) iris, against the double image
  at the deepest zoom. The numbers barely move (swap_vis -0.22 / -0.05); the trails were not the main
  carrier of the double image.
- Afterimage: feedback target 0.82 -> 0.64, feedback warp x(1 + 8E), bloom +0.18, contrast +0.15,
  ghost reach x(1 + 1.5E), hue blend +0.35: shorter, streakier, brighter trails instead of a
  flat wash.
- Shatter: noise a little lower (0.048 at the default), mask softness 0.14 -> 0.20, window 0.30-0.70,
  2.2-3.0 s ("harsh, messy").

### T35. Undertow and Depthwash replaced by Facets and Solarize
- Both kept their raw value (2 and 10), as Echo and Embers did in T30.
- Why replaced: two rounds of judges grouped both with the generic warp, and both kept the
  "live warp plus a mask" carrier that T27 identified as the problem.
- Facets (geometric, raw 2): a compound eye. UVs are pulled toward a hexagonal lens grid (6-10 cells
  across, by seed): `lens = cell - 1.6 local`. Mixing toward it first flattens each cell to its
  centre colour (a hex mosaic, at amount 0.38) and then shows each patch inverted and magnified. Lens
  amount 0.55 / 0.80 / 0.95. The cells exchange one at a time in a random order, loosely from the
  centre out (`0.6 hash + 0.4 r`).
- Solarize (colour, raw 10): the tone curve folds over itself. In the crossfade branch
  `0.5 - 0.5 cos(c (pi (1 + amount E) + E (0, 1.2, 2.4)))` is mixed in at 0.85 E, giving an S-curve,
  then solarized, then two bands, with each channel a little out of phase. The phase offsets scale
  with the value, so blacks stay black. The first try used a constant offset and flooded dark
  backgrounds with flat cyan. The fold amount is 0.6 / 1.1 / 1.6. The swap uses the flow order with
  softness 0.30, and is hidden because both pictures are tone-inverted at the plateau.
- No style needs a depth map any more. `TransitionDirector.eligible` keeps its `hasDepth` parameter,
  which the renderers pass, but no longer filters on it.
- Families: flow = Tide, Melt, Ripple; colour = Prism, Rainbow, Solarize; geometric = Kaleidoscope,
  Whirlpool, Dive, Shatter, Facets; temporal = Afterimage. Gentle set (offered below intensity 0.25):
  Tide, Afterimage, Melt, Rainbow, Ripple. Facets is favoured in wild stretches, Solarize in clear ones.

### T36. Measured, round 2 (default intensity, seed 0; `tx/round2` in the session scratchpad)
| style | swap_vis p1 / p2 | double p1 / p2 | pop p1 / p2 | seam_out p1 / p2 | step_max p1 / p2 |
|---|---|---|---|---|---|
| Tide | 0.24 / 0.08 | 0.21 / 0.08 | 1.3 / 1.3 | 1.77 / 1.57 | 0.045 / 0.053 |
| Facets | 0.13 / -0.16 | 0.10 / 0.07 | 2.0 / 1.6 | 1.00 / 0.98 | 0.037 / 0.030 |
| Prism | 0.25 / 0.23 | 0.19 / 0.19 | 1.9 / 1.7 | 1.59 / 1.38 | 0.025 / 0.028 |
| Kaleidoscope | 0.06 / 0.09 | 0.11 / 0.11 | 1.2 / 1.2 | 1.05 / 1.11 | 0.055 / 0.055 |
| Dive | -0.22 / -0.05 | 0.10 / 0.06 | 1.4 / 1.6 | 1.69 / 1.87 | 0.051 / 0.044 |
| Afterimage | 0.26 / -0.03 | 0.22 / 0.07 | 2.5 / 2.3 | 1.06 / 1.03 | 0.024 / 0.031 |
| Solarize | 0.35 / 0.18 | 0.30 / 0.16 | 1.6 / 2.1 | 1.07 / 1.07 | 0.025 / 0.059 |
| Shatter | 0.19 / -0.42 | 0.17 / 0.05 | 2.0 / 1.9 | 1.32 / 1.35 | 0.024 / 0.032 |
- Unchanged styles (Rainbow, Whirlpool, Ripple, Melt) measure as in round 1.
- Every exit jolt is now under the 2.5 limit (Tide was the last one above it). The step limit
  (0.050) is still exceeded by Kaleidoscope (0.055), Tide p2 (0.053, on the moving wave crest),
  Solarize p2 (0.059, the tone fold on the bright sky) and Dive / Whirlpool p1 (0.051).
- Solarize on the calm pair has the highest "both visible" score (0.35 / 0.30): the swap_vis metric
  compares structure against effects-off references, and a tone-inverted frame resembles both. Its
  clips are the judges' call.
- Outside transitions: frames against main's shader differ by at most 1 of 255, in under 0.00025 %
  of pixels (r2-04 and r2-07 at t = 47 / 160 / 330 / 600, both eyes). The effects-balance gates
  (`fx-judge-set.py --mode app`, 16 fixtures, 480 frames) PASS at 0.25 / 0.5 / 1.0 (hog loss mean
  0.063 / 0.092 / 0.124, strain p90 max 0.50 / 0.80 / 1.18, the same as round 1).

### T37. GPU, round 2 (interleaved A/B, 2048^2 MRT stereo, non-transition t = 47/113/600/2000)
- Round 2 against round 1: 1.013, and reversed (round 1 as B) 1.012. Both orders show the same
  ~1.2 % order bias, so the net change is about 1.000. The new stage B code (Prism twist, Solarize)
  sits in branches that are not taken outside a transition.
- Against main: 1.023 (round 1: 1.020). Main A/A in the same session: 0.997. The other workstream's
  simulator was running.
