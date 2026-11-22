# Vibrance decisions

Decision log for the vibrance workstream. Plan: `docs/plans/vibrance.md`. Measurements: `docs/plans/vibrance-measurements.md`.

## D1. Fix the visionOS encoding with a `bgra8Unorm` view of the `_srgb` drawable

- **Why:** the shader writes gamma-encoded values into an `_srgb` attachment, which encodes them a second time.
  RealityKit needs an `_srgb` texture that contains the un-re-encoded bytes.
- **Rejected:** a plain `bgra8Unorm` DrawableQueue. RealityKit would sample it without a decode and still treat
  the values as linear, so the result would be the same lifted image.
- **Rejected:** `_srgb` source textures (linear-light shader math). Correct, but it changes how every effect looks
  relative to macOS and invalidates the tuned constants.
- **Fallback:** decode at the end of the shader behind a uniform flag (3 MAD).
- **Open:** not confirmed on device. The plan has a gray-card check that uses the existing passthrough and
  solid-color test paths. If they already match, this decision is void.

## D2. Bind real feedback on visionOS; `feedbackMix = 0` there until it is bound

- **Why:** texture 4 is never bound, so 30% black is mixed into every frame and visionOS has no trails.
- A second color attachment (no blit, vibrance kept out of the loop) is left to the GPU workstream.

## D3. Saturation-compensated RGB blends, not OKLab mixing

- `restoreChroma(mix(a, b, t), mix(chroma(a), chroma(b), t), maxGain)` after the hue blend, the ghost-tap loop
  and the feedback mix.
- **Why:** about 25 scalar ops per blend against two cube roots and two matrices per OKLab conversion. The target
  is a convex combination of input chroma, so feedback cannot run away (300 frames measured equal to 30).
- **Gain caps:** 2.0 for the hue blend, 1.5 for taps and feedback. Floor of 0.02 on measured chroma so gray noise
  is not amplified.

## D4. Hue stage: cap the luma-restore scale instead of clamping

- **Why:** scale-then-clamp turns saturated dark hues into pastels. Capping at `1 / max channel` keeps hue and
  saturation and gives up luminance instead, which is the trade the user asked for.

## D5. Bloom: saturate the glow ×1.5 and screen it

- **Why:** the clamped add blew 1.7% of pixels to pure white (25% in the worst frame). Screen rolls off with color.
- `bloomAmount` and `bloomRadius` unchanged. If bloom needs more saturation headroom, raise 1.5 toward 1.8 first.

## D6. Vibrance stage design

- Last stage, in gamma RGB: black-point pull, then chroma gain `1 + amount * (1 - sat)`, gated off below chroma
  0.02, then `gamutFit`.
- **Defaults:** `vibranceAmount` 0.30 oscillating ±0.12 on golden-ratio frequencies; `blackPoint` 0.015.
- **Why not a bigger black point:** 0.03 crushed 4.3% of pixels (43% on the darkest image).
- **Adaptive per-image factor** is specified (CPU, once per image) but deferred. The stage already self-limits per
  pixel, and the factor is not prototyped.
- Runs inside the macOS feedback loop. Accepted because the compounding is bounded and measured stable.

## D7. No existing effect amount is reduced

- Every uniform in `EffectsUniformsComputer` keeps its current value and range. All changes are to how colors
  are combined, plus the one added stage.

## D8. Acceptance uses saturation, chroma and clipping, not a colorfulness ceiling

- **Why:** the Hasler colorfulness metric rewards hue variety, and the unfixed macOS output is already at +23%.
  An upper bound of +25% would fail any real fix. Upper limits are placed on saturation mean (+35%), p90 (+20%)
  and per-image boost (+60%) instead.
- Checked by `scripts/vibrance-check.py`. Today's output fails it in both modes; the prototype passes.

## D9. Prototype lives outside the app shader

- `tools/VibranceHarness/proto_patch.py` patches a copy of `EffectsRenderer.metal`; `scripts/vibrance-proto.sh`
  runs it. The app shader is untouched in this workstream because the shader-optimisation workstream owns it
  for now.

---

# Implementation (2026-11-14, feature/integration, on top of perf + images + orientation)

## Summary (read this first)

All of D1-D7 shipped, adapted to the current renderer (direct-to-drawable, both eyes in one MRT pass).
No effect amount was changed, and nothing was removed. The visionOS render target is still 2048x2048.

Harness (`scripts/vibrance-eval.sh` on `images-eval/round1`, 16 images x 5 times, 512², 30 warm-up
frames, both modes) then `scripts/vibrance-check.py`: **ALL PASS in both modes**. The two modes now
produce the same numbers to within 0.05, because visionOS no longer double-encodes and now has feedback.

| Full pipeline vs input (mean) | Before, macOS | Before, visionOS | **After (both modes)** | Limit |
|---|---|---|---|---|
| Saturation mean | −10.2% | −32.5% | **+26.8%** | 0 to +35 |
| Saturation p90 | −8.8% | −19.9% | **+13.0%** | −5 to +20 |
| OKLCH chroma | +24.3% | +12.9% | **+77.6%** | ≥ +20 |
| Colorfulness | +23.2% | +13.8% | **+69.5%** | ≥ +20 |
| Luminance | +15.8% | +43.6% | **+9.9%** | −5 to +15 |
| Contrast | −3.1% | −21.8% | **−11.8%** | ≥ −15 |
| Worst image, saturation | −31.4% | −57.8% | **−1.1%** | ≥ −5 |
| Most boosted image, saturation | +3.8% | n/a | **+58.2%** | ≤ +60 |
| Blown-white px, mean / worst frame | 1.73% / 25.5% | n/a | **0.05% / 1.71%** | ≤ 0.3 / ≤ 3 |
| Crushed-black px vs input | −1.6 | n/a | **−1.09 points** | ≤ +1.5 |
| Passthrough vs input | 0.0 | 90 | **0.00** | ±1% |

Marginal cost per stage (saturation / chroma). Before, bloom, feedback and hue waves all failed the −8%
limit. Now: bloom −7.5 / −3.0, hue waves −5.0 / −1.7, ghost taps −1.0 / −0.4, feedback −0.7 / +2.0,
and vibrance +13.0 / +11.9. Every other stage is ≥ 0 or within ±2.

Simulator (same real image, `-LiminalFreezeTime 37`, stereo with ML depth): mean saturation in the
screenshot went 0.11→0.35, 0.18→0.45 and 0.24→0.60. Mean luma went 0.63→0.57, 0.61→0.53 and 0.50→0.36.
Contrast (luma std) went 0.12→0.16, 0.12→0.17 and 0.12→0.13. Blown-white stayed at 0.04-0.05%.
The comparison image is `$SCRATCH/vibrance-final/compare.jpg`. Every effect is visible in both columns:
turbulence, log-sphere and fractal warps, chromatic fringing, rainbow hue waves, bloom grain and ghosting.
The "after" column also has feedback trails, which visionOS did not have before.

GPU (simulator, frozen t=100, 2 runs each, relative only): 0.135/0.141 → 0.142/0.146 ms mean per frame
(+4%, near the run-to-run noise); fps was unchanged (77.2/75.8 vs 77.3/75.3).

## V1. Output encoding: render into a `bgra8Unorm` view of the `_srgb` drawable (D1 confirmed)

- **What:** `OffscreenEffectsRenderer.renderFormat = .bgra8Unorm`. All three pipelines (mono, stereo MRT,
  passthrough) use it, and every pass targets `outputView(for: drawable.texture)`. That is a
  `makeTextureView(pixelFormat: .bgra8Unorm)` cached per drawable texture (the queue recycles a few).
  The DrawableQueue stays `bgra8Unorm_srgb`.
- **Confirmed in the simulator.** The test card (`-LiminalTestPattern -LiminalNoEffects`, stereo with flat
  depth) now has grey columns at mid-height, because the bottom strip sits under the simulator's floor
  overlay. The simulator's white level is 222/255, read from the 1.0 patch. Normalised by that:
  - **Before:** background 0.12 read 84. That is 0.87 × encode(31) = 84.6, the double encode.
    Ramp step 1/31 read 42 against a predicted 41.
  - **After (source → normalised readback):** 0.18 → 44.8 (45.9), 0.25 → 62.0 (63.8),
    0.46 → 116.0 (117.3), **0.50 → 127.5 (127.5)**, 0.735 → 186.1 (187.4), 0.75 → 190.7 (191.2),
    background 30.6 (30.6). Every patch is within 2/255; the double-encoded prediction for 0.5 was 187.5.
- **View creation works without `.pixelFormatView` usage** (sRGB-only difference). The log shows
  `Output view #n: drawable format 81 → view 80`. If it ever fails, the renderer logs an error once and
  falls back to the drawable. Not yet checked on device.
- **Rejected (unchanged from D1):** a plain `bgra8Unorm` queue, `_srgb` sources, and decoding in the
  shader. The shader decode is not needed because the view works, and it would complicate feedback,
  which would then read decoded values.
- `renderSolidColor` and `renderSimplePassthrough` blit raw bytes and were already correct.

## V2. visionOS feedback: bind each eye's previous output view; no copy and no extra texture (D2, adapted)

- **What:** `lastOutput[eye]` keeps the output view written last frame. The MRT pass binds the left eye's
  at texture 4 and the right eye's at a new **texture 6**. `effectsFragmentStereo` gained a
  `feedbackTextureRight` parameter and passes it to `shadeEye` for the right eye. The mono and single-eye
  fallback paths bind texture 4.
- **Why this over the plan's options:**
  - The plan's blit (one 2048² copy per eye per frame) would bring back exactly the cost the perf work
    removed (direct-drawable render was −48% GPU).
  - An MRT ping-pong (two extra attachments plus four 16 MB textures) adds 32 MB of writes per frame
    and 64 MB of memory.
  - Reading the previously presented drawable costs only the sample the shader already did.
  - It is also the same semantics as macOS: post-vibrance output, previous frame, same eye.
- **Safety:**
  - A pass never samples its own attachment. If the recycled drawable is the one about to be written,
    or there is no previous frame yet, `feedbackMix` is forced to 0 for that frame and a 1x1 black
    texture is bound.
  - The compositor only reads the old drawable, so read/read is fine.
  - A drawable is rewritten 2+ frames later on the same in-order queue.
- **Result:** visionOS gains trails, and the 30% black that was mixed in every frame is gone.
  The harness's visionOS mode now mirrors this. It renders through a view of an `_srgb` texture and
  feeds back the previous output view, and its numbers equal macOS mode's.
- **Watch on device:** it relies on DrawableQueue textures staying intact while queued. If trails flicker
  on device, switch to the MRT ping-pong described above.

## V3. Shader: chroma-preserving blends (D3-D5 as planned)

- Helpers `LUMA_W`, `chromaOf`, `gamutFit` and `restoreChroma` were added to `EffectsRenderer.metal`.
- **Hue:** the luma-restore scale is capped at `1/max channel` (the clamp is gone). Then
  `restoreChroma(mix, mix(chroma a, chroma b, hb), 2.0)`.
- **Ghost taps:** chroma before the loop is restored after it (gain cap 1.5). The loop and its
  0.15 weight are unchanged.
- **Bloom:** the glow is saturated ×1.5 and screened. `bloomAmount` 0.5 and `bloomRadius` 0.04 are unchanged.
  Bloom's −7.5% saturation is the tightest margin; if it needs room, raise 1.5 toward 1.8 first.
- **Feedback:** `restoreChroma` on the mix (gain cap 1.5). `feedbackMix` 0.3 and warp 0.03 are unchanged.

## V4. VIBRANCE stage (D6 as planned)

- This is the last stage of `shadeEye`, so it runs for both eyes and both platforms.
- The order is: black-point pull, then `g = 1 + amount·(1−sat)·smoothstep(0.02, 0.10, chroma)`,
  then `gamutFit`. That makes it luminance-preserving, it favours under-saturated pixels, it leaves greys
  alone, and it cannot clip.
- Two uniforms, `vibranceAmount` and `blackPoint`, were appended to the end of both structs. In Swift
  they default to 0, so the debug and dummy initialisers did not change. A zero-filled uniform buffer
  turns the stage off.
- `EffectsUniformsComputer.computeVibrance` gives `(0.30 + 0.12·wave)·imageFactor`, where `wave` runs
  on golden-ratio frequencies 0.023·φ and 0.041/φ, about 3-4 minute swells. `baseBlackPoint` is 0.015.

## V5. Adaptive per-image factor: shipped (it was cheap)

- `Liminal/Visual/ImageColorStats.swift` measures mean HSV saturation `s` and luma `y` on a 32x32 downsample.
  That runs once per image object, on the CPU, cached by identity, and costs about 0.1 ms.
  - `amount = clamp(1.3 − s, 0.5, 1.1)`
  - `dark = clamp(y / 0.30, 0.3, 1.0)`, which scales the black point
- During a crossfade, the previous and new factors are lerped by transition progress on both platforms
  (`ImmersiveDomeView` and `ContentView`). Both platforms measure the 3:2 cover-cropped frame.
- The harness applies the same factors. With them, the most-boosted image reaches +58.2% (limit 60).
  That is the muted cave image, which gets factor ~1.1. If that ever reads as garish, lower the 1.1 cap
  to 1.0 first.
- **Rejected:** computing the stats on the GPU (a reduction pass per image is more code for no gain),
  and a per-frame histogram (not needed, because the stage already self-limits per pixel).

## V6. Harness kept in lockstep

- `tools/VibranceHarness/main.swift`:
  - visionOS mode renders into a `bgra8Unorm` view of a `bgra8Unorm_srgb` target, with real feedback.
  - Both modes warm up 30 frames.
  - Per-image vibrance factors are applied.
  - New `vibrance` stage for knock-out and solo runs.
- `scripts/vibrance-eval.sh` also compiles `ImageColorStats.swift`.
- macOS mode still does not apply ContentView's `hueBaseShift = t·0.03`, same as before, so the
  numbers stay comparable with the baseline.

## V7. Test tooling (DEBUG only)

- **Test card:** grey columns at mid-height (left 0.18 / 0.46 / 0.50 / 0.735, right 0 / 0.25 / 0.75 / 1.0),
  readable in simulator screenshots.
- **`-LiminalTestImage <path>`:** shows one fixed image file, for before/after
  captures. The simulator can read host paths. The sandboxed macOS app cannot read `/private/tmp`, so
  use `-LiminalTestPattern` there.

## V8. Not done / open

- Device check: the encoding and the feedback binding are verified in the simulator only.
- Crossfade midpoint saturation, banding and 300-frame stability checks (plan, "Not automated yet").
  `restoreChroma` was measured stable at 300 frames in the prototype.
- Frozen-time captures exaggerate feedback smearing, because the warp compounds on an unchanging frame.
  This is the same behaviour macOS always had. Live, the trails move.
