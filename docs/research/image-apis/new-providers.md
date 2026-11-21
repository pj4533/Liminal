# Institutions that would need a new provider (tested 2026-11-21)

These sources cannot be reached through the existing `loc`, `nasa`, `wikimedia`, `cma`, `met` or `si` providers. Each one was called live with curl or Python (User-Agent `Liminal/1.0 (research)`, at most about 1 request per second). Sizes are from real downloads, measured with `sips` or PIL. The Library of Congress is out of scope here because another agent covers it.

## Ranking by value to Liminal

| Rank | Institution | Auth | Verified size route | Rights field | Vibe fit | Effort |
|---|---|---|---|---|---|---|
| 1 | **Digital Commonwealth / Boston Public Library** (Tichnor Brothers linen postcards) | none | IIIF `full/!2528,2528` → 2528x1616; `full/full` → 3300x2109 | `reuse_allowed_ssi` = "no restrictions", `license_ss` | Excellent: 1930-45 linen postcards of motels, highways, moonlit main streets, diners and skylines | Low: one JSON search plus IIIF |
| 2 | **Art Institute of Chicago** | none | IIIF `full/3000,` only (3000 px long side, capped at native) | `is_public_domain` (CC0) | Good: Hudson River School, Inness, ukiyo-e, 19th-century photographs, Impressionists | Low, but needs care with rate limits and query building |
| 3 | **Minneapolis Institute of Art (Mia)** | none | `https://1.api.artsmia.org/full/<id>.jpg` → 2956x1968 | `rights_type` = "Public Domain" | Good: large Japanese print collection, American painting, photographs | Low |
| 4 | **Internet Archive, GeoDIL collection** (thin sections only) | none | `archive.org/download/<id>/<file>` originals, 2548-5175 px | `licenseurl` = CC0 | Excellent but tiny: 68 polarised-light rock thin sections, very psychedelic | Low (pinned list or a generic IA provider) |
| 5 | **Rijksmuseum** (Linked Art API) | none | micr.io IIIF `full/max` → 5140x4544; `full/!2528,2528` → 2528x2235 | CC0 / Public Domain Mark in the object graph | Medium: Hiroshige (171 prints), moonlight titles (214), Dutch landscapes, 19th-century photographs | Medium: 3 extra requests per object |
| 6 | **Getty Museum** | none | IIIF `full/full` → 4708x3716; any size | `subject_to` → CC0, display name "Public Domain" | Medium: Watkins and other 19th-century landscape photographs | Medium: SPARQL search plus Linked Art |
| 7 | **National Gallery of Art** | none (images) | IIIF any size; `full/full` → 2674x3798 | `openaccess` = 1 in `published_images.csv` | Medium: American landscapes, photographs | Medium: no search API; bundle a curated id list |
| 8 | **Yale Center for British Art** | none (images) | IIIF `full/full` → 5927x8282 (8 MB, 15 s) | manifest `rights` = CC0 | Low to medium: Turner, Constable, botanical | High: no usable keyless search (LUX returned 202 HTML); slow image server |

Not usable without a key or a browser: NYPL, NARA, Smithsonian (DEMO_KEY), Harvard Art Museums, Walters, Paris Musées, Biodiversity Heritage Library, Flickr Commons, NPS. Details are at the end.

---

## 1. Digital Commonwealth (Boston Public Library): Tichnor Brothers postcards

- **Search (keyless JSON, Blacklight):**
  `https://www.digitalcommonwealth.org/search.json?q=<q>&per_page=<n>&page=<p>&f[related_item_host_ssim][]=The%20Tichnor%20Brothers%20Collection`
  - Response: `{links, meta, data[]}`. Totals are in `meta.pages.total_count`. Paging is by `page`; `links.next` is present while more pages exist.
  - Measured totals inside the Tichnor collection: motel 2,684, highway 1,031, night 495, skyline 180, desert 99, diner 70. All 30 sampled records per query were "no restrictions".
- **Fields** (`data[].attributes`):
  - Id: `id` (`commonwealth:xs55mj59t`).
  - Image id: `exemplary_image_ssi` (`commonwealth:xs55mj60k`).
  - Title: `title_info_primary_tsi`.
  - Date: `date_tsim` (`[ca. 1930–1945]`) and `date_start_dtsi`.
  - Creator: `publisher_tsi` ("Tichnor Quality Views … Tichnor Bros., Inc., Boston").
  - Rights: `rights_ss` ("No known copyright restrictions."), `license_ss` ("No known restrictions on use.") and `reuse_allowed_ssi` ("no restrictions").
  - Credit and link: `physical_location_ssim` (Boston Public Library) and `identifier_uri_ss` (ark URL).
  - Also available: `genre_specific_ssim` (Postcards), `subject_facet_ssim`, and `identifier_iiif_manifest_ss`.
- **Image (keyless IIIF 2):**
  - Size check: `https://iiif.digitalcommonwealth.org/iiif/2/<exemplary_image_ssi>/info.json`.
  - Download: `https://iiif.digitalcommonwealth.org/iiif/2/<exemplary_image_ssi>/full/!2528,2528/0/default.jpg`.
  - Measured: `full/full` 3300x2109 (2.2 MB, 0.5 s); `!2528,2528` 2528x1616 (1.3 MB).
  - Eight more postcards measured 3295-3336 x 2088-2181.
- **Rights gate:** keep only `reuse_allowed_ssi == "no restrictions"`. Other BPL collections on the same site are mixed; the Leslie Jones photographs, for example, are licensed CC BY-NC-ND. Map "No known restrictions on use." to the allowlist's "No known restrictions".
- **Fit and caveats:**
  - Linen-texture colour, moonlit streets, motels with 1940s cars, highway curves and sunsets: the strongest new match for "retro roadside".
  - Each card has a small printed caption strip and a handwritten accession number in a corner, and some have a white border. `BorderTrimmer` and the text-coverage rule should handle most of them. Multi-view motel cards with inset panels look busier; reject titles containing "Greetings" and "views".
  - Suggested queries: motel, highway, night, skyline, desert, "route 66", bridge, lake, sunset, diner.
- **Rate limits:** none hit at 1 request per second (about 40 requests).

## 2. Art Institute of Chicago: there is a high-resolution route

- **Search:**
  `https://api.artic.edu/api/v1/artworks/search?q=<q>&query[term][is_public_domain]=true&fields=id,title,image_id,is_public_domain,thumbnail,artwork_type_title,artist_title,date_display,credit_line&limit=<≤100>&page=<p>`
  - The search is Elasticsearch-backed, so a full ES body can also be sent with POST.
  - Note: a `query` clause combined with `q` falls back to popularity ranking. "moonlight" with the Painting type returned Seurat, Van Gogh and Renoir. Put the text in the query itself, for example `query[bool][must][][match][title]=moonlight`, or keep a pinned list.
- **Fields:**
  - Native size: `thumbnail.width` and `thumbnail.height`, so the size can be gated without an `info.json` call.
  - Rights: `is_public_domain`.
  - Also: `image_id`, `artist_title`, `date_display`, `artwork_type_title`, `credit_line`.
  - Artwork type ids: Painting 1, Photograph 2, Print 18, Drawing and Watercolor 14.
- **Image — the earlier finding of an 843 px cap is not the whole story.** The IIIF server allows only a fixed set of widths:

  | Request | Result |
  |---|---|
  | `full/843,` | 200 |
  | `full/1686,` | 200 (1686x1256, short side under the gate) |
  | `full/3000,` | 200 |
  | Widths listed in `info.json` `sizes` (2949 tested) | 200 |
  | `full/2000,`, `full/2528,`, `full/full`, `full/max`, `full/!2528,2528`, `full/pct:50` and tiles | 403 |

  `full/3000,` serves the image at 3000 px on the long side, or at native size when the image is smaller. It never upscales, and portraits are fitted by height:

  | `image_id` | Native | Served by `full/3000,` |
  |---|---|---|
  | `cef4e5df-…` | 3000x2235 | 3000x2235 (2.3 MB) |
  | `09b6a369-…` | 2971x2250 | 2971x2250 |
  | `18092196-…` | 10490x8127 | 3000x2324 |
  | `99e276fd-…` (portrait) | 6514x8315 | 2350x3000 (`,3000` gave the same) |
  | `d55b0cfc-…` | 1832x2250 | 1832x2250 |

  Use `https://www.artic.edu/iiif/2/<image_id>/full/3000,/0/default.jpg` and gate on `thumbnail` width and height of at least 2000x1333.
- **Rights:** `is_public_domain == true` means CC0 under AIC's open-access terms. Many results are not public domain, so check each record.
- **Rate limits:** HTTP 429 from `api.artic.edu` after about 6 searches plus about 125 IIIF requests in roughly 4 minutes at 1.1 s spacing. The documented anonymous limit is about 60 requests per minute, apparently shared across both hosts. Keep at most 1 request every 2 s and back off on 429.
- **Fit:** Hiroshige (30/30 passed size in the sampled query), Inness, Cole, Watkins, Le Gray, Monet's haystacks and water lilies. Good but not mid-century.

## 3. Minneapolis Institute of Art (Mia)

- **Search (keyless Elasticsearch proxy):** `https://search.artsmia.org/<query>?size=<n>&from=<offset>` (Lucene syntax in the path). `hiroshige image:valid public_access:1` returned 957 hits. Response: `hits.total.value` and `hits.hits[]._source`.
- **Fields:**
  - `_id` (object id), `title`, `artist`, `dated`, `classification`.
  - Rights: `rights_type` ("Public Domain" or "In Copyright"; filter client-side, because the query above also returned an in-copyright print).
  - Image availability: `image` ("valid"), `image_width`, `image_height`, `restricted`, `public_access` and `Rights_Image_Display` ("Full").
- **Image:**
  - `https://1.api.artsmia.org/full/<id>.jpg` returned 2956x1968 (1.6 MB), the native size from `image_width` and `image_height`.
  - `/800/<id>.jpg` returned 800x533. `/1600/`, `/2000/` and `/3000/` returned 403.
  - Other hosts failed: `api.artsmia.org/images/...` and `iiif.dx.artsmia.org` timed out, and `img.artsmia.org` returned 403.
- **Page and credit:** `https://collections.artsmia.org/art/<id>`, credited to "Minneapolis Institute of Art".
- **Fit:** Japanese landscape prints (Hiroshige, Hokusai, Hasui; apply the same ≤1930 date rule as for Commons shin-hanga) and American painting.

## 4. Internet Archive: GeoDIL thin sections

- **Collection:** `geodil_images` (2,716 items, all `licenseurl` CC0; Geoscience Digital Image Library, University of North Dakota).
- **Search:** `https://archive.org/advancedsearch.php?q=collection:geodil_images AND description:"thin section"&fl[]=identifier&fl[]=title&fl[]=licenseurl&rows=<n>&page=<p>&output=json` returned 68 items.
- **Record and file:** `https://archive.org/metadata/<id>` gives `metadata.description` (HTML, title in the first `<p>`), `creator`, `date` and `licenseurl`, plus `files[]` (take `source == "original"` with format JPEG). Download from `https://archive.org/download/<id>/<file>`.
- **Measured sizes:** thin sections 2548-2674 px wide (most about 2600x1810) and 5111-5175 px (5175x3608). The rest of GeoDIL (gems, hand specimens) is mostly under 2000 px (median about 1600) and is off-vibe.
- **Fit:** saturated interference colours: the most psychedelic natural imagery found in this pass.
- **Recommendation:** either a tiny generic "ia" provider (collection query, original file, `licenseurl` allowlist, size from a Range read) or a pinned list. Thin-section ids seen: GeoDIL-2634, -2636, -2633, -2563, -2538, -1514, -2556, -2573, -2628, -2622, -2626, -2630.
- **Other IA notes:**
  - The general public-domain image pool (299,161 items with `licenseurl:*publicdomain*`) is dominated by `opensource_image`, `community` and meme uploads, so it is rejected.
  - `collection:flickrcommons` has 802 items. `usgsphotography`, `noaa`, `nationalparkservice` and `tichnorbrothers` do not exist as image collections.

## 5. Rijksmuseum (keyless Linked Art)

- **Search:** `https://data.rijksmuseum.nl/search/collection?<filters>&imageAvailable=true` returns `orderedItems[]` (100 per page) with a `next` link and `partOf.totalItems`. Filters that worked: `creator`, `type` (painting, print, photograph), `title`, `description`, `creationDate` (`1850-1870`).

  | Search | Hits |
  |---|---|
  | `creator=Utagawa Hiroshige&type=print` | 171 |
  | `title=maanlicht` | 214 |
  | `description=paddenstoelen` | 48 |
  | `creator=Kawase Hasui` | 10 |
  | `type=photograph&creationDate=1850-1870&title=landschap` | 16 |

- **Object to image (three hops, `Accept: application/ld+json`):**
  1. `https://id.rijksmuseum.nl/<id>` gives `shows[0].id` (a VisualItem).
  2. The VisualItem gives `digitally_shown_by[0].id` (a DigitalObject).
  3. The DigitalObject gives `access_point[0].id`, for example `https://iiif.micr.io/zqZco/full/max/0/default.jpg`.
- **Image:** `https://iiif.micr.io/<id>/full/!2528,2528/0/default.jpg`.
  - `full/max` returned 5140x4544 (5.4 MB, 1.1 s).
  - `!2528,2528` returned 2528x2235 (1.4 MB, 2.6 s).
  - `2528,` returned the same image but took 21 s once.
- **Fields:**
  - Title: `identified_by[type=Name].content`.
  - Maker: `produced_by.part[].carried_out_by[]` (resolve the id for the name), with `notation` for "anonymous".
  - Rights: the object graph carries `https://creativecommons.org/publicdomain/zero/1.0/` (at `subject_of[].subject_to[].classified_as`) and the Public Domain Mark (at `subject_of[].digitally_carried_by[].referred_to_by[].content`).
- **Rate limits:** none hit at about 1 request per second.
- **Fit:** medium. Old masters dominate, but the Hiroshige series, moonlit Dutch landscapes and early photographs fit.

## 6. Getty Museum (keyless SPARQL plus Linked Art plus IIIF)

- **Search:** POST a `query=` form field to `https://data.getty.edu/museum/collection/sparql` (`Accept: application/sparql-results+json`). A title `CONTAINS("yosemite")` query took 4.1 s.
- **Object:** `https://data.getty.edu/museum/collection/object/<uuid>` (JSON-LD).
  - Image: `representation[0].id` = `https://media.getty.edu/iiif/image/<uuid>/full/full/0/default.jpg`.
  - Title: `_label` and `identified_by`.
  - Rights: `subject_to[]`, classified as `http://creativecommons.org/publicdomain/zero/1.0/` with display name "Public Domain".
  - Credit line: `referred_to_by` ("Source Credit Line").
- **Image:** `full/full` returned 4708x3716 (3.3 MB, 1.0 s); `!2528,2528` returned 2528x1995 (1.0 MB).
- **Fit:** Carleton Watkins, Muybridge and other 19th-century photographs and landscapes. Medium; similar to Met and CMA photographs.

## 7. National Gallery of Art (images keyless, no search API)

- **Data:** GitHub `NationalGalleryOfArt/opendata`. `data/published_images.csv` (92 MB) has columns `uuid, iiifurl, iiifthumburl, viewtype, sequence, width, height, maxpixels, openaccess, created, modified, depictstmsobjectid, assistivetext`. `data/objects.csv` (83 MB) has title, attribution, date and classification. `objects_terms.csv` has keywords.
- **Image:** `https://api.nga.gov/iiif/<uuid>/full/!2528,2528/0/default.jpg`. Measured `full/full` 2674x3798 (3.5 MB, 0.24 s) and `!2528,2528` 1780x2528.
- **Rights:** `openaccess == 1` means CC0.
- **Recommendation:** build a curated id list offline (for example "landscape" or "moonlight" terms with `openaccess=1`, `viewtype=primary` and long side ≥ 2000) and ship it as a pinned-only source.

## 8. Yale Center for British Art

- **Manifest:** `https://manifests.collections.yale.edu/ycba/obj/<objectId>` (keyless) gives `rights` = CC0 and image ids `https://images.collections.yale.edu/iiif/2/ycba:<uuid>`.
- **Image:** `full/full` returned 5927x8282 (8 MB, 15 s); `!2528,2528` returned 1809x2528 (10.5 s). The server is slow.
- **Search:** LUX (`https://lux.collections.yale.edu/api/search/item?q=…`) answered 202 with HTML, so it is not usable keyless.
- **Recommendation:** pinned list only, low priority.

## Not usable keyless (rejected for now)

| Institution | What was tried | Result |
|---|---|---|
| NYPL Digital Collections | `images.nypl.org/index.php?id=1260573&t=w` | 760x588 |
| | `t=q`, `t=v`, `t=g` | 404 |
| | `iiif.nypl.org/iiif/3/<imageID>/info.json` | 200, keyless, `maxArea` 400M, but this image's master is only 760x588 |
| | `api.repo.nypl.org` | 401 (token) |
| | digitalcollections.nypl.org search | Incapsula JS challenge; not bypassed |
| | Verdict | A free API token would allow search; IIIF is then keyless. Re-test with a token. |
| NARA Catalog v2 | `catalog.archives.gov/api/v2/records/search` | SPA HTML without `x-api-key`. Keep using the Commons DOCUMERICA mirror (3000 px). |
| Smithsonian Open Access | DEMO_KEY | 429 on the first call (`x-ratelimit-limit: 10`, remaining 0; the shared quota was already spent). Needs a real api.data.gov key. |
| Harvard Art Museums | `api.harvardartmuseums.org/object` | 401 (apikey required) |
| Walters | `api.thewalters.org/v1/objects.json` | 403 HTML |
| Paris Musées | GraphQL `apicollections.parismusees.paris.fr/graphql` | 403 HTML (token) |
| Biodiversity Heritage Library | `api3` | 401 (key). Plates are reachable through Commons and IA. |
| Flickr Commons | `flickr.photos.search` | error 100 (key). The NOAA and Apollo Flickr streams are mirrored on Commons. |
| NPS (NPGallery / developer API) | `developer.nps.gov/api/v1/...` | 403 (key) |
| Openverse | `api.openverse.org/v1/images` | Keyless but limited to 20/min and 200/day anonymous; results re-index Commons and Flickr. Discovery only. |
| Europeana | not re-tested | Survey verdict stands: mostly 400-1000 px previews; key required. |
