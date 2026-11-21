# Library of Congress high-resolution survey for Liminal API mode

Tested 2026-11-21. All requests were made with `User-Agent: Liminal/1.0 (research)` at about 1 request per second. LoC answered 503 twice during the run, and its search JSON came back truncated three times. Downloads, contact sheets, logs and probe scripts stayed in a scratch folder outside the repository. The sources it led to are in `image-collections.json` (`decisions/images.md` D45); the queries were re-checked and the entries written by the lead after this report.

## The short version

- **Nearly every Prints & Photographs collection reaches 2000 px through the scanned-master IIIF route**, not only FSA colour. The pattern is the same one `LOCProvider.masterIIIF` already uses. Take the thumbnail `https://tile.loc.gov/storage-services/service/pnp/<agg>/<dirs>/<id>(_150px|t|r|v).(jpg|gif)`, then request `https://tile.loc.gov/image-services/iiif/master:pnp:<agg>:<dirs with / as :>:<id>u`. Search results usually carry only `_150px.jpg` or `t.gif` thumbnails, and the existing regex already handles both. No new id or suffix pattern was needed for any kept collection.
- **The John Margolies Roadside America archive is online in high resolution.** The research doc says "1024 only", but that no longer holds. The masters are 3500x5200 or 5200x3600 (39 of 40 sampled, 97%). It is not a `/collections/<slug>/` collection, so it needs a small `LOCProvider` change (a `partof` facet on `/photos/`). It is the best vibe match found: 1976-1995 Kodachrome slides of motel neon, drive-ins, diners, gas stations, dinosaurs and mini golf, mostly under deep-blue skies.
- **Scaled IIIF requests fail on a large share of masters.** They return HTTP 500 for `full/!2528,2528`, `full/2528,`, `pct:` and region requests alike. Only `full/full/0/default.jpg` works. The app's existing 5xx fallback covers this. Measured scaled success rates: Margolies 0/20, photochrom 9/19, Japanese prints 7/21, Detroit 8/19, Prokudin-Gorskii 20/20, FSA B&W 5/16. The `info.json` `tiles` field does not predict which masters fail: every one reports `scaleFactors: [1]`.
- **Byte budget.** `full/full` JPEGs are 0.4-10 MB for every kept collection except FSA/OWI B&W 4x5 negatives. Those masters are 13,600-14,400 px and come out at 10.6-18.1 MB, so 5 of 16 sampled are over the 12 MB `maxBytes`.
- **Rights.** The kept collections are all "No known restrictions on publication/reproduction". HABS/HAER and about 10% of FSA B&W carry "No known restrictions on images made by the U.S. Government; images copied from other sources may be restricted". `ImageRights.canonical` rejects these because the text contains "restricted", which is the safe outcome. The following are rejected on rights:
  - Look, about 95% "Publication may be restricted";
  - Horydczak, "Publication may be restricted";
  - Matson hand-coloured lantern slides, "Publication may be restricted";
  - the Bill Graham/Avalon psychedelic posters, "Rights status not evaluated";
  - NYWT&S, mostly restricted.

## Collections kept (now in image-collections.json)

| id | Collection / route | Total online | ≥2000 px in sample | Long side | full/full size | Rights | Rebate | Weight |
|---|---|---|---|---|---|---|---|---|
| loc-margolies-roadside | `/photos/?fa=partof:john margolies roadside america photograph archive` (needs code change) | 11,708 images; 990 hits for "motel", 326 "motel sign", 325 "drive-in", 756 "gas station", 525 "mini golf" | 39/40 (one 500 on info.json) | 5000-5330 | 0.9-2.1 MB (20/20 under 12 MB) | "No known restrictions on publication. For more information, see 'John Margolies…'" (accepted) | Yes: black slide mount, trims cleanly with `trimScanEdges` | 3 |
| loc-photochrom | `photochrom-prints` | 7,501 | 53/55 (two info.json timeouts that answered on retry) | 3,400-7,470 | 1.5-6 MB (19/19 under 12 MB) | "No known restrictions on publication." / "…on reproduction." (both accepted) | The 2008/2017 series have a thin black rebate; the 2001/2002 series are clean with a caption strip | 2 |
| loc-prokudin-gorskii | `prokudin-gorskii` | 2,609 | 52/52 | 2,900-3,780 (often square) | 0.4-1.8 MB, and scaled 20/20 OK | "No known restrictions on publication. For additional information on commercial use…" (accepted); about 2% empty, which is rejected | **RGB misregistration fringes** 4-8% on left and right; the dark-edge trimmer misses them (see code change 3) | 1 |
| loc-detroit-landscapes | `detroit-publishing-company` | 25,390 | 46/50 (four tiny 500x420 card scans) | 3,600-8,060 (8x10 glass negatives about 5,100x4,050) | 1.3-3.8 MB | "No known restrictions on publication." | Dark glass-plate edges, damaged corners; mostly **monochrome** | 1 |
| loc-japanese-prints | `japanese-fine-prints-pre-1915` | 2,787 | 32/32 | 2,360-10,000 | 0.4-7.5 MB | "No known restrictions on publication." (1 of 80 "not evaluated") | Paper mounts and margins on some (BorderTrimmer and the paper gate decide); no film rebate | 1 |
| loc-gottscho-fireworks | `gottscho-schleisner` (fireworks only) | 29,010 total but only 14 fireworks | 11/12 fireworks; **8/43 across general queries** (most masters are 560x420 copies) | 4,390-5,210 | 0.2-0.8 MB | "No known restrictions on publication. For information, see: 'Gottscho-Schleisner Collection'" | Rounded dark transparency mount: `trimScanEdges` | 1 |
| loc-fsa-owi-bw-landscapes | `fsa-owi-black-and-white-negatives` | 169,683 (171,440 per collection list) | 38/40 | 4,300-14,400 | 1.3-18.1 MB; **11/16 under 12 MB** | 90% "No known restrictions. For information, see U.S. Farm Security…" (accepted); 10% "images copied from other sources may be restricted" (rejected) | Negative rebate and edge codes: `trimScanEdges` | 1 |
| loc-popular-graphic-arts-moonlight | `popular-graphic-arts` | 18,932 (20 "moonlight", 56 "sunset", 218 "lake") | 20/20 | 5,700-10,840 | 2.6-9.9 MB, scaled 0/6 | 89% accepted ("No known restrictions on publication."); 11% "not evaluated"/"may be restricted by other countries" (rejected) | Paper margins with printed captions under the image on Currier & Ives-style prints | 1 |
| loc-highsmith-space-fair | `carol-m-highsmith` (new themes) | 89 "space center", 72 "ferris wheel", 70 "fireworks" | 47/47 | 4,100-11,600 | `service:` items scale fine; `master:` items (2018+) need the full fallback | "No known restrictions on publication." | No | 1 |
| loc-matson-desert | `/photos/?fa=partof:matson (g. eric and edith) photograph collection` (needs code change) | 22,036 images; 281 "desert", 664 "dead sea" | 24/24 | 4,550-6,150 | small; scaled OK 3/3 | "No known restrictions on publication. For information see: 'G. Eric and Edith Matson…'" (accepted); the hand-coloured lantern slides are "Publication may be restricted" (rejected) | Glass-negative edges: `trimScanEdges`; **monochrome** | 1 |

### Notes per kept source

**Margolies.** All 20 sampled items return 500 for every scaled size, while `full/full` works (0.9-2.1 MB, 5,200x3,600). The app already falls back on 5xx, so only the wasted first request costs anything. Many frames are vertical (3,500x5,200): their 3:2 cover crop keeps the middle third and cuts sign tops (see `trim-a.jpg`). The landscape frames are better, so the pins are all horizontal. The trimmer simulation (`trim.py`, a port of `ScanEdgeTrimmer`) found the slide mount on all 6 test frames, at 9-15 of 300 columns per side and up to 65 on one vertical frame, and left clean pictures. The titles are plain English ("Astro Motel sign…"), so `rejectTitleWords` works there. The "space" query returns only a 1990s shuttle launch, so it is not used. Rights page: https://www.loc.gov/rr/print/res/723_marg.html.

**Photochrom.** This source overlaps the existing Commons `photochrom-landscapes` source, which uses copies of the same LoC masters. The same picture could therefore arrive twice under two provider ids. Either keep the weight low or drop the Commons source; the LoC route is the original, with the rights field read directly. About 15% of results are costume or "type" portraits ("[A Girl of the Black Forest…]"), so the entry rejects those title words. Queries that came back empty because LoC timed out the first time ("canyon", "moonlight") returned results on retry (23 and 17 hits).

**Prokudin-Gorskii.** These are 1905-1915 three-colour glass-plate composites. Most have saturated red, green and blue misregistration bands where the three plates do not overlap. The bands are measured at 3.7-7.3% on the left and right sides and 7-14% on the top and bottom. The 3:2 cover crop of a square frame already removes 16.7% from the top and bottom, so only the side bands survive. `ScanEdgeTrimmer` looks only for dark lines, which leaves the side bands visible (see `trim-a.jpg`, frames 2018680409, 2018680980 and 2018679170). Some items, for example 2018679724, are clean re-composites without bands. Without code change 3, the source still works, but some pictures will show thin coloured bars on the sides. Most titles are in transliterated Russian; "Zakat" means "sunset".

**Detroit Publishing.** These are 1880-1920 8x10 glass negatives (B&W) at about 5,100x4,050, and they scale for about 40% of items. About 8% of hits are 500 px scans of photochrom postcards, which the size gate rejects. Monochrome counts toward `monochromeEvery: 6` together with FSA B&W and Matson, so all three get weight 1.

**Japanese prints.** These overlap the Cleveland and Met ukiyo-e sources but reach a higher resolution here (up to 10,000 px). Masters over about 5,000 px usually need the full fallback, at up to 7.5 MB. Many titles are romanized Japanese, so title filters do little. The "mount fuji" query returns Hokusai *envelopes* (pictorial wrappers), which `rejectTitleWords: ["envelope"]` filters.

**Gottscho-Schleisner.** Only a few colour transparencies have full scans; most masters are 560x420. The 1939 World's Fair fireworks series is the find: magenta and blue bursts on black, the most psychedelic LoC pictures seen. The source has a single query, the 11 large items are pinned, and the rest is left to the size gate.

**FSA/OWI B&W.** The 35 mm and 2¼ masters (4,300-5,600 px) scale fine at about 1.3-2 MB. The 4x5 negatives (about 13,800x10,600) only serve `full/full`, at 10.6-18.1 MB, so about 30% of a landscape sample is lost to `maxBytes` 12 MB (see code change 2). Decoding a 147 MP JPEG through `CGImageSourceCreateThumbnailAtIndex` uses DCT scaling, so memory should be fine, but this is unmeasured in the app. Good subjects: Many Glacier highway, dust storms, grain elevators, Lander County desert. "clouds" returns two pure cloud studies (2017697935, 2017693804) with an **empty** rights field, which is rejected, so the query is not used. Monochrome only.

**Popular Graphic Arts.** These are 1850-1900 chromolithographs (Currier & Ives and others): moonlit lakes, a "Moonlight in Egypt", sunsets. Scaled requests fail and the full files are 2.6-9.9 MB. Paper margins and printed captions sit under many prints. The openness and paper gates should reject the busiest ones, but the caption crop is unverified in the app.

**Highsmith space/fair.** This uses the same collection and route as the two existing Highsmith sources, with new themes: the 1980 Space Center Houston rocketry series, the 2010 Huntsville Space & Rocket Center, colourful state-fair Ferris wheels at dusk, and fireworks. "psychedelic" and "googie" return 0 hits. "mushroom" finds only Phoenix's mushroom-shaped shelters, which are architecture, not fungi.

**Matson.** The 1898-1946 B&W glass negatives of the Sinai, Palmyra, the Dead Sea and sand dunes are strong empty-horizon pictures. Like Margolies, Matson is not a `/collections/` slug and needs the `partof` route. The colour lantern slides are rights-restricted and sit inside a heavy black mask (25-40% per side, beyond `ScanEdgeTrimmer.maxSideShare`), so they are excluded either way.

## Collections examined and rejected

| Collection | Slug / route | What was measured | Why rejected |
|---|---|---|---|
| WPA posters | `works-progress-administration-posters` (946) | 20/24 ≥2000 (3,450-9,250), rights OK | Every poster is portrait with large lettering ("See America", "Visit the zoo"). It fails the no-text brief. |
| Genthe (autochromes) | `genthe` (16,862) | 0/24 ≥2000: masters are 300-560 px copies | Too small. |
| Horydczak | `horydczak` (14,331) | 1/24 ≥2000 | "Publication may be restricted" on every item. |
| Look Magazine | `look-magazine` (8,283) | 25/25 ≥2000 (3,000-7,000) | About 95% "Publication may be restricted" (95 of 100 unfiltered results). The unrestricted ones are staff portraits ("Girl astronaut"). |
| NYWT&S | no collection slug; only items in "miscellaneous items in high demand" under `/photos/` | Mixed sizes | 16 of 25 sampled "Publication may be restricted", 5 "No information on creator or on reproduction rights", the rest portraits/newsroom. No facet to scope a search. |
| Harris & Ewing | `harris-ewing` (41,543) | 6/6 ≥2000 (glass negatives 4,000x5,100), rights OK | 1905-1945 DC news and portraits in B&W. Only cherry blossoms fit the brief, and monochrome is already covered by FSA, Detroit and Matson. Could be a pinned handful later. |
| National Photo Company | `national-photo-company` (35,635) | 2/6 ≥2000; many 1,536 px | Mixed small masters, some "Rights status not evaluated", 1909-1932 DC news. |
| Bain | `bain` (41,522) | 6/6 ≥2000 (3,200-7,000) | B&W news and portraits, 1900-1920s. Wrong period and subject. |
| Panoramic photographs | `panoramic-photographs` (4,322) | 23/24 long side ≥2000, but the short side is 570-730 px on 75% | 4:1-6:1 ratio. Fails the app's `minShortSide` 1,365 and the 3:2 crop discards the panorama. A few giants (21,764x6,420, 10 MB) exist. |
| Stereograph cards | `stereograph-cards` (55,874) | 3/5 ≥2000 (4,800x2,340 cards) | Two side-by-side frames on a printed card mount. A cover crop shows the seam. Needs a half-crop feature. |
| HABS/HAER/HALS | `historic-american-buildings-landscapes-and-engineering-records` (43,353) | 28/32 ≥2000 (5,000-10,240); masters use a `p` suffix (`.../photos/347223p_150px.jpg` → `...:347223pu`) and work | 100/100 rights strings contain "images copied from other sources may be restricted" → `ImageRights` rejects. Also B&W architectural documentation with HAER labels and some postcard copies. |
| Cabinet of American Illustration | `cabinet-of-american-illustration` (3,914) | 0/5 ≥2000 (1,024 max) | Too small; drawings. Some "Publication may be restricted". |
| Fine Prints (general) | `fine-prints` (4,626) | 4/6 ≥2000 | Rights mixed: empty, "may be restricted". The small yield of moonlight etchings is not worth a source. |
| Artist Posters / Performing Arts / Yanker | `artists-posters` (4,410), `performing-arts-posters` (2,100), `yanker-posters` (3,500) | n/a | The psychedelic rock posters (Bill Graham, Matrix, Jimi Hendrix) are "Rights status not evaluated". The Yanker "psychedelic light and sound show" poster is a text poster. All are text-heavy. |
| Gottscho-Schleisner (beyond fireworks) | `gottscho-schleisner` | 0/12 "world's fair night", 0/11 "lagoon", 0/12 "trylon", 2 of 8 "skyline" | Most masters are 560x420 reference copies. |
| U.S. News & World Report | no collection slug or `partof` facet (items sit in "miscellaneous items in high demand") | Masters 5,200-5,440 px (e.g. `ppmsca:54500:54560u` 5229x3651); scaled 0/4, full 1.7-2.4 MB; rights "No known restrictions on publication. For information see 'U.S. News & World Report…'" | Not rejected on merit: 1960s-70s highways, expressways and aerial cities, the right era. But it is B&W, and the only way to scope a search is the free-text "U.S. News & World Report" or the staff-photographer `contributor` facet (Leffler, Trikosko, O'Halloran). That needs a further provider option, so it is left for later. One `full/full` download came back truncated (49 KB, HTTP 200); the app's decode would reject it. |

## Code changes LOCProvider (and friends) need

1. **Search by `partof` facet on `/photos/` (needed for Margolies and Matson).** `LOCProvider.search` hard-codes `https://www.loc.gov/collections/<collection>/`. Margolies (`/collections/john-margolies-roadside-america-photograph-archive/` → 404) and Matson (`/collections/matson-photograph-collection/` → 404) only exist as facets. Verified working: `https://www.loc.gov/photos/?fo=json&q=motel&c=25&sp=1&fa=partof:john margolies roadside america photograph archive|online-format:image`. This returned 990 results, and the JSON is identical in shape to the collection search: `results[].image_url`, `item.rights_advisory`, `pagination.next`. Proposal:
   - add an optional `partof: String?` to `CuratedSource`;
   - in `search`, when `partof` is set, use base `https://www.loc.gov/photos/` and `fa = "partof:\(partof)|online-format:image"`, otherwise the current `/collections/<collection>/` URL;
   - make `collection` optional for those entries; the guard `let collection = source.collection` currently returns an empty page;
   - `parseSearch`, `parseItem`, `masterIIIF` and the pinned-item path (`/item/<id>/?fo=json`) work unchanged. Pinned items resolve the same way, verified for 2017703592.

   In the research draft the two entries carry both `"partof"` and a placeholder `"collection"` equal to the facet, so they are self-describing. Drop `collection` if the field becomes optional.
2. **`maxBytes` for LoC full-master fallbacks (FSA B&W 4x5 negatives).** These masters only answer `full/full`, at 10.6-18.1 MB, so 5 of 16 sampled are over 12 MB. `ImageHTTP.download` then throws `tooLarge`. Options:
   - a per-source `maxBytes` override, for example 20,000,000 for `loc-fsa-owi-bw-landscapes`;
   - accept the loss of about 30% of that source.

   Also measure memory and time for decoding a 147 MP JPEG on visionOS. `CGImageSourceCreateThumbnailAtIndex` should use DCT scaling, but that is unmeasured. No other kept collection exceeded 10 MB: the largest were Popular Graphic Arts 9.9 MB, the 21,764 px panorama 10.3 MB, and Japanese prints 7.5 MB.
3. **Prokudin-Gorskii colour fringes.** `ScanEdgeTrimmer` only walks dark lines (`darkLuma` 0.16), and the P-G plate edges are saturated red, green, blue, yellow or magenta bands, 4-7.5% wide on the left and right. Options:
   - a per-source fixed inset, for example `"edgeInset": 0.08`, applied before the cover crop. It is simple and loses little of a square frame: 3,744² → about 3,145x2,097 after the 3:2 crop, still ≥2048x1365;
   - extend `ScanEdgeTrimmer` so it also counts a line as rebate when its mean saturation sits far above the frame's interior. Sky lines are low-saturation, so they would not trip it. My Python heuristic (`fringe.py`: line saturation > interior + 0.12) found 3.7-7.3% on the sides.
4. **Optional: skip the doomed scaled request.** For Margolies, 20 of 20 scaled requests were 500. A source flag such as `"masterFullOnly": true` could request `full/full` directly and save one round-trip per picture. Each 500 takes 0.1-0.5 s, so this is a nicety, not a need.
5. **Cold masters.** The first `info.json` for an uncached master (`master:pnp:ppmsca:18200:18244u`) did not answer within 40 s. It answered in 0.07-0.14 s a minute later. `ImageHTTP` uses `timeoutIntervalForRequest` 30 s, so the first try may time out. Treat it as a soft, retryable failure rather than a permanent rejection of the item (I did not check what the ledger does today).
6. **No changes needed to `masterIIIF`.** All the kept collections' thumbnails match the existing regex (`_150px.jpg`, `t.gif`, `v.jpg`): `mrg`, `matpc`, `ppmsc`, `ppmsca`, `prokc`, `det`, `cph`, `fsa`, `ppmscd`. HABS uses `<n>p_150px.jpg`. The regex captures `.../347223p` and appends `u`, which gives the working `347223pu` master. So HABS would work too, apart from its rights.
7. **Rights.** No change is recommended. The "images copied from other sources may be restricted" family is correctly rejected. "No known restrictions on reproduction." (photochrom 2001/2002 series) is already accepted by the `hasPrefix("no known restrictions")` rule.

## Vibe judgement (from the contact sheets)

- Best: Margolies (neon, drive-ins, blue skies; 1970s-80s Kodachrome), Gottscho fireworks, photochrom lakes and sunsets, Prokudin-Gorskii rivers (pink and turquoise palettes), Hiroshige and Hokusai moon prints.
- Good for the monochrome sixth: FSA Glacier highway and dust storms, Detroit canyons and night views, Matson desert.
- Weaker: Popular Graphic Arts (captions), Highsmith space (2010 museum displays; the 1980 Houston series is better).

## sources.json notes

- `loc-margolies-roadside` and `loc-matson-desert` need code change 1 (`partof`). Until that lands, keep them disabled; the placeholder `collection` value would otherwise 404.
- `loc-prokudin-gorskii` works today but shows side fringes until code change 3 lands.
- `loc-fsa-owi-bw-landscapes` loses about 30% of its 4x5 items to `maxBytes` until code change 2 lands. Its pins are dust-storm items (6144x4744 and 8824x5424), not the 16 MB Glacier frames.
- `rejectTitleWords` is generic in `CuratedSource.rejectsTitle`, so it applies to LoC.
- The pins were measured through info.json (all ≥2000 px, rights accepted). Some were also downloaded and viewed: Margolies 2017703583/91/92, photochrom 2008678241, 2017649296, 2017649299 and 2001700813, P-G 2018679724, 2018680980 and 2018679170, Japanese 2008661032, 2008680225 and 2008660526, Gottscho 2018750452-455, and PGA 2003677746, 2018756622 and 2017650239. The rest were chosen from their titles and sizes and have not been looked at. The final pin download batch was cut short when the lead asked me to wrap up.
