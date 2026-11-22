# Performance plan (visionOS dome render path)

Ranked by GPU-time win per unit of risk. Constraints: output stays 2048x2048 per eye, the look is
preserved (frozen-time screenshot comparison), GPU time is the primary metric. Measured numbers and
decisions go in `docs/decisions/performance.md`.

## Round 1 analysis (2026-11-14)

### What a frame costs today
Per frame the render loop (`ImmersiveDomeView.startRenderLoop`, MainActor, `Task.sleep` paced to
11.1 ms) commits three command buffers:

1. `dome`: breathing compute over 1,813 vertices (`LowLevelDomeMesh.updateBreathing`). Negligible.
2. `eyeL` and 3. `eyeR` (`OffscreenEffectsRenderer.renderEyeToDrawable`): each runs the full
   `effectsFragment` over 2048² into the shared `outputTexture` (clear + store), then blits
   2048² into the drawable texture.

So 8.4 M shaded pixels and 8.4 M copied pixels per frame, about 755 M shaded pixels per second at 90 Hz.

Per pixel, `effectsFragment` evaluates (counting sin/cos/exp/log/atan as "trig"):

| stage | trig | texture samples | same for both eyes? |
|---|---|---|---|
| turbulence (8 iterations) | 8 | 0 | yes |
| log-spherical (6 octaves + log2, atan2, exp, cos, sin) | ~47 | 0 | yes |
| sinusoidal noise (2 x 5 octaves) | 70 | 0 | yes |
| stereo parallax | pow | 1 depth | no |
| chromatic + crossfade | pow | 3 source + 3 previous | no |
| hue waves | 9 + length | 0 | function of final uv only |
| fractal hue (4 octaves + float HSV) | 28 | 1 depth | noise is a function of final uv only |
| ghost taps | 0 | 0-8 source | no |
| bloom | 2 | 1 source (random offset) | no |
| feedback warp (8 iterations) | 8 | 1 feedback | see finding 2 |

About 175 trig evaluations per pixel per eye, of which about 125 (the three distortion stages) are
identical for both eyes because they run before the stereo parallax. Every threshold uniform
(`logSphereAmount`, `fractalNoiseAmount`, `fractalHueAmount`, `bloomAmount`, `feedbackMix`) is
always above 0.001 in `EffectsUniformsComputer`, so no stage is ever skipped.

### Findings
1. **Redundant 2048² copy per eye.** The drawable texture is created with `.renderTarget` usage and
   the same `bgra8Unorm_srgb` format as the pipeline, yet the shader renders into `outputTexture`
   and a blit copies it. The split-pass trial puts the copy at about a third of each eye pass
   (blitL 0.043 of 0.130 ms). Nothing reads `outputTexture` afterwards on visionOS.
2. **The feedback stage is dead work on visionOS.** `feedbackMix` is 0.3 on both platforms, but only
   macOS binds texture index 4. On visionOS the shader runs a second 8-iteration turbulence and
   samples an unbound texture. The result is undefined by the Metal spec; in practice it reads
   zero, so the stage currently just multiplies the image by 0.7.
3. **Three wasted texture samples outside transitions.** With no transition, `previousTexture`
   falls back to `sourceTexture` and `transitionProgress` is 0, so the three "previous" samples
   fetch the same texels as the three source samples and the mix returns them unchanged.
   Transitions last 1.5 s out of roughly every 30 s.
4. **The distortion field is computed twice per frame and at full resolution.** It is a smooth
   field (shortest wavelength about 130 px at 2048², except within about 60 px of the log-spherical
   centre where the top octave contributes under 2 px of displacement).
5. **Hue waves and fractal-hue noise are smooth scalar functions of the final uv**, evaluated per
   pixel per eye in float.
6. **Three command buffers per frame, and the stereo path has no in-flight bound.** The mono path
   has a semaphore; the stereo path does not. `nextDrawable()` is called on the MainActor twice per
   frame and can block.
7. `loadAction = .clear` on a pass that covers every pixel.

## Ranked plan

| # | item | expected GPU win | look risk | status |
|---|---|---|---|---|
| 1 | Render each eye directly into its drawable texture (no `outputTexture`, no blit, `.dontCare` load) | about 30 % of each eye pass | none | round 1 |
| 2 | Compile the feedback stage out on visionOS with a function constant, keeping today's result | 8 trig + 1 sample per pixel per eye | low (needs a decision, see below) | round 1 |
| 3 | Skip the three previous-texture samples when not transitioning | 3 of 7-16 samples per pixel, 95 % of the time | none | round 1 |
| 4 | Shared low-res displacement pre-pass (turbulence + log-spherical + noise) sampled by both eyes | about 125 of 175 trig per pixel per eye; largest single win | medium | round 1 |
| 5 | Bake hue waves + fractal-hue noise into a low-res field texture | about 37 trig per pixel per eye | medium | round 1 |
| 6 | One command buffer per frame (dome + pre-pass + both eyes) and an in-flight bound for stereo | small GPU, fewer CPU stalls | low | round 1 |
| 7 | Decouple the effects update rate from the display rate (for example 45-60 Hz; RealityKit still reprojects the dome at display rate) | up to 2x | changes temporal look (bloom shimmer rate); needs user sign-off | later |
| 8 | Bloom and ghost taps sample a mip level of the source (cache-coherent) | texture-cache misses | medium (softer glow) | later |
| 9 | Merge the two HSV round trips; move remaining float math to half | small after 5 | medium | later |
| 10 | Pace the loop from a display-linked source instead of `Task.sleep`; move encoding off the MainActor | CPU and jitter only | low | later |

### Rejected or deferred
- **Rendering below 2048²**: violates the resolution constraint.
- **Rendering only when content changes**: the effects animate every frame.
- **Both eyes in one MRT pass**: after item 4 the shared work is already hoisted; the per-eye part
  differs from the parallax onward, so MRT would save only rasterisation of one quad.
- **Compute instead of fragment for the main pass**: no gain on a TBDR GPU for a full-screen pass
  that writes one attachment; the fragment path already gets tile memory for free.
- **Function-constant specialisation of the other stages**: their amounts never reach zero, so
  there is nothing to strip. Only feedback (item 2) qualifies.

### Decision needed from the user (item 2)
The visionOS image is currently 30 % darker than the shader intends because the feedback texture is
never bound. Item 2 keeps that brightness (a multiply) so the look does not change. The alternative
is real feedback trails as on macOS, which costs an extra 2048² copy per eye per frame, or removing
the darkening, which brightens the dome.

### Measurement notes
- Simulator GPU totals are about 0.3 ms per frame, so small wins sit near the noise floor (about
  7 %). Use `--split` and the median of 3 runs; confirm the absolute effect on a Vision Pro.
- The frozen screenshot pins time but not the source image. Items 4 and 5 need a pinned image to
  compare pixels: add a debug flag that pins the cache image, or an A/B launch flag that switches
  the old and new path in the same run.

---

## Round 2 analysis (2026-11-14)

### What round 1 taught us
Round 1 kept one item (direct-to-drawable render, 0.304 -> 0.159 ms) and reverted five. Reading the
five reverted results together points at the harness, not at the ideas:

1. **The simulator GPU number is dominated by fixed per-command-buffer cost, not shader cost.**
   The `dome` pass (compute over 1,813 vertices) reads 0.05-0.09 ms. `eyeR` (about 175 trig and
   7-16 texture samples on each of 4.2 M pixels) reads 0.04-0.08 ms. Those cannot both be work
   proportional to the load. The low-res displacement pre-pass read 0.10 ms, and the hue bake
   0.11-0.21 ms, for the same reason: every extra pass pays the fixed cost. So the metric rewards
   removing passes and command buffers and is nearly blind to per-pixel math.
2. **The 0.159 ms reference was a lucky session.** Its three runs were 0.159 / 0.229 / 0.112.
   The next two items (feedback function constant, skip-previous-samples) only remove work, and
   one is bit-identical by construction, yet they read 0.282 and 0.280 ms. A session-level shift
   of the host is the simplest explanation (inference: HEAD was not re-measured in those
   sessions). Comparing a candidate against a number from an earlier session is not valid.
3. **Frozen screenshots never compared like with like**, because the source image is random.
   No item had its look verified numerically.

So round 2 starts with a measurement that responds to shader cost and gives pixel parity, then
prefers changes that also remove passes (visible even in the simulator metric).

### Remaining per-frame cost (HEAD 5d40d08)
- 3 command buffers: `dome` compute, `eyeL`, `eyeR`. Each eye is one 2048² pass straight into its
  drawable.
- Per eye-pixel: about 125 trig for the distortion field (turbulence 8, log-spherical about 47,
  sinusoidal noise 70), which is **identical for both eyes** because it runs before the parallax
  shift; then about 50 trig and 7-16 texture samples that are per-eye.
- Texture state that hurts sampling and store bandwidth on Apple GPUs: source, previous and depth
  textures are `.shared` and never optimised for GPU access; both drawable queues declare
  `.shaderWrite`, which nothing uses since the blit was removed.
- The bloom stage takes one sample at a random offset of up to ±82 px per pixel from an
  unmipped 2048² texture (cache-hostile). Ghost taps add 0-8 more full-res samples.
- CPU side: the loop runs on the MainActor paced by `Task.sleep`; `nextDrawable()` is called
  twice per frame there; each transition redraws the previous image through CoreGraphics
  (2048², high interpolation) although that image is already on the GPU as `sourceTexture`.

## Round 2 ranked plan

| # | id | item | expected win on device | look risk |
|---|---|---|---|---|
| 1 | shader-bench-harness | Offline Mac-GPU benchmark of the real eye pass at 2048² with a fixed image and time; reports ms per eye and writes a PNG for exact pixel diffs | enabler: makes items 2, 4-7 measurable | none (tooling only) |
| 2 | mrt-stereo-single-pass | One render pass writes both eyes (two colour attachments); the distortion field is computed once per pixel, the per-eye part twice | about 125 of about 350 trig per pixel pair (roughly 30-35 % of eye ALU), one fewer pass and command buffer | none (same maths per eye) |
| 3 | dome-breathing-cpu | Compute the 1,813 breathing vertices on the CPU and write them into the LowLevelMesh; drop the compute pass and its command buffer | one command buffer and one compute pass per frame; about a third of the simulator metric, small on device | none |
| 4 | texture-gpu-hygiene | Drop `.shaderWrite` from both drawable queues; `optimizeContentsForGPUAccess` on source / previous / depth after each upload | lower store and sampling bandwidth; size unknown until measured on device | none |
| 5 | alu-exact-cleanups | Replace `cos/sin(atan2)` by `centered / R`, hoist uniform-only maths to the CPU, share one turbulence rotation table | about 5-8 % of eye ALU | low (float rounding only) |
| 6 | noise-angle-addition | Derive the second sinusoidal-noise field from the first field's sin/cos by angle addition | about 30 of 70 trig in that stage (about 17 % of eye ALU) | medium (removes half-precision quantisation in the high octaves) |
| 7 | bloom-ghost-mip-sampling | Mipmap the source once per image; bloom and ghost taps sample a coarser level | fewer texture-cache misses on 2-9 samples per pixel | medium (slightly softer glow) |
| 8 | realitykit-paced-loop | Drive the frame from RealityKit's per-frame update instead of `Task.sleep`; reuse the uploaded source texture as `previousTexture` on transition | no GPU change; steadier intervals, no 2048² CoreGraphics redraw per transition | low |

Items 2, 5 and 6 edit the same shader and stack. Items 3, 4, 7 and 8 are independent of them.

### Not in this round
- **Updating the effects below display rate (45-60 Hz)**: the largest remaining lever on device
  (up to 2x), but it changes how fast the bloom shimmer animates. Needs the user's sign-off.
- **Feedback stage on visionOS** (samples an unbound texture, darkens the image by 30 %): the
  function-constant attempt was reverted on a noisy measurement. Worth a retry once item 1 exists,
  together with the user's decision on the intended brightness.
- **Skip-previous-samples, low-res displacement pre-pass, hue bake, single command buffer**:
  already attempted. The two extra-pass designs should stay rejected unless a device measurement
  shows that a pass is cheap there. Skip-previous-samples deserves a re-measurement with item 1.
- **Any render size below 2048²**: violates the resolution requirement.

### Verdict rule for this round
Compare candidate and reference **in the same session, interleaved** (A B A B A B), never against
a number from an earlier session. For shader items use the item 1 benchmark as the GPU number and
its PNG diff as the parity check; use `perf-run.sh` for errors, the 2048² log line and pacing.

---

## Round 2b analysis (2026-11-14): per-pixel plan from the deterministic bench

Round 2 above was judged on the simulator and dropped every ALU item. This section re-plans the
per-pixel work with `scripts/shader-bench.sh` (interleaved A/B, Apple M4, MRT both eyes at 2048²,
reference about 6.5-7.0 ms/frame). Nothing in the app changed in this step; all variants were
throw-away shader files in the scratchpad.

### Where the frame goes (stage knock-outs, one interleaved run each, 4 x 300 frames)
Each row removes one stage from the current shader and reads the B/A ratio. It is an upper bound on
what any optimisation of that stage can save. A/A floor is about ±1.2%.

| stage removed | B/A | share of frame |
|---|---|---|
| sinusoidal noise (2 fields x 5 octaves, shared by both eyes) | 0.807 | 19.3% |
| fractal hue (4 octaves + float HSV + depth sample, per eye) | 0.858 | 14.2% |
| ... of which the noise octaves (noise replaced by a constant) | 0.915 | 8.5% |
| feedback (turbulence + sample + restoreChroma, per eye) | 0.873 | 12.7% |
| ... of which the 8-iteration turbulence | 0.925 | 7.5% |
| log-spherical (6 octaves + log2/atan2/exp, shared) | 0.876 | 12.4% |
| bloom (hash + random-offset sample + screen, per eye) | 0.917 | 8.3% |
| ... of which the random offset (sample at uv instead) | 0.987 | 1.3% |
| ghost taps (2 active taps, per eye) | 0.920 | 8.0% |
| hue waves (9 float sin, per eye) | 0.925 | 7.5% |
| turbulence (8 iterations, shared) | 0.952 | 4.9% |
| vibrance stage (gamutFit etc., per eye) | 0.958 | 4.2% |
| three previousTexture samples | 0.997, 0.981 | 0-2% (inside noise) |
| chromatic aberration as one tap instead of three | 1.005 | 0% |
| all three distortion stages together | 0.620 | 38% |

Reading it:
- **Trig in the three Nishitsuji octave loops is 46% of the frame** (noise 19.3 + log-spherical 12.4 +
  fractal hue 14.2). That is where the plan goes first.
- **Texture sampling is cheap on this GPU.** Dropping three previous-texture samples or two of the
  three chromatic taps is not measurable, and bloom's cache-hostile random offset costs 1.3%.
  So skip-previous-samples and mip sampling, both dropped in round 1, were correctly low value on a
  Mac GPU. Vision Pro may differ on texture cost; it cannot be shown here.
- **Nothing can be compiled out.** Every stage amount is above its 0.001 threshold at all times in
  `EffectsUniformsComputer`, and `hasSaliencyMap` is the only branch that is always false. Function
  constants would strip one never-taken uniform branch.

### Prototype already measured: double-angle octave recurrence
All three loops evaluate `sin(p * s)` and `cos(p * s)` for s = 1, 2, 4, ... The components are only
permuted (`sin(pos.zxy*s)`, `cos(pos.yxz*s)`), so one `sin(p)` and one `cos(p)` give every octave by
`sin 2a = 2 sin a cos a`, `cos 2a = 1 - 2 sin² a`. The second noise field (`pos + (17,31,7)`) comes
from the first by angle addition with compile-time constants.

```metal
#define DBL(S,C) { half3 _t = 2.0h * S * C; C = 1.0h - 2.0h * S * S; S = _t; }
static inline half flowOctaves(half3 s1, half3 c1, int octaves) {
    half e = 0.0h; half w = 1.0h;
    for (int j = 0; j < octaves; j++) {
        e += sin(dot(s1.zxy - 0.5h, 1.0h - c1.yxz)) * w;
        DBL(s1, c1)
        w *= 0.5h;
    }
    return e;
}
// sinusoidal noise:
half3 ns = sin(noisePos), nc = cos(noisePos);
const half3 ks = half3(-0.961397h, -0.404038h, 0.656987h);   // sin(17, 31, 7)
const half3 kc = half3(-0.275163h,  0.914742h, 0.753902h);   // cos(17, 31, 7)
float noiseX = float(flowOctaves(ns, nc, 5));
float noiseY = float(flowOctaves(ns * kc + nc * ks, nc * kc - ns * ks, 5));
// log-spherical: e += flowOctaves(sin(p), cos(p), 6);  offset = centered / R * displacement
// fractal hue:   fractalValue = float(flowOctaves(sin(noisePos), cos(noisePos), 4));
```

| variant | trig per pixel pair | B/A run 1 | B/A run 2 |
|---|---|---|---|
| noise only | 70 -> 16 | 0.874 | 0.899 |
| log-spherical only (+ `centered / R`) | 47 -> 15 | 0.929 | |
| fractal hue only (per eye) | 2 x 28 -> 2 x 10 | 0.953 | |
| **all three** | about 173 -> 51 | **0.784** | **0.749** |

So the three together take the frame from about 6.5 ms to about 4.8-5.1 ms (-22 to -25%).

Parity (worst file over 10 PNGs, both eyes, incl. the transition scenario):

| pair | worst PSNR | worst max diff |
|---|---|---|
| current vs all-three prototype | 32.4 dB (mean abs 1.76 / 255) | 177 |
| current vs "truth" (same direct trig, all in float) | 32.2 dB | 169 |
| truth vs all-three prototype | 38.2 dB | 121 |

The current shader is itself 32 dB from its own float evaluation: at the top octaves the half
arguments reach 250-590, where a half step is 0.125-0.5 rad, so those octaves are quantised today.
The recurrence removes that quantisation and lands closer to the float truth than the current shader
does. It cannot pass the 50 dB exact-math rule, so it is a look change that needs eyes. Side-by-side
560 px crops at 100% (t=113 steady and the mid-transition frame) show the same structure, grain and
colour; the differences are thin lines along distortion contours.

## Round 2b ranked plan

Ranked by measured or bounded saving on the bench. Items 1-3 edit separate functions and stack
(measured together). Verdict rule as logged: interleaved A/B, more than 2% in two runs.

| # | id | item | expected (of frame) | parity |
|---|---|---|---|---|
| 1 | noise-double-angle | Sinusoidal noise: one sin/cos of `noisePos`, octaves by double-angle, second field by angle addition | -10 to -13% (measured 0.874, 0.899) | visual-equivalent |
| 2 | logsphere-double-angle | Log-spherical: same recurrence over 6 octaves; radial direction as `centered / R` instead of cos/sin(atan2) | -7% (measured 0.929) | visual-equivalent |
| 3 | fhue-double-angle-half-hsv | Fractal hue: same recurrence over 4 octaves per eye; then the float, branchy HSV round trip in half and branch-free | -5% measured (0.953) for the noise; up to -3% more from the remaining 5.7% | visual-equivalent (noise), near-exact (HSV) |
| 4 | mrt-share-eye-independent | Compute once per pixel instead of once per eye: feedback-warp turbulence (at the shared uv), bloom hash, the three vertical hue waves, ghost offsets, crossfade easing | -4 to -6% (bounds: feedback turbulence 7.5%, hue waves 7.5%, bloom 8.3%) | exact except the feedback warp (visual-equivalent) |
| 5 | per-eye-alu-half | Remaining per-eye float math: six x-dependent hue waves in half with the time phase wrapped in float; `pow(d, 0.75)` as two sqrt; turbulence rotation table as constants; one max/min shared by `restoreChroma`, `gamutFit` and vibrance | -2 to -4% | near-exact |
| 6 | bloom-ghost-mip | Mipmapped source; bloom samples a coarse level, ghost taps one level down | 0 to -1.5% on M4 (bound 1.3% for bloom); possibly more on device | visual-equivalent |
| 7 | specialise-and-skip-retest | Function constant for the saliency branch, skip previous-texture samples when `transitionProgress == 0` | 0 to -2% (bound measured 0.997, 0.981) | exact |

Stacked expectation for 1-5: about -30 to -35% of the current frame on the bench.

### Notes per item
1. **noise-double-angle**: replaces `nishitsujiNoiseFlowing` calls in `distortedUV` with the snippet
   above. Keep half; float was not needed (38 dB from truth is recurrence rounding in half; try
   float `DBL` if the PNG check finds banding, it costs little). Shared by both eyes, so the
   macOS/mono path gets it too.
2. **logsphere-double-angle**: `p` stays as built today. Guard `centered / R` for R = 0
   (`atan2(0,0)` gives angle 0, so use (1, 0)). `atan2` stays, it feeds `p.z`.
3. **fhue-double-angle-half-hsv**: two commits so each can be judged: recurrence first, then HSV.
   Do not reuse the parallax depth sample (it is taken before the parallax shift; a different texel).
4. **mrt-share-eye-independent**: only `effectsFragmentStereo` changes; pass the shared values into
   `shadeEye` (a small struct), and have `effectsFragment` compute them the old way so macOS and the
   mono fallback stay bit-identical. The feedback turbulence moves from the per-eye uv to the shared
   pre-parallax uv: the eyes' uv.x differ by at most 0.01, which changes the feedback lookup by about
   1 px, compounded through the 0.3 feedback mix. A/B it on its own before merging with the exact parts.
5. **per-eye-alu-half**: each sub-change separately through `--compare`; keep those above 50 dB.
6. **bloom-ghost-mip**: needs mipmaps in the app upload path and in the bench (`generateMipmaps`
   after upload, sampler with mip filter). Low on the Mac; listed because the round 1 note asked for a
   device re-test and because coarser bloom taps may also look better.
7. **specialise-and-skip-retest**: the round 1 items, now with a bench bound. Run one confirming A/B
   pair and log the result. Ship only if it clears 2%.

### Not planned
- **Noise from a LUT texture**: after items 1-3 the loops are about 4 trig + 1 `sin` per octave; a
  texture fetch per octave would not beat that and would change the pattern.
- **Hoisting uniform-only trig to the CPU**: with the recurrence the time-only component costs one
  sin and one cos per loop. Not worth a uniform layout change (Swift and Metal structs must match).
- **Low-res pre-passes, effects below display rate, render size below 2048²**: as before.
