# The image pipeline, end to end

[← Image sources](README.md) · [Sources](sources.md) · [Providers](providers.md) · [Adding a source](adding-a-source.md) · [Research history](research-history.md)

This page follows one picture from an institution's API to the screen and back into the rotation. Types are named rather than cited by line. Numbers are the shipped defaults in `image-collections.json` (`defaults`) or constants in the code, as of 2026-11-21. Rationale and measurements are in [`decisions/images.md`](../decisions/images.md) D36-D45 and D48.

The pipeline has two halves that never wait on each other:

- **Ingest** (`CuratedImageFeed`, background task) fetches one picture at a time and stores it in the pool on disk. It runs only while fewer than `unseenAhead` (36) never-shown pictures are waiting.
- **Display** (`CuratedImageFeed.nextDisplay`, called by `ImageQueue`) picks the next stored picture. It reads only from disk.

Contents:

1. [Which source is next](#1-which-source-is-next)
2. [Which candidate is next: pins, search pages and the ledger](#2-which-candidate-is-next-pins-search-pages-and-the-ledger)
3. [Resolve: URL, size, rights and credit](#3-resolve-url-size-rights-and-credit)
4. [The pre-download gate](#4-the-pre-download-gate)
5. [Download](#5-download)
6. [Failures, rejections and backoff](#6-failures-rejections-and-backoff)
7. [Decode](#7-decode)
8. [Trimming: ScanEdgeTrimmer and BorderTrimmer](#8-trimming-scanedgetrimmer-and-bordertrimmer)
9. [3:2 framing](#9-32-framing)
10. [The gates: size, openness, document, monochrome, text, faces](#10-the-gates-size-openness-document-monochrome-text-faces)
11. [Storing: colour and the sidecar](#11-storing-colour-and-the-sidecar)
12. [The pool on disk](#12-the-pool-on-disk)
13. [Display rotation](#13-display-rotation)
14. [How pictures reach the screen, and Lo-Fi timing](#14-how-pictures-reach-the-screen-and-lo-fi-timing)
15. [Credits](#15-credits)
16. [Network use in test runs](#16-network-use-in-test-runs)
17. [Concurrency: what runs where](#17-concurrency-what-runs-where)
18. [Log lines](#18-log-lines)
19. [Debug flags and verification](#19-debug-flags-and-verification)

## 0. Startup

- `ImageQueue` builds its `CuratedImageFeed` at init.
- The feed loads `ImageCollections.bundled` from `image-collections.json`. If the file is missing or fails to decode, the feed logs an error and uses an empty list, and the app then shows only the standby art.
- `ImageProviders.all()` registers every keyless provider (`loc`, `nasa`, `wikimedia`, `cma`, `met`, `dc`, `aic`). It adds `si` only when `SMITHSONIAN_API_KEY` is set in the environment.
- The active sources are those with `enabled: true`, `weight > 0` and a registered provider. `-LiminalImageProvider <ids>` narrows them further: each id may be a provider id or a source id.
- One seed drives two random generators. The ingest generator uses the seed, and the display generator uses the seed plus `0x5EED`. The seed is `-LiminalImageAPISeed <n>` when given, otherwise random.

Log: `🖼️ [API] feed: 33 sources (loc-highsmith-roadside,…), offline=false`.

## 1. Which source is next

`ImageRotation.nextSource` draws from a **weighted bag** (`SourceBag`):

- Each usable source goes into the bag `round(weight)` times, at least once. The bag is shuffled, drawn without replacement, and refilled when it is empty or nothing in it is acceptable.
- Never the same source twice in a row while another source is usable.
- Never the same provider three times in a row while another provider is usable.
- A source is unusable while its provider is backing off, or while the source is "dry" (it had nothing new to try within the last 30 minutes).
- When only one source or provider is left, the rules give way.

The ingest loop (`CuratedImageFeed.ingestLoop`) runs on a detached background-priority task and repeats these steps:

| Condition | What happens |
|---|---|
| `-LiminalImageAPIOffline YES` | Ingest stops: `ingest off (-LiminalImageAPIOffline)` |
| At least `unseenAhead` (36) never-shown pictures in the pool | Sleep 5 s and check again |
| Less than `minFreeBytes` (1 GB) free on the volume | Sleep 60 s: `ingest paused: N bytes free` |
| No usable source | Sleep 10 s |
| Otherwise | Fetch one candidate from the next source, then sleep `ingestInterval` (4 s) |

Before the first step, `CuratedImagePool.backfillFingerprints` fingerprints any pool picture stored before D48 and removes the later copy of a picture found twice (section 12). It also runs under `-LiminalImageAPIOffline`.

So the network only ever adds to the pool on disk, at most one download every 4 seconds plus the per-host gaps, and the pool stops growing once 36 unseen pictures are waiting. Measured 2026-11-21 on macOS: about one stored picture every 6 s while it fills, against one shown every 28 s in Lo-Fi, so new pictures arrive four to five times faster than they are shown. 36 waiting pictures cover about 17 minutes of Lo-Fi without network (D48).

## 2. Which candidate is next: pins, search pages and the ledger

`CuratedImageFeed.nextCandidate` looks for an item that the ledger has never seen. A **candidate key** is `provider:itemID` (for example `loc:2013631471` or `wikimedia:File:SUNSET - NARA - 544071.jpg`). Every key the ledger records is skipped, whether it was stored or rejected. Nothing is downloaded twice, and a rejected item is never retried.

**The same picture under another id** (`ImageIdentity`, D48). A candidate is also skipped when one of its catalogue aliases belongs to a stored picture. Aliases start with `~` so they never collide with a key:

| Provider | Aliases |
|---|---|
| `loc` | `~lccn:<id>` when the item id is an LCCN (8-12 digits) |
| `nasa` | `~nasa:<ID>` (upper case), plus any NASA frame number in the id |
| `wikimedia` | `~commons:<title>` (underscores as spaces, lower case); `~lccn:<n>` from `LCCN<n>` in the title (Commons copies of LoC scans); `~nara:<n>` from `NARA - <n>` (DOCUMERICA prints uploaded twice); NASA frame numbers (`AS08-14-2383`, `S65-34661`, `SL4-…`, `ISS…-E-…`, `PIA12345`, `GPN-…`) |

Aliases of rejected candidates are not recorded, so a copy of a picture rejected elsewhere (for example too small on Commons) can still come from its own institution. A copy that no catalogue number links is caught after decode by the fingerprint gate (section 11).

1. **Pins first.** The first time a source with `pinned` ids is used, `provider.pinned` is called. Most providers return stubs that `resolve` looks up later; Commons fetches the pinned files 50 titles per request. The list is cached in the ledger under `<sourceID>|pinned`, and a random unseen pin is taken.
2. **Then searches**, in a fresh shuffled order each time. A source's searches (`CuratedSource.allQueries`) are its `queries`, then its `searches` (Commons free text), then its `categories` (Commons). For each one:
   - If the ledger has a cached page for `<sourceID>|<queryKey>`, its first unseen candidate is taken.
   - Otherwise the cursor decides. No cursor means start at the first page; an empty cursor (`""`) means the search has no more pages, so it is skipped. The next page is fetched with 20 results per page (`CuratedImageFeed.perPage`). Its unseen candidates are cached and the cursor advances.
   - The query key is stable: `q:<text>|<type>|<department>|<yearStart>|<yearEnd>` or `cat:<category>`.
3. **Nothing left.** The source is marked dry for 30 minutes: `<source>: nothing new to try for now`. If its oldest cached page is more than `candidateRefreshDays` (7) days old, its cursors and cached pages are reset so the searches start again from page 1 and pick up new uploads.

Cursors differ by provider: a page number (LoC, NASA, Digital Commonwealth, AIC), an offset (Cleveland, the Met, Smithsonian), or a Commons continue token. See [providers.md](providers.md).

## 3. Resolve: URL, size, rights and credit

`provider.resolve(candidate, source:, context:, http:)` returns a `ResolvedImage`: the final image URL, the declared width, height, bytes and MIME type when the provider knows them, the credit, and an optional `fallbackURL`. The `ResolveContext` gives:

- `targetLongSide`: 2528 (2K at 3:2). For `trimScanEdges` sources it is 3413 (`CuratedImageFeed.scanFetchTarget`, 1.35 x 2528), which leaves room for up to 15% rebate on each side.
- `maxBytes`: 12,000,000.
- The institution name from the provider block in the JSON, and the licence allowlist.

Each provider fills in the candidate where the search result was thin. LoC reads `/item/<id>/?fo=json` and `info.json`, NASA reads `/asset/<id>`, the Met reads the object record, and Cleveland, Digital Commonwealth and AIC read the artwork or record. The provider then builds the URL of the largest useful file ([providers.md](providers.md) gives the route for each). Finally it calls the shared `credit(for:)` check in `ImageProvider`:

1. **Rights.** `ImageRights.verdict(rightsText:allowlist:)` canonicalises the record's own rights text, then compares it with `licenseAllowlist`:

   | Allowed label | Accepted texts (case-insensitive) |
   |---|---|
   | Public domain | `PD`, `PD-…`, `public domain…`, `Public Domain Mark`, `PDM`, `US government work…` |
   | CC0 | `CC0`, `CC-zero`, `Creative Commons Zero` |
   | No known restrictions | `No known restrictions…` |
   | No restrictions | `no restrictions` (exactly) |
   | CC BY x.y, CC BY-SA x.y | versions 2.0, 2.5, 3.0 and 4.0, written with spaces or hyphens; a port suffix such as `de` is dropped |

   Anything containing NC, ND, "noncommercial", "noderiv", "not evaluated" or "restricted" is rejected, as is empty or unknown text. Rejection reasons: `no rights statement`, `rights not allowed: …`, `licence not on the allowlist: …`.
2. **Title.** An empty title is rejected (`no title`). `rejectTitleWords` reject whole words only, case-insensitively, so "man" does not reject "Manhattan". `requireTitleContains` must appear in the title or in the item id (a Commons file name). Reason: `title rejected: …`.
3. **Attribution.** A CC BY or CC BY-SA picture whose record names no creator is rejected (`CC BY-SA 3.0 without a creator to credit`), because its credit could not meet the licence (D43).

## 4. The pre-download gate

`CuratedImageFeed.preDownloadGate` checks what the provider declared, before any download:

- The MIME type must be in `allowedMime` (`image/jpeg`, `image/png`).
- The byte size must be at most `maxBytes` (12 MB).
- The 3:2 cover crop of the declared size must be at least `minLongSide` x `minShortSide`, **2000 x 1333**, with 1 px of slack. That is 2% under 2048 x 1365, so plates just over 2000 px pass, and the difference cannot be seen under the effects.

Providers that declare sizes (Commons, Cleveland, LoC through IIIF, Digital Commonwealth, AIC) are gated here. The others (NASA, the Met) are checked after decode. NASA additionally sends a HEAD request inside `resolve` and rejects an original over 12 MB.

## 5. Download

`ImageHTTP` is the only HTTPS client of the pipeline. It is an actor:

- An ephemeral `URLSession` with no URL cache, one connection per host, a 30 s request timeout and a 180 s resource timeout. It never downloads in Low Data Mode (`allowsConstrainedNetworkAccess = false`).
- The User-Agent is `Liminal/1.0 (lo-fi audiovisual app; curated public-domain imagery)`, with no personal data.
- It fetches only https URLs (`ImageHTTP.secure` upgrades `http://` and `//` links, such as NASA's). Anything else fails with `insecureURL`.
- **Per-host gaps.** At least `defaultHostGap` (1 s) passes between requests to the same host. `hostGaps` sets 5 s for `collectionapi.metmuseum.org` and `images.metmuseum.org`, and 2 s for `api.artic.edu` and `www.artic.edu`.
- **Offline.** Under `-LiminalImageAPIOffline` every request fails with `.offline` before touching the network. The URL errors for no connection, lost connection, data not allowed and host not found also map to `.offline`.
- **Bot walls.** A 403 or 429 that answers with HTML, or HTML where JSON or an image was expected, becomes `.blocked`.
- **Size.** The file goes to `CuratedImageStore/tmp/<uuid>.download`. A file over `maxBytes` (`tooLarge`) or an empty one (`badContent`) is refused after the download completes. A streaming cap would need a delegate-based download (D43). The temp file is always removed.
- **fallbackURL.** When the download answers HTTP 5xx and the provider gave a `fallbackURL`, that URL is tried once. Today only LoC `master:` services set one (`{service}/full/full/0/default.jpg`), because about half of the FSA/OWI masters fail every scaled request with 500 but serve the whole master (D44).

## 6. Failures, rejections and backoff

Every outcome of one candidate is logged and recorded. Ingest itself never throws.

| Outcome | Result |
|---|---|
| `CandidateRejected` (a rule failed) | Recorded as rejected in the ledger with its reason, never retried |
| HTTP 401, 403, 404, 410 or 451 on one item, or `tooLarge`, `badContent`, `insecureURL` | Rejected the same way (the item is at fault, not the provider) |
| Cancellation (Stop, Clear) | Ignored; not a provider failure (D43) |
| The pool was cleared while the item was in flight | Dropped: `dropped <item>: the pool was cleared while it was fetched` |
| Anything else: HTTP 429 or 5xx without a fallback, timeouts, `.offline`, `.blocked`, bad JSON in a search | The **provider** backs off |

Each failure moves a provider one step up the backoff ladder, **1, 2, 5, 15, 30 minutes**, and any success resets it. `.blocked` (for example the Met's Incapsula wall) goes straight to 30 minutes. `.offline` also marks the network as down, which the status row shows. `Retry-After` headers are not read; the ladder is the only rule. Log: `🖼️ [API] <provider> backing off N min: <error>`.

## 7. Decode

`CuratedImageFeed.decode` uses ImageIO with no caching:

- The header is read first. It applies the EXIF orientation to width and height, rejects a file with no size, and rejects anything over **150 megapixels** (`maxSourcePixels`), because a small PNG can declare a huge canvas.
- `CGImageSourceCreateThumbnailAtIndex` then decodes straight to the size needed, so a large master never expands fully in memory. The long side is `decodeLongSide(width, height, target)`:
  - For pictures wider than 3:2, the target is scaled up by aspect / 1.5, so that after the crop the height still gives about `target` wide.
  - For portraits, the target is scaled up by 1 / aspect.
  - The result is capped at the native long side and at 2 x target (5056 px).

## 8. Trimming: ScanEdgeTrimmer and BorderTrimmer

Two trimmers run before framing.

**`ScanEdgeTrimmer`** runs only for sources with `trimScanEdges: true` (today `loc-fsa-owi-color`). Scanned slides carry the film rebate: black edges of different widths on each side, edge codes, rounded mount corners, and sometimes a green or amber film-base tint. On a 300 px wide proxy:

- A pixel is dark below luma 0.16. A line counts as rebate when at least 55% of the middle 60% of the line is dark, so a dark corner alone does not count.
- Each side is walked inward on its own while its lines are rebate, at most 15% of that side.
- A side where rebate was found loses an extra 2% inset (rounded corners and halation). Every side loses at least 3%, because thin tinted rebates are not dark enough to detect.
- If less than 60% of either dimension would remain, nothing is trimmed.

The picture was decoded at 3413 px. After the trim it is scaled to the usual decode size for 2528 (D44).

**`BorderTrimmer`** (`Liminal/Visual/BorderTrimmer.swift`, D18, D25) runs on every picture. It removes a **near-white** uniform border only when all four outer strips look alike (luma above 0.88, spread under 0.04) and the interior does not. It never trims near-black edges, because dark surroundings are often the content. Paper margins on plates and prints are not always uniform enough to trim; this is a known weakness (D42).

## 9. 3:2 framing

`ImageOpenness.bestWindow`:

- A picture with an aspect between **1.3 and 1.8** is stored whole. The renderers' cover crop (`ImageFraming`) does the rest, the same crop on both platforms.
- Any other picture is cut to a 3:2 window: five offsets along the long axis, from one end to the other. Each window is scored for openness (section 10), and the most open one wins, with a 0.02 bias towards the centre to break ties. The stored file is then already 3:2, so saliency and depth stay registered with the colour image.

## 10. The gates: size, openness, document, monochrome, text, faces

After framing, the picture is checked in this order. The first failure rejects it, with the reason recorded in the ledger.

**Size.** The 3:2 cover crop of the framed picture must still be at least 2000 x 1333 (`too small for a 2K 3:2 crop`).

**Openness score** (`ImageOpenness.score`). This asks how much room the picture leaves for the archive film. The film shows in a picture's shadows when at least 18% of it is darker than luma 0.3, otherwise in its highlights; this is the same rule as `VideoComposite`. The score is measured on a 48 x 32 thumbnail of the 3:2 cover crop:

| Measure | Definition |
|---|---|
| `shadowShare` | Share of pixels with luma < 0.3 |
| `highlightShare` | Share with luma > 0.65 |
| `keyShare` | `shadowShare` when it is at least 0.18, else `highlightShare` |
| `calmShare` | Share of the 12 x 8 cells (4 x 4 px each) whose luma standard deviation is < 0.06 |
| `edgeDensity` | Mean absolute luma step between neighbouring pixels |
| `paperShare` | Share with luma > 0.85 and saturation < 0.12 (blank paper, scan margins) |
| `saturation` | Mean HSV saturation |
| `openness` | 0.5 x key band + 0.5 x min(calmShare / 0.35, 1) |

The **key band** is 0 below a key share of 0.03. It rises linearly to 1 at 0.18, stays at 1 up to 0.60, then falls to 0.3 when the key covers the whole frame. The shader's `keyGain` already tames a very large key, so night pictures are lowered in score, not rejected (D38).

**Gates**, with the thresholds from `defaults.openness` in the JSON:

| Gate | Rejects when | Threshold | Reason logged |
|---|---|---|---|
| Film key | `keyShare < minKeyShare` | 0.04 | `no room for the film (key 0.03)` |
| Openness | `openness < minOpenness` | 0.2 | `not open enough (0.15)` |
| Document | `paperShare > documentPaperShare` and `edgeDensity > documentEdgeDensity` | 0.5 and 0.06 | `looks like a document (paper 0.62)` |
| Monochrome | `saturation < monochromeSaturation`, unless the source sets `allowMonochrome` | 0.025 | `monochrome (saturation 0.01)` |
| Text (Vision) | text boxes cover more than 25% of the frame, or more than `maxTextCoverage` of a paper-like picture (`paperShare > 0.3`) | 0.06 | `text covers 32% of the frame` |
| Faces (Vision) | more than `maxFaces` faces, or one face box larger than `maxFaceArea` of the frame | 4 and 0.015 | `5 faces`, `a face covers 2.3% of the frame` |

Notes on these gates:

- Text alone rejects only a page. Signs are part of the brief (neon, diners, drive-ins), and the first live run rejected a neon sign at 10% under a plain 6% rule (D38).
- Distant figures stay; only prominent faces or crowds are rejected.
- The Vision checks (`VNDetectTextRectanglesRequest`, `VNDetectFaceRectanglesRequest`) run on the 3:2 cover crop. They are **compiled out of simulator builds**: Vision cannot create its inference context in the visionOS Simulator, and the failed setups during live ingest went with 100-320 ms render stalls (D42). If Vision fails on a device or Mac, the check passes and `Vision checks skipped: …` is logged. On a Vision Pro the checks are still unverified.
- `monochromeSaturation` in the JSON drives this ingest gate. The display rotation's monochrome flag uses the same 0.025 from the code's standard thresholds.

## 11. Storing: colour and the sidecar

`CuratedImageFeed.store` finishes the picture:

- `SaturationMeter.meanSaturation` measures the picture's mean saturation.
- `ImageMetadata` records:
  - `id`, `createdAt`, `pixelWidth`, `pixelHeight` and `mimeType`.
  - `measuredSaturation`.
  - `source` (the `ImageSourceCredit`) and `openness` (the full `OpennessScore`).
- **Duplicate gate** (D48). `ImageFingerprint` of the framed picture (a 64-bit row and a 64-bit column difference hash of a 9 x 9 grey thumbnail, and a 3 x 3 colour thumbnail) is compared with every stored picture. Within 8 bits on both hashes and 24 levels of mean colour difference it is the same picture (another scan, size or JPEG of it), and the candidate is rejected as `duplicate of <candidate key>`. Unrelated pictures differ in about half the bits; the colour check keeps two pictures with the same layout apart (a red and a teal nebula centred on black).
- The image is encoded as JPEG at quality 0.9 and saved with `CuratedImagePool.add`, with its fingerprint and aliases.

Log: `🖼️ API image stored: source=… item=… size=2528x1685 openness=0.62 key=0.31 license=… url=…`.

## 12. The pool on disk

`CuratedImagePool`, decision D39:

```
Application Support/Liminal/CuratedImageStore/   (inside the app's sandbox container)
    <uuid>.jpg + <uuid>.json    picture and sidecar (an ImageStore with its own epoch key, no count cap)
    ledger.json                 candidates, cursors, cached search pages, shown history
    tmp/                        downloads in progress
```

- **Own folder and epoch key.** The pool's `ImageStore` uses `images.api.cacheEpoch` at epoch 1; a lower stored epoch purges only this folder at launch. It is excluded from backups.
- **The ledger** (`CuratedLedger`) holds:
  - `candidates`: each key, with the stored picture's UUID or the rejection reason, and a date.
  - `cursors`: a missing cursor means start from page 1; `""` means there are no more pages.
  - `lists`: cached unseen candidates per search, with the date fetched.
  - `shown`: each picture's last display serial and how often it was shown.
  - `history`: the display serial and the last 32 shown, with source and monochrome flag.
  - `aliases`: catalogue aliases of stored pictures (section 2), and `fingerprints`: each stored picture's `ImageFingerprint` (D48). Both are dropped when the picture leaves the pool. Every ledger field is optional on disk, so an older ledger loads with its shown history.

  Every change bumps a version, and a writer lock skips any snapshot older than the one on disk. The ingest task and the "shown" task write from different threads, and a lost candidate record would let an item be downloaded again (D43).
- **Budget.** `storeBudgetBytes` is 3 GB, roughly 1,200-2,500 pictures at 1-2.5 MB each. Right after each save, if the pool is over budget, the least recently shown pictures are removed. Never-shown pictures go last, oldest first, and the new picture is never removed. An evicted picture's candidate record is cleared, so the item can be fetched again later. Nothing that can play is otherwise capped (A31). Log: `pool over budget: removed N least recently shown`.
- **Fingerprint backfill** (D48). The ingest task fingerprints pictures stored before fingerprints existed, from their JPEGs decoded at 288 px. If two stored pictures match, the later one is removed, its candidate is recorded as `duplicate of …` so it is not fetched again, and the kept copy takes the later "last shown". Log: `fingerprinted N pool pictures, removed M duplicate copies`.
- **Launch sweep** (`CuratedPoolPolicy.sweep`). It removes only junk: images without a sidecar, sidecars without an image, names that are not `<UUID>.jpg` or `.json`, and temp files older than an hour. Loading the pool also forgets candidate records whose picture file is gone, so those items can return.
- **Free space.** Ingest pauses while the volume has less than 1 GB free (`volumeAvailableCapacityForImportantUsage`).
- **Clear Curated Pictures** stops ingest and the display loop, releases reservations, and deletes every picture and the ledger. This is done under the writer lock, so a ledger write already under way cannot bring the old file back. The clear bumps the store's clear generation. Ingest reads that generation before it resolves a candidate, so a picture that was in flight during the clear is refused when saved. Fetching then restarts from scratch.
- **Verify pool.** `-LiminalImageAPIFresh YES` uses an empty `CuratedImageStore-Verify` folder with the epoch key `images.api.cacheEpoch.verify`, so a test run never touches the user's pool. Combined with `-LiminalImageAPIOffline YES`, it reuses the previous verify pool. The next normal launch deletes the verify folder.

## 13. Display rotation

`CuratedImageFeed.nextDisplay(current:)` calls `ImageRotation.nextDisplay`, which is pure and seeded:

- **Candidates** are the stored pictures from active sources, so `-LiminalImageProvider` restricts display too. The picture on screen is excluded, and so are pictures already picked and waiting in the queue (**reservations**). A reservation that was never shown, such as a Lo-Fi stage that missed its reveal, expires after 600 s (D43). Stop or Clear releases all reservations.
- **New pictures first** (D48). While any never-shown picture is a candidate, only never-shown pictures are drawn, with weight = source weight x (0.5 + openness). A picture already shown is never picked while a new one waits. Because ingest keeps up to 36 new pictures waiting and fetches four to five times faster than Lo-Fi shows them, an online session shows no picture twice.
- **Nothing new** (offline, every provider backing off, or every source dry). The pick is from the least recently shown quarter of the pool (`reshowShare`, at least one picture), with the same weights, and never one shown within the last `recencyWindow` (24) displays when an older one exists. An offline pool of n pictures therefore cycles with no picture back sooner than about 3n/4 displays.
- **Hard rules.** Each rule gives way rather than return nothing, and chooses only within the set above, so neither lets a shown picture in ahead of a new one:
  - Not the previous picture's source, when the pool spans three or more sources.
  - At most one monochrome picture in any `monochromeEvery` (6): if one of the last 5 shown was monochrome, colour pictures are preferred.

Before D48 the weight mixed both: shown pictures came back at weight 1 once 24 to 48 displays had passed, against x 3 for a new one. With ingest holding 12 new pictures, every picture shown more than 48 displays ago competed with them, so the share of repeats grew with the pool: about 33% in the first hour of a new pool, 68% in the second session and 85% by the sixth (a port of the old rule over six one-hour Lo-Fi sessions; 51% and 89% for two-hour sessions). The launch frame was a random stored picture, which could be the last one seen.

When the picture actually reaches the screen, `markShown` records it in the history and the `shown` table on a detached task, and only then releases its reservation, so a pick in between can never take it as new. Log: `🖼️ API image shown: source=… item=… title=… creator=… license=… url=…`.

## 14. How pictures reach the screen, and Lo-Fi timing

`ImageQueue` connects the feed to the rest of the visual pipeline: buffer, 3:2 crop, saliency, depth, footage, effects and renderers. `EffectsUniforms`, the shaders and the 2048 visionOS render size are not touched.

- **Start** (`ImageQueue.start`). This calls `startFeed`, which starts ingest and a display loop. Every second, the loop tops the queue up to `pendingTarget` (2) pictures from `feed.nextDisplay`, using the disk only. It also publishes the status message, the status line and the picture count to the UI.
- **First frame.** `loadInitialImage` shows the rotation's pick (`feed.anyPicture` calls `nextDisplay`): a never-shown picture when there is one, else one of the least recently shown, never a random one (D48). If the pool is empty, the first reveal shows the bundled standby art.
- **Decoding for display** (`makeDisplayItem`). Pictures are never upscaled; the ingest gate already guarantees 2000 x 1333 (D40).
- **Timing.** The drum transport's audible downbeat is the clock. For each image change, `VisualEngine` waits until 6 s before the drop starts. It then records the pool's clear generation, and calls `ImageQueue.reserveForFill`. That takes the next queued picture, or up to three tries of `feed.nextDisplay` straight from disk, with no network wait. The staged picture is kept only if the pool still has the same clear generation, and if it is ready at least 2 s before the drop. It is revealed on the downbeat; the film's piece change and the dialogue hits use the same clock. If no different picture is ready, two bundled standby pictures can alternate. Because display never waits for the network, the reserve deadline is met offline as well.

## 15. Credits

Every stored picture carries an `ImageSourceCredit` in its sidecar. Every field comes from the institution's own record:

| Field | Example |
|---|---|
| `providerID`, `sourceID`, `itemID` | `cma`, `cma-ukiyoe-landscapes`, the museum's object id |
| `title`, `creator`, `date` | *Sudden Shower over Shin-Ōhashi Bridge…*, Utagawa Hiroshige, 1857 |
| `institution` | From the provider block in the JSON: "Library of Congress", "NASA", "Wikimedia Commons", "Cleveland Museum of Art", "The Metropolitan Museum of Art", "Boston Public Library", "Art Institute of Chicago", "Smithsonian Institution" |
| `license` | The canonical label: "Public domain", "CC0", "No known restrictions", "No restrictions", "CC BY-SA 4.0", … |
| `licenseURL` | The CC0 deed for CC0; the Public Domain Mark for "Public domain"; `creativecommons.org/licenses/by[-sa]/<v>/` for CC BY and CC BY-SA; none for "No known restrictions" |
| `sourceURL` | The item's page at the institution, which is the link in the UI |
| `imageURL` | The exact file downloaded |

- `displayLine` is "Title · Creator, date · Institution · Licence". `ImageCreditLine` shows it under **Now showing** in the Images & Storage section, with a "View at <institution>" link. The credit is never drawn over the picture.
- `requiresAttribution` is true for CC BY and BY-SA, and those pictures always have a named creator (section 3).
- For pictures that came through Commons, the institution is "Wikimedia Commons". The originating archive (NARA, BHL, USGS…) usually appears in the creator or title, and the [sources page](sources.md) credits it.

## 16. Network use in test runs

- Fetching uses only the free public APIs, so a verification run may use the network and spends nothing.
- `-LiminalImageAPIOffline YES` turns the network off for a run: ingest stops and the display rotation uses the stored pool.
- `-LiminalImageAPIFresh YES` fills an empty verify pool instead of the user's (section 12).
- The fallback order is queued pictures, then the pool on disk, then the bundled standby art.

## 17. Concurrency: what runs where

The app target defaults to main-actor isolation. The pipeline keeps everything heavy off it:

| Work | Where it runs |
|---|---|
| Ingest loop: search, resolve, download, decode, trim, score, Vision, JPEG encode, pool save | `Task.detached(priority: .background)` inside `CuratedImageFeed` (a `nonisolated final class`, `Sendable`, state under a `Mutex`) |
| HTTP pacing and requests | `actor ImageHTTP`, awaited only from the ingest task |
| Providers and their parsing | `nonisolated` `Sendable` structs; parsing is static pure functions over `Data` |
| Scoring, rights, rotation, trimming | `nonisolated` pure enums (`ImageOpenness`, `ImageRights`, `ImageRotation`, `ScanEdgeTrimmer`, `BorderTrimmer`) |
| Pool and ledger | `CuratedImagePool` (`nonisolated`, `Mutex` state, separate writer `Mutex`); written only from the ingest task and detached bookkeeping tasks, never from a render or audio thread |
| Display loop | `Task.detached` in `ImageQueue.startFeed`; publishes to `@MainActor` UI state with `MainActor.run` |
| "Picture shown" bookkeeping | `Task.detached(priority: .utility)` from `ImageQueue.didShow`. Written inline from the main-actor reveal it cost a 107 ms frame in the simulator perf run (D40) |
| Lo-Fi reserve | `@concurrent reserveForFill` |
| UI (credit, status) | Main actor, reading published values |

## 18. Log lines

All lines are in subsystem `com.saygoodnight.Liminal`, category `Visual`. Stream them on macOS with `log stream --predicate 'subsystem == "com.saygoodnight.Liminal"'`. For the visionOS Simulator, use `xcrun simctl spawn <udid> log stream …`.

| Line | Meaning |
|---|---|
| `🖼️ [API] feed: N sources (…), offline=…` | Feed built; the active sources |
| `🖼️ [API] pool: N pictures in CuratedImageStore` | Pool loaded (or `CuratedImageStore-Verify`) |
| `🖼️ [API] pool sweep removed N junk files` | Launch sweep found junk |
| `🖼️ [API] ingest starting: N pictures, M never shown` / `ingest stopped` | Ingest loop |
| `🖼️ [API] ingest off (-LiminalImageAPIOffline)` / `ingest paused: N bytes free` | Offline flag; low disk |
| `🖼️ [API] <source> <queryKey>: N results, M new` | One search page fetched |
| `🖼️ [API] <source>: nothing new to try for now` | Source dry for 30 min |
| `🖼️ API image stored: source=… item=… size=WxH openness=… key=… license=… url=…` | A picture entered the pool |
| `🖼️ API image rejected: source=… item=… reason=…` | Recorded as rejected, never retried |
| `🖼️ API image shown: source=… item=… title=… creator=… license=… url=…` | On screen, with its credit |
| `🖼️ [API] <provider> backing off N min: <error>` | Provider backoff |
| `🖼️ [API] dropped <item>: the pool was cleared while it was fetched` | Clear during a fetch |
| `🖼️ [API] pool over budget: removed N least recently shown` | 3 GB eviction |
| `🖼️ [API] fingerprinted N pool pictures, removed M duplicate copies` | Fingerprint backfill of an older pool (D48) |
| `🖼️ API image rejected: … reason=duplicate of <key>` | The same picture is already in the pool (D48) |
| `🖼️ [API] Vision checks skipped: …` | Vision failed; text and face checks passed by default |
| `🖼️ [API] image-collections.json missing from the bundle` / `failed to decode` | JSON problem; the app shows standby art |
| `ImageQueue starting`, `🖼️ [ImageQueue] feed starting` / `stopped` | Display loop |
| `📂 [ImageQueue] pool: N pictures` | First-frame load |
| `🗑️ [ImageQueue] Clear Curated Pictures: removed N pictures` | Clear Curated Pictures |

A quick tally from a saved log:

```sh
grep -c "API image stored" run.log; grep -c "API image rejected" run.log; grep -c "API image shown" run.log
grep "API image rejected" run.log | sed 's/.*reason=//' | sort | uniq -c | sort -rn
```

## 19. Debug flags and verification

The flags are compiled out of Release builds and documented in [`development.md`](../development.md). Each one counts as an automation flag.

| Flag | Effect |
|---|---|
| `-LiminalImageProvider <id[,id]>` | Restrict ingest and display to these provider ids (`loc`, `nasa`, `wikimedia`, `cma`, `met`, `dc`, `aic`) or source ids |
| `-LiminalImageAPIOffline YES` | Pool only, no network; ingest off |
| `-LiminalImageAPISeed <n>` | Seed the ingest and display rotations |
| `-LiminalImageAPIFresh YES` | Use the empty `CuratedImageStore-Verify` pool. With `-LiminalImageAPIOffline YES`, reuse the previous verify pool |

Standard checks, from `development.md` and D41-D44:

- **Unit tests** (Swift Testing, fixtures in `LiminalTests/Fixtures/ImageAPI/`):

  ```sh
  xcodebuild test -scheme Liminal -destination 'platform=macOS' \
    -only-testing:LiminalTests/ImageCollectionsTests -only-testing:LiminalTests/ImageProviderParsingTests \
    -only-testing:LiminalTests/ImageRightsTests -only-testing:LiminalTests/ImageRotationTests \
    -only-testing:LiminalTests/ImageOpennessTests -only-testing:LiminalTests/CuratedImagePoolTests \
    -only-testing:LiminalTests/CuratedImageFeedTests -only-testing:LiminalTests/ImageQueueTests \
    -only-testing:LiminalTests/ScanEdgeTrimmerTests -only-testing:LiminalTests/ImageRepeatRotationTests \
    -only-testing:LiminalTests/ImageIdentityTests -only-testing:LiminalTests/ImageFingerprintTests \
    -only-testing:LiminalTests/ImageRepeatPoolTests -only-testing:LiminalTests/ImageRepeatFeedTests
  ```

- **Repeats.** In a live log, `grep "API image shown" run.log | sed 's/.*item=\([^ ]*\) title.*/\1/' | sort | uniq -d` must print nothing while ingest is online.

- **macOS live run.** Launch the built app with `-LiminalAutoPlay YES -LiminalImageAPIFresh YES -archive.enabled YES -LiminalVideoOffline YES`, stream the log, and look at the screen with Peekaboo. Expect at least six shown pictures from three sources in five minutes and credits in the panel. Add `-LiminalImageProvider <source-id>` to test one source.
- **Offline reuse.** Run again with `-LiminalImageAPIOffline YES` added. Pictures keep changing, the log shows `ingest off`, and no network requests are made.
- **visionOS Simulator.** `xcrun simctl launch <udid> com.saygoodnight.Liminal -LiminalAutoPlay YES -LiminalOpenDome YES -LiminalImageAPIFresh YES -LiminalControlsScroll images`, then a screenshot with `xcrun simctl io <udid> screenshot`. The text and face checks do not run in the simulator.
- **Lo-Fi perf.** Run `scripts/perf-run.sh --extra "-LiminalImageAPIFresh YES"` with ingest live, and again with `-LiminalImageAPIOffline YES`, and compare the two. Results are in D42.

Keep launches serialized: only one Liminal instance at a time. Terminate the app afterwards.
