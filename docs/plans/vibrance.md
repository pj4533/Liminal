# Vibrance fix plan: keep every effect, restore the color

Status: **implemented** (see `docs/decisions/vibrance.md`, V1-V9, for what shipped, how the renderer-level
fixes were adapted to the direct-to-drawable MRT renderer, and the final numbers). Originally: no app shader
or renderer code was changed by this document. The numbers come from
`scripts/vibrance-eval.sh` (baseline, see `vibrance-measurements.md`) and from a prototype of the shader
changes below, applied to a *copy* of the shader by `scripts/vibrance-proto.sh` and measured with the same
harness (16 images × 5 times, 512², macOS mode with a 30-frame feedback loop).

## Summary

The washed-out look has five causes. Two are renderer bugs on visionOS, three are in the shader math.

| # | Cause | Where | Measured cost |
|---|---|---|---|
| 1 | Output is sRGB-encoded twice | visionOS renderer | passthrough: luminance +51%, saturation −33%, contrast −14% |
| 2 | Feedback slot is unbound, so 30% black is mixed in every frame | visionOS renderer | −11% luminance, chroma and contrast |
| 3 | Hue stage: luma-restore scale followed by a hard clamp, then an RGB mix of two different hues | shader stage 3 | −13% saturation, −13% chroma |
| 4 | Bloom is a clamped add of a brightness-weighted sample | shader stage 5 | −9% saturation, +14% luminance, 1.7% of pixels blown to white (25% in the worst frame) |
| 5 | Ghost taps and feedback average differently-colored pixels in RGB | shader stages 4 and 6 | taps −6% saturation, feedback −11% saturation |

With the shader fixes plus the new vibrance stage, the prototype measures as follows (full pipeline vs input,
mean over 80 frames):

| | Colorfulness | Saturation | Sat p90 | OKLCH chroma | Luminance | Contrast | Blown white |
|---|---|---|---|---|---|---|---|
| Today (macOS) | +23% | −10% | −9% | +24% | +16% | −3% | 1.73% |
| Today (visionOS) | +14% | −33% | −20% | +13% | +44% | −22% | n/a |
| Stage fixes only | +52% | +12% | +3% | +59% | +11% | −13% | 0.03% |
| Stage fixes + vibrance 0.30, black point 0.015 | +71% | +27% | +12% | +79% | +8% | −9% | 0.02% |

The worst image goes from −31% saturation to −1%. No stage costs more than 7% saturation or 2.5% chroma.
All effects stay on with their current amounts and motion; I compared sheets at t=113 and t=611 and the
warps, rainbow waves, trails, ghosts and glow are all still there, with deeper color and no white-out.

Once fixes 1 and 2 land, visionOS produces the same bytes as the macOS mode of the harness, so the last row
is the expected headset result too. That equivalence is an inference from the formats, not a device
measurement (see "On-device check").

## Diagnosis

Things checked and cleared:

- **RealityKit material.** Both paths are unlit with tone mapping off: `UnlitMaterial(applyPostProcessToneMap: false)`
  for mono and `unlitSurface(applyPostProcessToneMap: false)` in `StereoMaterialBuilder`. No lit shading, no tint
  on the real material (the red tint is on a hidden placeholder only).
- **Alpha.** The shader returns alpha 1 and blending is off. Sources are opaque, so premultiplication is a no-op.
- **macOS.** `MTKView` is `bgra8Unorm`, textures load with `.SRGB: false`. Passthrough is bit-exact (0.0% on every metric).
- **Geometric stages** (Ken Burns, turbulence, log-sphere, fractal noise): within ±3%. The −7% saturation shown
  for Ken Burns is reframing (a different crop), not color loss.
- **Chromatic aberration, contrast/saturation boost, fractal hue**: these add color (+6%, +8%, +12% saturation).
- **`DreamyEffects.metal`** is the SwiftUI `ShaderLibrary` path (`VisualEffects.swift`), not the image pipeline.
  **`DomeCompute.metal`** is a vertex-displacement kernel. Neither touches color here.
- **Crossfade.** It mixes two images in gamma RGB, which desaturates mid-transition. The harness renders at
  `transitionProgress` 0, so this is unmeasured. It is transient and is covered by the final vibrance stage.

### 1. visionOS double sRGB encode

Source textures are `bgra8Unorm` holding sRGB bytes, so the shader works on gamma-encoded values `v`. The
render target is the `bgra8Unorm_srgb` drawable, so Metal applies linear→sRGB on store and the texture holds
`encode(v)`. RealityKit samples an `_srgb` texture with a decode, gets `v`, treats it as linear light, and the
compositor encodes it for the display. The viewer sees `encode(v)`: mid-gray 128 shows as 188.

The comments in `OffscreenEffectsRenderer.swift` and `PLATFORM_ARCHITECTURE.md` ("auto-applies gamma encoding
on write to match macOS") describe the opposite of what happens. macOS writes `v` unchanged.

Switching the DrawableQueue to plain `bgra8Unorm` would probably **not** fix it: the texture would hold `v`,
RealityKit would sample `v` with no decode and still treat it as linear, and the viewer would still see
`encode(v)`. The texture RealityKit samples must be `_srgb` and must contain the bytes `v`.

### 2. visionOS feedback reads black

`OffscreenEffectsRenderer` never binds texture index 4, and `feedbackMix` is 0.3. Every frame is
`mix(color, 0, 0.3)`. There are also no trails on visionOS at all, so an effect is missing there today.

### 3. Hue stage

Two separate losses:

- `colorBlended = shiftedRgb * (originalLuma / shiftedLuma)` followed by `clamp(0, 1)`. When a bright hue is
  rotated to a dark one (yellow → blue), the scale is far above 1. The largest channel clamps at 1 while the
  two smaller channels keep growing: (0.2, 0.2, 1.0) × 3 → (0.6, 0.6, 1.0). Saturation drops from 0.8 to 0.4.
- `mix(color.rgb, saturated, hueBlendAmount)`. The spatial hue offset reaches several full turns, so the two
  colors being mixed often have opposite hues, and an RGB mix of opposite hues passes through gray. With
  `hueBlendAmount` averaging 0.4, this is the largest single shader loss.

### 4. Bloom

`currentColor += bloomSample * brightness * 0.5`, then clamp. On bright areas all three channels reach 1, so
highlights go flat white (the mushroom cave floor). The single random sample per pixel also shows as grain.

### 5. Ghost taps and feedback

Each tap mixes 15% of the *unprocessed* source at an offset. Up to eight taps stack, so as much as half of the
pixel can be replaced by raw, differently-hued source. Feedback mixes 30% of a warped earlier frame. Both are
plain RGB averages of pixels with different hues, which lowers chroma. Feedback also costs 12% contrast, which
is the blur of the trails themselves and is left alone.

## Fixes

Priority order. P0 items are renderer bugs and need no shader change. P1 items are the shader changes that
were prototyped. Uniform amounts for every existing effect stay exactly as they are.

### P0-a. visionOS output encoding (GPU cost: zero)

Keep the DrawableQueue as `bgra8Unorm_srgb`. Render into a `bgra8Unorm` **view** of the drawable texture:

```swift
let target = drawable.texture.makeTextureView(pixelFormat: .bgra8Unorm)   // cache per underlying texture
renderPassDescriptor.colorAttachments[0].texture = target
// pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm   (both pipelines, mono and stereo paths)
```

The bytes written are `v`. RealityKit samples through the `_srgb` format, decodes to linear, and the display
shows `v`, the same as macOS. Metal allows a view that differs only in sRGB-ness without
`MTLTextureUsage.pixelFormatView`; if the DrawableQueue texture refuses the view on device, use the fallback.

Fallback (3 multiply-adds per pixel): keep the `_srgb` attachment and decode at the very end of the shader
behind a new uniform flag, `c = c * (c * (c * 0.305306h + 0.682171h) + 0.012523h)`. The store re-encodes it to `v`.

Not recommended: making the source textures `_srgb` so the shader runs in linear light. It fixes passthrough but
changes how every effect looks compared with macOS (contrast pivot, bloom weighting, mixes), and the constants
below were tuned on gamma values.

Also update the two misleading comments and the "Color Space Handling" section of `PLATFORM_ARCHITECTURE.md`,
and change the harness's visionos mode to mirror the new target so it keeps measuring what ships.

### P0-b. visionOS feedback (GPU cost: one 2048² blit per eye per frame, or zero with MRT)

Bind a real previous-frame texture at index 4, one per eye in stereo, `bgra8Unorm`, zero-initialised, copied
from the drawable after the render pass exactly as `EffectsMetalView` does. Until that lands, set
`feedbackMix = 0` in the visionOS uniforms so no black is mixed in. That stop-gap is one line.

The fragment shader already pays for the feedback sample today; it just reads zero. The new cost is the blit
(about 16 MB per eye). An alternative with no blit is a second color attachment that writes the feedback
texture directly (ping-pong two textures). That would also keep the vibrance stage out of the feedback loop.
It is more plumbing, so treat it as an optimisation for the GPU workstream, not part of this fix.

### P1 shared helpers (EffectsRenderer.metal)

```metal
constant half3 LUMA_W = half3(0.299h, 0.587h, 0.114h);

static inline half chromaOf(half3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

// Scale chroma about luma so every channel lands in [0,1]. Hue and luma are unchanged.
static inline half3 gamutFit(half3 c, half l) {
    half hi = max(c.r, max(c.g, c.b));
    half lo = min(c.r, min(c.g, c.b));
    half k = min(1.0h, min((1.0h - l) / max(hi - l, 1.0e-4h), l / max(l - lo, 1.0e-4h)));
    return l + (c - l) * k;
}

// Raise chroma toward `target` (never lower it), luma-preserving and gamut-safe.
static inline half3 restoreChroma(half3 c, half target, half maxGain) {
    half l = dot(c, LUMA_W);
    half g = clamp(target / max(chromaOf(c), 0.02h), 1.0h, maxGain);
    return gamutFit(l + (c - l) * g, l);
}
```

`restoreChroma` is the saturation-compensated blend: after any RGB mix of `a` and `b` by `t`, the target is
`mix(chromaOf(a), chromaOf(b), t)`. The target is a convex combination of the inputs' chroma, so the result is
never more saturated than its inputs and the feedback loop cannot run away. The `0.02` floor and `maxGain` stop
it amplifying noise in near-gray pixels. I chose this over OKLab mixing because OKLab needs two cube roots and
two 3×3 matrices per conversion, per blend; this costs about 25 scalar ops and measured well.

### P1-a. Hue stage (about +35 ALU ops)

Limit the luma-restore scale so the largest channel stops at 1, instead of clamping afterwards:

```metal
half shiftedMax = max(shiftedRgb.r, max(shiftedRgb.g, shiftedRgb.b));
half3 colorBlended = shiftedRgb * min(originalLuma / max(shiftedLuma, 0.001h),
                                      1.0h / max(shiftedMax, 0.001h));
// the clamp(colorBlended, 0, 1) line is no longer needed
```

A hue rotated from bright to dark now becomes a deep, fully saturated color instead of a pastel one.

Then compensate the blend with the original:

```metal
half hb = half(uniforms.hueBlendAmount);
half3 currentColor = mix(color.rgb, saturated, hb);
currentColor = restoreChroma(currentColor, mix(chromaOf(color.rgb), chromaOf(saturated), hb), 2.0h);
```

Unchanged: the wave shapes and amplitudes, the 1.4–1.6 HSV saturation gain, `contrastBoost` 1.4,
`saturationBoost` 1.3, `hueBlend = colorCycle * 0.8`. Measured marginal cost of the hue waves goes from
−13.3% saturation / −13.4% chroma to −4.6% / −0.8%.

### P1-b. Ghost taps (about +30 ALU ops, once per pixel, only when taps are active)

Leave the loop and the 0.15 weight alone. Record chroma before the loop and restore after it:

```metal
half preTapChroma = chromaOf(currentColor);
for (...) { ... }                         // unchanged
if (tapCount > 0) { currentColor = restoreChroma(currentColor, preTapChroma, 1.5h); }
```

The ghosts keep their shape (luma is untouched) and take on the processed color. Marginal cost goes from
−5.8% saturation / −7.1% chroma to −0.6% / −0.4%.

### P1-c. Bloom (about +8 ALU ops, removes one clamp)

Saturate the glow by 1.5 about its own luma and screen it instead of adding it:

```metal
half3 glow = bloomSample * brightness * half(uniforms.bloomAmount);
half glowL = dot(glow, LUMA_W);
glow = clamp(glowL + (glow - glowL) * 1.5h, 0.0h, 1.0h);
currentColor = 1.0h - (1.0h - currentColor) * (1.0h - glow);
```

Screen cannot exceed 1, so highlights roll off with their color instead of clipping to white. `bloomAmount`
stays 0.5 and `bloomRadius` 0.04. Blown-white pixels drop from 1.73% to 0.03% (worst frame 25% → 1.3%).
Bloom's luminance lift drops from +14% to +8%, and its saturation cost from −8.9% to −7.0%. This is the
tightest margin against the 8% limit. If it needs more room, raise the 1.5 to 1.8 before touching `bloomAmount`.
The grain is a property of single-sample bloom. It is partly averaged out by feedback, which visionOS will
gain from P0-b.

### P1-d. Feedback (about +30 ALU ops)

```metal
half fm = half(uniforms.feedbackMix);
half fbTarget = mix(chromaOf(currentColor), chromaOf(feedbackColor), fm);
currentColor = restoreChroma(mix(currentColor, feedbackColor, fm), fbTarget, 1.5h);
```

`feedbackMix` stays 0.3 and `feedbackWarpAmount` 0.03, so the trails are as long and as warped as today.
Marginal cost goes from −10.9% saturation / −8.8% chroma to −0.6% / +2.0%. The 12% contrast cost stays,
because that is the trail blur.

### P1-e. New VIBRANCE stage (about 30 ALU ops, no samples, no branches, no extra pass)

Last thing in `effectsFragment`, after feedback, before the return:

```metal
// === 7. VIBRANCE ===
half bp = half(uniforms.blackPoint);
half3 c = max((currentColor - bp) / (1.0h - bp), 0.0h);          // black-point pull-down
half l  = dot(c, LUMA_W);
half mx = max(c.r, max(c.g, c.b));
half ch = mx - min(c.r, min(c.g, c.b));
half sat = ch / max(mx, 1.0e-3h);
half g = 1.0h + half(uniforms.vibranceAmount) * (1.0h - sat)      // weighted toward under-saturated pixels
              * smoothstep(0.02h, 0.10h, ch);                    // leave true grays and noise alone
currentColor = gamutFit(l + (c - l) * g, l);                      // luma-preserving, gamut-safe
```

Properties:

- The gain tapers to 1 as saturation approaches 1, so already-vivid pixels are not pushed further. That taper is
  the soft knee; `gamutFit` is the hard guarantee that no channel leaves [0,1] and that hue and luma hold.
- Near-neutral pixels (chroma under 0.02) get no gain, so gray stays gray and bloom grain is not colorized.
- It runs inside the feedback loop on macOS (the drawable is what gets copied). The compounding is geometric
  with ratio 0.3 and bounded by the taper. Measured: 300 warm-up frames give the same result as 30 (saturation
  +21.4% vs +21.5%, no clipping change).

Two new uniforms, appended to the end of `EffectsUniforms` in both `EffectsUniforms.swift` and the Metal struct
(order must match): `vibranceAmount`, `blackPoint`. The passthrough/dummy uniform initialisers need the two
fields as well (0, 0).

`EffectsUniformsComputer`:

```swift
/// Slow, non-repeating swell so color intensity breathes with the rest of the piece.
static func computeVibrance(time: Float, imageFactor: Float = 1) -> Float {
    let phi: Float = 1.618034
    let wave = (sin(time * 0.023 * phi) + sin(time * 0.041 / phi) * 0.6) / 1.6   // -1..1
    return (0.30 + 0.12 * wave) * imageFactor                                     // 0.18..0.42 at factor 1
}
// blackPoint: 0.015 * darkFactor
```

- Prototype numbers above use a constant 0.30 and black point 0.015. The range was checked at 0.20 and 0.50:
  saturation +27% and +37% with black point 0.03–0.04, no blown whites at either end.
- `imageFactor` (adaptive, CPU, once per image, zero GPU cost): compute mean HSV saturation `s` and mean luma
  `y` on a 32×32 downsample where saliency/depth are already prepared.
  `imageFactor = clamp(1.3 - s, 0.5, 1.1)` and `darkFactor = clamp(y / 0.30, 0.3, 1.0)`. During a crossfade,
  lerp both between the previous and new image with `transitionProgress`. The stage is already self-limiting per
  pixel, so ship the oscillating version first and add `imageFactor` only if muted or neon images still look
  off. It is not prototyped.
- `darkFactor` matters: a black point of 0.03 raised crushed-black pixels from 1% to 4.3% (43% on the darkest
  image). At 0.015 it is 2.9% against 2.5% in the inputs.

### GPU cost summary

| Change | Cost |
|---|---|
| P0-a output view | none |
| P0-a fallback (decode in shader) | 3 MAD |
| P0-b feedback bind on visionOS | 1 blit per eye per frame (or none with MRT) |
| P1-a hue | ~35 ALU |
| P1-b ghost taps | ~30 ALU, only when taps are active |
| P1-c bloom | ~8 ALU, minus one clamp |
| P1-d feedback | ~30 ALU |
| P1-e vibrance | ~30 ALU |

About 130 scalar ops per pixel in total, with no texture samples, loops, branches or passes added. The ALU
counts are estimates from reading the code, not profiler numbers; the GPU workstream's bench should confirm
them. For scale, the shader already runs about 30 octaves of trig noise and 16+ texture samples per pixel.
If the bench wants it cheaper: P1-d and P1-e can share one `gamutFit` (multiply the two gains first), and
`chromaOf(color.rgb)` in P1-a can reuse `d` from the existing RGB→HSV conversion.

## Acceptance criteria

Automated, with `scripts/vibrance-eval.sh <in> <out>` followed by `python3 -I scripts/vibrance-check.py <out>`
(exits non-zero on failure). On the 16 `images-eval/round1` images, both modes:

| Check | Limit | Today macOS | Today visionOS | Prototype |
|---|---|---|---|---|
| Passthrough vs input, any metric, any image | within ±1% | 0.0 | 90 | 0.0 |
| Full: saturation mean | 0% to +35% | −10.2 | −32.5 | +27.0 |
| Full: saturation p90 | −5% to +20% | −8.8 | −19.9 | +12.3 |
| Full: OKLCH chroma | ≥ +20% | +24.3 | +12.9 | +79.2 |
| Full: colorfulness | ≥ +20% | +23.2 | +13.8 | +71.1 |
| Full: luminance | −5% to +15% | +15.8 | +43.6 | +7.6 |
| Full: contrast | ≥ −15% | −3.1 | −21.8 | −9.1 |
| Worst image, saturation | ≥ −5% | −31.4 | −57.8 | −1.1 |
| Most boosted image, saturation | ≤ +60% | +3.8 | n/a | +53.0 |
| Each stage, marginal saturation and chroma | ≥ −8% | fails: bloom, feedback, hue waves | fails: bloom, feedback, taps, hue waves | worst −7.0 (bloom) |
| Blown-white pixels, mean / worst frame | ≤ 0.3% / ≤ 3% | 1.73 / 25.5 | n/a | 0.02 / 1.33 |
| Crushed-black pixels above input | ≤ +1.5 points | −1.6 | n/a | +0.35 |

The original suggestion of colorfulness within −10% to +25% does not fit this pipeline: the Hasler metric rewards
hue variety, and the rainbow effects already put the unfixed macOS output at +23%. Saturation, chroma and the
clipping checks are the measures that track the washed-out look, with the upper limits on saturation mean, p90
and per-image boost guarding against a garish result.

Not automated yet, to add with the implementation:

- **Banding.** Render a synthetic smooth ramp (hue sweep × luma ramp) with only the vibrance stage on. Adjacent
  pixels must not differ by more than 3/255 and the ramp must stay monotonic.
- **Feedback stability.** `--warmup 300` must match `--warmup 30` within 2% on every metric.
- **Transition.** Add a `transitionProgress = 0.5` render to the harness and require saturation within 10% of
  the two endpoint frames.
- **GPU.** Fragment time within +3% of the pre-change shader on the GPU workstream's bench.
- **Look.** Side-by-side sheets for all 16 images at two times, reviewed by eye: every effect visibly present.

### On-device check for P0-a

This is the one finding that rests on how RealityKit samples the drawable, which I could not observe (the
simulator was off-limits for this workstream). The renderer already has what is needed to confirm it:

1. Show a 50% gray image (bytes 128) through `renderPassthrough` (render path, encodes on store).
2. Show the same gray through the solid-color test path, which blits `bgra8Unorm` bytes into the drawable (no encode).
3. If the two differ in brightness, the double encode is confirmed and step 2 is the correct one. A capture should
   read about 128 for step 2 and about 188 for step 1.
4. After P0-a, both read about 128 (±6).

If the two already match on device, P0-a is void: skip it and tell the harness's visionos mode to use
`bgra8Unorm`. The P0-b and P1 work stands either way, since macOS shows the same shader losses.

## Reproducing the prototype

```
# baseline through the same script
scripts/vibrance-proto.sh <in> <out> -DFIX_HUE=0 -DFIX_TAPS=0 -DFIX_BLOOM=0 -DFIX_FB=0 -DVIB=0.0h -DBP=0.0h
# stage fixes only
scripts/vibrance-proto.sh <in> <out> -DVIB=0.0h -DBP=0.0h
# recommended
scripts/vibrance-proto.sh <in> <out> -DVIB=0.3h -DBP=0.015h
```

`tools/VibranceHarness/proto_patch.py` holds the exact shader edits above, applied to a copy in `<out>/.src`.
The baseline run reproduces the committed measurements to within 0.1%.

## Implementation order

1. P0-b stop-gap (`feedbackMix = 0` on visionOS) and the P0-a device check.
2. P0-a view (or fallback), update harness visionos mode, re-run: passthrough must be lossless.
3. P1-a to P1-d in the shader, coordinated with the shader-optimisation workstream since they touch the same file.
4. P1-e uniforms + stage + `computeVibrance`.
5. P0-b real feedback texture on visionOS.
6. Banding/stability/transition checks, then `imageFactor` if still wanted.
