# Image source "AI vs API": plan

> **Status (2026-11-21): implemented** on branch `image-api-mode`. What changed from this plan while building, with
> measurements, is in `docs/decisions/images.md` D36-D41: no upper key-share gate (it rejected the night neon and
> nebulae), monochrome at saturation < 0.025, text rejects only paper-like pictures or text over a quarter of the
> frame, size gate 2000 x 1333, NASA originals over 12 MB rejected (`~large` is 1920 px), the Smithsonian key read
> from the environment only, and the "picture shown" ledger write moved off the main actor. Section 11 gate 5 (the
> toggle clicked in the live app) was covered by a unit test because the Mac's screen was locked during the runs.

A second way of getting pictures. **AI** is today's Gemini generation. **API** shows curated public-domain and
openly licensed imagery fetched from library, museum and space-agency APIs: roadside neon, 1970s Kodachrome,
Apollo-era Earth views, photochroms, fungi, woodblock landscapes. It is a mode toggle with the same look as
Ambient / Lo-Fi. Branch `image-api-mode`.

Research this plan rests on: `docs/research/image-apis/survey.md` (which APIs work, keys, resolution, rights),
`collections.md` (the 13 curated sources, measured sizes, rejections) and `openpics.md` (the user's earlier
OpenPics app). The approved source list is `Liminal/Visual/ImageSources/image-collections.json`.

Decisions taken while building go in `docs/decisions/images.md`, starting at **D36**. Numbers marked *(tune)*
are starting points.

## 0. Findings that shape the design

| Finding | Consequence |
|---|---|
| Every picture enters through `ImageQueue`, and everything after it (buffer, Lo-Fi reserve, 3:2 crop, saliency, depth, mood, footage) ignores where the picture came from. | API mode is a third loop inside `ImageQueue` that produces the same `DisplayItem`s. No renderer, shader, uniform or Lo-Fi scheduling change. |
| `generationDisabled` includes `DebugLaunchOptions.blocksImageGeneration`. | API mode gets its own gate. Automation launches must still fetch from the free APIs, and must still never reach Gemini. |
| Lo-Fi reserves a picture 6 s before a build and drops it if it is not ready 2 s before. Only local data makes that deadline. | The display side of API mode reads only from disk. The network only ever adds to the disk pool. |
| `ImageStore` hard-codes its folder and uses one global epoch key; `migrateIfNeeded` would purge both stores. It caps at 400 images. | The API pool is a second `ImageStore` with its own folder, epoch key and no count cap. |
| `ImageMetadata.spec` is required and `VisualMoodBuilder` reads warmth, energy, moods and subject category from it. | Each source carries a mood mapping, and the feed builds a `PromptSpec` from it. `VisualMoodBuilder` is untouched. |
| On macOS the RealESRGAN path stretches any input to 512×512 and returns 2048². Today it never runs. | Accept only pictures whose 3:2 crop is at least 2048 px wide, and guard the upscaler so a non-square image is never squashed. No upscaling is needed for the enabled sources. |
| Footage shows in the picture's shadows (`luma < 0.3` on at least 18% of a 16×16 thumbnail), or in its highlights otherwise, and is tinted from the picture's colours. Grey pictures give grey film and cannot be recoloured by the shader. | Score "openness" at ingest with the same thresholds, keep colour sources the majority, and cap monochrome pictures in the rotation. |
| All five enabled providers are keyless (LOC, NASA, Wikimedia Commons, Cleveland, Met). Commons fails in bursts, the Met has a bot wall after about 100 rapid requests, LOC only reaches 2K through IIIF. | One paced HTTPS client with per-host gaps and a per-provider backoff ladder. A blocked provider is skipped, never fatal. |
| The app is sandboxed with outgoing network on and has no ATS exceptions. | HTTPS only. NASA asset URLs are rewritten from `http` to `https`. |

## 1. Behaviour

- **Toggle.** A segmented picker "AI | API" sits directly under the Ambient / Lo-Fi picker, on macOS and in the
  visionOS control window, built the same way as `MusicModeControls`. Default is AI. Switching leaves the picture
  on screen and takes effect at the next image change (timer in Ambient, next drum boundary in Lo-Fi).
- **API mode never calls Gemini.** No request, no `GenerationBudget.check()` or `record()`, no prompt history
  advance. The Gemini cap UI and Cache Only toggle are hidden while API is selected.
- **Fallback ladder in API mode:** pictures waiting in the queue → the API pool on disk → the bundled standby art.
  The AI cache is never shown in API mode, and Gemini is only ever used in AI mode. If every provider fails, the
  pool keeps rotating and the status row says so.
- **Credits.** The picture on screen shows title, creator, date, institution, licence and a source link next to
  the film credit. Every ingest and every display is logged with the same fields.

## 2. Settings and switching

### 2.1 Types

`Liminal/Visual/ImageSources/ImageSource.swift`:

```swift
nonisolated enum ImageSource: String, CaseIterable, Codable, Sendable {
    case ai, api
    var title: String            // "AI" / "API"
    static let defaultsKey = "visual.imageSource"
    static var current: ImageSource   // DEBUG flag override, then UserDefaults, default .ai
}
```

`ImageSource.current` reads `UserDefaults.standard` directly (the pattern of `DialogueTranscriptionMode.current`),
because `ImageQueue` runs off the main actor.

### 2.2 `SettingsService`

Add key `visual.imageSource`, `@Published var imageSource: ImageSource` with a `didSet` that writes the raw value,
load with fallback `.ai`, and reset to `.ai` in `resetToDefaults`. Same shape as `musicMode`.

### 2.3 Switching while running

- `ImageSourceControls` (shared view) has `.onChange(of: settings.imageSource)` calling
  `VisualEngine.setImageSource(_:)`.
- `ImageQueue.switchSource(_ source:)`: cancel the running loop, bump a `sourceGeneration` counter (the same
  stale-result guard as `clearGeneration`), drain pending pictures (`state.clearBuffer()` and
  `imageBuffer.takePending()`), publish the cached count of the new store, restart the right loop if running.
- A Gemini request in flight when the user switches to API is discarded by the stale guard. Its cost was already
  recorded, which is correct.
- `reserveForFill`, `recycleOneFromCache`, `loadInitialImage`, `clearAllImages`, `cacheUsage` and
  `noCachedImagesMessage` all go through one `activeStore` accessor.

## 3. Provider layer

New folder `Liminal/Visual/ImageSources/` (file-system synchronized, no project edits).

### 3.1 Files and types

| File | Contents |
|---|---|
| `ImageSource.swift` | The enum above. |
| `ImageCollections.swift` | `Codable` model of `image-collections.json`: `ImageCollections` (defaults, providers, `licenseAllowlist`, `sources`), `CuratedSource` (id, provider, enabled, weight, themes, queries / categories / searches, pinned, reject words, `requireIIIF`, `requiresKey`, `mood`), `SourceMood` (moods, subjectCategory, energy, warmth). `ImageCollections.bundled` loads the bundled JSON once. |
| `ImageSourceCredit.swift` | `nonisolated struct ImageSourceCredit: Codable, Sendable, Equatable` (providerID, sourceID, itemID, title, creator, date, institution, license, licenseURL, sourceURL, imageURL), plus `displayLine` and `requiresAttribution`. |
| `ImageCandidate.swift` | `ImageCandidate` (key `provider:itemID`, title, creator, date, declared width/height/mime/bytes when known, rights text, page URL, image URL or resolver hint) and `ResolvedImage` (final HTTPS URL, expected size, credit). |
| `ImageHTTP.swift` | `actor ImageHTTP`: one ephemeral `URLSession`, User-Agent from the JSON defaults, no `URLCache`, `allowsConstrainedNetworkAccess = false`, per-host minimum gap (1 s default, 5 s for `collectionapi.metmuseum.org` and `images.metmuseum.org`), `json(_:)` and `download(_:to:maxBytes:)` (temp file then move, abort past `maxBytes`), typed `ImageFetchError` (`offline`, `http(status)`, `blocked`, `tooLarge`, `badContent`). An HTML body on a JSON or image request maps to `.blocked`. |
| `ImageProvider.swift` | `protocol ImageProvider: Sendable` with `id`, `candidates(source:query:page:http:) async throws -> [ImageCandidate]`, `pinned(source:ids:http:)`, `resolve(_:http:) async throws -> ResolvedImage`. `ImageProviders.all(environment:)` returns the providers whose key requirement is met. |
| `Providers/LOCProvider.swift` | Collection search JSON; IIIF service id from the result's `image_url`; one `info.json` call for the true size; image `{service}/full/{w},/0/default.jpg`; rights must equal "No known restrictions on publication". Uses `LooseString` for the mixed string / array fields. |
| `Providers/NASAProvider.swift` | `/search` with year window, `/asset/<id>` for `~orig` and `~large`; `~orig` unless a `HEAD` shows more than `maxBytes`, then `~large`; `http` rewritten to `https`. Credit from `center`, `photographer`, `secondary_creator`. |
| `Providers/WikimediaProvider.swift` | `generator=categorymembers` and `generator=search` with `prop=imageinfo`; mime allowlist (JPEG, PNG); licence from `extmetadata.LicenseShortName` against the allowlist; `Artist` and `Credit` stripped of HTML; scaled URL from `thumburl`. |
| `Providers/ClevelandProvider.swift` | `/api/artworks` with `type`, `has_image=1`, `cc0=1`; `images.print.url`; `share_license_status == "CC0"`. |
| `Providers/MetProvider.swift` | v1.1 search for object ids, then `/v1/objects/<id>`; `isPublicDomain` checked per object; `primaryImage`; classification allowlist. |
| `Providers/SmithsonianProvider.swift` | Last, optional. Only registered when `SMITHSONIAN_API_KEY` is present (`EnvironmentService`, `Secrets.swift.template` gets an empty placeholder). The source stays `enabled: false` in the JSON until its media resolution is measured. |
| `ImageRotation.swift` | Pure rotation logic, section 4. |
| `ImageOpenness.swift` | Pure scoring, section 6. |
| `ImageRights.swift` | `ImageRights.verdict(provider:rightsText:allowlist:) -> .allowed(license) / .rejected(reason)`. Normalises spellings ("PD-US", "Public domain", "CC BY-SA 4.0"). Unknown or empty is rejected. |
| `CuratedImagePool.swift` | The on-disk pool, section 5. |
| `CuratedImageFeed.swift` | The ingest pipeline and the two loops, section 4.3. |
| `ImageSourceControls.swift`, `ImageCreditLine.swift` | Shared SwiftUI, section 7. |

Each provider keeps its parsing in `static` pure functions that take `Data` and return candidates
(`LOCProvider.parseSearch(_:)`, `parseInfo(_:)`, and so on), so the tests run on saved JSON with no network.

Providers are `nonisolated` value types. `ImageHTTP` is an actor, as `ArchiveClient` is, and is only awaited from
the feed's detached tasks, never from the render path or the main actor.

### 3.2 Additions to `image-collections.json`

- A `mood` block per source, from the fixed vocabularies in `PromptTypes.swift`. Starting values *(tune)*:

| Source | moods | subjectCategory | energy | warmth |
|---|---|---|---|---|
| loc-highsmith-roadside | electric, playful | architecture | 0.55 | 0.4 |
| loc-highsmith-landscape | majestic, serene | landscape | 0.3 | 0.1 |
| nasa-space-age | majestic, eerie | celestial | 0.4 | -0.3 |
| nasa-deep-space | euphoric, majestic | celestial | 0.5 | 0.0 |
| documerica-1970s | melancholy, intimate | landscape | 0.4 | 0.5 |
| fungi-photographs | lush, eerie | plant | 0.35 | 0.1 |
| fungi-plates | eerie, intimate | plant | 0.25 | 0.3 |
| haeckel-art-forms | euphoric, eerie | creature | 0.5 | 0.0 |
| photochrom-landscapes | serene, majestic | landscape | 0.3 | 0.3 |
| cma-ukiyoe-landscapes | serene, melancholy | landscape | 0.25 | -0.1 |
| cma-early-photographs | melancholy, serene | landscape | 0.2 | 0.2 |
| met-landscapes | serene, majestic | landscape | 0.25 | 0.0 |

- `defaults.openness` thresholds (section 6), `defaults.storeBudgetBytes`, `defaults.unseenAhead`,
  `allowMonochrome` per source (true only for `cma-early-photographs`).
- `defaults.targetLongSide` raised to 3072 where a provider serves it (LOC IIIF, originals from NASA, Cleveland,
  Met). Commons stays at the measured 2048 unless a larger standard thumbnail step is confirmed in step 3.

## 4. Rotation and the feed

### 4.1 Two separate choices

1. **Ingest rotation:** which source the next download comes from.
2. **Display rotation:** which stored picture is shown next.

Keeping them apart means the display never waits on the network, offline reuse is the same code path as online,
and a slow provider cannot skew what is shown.

### 4.2 `ImageRotation` (pure, seeded, unit tested)

- `nextSource(sources:history:available:rng:)`: a bag holding each enabled source `weight` times, reshuffled when
  empty (the `ShuffleBag` pattern). Rules: never the same source twice in a row while another is available; never
  the same provider three times in a row; sources in backoff or without unseen candidates are skipped.
- `nextCandidate(source:candidates:ledger:rng:)`: pinned ids first, shuffled, then search results; anything
  already in the ledger (stored or rejected) is skipped.
- `nextDisplay(pool:history:rng:)`: weight per stored picture =
  `sourceWeight × recencyFactor × (0.5 + openness)`, where `recencyFactor` is 0 for the last 24 shown *(tune)* and
  rises with the number of pictures shown since. Hard rules: not the picture on screen, not the same source as the
  previous picture when the pool holds three or more sources, at most 1 monochrome picture in any 6. Pictures
  never shown get a ×3 boost so new arrivals surface quickly.
- `-LiminalImageAPISeed <n>` seeds the generator for repeatable runs.

### 4.3 `CuratedImageFeed`

`nonisolated final class CuratedImageFeed: Sendable`, owned by `ImageQueue`, with two detached loops.

**Display loop** (`ImageQueue.startAPIFeed`, replaces the generation loop in API mode): every second, while
fewer than `targetPendingCount` pictures are waiting, `nextDisplay` → `store.loadImage` → `enqueue`. This is the
cache recycler with a better picker. With an empty pool it sets the status "Fetching the first pictures…" and
waits; the Lo-Fi path shows the standby art meanwhile.

**Ingest loop:** runs while the pool holds fewer than `unseenAhead` (12 *(tune)*) pictures that have never been
shown, the network is allowed and not every provider is in backoff. One picture at a time:

1. `nextSource`, then `nextCandidate`. When a source has no unseen candidates, fetch its next search page
   (cursor kept per query in the ledger) and try again.
2. `provider.resolve` → `ResolvedImage`. Pre-download gates on declared metadata: rights verdict, mime, declared
   size (3:2 cover crop at least 2048 × 1365), bytes at most `maxBytes` (12 MB), title reject words.
3. `ImageHTTP.download` to a temp file.
4. Decode with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize` 3072,
   `CreateThumbnailFromImageAlways`, transform applied), so a large master never expands fully in memory.
5. `BorderTrimmer.trimmedIfBordered` for scan margins.
6. **Framing.** If the aspect is within 1.3 to 1.8, keep it and let the renderers' cover crop do the rest. Outside
   that (portrait plates, square Hasselblad frames), choose the 3:2 window along the long axis with the best
   openness score from five candidate offsets and cut it with `ImageFraming.crop(normalized:)`. The stored file is
   then already 3:2, so every downstream `coverCrop` is the identity and saliency and depth stay registered.
7. Post-decode gates: real pixel size after crop, openness and document checks (section 6), face check.
8. `DominantColorExtractor.analyze`, build `ImageMetadata` (`model = "api.<provider>"`,
   `spec` from the source's mood with `styleID = "api.<sourceID>"`, `source = credit`, openness scores).
9. Encode JPEG at quality 0.9 and `store.save`. Record the candidate key in the ledger as stored, or as rejected
   with its reason, so nothing is downloaded twice.
10. Log one line: source, item, size, openness, licence, URL.

**Pace.** At most one download every 4 s *(tune)* on top of the per-host gaps. Cold start goes pinned-first, which
needs no search call, so the first picture lands in a few seconds. Steady state fetches roughly one new picture
per picture shown.

**Failures.** A provider error puts that provider on the ladder 1 / 2 / 5 / 15 / 30 min (as `ArchiveCatalog`);
401 / 403 / 404 / 410 on one item marks only that item rejected. `.blocked` (the Met's bot wall) goes straight to
30 min. With everything in backoff or offline, ingest sleeps and display keeps rotating the pool.

### 4.4 `ImageQueue` changes

- `start()`: after the DEBUG fixed-image branches, `switch ImageSource.current`. `.api` → `startAPIFeed()`;
  `.ai` → today's code unchanged. `generationDisabled` stays AI-only.
- `requestImage` gains `guard activeSource == .ai else { throw … }` as a second lock on the Gemini path.
- `loadInitialImage`: in API mode, a random pool picture, else nothing (the standby art covers Lo-Fi, the first
  fetched picture shows itself in Ambient). The empty-cache test card applies only to AI mode or
  `-LiminalTestPattern`.
- `upscaleIfNeeded`: skip when the image is not square within 2% on macOS. `ImageUpscaler.shouldSkipUpscale` gets
  the same guard, with a test. A tiled RealESRGAN path is noted as follow-up, only needed if a sub-2048 source is
  ever approved.

## 5. The API pool on disk

### 5.1 Layout

`Application Support/Liminal/CuratedImageStore/`, excluded from backup:

- `<uuid>.jpg` and `<uuid>.json` (the normal `ImageStore` sidecar, now with `source` and openness fields).
- `ledger.json`: candidate keys seen (`stored` with uuid, or `rejected` with reason and date), per-query page
  cursors, per-picture `lastShown` and `showCount`, cached candidate lists with a fetch date (refreshed after
  7 days).
- `tmp/`: downloads in progress.

### 5.2 Code

- `ImageStore.init(root:defaults:directoryName:epochKey:maxImages:)`, defaults preserving today's behaviour.
  `ImageStore.curated` uses `"CuratedImageStore"`, `"images.api.cacheEpoch"` and `maxImages: nil`. Its
  `migrateIfNeeded` touches only its own folder and never the legacy directories.
- `ImageStore.save(jpeg:metadata:)` overload for bytes that did not come from Gemini.
- `CuratedImagePool` (`nonisolated final class`, `Mutex` state): loads sidecars once into memory, keeps the
  ledger, answers `nextDisplay` inputs, `markShown`, `usage()`. Policy decisions are pure static functions
  (`CuratedPoolPolicy.sweep(files:ledger:now:)`, `evictions(pool:budget:)`) so they are unit tested, as
  `ArchiveCachePolicy` is.

### 5.3 Size, and why

- Stored pictures are JPEG, long side at most 3072, about 1 to 2.5 MB each.
- **Budget 3 GB** (`defaults.storeBudgetBytes`), about 1,200 to 2,500 pictures. That is larger than the pictures
  an evening shows (about 150 an hour) by an order of magnitude, and the same size as the film cache.
- **Nothing is ever made unplayable** (A31, and the user's "no playback limits" rule). There is no count cap, no
  age cap and no per-source cap. Only when the pool passes the budget and a new picture has just been saved is
  the least recently shown picture removed, and its ledger entry is cleared so it can be fetched again. If the
  volume has under 1 GB free, ingest pauses and display continues.
- **Launch cleanup removes junk only:** image files with no sidecar, sidecars with no image, files that fail the
  `<UUID>.jpg` pattern, and anything in `tmp/` older than an hour.
- "Clear images" in API mode clears this pool and its ledger, not the AI cache. The label says which.

## 6. Openness, documents and people

### 6.1 `ImageOpenness.score(_ image: CGImage) -> OpennessScore` (pure, `nonisolated`)

Measured on a 48×32 thumbnail of the 3:2 cover crop:

| Measure | Definition | Use |
|---|---|---|
| `shadowShare` | fraction with luma < 0.3 (the constant `VideoComposite` uses) | film shows in shadows when ≥ 0.18 |
| `highlightShare` | fraction with luma > 0.65 | film shows in highlights otherwise |
| `keyShare` | `shadowShare` if ≥ 0.18, else `highlightShare` | what the film can occupy |
| `calmShare` | fraction of a 12×8 grid of cells whose luma standard deviation is < 0.06 | open sky, water, road, night |
| `edgeDensity` | mean absolute luma gradient | busy or text-like |
| `paperShare` | fraction with luma > 0.85 and saturation < 0.12 | scan margins, blank paper |
| `saturation` | mean saturation | monochrome when < 0.08 |

`openness = clamp(0.5·band(keyShare, 0.18…0.50) + 0.5·min(calmShare / 0.35, 1))`, where `band` is 1 inside the
range and falls linearly to 0 at 0.05 and 0.75.

Starting gates *(tune against the 56-picture contact sheet and the first 100 live ingests, then record in D36)*:

- reject `openness < 0.25`;
- reject `keyShare < 0.08` (nowhere for the film) or `keyShare > 0.75` (the film would cover the picture);
- reject a document: `paperShare > 0.55` and `edgeDensity` above its threshold, or Vision
  `VNDetectTextRectanglesRequest` boxes covering more than 6% of the frame;
- reject monochrome unless the source sets `allowMonochrome`.

Thresholds live in the JSON defaults, so tuning needs no code change. The score is stored in the sidecar and
feeds the display weight, so more open pictures appear more often rather than only passing a gate.

### 6.2 People

AI mode forbids humans and faces. Archival sources include them, and the brief asks for 1950s driving and
cityscapes, where small distant figures are part of the scene. Default policy: run
`VNDetectFaceRectanglesRequest` at ingest and reject a picture when any face box exceeds 1.5% of the frame or
more than four faces are found *(tune)*. Source-level `rejectTitleWords` already removes portraits by title.

Both Vision requests run once per picture, off the main actor, inside the ingest task. If Vision fails (possible
in the simulator), the check passes and the failure is logged.

## 7. UI and credits

- **`ImageSourceControls`**: segmented `Picker` with `.accessibilityIdentifier("imageSource")`, labelled
  "Images", segments "AI" and "API". macOS: `ContentView`, first row after the music-mode picker. visionOS:
  `ControlsView`, directly under the music section's picker. One shared view, as `MusicModeControls` is.
- **Hidden in API mode:** the Cache Only toggle and `ImageLimitSection` (Gemini caps).
- **`APIStatusRow`** becomes source-aware: in API mode "Curated collections: N sources online" / "Offline, showing
  saved pictures" / "Fetching the first pictures…".
- **`PlaybackStatus`** counts the active store.
- **`ImageCreditLine`**: shown when `visualEngine.currentMetadata?.source` is set. Text
  "Title · Creator, date · Institution · Licence", with a `Link` to the source page. Placed in the Images section
  on both platforms, next to the film credit text. Creator and licence are always shown, which covers CC BY and
  CC BY-SA.
- **Logs:** `LMLog.visual.info("API image shown: source=… item=… title=… creator=… license=… url=…")` when a
  picture becomes current, and the ingest line from 4.3. Both are stable strings the verify scripts grep.
- **Docs credit table:** `docs/experience.md` gains a table of sources (collection, institution, licence, link)
  beside the film table.

## 8. Debug flags

All in `DebugLaunchOptions.swift` (DEBUG value, Release stub, `logOnce` line), all added to
`blocksImageGeneration`, all in the flag table in `docs/development.md`.

| Flag | Effect |
|---|---|
| `-LiminalImageSource ai\|api` | Overrides the setting for this launch without persisting it. |
| `-LiminalImageProvider <id[,id]>` | Restrict ingest and display to these provider ids or source ids. |
| `-LiminalImageAPIOffline YES` | Pool only, no network. |
| `-LiminalImageAPISeed <n>` | Seeds both rotations. |
| `-LiminalImageAPIFresh YES` | Uses an empty `CuratedImageStore-Verify` folder, so a run proves fetching works and leaves the user's pool alone. The folder is removed at the next normal launch as junk. |

`blocksImageGeneration` keeps blocking Gemini in every one of these launches. API fetching does not consult it.
`-visual.imageSource api` also works as a settings key, but verification uses the flag because the flag blocks
generation by itself.

## 9. Tests (Swift Testing)

Fixtures are small JSON files trimmed from the saved probe responses, in `LiminalTests/Fixtures/ImageAPI/`,
loaded relative to `#filePath` as other suites do. No test touches the network or Gemini.

| Suite | Covers |
|---|---|
| `ImageSourceSettingsTests` | default `.ai`; persists and reloads; reset returns `.ai`; `ImageSource.current` honours the flag override; every new flag makes `blocksImageGeneration` true. |
| `ImageCollectionsTests` | bundled JSON decodes; every enabled source has a known provider, a mood from the fixed vocabularies and a weight > 0; every URL template is HTTPS; keyed sources are disabled without their key. |
| `ImageProviderParsingTests` | one search fixture and one detail fixture per provider (LOC search + `info.json`, NASA search + asset, Commons category + search, Cleveland, Met search + object, Smithsonian). Asserts ids, titles, sizes, image URLs, credits. Cases: LOC result with no IIIF service is skipped; NASA `http` becomes `https` and `~orig` over 12 MB falls back to `~large`; Commons TIFF and SVG are skipped and HTML is stripped from `Artist`; Met object with `isPublicDomain == false` is rejected; a Met HTML 403 body maps to `.blocked`. |
| `ImageRightsTests` | each allowlisted spelling is accepted; "Rights status not evaluated", CC BY-NC, CC BY-ND, empty and unknown are rejected; `requiresAttribution` is true for CC BY and CC BY-SA. |
| `ImageRotationTests` | over 10,000 seeded draws source shares match weights within tolerance; no source twice in a row; no provider three times in a row; a source in backoff is skipped; pinned come first; ledger entries are never drawn again; display never repeats within the recency window when the pool is larger than it; the monochrome cap holds; a one-picture pool still returns that picture. |
| `ImageOpennessTests` | synthetic images: dark sky over a bright strip scores high; white page with dense dark strokes is a document; uniform mid-grey has no key; a grey ramp is monochrome; the portrait window search picks the open end. |
| `CuratedImagePoolTests` | separate folder and epoch from `ImageStore.shared` (saving and migrating one leaves the other intact); sidecar round-trip with a credit; an old sidecar without `source` still decodes; sweep removes only orphans and stale temp files; eviction happens only over budget, removes the least recently shown and clears its ledger entry. |
| `ImagePipelineTests` (extend) | the upscaler skips non-square input on macOS; `VisualMoodBuilder` yields the source's moods and category for an API picture. |
| `GenerationBudgetTests` (extend) | running the API display path with a stub store leaves the ledger unchanged. |

## 10. Step order

Each step builds on macOS and is committed.

1. **Setting and flags.** `ImageSource`, `SettingsService`, the five debug flags, `ImageSourceControls` on both
   platforms (toggle only, no behaviour). `ImageSourceSettingsTests`. Build both platforms.
2. **Metadata and store.** `ImageSourceCredit`, optional `ImageMetadata.source` and openness fields,
   `ImageStore` parameters and save overload, `CuratedImagePool` with ledger, sweep and budget.
   `CuratedImagePoolTests`.
3. **Collections model and providers.** `ImageCollections`, mood blocks in the JSON, `ImageHTTP`, the five
   keyless providers with fixtures. Re-probe each endpoint once with `curl` while trimming fixtures, and settle
   the largest rendition each provider serves. `ImageCollectionsTests`, `ImageProviderParsingTests`,
   `ImageRightsTests`.
4. **Rotation and openness.** `ImageRotation`, `ImageOpenness`, their tests. Tune thresholds on the probe
   thumbnails in the scratch folder.
5. **Feed and queue.** `CuratedImageFeed`, `ImageQueue` branch, `switchSource`, `activeStore`, upscaler guard,
   `VisualEngine.setImageSource`. First live macOS run (section 11.3).
6. **Credits and status UI.** `ImageCreditLine`, source-aware `APIStatusRow`, `PlaybackStatus`,
   `ClearImagesSection`, hidden Gemini controls.
7. **visionOS.** Build, simulator run, perf run.
8. **Optional.** `SmithsonianProvider` behind its key; a Met fallback to the Internet Archive mirror
   `metropolitanmuseumofart-gallery` if the bot wall proves frequent.
9. **Docs.** `decisions/images.md` D36 onward (mode, sources, rights rule, people rule, pool size, thresholds as
   measured), `experience.md` (mode and credit table), `architecture.md` (pipeline), `development.md` (flags and
   the verify commands), `CLAUDE.md` and `AGENTS.md` together (repository map, "Images and generation" contract,
   the no-Gemini rule in API mode).

## 11. Verification gates

Every launch below carries an automation flag, so Gemini is blocked. Never pass `-LiminalAllowGeneration YES`.
One Liminal process at a time: wrap every test, launch and perf run in
`/usr/bin/lockf -k <scratchpad>/liminal-test.lock`, and terminate the app afterwards. Nothing is installed on the
physical Vision Pro.

1. **Builds.** `xcodebuild -scheme Liminal -destination 'platform=macOS' -derivedDataPath <scratchpad>/dd-imgapi build`
   and the same for `'platform=visionOS Simulator,name=Apple Vision Pro'` with `dd-imgapi-sim`.
2. **Unit tests.** `-only-testing:LiminalTests/<Suite>` for the suites in section 9 while iterating, then the
   full `LiminalTests` once.
3. **Live macOS run.** Launch the built app with
   `-LiminalAutoPlay YES -LiminalImageSource api -LiminalImageAPIFresh YES -LiminalImageInterval 8 -archive.enabled YES -LiminalVideoOffline YES`.
   Pass when, within 5 minutes, the log shows at least 6 distinct "API image shown" items from at least 3
   sources. Capture with `/opt/homebrew/bin/peekaboo` at four of them, including the control panel with the
   credit line and the toggle, and look at the captures: correct aspect, no stretched or margin-heavy picture,
   film visible in shadows or highlights.
4. **Offline reuse.** Relaunch with `-LiminalImageAPIOffline YES` on the pool from gate 3: pictures keep rotating,
   no network request is logged.
5. **Toggle.** Switch API → AI → API while playing (UI test or `peekaboo` click on `imageSource`): the picture
   changes at the next boundary, AI mode shows cached AI pictures or the test card, no Gemini request.
6. **visionOS Simulator run** (udid `4F6C4C06-AAE6-44DF-8460-070ED1A546E1`):
   `xcrun simctl launch <udid> com.saygoodnight.Liminal -LiminalAutoPlay YES -LiminalOpenDome YES -LiminalImageSource api -LiminalImageInterval 8`.
   Same 6-from-3 log criterion through `simctl spawn <udid> log stream`, screenshots of the dome and of the
   control window with the credit through `simctl io <udid> screenshot`. Simulator depth is zero, so the Backdrop
   key is not judged here.
7. **Lo-Fi perf.** `scripts/perf-run.sh --lofi --extra "-LiminalImageSource api"` passes all its existing checks
   (no ≥100 ms frame, no missed drum or picture change, no repeated phrase, no clock gap, no overload), once
   with a filled pool and network on (ingest running beside the render loop) and once with
   `-LiminalImageAPIOffline YES`. Compare frame times with a plain `--lofi` run taken the same session.
8. **No Gemini.** In every captured log: zero lines from the Gemini client and zero requests to the generation
   host; `visual.generationLedger` in the app's defaults is byte-identical before and after the runs.
9. **Rights audit.** Dump the sidecars from gates 3 and 6: every picture has a title, institution, source URL and
   an allowlisted licence.

## 12. Risks

| Risk | Mitigation |
|---|---|
| A verification run reaches Gemini. | Separate gate, `guard activeSource == .ai` in `requestImage`, every flag in `blocksImageGeneration`, gate 8. |
| Network or decode work disturbs the visionOS 90 fps loop. | All of it in detached tasks, one download and one decode at a time, thumbnail decode capped at 3072, perf gate 7 with ingest live. |
| The Met bot wall or Commons bursts. | Per-host gaps, `.blocked` → 30 min backoff, the provider is skipped, weight 1 source. Archive mirror as step 8. |
| Thresholds reject too much and the pool starves, or accept dull pictures. | Thresholds are data. Log every rejection with its reason and review the reject rate per source after the first 100 ingests. Pinned ids were hand-picked and give a floor of 78 pictures. |
| Portrait plates lose most of their area to the 3:2 crop. | Window search in 4.3 step 6; sources that still crop badly are weighted down or disabled in the JSON. |
| Paper-background plates (fungi, Haeckel) read as documents. | The document gate needs both high `paperShare` and text-like edges or detected text. Checked on the pinned plates in step 4. |
| CC BY-SA photographs (`fungi-photographs`) under live effects. | Creator and licence are shown and logged. The source is one line in the JSON to disable. Recordings published in the README should avoid those pictures or carry the attribution. |
| Provider APIs change (the Met retired `/v1/search` in October). | Parsing is isolated per provider with fixtures; a failing provider backs off and the rest carry on. |
| The second store purges or is purged by the AI cache migration. | Own folder and epoch key, `CuratedImagePoolTests` asserts isolation. |
| First launch in API mode with no network. | Standby art, then a clear status line. Bundling four public-domain pictures with credits as API standby art is a small follow-up if this looks thin. |

## 13. Decisions for the user

These have defaults in the plan and are easy to change later.

1. **People.** Default rejects pictures with a prominent face and keeps distant figures. Stricter (no faces at
   all) or looser are one threshold away.
2. **CC BY-SA fungi photographs.** Enabled with attribution. Disable for a strictly PD / CC0 pool.
3. **Pool budget.** 3 GB, least recently shown removed only past it and re-fetchable. Raise it rather than cap.
4. **Monochrome.** At most 1 in 6, from one source. Set to zero for colour only.

## Outcome (2026-11-21)

Built and merged-ready on `image-api-mode`. Rationale and measurements: `docs/decisions/images.md` D36-D43.

- **Shipped:** the AI | API picker (Settings key, macOS and visionOS controls), five keyless providers (Library of
  Congress, NASA, Wikimedia Commons, Cleveland, the Met; Smithsonian only with `SMITHSONIAN_API_KEY`), 13 curated
  sources in `image-collections.json` including Landsat Earth as Art, the pool with its own 3 GB budget, the
  openness gates, and the credit line in the controls.
- **Results:** 522 unit tests passed; live macOS and visionOS Simulator runs stored pictures from all 12 enabled
  sources with 0 Gemini requests. Lo-Fi perf with live ingest passes (max frame 46-59 ms vs 53 ms for AI in the
  simulator) after moving ingest and ledger writes off the render loop and storing at 2528 px.
- **Changed from the plan:** see the status note above, plus D42 (switch serialisation, simulator Vision checks
  compiled out) and D43 (attribution needs a creator, ledger ordering, clear during ingest, reservation expiry,
  cancellation, 150 MP decode limit).
- **Open:** the picker was driven by `-LiminalImageSourceFlipAt` and a unit test rather than a click (locked
  screen); Vision text and face checks are unverified on a Vision Pro; device frame times are unverified; weak
  spots are paper margins on plates, id-only NASA titles, long Commons creator lines and little true 1960s
  psychedelic poster art (LoC rock posters are 1024 px or smaller). The four user decisions in section 13 stay at
  their defaults.
