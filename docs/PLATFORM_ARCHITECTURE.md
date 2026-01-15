# Platform Architecture: macOS vs visionOS

This document explains the architectural differences between Liminal's macOS and visionOS implementations, why they exist, and what code is shared between platforms.

## Rendering Pipeline Comparison

| Aspect | macOS | visionOS | Why Different |
|--------|-------|----------|---------------|
| **Rendering API** | MTKView (direct Metal) | Offscreen Metal → DrawableQueue → RealityKit | MTKView unavailable on visionOS; RealityKit is native |
| **Display Surface** | Window framebuffer | Curved dome mesh (110°×75°) | visionOS is spatial/immersive |
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

The `OffscreenEffectsRenderer` handles Metal rendering to a 2048×2048 texture, which is then presented to a `TextureResource.DrawableQueue` that RealityKit can display on the curved dome mesh.

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
| **Audio system** | `Audio/*` | Generative ambient audio (AudioKit) |
| **Image generation** | `Visual/GeminiClient.swift` | Gemini API client |
| **Image pipeline** | `Visual/ImageQueue.swift`, `Visual/ImageCache.swift` | Buffering and persistence |
| **Settings** | `Services/SettingsService.swift` | UserDefaults persistence |
| **Platform abstraction** | `PlatformImage.swift` | NSImage/UIImage typealias |

### Key Insight: Same Shader, Different Delivery

The actual visual effects are 100% identical on both platforms. The same Metal shader code runs with the same uniform values computed by `EffectsUniformsComputer`. The only difference is HOW the shader output reaches the screen.

---

## What IS Platform-Specific

### macOS Only

| File | Purpose |
|------|---------|
| `LiminalApp.swift` | App entry point with WindowGroup |
| `ContentView.swift` | Main UI with sidebar controls |
| `Visual/EffectsMetalView.swift` | MTKView-based Metal rendering |
| `Visual/TimerDrivenCrossfade.swift` | Timer-driven transition manager (tracks progress for GPU shader) |

### visionOS Only

| File | Purpose |
|------|---------|
| `visionOS/LiminalVisionApp.swift` | App entry point with ImmersiveSpace |
| `visionOS/ControlsView.swift` | Floating controls window |
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

Both platforms use `.bgra8Unorm` textures, but color management differs:

- **macOS**: Device RGB (implicit sRGB for display)
- **visionOS**: `.raw` semantic on TextureResource prevents sRGB conversion

This ensures identical color output despite different display pipelines.

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
