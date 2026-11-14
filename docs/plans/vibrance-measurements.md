# Vibrance measurements: color loss in the effect pipeline

Status: measurement only. This doc changes no shader logic. Fixes are proposed below and will be applied later.

## How to re-run

```
scripts/vibrance-eval.sh <input-dir> <out-dir>
# e.g. LIMINAL_METALLIB=<DerivedData>/.../Liminal.app/Contents/Resources/default.metallib scripts/vibrance-eval.sh imgs out
```

- `tools/VibranceHarness/main.swift` is a small Swift CLI. It is compiled together with the app's real
  `EffectsUniforms.swift`, `EffectsUniformsComputer.swift`, `SmoothOscillator.swift` and `GhostTapManager.swift`,
  and it loads the compiled EffectsRenderer metallib. By default it compiles `Liminal/Shaders/*.metal` from the
  working tree. Set `LIMINAL_METALLIB` to use the app bundle's library instead. Both gave bit-identical output
  on tap-free variants. Only GhostTapManager's `Float.random` direction jitter differs between runs.
- **visionos mode** mirrors `OffscreenEffectsRenderer`:
  - the source is a `bgra8Unorm` texture filled from an sRGB CGContext, stretched to a square;
  - the render target is `bgra8Unorm_srgb`;
  - texture index 4 (feedback) is never bound, so the harness binds a 1x1 black texture to emulate the
    zero read from an unbound texture;
  - saliency is 1x1 gray, depth is a flat 0.5, mono (stereoOffset 0), transitionProgress 0, delay 0.5.
- **macos mode** mirrors `EffectsMetalView`: a `bgra8Unorm` target and a real feedback ping-pong over 30 warm-up
  frames at 60 fps leading into t.
- Times t ∈ {0, 37, 113, 260, 611}. Renders are 512².
- Each stage is neutralized through its uniform:
  - `ko:X` = full pipeline vs the full pipeline with X off (X's marginal effect);
  - `solo:X` = only X on vs all-off.
- `colorblock` = hueBlendAmount 0. It removes the whole hue-wave + HSV-sat + contrast/sat block.
- Metrics come from `scripts/colorfulness.py`. They are computed on the PNG bytes read as sRGB, which is what the
  display shows:
  - Hasler–Süsstrunk M;
  - HSV saturation mean and p90;
  - OKLCH chroma;
  - OKLab L mean (lum) and std (contrast).
- Inputs: 16 colorful photoreal images (`images-eval/round1/00..15.jpg`).

## Key findings

1. **visionOS has a double sRGB encode. This is the main cause of the "washed out" look.** Source textures are
   `bgra8Unorm` holding sRGB-encoded bytes, so the shader works on gamma-encoded values. Its output is written to
   `bgra8Unorm_srgb`, which applies linear→sRGB *again* on store. With effects completely off (passthrough), compared
   with the input:
   - **lum +51%** (range +16..+90);
   - **HSV saturation −33%** (p90 −21%);
   - **contrast −14%**.

   Blacks lift to gray and every color turns pastel. OKLCH chroma barely moves (+3%) because the colors get lighter
   rather than greyer. That pastel shift is exactly the "bland" look. macOS passthrough is lossless (0.0% on every
   metric). The likely fix is to write to `bgra8Unorm` (or make the source `_srgb` so the math runs in linear).
   This needs on-device confirmation of how the RealityKit unlit + `.raw` path samples an `_srgb` drawable. If it
   decodes on sample, which is standard, the headset shows the lifted bytes.
2. **Feedback reads black on visionOS.** `OffscreenEffectsRenderer` never binds texture 4, yet `feedbackMix` is 0.3,
   so every frame is mixed 30% toward black: −14% M and −11% lum/chroma/contrast, the same on every image. On macOS
   the real feedback costs −14.5% M, −11% sat and −13% contrast, because blurry warped trails average the colors
   together.
3. **Bloom washes toward white.** Bloom adds `sample * luma * 0.5` with no saturation preservation:
   - −12% sat and +7% lum on visionOS;
   - −9% sat and +14% lum on macOS.

   It also adds visible per-pixel grain.
4. **Ghost taps** blend the *unprocessed* source back in at 15% per tap: −8 to −13% M and −6 to −12% sat.
5. **Spatial hue waves (`hueshift`)** cost −14% M, −13 to −15% sat and −14% chroma as a marginal effect. The
   HSV→RGB step, the luma-preserving rescale and the clamp lose saturation on strongly rotated hues.
6. **Stages that add color:**
   - fractal hue: +14 to +22% M;
   - chromatic aberration: +7 to +11% M;
   - contrast/sat boost: +8% M.

   The geometric warps (turbulence, logsphere, fractal noise, Ken Burns) are roughly neutral (±3%).
7. The full pipeline's Hasler M looks *up* (+14% visionOS, +23% macOS) because fractal hue and the hue waves add
   hue variety. Saturation and contrast tell the real story. On visionOS, full vs input:
   - **sat −33%**;
   - **lum +44%**;
   - **contrast −22%**.

   Viewing the sheets confirms this. Deep reds and blacks, for example the pomegranate (12) and the mushroom
   cave (07), turn milky pink and gray.

## Proposed fixes (for the later fix pass, keeping every effect)

- Fix the visionOS output encoding (finding 1). This alone recovers about +33% saturation and removes the lift.
- Bind a real feedback ping-pong on visionOS, like macOS, or set feedbackMix to 0 there until it is bound.
- Make bloom saturation-preserving: tint the add by the hue of the current color, or add in luma and then restore chroma.
- Sample ghost taps from the processed color path, or apply a saturation compensation to the tap color.
- Add a final "vibrance" stage: a saturation boost weighted toward low-saturation pixels plus a slight black-point
  pull-down. Use the harness metrics as the target: sat_mean and contrast at or above the input.

## Comparison sheets

Each sheet `<out-dir>/sheets/NN.jpg` shows: input | visionOS full at t=0, 113, 611 | macOS full t=113 | worst solo stage.

## Results (mean % change, min..max across 16 images × 5 times)

### visionos

| comparison | colorfulness | sat_mean | sat_p90 | chroma | lum | contrast |
|---|---|---|---|---|---|---|
| passthrough vs input | +0.0 (-38..+35) | -32.9 (-51..-12) | -21.3 (-49..+0) | +2.7 (-41..+48) | +51.2 (+16..+90) | -14.1 (-39..+10) |
| all-off vs input | +0.0 (-38..+35) | -32.9 (-51..-12) | -21.3 (-49..+0) | +2.7 (-41..+48) | +51.2 (+16..+90) | -14.1 (-39..+10) |
| FULL vs input | +13.8 (-46..+149) | -32.5 (-64..-9) | -19.9 (-55..+18) | +12.9 (-58..+97) | +43.6 (+9..+88) | -21.8 (-55..+20) |
| ko:bloom | -7.3 (-25..+2) | -12.1 (-39..-3) | -9.3 (-36..+0) | -8.6 (-34..-0) | +6.8 (+3..+10) | +7.6 (-13..+13) |
| ko:chromatic | +10.6 (-0..+49) | +6.6 (-0..+25) | +5.7 (-1..+34) | +8.9 (+0..+31) | +0.1 (-0..+2) | -0.9 (-4..+0) |
| ko:colorblock | +0.5 (-33..+27) | -1.8 (-31..+9) | -1.2 (-39..+19) | +1.4 (-19..+20) | -1.8 (-8..+0) | +4.9 (-1..+22) |
| ko:contrastsat | +7.7 (-1..+29) | +11.0 (-1..+43) | +8.3 (-2..+81) | +9.6 (-2..+31) | -1.6 (-7..-0) | +4.2 (+0..+11) |
| ko:feedback | -13.9 (-15..-14) | +1.5 (+1..+3) | +1.5 (-0..+6) | -11.2 (-11..-11) | -11.2 (-11..-11) | -11.2 (-11..-11) |
| ko:fractalhue | +22.3 (-0..+68) | +17.6 (+2..+38) | +18.8 (+1..+51) | +19.6 (+5..+48) | -1.4 (-8..+2) | +0.5 (-6..+20) |
| ko:fractalnoise | -0.2 (-6..+4) | +0.2 (-4..+6) | -0.1 (-4..+6) | -0.0 (-4..+4) | -0.2 (-3..+2) | -0.2 (-5..+3) |
| ko:ghosttaps | -13.3 (-24..+0) | -11.5 (-23..+0) | -12.7 (-25..+0) | -10.7 (-19..+0) | +1.4 (+0..+6) | -4.4 (-12..+0) |
| ko:hueshift | -13.9 (-42..+3) | -14.5 (-43..+0) | -8.0 (-41..+3) | -13.9 (-42..+0) | -0.1 (-6..+4) | +0.7 (-7..+17) |
| ko:kenburns | +1.3 (-14..+17) | -6.4 (-28..+14) | -5.2 (-28..+9) | +0.6 (-17..+16) | +5.0 (-4..+19) | -2.5 (-24..+16) |
| ko:logsphere | -1.2 (-6..+5) | +1.4 (-6..+14) | +1.1 (-8..+22) | -0.5 (-5..+8) | -1.2 (-6..+2) | +0.4 (-9..+7) |
| ko:turbulence | +0.0 (-4..+4) | +0.5 (-5..+6) | +0.3 (-6..+6) | +0.4 (-5..+5) | -0.2 (-3..+2) | -0.2 (-4..+5) |
| solo:bloom | -2.9 (-18..+2) | -9.7 (-38..-1) | -7.4 (-22..+0) | -4.1 (-32..+1) | +6.2 (+3..+8) | +5.9 (-12..+11) |
| solo:chromatic | +23.6 (+0..+81) | +8.9 (+0..+30) | +7.4 (-4..+43) | +16.2 (+1..+55) | +0.4 (-0..+2) | -2.7 (-6..-0) |
| solo:contrastsat | +22.5 (+1..+67) | +18.1 (+1..+52) | +8.3 (+0..+72) | +23.1 (+1..+61) | -2.8 (-10..+0) | +7.1 (+1..+16) |
| solo:feedback | -14.0 (-15..-14) | +1.8 (+1..+3) | +2.0 (+0..+4) | -11.2 (-11..-11) | -11.2 (-11..-11) | -11.2 (-11..-11) |
| solo:fractalhue | +42.3 (+11..+140) | +27.9 (+10..+55) | +31.8 (+0..+88) | +32.2 (+8..+95) | -2.3 (-10..+5) | +0.9 (-14..+36) |
| solo:fractalnoise | -2.5 (-11..+2) | -2.3 (-10..+1) | -3.1 (-13..+1) | -1.4 (-8..+1) | +0.3 (-1..+2) | -2.0 (-7..+1) |
| solo:ghosttaps | -6.5 (-16..+0) | -6.3 (-16..+0) | -7.7 (-18..+0) | -3.8 (-9..+0) | +0.9 (+0..+5) | -5.4 (-11..+0) |
| solo:hueshift | -1.9 (-36..+70) | -12.8 (-42..+5) | -8.2 (-50..+14) | -5.6 (-29..+11) | -0.2 (-1..+0) | -0.2 (-3..+2) |
| solo:kenburns | +0.3 (-14..+18) | -7.5 (-30..+9) | -7.4 (-34..+5) | -1.1 (-23..+13) | +4.8 (-4..+17) | -4.3 (-24..+17) |
| solo:logsphere | -4.0 (-9..-1) | -1.4 (-7..+6) | -2.3 (-9..+6) | -2.0 (-7..+3) | -0.8 (-4..+2) | -1.6 (-11..+5) |
| solo:turbulence | -2.6 (-7..+2) | -2.2 (-7..+3) | -3.0 (-9..+1) | -1.5 (-6..+3) | +0.1 (-2..+3) | -1.7 (-7..+3) |

### macos

| comparison | colorfulness | sat_mean | sat_p90 | chroma | lum | contrast |
|---|---|---|---|---|---|---|
| passthrough vs input | +0.0 (+0..+0) | +0.0 (+0..+0) | +0.0 (+0..+0) | +0.0 (+0..+0) | +0.0 (+0..+0) | +0.0 (+0..+0) |
| all-off vs input | -0.0 (-0..+0) | -0.0 (-0..+0) | +0.0 (+0..+0) | -0.0 (-0..+0) | +0.0 (-0..+0) | -0.0 (-0..+0) |
| FULL vs input | +23.2 (-30..+138) | -10.2 (-46..+13) | -8.8 (-35..+15) | +24.3 (-34..+75) | +15.8 (-7..+48) | -3.1 (-28..+19) |
| ko:bloom | +4.5 (-14..+12) | -8.9 (-36..-1) | -5.8 (-23..+0) | +0.2 (-27..+9) | +13.9 (+6..+18) | +17.8 (-6..+26) |
| ko:chromatic | +6.7 (-0..+27) | +4.0 (-1..+19) | +3.5 (-0..+21) | +5.6 (-1..+23) | +0.1 (-0..+2) | -0.7 (-4..+0) |
| ko:colorblock | +1.7 (-24..+33) | -2.5 (-27..+12) | -0.8 (-27..+19) | +0.9 (-22..+22) | -2.1 (-10..+2) | +3.2 (-1..+21) |
| ko:contrastsat | +7.6 (+0..+25) | +7.8 (-0..+30) | +5.8 (-1..+73) | +7.7 (-3..+26) | -1.6 (-7..+0) | +2.5 (+0..+6) |
| ko:feedback | -14.5 (-25..-4) | -10.9 (-26..-2) | -10.7 (-30..+0) | -8.8 (-20..+5) | +0.9 (-9..+11) | -12.9 (-25..-2) |
| ko:fractalhue | +13.6 (+1..+27) | +11.7 (+1..+27) | +10.3 (-0..+24) | +13.9 (-0..+30) | -1.8 (-7..+2) | -1.1 (-8..+13) |
| ko:fractalnoise | -0.8 (-8..+5) | +0.2 (-6..+5) | +0.1 (-6..+17) | -0.4 (-8..+4) | -0.7 (-8..+6) | -1.3 (-8..+4) |
| ko:ghosttaps | -8.1 (-16..+0) | -5.8 (-14..+0) | -5.8 (-16..+0) | -7.1 (-15..+0) | +0.8 (-1..+3) | -2.2 (-9..+0) |
| ko:hueshift | -14.3 (-41..+2) | -13.3 (-41..+0) | -7.1 (-31..+2) | -13.4 (-44..+1) | -1.0 (-11..+7) | +0.7 (-7..+18) |
| ko:kenburns | +2.4 (-28..+23) | -7.5 (-26..+11) | -6.6 (-33..+7) | +4.7 (-26..+32) | +9.6 (-12..+37) | -3.4 (-28..+28) |
| ko:logsphere | -2.1 (-15..+8) | +2.2 (-7..+21) | +2.1 (-10..+50) | -1.8 (-11..+12) | -2.6 (-12..+6) | +0.4 (-16..+10) |
| ko:turbulence | -0.7 (-6..+6) | +0.2 (-7..+8) | -0.0 (-8..+20) | -0.1 (-5..+6) | -0.5 (-6..+6) | -1.5 (-8..+9) |
| solo:bloom | +9.2 (-10..+17) | -7.2 (-38..-0) | -4.1 (-19..+0) | +3.8 (-27..+12) | +12.6 (+6..+18) | +14.6 (-5..+22) |
| solo:chromatic | +22.0 (+1..+68) | +7.8 (+0..+25) | +5.6 (-0..+37) | +16.8 (+1..+49) | +0.7 (-0..+4) | -2.0 (-4..-0) |
| solo:contrastsat | +30.6 (+2..+82) | +14.3 (+0..+41) | +5.0 (-1..+57) | +23.4 (+2..+61) | -1.6 (-8..+2) | +5.9 (+0..+15) |
| solo:feedback | -5.8 (-16..-1) | -5.0 (-12..-1) | -5.5 (-15..+0) | -2.5 (-8..+0) | +0.6 (-1..+3) | -6.8 (-13..-1) |
| solo:fractalhue | +22.6 (+3..+49) | +15.4 (+3..+27) | +12.5 (+0..+30) | +24.9 (+5..+52) | -2.3 (-11..+7) | -1.8 (-15..+17) |
| solo:fractalnoise | -0.9 (-8..+4) | -1.1 (-7..+1) | -1.4 (-8..+0) | -0.6 (-7..+3) | +0.0 (-2..+2) | -1.8 (-6..+2) |
| solo:ghosttaps | -4.1 (-14..+0) | -3.4 (-10..+0) | -3.9 (-13..+0) | -1.9 (-7..+0) | +0.2 (-1..+2) | -4.7 (-11..+0) |
| solo:hueshift | -1.3 (-29..+35) | -10.3 (-29..+4) | -4.4 (-30..+8) | -2.6 (-27..+11) | -0.7 (-6..+1) | -0.5 (-7..+2) |
| solo:kenburns | +4.6 (-13..+25) | -4.4 (-19..+7) | -3.4 (-20..+4) | +4.9 (-25..+29) | +7.5 (-5..+25) | -0.3 (-13..+20) |
| solo:logsphere | -3.1 (-11..+2) | -0.7 (-5..+4) | -1.2 (-5..+2) | -2.2 (-8..+5) | -1.6 (-5..+2) | -2.4 (-12..+1) |
| solo:turbulence | -1.1 (-7..+3) | -1.1 (-5..+3) | -1.2 (-6..+1) | -0.9 (-6..+4) | -0.2 (-3..+3) | -1.5 (-8..+4) |
