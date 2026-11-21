# API image sources

[← Image sources](README.md) · [Pipeline](pipeline.md) · [Providers](providers.md) · [Adding a source](adding-a-source.md) · [Research history](research-history.md)

Every source in `Liminal/Visual/ImageSources/image-collections.json` (version 2, updated 2026-11-21). 33 of 34 sources are enabled, with a total weight of 48. The JSON is the authority; this page was written from it on 2026-11-21. Measured sizes come from the research passes ([collections](../research/image-apis/collections.md), [other institutions](../research/image-apis/other-institutions.md), [new providers](../research/image-apis/new-providers.md)) and the live ingest runs (`decisions/images.md` D41-D44).

How to read the columns:

- **Weight** is how many times the source goes into the ingest rotation's bag (rounded, at least 1), and it also multiplies the display weight of its stored pictures. See [pipeline.md](pipeline.md#1-which-source-is-next).
- **Mono** says whether monochrome pictures may be stored (`allowMonochrome`). Even then, display shows at most one monochrome picture in six.
- **Pins** is the number of pinned ids, which are tried before any search.
- The licence shown in the app comes from each item's own record, never from the source's `license` note in the JSON (that field is documentation).

## All sources

| Source id | Provider | Weight | On | Mono | Pins | Searches | Shows |
|---|---|---|---|---|---|---|---|
| [`loc-highsmith-roadside`](#loc-highsmith-roadside) | loc | 3 | yes | no | 12 | 7 | retro roadside, neon, diners, drive-in |
| [`loc-highsmith-landscape`](#loc-highsmith-landscape) | loc | 2 | yes | no | 8 | 5 | landscapes, trees, fog, desert |
| [`loc-fsa-owi-color`](#loc-fsa-owi-color) | loc | 2 | yes | no | 0 | 10 | 1939-1944 Kodachrome, small towns, roads, farms |
| [`nasa-space-age`](#nasa-space-age) | nasa | 3 | yes | no | 13 | 5 | space age, earth from orbit, moon, 1960s |
| [`nasa-deep-space`](#nasa-deep-space) | nasa | 1 | yes | no | 5 | 2 | psychedelic, nebula, cosmic colour |
| [`documerica-1970s`](#documerica-1970s) | wikimedia | 3 | yes | no | 9 | 7 | 1970s, Kodachrome, highways, driving |
| [`fungi-photographs`](#fungi-photographs) | wikimedia | 2 | yes | no | 4 | 2 | mushrooms, fungi, forest floor |
| [`fungi-plates`](#fungi-plates) | wikimedia | 1 | yes | no | 0 | 2 | mushrooms, botanical plates, mycology |
| [`haeckel-art-forms`](#haeckel-art-forms) | wikimedia | 1 | yes | no | 4 | 1 | psychedelic, symmetry, natural forms, fungi |
| [`landsat-earth-as-art`](#landsat-earth-as-art) | wikimedia | 1 | yes | no | 8 | 0 | psychedelic, false colour, Earth as Art, rivers |
| [`photochrom-landscapes`](#photochrom-landscapes) | wikimedia | 2 | yes | no | 3 | 2 | vintage colour, landscapes, coasts, old views |
| [`cma-ukiyoe-landscapes`](#cma-ukiyoe-landscapes) | cma | 1 | yes | no | 6 | 3 | woodblock prints, night, rain, moon |
| [`cma-early-photographs`](#cma-early-photographs) | cma | 1 | yes | yes | 6 | 3 | trees, forests, landscapes, old photographs |
| [`met-landscapes`](#met-landscapes) | met | 1 | yes | no | 8 | 4 | woodblock prints, trees, giant sequoias, moonlight |
| [`si-american-landscapes`](#si-american-landscapes) | si | 1 | **no** | no | 0 | 2 | landscapes, American art |
| [`documerica-western-landscapes`](#documerica-western-landscapes) | wikimedia | 2 | yes | no | 15 | 12 | 1970s, Kodachrome, canyons, deserts |
| [`documerica-smog-and-neon`](#documerica-smog-and-neon) | wikimedia | 2 | yes | no | 12 | 4 | 1970s, smog sunsets, Las Vegas neon, light streaks |
| [`aurora-and-milky-way`](#aurora-and-milky-way) | wikimedia | 1 | yes | no | 8 | 2 | aurora, Milky Way, night sky, psychedelic colour |
| [`galaxies-hubble-webb`](#galaxies-hubble-webb) | wikimedia | 1 | yes | no | 7 | 1 | galaxies, Hubble, Webb, psychedelic colour |
| [`forests-featured`](#forests-featured) | wikimedia | 1 | yes | no | 4 | 2 | forests, trees, fog, autumn |
| [`apollo-archive`](#apollo-archive) | wikimedia | 1 | yes | yes | 3 | 1 | Apollo, lunar surface, Saturn V, space age |
| [`american-west-painters`](#american-west-painters) | wikimedia | 1 | yes | no | 7 | 2 | Hudson River School, Rocky Mountain School, Yosemite, Grand Canyon |
| [`shin-hanga-pinned`](#shin-hanga-pinned) | wikimedia | 1 | yes | no | 6 | 0 | shin-hanga, woodblock prints, snow, mist |
| [`nasa-orbital-earth-1960s`](#nasa-orbital-earth-1960s) | nasa | 2 | yes | no | 20 | 5 | space age, Earth from orbit, Mercury, Gemini |
| [`nasa-lunar-orbit`](#nasa-lunar-orbit) | nasa | 1 | yes | yes | 4 | 2 | Moon, earthrise, lunar orbit, Apollo 8-17 |
| [`nasa-aurora-from-orbit`](#nasa-aurora-from-orbit) | nasa | 1 | yes | no | 5 | 1 | aurora, Earth at night, psychedelic green and red, ISS |
| [`nasa-cape-kennedy-aerials`](#nasa-cape-kennedy-aerials) | nasa | 1 | yes | yes | 3 | 1 | space age, Cape Kennedy, launch pads, 1960s aerials |
| [`cma-american-landscapes`](#cma-american-landscapes) | cma | 1 | yes | no | 15 | 1 | Hudson River School, luminism, twilight, storm clouds |
| [`cma-weather-prints`](#cma-weather-prints) | cma | 1 | yes | no | 6 | 3 | night rain, snow, moonrise, woodblock prints |
| [`met-american-tonalists`](#met-american-tonalists) | met | 1 | yes | no | 5 | 1 | moonlight, Tonalism, Blakelock, Ryder |
| [`met-early-photographs`](#met-early-photographs) | met | 1 | yes | yes | 8 | 3 | 1850s salt and albumen prints, Le Gray, Fontainebleau, Yosemite |
| [`met-hiroshige-night`](#met-hiroshige-night) | met | 1 | yes | no | 4 | 1 | Hiroshige, night, moonlight, rain |
| [`dc-tichnor-postcards`](#dc-tichnor-postcards) | dc | 3 | yes | no | 0 | 12 | 1930-45 linen postcards, motels, highways, moonlit main streets |
| [`aic-landscapes`](#aic-landscapes) | aic | 1 | yes | no | 0 | 8 | 19th-century landscape painting and prints, moonlight, forests, rivers |

Weight by provider (enabled sources): wikimedia 20, nasa 9, loc 7, cma 4, met 4, dc 3, aic 1 (total 48).

## Credits by institution

API mode exists because these institutions publish their collections openly. Each stored picture keeps its own title, creator, date, institution, licence and page link, and the control panel shows them under **Now showing**.

- **Library of Congress**, Prints and Photographs Division: the Carol M. Highsmith Archive and the FSA/OWI Color Photographs; also the source of the photochroms and Haeckel plates mirrored on Commons.
- **NASA** (Johnson, Kennedy, Ames, JPL) through the NASA Image and Video Library, and through the Project Apollo Archive on Commons.
- **Wikimedia Commons** and its contributors, including the US National Archives (DOCUMERICA scans of the EPA project), the Biodiversity Heritage Library, the USGS (Landsat), ESA and STScI, the Google Art Project, the Rijksmuseum, and individual photographers credited by name.
- **Cleveland Museum of Art** Open Access (CC0).
- **The Metropolitan Museum of Art** Open Access (CC0).
- **Boston Public Library** through Digital Commonwealth: the Tichnor Brothers Collection.
- **Art Institute of Chicago** (CC0 public-domain works).
- **Smithsonian Institution** Open Access (provider coded, source disabled without a key).

The user-facing credits table is in [experience.md](../experience.md#api-image-sources).

<!-- LOC-BATCH: the upcoming Library of Congress batch goes here: add rows to the table above and a section per source below. -->

## Source by source

Each section lists the provider, what the source searches, what it shows, the measured size, the exact route to the high-resolution file, the rights field and the value that is accepted, and the full pinned list. `T` is the requested long side.

### loc-highsmith-roadside

- **Provider:** `loc` (Library of Congress). **Weight** 3. **Enabled:** yes. **Monochrome allowed:** no.
- **Collection slug:** `carol-m-highsmith`.
- **Queries:** `neon sign motel`, `diner neon`, `drive-in theater`, `route 66`, `vintage car`, `old gas station`, `roadside attraction`.
- **Filters:** `requireIIIF` (results without a IIIF service are dropped); `useMasters` (scanned-master IIIF route).
- **Shows:** Carol M. Highsmith's photographs of retro roadside America: neon motel and diner signs at night, drive-in screens, Route 66, vintage cars (an Edsel grille, Havana Chevrolets), old gas stations and roadside attractions. The photographs are 1980-2017, the subjects mid-century.
- **Measured:** IIIF masters 3000-11600 px; served at 2528 on the long side. Highsmith items catalogued from 2018 on have only a 1024 px `v.jpg`, and `useMasters` reaches their masters too (for example 7313x4696). Sample of 20 per query at 2048 px or more: neon sign motel 13, drive-in theater 13, route 66 18, vintage car 18, old gas station 14 of 15.
- **High-resolution route:** IIIF `service:` derivative when the result has one; otherwise the scanned master `https://tile.loc.gov/image-services/iiif/master:pnp:<path>u` derived from the 1024 px `v.jpg` path. Download `{service}/full/!T,T/0/default.jpg`; on HTTP 5xx from a `master:` service, `{service}/full/full/0/default.jpg` once.
- **Rights:** `item.rights_advisory` (else `rights_information`): "No known restrictions on publication" → **No known restrictions**.
- **Mood sent to the music:** electric, playful; subject architecture; energy 0.55; warmth 0.4.
- **Credit:** Carol M. Highsmith Archive, Library of Congress, Prints and Photographs Division (gift to the public). [Collection](https://www.loc.gov/collections/carol-m-highsmith/)

<details><summary>12 pinned ids</summary>

- `2013631471`
- `2017881793`
- `2015632003`
- `2017885609`
- `2010630400`
- `2010630069`
- `2010638658`
- `2011631207`
- `2010630156`
- `2013633512`
- `2015632614`
- `2014630329`

</details>

### loc-highsmith-landscape

- **Provider:** `loc` (Library of Congress). **Weight** 2. **Enabled:** yes. **Monochrome allowed:** no.
- **Collection slug:** `carol-m-highsmith`.
- **Queries:** `redwood forest`, `fog`, `Monument Valley`, `desert highway`, `skyline at night`.
- **Filters:** `requireIIIF` (results without a IIIF service are dropped); `useMasters` (scanned-master IIIF route).
- **Shows:** Highsmith landscapes: redwood canopies, the Golden Gate in fog, Monument Valley, desert highways, city skylines at dusk with light trails.
- **Measured:** IIIF masters 3192-11608 px; served at 2528. Samples: redwood forest 13/13, Monument Valley 15/15, fog 15/15 at 2048 px or more.
- **High-resolution route:** IIIF `service:` derivative when the result has one; otherwise the scanned master `https://tile.loc.gov/image-services/iiif/master:pnp:<path>u` derived from the 1024 px `v.jpg` path. Download `{service}/full/!T,T/0/default.jpg`; on HTTP 5xx from a `master:` service, `{service}/full/full/0/default.jpg` once.
- **Rights:** `item.rights_advisory` (else `rights_information`): "No known restrictions on publication" → **No known restrictions**.
- **Mood sent to the music:** majestic, serene; subject landscape; energy 0.3; warmth 0.1.
- **Credit:** Carol M. Highsmith Archive, Library of Congress. [Collection](https://www.loc.gov/collections/carol-m-highsmith/)

<details><summary>8 pinned ids</summary>

- `2013632523`
- `2013635145`
- `2013632243`
- `2013632725`
- `2011630130`
- `2011630273`
- `2016632994`
- `2013630402`

</details>

### loc-fsa-owi-color

- **Provider:** `loc` (Library of Congress). **Weight** 2. **Enabled:** yes. **Monochrome allowed:** no.
- **Collection slug:** `fsa-owi-color-photographs`.
- **Queries:** `landscape`, `road`, `highway`, `main street`, `town`, `trees`, `farm`, `railroad`, `sky`, `night`.
- **Filters:** `requireIIIF` (results without a IIIF service are dropped); `useMasters` (scanned-master IIIF route); `trimScanEdges` (film rebate trim, fetched at 1.35x).
- **Shows:** 1939-1944 Kodachrome slides of the Farm Security Administration and Office of War Information: small-town main streets (Feininger's Creede), Russell Lee's Million Dollar Highway, farms, rail yards, roads and skies.
- **Measured:** Scanned TIFF masters 4641-7738 px (40 of 40 sampled items had one, 2026-11-21). About half answer every scaled IIIF request with HTTP 500 and serve only `full/full` (1-5 MB JPEG). After `ScanEdgeTrimmer` removes 6-30% of the width, pictures are scaled back to 2528.
- **High-resolution route:** Scanned master `https://tile.loc.gov/image-services/iiif/master:pnp:fsac:<path>u` derived from the 1024 px `v.jpg` path (size from `info.json`). Download `{service}/full/!3413,3413/0/default.jpg` (1.35 x 2528, room for the rebate trim); on HTTP 5xx, `{service}/full/full/0/default.jpg` once.
- **Rights:** `item.rights_advisory` (else `rights_information`): "No known restrictions on publication" → **No known restrictions**.
- **Mood sent to the music:** melancholy, serene; subject landscape; energy 0.3; warmth 0.5.
- **Credit:** Farm Security Administration / Office of War Information Color Photographs, Library of Congress (US Government work). [Collection](https://www.loc.gov/collections/fsa-owi-color-photographs/)
- **Notes:** Colour only. The film rebate (black edges, edge codes, rounded mount corners, tinted base) is trimmed by `trimScanEdges` (D44).

### nasa-space-age

- **Provider:** `nasa` (NASA Image and Video Library). **Weight** 3. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `earth from apollo` (1966-1972), `gemini earth view` (1965-1966), `lunar surface` (1969-1972), `skylab earth` (1973-1974), `space colony` (1975-1977).
- **Filters:** whole-word title rejects: `press conference`, `presidential`, `portrait`, `diagram`, `chart`, `crew`.
- **Shows:** Apollo, Gemini and Skylab views of Earth, the lunar surface, Earthrise, and the 1975-77 Ames space-colony paintings (Stanford torus).
- **Measured:** Originals 3000-10479 px; Hasselblad scans are about 4096x4096 and keep 4096x2731 after the 3:2 crop. Median `~orig` 2-4.5 MB. One Ames painting (`AC76-0628`) is 29 MB and is rejected by the 12 MB limit.
- **High-resolution route:** `https://images-api.nasa.gov/asset/<nasa_id>` lists the files; the `~orig` JPEG or PNG is downloaded (http links upgraded to https) after a HEAD shows it is at most 12 MB. No `~large` fallback: it is only 1920 px.
- **Rights:** No per-item field: every item is credited as "US Government work (NASA media are generally not copyrighted)" → **Public domain**. Title reject words are the guard against third-party works.
- **Mood sent to the music:** majestic, eerie; subject celestial; energy 0.4; warmth -0.3.
- **Credit:** NASA (Johnson Space Center, Ames Research Center). [NASA Image and Video Library](https://images.nasa.gov/)
- **Notes:** The pinned grey Earthrise `as8-15-2561` was rejected as monochrome in the first live run (D41).

<details><summary>13 pinned ids</summary>

- `as11-44-6549`
- `as11-44-6552`
- `as13-60-8588`
- `as8-15-2561`
- `s65-34661`
- `s65-45763`
- `s66-63517`
- `as11-40-5927`
- `sl4-143-4707`
- `sl3-121-2371`
- `AC76-0628`
- `ARC-1975-AC75-1086`
- `ARC-1976-AC76-0525`

</details>

### nasa-deep-space

- **Provider:** `nasa` (NASA Image and Video Library). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `nebula` (1990-2026), `pillars of creation` (1995-2026).
- **Filters:** whole-word title rejects: `3-D`, `diagram`, `chart`, `keynote`.
- **Shows:** Nebulae and the Pillars of Creation: psychedelic colour fields on dark backgrounds. Outside the mid-century period, kept at weight 1 for the colour.
- **Measured:** 2448-7857 px; some results are under 2K and fail the size gate.
- **High-resolution route:** `https://images-api.nasa.gov/asset/<nasa_id>` lists the files; the `~orig` JPEG or PNG is downloaded (http links upgraded to https) after a HEAD shows it is at most 12 MB. No `~large` fallback: it is only 1920 px.
- **Rights:** No per-item field: every item is credited as "US Government work (NASA media are generally not copyrighted)" → **Public domain**. Title reject words are the guard against third-party works.
- **Mood sent to the music:** euphoric, majestic; subject celestial; energy 0.5; warmth 0.0.
- **Credit:** NASA, ESA, JPL (PIA images). [NASA Image and Video Library](https://images.nasa.gov/)

<details><summary>5 pinned ids</summary>

- `PIA14417`
- `PIA03096`
- `PIA03606`
- `PIA15658`
- `PIA25433`

</details>

### documerica-1970s

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 3. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:DOCUMERICA photographs by Charles O'Rear`; `Category:DOCUMERICA photographs by John Messina`.
- **Searches** (`filetype:bitmap` is added): `DOCUMERICA sunset`, `DOCUMERICA highway traffic`, `DOCUMERICA night`, `DOCUMERICA skyline`, `DOCUMERICA desert`.
- **Filters:** title or file name must contain `NARA`.
- **Shows:** The EPA's DOCUMERICA project (1971-77) in Kodachrome: sunsets, highway traffic at dusk, refineries, Louisville at night, Lake Mead. The strongest 1970s source.
- **Measured:** Almost all 3000x2000 (already 3:2). DOCUMERICA sunset and highway traffic searches: 20/20 at 2048 px or more. Some 1974 EPA-lab scans are 2000 px and fail the gate.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** melancholy, intimate; subject landscape; energy 0.4; warmth 0.5.
- **Credit:** Environmental Protection Agency, DOCUMERICA; scans by the US National Archives (NARA), via Wikimedia Commons. [Category:DOCUMERICA](https://commons.wikimedia.org/wiki/Category:DOCUMERICA)
- **Notes:** `requireTitleContains: "NARA"` keeps searches on NARA scans (the phrase is checked in the title and in the Commons file name).

<details><summary>9 pinned ids</summary>

- `File:SUNSET - NARA - 544071.jpg`
- `File:SUNSET - NARA - 544655.jpg`
- `File:OIL REFINERY IN THE SUNSET - NARA - 546384.jpg`
- `File:PUGET SOUND AT SUNSET, SEEN FROM MARYSVILLE - NARA - 552277.jpg`
- `File:EXPRESS BUS LANE ON SHIRLEY HIGHWAY, A MAJOR ARTERY CONNECTING THE NORTHERN VIRGINIA SUBURBS WITH THE CITY OF... - NARA - 553894.jpg`
- `File:5.P.M. TRAFFIC ON ROUTE 2 IN BAYOMAN - NARA - 546370.jpg`
- `File:MIDAFTERNOON TRAFFIC ON SHIRLEY HIGHWAY. ADDITIONAL LANES ARE UNDER CONSTRUCTION - NARA - 547222.jpg`
- `File:OHIO RIVER AND LOUISVILLE AT NIGHT - NARA - 545913.jpg`
- `File:A GOOD WIND AND A GOOD SAIL ON HOOVER DAM'S LAKE MEAD - NARA - 549082.jpg`

</details>

### fungi-photographs

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 2. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Featured pictures of fungi`; `Category:Quality images of fungi`.
- **Shows:** Modern photographs of fly agarics, shelf and bracket fungi on dark forest floors.
- **Measured:** 2306-5184 px.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** lush, eerie; subject plant; energy 0.35; warmth 0.1.
- **Credit:** Individual Wikimedia Commons photographers, credited by name with their licence. [Featured pictures of fungi](https://commons.wikimedia.org/wiki/Category:Featured_pictures_of_fungi)
- **Notes:** Mostly CC BY-SA. A file whose record names no creator is rejected (D43). One line (`enabled: false`) turns the source off.

<details><summary>4 pinned ids</summary>

- `File:Amanita muscaria qtl4.jpg`
- `File:Agaricales-20191229-RM-101505.jpg`
- `File:Bamberg Hain Pilze Unidentified Pholiota stack.jpg`
- `File:2017.05.13.-04-Bruehl Rohrhof--Laetiporus sulphureus (Gemeiner Schwefelporling).jpg`

</details>

### fungi-plates

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Icones Farlowianae`; `Category:Illustrations of British Fungi (Hymenomycetes), to serve as an atlas to the "Handbook of British Fungi"`.
- **Shows:** Botanical mushroom plates on cream paper: *Icones Farlowianae* (1929) and M. C. Cooke's *Illustrations of British Fungi* (1888).
- **Measured:** 2063-3388 px. Some plates are just over 2000 px; the 2% slack in the size gate admits the 2026 px ones.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** eerie, intimate; subject plant; energy 0.25; warmth 0.3.
- **Credit:** Biodiversity Heritage Library scans via Wikimedia Commons. [Icones Farlowianae](https://commons.wikimedia.org/wiki/Category:Icones_Farlowianae)
- **Notes:** Paper margins remain on some plates (D42).

### haeckel-art-forms

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Kunstformen der Natur`.
- **Filters:** whole-word title rejects: `page`, `Titel`, `Vorwort`, `Inhalt`.
- **Shows:** Ernst Haeckel's *Kunstformen der Natur* (1899-1904): symmetric radiolarians, jellyfish, sea lilies and fungi plates.
- **Measured:** 6000-8952 px, portrait. The 3:2 window is cut from the most open of five offsets.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** euphoric, eerie; subject creature; energy 0.5; warmth 0.0.
- **Credit:** Library of Congress copies via Wikimedia Commons. [Kunstformen der Natur](https://commons.wikimedia.org/wiki/Category:Kunstformen_der_Natur)
- **Notes:** Uses the parent category: the *(1899)* subcategory is a full book scan, mostly text pages. Reject words drop title, foreword and contents pages.

<details><summary>4 pinned ids</summary>

- `File:Basimycetes. - Schwammpilze LCCN2015648945.jpg`
- `File:Ciliata. - Wimperlinge LCCN2015647734.jpg`
- `File:Crinoidea. - Palmensterne LCCN2015648907.jpg`
- `File:Ctenophorae. - Kammquallen LCCN2015648914.jpg`

</details>

### landsat-earth-as-art

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Searches:** none; the source is pinned ids only.
- **Shows:** USGS and NASA Landsat false-colour scenes (*Earth as Art*, MSS near-infrared 1972-81, Lena Delta, Malaspina Glacier, Holuhraun): saturated magenta, cyan and orange fields. Pinned only.
- **Measured:** 2015-7193 px. One MSS scene was rejected for too little film key (0.04) when the source was added (D42).
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** euphoric, majestic; subject landscape; energy 0.5; warmth 0.2.
- **Credit:** US Geological Survey and NASA, via Wikimedia Commons. [Landsat images](https://commons.wikimedia.org/wiki/Category:Landsat_images)
- **Notes:** No categories or searches: the Landsat categories are mostly labelled maps with a median of 1902 px.

<details><summary>8 pinned ids</summary>

- `File:Cubism—Landsat Style.jpg`
- `File:Lena River Delta - Landsat 2000.jpg`
- `File:Malaspina Glacier, Alaska (2749).jpg`
- `File:Shetlandinseln (Landsat).jpg`
- `File:Holuhraun False Color OLI Landsat 8 01.jpg`
- `File:Shalkarteniz 1975-05-09 Landsat 1-5 MSS L1 False Color Near Infrared.jpg`
- `File:Shalkarteniz 1981-06-18 Landsat 1-5 MSS L1 False Color Near Infrared.jpg`
- `File:Ebinur 1972-09-21 Landsat 1-5 MSS L1 False Color Near Infrared.jpg`

</details>

### photochrom-landscapes

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 2. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Photochrom pictures from the Library of Congress`; `Category:Photochrom prints collection`.
- **Filters:** whole-word title rejects: `girl`, `woman`, `belle`, `man`, `portrait`, `beggars`, `type`.
- **Shows:** Hand-tinted photochrom views, 1890-1910: gorges, coasts, ruins and old towns.
- **Measured:** 3300-7300 px. Commons holds copies made from the LoC TIFF masters, which is why this source goes through Commons.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** serene, majestic; subject landscape; energy 0.3; warmth 0.3.
- **Credit:** Library of Congress Photochrom Prints Collection, via Wikimedia Commons. [Photochrom prints collection](https://commons.wikimedia.org/wiki/Category:Photochrom_prints_collection)
- **Notes:** Reject words remove the portrait and "type" studies.

<details><summary>3 pinned ids</summary>

- `File:In Buller Gorge I LCCN2017658073.jpg`
- `File:In Buller Gorge II LCCN2017658074.jpg`
- `File:Kotau Point. West Coast LCCN2017657809.jpg`

</details>

### cma-ukiyoe-landscapes

- **Provider:** `cma` (Cleveland Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `Hiroshige` (type Print), `Hokusai` (type Print), `moonlight` (type Print).
- **Shows:** Hiroshige and Hokusai woodblock prints: night rain, fireworks, full moons.
- **Measured:** `images.print` 3400 px on the long side (2-4 MB).
- **High-resolution route:** `images.print.url` from the artwork record (JPEG, about 3400 px on the long side). Never `images.full` (TIFF).
- **Rights:** `share_license_status` = "CC0" (the search also passes `cc0=1`) → **CC0**.
- **Mood sent to the music:** serene, melancholy; subject landscape; energy 0.25; warmth -0.1.
- **Credit:** Cleveland Museum of Art Open Access. [Open Access](https://www.clevelandart.org/open-access)
- **Notes:** Weight lowered from 2 to 1 in D42, when woodblock prints were 10 of 54 pictures shown.

<details><summary>6 pinned ids</summary>

- `106962`
- `103244`
- `120225`
- `126086`
- `152499`
- `106965`

</details>

### cma-early-photographs

- **Provider:** `cma` (Cleveland Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** yes.
- **Queries:** `landscape` (type Photograph), `forest` (type Photograph), `trees` (type Photograph).
- **Shows:** 1850s-1900 albumen and salt prints: Fontainebleau forest, trees, landscapes.
- **Measured:** 3400 px.
- **High-resolution route:** `images.print.url` from the artwork record (JPEG, about 3400 px on the long side). Never `images.full` (TIFF).
- **Rights:** `share_license_status` = "CC0" (the search also passes `cc0=1`) → **CC0**.
- **Mood sent to the music:** melancholy, serene; subject landscape; energy 0.2; warmth 0.2.
- **Credit:** Cleveland Museum of Art Open Access. [Open Access](https://www.clevelandart.org/open-access)

<details><summary>6 pinned ids</summary>

- `157126`
- `157013`
- `154048`
- `154698`
- `164940`
- `156527`

</details>

### met-landscapes

- **Provider:** `met` (The Metropolitan Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `Mount Fuji` (department 6), `landscape woodblock`, `moonlight landscape`, `trees photograph` (department 19).
- **Filters:** classification allowlist: `"Prints"`, `"Paintings"`, `"Photographs"`, `"Drawings"`.
- **Shows:** Hokusai and other Mount Fuji prints, woodblock landscapes, moonlight, and tree photographs such as the 1878 Calaveras Grove sequoias.
- **Measured:** 2000-4000 px.
- **High-resolution route:** `primaryImage` from `/public/collection/v1/objects/<objectID>` (the original, up to about 4000 px).
- **Rights:** `isPublicDomain` = true on the object record (the search's own filter is ignored by the server) → **CC0**.
- **Mood sent to the music:** serene, majestic; subject landscape; energy 0.25; warmth 0.0.
- **Credit:** The Metropolitan Museum of Art Open Access. [Open Access](https://www.metmuseum.org/about-the-met/policies-and-documents/open-access)
- **Notes:** Some Fuji scrolls are mostly blank (D42).

<details><summary>8 pinned ids</summary>

- `56611`
- `54887`
- `57196`
- `56229`
- `459334`
- `732749`
- `732813`
- `732816`

</details>

### si-american-landscapes

- **Provider:** `si` (Smithsonian Open Access). **Weight** 1. **Enabled:** no. **Monochrome allowed:** no.
- **Queries:** `landscape AND unit_code:SAAM`, `space AND unit_code:NASM`.
- **Filters:** `requiresKey: SMITHSONIAN_API_KEY`.
- **Shows:** Smithsonian American Art Museum landscapes and National Air and Space Museum items. **Disabled.**
- **Measured:** ids.si.edu delivery measured at 2999x2263.
- **High-resolution route:** `content.descriptiveNonRepeating.online_media.media[0].content` (ids.si.edu delivery service).
- **Rights:** `metadata_usage.access` = "CC0" → **CC0**.
- **Mood sent to the music:** serene, majestic; subject landscape; energy 0.25; warmth 0.1.
- **Credit:** Smithsonian Institution Open Access.
- **Notes:** Needs `SMITHSONIAN_API_KEY` in the environment (api.data.gov). `DEMO_KEY` allows 10 requests and was already spent when tested. The source stays `enabled: false` until its sizes are measured with a real key.

### documerica-western-landscapes

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 2. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:DOCUMERICA photographs by David Hiser`; `Category:DOCUMERICA photographs by Dick Rowan`; `Category:DOCUMERICA photographs by Charles Steinhacker`; `Category:DOCUMERICA photographs by Bruce McAllister`; `Category:DOCUMERICA photographs by Fred Ward`.
- **Searches** (`filetype:bitmap` is added): `DOCUMERICA canyon`, `DOCUMERICA lake`, `DOCUMERICA mountains`, `DOCUMERICA beach`, `DOCUMERICA fog`, `DOCUMERICA storm`, `DOCUMERICA forest`.
- **Filters:** title or file name must contain `NARA`; whole-word title rejects: `laboratory`, `sign`, `signs`, `trash`, `garbage`, `dump`, `landfill`, `sewage`, `Mrs`, `Mr`, `trout`, `housekeeper`, `worker`, `workers`, `testing`, `classroom`, `school`.
- **Shows:** DOCUMERICA landscapes by David Hiser (Canyonlands arches, Upheaval Dome aerials, Escalante), Dick Rowan (Big Sur, redwoods, dunes), Charles Steinhacker (New Hampshire and Maine rivers), Bruce McAllister (Utah and Colorado aerials, alkaline ponds) and Fred Ward (Everglades sunsets).
- **Measured:** Category samples passed the size gate 36-40 of 40; served 3000x2001 to 3000x2064 (or 2001-2025x3000).
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** melancholy, majestic; subject landscape; energy 0.35; warmth 0.55.
- **Credit:** EPA DOCUMERICA, NARA scans, via Wikimedia Commons. [Category:DOCUMERICA](https://commons.wikimedia.org/wiki/Category:DOCUMERICA)
- **Notes:** Searches that matched the wrong thing were left out: "Las Vegas" (the EPA laboratory), "rainbow" (trout), "clouds" (White Cloud, Kansas).

<details><summary>15 pinned ids</summary>

- `File:ANGEL ARCH, FAMOUS ROCK FORMATION - NARA - 545566.jpg`
- `File:ANGEL ARCH, FAMOUS ROCK FORMATION IN CANYONLANDS NATIONAL PARK - NARA - 545551.jpg`
- `File:AERIAL VIEW OF UPHEAVAL DOME, PERHAPS THE MOST GEOLOGICALLY INTERESTING FEATURE OF THE CANYONLANDS. IT IS A VAST... - NARA - 545796.jpg`
- `File:California - Between Monterey And Big Sur - NARA - 543403.jpg`
- `File:Back - Packers Chat At Sunset. This Area Has Been Ear - Marked For Heavy Recreational Development - NARA - 543417.jpg`
- `File:California - Big Basin Redwood State Park - NARA - 543442.jpg`
- `File:BIRDS AND DUNES - NARA - 543263.jpg`
- `File:ANDROSCOGGIN RIVER IN THE "13-MILE WOODS" AREA NEAR ERROL NOT FAR FROM THE HEADWATERS OF THE RIVER - NARA - 550656.jpg`
- `File:ANDROSCOGGIN RIVER JUST NORTH OF THE BERLIN TOWN LINE - NARA - 550691.jpg`
- `File:CHOKOLOSKEE ROOKERY IN EVERGLADES NATIONAL PARK - NARA - 544601.jpg`
- `File:CHOKOLOSKEE ROOKERY IN EVERGLADES NATIONAL PARK - NARA - 544609.jpg`
- `File:CHOKOLOSKEE ROOKERY IN EVERGLADES NATIONAL PARK - NARA - 544493.jpg`
- `File:ESCALANTE RIVER AND CANYON - NARA - 544929.jpg`
- `File:VIEW OF GLEN CANYON, UTAH, FROM THE ARIZONA SHORE OF LAKE POWELL - NARA - 544170.jpg`
- `File:AERIAL VIEW OF THE POND WHEN CLEANUP OPERATIONS WERE HALF FINISHED. THE WHITE AREAS ARE ALKALINE. IN THE BACKGROUND... - NARA - 555863.jpg`

</details>

### documerica-smog-and-neon

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 2. **Enabled:** yes. **Monochrome allowed:** no.
- **Searches** (`filetype:bitmap` is added): `DOCUMERICA smog`, `DOCUMERICA neon`, `DOCUMERICA freeway`, `DOCUMERICA dusk`.
- **Filters:** title or file name must contain `NARA`; whole-word title rejects: `testing`, `laboratory`, `gas`, `station`, `sign`, `signs`, `Mrs`, `Mr`, `worker`, `workers`, `classroom`, `housekeeper`.
- **Shows:** Orange suns through Los Angeles smog, Las Vegas casino light streaks, freeway interchanges at dusk.
- **Measured:** smog 40, neon 30, freeway 32, dusk 21 size-passing results; about 3000x2000.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** electric, eerie; subject landscape; energy 0.55; warmth 0.7.
- **Credit:** EPA DOCUMERICA, NARA scans, via Wikimedia Commons. [Category:DOCUMERICA](https://commons.wikimedia.org/wiki/Category:DOCUMERICA)

<details><summary>12 pinned ids</summary>

- `File:SUNSET SEEN THROUGH HEAVY SMOG - NARA - 542678.jpg`
- `File:SUNSET SEEN THROUGH HEAVY SMOG - NARA - 542679.jpg`
- `File:SUNSET SEEN THROUGH SMOG - NARA - 542680.jpg`
- `File:SUNSET SEEN THROUGH SMOG - NARA - 542681.jpg`
- `File:LOW-HANGING SMOG - NARA - 542683.jpg`
- `File:SETTING SUN, SMOG AND DERRICKS - NARA - 544707.jpg`
- `File:NIGHT LIGHTS - NARA - 549009.jpg`
- `File:NIGHT LIGHTS - NARA - 549015.jpg`
- `File:NIGHT LIGHTS - NARA - 549026.jpg`
- `File:LIGHT PATTERNS CREATED BY MULTICOLORED CASINO DISPLAYS IN DOWNTOWN LAS VEGAS - NARA - 549111.jpg`
- `File:THE BRENDA CUTOFF, INTERSTATE 10. A NEW FREEWAY TO LOS ANGELES, CALIFORNIA - NARA - 544043.jpg`
- `File:FREEWAY INTERCHANGE NORTH OF MIAMI - NARA - 544642.jpg`

</details>

### aurora-and-milky-way

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Featured pictures of aurora`; `Category:Featured pictures of the Milky Way`.
- **Filters:** whole-word title rejects: `chart`, `map`, `constellation`, `constellations`, `diagram`, `annotated`, `labeled`, `labelled`, `panorama`.
- **Shows:** Featured Commons photographs of aurorae and the Milky Way.
- **Measured:** Served 3008x1960 to 3072x4608. Very wide panoramas fail: a 9640x3949 file is served at 3072x1258.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** euphoric, eerie; subject celestial; energy 0.45; warmth -0.2.
- **Credit:** Individual Commons photographers and agencies, credited by name with their licence. [Featured pictures of aurora](https://commons.wikimedia.org/wiki/Category:Featured_pictures_of_aurora)

<details><summary>8 pinned ids</summary>

- `File:Aurora borealis over Eielson Air Force Base, Alaska.jpg`
- `File:Lofoten, Norway (Unsplash).jpg`
- `File:G5 aurora over Tuntorp, Lysekil Municipality 15.jpg`
- `File:Multicolored aurora borealis pillar over Brastad.jpg`
- `File:Milky Way IR Spitzer.jpg`
- `File:Guisard - Milky Way.jpg`
- `File:Center of the Milky Way Galaxy IV – Composite.jpg`
- `File:Pedra Azul Milky Way.jpg`

</details>

### galaxies-hubble-webb

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Featured pictures of galaxies`.
- **Filters:** whole-word title rejects: `chart`, `diagram`, `comparison`, `spectrum`, `annotated`, `labeled`, `labelled`, `compass`, `scale`, `curve`, `calendar`.
- **Shows:** Featured galaxy pictures from Hubble, Chandra, Spitzer and Webb.
- **Measured:** Served 3072x1523 to 3072x3114; the Webb Crab Nebula pin is a PNG at 3072x2675. Featured galaxies: 37 of 37 pass size.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** euphoric, majestic; subject celestial; energy 0.5; warmth 0.0.
- **Credit:** NASA, ESA, CSA, STScI and other agencies via Wikimedia Commons (PD, CC BY 4.0 for ESA/Webb). [Featured pictures of galaxies](https://commons.wikimedia.org/wiki/Category:Featured_pictures_of_galaxies)
- **Notes:** The Webb and Hubble categories themselves were rejected (charts, calendar covers, light curves, median 1920 px), so only featured pictures and pins are used.

<details><summary>7 pinned ids</summary>

- `File:Hubble2005-01-barred-spiral-galaxy-NGC1300.jpg`
- `File:Antennae galaxies xl.jpg`
- `File:M82 Chandra HST Spitzer.jpg`
- `File:Messier51 sRGB.jpg`
- `File:UGC 1810 and UGC 1813 in Arp 273 (captured by the Hubble Space Telescope).jpg`
- `File:Infrared false color view of M66 from the Jamess Webb Telescope.jpg`
- `File:Crab Nebula imaged using James Webb Space Telescope.png`

</details>

### forests-featured

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Featured pictures of forests`; `Category:Quality images of forests`.
- **Filters:** whole-word title rejects: `panorama`, `map`.
- **Shows:** Featured and quality Commons pictures of forests: fog, autumn, light shafts.
- **Measured:** Served 2736x3648 to 3072x4096; 40 of 40 sampled passed size.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** lush, serene; subject plant; energy 0.3; warmth 0.2.
- **Credit:** Individual Commons photographers (mostly CC BY-SA 4.0). [Featured pictures of forests](https://commons.wikimedia.org/wiki/Category:Featured_pictures_of_forests)

<details><summary>4 pinned ids</summary>

- `File:Dülmen, Umland -- 2014 -- 7056.jpg`
- `File:2014 Park w Kłodzku.jpg`
- `File:Bruderwald-Herbst-026375.jpg`
- `File:Bruderwald Nebel 286411.jpg`

</details>

### apollo-archive

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** yes.
- **Commons categories:** `Category:Files from Project Apollo Archive Flickr Stream`.
- **Filters:** whole-word title rejects: `About`, `portrait`, `training`, `suit`, `suiting`, `insignia`, `emblem`, `patch`, `press`, `conference`, `breakfast`, `crew`, `simulator`, `quarantine`, `recovery`.
- **Shows:** The Project Apollo Archive scans (14,987 files): launches, the lunar surface, CSM views. Monochrome allowed.
- **Measured:** 2880-3072 px served; 38 of 40 sampled passed size.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** majestic, eerie; subject celestial; energy 0.45; warmth -0.2.
- **Credit:** NASA, via the Project Apollo Archive Flickr stream on Wikimedia Commons. [Category](https://commons.wikimedia.org/wiki/Category:Files_from_Project_Apollo_Archive_Flickr_Stream)

<details><summary>3 pinned ids</summary>

- `File:Apollo 11 liftoff (48334428021).jpg`
- `File:Apollo 11 CSM from LM after undocking (48334388826).jpg`
- `File:Apollo 11 liftoff - July 16, 1969 9 32 AM EDT (48299052517).jpg`

</details>

### american-west-painters

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Commons categories:** `Category:Google Art Project works by Albert Bierstadt`; `Category:Google Art Project works by Thomas Moran`.
- **Filters:** whole-word title rejects: `portrait`, `interior`, `study`.
- **Shows:** Albert Bierstadt and Thomas Moran: luminous Rockies, Yosemite, the Grand Canyon in storm light.
- **Measured:** Served 3001-3072 px; Bierstadt 26 of 27 and Moran 9 of 9 pass size.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** majestic, serene; subject landscape; energy 0.35; warmth 0.3.
- **Credit:** Museum paintings photographed for the Google Art Project, via Wikimedia Commons (19th-century, public domain).

<details><summary>7 pinned ids</summary>

- `File:Albert Bierstadt 001.jpg`
- `File:Albert Bierstadt - Rocky Mountain Landscape - Google Art Project.jpg`
- `File:Albert Bierstadt - A Storm in the Rocky Mountains, Mt. Rosalie - Google Art Project.jpg`
- `File:Albert Bierstadt - California Spring - Google Art Project.jpg`
- `File:Albert Bierstadt - Bridal Veil Falls, Yosemite Valley, California - Google Art Project.jpg`
- `File:Thomas Moran, American (born England) - Grand Canyon of the Colorado River - Google Art Project.jpg`
- `File:Thomas Moran - Grand Canyon in Stormy Weather, Arizona - Google Art Project.jpg`

</details>

### shin-hanga-pinned

- **Provider:** `wikimedia` (Wikimedia Commons). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Searches:** none; the source is pinned ids only.
- **Shows:** Shin-hanga woodblock prints by Kawase Hasui and Yoshida Hiroshi: snow, mist, cherry blossom. Pinned only.
- **Measured:** Served 1780x2480 to 3072x4613. A narrow portrait such as the 1780 px one crops to under 2000 px wide and is rejected by the size gate.
- **High-resolution route:** `imageinfo` with `iiurlwidth=3072`: the original `url` when the file is at most 3072 px wide, otherwise the scaled `thumburl`. JPEG and PNG only.
- **Rights:** the file's own `extmetadata.LicenseShortName` → **Public domain**, **CC0**, **CC BY x.y** or **CC BY-SA x.y** (CC BY / BY-SA only with a named creator).
- **Mood sent to the music:** serene, melancholy; subject landscape; energy 0.25; warmth -0.1.
- **Credit:** Museum scans (Rijksmuseum, Google Art Project and others) via Wikimedia Commons.
- **Notes:** **Copyright trap.** Commons marks these artists' prints "Public domain" whatever their date, but prints published after 1930 are probably still under US copyright (URAA restoration). Only prints dated 1930 or earlier are pinned (checked through `DateTimeOriginal`), and the categories must never be added.

<details><summary>6 pinned ids</summary>

- `File:Hikawa park in Omiya Omiya Hikawa no koen (titel op object), RP-P-1994-49.jpg`
- `File:Kawase Hasui (1930s) Evening of Ushibori.jpg`
- `File:Kiyomizu Hall, Ueno in de sneeuw, objectno PK.MP.26578.jpg`
- `File:Hiroshi Yoshida - Kumoi-Zakura (Kumoi Cherry Trees) - Google Art Project.jpg`
- `File:Hodakayama, from the series Twelve Scenes in the Japan Alps, Hiroshi Yoshida.jpg`
- `File:Hiroshi Landschaft.jpg`

</details>

### nasa-orbital-earth-1960s

- **Provider:** `nasa` (NASA Image and Video Library). **Weight** 2. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `mercury earth` (1961-1963), `earth sky` (1965-1966), `apollo 7 earth` (1968-1968), `apollo 9 mission image` (1969-1969), `skylab earth observation` (1973-1974).
- **Filters:** whole-word title rejects: `insignia`, `emblem`, `patch`, `prelaunch`, `insertion`, `project`, `crew`, `portrait`, `diagram`, `chart`, `astronaut`, `suit`, `training`, `chimpanzee`, `recovery`, `liftoff`.
- **Shows:** The first orbital Earth photographs (Mercury), Gemini "Earth-sky" frames (Sahara dunes, Red Sea, the limb), Apollo 7 and Apollo 9 (SO-65 multispectral, magenta Earth), and Skylab false-colour infrared.
- **Measured:** Mercury 3000-5298 px; Gemini 3600-6837; Apollo 9 4062-5771; Apollo 7 4078-4146; Skylab 2971-4124 square (2.9-4.4 MB).
- **High-resolution route:** `https://images-api.nasa.gov/asset/<nasa_id>` lists the files; the `~orig` JPEG or PNG is downloaded (http links upgraded to https) after a HEAD shows it is at most 12 MB. No `~large` fallback: it is only 1920 px.
- **Rights:** No per-item field: every item is credited as "US Government work (NASA media are generally not copyrighted)" → **Public domain**. Title reject words are the guard against third-party works.
- **Mood sent to the music:** majestic, serene; subject celestial; energy 0.4; warmth -0.2.
- **Credit:** NASA. [NASA Image and Video Library](https://images.nasa.gov/)
- **Notes:** Overlaps `nasa-space-age` on Gemini and Skylab; kept separate for weight.

<details><summary>20 pinned ids</summary>

- `s62-06604`
- `s62-06607`
- `s62-06612`
- `s62-03270`
- `S61-01918`
- `s65-63256`
- `s65-63780`
- `s65-63829`
- `s66-63485`
- `as09-23-3617`
- `as09-26a-3748a`
- `as09-23-3592`
- `as09-26a-3728a`
- `as09-20-3177`
- `SL3-87-0299`
- `SL3-33-156`
- `SL3-22-322`
- `SL4-93-167`
- `SL3-33-167`
- `SL3-45-020`

</details>

### nasa-lunar-orbit

- **Provider:** `nasa` (NASA Image and Video Library). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** yes.
- **Queries:** `lunar orbit` (1968-1972), `lunar farside` (1968-1972).
- **Filters:** whole-word title rejects: `traverse`, `overlaid`, `launch`, `map`, `diagram`, `chart`, `crew`, `portrait`, `insignia`.
- **Shows:** Earthrises, Copernicus crater, the CSM over the Moon, the far side. Monochrome allowed.
- **Measured:** About 4095 px square (farside 3249-4112).
- **High-resolution route:** `https://images-api.nasa.gov/asset/<nasa_id>` lists the files; the `~orig` JPEG or PNG is downloaded (http links upgraded to https) after a HEAD shows it is at most 12 MB. No `~large` fallback: it is only 1920 px.
- **Rights:** No per-item field: every item is credited as "US Government work (NASA media are generally not copyrighted)" → **Public domain**. Title reject words are the guard against third-party works.
- **Mood sent to the music:** eerie, majestic; subject celestial; energy 0.3; warmth -0.4.
- **Credit:** NASA. [NASA Image and Video Library](https://images.nasa.gov/)

<details><summary>4 pinned ids</summary>

- `as12-47-6891`
- `as17-145-22287`
- `as8-14-2392`
- `as17-152-23274`

</details>

### nasa-aurora-from-orbit

- **Provider:** `nasa` (NASA Image and Video Library). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `aurora international space station` (2010-2026).
- **Filters:** whole-word title rejects: `insignia`, `emblem`, `patch`, `crew`, `portrait`, `astronaut`, `spacewalk`.
- **Shows:** Green and red aurorae and Earth at night photographed from the International Space Station.
- **Measured:** 4256-8256 px, 1-10.4 MB.
- **High-resolution route:** `https://images-api.nasa.gov/asset/<nasa_id>` lists the files; the `~orig` JPEG or PNG is downloaded (http links upgraded to https) after a HEAD shows it is at most 12 MB. No `~large` fallback: it is only 1920 px.
- **Rights:** No per-item field: every item is credited as "US Government work (NASA media are generally not copyrighted)" → **Public domain**. Title reject words are the guard against third-party works.
- **Mood sent to the music:** eerie, euphoric; subject celestial; energy 0.45; warmth -0.3.
- **Credit:** NASA (ISS crew photographs). [NASA Image and Video Library](https://images.nasa.gov/)

<details><summary>5 pinned ids</summary>

- `iss072e159172`
- `iss052e007904`
- `iss040e064832`
- `iss071e570863`
- `iss040e113977`

</details>

### nasa-cape-kennedy-aerials

- **Provider:** `nasa` (NASA Image and Video Library). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** yes.
- **Queries:** `aerial view` (1960-1975).
- **Filters:** whole-word title rejects: `wind`, `tunnel`, `construction`, `recovery`, `diagram`, `chart`, `crew`, `portrait`.
- **Shows:** 1960s aerial views of Cape Kennedy: launch pads, the Vehicle Assembly Building. Monochrome allowed.
- **Measured:** 3000-4661 px.
- **High-resolution route:** `https://images-api.nasa.gov/asset/<nasa_id>` lists the files; the `~orig` JPEG or PNG is downloaded (http links upgraded to https) after a HEAD shows it is at most 12 MB. No `~large` fallback: it is only 1920 px.
- **Rights:** No per-item field: every item is credited as "US Government work (NASA media are generally not copyrighted)" → **Public domain**. Title reject words are the guard against third-party works.
- **Mood sent to the music:** majestic, playful; subject architecture; energy 0.4; warmth 0.2.
- **Credit:** NASA (Kennedy Space Center). [NASA Image and Video Library](https://images.nasa.gov/)

<details><summary>3 pinned ids</summary>

- `S64-22412`
- `S69-27916`
- `KSC-64PC-0082`

</details>

### cma-american-landscapes

- **Provider:** `cma` (Cleveland Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `American landscape` (type Painting).
- **Shows:** Hudson River School and luminist paintings: Church's *Twilight in the Wilderness*, Bierstadt, Gifford, Kensett, Heade, Inness, Lane.
- **Measured:** 3400 px.
- **High-resolution route:** `images.print.url` from the artwork record (JPEG, about 3400 px on the long side). Never `images.full` (TIFF).
- **Rights:** `share_license_status` = "CC0" (the search also passes `cc0=1`) → **CC0**.
- **Mood sent to the music:** majestic, serene; subject landscape; energy 0.3; warmth 0.3.
- **Credit:** Cleveland Museum of Art Open Access. [Open Access](https://www.clevelandart.org/open-access)
- **Notes:** Plain keywords with `type=Painting` (landscape, moonlight, forest) drift to Chinese and Japanese scrolls and Mughal miniatures; "American landscape" returns 33 US paintings.

<details><summary>15 pinned ids</summary>

- `141639`
- `144732`
- `172815`
- `127224`
- `150968`
- `144968`
- `169614`
- `134072`
- `109239`
- `109249`
- `144967`
- `173688`
- `143477`
- `124771`
- `163456`

</details>

### cma-weather-prints

- **Provider:** `cma` (Cleveland Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `rain` (type Print), `Hiroshige snow` (type Print), `Hiroshige moon` (type Print).
- **Shows:** Night rain, snow and moonrise prints by Hiroshige and Arthur Wesley Dow.
- **Measured:** rain 27 of 27, Hiroshige snow 23 of 25, Hiroshige moon 19 of 19 at 3400 px.
- **High-resolution route:** `images.print.url` from the artwork record (JPEG, about 3400 px on the long side). Never `images.full` (TIFF).
- **Rights:** `share_license_status` = "CC0" (the search also passes `cc0=1`) → **CC0**.
- **Mood sent to the music:** melancholy, serene; subject landscape; energy 0.25; warmth -0.2.
- **Credit:** Cleveland Museum of Art Open Access. [Open Access](https://www.clevelandart.org/open-access)

<details><summary>6 pinned ids</summary>

- `152490`
- `121618`
- `120227`
- `161230`
- `86501`
- `112467`

</details>

### met-american-tonalists

- **Provider:** `met` (The Metropolitan Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `moonlight` (department 1).
- **Filters:** classification allowlist: `"Paintings"`, `""`.
- **Shows:** Moonlit American Tonalist paintings: Ryder's *Moonlight Marine*, Tryon, Blakelock, Farrer's *Winter Scene in Moonlight*.
- **Measured:** 2211-3811 px.
- **High-resolution route:** `primaryImage` from `/public/collection/v1/objects/<objectID>` (the original, up to about 4000 px).
- **Rights:** `isPublicDomain` = true on the object record (the search's own filter is ignored by the server) → **CC0**.
- **Mood sent to the music:** eerie, melancholy; subject landscape; energy 0.2; warmth 0.1.
- **Credit:** The Metropolitan Museum of Art, American Wing. [Open Access](https://www.metmuseum.org/about-the-met/policies-and-documents/open-access)
- **Notes:** American Wing paintings have an empty `classification`, so the allowlist includes "". That would also admit unclassified decorative objects, so the source keeps to one query plus pins.

<details><summary>5 pinned ids</summary>

- `11979`
- `12833`
- `10183`
- `16577`
- `10181`

</details>

### met-early-photographs

- **Provider:** `met` (The Metropolitan Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** yes.
- **Queries:** `Le Gray` (department 19), `Yosemite` (department 19), `waterfall` (department 19).
- **Filters:** classification allowlist: `"Photographs"`.
- **Shows:** 1850s salt and albumen prints: Gustave Le Gray's Fontainebleau trees and the Seine, Carleton Watkins's Yosemite mammoth plates, waterfalls. Monochrome allowed.
- **Measured:** Le Gray 3811-3934 px; Yosemite 2335-3601; waterfall 2001-4000 (half of the waterfall results are not public domain and are rejected).
- **High-resolution route:** `primaryImage` from `/public/collection/v1/objects/<objectID>` (the original, up to about 4000 px).
- **Rights:** `isPublicDomain` = true on the object record (the search's own filter is ignored by the server) → **CC0**.
- **Mood sent to the music:** melancholy, serene; subject landscape; energy 0.2; warmth 0.3.
- **Credit:** The Metropolitan Museum of Art, Photographs. [Open Access](https://www.metmuseum.org/about-the-met/policies-and-documents/open-access)

<details><summary>8 pinned ids</summary>

- `285461`
- `265065`
- `283122`
- `264904`
- `732756`
- `285438`
- `728329`
- `282040`

</details>

### met-hiroshige-night

- **Provider:** `met` (The Metropolitan Museum of Art). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `Hiroshige night` (department 6).
- **Filters:** classification allowlist: `"Prints"`.
- **Shows:** Hiroshige night, moonlight and rain prints.
- **Measured:** 3797-3939 px (2 of 18 results under 2000).
- **High-resolution route:** `primaryImage` from `/public/collection/v1/objects/<objectID>` (the original, up to about 4000 px).
- **Rights:** `isPublicDomain` = true on the object record (the search's own filter is ignored by the server) → **CC0**.
- **Mood sent to the music:** serene, melancholy; subject landscape; energy 0.25; warmth -0.1.
- **Credit:** The Metropolitan Museum of Art, Asian Art. [Open Access](https://www.metmuseum.org/about-the-met/policies-and-documents/open-access)

<details><summary>4 pinned ids</summary>

- `36957`
- `36531`
- `56677`
- `55712`

</details>

### dc-tichnor-postcards

- **Provider:** `dc` (Digital Commonwealth (Boston Public Library)). **Weight** 3. **Enabled:** yes. **Monochrome allowed:** no.
- **Host collection facet:** `The Tichnor Brothers Collection`.
- **Queries:** `motel`, `highway`, `night`, `skyline`, `desert`, `route 66`, `diner`, `bridge`, `sunset`, `lake`, `moonlight`, `gas station`.
- **Filters:** whole-word title rejects: `Greetings`, `views`.
- **Shows:** Tichnor Brothers linen postcards, 1930-45: motels with 1940s cars, highway curves, moonlit main streets, diners, skylines, bridges, sunsets. The strongest retro-roadside source after Highsmith.
- **Measured:** Native 3295-3336 x 2088-2181; served 2528x1616 by `!2528,2528` (1.3 MB). Totals inside the collection: motel 2,684, highway 1,031, night 495, skyline 180, desert 99, diner 70.
- **High-resolution route:** `https://iiif.digitalcommonwealth.org/iiif/2/<exemplary_image_ssi>/full/!2528,2528/0/default.jpg`.
- **Rights:** `reuse_allowed_ssi` = "no restrictions" (else `license_ss`) → **No restrictions**.
- **Mood sent to the music:** playful, melancholy; subject architecture; energy 0.45; warmth 0.6.
- **Credit:** The Tichnor Brothers Collection, Boston Public Library, via Digital Commonwealth. [Collection](https://www.digitalcommonwealth.org/search?f%5Brelated_item_host_ssim%5D%5B%5D=The+Tichnor+Brothers+Collection)
- **Notes:** Each card has a printed caption strip and an accession number in a corner; the text rule and border trim handle most of them. Multi-view "Greetings" cards are rejected by title.

### aic-landscapes

- **Provider:** `aic` (Art Institute of Chicago). **Weight** 1. **Enabled:** yes. **Monochrome allowed:** no.
- **Queries:** `moonlight`, `night`, `forest`, `river` (type Painting), `mountain` (type Painting), `sunset`, `waterfall`, `landscape` (type Photograph).
- **Shows:** Public-domain 19th-century landscape paintings, prints and photographs: Inness, Cole, Hiroshige, Watkins, Le Gray, Monet.
- **Measured:** 3000 px on the long side (or native when smaller): 3000x2235, 2971x2250, 3000x2324 from a 10490 px master, 2350x3000 for a portrait.
- **High-resolution route:** `https://www.artic.edu/iiif/2/<image_id>/full/3000,/0/default.jpg` (3000 px on the long side, or native when smaller; the only large width the server allows).
- **Rights:** `is_public_domain` = true → **CC0** (AIC's open-access terms).
- **Mood sent to the music:** serene, majestic; subject landscape; energy 0.25; warmth 0.2.
- **Credit:** Art Institute of Chicago (CC0 public-domain works). [Collection](https://www.artic.edu/collection)

## Rejected sources

The JSON also keeps a `rejected` list so nobody re-adds them by accident. It is documentation only; the app does not read it.

| Source | Reason |
|---|---|
| LOC FSA/OWI color, photochrom, Prokudin-Gorskii, Detroit Publishing, Margolies, Japanese prints | Only a 1024 px JPEG plus 30-144 MB TIFF masters; IIIF info.json 404 or 1024 max. Use the Wikimedia copies of LOC photochroms instead (up to 7300 px). |
| LOC Highsmith items added 2018 and later | Many carry only a 1024 px v.jpg (no JP2/IIIF), filtered by requireIIIF |
| LOC psychedelic rock posters (Bill Graham, Avalon Ballroom) | Rights status not evaluated; 1024 px or less |
| LOC Yanker poster collection | 640 px JPEG only |
| Wikimedia Category:Kunstformen der Natur (1899) | Full-book BHL scans, mostly text pages; use the parent category plates |
| Wikimedia Category:Marbled paper | Book bindings with colour rulers and spines |
| Wikimedia Category:Toadstools, mushrooms, fungi, edible and poisonous | Lovely plates, but 1908 px long side |
| Wikimedia Ansel Adams NARA series, Photochrom Zentralbibliothek Zuerich | Capped at 2000 px; candidate for a later upscale tier |
| Wikimedia Category:Googie architecture | Modern snapshots, mixed sizes and licences; Highsmith covers the subject better |
| Internet Archive free-text (psychedelic, kodachrome) | AI art, music covers and uploader-asserted licences |
| Europeana | Mostly 400-1000 px previews; production key needed |
| Met Walker Evans and 1950s photographs | Not public domain |
| CMA mushroom query | Returns decorative objects (lamps, boxes); restrict CMA to Print/Photograph types |

Two of those entries are out of date: FSA/OWI colour now reaches its masters through the IIIF `master:` route (D44), and the newer Highsmith items are reached the same way through `useMasters`. Photochroms and Prokudin-Gorskii could use the same route but have not been added from the LoC (photochroms come through Commons). More rejected institutions and categories, with reasons, are in [research-history.md](research-history.md#rejected-and-why).
