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
│   │   ├── GenerativeEngine.swift   # Main audio coordinator
│   │   ├── VoiceLayer.swift         # Single voice with oscillators
│   │   ├── EffectsChain.swift       # Reverb + Delay
│   │   ├── MarkovChain.swift        # Note selection
│   │   └── Scale.swift              # Scale definitions
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

**GenerativeEngine** - Coordinates three voice layers playing continuously:
- **Bass Voice**: Low drone (MIDI 36-48), 2 detuned oscillators, 4s attack, 8s release
- **Mid Voice**: Pad layer (MIDI 48-72), 4 detuned oscillators, 2.5s attack, 6s release
- **Shimmer Voice**: High pings (MIDI 72-84), single oscillator, short staccato notes

**Controls** (via SettingsService):
| Slider | Audio Effect |
|--------|--------------|
| Delay | Delay feedback (0.3-0.8) and mix (0.2-0.7) |
| Reverb | Reverb mix (0.3-0.9) |
| Notes | Shimmer note frequency (gap between pings) |

**Scale System**: Markov chains select notes within the current scale. Available scales:
- Pentatonic Major/Minor
- Major, Natural Minor
- Dorian, Mixolydian, Lydian

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
