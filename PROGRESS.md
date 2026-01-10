# Liminal Development Progress

## Current Status: Phase 4 - Visual Generation (COMPLETE)

**Last Updated:** 2026-01-10

## Completed

### Phase 0: Project Setup & Secrets
- [x] Created `Liminal/.gitignore`
- [x] Created shared scheme `Liminal.xcscheme` in xcshareddata
- [x] Created `SecretsTemplate.swift` with GEMINI_API_KEY placeholder
- [x] Created `Services/EnvironmentService.swift`
- [x] Updated root `.gitignore` to ignore Liminal xcuserdata
- [x] Verified Liminal-Dev scheme loads API key correctly

### Phase 1: Audio Foundation (DONE)
- [x] Added AudioKit + SoundpipeAudioKit packages
- [x] Created `Audio/AudioEngine.swift` with basic DynamicOscillator
- [x] Added Play/Stop button to ContentView - **AUDIO WORKS!** (buzzy 220Hz tone)
- [x] Created `Utils/Logger.swift` (LMLog unified logging)
- [x] Updated EnvironmentService to use LMLog
- [x] Created `Audio/VoiceLayer.swift` with detuned oscillators + envelope
- [x] Fixed fade-out bug (envelope now fades to silence naturally)
- [x] Created `Audio/EffectsChain.swift` with reverb + delay
- [x] Fixed clicking bug: use `Oscillator` not `DynamicOscillator` (wavetable discontinuity)

### Phase 2: Generative Music (DONE)
- [x] Created `Audio/Scale.swift` with pentatonic, major modes, dorian, etc.
- [x] Created `Audio/MarkovChain.swift` with voice-specific presets (bass/mid/shimmer)
- [x] Created `Audio/GenerativeEngine.swift` with 3 voice layers
- [x] Wired up ContentView with scale picker

### Phase 3: Mood System (DONE)
- [x] Created `State/MoodState.swift` with brightness, tension, density, movement parameters
- [x] Added `MoodSlidersView` UI component with 4 sliders
- [x] Wired mood to audio: reverb mix, delay feedback, auto scale selection
- [x] Mood observation via Combine in GenerativeEngine

### Phase 4: Visual Generation (DONE)
- [x] Created `Visual/GeminiClient.swift` - async Gemini API for image generation
- [x] Created `Visual/ImageQueue.swift` - buffers 2-3 images ahead
- [x] Created `Visual/VisualEngine.swift` - coordinates generation, mood-based prompts
- [x] Added image display to ContentView with split layout
- [x] Connected mood changes to image triggers (threshold-based)

## Not Started

### Phase 5: Visual Morphing
- RIFE integration
- Metal shader fallback
- Display pipeline

### Phase 6: Integration & Polish
- Connect mood changes to image triggers
- Particle overlay system
- Performance optimization

## Key Files

| File | Purpose |
|------|---------|
| `Audio/GenerativeEngine.swift` | Main audio engine: 3 voices + effects + mood integration |
| `Audio/VoiceLayer.swift` | Detuned oscillators + envelope for soft pads |
| `Audio/EffectsChain.swift` | Reverb (CostelloReverb) + delay (VariableDelay) |
| `Audio/Scale.swift` | Musical scales (pentatonic, dorian, etc.) |
| `Audio/MarkovChain.swift` | Probabilistic note selection |
| `Visual/VisualEngine.swift` | Coordinates image generation and mood-based prompts |
| `Visual/GeminiClient.swift` | Async Gemini REST API client for image generation |
| `Visual/ImageQueue.swift` | Buffers pre-generated images for smooth transitions |
| `State/MoodState.swift` | Observable mood: brightness, tension, density, movement |
| `Services/EnvironmentService.swift` | API key management |
| `Utils/Logger.swift` | LMLog unified logging |
| `SecretsTemplate.swift` | Placeholder for API keys |

## Dependencies

- AudioKit (core framework)
- SoundpipeAudioKit (oscillators, effects, filters)

## Plan Location

Full plan at: `/Users/pj4533/.claude/plans/synchronous-wondering-kettle.md`
