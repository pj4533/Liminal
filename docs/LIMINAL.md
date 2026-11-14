# Liminal - Generative Ambient Audio-Visual Experience

A macOS app that generates endless, evolving ambient music synchronized with AI-generated visuals that morph continuously. The system runs autonomously but provides abstract controls for users to "shape" the experience without directly controlling it.

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
┌─────────────────────────────────────────────────────────────────┐
│                        SwiftUI UI                                │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐     │
│  │   Sliders    │  │ Scale Picker │  │  Visual Display    │     │
│  │ delay        │  │              │  │  (EffectsMetalView)│     │
│  │ reverb       │  │              │  │                    │     │
│  │ notes        │  │              │  │                    │     │
│  └──────────────┘  └──────────────┘  └────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      SettingsService                             │
│  Persists all settings to UserDefaults                           │
│  Single source of truth for UI and engines                       │
└─────────────────────────────────────────────────────────────────┘
              │                                    │
              ▼                                    ▼
┌──────────────────────────┐      ┌──────────────────────────────┐
│     AUDIO ENGINE         │      │      VISUAL ENGINE           │
│     (AudioKit)           │      │                              │
│                          │      │  ┌────────────────────────┐  │
│  ┌────────────────────┐  │      │  │ GeminiClient           │  │
│  │ Bass Voice (drone) │  │      │  │ (Nano Banana model)    │  │
│  │ 2 detuned oscs     │  │      │  └──────────┬─────────────┘  │
│  └────────────────────┘  │      │             │                │
│  ┌────────────────────┐  │      │             ▼                │
│  │ Mid Voice (pad)    │  │      │  ┌────────────────────────┐  │
│  │ 4 detuned oscs     │  │      │  │ ImageUpscaler          │  │
│  └────────────────────┘  │      │  │ (CoreML RealESRGAN 4x) │  │
│  ┌────────────────────┐  │      │  └──────────┬─────────────┘  │
│  │ Shimmer Voice      │  │      │             │                │
│  │ soft pings         │  │      │             ▼                │
│  └────────────────────┘  │      │  ┌────────────────────────┐  │
│           │              │      │  │ ImageCache             │  │
│           ▼              │      │  │ (persistent storage)   │  │
│  ┌────────────────────┐  │      │  └──────────┬─────────────┘  │
│  │ Effects Chain      │  │      │             │                │
│  │ - Reverb           │  │      │             ▼                │
│  │ - Delay            │  │      │  ┌────────────────────────┐  │
│  └────────────────────┘  │      │  │ MorphPlayer            │  │
│                          │      │  │ (GPU crossfade)        │  │
│                          │      │  └──────────┬─────────────┘  │
│                          │      │             │                │
│                          │      │             ▼                │
│                          │      │  ┌────────────────────────┐  │
│                          │      │  │ EffectsMetalView       │  │
│                          │      │  │ (unified GPU effects)  │  │
│                          │      │  │ - Ken Burns            │  │
│                          │      │  │ - fBM Distortion       │  │
│                          │      │  │ - Spatial Hue Shift    │  │
│                          │      │  │ - Saliency Hue         │  │
│                          │      │  │ - Feedback Trails      │  │
│                          │      │  └────────────────────────┘  │
└──────────────────────────┘      └──────────────────────────────┘
```

## File Structure

```
Liminal/
├── Liminal.xcodeproj/
│   └── xcshareddata/xcschemes/
│       └── Liminal.xcscheme         # Shared scheme (no secrets)
├── Liminal/
│   ├── LiminalApp.swift             # App entry point
│   ├── ContentView.swift            # Main UI + VisualDisplayView
│   ├── SecretsTemplate.swift        # API key placeholder
│   │
│   ├── Audio/
│   │   ├── GenerativeEngine.swift   # Facade (UI, settings, hooks)
│   │   ├── MusicConductor.swift     # Off-main scheduler, scenes, layers
│   │   ├── MusicState.swift         # Lock-free state bus for visuals
│   │   ├── MixBus.swift             # Sends, reverb, delay, shimmer, limiter
│   │   ├── Layers/                  # Drone, Pad, Lead, Keys, Drips, Air, Grains, Pluck
│   │   └── Harmony.swift, SceneDirector.swift, Scale.swift, ...
│   │
│   ├── Visual/
│   │   ├── VisualEngine.swift       # Coordinates image generation
│   │   ├── GeminiClient.swift       # Gemini API (Nano Banana model)
│   │   ├── ImageQueue.swift         # Maintains buffer of images
│   │   ├── ImageUpscaler.swift      # CoreML RealESRGAN 4x upscale
│   │   ├── ImageCache.swift         # Persistent image storage
│   │   ├── MorphPlayer.swift        # GPU crossfade transitions
│   │   ├── EffectsMetalView.swift   # Unified Metal effects renderer
│   │   ├── DepthAnalyzer.swift      # Vision saliency analysis
│   │   └── VisualEffects.swift      # EffectController (time driver)
│   │
│   ├── Shaders/
│   │   ├── EffectsRenderer.metal    # All effects in single GPU pass
│   │   └── DreamyEffects.metal      # SwiftUI shader wrappers (legacy)
│   │
│   ├── Services/
│   │   ├── EnvironmentService.swift # API key management
│   │   ├── SettingsService.swift    # UserDefaults persistence
│   │   └── LMLog.swift              # Unified OSLog logging
│   │
│   ├── Utils/
│   │   └── Logger.swift             # LMLog enum
│   │
│   └── Resources/
│       ├── Assets.xcassets
│       └── realesrgan512.mlmodelc   # RealESRGAN CoreML model
```

## Key Components

### Audio System

**GenerativeEngine** is a facade over `MusicConductor` (own serial queue, 20 ms tick, nothing on MainActor). Eight synthesized layers (drone, pad, lead, keys, drips, air, grains, pluck) are shaped by a SceneDirector (stillness, drift, bloom, constellation, tide), a drifting harmonic field and rare events, and mixed through Zita reverb, delay, shimmer and a limiter. Full description: `docs/plans/music-current.md`; decisions: `docs/decisions/music.md`. The render loop can read `engine.musicState` (lock-free `MusicState`) and the image pipeline can call `setVisualMood`, `imageDidChange`, `setVisualActivity` (not yet wired).

**Controls** (via SettingsService): Style (`audio.style`), Density (`audio.notes`), Space (`audio.reverb`), Echo (`audio.delay`, also the visual trail), Scale with Auto (`audio.scaleAuto`, `audio.scale`).

### Visual System

**Image Generation Pipeline**:
```
Prompt → Gemini API (gemini-2.5-flash-image) → 1024px image
    → Resize to 512px → CoreML RealESRGAN → 2048px upscaled
    → ImageCache (persistent ~/Library/Application Support/Liminal/)
```

**MorphPlayer**: GPU-accelerated crossfade transitions via CIDissolveTransition
- 1.5 second transitions at 30fps
- Cubic ease-in-out for smooth motion
- Generates saliency maps for each image (async)

**EffectsMetalView**: All visual effects in single Metal GPU pass:
- Ken Burns (scale + pan)
- fBM Distortion (underwater warping)
- Spatial Hue Shift (rainbow waves)
- Saliency-Based Hue (subjects vs background)
- Feedback Trails (expanding ghost frames)

See [LIMINAL_EFFECTS.md](LIMINAL_EFFECTS.md) for detailed effect documentation.

### Settings System

**SettingsService** - Single source of truth, persists to UserDefaults:

| Setting | Key | Default | Description |
|---------|-----|---------|-------------|
| delay | audio.delay | 0.5 | Delay amount + visual trail intensity |
| reverb | audio.reverb | 0.5 | Reverb mix |
| notes | audio.notes | 0.5 | Shimmer note frequency |
| currentScale | audio.scale | Pentatonic Major | Musical scale |
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
- Gemini API (gemini-2.5-flash-image / "Nano Banana") - Image generation

**Frameworks**:
- Metal / MetalKit - GPU effects rendering
- CoreML - RealESRGAN upscaling
- Vision - Saliency analysis
- CoreImage - GPU crossfade transitions
- Combine - Reactive state management

## Logging

Uses unified OSLog via `LMLog` enum:

```swift
LMLog.audio.info("Voice started")
LMLog.visual.debug("Morph frame 30/60")
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
