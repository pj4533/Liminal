# Spatial plan: one unified, depth-relief, wrap-around immersive space

> Status (2026-11-15): phases 0 to 5 implemented on feature/spatial. Device checks remain; see the
> device checklist in docs/decisions/spatial.md.
>
> The release later moved the hero patch to 16:9. [Current shell and recording geometry](../decisions/spatial.md#s19-widescreen-hero-and-immersive-recording-2026-11-23)

Branch `feature/spatial`. Decisions with reasons: [docs/decisions/spatial.md](../decisions/spatial.md).

## 1. Goal and decision

Replace the two visionOS modes ("Enter Dome" and "Spatial Diorama") with ONE immersive experience
that is really 3D, wraps around the viewer, and shows the full tuned effect stack.

Chosen architecture: the **mirror-wrap depth-relief shell**, in RealityKit.

- One immersive space, `liminalSpace`, one button.
- The existing effects renderer keeps producing the effected image as a 2048x2048 texture. Nothing
  in the effect stages, the uniform struct or `EffectsUniformsComputer` changes.
- That one texture is shown on real geometry: a cylindrical shell around the viewer whose vertices
  are pushed nearer or farther along the viewer's line of sight by the ML depth map. Stereo depth
  and head-motion parallax come from the geometry, so the system renders them correctly per eye.
- The shell wraps 337.5 degrees horizontally and about 119 degrees vertically by repeating the
  same texture with mirrored UVs (a kaleidoscope continuation). Mirror seams are continuous, and
  the first seams sit at +/-56 degrees, just outside the forward field of view, so looking straight
  ahead shows the same framing as the dome does today.
- Because every tile samples the same effected texture, the intensity setting, clarity cycle,
  crossfade or any future `transitionType`, ghost taps and music coupling all appear on the whole
  shell at no extra GPU cost.

Rejected or deferred (details in the decisions file): CompositorServices rewrite, LowLevelRenderer,
`ImagePresentationComponent` (cannot take effects), Gaussian splats, layered depth planes, and wide
(4:1) pictures.

## 2. Geometry

All angles are measured from the shell centre (the viewer's head position at entry).

| Item | Value |
|---|---|
| Base radius `rho0` | 2.5 m (was 2.0 m flat panel) |
| Hero tile | 112.5 x 75 degrees, same as today, image undistorted, UV unmirrored |
| Side tiles | 2, each 112.5 degrees, UV mirrored in u; total 337.5 degrees |
| Rear gap | 22.5 degrees directly behind, black; side tiles fade to black from azimuth 124 to 168.75 degrees |
| Vertical bands | above and below the hero rows, UV mirrored in v, sampling the 60% of the image nearest the edge; reach elevation +/-59.4 degrees (tan-space, like the current mesh) |
| Vertical fade | brightness 1 at 20% into the band, 0 at its outer edge |
| Side tile gain | 0.9 (tunable) |

Mesh: one `LowLevelMesh` tile, 112 x (24 + 72 + 24) segments = 113 x 121 = 13,673 vertices,
27k triangles. Three `ModelEntity` tiles share it:

- hero: identity;
- right: scale x = -1, then rotate -112.5 degrees about Y;
- left: scale x = -1, then rotate +112.5 degrees about Y.

Mirror and rotation both keep the shell centre fixed, so line-of-sight displacement stays radial
in every tile. Mirroring flips triangle winding, so the material uses `faceCulling = .none`.
Vertex layout gains `uv1` = (band coordinate, 0) for the vertical fade; stride 40 bytes.

Base position for azimuth `h`, tan-elevation `t`: `rho0 * (sin h, t, -cos h)`.
Displaced position: `base * (rho / rho0)`, where `rho` comes from the relief field (section 3).
Part bounds: a box of +/-7 m.

## 3. Depth

Source: the existing `DepthMapGenerator` output (Depth Anything V2 small, 518x392, 0 = far,
1 = near, about 31 ms per image, already produced for every image).

`DepthReliefField` (new, pure Swift, platform independent, unit tested), built once per image off
the main actor:

1. Apply the same cover-crop as the colour image, resample to the 113 x 73 hero grid.
2. Normalise per image: percentiles p2..p98 map to 0..1; subtract the median so half the scene
   sits behind the base radius and half in front.
3. Blur with a 3x3 binomial kernel, twice.
4. Slope limit: neighbouring vertices differ by at most 0.035 1/m, which bounds "rubber sheet"
   stretching at silhouettes.
5. Store as inverse-radius offsets `q` in -0.5...0.5.

Per frame (main actor, about 14k vertices, a few multiplies each):

```
inv = 1/rho0 + k * q * 0.458        // 0.458 = 1/1.6 - 1/6.0 (1/m)
rho = 1 / inv                        // k = 1: 1.6 m (near) ... 5.85 m (far)
k   = depthSetting * (1 - 0.6 * drive) * (1 - 0.5 * sin(pi * transitionProgress)) * bandTaper
```

- `depthSetting`: new "Depth" slider, 0...1, default 0.6. Zero gives a smooth shell.
- `drive`: `EffectLook.drive(time:)`, read only. The scene is most solid in clear stretches and
  melts toward the smooth shell in wild stretches. This also hides the fact that the relief is
  tied to the undistorted image while the texture warps.
- Transition: `q` lerps from the previous image's field to the new one with the same
  `transitionProgress` the shader gets, and the relief dips mid-transition. If depth for the new
  image is late, hold the old field and ease over 0.6 s when it arrives.
- Bands: relief tapers to zero at the outer edge.
- Breathing: the current four-sine wave stays, as a radius change of at most +/-3 cm at under
  0.1 Hz, applied to the hero rows and tapered in the bands.

Displacement is done on the CPU in `LowLevelMesh` (deterministic, works in the simulator, about
0.1 ms in Release). A ShaderGraph geometry modifier is the documented alternative.

Stereo comfort: vergence range at k = 1 is 0.6 to 2.3 degrees (1.6 to 5.85 m); at the default 0.6
it is about 1.9 to 4.2 m. Both eyes see the same texture, so there is no per-eye effect mismatch.
No head-locked content, no fast world-space motion.

## 4. Effects

- Render the effects ONCE per frame at 2048x2048 with the existing mono path
  (`OffscreenEffectsRenderer.renderAndPresent`, `effectsFragment`), and show that texture to both
  eyes. Angular resolution on the hero tile is unchanged (2048 px over 112.5 x 75 degrees per eye).
- The texture-space stereo parallax (`stereoOffset`) is turned off: it would fight the real
  geometry, and its sign is wrong in mirrored tiles. The stereo MRT path stays in the code as a
  DEBUG A/B option (`-LiminalShellTextureStereo YES`, hero tile only) until device review.
- Hue-by-depth keeps working (the depth texture is still uploaded).
- New `ShellMaterialBuilder` (ShaderGraphCoder): sample texture with the V flip from
  `StereoMaterialBuilder`, multiply by per-tile parameters (`gain`, rear-fade start/end in u and
  direction) and the `uv1` vertical fade, unlit, no tone map. Fades go to opaque black, so there is
  no alpha blending.
- Transitions: the shell only consumes the effected texture plus `transitionProgress`, so the
  other workstream's `transitionType` family is inherited without changes here. To limit merge
  conflicts, `ImmersiveDomeView.swift` keeps its name and its render loop structure; this branch
  only swaps the mesh, the material and the render call, and adds small hooks.

## 5. Placement and immersion

- `HeadPoseProvider` (new): ARKit `WorldTrackingProvider.queryDeviceAnchor` once at entry gives head
  position and yaw. The shell root is placed at the head position, levelled, facing the entry yaw.
  Fallback (simulator, provider unavailable): (0, 1.5, 0), yaw 0.
- Slow re-centre: if the head moves more than 0.35 m from the shell centre, the centre eases
  toward it (time constant 3 s). Inside that zone head motion gives true parallax.
- `.immersionStyle(selection:, in: .progressive(0.4...1.0, initialAmount: 1.0), .full)`.

## 6. UI and migration

- `ControlsView`: one button, "Enter Liminal" / "Exit" (accessibility id stays `enterDome` so
  `scripts/sim-tap.sh` keeps working), one `isImmersed` state. Remove `dioramaButton`,
  `toggleDiorama`, `isDioramaActive`.
- Visuals section: add the "Depth" slider (`SettingsService.depthStrength`, default 0.6).
- `LiminalVisionApp`: one `ImmersiveSpace(id: "liminalSpace")`. Remove `liminalDiorama`.
- Delete `SpatialDioramaView.swift`. Replace `LowLevelDomeMesh.swift` with `SpatialShellMesh.swift`.
  `StereoMaterialBuilder.swift` stays until device review of the A/B flag, then goes.
- `-LiminalOpenDome YES` keeps working and opens `liminalSpace` (perf-run.sh unchanged).
- Update README, `docs/PLATFORM_ARCHITECTURE.md`, `docs/VISIONOS_3D_IMPLEMENTATION.md`,
  `scripts/perf-run.sh` comments.

New files:

| File | Content |
|---|---|
| `Liminal/Visual/Spatial/ShellLayout.swift` | constants above, UV and position maths (all platforms) |
| `Liminal/Visual/Spatial/DepthReliefField.swift` | depth to inverse-radius field (all platforms) |
| `Liminal/visionOS/SpatialShellMesh.swift` | LowLevelMesh tile, per-frame write |
| `Liminal/visionOS/ShellMaterialBuilder.swift` | ShaderGraph material with fades |
| `Liminal/visionOS/HeadPoseProvider.swift` | entry pose and re-centre |
| `LiminalTests/SpatialShellTests.swift` | layout and relief tests |

New DEBUG flags (all automation flags like the others): `-LiminalShellYaw <deg>`,
`-LiminalShellPitch <deg>`, `-LiminalShellHeadOffset "x,y,z"` (moves the shell to imitate head
translation, shows parallax in the fixed-camera simulator), `-LiminalShellDepth <0...1>`,
`-LiminalShellTextureStereo YES`.

## 7. Performance budget (Vision Pro M2, 90 Hz)

| Cost | Now | Planned |
|---|---|---|
| Effects pass | stereo MRT, 2 x 2048x2048, about 5 ms on the M4 bench | mono, 1 x 2048x2048, about half |
| Shell draw | 3.5k triangles, one texture sample | 81k triangles, one texture sample plus fades |
| CPU per frame | 1.8k vertex write | 13.7k vertex write, target under 0.15 ms Release |
| Per image | depth 31 ms off loop | plus relief field build, target under 5 ms, off loop |

Gate: `scripts/perf-run.sh` (`LIMINAL_SIM_UDID=4F6C4C06-AAE6-44DF-8460-070ED1A546E1`) shows
`gpu_ms_mean` and `dropped_per_5s` no worse than the baseline taken in phase 0, at 90 fps.
The render target never goes below 2048x2048.

## 8. Simulator and device

Verifiable in the simulator: build, unit tests, upright and seamless tiles at several yaws, fades,
relief shape (head-offset flag, before/after screenshots), effects on all tiles, transition
behaviour (screen recording), perf comparison.

Device only: stereo depth comfort and the right default for `depthSetting`, real head-motion
parallax and the 0.35 m re-centre, entry pose from ARKit, M2 frame time and heat, whether mirror
seams read well, progressive versus full immersion feel. Each gets a line in the device checklist
in the decisions file.

## 9. Phases

Each phase builds on macOS, the visionOS simulator and the visionOS device target, passes
`LiminalTests`, and is committed on its own.

**Phase 0: harness.** Add the yaw, pitch and head-offset flags (applied to the current panel
entity) and take baselines.
Check: screenshots of the current dome at yaw 0, 60, 180; a perf-run baseline saved under `sp/`.

**Phase 1: shell geometry, no relief.** `ShellLayout`, `SpatialShellMesh`, `ShellMaterialBuilder`,
three tiles, mono render path, texture parallax off. Mono `UnlitMaterial` on the hero tile only
remains the fallback if the ShaderGraph build fails.
Check: with `-LiminalTestPattern YES`, screenshots at yaw 0, +/-56, +/-112, 180 and pitch +/-45 show
the pattern upright in the hero tile, continuous at every seam, fades at the rear and top; with a
fixture image and effects on, effects are visible in every tile; layout unit tests pass (seam UVs
equal on both sides, hero UV identical to the old mesh).

**Phase 2: depth relief.** `DepthReliefField`, per-frame displacement, previous/current lerp.
Check: unit tests (constant depth gives a smooth shell, radius always within 1.6...6.0 m, slope
limit holds, percentiles handled for flat and noisy input); simulator screenshots with
`-LiminalShellHeadOffset 0.15,0,0` versus none show near regions shifting more than far ones;
`-LiminalShellDepth 0` matches phase 1 pixel for pixel at frozen time.

**Phase 3: coupling and placement.** Relief scaled by `drive` and by `transitionProgress`,
breathing, `HeadPoseProvider`, re-centre, "Depth" setting.
Check: SYNC/PERF log lines report `k`; a recording across an image change shows the relief
flattening and reforming with no pop; the slider changes relief live; the simulator falls back to
(0, 1.5, 0).

**Phase 4: one mode.** UI, scene and file removal from section 6, immersion style, docs.
Check: no `Diorama` or `liminalDiorama` left in sources or scripts; one button; `-LiminalOpenDome`
opens the space; QA screenshots of the controls window.

**Phase 5: verification.** Perf gate from section 7, recordings at intensity 0, 0.5 and 1,
fixture sweep, decisions file completed with the device checklist.
Check: perf no worse than baseline; `git status` clean.

**Later, after device review (not in this branch unless trivial):** remove the texture-stereo A/B
path, tune defaults, consider a warped-depth output so relief follows the distortion, and consider
wider source images.
