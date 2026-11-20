# CLAUDE.md

Guidance for Claude Code in this repository. It extends [AGENTS.md](AGENTS.md), the tool-neutral agent guide. When you change a convention here, update AGENTS.md as well.

## What Liminal is

Liminal is a native SwiftUI ambient audiovisual app for **macOS 26+ and visionOS**. It has no iOS target and no web backend. It:

- synthesizes music in two modes: **Ambient** (eight synthesis layers, styles Drift/Glass/Deep/Garden) and **Lo-Fi** (sampled instruments, deep bass, optional private drum takes, and archive dialogue chopped on the beat);
- generates surreal 3:2 2K images with Gemini, caches them on disk, and reuses the cache when generation is capped or unavailable;
- renders the images through one staged Metal effects shader (MTKView on macOS; RealityKit drawables on a depth-displaced wraparound shell on visionOS);
- weaves Internet Archive footage and its treated soundtrack into the scene.

Music drives visual uniforms through `MusicState` → `MusicReactor`. Each image sends a mood back to the music through `VisualMoodBuilder`. In Lo-Fi, the drum transport's audible downbeat is the clock for image changes, footage cues and dialogue hits.

## Build, test, verify

Always build after changes. **Always pass `-destination`**; never build for iOS. Toolchain: Xcode 27.2, simulator "Apple Vision Pro" (visionOS 27.2).

```sh
xcodebuild -scheme Liminal -destination 'platform=macOS' build
xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

- The full unit suite takes several minutes. For audio work, use the narrower Lo-Fi test list in `docs/development.md#lo-fi-checks` or `-only-testing:LiminalTests/<Suite>`.
- Tests use **Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest.
- `Liminal/Secrets.swift` (gitignored) must exist. Copy `Secrets.swift.template` and keep the placeholder unless generation is needed. `GEMINI_API_KEY` in the environment takes precedence.
- Never change signing settings to work around a local build failure. A new Xcode may need `xcodebuild -downloadComponent MetalToolchain`.
- The project uses Xcode file-system synchronized groups, so new files under `Liminal/` and the test folders join their targets automatically. Do not hand-edit `project.pbxproj` to add them.

### Visual verification

A successful build does not show that the visuals are correct. Build, terminate the old process, relaunch the new build, capture with `/opt/homebrew/bin/peekaboo`, and look at the image. Use element IDs where possible.

- visionOS Simulator: `xcrun simctl io <udid> screenshot x.png` (captures immersive content), and `scripts/sim-tap.sh X Y` / `scripts/sim-drag.sh` for input in 3840×2160 screenshot coordinates. AXe and XcodeBuildMCP UI taps do not work. See `docs/research/visionos-sim-automation/README.md`.
- PERF log lines: `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.saygoodnight.Liminal"'`.
- Simulator ML depth is all zeros. Use `-LiminalDepthImage` / `-LiminalShellCycle` fixtures, and treat hardware behavior as unverified until checked on a device.
- Simulator performance is not device performance. Use it only for before/after comparisons.

## Do not spend Gemini budget

Automated test runs once exceeded the user's monthly Google budget. Any DEBUG launch with an automation flag (`-LiminalAutoPlay`, `-LiminalOpenDome`, `-LiminalMusicSeed`, `-LiminalFreezeTime`, perf/test flags…) suppresses generation and shows cached images or the test card. `DebugLaunchOptions.blocksImageGeneration` is the gate. Add any new automation flag to it. Pass `-LiminalAllowGeneration YES` only when generation itself is under test, and keep that to a handful of images. Never press Play in a flagless launch during automation.

## Repository map

- `Liminal/LiminalApp.swift`, `ContentView.swift`, `*Section.swift`, `ControlComponents.swift`, `MusicModeControls.swift`: macOS entry point and shared control UI.
- `Liminal/visionOS/`: visionOS app, control window, `ImmersiveDomeView` render loop, `OffscreenEffectsRenderer` (2048² mono render into a RealityKit `DrawableQueue`), `SourceTextureUploader`, shell mesh/materials, head pose.
- `Liminal/Audio/`: `GenerativeEngine` facade (graph, start/stop, route recovery), `MusicConductor` (own queue), `SceneDirector`, `Layers/`, `MixBus`, `OfflineRender`, `ArchiveVoice`.
- `Liminal/Audio/Lofi/`: `LofiScore` (32-bar forms, motifs), `LofiRenderer` (off-audio-thread phrase render), `LofiPlayback` (transport, phrase queue, late-phrase fallback, clock publishing), `LofiBus`/`LofiMasterBus`, `LofiDrumTake`/`LofiDrumLibrary`/`LofiBeatGrid`, `LofiDialogueSampler`/`LofiSpeechFocus`, effects and sidechains. `InstrumentSamples/` holds the CC0 samples credited in `docs/lofi-samples.md`. Also `LofiStemChains` (per-bus chains), `LofiDrumLandmarks` and `LofiTimingField` (attack landmarks and the sparse shared timing), `LofiBassVoice` (two-layer bass: synthesized sub plus sampled body), `LofiBassSamples` (the `LofiBass-*` body kits), `LofiBassThrow` (dub throws into the wet stem), `LofiPadVoice` (granular held pad), the per-part files `LofiScore+Bass`/`+Mids`, `LofiRenderer+Bass`/`+Texture` and `LofiStemChains+Bass`/`+Mids`, and `LofiCaptureHooks` (offline capture taps, inert in the app).
- `Liminal/Audio/Lofi/Dialogue/`: dialogue chopping. Analyzer, hierarchy, pad bank builder, motif and performer, reorder guard, chop renderer, cue coordinator and director, transcription provider and assets. See `docs/architecture.md#dialogue-chopping-pipeline`.
- `Liminal/Audio/Lofi/DSP/`: biquad, dynamics, loudness, saturation, stereo, true peak, master kernel and finisher.
- `Liminal/Visual/`: `GeminiClient`, `ModelRouter`, `ImageGenerationConfig`, `GenerationBudget`, `Prompt/`, `ImageQueue`/`ImageStore`/`AtomicImageBuffer`, `ImageFraming`, upscalers, `DepthMapGenerator` (Core ML depth), `DepthAnalyzer` (Vision saliency, an actor), `TimerDrivenCrossfade`, `EffectsMetalView` (macOS), `EffectsUniformsComputer`, `MusicReactor`/`MusicModulation`, `Spatial/`.
- `Liminal/Shaders/`: `EffectsRenderer.metal` (single staged fragment shader), `ArchiveVideo.metal`, `DreamyEffects.metal`. `Liminal/EffectsUniforms.swift` is the CPU-side layout contract.
- `Liminal/Archive/`: catalog/client/seed list (`archive-seeds.json`), `ArchiveClipStore` (3 GB cache, 10 pinned + 2 rotating, launch sweep of unindexed and temp files), `VideoFrameSource`, `FootageWeaver`, `VideoComposite`, `ArchiveAudio` (decode and cue math).
- `Liminal/Services/`: `SettingsService` (persistent settings), `EnvironmentService` (credentials).
- `Liminal/Utils/DebugLaunchOptions.swift`: every debug launch flag, compiled out of Release. The flag table is in `docs/development.md`.
- `LiminalTests/`, `LiminalUITests/`; `scripts/` (perf, shader bench, transition/footage clips, music renders and Lo-Fi analysis, archive curation; `mix-report.sh`, `mix-matrix.sh`, `mix-criteria.json` and `mixlib/` for mix verification; `solo-stems.py` and `stem-bands.py` for per-channel levels and bands); `tools/` (standalone Swift harnesses).
- Docs: `docs/README.md` (index), `architecture.md`, `experience.md`, `development.md`, `decisions/` (rationale, with numbered items such as D34 and A30), `plans/` and `research/` (may describe unfinished or historical work). The older uppercase docs (`LIMINAL.md`, `PLATFORM_ARCHITECTURE.md`, `DUAL_PIPELINE_ARCHITECTURE.md`, …) predate current decisions. Check the source before relying on them.

## Contracts to preserve

**Swift concurrency.** The app target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency (Swift 5 mode). Unannotated types are main-actor isolated. Code that runs off the main actor must be `nonisolated`, `@concurrent`, an actor, or `Task.detached`. Examples: `nonisolated enum ImageFraming`, `@concurrent reserveForFill`, `actor DepthAnalyzer`. Keep heavy work off the main actor: image cropping, colour stats, texture builds, saliency, depth inference and mood building.

**Audio.**
- Do not block, allocate or take locks on realtime render paths and tap blocks. Use `Atomic` and `Mutex` from the Synchronization framework.
- Device-property getters such as `outputPresentationLatency` query Core Audio synchronously. Read them once when arming the transport, not on per-tick paths.
- Preserve the scheduling and thread boundaries. The conductor has its own queue. Lo-Fi phrases render off the audio thread and are scheduled sample-accurately on the five stem players plus the dialogue input.
- Lo-Fi late-phrase fallback: interior phrases queue early. A phrase that misses its deadline repeats the previous stems on the same grid. Do not reintroduce silent rests.
- Route changes that stop `AVAudioEngine` re-arm music and the visual clock together through `GenerativeEngine.recoverStoppedGraph`. A user Stop cancels a pending recovery.
- Drum takes keep their original sample grid and interior fills. Only the outer 1 ms attack and 4 ms release are tapered.
- Keep fades, cache limits, and the separate soundtrack and dialogue paths in Lo-Fi.
- Dialogue analysis never delays the film bed or the music. Plans carry the cue token and revision (`ArchiveVoice.perform` ignores stale tokens and lower revisions). The acoustic fallback is always retained when transcription is unavailable.

**Rendering.**
- Image row 0 is the top. Use the same 3:2 cover crop (`ImageFraming`) on both platforms, and register saliency and depth with the same normalized crop as the colour image.
- `EffectsUniforms` (Swift) must match the Metal struct exactly. `EffectsUniformsComputer` is the single source of truth for both renderers.
- Per-frame shader constants are passed with `setFragmentBytes` so each in-flight command buffer has its own copy. Do not go back to one shared `MTLBuffer` that the CPU overwrites.
- Build depth textures fresh rather than overwriting one that a frame in flight may still use.
- visionOS: never lower the 2048×2048 render size. Optimize shaders (ALU, precision, octaves, function constants) instead. Acquire drawables on the serial worker (`acquireDrawable`) before sampling the frame's state. When the GPU is saturated, skip a submission rather than block.
- A staged visionOS picture (`PreparedImageSlot`) owns its colour texture, depth, depth texture and relief field, so a late depth result can never attach to another picture.

**Images and generation.**
- Settings live in `ImageGenerationConfig` and caps in `GenerationBudget`. The primary model is `gemini-nano-banana-2.1` and the fallback is `gemini-3.1-flash-lite-image`. Treat these as repo configuration, not verified provider availability.
- Cache reuse is the fallback whenever generation is capped or unavailable.

**Archive.** Retain each source's credit (`docs/experience.md` film table). Ten pinned films plus two rotating discoveries share a 3 GB cache. Do not add size caps or budgets that change what can play (user decision, 2026-11-19, A31); if more storage is needed, raise the storage. Launch cleanup only removes files the index does not list and stale temp files.

## Never commit

Real API keys or `Liminal/Secrets.swift`, the private drum recordings in `Liminal/SlowBurnDrums/` and `Liminal/Audio/Lofi/SlowBurnBeatGrid.json` (both gitignored), user schemes/`xcuserdata`, caches, build products, perf captures, or raw personal recordings. README media is curated in `docs/media/`.

Do not casually regenerate or delete the bundled Core ML models (`DepthAnythingV2SmallF16.mlpackage`, `realesrgan512.mlmodelc`).

## Useful debug flags and scripts

All flags are in `DebugLaunchOptions.swift` and documented in `docs/development.md`. Common ones:

- `-LiminalAutoPlay YES`, `-LiminalOpenDome YES`, `-audio.musicMode lofi`, `-archive.enabled YES` (settings keys work as launch args too)
- `-LiminalMusicSeed <n>` replays a score (seed printed in "Music graph built … seed N"), and `-LiminalVideoSeed <n>` pins the footage weaver
- `-LiminalVideoOffline YES` (cache only), `-LiminalVideoFile <mp4>`, `-LiminalTestImage <path|dir>`, `-LiminalImageInterval <s>`, `-LiminalFreezeTime <s>`
- `-LiminalTraceLofi YES` (exact take sample ranges), `-LiminalDelaySecondTake <s>` (forces the late-phrase fallback)
- `scripts/perf-run.sh [--lofi]`: visionOS simulator perf with a JSON summary. `--lofi` fails on a ≥100 ms frame, missed drum or picture changes, a repeated phrase or timed rest, a master-tap clock gap, or a Core Audio overload.
- `scripts/check-lofi.sh`: headless Lo-Fi capture with LUFS, true-peak and routing checks (needs FFmpeg and Python 3).
- `scripts/mix-report.sh` (one capture) and `scripts/mix-matrix.sh` (five cases, `--strict` gates on fail-level criteria in `scripts/mix-criteria.json`): per-bus stems, spectrograms, masking, low end, loudness, true peak, limiter reduction, intelligibility and chop cadence. Interpretation is in `docs/mix-verification.md`. Run one capture at a time, and keep captures out of git.
- `scripts/shader-bench.sh`, `tx-clip.sh`, `ffx-clip.sh`, `render-music.sh`, `av-coupling-check.sh`. Read a script's options before running it, because some fetch network fixtures.

## Documentation and commits

- Keep docs synchronized with source in the same change. Measurements and rationale go into the matching `docs/decisions/*.md` with dates, and user-facing behavior goes into `experience.md`/`architecture.md`. Documentation-only work should not touch app source.
- Use sosumi.ai instead of developer.apple.com for Apple documentation.
- Commit messages: recent history uses a plain, descriptive sentence-case subject with no prefix or emoji (e.g. "Pin Thinking Machines and Hear Here alongside two rotating discoveries"). Older history used gitmoji conventional commits. Work on `main` unless asked to branch, and keep changes scoped to the request.
