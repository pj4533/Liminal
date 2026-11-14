# Image pipeline decisions

## Summary (read this first)

- Model: gemini-3.1-flash-image at 3:2, 2K, with the existing key. About half of prompts tagged needsStrongSurreal (about 10% of images) go to gemini-nano-banana-2.1. Fallback chain: gemini-3.1-flash-lite-image, then gemini-2.5-flash-image, then recycle cached images. Chosen because it was the most photographic and colorful of the five models the key exposes (D1-D3).
- Prompt system: style (16, 13 photographic) x subject (about 110 concrete objects/places) x transformation (25) x palette (17) x composition (8), with recency-weighted anti-repetition and 20% chance of a 3-4 image series (D5, D10, D11). No people, no text-bearing subjects (D8, D9). The old scenes survive as one style (D6).
- Clear cache on device: open the controls panel, find "Clear All Images" (ClearImagesSection, same in the visionOS controls and the macOS window), confirm. It wipes all caches, cancels in-flight work and restarts generation (D15). Also, this release bumps cacheEpoch to 2, so the first launch deletes the old cached images automatically (D14).
- Scores, eval1 (16 new vs 6 old, 1-5): recognizability 5, photorealism 4, style variety 5, palette variety 4, surreal 5, effect suitability 4. Old set was samey blue-grey abstract CGI-looking scenes (D32).
- Open questions for the user:
  1. Spend: pacing generates only to keep 2 images pending, but 2K Gemini images are costlier than before. Want an hourly cap setting?
  2. Another provider or key: not worth it now (D31). Flux, gpt-image or Midjourney were not tested and each needs a new key. Revisit only if you want more control over style than Gemini gives.
  3. Teal skew and studioProduct frequency (D32 follow-ups): tune now?
  4. Renderer workstream: macOS window is now 3:2 (D28) and GPU textures persist after Clear until the next image (D15).
  5. Unit-test runs on macOS purge the local cache once (D29).

Format: decision, why, alternatives.

## D0 Baseline mapping
- Decision: document current pipeline before changes (docs/plans/images-current.md).
- Why: ground later changes in facts.
- Alternatives: none.

## D1 Model evaluation
- Decision: evaluate the five image models the key exposes; details in docs/research/image-models.md.
- Why: the current model (gemini-2.5-flash-image) was the least photographic of the five.
- Alternatives: other providers (Flux, gpt-image, Midjourney). Not tested; none is clearly better for this look, and each needs a new key.

## D2 Primary model gemini-3.1-flash-image, with a fallback chain
- Decision: primary gemini-3.1-flash-image. About half of prompts tagged needsStrongSurreal (melt, unravel, shatter; about 10% of all images) go to gemini-nano-banana-2.1. On 429/5xx/404/timeout fall back to gemini-3.1-flash-lite-image, then gemini-2.5-flash-image, with a doubling cooldown per model. If every model is cooling down, recycle cached images.
- Why: 3.1 flash was the most photographic and colorful at about 9s (1K). It is literal about surreal state changes, where nano-banana-2.1 was the only model that melted the carousel. A safety block is a prompt problem, so it draws a new prompt and keeps the model.
- Alternatives: gemini-3-pro-image as primary (best fidelity, twice the price, 16s); single model with no routing (simpler, loses the melt effects); no fallback (display stalls on quota errors).

## D3 Request 3:2 at 2K, skip the upscalers for large images
- Decision: imageConfig aspectRatio "3:2", imageSize "2K" (verified 2528x1696 JPEG, 15.5s). ImageUpscaler returns the input unchanged when the long side is at least 2048.
- Why: the dome panel is 110x75 degrees (1.47:1) and the offscreen renderer stretches any source into a square texture that the panel stretches back, so 3:2 displays with about 2% distortion and no renderer change. Square is stretched 47%, 16:9 squeezed 17%. At 2K the image already exceeds the 2048 renderer texture; MetalFX 4x would produce a 10112 px image and RealESRGAN squashes to 512 first.
- Alternatives: 16:9 (worse fit); 1K plus upscaling (cheaper, visibly softer, keeps the 512 squash on macOS); 4K (no visible gain through a 2048 texture).

## D4 macOS visual area becomes 3:2
- Decision: change SquareVisualWindowDelegate to a 3:2 visual area. Fallback if the macOS renderer assumes square: center-crop to square in the macOS branch of ImageQueue.
- Why: otherwise 3:2 images are squeezed 50% on macOS.
- Alternatives: generate square on macOS only (two prompt/cache variants); letterbox (needs renderer work).
- Needs a check with the renderer workstream.

## D5 Style x subject x transformation x palette x composition grammar
- Decision: 16 styles (13 photographic at 78%, 3 abstract/continuity at 22%), about 110 concrete subjects in 9 categories, 26 transformations in 12 kinds, 17 palettes, 8 compositions. Details in docs/plans/images.md.
- Why: today only the scene varies and 60 words of shared boilerplate pin the look. Independent axes give variety, and concrete nouns give the viewer something to recognize, which is what makes the shader effects land.
- Alternatives: an LLM writing prompts (more variety, but adds latency, cost and a non-deterministic step that cannot be unit-tested); a longer flat list of hand-written scenes (what exists now, does not scale and cannot avoid repeats by axis).

## D6 Keep the existing look as one style, not the whole system
- Decision: about 14 of the 50 current scenes that name a concrete place survive as the cosmicDream style at about 6%. fractalNature and liquidAbstract carry the fractal and pattern vocabulary as real photographed things.
- Why: the user asked to build on what exists. The abstract-metaphor scenes ("stacked moments in time") are the ones models render as generic digital art, so those are dropped.
- Alternatives: keep all 50 (keeps the samey look); drop them all (throws away the continuity the user asked for).

## D7 Positive phrasing only; drop "Natural, realistic colors" and the "not illustration" list
- Decision: no negative style lists. Each prompt names an explicit palette, and ends with a fixed tail that includes "Full-bleed photograph: the scene fills the entire image edge to edge".
- Why: tested today. "Kodak Aerochrome film, medium format ... no border, no frame" came back with a white film-scan border; "in the look of Aerochrome film" plus the full-bleed sentence did not. "Natural, realistic colors" suppresses exactly the color the user wants.
- Alternatives: keep the negatives (primes the look they name); rely only on a border-trimming pass.

## D8 Leave out subjects that carry text; tag the borderline ones
- Decision: no clocks, signs, books, labelled bottles or neon signs. Subjects such as the rotary phone and typewriter are tagged textProne and get "all surfaces blank and unmarked".
- Why: tested today. "No lettering" did not remove the numerals on a phone dial, and garbled text is the fastest way for an image to look fake.
- Alternatives: allow text and accept defects; detect text after generation (needs OCR, not worth it).

## D9 No people in prompts
- Decision: the tail says "no people"; no human subjects in the library.
- Why: faces under distortion shaders read as unpleasant rather than trippy, and people raise the safety-block rate.
- Alternatives: silhouettes only. Could be added later as a style.

## D10 Anti-repetition by recency-weighted draws; history persisted
- Decision: each axis is drawn with weight x recency penalty (style not within 2, palette not within 3, subject not within 40, category and transformation kind not back to back). History is saved in UserDefaults.
- Why: uniform random draws repeat far more often than people expect; a restart should not replay the same style.
- Alternatives: shuffle-bag per axis (no repeats at all, but couples axes and makes series awkward); no memory.

## D11 Series: 20% chance to start a run of 3 or 4 related images
- Decision: four kinds (same subject, same palette, same style and category, same material), with the other axes forced to differ.
- Why: consecutive images that relate give the session some shape without making it samey.
- Alternatives: no series; longer arcs driven by the music (later, once audio reads the metadata).

## D12 Metadata is carried next to the image, not inside it
- Decision: ImageMetadata (prompt spec, model, measured dominant colors, brightness, saturation) travels through AtomicImageBuffer via new additive methods and is stored as a JSON sidecar. Existing buffer methods keep their signatures.
- Why: the renderers belong to another workstream and must keep compiling untouched. Measured colors matter because the model does not always follow the palette.
- Alternatives: a new GeneratedImage type replacing CGImage everywhere (cleaner, but touches renderer code); intended palette only (wrong when the model drifts).

## D13 One ImageStore directory, original bytes, lazy decode, 400-image cap
- Decision: Application Support/Liminal/ImageStore holds the model's original bytes plus a sidecar per image, on both platforms. Images are decoded when needed. Oldest are evicted beyond 400.
- Why: output is JPEG, not PNG; macOS was re-encoding 2048 PNGs; visionOS decoded the whole cache into memory at launch, which at 2K is 17 MB per image.
- Alternatives: keep two directories and formats (more code, more ways for Clear to miss files); no cap.

## D14 cacheEpoch purges automatically; prompt version alone does not
- Decision: ImageStore.cacheEpoch (set to 2 in this release) is compared with a stored value at launch; a lower or missing value deletes ImageStore plus the legacy RawImages and UpscaledImages directories. PromptLibrary.version is only recorded in metadata.
- Why: the user wants the old images on the Vision Pro gone, and they are the wrong shape for the new pipeline, so this release should remove them without anyone finding a button. But each image costs money, so routine wording changes must not wipe the cache.
- Alternatives: purge on every prompt-version bump (wasteful); never purge automatically (old square images keep appearing until the user clears by hand); keep old images but stop showing them (uses disk for nothing).

## D15 Single "Clear All Images" path through VisualEngine, with confirmation
- Decision: both UIs call VisualEngine.clearAllImages(). It deletes whole directories, cancels the generator or recycler, clears the buffer (pending, depth, metadata), resets prompt history, posts one notification, and restarts generation. A clearGeneration counter makes an in-flight image get dropped instead of re-added.
- Why: the current buttons delete only *.png in two directories, the visionOS recycler keeps re-queuing deleted images from memory, and an in-flight generation can land after the clear.
- Alternatives: keep the notification-only design (cannot cancel or restart tasks in order); separate buttons per cache (the user asked for one).
- Known limit: renderer GPU textures stay until the next image; dropping them is a renderer change for the other workstream.

## D16 Pace generation to display
- Decision: generate only while fewer than 2 images are pending.
- Why: the current loop generates continuously with a 2s pause while images are shown every 30s. The visionOS pending queue is unbounded, so memory grows and about two thirds of the API spend is never displayed in a typical session.
- Alternatives: leave it (fills the cache faster, at that cost); a hard hourly budget (possible later as a setting).

## D17 Pure PromptBuilder, compiled standalone for prompt dumps
- Decision: Liminal/Visual/Prompt/ imports Foundation only. scripts/print-prompts.sh compiles it with swiftc; scripts/gen-sample-images.py turns a prompt file into images and a labelled contact sheet.
- Why: prompt quality can be iterated without Xcode, the simulator or the app, and the standalone compile fails as soon as someone adds an app dependency to the builder.
- Alternatives: dump prompts from a unit test through an environment variable (works, but slow and awkward to pipe); duplicate the library in Python (two sources of truth).

## D18 BorderTrimmer as a safety net
- Decision: crop uniform white or black borders detected on all four sides before caching.
- Why: one of four test images came back with a film-scan border. The prompt fix worked, but a border on a dome is very visible and the check is cheap.
- Alternatives: prompt wording only; regenerate on detection (costs a second image).

# Implementation decisions

## D19 RGB lives in Prompt/, not ImageMetadata.swift
- Decision: `RGB` is defined in `Liminal/Visual/Prompt/PromptTypes.swift`.
- Why: `PromptSpec` carries palette swatches and Prompt/ must compile standalone with swiftc (D17).
- Alternatives: duplicate the type (two sources of truth).

## D20 Small API deviations from the plan
- Decision: `PromptSpec` gains `materialID` (materialThread series hold it). `ModelRouter.model(for:now:using:)` takes `now` and returns nil when every model is cooling down. `GeminiError.network` carries a String (keeps the enum Sendable). `ImageStore.save` takes an optional `trimmed` image; it adds `imageFiles()`, `entry(id:url:)` and `imageCount()` for the recycler so it never reads 400 sidecars to pick one image.
- Why: each was needed to implement a planned rule without a clock or globals in the pure types.
- Alternatives: keep the exact signatures and hide state (harder to test).

## D21 Library adjustments while implementing
- Decision: 25 transformations (plan said 26) with extra slots `{Sn}` (bare noun), `{S2p}` (plural second subject), `{MS}` (carvable materials) and `{B}` (burst items). Materials use plain names ("jade", added "white marble", "rose quartz") so "carved from a single block of jade" reads correctly. Styles gained `excludedTransformations` (macro never gets "flock", studioProduct never gets "standing alone in {E}") and `scaleOverrides` (macro accepts any subject as "a miniature X resting on a single leaf"; aerial/tiltShift/grandLandscape/longExposure accept small subjects only as "the size of a mountain").
- Why: generated sentences that read wrong ("carved from a single block of carved jade") or fought the style.
- Alternatives: free combination (produced nonsense in dumps).

## D22 Series feasibility rules
- Decision: subjectStudy never starts on a landscape subject; paletteRun never starts on the aerochrome palette; styleSet only starts in a category with at least 2x the series length of subjects and never on a palette-locked style; abstract styles in a styleSet hold only the style. A style is only drawn if it still has a fresh subject (with a fresh transformation kind) and a fresh palette. If a series cannot continue, it ends early instead of relaxing into repeats.
- Why: the first test runs showed series repeating a subject four times (flashNight + architecture = only the phone booth) and subjectStudy repeating a transformation kind.
- Alternatives: relax penalties inside series (produced the repeats).

## D23 Word budget trims
- Decision: shortened the tilt-shift lead, the monoCobalt clause, the lowAngle and patternHorizon fragments and the aerochrome texture; prompts now run 103-140 words over 15,000 samples.
- Why: worst cases hit 143 words against the 70-140 target.

## D24 Evaluation rounds (gemini-3.1-flash-image, 3:2, 1K)
- Round 1 (24 images, seed 101, strong-surreal prompts on nano-banana-2.1): all 24 photoreal and recognizable, clearly different looks. Defect: doubleExposure (4 in a styleSet run) and studioProduct came back on white/pale backdrops, which would flood the dome with white.
- Fix: doubleExposure lighting is now "a dark silhouette against a deep saturated dusk sky" and the second scene is named ("a vast landscape"); studioProduct asks for a "seamless backdrop in a deep palette color". doubleExposure weight 5 -> 4, prism 4 -> 5 (prism tested very well).
- Round 2 (16 images, seed 202, biased to those styles): no white backdrops; double exposures now readable.
- Also verified the fallbacks: gemini-3.1-flash-lite-image returns 1264x848 JPEG at 3:2/1K in 3.8s; gemini-2.5-flash-image accepts imageSize 1K and returns a 1248x832 PNG (the store keeps PNG bytes as .png).
- Images: scratchpad `images-eval/round1/`, `images-eval/round2/`, `images-eval/fallback/` (not in the repo).

## D25 BorderTrimmer trims only near-white borders
- Decision: uniform near-black edges are never cropped.
- Why: flashNight, biolumNight and macro produce black surroundings on purpose; cropping them cuts into the subject. The observed defect was a white film-scan border.
- Alternatives: trim both and require a sharp edge (more code, still risky on dark studio shots).

## D26 One cache recycler for both platforms; macOS live mode starts with an empty queue
- Decision: Cache Only mode and the all-models-cooling-down case both use `recycleOneFromCache()` (decode one image, avoid the last 50 shown). macOS no longer loads the whole cache into its display queue at start.
- Why: with pacing (D16) a preloaded macOS queue would block generation forever; it also kept every decoded image in memory.
- Alternatives: keep the macOS refill logic (it depended on unpaced generation).

## D27 Concurrency annotations
- Decision: the new pipeline types are `nonisolated` (the app target uses default MainActor isolation); `GeminiClient.generate` is `@concurrent`; `ImageQueue`, `AtomicImageBuffer`, `LMLog` and `EnvironmentService` are marked `nonisolated`. On visionOS the pipeline creates no UIImage at all.
- Why: keeps decoding and network work off the MainActor, which the 90fps visionOS render loop starves.
- Alternatives: leave the implicit MainActor isolation (work would hop to the starved main actor).

## D28 macOS 3:2 visual area needs no renderer change
- Decision: `SquareVisualWindowDelegate.visualAspect = 1.5`; no center-crop fallback.
- Why: `EffectsMetalView` draws a full-screen quad sampling the source texture, so any drawable aspect works. Renderer workstream may still want to know the window changed shape.

## D29 Clear and cache side effects to know about
- Running the macOS unit tests launches the app as test host, which runs `migrateIfNeeded()` and purges the local macOS cache once (epoch 2). That is the designed first-launch behavior.
- Renderer GPU textures still hold the last image until a new one arrives (D15 known limit; renderer workstream).

## D30 Commit attribution
- Decision: commits from the implementation step end with the session's current attribution lines (Co-Authored-By Claude Opus 5.5 plus the Claude-Session link).
- Why: that is the attribution the session supplied; it also matches the shared rules.

## D31 Provider recommendation unchanged
- Decision: stay on Gemini with the existing key. No other provider or key is needed for the requested look.
- Why: two evaluation rounds on gemini-3.1-flash-image produced photoreal, recognizable, colorful surreal images; the open question is spend (about 120 images an hour at 2K when playing), not quality.

## D32 Evaluation round (eval1): fresh seed 7301, 16 new vs 6 old
- Setup: both platform builds succeeded. 16 prompts from `scripts/print-prompts.sh -n 16 -s 7301`, generated on gemini-3.1-flash-image 3:2 1K. Old-style: the first 6 baseline prompts from docs/plans/images-current.md on gemini-2.5-flash-image 1:1 (the old config). Images: scratchpad `images-eval/round1/` and `round1/old/` (the earlier implementation-time round was moved to `round1-prev-impl/`).
- Viewed via the two contact sheets (new 4x4, old 2x3), not each full-size file.
- Scores (1-5): recognizability 5, photorealism 4, style_variety 5, palette_variety 4, surreal_trippy 5, effect_suitability 4. PASS; clearly better than old on recognizability (beetle, sailboat, guitar, pomegranate, antlers vs. abstract mood scenes), photorealism and variety. Old set was samey (blue-grey, centered abstract metaphors, CGI look).
- Problems: (1) teal/blue skew: 00, 04, 07, 08, 09 lean teal; (2) studioProduct drew 4 of 16 and its backdrops read similar; (3) 02 underwater has a small subject (diver) in a busy frame; (4) 15 cave and 11 prism are cluttered with weak focal point; (5) 04 and 11 prism lean CGI-ish; (6) no text artifacts seen.
- Possible follow-up, not done: slightly lower studioProduct weight, nudge palette picker away from teal-adjacent palettes after a teal one.
