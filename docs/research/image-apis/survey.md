# Image API survey for Liminal's API mode (2026-11-21)

Goal: curated, high-resolution, legally reusable imagery for an "API" image mode (vs "AI" Gemini generation). Vibe: psychedelic, 1950s-70s, old film stills, vintage photography and illustration, mushrooms, trees, landscapes, roadside and cityscapes, cars and driving, space age, surreal. Pictures need roughly 3:2 cover crops at up to 2K, so sources that give 2000+ px on the long side are preferred. Prior art: [openpics.md](openpics.md).

Method: keyless endpoints were called with curl on 2026-11-21 and pixel sizes were measured on real downloads. Items marked "unverified" were not exercised (key needed, or not reached) and come from docs or search results.

## Ranked shortlist

| # | Source | Auth | Verified max size | Rights field | Vibe fit |
|---|---|---|---|---|---|
| 1 | Library of Congress (loc.gov JSON + IIIF) | none | 7041x5562 JP2; IIIF 2048w confirmed | `rights_advisory` text per item | Excellent: FSA/OWI color 1620 items, Highsmith 1394 results for "highway", Detroit Publishing 25k, Yanker posters, roadside neon |
| 2 | NASA Image and Video Library | none | `~orig.jpg` 2973x1967 (Apollo 1969) | NASA media mostly public domain, check `secondary_creator`/description | Excellent for space-age 1960-72 |
| 3 | Wikimedia Commons (MediaWiki API) | none (set a User-Agent) | originals vary; `Special:FilePath?width=2048` scales | `extmetadata` LicenseShortName, Artist, Credit | Good but noisy; needs category/license filtering |
| 4 | Smithsonian Open Access (api.si.edu) | api.data.gov key; `DEMO_KEY` works (limit header 10) | media via ids.si.edu; size unverified | `metadata_usage.access` = CC0 | Good: NMAH 1960s objects, posters, Freer/NPG, SAAM art |
| 5 | The Met Open Access | none | `primaryImage` original 4000x3184 | `isPublicDomain` boolean | Landscapes, trees, Hudson River, prints; weak on 1950-70 |
| 6 | Cleveland Museum of Art | none | `print` 1536x1931 JPEG, tiff larger | `share_license_status` CC0, `cc0=1` filter | Landscapes, prints, some Asian art; weak on mid-century |
| 7 | Internet Archive (advancedsearch + download) | none | original upload (11 MB JPG seen) | per-item `licenseurl`, mixed (many NC/ND) | Huge, mixed; filter by collection and license |
| 8 | Europeana | key; `api2demo` works for tests | `edmIsShownBy` often IIIF max | `rights` URI, `reusability=open` filter | Wide, patchy for 1960s psychedelic (0 hits for the query tried) |

Recommended integration order: LOC, NASA, Smithsonian, Met, Wikimedia Commons (curated categories only), Cleveland, Internet Archive. Europeana as a later optional provider.

## Per-source notes

### Library of Congress (rank 1)
- Search: `https://www.loc.gov/photos/?q=<terms>&fo=json&c=<count>&sp=<page>&fa=online-format:image`; per collection `https://www.loc.gov/collections/<slug>/?fo=json&q=..`. Confirmed slugs: `fsa-owi-color-photographs` (1623), `carol-m-highsmith` (1394 for "highway"), `detroit-publishing-company` (25391). Yanker poster collection is reached through `/photos/` (the collection slug returned no pagination).
- Item detail: `https://www.loc.gov/item/<id>/?fo=json` returns `resources[0].files` with every derivative: for Highsmith a IIIF set (pct:6.25/12.5/25 plus a 7041x5562 JP2), for FSA color a 1024 px `v.jpg` and a master TIFF (144 MB, avoid), for Yanker posters only a 640 px `r.jpg` and a TIFF.
- IIIF: `https://tile.loc.gov/image-services/iiif/service:pnp:highsm:13000:13052/full/2048,/0/default.jpg` returned a real 2048x1617 JPEG (422 KB). Build the service id from the item's own file URLs rather than guessing.
- Old `/pictures/` endpoint still answers (`loc.gov/pictures/search/?q=..&fo=json`) but the item resource block returned null, so the OpenPics "largest/larger/large" lesson no longer applies; use `/item/<id>/?fo=json` files instead.
- Rights: `item.rights_advisory`/`rights`, for example "No known restrictions on publication" (Yanker). Per-image text, store it as the credit. Highsmith is donated to the public domain.
- Limits: documented burst limits with CAPTCHA/429 for abuse; stay under a few requests per second. Not exercised to failure.

### NASA Image and Video Library (rank 2)
- `https://images-api.nasa.gov/search?q=<q>&media_type=image&year_start=1965&year_end=1972` (no key). Asset list: `https://images-api.nasa.gov/asset/<nasa_id>` gives `~orig`, `~large`, `~medium`, `~small`, `~thumb`.
- Measured: `s69-35505~orig.jpg` 2973x1967, 790 KB. Hosts redirect http to https.
- Rights: US government work, generally public domain, but some images carry third-party credit; keep `center`, `photographer` and `description`.
- Fit: Apollo, Gemini, Mercury, Earth rise, nebula plates. Strongly "space-age retro".

### Wikimedia Commons (rank 3)
- `https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=<q>&gsrnamespace=6&gsrlimit=N&prop=imageinfo&iiprop=url|size|mime|extmetadata&format=json`; categories via `list=categorymembers`.
- Free text search is noisy (a "highway 1950s" query returned a cinema photo, an SVG template and a PNG diagram). Needs curated category lists, `filetype:bitmap`, min width filter and an allowlist of `LicenseShortName` values (PD, CC0, CC BY, CC BY-SA). `Special:FilePath/<name>?width=2048` serves scaled copies.
- Rights are in `extmetadata` (License, Artist, Credit, AttributionRequired).
- Needs a descriptive User-Agent; be gentle.

### Smithsonian Open Access (rank 4)
- `https://api.si.edu/openaccess/api/v1.0/search?q=<q>+AND+online_media_type:Images&api_key=<key>&rows=N`. `DEMO_KEY` worked but reported `x-ratelimit-limit: 10` per window; a free api.data.gov key is needed for real use (document key setup; mode must run without it).
- Each row has `metadata_usage.access` (CC0) and `online_media.media[]` with ids.si.edu URLs. Many rows have no `online_media`; filter on the media type and CC0 flag in the query. Max resolution not measured.
- Fit: National Museum of American History 1960s objects ("Psychedelic Thermos"), posters, Freer, SAAM, NASM (space).

### The Met (rank 5)
- Important change found: the old `/public/collection/v1/search` was retired on 2026-10-01 (response says so). Use `https://collectionapi.metmuseum.org/public/collection/v1.1/search?hasImages=true&isPublicDomain=true&q=forest&limit=..` (offset/limit paging, returns `objectIDs`), then `/v1/objects/<id>` for `primaryImage`, `isPublicDomain`, `objectDate`, `artistDisplayName`.
- Measured: Wheat Field with Cypresses original 4000x3184. A normal User-Agent is needed for the image host in some cases.
- Fit: landscapes, trees, prints, Japanese woodblocks. Little 1950-70.

### Cleveland Museum of Art (rank 6)
- `https://openaccess-api.clevelandart.org/api/artworks/?q=<q>&has_image=1&cc0=1&limit=N&fields=title,images,share_license_status,url`. No key. "forest" has 209 CC0 hits, "landscape" 1595.
- `images.web` 778 px, `images.print` 1536x1931 (2.6 MB, measured), `images.full` tiff for large files.
- `share_license_status` = CC0, plus `url` for credit.

### Internet Archive (rank 7)
- `https://archive.org/advancedsearch.php?q=mediatype:image AND collection:<c>&fl[]=identifier&fl[]=licenseurl&rows=N&output=json`; files via `https://archive.org/metadata/<id>` then `https://archive.org/download/<id>/<file>`. Collections seen: `nasa` 188,766 images, `flickrcommons` 802 images. `prelinger` and others reported 0 images (they are film or text).
- Licenses vary per item and many are CC BY-NC-ND (the 'vintage car' sample), which fails Liminal's licensing rule; require `licenseurl` PD/CC0/BY or collection-level PD.
- The IIIF URL guess `iiif.archive.org/iiif/3/<id>$<file>` returned 404; use direct downloads.

### Europeana (rank 8)
- `https://api.europeana.eu/record/v2/search.json?wskey=<key>&query=..&media=true&qf=TYPE:IMAGE&reusability=open&profile=rich`. `api2demo` works for tests; get a free key for production. `REUSABILITY` as a qf is invalid; use the `reusability` parameter.
- `edmIsShownBy` is often a IIIF `full/max` link from the provider. Rights per item in `rights`. "NEW HIGHWAY OPENED" (National Library of Israel) came back CC BY 4.0. The "1960s psychedelic" query returned zero hits.

## Others evaluated

| Source | Result |
|---|---|
| Rijksmuseum | New keyless Linked Art API: `https://data.rijksmuseum.nl/search/collection?imageAvailable=true&type=painting` returned 4,929 hits; objects resolve at `https://id.rijksmuseum.nl/<id>`, images via IIIF in the object graph. Old-masters dominated, low fit. |
| Art Institute of Chicago | `api.artic.edu` works keyless, IIIF `info.json` reports 3000x2465, but full-size requests are blocked by an IIIF allowlist; only 843 px was served (measured). Many results are not public domain (`is_public_domain` false). Low priority. |
| Openverse | `https://api.openverse.org/v1/images/?q=..&license_type=commercial&source=wikimedia,nasa,flickr` works keyless; anonymous 20/min, 200/day. Sizes mostly 1024 px Flickr `_b`. Useful as a discovery layer only. Smithsonian is not an indexed source. |
| DPLA | Needs a key (403 without), key by POST with an email. Aggregates other hubs. Unverified beyond that. |
| NYPL Digital Collections | Needs a token (401 without). Unverified. |
| NARA Catalog | v2 needs a key by emailing Catalog_API@nara.gov (10,000 requests/month, x-api-key header); endpoint serves HTML without it. Skip for now. |
| Biodiversity Heritage Library | Needs a key (401). Fit for mushroom/botanical plates. Candidate later; also reachable through Wikimedia and IA. |
| Flickr Commons (and BPL, Cambridge Historical Society) | Needs an API key (error code 100 without). Candidate later. |
| Getty, Paris Musees, Calisphere, David Rumsey, Trove | Not usable keyless in this pass (Getty 404 on the guessed URL, Paris Musees GraphQL and Rumsey 200 HTML, Calisphere 202). Unverified. |
| Unsplash, Pexels, Pixabay | Need keys and carry attribution/hotlink rules; modern stock photography, wrong vibe. Skip. |
| LIFE archive, Reddit subs | Gone or rights unclear. Exclude. |

## Lessons for the implementation
- Prefer keyless: LOC, NASA, Wikimedia, Met, Cleveland, Internet Archive. Smithsonian and Europeana are optional with a key; mode must run without them.
- Download the best derivative at or above 2048 px on the long side, avoid TIFF and files above about 12 MB (OpenPics lesson), and cache on disk with the credit record (title, creator, institution, source URL, license).
- Many 1950s-70s items are portrait or small (posters at 640 px, FSA 1024 px). Gate on a minimum short side and let `ImageFraming` cover-crop to 3:2; reject sources too small to cover 2K.
- Use curated query lists and collections per theme rather than free text, and filter on the rights field per image.
- Send a descriptive User-Agent, honour 429s, and keep requests to a few per second.
