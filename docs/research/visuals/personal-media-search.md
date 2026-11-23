# Personal image and video search (research handoff)

[← Visual research](README.md)

Research handoff of 22 November 2026, written against `5d21cdc` and kept here as a clean copy. It is the source of the interest packs and film routes that shipped as [D130](../../decisions/images.md) (twelve image packs and the priority share) and [A32](../../decisions/archive-video.md) (five film routes and three pins). The shipped sources are in [image-sources/sources.md](../../image-sources/sources.md#interest-packs-d130).

**Evidence files were not supplied.** The handoff cites a `liminal-personal-media-evidence/` folder (code audit, query findings, `query-results.json`, a contact sheet and a proposed query bank). Those files were not available when the work was implemented, so their names below are plain text and nothing links to them. The tables in this note carry the queries; every query was re-validated live against its provider before it went into the app (D130, A32). Counts below are from the handoff's own run and are not the app's measured yield.

**What changed from this handoff when it was built:** all twelve starter searches were tried, and the packs were widened and then narrowed from in-app previews (for example the `music store`, `science museum`, `magnetic tape` and `Purkinje cells` searches were dropped for off-subject results). Of the six film recipes, five became routes (machines, perception, recording, ecosystems, night city) and the futures recipe was left out because it kept two entries of one film. See the two decision records for the measured results.

**Date:** 22 November 2026 (America/New_York). **Audience:** coding session for the current Apple Liminal app. **Baseline:** [`main` at `5d21cdc93db1f2c7bb8d494605d0637fba407d27`](https://github.com/pj4533/Liminal/tree/5d21cdc93db1f2c7bb8d494605d0637fba407d27). Research and proposed changes only; no Liminal implementation or Push work is included.

## Recommendation

Enrich the existing collection with deliberate search packs grounded in PJ's stated interests: consciousness, AI, cyberpunk, retro music and science fiction. Start with **analog machine rooms, crate-digger surroundings, imagined habitats, lived-in night transit, and inner-world/natural patterns**. These pack names and moods are editorial translations of his interests, not user-endorsed presets. More subject variety matters more than the largest possible query list. No new provider or UI is needed for the first pass. Preserve existing still/footage rendering and music behavior.

Aim for worn, curious, spacious, mysterious and human imagery: equipment someone used, a room with traces of work, speculative architecture with water and plants, infrastructure after dark. Avoid a feed dominated by glossy sci-fi/game promotion, AI stock brains, movie posters, franchise fan art or corporate headshots. Those are curation judgments to validate with PJ through the resulting pictures, not facts about every image he would like.

Translate abstract subjects into visible objects. Archive metadata rarely says “AI consciousness atmosphere”; it does say radio studio, magnetic tape, perception experiment, neuron drawing or space settlement. The inspected Highsmith radio studio and NASA torus habitat are concrete examples of that translation. A neuron, river delta and tree may suggest branching across scales; that is a visual metaphor, not evidence that they share cognition or depict consciousness scientifically.

The recommended first step is the 12-search starter below, followed by a bounded preview with source and item provenance. A reasonable editorial target is three strong fresh images per pack before expanding the reserve bank. That is a review target, not a promised yield.

## Evidence and reading limits

The read-only audit inspected the complete source configuration and current Swift paths. The live run made **35 attempts: 32 valid searches (24 image queries and eight Internet Archive comparisons)** across all seven active image providers and Archive. Three initial Met v1 requests returned 410; corrected v1.1 calls worked. This was a research-script correction, not evidence of an active outage. API observations span the afternoon/evening of 22 November, America/New_York; exact machine timestamps remain explicitly UTC in the preserved JSON.

Twelve anchors were enriched; eleven anchor thumbnails were inspected, with the Commons analog-computer thumbnail blocked by HTTP 429. Some alternate film item thumbnails were also inspected. Film thumbnails can be title cards. **No full films were watched, no films fully downloaded, no app admission gates run, and no macOS/visionOS device acceptance performed.** Native dimensions, public-domain flags and license fields are metadata evidence, not a promise that an image will survive crop, text, face or openness gates. Record-level rights were read; there was no independent chain-of-title investigation.

Supplementary files: complete code/source audit, query findings and official reference list, exact request/response metadata, small inspected contact sheet, and machine-readable proposed query bank. This main document contains the recommendation, inventory, query strings and film shortlist so it can be forwarded alone. The evidence files preserve exhaustive pins, gates and response detail.

## Current source inventory: extend this system

There are **44 configured source entries, 43 enabled**: LOC 13, NASA 6, Commons 14, Cleveland 4, Met 4, Digital Commonwealth 1, AIC 1, plus one disabled Smithsonian entry. The seven keyless providers are active. Smithsonian needs both a key and source enablement. Current code, rather than older documentation counts, is the baseline.

The active path is `ImageQueue → CuratedImageFeed → institution providers → CuratedImagePool → disk-only display`. JSON `themes` describe curation, not search requests. Actual retrieval comes from `queries`, Commons `searches`/`categories`, collection constraints and source pins. Top-level `rejected` is historical descriptive commentary and is not decoded as executable exclusions. There is no topic-to-music-preset routing; `LofiPreset` selects instruments. There is no active Unsplash, Pexels, Pixabay or Gemini generation path.

In the inventory, `q` means a literal provider query, `search` means Commons namespace-6 file search, and `category` means an already configured exact Commons category. NASA year ranges and museum type/department constraints remain in the complete audit. Pinned-only sources are explicitly identified. Existing space colonies, fungi, neon and landscapes are already covered; the proposal deepens them rather than claiming them as new subjects.

| Provider / source ID | Existing query vocabulary or categories | Fit for additions |
|---|---|---|
| loc: `loc-highsmith-roadside` | q: neon sign motel; q: diner neon; q: drive-in theater; q: route 66; q: vintage car; q: old gas station; q: roadside attraction | New Highsmith interiors source can share collection; review gate differences |
| loc: `loc-highsmith-landscape` | q: redwood forest; q: fog; q: Monument Valley; q: desert highway; q: skyline at night | Keep existing coverage; reserve nearby terms only |
| loc: `loc-fsa-owi-color` | q: landscape; q: road; q: highway; q: main street; q: town; q: trees; q: farm; q: railroad; q: sky; q: night | Keep existing coverage; reserve nearby terms only |
| loc: `loc-margolies-roadside` | q: motel sign; q: drive-in; q: diner; q: gas station; q: mini golf; q: neon; q: dinosaur | Keep existing coverage; reserve nearby terms only |
| loc: `loc-photochrom` | q: lake; q: sunset; q: canyon; q: moonlight; q: waterfall | Keep existing coverage; reserve nearby terms only |
| loc: `loc-prokudin-gorskii` | q: river; q: lake; q: zakat; q: view | Keep existing coverage; reserve nearby terms only |
| loc: `loc-detroit-landscapes` | q: canyon; q: falls; q: night; q: lake; q: mountains | Keep existing coverage; reserve nearby terms only |
| loc: `loc-japanese-prints` | q: moon; q: snow; q: rain; q: night; q: mount fuji | Keep existing coverage; reserve nearby terms only |
| loc: `loc-gottscho-fireworks` | q: fireworks | Keep existing coverage; reserve nearby terms only |
| loc: `loc-fsa-owi-bw-landscapes` | q: highway; q: dust storm; q: grain elevator; q: desert; q: glacier | Keep existing coverage; reserve nearby terms only |
| loc: `loc-popular-graphic-arts-moonlight` | q: moonlight; q: sunset; q: lake | Keep existing coverage; reserve nearby terms only |
| loc: `loc-highsmith-space-fair` | q: space center; q: ferris wheel; q: fireworks; q: rocket | Keep existing coverage; reserve nearby terms only |
| loc: `loc-matson-desert` | q: desert; q: dead sea; q: sand dunes; q: palmyra | Keep existing coverage; reserve nearby terms only |
| nasa: `nasa-space-age` | q: earth from apollo (yearStart=1966, yearEnd=1972); q: gemini earth view (yearStart=1965, yearEnd=1966); q: lunar surface (yearStart=1969, yearEnd=1972); q: skylab earth (yearStart=1973, yearEnd=1974); q: space colony (yearStart=1975, yearEnd=1977) | Habitat overlap already present; add settlement synonyms and reviewed items |
| nasa: `nasa-deep-space` | q: nebula (yearStart=1990, yearEnd=2026); q: pillars of creation (yearStart=1995, yearEnd=2026) | Keep existing coverage; reserve nearby terms only |
| nasa: `nasa-orbital-earth-1960s` | q: mercury earth (yearStart=1961, yearEnd=1963); q: earth sky (yearStart=1965, yearEnd=1966); q: apollo 7 earth (yearStart=1968, yearEnd=1968); q: apollo 9 mission image (yearStart=1969, yearEnd=1969); q: skylab earth observation (yearStart=1973, yearEnd=1974) | Keep existing coverage; reserve nearby terms only |
| nasa: `nasa-lunar-orbit` | q: lunar orbit (yearStart=1968, yearEnd=1972); q: lunar farside (yearStart=1968, yearEnd=1972) | Keep existing coverage; reserve nearby terms only |
| nasa: `nasa-aurora-from-orbit` | q: aurora international space station (yearStart=2010, yearEnd=2026) | Keep existing coverage; reserve nearby terms only |
| nasa: `nasa-cape-kennedy-aerials` | q: aerial view (yearStart=1960, yearEnd=1975) | Keep existing coverage; reserve nearby terms only |
| wikimedia: `documerica-1970s` | search: DOCUMERICA sunset; search: DOCUMERICA highway traffic; search: DOCUMERICA night; search: DOCUMERICA skyline; search: DOCUMERICA desert; category: DOCUMERICA photographs by Charles O'Rear; category: DOCUMERICA photographs by John Messina | Keep existing coverage; reserve nearby terms only |
| wikimedia: `fungi-photographs` | category: Featured pictures of fungi; category: Quality images of fungi | Keep existing coverage; reserve nearby terms only |
| wikimedia: `fungi-plates` | category: Icones Farlowianae; category: Illustrations of British Fungi (Hymenomycetes), to serve as an atlas to the "Handbook of British Fungi" | Keep existing coverage; reserve nearby terms only |
| wikimedia: `haeckel-art-forms` | category: Kunstformen der Natur | Keep existing coverage; reserve nearby terms only |
| wikimedia: `landsat-earth-as-art` | pinned files only | Keep existing coverage; reserve nearby terms only |
| wikimedia: `photochrom-landscapes` | category: Photochrom pictures from the Library of Congress; category: Photochrom prints collection | Keep existing coverage; reserve nearby terms only |
| wikimedia: `documerica-western-landscapes` | search: DOCUMERICA canyon; search: DOCUMERICA lake; search: DOCUMERICA mountains; search: DOCUMERICA beach; search: DOCUMERICA fog; search: DOCUMERICA storm; search: DOCUMERICA forest; category: DOCUMERICA photographs by David Hiser; category: DOCUMERICA photographs by Dick Rowan; category: DOCUMERICA photographs by Charles Steinhacker; category: DOCUMERICA photographs by Bruce McAllister; category: DOCUMERICA photographs by Fred Ward | Keep existing coverage; reserve nearby terms only |
| wikimedia: `documerica-smog-and-neon` | search: DOCUMERICA smog; search: DOCUMERICA neon; search: DOCUMERICA freeway; search: DOCUMERICA dusk | Keep existing coverage; reserve nearby terms only |
| wikimedia: `aurora-and-milky-way` | category: Featured pictures of aurora; category: Featured pictures of the Milky Way | Keep existing coverage; reserve nearby terms only |
| wikimedia: `galaxies-hubble-webb` | category: Featured pictures of galaxies | Keep existing coverage; reserve nearby terms only |
| wikimedia: `forests-featured` | category: Featured pictures of forests; category: Quality images of forests | Keep existing coverage; reserve nearby terms only |
| wikimedia: `apollo-archive` | category: Files from Project Apollo Archive Flickr Stream | Keep existing coverage; reserve nearby terms only |
| wikimedia: `american-west-painters` | category: Google Art Project works by Albert Bierstadt; category: Google Art Project works by Thomas Moran | Keep existing coverage; reserve nearby terms only |
| wikimedia: `shin-hanga-pinned` | pinned files only | Keep existing coverage; reserve nearby terms only |
| cma: `cma-ukiyoe-landscapes` | q: Hiroshige (type=Print); q: Hokusai (type=Print); q: moonlight (type=Print) | Keep existing coverage; reserve nearby terms only |
| cma: `cma-early-photographs` | q: landscape (type=Photograph); q: forest (type=Photograph); q: trees (type=Photograph) | Keep existing coverage; reserve nearby terms only |
| cma: `cma-american-landscapes` | q: American landscape (type=Painting) | Pond / marsh / twilight Painting additions |
| cma: `cma-weather-prints` | q: rain (type=Print); q: Hiroshige snow (type=Print); q: Hiroshige moon (type=Print) | Reeds / water lilies Print reserve |
| met: `met-landscapes` | q: Mount Fuji (departmentId=6); q: landscape woodblock; q: moonlight landscape; q: trees photograph (departmentId=19) | Keep existing coverage; reserve nearby terms only |
| met: `met-american-tonalists` | q: moonlight (departmentId=1) | Keep existing coverage; reserve nearby terms only |
| met: `met-early-photographs` | q: Le Gray (departmentId=19); q: Yosemite (departmentId=19); q: waterfall (departmentId=19) | Keep existing coverage; reserve nearby terms only |
| met: `met-hiroshige-night` | q: Hiroshige night (departmentId=6) | Keep existing coverage; reserve nearby terms only |
| dc: `dc-tichnor-postcards` | q: motel; q: highway; q: night; q: skyline; q: desert; q: route 66; q: diner; q: bridge; q: sunset; q: lake; q: moonlight; q: gas station | Radio and rail stations; watch printed lettering |
| aic: `aic-landscapes` | q: moonlight; q: night; q: forest; q: river (type=Painting); q: mountain (type=Painting); q: sunset; q: waterfall; q: landscape (type=Photograph) | Railroad and pond title queries |
| si: `si-american-landscapes` | q: landscape AND unit_code:SAAM; q: space AND unit_code:NASM | DISABLED; optional future work only |

Source authority: [Liminal/Visual/ImageSources/image-collections.json](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Visual/ImageSources/image-collections.json#L135); decoder and supported source fields: [Liminal/Visual/ImageSources/ImageCollections.swift](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Visual/ImageSources/ImageCollections.swift#L14). The complete audit provides a pinned line link for each entry. Commons categories above are existing exact categories; the additional bank uses search strings and invents no categories.

### Footage, fallback and selection inventory

Internet Archive is the only active video provider. The six Prelinger routes are `newsreel` (weight 3), `trippy` (10), `drug-education` (5), `educational` (2), `spaceage` (2) and `bw` (1), within 1950–1969. Newsreel searches newsreel/news magazine/telenews/screen magazine; trippy covers psychedelic, kaleidoscope, hypnosis, optical illusion and experimental-film terms; drug education uses title/subject clauses; educational uses animation/cartoon/visual effects/psychology/science/future; spaceage uses rocket/satellite/outer space/computer/electronic/television; bw uses quoted `color:"B&W"`. Exclusions apply to discovery and again to title/description/subject metadata. Drug education has specific existing exceptions; the new recipes below use the ordinary full exclusions.

Ten explicit pinned films bypass broad discovery filters and may fall outside those dates or the Prelinger collection. `archive-seeds.json` holds 164 metadata records for cold start/search failure, not bundled films. Current weaving favors **four curated-pin pieces to one discovery piece** when both exist; adding a route does not ensure it appears soon. Route selection weights differ from candidate weights: trippy/drug-education candidates get 5, others 1. Known-color discovery needs a color-allowing route and passes at 0.2 odds; raw API counts do not include that decision.

Archive cache policy is 3 GB, **ten pin slots plus two discovery slots**, with a 2 GB free-space reserve. Downloads are sequential; the first three can arrive quickly, later successful downloads are at least 15 seconds apart. Discovery retires after two uses; recent/retired IDs and protected on-screen clips constrain selection. Requests have a two-second gap, 30-second request/600-second resource timeout and no URL cache. New queries do not increase any capacity. Check pin count and budget before adding full films.

Accepted file candidates are MP4, excluding `_edit.mp4`, with supported H.264/MPEG4 format metadata, at least 2 MB and known duration at least 25 seconds. Actual validation requires finite duration, a video track and height at least 200. Selection prefers smallest files for pins or very small caches; otherwise it prefers a main file at most 80 MB, then a 512kb derivative, then smallest. After download, full pins are retained if the pinned budget permits; other sources over 120 MB may be replaced by an interior passthrough excerpt targeting 80 MB, 30–240 seconds, with validation/fallback. That changes available segment and dialogue range.

Source: [Liminal/Archive/ArchiveCatalog.swift](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Archive/ArchiveCatalog.swift#L14) and the complete audit's cache/service/seed excerpts. Dialogue interest weights are a later stage selecting words from already-downloaded/transcribed films; they retrieve neither films nor images. A word such as “mind” in that lexicon does not create a media search.

The still pool is separately 3 GB, targets 36 unseen images, pauses below 1 GB free disk, and waits four seconds plus host gaps (default one second, Met five, AIC two). Sources are selected in a weighted shuffled bag, with source/provider repetition avoidance. Pins are attempted before shuffled query routes. Rejected candidates are not retried; searches refresh after seven days and exhausted sources dry for 30 minutes. Persistent identity/alias/fingerprint deduplication prevents alternate copies from creating fresh variety.

Two bundled standby pictures, `StandbyImages/LiminalLightning.jpg` and `LiminalMushrooms.jpg`, remain the fallback. Legacy/generated `ImageStore`, debug image/directory/pattern overrides, local test video and `docs/media` assets are not active collection providers. Display is disk-only, queues two decoded pictures ahead and applies recency/openness/source weighting; no proposal here changes reveal timing, still/depth/saliency framing, Metal effects or archive weaving.

## Translate interests into visible subjects

| Interest/context | Concrete subjects to seek | Interpretation and boundary |
|---|---|---|
| Consciousness (explicit) | Perception experiments, optical interference, retina/neuron drawings, pond micrographs | Inner-world metaphor; no image is scientific proof of consciousness. Avoid generic brain stock. |
| AI (explicit) | Analog computers, patchboards, magnetic core, terminals, control rooms | History of human/machine interfaces; archival machines need not be AI systems. |
| Cyberpunk (explicit) | Rail platforms, rain, wiring, laundromats, public telephones, layered infrastructure | Grounded urban atmosphere; inspect signage/people and avoid glossy promotional art. |
| Retro music (explicit) | Radio studios, tape machines, record cutting, jukeboxes, record shops | Rooms, machines and places convey music culture without relying on album-cover or portrait feeds. |
| Science fiction (explicit) | NASA settlements, habitat interiors, antennas, observatories, spacecraft interiors | Speculative futures with lived environments; existing space-colony material already contributes. |
| Neuromancer / Neuro (retained music context) | Terminals, rain, transmission, tape, infrastructure | PJ recorded Neuro using Gibson reading Neuromancer. Treat that as atmosphere, not permission to reuse proprietary audio or franchise assets. |
| Regional/minor-key funk/soul, Daptone, Dilla/Premier; archives and overlooked thinkers (retained) | Local radio, record-era rooms, obscure equipment, everyday regional settings | Crate-digging and “hunger over polish” are useful editorial context, not a requirement to depict musicians. |
| Offbeat film / MST3K; Grail Diary discovery (retained) | Strange instructional demonstrations, tactile diagrams, unusual scientific apparatus | Preserve discovery and curiosity; book pages may fail text/crop gates. No blanket B-movie clearance. |
| Ponds/ecosystems and Hudson Valley (related context) | Pond reflections, reeds, marsh, fern plates, Catskill/Hudson regional archives | Optional quieter counterpoint. No identifiable private locations or requirement to turn every hobby into imagery. |

Preference provenance is available locally in `memories/user_profile.md` (compiled profile), the Music section of `knowledge/raw/conversations/2026-04-08_pj-updates-family-career-music.md`, and `knowledge/raw/conversations/2026-04-14_pj-daptone-dj-history.md` (direct conversation captures). These establish relevant tastes; the visual translations above remain editorial inference. This handoff needs no private-profile access to use its query recommendations.

## Prioritized starter: 12 new exact image searches

Counts below are **raw first-page returned records / total matching items**, never admitted pictures. LOC and Commons totals were not requested in a comparable item-count form; “unknown” is deliberate. All twelve were tested. Each string is new relative to current exact provider query strings, although subject overlap is intentional.

| Priority / provider and fit | Exact query | Observed returned / total | Action and caveat |
|---|---|---|---|
| 1 LOC Highsmith; proposed interiors source | `radio studio` | 18 / unknown | Start with empty machine-room imagery; inspected studio 2011634401 is strongest. |
| 2 NASA; space-age habitat extension | `space settlement` | 4 / 4 | Inspect interior/exterior habitats; overlaps current `space colony`. Proposed test years 1960–1980. |
| 3 Commons; proposed machine source | `analog computer` | 20 / unknown | Resolve files/credits and inspect; enriched anchor thumbnail was blocked. |
| 4 NASA; proposed machine-room source | `magnetic tape` | 4 / 4 | Wind-tunnel equipment mixed with geoscience. Search fit is broader than phrase suggests. |
| 5 NASA; proposed machine-room source | `mission control` | 20 / 293 | Prefer room geometry and machinery over prominent people. |
| 6 LOC Highsmith; proposed interiors source | `jukebox` | 7 / unknown | Strong object vocabulary; inspected jukebox is portrait and may crop poorly. |
| 7 Commons; proposed record-machines source | `reel to reel tape recorder` | 20 / unknown | Plausible equipment; inspected white product shot is not a top hero. |
| 8 DC Tichnor postcards | `radio station` | 10 / 10 | Regional architecture; WIAC lettering may trigger page/text rejection. |
| 9 DC Tichnor postcards | `railroad station` | 20 / 86 | Transit/architecture; review text and postcard borders. |
| 10 CMA American landscapes, Painting | `pond` | 20 / 27 | Strong quieter material; keep Painting constraint. |
| 11 AIC landscapes, title match | `railroad` | 20 / 24 | Strong inspected painting; query is on title, not broad full text. |
| 12 LOC Highsmith; proposed interiors source | `record store` | 20 / unknown | Broad matches, including people. Curate carefully rather than assume 20 record shops. |

NASA `analog computer` (3/3) is a reserve: matches simulator/centrifuge descriptive text, not necessarily patchboards. Met `pond` (20/557) is another reserve; `botanical` (20/9078) and `radio` (20/177) are broad metadata results, not evidence of relevance. Do not prioritize Met radio merely because it has hits.

### Candidate stills for item-level review

| Candidate and stable link | Native dimensions / rights evidence | Inspection and next step |
|---|---|---|
| [LOC 2011634401, radio studio](https://www.loc.gov/item/2011634401/) | 6162×4765; “No known restrictions on publication” | Thumbnail inspected: empty 1980s control room. First pin candidate after actual crop/text/device checks. |
| [NASA ARC-1975-AC75-2621, torus interior](https://images.nasa.gov/details/ARC-1975-AC75-2621) | 3393×2604; NASA general usage policy, third-party credit still needs review | Thumbnail inspected: water, greenery and architecture, visually busy. Check existing pins before adding. |
| [NASA ARC-1976-AC76-0525, neighboring habitats](https://images.nasa.gov/details/ARC-1976-AC76-0525) | 3204×2210; same NASA policy caveat | Thumbnail inspected: ring habitats in open black space. Check existing pins before adding. |
| [CMA 124078 / 1944.80, Pond at Ville-d'Avray](https://clevelandart.org/art/1944.80) | 3400×2006; record CC0 | Thumbnail inspected: muted reflected pond/tree masses. Good quiet counterpart. |
| [AIC 33212, Arcueil Aqueduct at Sceaux Railroad Crossing](https://www.artic.edu/artworks/33212) | 2912×2250; `is_public_domain=True` | Thumbnail inspected: green railway/aqueduct with depth; test framing. |

Additional enriched examples are LOC jukebox [2011633318](https://www.loc.gov/item/2011633318/) (5745×7236, no known restrictions; portrait crop risk), [Commons Aria tape recorder](https://commons.wikimedia.org/wiki/File:2017_Magnetofon_szpulowy_Aria_M_2408_SD.jpg) (4070×2874, CC BY-SA 4.0; inspected white product view), [Commons analog computer](https://commons.wikimedia.org/wiki/File:Analog_computer_(19759475290).jpg) (3648×2736, CC BY-SA 2.0; metadata only, HTTP429 thumbnail), and [DC WIAC](https://www.digitalcommonwealth.org/search/commonwealth:x346g4360) (3311×2107, no restrictions; inspected but large lettering). BY-SA needs retained attribution and downstream compliance. NASA hosting alone is not asset-specific clearance.

Baseline pin check: `ARC-1975-AC75-2621` is not found in current image-source pins. Recheck the coding checkout before adding.

Baseline pin check: `ARC-1976-AC76-0525` is already pinned in `nasa-space-age`. Do not add a duplicate.

## Copyable reserve query bank

Use these strings individually with their provider's existing syntax. “Proposed” means not API-tested in this run. “Tested” establishes a response only. The machine-readable companion assigns stable IDs, exact test indices, current/proposed target IDs, media kind, theme, priority and supported type/year constraints. It is a **research interchange file**, not importable app configuration. All `proposed-*` source IDs below are placeholders that do not exist yet; create reviewed source entries only where collection, monochrome or admission policy needs a separate group.

NASA rows use proposed 1960–1980 test/config years, including additions targeting `nasa-space-age`; current queries retain their own narrower years. LOC rows use Highsmith, DC uses Tichnor. CMA quiet habitats uses Painting; CMA reeds/water lilies uses Print. Met broad reserve has no department filter yet and must use classifications supported by its adapter. AIC uses current title matching. Commons rows are plain file searches, with existing namespace-6 `filetype:bitmap` handling, not invented categories. Repeated terms across different institutions are intentional comparison searches.

The bank contains **114 distinct provider/string pairs: 90 untested proposals plus all 24 tested image queries**. Twelve tested queries are the starter; the remainder include cautioned reserves and explicit negatives. No exact provider/string duplicates exist against the baseline's `queries` or `searches`. That does not mean the subjects are new: current space colony, fungi, neon, night, water and landscapes remain substantial overlaps.

| Provider / target source | Pack | Exact individual strings and evidence status |
|---|---|---|
| wikimedia / `proposed-commons-machines` | Analog machinery | `mainframe computer` proposed; `computer terminal` proposed; `magnetic core memory` proposed; `patch panel` proposed; `teletype` proposed; `vacuum tube computer` proposed; `telephone exchange` proposed; `oscilloscope` proposed; `reel to reel tape recorder` **tested**; `analog computer` **tested** |
| nasa / `proposed-nasa-machine-rooms` | Analog machinery | `analog computer` **tested**; `magnetic tape` **tested**; `mission control` **tested**; `control console` proposed; `telemetry` proposed; `satellite ground station` proposed; `Goldstone` proposed; `wind tunnel control room` proposed |
| loc / `proposed-loc-highsmith-interiors` | Record-era places | `radio studio` **tested**; `radio station` proposed; `recording studio` proposed; `telephone booth` proposed; `observatory` proposed; `planetarium` proposed; `laundromat` proposed; `bowling alley` proposed; `bus station` proposed; `theater marquee` proposed; `record store` **tested**; `jukebox` **tested**; `music store` proposed; `record shop` proposed; `drive in speaker` proposed; `observatory dome` proposed; `science museum` proposed |
| wikimedia / `proposed-commons-inner-worlds` | Inner worlds | `Cajal neuron` **tested**; `Purkinje cells` proposed; `retina drawing` proposed; `interference pattern` proposed; `schlieren photography` proposed; `fluid flow visualization` proposed; `diatom micrograph` proposed; `water caustics` proposed; `soap film interference` proposed; `microscope pond` proposed |
| wikimedia / `proposed-commons-night-infrastructure` | Night transit | `rainy neon street` **tested**; `Tokyo railway night` proposed; `empty subway platform` proposed; `elevated railway night` proposed; `Hong Kong alley night` proposed; `tram rain` proposed; `utility wires dusk` proposed; `telephone booth night` proposed; `laundromat night` proposed; `industrial canal night` proposed |
| dc / `dc-tichnor-postcards` | Night transit | `radio station` **tested**; `railroad station` **tested**; `elevated railway` proposed; `subway station` proposed; `New York night` proposed; `theater` proposed; `neon sign` proposed; `Catskill Mountains` proposed; `Hudson River` proposed; `Berkshire lake` proposed; `canoe lake` proposed |
| wikimedia / `proposed-commons-record-machines` | Crate-digger surroundings | `turntable` proposed; `vinyl record grooves` proposed; `record cutting lathe` proposed; `radio mixing console` proposed; `recording studio control room` proposed; `record shop` proposed; `jukebox` proposed; `tape spool` proposed |
| nasa / `nasa-space-age` | Imagined habitats | `space settlement` **tested**; `Stanford torus` proposed; `Bernal sphere` proposed; `space station concept` proposed; `lunar base concept` proposed; `radio telescope` proposed; `Deep Space Network` proposed; `Viking surface` proposed; `Mariner spacecraft` proposed; `spacecraft interior` proposed |
| wikimedia / `proposed-commons-field-notebook` | Field notebook | `satellite dish night` proposed; `planetarium projector` proposed; `pond reflection` proposed; `duckweed` proposed; `reeds reflection` proposed; `moss macro` proposed; `botanical fern illustration` proposed; `astronomical instrument` proposed; `lunar map engraving` proposed |
| cma / `cma-american-landscapes` | Quiet habitats | `pond` **tested**; `marsh` proposed; `twilight` proposed; `reflection` proposed |
| cma / `cma-weather-prints` | Field notebook | `reeds` proposed; `water lilies` proposed |
| met / `proposed-met-water-and-notebook` | Quiet habitats | `pond` **tested**; `botanical` **tested**; `marsh` proposed; `nocturne` proposed; `railway` proposed |
| aic / `aic-landscapes` | Quiet habitats | `pond` **tested**; `railroad` **tested**; `reflection` proposed; `twilight` proposed |

### Negative and low-precision tests: do not silently add

| Provider / exact query | Test result | Decision |
|---|---|---|
| LOC Highsmith `utility wires` | 0 returned | Do not add this exact search there; Commons infrastructure alternatives remain untested. |
| CMA `radio`, type Photograph | 0 / 0 | Do not add. |
| CMA `microscope`, type Print | 0 / 0 | Do not add. |
| DC Tichnor `jukebox` | 0 / 0 | Do not add. |
| AIC title `radio` | 0 / 0 | Do not add. |
| Met `radio` | 20 / 177 | Hold as broad metadata evidence; not starter or relevance proof. |

Commons `Cajal neuron` returned 20 but includes portraits, irrelevant diagrams and undersized pages. The [famous Cajal Purkinje image](https://commons.wikimedia.org/wiki/File:Cajal_-_a_purkinje_neuron_from_the_human_cerebellum.jpg) is 720×1024, so it is not an import recommendation. Some textbook pages around 1258×1334 fail size; larger Wellcome drawings are tall/page-like and require credit and text review. `rainy neon street` returned 20, including many undersized files and larger nightlife images with people/signage concerns; those nightlife thumbnails were not inspected. Prefer narrower lane/platform/infrastructure searches before treating this as a good pack.

Global size, crop, saturation/openness, page-text and face filters remain useful. Do not switch them off for diagrams, postcards or desired retro objects. A separate source policy may be justified after actual candidate review; that is a coding-session decision, not an instruction to weaken the whole feed.

## Video search recipes

The four clauses below were tested inside the **current full ordinary exclusions**, Prelinger collection, movies and 1950–1969. These are proposed new `ArchiveCatalog` routes, not existing routes. Adding them requires Swift changes and mirrored changes to the offline `scripts/archive-curate.py`; editing image JSON cannot activate them.

| Pack / exact inner clause | Current full-filter total | Diagnostic no-NOT total |
|---|---:|---:|
| `computer OR cybernetics OR "magnetic tape"` | 22 | 48 |
| `perception OR "optical illusion" OR consciousness` | 8 | 26 |
| `"sound recording" OR phonograph OR jukebox` | 25 | 43 |
| `microscope OR pond OR astronomy` | 17 | 58 |

The relaxed counts dropped only the complete NOT clause. They are diagnostics, not recommendations to remove safeguards. They retain dates/collection/movie constraints. `OnGuard1956` has excluded “war” in metadata and appears in relaxed perception results: a reviewed pin/excerpt could be considered after watching, not a global war exception. `HowtoLis1957` appears only in relaxed sound results even though fetched title/description/subject contained no local excluded terms; the responsible indexed field was not verified.

Search precision still matters. County Government and Self-Conscious Guy are wrong-direction perception matches. The machine route finds Logic by Machine, Computing for Fun and Incredible Machine records, but attractive titles do not establish rights or whole-film suitability. Pond/microscope also returns industrial ads. Separate film discovery, visual footage selection and soundtrack/dialogue selection; changing an interest lexicon does not retrieve better video.

The following generator prints complete copyable request URLs using each **preserved tested full query**, including every exclusion. Run beside the evidence directory (not supplied here); it makes no request and cannot silently drop the NOT clause:

```python
import json
from pathlib import Path
from urllib.parse import urlencode

evidence = json.loads(Path(
    "liminal-personal-media-evidence/query-results.json"
).read_text())
for record in evidence["results"]:
    if (record["provider"] == "ia"
            and record["variant"] == "new_current_full_filters"):
        print(record["query"])
        print(record["request_url"])
```

For a standalone forward without evidence, this conceptual Swift addition uses the actual current `Query`, `fullQuery` and `searchURL` APIs, so the existing exclusion array is reused rather than copied or abbreviated. It is **not compile-tested**, not a patch, and the weight/color choice is a proposal to review:

```swift
let machines = ArchiveCatalog.Query(
    name: "machines",
    text: #"collection:prelinger AND (computer OR cybernetics OR "magnetic tape")"#,
    weight: 1,
    allowsColour: true
)
let completeQuery = ArchiveCatalog.fullQuery(machines)
let url = ArchiveCatalog.searchURL(machines, page: 1, rows: 50)
```

Do not emit a supposedly runnable query with `NOT (...)` standing in for exclusions. Use current `fullQuery`, or the exact tested URLs in evidence. The live service sends seven repeated `fl[]` fields (identifier, title, year, sound, color, licenseurl, runtime), rows 50, no sort, and chooses random available pages after initial count discovery. The offline helper uses page one/download ordering and is not an exact simulation of live selection.

Untested expansion clauses, to validate separately:

| Pack | Exact additional inner clause |
|---|---|
| Machines | `"data processing" OR "electronic brain" OR "analog computer"` |
| Perception | `"visual perception" OR seeing OR memory OR learning` |
| Recording | `"magnetic recording" OR "radio broadcasting" OR "record player"` |
| Urban | `"city lights" OR subway OR "elevated railway" OR "urban transportation" OR "neon sign"` |
| Futures | `planetarium OR observatory OR "space travel" OR "space station"` |
| Ecosystems | `microscopy OR "plant growth" OR "time lapse" OR "water surface"` |

Franchise/artist names can inspire research; do not expect 1950–1969 Prelinger routes to retrieve Dilla-era music culture or Neuromancer-era fiction. Keep the era constraint honest.

### Concrete film shortlist: review these versions

| Item / stable identifier | Rights and file metadata | What is established / next step |
|---|---|---|
| [Living Stereo](https://archive.org/details/LivingSt1958), `LivingSt1958` | Legacy `http://creativecommons.org/licenses/publicdomain/`; main MP4 48,130,485 B, 640×480 | Item thumbnail inspected: man/speakers/projected text. Watch and check content, duration, faces and actual frame variety before pinning. |
| [Sound And The Story](https://archive.org/details/SoundAndTheS), `SoundAndTheS` | Same legacy dedication; main MP4 148,640,862 B, 640×480; 512kb derivative 103,389,250 B, 320×240 | Thumbnail is title card; record/turntable subject from metadata. Main may take excerpt path depending on pin/budget policy; derivative is much lower resolution. Neither is a ready clip. |
| [Spring Comes to a Pond](https://archive.org/details/SpringCo1952), `SpringCo1952` | Same legacy dedication; main MP4 77,321,447 B, 640×480 | Thumbnail is title card; pond subject from metadata. Main HEAD response recorded, but HEAD is not playable-file or content validation. |

These item records carry legacy public-domain dedication metadata; that is not independent clearance or a claim of watched suitability. Prelinger's [own FAQ](https://www.panix.com/~footage/prelarch.html) says some films are public domain and many are not, while legacy dedications remain valid. [IA's rights guidance](https://archivesupport.zendesk.com/hc/en-us/articles/360014759692-Rights) does not guarantee uploader metadata. Retain exact item version, uploader/rights record, file choice and review result.

Hold these lookalikes for rights review: `Logic_by_Machine`, `0577_Logic_by_Machine_15_01_03_00`, `Sound_and_the_Story_The`, and `0372_Secrets_of_the_Pond_E01245_03_14_56_00` had no `licenseurl`. Do not substitute them for the three listed versions because a title sounds the same. `OnGuard1956` and `HowtoLis1957` have legacy dedication URLs but still need content/filter review. No full-film viewing was part of this search research.

## Implementation brief and acceptance

Start with the existing image configuration and provider adapters. A separate Highsmith interiors source is useful if weight, monochrome or gates need deliberate treatment; a new institutional provider is unnecessary. Keep the supported schema. For example, these are real source/query fields, with a **proposed** source ID and proposed years, not a claim this source exists:

```json
{
  "id": "proposed-nasa-machine-rooms",
  "provider": "nasa",
  "enabled": true,
  "weight": 1,
  "themes": ["analog machinery", "human machine interfaces"],
  "queries": [
    {"q": "magnetic tape", "yearStart": 1960, "yearEnd": 1980},
    {"q": "mission control", "yearStart": 1960, "yearEnd": 1980}
  ],
  "pinned": [],
  "license": "nasa",
  "allowMonochrome": false
}
```

This is a field-shape example, not a final source policy: check NASA's existing rights behavior and inspect whether monochrome equipment warrants a separate source. Do not copy research-bank keys such as `theme`, `evidenceStatus` or `targetSourceId` into app JSON expecting executable behavior. Existing source `themes` remains descriptive. Existing `defaults.maxRequestsPerSecond` is not decoded; actual pacing comes from ingest/host gaps.

| File / component | Authorized follow-on scope to consider |
|---|---|
| `Liminal/Visual/ImageSources/image-collections.json` | Reviewed starter queries/source entries and item pins; verify duplicates, exact syntax and source-specific gates. |
| `Liminal/Visual/ImageSources/ImageCollections.swift` | Use existing supported schema and decode tests; change only if an actual unmet requirement emerges. |
| `Liminal/Visual/ImageSources/CuratedImageFeed.swift` | Request/candidate provenance and bounded preview evidence as needed; preserve pacing/dedup/cache behavior. |
| `Liminal/Visual/ImageSources/CuratedImagePool.swift` | Inspect admission/display outcomes; preserve disk-only display and selection policy. |
| `Liminal/Archive/ArchiveCatalog.swift` | Proposed routes, explicit weight/color decisions, current exclusion reuse; no global exclusions removal. |
| `scripts/archive-curate.py` | Mirror route changes; validate syntax against live query construction while acknowledging offline ordering differences. |
| `ArchiveSeedList.pinned` / `archive-seeds.json` | Only after film/content/rights/file review; inspect actual defining file and cache capacity before pin changes or seed regeneration. |

Acceptance should measure **usable new unique yield**, not API totals:

1. Decode/validate source config and compare against the pinned baseline. Report new strings, intentional semantic overlaps, exact duplicate provider/query pairs and duplicate item pins. The proposed bank's exact-pair check is already clean against this baseline; re-run on the actual coding checkout.
2. Validate every provider request in its own syntax: NASA query years; Highsmith/Tichnor collection; Commons file search and file license/artist; CMA type; Met v1.1 search and object-level public-domain/classification checks; AIC title/public-domain bool query and IIIF resolution. A search hit is not a resolved asset.
3. Log request → raw hits → resolved candidates → rejection reason → admitted unique assets → actually shown IDs. Keep source/item provenance in the bounded review session. Compare fresh admitted yield and scene variety against existing pool contents, not total retained files.
4. Inspect at least ten admitted images per starter pack on macOS and visionOS/device with actual Vision gates. A pack is a subject grouping and may combine several starter searches. If fewer than ten survive, report that limitation and inspect all survivors. Check 3:2 crop, legible text/page rejection, faces, openness/key share, saliency/depth and rendered readability. Simulator omits Vision face/text checks; failed device Vision can pass with a log, so record that explicitly.
5. If yield is weak, narrow/broaden one field and try provider-appropriate synonyms. Do not relax global size/rights/text/face filters merely to increase counts. Current JPEG/PNG, 12 MB, 150 MP declared-canvas and 2000×1333 cover-crop constraints remain. Existing rejected-ledger entries do not retry; a changed criterion may need targeted versioning/migration. Do not clear the whole pool.
6. Verify bounded review can actually show the new source/items despite 43 enabled-source weighted selection and the four-to-one pin/discovery video bias. Use explicit provenance; adding queries alone is no visibility guarantee. Keep cache/network/disk policies, recency, fingerprint/alias dedup and on-screen protection.
7. For films, watch the chosen file/version, inspect varied frames and content, verify record rights, run AVAssetReader validation and check full-pin/excerpt/derivative behavior before adding. Query additions leave ten pins/two discovery slots unchanged. Preserve dialogue/transcription and music behavior.
8. Run the relevant Liminal config/unit/build checks available to the coding session and report actual device limits. This research handoff is not a compile or deployment result. Keep render code and effects outside the proposed change unless a demonstrated integration defect requires a separately reviewed fix.

### Optional providers, lowest priority

Smithsonian already has an adapter but is disabled and needs a key. The indexed primary [J Dilla Minimoog Voyager record](https://www.si.edu/object/minimoog-voyager-synthesizer-used-j-dilla%3Anmaahc_2014.139.2a) says CC0; direct open returned 403. It is an interesting optional lead, not a checked asset or recommended pin. The [LOC Gottlieb free-to-use set](https://www.loc.gov/free-to-use/gottlieb-jazz-photos/) is real but largely portraits, with likely prominent-face concerns; optional content research, not starter. These supplemental primary references were not additional tested provider queries.

NASA video would require a video integration beyond the current image-only NASA path. LOC film is likewise not an existing image-adapter video route. Historical institutional computer collections may be useful but permission/API/asset reuse is uncertain. None is needed to validate the proposed direction.

## Primary references and scope

[Official NASA API](https://images.nasa.gov/docs/images.nasa.gov_api_docs.pdf) establishes request syntax; [NASA usage policy](https://www.nasa.gov/nasa-brand-center/images-and-media/) covers acknowledgement/third-party/person exceptions. The [NASA retrofuturistic space-art introduction](https://www.nasa.gov/image-article/retrofuturistic-nasa-space-art/) provides context for 1970s settlement art, not a separate API test or license for every hosted image.

Provider documentation: [LOC JSON](https://www.loc.gov/apis/json-and-yaml/), [MediaWiki search](https://www.mediawiki.org/wiki/API:Search), [Commons reuse](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia), [CMA Open Access API](https://www.clevelandart.org/open-access-api), [Met API/migration](https://metmuseum.github.io/), [Digital Commonwealth API](https://www.digitalcommonwealth.org/api), [AIC API](https://api.artic.edu/docs/), and [Internet Archive complex search](https://help.archive.org/help/search-building-powerful-complex-queries/). Official references support syntax/policy; preserved responses support observed counts. No scholarly argument or scientific evidence about consciousness is claimed here.

## Copy/paste task for the coding session

> In current Apple Liminal, compare the working checkout with baseline `5d21cdc93db1f2c7bb8d494605d0637fba407d27`. Implement a small source-content expansion using the 12 tested starter searches in this handoff, prioritizing empty radio/analog rooms, imagined habitats, record-era equipment, rail environments and pond paintings. Treat all proposed source IDs and weights as reviewable configuration, not existing behavior. Check item pins for duplicates, preserve per-provider syntax/rights and current admission/cache/network rules, and keep existing rendering and music. Add the four proposed Archive routes only after explicit weight/color decisions, mirror the offline helper, and retain full current exclusions. Review exact film versions before any pin additions. Use a bounded source/item-provenance preview to inspect at least ten admitted images per starter pack on macOS and visionOS/device where available; report raw/resolved/rejected/admitted/shown unique yield and limitations. Prefer three strong fresh images per pack before broad reserve expansion. No new theme UI/provider, global filter relaxation or Push work is required. Run relevant config/tests/build checks and return the actual diff, evidence and unresolved device/rights decisions.
