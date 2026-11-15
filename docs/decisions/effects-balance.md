# Effects balance: decisions

Decision log for the effects-balance workstream. Plan with all numbers: `docs/plans/effects-balance.md`.
Request: the effects made the image unrecognisable on the Vision Pro; keep every effect, add limits, a slow
change in how much they are used, and a setting.

Status: diagnosis and design (E1 to E14). Implementation decisions are appended below as they are made.

## Diagnosis

### E1. Measure with the real shader, offline, against an effect-free frame
- What: `scripts/shader-bench.sh` gained `--render-only`, `--set` (uniform overrides) and `--scenarios`;
  `scripts/fx-structure.py` renders each fixture with every effect knocked out and alone and scores it
  against the same frame with all effects off (Ken Burns kept).
- Why: the simulator shows a random image and cannot switch one effect off. The bench compiles the app's
  own uniform code and the working-tree shader, so the frames are what the app draws.
- No image was generated. The fixtures are existing photos with known subjects.

### E2. Score on luma, and treat HOG as the recognisability proxy
- What: four metrics (SSIM at 384 px, SSIM at 96 px, edge-map correlation, HOG cosine), all on luma.
- Why: a hue rotation alone should cost nothing. SSIM collapses under any smooth shift (the water alone
  loses 0.69) although the subject is still obvious, so it cannot be the gate. HOG ranks frames the way the
  eye does, but its range is compressed (0.05 clean-ish, 0.15 unreadable), so it is a gate on the mean only.
- The final word is a blind judge, not a metric (E13).

### E3. Add a CPU model of the warp field for a geometric budget
- What: `scripts/fx_model.py` ports `distortedUV` and the oscillators and reports displacement, strain
  (size of the displacement gradient) and fold fraction.
- Why: "how far and how roughly is the picture bent" is the quantity a cap has to act on, and it cannot be
  read from pixels. Validated: the model's warp of the reference frame matches the shader's output with
  SSIM 0.90 to 0.97 (0.29 to 0.43 without the warp); its oscillators match the app to 5e-7.
- Found: combined strain is the root-sum-square of the three warps, with 12.8 / 42 / 28 per unit amount for
  turbulence / log-spherical / fractal noise.

### E4. Verdict on "the radial is the culprit": partly; the cause is three warps stacked all the time
- Each warp alone leaves the subject readable. Removing any single one from the full pipeline recovers
  about 0.02 of 0.154 HOG loss. All three together, without any colour effect, give the full loss.
- The radial has the largest displacement (p95 0.063 of the picture, the water 0.041) and puts a pucker on
  the centre of the source image, where the subject is, plus a one-sided squeeze of the top half. It is the
  most visible signature, which is why it was named.
- The water has the highest strain but is smooth; it is readable alone even at 0.072.
- Fractal noise is as damaging as the radial.
- Today's combined strain is never below 0.4 and is above 0.7 for 93 % of the time: the oscillators are
  decorrelated, so something is always high. That, not any one amount, is why there is no clear moment.
- Colour is the second layer (0.30 SSIM loss alone): hue waves put several rainbow cycles across the frame.

## Design

### E5. One drive value moves every effect together: clarity cycle x fresh-image hold
- What: `d = macroDrive(time, intensity) * fresh(imageAge)`; every amount is a mix of a clear value and a
  wild value by `d`, times its own existing oscillator.
- Why: clear stretches only exist if the effects calm down together. The per-effect oscillators are kept
  for variety inside a stretch.
- Rejected: only lowering every maximum. It makes the picture uniformly bland and still never clear.

### E6. Clarity cycle: three golden-ratio sines, periods 420 / 260 / 160 s, through a smoothstep
- Why: same non-repeating construction as `SmoothOscillator`, but slow. The smoothstep window
  (-0.45...0.55) gives real plateaus: 39 % of the time clear and 32 % wild at the default. Fastest change
  0.031 per second, so clear to wild takes at least 32 s.
- Phases chosen so a session starts clear and reaches its first wild stretch after about a minute.
- Rejected: periods near 5 minutes only (300 / 185 / 115 s): transitions were as fast as 17 s.

### E7. Fresh-image hold driven by image age
- What: the drive goes to 0 during the crossfade, holds until 3 s after the fade-in, and returns by 11 s.
- Why: images change every 30 s, so without it most images would first appear mid-warp. The drop is hidden
  under the transition melt. It is a pure function of the age, so the computer stays stateless (as C2 in
  av-coupling.md requires).
- Cost: at most 63 % of an image's time can be wild. Accepted: recognisability is the goal.

### E8. Strain budget instead of independent caps; radial and noise give way before the water
- What: `sqrt((12.8 a_t)^2 + (26 a_l)^2 + (28 a_n)^2) <= B(intensity)`, B = 0.30 / 0.90 / 1.45 at
  intensity 0 / 0.5 / 1; when over, log-spherical and noise are scaled down together; the water is only
  clamped if it alone exceeds B.
- Why: the damage is the combination (E4), so the limit has to be on the combination. The user loves the
  water, so it has priority. The budget runs after the music factors, so music cannot break it.
- B(0.5) = 0.90: frames at combined strain 0.6 to 0.8 were readable with colour on; 1.0 and above were not.

### E9. Log-spherical: capped, windowed to the wild part of the cycle, and masked off the centre
- What: maximum 0.011 at the default (today up to 0.02), only when `d > 0.45`, and the shader multiplies its
  offset by `smoothstep(0.10, 0.42, R)`.
- Why: this is the effect the user named. The mask removes the pucker on the subject and keeps the
  kaleidoscope in the periphery, which on the dome is peripheral vision. Strain per unit amount falls from
  42 to 26.
- Rejected: CPU-only reduction. The centre pucker stays visible at any amount large enough to see at all.
- Cost: one smoothstep inside a branch. A/B 0.998 (noise).

### E10. Lower the two skip thresholds in the shader to 0.00002
- Why: the amounts now pass through zero. At 0.001 the warp would pop in by up to 0.006 of the picture.
- Side effect: in clear stretches both branches are skipped, about 19 % less GPU time for those frames.

### E11. Colour stays strong, hue waves are limited
- What: hue blend 0.40...0.70 of the colour cycle at the default (today 0.80), hue-wave intensity
  0.10...0.30 (today 0.60), fractal hue x0.5...0.85, chromatic x0.6...0.9, feedback mix 0.20...0.28.
- Why: colour costs far less structure than warp (E4) and carries the psychedelic look in clear stretches.
  The wave intensity sets how many rainbow bands cross the picture; that is what breaks figure from ground.
- Bloom, vibrance, ghost taps and the saturation and contrast boosts are unchanged at the default.

### E12. Setting "Effect intensity", 0...1, default 0.5
- What: scales the clear and wild values of every amount, the strain budget, the transition boost, and
  shifts the clarity cycle (more wild time when higher). Piecewise-linear through three anchors.
- 0 = nearly clean image with gentle water (strain at most 0.24, no radial, no noise). 1 = today's wild
  level during wild stretches (strain p90 1.22 against today's 1.28), still inside a budget of 1.45 and
  still breathing.
- Why three anchors: the default look can be tuned without moving the ends.
- Why 0.5: equal room on both sides of the slider.

### E13. Acceptance is a blind judge set with orientation decoys
- What: `scripts/fx-judge-set.py` writes shuffled frames with neutral names and a private key; a quarter
  are rotated 180 degrees. Judges name the subject, the orientation and rate trippiness 1 to 5.
- Why decoys: every real frame is upright, so a judge who always answers "upright" would score 100 %.
- The 10 sample times follow the long-run proportions of the clarity cycle (4 clear, 3 wild, 3 between), so
  "recognised most of the time" is measured on the time the user actually sees.
- Pass criteria and objective gates: plan section 8.

### E14. Ken Burns zoom range 1.04...1.32 (was 1.00...1.40) and additive transition boosts
- Zoom: at 1.40 only 51 % of the picture is visible, which hides what the subject is; at 1.32 it is 57 %.
- Transition: the boost was a multiple of the base (x10 water). With a base that now goes near zero a
  multiple would vanish, so it is an added amount, 0.16 for the water at the default (today about 0.48).

## Prototype results (before implementation)

`fx-judge-set.py --mode proto` and `--mode current`, same 60 (fixture, time, age) frames per level:

| | mean HOG loss | max strain p90 | max displacement p95 | max fold |
|---|---|---|---|---|
| shipped | 0.149 | 1.45 | 0.123 | 0.025 |
| proposed, 0.25 | 0.054 | 0.48 | 0.035 | 0 |
| proposed, 0.5 | 0.077 | 0.78 | 0.062 | 0.0006 |
| proposed, 1.0 | 0.112 | 1.30 | 0.111 | 0.0025 |

By eye, the default's wildest frames keep the hourglass, romanesco, accordion, ferris wheel and jellyfish
readable and are clearly psychedelic. Not yet judged blind. If the default reads as too tame, raise colour
before warp (plan 8.4).

## Implementation

### E15. `EffectLook` holds the look; `EffectsUniformsComputer.compute(..., look:)` applies it
The setting, the image age and every tuning constant (`EffectLook.Tuning`) live in
`Liminal/Visual/EffectLook.swift`, which the shader bench also compiles. Reason: one place to retune.
Both renderers and the bench call the same `compute`, so they cannot drift. The default argument
(intensity 0.5, no image age) is the shipped look, so `compute(time:)` callers and the bench's default
runs measure what ships.

### E16. Golden parity with the prototype
`LiminalTests/EffectLookTests.goldenParityWithModel` checks the drive and 12 uniforms at the 12 inputs of
`fx_model.py golden` (tolerance 1e-4). Reason: the plan's measurements were made with the Python prototype.
The `--mode app` judge set reproduces the prototype's numbers to the third decimal (table below), which
confirms the port. If a number is retuned, change `fx_model.proposed()` too and regenerate the golden rows.

### E17. The budget is fitted after the music factors and before the absolute caps and the transition boost
Reason: loud music can raise the water, but it can never push the combined warp past the budget. The caps
(0.10 / 0.020 / 0.036) and the chromatic cap keep their "before the transition boost" meaning from the
av-coupling work. The feedback-mix cap is now relative to the look's base (±0.04, never above 0.34), and
the bloom cap scales with the base (0.72 at 0.5).

### E18. Image age starts at the crossfade, not at the first image
macOS (`MusicSyncBox.transitionStart`) and visionOS (`transitionStartEffectTime`) record the effect time when
a crossfade starts. The first image has no crossfade, so its age is nil and the fresh hold is 1. Reason:
sessions already start clear (E6). On macOS the value resets when Play restarts the effect clock.

### E19. The renderers ease intensity with a 0.5 s one-pole (`EffectIntensitySmoother`)
Reason: dragging the slider must not step the picture. The smoother holds its value when the same frame
asks twice (macOS evaluates uniforms more than once per tick). It snaps when the clock restarts or jumps by
more than 1 s. With `-LiminalFreezeTime` the target is used directly.

### E20. DEBUG flag `-LiminalEffectIntensity X` overrides the setting without changing it
Reason: sim checks and perf runs need a fixed intensity without touching the user's saved value. Like the
other automation flags, it blocks Gemini generation.

### E21. The slider sits first in the Visuals section on both platforms
It is the shared `ValueSlider` with "Subtle"/"Wild" end labels and a caption. `ValueSlider` gained an
optional `explanation` for that caption. Reason: this is the control the user asked for, so it should be
the first thing in Visuals. The shared component shows the value as a percentage and wraps its labels.

### E22. Slew test skips the crossfade
`noPopsAtFullIntensity` checks a step below 0.002 per 1/90 s over 900 s at I = 1, with images every 30 s,
except during the first 1.5 s of each image. Reason: the drive falls to clear during the crossfade, and
that fall (up to 0.003 per frame in hue-wave intensity) hides under the transition melt. The melt itself
moves far faster: the water boost changes up to 0.009 per frame.

## Implementation results

- Unit tests (`LiminalTests`, macOS) pass, including the new `EffectLookTests` (golden parity, 10 000
  random inputs within the budget and caps, strain monotonic in intensity, clarity cycle bounded and slow
  with clear and wild shares, fresh hold, no pops, no radial or noise at I = 0, smoother).
- Judge set, `--mode app`, 180 frames (`scratchpad/fx/round0`):

| intensity | mean HOG loss | max HOG loss | max strain p90 | max fold | gate |
|---|---|---|---|---|---|
| 0.25 | 0.054 | 0.090 | 0.48 | 0 | PASS |
| 0.5 | 0.077 | 0.133 | 0.78 | 0.0006 | PASS |
| 1.0 | 0.112 | 0.198 | 1.30 | 0.0025 | PASS |

- GPU (shader-bench on an M4, 2048² MRT stereo, simulator idle in the background):
  - Same uniforms, main's shader A against the new shader B, interleaved: B/A is 1.012 as the median of
    trials (trials 0.993 to 1.030).
  - The only scenario that moves is t37, a near-clear moment (2.87 to 3.23 ms). There the fractal-noise
    amount is between 0.00002 and 0.001: the new shader evaluates it and the old one skipped it. This is
    the cost of E10, which removes the pop.
  - End to end (shipped uniforms with the shipped shader, against the new ones), median over the same
    scenarios: 3.77 ms shipped, 3.56 ms new (0.94). In clear stretches both warp branches are skipped
    (t260: 2.90 ms).
- `scripts/av-coupling-check.sh` fails on the bloom 3–30 Hz band (0.0579 against 0.05). **Main fails
  with the identical value**, so this is unrelated to this work: bloom at the default is unchanged, and the
  failure predates it, probably from the calm-music redesign. It is left for a separate fix. Every other
  coupling check passes: distortion slew 0.00017, correlation 0.999, toggle off with 0 mismatches.

## Tuning round 1 (after the round-0 blind judges)

Round 0 (3 blind judges, 180 frames) solved the original problem: 100 % of frames recognised at every
intensity, orientation 94 % at the default once the top-down ferris wheel is excluded. It failed on
trippiness instead: 1.84 / **2.59** / **3.93** at intensity 0.25 / 0.5 / 1.0, against the targets of at least
3.0 at the default and 4.0 at 1.0. The judges rated clear-stretch frames about 2 and wild-stretch frames 3 to 3.4
at the default. At 1.0 the worst frames were the blossoming tree, where several stacked rainbow cycles
(hue waves 0.21-0.24 with hue blend 0.3-0.4) merged figure and ground, and the hourglass, where turbulence
plus crystalline noise melted the outline. The radial was near zero in most of those frames.

A ridge regression of the round-0 ratings on the uniforms (R² 0.77, `scratchpad/fx/round1-work/tripmodel.py`)
ranks what makes a frame look trippy to the judges: chromatic aberration and fractal hue first, then
hue waves and feedback. Warp amount adds nothing once colour is accounted for. So round 1 raises colour
and fringing, which are cheap for recognisability, caps stacked rainbows, and leaves the warp budget alone.

### E23. More colour and fringing in every stretch, and a little more water
- What:
  - Chromatic mix (clear, wild) at the default: 0.6 / 0.9 becomes 0.9 / 1.15; at 1.0, 0.9 / 1.0 becomes 1.1 / 1.3.
    It stays under the 0.02 cap.
  - Fractal hue at the default: 0.5 / 0.85 becomes 0.75 / 1.0; at 1.0, 0.8 / 1.0 becomes 1.0 / 1.15.
  - Clear-stretch hue waves at the default: 0.10 becomes 0.12. Clear-stretch feedback: 0.20 becomes 0.22.
  - The hue blend no longer follows the colour cycle down to 0. It moves between 35 % and 100 % of its
    amount (`hueBlendFloor`).
  - Water clear amount: 0.024 / 0.030 becomes 0.028 / 0.036 at the default / 1.0. Water wild at the default:
    0.056 becomes 0.058.
  - `macroBias` 0.50 becomes 0.60, so intensity 1.0 spends more time wild and 0.25 more time clear. The
    default's cycle is unchanged.
- Why:
  - The clear stretches were the tame ones. Before this change the colour cycle could dip the hue blend to
    nearly 0, which gave plain-photo moments.
  - Chromatic aberration and fractal hue are what the judges responded to. Both keep each pixel's
    luminance, so the outlines that make a subject recognisable stay.
  - The user loves the water warp, and the default HOG loss had headroom (0.077 against a 0.10 gate).

### E24. Crystalline noise at intensity 1.0 is capped at 0.022 (was 0.026)
- Why: in the round-0 hourglass and tree frames at 1.0, the noise on top of turbulence made a
  high-frequency shatter that hid the outline. The radial stays as in round 0: it was not the cause.

### E25. Stacked rainbows are capped
- What:
  - Hue-wave anchors are lowered: clear (0.02, 0.12, 0.24), wild (0.05, 0.28, 0.40).
  - Hue waves are capped at 0.20 absolute (`hueWaveCap`).
  - Hue waves times hue blend is capped at 0.065 (`rainbowCap`). Within that cap the blend wins and the
    waves give way.
- Why:
  - The product of the two is the strength of the spatial rainbow. Above about 0.07 the rainbow ran through
    the tree several times and the judges lost the figure.
  - The hue blend alone, a global shift with contrast and saturation, keeps the structure, so it is the
    one allowed to stay high.
  - The cap is a min() of continuous functions, so it adds no jumps; the no-pops test still passes.

### E26. Judge set: venus flytrap replaces the top-down ferris wheel; new frame names per round
- What:
  - `fx-judge-set.py` now uses r2-07 (venus flytrap, a dark scene with a clear up) in place of r2-03.
  - The new `--prefix` option, together with a new `--seed`, gives every round its own frame names and
    shuffle. Round 1 uses `view-NNN`, seed 4139.
- Why:
  - A top-down photo has no up, so every orientation answer on it was "cannot tell". That cost 16.7 points
    on the strict orientation score whatever the effects did.
  - The near-symmetric hourglass is kept on purpose, even though it causes most of the orientation misses,
    so the test stays hard.
  - The flytrap is another dark, low-key scene, the kind where the tree failed.
  - Judges must not be able to match frames across rounds.

### Round 1 results (before judging)
- Judge set, `--mode app`, 180 frames (`scratchpad/fx/round1`, key in `round1/key`):

| intensity | mean HOG loss | max HOG loss | max strain p90 | max fold | gate |
|---|---|---|---|---|---|
| 0.25 | 0.064 | 0.109 | 0.50 | 0 | PASS |
| 0.5 | 0.090 | 0.147 | 0.81 | 0.0008 | PASS |
| 1.0 | 0.124 | 0.189 | 1.28 | 0.0024 | PASS |

  HOG loss rises with the extra colour, since HOG sees gradient changes from hue, and with the darker flytrap
  fixture. Every gate still passes.
- Trippiness predicted by the round-0 regression on the new uniforms: 2.13 / 3.19 / 4.14 (round 0: 1.84 /
  2.59 / 3.93 actual, 1.84 / 2.63 / 3.90 fitted). This is a proxy only; the blind judges decide.
- Contact sheet (`round1/sheet.jpg`): every subject is recognisable and upright at the default and at 1.0. The
  tree at 1.0 keeps its trunk and crown, the rainbow stays within the blossoms and no longer floods
  figure and ground together, and the default is clearly psychedelic in every column.
- The shader is unchanged (same metallib hash). shader-bench default median: 3.62 ms against 3.56 ms in round 0,
  which is within run-to-run noise.
- Unit tests pass. The golden values were regenerated from `fx_model.py golden`, and the random-input test
  now also asserts the rainbow cap.
