# Image sources

[← Documentation](../README.md) · [Pipeline](pipeline.md) · [Sources](sources.md) · [Providers](providers.md) · [Adding a source](adding-a-source.md) · [Research history](research-history.md)

Liminal shows curated public-domain and openly licensed pictures from library, museum and space-agency APIs: the Library of Congress, NASA, Wikimedia Commons, the Cleveland Museum of Art, the Met, the Boston Public Library (through Digital Commonwealth) and the Art Institute of Chicago. It needs no key and spends nothing.

This folder documents the picture pipeline completely: how a picture travels from an institution's API to the screen, every source and provider, how to add one, and how the sources were found. It was written on 2026-11-21 from the code in `Liminal/Visual/ImageSources/` and `image-collections.json`. Where an older plan or research note disagrees with the code, the code is right.

| Page | What it covers |
|---|---|
| [pipeline.md](pipeline.md) | The whole process end to end: source rotation, search paging and the ledger, resolving, download, decode, trimming, the openness, text, face and monochrome gates with their thresholds, 3:2 framing, the pool on disk, display rotation, Lo-Fi timing, credits, concurrency, log lines, debug flags and verification |
| [sources.md](sources.md) | Every source in `image-collections.json`: what it searches and shows, measured resolution, the route to the high-resolution file, rights, weight, monochrome, pins, credits |
| [providers.md](providers.md) | One section per provider (`loc`, `nasa`, `wikimedia`, `cma`, `met`, `dc`, `aic`, `si`): endpoints, auth, paging, fields, the high-resolution trick, rate limits and known pitfalls |
| [adding-a-source.md](adding-a-source.md) | How to research a collection, write its JSON entry (every field), write a provider, test it with fixtures, and verify it live without touching the user's pool |
| [research-history.md](research-history.md) | How the sources were found, from OpenPics to the 2026-11-21 research passes, and what was rejected and why |

Decisions and measurements: [`decisions/images.md`](../decisions/images.md) D36-D45 and D48. The original plan: [`plans/image-api-mode.md`](../plans/image-api-mode.md) (implemented; parts have changed since, see the decisions).

## What the user sees

- **The credit line.** In the **Images & Storage** section of the controls, **Now showing** gives the picture on screen as "Title · Creator, date · Institution · Licence" and a link, "View at <institution>", to the item's page (`ImageCreditLine`). The credit is never drawn on the picture itself.
- **The status row** (`CollectionsStatusRow`) reads, for example, "Curated collections: 7 of 7 sources online". Here "sources" counts providers that are not backing off. It turns yellow when some are, and reads "Offline, showing saved pictures" or "Collections not answering, showing saved pictures" when none are reachable.
- **Status messages** appear when the pool is empty: "Fetching the first pictures…", "Offline and no saved pictures yet." or "The image collections are not answering right now."
- **Clearing.** The clear button reads **Clear Curated Pictures**. It asks "Delete all N curated pictures (size)?" and clears the pool and its ledger. The usage line reads "N curated pictures saved, size".

## Network use in test runs

Fetching uses only free public APIs, so a verification run may use the network. The fallback order is queued pictures, then the pool on disk, then the bundled standby art. `-LiminalImageAPIOffline YES` turns the network off for a run, and `-LiminalImageAPIFresh YES` fills a throwaway pool instead of the user's.

## The flow at a glance

```mermaid
flowchart TD
    subgraph Ingest["Ingest (background task, one picture at a time)"]
        A[Weighted source bag<br/>ImageRotation.nextSource] --> B[Pinned ids, cached search page,<br/>or next search page<br/>provider.search / pinned]
        B --> C[Resolve: final URL, declared size,<br/>rights verdict and credit<br/>provider.resolve + ImageRights]
        C --> D[Pre-download gate:<br/>mime, 12 MB, 2000x1333 3:2 crop]
        D --> E[HTTPS download<br/>ImageHTTP: host gaps, offline,<br/>fallbackURL on 5xx]
        E --> F[Bounded decode, ScanEdgeTrimmer,<br/>BorderTrimmer, best 3:2 window]
        F --> G[Size, openness, document,<br/>monochrome, text and face gates]
        G --> H[Colour analysis, JPEG 0.9<br/>into CuratedImageStore + ledger]
    end
    subgraph Display["Display (disk only)"]
        H --> I[CuratedImagePool]
        I --> J[ImageRotation.nextDisplay:<br/>new pictures first, openness, source alternation,<br/>monochrome cap, reservations]
        J --> K[ImageQueue: buffer, Lo-Fi reserve,<br/>3:2 crop, saliency, depth, footage]
        K --> L[Screen + credit line<br/>markShown -> ledger]
    end
    C -. rejected .-> R[Ledger: rejected with reason,<br/>never retried]
    D -. rejected .-> R
    G -. rejected .-> R
```

The two halves never wait on each other. Ingest only adds to the pool, and only while fewer than 12 never-shown pictures are waiting. Display only reads the pool on disk. A slow or offline network therefore never delays an image change: the Lo-Fi reserve deadline is always met from disk, and offline the rotation keeps going from what is stored.

## Where the code is

All of it is under `Liminal/Visual/ImageSources/`:

| File | Role |
|---|---|
| `image-collections.json`, `ImageCollections.swift` | The approved sources, defaults (sizes, gaps, thresholds) and licence allowlist, and the types that decode them |
| `ImageIdentity.swift` | Catalogue aliases and the perceptual fingerprint that catch duplicates |
| `ImageProvider.swift`, `ImageCandidate.swift` | The provider protocol, the shared rights and credit check, the registry (`ImageProviders.all`), loose JSON helpers, and candidate and resolved-image types |
| `Providers/*.swift` | One adapter per institution: `LOCProvider`, `NASAProvider`, `WikimediaProvider`, `ClevelandProvider`, `MetProvider`, `DigitalCommonwealthProvider`, `ArticProvider`, `SmithsonianProvider` |
| `ImageHTTP.swift` | The one HTTPS client: paced per host, ephemeral, generic User-Agent |
| `ImageRights.swift` | The rights rule and licence labels and links |
| `ImageOpenness.swift` | The room-for-the-film score, its gates and the 3:2 window search |
| `ScanEdgeTrimmer.swift` | Film rebate trim for scanned slides (`Liminal/Visual/BorderTrimmer.swift` handles white borders) |
| `ImageRotation.swift` | The two seeded choices: next source to ingest from, next picture to show |
| `CuratedImagePool.swift` | The pool on disk, ledger, eviction and launch sweep |
| `CuratedImageFeed.swift` | The ingest loop and the display entry points |
| `ImageSourceCredit.swift` | The credit record stored with each picture |

The UI is in `Liminal/ImageCreditControls.swift` (credit line, status row) and `Liminal/ClearImagesSection.swift`. `ImageQueue` (`startFeed`, `reserveForFill`, `showReserved`, `clearAllImages`) connects the feed to the rest of the visual pipeline. Tests are in `LiminalTests/CuratedImageTests.swift` and `ImageRepeatTests.swift`, with fixtures in `LiminalTests/Fixtures/ImageAPI/`.
