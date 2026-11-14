# Liminal Visual Effects

Complete documentation of the visual effects system. All effects are rendered in a **single Metal GPU pass** via `EffectsMetalView` for maximum performance.

---

> **Status (2026-11-14): partly historical.** The per-effect sections below (1-6) describe the original design and still explain the intent of each effect, but several details are stale: `MorphPlayer.swift` and `CIDissolveTransition` no longer exist (the crossfade is a shader blend driven by `transitionProgress`), Ken Burns and all uniforms are computed in `Visual/EffectsUniformsComputer.swift` (not `ContentView.swift`), the uniform struct has more fields (read `Liminal/EffectsUniforms.swift`), and macOS no longer renders a separate copy pass. The shader is the source of truth: `Liminal/Shaders/EffectsRenderer.metal`. Later additions are documented in `docs/decisions/vibrance.md` (vibrance stage, chroma-preserving blends, feedback on visionOS), `docs/decisions/performance.md` (MRT stereo pass, shader optimizations) and `docs/decisions/av-coupling.md` (music-driven modulation).

## Effect Stack

Current order in `EffectsRenderer.metal` (both platforms):

```
Source Image
  -> Ken Burns Transform (scale + offset)
  -> Distortion (turbulence, log-spherical, sinusoidal interference)
  -> Stereo depth parallax (visionOS) + chromatic aberration
  -> Crossfade (previous -> current, eased)
  -> Spatial Hue Shift (rainbow waves)
  -> Saliency-Based Hue Variation
  -> Contrast / Saturation
  -> Fractal hue cycling
  -> Ghost Taps (discrete delay echoes)
  -> Stochastic Bloom
  -> Feedback Warping (trails)
  -> Vibrance (black point, chroma gain, gamut-safe)
  -> Output
```

---

## 1. Ken Burns Effect

**Location:** `ContentView.swift` (computed properties) → passed to `EffectsMetalView`

**What it does:** Slow, continuous zoom and pan across the image. Uses compound sine waves at different frequencies so it never repeats exactly.

### Parameters

| Property | Formula | Result |
|----------|---------|--------|
| `kenBurnsScale` | `1.2 + 0.15*sin(t*0.05) + 0.05*sin(t*0.03)` | Oscillates 1.05 - 1.40 |
| `kenBurnsOffset` | Lissajous pattern with multiple frequencies | ±60-80px drift |

### Code Location
```swift
// ContentView.swift
private var kenBurnsScale: CGFloat {
    let base = 1.2
    let variation = 0.15 * sin(effectController.time * 0.05) + 0.05 * sin(effectController.time * 0.03)
    return CGFloat(base + variation)
}
```

### Notes
- Driven by `effectController.time` (60fps, never resets)
- Compound sine waves prevent repetitive patterns
- No parameters exposed to UI - runs autonomously

---

## 2. Dreamy Distortion (fBM)

**File:** `EffectsRenderer.metal` → `fbm_distort()`

**What it does:** Fractal Brownian Motion displacement creates underwater/heat haze warping. 5 octaves of simplex noise with oscillating rotation.

### Uniforms

| Parameter | Default | Description |
|-----------|---------|-------------|
| `distortionAmplitude` | 0.012 (base) | Displacement strength |
| `distortionSpeed` | 0.08 | Animation speed multiplier |

### Transition Boost

During crossfade transitions, amplitude is boosted **10x** to mask the blend:

```swift
// ContentView.swift
private var distortionAmplitude: Double {
    let baseAmplitude = 0.012
    let boostMultiplier = 10.0
    let transitionBoost = sin(morphPlayer.transitionProgress * .pi)
    return baseAmplitude * (1.0 + (boostMultiplier - 1.0) * transitionBoost)
}
```

Peak boost occurs at 50% transition progress, smooth ramp up/down via sine.

### Technical Details
- Uses simplex noise (Stefan Gustavson implementation)
- 5 octaves, lacunarity 2.0, persistence 0.5
- Oscillating rotation prevents directional drift

---

## 3. Spatial Hue Shift (Rainbow Waves)

**File:** `EffectsRenderer.metal` (integrated into `effectsFragment`)

**What it does:** Multi-frequency sine waves create flowing rainbow bands across the image. Uses **Color blend mode** to preserve original luminance while shifting hues.

### Uniforms

| Parameter | Default | Description |
|-----------|---------|-------------|
| `hueBaseShift` | time * 0.03 | Slow global hue rotation |
| `hueWaveIntensity` | 0.5 | Rainbow band strength |
| `hueBlendAmount` | 0.65 | Effect opacity (0=off, 1=full) |
| `contrastBoost` | 1.4 | Post-effect contrast enhancement |
| `saturationBoost` | 1.3 | Post-effect saturation enhancement |

### Wave Composition

10 overlapping waves for chaotic rainbow feel:

```metal
// Horizontal (3 frequencies)
sin(uv.x * 2.0 + time * 0.2) * intensity
sin(uv.x * 5.0 - time * 0.15) * intensity * 0.6
sin(uv.x * 8.0 + time * 0.3) * intensity * 0.3

// Vertical (3 frequencies)
sin(uv.y * 3.0 + time * 0.18) * intensity * 0.8
sin(uv.y * 6.0 - time * 0.22) * intensity * 0.5
sin(uv.y * 10.0 + time * 0.25) * intensity * 0.25

// Diagonal (2 frequencies)
sin((uv.x + uv.y) * 4.0 + time * 0.12) * intensity * 0.7
sin((uv.x - uv.y) * 3.0 - time * 0.16) * intensity * 0.5

// Radial (1 frequency)
sin(distance_from_center * 12.0 - time * 0.3) * intensity * 0.5
```

### Color Blend Mode

Preserves image structure while applying rainbow colors:

```metal
// Extract original luminance
half originalLuma = dot(color.rgb, half3(0.299, 0.587, 0.114));

// After hue shift, restore original luminance
half shiftedLuma = dot(shiftedRgb, half3(0.299, 0.587, 0.114));
half3 colorBlended = shiftedRgb * (originalLuma / shiftedLuma);
```

---

## 4. Saliency-Based Hue Variation

**Files:** `DepthAnalyzer.swift` + `EffectsRenderer.metal`

**What it does:** Uses Apple Vision's objectness-based saliency to identify "interesting" regions (subjects). Subjects and background get different hue treatments, creating color separation.

### Pipeline

```
Image → DepthAnalyzer.analyzeDepth() → Saliency Map (grayscale NSImage)
    → MorphPlayer.currentSaliencyMap → EffectsMetalView → MTLTexture
    → EffectsRenderer.metal samples at each pixel
```

### Uniforms

| Parameter | Default | Description |
|-----------|---------|-------------|
| `saliencyInfluence` | 0.6 | How much saliency affects hue (0=none, 1=full) |
| `hasSaliencyMap` | auto | 1.0 if texture available, 0.0 otherwise |

### Shader Logic

```metal
// Sample saliency (0 = background, 1 = subject)
half saliency = saliencyTexture.sample(texSampler, uv).r;

// Shift hue based on saliency: subjects one direction, background opposite
float saliencyOffset = (float(saliency) - 0.5) * uniforms.saliencyInfluence;

// Apply combined shift
hsv.x = fract(hsv.x + half(baseShift + spatialOffset + saliencyOffset));

// Salient regions get slightly more saturation
float satBoost = 1.4 + float(saliency) * 0.2;  // 1.4 to 1.6
```

### Notes
- Saliency analysis is async (~50-100ms per image)
- Map is generated when images arrive in MorphPlayer
- If no map available, effect gracefully degrades to spatial-only hue shift

---

## 5. Feedback Trails (Expanding Ghost Frames)

**File:** `EffectsRenderer.metal` + `EffectsMetalView.swift`

**What it does:** Double-buffered feedback loop creates expanding ghost echoes. Each frame blends the current render with a zoomed-out, rotated version of the previous frame.

### Uniforms

| Parameter | Default | Description |
|-----------|---------|-------------|
| `feedbackAmount` | 0.5 (from delay slider × 0.85) | Trail intensity (0=none, 1=full) |
| `feedbackZoom` | 0.96 | < 1 = expand outward, > 1 = shrink inward |
| `feedbackDecay` | 0.5 | Transparency falloff (lower = faster fade) |

### Architecture

```
Frame N:
  Read from feedbackTextures[current]
  Render effects + blend with read texture
  Write to feedbackTextures[next]
  Display feedbackTextures[next]
  Swap: current = next
```

### Motion Components

```metal
// Directional drift - ghosts expand outward
float driftAngle = time * 0.12 + sin(time * 0.07) * 2.0;
float driftMagnitude = 0.03 * feedbackAmount;
float2 drift = float2(cos(driftAngle), sin(driftAngle)) * driftMagnitude;

// Spiral rotation
float rotation = sin(time * 0.15) * 0.08 + sin(time * 0.23) * 0.04;

// Zoom for depth (< 1 expands outward)
rotated *= feedbackZoom;
```

### Transparency Fade

Ghosts fade by reducing blend amount, NOT by darkening RGB (prevents overall image darkening):

```metal
// Reduce opacity instead of brightness
half effectiveAmount = half(feedbackAmount * feedbackDecay);
half3 trailsBlended = mix(currentColor, feedback.rgb, effectiveAmount);
```

### Notes
- Controlled by the **Delay slider** (higher delay = more trails)
- Ghost frames expand outward (feedbackZoom < 1)
- Layered sine waves create organic, non-repetitive motion
- Double-buffered to prevent read-after-write artifacts

---

## 6. Image Transitions (Crossfade)

**File:** (historical: `MorphPlayer.swift`, removed; now `TimerDrivenCrossfade.swift` on macOS and `CGImageTransitionState` in `ImmersiveDomeView.swift` on visionOS)

**What it does:** GPU-accelerated alpha crossfade via `CIDissolveTransition`, masked by boosted fBM distortion.

### Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `crossfadeDuration` | 1.5 seconds | Transition length |
| `targetFPS` | 30 | Blend frame rate |

### Published Properties

| Property | Type | Description |
|----------|------|-------------|
| `currentFrame` | NSImage? | Currently displayed frame |
| `currentSaliencyMap` | NSImage? | Saliency map for current target |
| `isMorphing` | Bool | True during transition |
| `transitionProgress` | Double | 0-1, for effects to react |
| `poolSize` | Int | Images in history |

### Easing Function
```swift
// Cubic ease in-out
private func easeInOutCubic(_ t: Double) -> Double {
    if t < 0.5 {
        return 4 * t * t * t
    } else {
        return 1 - pow(-2 * t + 2, 3) / 2
    }
}
```

### Why Crossfade (not ML Morph)

We tried VTFrameProcessor (Apple's ML frame interpolation) but it produced blocky artifacts inherent to the neural network approach. Simple crossfade + boosted distortion creates smoother, more organic transitions.

---

## Effect Controller

**File:** `VisualEffects.swift` → `EffectController`

Manages the shared `time` value that drives all effects.

```swift
@MainActor
class EffectController: ObservableObject {
    @Published var time: Double = 0  // Never resets during playback

    func start() { /* Timer at 60fps, increments time */ }
    func stop() { /* Stops timer, preserves time value */ }
}
```

---

## EffectsMetalView Architecture

**File:** `EffectsMetalView.swift`

Custom `MTKView` subclass that renders all effects in a single GPU pass with feedback loop support.

### Key Components

| Component | Purpose |
|-----------|---------|
| `sourceTexture` | Current image from MorphPlayer |
| `saliencyTexture` | Grayscale saliency map |
| `feedbackTextures[2]` | Double-buffered for trail effect |
| `uniformBuffer` | All effect parameters |
| `pipelineState` | Compiled shader pipeline |

### Render Loop

```swift
override func draw(_ dirtyRect: NSRect) {
    // Update uniforms from properties

    // PASS 1: Render to feedback texture
    encoder.setFragmentTexture(sourceTexture, index: 0)
    encoder.setFragmentTexture(readFeedback, index: 1)
    encoder.setFragmentTexture(saliencyTexture, index: 2)
    // Draw to writeFeedback

    // PASS 2: Copy to screen
    // Draw writeFeedback to drawable

    // Swap feedback buffers
    currentFeedbackIndex = (currentFeedbackIndex + 1) % 2
}
```

---

## Files Reference

| File | Contents |
|------|----------|
| `ContentView.swift` | Ken Burns properties, effect parameters, distortion boost logic |
| `EffectsMetalView.swift` | MTKView with double-buffered feedback, texture management |
| `EffectsRenderer.metal` | All effects in single fragment shader |
| `DreamyEffects.metal` | Legacy SwiftUI shader wrappers (unused) |
| `VisualEffects.swift` | EffectController (time driver), legacy SwiftUI extensions |
| `TimerDrivenCrossfade.swift` | Crossfade progress (macOS); saliency maps come from `DepthAnalyzer` |
| `DepthAnalyzer.swift` | Vision framework saliency analysis |

---

## Uniforms Structure

Must match between Swift and Metal:

```swift
// Abridged and out of date: see Liminal/EffectsUniforms.swift for the real struct
struct EffectsUniforms {
    var time: Float
    var kenBurnsScale: Float
    var kenBurnsOffsetX: Float
    var kenBurnsOffsetY: Float
    var distortionAmplitude: Float
    var distortionSpeed: Float
    var hueBaseShift: Float
    var hueWaveIntensity: Float
    var hueBlendAmount: Float
    var contrastBoost: Float
    var saturationBoost: Float
    var feedbackAmount: Float
    var feedbackZoom: Float
    var feedbackDecay: Float
    var saliencyInfluence: Float
    var hasSaliencyMap: Float
}
```

---

## Future Ideas

### Additional Effects (Not Yet Built)

- **Ripple burst** - Expanding circle on transitions
- **Chromatic aberration** - RGB channel separation (have shader in JuceyTV)
- **Breathing wave** - Shader exists in DreamyEffects.metal (`breathingWave`), not currently used

---

## Tuning Guidelines

1. **Start extreme, dial back** - Crank parameters way up first, then reduce until right
2. **Color blend preserves structure** - Use blendAmount to control how much original shows through
3. **Transition boost masks blends** - 10x distortion during crossfade hides the alpha blend
4. **Feedback zoom < 1** - Makes ghosts expand outward (the psychedelic direction)
5. **Transparency fade vs brightness** - Reduce blend amount, don't darken RGB
6. **Multiple subtle > one intense** - Layer effects like audio mixing
