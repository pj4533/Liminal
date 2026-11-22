# API image providers

[← Image sources](README.md) · [Pipeline](pipeline.md) · [Sources](sources.md) · [Adding a source](adding-a-source.md) · [Research history](research-history.md)

A provider is one adapter per institution API, in `Liminal/Visual/ImageSources/Providers/`. This page gives, for each one, the endpoints it calls, auth, paging, the fields it reads, how it reaches a high-resolution file, rate limits and the pitfalls found so far. Measurements are from 2026-11-21 (`docs/research/image-apis/`, `decisions/images.md` D37, D40, D44). The code is the authority. The `providers` blocks in `image-collections.json` carry the same information as notes, but the app reads only their `name` and `institution`, so where a template in the JSON differs from the code (Commons still says `iiurlwidth=2048`), the code is right.

| id | Institution | Auth | Search paging | High-resolution route | Rights field → label | Host gap |
|---|---|---|---|---|---|---|
| [`loc`](#loc-library-of-congress) | Library of Congress | none | page `sp` | IIIF `service:` or scanned `master:` service, `full/!T,T`; `full/full` fallback on 5xx | `rights_advisory` → No known restrictions | 1 s |
| [`nasa`](#nasa-nasa-image-and-video-library) | NASA | none | page | `/asset/<id>` → `~orig` (HEAD ≤ 12 MB) | none → Public domain | 1 s |
| [`wikimedia`](#wikimedia-wikimedia-commons) | Wikimedia Commons | none (descriptive User-Agent) | continue token / offset | `thumburl` at `iiurlwidth=3072`, or the original when ≤ 3072 wide | `LicenseShortName` → PD, CC0, CC BY, CC BY-SA | 1 s |
| [`cma`](#cma-cleveland-museum-of-art) | Cleveland Museum of Art | none | offset `skip` | `images.print` (about 3400 px JPEG) | `share_license_status` → CC0 | 1 s |
| [`met`](#met-the-metropolitan-museum-of-art) | The Met | none | offset | `primaryImage` (original, up to about 4000 px) | `isPublicDomain` → CC0 | 5 s |
| [`dc`](#dc-digital-commonwealth-boston-public-library) | Digital Commonwealth (Boston Public Library) | none | page | IIIF 2 `full/!2528,2528` | `reuse_allowed_ssi` → No restrictions | 1 s |
| [`aic`](#aic-art-institute-of-chicago) | Art Institute of Chicago | none | page | IIIF `full/3000,` (fixed widths only) | `is_public_domain` → CC0 | 2 s |
| [`si`](#si-smithsonian-open-access-disabled) | Smithsonian | api.data.gov key (env) | offset `start` | `online_media.media[0].content` | `metadata_usage.access` → CC0 | 1 s |

`T` is the requested long side: 2528, or 3413 for `trimScanEdges` sources.

## What every provider does

The protocol (`ImageProvider.swift`):

```swift
nonisolated protocol ImageProvider: Sendable {
    var id: String { get }
    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage
    func pinned(source: CuratedSource, ids: [String], http: ImageHTTP) async throws -> [ImageCandidate]
    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage
}
```

- **`search`** returns one page of `ImageCandidate`s, plus the cursor of the next page, or nil on the last page. A `SourceQuery` is either `.search(CuratedQuery)` (text plus optional year window, `type` or `departmentId`) or `.category(String)` (Commons only). A provider ignores the kinds it does not support and returns an empty page.
- **`pinned`** has a default implementation that returns stubs; `resolve` then looks each one up. Only Commons overrides it, batching 50 titles per request.
- **`resolve`** fills in what the search left out. It builds the final URL, declares the size when it can, and ends with the shared `credit(for:source:context:imageURL:)`, which applies the rights verdict, the title rules and the attribution rule (see [pipeline.md](pipeline.md#3-resolve-url-size-rights-and-credit)).
- **Errors.** A rule failure throws `CandidateRejected(reason:)`, which records the item and never retries it. A network or server failure throws `ImageFetchError`, which backs the provider off unless it is an item failure (401, 403, 404, 410, 451 and the like).
- **Parsing** lives in static pure functions over `Data`, such as `LOCProvider.parseSearch` and `ArticProvider.candidate`, so the tests run on saved JSON with no network.
- **`LooseJSON`** reads the messy JSON of library APIs:
  - `string` accepts a string, a number or the first string in an array.
  - `int` accepts a number or a numeric string.
  - `plainText` strips HTML and entities (Commons Artist fields).
  - `year` turns `1969-07-20T00:00:00Z` into `1969`.
  - `query` builds URLs and encodes `+` as `%2B`, so servers do not read it as a space.
- **Registration.** `ImageProviders.all()` registers `LOCProvider`, `NASAProvider`, `WikimediaProvider`, `ClevelandProvider`, `MetProvider`, `DigitalCommonwealthProvider` and `ArticProvider`, plus `SmithsonianProvider` when `SMITHSONIAN_API_KEY` is set.
- **Requests** all go through `ImageHTTP`: https only, paced per host, a generic User-Agent and no cache ([pipeline.md](pipeline.md#5-download)).

### IIIF in one paragraph

Three providers (LoC, Digital Commonwealth, AIC) serve images through the [IIIF Image API](https://iiif.io/api/image/2.1/). A IIIF service is a base URL, and the server scales on request:

- `{service}/info.json` gives the native width, height and the allowed `sizes`.
- `{service}/full/!2528,2528/0/default.jpg` is the whole image fitted inside 2528 x 2528.
- `full/3000,` means 3000 px wide, and `full/full` is native size.

Servers may restrict which sizes they serve, as AIC does. LoC caps its request at the native size when it knows it.

---

## `loc`: Library of Congress

`LOCProvider`. Keyless. Sources: `loc-highsmith-roadside`, `loc-highsmith-landscape`, `loc-fsa-owi-color`.

**Search.** `https://www.loc.gov/collections/<collection>/?fo=json&q=<q>&c=20&sp=<page>&fa=online-format:image`

- `collection` is the source's collection slug (`carol-m-highsmith`, `fsa-owi-color-photographs`). Only `.search` queries are used.
- The cursor is the page number. A next page exists while `pagination.next` is set.

**Fields** (`parseSearch`), from each `results[]` entry:

| Field | Use |
|---|---|
| `id` | Item URL; the item id is its last path component (`2013631471`) |
| `title` | Title |
| `contributor` | Creator; all-lower-case names are title-cased ("highsmith, carol m." → "Highsmith, Carol M.") |
| `date` | Year |
| `item.rights_advisory`, else `item.rights_information` | Rights text |
| `image_url[]` | Derivative URLs, from which the IIIF service and size are read |
| page | `https://www.loc.gov/item/<id>/` |

**High resolution: the IIIF `service:` derivative.** Highsmith results carry IIIF derivatives such as `https://tile.loc.gov/image-services/iiif/service:pnp:highsm:31900:31928/full/pct:25/0/default.jpg#h=1228&w=1840`.

- `LOCProvider.iiif(from:)` takes the service id from the URL (everything before `/full/`). It computes the full size from the `pct:` region and the `#h=&w=` fragment: full = fragment x 100 / pct.
- The largest derivative gives the most exact size, so **a search hit needs no further request**.
- With `requireIIIF` (the default, `true`), results without a service are dropped.

**High resolution: the scanned master (`useMasters`, D44).** FSA/OWI colour, photochroms, Prokudin-Gorskii and Highsmith items catalogued from 2018 on expose no IIIF derivative. They have only a 1024 px `v.jpg` and a 30-144 MB TIFF master. The IIIF server does serve those masters, under a `master:` prefix rather than `service:`. `LOCProvider.masterIIIF(from:)` derives the service from the `v.jpg` path:

```
https://tile.loc.gov/storage-services/service/pnp/fsac/1a33000/1a33800/1a33849v.jpg
→ https://tile.loc.gov/image-services/iiif/master:pnp:fsac:1a33000:1a33800:1a33849u
```

- The path after `service/` has its `/` replaced by `:`, the trailing `v`, `r`, `t` or `_150px` is replaced by `u`, and the result gets the `master:` prefix.
- The size comes from `{service}/info.json`. An item with no master fails that request and is rejected on its own.
- Measured masters: FSA 4641-7738 px (40 of 40 sampled), photochrom `ppmsc:07700:07735u` 2759x3666, Prokudin-Gorskii `prokc:20100:20159u` 3808x3726, Highsmith `highsm:52000:52077u` 7313x4696.
- This is the OpenPics trick taken one step further. OpenPics read `resources[0].larger` from the old `/pictures/` JSON; that names the TIFF master, and its path gives the IIIF id.

**Resolve.**

1. For a pinned stub, read `https://www.loc.gov/item/<id>/?fo=json` (`parseItem`):
   - It reads `resources[].files[][]` for the IIIF service and the largest `width`/`height`, `item.title` and `item.date`.
   - `item.contributor_names` gives the creator: "Highsmith, Carol M., 1946-, photographer" becomes "Highsmith, Carol M.".
   - The rights come from the same fields as in a search.
   - With `useMasters`, the master route applies when there is no IIIF service.
2. If the size is still unknown, read `{service}/info.json` (`parseInfo`).
3. Download `{service}/full/!T,T/0/default.jpg` with T = min(native long side, target). The declared size is scaled to match.
4. For `master:` services, set `fallbackURL` to `{service}/full/full/0/default.jpg`.

**Rights.** "No known restrictions on publication" (Highsmith's gift to the public; FSA/OWI as US Government work) becomes **No known restrictions**. "Rights status not evaluated" and "Publication may be restricted" (for example the New York World-Telegram photographs) are rejected.

**Rate limits.** LoC documents burst limits with a CAPTCHA or 429 for abuse. At the 1 s default gap none was hit, and one timeout in the first live run backed the provider off for a minute.

**Pitfalls.**

- About half of the FSA/OWI masters answer **every scaled request with HTTP 500** (`full/2528,`, `full/!2528,2528`, `pct:50`) but serve `full/full`, a 1-5 MB JPEG of the whole master (for example 7366x9175 in 4 MB). Without the fallback, each one put the whole LoC provider into a one-minute backoff. With it, the 12 MB and 150-megapixel limits still apply, and decode scales the image down.
- Slide scans include the **film rebate**: black edges, edge codes, rounded mount corners and tinted base. `BorderTrimmer` leaves these, because the four edges are not alike. Set `trimScanEdges` ([pipeline.md](pipeline.md#8-trimming-scanedgetrimmer-and-bordertrimmer)).
- The IIIF `service:` derivatives of FSA, photochroms and Prokudin-Gorskii stop at 1024 px, and guessed master ids with the `service:` prefix return 404. That is why the first research pass wrongly rejected these collections.
- The old `/pictures/` endpoint still answers, but its item resource block is null. Use `/item/<id>/?fo=json`.
- The Yanker posters have 640 px JPEGs only. The Margolies Roadside America items tried had only a thumbnail online.
- Mid-century `/photos/` searches (`dates=1950/1969`) turn up mostly 1024 px items with restricted or unevaluated rights.

**Library of Congress batch (D45, 2026-11-21).** Findings from [loc-collections.md](../research/image-apis/loc-collections.md):

- **The `master:` route works across Prints & Photographs**, not only FSA colour: Margolies (`mrg`), Matson (`matpc`), photochrom (`ppmsc`), Prokudin-Gorskii (`prokc`), Detroit (`det`), Japanese prints and popular graphic arts (`cph`, `ppmsca`), FSA B&W (`fsa`). Search results usually carry only `_150px.jpg` or `t.gif` thumbnails; `masterIIIF` accepts both. HABS masters use a `p` suffix (`347223p` → `347223pu`) and also work, but every HABS rights string mentions "may be restricted", so HABS is not used.
- **`partof` sources.** Collections that exist only as a facet (Margolies, Matson) are searched at `https://www.loc.gov/photos/?fo=json&q=…&fa=partof:<name>|online-format:image`; the JSON has the same shape as a collection search. Set `partof` instead of `collection`.
- **Scaled requests fail often.** HTTP 500 for every scaled size on Margolies 20 of 20, photochrom 10 of 19, Japanese prints 14 of 21, Detroit 11 of 19 and FSA B&W 11 of 16 (Prokudin-Gorskii 0 of 20). `info.json` does not predict it. The `full/full` fallback handles them.
- **Bytes.** `full/full` is 0.4-10 MB everywhere except FSA B&W 4x5 negatives (13,600-14,400 px, 10.6-18.1 MB), about 30% of which exceed the 12 MB `maxBytes` and are skipped.
- **Cold masters.** The first `info.json` of an uncached master can take over 40 s, then answers in about 0.1 s; the 30 s request timeout makes that a provider error and a short backoff, not a rejection.
- **Prokudin-Gorskii fringes.** Coloured plate-misregistration bands (4-7.5% per side) are not dark, so the source sets `edgeInset` 0.08 on top of `trimScanEdges`.
- **Rejected on rights:** Look, Horydczak, Matson lantern slides, the Bill Graham/Avalon posters, NYWT&S, HABS/HAER. **Rejected on fit or size:** WPA posters (lettering), Genthe autochromes (masters 300-560 px), panoramas (short side 570-730 px), stereograph cards (two frames per card), Cabinet of American Illustration (1024 px).

---

## `nasa`: NASA Image and Video Library

`NASAProvider`. Keyless. Sources: `nasa-space-age`, `nasa-deep-space`, `nasa-orbital-earth-1960s`, `nasa-lunar-orbit`, `nasa-aurora-from-orbit`, `nasa-cape-kennedy-aerials`.

**Search.** `https://images-api.nasa.gov/search?q=<q>&media_type=image&year_start=<y>&year_end=<y>&page_size=20&page=<n>`

- The year window comes from the query object (`yearStart`, `yearEnd`).
- A next page exists while `collection.links[]` has `rel: "next"`.

**Fields** (`parseSearch`), from `collection.items[].data[0]`:

| Field | Use |
|---|---|
| `nasa_id` | Item id |
| `title` | Title |
| `photographer`, else `secondary_creator`, else "NASA <center>" | Creator, with HTML stripped and at most 120 characters |
| `date_created` | Year |
| `media_type` | Must be `image` |
| page | `https://images.nasa.gov/details/<nasa_id>` |

**Pinned.** Stubs are looked up with `search?nasa_id=<id>`.

**High resolution.**

- `https://images-api.nasa.gov/asset/<nasa_id>` lists every file. `parseAsset` takes the `~orig` `.jpg`, `.jpeg` or `.png`, encodes spaces as `%20`, and upgrades `http://` to https.
- A **HEAD** request reads `Content-Length`, and an original over 12 MB is rejected.
- There is **no `~large` fallback**. `~large` is only 1920 px, below the size gate, so an oversized original is rejected rather than replaced (D40). The provider note in the JSON says the same.
- No size is declared, so the size gate runs after decode.

**Rights.** No per-item field. Every item gets the rights text "US Government work (NASA media are generally not copyrighted)", which becomes **Public domain**. Credit keeps the centre and photographer.

**Measured.**

- Hasselblad scans are about 4096x4096; the 3:2 crop keeps 4096x2731.
- The median `~orig` is 2-4.5 MB, and a few panoramas or masters run to 13-47 MB.
- ISS aurora originals are 4256-8256 px and up to 10.4 MB.
- Every NASA pin's original was measured at 3000-8256 px and 1.0-10.4 MB.

**Pitfalls.**

- A few library items are third-party works (D43). The title reject words (`portrait`, `crew`, `insignia`, `diagram`…) are the guard.
- Press conferences, crew portraits and mission patches appear among the results.
- Voyager prints have white borders; do not query "Voyager".
- Goddard Hubble images are often 1280 px. Lunar Orbiter `~orig` files are unreadable.
- Some titles are just the item id.
- One Ames space-colony painting (`AC76-0628`) is 29 MB and is always rejected.

---

## `wikimedia`: Wikimedia Commons

`WikimediaProvider`. Keyless; Commons asks for a descriptive User-Agent, which `ImageHTTP` sends. Sources: the DOCUMERICA, fungi, Haeckel, Landsat, photochrom, aurora, galaxies, forests, Apollo, American West and shin-hanga sources.

**Base request.** Every call is `https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=url|size|mime|extmetadata&iiurlwidth=3072&iiextmetadatafilter=LicenseShortName|Artist|DateTimeOriginal|ObjectName|Credit`, plus one of:

| Kind | Added parameters | Cursor |
|---|---|---|
| Category (`categories`) | `generator=categorymembers&gcmtitle=Category:<name>&gcmtype=file&gcmlimit=20&gcmcontinue=<cursor>` | `continue.gcmcontinue` |
| Search (`searches`, `queries`) | `generator=search&gsrnamespace=6&gsrsearch=<q> filetype:bitmap&gsrlimit=20&gsroffset=<cursor>` | `continue.gsroffset` |
| Pinned | `titles=<up to 50 File: titles joined by \|>` | — |

**Fields** (`parse`). Pages are sorted by page id, so a page always comes out in the same order:

| Field | Use |
|---|---|
| `title` (`File:…`) | Item id |
| `extmetadata.ObjectName` | Title, with catalogue suffixes removed (" LCCN2017657809", " - NARA - 544071"); else the file name without `File:` and the extension |
| `extmetadata.Artist` | Creator, HTML stripped, at most 120 characters |
| `extmetadata.DateTimeOriginal` | Year |
| `extmetadata.LicenseShortName` | Rights |
| `imageinfo[0]`: `width`, `height`, `size`, `mime`, `url`, `thumburl`, `thumbwidth`, `thumbheight`, `descriptionurl` | Size, file and page |

**High resolution.** The provider asks Commons for a 3072 px wide thumbnail (`iiurlwidth=3072`):

- If the original is no wider than 3072, or there is no thumbnail, the **original** `url` is used, with its byte size declared.
- Otherwise the scaled **`thumburl`** is used, with the thumbnail's size declared.
- Measured served sizes are 2736-3072 px wide (pins re-checked 2026-11-21). Decode then scales them to the 2528 target.
- `resolve` accepts only `image/jpeg` and `image/png`. TIFF, SVG, PDF and DjVu are rejected.

**Rights.** The file's own `LicenseShortName`, judged against the allowlist. Ported licences such as "CC BY-SA 3.0 de" map to the base licence. CC BY and CC BY-SA files are kept only with a named creator. The institution in the credit is "Wikimedia Commons"; the originating archive (NARA, BHL, USGS) usually appears in the creator or title.

**Rate limits.** The default 1 s gap applies. Bursts returned errors during probing, and two 429 bursts happened even at 1 call per 2 s (`Retry-After` 6-37 s, possibly from a shared IP). A 429 backs the provider off on the ladder; `Retry-After` is not read.

**Pitfalls.**

- **The URAA trap.** Commons labels Kawase Hasui (d. 1957) and Yoshida Hiroshi (d. 1950) prints "Public domain" whatever their date. Shin-hanga published after 1930 are probably still under US copyright through URAA restoration ("Miyajima in de mist" 1947, "Wisteria" 1935, "Snow in Mukojima" 1931). Never add their categories. Pin only prints dated 1930 or earlier, checked through `DateTimeOriginal` (`shin-hanga-pinned`).
- **Free-text search is noisy.** A "highway 1950s" query returned a cinema photo, an SVG template and a diagram. Use curated categories, or keyword searches inside one project with `requireTitleContains` (DOCUMERICA uses "NARA"). Whole-word `rejectTitleWords` handle the rest. Some words match the wrong thing: "Las Vegas" matched the EPA laboratory, "rainbow" trout, and "clouds" White Cloud, Kansas.
- **Wide panoramas fail.** They are served 3072 px wide, so a 9640x3949 file arrives as 3072x1258 and fails the 1333 px short side.
- **Book scans.** *Kunstformen der Natur (1899)* is a full BHL book, mostly text pages, so the parent category is used. Some plates are TIFF duplicates.
- **Category names that do not exist** (do not use them): "Project Apollo Archive", "WPA posters", "Earth as Art", "NOAA Photo Library", "Kodachrome slides", "Featured pictures of deserts", "Quality images of aurorae", "Hubble Heritage", "Psychedelic posters".
- Long Commons creator lines, such as "Image provided by the USGS EROS Data Center…", are cut at 120 characters.

---

## `cma`: Cleveland Museum of Art

`ClevelandProvider`. Keyless. Sources: `cma-ukiyoe-landscapes`, `cma-early-photographs`, `cma-american-landscapes`, `cma-weather-prints`.

**Search.** `https://openaccess-api.clevelandart.org/api/artworks/?q=<q>&type=<type>&has_image=1&cc0=1&limit=20&skip=<offset>`

- `type` comes from the query object (`Print`, `Photograph`, `Painting`).
- The cursor is the `skip` offset. A next page exists while `skip + 20 < info.total`.

**Fields** (`candidate`), from `data[]`:

| Field | Use |
|---|---|
| `id` | Item id |
| `title` | Title |
| `creators[0].description` | Creator, cut before " (" ("Utagawa Hiroshige (Japanese, 1797–1858)" → "Utagawa Hiroshige") |
| `creation_date` | Date |
| `images.print.url`, `width`, `height`, `filesize` | File and declared size |
| `share_license_status` | Rights |
| `url` | Page |
| `type` | Kept as a hint |

Results without a print image are dropped. Pinned ids are read from `/api/artworks/<id>`.

**High resolution.** `images.print` is a JPEG of about 3400 px on the long side (2-4 MB). The museum has upgraded it from the 1536 px the first survey measured. Never use `images.full`, which is a TIFF.

**Rights.** `share_license_status` must be "CC0", and the search also passes `cc0=1`.

**Rate limits.** None hit at 1 request per second.

**Pitfalls.**

- **Keyword noise for paintings.** "landscape", "moonlight", "forest" and "ocean" with `type=Painting` return mostly Chinese and Japanese ink scrolls and Mughal miniatures. `q="American landscape"` returns 33 US paintings (Church, Bierstadt, Gifford). Add pins for the best.
- Without a type filter, "mushroom" returns lamps and boxes, "fungi" ceramics and jade, and "forest" Indian miniatures. Always set `type`.
- There is little mid-century material: `created_after=1945` with `created_before=1980` returns only 13 CC0 works.

---

## `met`: The Metropolitan Museum of Art

`MetProvider`. Keyless. Sources: `met-landscapes`, `met-american-tonalists`, `met-early-photographs`, `met-hiroshige-night`.

**Search.** `https://collectionapi.metmuseum.org/public/collection/v1.1/search?hasImages=true&isPublicDomain=true&q=<q>&departmentId=<id>&limit=20&offset=<n>`

- The search returns only `objectIDs` and `total`, so every candidate is a stub.
- A next page exists while `offset + 20 < total` and the page was not empty.
- The old `/v1/search` was retired on 2026-10-01.
- Departments used: 1 (American Wing), 6 (Asian Art), 19 (Photographs).

**Resolve.** `https://collectionapi.metmuseum.org/public/collection/v1/objects/<objectID>` (`parseObject`):

| Field | Use |
|---|---|
| `objectID` | Item id |
| `isPublicDomain` | Must be `true`, else `not public domain` |
| `classification` | Must be in the source's `allowClassification`, when set |
| `title`, `artistDisplayName`, `objectDate` | Credit |
| `objectURL` | Page |
| `primaryImage` | File |

**High resolution.** `primaryImage` is the original, up to about 4000 px (measured 4000x3184 for *Wheat Field with Cypresses*). No size is declared, so the size gate runs after decode.

**Rights.** "CC0", but only when the object's own `isPublicDomain` is true. The v1.1 search **ignores its own `isPublicDomain` filter** and returns objects that are not public domain.

**Rate limits.** An Incapsula bot wall answers 403 HTML for both the API and `images.metmuseum.org` after about 100 quick requests. `hostGaps` keeps 5 s between requests on both hosts. `ImageHTTP` maps the HTML 403 to `.blocked`, which backs the provider off for 30 minutes at once. About 50 requests at 5 s never hit the wall.

**Pitfalls.**

- **Empty classification.** Every American Wing painting sampled had `classification: ""`, so `met-american-tonalists` allows `["Paintings", ""]`. That also admits unclassified decorative objects, so the source is kept to one query plus pins.
- Without an allowlist, "forest" returns furniture and cutouts, and "mushroom" netsuke.
- Walker Evans and most 1950s photographs are not public domain. "clouds" in department 19 is mostly Weston, Hagemeyer and Shore, and half the "waterfall" results are not public domain either.
- Some Mount Fuji scrolls are mostly blank.
- The Internet Archive collection `metropolitanmuseumofart-gallery` mirrors the Met, with `<objectID>.jpg` and a `_mma.json` record per item. It would make a fallback, but is not implemented.

---

## `dc`: Digital Commonwealth (Boston Public Library)

`DigitalCommonwealthProvider`. Keyless Blacklight JSON plus IIIF 2. Source: `dc-tichnor-postcards`.

**Search.** `https://www.digitalcommonwealth.org/search.json?q=<q>&per_page=20&page=<n>&f[related_item_host_ssim][]=<collection>`

- `collection` is the host collection facet, for example "The Tichnor Brothers Collection".
- A next page exists while `meta.pages.next_page` is above 0.

**Fields** (`candidate`), from `data[]`:

| Field | Use |
|---|---|
| `id` | Item id (`commonwealth:xs55mj59t`) |
| `attributes.exemplary_image_ssi` | IIIF image id; records without one are dropped |
| `attributes.reuse_allowed_ssi`, else `license_ss` | Rights |
| `attributes.title_info_primary_tsi` | Title |
| `attributes.publisher_tsi` | Creator: "…Made Only by Tichnor Bros., Inc., Boston, Mass." → "Tichnor Bros., Inc." |
| `attributes.date_tsim` | Date, brackets removed ("ca. 1930–1945") |
| `attributes.identifier_uri_ss` | Page (ark URL), else `/search/<id>` |

Pinned ids are read from `https://www.digitalcommonwealth.org/search/<id>.json`.

**High resolution.**

- `https://iiif.digitalcommonwealth.org/iiif/2/<exemplary_image_ssi>/info.json` gives the size; the search carries none, so it is read for every candidate.
- The file is `…/full/!2528,2528/0/default.jpg`.
- Tichnor postcards are natively 3295-3336 x 2088-2181, and the request serves 2528x1616 (1.3 MB).

**Rights.** `reuse_allowed_ssi` is the site's normalised verdict. Only "no restrictions" (→ **No restrictions**) is kept; "contact host" and the rest are rejected. The fallback `license_ss` "No known restrictions on use." maps to No known restrictions. Other collections on the site are mixed (the Leslie Jones photographs are CC BY-NC-ND), so always pair the collection facet with the per-record check.

**Rate limits.** None hit at 1 request per second (about 40 requests).

**Pitfalls.** Each card has a printed caption strip and a handwritten accession number in a corner, and some have a white border. The text rule and `BorderTrimmer` handle most of them. Multi-view motel cards are busy, so titles with "Greetings" or "views" are rejected.

---

## `aic`: Art Institute of Chicago

`ArticProvider`. Keyless. Source: `aic-landscapes`.

**Search.** `https://api.artic.edu/api/v1/artworks/search` with an Elasticsearch bool query in GET parameters:

```
query[bool][must][0][match][title]=<q>
query[bool][must][1][term][is_public_domain]=true
query[bool][must][2][term][artwork_type_id]=<id>        (only when the query has a type)
fields=id,title,image_id,is_public_domain,thumbnail,artist_title,date_display,artwork_type_title
limit=20&page=<n>
```

- Types map to ids: Painting 1, Photograph 2, Drawing and Watercolor 14, Print 18.
- A next page exists while `page < pagination.total_pages`.
- Pinned ids are read from `https://api.artic.edu/api/v1/artworks/<id>?fields=…`.

**Fields** (`candidate`):

| Field | Use |
|---|---|
| `id` | Item id |
| `image_id` | IIIF id; records without one are dropped |
| `title`, `artist_title`, `date_display` | Credit |
| `thumbnail.width`, `thumbnail.height` | Native size, so the size gate needs no `info.json` |
| `is_public_domain` | Rights |
| page | `https://www.artic.edu/artworks/<id>` |

**High resolution.** The IIIF server allows only a fixed set of widths:

| Request | Result |
|---|---|
| `full/843,`, `full/1686,` | 200 (too small) |
| `full/3000,` | 200: 3000 px on the long side, or native when smaller; portraits fitted by height; never enlarged |
| Widths listed in `info.json` `sizes` | 200 |
| `full/2000,`, `full/2528,`, `full/full`, `full/max`, `full/!2528,2528`, `full/pct:50`, tiles | 403 |

The provider always requests `https://www.artic.edu/iiif/2/<image_id>/full/3000,/0/default.jpg` and declares the native size fitted inside 3000. Measured: 3000x2235, 2971x2250, 3000x2324 from a 10490 px master, and 2350x3000 for a 6514x8315 portrait.

**Rights.** `is_public_domain == true` means CC0 under AIC's open-access terms (→ **CC0**). Anything else gets the rights text "not public domain (restricted)" and is rejected.

**Rate limits.** The documented anonymous limit is about 60 requests a minute, apparently shared by `api.artic.edu` and `www.artic.edu`. Probing at 1.1 s got a 429 after about 6 searches and 125 IIIF requests in roughly 4 minutes. `hostGaps` keeps 2 s on both hosts, and a 429 backs off on the ladder.

**Pitfalls.**

- Combining `q=` with a `query` filter falls back to popularity order, so "moonlight" paintings returned Seurat, Van Gogh and Renoir. Put the text in a `match` clause, as the provider does.
- The match is on the title only.
- A 403 on an image is an item failure, so the item is rejected. That only happens if someone changes the requested width.
- The first survey wrongly concluded AIC was capped at 843 px. It had only tried `full/full` and `!w,h`.

---

## `si`: Smithsonian Open Access (disabled)

`SmithsonianProvider`. Registered only when `SMITHSONIAN_API_KEY`, an api.data.gov key, is set in the environment. It is deliberately not in `Secrets.swift`, so existing local `Secrets.swift` files keep compiling. Source: `si-american-landscapes`, `enabled: false`.

**Search.** `https://api.si.edu/openaccess/api/v1.0/search?q=<q> AND online_media_type:Images&api_key=<key>&rows=20&start=<n>`. A next page exists while `start + 20 < response.rowCount`.

**Fields**, from `response.rows[]`:

| Field | Use |
|---|---|
| `id`, `title` | Item id and title |
| `content.descriptiveNonRepeating.online_media.media[0].content` | File; rows with `online_media` null are skipped |
| `metadata_usage.access`, else the media's `usage.access` | Rights |
| `content.freetext.name[0].content`, `freetext.date[0].content` | Creator and date |
| `descriptiveNonRepeating.record_link` | Page |

**High resolution.** The ids.si.edu delivery URL served 2999x2263 for a SAAM landscape. Other sizes are unmeasured, which is why the source stays disabled.

**Rights.** `metadata_usage.access` must be "CC0".

**Pitfalls.** `DEMO_KEY` allows 10 requests, and its shared quota was already spent when tested (429 on the first call). Many rows have `online_media: null` even with the media filter.
