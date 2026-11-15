# Liminal visionOS 3D Effects — Implementation Log

*Implemented: March 2026*

> **Superseded (November 2026).** The dome and the Spatial Diorama were merged into one immersive space, a
> wrap-around depth-relief shell with the effects on every tile. `LowLevelDomeMesh` and `SpatialDioramaView`
> are gone. See `docs/plans/spatial.md` and `docs/decisions/spatial.md`. This file is kept as history.

## Overview

Seven phases of 3D spatial effects were implemented for the visionOS dome experience. These transform the flat 2D shader output into a living, breathing 3D scene with depth displacement, stereoscopic rendering, atmospheric fog, particle transitions, and Apple's visionOS 26 spatial diorama API.

**Key constraint:** `CustomMaterial` does not exist on visionOS. All GPU work uses `ShaderGraphMaterial` (via ShaderGraphCoder), `LowLevelMesh`, or Metal compute shaders.

**Where the effects live:**
- **Phases 1, 3, 4, 6, 7** — Inside the **dome** (Enter Dome button). These modify the existing dome experience.
- **Phase 5** — The **Spatial Diorama** button. A separate immersive space using Apple's ImagePresentationComponent.
- **Phase 2** — ML depth maps. Shared infrastructure that feeds into Phases 3, 4, and 7.

---

## Phase 1: LowLevelMesh Migration

**Goal:** Replace CPU-side mesh rebuilding (~1-2ms/frame) with GPU compute shader (~0.1ms).

**What changed:** The dome's breathing animation previously called `MeshResource.generate()` + `.replace(with:)` every frame on CPU. Now a Metal compute kernel (`breathingDisplacement`) runs on GPU, reading base vertices from a static buffer and writing displaced vertices directly into the `LowLevelMesh`.

**Visual difference:** None — same breathing animation, just faster. This was foundational for Phase 3 (depth displacement requires the compute shader path).

### Files Created
- **`Liminal/Shaders/DomeCompute.metal`** — `breathingDisplacement` kernel. Reads base vertices, applies 4-wave sinusoidal displacement along normals. Also accepts depth texture for Phase 3.
- **`Liminal/visionOS/LowLevelDomeMesh.swift`** — Wraps `LowLevelMesh` lifecycle. Generates initial dome geometry (48x36 segments, 1813 vertices), creates base vertex buffer, dispatches compute shader via `updateBreathing()`.

### Files Modified
- **`Liminal/visionOS/ImmersiveDomeView.swift`** — Replaced `@State` arrays (`basePositions`, `baseNormals`, `baseUVs`, `meshIndices`) and `meshResource` with `@State private var domeMesh: LowLevelDomeMesh?`. Removed all CPU mesh generation code (`createBreathingMeshData`, `updateBreathingMesh`, `BreathingMeshData` struct).
- **`Liminal/visionOS/OffscreenEffectsRenderer.swift`** — Made `device` and `commandQueue` properties public so `LowLevelDomeMesh` and `ParticleSystemRenderer` can use them.

### Vertex Layout
```
DomeVertex (32 bytes):
  packed_float3 position  (offset 0, 12 bytes)
  packed_float3 normal    (offset 12, 12 bytes)
  packed_float2 uv        (offset 24, 8 bytes)
```

---

## Phase 2: ML Depth Maps

**Goal:** Generate per-pixel depth maps from Gemini images using on-device ML. These depth maps drive Phases 3, 4, and 7.

**Model:** `DepthAnythingV2SmallF16.mlpackage` from [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small). ~50MB, Float16 precision, runs on Apple Neural Engine. Input: 518x518 image. Output: 518x396 grayscale depth map (0=far, 1=near). Inference: ~31ms.

### Files Created
- **`Liminal/DepthAnythingV2SmallF16.mlpackage/`** — CoreML model downloaded from HuggingFace.
- **`Liminal/Visual/DepthMapGenerator.swift`** — `actor DepthMapGenerator` wrapping the CoreML model. `generateDepth(from: CGImage) throws -> CGImage` resizes input, runs inference, returns grayscale depth.

### Files Modified
- **`Liminal/Visual/AtomicImageBuffer.swift`** — Added parallel depth storage: `_currentDepth: CGImage?`, `_depthGeneration: UInt64`, with `storeDepth()`, `loadDepthWithGeneration()`, `loadDepth()`. Same lock-free pattern as image storage.
- **`Liminal/visionOS/OffscreenEffectsRenderer.swift`** — Added `depthTexture: MTLTexture?` and `updateDepthTexture(from: CGImage)` to upload depth as `.r8Unorm` texture.
- **`Liminal/visionOS/ImmersiveDomeView.swift`** — Initializes `DepthMapGenerator` in background. Triggers depth generation on new images. Polls depth buffer and uploads to renderer each frame.

### Threading Model
- Depth generation runs in `Task.detached` (off MainActor, on ANE)
- Results stored in `AtomicImageBuffer` (lock-free)
- Render loop polls `loadDepthWithGeneration()` each frame, uploads when changed
- Images change every ~30s, inference takes ~31ms — zero render loop impact

---

## Phase 3: Depth-Displaced Mesh

**Goal:** Subjects in the image physically push toward the viewer. The flat image becomes a breathing relief sculpture.

**How it works:** The `breathingDisplacement` compute kernel samples the depth texture at each vertex's UV coordinate. Vertices with higher depth values (nearer subjects) are displaced further along their normal, pushing them toward the viewer. The displacement amplitude oscillates organically between 0.08m and 0.20m using `SmoothOscillator` (golden ratio-based, never repeats).

### Files Modified
- **`Liminal/Shaders/DomeCompute.metal`** — Added `texture2d<float> depthMap [[texture(0)]]` parameter. Samples depth at vertex UV, adds `depthVal * depthAmplitude` displacement along normal. `hasDepthMap` flag prevents sampling when no texture is bound.
- **`Liminal/visionOS/LowLevelDomeMesh.swift`** — `updateBreathing()` now accepts optional `depthTexture: MTLTexture?` and `depthAmplitude: Float`. Passes to compute kernel. Added `depthAmplitude` and `hasDepthMap` fields to `BreathingParams` struct.
- **`Liminal/visionOS/ImmersiveDomeView.swift`** — Computes oscillating depth amplitude each frame: `0.08 + (0.20 - 0.08) * SmoothOscillator.value(at: time)`. Passes `effectsRenderer?.depthTexture` to mesh update.

### BreathingParams Struct (Swift ↔ Metal)
```swift
struct BreathingParams {
    var time: Float
    var amplitude: Float
    var speed: Float
    var vertexCount: UInt32
    var horizontalSegments: UInt32
    var verticalSegments: UInt32
    var depthAmplitude: Float   // Phase 3: 0.08–0.20m oscillating
    var hasDepthMap: Float      // Phase 3: 1.0 if depth texture bound
}
```

---

## Phase 4: Stereoscopic Per-Eye Rendering

**Goal:** True stereoscopic 3D. Each eye sees a slightly different image based on depth — near objects have more parallax, far objects less. Creates convincing depth perception.

**How it works:** A `ShaderGraphMaterial` built with [ShaderGraphCoder](https://github.com/praeclarum/ShaderGraphCoder) uses `GeometrySwitchCameraIndex` to route different textures to each eye. Two `DrawableQueue`s feed left/right eye content. The effects shader renders twice per frame with opposite UV offsets scaled by the depth map. Stereo separation oscillates via `SmoothOscillator` for "depth breathing."

### Files Created
- **`Liminal/visionOS/StereoMaterialBuilder.swift`** — Builds a `ShaderGraphMaterial` programmatically using ShaderGraphCoder. Creates two `TextureResource` + `DrawableQueue` pairs (left/right). Wires them through `geometrySwitchCameraIndex()` → `unlitSurface()`. The dome entity uses this material instead of `UnlitMaterial`.

### Files Modified
- **`Liminal/visionOS/OffscreenEffectsRenderer.swift`** — Added `renderStereoAndPresent()` method that renders the fragment shader twice (left eye: negative UV offset, right eye: positive UV offset) and presents to separate drawable queues. Private `renderEyeToDrawable()` helper handles per-eye rendering.
- **`Liminal/visionOS/ImmersiveDomeView.swift`** — Builds stereo material on setup. Render loop uses stereo path when available, mono fallback otherwise. Stereo offset: `0.002 + 0.004 * SmoothOscillator`.
- **`Liminal.xcodeproj/project.pbxproj`** — Added ShaderGraphCoder SPM dependency (https://github.com/praeclarum/ShaderGraphCoder, version 2.0.0).

### Stereo Pipeline
```
Effects Shader → Left UV offset → Left DrawableQueue ─┐
                                                       ├→ GeometrySwitchCameraIndex → UnlitSurface
Effects Shader → Right UV offset → Right DrawableQueue ┘
```

**Note:** Stereo only works on physical Vision Pro (not Simulator). Close one eye to confirm per-eye difference.

---

## Phase 5: ImagePresentationComponent (visionOS 26)

**Goal:** Use Apple's on-device ML to turn each Gemini image into a walkable 3D spatial diorama with head-tracked parallax. Separate immersive space from the dome.

**How it works:** `ImagePresentationComponent.Spatial3DImage` takes an image file, runs `generate()` for ML inference (several seconds), then creates a spatial 3D scene you can lean into and look around. This is a completely separate experience from the dome.

### Files Created
- **`Liminal/visionOS/SpatialDioramaView.swift`** — `RealityView` with entity holding `ImagePresentationComponent`. Polls `AtomicImageBuffer` every 1s for new images. On new image: saves to temp JPEG file → creates `Spatial3DImage(contentsOf:)` → calls `generate()` → sets `spatial3DImmersive` viewing mode → attaches to entity.

### Files Modified
- **`Liminal/visionOS/LiminalVisionApp.swift`** — Added `ImmersiveSpace(id: "liminalDiorama")` using `SpatialDioramaView`.
- **`Liminal/visionOS/ControlsView.swift`** — Added "Spatial Diorama" toggle button. Dome and diorama are mutually exclusive (dismisses one before opening the other). Added `isDioramaActive` state.

### Limitations
- `generate()` does NOT work in the visionOS Simulator — device only
- Takes several seconds per image (ML inference)
- `Spatial3DImageError error 10` observed on first test — under investigation (may be image format or visionOS 26 beta issue)

---

## Phase 6: Particle Dissolution

**Goal:** During image transitions, pixels dissolve into 3D space as particles, swirl with turbulence, then reform into the next image. Psychedelic transition effect.

**How it works:** 65,536 particles (256x256 grid) sample color and position from the current image's dome surface. On transition: particles fly outward (dissolve), swirl with turbulence forces, then converge to target positions on the next image. Three compute kernels handle spawn, update, and vertex copy. A `LowLevelMesh` with `.point` topology renders the particles.

### Three-Phase Animation
```
Phase 0.0 → 0.3: DISSOLVE — particles fly outward from dome surface
Phase 0.3 → 0.7: TURBULENCE — particles swirl in 3D space
Phase 0.7 → 1.0: CONVERGE — particles reform into next image
```

### Files Created
- **`Liminal/Shaders/ParticleCompute.metal`** — Three compute kernels:
  - `spawnParticles`: Maps particle index to UV grid, samples image color + depth, positions on dome surface
  - `updateParticles`: Three-phase animation with per-particle random seeds for varied motion
  - `copyParticlesToVertices`: Copies positions/colors to `LowLevelMesh` vertex buffer, applies fade at endpoints
- **`Liminal/visionOS/ParticleSystemRenderer.swift`** — Manages particle buffer (64 bytes/particle), `LowLevelMesh` with `.point` topology, compute pipeline dispatch. API: `spawnFromImage()`, `setTargetImage()`, `startDissolution()`, `update()`.

### Files Modified
- **`Liminal/visionOS/ImmersiveDomeView.swift`** — Added particle entity alongside dome entity. On image transition: spawns particles from previous image, sets target to new image, starts dissolution. Each frame updates simulation. Dome opacity fades with `OpacityComponent` during dissolution (dome fades out as particles take over, fades back in as they converge).

### Particle Struct (Metal, 64 bytes)
```metal
struct Particle {
    packed_float3 position;      // Current world position
    packed_float3 velocity;      // Current velocity
    packed_float3 targetPosition; // Convergence target
    packed_float3 color;         // RGB from image
    float life;                  // 0 = alive, 1 = expired
    float phase;                 // Animation phase (0→1)
    float seed;                  // Per-particle random
    float _pad;                  // Alignment
};
```

---

## Phase 7: Volumetric Atmosphere

**Goal:** Depth-aware fog in the fragment shader. Near subjects pierce through mist, far regions are shrouded. Creates atmospheric depth from the flat image.

**How it works:** After stochastic bloom in the effects pipeline, a new atmosphere stage samples the depth map and computes fog density inversely proportional to depth. Animated simplex noise adds volumetric texture. Fog color shifts slowly over time. Maximum 30% opacity to keep it subtle.

### Files Modified
- **`Liminal/EffectsUniforms.swift`** — Added `var atmosphereAmount: Float` field. Must stay in sync with Metal struct.
- **`Liminal/Shaders/EffectsRenderer.metal`** — Added `float atmosphereAmount` to uniforms struct. Added `texture2d<half> depthTexture [[texture(5)]]` parameter. New atmosphere stage (stage 6): samples depth, computes fog density, adds animated noise for volumetric texture, blends fog color.
- **`Liminal/Visual/EffectsUniformsComputer.swift`** — Added `computeAtmosphere(time:)` method. Oscillates 0.1–0.3 via `SmoothOscillator`.
- **`Liminal/visionOS/OffscreenEffectsRenderer.swift`** — Binds depth texture at index 5 in fragment shader encoder (both mono and stereo paths).
- **`Liminal/Visual/EffectsMetalView.swift`** — Updated macOS uniforms constructor to include `atmosphereAmount: 0` (macOS doesn't have depth maps yet).

### Atmosphere Shader Logic
```metal
if (uniforms.atmosphereAmount > 0.001) {
    half depthVal = depthTexture.sample(depthSampler, uv).r;  // 0=far, 1=near
    float fogDensity = (1.0 - float(depthVal)) * uniforms.atmosphereAmount;
    // + animated noise for volumetric texture
    // + slowly shifting fog color
    // Blended into output, capped at ~30% opacity
}
```

---

## Dependency Graph

```
Phase 1 (LowLevelMesh) ──┐
                          ├──> Phase 3 (Depth Displacement) ──> Phase 4 (Stereo)
Phase 2 (ML Depth Maps) ──┤
                          └──> Phase 7 (Atmosphere)

Phase 5 (ImagePresentationComponent) — independent, separate immersive space
Phase 6 (Particle Dissolution) — uses LowLevelMesh pattern from Phase 1
```

**Implementation order:** 1 → 2 → 3 → 7 → 4 → 5 → 6

---

## All Files Changed

| File | Status | Phases |
|------|--------|--------|
| `Shaders/DomeCompute.metal` | **Created** | 1, 3 |
| `Shaders/ParticleCompute.metal` | **Created** | 6 |
| `visionOS/LowLevelDomeMesh.swift` | **Created** | 1, 3 |
| `visionOS/StereoMaterialBuilder.swift` | **Created** | 4 |
| `visionOS/SpatialDioramaView.swift` | **Created** | 5 |
| `visionOS/ParticleSystemRenderer.swift` | **Created** | 6 |
| `Visual/DepthMapGenerator.swift` | **Created** | 2 |
| `DepthAnythingV2SmallF16.mlpackage/` | **Downloaded** | 2 |
| `visionOS/ImmersiveDomeView.swift` | **Modified** | 1, 2, 3, 4, 6 |
| `visionOS/OffscreenEffectsRenderer.swift` | **Modified** | 1, 2, 4, 7 |
| `Visual/AtomicImageBuffer.swift` | **Modified** | 2 |
| `Shaders/EffectsRenderer.metal` | **Modified** | 7 |
| `EffectsUniforms.swift` | **Modified** | 7 |
| `Visual/EffectsUniformsComputer.swift` | **Modified** | 7 |
| `Visual/EffectsMetalView.swift` | **Modified** | 7 |
| `visionOS/LiminalVisionApp.swift` | **Modified** | 5 |
| `visionOS/ControlsView.swift` | **Modified** | 5 |
| `Liminal.xcodeproj/project.pbxproj` | **Modified** | 4 (ShaderGraphCoder SPM) |

---

## Bug Fixes After Initial Testing

### Issue: No 3D effects visible in dome on first test

**Root cause:** Depth map generation only triggered during image transitions. If no image transition occurs while the dome is active, the depth texture is never generated. Without depth: no mesh displacement (Phase 3), no atmosphere fog (Phase 7), and minimal stereo parallax (Phase 4).

**Fix:** Generate depth for the initial image in two places:
1. When the initial image is set (if depth generator is already loaded)
2. When the depth generator finishes loading (immediately generates depth for whatever image is currently displaying)

```swift
// In DepthMapGenerator init callback:
if let gen = generator, let currentImage = imageBuffer.loadCurrent() {
    let depth = try await gen.generateDepth(from: currentImage)
    imageBuffer.storeDepth(depth)
}
```

### Issue: No image transitions occurring while dome is active

**Observation:** Images are queued (`AtomicBuffer QUEUE: pending=1,2,3`) but `advanceFromQueue()` wasn't called until after the dome was dismissed. This is a pre-existing timing issue — the image advance timer runs independently and hadn't fired during the test session.

**Impact:** Particle dissolution (Phase 6) never triggered because it requires a transition. Depth-dependent effects also didn't activate until the depth fix above.

### Issue: Spatial Diorama shows black screen

**Error:** `Spatial3DImageError error 10`

**Investigation:** Added detailed step-by-step logging to identify which step fails (file save, Spatial3DImage init, or generate()). Switched image format from PNG to JPEG for better compatibility with `ImagePresentationComponent`. Error 10 may be a visionOS 26 beta issue — needs further testing.

### Issue: `ModelEntity` has no `opacity` property

**Error:** `value of type 'ModelEntity' has no member 'opacity'`

**Fix:** Use `OpacityComponent` instead:
```swift
// Wrong:
panelEntity?.opacity = fade
// Correct:
panelEntity?.components.set(OpacityComponent(opacity: domeOpacity))
```

### Added diagnostic logging

Added `3D STATUS` log line every second showing feature activation state:
```
🔮 3D STATUS: depth=true stereo=true particles=false dissolving=false depthAmp=0.142 gen=1
```

Also added logging for:
- Depth texture upload confirmation (`🗺️ Depth texture uploaded to renderer`)
- Initial depth generation on model load
- Diorama step-by-step progress

---

## What To Expect Visually

**In the dome (after depth loads, ~5-10s):**
- Mesh breathing remains the same but is now GPU-driven (Phase 1 — performance improvement, not visual)
- Subjects in the image push toward you based on depth (Phase 3 — visible as relief sculpture effect)
- Subtle fog on distant parts of the image (Phase 7 — animated volumetric noise)
- Stereoscopic depth if on physical Vision Pro (Phase 4 — close one eye to confirm)
- During image transitions: particles dissolve/swirl/reform (Phase 6)

**In the spatial diorama (separate button):**
- Apple's ML generates a walkable 3D scene from the image (Phase 5)
- Lean in and look around with head-tracked parallax
- New images trigger new spatial scenes (~5-10s generation time)

---

## Performance Budget

| Component | Cost | Notes |
|-----------|------|-------|
| LowLevelMesh compute | ~0.1ms | Down from ~1-2ms (CPU) |
| Depth inference | ~31ms | Off MainActor, runs every ~30s |
| Stereo rendering | ~2x fragment shader | Two render passes, ~4ms total |
| Atmosphere fog | ~0.1ms | One noise eval per pixel |
| Particle update (65K) | ~0.2ms | GPU compute |
| **Total render** | ~4-5ms | Well under 11.1ms budget (90fps) |
