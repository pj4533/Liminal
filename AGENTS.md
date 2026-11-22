# Liminal repository guide

## Scope and workflow

Liminal is a native SwiftUI audiovisual app for macOS 26+ and visionOS (Apple Vision Pro). It plays lo-fi beats with archive dialogue chopped on the beat, shows curated public-domain and openly licensed pictures from library, museum and NASA APIs, renders them through Metal effects, and blends footage from the Internet Archive. No web backend or iOS target exists. Keep documentation synchronized with source; decision records describe rationale, while plans may describe unfinished work.

Always build after changes. Always specify a destination to xcodebuild. Do not change signing settings to work around a local build failure.

```sh
xcodebuild -scheme Liminal -destination 'platform=macOS' build
xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

Use installed SDKs and available simulator names. Resolve Swift packages through Xcode; pins are in the workspace Package.resolved. Never commit credentials, user schemes, caches, build products, or raw personal recordings.

## Repository map

- `Liminal/LiminalApp.swift`, `ContentView.swift`, shared control sections (`MusicControls` for tempo and scale, `ImageCreditControls` for the credit line and collections status): macOS entry point and UI.
- `Liminal/visionOS/`: visionOS entry point, control window, immersive depth-displaced shell, head pose, source upload, offscreen rendering and RealityKit materials.
- `Liminal/Audio/`: GenerativeEngine facade, `ArchiveConductor` and `ArchiveMixBus` for the film bed and chops, `AudioRamps`, offline renders, and archive audio voices.
- `Liminal/Audio/Lofi/`: Lo-Fi form and motifs, acoustic sample playback, full-take drum transport, fill detection for the drop transitions (`LofiFillDetector`), footage-dialogue chopping, and stereo effects. The score and DSP tests plus `scripts/check-lofi.sh` verify this path. Keep the private drum files and beat-grid catalog out of Git. See [instrument credits](docs/lofi-samples.md) for the bundled CC0 samples. Related files in this folder: `LofiStemChains` (per-bus chains), `LofiDrumLandmarks` and `LofiTimingField` (drum attack landmarks and the sparse shared timing), `LofiBassVoice` (the bass tones, `LofiBassTone`: synthesized sub below 160 Hz, one dark layer above, a strike on kick-anchored notes; `LofiBassTone.tone(seed:phrase:)` rotates round, upright and synth every 16-bar break, D120), `LofiBassSamples` (the `LofiBass-*` body kits), `LofiBassThrow` (dub throws into the wet stem) and `LofiBassThrowSend` (the frozen D116 throw send), `LofiPadVoice` (granular held pad), the per-part files `LofiScore+Bass`/`+Mids`, `LofiRenderer+Bass`/`+Texture` and `LofiStemChains+Bass`/`+Mids`/`+TapeNull` (the last is the capture-only null test across the drum tape stage, D121), and `LofiCaptureHooks` (offline capture taps, inert in the app), plus `LofiPreset` (per-take instrument programs), `LofiSampleBank` (lead multisamples), `LofiGuitarPhrasing` (guitar ornaments, D114), `LofiSpectralHold` (resynthesized note shadows), `LofiMotion` and `LofiWetTone` (wet-stem colour and its linked shelf).
- `Liminal/Audio/Lofi/Dialogue/`: dialogue chopping. Analyzer, speech hierarchy, pad bank builder, motif and performer (performance plans, hook roles and templates, D125; gated hits and the 16-bar arc, D126; the chop beat's groove cell and loop feel in `DialogueChopBeat`, D127), waveform onsets of pads (`DialogueOnset`, D126), line interest scoring (`DialogueLineInterest`, D124), reorder guard, chop renderer, cue coordinator and director, transcription provider and speech assets. See [architecture](docs/architecture.md#dialogue-chopping-pipeline).
- `Liminal/Audio/Lofi/DSP/`: biquad, dynamics, loudness, saturation, stereo, true-peak, the master kernel and the master finisher.
- `Liminal/Visual/`: image queue/store/framing/depth, MusicReactor and computed effect uniforms.
- `Liminal/Visual/ImageSources/`: The image pipeline: the approved collections (`image-collections.json`), a paced https client, one provider per institution API (LOC, NASA, Wikimedia Commons, Cleveland, Met, optional Smithsonian), the rights rule, openness scoring, rotation, the curated pool and the ingest/display feed.
- `Liminal/Shaders/`: GPU effects. `EffectsUniforms.swift` is the CPU-side layout contract.
- `Liminal/Archive/`: Internet Archive catalog/client, seed list, disk clip cache, frame source, FootageWeaver and compositing/audio.
- `Liminal/Recording/`: the Record button: renderer frames and the final mix into a movie saved to Photos (`docs/recording.md`). `RecordingTiming.swift` holds the movie-clock decisions: each frame and audio buffer is placed by its own presentation or heard time, never by "next slot" or sample count across a gap (D47); check movies with `scripts/av-sync-check.py`.
- `Liminal/Services/`: persistent settings (scale, tempo, effect and footage controls).
- `LiminalTests/`: image, spatial, transition, effect, archive, music and coupling checks. `LiminalUITests/`: UI and launch tests.
- `scripts/`: simulator interaction, GPU performance, transition/footage clips, Lo-Fi capture and analysis, archive curation and visual measurements. `mix-report.sh` and `mix-matrix.sh` capture Lo-Fi audio and measure the mix against `mix-criteria.json`, using the modules in `scripts/mixlib/`; `solo-stems.py` and `stem-bands.py` give per-channel levels and bands, `bass-tone.py` checks the bass tone gates, `distortion-report.py` measures clipping, stage nulls and encode overs against the distortion gates, `strum-report.py` measures the guitar and harp strums (D128), and `av-sync-check.py` checks a recorded movie's A/V sync; read [mix verification](docs/mix-verification.md) first. Inspect script options before execution; some fetch network fixtures or require local tools.
- `tools/`: standalone Swift visual and audio harnesses (`TapTimingCheck.swift` checks the audio tap's clock against `play(at:)`).
- `docs/decisions/`: design decisions and review index; `docs/plans/` and `docs/research/`: implementation plans and research. Older architecture documents may predate current decisions.
- Bundled Core ML resource: DepthAnythingV2SmallF16.mlpackage. Do not casually regenerate or delete binary model assets.

## Behavioral and rendering contracts

Harmony can evolve automatically or pin a scale. MusicState feeds visual modulation. Preserve audio scheduling and thread boundaries; avoid work or allocation on realtime paths.

Dialogue analysis never delays the film bed or the music. A dialogue plan carries its cue token and revision, and stale tokens and lower revisions are ignored. Transcription is optional: the acoustic fallback is always retained and is used whenever transcription is unavailable. Verify mix changes with the [mix verification](docs/mix-verification.md) tools (`scripts/mix-matrix.sh`) rather than by ear.

Images use row zero at the top. Preserve consistent crop/orientation across platforms. CPU and Metal uniform structures must match exactly. EffectsUniformsComputer is shared computation; macOS uses MTKView and visionOS renders into RealityKit drawable textures on a depth-displaced wraparound shell. Simulator depth inference can be zero: use depth fixtures and validate actual hardware separately.

Pictures come only from the curated pipeline (decisions/images.md D36-D41). Display shows only the pool on disk (its own store, 3 GB, least recently shown evicted past the budget), keeps only pictures whose record is public domain, CC0, no known restrictions or CC BY / BY-SA, and keeps a credit for each. It never repeats a picture while a never-shown one is available, and ingest skips copies of a stored picture under another id (D48). Keep network, decoding and ledger writes off the main actor.

Archive footage weaves changing segments, looks and interaction recipes into the still-image anchor. The 12-film pool keeps ten pinned sources and two rotating discoveries. The filtered continuous soundtrack and beat-scheduled speech have separate audio paths. The dialogue path levels each cut and includes its own delay and room. Preserve fades and cache limits. Do not add size caps that change what can play (A31); launch cleanup only removes unindexed footage and stale download temp files. Retain individual archive source credits.

## Safe validation and visual review

DebugLaunchOptions documents automation flags. Automated launches fetch pictures from the free public image APIs; pass LiminalImageAPIFresh (a throwaway pool that keeps runs out of the user's) or LiminalImageAPIOffline (saved pictures only, no network). LiminalImageProvider and LiminalImageAPISeed are automation flags too. Relevant scripts include perf-run.sh, shader-bench.sh, tx-clip.sh, ffx-clip.sh and av-sync-check.py.

Always use `/opt/homebrew/bin/peekaboo` for visual verification. Build, terminate the old app process, relaunch the newly built app, capture using Peekaboo and actually view the resulting image. Use element IDs for interaction when possible. Screen Recording and Accessibility permissions are required for live UI automation. For recorded footage, Peekaboo capture video can sample frames for review. Never infer visual correctness from a successful build alone.

Use sosumi.ai rather than developer.apple.com when retrieving Apple documentation. Keep changes scoped to the request. Documentation-only work should not alter app source. README media is curated in docs/media; the original Desktop recording is not part of the repository.
