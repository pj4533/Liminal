# Adding an API image source

[← Image sources](README.md) · [Pipeline](pipeline.md) · [Sources](sources.md) · [Providers](providers.md) · [Research history](research-history.md)

There are two cases:

- **A new source for an existing provider** (another LoC collection, Commons category, NASA query or museum search). This is a JSON edit plus verification.
- **A new institution**, which also needs a provider: one Swift file, a registry line, a provider block, fixtures and tests.

Either way, the work has four steps: research the collection, write the entry, build and test, then verify live without touching the user's pool or spending Gemini budget.

## 1. Research the collection

The bar a picture has to clear is set by the pipeline ([pipeline.md](pipeline.md)):

- **Size:** a 3:2 cover crop of at least **2000 x 1333**. The long side is fetched near 2528.
- **Rights:** the item's **own record** says public domain, CC0, "no known restrictions", "no restrictions", or CC BY / CC BY-SA with a named creator.
- **Format:** JPEG or PNG, at most **12 MB**, at most 150 megapixels.
- **Room for the film:** at least 4% of the frame in the film's key (shadows or highlights), an openness of at least 0.2, not a document, not monochrome (unless the subject is), no large text, no prominent faces.
- **The vibe:** psychedelic, 1950s-70s, old film and old imagery, mushrooms, trees, landscapes, retro roadside and cityscapes, driving, space age, surreal. The brief is in D36.

Work in the session scratchpad, never in the repository. Send a research User-Agent such as `Liminal/1.0 (research)` with no personal details, and keep to about one request per second per host (5 s for the Met).

### Find where the high resolution is

Most failures are "the API only shows a 1024 px preview". Before giving up on a collection:

1. **Read the item record, not just the search result.** Look for every derivative: `files`, `resources`, `images`, `representation`, `access_point` or `digitally_shown_by`.
2. **Look for a IIIF service.** If any URL contains `/iiif/`, take the part before `/full/` and request `{service}/info.json`. It gives the native `width`, `height`, and sometimes the allowed `sizes` or a `maxWidth`. Then try `full/!2528,2528/0/default.jpg`, `full/3000,/0/default.jpg` and `full/full/0/default.jpg`, and note which ones answer 200, 403 or 500. AIC answers only a few fixed widths, and some LoC masters answer only `full/full`.
3. **Use the OpenPics trick.** The user's earlier app, OpenPics ([openpics.md](../research/image-apis/openpics.md)), reached high-resolution LoC files through old endpoints that still name the TIFF master. A master path often maps onto a IIIF id. For LoC, `storage-services/service/pnp/<path>v.jpg` becomes `image-services/iiif/master:pnp:<path with : for />u`. Check under which prefix the server serves masters (`master:` at LoC, not `service:`); a guessed id with the wrong prefix returns 404 and looks like "no master". This is how FSA/OWI colour went from "1024 px only" to 4641-7738 px (D44).
4. **Look for mirrors.** Commons holds full-size copies of LoC photochroms (up to 7300 px) and NARA's DOCUMERICA. The Internet Archive mirrors the Met.

### Measure

- **Read the real pixel size from a file header** with an HTTP Range read of 256 KB:

  ```sh
  curl -s -A 'Liminal/1.0 (research)' -r 0-262143 -o head.jpg "$URL" && sips -g pixelWidth -g pixelHeight head.jpg
  ```

  You can also read `info.json`, or download a few files whole and measure them with `sips` or PIL. Spot-check that the reported size matches what is served.
- **Sample 20-40 results per query** and count how many pass 2000 x 1333 after a 3:2 cover crop. A very wide panorama or a narrow portrait can fail even when its long side is large.
- **Check file weight.** Note anything over 12 MB, and whether a smaller derivative that still passes the gate exists. NASA's `~large` does not: it is 1920 px.

### Check the rights per record

- Find the field that carries the item's rights, and list the values it takes across a sample.
- Confirm the values canonicalise to an allowlist label (`ImageRights.canonical`). Values that contain NC, ND, "not evaluated" or "restricted" are always rejected.
- Collection-level claims are not enough. Digital Commonwealth's collections are mixed, and the Met's search ignores its own public-domain filter.
- Watch for traps where a "Public domain" label is wrong. Commons marks post-1930 shin-hanga "PD" even though those prints are probably under US copyright through URAA. When in doubt, pin only the items you have checked.
- CC BY and CC BY-SA need a creator in the record; otherwise the picture is rejected.

### Judge the vibe on contact sheets

Lay out the first 18-30 size-passing results per query as thumbnails, **centre-cropped to 3:2** the way `ImageFraming` crops. Judge each one against the brief and the gates. For example, with PIL (run on downloaded files with `python3 -I` from a separate directory):

```python
from PIL import Image
import glob, math, sys
files = sorted(glob.glob(sys.argv[1] + "/*.jpg"))[:30]
W, H, cols = 300, 200, 6
sheet = Image.new("RGB", (W * cols, H * math.ceil(len(files) / cols)), "black")
for i, f in enumerate(files):
    im = Image.open(f).convert("RGB")
    a = im.width / im.height
    if a > 1.5:   # cover crop to 3:2, centred
        w = int(im.height * 1.5); im = im.crop(((im.width - w) // 2, 0, (im.width + w) // 2, im.height))
    else:
        h = int(im.width / 1.5); im = im.crop((0, (im.height - h) // 2, im.width, (im.height + h) // 2))
    sheet.paste(im.resize((W, H)), ((i % cols) * W, (i // cols) * H))
sheet.save(sys.argv[2])
```

Drop queries whose results are mostly off-brief. Note the words in bad titles: they become `rejectTitleWords`. Pick the best items as pins.

Write the findings, with dates, measured sizes and verdicts, into `docs/research/image-apis/`. Use a new file, or a section in [collections.md](../research/image-apis/collections.md) or [other-institutions.md](../research/image-apis/other-institutions.md). Keep raw probe data and sheets out of git.

## 2. Write the JSON entry

Add an object to `sources` in `Liminal/Visual/ImageSources/image-collections.json`. Every field:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Unique, kebab-case, usually `<provider>-<theme>`. Stored in every picture's credit and used by `-LiminalImageProvider` |
| `provider` | string | yes | A registered provider id: `loc`, `nasa`, `wikimedia`, `cma`, `met`, `dc`, `aic` (or `si` with a key) |
| `enabled` | bool | yes | `false` keeps the entry without using it |
| `weight` | number | yes | Copies in the ingest bag (`round(weight)`, at least 1) and a multiplier on display weight. Most sources are 1-3; the enabled total is 48 (2026-11-21) |
| `themes` | [string] | yes | Documentation: what the source is for |
| `mood` | object | yes | `{"moods": [...], "subjectCategory": "...", "energy": 0-1, "warmth": -1-1}`. Becomes the picture's `PromptSpec`, which `VisualMoodBuilder` sends to the music. Moods (1-4): `serene`, `eerie`, `euphoric`, `ominous`, `playful`, `majestic`, `intimate`, `electric`, `melancholy`, `lush`. Subject categories: `creature`, `plant`, `architecture`, `object`, `vehicle`, `landscape`, `food`, `instrument`, `celestial` |
| `license` | string | yes | Documentation: what the rights should be. The app always judges each item's own record |
| `collection` | string | LoC, DC | LoC collection slug (`carol-m-highsmith`); Digital Commonwealth host collection facet ("The Tichnor Brothers Collection") |
| `queries` | [string or object] | one of these three, or pins | Searches. A plain string, or `{"q": "...", "yearStart": 1965, "yearEnd": 1972}` (NASA), `{"q": "...", "type": "Print"}` (Cleveland; AIC with Painting, Photograph, Print, Drawing and Watercolor), `{"q": "...", "departmentId": 19}` (the Met) |
| `searches` | [string] | | Commons free-text searches (`filetype:bitmap` is appended) |
| `categories` | [string] | | Commons category names without `Category:` |
| `pinned` | [string or number] | | Item ids tried before any search, in random order: LoC item ids, NASA ids, Commons `File:` titles, museum object ids |
| `rejectTitleWords` | [string] | | Whole words, case-insensitive. A match rejects the item |
| `requireTitleContains` | string | | Must appear in the title or the item id (Commons file name); DOCUMERICA uses `"NARA"` |
| `requireIIIF` | bool | LoC | Default `true`: drop results without a IIIF service (they would be 1024 px) |
| `useMasters` | bool | LoC | Use the IIIF service of the scanned master when there is no derivative (D44) |
| `trimScanEdges` | bool | | Trim the film rebate of slide scans (`ScanEdgeTrimmer`), fetching at 1.35x |
| `allowClassification` | [string] | the Met | Classification allowlist; include `""` for departments that leave it empty (American Wing) |
| `allowMonochrome` | bool | | Allow monochrome pictures (mean saturation under 0.025). Use only where grey or sepia is the subject; display still caps it at one in six |
| `requiresKey` | string | | Documentation for keyed providers (`SMITHSONIAN_API_KEY`); enabled sources must not set it |

Defaults and limits that apply to every source live in `defaults`: sizes, `maxBytes`, `hostGaps`, the `openness` thresholds, `recencyWindow`, `monochromeEvery`, `unseenAhead`, `ingestInterval` and `candidateRefreshDays`. The allowed rights labels live in `licenseAllowlist`. Change those only with a decision record, because they apply to every source.

An example, `dc-tichnor-postcards`:

```json
{
  "id": "dc-tichnor-postcards",
  "provider": "dc",
  "enabled": true,
  "weight": 3,
  "themes": ["1930-45 linen postcards", "motels", "highways", "moonlit main streets", "roadside"],
  "collection": "The Tichnor Brothers Collection",
  "queries": ["motel", "highway", "night", "skyline", "desert", "route 66", "diner", "bridge", "sunset", "lake", "moonlight", "gas station"],
  "rejectTitleWords": ["Greetings", "views"],
  "license": "Boston Public Library, reuse_allowed_ssi no restrictions",
  "pinned": [],
  "allowMonochrome": false,
  "mood": { "moods": ["playful", "melancholy"], "subjectCategory": "architecture", "energy": 0.45, "warmth": 0.6 }
}
```

Guidance:

- **Pins** guarantee the best items arrive early. Searches then fill in. A pins-only source (`landsat-earth-as-art`, `shin-hanga-pinned`) is right when the category or search is mostly off-brief or risky.
- **Weights** shift the mix. Look at what the whole rotation shows, not just the new source. In D42, woodblock prints were 10 of 54 pictures shown, and a weight came down.
- **Overlap** with an existing source is fine, but it adds weight to that theme.
- If a rejected source should stay rejected, add it to the JSON's `rejected` list with the reason.

`ImageCollectionsTests.enabledSourcesAreComplete` checks every enabled source:

- its provider is keyless and has a provider block;
- the weight is above 0;
- there are 1-4 moods, energy is in 0...1 and warmth in -1...1;
- there is something to fetch;
- `requiresKey` is not set.

It also checks that only listed sources allow monochrome. If a new source sets `allowMonochrome: true`, add its id to the test's `monochrome` set (or to `locMonochrome` for Library of Congress sources) with the reason.

## 3. Add a provider (new institutions only)

1. **Write `Liminal/Visual/ImageSources/Providers/<Name>Provider.swift`.** It is a `nonisolated struct <Name>Provider: ImageProvider` with a short `id`. The file joins the target automatically (synchronized groups), so do not edit `project.pbxproj`. Model it on `DigitalCommonwealthProvider` (search plus IIIF) or `ClevelandProvider` (search plus a direct file URL).
   - `search` builds the URL with `LooseJSON.query`. It returns `CandidatePage(candidates:next:)`, where `next` is the next page number or offset as a string, nil on the last page. Return an empty page for query kinds the institution does not support.
   - Do **all parsing in static functions over `Data`** (`static func parseSearch(_ data: Data) throws -> …`, `static func candidate(_ record: [String: Any]) -> ImageCandidate?`), using the `LooseJSON` helpers. Tests call these directly.
   - Each `ImageCandidate` gets `providerID`, a stable `itemID`, title, creator, date, the rights text from the record, the page URL, and either the image URL or a `hint` (a IIIF id, for example) that `resolve` turns into one. Declare the width, height, bytes and MIME type when the record carries them, so the pre-download gate can skip files that are too small.
   - In `resolve`, look up stubs (pinned ids) when needed, read `info.json` when the size is unknown, and build the largest useful URL, near `context.targetLongSide`, without upscaling. End with `credit(for:source:context:imageURL:)`. Throw `CandidateRejected(reason:)` for rule failures. Set `fallbackURL` only for a measured server quirk.
   - Only fetch https (`ImageHTTP.secure` upgrades `http://`).
2. **Register it** in `ImageProviders.all()` in `ImageProvider.swift`. A keyed provider reads its key from the environment only and registers only when the key is set. Do not add it to `Secrets.swift`.
3. **Add a provider block** to the JSON `providers` map. The app reads `name` and `institution`; the institution goes into every credit. Also write `auth`, `search`, `image`, `notes` and `license` as documentation. All URL templates must be https, which `everyProviderURLIsHTTPS` checks.
4. **Add `hostGaps`** entries if the institution rate-limits (the Met 5 s, AIC 2 s). The default gap is 1 s.
5. **Fixtures.** Trim a live response to a few records and save it as `LiminalTests/Fixtures/ImageAPI/<id>-search.json` (and `<id>-object.json` or similar). Keep at least one record that must be rejected (wrong rights, no image) alongside good ones. Do not keep anything personal. The fixtures directory is read with `ImageAPIFixtures.data("<file>")`.
6. **Tests** (Swift Testing) go in `LiminalTests/ImageAPIModeTests.swift`:
   - In `ImageProviderParsingTests`: parse the fixture and check the ids, title, creator, rights text, image hint or URL, the declared size, the next cursor, and that bad records are dropped or carry rejectable rights. See `digitalCommonwealthKeepsTheIIIFImageAndTheReuseVerdict` and the AIC test.
   - In `ImageRightsTests`: if the institution's rights wording is new, check that it canonicalises to the intended label and that its restricted values are rejected.
   - Add the provider id to the `keyless` set in `ImageCollectionsTests.enabledSourcesAreComplete`.
   - Run the API-mode suites:

     ```sh
     xcodebuild test -scheme Liminal -destination 'platform=macOS' \
       -only-testing:LiminalTests/ImageCollectionsTests -only-testing:LiminalTests/ImageProviderParsingTests \
       -only-testing:LiminalTests/ImageRightsTests -only-testing:LiminalTests/ImageRotationTests \
       -only-testing:LiminalTests/ImageOpennessTests -only-testing:LiminalTests/CuratedImagePoolTests \
       -only-testing:LiminalTests/CuratedImageFeedTests -only-testing:LiminalTests/ImageQueueAPIModeTests \
       -only-testing:LiminalTests/ScanEdgeTrimmerTests -only-testing:LiminalTests/ImageSourceSettingsTests
     ```

7. **Build both platforms**:

   ```sh
   xcodebuild -scheme Liminal -destination 'platform=macOS' build
   xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
   ```

## 4. Verify live

API mode calls only free public APIs, so a verification run may use the network. `-LiminalImage*` flags are automation flags, which keeps Gemini off. Run one Liminal at a time, and terminate it afterwards.

1. **Run only the new source in a throwaway pool.** Launch the built macOS app with:

   ```
   -LiminalAutoPlay YES -LiminalImageSource api -LiminalImageAPIFresh YES \
   -LiminalImageProvider <source-id> -LiminalImageInterval 8 -archive.enabled YES -LiminalVideoOffline YES
   ```

   `-LiminalImageAPIFresh YES` uses an empty `CuratedImageStore-Verify` folder, which the next normal launch removes. `-LiminalImageProvider` accepts a source id or a provider id, and a comma-separated list.
2. **Stream the log** (`log stream --predicate 'subsystem == "com.saygoodnight.Liminal"'`) for five minutes or so, and check:
   - `🖼️ [API] feed: 1 sources (<source-id>)`, then `<source-id> <queryKey>: N results, M new` for the searches.
   - `API image stored: … size=… openness=… key=… license=…` with the expected licence and a size near 2528.
   - `API image rejected: … reason=…`. Tally the reasons. Many `title rejected` lines mean the reject words are too broad. Many `too small` lines mean the route is not the high-resolution one. Many `no room for the film`, `not open enough`, `text covers` or `monochrome` lines mean the source is off-brief for API mode.
   - `API image shown: … license=… url=…`, then open a few of the URLs.
   - No `backing off` loops. If there are some, look at the error (429, 5xx, `blocked`) and add a host gap or a fallback.
   - No `[Gemini]` lines.
3. **Look at the screen.** Build, terminate the old process, relaunch, and capture with `/opt/homebrew/bin/peekaboo`. Check the 3:2 framing, that the film shows through, and the credit under **Now showing** in Images & Storage.
4. **Run the whole rotation** without `-LiminalImageProvider` to see the new source in the mix, at its weight.
5. **Offline reuse.** Run again with `-LiminalImageAPIOffline YES` added: the verify pool is reused and nothing is fetched.
6. **Performance**, when the provider serves large files or the source is heavy: run `scripts/perf-run.sh --lofi --extra "-LiminalImageSource api -LiminalImageAPIFresh YES -LiminalImageProvider <id>"` and compare it with a plain `--lofi` run (D42).
7. **visionOS Simulator**, optionally: the launch line in [pipeline.md](pipeline.md#19-debug-flags-and-verification). The text and face checks do not run in the simulator.

## 5. Document it

In the same change:

- **[sources.md](sources.md):** a row in the table and a section with the provider, searches, what it shows, measured size, route, rights, weight, monochrome, pins and credit.
- **[providers.md](providers.md):** a new provider section, or new pitfalls in an existing one.
- **[`experience.md`](../experience.md#api-image-sources):** a row in the user-facing credits table, naming the institution and linking to the collection.
- **[`decisions/images.md`](../decisions/images.md):** a dated entry with what was added and the live-run numbers (stored, rejected by reason, shown).
- **The research note** from step 1, and a line in [research-history.md](research-history.md).
