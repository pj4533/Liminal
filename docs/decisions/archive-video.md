# Archive footage: decisions

Decision log for the archive footage workstream. Plan with all numbers: `docs/plans/archive-video.md`.
Request: old (1950s-60s, mostly black and white, newsreel / trippy / odd) Internet Archive film fades into
the scene now and then, under the same effects as the picture; its sound enters later, very gently.

Status: phases 1-3 built (fetch and cache, footage in the shader on both platforms, moments). Audio
(phase 4) and the settings section (phase 5) are not built yet; until then footage is on by default and
`-LiminalVideoOff YES` turns it off.

## Fetch and cache

### A1. Prelinger Archives only
- What: every query is `collection:prelinger`, years 1950-1969, `mediatype:movies`.
- Why: Prelinger items carry a public-domain licence and the collection states no restriction on reuse.
  Newsreel and classic-TV collections fit the brief, but their rights are unverified (open question 1).

### A2. Filter client-side, tolerant of spelling
- What: the query also excludes terms, and `ArchiveCatalog.accept` checks the year, the title (whole-word
  exclusion match) and the colour field again; `/metadata` is checked again on title + description + subject.
- Why: field values are inconsistent (`B&W`, `b&w`, `b/w`, `B&W (tinted)`, `C`, `color`, `Color`; years as
  number, string or list) and some are missing. `LooseString` decodes all of them.
- Found while curating: the unquoted `color:(B&W)` makes the search backend fail (`[BACKEND_ERROR]`);
  the query uses `color:"B&W"`.
- The exclusion list grew after the first curation pass, which surfaced politics, crime and bodies
  (`murder, kidnapping, revolt, strike, hospital, mental, police, crime, protest, ammunition, atom(ic),
  nuclear, gun, prison, drug, narcotic, alcohol, puberty, adolescence, sex, larynx, campaign, debate,
  nixon(s), eisenhower, kennedy, candidacy, "miss america", "dew line", turmoil`, and two names).

### A3. A bundled seed list of 164 items
- What: `Liminal/Archive/archive-seeds.json`, made by `scripts/archive-curate.py` (5 searches, 2 s apart;
  `--from-raw` re-filters saved responses without new requests). Used on a first launch (no search round
  trip before the first clip) and whenever search fails.
- Colour items are in the list (from the two queries that allow colour); the 20 % colour odds apply at
  pick time, as for search results.

### A4. Pool: three fast, then slowly to twelve, then turnover
- What: downloads back to back (the client still waits 2 s between requests) until 3 clips are ready;
  then one per 90 s up to 12; when full, one clip is replaced every third moment, at most one download
  per 3 minutes. 1 GB cap, least recently used evicted first, never the clip on screen, and the pool
  (counting the incoming clip) never drops below 3.
- Measured: 3 clips ready 40 s after Play in the simulator (51.3, 71.9 and 6.3 MB); on the Mac the third
  clip was cached 29 s after the first.
- While fewer than 2 clips are ready the smallest acceptable file is taken. That is often the 320x240
  `_512kb.mp4`, which looks soft; it is kept because the first moment should not wait for 80 MB.

### A5. Polite client
- `URLSession` with `User-Agent: Liminal/1.0` (no personal data), one connection per host, no requests
  in Low Data Mode (`allowsConstrainedNetworkAccess = false`), requests serialised by the actor with at
  least 2 s between them, no URL cache. HTTP 401/403/404/410/451 (and an empty or dark `/metadata`
  answer) put the item on the persistent bad list; network errors back off 1, 2, 5, 15, 30 minutes.
- No key and no secret: LostArchiveTV never needed one for public items.

## Footage into the picture

### A6. Decode with AVAssetReader on its own queue, pre-pass on its own command queue
- What: `VideoFrameSource` reads the segment with `AVAssetReader` (BGRA, Metal compatible), paced by the
  host clock times the moment's rate (0.6-0.85), wraps each frame with `CVMetalTextureCache` and runs the
  `videoPrepass` compute kernel into the next of three 960x720 stage textures (r = levelled luma blended
  with the previous frame, g = slow average, b = motion). `latest()` is one lock read.
- Why its own command queue (the plan said the renderer's): a stage texture is published only from the
  pre-pass completion handler and rewritten at the earliest two video frames later (more than 80 ms),
  longer than any render that samples it stays in flight (3 x 11 ms). Sharing the renderer's queue would
  have tied the decoder to one renderer and to the main actor.
- `CVMetalTextureCache` works in the visionOS 27.2 simulator (no fallback warning in any run); the
  byte-copy fallback stays for safety.
- Levels: 5th/95th luma percentiles over 8 frames, measured once at download (`ArchiveClipValidator`).

### A7. Separate footage fragment variants, used only while footage shows
- What: `shadeEye` is a template on `kVideo`. `effectsFragment` / `effectsFragmentStereo` instantiate it
  without footage; `effectsFragmentVideo` / `effectsFragmentStereoVideo` add texture 7 and the composite.
  Both renderers switch to the footage pipeline only on frames with `videoMix > 0` and a stage texture.
- Why: the obvious single shader with an inlined `if (videoMix > 0)` branch changed the compiler's
  fast-math code for the left eye even with footage off (max abs diff 5/255 on 0.8 % of pixels, parity
  rule is 1/255). A `noinline` composite restored exact parity but cost 26 % with footage on (a real
  call on the GPU). The template keeps the plain fragments byte-for-byte the shader without footage.
- Measured (Apple M4, shader-bench, 2048², 5 trials, interleaved A/B):
  - footage off vs `main`: parity `identical` (max abs diff 0 on all 10 frames); GPU B/A per trial
    0.998, 1.006, 1.000, 1.010, 1.000.
  - footage on (window look) vs `main` without footage: mono (the app's path) B/A 1.047-1.067; MRT
    stereo (the A/B harness path) 1.11-1.12.

### A8. The footage rides 60 % of the picture's warp
- What: the composite samples the footage at `mix(texCoord, warpedUV, 0.6)`, plus a slow drift.
- Why: at the full warp the film was unreadable in wild stretches; at 60 % it still swims with the water
  and transitions but faces and titles stay legible (sim stills: the "NEWS MAGAZINE of the SCREEN" title
  card reads in all four looks).

### A9. Look tuning, round 0
- Film contrast `smoothstep(0.03, 0.97, luma)` before every look.
- Phantom: highlights from luma 0.18, 55 % weight without motion, oval radius 0.32-0.66.
- Imprint: soft-light strength 2.2 (1.6 was invisible on the bench).
- Window: radius 0.40 +- 0.04 (aspect-correct units), soft edge 0.18 inside / 0.05 outside.
- Emerge unchanged from the plan (0 at intensity 0, at most 20 s at peak).
- Ceilings as the plan. Still a first pass: the user's eye decides.

### A10. Tint from the picture, measured off the main actor
- The render loops pass the current picture (macOS: its identity, the CGImage is made only on change);
  the service measures a 16x16 thumbnail in a detached task (brightest and darkest fifth) and eases
  toward it with a 1 s time constant. No image metadata needed, so it also works with test images.

### A11. Mix terms
- `videoMix = envelope x ceiling(look, intensity) x (0.75 + 0.25 drive) x (0.55 + 0.45 settled)`, where
  `settled` is 0 during a crossfade and rises to 1 over the 6 s after it. With a 15 s test interval the
  mix therefore dips to about 0.3 at every image change (visible in the logs); at the default interval
  it is mostly at its ceiling.

## Moments

### A12. Director on the playback clock, ticked at 2 Hz off the main actor
- `VideoMomentDirector` is pure and seeded; the service ticks it in a detached task with the conditions
  the render loops report (transition running, image age, music energy, intensity; about 2 Hz, one lock
  write). Times are seconds since Play on the host clock, not effect time: `-LiminalFreezeTime` pins the
  effects but footage still plays.
- Tested over 1000 seeds: first moment 90-150 s, never before 60 s, length 30-80 s, fades 8-14 / 10-16 s,
  gaps 2.5-6 min, no look twice in a row, Emerge never at intensity < 0.4 and at most 20 s at peak, waits
  for a transition and an image at least 8 s old (at most 30 s) and for loud music (at most 60 s).
- A short clip shortens the moment; a clip that runs out fades out over 4 s.

### A13. Debug flags
- `-LiminalVideoForce YES` (alias `-LiminalVideoNow`): first moment at 5 s, 10 s gaps.
- `-LiminalVideoLook phantom|imprint|window|emerge`, `-LiminalVideoSeed <n>`.
- `-LiminalVideoFile <mp4>` (alias `-LiminalVideoClip`): a local clip, no network.
- `-LiminalVideoMix <0...1>`: one long moment at a constant mix from 2 s (stills).
- `-LiminalVideoOffline YES`: cache only, no requests. `-LiminalVideoOff YES`: no footage at all.
- All of them count as automation flags (they block image generation). The other automation flags do not
  block the archive.
- `scripts/perf-run.sh --extra "<args>"` passes extra launch arguments.

## Verification (build 1)

- Unit tests: `LiminalTests/ArchiveFootageTests.swift` (queries, URL encoding, loose decoding, filters,
  file pick, durations, segments, shuffle bag, cache policy and store round trip, director schedule over
  1000 seeds, envelope, look and clip choice, mix formula, uniform stride, tint). 114 tests pass.
- Simulator: real fetch (ids, titles and years in the log), offline relaunch from the cache, a 65 s
  recording across a Window moment's fade in, hold and fade out, constant-mix stills of all four looks.
- `scripts/perf-run.sh`, 30 s windows: footage off 79.1 fps, interval p95 13.32 ms, 0.17 dropped per 5 s;
  footage on (Window moment) 79.3 fps, p95 13.32 ms, 0.67 dropped per 5 s (the extra slow frames are
  the harness's own screenshot and one 20.6 ms frame at an image change, as in the off run).
- macOS: fetch and moments run with the same flags (log), footage pipeline bound only during moments.
- Recognisability with footage off: `scripts/fx-judge-set.py` (app mode, 180 frames) passes its
  objective gate at intensity 0.25, 0.5 and 1.0 (as it must: the plain fragments render bit-identical
  frames).

## Open

- Audio (phase 4) and the settings section, status line and credit (phase 5).
- Open questions 1-3 of the plan (collections, colour odds, floating screen).
- Device: 90 Hz pacing with footage on, and the decode cost on the Vision Pro.
