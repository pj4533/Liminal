# Image pipeline decisions

## Summary (read this first)

- Model: gemini-3.1-flash-image at 3:2, 2K, with the existing key. About half of prompts tagged needsStrongSurreal (about 10% of images) go to gemini-nano-banana-2.1. Fallback chain: gemini-3.1-flash-lite-image, then gemini-2.5-flash-image, then recycle cached images. Chosen because it was the most photographic and colorful of the five models the key exposes (D1-D3).
- Prompt system: style (16, 13 photographic) x subject (about 110 concrete objects/places) x transformation (25) x palette (17) x composition (8), with recency-weighted anti-repetition and 20% chance of a 3-4 image series (D5, D10, D11). No people, no text-bearing subjects (D8, D9). The old scenes survive as one style (D6).
- Clear cache on device: open the controls panel, find "Clear All Images" (ClearImagesSection, same in the visionOS controls and the macOS window), confirm. It wipes all caches, cancels in-flight work and restarts generation (D15). Also, this release bumps cacheEpoch to 2, so the first launch deletes the old cached images automatically (D14).
- Scores, eval1 (16 new vs 6 old, 1-5): recognizability 5, photorealism 4, style variety 5, palette variety 4, surreal 5, effect suitability 4. Old set was samey blue-grey abstract CGI-looking scenes (D32).
- **API mode (D36-D41, 2026-11-21):** "Images: AI | API". API shows curated public-domain and openly licensed pictures from the Library of Congress, NASA, Wikimedia Commons, Cleveland and the Met, gated for rights, 2K size, room for the film, text and faces, kept in their own 3 GB pool with a credit per picture. API mode never calls Gemini.
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

## D33 Round 2 prompt tweaks: teal skew, studioProduct, subject size
- Decision: (1) palettes 17 -> 25: added scarletRose, saffronGold, magentaBloom, verdantGreen, sorbetPastel (high-key pastels), garnetAmethyst (jewel), coralMango, violetEmber, each weight 1.1-1.3. (2) Lowered teal/blue palette weights: deepSea 0.5, monoCobalt 0.5, rustAndTeal 0.5, borealis 0.6, neonNoir 0.7. (3) studioProduct weight 8 -> 3.5 with backdrop wording "bold palette color that contrasts with the subject"; added style sunlitStill (weight 3, hard window sun, long shadow on plaster wall and glossy tabletop) so product-like shots vary (styles 16 -> 17). (4) Tail now says "One large focal subject filling at least a third of the picture" (was "in the central third"); avoided the word "frame" because bannedWords forbids it. (5) Tests: counts 17 styles / 25 palettes; sunlitStill allowed any palette in styleRulesHold.
- Why: eval1 (D32) showed teal in 5/16, studioProduct 4/16 with similar backdrops, small subjects in 02 and 15.
- Numbers: 200 seeded prompts (seed 9001). Styles: cineStill 19, grandLandscape 18, aerial 17, longExposure 16, biolumNight 14, fractalNature 14, underwater 13, studioProduct 11, aerochrome 11, liquidAbstract 10, doubleExposure 10, tiltShift 9, flashNight 9, prism 9, macro 8, sunlitStill 7, cosmicDream 5. Palettes: acidCitrus 14, bloodMoon 14, ultraviolet 14, scarletRose 13, aerochrome 11, garnetAmethyst 10, verdantGreen 10, candyPastel 10, desertSunset 9, violetEmber 9, toxicBloom 9, coralMango 9, magentaBloom 8, jewelBox 7, neonNoir 6, primaries 6, rustAndTeal 6, moltenGold 5, pearl 5, borealis 5, deepSea 4, earth 4, sorbetPastel 4, saffronGold 4, monoCobalt 4. Teal/blue-led palettes (deepSea, monoCobalt, rustAndTeal, borealis, neonNoir) are now 25/200 (12.5%). Max prompt length 138 words (limit 140).
- Samples: 8 images (seed 7302, 3:2 1K) in scratchpad images-eval/round2/, contact sheet viewed. Warm/magenta/green/purple/orange now dominate; subjects (moth, fern tree, mushrooms, pomegranate, key, fox) fill roughly a third or more; studio backdrop purple/blue rather than teal. Remaining notes: 02 (pearl, tree in tiled hall) is pale and low-contrast; 07 underwater still leans teal because the underwater style itself implies it. saffronGold/sorbetPastel drew only 4/200 each (weight is relative to the style/palette filters), could be raised if wanted.
- Alternatives: backdrop variants per style (needs a builder change) instead of a new style; hard exclusion of teal palettes (loses variety).

## D34 (2026-11-15): Spending cap and no image generation from automated test launches

- **Why:** on 2026-11-14 the Google Cloud billing account crossed 90% and then 100% of its $100 monthly budget. During that day's development the app was launched about 95 times by automated perf, screenshot and Simulator checks, and every launch that pressed Play generated new 2K images. A budget alert only notifies; it does not stop spending. The app had no limit of its own.
- **What:**
  - `GenerationBudget` keeps a rolling ledger of generated images in UserDefaults (`visual.generationLedger`), so the cap survives relaunches. The generation loop checks it before every request; past the limit it shows cached images and a status line ("Hourly/Daily image limit reached ... new ones in about N min") until the window rolls.
  - Defaults: **20 new images per hour, 100 per rolling 24 hours**, adjustable with steppers next to Cache only on both platforms (0 = no new images). At default image pacing a session uses about 2 per minute until the queue is full, so 20/hour is roughly one new image every 3 minutes once a session settles.
  - DEBUG only: any launch with automation flags (`-LiminalAutoPlay`, `-LiminalOpenDome`, `-LiminalFreezeTime`, `-LiminalPerfLogInterval`, `-LiminalTestPattern`, `-LiminalTestImage`, `-LiminalNoEffects`, `-LiminalSyncLog`, ...) never calls Gemini: it recycles cached images, or shows the test card when the cache is empty. `-LiminalAllowGeneration YES` overrides this for a deliberate generation test (the cap still applies).
  - `scripts/gen-sample-images.py` generates at most 12 images per run unless `--allow-more` is passed.
- **Alternatives rejected:** a monthly dollar estimate in the app (prices change and the app can't see the bill); counting failed requests (not billed); a hard Google-side quota (the user can set one in the Cloud console, and should if they want a guaranteed ceiling, but the app should be safe on its own).

## D35 (2026-11-15): Latest model (gemini-nano-banana-2.1) as primary, photographic prompt tail, 50/day cap

- **Policy (user):** always use the latest non-deprecated image model. Google's release notes mark `gemini-3.1-flash-image` deprecated and point to `gemini-nano-banana-2.1` as its successor. ListModels on the key (2026-11-15) shows nano-banana-2.1 as the newest image model.
- **Model:** primary is now `gemini-nano-banana-2.1` at 2K (2528x1696, 3:2, verified). The pricing page lists $0.0504 per 2K image, half the old primary's $0.101. Cloud Monitoring shows it also emits roughly as many text ("thinking") output tokens as image tokens per request, a small extra cost the old model mostly didn't have (about 340 text tokens per image on 3.1-flash). The surreal-model split (D2) is retired, since the primary is now the model that melts best; the mechanism stays, with share 0. The fallback is `gemini-3.1-flash-lite-image` at 1K only; the deprecated 3.1-flash and the old 2.5-flash were removed. After that, the cache.
- **Prompting:** three 12-image A/B rounds at 1K on the same seed (seed 4101; about $1.20 total), viewed side by side:
  - r0, the old tail: mostly photographic, but the galaxy ocean, studio product, prism boats and jellyfish read as CGI.
  - r1, a long "full-frame camera ... never a 3D render, illustration ..." clause: more photographic objects, but it diluted other instructions (a person appeared, and the hummingbird lost its reflection concept). Rejected.
  - r2, chosen: "... shot on a real camera rather than rendered: true-to-life textures, natural imperfections, real depth of field, subtle grain." It ships as "Plausible materials and light, a genuine camera photograph: true-to-life textures, natural imperfections, real depth of field, subtle grain.", because the prompt tests ban the word "render" (it can invite render-like output) Every concept kept, no people, product and still-life shots read as photographs.
  - The cosmicDream lead "Photorealistic wide view of an impossible place" became "Real landscape photograph of an impossible place".
  - The tail was trimmed elsewhere ("rich tactile surface texture" overlapped the new clause) to keep every prompt in 110-140 words (400-prompt check).
  - A final 2K check (4 images, seed 777) gave a canyon cistern, a macro bonsai, a bioluminescent tree and an aerial temple; all read as photographs.
- **Cap:** the default daily limit drops from 100 to **50** (about $2.50-3 a day at the new price, well under the user's $5/day ceiling); hourly stays 20.

## D36 (2026-11-21): A second image source, "API": curated collections beside Gemini

- **Request (user, 2026-11-20/21):** a mode that finds imagery online instead of generating it, from approved collections that fit the vibe (psychedelic, old films and old imagery, 1950s-70s, mushrooms, trees, landscapes, retro views and cityscapes, driving), open enough for the film footage to show through, at high resolution, as a toggle like Ambient / Lo-Fi.
- **What:** a segmented "Images: AI | API" picker directly under the Ambient / Lo-Fi picker on both platforms (`ImageSourceControls`, setting `visual.imageSource`, default AI). Switching keeps the picture on screen; the next image change (timer in Ambient, drum boundary in Lo-Fi) shows the new source.
- **Seam:** API mode is a third loop inside `ImageQueue` (`startAPIFeed`) producing the same `DisplayItem`s. Buffer, Lo-Fi reserve, 3:2 crop, saliency, depth, mood and footage are unchanged; `EffectsUniforms`, shaders and the 2048 visionOS render size are untouched.
- **Never Gemini in API mode:** no request, no `GenerationBudget.check()`/`record()`, no prompt history. `requestImage` refuses unless the active source is AI, and a Gemini result that lands after a switch is dropped. The Gemini cap UI and Cache Only are hidden while API is selected. API fetching has its own gate: automation flags block Gemini, never the free public APIs.
- **Fallback ladder:** queued pictures, then the API pool on disk, then the bundled standby art. The AI cache is never shown in API mode.
- **Verified:** across the macOS and visionOS Simulator runs of 2026-11-21 (section D41), 0 `[Gemini]` log lines.

## D37 (2026-11-21): Sources, providers and the rights rule

- **Providers (all keyless):** Library of Congress (collection JSON + IIIF), NASA Image and Video Library, Wikimedia Commons (MediaWiki API), Cleveland Museum of Art Open Access, the Met Open Access. Smithsonian is coded but registered only when `SMITHSONIAN_API_KEY` is in the environment (not in `Secrets.swift`, so existing local `Secrets.swift` files keep compiling), and its source stays disabled until its sizes are measured. Research: `docs/research/image-apis/survey.md`, `collections.md`, `openpics.md`.
- **Sources:** the 12 enabled sources of `Liminal/Visual/ImageSources/image-collections.json`, each with a weight, pinned ids, queries or categories, and a mood block (moods, subject category, energy, warmth) that becomes the picture's synthesized `PromptSpec`, so `VisualMoodBuilder` still sends mood words to the music.
- **Rights:** a picture is kept only when its own record says public domain, CC0, "No known restrictions", or CC BY / CC BY-SA (`ImageRights`): LOC `rights_advisory`, NASA as US Government work, Commons `LicenseShortName` (ported licences such as "CC BY-SA 3.0 de" map to the base licence), Cleveland `share_license_status == CC0`, Met `isPublicDomain` per object (the v1.1 search ignores its own filter). Unknown, empty, NC and ND are rejected. Every picture stores title, creator, date, institution, licence, licence link, page and file URL; the control panel shows it under "Now showing" with a link.
- **OpenPics lesson revisited:** the old LOC "largest/larger/large" resource trick no longer reaches 2K; only items with a IIIF service do, and their full size is read from the search result's `pct:` derivative fragment, so a search hit needs no extra request.
- **CC BY-SA fungi photographs** stay enabled with attribution (plan 13.2). One line in the JSON disables them.

## D38 (2026-11-21): Openness, documents and people at ingest

- `ImageOpenness.score` on a 48x32 thumbnail of the 3:2 window measures shadow and highlight share (the same luma 0.3 / 18% rule as `VideoComposite`), calm cells, edge density, paper share and saturation. `openness = 0.5 x keyBand + 0.5 x min(calm / 0.35, 1)`.
- **Tuning on the 409 probe thumbnails** (scratchpad `imageapi/tune`): the plan's `keyShare > 0.75` reject would have removed the night neon diners, dusk skylines, nebulae and the Golden Gate fog, which are the core of the brief. The shader's `keyGain` already tames a key that covers most of the frame, so a large key only lowers the score (band falls to 0.3 at full coverage). Gates as shipped: openness >= 0.2, key share >= 0.04, document = paper > 0.5 and edge > 0.06, monochrome = mean saturation < 0.025 (0.08 would have rejected the pinned Earthrise and fog pictures, measured 0.03-0.06).
- **Text:** Vision text boxes reject a picture only when they cover more than a quarter of the frame, or more than 6% of a paper-like picture. The first live run rejected a neon sign at 10% under the plain 6% rule, and signs are part of the brief.
- **People (plan 13.1 default):** reject when a face box covers more than 1.5% of the frame or more than four faces are found; distant figures stay. Vision cannot run in the visionOS Simulator ("Could not create inference context"), so the checks are compiled out of simulator builds (D42): the failed setups during live ingest went with 100-320 ms render stalls. They run on Macs and devices; on a Vision Pro they are unverified.
- **Framing:** pictures with an aspect of 1.3-1.8 are stored whole (the renderers' cover crop does the rest); others are cut to the most open of five 3:2 windows along the long axis, so the stored file is already 3:2 and saliency and depth stay registered.
- **Monochrome** (only `cma-early-photographs` may be) is capped at one in six in the display rotation (plan 13.4).

## D39 (2026-11-21): The API pool on disk

- `Application Support/Liminal/CuratedImageStore/`, an `ImageStore` with its own folder, epoch key (`images.api.cacheEpoch`) and no count cap, so neither store's migration can purge the other (unit tested). `ledger.json` beside it records every candidate (stored or rejected with a reason, so nothing is downloaded twice), search cursors, cached search pages and when each picture was last shown.
- **Budget 3 GB** (plan 13.3, about 1,200-2,500 pictures at 1-2.5 MB). Nothing that can play is capped (A31): only past the budget, right after a save, is the least recently shown picture removed, and its ledger entry cleared so it can come back. Ingest pauses with under 1 GB free. Launch cleanup removes only images without sidecars, sidecars without images, names that are not `<UUID>.jpg|json`, and temp downloads older than an hour.
- "Clear images" in API mode ("Clear Curated Pictures") clears this pool and its ledger, never the AI cache.

## D40 (2026-11-21): Resolution and fetching

- Requested long side 2528, the size of Gemini's 2K pictures (`ImageGenerationConfig`), where the server scales (LOC IIIF `full/!2528,2528`, Commons thumbnails, which come back at Commons' 3840 step or as the original when that is smaller), originals from NASA, Cleveland (`images.print`, 3400 px) and the Met. Decoding uses `CGImageSourceCreateThumbnailAtIndex` sized so the 3:2 crop is about 2528 wide (at most 5056 on the long side), so a large master never expands fully in memory. Stored as JPEG quality 0.9.
- **2528, not 3072 (changed 2026-11-21 in the independent verification, D42):** both renderers draw at most 2048 px wide, so 3072 bought nothing on screen. With 3072 pictures, two Lo-Fi perf runs with ingest live failed with 118-324 ms stalls and 45-175 ms frames at reveals; the same pool scaled to 2528 brought reveals back to the AI-cache range.
- **Size gate:** the 3:2 cover crop must be at least 2000 x 1333, 2% under 2048 x 1365. The first live run rejected *Icones Farlowianae* plates at 2026 px; the difference is invisible under the effects. No upscaling is needed for any enabled source. Pool pictures never go through the upscaler (`ImageQueue.makeDisplayItem`): its threshold is a 2048 px long side, so on a visionOS device a 2000-2047 px picture would otherwise have gone through MetalFX at 4x (about 8000 px wide). The macOS RealESRGAN path stretched any input to 512x512, so `ImageUpscaler.shouldSkipUpscale` now also skips non-square pictures on macOS.
- **NASA:** `~large` is only 1920 px (measured 2026-11-21), below the gate, so an original over 12 MB is rejected rather than replaced (one Ames space-colony painting, 29 MB).
- **Pacing:** one HTTPS client (`ImageHTTP`, ephemeral session, generic User-Agent, no Low Data Mode downloads, https only with NASA's http links upgraded), 1 s minimum per host and 5 s for the Met's two hosts, one download every 4 s at most, ingest only while fewer than 12 never-shown pictures wait. A provider error backs that provider off 1 / 2 / 5 / 15 / 30 min; the Met's HTML bot wall (`.blocked`) goes straight to 30 min; 401/403/404/410 on one item rejects only that item.
- **Main-actor rule:** the ledger write for "picture shown" happens on a detached task. Written inline from `showReserved` (main actor, at the Lo-Fi reveal) it cost a 107 ms frame in the simulator perf run with ingest live; ingest also runs at background priority.

## D41 (2026-11-21): Verification

- **macOS live run** (`-LiminalAutoPlay YES -LiminalImageSource api -LiminalImageAPIFresh YES -LiminalImageInterval 8 -archive.enabled YES -LiminalVideoOffline YES`, 5 min, Lo-Fi from the saved setting): 21 pictures stored, 11 rejected, 9 shown from 8 sources; screenshots showed correct 3:2 framing (Highsmith's Maverick Inn neon, a Buller Gorge photochrom, a Laetiporus bracket fungus) with the film showing through.
- **Offline reuse** (`-LiminalImageAPIOffline YES` on that pool, Ambient, 8 s): 18 pictures shown in 2.5 min, ingest off, no network requests.
- **visionOS Simulator** (`-LiminalOpenDome YES`, Ambient, fresh pool, 4.5 min): 33 stored, 2 rejected, 29 shown from 11 sources; the control window shows the credit ("Sudden Shower over Shin-Ōhashi Bridge ... Utagawa Hiroshige, 1857 · Cleveland Museum of Art · CC0").
- **Lo-Fi perf** (`scripts/perf-run.sh --lofi`, 60 s): plain AI-cache run passes (max frame 33 ms); API with ingest live passes twice after D40's main-actor fix (max 74 and 57 ms, fps 79); API offline passes (max 52 ms).
- **Across all runs:** 95 pictures stored from 12 sources (licences: Public domain 50, CC0 21, No known restrictions 12, CC BY-SA 11, CC BY 1), 14 rejected (title rules 4, small plates 5, text 2, monochrome 1, NASA original over 12 MB 1, small Met print 1), 0 Gemini log lines.
- **Not done:** the AI -> API toggle was not clicked in the live app (the Mac's screen was locked, so Peekaboo clicks landed on the login window); `switchSource` API -> AI -> API is covered by `ImageQueueAPIModeTests` instead. Nothing was installed on the Vision Pro.

## D42 (2026-11-21): Independent verification and fixes

Re-checked by a second pass on branch `image-api-mode`: builds (macOS, visionOS Simulator), the image suites (84 tests), a live macOS run, simulator Lo-Fi perf runs, and the source switch.

- **macOS live run** (Lo-Fi, archive footage, fresh pool, 4.4 min, `-LiminalImageSourceFlipAt 165,210`): 19 stored from 12 sources, 1 rejected (monochrome), 7 shown from 7 sources before the switch, each with its credit line in the log. The flip to AI stopped ingest and the API loop, started the AI cache recycler (`cacheOnly=true, cached=38`), and the next reveal showed a cached AI picture; the flip back restarted the API feed and the next reveal showed a pool picture (Hokusai). The picker and status line follow the source in the screenshots. No Gemini request in the log (the only Gemini line is the credentials check of the AI status row).
- **Fixes:**
  - The picker's switches ran as unordered detached tasks: a quick AI -> API -> AI could finish on API while the picker showed AI, or interleave inside `switchSource` and start two loops. `VisualEngine.setImageSource` now chains each switch after the previous one.
  - The Lo-Fi prefetch and reveal checked the AI cache's clear generation even in API mode, so a picture staged before "Clear Curated Pictures" or before a source switch could still be revealed. They now check the store the picture came from and that it is still the active one.
  - Target size 3072 -> 2528 and no upscaling of pool pictures (D40); Vision compiled out of simulator builds (D38).
- **Simulator Lo-Fi perf** (`perf-run.sh --lofi --seconds 120`, host under load from other apps). An offline API run (pool only, no ingest) passed like the AI baseline, which isolated the stalls to live ingest:

| Run | Result | Max frame | Frames over 40 ms (whole run) |
|---|---|---|---|
| AI cache baseline (two runs) | pass, pass | 53, 53 ms | 3, 4 |
| API, fresh pool, ingest live, 3072 | fail | 118 ms (first reveal) | 6 |
| API, warm pool, ingest live, 3072 | fail | 325 ms | 9 |
| API, same pool scaled to 2528, ingest live | pass | 90 ms | 7 |
| API, 2528 target, ingest live | fail | 182 ms | 12 |
| API, pool only (`-LiminalImageAPIOffline YES`) | pass | 59 ms | 3 |
| API, 2528 + no Vision in the simulator, ingest live (two runs) | pass, pass | 59, 46 ms | 3, 1 |

- **Debug flag added:** `-LiminalImageSourceFlipAt <s[,s]>` flips the Images picker at those times through the settings binding and puts the stored setting back, so the switch can be checked when the screen is locked.
- **Vibe check** (contact sheet of the 54 distinct pictures the verification runs stored and showed, scratchpad `share/imgapi/displayed.jpg`): the 1950s-70s brief is well served (DOCUMERICA highway traffic at dusk, sunsets and refineries; Highsmith neon diners, motels, drive-ins, an Edsel grille and Havana Chevrolets; Gemini and Apollo Earth views), as are trees and landscapes (redwoods, Monument Valley, desert highway, photochroms) and mushrooms (fly agaric, shelf fungi). Japanese woodblock prints were 10 of 54 (Cleveland weight 2 plus the Met), more than the brief asks for, and psychedelic colour came only from nebulae and Haeckel. Changes: Cleveland's ukiyo-e weight 2 -> 1, and a new `landsat-earth-as-art` source (weight 1, eight pinned USGS/NASA false-colour Landsat scenes on Commons, public domain or CC BY 2.0). A macOS run restricted to it stored 7 of the 8 at 2528 px (one MSS scene rejected for too little film key, 0.04) and showed them with their credits.
- **Still weak:** paper margins on some plates and prints (Haeckel, *Icones Farlowianae*, a Hiroshige mat, a 1975 Ames painting with a white border) and the Met's mostly blank Fuji scrolls; NASA titles that are just the item id; long Commons creator lines (Malaspina: "Image provided by the USGS EROS Data Center ..."). True 1960s psychedelic poster art was not added: the LOC rock posters are 1024 px or less with unevaluated rights, and Commons' *Psychedelic art* category is mostly modern CC BY-SA snapshots.

## D43 (2026-11-21): Code review fixes

A review of the whole `image-api-mode` branch found these and fixed them (unit tests in `ImageAPIModeTests`):

- **Attribution:** a CC BY or CC BY-SA picture whose record names no creator is now rejected ("CC BY-SA 3.0 without a creator to credit"). The credit line could not have met the licence's attribution term. Public domain, CC0 and "No known restrictions" pictures still need only a title.
- **Ledger writes in order:** the ingest task and the detached "picture shown" task both wrote `ledger.json`, each from a snapshot taken under the lock and written after the lock was released, so an older snapshot could land last. A lost candidate record would let the same item be downloaded again after a relaunch. Each change now carries a version, and a writer lock skips any snapshot older than the one on disk.
- **Clear while fetching:** a picture whose download began before "Clear Curated Pictures" was saved afterwards, because the clear generation was read at save time. Ingest now reads it before resolving the candidate, so that picture is refused. The clear also holds the writer lock, so a ledger write that is already under way cannot bring the old file back.
- **Dropped reservations:** a picture picked for display but never shown, such as a Lo-Fi stage that missed its reveal, stayed reserved until the next Stop or source switch, which could starve a small pool. Reservations now expire after 10 minutes.
- **Cancellation is not a provider failure:** stopping ingest (source switch, Stop, Clear) during a search used to put that provider into a 1-minute backoff. `CancellationError` and `URLError.cancelled` are now ignored.
- **Decode bound:** files whose header declares more than 150 megapixels, or no size at all, are rejected before decoding. A 12 MB PNG can declare a canvas that ImageIO would decode in full.

Left as they are, with the reasons:

- **Size limit enforced after download:** the download is checked against 12 MB after it completes. Providers that declare a size (Commons originals, Cleveland, NASA's HEAD) are gated before downloading, and the 180 s resource timeout bounds the rest. A streaming cap would need a delegate-based download.
- **3 GB pool budget:** this is the plan's default (plan 13.3) and is still for the user to decide against A31.
- **NASA rights:** NASA rights are taken as US Government work for every item. A few NASA library items are third-party works; the title-reject words remain the guard.

## D44 (2026-11-21): FSA/OWI colour from the Library of Congress masters

The user remembered high-resolution FSA photographs from OpenPics and asked whether the OpenPics trick had been tried. It had not been followed far enough: the research (D40, `research/image-apis/collections.md`) rejected FSA/OWI colour, photochroms and Prokudin-Gorskii as 1024 px only because their IIIF `service:` derivatives stop there and the guessed master ids used the wrong prefix.

- **Masters.** `LOCProvider.masterIIIF` turns a result's 1024 px `v.jpg` url into the IIIF service of its scanned master (`.../iiif/master:pnp:<path>u`). A source opts in with `useMasters`. The size comes from `info.json`; an item with no master fails that request and is rejected on its own. All 40 sampled FSA colour items had masters of 4641-7738 px. The Highsmith sources also set `useMasters`, which adds the newer Highsmith items that have only a `v.jpg` (for example 7313x4696).
- **Fallback.** About half of the FSA masters return HTTP 500 for every scaled request but serve `full/full` (1-5 MB). `ResolvedImage.fallbackURL` is tried once on a 5xx; the 12 MB limit and the 150 megapixel decode limit still apply.
- **Film rebate.** `ScanEdgeTrimmer` (opt-in `trimScanEdges`) removes the black edges, edge codes, rounded corners and tinted film base that the slide scans include, before `BorderTrimmer`, the openness window and the gates. Because the trim removes 6-30% of the width, these sources are fetched and decoded at 1.35x the target (`scanFetchTarget`, 3413 px) and scaled back to the usual size after the trim; at 2528 px, 6 of 36 FSA pictures fell just under the 2000 px gate after trimming.
- **Source.** `loc-fsa-owi-color`, weight 2, queries landscape, road, highway, main street, town, trees, farm, railroad, sky and night; colour only (`allowMonochrome` false). The same masters route would also work for photochroms (now from Wikimedia) and Prokudin-Gorskii; neither was added.
- **Verified.** API-mode suites 52 passed (new `ImageProviderParsingTests.locMastersStandInForTheMissingIIIFDerivative`, `ScanEdgeTrimmerTests`). A live macOS run limited to the source (`-LiminalImageProvider loc-fsa-owi-color -LiminalImageAPIFresh YES`) stored and showed FSA pictures at 2528 px with no Gemini requests; before the fallback, the 5xx masters put the whole LoC provider into one-minute backoffs. A second 5-minute run with the trimmer stored 20 FSA pictures (2209-2378 px wide after the trim) and rejected 9: 6 just under the size gate (fixed by the larger fetch above), one 32% text, one with no room for the film.

## D45 (2026-11-21): A wider rotation: 31 more sources and two new providers

The user asked for "as many as you can so the total is much more varied", with the high-resolution route worked out for collections that had been skipped. Two research passes ran in parallel: everything outside the Library of Congress ([other-institutions.md](../research/image-apis/other-institutions.md), [new-providers.md](../research/image-apis/new-providers.md)) and the Library of Congress ([loc-collections.md](../research/image-apis/loc-collections.md)). The rotation went from 14 sources and 5 providers to 44 sources (43 enabled, total weight 60) and 7 providers.

- **New providers.** `DigitalCommonwealthProvider` (`dc`): Boston Public Library's Tichnor Brothers linen postcards (1930-45 motels, highways, moonlit main streets), keyless Blacklight JSON plus IIIF at about 3300 px, kept only when `reuse_allowed_ssi` is "no restrictions". `ArticProvider` (`aic`): Art Institute of Chicago public-domain works through an Elasticsearch bool query (title match plus `is_public_domain`), images from `full/3000,` (the server serves only fixed widths; 2528, `full`, `max` and `!w,h` return 403), 2 s host gap for its 60-a-minute limit.
- **Outside the LoC, 17 sources** on the existing providers: DOCUMERICA landscapes and smog-and-neon, aurora and Milky Way, Hubble and Webb galaxies, featured forests, the Project Apollo Archive, Bierstadt and Moran, six pinned 1910-30 shin-hanga prints (Commons labels post-1930 Hasui and Yoshida prints "Public domain" though they are likely still under US copyright, so their categories are not used), NASA orbital Earth 1961-74, lunar orbit, aurora from orbit and Cape Kennedy aerials, Cleveland American landscape paintings and weather prints, the Met's American Tonalists (American Wing paintings have an empty classification, so the source allows `""`), early photographs and Hiroshige night prints.
- **Library of Congress, 10 sources** through the scanned-master route (D44), which works across Prints & Photographs: Margolies Roadside America (1976-95 Kodachrome, the best roadside match; masters 5000-5330 px), photochrom, Prokudin-Gorskii, Detroit Publishing, Japanese prints, Gottscho-Schleisner 1939 fireworks, FSA/OWI black-and-white, popular graphic arts, Highsmith space and fairs, and Matson. Each query was checked to return results on 2026-11-21.
- **Code.** `CuratedSource.partof` searches `/photos/` with a `partof:` facet for collections that are not `/collections/` slugs (Margolies, Matson). `edgeInset` cuts a fixed share of each side after the scan trim, for Prokudin-Gorskii's coloured plate-misregistration bands.
- **Monochrome.** Allowed where it is the subject (early photographs, the lunar surface, 1960s aerials, Detroit glass negatives, FSA/OWI black-and-white, Matson), all at weight 1; display still shows at most one monochrome picture in six.
- **Known losses, accepted.** About 30% of FSA/OWI black-and-white 4x5 masters exceed the 12 MB limit (only `full/full` works for them, at 10.6-18.1 MB). Popular graphic arts captions and vertical Margolies frames rely on the existing gates and crop.
- **Rejected on rights:** Look, Horydczak, Matson lantern slides, the Bill Graham/Avalon posters, NYWT&S, HABS/HAER, NYPL, NARA, Smithsonian (key). **On fit or size:** WPA posters, Genthe, panoramas, stereographs, the Cabinet of American Illustration.
- **Verified.** API-mode suites pass with new parser tests for both providers and the `partof` URL. A live macOS run limited to the new providers and six new sources stored 23 pictures (Tichnor postcards, AIC landscapes, aurora, DOCUMERICA neon, Skylab and Gemini Earth, Tonalist paintings) with no Gemini requests; a three-loop session showed AIC, Commons and NASA pictures from this batch. A 200 s live run limited to the ten LoC sources stored 18 pictures from nine of them (Margolies 5, photochrom 2, Prokudin-Gorskii 2, FSA/OWI B&W 2, popular graphic arts 2, Matson, Japanese prints, Gottscho fireworks, Highsmith space and fairs; all at 2088-2799 px after the trim) and rejected two (a Margolies sign with no room for the film, a 1695 px Detroit scan), with no Gemini requests. The full unit suite passed except the two private drum-take checks that depend on the locally installed Slow Burn loops (unrelated). macOS, visionOS Simulator and visionOS device Release builds succeed.

## D46 (2026-11-21): Recording from the renderer, saved to Photos

The user asked for an in-app record control that saves to Photos, works on Vision Pro, has "absolutely no dropped frames" and the best audio possible. A ScreenCaptureKit window recording tried first for a preview clip was jumpy and was dropped.

- **From the renderer, not the screen.** Each frame is copied on the GPU, in its own command buffer, into an IOSurface pixel buffer from the recorder's pool, and appended to a hardware HEVC track when the command buffer completes. Nothing waits on the GPU; the render thread encodes one small pass. On visionOS the 2048² shell texture is scaled back to 3:2 (2048x1366); the headset view itself (passthrough, room) cannot be recorded by an app, so Record My View in Control Center stays the way to capture that.
- **Even timing.** (Superseded by D47: frames are placed by their own presentation time, nearest frame per 60 Hz slot, so a render rate above 60 Hz no longer stretches the picture.)
- **Audio.** Lossless 24-bit LPCM at the engine rate from a unity mixer after the master chain (`recordTap`). Not `mainMixerNode`: touching it while running made AVAudioEngine try to connect one and abort (crash seen in the simulator, 2026-11-21). The tap only fills a lock-free ring; the writer queue builds sample buffers.
- **Setup off the main actor.** The writer, encoder and copy pipeline took about 0.4 s on the Mac's main thread (which draws the frames) and caused a 427 ms frame gap; building them on a detached task removed it.
- **Measured.** macOS 60 s (before the timing fix): 3588 frames, 59.92 fps, 0 dropped by the recorder, 3 intervals over 25 ms (app main-thread stalls, also present without recording). Simulator: functional only (software HEVC). Photos save checked in the simulator. The first device movie showed the timing defects of D47; fixed-build device numbers are pending.

## D47 (2026-11-21): One movie clock for the recording

The user played a Vision Pro recording back and the sound was "quite a bit out of sync" with the picture: the drop cuts no longer landed on the drum downbeat, although they had live. Measured from the device movie (`scripts/av-sync-check.py --legacy`, docs/recording.md):

- **Video stretched.** 9189 frames, every pts step exactly 1/60 s (153.15 s). The visionOS render loop is sleep-paced towards 90 Hz and ran at about 81.6 fps (2276, 2266 and 2275 frames between cuts that are 32 beats, 27.83 s, apart; 9188 frames over the real 113.0 s gives 81.3 fps). D46's rule "two frames in one slot take consecutive slots" gave every frame its own slot, so the picture ran 1.36x slower than real time.
- **Audio closed up after an overrun.** The audio media was 1230 whole 4800-frame tap buffers with an edit list skipping 12.113 s: the first frame reached the recorder 12.1 s after the tap started (cause not established; a first-run Photos prompt requested at that moment is the likely one). The drain waited for that frame, the 10 s ring filled, and whole buffers were dropped until it came. A hard splice sits at exactly media sample 480,000 (the ring's capacity; prediction-error ratio 126, against 1.9 median and 5.6 at the 99th percentile at other buffer joins); the beat phase jumps across it by 0.373 s mod one beat, which with the 2.113 s mechanical minimum gives a gap of 2.11 s. Audio was stamped by sample count, so everything after the splice was 2.11 s early.
- **Together** the picture was late by 7.2, 17.3, 27.3 and 37.4 s at the four cuts: offset = 2.76 s + 0.360 x t, residuals within 51 ms. The last 42 s had no sound.

Fix (`Liminal/Recording/RecordingTiming.swift`, `FrameRecorder`):

- **One clock.** Movie time 0 is the first frame's presentation time on the uptime clock (the transport's and the drop cuts'). Slot k is at k/60 s, sample n at n/rate s; both tracks start at 0 with no edit list and end at the end of the last slot (audio trimmed or padded).
- **Nearest frame per slot** (`FrameSlotter`). Each frame goes to the slot nearest its presentation time; the nearer of two wins; an empty slot repeats the previous frame; a late frame is dropped. A hysteresis of a quarter slot, only for sources near 60 Hz, keeps a phase on a slot boundary from alternating drop and repeat. visionOS frames carry the display time the loop expects, sampled with their drop state (the display lead minus its half-frame early bias, `renderAndPresent(presentationTime:)`), macOS frames the draw uptime plus the measured present latency, so a recorded cut sits where it was shown.
- **Audio placed by when it is heard** (`AudioTimeline`). The tap stores each buffer with its host and sample time (one `Mark` per buffer, written after the audio; a buffer that does not fit is dropped with its mark). Contiguous buffers follow sample for sample; a sample-time gap becomes exactly that much silence; a sample-clock break (an engine restart) is placed again by host time; audio before T0 is skipped. Latency is the tapped node's `outputPresentationLatency` (the same mapping the transport uses, `player.outputPresentationLatency`), refreshed after a route recovery. The device's audio clock is followed against the host clock (`driftSeconds`) and subtracted from video times.
- **No overrun while waiting for video.** The ring is drained every 20 ms from the start; the last 2 s before the first frame are kept. Photos access is asked before the first recording, not during it.
- **Checked.** `LiminalTests/RecordingTimingTests` (18 tests, 21 cases): render streams at 60, 83, 90 and 120 Hz with ±2 ms jitter for 10 minutes give consecutive slots, each within half a slot of its frame, span equal to real span within a frame; the device stream (9189 frames at 81.3 fps) gives 113.0 s, not 153 s; overruns, restarts, pre-roll, a late first buffer, ±1 ms host jitter and a 100 ppm device clock. `tools/TapTimingCheck.swift`: on macOS, tap host time + index / rate equals the `play(at:)` host time within half a sample. Simulator, Lo-Fi, 90 s at 768x512 H.264 (render 77 fps): constant 60 fps, tracks equal to the sample, no splice, drop cuts +12.1, +2.8 and -6.5 ms from their logged downbeats; 150 s with footage and dialogue, every tap buffer traced: 1498 buffers contiguous, five cuts -5.6 to +9.0 ms. macOS 90 s and 150 s: 5393 and 8992 frames from 59.9 fps rendering, 0 dropped, drift -0.49 and -0.80 ms (about 5 ppm, the output's real rate against the host clock). `scripts/av-sync-check.py --legacy` on the device movie reproduces the diagnosis above (81.6 fps from cut spacing, 2.11 s gap, the same four offsets).
- **Re-checked, three fixes (2026-11-21).** An independent verification confirmed the before numbers (audio media exactly 1230 tap buffers, 123.0 s; real span after the first frame 113.0 s, 81.3 fps) and fixed three things: the tap now stays on after Stop (up to 0.6 s) until the audio reaches the last slot's end, so movies no longer end in 70-100 ms of padded silence; the near-60 Hz hysteresis is limited to a mean step within 10% of a slot, with each step clamped to 1.75 slots, because a single hiccup in a 78-82 fps stream had switched it on and moved frames up to 12.4 ms (now at most 8.3 ms above 66 Hz); and `scripts/av-sync-check.py --log` matches each downbeat to the settled one-frame change within 100 ms, instead of a heavy drop build's flash frame 279 ms early. `RecordingTimingAdversarialTests` adds 10 cases (the hiccup case fails on the previous slotter). Simulator 150 s with footage and dialogue: 0 silence frames, max slot error 8.3 ms, five cuts -0.9 to +13.8 ms, each within one slot of the offset the app logged live; macOS 90 s: 0 silence frames, 0 discontinuities.
- **Not verified.** The fixed build's movie on the device, the tap's host-time semantics on visionOS hardware (same API, checked on macOS), and the 28 ms visionOS display lead (shared with the live cut, so the movie matches what the app intends). With footage and dialogue on, the simulator's rendered mix twice held exact-zero runs (69 and 12 ms in 150 s) inside contiguous tap buffers: zeros the engine rendered, not audio the recorder lost; macOS had none in the same 150 s. Its cause is not investigated here.

## D48 (2026-11-21): No repeats in API mode while new pictures exist

The user saw the same API picture twice and asked how often they repeat, expecting never with 43 sources. They repeated often, and more the longer the app was used.

- **Cause: the display weight let shown pictures compete with new ones.** `ImageRotation.nextDisplay` weighted a never-shown picture x 3, and a shown one at 0 for 24 displays, then rising to 1 over the next 24. Ingest stopped once 12 new pictures waited (`unseenAhead`). So after about 48 displays every old picture competed at weight 1 with 12 new ones at weight 3, and the share of repeats grew with the pool. A port of the old rule over consecutive one-hour Lo-Fi sessions (128 pictures at 28 s, ingest keeping 12 new pictures waiting, 20 seeds): **33% of pictures shown were repeats in the first session, 68% in the second, 78%, 82%, 84%, 85% by the sixth**; for two-hour sessions 51%, 80%, ... 89%. Because repeats used up fewer new pictures, ingest fetched less and the pool grew slowly (230 pictures after six hours instead of 779).
- **Not the cause: supply.** A live macOS run with a fresh verify pool (2026-11-21) stored 16 pictures in 100 s (one every 6 s) and then idled at the 12-picture limit; Lo-Fi shows one every 28 s, so ingest is four to five times faster than display. Search cursors already persist per query in the ledger and walk every page; the reachable set is large ("Reachable" below). Host pacing (1 s, Met 5 s, AIC 2 s) does not starve ingest.
- **Other repeat paths found.** (1) The launch frame was `pool.items.randomElement()`, any stored picture, often a recent one. (2) `markShown` released the reservation before recording the picture as shown, so a pick in that window could take the picture on screen as new. (3) The same picture under two ids: Commons holds copies of LoC scans (titles ending `LCCN<n>`, for example the photochroms that `loc-photochrom` and `photochrom-landscapes` both reach), of NASA frames (`AS08-14-2383`, also in `nasa-space-age` and `apollo-archive`), and DOCUMERICA prints uploaded twice under different titles with the same NARA number. The ledger key `provider:itemID` could not see these. Two museums' impressions of the same Hiroshige print are a further case no id links.
- **Fix.**
  - **New pictures first** (`ImageRotation.nextDisplay`): while any never-shown picture is a candidate, only never-shown pictures are drawn (weight source weight x (0.5 + openness)); the source-alternation and monochrome rules choose within that set and give way rather than admit a shown picture. With nothing new (offline, every provider in backoff), the pick is from the least recently shown quarter (`reshowShare` 0.25) and never within `recencyWindow` (24) when anything older exists, so an offline pool of n cycles with no picture back sooner than about 3n/4 displays. The x 3 `unseenBoost` is gone.
  - **First frame** is the rotation's pick (`anyPicture` calls `nextDisplay`).
  - **`markShown`** records the picture as shown in memory before releasing its reservation (and releases it before the ledger file is written, so a slow write cannot hold it back), and a launch frame that loses to another picture is released at once instead of after 600 s.
  - **`unseenAhead` 12 -> 36**: about 17 minutes of Lo-Fi with no network (a Vision Pro waking without Wi-Fi, a provider wall), at about 1.5 MB each (54 MB). Ingest pacing is unchanged; this changes how far ahead it works, not how fast.
  - **Catalogue aliases** (`ImageIdentity`): LCCNs, NARA numbers, NASA frame and PIA/GPN ids and normalised Commons titles, read from the item id before any download. A candidate whose alias belongs to a stored picture is skipped like a seen key. Aliases of rejected candidates are not recorded.
  - **Perceptual fingerprint** (`ImageFingerprint`): 64-bit row and column difference hashes of a 9 x 9 grey thumbnail and a 3 x 3 colour thumbnail of the stored 3:2 picture. Within 8 bits on both hashes and a mean colour difference of 24 levels, a new picture is rejected as `duplicate of <key>`. The ingest task backfills fingerprints for an older pool from its JPEGs (288 px decode) and removes the later copy of a picture stored twice; its candidate is recorded as a duplicate and the kept copy takes the later "last shown". Removing an exact second copy is junk cleanup, not a cap (A31): no picture that can play is lost.
  - `CuratedLedger` gained `aliases` and `fingerprints` and now decodes every field optionally, so an older ledger keeps its shown history.
- **Kept.** The 3 GB budget and its least-recently-shown eviction (A31): an evicted picture can still return after its search restarts (`candidateRefreshDays`, 7). At about 1.2-2.5 MB a picture that is roughly 1,200-2,500 pictures, 9-19 hours of Lo-Fi, before the first eviction.
- **Reachable.** One count request per search of every enabled source (2026-11-21, paced; 23 LoC requests timed out and 17 Commons requests were refused with 429, so this is a floor): 46,960 search results plus the pins, before overlaps and the rights, size and openness gates. Large ones: Commons DOCUMERICA western landscapes 10,240, Tichnor postcards 7,795, the Met landscapes 5,171, LoC Detroit 4,470, AIC 2,397, LoC FSA/OWI B&W 2,317, DOCUMERICA 2,199, Margolies 2,158, FSA/OWI colour 2,140; small ones are pinned-only (Landsat 8, shin-hanga 6) or narrow (Gottscho fireworks 25, Met Hiroshige night 22). The two live runs rejected 3 of 44 candidates; even at half kept that is over 20,000 pictures, more than 150 hours of Lo-Fi at 28 s each, so no weighted source runs dry in a session. Cursors persist per search in the ledger, so each session continues where the last stopped.
- **Real pictures.** The fingerprint separates the 17 pictures a live run stored (136 pairs: closest 34 of 128 bits, median 59; threshold 8 + 8) and matches each to a 200 px copy of itself; the LoC photochrom 2017658073 and its Commons copy "In Buller Gorge I LCCN2017658073" (which a live run stored from `photochrom-landscapes`) differ by 1 bit, and share the alias `~lccn:2017658073`.
- **Expected repeats after the fix.** The same port with the new rule: 0% in every session, online. Offline, repeats begin only after the pool's never-shown pictures run out (36 or more), then at most once per about 3n/4 displays.
- **Checked.** `LiminalTests/ImageRepeatTests.swift` (5 suites, 19 tests): a shown picture never beats a new one even against the source and monochrome rules; offline cycles keep 30 displays between returns in a pool of 40; a two-hour session over a pool of 300 shown pictures with ingest shows no repeat; LCCN, NASA frame, NARA and Commons-title aliases match across providers and unrelated ids share none; fingerprints match across size, JPEG quality and a 1% shift, and not across 58 other patterns, two dark gradients or a red and a teal blob on black; pool aliases and fingerprints survive a reload, leave with eviction, and the backfill removes the later copy; an old ledger decodes with its history; the first frame is a new picture; six picks with `markShown` between give six pictures. The existing API suites pass (72 tests with the new ones); `monochromeCapHolds` now uses a pool where new colour pictures remain, since a new monochrome now wins over a repeat. macOS and visionOS Simulator builds succeed.
