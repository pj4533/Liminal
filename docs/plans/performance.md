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
