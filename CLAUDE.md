# CLAUDE.md

Guidance for Claude Code in this repository. It extends [AGENTS.md](AGENTS.md), the tool-neutral agent guide. When you change a convention here, update AGENTS.md as well.

## What Liminal is

Liminal is a native SwiftUI audiovisual app for **macOS 26+ and visionOS**. It has no iOS target and no web backend. It:

- plays **Lo-Fi beats**: sampled instruments, a warm bass, a held pad, optional private drum takes, and archive dialogue chopped on the beat;
- shows curated public-domain and openly licensed 3:2 pictures from library, museum and NASA APIs, stored in a pool on disk that keeps rotating offline;
- renders the pictures through one staged Metal effects shader (MTKView on macOS; RealityKit drawables on a depth-displaced wraparound shell on visionOS);
- weaves Internet Archive footage and its treated soundtrack into the scene.

Music drives visual uniforms through `MusicState` → `MusicReactor`. The drum transport's audible downbeat is the clock for image changes, footage cues and dialogue hits.

## Build, test, verify

Always build after changes. **Always pass `-destination`**; never build for iOS. Toolchain: Xcode 27.2, simulator "Apple Vision Pro" (visionOS 27.2).

```sh
xcodebuild -scheme Liminal -destination 'platform=macOS' build
xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

- The full unit suite takes several minutes. For audio work, use the narrower Lo-Fi test list in `docs/development.md#lo-fi-checks` or `-only-testing:LiminalTests/<Suite>`.
- Tests use **Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest.
- Never change signing settings to work around a local build failure. A new Xcode may need `xcodebuild -downloadComponent MetalToolchain`.
- The project uses Xcode file-system synchronized groups, so new files under `Liminal/` and the test folders join their targets automatically. Do not hand-edit `project.pbxproj` to add them.

### Visual verification

A successful build does not show that the visuals are correct. Build, terminate the old process, relaunch the new build, capture with `/opt/homebrew/bin/peekaboo`, and look at the image. Use element IDs where possible.

- visionOS Simulator: `xcrun simctl io <udid> screenshot x.png` (captures immersive content), and `scripts/sim-tap.sh X Y` / `scripts/sim-drag.sh` for input in 3840×2160 screenshot coordinates. AXe and XcodeBuildMCP UI taps do not work. See `docs/research/visionos-sim-automation/README.md`.
- PERF log lines: `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.saygoodnight.Liminal"'`.
- Simulator ML depth is all zeros. Use `-LiminalDepthImage` / `-LiminalShellCycle` fixtures, and treat hardware behavior as unverified until checked on a device.
- Simulator performance is not device performance. Use it only for before/after comparisons.

## Automation launches

Any DEBUG launch with an automation flag (`-LiminalAutoPlay`, `-LiminalOpenDome`, `-LiminalMusicSeed`, `-LiminalFreezeTime`, perf/test flags…) may fetch pictures from the free public image APIs. Pass `-LiminalImageAPIFresh YES` so the run fills a throwaway verify pool instead of the user's, or `-LiminalImageAPIOffline YES` to show only saved pictures with no network. Image flags: `-LiminalImageProvider`, `-LiminalImageAPIOffline`, `-LiminalImageAPISeed`, `-LiminalImageAPIFresh`. Add any new automation flag to `DebugLaunchOptions.isAutomated`.

## Repository map

- `Liminal/LiminalApp.swift`, `ContentView.swift`, `*Section.swift`, `ControlComponents.swift`, `MusicControls.swift` (tempo and scale), `ImageCreditControls.swift` (credit line and collections status): macOS entry point and shared control UI.
- `Liminal/visionOS/`: visionOS app, control window, `ImmersiveDomeView` render loop, `OffscreenEffectsRenderer` (2048² mono render into a RealityKit `DrawableQueue`), `SourceTextureUploader`, shell mesh/materials, head pose.
- `Liminal/Audio/`: `GenerativeEngine` facade (graph, start/stop, route recovery), `ArchiveConductor` (own queue; drives the film bed and chops), `ArchiveMixBus` (the footage bus), `ArchiveStrip` (the film bed's strip), `AudioRamps` (`ParamRamp`, `SoftEnv`, `expMap`, `dbToGain`), `OfflineRender`, `ArchiveVoice`, `MusicState`.
- `Liminal/Audio/Lofi/`: `LofiScore` (32-bar forms, motifs), `LofiRenderer` (off-audio-thread phrase render), `LofiPlayback` (transport, phrase queue, late-phrase fallback, clock publishing), `LofiBus`/`LofiMasterBus`, `LofiDrumTake`/`LofiDrumLibrary`/`LofiBeatGrid`, `LofiSpeechFocus`, effects and sidechains. `InstrumentSamples/` holds the CC0 samples credited in `docs/lofi-samples.md`. Also `LofiStemChains` (per-bus chains), `LofiDrumLandmarks` and `LofiTimingField` (attack landmarks and the sparse shared timing), `LofiFillDetector` (where each take's halfway and turnaround fills start, for the drop transitions), `LofiBassVoice` (the bass tones, `LofiBassTone`: synthesized sub below 160 Hz, one dark layer above, a strike on kick-anchored notes; `LofiBassTone.tone(seed:phrase:)` rotates round, upright and synth every 16-bar break, D120), `LofiBassSamples` (the `LofiBass-*` body kits), `LofiBassThrow` (dub throws into the wet stem) and `LofiBassThrowSend` (the frozen D116 throw send), `LofiPadVoice` (granular held pad), the per-part files `LofiScore+Bass`/`+Mids`, `LofiRenderer+Bass`/`+Texture` and `LofiStemChains+Bass`/`+Mids`/`+TapeNull` (the last is the capture-only null test across the drum tape stage, D121), and `LofiCaptureHooks` (offline capture taps, inert in the app), plus `LofiPreset` (per-take instrument programs), `LofiSampleBank` (lead multisamples), `LofiGuitarPhrasing` (guitar ornaments, D114), `LofiSpectralHold` (resynthesized note shadows), `LofiMotion` and `LofiWetTone` (wet-stem colour and its linked shelf).
- `Liminal/Audio/Lofi/Dialogue/`: dialogue chopping. Analyzer, hierarchy, pad bank builder, motif and performer (hook roles and templates, D125; gated hits and the 16-bar arc, D126; the chop beat's groove cell and loop feel in `DialogueChopBeat`, D127), waveform onsets of pads (`DialogueOnset`, D126), line interest scoring (`DialogueLineInterest`, D124), reorder guard, chop renderer, cue coordinator and director, transcription provider and assets. See `docs/architecture.md#dialogue-chopping-pipeline`.
- `Liminal/Audio/Lofi/DSP/`: biquad, dynamics, loudness, saturation, stereo, true peak, master kernel and finisher.
- `Liminal/Visual/`: `ImageQueue` (the reserve and the display queue over the feed), `ImageStore`/`AtomicImageBuffer`, `ImageFraming`, `SaturationMeter`, `DepthMapGenerator` (Core ML depth), `DepthAnalyzer` (Vision saliency, an actor), `TimerDrivenCrossfade`, `EffectsMetalView` (macOS), `EffectsUniformsComputer`, `MusicReactor`/`MusicModulation`, `Spatial/`.
- `Liminal/Visual/ImageSources/`: the image pipeline. `image-collections.json` (the approved sources and gates) and `ImageCollections`, `ImageHTTP` (paced https client), `Providers/` (LOC, NASA, Wikimedia, Cleveland, Met, Digital Commonwealth, Art Institute of Chicago, optional Smithsonian), `ImageRights`, `ImageOpenness`, `ImageRotation`, `ImageIdentity` (catalogue aliases and the duplicate fingerprint), `CuratedImagePool` (own store + ledger, 3 GB) and `CuratedImageFeed` (ingest and display). `Liminal/ImageCreditControls.swift` holds the credit line and the collections status row.
- `Liminal/Shaders/`: `EffectsRenderer.metal` (single staged fragment shader), `ArchiveVideo.metal`, `RecorderCopy.metal`. `Liminal/EffectsUniforms.swift` is the CPU-side layout contract.
- `Liminal/Archive/`: catalog/client/seed list (`archive-seeds.json`), `ArchiveClipStore` (3 GB cache, 10 pinned + 2 rotating, launch sweep of unindexed and temp files), `VideoFrameSource`, `FootageWeaver`, `VideoComposite`, `ArchiveAudio` (decode and cue math).
- `Liminal/Recording/`: `FrameRecorder` (renderer frames into HEVC in the frame's own command buffer, the `GenerativeEngine.recordTap` mix into 24-bit LPCM through a lock-free ring of buffers and time stamps), `RecordingTiming` (`FrameSlotter` and `AudioTimeline`: the pure movie-clock decisions, D47), `RecordingController` (start/stop, Photos), `RecordControls`. See `docs/recording.md`.
- `Liminal/Services/`: `SettingsService` (persistent settings: scale, tempo, effect and footage controls).
- `Liminal/Utils/DebugLaunchOptions.swift`: every debug launch flag, compiled out of Release. The flag table is in `docs/development.md`.
- `LiminalTests/`, `LiminalUITests/`; `scripts/` (perf, shader bench, transition/footage clips, Lo-Fi capture and analysis, archive curation; `mix-report.sh`, `mix-matrix.sh`, `mix-criteria.json` and `mixlib/` for mix verification; `solo-stems.py` and `stem-bands.py` for per-channel levels and bands, `bass-tone.py` for the bass tone gates, `distortion-report.py` for clip detection, stage nulls, encode overs and the distortion gates; `av-sync-check.py` for recorded movies' A/V sync); `tools/` (standalone Swift harnesses, including `TapTimingCheck.swift` for the tap clock).
- Docs: `docs/README.md` (index), `architecture.md`, `experience.md`, `development.md`, `decisions/` (rationale, with numbered items such as D34 and A30), `plans/` and `research/` (may describe unfinished or historical work). The older uppercase docs (`PLATFORM_ARCHITECTURE.md`, `DUAL_PIPELINE_ARCHITECTURE.md`, …) predate current decisions. Check the source before relying on them.

## Contracts to preserve

**Swift concurrency.** The app target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency (Swift 5 mode). Unannotated types are main-actor isolated. Code that runs off the main actor must be `nonisolated`, `@concurrent`, an actor, or `Task.detached`. Examples: `nonisolated enum ImageFraming`, `@concurrent reserveForFill`, `actor DepthAnalyzer`. Keep heavy work off the main actor: image cropping, colour stats, texture builds, saliency and depth inference.

**Audio.**
- Do not block, allocate or take locks on realtime render paths and tap blocks. Use `Atomic` and `Mutex` from the Synchronization framework.
- Device-property getters such as `outputPresentationLatency` query Core Audio synchronously. Read them once when arming the transport, not on per-tick paths.
- Preserve the scheduling and thread boundaries. The conductor has its own queue. Phrases render off the audio thread and are scheduled sample-accurately on the five stem players plus the dialogue input.
- Late-phrase fallback: interior phrases queue early. A phrase that misses its deadline repeats the previous stems on the same grid. Do not reintroduce silent rests.
- Route changes that stop `AVAudioEngine` re-arm music and the visual clock together through `GenerativeEngine.recoverStoppedGraph`. A user Stop cancels a pending recovery.
- Drum takes keep their original sample grid and interior fills. Only the outer 1 ms attack and 4 ms release are tapered.
- Keep fades, cache limits, and the separate soundtrack and dialogue paths.
- Dialogue analysis never delays the film bed or the music. Plans carry the cue token and revision (`ArchiveVoice.perform` ignores stale tokens and lower revisions). The acoustic fallback is always retained when transcription is unavailable.

**Rendering.**
- Image row 0 is the top. Use the same 3:2 cover crop (`ImageFraming`) on both platforms, and register saliency and depth with the same normalized crop as the colour image.
- `EffectsUniforms` (Swift) must match the Metal struct exactly. `EffectsUniformsComputer` is the single source of truth for both renderers.
- Per-frame shader constants are passed with `setFragmentBytes` so each in-flight command buffer has its own copy. Do not go back to one shared `MTLBuffer` that the CPU overwrites.
- Build depth textures fresh rather than overwriting one that a frame in flight may still use.
- visionOS: never lower the 2048×2048 render size. Optimize shaders (ALU, precision, octaves, function constants) instead. Acquire drawables on the serial worker (`acquireDrawable`) before sampling the frame's state. When the GPU is saturated, skip a submission rather than block.
- A staged visionOS picture (`PreparedImageSlot`) owns its colour texture, depth, depth texture and relief field, so a late depth result can never attach to another picture.

**Images.**
- Pictures come only from the curated pipeline (decisions/images.md D36-D41). Display reads only from its own pool (`CuratedImageStore/`, no count cap, 3 GB budget evicting the least recently shown); the network only adds to the pool, so the rotation keeps going offline. Display never repeats a picture while a never-shown one is available, and ingest skips copies of a stored picture under another id (catalogue aliases, perceptual fingerprint, D48).
- Keep pictures only when their record passes `ImageRights` (PD, CC0, no known restrictions, CC BY / BY-SA) and keep each picture's credit.
- Keep network, decode and ledger writes off the main actor.

**Recording.** Every movie frame and audio buffer is placed by its own presentation or heard time on one movie clock (`FrameSlotter`, `AudioTimeline`, D47). Never place by "next slot" or "next sample" alone, never stamp audio by sample count across a gap, and keep the recorder's tap free of locks and allocation. Check movies with `scripts/av-sync-check.py`.

**Archive.** Retain each source's credit (`docs/experience.md` film table). Ten pinned films plus two rotating discoveries share a 3 GB cache. Do not add size caps or budgets that change what can play (user decision, 2026-11-19, A31); if more storage is needed, raise the storage. Launch cleanup only removes files the index does not list and stale temp files.

## Never commit

Credentials of any kind, the private drum recordings in `Liminal/SlowBurnDrums/` and `Liminal/Audio/Lofi/SlowBurnBeatGrid.json` (both gitignored), user schemes/`xcuserdata`, caches, build products, perf captures, or raw personal recordings. README media is curated in `docs/media/`.

Do not casually regenerate or delete the bundled Core ML model (`DepthAnythingV2SmallF16.mlpackage`).

## Useful debug flags and scripts

All flags are in `DebugLaunchOptions.swift` and documented in `docs/development.md`. Common ones:

- `-LiminalAutoPlay YES`, `-LiminalOpenDome YES`, `-archive.enabled YES` (settings keys work as launch args too)
- `-LiminalMusicSeed <n>` replays a score (seed printed in "Music graph built … seed N"), and `-LiminalVideoSeed <n>` pins the footage weaver
- `-LiminalVideoOffline YES` (cache only), `-LiminalVideoFile <mp4>`, `-LiminalTestImage <path|dir>`, `-LiminalFreezeTime <s>`
- `-LiminalTraceLofi YES` (exact take sample ranges), `-LiminalDelaySecondTake <s>` (forces the late-phrase fallback)
- `scripts/perf-run.sh`: visionOS simulator perf with a JSON summary. It fails on a ≥100 ms frame, missed drum or picture changes, a repeated phrase or timed rest, a master-tap clock gap, or a Core Audio overload.
- `scripts/check-lofi.sh`: headless Lo-Fi capture with LUFS, true-peak and routing checks (needs FFmpeg and Python 3).
- `scripts/mix-report.sh` (one capture) and `scripts/mix-matrix.sh` (five cases, `--strict` gates on fail-level criteria in `scripts/mix-criteria.json`): per-bus stems, spectrograms, masking, low end, loudness, true peak, limiter reduction, intelligibility and chop cadence. Interpretation is in `docs/mix-verification.md`. Run one capture at a time, and keep captures out of git.
- `scripts/shader-bench.sh`, `tx-clip.sh`, `ffx-clip.sh`, `av-sync-check.py`. Read a script's options before running it, because some fetch network fixtures.

## Documentation and commits

- Keep docs synchronized with source in the same change. Measurements and rationale go into the matching `docs/decisions/*.md` with dates, and user-facing behavior goes into `experience.md`/`architecture.md`. Documentation-only work should not touch app source.
- Use sosumi.ai instead of developer.apple.com for Apple documentation.
- Commit messages: recent history uses a plain, descriptive sentence-case subject with no prefix or emoji (e.g. "Pin Thinking Machines and Hear Here alongside two rotating discoveries"). Older history used gitmoji conventional commits. Work on `main` unless asked to branch, and keep changes scoped to the request.
