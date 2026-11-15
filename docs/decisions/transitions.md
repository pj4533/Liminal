# Image transitions: decisions

Decision log for the transitions workstream. Plan with all numbers: `docs/plans/transitions.md`.
Request: the transition between images (distort, switch, come back) is liked but is the same every time;
make a family of them that flows out of and back into the live effects.

Status: design done (T1-T14). Nothing in the app has changed yet; tooling only.

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

## Open points for implementation
- The transition tracker on visionOS is in `ImmersiveDomeView.swift`, which the spatial workstream is
  rebuilding. The hook is three call sites (spec at crossfade start, `spec.duration`, `transition:` into
  `compute`); merge order should put the spatial rebuild first.
- Depthwash is offered only when a depth map is bound (visionOS). macOS binds no depth texture.
