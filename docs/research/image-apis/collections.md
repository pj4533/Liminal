# Curated image collections (2026-11-21)

This file records which public collections and queries Liminal's curated pictures rotate through, and why. It follows [survey.md](survey.md), which ranks the APIs, and [openpics.md](openpics.md), which covers the earlier OpenPics project. The machine-readable result is [`Liminal/Visual/ImageSources/image-collections.json`](../../../Liminal/Visual/ImageSources/image-collections.json).

## Method

- On 2026-11-21 a Python probe called every API live. It made about 80 searches and examined about 900 records.
- **How sizes were measured.** For each record the probe recorded the id, title, date, rights field and full-resolution URL. It read the real pixel size from the image header (an HTTP Range read of 256 KB) or from the IIIF `info.json`.
- **Spot checks.** Ten images were downloaded whole and measured with `sips`. Every one matched the reported size. For example, LOC IIIF `full/2048,` returned 2048x1365, NASA `as13-60-8588~orig` was 4095x4095, CMA `1948.306_print.jpg` was 3400x2270, the Commons DOCUMERICA original was 3000x2023 and its `Special:FilePath?width=2048` copy also measured 3000x2023, and a Commons LOC photochrom was 7280x5340.
- **Visual review.** About 400 thumbnails were laid out on review sheets with the same 3:2 centre cover crop that `ImageFraming` uses, and each was judged for vibe. The judging asked: is it psychedelic, surreal or mid-century, and does it have calm or dark areas where the archive footage can show through? Text pages, documents, identifiable private portraits and unclear rights were rejected.
- **Where the files are.** The probe script, raw JSON and thumbnails are in the session scratchpad (`imageapi/probe/`), outside git. The contact sheet of 56 picks is at `share/imgapi/samples.jpg` in the scratchpad, also outside git. Every image on it is at least 2048 px on the long side.

## Results by source

The table lists the sources that were kept. "Long side" is the measured size of the best derivative the app should fetch.

| Source id | Provider / query | Measured long side | Licence | Vibe | Weight |
|---|---|---|---|---|---|
| loc-highsmith-roadside | LOC `carol-m-highsmith`: neon, diners, drive-ins, Route 66, vintage cars, gas stations | 3000-11600 (JP2 masters, IIIF scaled to 2048) | "No known restrictions on publication" | Neon diners and motels at night, drive-in screens, Edsel grilles, Havana Chevrolets | 3 |
| loc-highsmith-landscape | LOC Highsmith: redwoods, fog, Monument Valley, desert highway, skyline at night | 3192-11608 | same | Golden Gate in fog, redwood canopies, dusk skylines with light trails | 2 |
| loc-fsa-owi-color | LOC `fsa-owi-color-photographs` (1939-44 Kodachrome slides): landscape, road, highway, main street, town, trees, farm, railroad, sky, night | 4641-7738 (scanned TIFF masters through IIIF `master:`) | "No known restrictions on publication" | Feininger's Main Street in Creede, Russell Lee's Million Dollar Highway, small towns, farms, desert | 2 |
| nasa-space-age | NASA: Apollo, Gemini and Skylab Earth views, lunar surface, 1975-77 Ames space-colony art | 3000-10479 (Hasselblad scans are about 4096 square) | US Government work, generally not copyrighted | Earthrise, deep-blue Gemini Earth-sky views, Stanford torus paintings | 3 |
| nasa-deep-space | NASA: nebula, pillars of creation | 2448-7857 (some below 2K) | same | Psychedelic colour fields, mostly dark backgrounds | 1 |
| documerica-1970s | Wikimedia Commons, EPA DOCUMERICA (NARA scans) | 3000 (3000x2000, already 3:2) | Public domain | 1971-77 Kodachrome: sunsets, highway traffic at dusk, refineries, Louisville at night. The strongest 1970s source | 3 |
| fungi-photographs | Commons featured and quality pictures of fungi | 2306-5184 | CC BY-SA / CC BY / PD per file | Fly agarics and shelf fungi on dark forest floors | 2 |
| fungi-plates | Commons *Icones Farlowianae* (1929), Cooke *Illustrations of British Fungi* (1888) | 2063-3388 | PD / CC BY 2.0 | Botanical mushroom plates on cream paper | 1 |
| haeckel-art-forms | Commons *Kunstformen der Natur* (parent category, LOC copies) | 6000-8952 (portrait) | PD | Symmetric psychedelic natural forms | 1 |
| landsat-earth-as-art | Commons: eight pinned USGS/NASA Landsat false-colour scenes (*Earth as Art*, MSS near-infrared 1972-81, Lena Delta, Malaspina Glacier, Holuhraun) | 2015-7193 | PD / CC BY 2.0 / CC0 per file | Saturated magenta, cyan and orange colour fields: the most psychedelic source. Added 2026-11-21 in the verification (D42); the posters in the same search carry text and are not pinned | 1 |
| photochrom-landscapes | Commons, LOC photochroms | 3300-7300 | PD | Hand-tinted 1890-1910 colour views: gorges, coasts, ruins | 2 |
| cma-ukiyoe-landscapes | Cleveland Museum of Art, `type=Print`: Hiroshige, Hokusai, moonlight | 3400 | CC0 | Night rain, fireworks, full moons | 1 (2 until D42) |
| cma-early-photographs | Cleveland, `type=Photograph`: landscape, forest, trees | 3400 | CC0 | 1850s-1900 albumen landscapes, Fontainebleau forest | 1 |
| met-landscapes | The Met: Mount Fuji (department 6), woodblock landscapes, moonlight, tree photographs (department 19) | 2000-4000 | CC0 if `isPublicDomain` | Hokusai, 1878 Calaveras Grove sequoias | 1 |
| si-american-landscapes (disabled) | Smithsonian: SAAM landscapes, NASM | 3000 (ids.si.edu, measured 2999x2263) | CC0 | American landscape painting | 1, needs a key |

### Library of Congress

- **Where the high resolution is.** Only items that expose a IIIF JP2 service reach 2K. In practice that means Carol M. Highsmith's archive (70,434 items), most of it photographed between 1980 and 2017. Its subjects are retro (neon, diners, drive-ins and Route 66), even though the photographs are recent. Twenty-result samples per query, counting how many were at least 2048 px:

  | Query | At least 2048 px |
  |---|---|
  | neon sign motel | 13/20 |
  | drive-in theater | 13/20 |
  | route 66 | 18/20 |
  | vintage car | 18/20 |
  | redwood forest | 13/13 |
  | Monument Valley | 15/15 |
  | fog | 15/15 |
  | old gas station | 14/15 |

- **Newer Highsmith items fall short.** Highsmith items catalogued from 2018 onward, for example the Lucky Motel and Santa Fe Club neon in Las Vegas, have only a 1024 px `v.jpg` and a TIFF master. Filter on the IIIF service (`requireIIIF`).
- **No extra request is needed for rights or size.** The search result already carries `item.rights_advisory` and the IIIF service id inside `image_url`. One `info.json` call gives the true size.
- **Scanned masters through IIIF (2026-11-21, after the user asked about high-res FSA photographs).** The OpenPics trick (`/pictures/item/<id>/?fo=json`, `resources[0].larger`) still names the master: for FSA/OWI colour it is a 46 MB TIFF (`storage-services/master/pnp/fsac/.../1a33849u.tif`). The IIIF image service serves that master under a `master:` prefix, not `service:`: `https://tile.loc.gov/image-services/iiif/master:pnp:fsac:1a33000:1a33800:1a33849u/info.json` reports 4698x3280, and `full/2528,/0/default.jpg` returned a 2528x1764 JPEG in 0.7 s. The id is the 1024 px `v.jpg` path with `/` as `:` and `v` replaced by `u`. Measured: 40 of 40 sampled FSA colour items have a master of at least 2000 px; photochrom `ppmsc:07700:07735u` is 2759x3666, Prokudin-Gorskii `prokc:20100:20159u` is 3808x3726, and a 2018 Highsmith item with only a `v.jpg` (`highsm:52000:52077u`) is 7313x4696. The Margolies items tried had only a thumbnail online. Two catches:
  - About half of the FSA masters answer every scaled request (`full/2528,`, `full/!2528,2528`, `pct:50`) with HTTP 500 and the same request again later, while `full/full/0/default.jpg` works (1-5 MB JPEG of the whole master, for example 7366x9175 in 4 MB). The app tries the scaled url and falls back to `full/full` on a 5xx; decode scales it.
  - The scans include the film rebate: black edges of different widths, edge codes, rounded mount corners and sometimes a green or amber film-base tint. `BorderTrimmer` needs four alike edges and leaves them. `ScanEdgeTrimmer` walks each side in while its middle 60% is mostly dark (luma < 0.16, at most 15% per side), adds a 2% inset, and trims at least 3% from every side. Checked on six live FSA masters: all six came out clean.
- **Previously rejected because they top out at 1024 px** (true of the `service:` derivatives; see the item above for the masters): photochroms (7,500), FSA/OWI colour (1,622), Prokudin-Gorskii (2,609), Detroit Publishing, Japanese fine prints, and the John Margolies Roadside America archive (11,751, an ideal subject, but 1024 only). Their masters are 30-144 MB TIFFs. IIIF `info.json` for the `v` derivative reports 1024, and the master ids return 404. Their masters turned out to be reachable (D44 in `decisions/images.md`).
- **Mid-century searches.** Searching `/photos/` with `dates=1950/1969` turned up few usable items. Most are 1024 px or smaller, and many are marked "Publication may be restricted" (New York World-Telegram) or "Rights status not evaluated". The 1960s psychedelic rock posters (Bill Graham and Avalon Ballroom) are "not evaluated", so they were rejected.

### NASA Image and Video Library

- **Size.** Every space-age query returned mostly images at least 2048 px: earth 15/15, launch 15/15, Gemini Earth views 12/12, Skylab 12/12, space colony 11/11 and lunar 14/15.
- **File weight.** The median `~orig` is 2-4.5 MB. A few panoramas or masters run to 13-47 MB, so fall back to `~large` when the original exceeds `maxBytes`.
- **What to reject.** Press-conference and crew-portrait items (for example `s66-45605` and `s65-33250`), and Voyager or ARC items with white borders or diagrams. Use `rejectTitleWords` and do not query "Voyager".
- **Nebula imagery.** Nebula queries span 1999-2022 and fall outside the period, but their colour fits the psychedelic brief, so they get a low weight.

### Wikimedia Commons

- **Use categories and search with care.** Free-text search is too noisy, but curated categories and `filetype:bitmap` searches inside DOCUMERICA work well.
- **DOCUMERICA.** It holds about 15,000 public-domain EPA photographs from 1971-77 across 90 photographer categories. They are scanned at 3000 px in 3:2, which makes them the best fit for "driving in the 70s" and retro cityscapes. "DOCUMERICA sunset" and "DOCUMERICA highway traffic" both returned 20/20 images at least 2048 px. Some scans are 2000 px (for example the 1974 EPA-lab series), and the size gate removes them.
- **LOC photochroms on Commons.** The copies were uploaded from the TIFF masters at up to 7300 px, so Commons is the way to get photochroms at full size. Filter out portraits ("girl", "belle") by title.
- **Haeckel.** Use the parent *Kunstformen der Natur* category. The *(1899)* subcategory is a full BHL book scan, mostly text pages. Some plates are TIFF duplicates; filter on mime.
- **Fungi photographs.** The featured pictures are modern CC BY-SA photographs, but the vibe (dark forest floor, glowing caps) is strong. They need an attribution credit (Artist plus licence).
- **Rejected categories:**
  - *Marbled paper*: book bindings with colour rulers.
  - *Toadstools, mushrooms, fungi, edible and poisonous*: 1908 px.
  - The Ansel Adams NARA series and the Zentralbibliothek Zürich photochroms: capped at 2000 px. They are beautiful but below the size gate.
  - *Googie architecture*: modern snapshots under mixed licences.
- **Rate limits.** Quick successive calls sometimes failed. Pace the requests at about 1 per second and send a descriptive User-Agent.

### Cleveland Museum of Art

- **Size.** The `images.print` derivative is now 3400 px on the long side. The survey measured it at 1536, so the museum has upgraded it. All 20 sampled records cleared 2048 in forest, landscape, night and Hiroshige queries. Never fetch `images.full`, which is a TIFF.
- **Filter by type.** Restrict to `type=Print` or `type=Photograph`. The mushroom query returns lamps, boxes and ritual objects, and the forest query returns Indian miniatures, which are off-vibe.
- **Little mid-century material.** `created_after=1945` with `created_before=1980` returns only 13 CC0 works.

### The Met

- **Sizes and the broken filter.** Originals are up to 4000 px. The v1.1 search ignores `isPublicDomain=true`: forest, mushroom and waves results included objects that are not public domain. Check `isPublicDomain` on each object. Use a classification allowlist, because "forest" returns furniture and cutouts and "mushroom" returns netsuke.
- **Bot wall.** After about 100 requests in a few minutes, an Incapsula WAF returned 403 HTML for both the API and `images.metmuseum.org`. Access recovered after a few minutes, but the image host stayed blocked for curl. The app must be gentle (about one object every few seconds), cache aggressively and treat 403 as a temporary outage.
- **Mirror.** The Internet Archive collection `metropolitanmuseumofart-gallery` (140,926 images) mirrors the Met. Each item has the original JPEG and a `_mma.json` record, which makes it a fallback.
- **Walker Evans** and 1950s photographs at the Met are not public domain.

### Smithsonian (optional)

- `DEMO_KEY` reported `x-ratelimit-limit: 10`, and the probe used all 10 requests.
- With the image filter, SAAM landscape rows had `online_media` whose ids.si.edu delivery URL served a 2999x2263 JPEG.
- The psychedelic query returned NMAH rows with `online_media: null`.
- The source is disabled unless `SMITHSONIAN_API_KEY` is set.

### Internet Archive

- Free-text image search mostly returns synthetic images, band photographs and uploader-asserted CC licences. The query "psychedelic" with a public-domain licenceurl gave 303 hits, mostly modern work. Rejected as a source.
- Its only use is the Met mirror described above.

### Europeana

- With `api2demo`, mushroom, 1960s automobile and forest queries returned mostly 400-1000 px previews. Only 2 of 31 were at least 2048 px. Rejected for now.

## Licensing approach

Keep the image only if its own record says it is reusable:

| Provider | Field to check | Required value |
|---|---|---|
| LOC | `rights_advisory` | "No known restrictions on publication" |
| NASA | (no field) | US Government work (keep the centre and photographer) |
| Commons | `LicenseShortName` | in `licenseAllowlist` (PD, CC0, CC BY, CC BY-SA) |
| CMA | `share_license_status` | CC0 |
| Met | `isPublicDomain` | true |
| Smithsonian | `metadata_usage.access` | CC0 |

Store the credit record (title, creator, institution, source URL, licence) with the cached file and show it the way archive film credits are shown. CC BY and CC BY-SA images require the creator and licence in that credit. Liminal does not alter or redistribute the files beyond showing them, but the credit should still be shown.

## Resolution summary

| Reaches 2K and above | Below 2K (rejected) |
|---|---|
| LOC Highsmith with IIIF (2048 served; masters 3000-11600) | LOC photochroms, FSA colour, Margolies, Prokudin-Gorskii (1024) |
| NASA (3000-4400 typical) | Highsmith items from 2018 on (1024) |
| Commons DOCUMERICA (3000x2000) | Ansel Adams NARA and the Zürich photochroms (2000) |
| Commons photochroms (3300-7300) and Haeckel (6000-8900) | Toadstools plates (1908) |
| CMA print (3400) | Europeana previews |
| Met (2000-4000) | |
| Smithsonian (3000) | |

The 3:2 cover crop costs the most on square NASA frames and portrait plates (Haeckel, fungi plates). Square NASA frames still leave 4096x2731. Portrait plates keep the centre band, and a 2300x3280 plate crops to about 2300x1533, which is above 1365 px tall.

## What needs a key

- **Smithsonian** needs an api.data.gov key (env `SMITHSONIAN_API_KEY`). The source is disabled without one.
- **Europeana** would need a key, but it is not used.
- **Every enabled source is keyless:** LOC, NASA, Commons, Cleveland and the Met.

## First live ingest (2026-11-21)

The app's own ingest ran on macOS and in the visionOS Simulator (decisions/images.md D41). 95 pictures were stored
from all 12 enabled sources and 14 were rejected: 4 DOCUMERICA files by a title rule that was then fixed, 5
*Icones Farlowianae* and Cooke plates under 2048 px (the gate now allows 2% under, which admits the 2026 px ones), 2
for text (a Haeckel plate caption and a neon sign, before the text rule was relaxed), 1 grey Earthrise
(`as8-15-2561`), 1 NASA original of 29 MB (`AC76-0628`) and 1 small Met print. LOC timed out once and backed off
for a minute; the Met did not hit its bot wall at 5 s per request.
