# Image transitions: decisions

Decision log for the transitions workstream. Plan with all numbers: `docs/plans/transitions.md`.
Request: the transition between images (distort, switch, come back) is liked but is the same every time;
make a family of them that flows out of and back into the live effects.

Status: implemented on both platforms (T15-T26), round 0 clips rendered; blind judging and the
simulator / macOS run of plan 8.3 are next.

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
