# Image generation plan (feature/images)

Status: design, not yet implemented. Baseline is in `docs/plans/images-current.md`, model evaluation in `docs/research/image-models.md`, decisions in `docs/decisions/images.md`.

Goal: varied, colorful, photoreal-but-surreal images of things you can recognize, in several distinct styles, on a better model, with one button that removes every old image.

## 0. What I checked before designing

- Looked at all 15 model-eval images. Agree with the evaluation: `gemini-3.1-flash-image` is the most photographic; `gemini-2.5-flash-image` (current) looks rendered; only `gemini-nano-banana-2.1` really "melted" the carousel.
- Generated 4 new images with the prompt grammar in section 5 on `gemini-3.1-flash-image` at 3:2 (grand piano overgrown with coral on a salt flat in infrared; rotary phone made of citrus; greenhouse of sunflowers on the seabed). All four were photoreal, immediately recognizable, and looked nothing like each other. Files: scratchpad `images-eval/design/` (`t1.jpg`, `a.jpg`, `b.jpg`, `c.jpg`, `sheet.jpg`).
- Two findings from those four images that shape the design:
  1. Film-stock wording plus a negative list ("Kodak Aerochrome film, medium format ... no border, no frame") produced a white film-scan border. Rewording to "in the look of Aerochrome film" plus a positive "the scene fills the entire image edge to edge" removed it. So: no negative lists, and no "film scan / medium format film" wording.
  2. "No lettering" does not remove text that belongs to the object (the phone dial had numerals). So subjects that carry text are tagged and get "blank and unmarked" wording, or are left out.
- Two existing problems found while reading the code that this work must fix because the new model makes them worse:
  1. The generation loop is not paced. `startContinuousGeneration` generates, sleeps 2s, generates again, while images are consumed once per 30s. The visionOS pending queue (`AtomicImageBuffer._pendingQueue`) has no cap. That is unbounded memory and roughly 3x the API spend actually displayed.
  2. visionOS decodes every cached image into memory at startup (`loadAllRawAsCGImages`) and again in the recycler. At 2528x1696 that is 17 MB per image.

## 1. Model and request

| Item | Choice |
|---|---|
| Primary model | `gemini-3.1-flash-image` |
| Surreal variant | `gemini-nano-banana-2.1`, used for half of the prompts whose transformation is tagged `needsStrongSurreal` (melt, unravel, shatter). About 10% of images. |
| Fallback chain on errors | `gemini-3.1-flash-lite-image`, then `gemini-2.5-flash-image` |
| Aspect ratio | `3:2` |
| Size | `2K` (verified today: 2528x1696 JPEG, 15.5s). `1K` gives 1264x848. |
| Modalities | `["IMAGE"]` |
| Auth | `x-goog-api-key` header (key leaves the URL) |

Why 3:2: the dome panel is 110 by 75 degrees, 1.47:1. `OffscreenEffectsRenderer.updateSourceTexture` stretches any source into its 2048x2048 texture, and the panel stretches that back out to 1.47:1. A 3:2 image (1.5:1) therefore displays with about 2% distortion and needs no renderer change. 16:9 would be squeezed 17%; the current square is stretched 47%.

Why 2K: at 1K the 848-pixel height is stretched to 2048 rows. At 2K the image already exceeds the renderer texture, so the upscalers are skipped entirely (MetalFX 4x on a 2K image would be 10112 px wide; RealESRGAN squashes to 512 first and destroys detail).

Upscale policy (`ImageUpscaler`, both platforms): if the long side is at least 2048, return the image unchanged. Otherwise the existing path runs. This keeps the fallback models (1K) working.

macOS: the visual area is forced square by `SquareVisualWindowDelegate` in `ContentView.swift`. Change the constraint to 3:2 (`visualAspect: CGFloat = 1.5`). If the macOS renderer turns out to assume a square drawable, fall back to center-cropping to square in the macOS branch of `ImageQueue`. This needs a check with the renderer workstream.

### Files and types

`Liminal/Visual/ImageGenerationConfig.swift` (new)
```swift
struct ImageGenerationConfig: Sendable {
    var primaryModel = "gemini-3.1-flash-image"
    var surrealModel = "gemini-nano-banana-2.1"
    var surrealModelShare = 0.5            // of prompts tagged needsStrongSurreal
    var fallbackModels = ["gemini-3.1-flash-lite-image", "gemini-2.5-flash-image"]
    var aspectRatio = "3:2"
    var imageSize = "2K"                   // fallback models are sent "1K"
    var requestTimeout: TimeInterval = 60
    var targetPendingCount = 2             // backpressure, see section 7
    static let standard = ImageGenerationConfig()
}
```

`Liminal/Visual/GeminiClient.swift` (changed). One method replaces the two near-duplicates.
```swift
struct GeneratedImageData: Sendable {
    let data: Data          // bytes exactly as returned
    let mimeType: String    // "image/jpeg" in practice
    let cgImage: CGImage    // decoded with CGImageSource, no UIImage/NSImage
    let model: String
    let latency: TimeInterval
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)   // 429 and 5xx are retryable
    case noImage(finishReason: String?)       // safety block or empty response
    case decodeFailed
    case network(Error)
    var isQuotaOrServer: Bool { get }         // 429, 500, 503, 404 (model gone)
}

func generate(prompt: String, model: String, aspectRatio: String, imageSize: String) async throws -> GeneratedImageData
```
Request body adds `generationConfig.imageConfig { aspectRatio, imageSize }`. macOS wraps `cgImage` in a `PlatformImage` at the call site.

`Liminal/Visual/ModelRouter.swift` (new, pure, unit-testable)
```swift
struct ModelRouter {
    init(config: ImageGenerationConfig)
    mutating func model<R: RandomNumberGenerator>(for spec: PromptSpec, using rng: inout R) -> String
    mutating func recordSuccess(model: String)
    mutating func recordFailure(model: String, error: GeminiError, now: Date)
    func delayBeforeNextAttempt(now: Date) -> TimeInterval
}
```
Rules:
- `noImage` (safety block): keep the model, draw a new prompt, retry at once. After 3 in a row, wait 10s.
- 429, 5xx, 404, timeout: put that model on cooldown (30s, doubling to a 10 min cap) and use the next model in the chain. Retry the primary when its cooldown ends.
- Every model on cooldown: the queue switches to recycling cached images until one is available. The display never stalls.
- 400 with an `imageConfig` complaint on a fallback model: retry once without `imageSize`.

## 2. Styles (16)

Each style is data in `PromptLibrary`. Fields: `id`, `family`, `weight`, `lead` (opening words), `camera`, `lighting`, `texture`, `categories` it accepts, `scales` it accepts, `paletteRule`, `moods`, `energy`.

Photographic, 78% of images:

| id | weight | lead | camera | lighting | texture cues |
|---|---|---|---|---|---|
| `macro` | 8 | Extreme macro photograph | 100mm macro lens, f/8, focus-stacked | ring flash softened by diffusion, background falling to dark | pores, scales, dew beads, pollen grains, fine fibres |
| `cineStill` | 7 | Cinematic film still | 40mm anamorphic lens, shallow depth of field, oval bokeh | motivated practical lights, thin haze, soft halation around highlights | fine grain, wet reflective ground, atmospheric depth |
| `aerochrome` | 6 | Color infrared landscape photograph in the look of Aerochrome film | 50mm lens, deep focus | hard late-afternoon sun, long crisp shadows | fine grain, foliage glowing crimson and pink |
| `longExposure` | 6 | Long-exposure night photograph | 24mm lens, f/11, thirty-second exposure on a tripod | ambient twilight plus moving light sources | light trails, silk-smooth water, star streaks, razor-sharp static subject |
| `underwater` | 6 | Underwater wide-angle photograph | 16mm lens behind a dome port | shafts of sunlight from the surface | suspended particles, caustic ripples, bubbles |
| `doubleExposure` | 5 | In-camera double exposure photograph | 85mm lens | bright clean backdrop behind a dark silhouette | the silhouette of the subject filled with a second scene, soft blended edges |
| `tiltShift` | 5 | Tilt-shift photograph from a high vantage that makes the scene look like a miniature model | 90mm tilt-shift lens | bright midday sun, saturated color | tiny crisp details in a narrow band of focus, creamy blur above and below |
| `biolumNight` | 6 | Night photograph lit only by bioluminescence | 35mm lens, f/1.4 | the glow is the only light source, surroundings near black | wet surfaces, glowing veins and spores, light spilling onto nearby objects |
| `studioProduct` | 8 | High-end studio product photograph | 100mm lens, f/11, focus-stacked | softbox key light with a hard rim light, seamless backdrop | glossy highlights, beads of moisture, immaculate surfaces |
| `aerial` | 6 | Top-down drone photograph | 24mm lens pointing straight down, f/8 | low sun, long graphic shadows | repeated shapes, ridges, furrows, strong pattern |
| `grandLandscape` | 6 | Large-format landscape photograph | 90mm view-camera lens, f/22, everything in focus | golden hour or blue hour, fog in layers | rock strata, water, cloud detail from foreground to horizon |
| `flashNight` | 5 | Direct on-camera flash photograph at night | 28mm lens, hard flash | subject brightly lit against a black background | saturated color, sharp specular highlights, hard shadow directly behind |
| `prism` | 4 | Photograph shot through a glass prism held against the lens | 50mm lens, f/2 | backlit, strong sun flare | rainbow flares, mirrored fragments of the subject repeating at the frame edges |

Abstract and continuity, 22%:

| id | weight | lead | notes |
|---|---|---|---|
| `liquidAbstract` | 8 | Macro photograph of real fluids | Own subject list: ink blooming in water, oil-and-water cells, ferrofluid spikes, soap-film interference bands, marbled paint, melting dyed ice. 100mm macro, backlit on a light table. Fills the frame with pattern. Gives the shaders pure texture. |
| `fractalNature` | 8 | Photograph of a natural fractal structure | Own subject list: romanesco, fern fronds, frost on glass, river delta from the air, nautilus cross-section, lightning, bismuth crystals, succulent spirals, branching coral. Keeps the existing fractal vocabulary, but as real objects. |
| `cosmicDream` | 6 | Photorealistic wide view of an impossible place | The existing look. Uses a curated subset (about 14) of the current 50 scenes, the ones that name a concrete place: tree with galaxies in its sap, mercury-wave beach, observatory with nested spheres, cathedral-sized mushrooms, aurora rivers, origami mountains, city with a different reflection, fungal network cross-section. Gets the new palette and composition clauses; the old boilerplate is dropped. |

Palette rules: `aerochrome` is locked to the `aerochrome` palette. `biolumNight`, `longExposure` and `flashNight` draw only from dark-compatible palettes. `doubleExposure` and `studioProduct` take any. Everything else takes any except `aerochrome`.

## 3. Subjects and transformations

### Subjects (about 110, in `PromptLibrary+Subjects.swift`)

```swift
struct Subject: Sendable {
    let id: String              // "grandPiano"
    let phrase: String          // "a grand piano"
    let plural: String          // "grand pianos"
    let category: SubjectCategory
    let scale: SubjectScale     // tiny, handheld, humanSized, monumental, landscape
    let textProne: Bool         // adds "all surfaces blank and unmarked"
}
enum SubjectCategory: String, CaseIterable, Codable {
    case creature, plant, architecture, object, vehicle, landscape, food, instrument, celestial
}
```

| Category | Subjects |
|---|---|
| creature | chameleon, octopus, snowy owl, koi, jellyfish, stag with full antlers, hummingbird, tiger, peacock, humpback whale, moth, seahorse, fox, flamingo, beetle, manta ray |
| plant | orchid, giant sequoia, sunflower, cactus, mushroom cluster, water lily, bonsai, dandelion seed head, venus flytrap, cherry tree in blossom, fern, pinecone |
| architecture | lighthouse, spiral staircase, greenhouse, cathedral, suspension bridge, water tower, carousel, windmill, subway station, drive-in screen (blank), stone archway, swimming pool, phone booth (unmarked), ferris wheel |
| object | rotary telephone (blank dial), armchair, chandelier, umbrella, typewriter (blank keys), lightbulb, bicycle, hourglass, teapot, vintage television (blank screen), sneaker, key, bathtub, ladder, chess set, disco ball |
| vehicle | steam locomotive, sailboat, hot-air balloon, classic convertible, tram, biplane, submarine, cable car, rowing boat, motorcycle, zeppelin, school bus (unmarked) |
| landscape | salt flat, waterfall, sea stack, sand dunes, glacier cave, volcano, terraced rice fields, slot canyon, lavender field, mangrove, hot spring, basalt columns |
| food | pomegranate, layered cake, citrus, honeycomb, pineapple, ice-cream cone, bowl of noodles, artichoke, watermelon, soft-boiled egg, croissant, dragon fruit |
| instrument | grand piano, cello, trumpet, harp, drum kit, vinyl turntable, accordion, electric guitar, pipe organ, gramophone, saxophone, modular synthesizer |
| celestial | full moon, ringed planet, comet, solar eclipse, aurora, spiral galaxy, thunderhead with lightning, meteor shower, crescent moon, the sun |

Clocks, road signs, books, bottles with labels and neon signs are left out because their text is the first thing that goes wrong.

### Transformations (26, in `PromptLibrary+Transformations.swift`)

```swift
struct Transformation: Sendable {
    let id: String
    let kind: TransformationKind   // material, scale, displacement, hybrid, container, multiplicity,
                                   // stateChange, gravity, overgrowth, reflection, luminous, plain
    let template: String           // slots: {S} subject, {Sp} plural, {S2} second subject, {M} material,
                                   // {E} environment, {G} growth
    let weight: Double
    let needsStrongSurreal: Bool
    let moods: [Mood]
}
```

| kind | templates |
|---|---|
| material | `{S} made entirely of {M}` / `{S} carved from a single block of {M}` |
| scale | `{S} the size of a mountain, towering over {E}` / `a miniature {S} resting on a single leaf` |
| displacement | `{S} standing alone in {E}` / `{S} resting on the seabed, perfectly intact` |
| hybrid | `{S} with {S2} growing out of it like blossoms` / `{S} whose surface is covered in the patterned skin of {S2}` |
| container | `{S}, and inside it a complete tiny {E} with its own weather` / `{S2} sealed inside a giant glass {S}` |
| multiplicity | `hundreds of identical {Sp} arranged in a perfect spiral that recedes to the horizon` / `a flock of {Sp} flying in formation across the sky` |
| stateChange (strong surreal) | `{S} half melted, sagging and flowing like thick syrup while still clearly recognizable` / `{S} bursting into a cloud of {petals, butterflies, feathers, soap bubbles}, frozen in mid-air` / `{S} unravelling into long ribbons that drift on the wind` |
| gravity | `{S} floating a metre above {E}, casting a sharp shadow below` / `{S} hanging upside down from the clouds` |
| overgrowth | `{S} overgrown with {G}, as if abandoned for a century` |
| reflection | `{S} reflected in perfectly still water, the reflection showing {S2} instead` |
| luminous | `{S} glowing from within like a paper lantern` / `a translucent {S} with its inner structure visible and softly lit` |
| plain (weight 10%) | `{S}` with one spectacular real detail, no impossibility. The style and palette carry the strangeness. |

Slot lists:
- `{M}` (20): blown glass, liquid chrome, carved jade, honeycomb dripping honey, living moss, stained glass, folded paper, knitted wool, porcelain with gold kintsugi seams, translucent amber, clear ice, woven copper wire, opal, soap-bubble film, citrus fruit, pink coral, feathers, polished obsidian, molten glass, wildflowers.
- `{E}` (16): a white salt flat, a flooded ballroom, the seabed, the tops of the clouds, a black lava field, an empty swimming pool, fresh snow, red sand dunes, a mossy forest, a mirror-still lake, a wheat field, a tiled bathhouse, a foggy pier, a moonlit rooftop, a field of poppies, an ice cave.
- `{G}` (8): coral and barnacles, moss and ferns, quartz crystals, glowing mushrooms, wildflowers, frost feathers, ivy and wisteria, bracket fungi.

Compatibility is a small table of exclusions, not free combination: landscapes and celestial subjects cannot take `material`, `displacement` or `overgrowth`; `{S2}` always comes from a different category; `macro` only takes tiny or handheld subjects or miniature transformations; `aerial` and `tiltShift` only take human-sized or larger.

## 4. Palettes (17)

```swift
struct Palette: Sendable {
    let id: String
    let words: [String]        // explicit color words that go into the prompt
    let accent: String?
    let swatches: [RGB]        // intended colors, for metadata
    let isDark: Bool
    let warmth: Double         // -1 cool ... +1 warm
    let energy: Double         // 0 calm ... 1 intense
    let moods: [Mood]
    let weight: Double
}
```

| id | color words | accent | dark-compatible |
|---|---|---|---|
| `aerochrome` | crimson, hot pink, deep teal | bone white | no |
| `acidCitrus` | acid lime green, tangerine, hot magenta | ultramarine | no |
| `deepSea` | cobalt blue, turquoise, oxidized copper green | sunflower yellow | yes |
| `neonNoir` | electric cyan, neon magenta, violet | wet black | yes |
| `desertSunset` | burnt sienna, coral, apricot | dusty violet | no |
| `borealis` | emerald, aurora green, ice blue | indigo | yes |
| `candyPastel` | bubblegum pink, mint, butter yellow | baby blue | no |
| `moltenGold` | molten gold, ember orange, cream | obsidian black | yes |
| `jewelBox` | emerald, ruby, sapphire, amethyst | black velvet | yes |
| `monoCobalt` | every shade of blue from navy to ice | one vermilion accent | yes |
| `toxicBloom` | chartreuse, deep violet, acid yellow | black | yes |
| `rustAndTeal` | oxidized teal, rust orange, charcoal | bone | no |
| `pearl` | pearl white, opal shimmer, lilac | pale gold | no |
| `primaries` | fire-engine red, sky blue, sun yellow | grass green | no |
| `bloodMoon` | deep maroon, copper, moon white | black | yes |
| `ultraviolet` | ultraviolet purple, fluorescent green, hot orange | blue-black | yes |
| `earth` (low weight) | moss green, ochre, slate | cream | no |

Prompt clause: `Color palette: {w1}, {w2} and {w3} with {accent} accents, vivid and clearly separated.` The current "Natural, realistic colors" line is deleted; it is the main cause of the samey look.

## 5. Prompt grammar, anti-repetition, series, metadata

### Assembly

```
{style.lead}, {style.camera}. {Transformed subject}[, all surfaces blank and unmarked]. {Palette clause} {style.lighting}. {style.texture}. {composition.fragment}. {tail}
```

Tail (the wording that tested clean):
> One clear focal subject in the central third with a strong readable silhouette, crisp edges and rich tactile surface texture, uncluttered surroundings. Full-bleed photograph: the scene fills the entire image edge to edge. Physically plausible materials and light, as if really photographed. The image contains only the scene itself: no lettering, no logos, no people.

Target length 70 to 140 words. The words "illustration", "digital art", "CGI", "render", "border", "frame", "watermark" and "film scan" never appear; a test enforces it.

Compositions (8): centered hero at eye level; low angle looking up at a monument; straight top-down; perfect symmetry with a reflection; pattern repeating to the horizon; extreme close-up filling the frame; small subject in vast empty space; subject seen through a foreground opening. Styles restrict which apply (`aerial` is always top-down; `macro` is close-up or centered).

### Types (`Liminal/Visual/Prompt/`, Foundation only, no app imports)

```swift
// SeededRNG.swift
struct SeededRNG: RandomNumberGenerator { init(seed: UInt64); mutating func next() -> UInt64 }  // SplitMix64

// PromptLibrary.swift (+Styles, +Subjects, +Transformations, +Palettes, +Legacy)
struct PromptLibrary: Sendable {
    static let version = 2                 // prompt-system version, stored in every image's metadata
    let styles: [Style]; let subjects: [Subject]; let transformations: [Transformation]
    let palettes: [Palette]; let compositions: [Composition]
    static let standard: PromptLibrary
    func validate() -> [String]            // empty when every style has at least one legal combination
}

// PromptSpec.swift
struct PromptSpec: Sendable, Codable, Equatable {
    let text: String
    let styleID: String, styleFamily: StyleFamily
    let paletteID: String, paletteSwatches: [RGB]
    let subjectID: String, subjectCategory: SubjectCategory
    let secondSubjectID: String?
    let transformationID: String, transformationKind: TransformationKind
    let compositionID: String
    let moods: [Mood]                      // 2 to 4, from a fixed vocabulary
    let energy: Double, warmth: Double
    let needsStrongSurreal: Bool
    let series: SeriesInfo?
    let promptVersion: Int
}
enum Mood: String, Codable, CaseIterable {
    case serene, eerie, euphoric, ominous, playful, majestic, intimate, electric, melancholy, lush
}
struct SeriesInfo: Codable, Sendable, Equatable { let id: UUID; let kind: SeriesKind; let index: Int; let length: Int }
enum SeriesKind: String, Codable { case subjectStudy, paletteRun, styleSet, materialThread }

// PromptHistory.swift
struct PromptHistory: Codable, Sendable, Equatable {
    var styles: [String] = []              // last 6
    var palettes: [String] = []            // last 6
    var subjects: [String] = []            // last 40
    var categories: [SubjectCategory] = [] // last 3
    var transformationKinds: [TransformationKind] = []  // last 4
    var compositions: [String] = []        // last 2
    var activeSeries: ActiveSeries?
    mutating func record(_ spec: PromptSpec)
}

// PromptBuilder.swift
struct PromptTuning: Sendable {
    var seriesStartProbability = 0.2
    var seriesLength = 3...4
    var plainTransformationShare = 0.10
    static let standard = PromptTuning()
}
struct PromptBuilder: Sendable {
    init(library: PromptLibrary = .standard, tuning: PromptTuning = .standard)
    func next<R: RandomNumberGenerator>(history: inout PromptHistory, using rng: inout R) -> PromptSpec
    func batch(count: Int, seed: UInt64) -> [PromptSpec]     // fresh history, SeededRNG(seed)
}
```

`PromptBuilder` is a pure function of (library, tuning, history, rng). No clock, no globals, no network.

### Weighted choice with recency penalty

Order of draws: style, subject, transformation (and its slots), palette, composition. Each draw uses `weight * penalty`:

| Axis | Penalty |
|---|---|
| style | 0 if used in the last 2 images; 0.3 if in the last 6 |
| palette | 0 if in the last 3; 0.3 if in the last 6 |
| subject | 0 if in the last 40 |
| subject category | 0 if same as the previous image; 0.5 if in the last 3 |
| transformation kind | 0 if same as the previous image; 0.4 if in the last 4 |
| composition | 0.2 if same as the previous image |

If every candidate scores 0 (a small pool after filtering), the hard zeros are relaxed to 0.05 so a draw always succeeds. With 16 styles, 17 palettes and 110 subjects, the same style can come back no sooner than every third image and the same subject no sooner than every 41st.

### Series

At each image that is not already in a series, start one with probability 0.2, length 3 or 4. One axis is held, the rest are forced to differ:

| Kind | Held | Varies |
|---|---|---|
| `subjectStudy` | subject | style, palette, transformation (the same piano three ways) |
| `paletteRun` | palette | style, subject |
| `styleSet` | style and subject category | subject, palette |
| `materialThread` | material `{M}` | subject, style |

The held axis is exempt from its own recency penalty during the series. `SeriesInfo` goes into the metadata. Series are in generation order, which is display order in live mode; the cache recycler does not try to keep them together.

### App-side wrapper

`Liminal/Visual/PromptDirector.swift` (new)
```swift
final class PromptDirector: @unchecked Sendable {   // lock-protected, not an actor (MainActor starvation on visionOS)
    init(builder: PromptBuilder = PromptBuilder(), defaults: UserDefaults = .standard)
    func next() -> PromptSpec          // SystemRandomNumberGenerator; saves history to UserDefaults "images.promptHistory"
    func reset()                       // called by clear-all
}
```
`ImageQueue.promptBuilder: (() -> String)?` becomes `promptSource: (() -> PromptSpec)?`. `VisualEngine.buildPrompt()` is deleted; its scenes that survive move to `PromptLibrary+Legacy.swift`.

### Per-image metadata

`Liminal/Visual/ImageMetadata.swift` (new)
```swift
struct RGB: Codable, Sendable, Equatable { let r: Double, g: Double, b: Double }

struct ImageMetadata: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let spec: PromptSpec            // style id, palette id, moods, energy, warmth, series, prompt text, prompt version
    let model: String
    let pixelWidth: Int, pixelHeight: Int
    let mimeType: String
    let dominantColors: [RGB]       // measured from the pixels, 5 colors, most coverage first
    let measuredBrightness: Double  // 0...1 mean luma
    let measuredSaturation: Double  // 0...1 mean
}
```
`Liminal/Visual/DominantColorExtractor.swift` (new): `static func analyze(_ image: CGImage) -> (colors: [RGB], brightness: Double, saturation: Double)`. Draws the image into 48x32 RGBA, buckets pixels into a 4x4x4 RGB histogram, returns the mean color of the 5 fullest buckets. Under 1 ms, CoreGraphics only.

Exposure, additive so renderer code keeps compiling untouched:
- `AtomicImageBuffer`: `storeCurrent(_:metadata:)`, `queuePending(_:metadata:)` (metadata defaults to nil), `loadCurrentMetadata() -> ImageMetadata?`, `loadCurrentWithMetadata() -> (image: CGImage?, metadata: ImageMetadata?, generation: UInt64)`. The pending queue stores pairs, and `advanceFromQueue()` moves the metadata with the image. Existing methods keep their signatures.
- `VisualEngine`: `@Published private(set) var currentMetadata: ImageMetadata?`, updated in `advance()`. Best effort on visionOS; the atomic read is the reliable one.
- Nothing is wired to audio. A later consumer reads `imageBuffer.loadCurrentMetadata()` when the generation counter changes.

## 6. Composition rules for the effects

The shaders (Ken Burns, distortion, hue shift, ghost taps) read best on structure, and Ken Burns shows only the central 80% or so. So every prompt asks for:
1. One focal subject in the central third. Nothing important at the edges.
2. A strong silhouette against a simpler background (the dark falloff, seamless backdrop, open sky and open water in the style definitions exist for this).
3. Crisp edges and tactile texture at more than one scale, so distortion has something to bend.
4. A limited palette of three colors and an accent, so hue shifting moves clear color blocks instead of mud.
5. The scene filling the image, no lettering, no logos, no people. People are left out because warped faces read as unpleasant rather than trippy, and because of safety blocks.

Safety net for borders: `Liminal/Visual/BorderTrimmer.swift`, `static func trimmedIfBordered(_ image: CGImage) -> CGImage`. Samples the outer 2% on each side; if all four strips are near-uniform and near-white or near-black while the interior is not, crops inward to the content. Runs once per generated image before caching.

## 7. Cache, pacing, and "Clear all images"

### Store

`Liminal/Visual/ImageStore.swift` replaces `ImageCache.swift` (same non-actor, thread-safe design).

```
Application Support/Liminal/ImageStore/
    <uuid>.jpg | .png      original bytes from the model (after border trim only if trimmed)
    <uuid>.json            ImageMetadata sidecar
    <uuid>.depth.png       optional depth map (slot reserved; see below)
```

```swift
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()
    static let cacheEpoch = 2                 // bump to purge every device's cache on next launch

    struct Entry: Sendable { let id: UUID; let imageURL: URL; let metadata: ImageMetadata? }
    struct Usage: Sendable { let imageCount: Int; let bytes: Int64 }

    func migrateIfNeeded()                    // runs once at launch, before anything is loaded
    func entries() -> [Entry]                 // newest first; reads sidecars, decodes no pixels
    func loadImage(_ entry: Entry) -> CGImage?
    func save(_ image: GeneratedImageData, metadata: ImageMetadata, clearGeneration: UInt64) throws -> Entry
    func saveDepth(_ depth: CGImage, for id: UUID)
    func loadDepth(for id: UUID) -> CGImage?
    func usage() -> Usage
    var clearGeneration: UInt64 { get }       // increments on every clear
    @discardableResult func clearEverything() -> Usage
}
```

- Both platforms store the original model bytes. macOS stops storing a 2048 PNG re-encode.
- Images are decoded on demand. Startup lists entries and decodes one. The recycler decodes one at a time. macOS keeps at most 12 decoded images in `StateManager`.
- Size cap: 400 images. `save` deletes the oldest beyond that.
- Depth: `saveDepth`/`loadDepth` exist so the dome view can skip DepthAnything for recycled images. Calling them from `ImmersiveDomeView` is a small follow-up for the renderer workstream; nothing here depends on it.

### Versioning and automatic invalidation

Two numbers, on purpose:
- `PromptLibrary.version`: written into every sidecar. Changing a subject list bumps it. It does not delete anything.
- `ImageStore.cacheEpoch`: compared with `UserDefaults "images.cacheEpoch"` in `migrateIfNeeded()`. If the stored value is lower or missing, the store deletes the whole `ImageStore/` directory and the legacy `RawImages/` and `UpscaledImages/` directories, then writes the new epoch.

Decision: this release sets `cacheEpoch = 2`, so the first launch of the new build on the Vision Pro removes all the old square images automatically, and the manual button is there as well. Later prompt tweaks do not purge unless someone bumps the epoch deliberately. Reason: the old images are exactly what the user wants gone and they are the wrong shape for the new pipeline, but silently destroying a paid-for cache on every wording change would be wrong.

### One clear action

`VisualEngine.clearAllImages()` calls `ImageQueue.clearAllImages() async`, which does this in order:
1. `store.clearEverything()`: increments `clearGeneration`, deletes `ImageStore/`, `RawImages/`, `UpscaledImages/` as whole directories (every file type, sidecars and depth included), recreates `ImageStore/`.
2. Cancels `generationTask` (generator or cache recycler) and waits for it.
3. `imageBuffer.clear()`: current, next, pending queue, depth, metadata.
4. Clears `StateManager` (buffer, cached list, display history) and the `@Published` mirrors.
5. `promptDirector.reset()`.
6. Posts `.imageCacheCleared` once.
7. If the engine was running and Cache Only is off, starts generation again. If Cache Only is on, stays idle and the UI says "No cached images. Turn off Cache Only to generate new ones."

The in-flight race is closed by the generation counter: `generateAndUpscaleOne` captures `store.clearGeneration` before calling Gemini and passes it to `store.save`, which refuses a stale value; the same check guards `queuePending`. An image that was mid-flight when the user tapped Clear is dropped.

Known limit: the renderers keep their current GPU textures until the next image arrives. Dropping them on `.imageCacheCleared` is a renderer change for the other workstream. Until then the last image stays on screen for the 10 to 20 seconds it takes to generate a new one.

UI (`ContentView.swift`, `ControlsView.swift`), same on both:
- Button "Clear All Images", destructive, with a `confirmationDialog`: "Delete all 42 images (310 MB)? This cannot be undone. New images will be generated."
- The line under it shows a live count and size from `store.usage()`, refreshed on `.imageCacheCleared` and whenever `visualEngine.totalCachedCount` changes.
- "Reset All to Defaults" does not clear images; the two stay separate.

### Pacing (fixes the unbounded loop)

`startContinuousGeneration` generates only while `imageBuffer.pendingCount() < config.targetPendingCount` (2) on visionOS, or `state.bufferCount() < 2` on macOS; otherwise it sleeps 1s and checks again. Generation rate then equals display rate: 120 images an hour at the default 30s interval.

Cost at that rate, using the unverified third-party prices in the research doc: about $12 an hour at 2K, $8 at 1K. See open questions.

## 8. Test seam and evaluation tooling

### Unit tests: `LiminalTests/PromptBuilderTests.swift` (Swift Testing)

- `deterministic`: `batch(count: 50, seed: 7)` twice gives identical specs.
- `libraryIsValid`: `PromptLibrary.standard.validate()` is empty.
- `noNearRepeats`: over 300 prompts, no style within 2, no palette within 3, no subject within 40.
- `coverage`: over 1000 prompts every style, palette, category and transformation kind appears; no style exceeds 2.5x its weight share.
- `wordBudget`: every prompt is 70 to 140 words and contains the full-bleed sentence.
- `bannedWords`: none of the priming words listed in section 5 appear.
- `seriesInvariants`: within a series the held axis is constant and the varying axes differ.
- `textProneSubjectsGetBlankClause`.
- `printSample`: prints 20 prompts for seed 14 to the test log.
- `ModelRouterTests`: fallback order, cooldown doubling, safety block keeps the model.
- `ImageStoreTests` (temp directory injected through an internal `init(root:defaults:)`): save and list; `clearEverything` removes sidecars and legacy directories; stale `clearGeneration` save is refused; epoch bump purges.

Run with `xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests`.

### Prompt dump without Xcode: `scripts/print-prompts.sh`

```
scripts/print-prompts.sh [-n 24] [-s SEED] [--jsonl] > prompts.txt
```
Compiles `Liminal/Visual/Prompt/*.swift` plus `scripts/PromptDump/main.swift` with `swiftc` into the scratch directory and runs it. Plain output is one prompt per line. `--jsonl` emits the full `PromptSpec` per line. This also proves the builder has no app dependencies; it stops compiling the moment someone adds one.

### Sample generator: `scripts/gen-sample-images.py`

```
scripts/gen-sample-images.py --prompts prompts.txt --out DIR
    [--model gemini-3.1-flash-image] [--aspect 3:2] [--size 1K]
    [--limit N] [--concurrency 3] [--cols 4] [--thumb-width 640] [--retries 2]
```
- Python 3 standard library for HTTP, Pillow for the sheet (ffmpeg `xstack` fallback if Pillow is missing).
- Input: plain text (one prompt per line, `#` comments) or the JSONL from `print-prompts.sh`.
- Key: `GEMINI_API_KEY` if set, otherwise parsed from `Liminal/Secrets.swift`. Sent in the `x-goog-api-key` header. Never printed, never written.
- Output: `NN.jpg` per prompt, `manifest.json` (index, prompt, style, palette, model, latency, status), `contact-sheet.jpg` with each tile labelled `NN style / palette`. Failures get a grey tile with the reason.
- Default size is 1K for evaluation rounds (cheaper, and enough to judge). 24 prompts is about $1.60 at the unverified price.

### Evaluation loop

1. `print-prompts.sh -n 24 -s <seed> --jsonl > round.jsonl`
2. `gen-sample-images.py --prompts round.jsonl --out images-eval/<round>/`
3. Read the contact sheet. Score each tile: photoreal, recognizable in under a second, palette matches, border or text defect. Score the sheet as a whole: does it look like 24 different photographers?
4. Fix the library entries that fail (a style whose images look rendered, a transformation the model ignores, a palette that washes out), bump nothing, repeat. Two or three rounds.
5. Record what changed and why in `docs/decisions/images.md`.

## 9. Implementation order

1. `Prompt/` types, library data, `PromptBuilder`, tests, `print-prompts.sh`. No app behavior changes yet.
2. `gen-sample-images.py`, then two or three evaluation rounds to tune the library.
3. `GeminiClient.generate`, `ImageGenerationConfig`, `ModelRouter`, upscale skip rule.
4. `ImageMetadata`, `DominantColorExtractor`, `BorderTrimmer`, `AtomicImageBuffer` metadata methods.
5. `ImageStore`, migration and epoch purge, lazy loading, pacing in `ImageQueue`, `PromptDirector` wired in, `VisualEngine.buildPrompt` removed.
6. `clearAllImages`, both UIs, macOS 3:2 window.
7. Build both platforms, run tests, final decisions-doc pass.

Files touched: `GeminiClient.swift`, `ImageQueue.swift`, `AtomicImageBuffer.swift`, `ImageUpscaler.swift` (skip rule only), `VisualEngine.swift`, `ContentView.swift`, `ControlsView.swift`. `ImageCache.swift` is deleted. No shader, renderer, dome view or simulator changes. New Swift files sit under `Liminal/` and `LiminalTests/`, which are file-system-synchronized groups, so the project file needs no edit.

## 10. Open questions for the user

1. Spend. Paced generation at the 30s default is about 120 images an hour, roughly $12 an hour at 2K on the unverified prices. Options if that is too much: 1K (about a third cheaper, softer on the dome), or mix cached images back in once the library holds 100 or more (for example every other image fresh). The plan as written generates every image fresh, as the app does today.
2. Pricing for `gemini-nano-banana-2.1` and the lite model is not confirmed. The 10% surreal share is easy to set to zero.
3. No other provider or key is recommended. Gemini 3.x on the existing key produced the look that was asked for in the tests above.
