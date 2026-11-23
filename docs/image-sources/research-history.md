# How the API image sources were found

[← Image sources](README.md) · [Pipeline](pipeline.md) · [Sources](sources.md) · [Providers](providers.md) · [Adding a source](adding-a-source.md)

This page is the timeline of the research behind the curated picture feed. It links to the detailed reports in [`docs/research/visuals/image-apis/`](../research/visuals/image-apis/) and the decisions in [`decisions/images.md`](../decisions/images.md). The research reports are snapshots: where they disagree with later findings, the later finding is noted here. The research ran in session scratchpads (probe scripts, raw JSON, contact sheets), which are not in the repository; the reports and the JSON are what was kept.

## Timeline

| Date | Step | Outcome | Details |
|---|---|---|---|
| 2013-2016 | **OpenPics**, the user's earlier iOS app, browsed remote image collections | Prior art: provider list and the LoC "largest / larger / large" resource trick | [openpics.md](../research/visuals/image-apis/openpics.md) |
| 2026-11-20/21 | **The request.** The user asked for imagery found online from approved collections | Brief: psychedelic, old films and imagery, 1950s-70s, mushrooms, trees, landscapes, retro views, cityscapes, driving; open enough for the footage; high resolution | D36 |
| 2026-11-21 | **API survey.** Keyless endpoints called with curl, pixel sizes measured on real downloads | Ranked: LoC, NASA, Commons, Smithsonian (key), the Met, Cleveland, Internet Archive, Europeana (key) | [survey.md](../research/visuals/image-apis/survey.md) |
| 2026-11-21 | **Collections pass.** A Python probe made about 80 searches over about 900 records, reading sizes from headers or `info.json`. About 400 thumbnails were judged on 3:2 review sheets | 12 enabled sources plus a disabled Smithsonian one, and the first version of `image-collections.json` | [collections.md](../research/visuals/image-apis/collections.md), D37 |
| 2026-11-21 | **Gate tuning** on the 409 probe thumbnails | The plan's "key share > 0.75" reject would have removed night neon, dusk skylines and nebulae. Shipped gates: openness ≥ 0.2, key ≥ 0.04, document, monochrome < 0.025, text and face rules | D38 |
| 2026-11-21 | **First live ingest** on macOS and in the visionOS Simulator | 95 pictures stored from all 12 sources and 14 rejected. The size gate gained 2% slack and the text rule was relaxed for signs | D41 |
| 2026-11-21 | **Independent verification** | Target 3072 → 2528 (render stalls with 3072); pictures never enlarged; Vision compiled out of the simulator; Cleveland ukiyo-e weight 2 → 1; `landsat-earth-as-art` added for psychedelic colour | D40, D42 |
| 2026-11-21 | **Code review** | CC BY needs a creator; ledger writes versioned; clear-while-fetching fixed; reservations expire; cancellation is not a failure; 150 MP decode bound | D43 |
| 2026-11-21 | **FSA/OWI masters.** The user remembered high-resolution FSA photographs in OpenPics and asked whether the OpenPics trick had been tried | It had not been followed far enough. The TIFF master path maps onto a IIIF `master:` service, giving 4641-7738 px. About half need the `full/full` fallback; `ScanEdgeTrimmer` removes the film rebate. `loc-fsa-owi-color` added, and Highsmith gained `useMasters` | D44, [collections.md](../research/visuals/image-apis/collections.md#library-of-congress) |
| 2026-11-21 | **Second pass outside the LoC.** Expand Commons, NASA, Cleveland and the Met, and re-test institutions that were skipped | 17 new sources. Digital Commonwealth (Tichnor postcards) and Art Institute of Chicago providers added (commit "Add Digital Commonwealth and Art Institute of Chicago providers and 19 more curated sources") | [other-institutions.md](../research/visuals/image-apis/other-institutions.md), [new-providers.md](../research/visuals/image-apis/new-providers.md) |
| 2026-11-21 | **Library of Congress pass.** Survey every P&P collection that fits, apply the scanned-master route, check rights per collection | 10 new LoC sources: Margolies Roadside America, photochrom, Prokudin-Gorskii, Detroit Publishing, Japanese prints, Gottscho fireworks, FSA/OWI B&W, popular graphic arts, Highsmith space and fairs, Matson. New `partof` search route and `edgeInset` (D45) | [loc-collections.md](../research/visuals/image-apis/loc-collections.md) |

## What each step taught

### OpenPics (prior art)

OpenPics shipped providers for the Library of Congress, NYPL, DPLA, Europeana, Trove, Calisphere, Flickr Commons (and the Boston Public Library and Cambridge Historical Society Flickr accounts), the LIFE archive, and a few Reddit history subs.

- Its LoC provider read `links.resource` with `?fo=json` and took `resource.largest`, `larger` or `large`, skipping files over 12 MB. That 12 MB limit survives as `maxBytes`.
- The survey found the `/pictures/` item resource block null in 2026 and concluded that the trick no longer applied. That was half right: the block is gone from the modern JSON, but the master it pointed to is still served, through IIIF (see the FSA step below).
- Dropped: Reddit (rights unclear), LIFE (gone), and the keyed aggregators (DPLA, Europeana, Trove), which the brief did not need.

### Survey (2026-11-21)

- **Library of Congress** ranked first. `loc.gov` collection JSON plus IIIF: `full/2048,` returned a real 2048 px JPEG. The search result carries `rights_advisory` and the IIIF service id, so a search hit needs no further request.
- **NASA Image and Video Library** is keyless with `~orig` originals of about 3000 px, and its US Government work status is clear.
- **Wikimedia Commons** is noisy in free text but excellent in curated categories. It needs a descriptive User-Agent.
- **The Met.** The old `/v1/search` was retired on 2026-10-01; v1.1 works but ignores its own public-domain filter.
- **Cleveland** was measured at 1536 px for `images.print`, later found to be 3400.
- **Smithsonian** needs an api.data.gov key; `DEMO_KEY` allows 10 requests.
- **The Art Institute of Chicago** was wrongly judged capped at 843 px, because only `full/full`-style requests had been tried. Corrected in the second pass.
- The lessons that became rules:
  - Prefer keyless sources.
  - Fetch the best derivative at or above 2048 px, avoiding TIFF and files over about 12 MB.
  - Gate on the 3:2 crop.
  - Use curated queries, not free text.
  - Judge rights per item.
  - Send a descriptive User-Agent and honour 429s.

### Collections pass (2026-11-21)

- **The LoC's high resolution was only in IIIF items**, which meant Carol M. Highsmith's archive. Her photographs are modern, but the subjects are retro: neon, diners, drive-ins, Route 66. Items catalogued from 2018 on had only a 1024 px `v.jpg`.
- **FSA/OWI colour, photochroms, Prokudin-Gorskii, Detroit Publishing, the Japanese fine prints and Margolies** looked 1024 px only. Their `service:` derivatives stop there, and the guessed master ids used the wrong prefix. They were rejected at this point, and FSA was later reopened.
- **DOCUMERICA on Commons** turned out to be the best 1970s source: about 15,000 public-domain EPA photographs from 1971-77, scanned by NARA at 3000x2000.
- **Commons also holds full-size copies of the LoC photochroms** (up to 7300 px), so photochroms come through Commons.
- **Cleveland's `images.print`** is now 3400 px. Its searches must be restricted to `type=Print` or `type=Photograph`.
- **The Met** needs a classification allowlist and gentle pacing: an Incapsula wall appeared after about 100 quick requests.
- The pass produced a contact sheet of 56 picks, every one at least 2048 px.

### First live ingest and verification (2026-11-21)

- 95 pictures were stored from 12 sources. The licences were Public domain 50, CC0 21, No known restrictions 12, CC BY-SA 11 and CC BY 1.
- The 14 rejections were: title rules 4, small plates 5, text 2, monochrome 1, NASA original over 12 MB 1, small Met print 1.
- The vibe check of 54 pictures shown found the 1950s-70s brief well served, woodblock prints over-represented, and psychedelic colour coming only from nebulae and Haeckel. Landsat false colour was added as a result.
- Still weak:
  - paper margins on some plates and prints;
  - blank Met Fuji scrolls;
  - NASA titles that are just ids;
  - long Commons creator lines;
  - no true 1960s psychedelic poster art. The LoC rock posters are 1024 px with unevaluated rights, and Commons' *Psychedelic art* is modern snapshots.

### FSA/OWI masters (2026-11-21)

The user asked whether the OpenPics trick had been tried for the FSA photographs. Following it further:

- `/pictures/item/<id>/?fo=json` still names the TIFF master: `storage-services/master/pnp/fsac/.../1a33849u.tif`.
- The IIIF image service serves that master under a `master:` prefix: `iiif/master:pnp:fsac:1a33000:1a33800:1a33849u`. Its `info.json` reports 4698x3280.
- 40 of 40 sampled FSA colour items had masters of 4641-7738 px. A photochrom, a Prokudin-Gorskii and a 2018 Highsmith item also resolved this way.
- Two catches came up. About half the masters return HTTP 500 for every scaled request but serve `full/full`, which became the `fallbackURL`. The scans also include the film rebate, which `ScanEdgeTrimmer` now removes; six live masters came out clean.

Lesson: when an API shows only a preview, follow every path to the master before rejecting a collection ([adding-a-source.md](adding-a-source.md#find-where-the-high-resolution-is)).

### Second pass outside the LoC (2026-11-21)

- **Commons.** 26 DOCUMERICA photographer categories were sampled and 15 judged on contact sheets. Kept: Hiser, Rowan, Steinhacker, McAllister and Ward, plus the smog, neon, canyon, freeway and other keyword searches. Also added: featured aurora, Milky Way, galaxies and forests; the Project Apollo Archive (14,987 public-domain files); Bierstadt and Moran; and pinned shin-hanga.
- **The URAA trap.** Commons marks Hasui and Yoshida prints "PD" whatever their date. Prints published after 1930 are probably still under US copyright, so only checked prints dated 1930 or earlier are pinned.
- **NASA.** Mercury, Gemini Earth-sky, Apollo 7 and 9, Skylab false-colour infrared, lunar orbit, ISS aurora and Cape Kennedy aerials. All pins measured 3000-8256 px and 1.0-10.4 MB.
- **Cleveland.** "American landscape" paintings; rain, snow and moon prints.
- **The Met.** American Wing moonlight paintings, which have an empty `classification`; Le Gray, Watkins and waterfall photographs; Hiroshige at night.
- **Digital Commonwealth.** The Boston Public Library's Tichnor Brothers linen postcards (1930-45 motels, highways, moonlit main streets) are keyless at about 3300 px with "no restrictions". This is the strongest new retro-roadside source, and a provider was written for it.
- **Art Institute of Chicago.** `full/3000,` does serve 3000 px; only fixed widths are allowed. A provider was written for it as well.
- Ranked for later: the Minneapolis Institute of Art, the GeoDIL thin sections on the Internet Archive, the Rijksmuseum, the Getty, the National Gallery of Art and the Yale Center for British Art ([new-providers.md](../research/visuals/image-apis/new-providers.md)).

## Rejected, and why

Where something was rejected, the reason is recorded so nobody repeats the probe. Some rejections were later reversed; this is noted.

### Institutions and APIs

| Source | Reason | Status |
|---|---|---|
| Europeana | Mostly 400-1000 px previews (2 of 31 at 2048 px or more); production key needed | Rejected |
| Internet Archive free-text image search | Synthetic images, music covers and uploader-asserted licences; many CC BY-NC-ND | Rejected (its Met mirror and GeoDIL thin sections remain candidates) |
| NYPL Digital Collections | Token needed for search; the masters tested were 760x588 | Re-test with a token |
| NARA Catalog v2 | Needs an `x-api-key` | Use the Commons DOCUMERICA mirror |
| Smithsonian Open Access | api.data.gov key needed; `DEMO_KEY` quota spent | Provider coded, source disabled |
| Harvard Art Museums, Walters, Paris Musées, Biodiversity Heritage Library, Flickr Commons, NPS | Key or token required (401/403) | BHL plates and the Apollo and NOAA Flickr streams are reached through Commons |
| DPLA, Trove, Calisphere, David Rumsey | Key needed or not usable keyless | Not pursued |
| Openverse | Keyless but 20 a minute and 200 a day anonymous; re-indexes Commons and Flickr at about 1024 px | Discovery only |
| Unsplash, Pexels, Pixabay | Keys, attribution and hotlink rules; modern stock, wrong vibe | Rejected |
| LIFE archive, Reddit history subs | Gone, or rights unclear | Rejected |
| Art Institute of Chicago (survey) | "843 px only" | **Reversed:** `full/3000,` works (second pass) |

### Collections and categories

| Source | Reason | Status |
|---|---|---|
| LoC FSA/OWI colour, photochroms, Prokudin-Gorskii (collections pass) | "1024 px only" | **Reversed for FSA** through the IIIF `master:` route (D44); photochroms come through Commons; Prokudin-Gorskii not added yet |
| LoC Highsmith items from 2018 on | Only a 1024 px `v.jpg` | **Reversed** through `useMasters` |
| LoC psychedelic rock posters (Bill Graham, Avalon Ballroom) | Rights not evaluated; 1024 px or less | Rejected |
| LoC Yanker posters | 640 px | Rejected |
| LoC John Margolies Roadside America | Only thumbnails online for the items tried | Rejected |
| LoC mid-century `/photos/` (1950-69) | Mostly 1024 px; "Publication may be restricted" or "not evaluated" | Rejected |
| Commons *Kunstformen der Natur (1899)* subcategory | Full book scan, mostly text pages | The parent category is used instead |
| Commons *Marbled paper* | Book bindings with colour rulers | Rejected |
| Commons *Toadstools, mushrooms, fungi, edible and poisonous*; *Herbier de la France* | 1908 px; 1646 px median | Rejected |
| Commons Ansel Adams NARA series; Zentralbibliothek Zürich photochroms | Capped at 2000 px | Below the size gate |
| Commons *Googie architecture*, *1950s automobiles*, *Psychedelic art*, *Autochromes*, *Mushrooms in art*, *Moonlight in art* | Modern snapshots, documents, portraits, mixed licences | Rejected |
| Commons Hubble and Webb image categories | Charts, light curves, calendar covers; median 1920 px; TIFF, PDF and OGG | Featured galaxies and pins used instead |
| Commons WPA and See America posters, space posters | Small, or large title text | Rejected |
| Commons Charles W. Cushman, Bob Wick, Kodachrome 25 slides | 600 px median; rafting people; about 2087 px amateur slides | Rejected |
| Commons Carleton Watkins Yosemite | Circular vignettes on cream mounts that the trimmer cannot handle | The Met's Watkins plates are used instead |
| Commons Kawase Hasui and Yoshida Hiroshi categories | Post-1930 prints probably still under US copyright (URAA) | Pinned ≤ 1930 prints only |
| Commons *Landsat images* category | Maps with labels; median 1902 px | Pinned scenes only |
| Commons NOAA Photo Library stream, O'Sullivan, Jackson-Hayden surveys, fractals, twilights, night photography | Not reviewed in detail | Candidates |
| DOCUMERICA photographers Norton, Tress, Calonius, Gillette, Falconer, St. Gil | Mines, people, landfill, text-heavy signs | Not added |
| DOCUMERICA searches "motel", "Las Vegas", "rainbow", "drive-in", "clouds", "aerial" | People; wrong matches (EPA lab, trout, "drive", White Cloud KS); mines | Not added |
| NASA Voyager, Hubble via GSFC, Webb, broad "aurora", Lunar Orbiter, "saturn v launch" | White borders and mosaics; 1280 px; event photographs; mixed sizes; unreadable originals; diagrams and VIPs | Rejected |
| Cleveland mushroom, fungi and plain painting keywords | Lamps, ceramics, Asian scrolls, Mughal miniatures | Use types and "American landscape" |
| Met Walker Evans and 1950s photographs, "clouds" (department 19), mushrooms | Not public domain; caricatures | Rejected |

## Interest packs (2026-11-22/23)

The user asked for more of what they enjoy. A handoff ([personal-media-search.md](../research/visuals/personal-media-search.md)) supplied the queries; twelve priority sources were built from it, previewed per pack, and narrowed (queries dropped for storefronts, lab slides, a bubble performer, cloud photographs and cattle). Measurements and the dropped searches are in D130 in [decisions/images.md](../decisions/images.md); the film side is A32.

## Open candidates

- **Through existing providers:** LoC photochroms and Prokudin-Gorskii through the `master:` route; the Commons NOAA stream with strict reject words; O'Sullivan and Jackson survey photographs (monochrome).
- **New providers, ranked in [new-providers.md](../research/visuals/image-apis/new-providers.md):** the Minneapolis Institute of Art (keyless, about 3000 px), GeoDIL thin sections (CC0, very psychedelic, 68 items), the Rijksmuseum (keyless Linked Art, 5140 px), the Getty (SPARQL), the National Gallery of Art (no search API; pinned list) and the Yale Center for British Art (pinned list).
