# Liminal repository guide

## Scope and workflow

Liminal is a native SwiftUI ambient audiovisual app for macOS 26+ and visionOS (Apple Vision Pro). It synthesizes music, generates and caches Gemini images, renders Metal effects, and blends footage from the Internet Archive. No web backend or iOS target exists. Keep documentation synchronized with source; decision records describe rationale, while plans may describe unfinished work.

Always build after changes. Always specify a destination to xcodebuild. Do not change signing settings to work around a local build failure.

```sh
xcodebuild -scheme Liminal -destination 'platform=macOS' build
xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

Use installed SDKs and available simulator names. Resolve Swift packages through Xcode; pins are in the workspace Package.resolved. A local Liminal/Secrets.swift defining Secrets.geminiKey is required: copy Secrets.swift.template, keeping the placeholder if generation is unnecessary. GEMINI_API_KEY takes precedence. Never commit real keys, user schemes, caches, build products, or raw personal recordings.

## Repository map

- `Liminal/LiminalApp.swift`, `ContentView.swift`, shared control sections: macOS entry point and UI.
- `Liminal/visionOS/`: visionOS entry point, control window, immersive depth-displaced shell, head pose, source upload, offscreen rendering and RealityKit materials.
- `Liminal/Audio/`: GenerativeEngine facade, Ambient scheduler and synthesis layers, shared effects and mix, offline renders, and archive audio voices.
- `Liminal/Audio/Lofi/`: Lo-Fi scoring, acoustic sample playback, drum grids, and stereo effects. Keep the private drum files and beat-grid catalog out of Git. See [instrument credits](docs/lofi-samples.md) for the bundled CC0 samples.
- `Liminal/Visual/`: Gemini client and model routing, prompt construction/history, generation budgets, image queue/store/framing/upscaling/depth, MusicReactor and computed effect uniforms.
- `Liminal/Shaders/`: GPU effects. `EffectsUniforms.swift` is the CPU-side layout contract.
- `Liminal/Archive/`: Internet Archive catalog/client, seed list, disk clip cache, frame source, FootageWeaver and compositing/audio.
- `Liminal/Services/`: persistent settings and environment credentials.
- `LiminalTests/`: prompt, image, budget, spatial, transition, effect, archive, music and coupling checks. `LiminalUITests/`: UI and launch tests.
- `scripts/`: simulator interaction, GPU performance, transition/footage clips, music rendering/analysis, archive curation and visual measurements. Inspect script options before execution; some fetch network fixtures or require local tools.
- `tools/`: standalone Swift visual/prompt harnesses.
- `docs/decisions/`: design decisions and review index; `docs/plans/` and `docs/research/`: implementation plans and research. Older architecture documents may predate current decisions.
- Bundled Core ML resources: DepthAnythingV2SmallF16.mlpackage and realesrgan512.mlmodelc. Do not casually regenerate or delete binary model assets.

## Behavioral and rendering contracts

Music styles are Drift, Glass, Deep and Garden. Harmony can evolve automatically or pin a scale. MusicState feeds visual modulation; image mood feeds back into music. Preserve audio scheduling and thread boundaries; avoid work or allocation on realtime paths.

Images use row zero at the top. Preserve consistent crop/orientation across platforms. CPU and Metal uniform structures must match exactly. EffectsUniformsComputer is shared computation; macOS uses MTKView and visionOS renders into RealityKit drawable textures on a depth-displaced wraparound shell. Simulator depth inference can be zero: use depth fixtures and validate actual hardware separately.

Generation settings live in ImageGenerationConfig; budget caps live in GenerationBudget. Primary model is currently gemini-nano-banana-2.1, fallback gemini-3.1-flash-lite-image. Treat these as repository configuration, not independently verified provider availability. Cache reuse is the fallback when generation is unavailable or capped.

Archive footage weaves changing segments, looks and interaction recipes into the still-image anchor. Archive audio is deliberately quiet and filtered. Preserve fades and cache limits. Retain individual archive source credits.

## Safe validation and visual review

DebugLaunchOptions documents automation flags. Automated debug launches suppress generation unless explicitly opted in with LiminalAllowGeneration. Prefer cached images or test fixtures to avoid API spend. Relevant scripts include perf-run.sh, shader-bench.sh, tx-clip.sh, ffx-clip.sh, render-music.sh and av-coupling-check.sh.

Always use `/opt/homebrew/bin/peekaboo` for visual verification. Build, terminate the old app process, relaunch the newly built app, capture using Peekaboo and actually view the resulting image. Use element IDs for interaction when possible. Screen Recording and Accessibility permissions are required for live UI automation. For recorded footage, Peekaboo capture video can sample frames for review. Never infer visual correctness from a successful build alone.

Use sosumi.ai rather than developer.apple.com when retrieving Apple documentation. Keep changes scoped to the request. Documentation-only work should not alter app source. README media is curated in docs/media; the original Desktop recording is not part of the repository.
