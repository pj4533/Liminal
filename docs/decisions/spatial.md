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

## Device checklist (to fill in)

- Stereo comfort at Depth 0.6 and 1.0
- Head-motion parallax and re-centre at 0.35 m
- Entry pose (position and yaw) from ARKit
- Frame time and heat on M2 at 90 Hz
- Mirror seams and rear fade
- Progressive versus full immersion
