# Spatial decisions

Plan: [docs/plans/spatial.md](../plans/spatial.md). Entries are added as the work proceeds.

## S1. One immersive mode replaces Dome and Spatial Diorama

The diorama used `ImagePresentationComponent` / `Spatial3DImage.generate()`. The system renders
it, there is no shader or texture hook, it takes seconds per image, has no transitions and does
not run in the simulator. Effects cannot be applied to it. The dome had effects but was a flat
texture on a curved panel with a small UV parallax. One mode with both properties is what was
asked for, so the diorama is removed instead of kept as a second button.

## S2. RealityKit shell with texture-space effects, not CompositorServices

The effects need a texture-space pass anyway (feedback trails, Ken Burns, crossfade), and that
pass exists and is tuned. What was missing is 3D presentation of its output. RealityKit gives
head pose, per-eye projection, foveation and reprojection for free, works in the simulator, and
keeps the SwiftUI controls flow as it is. A CompositorServices rewrite would re-implement all of
that for no visual gain here, and its simulator and foveation behaviour were not confirmed by the
research. It stays the option to revisit if RealityKit cannot hold 90 Hz on device.
LowLevelRenderer (visionOS 27) is new and thinly documented, and Apple's own advice for combining
it with RealityView is the texture-on-tessellated-mesh pattern used here. Gaussian splats cannot
run the fragment effects.

## S3. Depth as real geometry, displaced on the CPU along the line of sight

Real geometry gives correct stereo and head-motion parallax. Displacing along the ray from the
shell centre means the viewer at the centre sees no stretching at depth edges; it only appears
with head translation, and the blur plus slope limit bound it. CPU displacement of about 14k
vertices is cheap, deterministic and testable; images change every 30 s or so. A ShaderGraph
geometry modifier is the alternative if CPU time ever matters.

## S4. Mono effects render, texture parallax off

With real depth in the geometry, the per-eye UV parallax is a second, conflicting depth cue, and
it has the wrong sign in mirrored tiles. Rendering the effects once and showing the same texture
to both eyes keeps 2048x2048 per eye and roughly halves the effects GPU cost, which pays for the
larger shell on the M2. The stereo path stays behind a DEBUG flag for an A/B on device.

## S5. Coverage by mirrored continuation of the 3:2 image, not wide generation

Options considered: wide (4:1 or 8:1) generation, multi-image stitching, edge blur extension,
mirror tiling. Mirror tiling was chosen because it needs no new assets or API spend, works with
every cached image, costs no extra effect rendering, keeps the hero framing and angular
resolution identical to today, and fits the kaleidoscopic look. Wide generation would spread
2048 px over two to three times the angle (or need a larger render target and effect-math changes
owned by the transitions workstream), cost more per image, and invalidate the cache; no true
panorama mode is documented for the model. It is left as later work. No Gemini calls were made.

Three tiles of 112.5 degrees leave a 22.5 degree gap behind the viewer, faded to black. Four
90 degree tiles would close the circle but shrink the image to 90 x 60 degrees and put seams
inside the forward view.

## S6. Relief follows the clarity cycle and the transition

The relief is tied to the undistorted image, while the texture is warped by the effects. Scaling
relief down as `EffectLook.drive` rises, and dipping it mid-transition, keeps geometry and picture
in agreement when it matters (clear stretches) and reads as the scene melting and re-forming.
Only public outputs of the effect code are read; none of it is edited.

## S7. Bands continue at the image's angular rate (30% mirrored, to ±60°), not 60% squeezed

Implementation, phase 1. The plan put 60% of the image into each vertical band and reached ±59.4°
by spacing the band in tan(elevation). The hero rows are linear in elevation (like the old dome),
so that would compress the mirrored picture about 2x right at the seam. The bands now keep the
image's own rate (75° per unit v): each mirrors the 30% of the image nearest its edge and reaches
±60°, so the reflection is continuous in scale as well as position. 12 rows per band
(113 x 97 = 10,961 vertices per tile, 21.5k triangles; 64.5k for the shell).

## S8. One material per tile with baked constants; uv1 carries the band coordinate

ShaderGraphCoder can promote parameters, but nothing changes per frame, so each tile gets its own
`ShaderGraphMaterial` with its gain and rear-fade range baked in (three graphs built once at entry,
all sampling the same `TextureResource`). `faceCulling = .none` because the side tiles are
mirrored with a negative x scale. The texture-stereo A/B (`-LiminalShellTextureStereo`) puts the
old stereo material on the hero and the left-eye texture on the sides.

## S9. Per-frame vertex write with vDSP

The per-vertex Swift loop cost ~1.6 ms per frame in the Debug build the simulator and perf
harness use (`@_optimize(speed)` is ignored at -Onone). The breathing wave is split into column,
row and per-vertex terms with angle-sum identities and everything (breathing, relief blend,
1/(1 + k q), interleaved write) is done with a few hundred vDSP calls: 0.22 ms per frame in Debug in
the simulator, and the Release cost is lower still.

## S10. Harness notes

`-LiminalShellYaw` / `-LiminalShellPitch` take degrees. Pass negative angles as their positive
equivalent (304 for -56): the argument domain reads a value that starts with `-` as the next key.
`-LiminalHideControls YES` closes the controls window after the space opens so screenshots are
unobstructed.

## S11. Relief: exact slope limit, late depth held, and the k coupling landed with phase 2

- The slope limit is the mean of the lower and upper Lipschitz envelopes (two-pass L1 chamfer),
  not an iterative relaxation: it is exact (every neighbour step <= 0.035 1/m / 0.458 = 0.076 in q),
  deterministic, stays inside the input range and leaves already-smooth fields untouched.
- The depth map is generated from the cover-cropped image, so it already spans the image; no
  second crop is applied.
- `ReliefBlend` keeps previous/current fields by image generation. The new field morphs in with
  the crossfade's progress; a late field is held at the old one and eases in over 0.6 s; a field
  for a superseded generation is dropped.
- `k = depth x (1 - 0.6 drive) x (1 - 0.5 sin(pi p))` (planned for phase 3) is already in, because it
  is one pure function of public outputs (`EffectLook.drive`, transition progress) and it is what
  hides the relief/warp mismatch. The Depth setting itself is still the DEBUG flag / default 0.6.
- Measured in the simulator, Debug: relief field build 25 to 120 ms off the main actor (Release
  will be well under the 5 ms target only if optimised; it runs once per image off the render loop
  either way); per-frame vertex write with relief 0.3 to 0.5 ms.

## S12. The simulator's ML depth map is all zeros; relief is checked with Mac-made depth

Depth Anything in the visionOS simulator returns an all-zero map (logged: min = max = 0), so the
relief field there is flat and only the device exercises real ML depth. For simulator checks,
`-LiminalDepthImage <png>` and `-LiminalShellCycle "img|depth,..."` feed depth maps produced on the
Mac with the same model (same cover crop, 518x392, min-max normalised). With depth 1 and a 15 cm
head offset the near cliff of fixture r2-01 shifts 40 px and the far sky 29 to 32 px, against a
uniform 33 to 35 px with depth 0.

## S13. ARKit entry pose works in the simulator; re-centre polls at 10 Hz

`HeadPoseProvider` runs a `WorldTrackingProvider` (no authorization prompt needed for the device
anchor) and waits up to 1 s at entry for a tracked pose. Contrary to the plan's expectation, the
visionOS 27.2 simulator does report one: the logs show `SHELL placed at (0.00, 1.60, 0.00) yaw=-0.0°
source=ARKit`, so the fallback (0, 1.5, 0) is only used when tracking is unsupported or late. The
re-centre (`ShellRecentre`, pure, unit tested) queries the device anchor every 0.1 s rather than every
frame: start at 0.35 m, ease with a 3 s time constant (frame-rate independent), stop within 5 cm
(hysteresis, so the shell does not creep after small head moves). Only position is re-centred; the
entry yaw stays, so turning the head looks around the scene instead of dragging it along.

## S14. Depth setting, eased; breathing coupled to the music within the 3 cm cap

- "Depth" (`SettingsService.depthStrength`, default 0.6, persisted, reset with the others) is a slider
  in the Visuals section. The render loop eases it with a 0.5 s one-pole (`DepthSettingSmoother`), so
  dragging the slider or a reset reshapes the relief smoothly rather than in one frame (comfort).
  `-LiminalShellDepth` still overrides it.
- Breathing amplitude is 2 cm at rest and rises toward the 3 cm comfort cap with the music's scene
  energy and slow geometry pulse, scaled by the coupling's master wet (`MusicModulation.amount`), so
  it is 2 cm when "Sync visuals to music" is off. The mesh clamps it to 3 cm. Colour, glow, ghost-tap
  bursts and the other music couplings already reach every tile through the shared effects texture.

## S15. One immersive space and one button

`LiminalVisionApp` has a single `ImmersiveSpace(id: "liminalSpace")` with
`.progressive(0.4...1.0, initialAmount: 1.0)` and `.full`; at full the simulator room no longer shows
behind or below the shell. `ControlsView` has one "Enter Liminal" / "Exit Liminal" button (accessibility
id still `enterDome`) and the Depth slider. `SpatialDioramaView.swift` is deleted; no source or script
mentions the diorama any more. `-LiminalOpenDome YES` opens `liminalSpace`, so `perf-run.sh` is
unchanged apart from comments, its log check and the re-measured `sim-tap.sh` coordinates
(Play 1371 826, Enter Liminal 1371 930). `ImmersiveDomeView.swift` keeps its name for merge safety with
the transitions workstream; transitions only reach the shell through the effected texture and
`transitionProgress`, so any new transition type is inherited unchanged.

## S16. Final verification (simulator, Debug)

- All three builds (macOS, visionOS simulator, generic visionOS device) succeed; LiminalTests pass,
  including six new placement tests.
- Screenshots at yaw 0, 56, 112, 180, 304 (-56) and pitch 45, 315 (-45): effects on every tile, seams
  continuous, rear gap and top/bottom fade to black.
- Recording across two image changes at depth 1: k dips to about 0.62 mid-transition and returns to 1,
  the relief blend weight goes 0 -> 0.7 -> 1, and the effected morph plays on the shell with no pop.
- Recordings at effect intensity 0, 0.5 and 1 show the expected range from clear to wild.
- perf-run (30 s after 15 s warm-up): 78.4 fps, 2.17 dropped per 5 s, GPU 0.128 ms, against the
  phase 0 baseline of 78.0 fps, 2.5 dropped, 0.138 ms. Render target unchanged at 2048x2048.

## S17. Independent review fixes

- Setup cancelled by leaving the space early (while waiting for the first image, ARKit entry pose or
  the depth map) no longer starts the render loop afterwards. Before, `.task` cancellation ran after
  `onDisappear`, so the loop started with nothing left to cancel it and kept rendering.
- The controls window's Enter/Exit label follows the space when it closes another way (Digital
  Crown, Home): `ImmersiveDomeView` posts `didCloseNotification` from `onDisappear`. Before, the
  button stayed on "Exit Liminal" and the first tap did nothing visible.
- `-LiminalAutoExitAfter <s>` (DEBUG) leaves the space through the Exit button's code path, so Exit is
  verified in the simulator where window taps do not work.
- Harness: negative yaw/pitch values need a leading space (`-LiminalShellYaw " -90"`); a bare "-90"
  is read as the next key and the flag is silently ignored.
- Review verdict, no change needed: stereo comes from real geometry (both eyes see the same relief
  mesh), so left/right cannot be swapped; near (depth 1) maps to a smaller radius (measured: near
  regions shift 73-74 px vs 55 px for the far background under a 0.3 m head offset, uniform with
  Depth 0); image upright; fixed bounds contain the viewer, so the shell is never culled.
- Known, not from this branch: each image change still costs one 65-90 ms render-loop frame
  (cover-crop, colour stats and texture upload on the main actor); the main-branch baseline logs show
  the same hitch.

## Device checklist (to fill in on Apple Vision Pro, visionOS 27.2.1)

- Real ML depth relief (the simulator's Depth Anything output is all zeros)
- Stereo comfort at Depth 0.6 and 1.0; whether the default should change
- Head-motion parallax and re-centre at 0.35 m
- Entry pose (position and yaw) from ARKit when entering seated and standing
- Frame time and heat on M2 at 90 Hz
- Mirror seams and rear fade
- Progressive versus full immersion
- Texture-stereo A/B (`-LiminalShellTextureStereo YES`); if the geometry alone reads well, remove
  `StereoMaterialBuilder` and the stereo render path
