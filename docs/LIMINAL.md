# Liminal - Generative Ambient Audio-Visual Experience

A macOS app that generates endless, evolving ambient music synchronized with AI-generated visuals that morph continuously. The system runs autonomously but provides abstract controls for users to "shape" the experience without directly controlling it.

> **Status note (2026-11-14):** this overview was synced with the code after the music, images, vibrance, orientation, performance, coupling and UI work. Older diagrams were replaced. For the up-to-date entry point see `README.md`; platform details are in `PLATFORM_ARCHITECTURE.md`; decisions are indexed in `decisions/README.md`.

## Quick Start

```bash
cd ~/Developer/Liminal
open Liminal.xcodeproj
# Use Liminal-Dev scheme (has GEMINI_API_KEY environment variable)
# Build and run (Cmd+R)
```

**CLI Build:**
```bash
cd ~/Developer/Liminal && xcodebuild -scheme Liminal -destination 'platform=macOS' build
```

## Architecture Overview

```
SwiftUI UI (Playback, Music, Visuals, Images & Storage; shared pieces in ControlComponents.swift)
        |
SettingsService (UserDefaults; single source of truth for UI and engines)
        |
  +-----+------------------------------+
  |                                    |
AUDIO: GenerativeEngine (facade)    VISUAL: VisualEngine
  MusicConductor (own queue)          PromptDirector / PromptBuilder -> GeminiClient (ModelRouter)
  SceneDirector, Harmony, 8 layers    ImageQueue + ImageStore (disk) -> ImageUpscaler / MetalFXUpscaler
  MixBus (reverb, delay, shimmer,     3:2 centre crop (ImageFraming), ImageColorStats, saliency, depth
  limiter)                            EffectsUniformsComputer -> EffectsRenderer.metal
  MusicState (lock-free) ----------> MusicReactor -> MusicModulation (clamped uniform nudges)
  setVisualMood / imageDidChange <--- VisualMoodBuilder (metadata + pixels)
  / setVisualActivity
                                      macOS: EffectsMetalView (MTKView)
                                      visionOS: OffscreenEffectsRenderer (one MRT pass, both eyes)
                                                -> DrawableQueue -> RealityKit dome
```

## File Structure

```
Liminal/
  LiminalApp.swift, ContentView.swift, ControlComponents.swift, ClearImagesSection.swift
  EffectsUniforms.swift          # must match the Metal struct exactly
  Audio/        GenerativeEngine (+Settings), MusicConductor, MusicState, MusicScheduler, MixBus,
                SceneDirector, Harmony, Scale, VisualCoupling, OfflineRender, Layers/ (8 layers)
  Visual/       VisualEngine, GeminiClient, ModelRouter, ImageQueue, ImageStore, ImageUpscaler,
                MetalFXUpscaler, ImageFraming, ImageColorStats, ImageMetadata, DepthAnalyzer,
                EffectsMetalView, EffectsUniformsComputer, MusicModulation, MusicReactor,
                VisualMoodBuilder, GhostTapManager, SmoothOscillator, TimerDrivenCrossfade,
                AtomicImageBuffer, Prompt/ (PromptLibrary, PromptBuilder, ...)
  Shaders/      EffectsRenderer.metal (all effects), DreamyEffects.metal (legacy, unused)
  Services/     SettingsService, EnvironmentService
  Utils/        Logger (LMLog), DebugLaunchOptions, GPUTimingStats, TestPatternGenerator
  visionOS/     LiminalVisionApp, ControlsView, ImmersiveDomeView, OffscreenEffectsRenderer,
                LowLevelDomeMesh, StereoMaterialBuilder, SpatialDioramaView
LiminalTests/   AVCouplingTests, ImagePipelineTests, MusicRenderTests, PromptBuilderTests, ...
scripts/, tools/ (ShaderBench, VibranceHarness), docs/
```

## Key Components

### Audio System

**GenerativeEngine** is a facade over `MusicConductor` (own serial queue, 20 ms tick, nothing on MainActor). Eight synthesized layers (drone, pad, lead, keys, drips, air, grains, pluck) are shaped by a SceneDirector (stillness, drift, bloom, constellation, tide), a drifting harmonic field and rare events, and mixed through Zita reverb, delay, shimmer and a limiter. Full description: `docs/plans/music-current.md`; decisions: `docs/decisions/music.md`. The render loop can read `engine.musicState` (lock-free `MusicState`) and the image pipeline can call `setVisualMood`, `imageDidChange`, `setVisualActivity` (wired through `VisualMoodBuilder` and `MusicReactor`; see `decisions/av-coupling.md`).

**Controls** (via SettingsService): Style (`audio.style`), Density (`audio.notes`), Space (`audio.reverb`), Echo (`audio.delay`, also the visual trail), Scale with Auto (`audio.scaleAuto`, `audio.scale`).

### Visual System

**Image pipeline**:
```
Style x subject x transformation x palette x composition prompt (PromptBuilder)
  -> Gemini (gemini-3.1-flash-image, 3:2 at 2K; ModelRouter fallbacks)
  -> ImageStore (disk, with metadata) -> upscale if small -> centre-crop to 3:2
```
There is no MorphPlayer or ImageCache any more: `ImageQueue` and `ImageStore` hold images, and the crossfade is done in the shader (`transitionProgress`), driven by `TimerDrivenCrossfade` on macOS and `CGImageTransitionState` on visionOS.

**Shader** (`EffectsRenderer.metal`, one pass): Ken Burns, distortion, stereo parallax, chromatic aberration, crossfade, spatial/saliency/fractal hue, contrast and saturation, ghost taps, stochastic bloom, feedback warping, vibrance. See `LIMINAL_EFFECTS.md` and `decisions/vibrance.md`.

**Orientation**: texture row 0 is the image top everywhere (`decisions/orientation.md`).

### Settings System

**SettingsService** - Single source of truth, persists to UserDefaults:

| Setting | Key | Default | Description |
|---------|-----|---------|-------------|
| delay | audio.delay | 0.5 | Delay amount + visual trail intensity |
| reverb | audio.reverb | 0.5 | Reverb size and shimmer |
| notes | audio.notes | 0.5 | Density of the pointed layers |
| style | audio.style | Drift | Music style |
| scaleAuto / currentScale | audio.scaleAuto, audio.scale | Auto | Scale pin |
| syncVisualsToMusic | visual.syncToMusic | true | Music drives visuals |
| imageInterval | visual.imageInterval | 30.0 | Seconds between image advances |
| cacheOnly | visual.cacheOnly | false | Skip generation, use cached images |

## Secrets Management

Uses JuceyTV pattern for Xcode Cloud compatibility:

| Scheme | Contains Secrets | Committed |
|--------|------------------|-----------|
| Liminal.xcscheme | NO | YES |
| Liminal-Dev.xcscheme | YES (GEMINI_API_KEY) | NO |

**Local Development**: Use `Liminal-Dev` scheme which has `GEMINI_API_KEY` in environment variables.

## Dependencies

**Swift Packages**:
- AudioKit 5.x - Audio synthesis and effects
- AudioKitEX - Additional DSP
- SoundpipeAudioKit - Oscillators

**APIs**:
- Gemini API (gemini-3.1-flash-image, fallbacks in `ImageGenerationConfig`) - Image generation

**Frameworks**:
- Metal / MetalKit - GPU effects rendering
- CoreML - RealESRGAN upscaling
- Vision - Saliency analysis
- MetalFX - upscaling on visionOS device
- Combine - Reactive state management

## Logging

Uses unified OSLog via `LMLog` enum:

```swift
LMLog.audio.info("Voice started")
LMLog.visual.debug("image queued")
LMLog.gemini.error("API call failed")
```

Categories: `.general`, `.audio`, `.visual`, `.state`, `.ui`, `.gemini`

## Design Philosophy

The app embodies "indirect control" - users shape the experience through abstract parameters rather than direct manipulation. Both audio and visual systems should:

1. **Always be evolving** - Never static, always in motion
2. **Feel organic** - Smooth, flowing, natural (not glitchy)
3. **Respond to controls** - All parameters influence the output
4. **Run autonomously** - Can be left running indefinitely

The visuals mirror the audio philosophy: AI generation provides the basis, but continuous effects and transitions provide the constant movement.
