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
- **MetalFX / rendering below 2048²**: violates the resolution constraint.
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
- **MetalFX or any render size below 2048²**: violates the resolution requirement.

### Verdict rule for this round
Compare candidate and reference **in the same session, interleaved** (A B A B A B), never against
a number from an earlier session. For shader items use the item 1 benchmark as the GPU number and
its PNG diff as the parity check; use `perf-run.sh` for errors, the 2048² log line and pacing.
