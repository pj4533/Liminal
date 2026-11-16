# Archive footage: decisions

Decision log for the archive footage workstream. Plan with all numbers: `docs/plans/archive-video.md`.
Request: old (1950s-60s, mostly black and white, newsreel / trippy / odd) Internet Archive film fades into
the scene now and then, under the same effects as the picture; its sound enters later, very gently.

Status: phases 1-5 built: fetch and cache, footage in the shader on both platforms, moments, the film's
sound (A14-A19) and the "Archive Footage" settings card (A20-A22). Phase 6 (floating screen) is not built
(A23).

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

## Sound

### A14. One more static strip in the music graph, no new reverb
- What: `Liminal/Audio/ArchiveVoice.swift`: an `AVAudioPlayerNode` (wrapped as an AudioKit `Node`) ->
  HPF 220 Hz -> LPF 2.4 kHz -> LPF 2.4 kHz -> `LayerStrip` (dry -12 dB, reverb send 1.0, delay send 0.6, pan
  walk +-0.4 on a 53 s channel). Built in `GenerativeEngine.init`, added to `MixBus` with the layers' strips,
  ticked by the conductor at 10 Hz. The three filters are bypassed while nothing plays.
- Why: what is heard is the existing Zita tail and dark tape delay, so the film sits in the music's room;
  nothing is rewired at run time and nothing is ducked (music.md calm rules). AudioKit's `AudioPlayer` was
  not used: it adds a mixer and file handling for a node that only ever plays one buffer.
- Control: `MusicControl.archiveBegin(cue)`, `.archiveEnd(fade:)`, `.archiveGain(_)`, applied on the
  conductor queue like every other control; the fades are the strip's smoothstep `SoftEnv`. A cue that
  arrives while another is audible fades that one out over 0.4 s first. Engine stop fades it with the rest.

### A15. Timing: 4 s after the picture, out with the picture's fade out
- `ArchiveAudioCuePlan` (pure): begin = picture start + 4 s, fade in 12 s (shorter if the moment is), fade out
  starts with the picture's fade out and lasts min(10 s, picture fade out), so the sound is gone first. An early
  fade out (clip ran out: 4 s; footage turned off or Stop: 2 s) moves it too. Under 6 s of sound: no cue.
- Sync: the sound starts at source `segment + 4 s x rate`, where the slowed picture is at that moment. The
  service decodes it right when the moment begins (0.6-1.7 s in the logs) and sleeps until the cue time, so
  it starts on time rather than on the 2 Hz director tick.

### A16. Pre-slowed, normalised buffer instead of a VariSpeed node
- What: `ArchiveAudioDecoder` reads the segment with `AVAssetReader` as mono float at the engine rate, then
  `ArchiveAudioMath.prepare`: linear-interpolation resample by the moment's rate (0.6-0.85, so 3-9 semitones
  down like slowed tape), normalise to -26 dBFS RMS (at most +12 dB; under -60 dBFS = silent, no cue), soft
  clip at -9 dBFS, 80 ms raised-cosine edges, copied to both channels in the engine's format. Off the main
  actor; at most about 70 s (27 MB).
- Why not the plan's `VariSpeed`: one more AU in the graph running all the time, and the rate never changes
  during a moment. The plan's +-0.3 % tape wobble was dropped with it; the delay already has wow, and the
  reverb blurs the rest.
- Trim: `baseTrim` -11 dB, found with the offline render (first try gave -42.3 dBFS over the hold).

### A17. Level: "Footage audio" is proportional in amplitude
- 0 = no cue at all; 0.5 (default) = gain 1 (stem about -42 dBFS over the hold); 1 = gain 2 (+6 dB, -36 dBFS);
  0.25 = -6 dB. A change during a moment is applied at once (`archiveGain`), 0 fades it out over 2 s.

### A18. Verified offline (build 2)
- `render-music.sh` gained `ARCHIVE=<mp4>` (+ `ARCHIVE_AT/LEN/RATE/START/LEVEL`), `ONLY=archive`,
  `MUTE=archive`; `MusicRenderTests` builds a moment like the app's (picture fade 11 s in, 13 s out), decodes
  with the app's decoder and posts the cue at render time (`renderOffline(onStep:)`), writing
  `<label>.archive.json`. `scripts/analyze-archive-audio.py` reads the mix, the stem, the bypassed twin, the
  base render without the archive and the pad stem.
- Render: 300 s, seed 1, `NewsMaga1957` (a 1957 newsreel with narration and music), picture 90-165 s, sound
  94-162 s, rate 0.72. Results:
  - stem over the hold -42.0 dBFS RMS (loudest second -41.4), true peak -26.5 dBFS; pad stem -23.3 dBFS and
    whole mix -22.6 dBFS over the same window: the film is 18.7 dB under the pad, 19.4 dB under the mix.
    The mix RMS over the moment rises 0.04 dB.
  - spectrum: centroid 502 Hz, 95 % roll-off 1.1 kHz, share above 2 kHz -25 dB, above 3 kHz -44 dB, above
    5 kHz -96 dB; the loudest 50 ms above 3 kHz is -70.9 dBFS (gate -60). The mix's power above 3 kHz
    over the moment rises 0.8 dB, above 5 kHz 0.0 dB.
  - fades: 50 % at 7.5 s, 90 % at 11.8 s after the start (smoothstep of 12 s, mean deviation 0.14); out:
    -20 dB 9.2 s and -40 dB 13.8 s after the fade starts (picture fade out 13 s).
  - limiter: the bypassed twin peaks at -8.3 dBFS, and equals the limited mix within 2.6e-4 once aligned (the
    bypass removes the limiter's 480-sample look-ahead delay): idle. Mix true peak -8.3 dBFS with and without
    the archive.
  - `check-music.py --pass 2`: the same gates pass with and without the archive (55); the one failure,
    `chroma_novelty` 0.465 (max 0.45), is in both (seed 1 at 300 s). Calm metrics move by at most 0.6 dB or
    2 attacks per minute; offline render speed 7.2x -> 7.0x real time.
  - top of the slider (`ARCHIVE_LEVEL=1`): -36.0 dBFS over the hold, true peak -20.4 dBFS.
- Demo: `audio-demo.m4a`, 90 s (84-174 s of the render): music alone, the film's sound coming in from 10 s,
  holding, fading out from 68 s, tail to 78 s.

### A19. Verified in the apps
- visionOS simulator (forced, offline cache): decode 67.6 s of sound in 1650 ms (with offline renders running
  on the host) and 567 ms; "archive audio begin" 4.0 s after "moment begin"; "archive audio end fade=10.0s"
  at the picture's fade-out start. A run without host load had no slow frame across decode, sound start,
  sound end and turning footage off (36 PERF windows, 79.5 fps, 0 dropped).
- macOS: same sequence (decode 923 ms, begin 4.0 s after the picture).
- Not checkable here: how it sits in the Vision Pro's speakers; the user's ear is the final check.

## Settings

### A20. One "Archive Footage" card, the same on both platforms
- `ArchiveFootageSection` (shared): "Archive footage" toggle (on), "Footage amount" Rare / Normal / Often,
  "Footage audio" slider (Off ... Louder, 50 %), a status line ("Showing: [Reno Rodeo] (1950)", "3 clips ready",
  "Footage starts with playback", "Archive footage off"), "Clear Footage" with a confirmation (keeps the clip on
  screen), the cache line ("5 films cached, 232.5 MB") and the credit "Films: Prelinger Archives via the
  Internet Archive, public domain." Status and cache are polled every 2 s while the card is visible.
- Placement: Mac sidebar after Visuals. visionOS: under Music in the three-column layout (the Visuals column
  is already the longest), between Music and Images & Storage in two columns, after Visuals in one.
- Persisted keys `archive.enabled`, `archive.amount`, `archive.audioLevel`; "Reset All Settings" resets them.

### A21. Off means fade out, then stop
- Footage runs while playback wants it and the setting is on. Turning it off during a moment fades picture and
  sound over 2 s, then stops prefetching and decoding (the cache stays); turning it on while playing starts
  again (a new moment clock, so the first moment is 90-150 s away at Normal). The amount applies from the next
  gap. Verified with `-LiminalVideoOffAt 30`: setting off at 30.2 s, sound end fade 2.0 s, envelope 1.0 -> 0.13
  in 2 s, "footage stop" 2.5 s after the setting.

### A22. Layout checked by screenshot
- `-LiminalControlsScroll archive` scrolls to the card, `-LiminalControlsWidth <pt>` sets the visionOS window
  width (taps do not work in the Xcode 27 simulator). No truncation at 1240 (three columns), 880 (two) and 560
  (one) pt, nor in the 320 pt Mac sidebar.

### A23. Floating screen: not built
- The plan recommends building it only after the user has lived with phases 1-5 (phase 6, off by default).
  This build does not include it.

## Verification (build 1)

- Unit tests: `LiminalTests/ArchiveFootageTests.swift` (queries, URL encoding, loose decoding, filters,
  file pick, durations, segments, shuffle bag, cache policy and store round trip, director schedule over
  1000 seeds, envelope, look and clip choice, mix formula, uniform stride, tint). 114 tests pass (122 after phases 4-5).
- Simulator: real fetch (ids, titles and years in the log), offline relaunch from the cache, a 65 s
  recording across a Window moment's fade in, hold and fade out, constant-mix stills of all four looks.
- `scripts/perf-run.sh`, 30 s windows: footage off 79.1 fps, interval p95 13.32 ms, 0.17 dropped per 5 s;
  footage on (Window moment) 79.3 fps, p95 13.32 ms, 0.67 dropped per 5 s (the extra slow frames are
  the harness's own screenshot and one 20.6 ms frame at an image change, as in the off run).
- macOS: fetch and moments run with the same flags (log), footage pipeline bound only during moments.
- Recognisability with footage off: `scripts/fx-judge-set.py` (app mode, 180 frames) passes its
  objective gate at intensity 0.25, 0.5 and 1.0 (as it must: the plain fragments render bit-identical
  frames).

## Review (independent pass)

### A24. Fixes from the review
- Texture cache flushed: `VideoFrameSource` never called `CVMetalTextureCacheFlush`, so the cache could
  keep recycled IOSurface textures for the whole session. It now flushes every 30 decoded frames and on
  teardown (in-flight pre-passes keep their own `CVMetalTexture` until their completion handler).
- Eviction protects the clip on screen at add time: the protected id was read before the download started,
  which can take minutes; a moment that began meanwhile on another clip could have had its file evicted.
  `fetchOne` now reads it right before `store.add`.
- A skipped candidate is not a download: colour odds, exclusion, no playable file or a failed validation
  used to set `lastDownload` too, so the pool waited 90 s for nothing. `fetchOne` returns whether a clip
  was added.
- Stop/start race: `halt` took the task list after clearing `running`, so a `launch` in between (footage
  turned back on as the director halted) could have had its new tasks cancelled. `halt` now takes the old
  tasks first; `prefetchLoop` also stops when `running` is false.
- Cold start prefers a short first film: in the review's simulator run (empty cache) the first candidate's
  smallest file was 77 MB and that server delivered 0.34 MB/s, so the first moment came 3 min 45 s after
  Play. With an empty cache a candidate whose chosen file is over 40 MB is passed over (not marked bad), at
  most 6 times. Re-run: first clip (37.8 MB) cached 9 s after Play, first moment at 20 s.

### A25. Review evidence
- Footage off vs `main`: shader-bench parity identical (max abs diff 0 on every frame); mono GPU B/A
  1.002, 1.010, 1.004 (3 trials). So the recognisability gates are unchanged by construction.
- Simulator, 7.5 min, real fetch from an empty cache, forced moments: 4 moments (phantom, imprint, window,
  imprint), sound 4.0 s after the picture each time, decode 440-885 ms, a clip without audio handled
  ("no sound: clip has no audio track"), transitions (ripple, solarize, facets ...) every 15 s throughout.
  `perf-run.sh` 200 s window: 79.6 fps, interval p95 13.32 ms, 0 dropped per 5 s.
- macOS (sandboxed, `com.apple.security.network.client` present): downloads and moments run, 60 fps,
  GPU 3.4-4.2 ms with a Window moment at mix 0.6.
- Seen in the stills: the Window and Phantom looks read; Imprint is hard to see on busy pictures and the
  320x240 cold-start files look soft. The still picture stays recognisable in every frame.
- Not changed, for the user to judge: `medical_quacks_2` ("Confidential File: Medical Quacks") passed the
  filters (no excluded word); add `medical` to the exclusions if that kind of film is unwanted.

## Open

- Open questions 1-3 of the plan (collections, colour odds, floating screen).
- The user's ear on the sound level (default -42 dBFS, about 19 dB under the music) and the look strengths.
- Device: 90 Hz pacing with footage on, and the decode cost on the Vision Pro.
