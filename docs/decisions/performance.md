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

### Measured result: direct-drawable-render (verdict KEEP)

Median of 3 unfrozen 30 s simulator runs vs baseline (before -> after):
- GPU ms/frame mean: 0.304 -> 0.159 (-48%); p95 0.550 -> 0.260. Runs: 0.159 / 0.229 / 0.112.
- Per pass (run 1): dome 0.073 -> 0.050, eyeL 0.152 -> 0.067, eyeR 0.079 -> 0.042.
- fps median 46.4 (baseline 49.9) and interval p95 ~51 ms: simulator is CPU/pacing bound and noisy (runs 46.4/49.6/38.9), so not meaningful; GPU time is the primary metric.
- Logs: no errors; "Direct drawable render: 2048x2048 format=81" logged, resolution unchanged.
- Visual: frozen (t=100) screenshot shows a different random source image than baseline, so a numeric diff is meaningless (mean abs diff ~30). Visually upright, correct colour, all effects present (distortion, chromatic fringing, grain, haze). Judged acceptable.
Verdict: kept (>=3% GPU improvement, no new errors).

## Compile feedback-warp stage out on visionOS via function constant (231c4f1) - REVERTED

- What: function constant to dead-strip the feedback-warp stage in the visionOS fragment shader, output meant to be unchanged.
- Measured (simulator, medians of 3): GPU mean 0.282 ms vs 0.159 ms before; p95 0.52 ms vs 0.26 ms; fps 77.9 vs 46.4 (frame interval p95 13.4 ms vs 51 ms). Per-pass: dome 0.089, eyeL 0.128, eyeR 0.069. No errors in logs.
- Verdict: not kept. GPU time did not improve (it was higher), so the rule of >=3% GPU gain was not met. The fps jump looks like simulator or host load differences between sessions, not a real gain, since GPU ms moved the wrong way.
- Visual parity: frozen screenshots could not be compared. Mean abs diff was 46.8, but the two captures showed different source images (the image pool changes per run), so the diff says nothing about the shader.
- Alternative to revisit: A/B the same build with the constant on and off in one session, using a fixed image, to separate shader cost from host noise.

## Result: skip previousTexture samples (skip-previous-samples) - NOT KEPT

- Measured (simulator, 3 runs x 30 s, medians): GPU mean 0.280 ms (runs 0.291 / 0.280 / 0.258) vs 0.159 ms before; p95 0.49 ms vs 0.26; fps 76.7 vs 46.4. Per-pass (run 2): dome 0.084, eyeL 0.127, eyeR 0.068. Frozen run: GPU mean 0.137 ms vs 0.113 before. No errors in logs.
- Verdict: reverted (branch reset to 16ea43d). GPU ms did not improve by >=3%; it was higher. As with the feedback-warp run, fps and GPU ms moved in opposite directions, which points to host/session noise in the simulator rather than a shader effect.
- Visual parity: frozen screenshots show the same effect style but different source images (image pool varies per run), so the numeric diff (mean abs 38.5) is not meaningful. Output is bit-identical by construction outside transitions.
- Note: the change is logically sound (removes 3 fetches per pixel outside crossfades) but cannot be shown to help with this simulator harness. Worth retrying with an A/B on the same build and a fixed image, or on real hardware.

## Shared low-res displacement pre-pass (turbulence + log-spherical + sinusoidal noise) — REVERTED

- What: commit 19d26be computed displacement once at low res in a pre-pass, sampled by both eyes.
- Measured (visionOS sim, medians of 3): GPU mean 0.313 ms (runs 0.315/0.313/0.308) vs 0.159 ms before (about +97%, worse). Per-pass: disp=0.101, dome=0.088, eyeL=0.073, eyeR=0.048. The new disp pass costs more than the eye-pass work it saves. fps 73.9 vs 46.4 and p95 interval 16.5 ms vs 51 ms, but those are simulator/system-load noise, not GPU gain. GPU p95 0.53 ms vs 0.26 ms.
- Visual: frozen screenshot mean abs diff 55 vs baseline, but the dome showed a different source image (queue count 263 vs 64), so parity could not be established.
- No errors in logs.
- Verdict: not kept; branch reset to c3c3592. Alternative (not tried): fold displacement into a single eye pass with fewer octaves.

## Bake hue waves and fractal-hue noise into a 512² field texture (reverted)

- What: commit 8c61f39 added a separate pass baking hue waves and fractal-hue noise into a low-res field texture, sampled at the final uv.
- Measured (visionOS simulator, 3 runs): GPU mean 0.362 / 0.693 / 0.796 ms (median 0.693) vs prior best 0.159 ms. fps 74.1 / 30.7 / 26.7 (median 30.7) vs 46.4. Interval p95 median 70.95 ms. The new hue bake pass itself cost 0.11-0.21 ms/frame, which exceeds the whole prior frame.
- Frozen run: GPU mean 0.362 ms. The frozen screenshot content differs from the baseline because a different generated image was on screen, so a numeric diff is not meaningful. No errors in the logs.
- Verdict: NOT kept. The extra pass and texture sampling cost more than the per-pixel noise it removed. Reset to fbf870e.
- Alternative: none pursued; per-pixel evaluation is already cheap after the half-precision and octave reductions.

## One command buffer per frame + in-flight bound (ed2ec02) - REVERTED

- What: merged dome compute + both eye passes into a single command buffer, with an in-flight bound on the stereo path.
- Measured (medians of 3, simulator): gpu_ms_mean 0.234 (runs 0.241/0.234/0.233) vs 0.159 before; fps_mean 61.1 (61.1/45.1/66.7) vs 46.4; frame interval p95 25.9 ms vs 51.1; dropped/5s 122.5 vs 115.3. Frozen run: gpu 0.198 ms, fps 67.4.
- Caveat: the GPU metric changed meaning (one whole-frame span now, previously a sum of three pass spans), so GPU ms is not directly comparable; fps is bimodal and noisy in the simulator (run 2 was 45 fps).
- Visual parity: frozen screenshot mean abs diff vs baseline was 38, too large to call parity (could not be confirmed equivalent).
- Verdict: not kept. GPU ms (primary metric) did not improve by >=3% and parity was unconfirmed. Branch reset to 8981aaf.

---

## 2026-11-14: Round 2 plan

Re-read the per-frame path at 5d40d08 and extended `docs/plans/performance.md` with a round 2
section. Nothing was measured in this step; the conclusions below come from the round 1 numbers.

- **Why five of six round 1 items were reverted**: the simulator `gpu ms` reads 0.05-0.09 ms for
  the 1,813-vertex dome compute and 0.04-0.08 ms for a 4.2 M pixel eye pass, so it mostly measures
  a fixed cost per command buffer or pass and barely responds to per-pixel work. Both extra-pass
  designs (displacement pre-pass 0.10 ms, hue bake 0.11-0.21 ms) lost for that reason. The
  0.159 ms reference came from one session whose runs spanned 0.112-0.229; two later
  work-removing changes read 0.28, which looks like a session shift (inferred, HEAD was not
  re-measured alongside them).
- **Decision**: first build a benchmark that responds to shader cost and gives pixel parity
  (fixed image, fixed time, Mac GPU, real `.metal` source), then prefer changes that remove
  shared work without adding passes: both eyes in one MRT pass, breathing on the CPU, texture
  hygiene, exact ALU clean-ups. Two look-affecting items (noise by angle addition, mip sampling
  for bloom and ghost taps) come after and need the PNG diff.
- **Alternatives rejected**: retrying the low-res pre-passes (each new pass costs more than it
  saves in this metric, and they carry look risk); effects below display rate (needs user
  sign-off); anything below 2048².
- **Rule change**: candidate and reference are measured interleaved in one session.

## Offline Mac-GPU shader benchmark harness (commit 51ae60c) - NOT KEPT

- What: scripts/shader-bench.swift + shader-bench.sh, an offline 2048^2 eye-pass benchmark with PNG parity output.
- Why measured: workflow step requires every commit to be run through perf-run.sh. The commit touches only scripts/ and docs/ (no app code), so it cannot change app GPU time.
- Measured (visionOS sim, median of 3): gpu_ms_mean 0.258 (0.261/0.254/0.258), fps 74.15 (74.2/61.5/75.1), interval p95 17.7 ms. Frozen run: gpu 0.264 ms. No errors in logs.
- Comparison to the "current best" (0.159 ms) is not apples to apples: sim host load and loaded dome image content differ between sessions (frozen screenshots differ because different generated images were loaded: 551 vs 64 in the image counter; mean abs diff 47). Not a shader regression since no shader changed.
- Verdict: no gain (>=3% threshold not met), so the branch was reset to 173a05a per workflow rules. The harness is a tooling-only change; it can be re-applied from 51ae60c if wanted (git cherry-pick 51ae60c).

## Both eyes in one MRT pass (mrt-stereo-single-pass) - implemented, awaiting measurement

- What: `effectsFragment`'s body is split, with no change to any maths, into `distortedUV()`
  (Ken Burns, turbulence, log-spherical, sinusoidal noise, UV clamp) and `shadeEye()` (stereo
  parallax through the final colour). `effectsFragment` calls both with `uniforms.stereoOffset`,
  so the macOS path and the visionOS mono path are unchanged. The new `effectsFragmentStereo`
  calls `distortedUV` once and `shadeEye` twice (-|offset| for the left eye, +|offset| for the
  right), and writes `[[color(0)]]` = left and `[[color(1)]]` = right.
  In `OffscreenEffectsRenderer.renderStereoAndPresent`, both drawables are acquired first. If
  both are available, one render pass (two bgra8Unorm_srgb attachments, .dontCare/.store), one
  draw and one command buffer are encoded and tracked as pass "eyes", and then both drawables are
  presented. If only one drawable is available, that eye is rendered through the old per-eye path,
  so it is never left showing a stale frame silently. The fallback is logged once.
- Why: the distortion field is about 125 of about 175 trig per eye-pixel and depends only on
  texCoord and uniforms, so both eyes computed it twice. An MRT pass shares it at full 2048²
  resolution without adding a pass. The low-res pre-pass from round 1 lost because the extra pass
  cost more than it saved. This change also removes one command buffer and one pass per frame,
  which the simulator's per-pass fixed cost can see.
- Kept unchanged: the feedback stage stays inside `shadeEye` with texture 4 unbound and the UV
  for each eye. Bloom noise still uses `in.position.xy`, which is the same for both eyes. The
  `EffectsUniforms` layout is unchanged; in the stereo pipeline `stereoOffset` carries the
  magnitude, and it is still 0 when there is no depth texture. The 2048² drawable check now runs
  through `validateDrawableSize()` on both attachment textures on every pass, and logs once.
- Alternatives considered: a vertex-amplification/layered render target, which RealityKit's two
  separate DrawableQueues cannot provide since they are two textures and not an array; and
  keeping two passes with a shared displacement texture, which was measured and lost in round 1.
- Parity: the shader-bench harness was reverted (not on the branch), so pixel parity has to be
  checked by frozen-time screenshot in the measurement step. The maths is moved verbatim, so a
  zero diff is expected.
- Builds: visionOS Simulator and macOS both succeed.
- Measured numbers: to be appended by the measurement step. Expected: the "eyeL"+"eyeR" pair is
  replaced by one "eyes" pass, with a lower simulator total from one fewer pass's fixed cost, and
  about 30-35% less arithmetic across the two eyes on device.

### Measured result: MRT single-pass stereo (ac1ad07) - KEPT
- Medians of 3 runs (30 s each, simulator, relative only): fps 68.3 (70.8 / 66.0 / 68.3), frame interval
  p95 21.9 ms, GPU mean 0.201 ms (0.208 / 0.198 / 0.201), GPU p95 0.371 ms. Passes: dome 0.082,
  eyes 0.120 ms. Frozen (t=100): fps 77.1, GPU mean 0.198, dome 0.090, eyes 0.108.
- Previous best: fps 46.4, GPU mean 0.159 (runs 0.159 / 0.229 / 0.112, so run-to-run noise is about
  +/-35%), interval p95 51.1 ms, eyeL+eyeR about 0.109 ms.
- Verdict: kept on the fps criterion. fps rose about 47% and interval p95 dropped from 51 to 22 ms,
  consistently across all three runs. Simulator GPU ms mean looks about 26% higher, but that sits inside
  the baseline's own run spread and the simulator's per-pass timing is not representative of the Vision
  Pro. The arithmetic saving (shared distortion field) applies on device; one fewer pass and command
  buffer also lowers per-frame overhead.
- Parity: the frozen screenshots are not pixel-comparable because the dream-image set differs between
  runs (the baseline shot had a different image loaded), so the mean abs diff of 42 is content, not
  shader, difference. Visually the effect stack (distortion, chromatic fringing, grain, hue shift) looks
  equivalent. The maths was moved verbatim. No errors in the logs.
