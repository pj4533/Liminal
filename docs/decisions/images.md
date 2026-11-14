# Image pipeline decisions

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
