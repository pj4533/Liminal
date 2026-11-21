# API image mode: more sources outside the Library of Congress (tested 2026-11-21)

**Scope:** everything except the Library of Congress. The work had two parts: expand the existing `wikimedia`, `nasa`, `cma` and `met` providers with more in-vibe sources, and re-examine institutions that were skipped before.

**Deliverables.** The research ran in a scratch folder that is not in the repository (raw probe JSON per provider, and contact sheets of the first 18-30 size-passing results per query, centre-cropped to 3:2 the way `ImageFraming` crops; every vibe call below was made by looking at those sheets). What was kept is in the repository:

- The 17 sources it proposed are in `Liminal/Visual/ImageSources/image-collections.json` (added 2026-11-21, `decisions/images.md` D45).
- [new-providers.md](new-providers.md): institutions that need provider code, ranked. Digital Commonwealth and the Art Institute of Chicago were implemented (`DigitalCommonwealthProvider`, `ArticProvider`).

## Method

- **Requests:** Python and curl with User-Agent `Liminal/1.0 (research)`, paced per host:
  - Commons API: 2 s.
  - The Met: 5 s.
  - Everything else: 0.5-1.1 s.
- **Size gate:** same as the app: JPEG or PNG, long side at least 1960 and short side at least 1306 (the 2000x1333 gate with 2% slack). Licence matched against the app's allowlist.
- **Size measurement:**
  - Commons: `imageinfo` (original size, and the 3072 px `thumburl` size the provider actually downloads).
  - NASA: the `~orig` header (256 KB Range read) and `Content-Range` for bytes.
  - CMA: `images.print` width and height.
  - The Met: the `primaryImage` header.
  - Other institutions: full downloads measured with `sips`.
- **Pins:** every Commons pin in `sources.json` was re-checked in one batch for existence, licence, date and the size the provider will actually be served (`pins.py`). Every NASA pin's original was measured: all are 3000-8256 px and 1.0-10.4 MB, under `maxBytes`.

## Findings that change earlier conclusions

1. **The Art Institute of Chicago does serve 3000 px.** `https://www.artic.edu/iiif/2/<image_id>/full/3000,/0/default.jpg` returns the image at 3000 px on the long side, capped at native size; portraits are fitted by height. Only the widths 843, 1686 and 3000 (and the `sizes` listed in `info.json`) are allowed; `2000,`, `2528,`, `full`, `max`, `!w,h`, `pct:` and tiles all return 403. Measured: 3000x2235, 2971x2250, 3000x2324 from a 10490 px master, and 2350x3000 for a portrait. It rate-limits at about 1 request per second over a few minutes (HTTP 429). See new-providers.md section 2.
2. **Shin-hanga copyright trap on Commons.** Commons labels Kawase Hasui (d. 1957) and Yoshida Hiroshi (d. 1950) prints "Public domain" whatever their date. Under URAA restoration, prints published after 1930 are probably still under US copyright. The pins checked included "Miyajima in de mist" (published 1947, 昭和22年), "Wisteria" (1935) and "Snow in Mukojima" (1931). The categories therefore must not be used. `shin-hanga-pinned` contains only prints dated 1930 or earlier (checked through `DateTimeOriginal`).
3. **The Met's American Wing paintings have an empty `classification`.** Every object in the department 1 sample came back with `classification: ""`. The existing `met-landscapes` allowlist would reject all of them. `met-american-tonalists` uses `"allowClassification": ["Paintings", ""]`. This works with the current `parseObject` because `allow.contains("")` matches, but it also admits unclassified decorative objects, so the source is limited to the "moonlight" query plus pins.
4. **Boston Public Library's Tichnor linen postcards** (1930-45 motels, highways, moonlit main streets) are keyless at 3300 px with "no restrictions". This is the best new retro-roadside source; it needs a new provider (new-providers.md section 1).
5. **CMA keyword searches for paintings drift to Asian scrolls.** "landscape", "moonlight" and "forest" with `type=Painting` mostly returned Chinese and Japanese ink scrolls and Mughal miniatures. `q="American landscape"` with `type=Painting` returns 33 US paintings: Church's *Twilight in the Wilderness*, Bierstadt and Gifford. Use it, plus pins.

## Results by provider

### Wikimedia Commons

**DOCUMERICA (EPA 1971-77, NARA scans).** All public domain; almost all files are 3000x2000. 26 photographer categories were sampled (40 files each), and the 3:2 crops of 15 were judged on contact sheets.

| Photographer category | Files | Size pass | Verdict |
|---|---|---|---|
| David Hiser | 481 | 38/40 | **Keep.** Canyonlands arches, the Maze, Upheaval Dome aerials, Escalante |
| Dick Rowan | 403 | 40/40 | **Keep.** Big Sur, Bodie ghost town, redwoods, dunes, sunsets |
| Charles Steinhacker | 112 | 36/40 | **Keep.** Faded magenta Kodachrome rivers in New Hampshire and Maine |
| Bruce McAllister | 189 | 40/40 | **Keep.** Utah and Colorado aerials, alkaline ponds; abstract and psychedelic |
| Fred Ward | 179 | 39/40 | **Keep.** Everglades sunsets with birds, mangroves (butterfly close-ups too) |
| Boyd Norton | 636 | 40/40 | Mixed: meadows, but also mines, scaffolds and rafting. Not added |
| Arthur Tress | 175 | 40/40 | Surreal Jamaica Bay (sunken cars), but many signs and people. Not added |
| Erik Calonius | 262 | 40/40 | Strip mining, Harlem. Off-vibe |
| Bill Gillette | 263 | 40/40 | Landfill and trash. Off-vibe |
| David Falconer | 499 | 39/40 | 1973 energy-crisis signs. Text-heavy, rejected |
| Marc St. Gil | 355 | 40/40 | Bison, junk cars, portraits. Off-vibe |
| Gene Daniels, Blair Pittman, Tomas Sennett, Aleksandrowicz, Pickerell, Gary Miller, Paul Sequeira, Dennis Cowals, Jack Corn, Belinda Rain, Harry Schaefer, William Strode, Donald Emmerich, John Vachon, Hank Morgan | 8-799 | 38-40/40 | Stats only, not visually reviewed (sheets are in `sheets/b1-doc-*`). Mostly people and industry going by subjects |

DOCUMERICA keyword searches (the `searches` mechanism, filtered by `requireTitleContains: "NARA"`):

| Search | Size pass (NARA title) | Verdict |
|---|---|---|
| smog | 40 (36) | **Keep.** Orange suns through LA smog: very psychedelic |
| neon | 30 (27) | **Keep.** Las Vegas casino light streaks; some signs |
| canyon | 39 (28) | **Keep** |
| freeway | 32 (32) | **Keep.** Some "no gas" signs, handled by reject words |
| lake | 30 | Keep |
| mountains | 39 | Keep |
| beach | 38 | Keep |
| fog | 24 | Keep |
| storm | 33 | Keep |
| forest | 39 | Keep |
| dusk | 21 | Keep (fewer hits) |
| aerial | 34 | Not added: mix of mines and developments |
| motel | 19 | Rejected: people |
| Las Vegas | 38 | Rejected: matches the EPA Las Vegas laboratory |
| rainbow | 26 | Rejected: matches rainbow trout |
| drive-in | 36 | Rejected: matches "drive" |
| clouds | 33 | Rejected: matches "White Cloud, Kansas" |
| Lake Powell | 24 | Covered by "lake" |

**Other categories:**

| Category | Files | Size pass | Licences | Verdict |
|---|---|---|---|---|
| Featured pictures of aurora | 14 | 14/14 | CC BY-SA, CC BY, PD, CC0 | **Keep.** Pure psychedelic colour |
| Featured pictures of the Milky Way | 23 | 21/23 | mixed open | **Keep.** Reject words for the constellation chart; avoid very wide panoramas, since a 9640x3949 file is served at 3072x1258 and fails the gate |
| Featured pictures of galaxies | 37 | 37/37 | 21 PD, 11 CC BY 4.0 | **Keep** |
| Images by the James Webb Space Telescope | 111 | 21/40 | CC BY, PD | Charts, calendar covers and light curves. **Pins only** (M66, Crab Nebula, HOPS 383) |
| Images by the Hubble Space Telescope | 650 | 9/40 | | Median 1920 px; TIFF, PDF and OGG files. Rejected |
| Featured pictures of forests | 65 | 40/40 | mostly CC BY-SA 4.0 | **Keep.** Fog, autumn, light shafts |
| Quality images of forests | 47 | 40/40 | | **Keep** |
| Featured pictures of twilights | 386 | 38/40 | | Modern, good, but buildings and castles. Optional |
| Featured night photography | 237 | 39/40 | | Optional |
| Featured pictures of clouds | 92 | 35/40 | | Buildings and a car; rejected |
| Featured pictures of mountains, roads, skylines, bodies of water, volcanoes | | 30-40/40 | | Modern CC photography; not reviewed in detail. Candidates for a later "modern landscapes" source |
| Files from Project Apollo Archive Flickr Stream | **14,987** | 38/40 | all PD | **Keep** (weight 1). Lunar surface, launches, CSM views; some suit-up and crew shots, so reject words are set |
| Google Art Project works by Albert Bierstadt | 27 | 26/27 | PD | **Keep.** Luminous Rockies and Yosemite |
| Google Art Project works by Thomas Moran | 9 | 9/9 | PD | **Keep** |
| Kawase Hasui | 70 | 13/40 | "PD" | Vibe excellent but post-1930 copyright risk; **pins only** (see above) |
| Woodblock prints by Yoshida Hiroshi | 70 | 11/40 | "PD" | Same; pins only |
| Photographs of Yosemite by Carleton E. Watkins | 196 | 33/40 | CC0 | Circular vignettes on cream mounts; the border trimmer will not cope. Rejected (the Met's Watkins mammoth plates are used instead) |
| Photographs by Timothy H. O'Sullivan | 84 | 24/40 | PD | Monochrome survey photographs. Candidate, not reviewed |
| William Henry Jackson-Hayden Surveys | 189 | 32/40 | PD | Candidate, not reviewed |
| Files from the NOAA Photo Library Flickr stream | 6,483 | 31/40 | PD | Mixed: reef fish, glaciers, storm cells, sequoias, coasts. Candidate source with strict reject words |
| WPA posters, National Park Service | 16 | 7/16 | PD | Portrait posters with text; few pass |
| Work Projects Administration Poster Collection | 102 | 16/40 | PD | Median 1536 px; rejected |
| See America posters | 12 | 8/12 | PD | Too few; text |
| Featured pictures of space posters | 14 | 14/14 | PD | JPL "Exoplanet Travel Bureau" and "Galaxy of Horrors": big titles. Rejected for text |
| Photographs by Charles W. Cushman | 259 | 0/40 | CC BY 2.0 | Median 600 px; rejected |
| Herbier de la France (Bulliard mushrooms) | 155 | 0/40 | PD | Median 1646 px; rejected |
| Mushrooms in art | 176 | 26/40 | mixed | Mostly documents, signs and a VW bus; rejected. A few BHL plates are nice |
| Moonlight in art, Nocturnes | 207, 25 | 18/40, 1/25 | | Engravings, sheet music, records; rejected |
| Autochromes | 105 | 16/40 | | WWI soldiers and portraits; rejected |
| Psychedelic art | 93 | 19/40 | | Modern concert and graffiti snapshots; rejected |
| Featured pictures of fractals | 13 | 12/13 | CC | Not reviewed; possible psychedelic filler |
| 1950s automobiles | 42 | 19/40 | | Modern car-show photographs; rejected |
| Landsat images | 317 | 16/40 | CC BY 2.0 / PD | Maps with labels; median 1902 px. Keep the existing pinned approach |
| Photographs taken on Kodachrome 25 film | 35 | 18/35 | CC BY | 1980s amateur slides at about 2087 px; borderline, not added |
| Photographs by Bob Wick (BLM) | 490 | 35/40 | CC BY 2.0 | Mostly rafting people; rejected |
| Tichnor Brothers (Commons) | 2 files | 0 | | Use Digital Commonwealth instead |

Category names that do not exist on Commons, so do not use them: "Project Apollo Archive", "WPA posters", "Earth as Art", "NOAA Photo Library", "Kodachrome slides", "Featured pictures of deserts", "Quality images of aurorae", "Hubble Heritage", "Psychedelic posters".

**Commons rate limits:** two 429 bursts happened even at 1 call per 2 s (Retry-After 6-37 s), probably from sharing the IP with another agent. The app's 1 s pacing should back off on 429.

### NASA Image and Video Library

| Query | Window | Hits | Measured originals | Verdict |
|---|---|---|---|---|
| skylab earth observation | 1973-74 | 84 | 2971-4124 px square, 2.9-4.4 MB | **Keep.** False-colour infrared Earth, very psychedelic |
| mercury earth | 1961-63 | 61 | 3000-5298 px, 1-3.3 MB | **Keep.** First orbital Earth-limb photographs; reject words for capsule and chimp shots |
| earth sky | 1965-66 | 90 | 3600-6837 px | **Keep.** Gemini "EARTH-SKY" frames (Sahara dunes, Red Sea, limb); reject EVA and "insignia" |
| apollo 9 mission image | 1969 | 24 | 4062-5771 px | **Keep.** SO-65 multispectral (magenta Earth) and terrain |
| apollo 7 earth | 1968 | 34 | 4078-4146 px | Keep |
| lunar orbit | 1968-72 | 673 | about 4095 px square | **Keep.** Earthrises, Copernicus, CSM over the Moon |
| lunar farside | 1968-72 | 31 | 3249-4112 px | Keep |
| aurora international space station | 2010-26 | 259 | 4256-8256 px, 1-10.4 MB | **Keep.** Green and red aurora from the ISS; one mission patch to reject |
| aerial view | 1960-75 | 54 | 3000-4661 px | **Keep** (weight 1). KSC pads and VAB, retro space-age aerials |
| apollo earth | 1968-72 | 507 | about 4095 px | Already covered by `nasa-space-age` |
| saturn v launch | 1967-73 | 311 | 2292-3000 px, up to 9.6 MB | Mixed: diagrams, VIPs and B&W pad shots. Not added; Apollo 11 liftoff pins come through Commons |
| viking mars | 1976-80 | 4 | 3072x2048 | Too few; "viking lander mars surface" returned 0 |
| voyager jupiter | 1979-80 | 48 | | Prints with white borders, B&W mosaics; rejected (as before) |
| hubble galaxy / hubble nebula | | 574 / 143 | many 1280 px (GSFC archive) | Rejected; use Commons galaxies |
| webb | 2022-26 | 255 | | Event photographs of people; rejected |
| aurora | 1960-2026 | 805 | 350-6240 px, one 26 MB | Mixed; use the ISS query |
| lunar orbiter | 1966-68 | 95 | `~orig` unreadable | Not usable |
| space settlement | 1975-80 | 4 | | Existing "space colony" query is enough |

### Cleveland Museum of Art

| Query | Type | Hits | Print size | Verdict |
|---|---|---|---|---|
| American landscape | Painting | 33 | 3400 px | **Keep:** Church, Bierstadt, Gifford, Kensett, Heade, Inness, Lane |
| rain | Print | 27 | 27/27 at 3400 px | **Keep:** Hiroshige night rain |
| Hiroshige snow | Print | 25 | 23 pass | Keep |
| Hiroshige moon | Print | 19 | 19 pass | Keep |
| Arthur Wesley Dow (artist name) | Print | 5 | | Pinned *Moonrise* and *The Long Road* |
| Yoshida (artist name) | Print | 8 | | Only *Evening on the Chikugo River* (1927) is pinned; the rest are "after 1929" or later |
| landscape, moonlight, forest, ocean | Painting | | | Mostly Asian scrolls and Mughal miniatures; rejected |
| fungi | (any) | 15 | | Ceramics and jade; rejected |
| Hasui | Print | 0 | | |
| Thomas Cole | Painting | 3 | | Too few to query |

### The Met

| Query | Department | Hits | Measured | Verdict |
|---|---|---|---|---|
| moonlight | 1 (American Wing) | 19 | 2211-3811 px | **Keep** with the classification fix: Ryder *Moonlight Marine*, Tryon, Blakelock, Farrer *Winter Scene in Moonlight* |
| landscape | 1 | 2,304 | 680-2811 px | Mixed sizes, unclassified objects; pins only |
| Le Gray | 19 | 261 | 3811-3934 px | **Keep:** Fontainebleau trees, Seine |
| Yosemite | 19 | 157 | 2335-3601 px | **Keep:** Watkins mammoth plates; one Ansel Adams result was not public domain |
| waterfall | 19 | 100 | 2001-4000 px | Keep (half the results are not public domain) |
| clouds | 19 | 1,562 | | Mostly not public domain (Weston, Hagemeyer, Shore); pin Fenton 282040 only |
| Hiroshige night | 6 | 18 | 3797-3939 px (2 under 2000) | **Keep** |
| mushrooms | 9 | 30 | | Regency caricatures; rejected |

No WAF block was hit at 5 s per request (about 50 requests).

### Smithsonian

DEMO_KEY returned 429 on the first call (`x-ratelimit-limit: 10`, remaining 0). The shared quota is exhausted, so the provider is not usable keyless. Leave `si-american-landscapes` disabled until a key exists.

## sources.json summary

| id | provider | weight | Contents |
|---|---|---|---|
| documerica-western-landscapes | wikimedia | 2 | 5 photographer categories and 7 searches, 15 pins |
| documerica-smog-and-neon | wikimedia | 2 | 4 searches, 12 pins |
| aurora-and-milky-way | wikimedia | 1 | 2 featured categories, 8 pins |
| galaxies-hubble-webb | wikimedia | 1 | Featured galaxies, 7 pins (including 2 Webb) |
| forests-featured | wikimedia | 1 | Featured and quality forests, 4 pins |
| apollo-archive | wikimedia | 1 | Project Apollo Archive stream (14,987 PD files), 3 pins, monochrome allowed |
| american-west-painters | wikimedia | 1 | Bierstadt and Moran (Google Art Project), 7 pins |
| shin-hanga-pinned | wikimedia | 1 | Pins only: 6 prints dated 1910-1930 |
| nasa-orbital-earth-1960s | nasa | 2 | Mercury, Gemini Earth-sky, Apollo 7 and 9, Skylab; 20 pins |
| nasa-lunar-orbit | nasa | 1 | 2 queries, 4 pins, monochrome allowed |
| nasa-aurora-from-orbit | nasa | 1 | ISS aurora, 5 pins |
| nasa-cape-kennedy-aerials | nasa | 1 | 1960s aerials, 3 pins |
| cma-american-landscapes | cma | 1 | "American landscape" paintings, 15 pins |
| cma-weather-prints | cma | 1 | rain, snow and moon prints, 6 pins |
| met-american-tonalists | met | 1 | moonlight in the American Wing, 5 pins, `allowClassification` includes "" |
| met-early-photographs | met | 1 | Le Gray, Yosemite, waterfalls; 8 pins; monochrome allowed |
| met-hiroshige-night | met | 1 | 4 pins |

Notes for whoever pastes these:

- **Overlap with existing sources.** `nasa-orbital-earth-1960s` overlaps the existing `nasa-space-age` queries "gemini earth view" and "skylab earth". `met-hiroshige-night` and `cma-weather-prints` overlap the existing ukiyo-e sources. Either keep them separate (more rotation weight for these themes) or fold their queries and pins into the existing entries.
- **Total weight.** Added weight is 20 against the current enabled total of 24, so a little under half of the rotation would come from the new entries. Scale the weights down if DOCUMERICA and NASA should stay dominant.
- **Monochrome.** `allowMonochrome: true` is set only where the subject is inherently grey or sepia (Moon, Apollo surface, 1850s photographs, 1960s B&W aerials). `monochromeEvery` still limits how often they appear.
- **`requireTitleContains: "NARA"`** keeps the DOCUMERICA searches on NARA scans. Whole-word `rejectTitleWords` such as "sign", "Mrs" and "testing" remove the worst hits seen on the sheets.
- **Commons pins** were all re-verified in one batch as listed below. The provider requests 3072 px thumbnails, so very wide panoramas fail; "Virmalised 17.03.15.jpg" (5000x1795, served at 3072x1103) was dropped for that reason.

Pin check results (`OK` means served size, mime and licence all pass):

| Pin group | Served size | Licence |
|---|---|---|
| DOCUMERICA | 3000x2001 to 3000x2064, or 2001-2025x3000 | PD, May-Sept 1972 to 1974 |
| Aurora and Milky Way | 3008x1960 to 3072x4608 | |
| Galaxies | 3072x1523 to 3072x3114 | Crab Nebula is a PNG at 3072x2675 |
| Forests | 2736x3648 to 3072x4096 | |
| Apollo | 2880-3072 px | PD |
| Bierstadt and Moran | 3001-3072 px | PD, 1866-1908 |
| Shin-hanga | 1780x2480 to 3072x4613 | Dated 1910, 1926, 1926, 1929, 1930, 1930 |

## Recommended next steps

1. Paste `sources.json` and let the app's own ingest run once with `-LiminalImageAPIFresh YES` to see the openness and text rejections.
2. Implement the Digital Commonwealth provider (Tichnor postcards). It is the highest-value new source and needs one search call plus IIIF.
3. Add the AIC route (`full/3000,`) with 2 s pacing, using pinned or ES-match queries.
4. Mia and the GeoDIL thin sections are cheap additions. Rijksmuseum and Getty are medium effort. NGA and YCBA suit pinned lists only.
