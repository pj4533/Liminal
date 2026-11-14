# Platform Architecture: macOS vs visionOS

This document explains the architectural differences between Liminal's macOS and visionOS implementations, why they exist, and what code is shared between platforms.

## Rendering Pipeline Comparison

| Aspect | macOS | visionOS | Why Different |
|--------|-------|----------|---------------|
| **Rendering API** | MTKView (direct Metal) | Offscreen Metal → DrawableQueue → RealityKit | MTKView unavailable on visionOS; RealityKit is native |
| **Display Surface** | Window framebuffer (3:2, letterboxed) | Curved dome mesh (112.5°×75°, 3:2 in view angle) | visionOS is spatial/immersive |
| **Frame Rate** | 60fps display link | 90fps RealityKit timeline | Platform requirements differ |
| **Image Blending** | GPU shader (fragment blend) | GPU shader (fragment blend) | Same approach, platform-optimal delivery |
| **State Management** | @Published properties | AtomicImageBuffer (lock-free) | 90fps starves MainActor |
| **Upscaling** | CoreML (RealESRGAN) | MetalFX (GPU scaler) | CoreML competes with RealityKit for GPU |
| **Coordinate Origin** | View-centered | Floor-centered (y=1.5m for eyes) | visionOS spatial coordinate system |

---

## Why visionOS Required Different Architecture

### Problem 1: MTKView Unavailable

**macOS**: `EffectsMetalView` is an MTKView subclass that handles:
- Automatic drawable management
- Display link synchronization
- Vsync coordination
- Direct rendering to window framebuffer

**visionOS**: MTKView doesn't exist. Must use RealityKit for immersive display, requiring a bridge:
```
Metal (offscreen) → DrawableQueue → TextureResource → RealityKit Entity
```

The `OffscreenEffectsRenderer` renders both eyes in one MRT pass straight into the 2048×2048 drawables of two `TextureResource.DrawableQueue`s (no intermediate texture or blit), which RealityKit displays on the curved dome mesh.

### Problem 2: MainActor Starvation

**The Problem**: visionOS's `TimelineView(.animation)` runs at 90fps and consumes ALL MainActor capacity. Any code waiting for MainActor scheduling (like `@Published` property updates) starves indefinitely.

**Symptoms on visionOS with @Published**:
- Image updates never appear
- UI freezes
- Transitions don't happen

**Solution**: `AtomicImageBuffer` uses `OSAllocatedUnfairLock` for lock-free image passing:
```swift
final class AtomicImageBuffer: @unchecked Sendable {
    nonisolated(unsafe) private var _current: CGImage?
    private let lock = OSAllocatedUnfairLock()

    func loadCurrent() -> CGImage? {
        lock.withLock { _current }  // No MainActor involvement
    }
}
```

**Why macOS doesn't need this**: At 60fps, there's sufficient MainActor capacity for @Published observation. The starvation only occurs at visionOS's 90fps rate.

### GPU Shader Crossfade (Both Platforms)

Both platforms now use GPU shader blending for crossfades. The shader receives:
- `sourceTexture` - the current (target) image
- `previousTexture` - the previous (from) image
- `transitionProgress` - 0.0 to 1.0 progress value

```metal
// In fragment shader - identical on both platforms
float eased = easeInOutCubic(uniforms.transitionProgress);
float4 sourceColor = sourceTexture.sample(s, uv);
float4 prevColor = previousTexture.sample(s, uv);
float4 blended = mix(prevColor, sourceColor, eased);
```

**Previous approach** (deprecated): macOS previously used Core Image `CIDissolveTransition`, but this has been removed in favor of the unified GPU approach for consistency and performance.

### Problem 4: Texture Bridging

**The Challenge**: RealityKit expects `TextureResource`, Metal produces `MTLTexture`. These are incompatible types.

**Solution**: `TextureResource.DrawableQueue` provides the bridge:
```swift
let descriptor = TextureResource.DrawableQueue.Descriptor(
    pixelFormat: .bgra8Unorm,
    width: 2048, height: 2048,
    usage: [.renderTarget, .shaderRead, .shaderWrite],
    mipmapsMode: .none
)
let queue = try TextureResource.DrawableQueue(descriptor)
textureResource.replace(withDrawables: queue)
```

Metal renders to the drawable's texture, calls `drawable.present()`, and RealityKit displays it.

---

## What IS Shared (100%)

| Component | File | Purpose |
|-----------|------|---------|
| **Shader code** | `Shaders/EffectsRenderer.metal` | All visual effects (Ken Burns, distortion, hue shifts, feedback) |
| **Uniform computation** | `Visual/EffectsUniformsComputer.swift` | Deterministic animation math |
| **Uniform structure** | `EffectsUniforms.swift` | Shader parameter data |
| **Audio system** | `Audio/*` | Eight-layer generative ambient engine (AudioKit), `MusicState` read by both renderers |
| **Audio-visual coupling** | `Visual/MusicReactor.swift`, `Visual/MusicModulation.swift`, `Visual/VisualMoodBuilder.swift` | Music -> clamped uniform nudges; image -> mood sent to the music |
| **Image generation** | `Visual/GeminiClient.swift` | Gemini API client |
| **Image pipeline** | `Visual/ImageQueue.swift`, `Visual/ImageStore.swift`, `Visual/ImageFraming.swift` | Buffering, disk persistence, 3:2 crop |
| **Settings** | `Services/SettingsService.swift` | UserDefaults persistence (incl. `visual.syncToMusic`) |
| **Control UI pieces** | `ControlComponents.swift`, `ClearImagesSection.swift` | Sections, value sliders, pickers, toggles used by both UIs |
| **Platform abstraction** | `PlatformImage.swift` | NSImage/UIImage typealias |

### Key Insight: Same Shader, Different Delivery

The actual visual effects are 100% identical on both platforms. The same Metal shader code runs with the same uniform values computed by `EffectsUniformsComputer`. The only difference is HOW the shader output reaches the screen.

---

## What IS Platform-Specific

### macOS Only

| File | Purpose |
|------|---------|
| `LiminalApp.swift` | App entry point with WindowGroup |
| `ContentView.swift` | Main UI: scrolling 320 pt control panel plus the 3:2 visual area; "Storage & Settings" sheet |
| `Visual/EffectsMetalView.swift` | MTKView-based Metal rendering |
| `Visual/TimerDrivenCrossfade.swift` | Timer-driven transition manager (tracks progress for GPU shader) |

### visionOS Only

| File | Purpose |
|------|---------|
| `visionOS/LiminalVisionApp.swift` | App entry point with ImmersiveSpace |
| `visionOS/ControlsView.swift` | Control window (1240x800, three columns, no settings sheet) |
| `visionOS/SpatialDioramaView.swift`, `LowLevelDomeMesh.swift`, `StereoMaterialBuilder.swift` | Diorama, dome mesh and stereo material |
| `visionOS/ImmersiveDomeView.swift` | RealityKit curved panel + render loop + `CGImageTransitionState` |
| `visionOS/OffscreenEffectsRenderer.swift` | Metal → DrawableQueue bridge |
| `Visual/AtomicImageBuffer.swift` | Lock-free image passing |

**Note**: `CGImageTransitionState` is a lightweight struct embedded in `ImmersiveDomeView.swift` that tracks transitions without @Published overhead. It includes an `easedProgress` property for smoother perceptual transitions.

---

## Architecture Diagram

### macOS Pipeline
```
ImageQueue (@Published)
    ↓
TimerDrivenCrossfade (tracks progress)
    ↓
EffectsMetalView (MTKView)
    ↓
EffectsRenderer.metal (shader + GPU blend)
    ↓
Window Framebuffer
```

### visionOS Pipeline
```
ImageQueue
    ↓
AtomicImageBuffer (lock-free)
    ↓
ImmersiveDomeView (polls buffer)
    ↓
OffscreenEffectsRenderer (Metal offscreen)
    ↓
EffectsRenderer.metal (shader + GPU blend)
    ↓
DrawableQueue → TextureResource
    ↓
RealityKit Curved Dome Mesh
```

---

## Design Decisions

### Why Not Unify to One Pipeline?

We evaluated using the visionOS approach (offscreen rendering + lock-free buffers) on macOS. The expert consensus was **against unification**:

| Concern | Analysis |
|---------|----------|
| Offscreen rendering overhead | Adds extra blit step with no benefit on macOS |
| Loss of MTKView benefits | Automatic vsync, display link, drawable management |
| AtomicImageBuffer complexity | Not needed - macOS 60fps doesn't starve MainActor |
| Testing burden | Would need to test a new pipeline that wasn't battle-tested |

**Conclusion**: Keep platform-specific rendering. The shared shader code ensures visual parity, while each platform uses its optimal rendering path.

### Why AtomicImageBuffer Instead of Async Streams?

Modern Swift concurrency (AsyncStream, actors) is designed for await-based consumption. The visionOS render loop needs to **poll** at 90fps without blocking. `OSAllocatedUnfairLock` with CGImage is the right pattern for this polling hot path.

### Why DrawableQueue Instead of LowLevelTexture?

visionOS 2.0 introduced `LowLevelTexture` as an alternative, but it's better suited for compute shader pipelines. `DrawableQueue` provides explicit frame timing control which is valuable for animation.

---

## Performance Characteristics

### macOS
- **Target FPS**: 60 (MTKView.preferredFramesPerSecond)
- **Texture size**: Matches window size
- **Memory**: ~16MB per texture at 2048×2048

### visionOS
- **Target FPS**: ~60 actual (90 capable, throttled via Task.sleep)
- **Texture size**: Fixed 2048×2048
- **Memory**: Same per-texture, plus DrawableQueue overhead
- **Critical**: `Task.yield()` in render loop prevents MainActor starvation

---

## Color Space Handling

The shader works on **gamma-encoded sRGB values** on both platforms (sources are `bgra8Unorm`
holding sRGB bytes; nothing is linearised), and both platforms store those values unchanged:

- **macOS**: `MTKView` is `bgra8Unorm`; the drawable bytes are the shader's values.
- **visionOS**: the DrawableQueue is `bgra8Unorm_srgb` (so RealityKit decodes on sample), but every
  pass renders into a cached **`bgra8Unorm` view** of the drawable (`OffscreenEffectsRenderer.outputView`).
  Rendering into the `_srgb` format directly encoded the values a second time (mid-grey 128 showed as
  ~188, saturation -33%). Verified in the simulator with the test card's grey patches
  (docs/decisions/vibrance.md, V1).

Feedback trails: macOS copies its drawable into a feedback texture; visionOS binds each eye's
previous output view (texture 4, right eye texture 6 in the MRT pass), no copy (V2).

The final shader stage is VIBRANCE (luminance-preserving chroma gain, gamut-safe); its amount comes
from `EffectsUniformsComputer.computeVibrance` times a per-image factor (`ImageColorStats`).

---

## Adding New Effects

When adding visual effects:

1. **Add to shader** (`Shaders/EffectsRenderer.metal`) - works on both platforms
2. **Add uniforms** (`EffectsUniforms.swift`) - shared data structure
3. **Compute values** (`EffectsUniformsComputer.swift`) - shared math
4. **Pass uniforms** - platform-specific (EffectsMetalView / OffscreenEffectsRenderer)

The last step is the only platform-specific work, and it's minimal (just passing the uniform buffer).

---

## Summary

The dual-pipeline architecture exists because macOS and visionOS have fundamentally different display requirements:

- **macOS**: Window-based, 60fps, direct Metal via MTKView
- **visionOS**: Spatial/immersive, 90fps, RealityKit-based with MainActor constraints

The architecture maximizes code sharing (audio, shaders, uniforms, services) while respecting each platform's native patterns. This is the correct approach - unification would add complexity without benefit.

## visionOS render path (post performance work)

- Both eyes render in a single MRT pass directly into the two RealityKit `DrawableQueue` drawables
  (2048x2048 each); there is no intermediate output texture or blit, and the distortion field is computed once.
- Dome breathing is computed on the CPU (no per-frame compute command buffer).
- Drawable queues no longer request `.shaderWrite`; uploaded source textures use `optimizeContentsForGPUAccess`.
- GPU timing: `Utils/GPUTimingStats.swift`; DEBUG launch flags: `Utils/DebugLaunchOptions.swift`;
  capture script: `scripts/perf-run.sh`. See `docs/decisions/performance.md`.

## Image orientation and aspect

One convention on both platforms: texture row 0 / texCoord.y = 0 is the image top. The visionOS upload
draws into the CGBitmapContext unflipped. The effects pass maps rows 1:1 into the drawable. Dome UVs
use v = 1 at the top, and the mono UnlitMaterial and stereo ShaderGraph material both sample row
`(1 - v) * H`. Every source is centre-cropped to 3:2 (`ImageFraming`). The square 2048² target stores
the 3:2 frame and the 112.5°×75° dome shows it undistorted. macOS letterboxes its view to 3:2. Details,
measurements and the DEBUG test-card flags: `docs/decisions/orientation.md`.

## Audio-visual coupling (both platforms)

`MusicReactor` (one per render loop, smoothing on the effect clock) turns `engine.musicState` snapshots into a `MusicModulation`, which `EffectsUniformsComputer.compute(..., music:)` converts into existing uniforms with hard clamps; `.neutral` reproduces the un-coupled output and no shader or uniform-struct change was needed. Scene changes request a small ghost-tap burst (`OffscreenEffectsRenderer.requestGhostBurst` on visionOS, `EffectsMetalViewRepresentable.ghostBurstSerial` on macOS). In the other direction `VisualMoodBuilder` sends `setVisualMood` and `imageDidChange` at crossfade start and `setVisualActivity` at most twice a second. `-LiminalFreezeTime` bypasses the coupling. Decisions: `decisions/av-coupling.md`.

## Control UI

Both platforms share the same four sections (Playback, Music, Visuals, Images & Storage) built from `ControlComponents.swift`. visionOS opens a 1240x800 window with no settings sheet; macOS has a 320 pt scrolling panel and a "Storage & Settings" sheet. Decisions: `decisions/ui.md`.
