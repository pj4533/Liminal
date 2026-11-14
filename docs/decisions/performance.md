# Performance decisions log

Append-only log of performance work on Liminal (what, why, alternatives, measured numbers).
Hard constraints: the visionOS render target stays 2048x2048, and the effects must look the same
(compare frozen-time screenshots). GPU time is the primary metric because the user believes the GPU
is the bottleneck on a real Vision Pro. Simulator numbers are only for before/after comparison.

---

## 2026-11-14: Measurement infrastructure + baseline

### What was added
- **`Liminal/Utils/GPUTimingStats.swift`** records per-pass GPU time from
  `MTLCommandBuffer.gpuStartTime/gpuEndTime` in `addCompletedHandler`. Each frame calls
  `beginFrame()` and every command buffer is tagged with a pass name. Per-frame GPU time is the
  sum of that frame's pass durations. Completion handlers on one queue fire in commit order, so a
  frame is closed when the next frame's first buffer completes. Aggregation uses one uncontended
  `OSAllocatedUnfairLock` per command buffer. The log line drains the stats and reports avg, p95
  (nearest rank) and max, plus avg/max for each pass.
  - visionOS passes: `dome` (LowLevelDomeMesh breathing compute), `eyeL`/`eyeR` (effects fragment
    pass + 2048² copy to the RealityKit drawable). Mono fallback: `fx`.
  - With `-LiminalPerfSplitPasses YES` the eye copy goes into its own command buffer, which gives
    `fxL`/`fxR` (effects shader) and `blitL`/`blitR` (copy). This is off by default because it
    changes command-buffer structure.
  - macOS: `fx` (effects pass + feedback blit, one command buffer).
- **Log lines extended** (both are logged with `privacy: .public` so they can be read outside a debugger):
  - `📊 visionOS PERF: fps=… | render avg=…ms max=…ms | dropped=… | transition=…% | interval p95=…ms | gpu avg=…ms p95=…ms max=…ms n=… passes[avg/max ms]: dome=a/b eyeL=… eyeR=…`
  - `📊 METAL PERF: … | interval p95=…ms | gpu avg=… p95=… max=… n=… passes[avg/max ms]: fx=…`
- **DEBUG-only launch args** (`Liminal/Utils/DebugLaunchOptions.swift`). In Release builds they become
  constants, and each applied flag logs one `🧪 DEBUG FLAG applied:` line:
  `-LiminalAutoPlay YES`, `-LiminalOpenDome YES` (visionOS; opens `liminalDome` 1 s after the
  controls window appears), `-LiminalFreezeTime <s>` (pins the effect clock on both platforms, which
  also pins dome breathing and stereo oscillation), `-LiminalPerfLogInterval <s>`,
  `-LiminalPerfSplitPasses YES`.
- **`scripts/perf-run.sh`** installs the built app, terminates any running instance, launches it
  with the flags and streams the log. It waits for the first PERF line, using `sim-tap.sh` as a
  fallback if the dome did not auto-open within 25 s. It then warms up for 15 s, collects N s,
  takes a screenshot and writes a JSON summary to `$SCRATCH/perf/<label>/`.

### Alternatives considered
- **MTLCounterSampleBuffer (stage-boundary timestamps)** would give per-encoder timing inside one
  command buffer. I rejected it for now: it needs GPU→CPU timestamp calibration
  (`sampleTimestamps`), resolve blits and per-device support checks. The simulator's proxy GPU is
  unlikely to support it, and splitting command buffers (opt-in flag) answers the same question
  (shader vs copy).
- **Splitting command buffers permanently** was rejected because it adds scheduling overhead and
  changes what is being measured.
- **Instruments / Metal System Trace** is still the right tool on device. The log-based numbers
  are for automated A/B runs.

### Not on the per-frame path
- MetalFXUpscaler / RealESRGAN (once per new image, about every 30 s) and depth generation
  (CoreML, once per image) are not instrumented. They are not frame costs, though they can cause
  hitches when an image changes.

### Baseline (visionOS simulator, Apple Vision Pro / visionOS 26.2, commit before optimizations)
`scripts/perf-run.sh --seconds 30` (15 s warm-up), unfrozen, 3 runs:

| run | fps mean | interval p95 ms | gpu mean ms | gpu p95 ms | gpu max ms | dropped/5s | dome | eyeL | eyeR |
|---|---|---|---|---|---|---|---|---|---|
| baseline-1 | 49.92 | 40.97 | 0.304 | 0.550 | 1.322 | 121.7 | 0.073 | 0.152 | 0.079 |
| baseline-2 | 49.01 | 39.03 | 0.313 | 0.550 | 1.144 | 118.5 | 0.075 | 0.157 | 0.081 |
| baseline-3 | 64.42 | 23.58 | 0.276 | 0.527 | 0.793 | 116.8 | 0.066 | 0.141 | 0.070 |
| **median** | **49.92** | **39.03** | **0.304** | **0.550** | **1.144** | **118.5** | **0.073** | **0.152** | **0.079** |
| baseline-frozen (t=100) | 68.52 | 19.44 | 0.289 | 0.475 | 0.974 | 73.7 | 0.063 | 0.152 | 0.074 |

A split-pass trial (`--split`, 8 s) gave fxL 0.087, blitL 0.043, fxR 0.045, blitR 0.030, dome 0.066 ms.

Frozen reference screenshot: `$SCRATCH/perf/baseline-frozen/screenshot.png`. The effect time is
pinned, but the source image is still picked at random from the cache, so compare it to another
frozen capture of the same source image.

macOS sanity check (Debug, `-LiminalAutoPlay YES -LiminalFreezeTime 100`): `fx` was about
0.9 ms/frame GPU at steady state.

### Reading the baseline
- In the simulator, GPU time per frame (about 0.3 ms) is tiny compared with the frame interval
  (p95 about 39 ms), and `dropped` counts loop intervals over 15 ms. **In the simulator the loop
  is limited by CPU, MainActor or pacing, not by the GPU.** The simulator runs Metal on the host
  Mac GPU, which is much faster than the Vision Pro's M2. Its `gpuStart/EndTime` values may also
  under-report: the macOS build reports about 0.9 ms for a similar shader at a similar pixel count.
  So these GPU numbers are only good for relative comparison. Absolute GPU cost has to be
  measured on device, where the same log line works.
- Per-pass shape: `eyeL` costs about twice `eyeR`. Both run the same shader at the same resolution,
  so `eyeL` probably absorbs cache warm-up or a dependency on the dome compute. The copy is about a
  third of each eye pass.
- Run-to-run variance in fps and interval p95 is large (49–64 fps), while GPU numbers are stable
  (±7 %). Use the median of 3 runs for comparisons.

---

## 2026-11-14: Round 1 plan

Read the whole per-frame path and wrote the ranked plan in `docs/plans/performance.md`.

- **Why the GPU is plausibly the bottleneck on device** although the simulator shows 0.3 ms: the
  fragment shader evaluates about 175 trig functions and 7-16 texture samples per pixel, over 8.4 M
  pixels per frame, plus two 2048² copies.
- **Chosen order**: free wins first (direct-to-drawable render, dead feedback stage, redundant
  crossfade samples), then the two low-res field pre-passes, which remove most of the per-pixel
  math and are the only items with a look risk.
- **Alternatives rejected**: MetalFX or lower render resolution (violates the 2048² requirement),
  MRT stereo, compute instead of fragment, specialising stages whose amounts never reach zero.
- **Deferred pending user sign-off**: updating the effects below display rate; it changes how fast
  the bloom shimmer animates.
- **Found while reading**: the feedback texture (index 4) is never bound on visionOS, so the
  feedback stage samples an unbound texture. Nothing was measured in this step.

---

## 2026-11-14: direct-drawable-render (round 1, item 1)

**What**: `OffscreenEffectsRenderer` now renders each eye (stereo `renderEyeToDrawable`), the mono
full-shader path and the debug passthrough path straight into `drawable.texture`, with
`loadAction = .dontCare` (the fullscreen quad writes every pixel) and `storeAction = .store`. The
2048² `outputTexture` (16 MB, shared storage) and every blit from it are gone.

**Why**: nothing read `outputTexture` after the copy, and the DrawableQueue textures are already
`.bgra8Unorm_srgb` render targets (`[.renderTarget, .shaderRead, .shaderWrite]`, both in
`StereoMaterialBuilder` and `setupDrawableQueue`), the same format as the pipeline's colour
attachment, so no pipeline or drawable-descriptor change is needed. This removes two 2048² copies,
two 16 MB intermediate stores and the `.clear` of the intermediate per frame.

**Safety**: a shared `makeDrawablePassDescriptor` logs the drawable size and pixel format once
("🖼️ Direct drawable render") and asserts (Debug) / logs an error if it is not 2048x2048.
`drawable.present()` still runs after `commit()`. The 2048² resolution is unchanged.

**`-LiminalPerfSplitPasses`**: with no blit there is nothing to split. The flag is kept as a no-op
(so `perf-run.sh --split` still parses) and its log line says so. Pass names stay `eyeL`/`eyeR`
(`fx` for mono).

**Alternatives considered**: keep the intermediate but make it `.private`/memoryless (still pays
the copy); render both eyes into one texture array (needs drawable/material changes, out of scope).

**Expected**: about 25-35 % lower `eyeL`/`eyeR` GPU time (baseline split: blitL 0.043 of 0.130 ms,
blitR 0.030 of 0.075 ms). Measurement is done by a separate agent; the frozen screenshot must be
checked for unchanged orientation and sRGB colour.
