# Codex Session Updates

This file records only the code and behavior changes I made in this session.

## Root Cause Fixes

- Fixed depth model input/output handling in `Liminal/Visual/DepthMapGenerator.swift`.
  - Corrected model input size usage to `518x392` (required by the bundled CoreML model).
  - Switched to direct `MLModel` prediction on the `"image"` feature.
  - Added normalization from float16 depth output to full-range 8-bit grayscale depth maps for stronger, stable downstream effects.
  - Kept inference off the main actor and resolved actor-isolation issues.

- Fixed first-image depth application in `Liminal/visionOS/ImmersiveDomeView.swift`.
  - Added `ensureDepthGeneratorReady()` and `generateAndApplyDepth(...)`.
  - Depth is now generated and uploaded for the initial image before entering normal rendering.
  - Depth on image transitions is now uploaded immediately when generated.

## 3D Strength Increase (Aggressive Tuning)

- Increased dome deformation strength in `Liminal/visionOS/ImmersiveDomeView.swift`.
  - Raised breathing amplitude.
  - Increased depth displacement amplitude range substantially.

- Increased depth response shaping in `Liminal/Shaders/DomeCompute.metal`.
  - Applied a boosted depth curve (`pow(depth, 0.55)`) before displacement so near areas push out more clearly.

- Added depth-based stereo parallax in `Liminal/Shaders/EffectsRenderer.metal`.
  - Added a new `stereoOffset` uniform (signed per-eye).
  - Implemented per-eye UV shift scaled by sampled depth.

- Wired stereo control through Swift:
  - Added `stereoOffset` to `Liminal/EffectsUniforms.swift`.
  - Added default wiring in `Liminal/Visual/EffectsUniformsComputer.swift`.
  - Updated uniform construction call sites in:
    - `Liminal/Visual/EffectsMetalView.swift`
    - `Liminal/visionOS/OffscreenEffectsRenderer.swift`
  - Set aggressive stereo offsets in `Liminal/visionOS/ImmersiveDomeView.swift`.

- Increased atmospheric depth visibility:
  - Raised atmosphere range in `Liminal/Visual/EffectsUniformsComputer.swift`.
  - Increased fog cap in `Liminal/Shaders/EffectsRenderer.metal`.

## Particle Transition Improvements

- Improved particle UV/dome mapping in `Liminal/Shaders/ParticleCompute.metal`.
  - Matched particle UV convention to dome UV convention for better alignment.
  - Removed an unused shader variable warning.

- Tuned particle transition behavior in `Liminal/visionOS/ParticleSystemRenderer.swift`.
  - Reduced dissolve radius and turbulence.
  - Shortened dissolve duration for a tighter transition.

- Improved dome continuity during dissolution in `Liminal/visionOS/ImmersiveDomeView.swift`.
  - Dome now remains partially visible instead of disappearing fully.

## Other Session Fixes

- Corrected depth texture upload orientation alignment in `Liminal/visionOS/OffscreenEffectsRenderer.swift` so depth sampling lines up with the rendered image.
- Resolved Swift concurrency warnings introduced during this session around detached depth tasks in `Liminal/visionOS/ImmersiveDomeView.swift`.
