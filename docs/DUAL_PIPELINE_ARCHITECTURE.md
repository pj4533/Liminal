# Dual Pipeline Architecture Review

**Date**: 2026-01-15
**Status**: Reviewed and approved - optimization deferred
**Reviewed by**: visionOS Expert, SwiftUI Architecture Expert, General Architecture Reviewer

## Summary

The Liminal codebase has two separate image pipelines for macOS and visionOS. This document captures an expert review of whether this duplication is necessary and what optimizations are possible.

**Verdict**: The dual pipeline is **architecturally justified**. The divergence exists for real technical reasons (MainActor starvation on visionOS), not accidental duplication.

---

## The Core Problem

On visionOS, the 90fps `TimelineView` monopolizes MainActor. Any code requiring MainActor access (including `UIImage` operations, `@Published` updates, standard Swift concurrency patterns) can be starved indefinitely. This causes real hangs, not theoretical concerns.

**The Solution**: visionOS uses `CGImage` exclusively throughout the pipeline, bypassing MainActor entirely.

---

## Current Architecture

### visionOS Pipeline (MainActor-free)
- `GeminiClient.generateImageRaw()` → returns `(Data, CGImage)` via `CGImageSource`
- `ImageCache.saveRawData()` → saves 1024x1024 originals to `RawImages/`
- `ImageCache.loadAllRawAsCGImages()` → loads via `CGImageSource`
- `ImageQueue` uses `CGImage` throughout, zero `UIImage`/`PlatformImage`

### macOS Pipeline (Standard)
- `GeminiClient.generateImage()` → returns `PlatformImage` (NSImage)
- `ImageCache.save()` → saves 4096x4096 upscaled to `UpscaledImages/`
- `ImageCache.loadAll()` → returns `[PlatformImage]`
- `ImageQueue` uses `PlatformImage` throughout

### Caching Strategy Difference

| Platform | Cache Directory | Resolution | File Size | Rationale |
|----------|----------------|------------|-----------|-----------|
| macOS | UpscaledImages/ | 4096x4096 | ~50MB | CoreML slow (~3s), disk cheap |
| visionOS | RawImages/ | 1024x1024 | ~1.5MB | MetalFX fast (~0.02s), storage limited |

---

## Expert Recommendations

### What TO DO (If Optimizing)

#### Option 1: Extract Shared GeminiClient Code (High Impact, Low Risk)
Both `generateImage()` and `generateImageRaw()` duplicate:
- URL construction
- Request building
- JSON parsing
- Base64 decoding

**Refactor**: Extract to a private method returning `(Data, CGImage)`, with thin public wrappers.

```swift
private func generateRawData(prompt:) -> (Data, CGImage)  // shared (~70 lines)
func generateImage(prompt:) -> PlatformImage             // wraps for macOS
func generateImageRaw(prompt:) -> RawImageResult         // wraps for visionOS
```

**Savings**: ~70 lines consolidated, zero architectural change.

#### Option 2: Unify Both Platforms on CGImage (Medium Impact, Medium Risk)
`PlatformImage` isn't required anywhere. SwiftUI supports:
```swift
Image(decorative: cgImage, scale: 1.0, orientation: .up)
```

Going CGImage-only on both platforms would:
- Eliminate all `#if os()` blocks in ImageQueue
- Create single code path for caching
- macOS would adopt "cache small originals" approach

**Trade-off**: macOS would upscale on load (~2-3s CoreML hit on startup).

#### Option 3: Shared File I/O Helper for ImageCache (Low Impact)
Extract common file enumeration, sorting, counting into shared helper.

**Savings**: ~30 lines.

---

### What NOT TO DO

#### Don't Use Protocol-Based Abstraction
Protocols with associated types add complexity without meaningful benefit here. The actual divergence is small (final conversion step), and protocol overhead outweighs the benefit.

#### Don't Unify Caching Strategies
The separate strategies are justified:
- macOS: Cache large (upscaled) because CoreML is slow, disk is cheap
- visionOS: Cache small (originals) because MetalFX is fast, storage is limited

Forcing identical strategies would hurt one platform or the other.

#### Don't Unify for Purity's Sake
The divergence exists for real technical reasons. ~150 lines of duplication is tolerable given the alternative (MainActor starvation bugs).

---

## Quantified Duplication

| Component | Duplicated Lines | Justification |
|-----------|-----------------|---------------|
| GeminiClient | ~70 | Network/parsing logic (could consolidate) |
| ImageCache | ~60 | Parallel APIs (could consolidate) |
| ImageQueue | ~20 | Platform conditionals (justified) |
| ImageUpscaler | 0 | CoreML vs MetalFX are legitimately different |

**Total**: ~150 lines, mostly in GeminiClient and ImageCache.

---

## visionOS-Specific Concerns Noted

1. **MetalFX fallback is silent** - When MetalFX fails, returns original image without throwing. Consider louder logging.

2. **No cache pruning** - `RawImages/` has no size limit. Consider LRU eviction for visionOS storage constraints.

3. **Some `print()` in AtomicImageBuffer** - Minor performance concern at 90fps.

---

## Decision

**2026-01-15**: Reviewed architecture with three expert agents. Consensus is the dual pipeline is correct. Optimization options documented above for future consideration, but not blocking. Moving on to higher priority work.

---

## Files Involved

- `Liminal/Visual/GeminiClient.swift` - Lines 110-234 (generateImage), 240-311 (generateImageRaw)
- `Liminal/Visual/ImageCache.swift` - Lines 44-89 (PlatformImage API), 129-212 (Raw Data API)
- `Liminal/Visual/ImageQueue.swift` - Lines 117-176 (loadCachedImages), 337-479 (generateAndUpscaleOne)
- `Liminal/Visual/AtomicImageBuffer.swift` - CGImage-native, reference implementation
- `Liminal/PlatformImage.swift` - Platform abstraction (could be eliminated with Option 2)
