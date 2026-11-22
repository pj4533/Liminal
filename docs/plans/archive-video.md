# Archive footage: plan

Old Internet Archive film (1950s-60s, mostly black and white) fades into the scene every few minutes,
composited with the current image inside the existing effect pipeline, with its own sound entering the
Lo-Fi music through heavy reverb and echo. Branch `feature/archive-video`.

Decisions taken while building go in `docs/decisions/archive-video.md` (prefix `A`, created in phase 1).
This plan fixes the design; numbers marked *(tune)* are starting points to be tuned by eye and ear.

## 0. What was read, and what it means

| Finding | Consequence |
|---|---|
| LostArchiveTV never searches the Archive: it ships an offline SQLite of identifiers and only calls `/metadata/{id}` and `/download/{id}/{file}`. No key is needed; the optional cookie is for restricted items. | Port its pure logic (metadata models, playable-file pick, duration parse, random start, content-failure classifier, shuffle bag). Add `advancedsearch.php` ourselves. Read no secret. |
| `advancedsearch.php` returns `sound`, `color`, `licenseurl`, `runtime`, `year`, `title` in `fl[]` (checked: 232 hits for a Prelinger newsreel/dream query). Values are inconsistent (`Sd` / `sound`, `B&W` / `C` / `color`), some fields missing. | Filter client-side, tolerant of spelling; missing `sound` = unknown, decided after the download by looking for an audio track. |
| Prelinger holds many 30-60 s newsreel items next to 8-20 min films; files are 2-70 MB h.264 at 480p, plus a `_512kb.mp4` at 240p. Range requests and redirects work. | Download whole files (small), keep them, cut random segments locally. No HTTP streaming at play time. |
| The fragment shader takes textures 0, 2, 3, 4, 5, 6; uniforms are a flat float struct mirrored in Swift, appended with defaults of 0. Transition code sits in uniform branches so it costs nothing outside a transition. | Video is texture 7 plus appended uniforms, in one uniform branch on `videoMix > 0`. |
| visionOS renders in a `@MainActor` loop that must never wait; images get a new texture built off the main actor (`SourceTextureUploader`) and the loop only swaps references. | Video frames are produced on their own queue into their own textures; the loop reads the latest one through a lock. The image path is not touched. |
| The audio graph is built once (`ArchiveMixBus`, `ArchiveStrip` with dry / reverb / delay sends) and driven from the conductor queue (`ArchiveConductor`); `renderOffline` advances the conductor in 20 ms steps. | The archive voice is one more static strip fed by a player node; buffers are scheduled at run time, the graph never changes. Offline render works unchanged. |
| The project uses file-system synchronized groups; the Mac target is sandboxed with outgoing network allowed. | New files under `Liminal/Archive/` build with no project edits. |

## 1. Fetch and cache

New folder `Liminal/Archive/`.

### 1.1 Types

- `ArchiveModels.swift`: `ArchiveSearchDoc` (identifier, title, year, sound, color, licenseurl, runtime),
  `ArchiveMetadata` / `ArchiveFile` (name, format, size, length, height), ported from LostArchiveTV.
- `ArchiveClient.swift` (`actor`): `search(query:page:rows:)`, `metadata(id:)`, `download(id:file:to:)`.
  One `URLSession` with `User-Agent: Liminal/1.0` (no personal data), `httpMaximumConnectionsPerHost = 1`,
  `allowsConstrainedNetworkAccess = false` (no downloads in Low Data Mode), 30 s request timeout. Requests are
  sequential with at least 2 s between them. HTTP 401 / 403 / 404 mark the item bad and move on.
- `ArchiveCatalog.swift` (pure): the curated queries, the exclusion filter, the file picker, duration parse,
  segment maths, shuffle bag. Fully unit-tested.
- `ArchiveClipStore.swift` (`actor`): the disk cache and its index.
- `ArchiveFootageService.swift`: owns the above plus the moment director (section 3); the only type the
  views and the render loops talk to.

### 1.2 Queries

All get `mediatype:movies AND year:[1950 TO 1969]` and the `NOT (...)` clause below. Weights pick the
query for each search; a random page inside the known hit count; `rows=50`.

| Weight | Query | Why |
|---|---|---|
| 3 | `collection:prelinger AND (newsreel OR "news magazine" OR telenews OR "screen magazine")` | old newsreels |
| 3 | `collection:prelinger AND (abstract OR experimental OR kaleidoscope OR optical OR hypnosis OR dream OR surreal)` | trippy and weird |
| 2 | `collection:prelinger AND subject:(animation OR cartoon OR "visual effects" OR psychology OR science OR future)` | odd educational film |
| 2 | `collection:prelinger AND (rocket OR satellite OR "outer space" OR computer OR electronic OR television)` | space age |
| 1 | `collection:prelinger AND color:(B&W)` | general fallback |

Only `collection:prelinger` in this build: its items carry a public-domain licence and the collection
states no restrictions on reuse. Newsreel, classic TV and feature-film collections have unverified rights
and stay out until the user decides (open question 1).

Exclusions, both in the query and again on title + description + subject after `/metadata`:
`war, bomb, casualty, casualties, surgery, operation, disease, nazi, hitler, execution, biological, venereal,
accident, crash, autopsy, "civil defense", propaganda, korea, vietnam, fallout, radiation, germ, hygiene,
birth, death, funeral, fire, riot, flicker, strobe`. Colour items are allowed only from the two "trippy"
queries at 20 % odds *(tune)*; everything else must be black and white.

### 1.3 Picking an item and a file

1. Shuffle bag over the search docs not yet in the cache or on the bad list (no repeats until exhausted).
2. `/metadata/{id}`: keep files with name `.mp4` and format `h.264`, `h.264 IA` or `512Kb MPEG4`; drop names
   ending `_edit.mp4`. Prefer the main h.264 file when it is 80 MB or less, else the `_512kb.mp4`; nothing
   over 120 MB. While fewer than 2 clips are ready, take the smallest playable file (fast first start).
3. Duration from `length` (seconds or `H:MM:SS`), must be 25 s to 25 min.
4. Download to `<store>/tmp/`, then validate off the main actor with `AVURLAsset`: a video track that
   decodes one frame, natural size at least 240 px high, the real duration. Record whether an audio track
   exists. Measure luma black / white points (5th / 95th percentile over 8 frames) and mean audio RMS
   (10 s sample) for the index. Failures are classified with the ported `isContentFailure`; a content
   failure puts the id on the bad list, a network failure only backs off.

### 1.4 Disk cache

- Location: `Application Support/Liminal/ArchiveFootage/` (next to `ImageStore`), excluded from backup.
  `index.json` holds per clip: id, title, year, file name, bytes, duration, hasAudio, levels, RMS, colour,
  licence, added, lastUsed, useCount, segments already shown.
- Size cap 1 GB, target pool 12 clips, minimum ready 3. Eviction: least recently used first, never the
  clip on screen, and never below 3 clips. No downloads when free disk space is under 2 GB.
- Prefetch: starts 10 s after Play, one download at a time, until the pool has 12. After that, one new
  clip replaces the most-used one every third moment, so the pool turns over slowly and old clips keep
  coming back ("revisit"). At most one download per 3 minutes.
- Segments: a moment asks for `duration` seconds of source. Start = LostArchiveTV's safe random start
  (margin `min(0.2 d, 60)`), re-rolled up to 4 times to stay 20 s away from segments already shown from that
  clip. Clips shorter than the request play whole and loop once with a 2 s self-crossfade.
- Offline: moments play from the cache with no requests. Empty cache = no moments, no error surface
  beyond one status line. Network errors back off 1, 2, 5, 15, 30 min.
- Bundled fallback `Liminal/Archive/archive-seeds.json`: about 150 identifiers vetted by
  `scripts/archive-curate.py` (runs the queries, applies the filters, prints titles for a human pass). Used
  when search fails or returns nothing, and as the first pick on a first launch (no search round trip).

## 2. Video into the picture

### 2.1 Decode (off the main actor)

`VideoFrameSource` (`nonisolated final class`, own serial queue, in `Liminal/Archive/`):

- `AVAssetReader` + `AVAssetReaderTrackOutput` over the segment's time range, output
  `kCVPixelFormatType_32BGRA`, Metal compatible. A local file needs no player, no clock and no audio
  session, and behaves the same in tests. (`AVPlayer` would also play the sound straight to the output,
  which must not happen.)
- Paced by the host clock at the clip's frame rate times a per-moment playback rate of 0.6-0.85 *(tune)*:
  slow motion reads as dreamlike, and the sound is slowed by the same rate (section 4).
- Each frame: `CVMetalTextureCache` wraps the pixel buffer (fallback: `texture.replace`, 1.2 MB at 480p),
  then a small pre-pass renders into the next of 3 `rgba8Unorm` stage textures at 960 x 720:
  - R = luma after the clip's levels (black / white points from the index), 6 % inset crop for film borders;
  - G = slow temporal average of R (time constant 0.5 s), for glows and the Window look;
  - B = motion, `|luma - previous luma|` smoothed, for the motion-keyed look;
  - R itself is blended with the previous frame (weight 0.4), which softens cuts and flashes
    (photosensitivity) and gives film-like smear.
  The pre-pass command buffer goes on the renderer's own `MTLCommandQueue`, so a stage texture is never
  written before an earlier render that samples it has run. Cost: one 960 x 720 pass 24-30 times a second.
- `latest()` returns the newest finished stage texture under an `OSAllocatedUnfairLock`; that is all the
  render loop ever calls. Decode stalls just hold the last frame.

### 2.2 Shader

`EffectsUniforms` (Swift and Metal, appended last, all default 0):

```
videoMix      0...1   envelope x look ceiling; 0 = the whole stage is skipped
videoLook     1...4   look id
videoSeed     0...1   placement, drift direction, mask shape
videoScale            footage size relative to the frame
videoAspect           x scale for a 4:3 frame on the 3:2 picture (cover fit)
videoTintR/G/B        highlight colour, from the image's dominant colours
videoShadeR/G/B       shadow colour for the duotone looks
```

`texture2d<half> videoTexture [[texture(7)]]` on `effectsFragment` and `effectsFragmentStereo`, passed
to `shadeEye`. With no video the renderers bind the existing 1 x 1 black texture and `videoMix` is 0.

The composite sits right after the crossfade and before the hue shift, inside
`if (uniforms.videoMix > 0.0)`. So everything downstream (hue waves, fractal hue, contrast, ghost taps'
host colour, feedback trails, vibrance) acts on picture and footage together, and the footage is sampled at
the already warped, parallax-shifted `uv`: it swims with the water, bends with the transitions and sits on
the depth relief of the shell. One video sample per eye; no rectangle is ever visible because every look
feathers the footage by a mask ordered by the flow field already in `WarpOut`.

Four looks, one per appearance:

| # | Look | What it does | Ceiling at intensity 0 / 0.5 / 1 |
|---|---|---|---|
| 1 | Phantom | Screen blend of the footage highlights, tinted with the image's brightest dominant colour and weighted by the motion channel: only what moves and glows shows, like a projection on smoke. 70 % of the frame, drifting. | 0.35 / 0.60 / 0.80 |
| 2 | Imprint | Soft-light: the footage's luma shades the picture's own colours. The picture stays, the film lives inside it. Full frame. | 0.40 / 0.70 / 0.90 |
| 3 | Window | A soft, flow-edged region (45-60 % of the frame, near the centre, slowly breathing) where the footage replaces the picture as a duotone from the image's darkest to brightest dominant colour. | 0.50 / 0.75 / 0.90 |
| 4 | Emerge | The footage takes over the whole frame as a duotone; the picture stays as 25 % colour and in the trails. Only at intensity 0.4 and above, at most 20 s at its peak. | 0 / 0.65 / 0.85 |

Weights *(tune)*: Phantom 3, Imprint 3, Window 3, Emerge 1; never the same look twice in a row.

- Tint: black and white has no hue for the hue stages to rotate, so colour comes from the tint uniforms
  (dominant colours in `ImageMetadata`, eased over 3 s when the image changes). The hue stages then move
  that colour with the rest of the frame.
- Effect intensity and the clarity cycle: `videoMix = envelope x ceiling(intensity) x (0.75 + 0.25 drive)
  x (0.55 + 0.45 fresh)`. A new image arriving during a moment pulls the footage back while it is fresh.
- `VideoComposite.swift` (pure): look ceilings, tint choice, the mix formula. `EffectsUniformsComputer.compute`
  gains `video: VideoCompositeState = .off`; with `.off` it writes zeros and nothing else changes.

### 2.3 Renderers

- visionOS `OffscreenEffectsRenderer`: `renderAndPresent` / `renderStereoAndPresent` take an optional
  `videoTexture`; bind at index 7 beside the others. Nothing in `bindImageTextures`, `SourceTextureUploader`
  or the prepared-image path changes.
- macOS `EffectsMetalView`: a `videoTexture` property set from the representable; same binding.
- Cost budget: video off, at most 1 % slower than `main` on shader-bench (hard limit 5 %); video on, at
  most 8 % slower and no missed frames at 90 Hz. The video runs at its own 15-25 fps under the 90 Hz loop.

## 3. Video moments

`VideoMomentDirector` (pure, seeded, in `Liminal/Archive/`), ticked twice a second by the service; it
publishes a `MomentPlan` (clip, segment, look, seed, start, fade in, hold, fade out, rate). The render loop
evaluates `plan.envelope(now)` each frame: no scheduling work on the main actor.

| | Rare | Normal (default) | Often |
|---|---|---|---|
| First moment after Play | 150-240 s | 90-150 s | 60-90 s |
| Gap between moments | 5-9 min | 2.5-6 min | 1-2.5 min |

- Never in the first 60 s. Length 30-80 s in total; fade in 8-14 s, fade out 10-16 s (smoothstep).
- Start waits (up to 30 s) until no image transition is running and the image is at least 8 s old; if the
  music's intensity is above 0.8 it waits up to 30 s more. A moment is never cut short by an image change:
  the picture changes underneath the footage.
- Fade out begins early if the clip runs out. Stop or leaving the space fades out in 2 s.
- When a moment starts and ends the service posts to the music (section 4).
- DEBUG flags in `DebugLaunchOptions`: `-LiminalVideoForce YES` (first moment at 5 s, 10 s gaps),
  `-LiminalVideoLook phantom|imprint|window|emerge`, `-LiminalVideoFile <mp4>` (local file, no network),
  `-LiminalVideoMix <0...1>` (constant mix, for frozen-time stills), `-LiminalVideoSeed <n>`,
  `-LiminalVideoOffline YES` (no requests), `-LiminalVideoOff YES`. The automation flags do not block the archive.

## 4. Audio

`Liminal/Audio/ArchiveVoice.swift`, built in `GenerativeEngine.init` with the other audio nodes:

```
AudioPlayer (buffer) -> VariSpeed -> HPF 220 Hz -> LPF 2.4 kHz -> LPF 2.4 kHz -> ArchiveStrip
ArchiveStrip: dry fader -12 dB, reverb send 1.0, delay send 0.6, slow pan walk +-0.4
```

- Mostly wet: what is heard is the Zita tail (8 s) and the dark tape delay of the `ArchiveMixBus`, so the
  voice shares the room of the music. No new reverb, no ducking of anything.
- Source: `ArchiveAudioDecoder` reads the segment's audio track with `AVAssetReader` into one
  `AVAudioPCMBuffer` in the engine's format, off the main actor (at most 80 s). Gain normalises the
  segment's RMS to -26 dBFS (at most +12 dB), peaks soft-clipped at -9 dBFS before the filters.
- Rate: `VariSpeed` at the video's playback rate (0.6-0.85), so the sound drops 3-9 semitones like slowed
  tape and stays loosely in step with the picture (started within 50 ms; nothing tighter is audible through
  the reverb). Tape wobble +-0.3 % at 0.4 Hz from the conductor's 10 Hz modulation.
- Level: stem mean RMS -42 dBFS at the default setting (the music's mean is about -25), ceiling -36 dBFS at
  the top of the slider, stem peak at or below -24 dBFS. Fade in 12 s, starting 4 s after the picture
  starts to appear; fade out 10 s, finishing before the picture is gone. The reverb tail outlasts it.
- Control: `ArchiveControl.begin(cue)` and `.end(fade:)`, applied by `ArchiveConductor` to `ArchiveVoice`.
  Silent clips and "Footage audio" at 0 simply never post.
- Works the same on macOS and visionOS (plain AVAudioEngine nodes, the existing audio session).

## 5. Optional 3D: a floating screen on visionOS

Recommendation: **do not ship it in the default experience; build it last, behind a setting that is off.**

- The blended layer already lives on the depth-relief shell, so the footage is spatial without a new
  object, and the spatial plan removed separate modes for a reason.
- A screen that floats and turns is a second focus point, and the user's own doubt was "maybe that's too
  distracting". It also needs a second drawable queue and material.
- Design if built (phase 6): a gently curved 1.4 m wide panel 2.5 m away, 15 degrees off centre, drifting
  on a slow figure of eight and turning at most +-12 degrees, edges feathered to nothing, fed by a 960 x 720
  drawable rendered from the stage texture with tint and a light warp. It appears only during a moment
  and takes the Window look's slot. Setting: "Floating screen (experimental)", off.

## 6. Settings and UI

`SettingsService` (persisted, reset by "Reset to defaults"):

| Setting | Key | Default | Control |
|---|---|---|---|
| Archive footage | `archive.enabled` | on | `ExplainedToggle`: "Old film from the Internet Archive fades into the scene" |
| Footage amount | `archive.amount` | Normal | segmented Rare / Normal / Often |
| Footage audio | `archive.audioLevel` | 0.5 | `ValueSlider`, 0 = silent |

- A new `ControlSection(title: "Archive Footage", systemImage: "film")` on both platforms: under Visuals
  in the visionOS third column, and in the Mac sidebar. It also shows the cache size with a
  "Clear footage" button, a status line ("3 clips ready", "Offline: 5 cached clips", "Showing: Logic by
  Machine (1962)") and the credit "Films: Prelinger Archives via the Internet Archive, public domain".
- Layout checked at the three visionOS widths and the Mac sidebar width for truncation.
- Turning the toggle off fades out a running moment (2 s) and stops prefetching; the cache stays.

## 7. Verification

| What | How | Pass |
|---|---|---|
| Pure logic | `LiminalTests/ArchiveCatalogTests`, `ArchiveClipStoreTests`, `VideoMomentDirectorTests`, `VideoCompositeTests`: file pick, duration parse, segment maths, exclusion filter, shuffle bag, search decoding from a saved JSON, LRU and cap, schedule bounds over 1000 seeds, mix formula, uniform struct stride | all pass with the existing 84 |
| Effects unchanged with video off | `scripts/shader-bench.sh --out` on `main` and on the branch, `--compare` | max abs diff at most 1 / 255 |
| GPU cost | `scripts/shader-bench.sh --shader-b` A/B against `main`, video off and on | off within 1 % (limit 5 %); on within 8 % |
| Composite frames | shader-bench gains `--video FRAME.png` and the video uniforms in `--set`; render each look at intensity 0 / 0.5 / 1 over 3 fixture images | reviewed by eye; no hard edge; picture still readable in looks 1-3 |
| Recognisability | `scripts/fx-judge-set.py` with video off | gates as on `main` |
| Fetch and cache | Mac and simulator launch with the automation flags; poll the log for `📼` lines | 3 clips ready within 3 minutes; relaunch with `-LiminalVideoOffline YES` plays from the cache with no request |
| Moments in the simulator | `-LiminalVideoForce YES`, `simctl recordVideo` 90 s and screenshots at fade in, peak, fade out, for each `-LiminalVideoLook` | footage visible, fades smooth, no rectangle |
| Frame pacing | `scripts/perf-run.sh` with and without `-LiminalVideoForce` | no new long frames; the image-change hitch check unchanged |
| Audio | an offline render of 180 s with and without the film, same seed (today `scripts/mix-report.sh`, whose `footage` stem is the film bed) | stem RMS -45...-39 dBFS, stem peak at most -24 dBFS, nothing above 3 kHz over -60 dBFS, fade in at least 8 s to 90 %, mix true peak unchanged within 0.5 dB |
| Fixtures | `scripts/archive-fetch-fixture.sh` downloads one known public-domain Prelinger clip into the scratchpad (one request, cached); one 640 x 480 frame is committed as `tools/ShaderBench/fixtures/video-01.png` | no video binary in the repository |

Not checkable without the device: 90 Hz pacing on Vision Pro hardware and how the levels sit in the
headset's speakers. Both are flagged for the user's device pass.

## 8. Phases

Each phase builds on macOS, the visionOS simulator and the visionOS device target, passes the unit tests
and leaves the app behaving as before when the feature is off.

1. **Archive client and cache.** `ArchiveModels`, `ArchiveClient`, `ArchiveCatalog`, `ArchiveClipStore`,
   `ArchiveFootageService` (prefetch only), `archive-seeds.json`, `scripts/archive-curate.py`, the debug
   flags for the network, tests. *Accept:* tests pass; 3 clips ready within 3 minutes on both platforms;
   offline relaunch reports the cached clips with zero requests; cap and eviction shown by a test.
2. **Footage in the shader.** `VideoFrameSource`, the stage pre-pass, the uniforms, the four looks,
   texture 7 in both renderers, `VideoComposite`, shader-bench `--video`, `-LiminalVideoFile` and
   `-LiminalVideoMix`. *Accept:* video-off parity and cost; frames of each look; a constant-mix run in the
   simulator shows moving footage on the shell with no long frames.
3. **Moments.** `VideoMomentDirector`, `MomentPlan`, the envelopes, look choice, the waits around
   transitions and loud music, `-LiminalVideoForce` and `-LiminalVideoLook`, tests. *Accept:* schedule
   tests; a recorded forced run shows fade in, hold and fade out for each look; nothing in the first 60 s
   of a normal run.
4. **Audio.** `ArchiveVoice`, `ArchiveAudioDecoder`, the `ArchiveControl` begin and end cases and the
   offline render option. *Accept:* the audio row of section 7; a forced run on the
   Mac is audibly gentle (the user's ear is the final check).
5. **Settings, credit, documents, final check.** The settings and the section on both platforms, the
   status line, clear button, `docs/decisions/archive-video.md` complete, README and architecture notes
   updated, the whole of section 7 run again. *Accept:* no truncation at any width; toggling off fades out
   within 2 s; all checks pass; `git status` clean.
6. **Floating screen (optional, off by default).** Only after the user has seen phases 1-5.

## 9. Open questions for the user

1. Collections: this build uses only the Prelinger Archives (public domain). Wider newsreel and classic TV
   collections fit the brief but their rights are unverified. Add them?
2. Colour footage: allowed at low odds from the "trippy" queries, shown as a duotone like the rest. Keep it
   strictly black and white instead?
3. The floating screen: build it now as an experiment, or after living with the blended layer?

## 10. Risks

- Content: keyword filters cannot see inside a film. The vetted seed list, the Prelinger-only scope and the
  exclusion list lower the odds; a "Skip this clip" control (which also bans the id) is a cheap addition if
  something unwanted shows up.
- Flashing: frame blending, the mix ceilings and the banned terms reduce it; a hard limiter on frame-to-frame
  luma change in the pre-pass is the next step if a clip still strobes.
- `CVMetalTextureCache` in the visionOS simulator: if unsupported, the byte-copy fallback is used (logged).
- Data use: about 0.5 GB for the first full pool, then roughly 40 MB every third moment; none in Low Data
  Mode.
