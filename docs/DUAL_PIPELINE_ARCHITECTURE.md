# Dual Pipeline Architecture Review

> **Historical (2026-01-15 review).** The two platform-specific render pipelines still share their shader and uniforms. The visionOS default now renders one effects texture directly into a RealityKit drawable for the depth-displaced shell. The older per-eye MRT path remains available for Debug comparisons. [Current platform architecture](PLATFORM_ARCHITECTURE.md) · [Performance decisions](decisions/performance.md)

**Date**: 2026-01-15
**Status**: Reviewed and approved
**Reviewed by**: visionOS Expert, SwiftUI Architecture Expert, General Architecture Reviewer

## Summary

Liminal has two render pipelines, one for macOS and one for visionOS. This document captures an expert review of whether the duplication is necessary.

**Verdict**: The dual pipeline is **architecturally justified**. The divergence exists for real technical reasons (MainActor starvation on visionOS), not accidental duplication.

---

## The Core Problem

On visionOS, the 90fps `TimelineView` monopolizes MainActor. Any code requiring MainActor access (including `UIImage` operations, `@Published` updates, standard Swift concurrency patterns) can be starved indefinitely. This causes real hangs, not theoretical concerns.

**The solution**: the visionOS render loop reads pictures as `CGImage` from `AtomicImageBuffer`, a lock-protected slot, and never waits for the MainActor.

---

## Current Architecture

Both platforms share the picture supply:

```
CuratedImageFeed -> CuratedImagePool (disk) -> ImageQueue -> AtomicImageBuffer -> renderer
```

- `CuratedImageFeed` fetches and ingests pictures from the public library, museum and NASA APIs; `CuratedImagePool` stores them on disk.
- `ImageQueue` supplies the next picture on the drum grid, and `AtomicImageBuffer` hands the current one to the render loop.
- macOS draws it through `EffectsMetalView` (MTKView); visionOS through `ImmersiveDomeView` and `OffscreenEffectsRenderer` into RealityKit drawables.

Both platforms use the same 16:9 display crop from `ImageFraming`. The pipelines differ in how the shader output reaches the screen.

---

## Expert Recommendations

### What NOT TO DO

#### Do not use protocol-based abstraction
Protocols with associated types add complexity without meaningful benefit here. The actual divergence is small (final delivery step), and protocol overhead outweighs the benefit.

#### Do not unify for purity's sake
The divergence exists for real technical reasons. A small amount of duplication is tolerable given the alternative (MainActor starvation bugs).

---

## visionOS-Specific Concerns Noted

1. **No `print()` in hot paths**: logging in `AtomicImageBuffer` at 90fps is a measurable cost.
2. **Storage is limited**: the curated pool has its own 3 GB budget that evicts the least recently shown picture (`decisions/images.md`).

---

## Decision

**2026-01-15**: Reviewed architecture with three expert agents. Consensus is the dual pipeline is correct.

---

## Files Involved

- `Liminal/Visual/AtomicImageBuffer.swift` - CGImage-native, reference implementation
- `Liminal/Visual/ImageQueue.swift` - Picture queue shared by both platforms
- `Liminal/Visual/ImageSources/CuratedImageFeed.swift`, `CuratedImagePool.swift` - Fetch, ingest and storage
- `Liminal/PlatformImage.swift` - Platform abstraction
