# Development reference

[← Project overview](../README.md) · [Documentation index](README.md)

## Lo-Fi checks

Run the macOS score, transport, DSP, and archive timing tests with an explicit destination.

```sh
xcodebuild test -scheme Liminal -destination 'platform=macOS' \
  -only-testing:LiminalTests/LofiTests \
  -only-testing:LiminalTests/LofiCompositionTests \
  -only-testing:LiminalTests/LofiProductionTests \
  -only-testing:LiminalTests/ArchiveVoiceRenderTests \
  -only-testing:LiminalTests/LofiDialogueSamplerTests \
  -only-testing:LiminalTests/ArchiveCachePolicyTests
```

Run `scripts/check-lofi.sh` with FFmpeg and Python 3 installed for a headless, reproducible 16-bar capture. It writes float stereo WAVs, the exact score and clock, and independent LUFS, true-peak, routing, and energy metrics outside the repository. The default cue is a repeatable test signal. `--no-footage` exercises silence routing, `--footage /path/to/clip.mov` uses a local soundtrack, `--cached-footage` uses an audio-bearing clip from the app cache, and `--private-drums` requires an installed drum pack and keeps its captures local. Use `--drum-name` with the filename stem to reproduce an exact private take. `--block`, `--bpm`, `--scale Dorian` and `--seed` vary a run. Use `--bars 32` for the full form or `--bars 64` for a longer instrument audit. `python3 scripts/measure-lofi-instruments.py /path/to/capture` reports the strongest 400 ms of each instrument, its wet return and their combined level, with the combined sample peak. With private drums, add `--next-drum-name` to audition a different take at the sixteen-bar downbeat and hear the footage cue through each fill. Add up to 16 beats of postroll after a complete take to measure its tail. The capture uses the live conductor’s footage gain and room settings and holds adaptive master trim at nominal for repeatability. The checker verifies both music-stem and pre-master sums and defaults to a −1.5 dBTP ceiling. Debug runs can use `--limiter apple-peak-limiter` for an isolated reference, or a fully qualified provider identity from the AU probe. The live app uses its built-in master. `python3 scripts/analyze-lofi.py --self-test` checks that the analyzer rejects known failures. `--ebu-subset` runs 17 synthetic cases from EBU Tech 3341 and 3342.

For a dialogue audition, use `--film-reel --bars 32` to change to another locally cached soundtrack every eight bars. Listen to `master.wav` for the mix, `film-soundtrack.wav` for the continuous film after its level automation, or `dialogue-chops.wav` for the post-fader drops with effects on the music bus. The echo and room can be auditioned together before the cue fader in `dialogue-fx.wav`. The full treated film bed, including its echo and room, is in `footage.wav`. The manifest records the film titles and offsets, source frame ranges, scheduled hit frames, playback speeds and reversed pickups. Add `--private-drums` to hear the local takes. For dialogue leveling, compare each hit against the backing during that hit and check the loudest syllables separately. Liminal uses 50 ms windows alongside a moving window of up to 400 ms; the latter corresponds to the momentary timescale in the [EBU loudness guidance](https://tech.ebu.ch/loudness/).

Use `python3 scripts/plot-lofi.py /path/to/capture --auditions` with NumPy, SciPy, and Matplotlib for three spectrogram resolutions, an overlay of planned rests and measured levels, reconstructed peaks at 4×, 8×, and 16×, and copies for listening near −20, −18, and −16 LUFS within headroom. Its JSON and NPZ files retain the energy and spectral measurements. For a paired comparison, add `--against /path/to/reference --comparison-out /path/to/new/directory` and optionally `--candidate-lag-frames <measured>` to override the graph's reported latency. It checks that both captures used the same score and sources, preserves the originals, and writes matched audio and difference plots. These signals expose overlap and decay. Listening still determines whether the speech or music has enough room.

Start with `-audio.musicMode lofi -LiminalAutoPlay YES -LiminalVideoOffline YES` for a cached-footage smoke test. The audio log reports instrument choices, 16-bar take starts, and any preparation misses. `-LiminalTraceLofi YES` also prints exact take sample ranges for a Debug launch. Add `-LiminalProbeLofiProviders YES` to a native Debug launch to log whether the host can discover Pro-C 2, Pro-L 2, and Animoog Z metadata. The probe does not instantiate or route audio to an extension. Physical headset listening and sustained profiling have their own acceptance checks in the [research notes](research/lofi-studio.md).

## README preview

The linked poster and MP4 live in `docs/media/`. The current clip is a live macOS recording of *Thinking Machines* over the Lo-Fi mix. To refresh it, use ScreenCaptureKit to capture only the Liminal app and its stereo output with the microphone disabled. A Debug launch with `-LiminalVideoFile` pointed at a credited film and `-LiminalAllowGeneration NO` makes the source identifiable and reuses cached imagery. Record across a drum fill, crop to the artwork, and export a short H.264 MP4 with AAC stereo and the MP4 index at the front for streaming.

Check the picture change, audio level and both channels in the exported clip. Choose the poster from that export. Update the duration, size, source credit, license and revision in the README playback link, then check the published bytes against the local file. [Current preview](../README.md#see-it-in-motion)

## Debug launch flags (DEBUG builds only, compiled out of Release)

Pass as launch arguments, for example `-LiminalAutoPlay YES`. Defined in `Liminal/Utils/DebugLaunchOptions.swift`.

**Any launch that uses these flags never calls Gemini** (no API spend from testing): it shows cached images, or the test card when the cache is empty. Add `-LiminalAllowGeneration YES` to deliberately allow generation; the in-app hourly/daily image limit still applies (`decisions/images.md` D34).

| Flag | Effect |
|------|--------|
| `-LiminalAutoPlay YES` | Start playback at launch |
| `-LiminalAllowGeneration YES` | Let an automated launch generate new images (off by default) |
| `-LiminalOpenDome YES` | Open the immersive space automatically (visionOS) |
| `-LiminalShellYaw <deg>`, `-LiminalShellPitch <deg>` | Rotate the immersive scene so that direction faces the fixed simulator camera (negative angles as positive equivalents, e.g. 304) |
| `-LiminalShellHeadOffset "x,y,z"`, `-LiminalShellDepth <0...1>` | Imitate a head offset (parallax in the simulator) / override the Depth setting |
| `-LiminalDepthImage <png>`, `-LiminalShellCycle "img\|depth,..."` | Use Mac-made depth maps (the simulator's ML depth is all zeros) / cycle fixture images |
| `-LiminalHideControls YES`, `-LiminalShellTextureStereo YES` | Close the controls window once the space is open / old per-eye texture parallax A/B |
| `-LiminalFreezeTime <s>` | Pin the effect clock for deterministic screenshots (bypasses coupling) |
| `-LiminalPerfLogInterval <s>` | Interval of the PERF log lines (default 1) |
| `-LiminalPerfSplitPasses YES` | Legacy split-pass option (no-op since the direct-drawable render) |
| `-LiminalTestPattern YES` / `-LiminalTestImage <path>` | Show a generated orientation test card / a given image. If `<path>` is a directory, its images are cycled on the image schedule (real transitions on known images; the macOS app is sandboxed, so use a path it can read) |
| `-LiminalImageInterval <s>` | Seconds between images for this launch (at least 4), not saved; e.g. 15 to see many transitions |
| `-LiminalForceStereoFlatDepth YES`, `-LiminalForceMonoMaterial YES` | Force flat depth / the mono fallback material |
| `-LiminalNoEffects YES` | Bypass all effects |
| `-LiminalSyncLog YES` | One SYNC log line per second (coupling state) |
| `-LiminalSyncStrength <x>` | Exaggerate the music-to-visuals coupling for tuning |
| `-LiminalEffectIntensity <0-1>` | Override the Effect intensity setting for this launch without changing it |
| `-LiminalTransitionStyle <name>` | Use this transition style for every image change (tide, facets, prism, rainbow, kaleidoscope, whirlpool, dive, afterimage, ripple, solarize, melt, shatter, classic) |
| `-LiminalTransitionSeed <n>` | Pin the transition seed too (same spec as `scripts/tx-clip.sh --style/--seed`) |
| `-LiminalVideoForce YES` | Archive footage pieces at the Fast change speed whatever the setting |
| `-LiminalVideoLook <name>`, `-LiminalVideoSeed <n>` | Every piece in this look (phantom, imprint, window, emerge) / pin the footage weaver's seed |
| `-LiminalVideoMode <recipe>` (alias `-LiminalFootageMode`) | Every piece in this footage recipe: a look or an interaction mode (undertow, wake, fringe, aurora, solar, poster, shadowplay, backdrop, kaleido, relief, glow, print) |
| `-LiminalVideoFile <mp4>`, `-LiminalVideoMix <0-1>` | Play a local clip, no network / one hour-long piece at a constant mix (stills) |
| `-LiminalVideoOffline YES`, `-LiminalVideoOff YES` | Cache only, no Internet Archive requests / no footage at all |
| `-LiminalVideoOffAt <s>` | Turn the Archive footage setting off that many seconds after footage starts (fade-out check), not saved |
| `-LiminalControlsScroll archive`, `-LiminalControlsWidth <pt>` | Scroll the control panel/window to the Archive Footage card / visionOS controls window width (layout screenshots) |


## Scripts (`scripts/`)

| Script | Purpose |
|--------|---------|
| `perf-run.sh` | Repeatable visionOS Simulator capture: launches with the debug flags, collects fps and GPU timing, writes a JSON summary and screenshot |
| `shader-bench.sh` | Deterministic Mac-GPU benchmark of the visionOS eye pass, with interleaved A/B of two shader files and parity PNG comparison |
| `sim-tap.sh X Y` | Click the visionOS Simulator at 3840x2160 screenshot pixel coordinates via Peekaboo |
| `sim-drag.sh` | Drag in the Simulator (needed for sliders) |
| `vibrance-eval.sh IN OUT` | Offline vibrance evaluation of the effect pipeline over a folder of images (`vibrance-check.py` checks the result) |
| `render-music.sh`, `check-music.py` | Offline render and analysis of the music engine; `ARCHIVE=<mp4>` mixes one footage piece's sound in |
| `analyze-archive-audio.py` | Level, spectrum, fades and limiter check of the archive sound in a render |
| `archive-curate.py`, `archive-fetch-fixture.sh` | Build the bundled Prelinger seed list / download one fixture clip to a scratch folder |
| `av-coupling-check.sh` | Offline check of the audio-visual coupling |

Simulator automation notes: `research/visionos-sim-automation/README.md`.


## Contributing

Issues and pull requests are welcome. Include your platform, Xcode version, reproduction steps, and relevant logs with sensitive information removed. For visual changes, include captures from the affected platform; simulator depth behavior differs from hardware.

Read [AGENTS.md](../AGENTS.md) for the repository map, build workflow, and rendering invariants. Run the macOS unit tests above before submitting code changes. Keep credentials and generated captures out of commits unless deliberately curated for documentation.


