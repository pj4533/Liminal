# Image orientation and aspect decisions

## Summary (read this first)

- One convention everywhere: **texture row 0 / texCoord.y = 0 is the TOP of the image**. Upload,
  effects pass, drawable and dome UVs now all follow it, with no compensating flips (O1-O4).
- The old pipeline had **two flips that cancelled**: the visionOS upload stored the image upside down
  (bogus `translateBy/scaleBy(y:-1)`), and the dome mesh used `v = 1 - vFrac` (inverted UVs). Both are
  gone. The mono UnlitMaterial and the stereo ShaderGraph material were measured to sample
  identically, before and after the fix (O3).
- Aspect: every surface shows the image at **3:2** (`ImageFraming.displayAspect`). Sources are
  centre-cropped ("cover") to 3:2 once. The 2048x2048 render target is kept and stores the 3:2 frame
  anisotropically. The dome is now **112.5° x 75°** (was 110°), which is exactly 3:2 in view angle,
  so the image shows undistorted. macOS letterboxes to 3:2 (O5-O7).
- Verified upright and consistent with a generated test card on all five paths: simulator mono,
  simulator stereo (flat depth and ML depth), effects off and on, and macOS effects off and on.
  Also checked with a real image and with the offline harness (O9).
- New DEBUG launch flags: `-LiminalTestPattern YES`, `-LiminalForceStereoFlatDepth YES`,
  `-LiminalForceMonoMaterial YES`, `-LiminalNoEffects YES` (O8).

Format: decision, why, alternatives, numbers.

## O1 Upload: no flip (visionOS renderer + harness)
- Decision: `OffscreenEffectsRenderer.updateSourceTexture`, `updatePreviousTexture` and
  `updateDepthTexture` draw the CGImage into the CGBitmapContext with no transform. The same applies
  to `tools/VibranceHarness/main.swift` `loadSource`. The saliency upload never flipped and is unchanged.
- Why: a CGBitmapContext's user space has a bottom-left origin, but its backing memory is still
  top row first. Drawing normally therefore already gives Metal order (row 0 = top). The old comment
  ("CGContext has origin at bottom-left, Metal expects top-left") applied the flip twice and stored the
  image upside down. That is why the vibrance harness, which copied the upload, wrote upside-down PNGs.
  The depth upload had copied the flip to stay registered with colour. Saliency had not, so saliency
  was mis-registered (it is unused on visionOS today: `hasSaliencyMap: false`).
- Alternatives: keep the flipped upload and compensate downstream. That is what we had, and it made
  every new consumer (the harness, depth, saliency) guess. Rejected.
- Evidence: with the upload fixed and the old UVs, the simulator showed the test card upside down in
  BOTH materials (`probe-stereo-noeffects.png` and `probe-mono-noeffects.png`, identical).

## O2 Effects pass and drawable: identity
- Decision: no change. `effectsVertex` maps NDC y = -1 (bottom of the render target, its last row) to
  texCoord.y = 1 (last texture row). So drawable row r samples texture row r. The "flip Y for Metal"
  comment describes exactly this identity mapping. macOS uses the same vertex shader with
  MTKTextureLoader, which uses a top-left origin by default. It was already upright.

## O3 Dome UVs: standard USD convention, and both materials sample the same way
- Decision: `LowLevelDomeMesh` writes `uv = (hFrac, vFrac)`: v = 0 at the bottom edge and v = 1 at the
  top (the RealityKit/USD convention), not `1 - vFrac`. `StereoMaterialBuilder` keeps its
  `(u, 1 - v)` texcoord.
- Why (measured in the simulator with the test card):
  - UnlitMaterial (mono fallback) samples DrawableQueue texture row `(1 - v) * H`.
  - The ShaderGraph image node (ShaderGraphCoder `sampleColor3f`) samples row `v * H`, with no
    implicit flip.
  - Given `1 - v`, the stereo material reads row `(1 - v) * H`, the same as mono. With v = 1 at the top,
    both read row 0, the image top.
  - This contradicts the original hypothesis that mono and stereo were oriented opposite to each other.
    They were always the same. The test card showed both flipped together after O1, and both upright
    after O3.
- Note: the simulator does build the stereo ShaderGraph material and runs DepthAnything (649 ms on
  first inference). The "stereo is device-only" premise no longer holds. `-LiminalForceMonoMaterial`
  was added so the mono fallback can still be inspected.
- Alternatives: keep `1 - vFrac` and drop the ShaderGraph flip. That would fix stereo but turn mono
  upside down, and the mesh UVs would stay non-standard. Rejected.

## O4 Where the convention lives
- `Liminal/Visual/ImageFraming.swift` has a header comment with the whole chain. Each step also has a
  comment where it happens: the renderer uploads, `LowLevelDomeMesh` UVs, and `StereoMaterialBuilder`.

## O5 Aspect: centre-crop to 3:2, keep the square 2048² target
- Decision: `ImageFraming.coverCrop` centre-crops any source to 3:2. Within 0.5% it is an identity.
  It uses `CGImage.cropping`, so nothing is copied. visionOS applies it once per new image in
  `ImmersiveDomeView`, and depth is generated from the cropped image, so depth stays registered. The
  framed 3:2 image is then stretched into the 2048x2048 drawable as before.
- Why: Gemini 3.1 returns 3:2 (for example 2528x1696 = 1.491). BorderTrimmer and the fallback models
  can return other aspects. Before, any aspect was stretched to the square and then to a 1.467 dome.
  A 3:2 image was squeezed about 2%; a square fallback image was stretched 47%. The square target
  stretched by 1.5 horizontally and the 3:2 dome stretched it back. Net result: no distortion.
  Horizontal texel density is 2048 / 1.5 = 1365 px per image height versus 2048 vertically. The
  source is 2528 px wide, so the 2048 px across the width are still a downsample. No source detail is
  lost compared with the old path, and resolution stays 2048² (hard constraint).
- Alternatives:
  - Letterbox (fit): black bars on the dome. Rejected because it is not immersive.
  - A 3072x2048 target: more pixels per frame, against the perf work, and the drawables would change.
    Rejected for now.
  - Matching the target aspect to each image instead of cropping. The dome geometry is fixed, so that
    still needs a crop or a stretch somewhere. Rejected.
- Effects run in texture-UV space, which is 1.5:1 on screen on both platforms (the macOS view is also
  3:2). Round UV-space effects (chromatic, log-sphere, noise) are stretched the same way on both. This
  is unchanged from before and consistent, so it was left alone (keeps the look).

## O6 Dome arc 110° → 112.5°
- Decision: `ImmersiveDomeView.horizontalArc = verticalArc * displayAspect = 75 * 1.5 = 112.5°`.
- Why: a viewer at the dome centre sees vertex (h, v) at azimuth h and elevation v. The mesh uses
  `y = r tan(v)` at horizontal distance r. So the angular extent is 110° x 75° = 1.467, not 1.5, and a
  3:2 image showed squeezed about 2.2%. Widening by 2.5° (about 1.25° per side) makes it exact without
  cutting vertical coverage. Physical surface aspect (3.93 m x 3.07 m) does not matter here, because
  the viewer is at the centre.
- Alternatives:
  - verticalArc 73.3°: less coverage. Rejected.
  - Crop to 1.467: throws away 2% of every image. Rejected.

## O7 macOS: crop + aspect-fit
- Decision: `EffectsMetalView` crops the source, the previous image and saliency with the same
  normalized rect (so saliency stays registered). `VisualDisplayView` gives the Metal view
  `.aspectRatio(displayAspect, .fit)` on black. `SquareVisualWindowDelegate.visualAspect` reads the
  same constant.
- Why: the window delegate keeps a 3:2 visual area only after a resize. At launch, and at min sizes or
  full screen, the view was not 3:2 and the image stretched. Now it is pillarboxed or letterboxed
  instead (see `mac-noeffects.png`: 1004 px window, black side bars, round circle).

## O8 DEBUG flags (Liminal/Utils/DebugLaunchOptions.swift; compiled out of Release)
- `-LiminalTestPattern YES`: `TestPatternGenerator` makes a 1536x1024 (3:2) card. It replaces the source
  image and turns generation off. Contents:
  - a big up arrow and "TOP" at the top, "BOTTOM" at the bottom
  - corners TL red, TR green, BL blue, BR yellow, labelled
  - "L" and "R" labels
  - a circle on a 64 px square grid (aspect check)
  - a 32-step black→white ramp
  - 18%/50% grey patches (code values 0.18 and 0.5, plus reflectance-encoded 0.46 and 0.735)
  - R G B C M Y swatches
- `-LiminalForceStereoFlatDepth YES`: stereo material with a constant 0.5 depth map (518x392) instead of
  ML depth.
- `-LiminalForceMonoMaterial YES`: use the mono UnlitMaterial fallback.
- `-LiminalNoEffects YES`: `passthroughFragment` on macOS, and in visionOS mono and stereo (one pass
  per eye).

## O9 Verification (2026-11-14, evidence in the session scratchpad `orientation/`)
| Path | Flags | Result |
|---|---|---|
| visionOS sim, stereo ShaderGraph, flat depth, no effects | TestPattern, ForceStereoFlatDepth, NoEffects | upright: arrow up, TOP top, red TL, green TR, ramp dark→light L→R |
| visionOS sim, mono UnlitMaterial, no effects | TestPattern, ForceMonoMaterial, NoEffects | upright, identical framing |
| visionOS sim, mono, effects on (t=30) | TestPattern, ForceMonoMaterial | upright (TOP/arrow top, red top-left) |
| visionOS sim, stereo flat depth, effects on | TestPattern, ForceStereoFlatDepth | upright |
| visionOS sim, stereo ML depth, effects on | TestPattern | upright |
| macOS, no effects / effects on | TestPattern (+NoEffects) | upright, circle round, letterboxed |
| visionOS sim, real image (glass artichoke) | NoEffects | upright: stem at bottom, matches the stored JPEG |
| VibranceHarness (visionos mode) on the same JPEG | — | passthrough and full output upright |
- Real Gemini image 2528x1696 → cropped to 2528x1685 (log: "Downsampling source 2528x1685 → 2048x2048").
- Before the fix (`probe-*.png`, with the upload fixed but the old UVs), both materials showed the card
  upside down. This confirms O1 and O3 were a cancelling pair.
- Earlier vibrance harness PNGs (docs/plans/vibrance-measurements.md) were upside down. Their colour
  metrics are orientation-independent, so the numbers still hold.
