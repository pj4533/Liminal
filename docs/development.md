# Development reference

[← Project overview](../README.md) · [Documentation index](README.md)

## Lo-Fi checks

Run the macOS score, transport, DSP, and archive timing tests with an explicit destination.

```sh
xcodebuild test -scheme Liminal -destination 'platform=macOS' \
  -only-testing:LiminalTests/LofiTests \
  -only-testing:LiminalTests/LofiCompositionTests \
  -only-testing:LiminalTests/LofiGuitarPhrasingTests \
  -only-testing:LiminalTests/LofiProductionTests \
  -only-testing:LiminalTests/ArchiveVoiceRenderTests \
  -only-testing:LiminalTests/DialogueClipGainTests \
  -only-testing:LiminalTests/ArchiveCachePolicyTests
```

For dialogue chop work run the `Dialogue*` suites. `DialogueHookProbeTests` prints each loop's trigger grid (row = bar, column = sixteenth, cell = fragment id), the hook metrics of `LiminalTests/DialogueHookMetrics.swift` and the ranked lines; xcodebuild does not echo the test host's output, so read it from the result bundle with `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>` (D125).

For guitar programs, `LofiStrumProbeTests` renders eight phrases per guitar program (72 BPM, 48 kHz, the program forced by the audition) against eight Steinway Grand phrases and prints integrated level, loudest 400 ms and 2-5 kHz share (`STRUM-PROBE` lines). It is skipped unless the test runner sees `LIMINAL_STRUM_PROBE`: pass `TEST_RUNNER_LIMINAL_STRUM_PROBE=1` to `xcodebuild test`, then read the attachment as above (D128). Its `hookDistribution` test prints the strummed hook's distribution over seeds 0..<48 (events, strings, sites, archetypes, share of bars). For strum work also run `LofiStrumTests` (the hook's score contract S1-S12 in three drum conditions) and `LofiAuditionTests`, and check captures with `scripts/strum-report.py` against a `--hook strumHook=off` twin.

For bass, chords or mix work add the suites that pin the bass line and voice, the pad, the stem chains and the render (`docs/plans/bass-and-pads.md` 5.1):

```sh
  -only-testing:LiminalTests/LofiRhythmTests -only-testing:LiminalTests/LofiArrangementTests \
  -only-testing:LiminalTests/LofiStemChainTests -only-testing:LiminalTests/LofiBassLineTests \
  -only-testing:LiminalTests/LofiBassVoiceTests -only-testing:LiminalTests/LofiPadTests \
  -only-testing:LiminalTests/LofiMixRenderTests -only-testing:LiminalTests/LofiLiveBusTests \
  -only-testing:LiminalTests/LofiCaptureHooksTests
```

`LofiStemChainTests.preparationStaysInsideItsBudget` holds a Debug phrase render under 1.5 s. Per-sample loops on the render path are `while` loops: in a Debug build a `for` loop over a range goes through the generic iterator and Swift's runtime metadata on every step, which cost the merged bass and pad render about a quarter of its time (D118).

Tests that assert on elapsed wall-clock time (deadlines, render budgets) carry the `.responsivePool` trait from `LiminalTests/ResponsivePoolTrait.swift`. Swift Testing starts every test at once, and the synchronous render tests can occupy every thread of the concurrency pool for seconds, which makes a `Task.sleep` or deadline wakeup in another test return late. The trait runs timed tests one at a time and starts each only after short sleeps return on time again. Add it to any new test that measures time, rather than widening its limit or turning parallel testing off.

Tests that hold synchronous code to a time budget (the dialogue stages, phrase and take preparation, the master kernel) measure it with `ForegroundTiming.measure` from `LiminalTests/ForegroundTiming.swift` and assert on `Cost.seconds`. A wall clock on a pool thread measures the machine in the parallel suite: on 19 November 2026 the dialogue stages read 212 ms alone and 570-680 ms beside the render suites, and CPU time alone still read 381-476 ms because the code also runs about 2.5 times slower there (efficiency cores, shared caches). The helper runs the work on its own user-interactive thread, reads that thread's CPU time, and divides it by how much slower than its idle reference (158 ms in a Debug build on this machine) a fixed calibration workload ran straight before and after. In the full suite the same stages then read 152-191 ms. The correction leans generous under load by up to about 30 %, so check a budget's real margin in an isolated run. Every measurement is written to the unified log: `log show --last 30m --predicate 'subsystem == "com.saygoodnight.Liminal.tests"'`.

Two more rules for tests in the parallel suite. AVAudioEngine delivers tap buffers on its own thread, also in manual rendering, in 0.1 s buffers a few render calls behind; wait for the taps to catch up while the engine still renders before removing them (`LofiLiveBusTests.render` renders 0.5 s of slack and waits there), or the end of the capture reads low under load. And a main-actor test that waits for other main-actor work should count polls, not wall-clock seconds, because another main-actor test can hold the actor for tens of seconds.

Run `scripts/check-lofi.sh` with FFmpeg and Python 3 installed for a headless, reproducible 16-bar capture. It writes float stereo WAVs, the exact score and clock, and independent LUFS, true-peak, routing, and energy metrics outside the repository. The default cue is a repeatable test signal. `--no-footage` exercises silence routing, `--footage /path/to/clip.mov` uses a local soundtrack, `--cached-footage` uses an audio-bearing clip from the app cache, and `--private-drums` requires an installed drum pack and keeps its captures local. Use `--drum-name` with the filename stem to reproduce an exact private take. `--block`, `--bpm`, `--scale Dorian` and `--seed` vary a run. Use `--bars 32` for the full form or `--bars 64` for a longer instrument audit. `python3 scripts/measure-lofi-instruments.py /path/to/capture` reports the strongest 400 ms of each instrument, its wet return and their combined level, with the combined sample peak. With private drums, add `--next-drum-name` to audition a different take at the sixteen-bar downbeat and hear the footage cue through each fill. Add up to 16 beats of postroll after a complete take to measure its tail. The capture uses the live conductor’s footage gain and room settings and holds adaptive master trim at nominal for repeatability. The checker verifies both music-stem and pre-master sums and defaults to a −1.5 dBTP ceiling. Debug runs can use `--limiter apple-peak-limiter` for an isolated reference, or a fully qualified provider identity from the AU probe. The live app uses its built-in master. `python3 scripts/analyze-lofi.py --self-test` checks that the analyzer rejects known failures. `--ebu-subset` runs 17 synthetic cases from EBU Tech 3341 and 3342.

For a dialogue audition, use `--film-reel --bars 32` to change to another locally cached soundtrack every eight bars. Listen to `master.wav` for the mix, `film-soundtrack.wav` for the continuous film after its level automation, or `dialogue-chops.wav` for the post-fader drops with effects on the music bus. The echo and room can be auditioned together before the cue fader in `dialogue-fx.wav`. The full treated film bed, including its echo and room, is in `footage.wav`. The manifest records the film titles and offsets, source frame ranges, scheduled hit frames, playback speeds and reversed pickups. Add `--private-drums` to hear the local takes. For dialogue leveling, compare each hit against the backing during that hit and check the loudest syllables separately. Liminal uses 50 ms windows alongside a moving window of up to 400 ms; the latter corresponds to the momentary timescale in the [EBU loudness guidance](https://tech.ebu.ch/loudness/).

Add `--transcribe` (the same as `--hook transcription=apple`) to build each cue's dialogue bank with an on-device Apple transcript, so word-piece chops align to recognized words. Before the render starts, the test transcribes each distinct cue source with the installed `en-US` SpeechTranscriber model, without the live 8 s deadline. It never downloads the model. If the model is not installed or the framework is unavailable, the capture continues on the acoustic plan. `manifest.dialogueTranscripts[]` records, for each cue, the model status, recognized words and text, any error, whether the plan used the transcript (`transcriptUsed`), and the text of each bank line, with the anchor line marked (`anchorText`, `lines[]`). Without the flag the capture is unchanged and the manifest has no such key. To install the model, set Dialogue understanding to "Allow download" in the app.

Use `python3 scripts/plot-lofi.py /path/to/capture --auditions` with NumPy, SciPy, and Matplotlib for three spectrogram resolutions, an overlay of planned rests and measured levels, reconstructed peaks at 4×, 8×, and 16×, and copies for listening near −20, −18, and −16 LUFS within headroom. Its JSON and NPZ files retain the energy and spectral measurements. For a paired comparison, add `--against /path/to/reference --comparison-out /path/to/new/directory` and optionally `--candidate-lag-frames <measured>` to override the graph's reported latency. It checks that both captures used the same score and sources, preserves the originals, and writes matched audio and difference plots. These signals expose overlap and decay. Listening still determines whether the speech or music has enough room.

Start with `-LiminalAutoPlay YES -LiminalVideoOffline YES -LiminalImageAPIOffline YES` for a cached-footage smoke test. The audio log reports instrument choices, 16-bar take starts, and any preparation misses. `-LiminalTraceLofi YES` also prints exact take sample ranges for a Debug launch. Add `-LiminalProbeLofiProviders YES` to a native Debug launch to log whether the host can discover Pro-C 2, Pro-L 2, and Animoog Z metadata. The probe does not instantiate or route audio to an extension. Physical headset listening and sustained profiling have their own acceptance checks in the [research notes](research/lofi-studio.md).

### Mix verification

Two commands capture Lo-Fi audio offline and measure it. Both need FFmpeg, Python 3 with NumPy, SciPy and Matplotlib, and the private drums for `--private-drums`. Set `DD` to a derived data path of your own, and write captures outside the repository.

```sh
# One capture, then the full report (JSON, Markdown, PNGs, audition files)
DD=$S/dd-name scripts/mix-report.sh --out DIR [--baseline DIR] [--strict] [--no-plots] [--case NAME] \
    [check-lofi.sh options: --private-drums --film-reel --bars 32 --seed 1042 --bpm 70 --hook k=v ...]
    (--hook bassTone=round|upright|synth pins one bass tone for the whole capture; without it the tone rotates every 16 bars, D120)
    (--hook guitarProgram=nylonstrum, pluckProgram=concertharp and guitarSlot=1|2 force the take's guitar or
     plucked-string program and the guitar's middle phrase for A/B captures; strumHook=off turns off the strummed hook, D128)

# The five-case matrix (ref, long, fast, same, nofilm), run one after another
DD=$S/dd-name scripts/mix-matrix.sh --out DIR [--baseline DIR] [--cases ref,long,fast,same,nofilm] [--strict] [--prune-wavs]

# Guitar and harp strum measures of one capture, against a before and a hook-off capture (D128)
python3 scripts/strum-report.py DIR [--baseline DIR] [--off DIR] [--json OUT]
```

`python3 scripts/mix-report.py CAPTURE_DIR` re-measures an existing capture without capturing again.

A report holds per-bus stems (drums, bass, lead, mids, space, dialogue chops, film bed, the Lo-Fi bus, pre-master and master), spectrograms at three resolutions, a band-energy and masking matrix between buses, low-band mono correlation, kick and bass window analysis, crest and PLR, integrated and short-term LUFS, true peak (FFmpeg and a 16x reconstruction), limiter and glue gain reduction from the master kernel's trace, dialogue intelligibility proxies, and the chop-change cadence from the plan log. The matrix adds `matrix-summary.md` and `matrix-summary.json`.

`python3 scripts/distortion-report.py CAPTURE --strict` measures distortion and headroom on a capture (clip detection, stage null tests, master gain reduction, bass harmonics, lossy-encode overs) and gates it on the `distortion` block of `scripts/mix-criteria.json`; add `--against OTHER` to check that a master-only change left the stems identical, and `--encode-test` for the share-clip encode. See [mix verification](mix-verification.md#distortion-and-headroom).

`scripts/mix-criteria.json` is the source of truth for the thresholds, in three families: C-M (master: loudness, true peak, PLR, crest, limiter, pumping, soft clip, mono, spectrum, LRA), C-B (buses: low-end clearance, kick and bass, drum crest, mids and lead, theme return, space, intelligibility, film bed, routing) and C-D (dialogue: 16-bar and 8-bar change, repeats, rests, overlaps, stage timing and lead, accents, motif loop shape). Each criterion has a `fail` or `warn` level. The result is pass, warn (a warn-level miss), fail, or skipped with a reason. A threshold change needs a written reason in `docs/plans/mpc-chopping-measurements.md`.

`--strict` makes the exit status nonzero when a fail-level criterion fails, or when a fail-level criterion is skipped for a reason other than no footage, no dialogue or not applicable to the case. `mix-report.sh` also exits nonzero when the capture's own routing or peak check fails. `mix-matrix.sh` exits nonzero when a case produced no capture, and under `--strict` when any case has a strict failure.

Only one capture runs at a time per machine. `check-lofi.sh` takes an exclusive lock on `/private/tmp/liminal-lofi-audio-config-<uid>.json` and a second capture waits for it (`--wait-lock SECONDS`, default 1200). This is the same one-instance rule as for app launches: serialize captures and test runs. Analysis needs no lock. A 32-bar capture is about 0.9 GB. Captures, WAVs, audition files and `report/` output stay out of git, and the harness refuses an output directory inside the checkout.

[Mix verification](mix-verification.md) explains each measurement, how to read the figures and how to compare against a baseline.

## README preview

The linked poster and MP4 live in `docs/media/`. The 22 November 2026 preview is a clip of the app's own in-app recorder (the real shader, the real Lo-Fi mix, the real dialogue chops), made in the visionOS Simulator from curated pictures:

1. **Record.** Build the Debug app for the simulator, install it, and launch it with automation flags only: `xcrun simctl launch <udid> com.saygoodnight.Liminal -LiminalAutoPlay YES -LiminalOpenDome YES -archive.enabled YES -LiminalImageAPIFresh YES -LiminalRecordAt 20,150 -LiminalRecordSize 768x512 -LiminalRecordCodec h264`, with `xcrun simctl spawn <udid> log stream --level info --predicate 'subsystem == "com.saygoodnight.Liminal"'` writing the log. The movie is kept in the container's `Documents/Recordings` (`xcrun simctl get_app_container <udid> com.saygoodnight.Liminal data`); the macOS sandbox container is not readable, so use the simulator. Terminate the app afterwards.
2. **Check and choose.** `python3 -I scripts/av-sync-check.py MOVIE --log APP.log` must pass (the 22 November run: constant 60 fps, no splices, six drop cuts within 11 ms of the logged downbeats). Movie time is the log's uptime minus `T0 uptime` in the `Recording clock` line. `Lo-Fi image reveal at downbeat` lines give the picture cuts, and each `Lo-Fi dialogue hook` line's `bars=` string shows where the chop beat is busy (bars 3-6 of the loop, a bar is about 3.5 s). Pick a window with a picture change and the chop beat, and look at frames from it with ffmpeg: a real picture, no test card, no black. The 22 November window is 33.0 s to 50.0 s of a 150 s recording: the drop build and cut to the fireworks at 35.3 s (movie time), and the chop beat from bar 3 at about 42 s.
3. **Encode.** ffmpeg: 768x512 H.264 at about 1000 kb/s, 30 fps, AAC 256 kb/s stereo lowered by 1.0 dB (`volume=-1dB`), a 0.3 s fade in and 0.6 s fade out on picture and sound, and `+faststart`. The poster is a frame from inside the clip (4.2 s). The lossless 24-bit recording has headroom, but a lossy encode raises true peak (D121), so measure the MP4 with `ffmpeg -i MP4 -vn -af ebur128=peak=true -f null -`: it must be at most -1.5 dBTP (the current clip is -1.9 dBTP, -14.9 LUFS integrated, 17.0 s, 2.5 MB). The older offline route (`scripts/check-lofi.sh` capture, `scripts/shader-bench.sh` or `scripts/ffx-clip.sh` picture, then ffmpeg) still works when the simulator is not available; `python3 scripts/distortion-report.py CAPTURE --aac MP4 --strict` gates that route.

Check the picture change, audio level and both channels in the exported clip. Update the duration, size and source credits in the README. The playback link points at the MP4 page on GitHub: jsDelivr refuses this repository because it is over its 50 MB package limit (20 November 2026), and raw.githubusercontent serves MP4 as a download. After pushing, check that the raw bytes on GitHub match the local file. Keep captures and intermediate frames out of git. [Current preview](../README.md#see-it-in-motion)

## Debug launch flags (DEBUG builds only, compiled out of Release)

Pass as launch arguments, for example `-LiminalAutoPlay YES`. Defined in `Liminal/Utils/DebugLaunchOptions.swift`.

Automation launches fetch pictures from the free public image APIs. Pass `-LiminalImageAPIFresh YES` so a run fills a throwaway pool instead of the user's, or `-LiminalImageAPIOffline YES` to show only saved pictures with no network.

| Flag | Effect |
|------|--------|
| `-LiminalAutoPlay YES` | Start playback at launch |
| `-LiminalTraceLofi YES` | Print the exact take sample ranges (Debug) |
| `-LiminalProbeLofiProviders YES` | Log whether the host can discover Pro-C 2, Pro-L 2 and Animoog Z metadata (native Debug launch; instantiates nothing) |
| `-LiminalMusicSeed <n>` | Replay a score from the unsigned seed printed in the `Music graph built` log line |
| `-LiminalDelaySecondTake <s>` | Delay preparation of the second drum take (up to 60 s) to exercise the late-phrase fallback |
| `-LiminalOpenDome YES` | Open the immersive space automatically (visionOS) |
| `-LiminalShellYaw <deg>`, `-LiminalShellPitch <deg>` | Rotate the immersive scene so that direction faces the fixed simulator camera (negative angles as positive equivalents, e.g. 304) |
| `-LiminalShellHeadOffset "x,y,z"`, `-LiminalShellDepth <0...1>` | Imitate a head offset (parallax in the simulator) / override the Depth setting |
| `-LiminalDepthImage <png>`, `-LiminalShellCycle "img\|depth,..."` | Use Mac-made depth maps (the simulator's ML depth is all zeros) / cycle fixture images |
| `-LiminalHideControls YES`, `-LiminalShellTextureStereo YES` | visionOS: close the controls window once the space is open; macOS: show only the picture (no control panel or status badge, window sized to 3:2) / old per-eye texture parallax A/B |
| `-LiminalFreezeTime <s>` | Pin the effect clock for deterministic screenshots (bypasses coupling) |
| `-LiminalPerfLogInterval <s>` | Interval of the PERF log lines (default 1) |
| `-LiminalPerfSplitPasses YES` | No-op since the direct-drawable render; kept so `perf-run.sh --split` parses |
| `-LiminalTestPattern YES` / `-LiminalTestImage <path>` | Show a generated orientation test card / a given image. If `<path>` is a directory, its images are cycled on the image schedule (real transitions on known images; the macOS app is sandboxed, so use a path it can read) |
| `-LiminalForceStereoFlatDepth YES`, `-LiminalForceMonoMaterial YES` | Force flat depth / the mono fallback material |
| `-LiminalAutoExitAfter <s>` | visionOS: leave the immersive space this long after it opened (checks Exit in the simulator) |
| `-LiminalNoEffects YES` | Bypass all effects |
| `-LiminalSyncLog YES` | One SYNC log line per second (coupling state) |
| `-LiminalSyncStrength <x>` | Exaggerate the music-to-visuals coupling for tuning |
| `-LiminalEffectIntensity <0-1>` | Override the Effect intensity setting for this launch without changing it |
| `-LiminalTransitionStyle <name>` | Use this transition style for every image change (tide, facets, prism, rainbow, kaleidoscope, whirlpool, dive, afterimage, ripple, solarize, melt, shatter, classic; in a Lo-Fi drop also tear, blocks, mosh, crush, vhs, sort, punch, slitscan, jumpcut, fracture, shutter, static, bleed, scramble, and the outs whirlpool, kaleidoscope, dive, melt, shatter, facets) |
| `-LiminalDropColour <name>` | Pin a drop's colour layer (none, split, posterize, falsecolour, grain, scanlines). Automation flag. |
| `-LiminalDropFinisher <name>` | Pin a drop's finisher (none, whiteout, blackout, invert, collapse). Automation flag. |
| `-LiminalDropLead <ms>` | Override the display lead a drop is evaluated with (macOS: measured draw-to-present plus half a frame, 25 ms until measured; visionOS 28 ms). Automation flag. |
| `-LiminalDropOff YES` | Lo-Fi uses the bell reveal of T43 instead of drops (A/B). Automation flag. |
| `-LiminalTransitionSeed <n>` | Pin the transition seed too (same spec as `scripts/tx-clip.sh --style/--seed`) |
| `-LiminalVideoForce YES` | Start the first footage fetch after 1 s instead of 5 s, even when films are cached |
| `-LiminalVideoLook <name>`, `-LiminalVideoSeed <n>` | Every piece in this look (phantom, imprint, window, emerge) / pin the footage weaver's seed |
| `-LiminalVideoMode <recipe>` (alias `-LiminalFootageMode`) | Every piece in this footage recipe: a look or an interaction mode (undertow, wake, fringe, aurora, solar, poster, shadowplay, backdrop, kaleido, relief, glow, print) |
| `-LiminalVideoFile <mp4>`, `-LiminalVideoMix <0-1>` | Play a local clip, no network / one hour-long piece at a constant mix (stills) |
| `-LiminalVideoOffline YES`, `-LiminalVideoOff YES` | Cache only, no Internet Archive requests / no footage at all |
| `-LiminalDialogueTranscription off\|installedOnly\|allowDownload` | Use this Dialogue understanding mode for the launch, not saved |
| `-LiminalVideoOffAt <s>` | Turn the Archive footage setting off that many seconds after footage starts (fade-out check), not saved |
| `-LiminalControlsScroll archive\|images`, `-LiminalControlsWidth <pt>` | Scroll the control panel/window to the Archive Footage / Images & Storage card / visionOS controls window width (layout screenshots) |
| `-LiminalImageProvider <id[,id]>` | Restrict ingest and display to these provider ids (loc, nasa, wikimedia, cma, met, dc, aic) or source ids |
| `-LiminalImageAPIOffline YES` | Show only the saved pictures; no network |
| `-LiminalImageAPISeed <n>` | Seed the ingest and display rotations |
| `-LiminalImageAPIFresh YES` | Use an empty `CuratedImageStore-Verify` pool so a run proves fetching without touching the user's pool (removed at the next normal launch). With `-LiminalImageAPIOffline YES` it reuses the previous verify pool |
| `-LiminalRecordAt <start>,<seconds>[,photos]` | Start a recording `<start>` s after playback is ready and stop it `<seconds>` later; keeps the file in `Documents/Recordings` and skips Photos unless `,photos` is given ([recording.md](recording.md)) |
| `-LiminalRecordSize <W>x<H>`, `-LiminalRecordCodec h264`, `-LiminalRecordTrace YES` | Record at this size / with H.264 instead of the picture's size and HEVC (simulator timing checks: its software HEVC encoder cannot keep 60 fps); the trace logs every tap buffer's stamp and track position; check the movie with `scripts/av-sync-check.py` ([recording.md](recording.md#checking-a-recording)) |

### Image pipeline checks

The pipeline fetches from free public APIs, so its verification runs may use the network. The full pipeline, log lines and how to verify a new source are in [image-sources/](image-sources/README.md). Serialize launches with the other runs and terminate the app afterwards.

- Unit tests: `-only-testing:LiminalTests/ImageCollectionsTests -only-testing:LiminalTests/ImageProviderParsingTests -only-testing:LiminalTests/ImageRightsTests -only-testing:LiminalTests/ImageRotationTests -only-testing:LiminalTests/ImageOpennessTests -only-testing:LiminalTests/CuratedImagePoolTests -only-testing:LiminalTests/CuratedImageFeedTests -only-testing:LiminalTests/ImageQueueTests -only-testing:LiminalTests/ScanEdgeTrimmerTests` (fixtures in `LiminalTests/Fixtures/ImageAPI/`, trimmed from live responses of 2026-11-21).
- macOS: launch the built app with `-LiminalAutoPlay YES -LiminalImageAPIFresh YES -archive.enabled YES -LiminalVideoOffline YES` and stream the log. Every stored, rejected and shown picture logs one line (`API image stored: ...`, `API image rejected: ... reason=...`, `API image shown: source=... license=... url=...`). Expect shown pictures from several sources over a few minutes.
- Offline reuse: add `-LiminalImageAPIOffline YES` to the same flags.
- visionOS Simulator: `xcrun simctl launch <udid> com.saygoodnight.Liminal -LiminalAutoPlay YES -LiminalOpenDome YES -LiminalImageAPIFresh YES -LiminalControlsScroll images` (the control window then shows the credit). Vision's text and face checks cannot run in the simulator and are skipped with a log line.
- Perf: `scripts/perf-run.sh --extra "-LiminalImageAPIFresh YES"` (ingest live) and with `-LiminalImageAPIOffline YES`. A fresh pool's first picture arrives inside the measurement window with the depth model cold, so for a like-for-like check run once to fill the pool and measure with the pool kept (in the simulator, copy `CuratedImageStore-Verify` to `CuratedImageStore` in the app container). Results in `docs/decisions/images.md` D42.


## Scripts (`scripts/`)

| Script | Purpose |
|--------|---------|
| `perf-run.sh` | Repeatable visionOS Simulator capture: launches with the debug flags, collects fps and GPU timing, writes a JSON summary and screenshot. It also checks drum and picture changes, phrase deadlines, master-tap continuity and Core Audio overloads, and exits non-zero on a failure |
| `shader-bench.sh` | Deterministic Mac-GPU benchmark of the visionOS eye pass, with interleaved A/B of two shader files and parity PNG comparison |
| `sim-tap.sh X Y` | Click the visionOS Simulator at 3840x2160 screenshot pixel coordinates via Peekaboo |
| `sim-drag.sh` | Drag in the Simulator (needed for sliders) |
| `vibrance-eval.sh IN OUT` | Offline vibrance evaluation of the effect pipeline over a folder of images (`vibrance-check.py` checks the result) |
| `analyze-lofi.py`, `plot-lofi.py` | Analysis and plots of a `check-lofi.sh` capture (see Lo-Fi checks above) |
| `archive-curate.py`, `archive-fetch-fixture.sh` | Build the bundled Prelinger seed list / download one fixture clip to a scratch folder |
| `mix-report.sh`, `mix-matrix.sh` | Capture Lo-Fi audio offline and measure the mix against `mix-criteria.json` (one capture or the five-case matrix); `mixlib/` holds the analysis modules. See Mix verification above |
| `solo-stems.py` | Turn a capture into a full-mix file plus one file per channel (drums, bass, chords, melody, reverb-echo, chops, film footage) at its level in the final mix, through the same master gain trace, so the stems sum to `master.wav`. `scripts/solo-stems.py CAPTURE OUT [--wav]` |
| `strum-report.py` | Guitar and harp hook measures of one capture (D128): events, strings, drum sites, chop overlap, loudness, tone and echo per phrase. With `--baseline` and `--off` (the same build with `--hook strumHook=off`) it prints PASS/FAIL per capture criterion C2-C10 and measures the hook alone as on minus off; exits 1 on a failure |
| `stem-bands.py` | Per-stem band levels of a capture (40-120 Hz, 120-300 Hz, 300-800 Hz, 1-4 kHz), whole-file and over the stem's active 400 ms windows (within 30 dB of its loudest), with deltas to a baseline and the band gates of `docs/plans/bass-tone-redo.md` 6.1 and 6.5. `scripts/stem-bands.py CAPTURE [--baseline CAPTURE] [--json OUT]` |
| `bass-tone.py` | The bass tone gates of `docs/plans/bass-tone-redo.md` 6: third-octave table of `bass.wav` re its 50+63 Hz bands (each band from its centre to the next), power above 300 Hz, the sustain-only 1-4 kHz bands, continuity (sounding ratio, silences over 150 ms, active share) and the strike (300-1500 Hz and 1-3 kHz contrast, peak against the kick's attack, brightest window). `scripts/bass-tone.py CAPTURE [--baseline CAPTURE] [--json OUT]`; self-test in `mixlib/selftest.py` |
| `prepare-lofi-samples.py`, `lofi-sample-recipes.sh` | Prepare and measure the bundled instrument samples. `--prefix LofiBass` writes bass body files (`LofiBass-<kit>-<stroke>-<midi>[-<rr>].wav`, pitch search from 30 Hz) and `--retune` resamples each file by its measured pitch error until it is within 3 cents; the lead (`LofiLead`) behaviour is the default. Recipes `bass-upright` and `bass-flatwound` rebuild the bass kits ([credits](lofi-samples.md)) |
| `av-sync-check.py` | Check a recorded movie's A/V sync from the file (constant 60 fps, no edit lists, whole audio, no splices or silence) and, with `--log APP.log`, each drop cut against its logged audible downbeat and the kicks against the transport grid; `--legacy` reproduces the 2026-11-21 device-movie diagnosis; exits 1 on failure. `python3 -I scripts/av-sync-check.py MOVIE.mov [--log APP.log] [--plot]`; see [recording.md](recording.md#checking-a-recording) (D47). `tools/TapTimingCheck.swift` checks the audio tap's clock against `play(at:)` |

Simulator automation notes: `research/visionos-sim-automation/README.md`.


## Contributing

Issues and pull requests are welcome. Include your platform, Xcode version, reproduction steps, and relevant logs with sensitive information removed. For visual changes, include captures from the affected platform; simulator depth behavior differs from hardware.

Read [AGENTS.md](../AGENTS.md) for the repository map, build workflow, and rendering invariants. Run the macOS unit tests above before submitting code changes. Keep captures out of commits unless deliberately curated for documentation.


