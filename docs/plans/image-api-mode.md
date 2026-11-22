# Curated pictures: pipeline plan and record

> **Status (2026-11-21): implemented.** What changed from this plan while building, with measurements, is in
> `docs/decisions/images.md` D36-D48: no upper key-share gate (it rejected the night neon and nebulae), monochrome
> at saturation < 0.025, text rejects only paper-like pictures or text over a quarter of the frame, size gate
> 2000 x 1333, NASA originals over 12 MB rejected (`~large` is 1920 px), the Smithsonian key read from the
> environment only, and the "picture shown" ledger write moved off the main actor. The file keeps its name
> because code comments cite its section numbers.

Pictures are curated public-domain and openly licensed imagery fetched from library, museum and space-agency
APIs: roadside neon, 1970s Kodachrome, Apollo-era Earth views, photochroms, fungi, woodblock landscapes. They are
the only picture source.

Research this plan rests on: `docs/research/visuals/image-apis/survey.md` (which APIs work, keys, resolution, rights),
`collections.md` (the curated sources, measured sizes, rejections) and `openpics.md` (the user's earlier
OpenPics app). The approved source list is `Liminal/Visual/ImageSources/image-collections.json`.

Decisions taken while building go in `docs/decisions/images.md`, starting at **D36**. Numbers marked *(tune)*
are starting points.

## 0. Findings that shape the design

| Finding | Consequence |
|---|---|
| Every picture enters through `ImageQueue`, and everything after it (buffer, Lo-Fi reserve, 3:2 crop, saliency, depth, footage) ignores where the picture came from. | The feed is one loop inside `ImageQueue` that produces `DisplayItem`s. No renderer, shader, uniform or Lo-Fi scheduling change. |
| Lo-Fi reserves a picture 6 s before a build and drops it if it is not ready 2 s before. Only local data makes that deadline. | The display side reads only from disk. The network only ever adds to the disk pool. |
| `ImageStore` takes its folder and epoch key as parameters. | The pool is an `ImageStore` with its own folder, epoch key and no count cap. |
| Footage shows in the picture's shadows (`luma < 0.3` on at least 18% of a 16x16 thumbnail), or in its highlights otherwise, and is tinted from the picture's colours. Grey pictures give grey film and cannot be recoloured by the shader. | Score "openness" at ingest with the same thresholds, keep colour sources the majority, and cap monochrome pictures in the rotation. |
| Every enabled provider is keyless (LOC, NASA, Wikimedia Commons, Cleveland, the Met, Digital Commonwealth, the Art Institute of Chicago). Commons fails in bursts, the Met has a bot wall after about 100 rapid requests, LOC only reaches 2K through IIIF. | One paced HTTPS client with per-host gaps and a per-provider backoff ladder. A blocked provider is skipped, never fatal. |
| The app is sandboxed with outgoing network on and has no ATS exceptions. | HTTPS only. NASA asset URLs are rewritten from `http` to `https`. |

## 1. Behaviour

- **No picture settings.** There is nothing to choose; the control panel shows the credit of the picture on
  screen, the pool count and the status of the collections.
- **Fallback ladder:** pictures waiting in the queue, then the pool on disk, then the bundled standby art. If every
  provider fails, the pool keeps rotating and the status row says so.
- **Credits.** The picture on screen shows title, creator, date, institution, licence and a source link next to
  the film credit. Every ingest and every display is logged with the same fields.

## 2. Settings

The pipeline has no persistent settings of its own. Its tuning lives in the `defaults` of
`image-collections.json` (section 3.2), and its automation flags are in section 8.

## 3. Provider layer

New folder `Liminal/Visual/ImageSources/` (file-system synchronized, no project edits).

### 3.1 Files and types

| File | Contents |
|---|---|
| `ImageCollections.swift` | `Codable` model of `image-collections.json`: `ImageCollections` (defaults, providers, `licenseAllowlist`, `sources`) and `CuratedSource` (id, provider, enabled, weight, themes, queries / categories / searches, pinned, reject words, `requireIIIF`, `requiresKey`). `ImageCollections.bundled` loads the bundled JSON once. |
| `ImageSourceCredit.swift` | `nonisolated struct ImageSourceCredit: Codable, Sendable, Equatable` (providerID, sourceID, itemID, title, creator, date, institution, license, licenseURL, sourceURL, imageURL), plus `displayLine` and `requiresAttribution`. |
| `ImageCandidate.swift` | `ImageCandidate` (key `provider:itemID`, title, creator, date, declared width/height/mime/bytes when known, rights text, page URL, image URL or resolver hint) and `ResolvedImage` (final HTTPS URL, expected size, credit). |
| `ImageHTTP.swift` | `actor ImageHTTP`: one ephemeral `URLSession`, User-Agent from the JSON defaults, no `URLCache`, `allowsConstrainedNetworkAccess = false`, per-host minimum gap (1 s default, 5 s for `collectionapi.metmuseum.org` and `images.metmuseum.org`), `json(_:)` and `download(_:to:maxBytes:)` (temp file then move, abort past `maxBytes`), typed `ImageFetchError` (`offline`, `http(status)`, `blocked`, `tooLarge`, `badContent`). An HTML body on a JSON or image request maps to `.blocked`. |
| `ImageProvider.swift` | `protocol ImageProvider: Sendable` with `id`, `candidates(source:query:page:http:) async throws -> [ImageCandidate]`, `pinned(source:ids:http:)`, `resolve(_:http:) async throws -> ResolvedImage`. `ImageProviders.all(environment:)` returns the providers whose key requirement is met. |
| `Providers/LOCProvider.swift` | Collection search JSON; IIIF service id from the result's `image_url`; one `info.json` call for the true size; image `{service}/full/{w},/0/default.jpg`; rights must equal "No known restrictions on publication". Uses `LooseString` for the mixed string / array fields. |
| `Providers/NASAProvider.swift` | `/search` with year window, `/asset/<id>` for `~orig` and `~large`; `~orig` unless a `HEAD` shows more than `maxBytes`, then `~large`; `http` rewritten to `https`. Credit from `center`, `photographer`, `secondary_creator`. |
| `Providers/WikimediaProvider.swift` | `generator=categorymembers` and `generator=search` with `prop=imageinfo`; mime allowlist (JPEG, PNG); licence from `extmetadata.LicenseShortName` against the allowlist; `Artist` and `Credit` stripped of HTML; scaled URL from `thumburl`. |
| `Providers/ClevelandProvider.swift` | `/api/artworks` with `type`, `has_image=1`, `cc0=1`; `images.print.url`; `share_license_status == "CC0"`. |
| `Providers/MetProvider.swift` | v1.1 search for object ids, then `/v1/objects/<id>`; `isPublicDomain` checked per object; `primaryImage`; classification allowlist. |
| `Providers/DigitalCommonwealthProvider.swift`, `Providers/ArticProvider.swift` | Added with the wider rotation (D45). |
| `Providers/SmithsonianProvider.swift` | Optional. Only registered when `SMITHSONIAN_API_KEY` is in the process environment. The source stays `enabled: false` in the JSON until its media resolution is measured. |
| `ImageRotation.swift` | Pure rotation logic, section 4. |
| `ImageOpenness.swift` | Pure scoring, section 6. |
| `ImageRights.swift` | `ImageRights.verdict(provider:rightsText:allowlist:) -> .allowed(license) / .rejected(reason)`. Normalises spellings ("PD-US", "Public domain", "CC BY-SA 4.0"). Unknown or empty is rejected. |
| `ImageIdentity.swift` | Catalogue aliases and the perceptual fingerprint that catch the same picture under two ids (D48). |
| `CuratedImagePool.swift` | The on-disk pool, section 5. |
| `CuratedImageFeed.swift` | The ingest pipeline and the display pick, section 4.3. |
| `Liminal/ImageCreditControls.swift` | `ImageCreditLine` and `CollectionsStatusRow`, shared SwiftUI, section 7. |

Each provider keeps its parsing in `static` pure functions that take `Data` and return candidates
(`LOCProvider.parseSearch(_:)`, `parseInfo(_:)`, and so on), so the tests run on saved JSON with no network.

Providers are `nonisolated` value types. `ImageHTTP` is an actor, as `ArchiveClient` is, and is only awaited from
the feed's detached tasks, never from the render path or the main actor.

### 3.2 `image-collections.json`

- Per source: id, provider, `enabled`, `weight`, themes, queries or categories, pinned ids, reject words and
  `allowMonochrome` (true only where monochrome is the subject). There is no per-source mood data.
- `defaults`: size gates (`minLongSide` 2000, `minShortSide` 1333), `targetLongSide` 2528, `maxBytes` 12 MB,
  the `openness` thresholds (section 6), `storeBudgetBytes` (3 GB), `minFreeBytes` (1 GB), `unseenAhead` (36),
  `ingestInterval` (4 s), `recencyWindow` (24), `monochromeEvery` (6), `candidateRefreshDays` (7) and the host
  gaps.

## 4. Rotation and the feed

### 4.1 Two separate choices

1. **Ingest rotation:** which source the next download comes from.
2. **Display rotation:** which stored picture is shown next.

Keeping them apart means the display never waits on the network, offline reuse is the same code path as online,
and a slow provider cannot skew what is shown.

### 4.2 `ImageRotation` (pure, seeded, unit tested)

- `nextSource(sources:history:available:rng:)`: a bag holding each enabled source `weight` times, reshuffled when
  empty. Rules: never the same source twice in a row while another is available; never the same provider three
  times in a row; sources in backoff or without unseen candidates are skipped.
- `nextCandidate(source:candidates:ledger:rng:)`: pinned ids first, shuffled, then search results; anything
  already in the ledger (stored or rejected) is skipped.
- `nextDisplay`: while any never-shown picture is a candidate, only never-shown pictures are drawn, weighted by
  source weight x (0.5 + openness); with nothing new, the pick is from the least recently shown quarter and never
  within the recency window when anything older exists (D48). Hard rules: not the picture on screen, not the same
  source as the previous picture when the pool holds three or more sources, at most 1 monochrome picture in any 6.
- `-LiminalImageAPISeed <n>` seeds the generator for repeatable runs.

### 4.3 `CuratedImageFeed`

`nonisolated final class CuratedImageFeed: Sendable`, owned by `ImageQueue`.

**Display side** (`ImageQueue`'s feed loop): every second, while fewer than `pendingTarget` pictures are waiting,
`nextDisplay` -> `store.loadImage` -> `enqueue`. With an empty pool it sets the status "Fetching the first
pictures..." and waits; the Lo-Fi path shows the standby art meanwhile.

**Ingest loop:** runs while the pool holds fewer than `unseenAhead` pictures that have never been shown, the
network is allowed and not every provider is in backoff. One picture at a time:

1. `nextSource`, then `nextCandidate`. When a source has no unseen candidates, fetch its next search page
   (cursor kept per query in the ledger) and try again.
2. `provider.resolve` -> `ResolvedImage`. Pre-download gates on declared metadata: rights verdict, mime, declared
   size, bytes at most `maxBytes` (12 MB), title reject words, catalogue aliases of a stored picture.
3. `ImageHTTP.download` to a temp file.
4. Decode with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize` from the target size,
   transform applied), so a large master never expands fully in memory.
5. `BorderTrimmer.trimmedIfBordered` for scan margins (and `ScanEdgeTrimmer` for slide scans, D44).
6. **Framing.** If the aspect is within 1.3 to 1.8, keep it and let the renderers' cover crop do the rest. Outside
   that (portrait plates, square Hasselblad frames), choose the 3:2 window along the long axis with the best
   openness score from five candidate offsets and cut it with `ImageFraming.crop(normalized:)`. The stored file is
   then already 3:2, so every downstream `coverCrop` is the identity and saliency and depth stay registered.
7. Post-decode gates: real pixel size after crop, openness and document checks (section 6), face check, duplicate
   fingerprint.
8. `SaturationMeter.meanSaturation`, then build `ImageMetadata` (id, createdAt, size, mime, measured saturation,
   `source` credit, `openness`).
9. Encode JPEG at quality 0.9 and save to the pool. Record the candidate key in the ledger as stored, or as
   rejected with its reason, so nothing is downloaded twice.
10. Log one line: source, item, size, openness, licence, URL.

**Pace.** At most one download every 4 s on top of the per-host gaps. Cold start goes pinned-first, which needs
no search call, so the first picture lands in a few seconds. Steady state fetches roughly one new picture per
picture shown.

**Failures.** A provider error puts that provider on the ladder 1 / 2 / 5 / 15 / 30 min (as `ArchiveCatalog`);
401 / 403 / 404 / 410 on one item marks only that item rejected. `.blocked` (the Met's bot wall) goes straight to
30 min. With everything in backoff or offline, ingest sleeps and display keeps rotating the pool.

### 4.4 `ImageQueue`

- `start()`: after the DEBUG fixed-image branches, starts the feed loop. `loadInitialImage` shows one picture from
  the pool picked by `nextDisplay`, else nothing (the standby art covers the first Lo-Fi reveal).
- `reserveForFill(excluding:)` and `showReserved` hand the prefetched picture to the Lo-Fi transport at the drum
  boundary.
- Pictures are never enlarged; a picture is shown at the size it was stored.

## 5. The pool on disk

### 5.1 Layout

`Application Support/Liminal/CuratedImageStore/`, excluded from backup:

- `<uuid>.jpg` and `<uuid>.json` (the `ImageStore` sidecar: id, createdAt, pixelWidth, pixelHeight, mimeType,
  measuredSaturation, `source` credit and `openness`).
- `ledger.json`: candidate keys seen (`stored` with uuid, or `rejected` with reason and date), per-query page
  cursors, per-picture `lastShown` and `showCount`, cached candidate lists with a fetch date (refreshed after
  7 days), catalogue aliases and fingerprints.
- `tmp/`: downloads in progress.

### 5.2 Code

- `ImageStore.init(root:defaults:directoryName:epochKey:epoch:)`. The pool uses `"CuratedImageStore"` and
  `"images.api.cacheEpoch"`, and has no count cap.
- `CuratedImagePool` (`nonisolated final class`, `Mutex` state): loads sidecars once into memory, keeps the
  ledger, answers `nextDisplay` inputs, `markShown`, `usage()`. Policy decisions are pure static functions
  (the launch sweep, `evictions(items:shown:budget:keep:)`) so they are unit tested, as `ArchiveCachePolicy` is.

### 5.3 Size, and why

- Stored pictures are JPEG, long side about 2528, about 1 to 2.5 MB each.
- **Budget 3 GB** (`defaults.storeBudgetBytes`), about 1,200 to 2,500 pictures. That is larger than the pictures
  an evening shows (about 150 an hour) by an order of magnitude, and the same size as the film cache.
- **Nothing is ever made unplayable** (A31, and the user's "no playback limits" rule). There is no count cap, no
  age cap and no per-source cap. Only when the pool passes the budget and a new picture has just been saved is
  the least recently shown picture removed, and its ledger entry is cleared so it can be fetched again. If the
  volume has under 1 GB free, ingest pauses and display continues.
- **Launch cleanup removes junk only:** image files with no sidecar, sidecars with no image, files that fail the
  `<UUID>.jpg` pattern, and anything in `tmp/` older than an hour.
- "Clear Curated Pictures" clears this pool and its ledger.

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

Starting gates *(tuned against the probe thumbnails and the first live ingests, as shipped in D38)*:

- reject `openness < 0.2` and `keyShare < 0.04` (nowhere for the film); there is no upper key-share gate, because
  the shader's `keyGain` already tames a key that covers most of the frame (D38);
- reject a document: `paperShare > 0.5` and `edgeDensity > 0.06`, or Vision text boxes covering more than a
  quarter of the frame (6% of a paper-like picture);
- reject monochrome (mean saturation < 0.025) unless the source sets `allowMonochrome`.

Thresholds live in the JSON defaults, so tuning needs no code change. The score is stored in the sidecar and
feeds the display weight, so more open pictures appear more often rather than only passing a gate.

### 6.2 People

Archival sources include people, and the brief asks for 1950s driving and
cityscapes, where small distant figures are part of the scene. Default policy: run
`VNDetectFaceRectanglesRequest` at ingest and reject a picture when any face box exceeds 1.5% of the frame or
more than four faces are found *(tune)*. Source-level `rejectTitleWords` already removes portraits by title.

Both Vision requests run once per picture, off the main actor, inside the ingest task. If Vision fails (possible
in the simulator), the check passes and the failure is logged.

## 7. UI and credits

- **Control panel.** `ImageCreditLine` shows title, creator, date, institution and licence with a `Link` to the
  source page, when the picture on screen has a credit; creator and licence are always shown, which covers CC BY
  and CC BY-SA. `CollectionsStatusRow` reads "Curated collections: N of M sources online", "Offline, showing saved
  pictures" or "Fetching the first pictures...". Both live in `Liminal/ImageCreditControls.swift` and sit in the
  Images & Storage section on both platforms. `PlaybackStatus` counts the pool, and "Clear Curated Pictures"
  clears it.
- **Logs:** `LMLog.visual.info("API image shown: source=... item=... title=... creator=... license=... url=...")`
  when a picture becomes current, and the ingest line from 4.3. Both are stable strings the verify scripts grep.
- **Docs credit table:** `docs/experience.md` has a table of sources (collection, institution, licence, link)
  beside the film table.

## 8. Debug flags

All in `DebugLaunchOptions.swift` (DEBUG value, Release stub, `logOnce` line), all counted as automation flags,
all in the flag table in `docs/development.md`.

| Flag | Effect |
|---|---|
| `-LiminalImageProvider <id[,id]>` | Restrict ingest and display to these provider ids or source ids. |
| `-LiminalImageAPIOffline YES` | Pool only, no network. |
| `-LiminalImageAPISeed <n>` | Seeds both rotations. |
| `-LiminalImageAPIFresh YES` | Uses an empty `CuratedImageStore-Verify` folder, so a run proves fetching works and leaves the user's pool alone. The folder is removed at the next normal launch as junk. |

## 9. Tests (Swift Testing)

Fixtures are small JSON files trimmed from the saved probe responses, in `LiminalTests/Fixtures/ImageAPI/`,
loaded relative to `#filePath` as other suites do. No test touches the network.

| Suite | Covers |
|---|---|
| `LiminalTests/CuratedImageTests.swift` | the bundled JSON decodes and every enabled source has a known provider and a weight > 0; every URL template is HTTPS; provider parsing from saved fixtures (LOC search + `info.json`, NASA search + asset, Commons, Cleveland, Met, Digital Commonwealth, AIC); rights spellings and rejections; rotation shares, no source twice in a row, backoff, ledger skips, the monochrome cap; openness on synthetic images; the pool (separate folder and epoch, sidecar round-trip, an old sidecar still decodes, sweep removes only orphans and stale temp files, eviction only over budget); the queue's feed loop. |
| `LiminalTests/ImageRepeatTests.swift` | new pictures before repeats, offline cycling, catalogue aliases, fingerprints, backfill (D48). |
| `LiminalTests/ImagePipelineTests.swift` | the Lo-Fi image reveal, `ImageStore`, the border trimmer and the saturation meter. |

## 10. Step order

Each step built on macOS and was committed.

1. **Metadata and store.** `ImageSourceCredit`, optional `ImageMetadata.source` and openness fields, `ImageStore`
   parameters, `CuratedImagePool` with ledger, sweep and budget.
2. **Collections model and providers.** `ImageCollections`, `ImageHTTP`, the keyless providers with fixtures.
   Each endpoint was re-probed once with `curl` while trimming fixtures, to settle the largest rendition each
   provider serves.
3. **Rotation and openness.** `ImageRotation`, `ImageOpenness`, their tests, tuned on the probe thumbnails.
4. **Feed and queue.** `CuratedImageFeed`, the `ImageQueue` loop. First live macOS run (section 11.3).
5. **Credits and status UI.** `ImageCreditLine`, `CollectionsStatusRow`, `PlaybackStatus`, `ClearImagesSection`.
6. **visionOS.** Build, simulator run, perf run.
7. **Optional.** `SmithsonianProvider` behind its key.
8. **Docs.** `decisions/images.md` D36 onward, `experience.md` (credit table), `architecture.md` (pipeline),
   `development.md` (flags and the verify commands), `CLAUDE.md` and `AGENTS.md` together.

## 11. Verification gates

Image fetching uses the free public APIs and spends nothing. One Liminal process at a time, and terminate the app
afterwards. Nothing is installed on the physical Vision Pro.

1. **Builds.** `xcodebuild -scheme Liminal -destination 'platform=macOS' build` and the same for
   `'platform=visionOS Simulator,name=Apple Vision Pro'`.
2. **Unit tests.** `-only-testing:LiminalTests/<Suite>` for the suites in section 9 while iterating, then the
   full `LiminalTests` once.
3. **Live macOS run.** Launch the built app with
   `-LiminalAutoPlay YES -LiminalImageAPIFresh YES -archive.enabled YES -LiminalVideoOffline YES`.
   Pass when, within 5 minutes, the log shows at least 6 distinct "API image shown" items from at least 3
   sources. Capture with `/opt/homebrew/bin/peekaboo` at four of them, including the control panel with the
   credit line, and look at the captures: correct aspect, no stretched or margin-heavy picture, film visible in
   shadows or highlights.
4. **Offline reuse.** Relaunch with `-LiminalImageAPIOffline YES` on the pool from gate 3: pictures keep rotating,
   no network request is logged.
5. **visionOS Simulator run** (`xcrun simctl launch <udid> com.saygoodnight.Liminal -LiminalAutoPlay YES -LiminalOpenDome YES`).
   Same 6-from-3 log criterion through `simctl spawn <udid> log stream`, screenshots of the dome and of the
   control window with the credit through `simctl io <udid> screenshot`. Simulator depth is zero, so the Backdrop
   key is not judged here.
6. **Lo-Fi perf.** `scripts/perf-run.sh` passes all its checks (no >= 100 ms frame, no missed drum or picture
   change, no repeated phrase, no clock gap, no overload), once with a filled pool and network on (ingest running
   beside the render loop) and once with `-LiminalImageAPIOffline YES`.
7. **Rights audit.** Dump the sidecars from gates 3 and 5: every picture has a title, institution, source URL and
   an allowlisted licence.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Network or decode work disturbs the visionOS 90 fps loop. | All of it in detached tasks, one download and one decode at a time, thumbnail decode bounded, perf gate 6 with ingest live. |
| The Met bot wall or Commons bursts. | Per-host gaps, `.blocked` -> 30 min backoff, the provider is skipped, weight 1 source. |
| Thresholds reject too much and the pool starves, or accept dull pictures. | Thresholds are data. Log every rejection with its reason and review the reject rate per source. Pinned ids were hand-picked and give a floor. |
| Portrait plates lose most of their area to the 3:2 crop. | Window search in 4.3 step 6; sources that still crop badly are weighted down or disabled in the JSON. |
| Paper-background plates (fungi, Haeckel) read as documents. | The document gate needs both high `paperShare` and text-like edges or detected text. |
| CC BY-SA photographs (`fungi-photographs`) under live effects. | Creator and licence are shown and logged. The source is one line in the JSON to disable. Recordings published in the README should avoid those pictures or carry the attribution. |
| Provider APIs change (the Met retired `/v1/search` in October). | Parsing is isolated per provider with fixtures; a failing provider backs off and the rest carry on. |
| First launch with no network. | Standby art, then a clear status line. |

## 13. Decisions for the user

These have defaults in the plan and are easy to change later.

1. **People.** Default rejects pictures with a prominent face and keeps distant figures. Stricter (no faces at
   all) or looser are one threshold away.
2. **CC BY-SA fungi photographs.** Enabled with attribution. Disable for a strictly PD / CC0 pool.
3. **Pool budget.** 3 GB, least recently shown removed only past it and re-fetchable. Raise it rather than cap.
4. **Monochrome.** At most 1 in 6. Set to zero for colour only.

## Outcome (2026-11-21)

Rationale and measurements: `docs/decisions/images.md` D36-D48.

- **Shipped:** keyless providers (Library of Congress, NASA, Wikimedia Commons, Cleveland, the Met, Digital
  Commonwealth, the Art Institute of Chicago; Smithsonian only with `SMITHSONIAN_API_KEY`), 43 enabled curated
  sources in `image-collections.json`, the pool with its own 3 GB budget, the openness gates, the no-repeat
  rotation and the credit line in the controls.
- **Changed from the plan:** see the status note above, plus D42 (simulator Vision checks compiled out) and D43
  (attribution needs a creator, ledger ordering, clear during ingest, reservation expiry, cancellation, 150 MP
  decode limit).
- **Open:** Vision text and face checks are unverified on a Vision Pro; device frame times are unverified; weak
  spots are paper margins on plates, id-only NASA titles, long Commons creator lines and little true 1960s
  psychedelic poster art (LoC rock posters are 1024 px or smaller). The four user decisions in section 13 stay at
  their defaults.
