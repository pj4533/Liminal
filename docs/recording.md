# Recording

[← Docs index](README.md)

The **Record** button sits under Play/Stop in the Playback section, on macOS and in the visionOS control window. It records what Liminal renders and what it plays, then saves the movie to the Photos library so it is easy to share. It is not a screen recording: no window, controls, cursor or passthrough appear in the movie.

## Using it

1. Press **Play**. On Vision Pro, also enter Liminal's immersive view. Record becomes available when the picture renderer is ready.
2. Press **Record**. The status line under the button counts up ("Recording 1:23").
3. Press **Stop Recording**, stop playback, or leave the immersive view on Vision Pro. The button shows "Saving…" while the file is closed, then the status says "1:23 saved to Photos".

The first time, the system asks for permission to **add** to the photo library (add-only access: Liminal cannot read your photos). If access is refused, the movie is still kept in the app's `Documents/Recordings` folder and the status says so. On macOS that folder is `~/Library/Containers/com.saygoodnight.Liminal/Data/Documents/Recordings`; on visionOS it is in the app's container (reachable through Files only if file sharing is enabled; Photos is the intended route).

## What is in the movie

| | macOS | visionOS |
|---|---|---|
| Picture | The 16:9 effects drawable, fitted to the nearest smaller exact 16:9 size with even dimensions. The size stays fixed if the window is resized while recording. | The immersive 2048² effects texture at the picture's 16:9 aspect (2048×1152) |
| Video codec | HEVC, about 0.35 bit per pixel at 60 Hz, at least 40 Mbit/s, no frame reordering, Rec. 709 tags | same |
| Frame rate | Constant 60 fps: every frame 1/60 s, frame count = length x 60 | same; the render loop runs at about 82 fps (sleep-paced towards 90 Hz), and each 60 Hz slot holds the frame shown nearest its time |
| Audio | The final mix after the master chain, **lossless 24-bit LPCM**, stereo, at the engine's rate (48 kHz) | same |
| Container | QuickTime `.mov`, named `Liminal yyyy-MM-dd at HH.mm.ss.mov` | same |

**visionOS and the immersive space.** An app cannot record the composited headset view (passthrough, the room, your head movement); only the system's *Record My View* in Control Center can, and it records at the system's resolution. Liminal records its own rendered picture instead, the same image that is projected on the dome, at full quality. To capture the headset view as you experienced it, use Control Center → Record My View alongside (or instead of) the Record button.

## How it works

`Liminal/Recording/`:

- **`FrameRecorder`** (nonisolated, one shared instance).
  - **Video.** Each renderer calls `capture(_:commandBuffer:presentationTime:)` after encoding its frame and before committing the command buffer: macOS in `EffectsMetalView.draw` (source: the drawable texture), visionOS in `OffscreenEffectsRenderer.renderAndPresent` (source: the bgra8Unorm view of the shell drawable). The recorder takes a pixel buffer from its own `CVPixelBufferPool` (IOSurface-backed, Metal compatible, at least 16 buffers), wraps it with `CVMetalTextureCache`, and encodes one full-screen-triangle pass (`RecorderCopy.metal`, bilinear) into it **in the same command buffer**. Both sources hold sRGB-encoded values in a `bgra8Unorm` texture, so the copy passes values through unchanged. When the command buffer completes, the pixel buffer is appended to the HEVC track on the recorder's serial `writerQueue`. Nothing waits on the GPU, and the render thread only encodes the small pass.
  - **Timing: one movie clock** (`RecordingTiming.swift`, D47). Movie time 0 is the presentation time of the first frame (T0, on the uptime clock the Lo-Fi transport and the drop cuts use). Video slot k is at exactly k/60 s and audio sample n at exactly n/rate s; nothing is placed by "next slot" or "next sample" alone, so the tracks cannot drift or shift against each other. Both start at 0 (no edit list) and end together at the end of the last slot. On Stop the picture ends at once, but the tap stays on (up to 0.6 s) until the audio heard up to the last slot's end has arrived, so the movie does not end in padded silence; the controller removes the tap after the file is finished.
    - *Frames.* Each frame carries its presentation time: macOS the draw time plus the measured present latency (`dropLead` minus its half-frame early bias); visionOS the display time the render loop expects for the frame, sampled with its drop state (`LofiImageReveal.presentationLatency`: the 28 ms display lead minus its half-frame early bias, 22 ms), passed to `renderAndPresent(presentationTime:)`. `FrameSlotter` puts each frame in the slot nearest that time: two frames for one slot keep the nearer (above 60 Hz about a quarter of the frames are surplus), a slot without a frame repeats the previous one (up to 10 s), a late frame is dropped. For a source within 10% of 60 Hz (by a mean frame step clamped so one stall or hiccup cannot pull an 80-90 fps mean into that window) a small hysteresis stops a phase on a slot boundary from alternating drop and repeat; it can hold a frame up to 0.75 slot (12.5 ms) off. Faster sources are always within half a slot (8.3 ms).
    - *Audio.* The tap writes each buffer with its `AVAudioTime` host and sample time (`AudioRing.Mark`). `AudioTimeline` places a buffer at the track position of the time it is heard (host time plus the tapped node's `outputPresentationLatency`, read once at start and again after a route recovery): a buffer that continues the previous one goes straight after it, sample for sample; lost samples (a dropped buffer, a ring overrun) become exactly that much silence; a break in the sample clock (an engine restart) is placed again by its host time; audio heard before T0 is skipped and a late first buffer is preceded by silence. It also follows the audio device's clock against the host clock (`driftSeconds`), and video times are corrected by it, so the movie's clock is the audio's.
    - *Pre-roll.* The ring is drained every 20 ms from the start, also before the first frame arrives (the last 2 s are kept), so it never fills while the movie waits for video.
  - **No drops from the recorder.** The real-time hardware HEVC encoder keeps up at 60 Hz; frames that arrive while the encoder is busy wait in a queue of up to 2 s (120 frames) instead of being dropped. On stop the queue is flushed before the track is finished.
  - **Audio.** `GenerativeEngine.recordTap`, a unity `Mixer` after the master chain and the graph's final node, carries the recorder's tap (it asks for 1024 frames; the device delivers its IO buffer, 4800 frames at the 100 ms visionOS buffer and in the simulator). `AVAudioEngine.mainMixerNode` is never touched: AudioKit does not use it, and accessing it makes AVAudioEngine try to connect one while running, which throws. The Lo-Fi master calibration keeps its own tap on `master.output`. The tap block only copies floats and one time stamp into `AudioRing`, a single-producer single-consumer ring of interleaved stereo (10 s, atomics, no locks, no allocation); a buffer that does not fit, or arrives at another sample rate, is dropped whole with its stamp. `writerQueue` turns the placements into `CMSampleBuffer`s on the LPCM track.
  - **Stats.** `Recording finished: N frames (… s at 60 fps) from M rendered at … fps, … surplus, … repeated, max slot error … ms, … dropped, … capture failures, first frame after … s; audio … s, … silence frames, … skipped before start, … discontinuities, … overruns, … rate mismatches, drift … ms, latency … ms` is logged when a movie is closed, then `Recording clock: Lo-Fi take downbeat at movie … s, beat … s, T0 uptime …, drift … ms` (the audible grid on the movie clock, for `scripts/av-sync-check.py`). Any audio buffer that is not contiguous logs `Recording audio: buffer at track …`.
- **`RecordingController`** (main actor): asks for add-only Photos access **before** a first recording (a prompt during a recording held up its first frame on the device), builds the writer, encoder session and copy pipeline **off the main actor** (on macOS the main thread draws the frames, and this setup took about 0.4 s), installs the tap, publishes the phase for the button, finishes on Stop or when playback stops, refreshes the audio latency after a route recovery (`routeRecovered`), and saves to Photos with `PHPhotoLibrary.requestAuthorization(for: .addOnly)` and `PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL:)`.
- **`RecordControls`**: the button and status line in both control panels.

**Permissions.** `Info.plist` has `NSPhotoLibraryAddUsageDescription`. The macOS sandbox gets the Photos entitlement from the build setting `ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY = YES` (`com.apple.security.personal-information.photos-library`). No other permission is needed: the recorder reads the app's own frames and audio, not the screen or microphone.

## Measurements (2026-11-21, before the timing fix)

| Run | Frames | Rate | Long intervals (>25 ms) | Dropped by recorder | Audio |
|---|---|---|---|---|---|
| macOS, Lo-Fi, API pictures, footage on, 60 s, 1824x1216 | 3588 over 59.9 s | 59.92 fps | 3 (max 66.7 ms, one app stall of 71 ms) | 0 | 59.8 s, 0 overruns |
| macOS, 30 s, setup still on the main thread | 1788 over 30.0 s | 59.57 fps | 7 (max 116.7 ms) | 0 | 30.0 s |
| visionOS Simulator, 45 s, 2048x1366 | 106 | 2.3 fps | | 2611 | 45.0 s, 0 overruns |

- The simulator has no hardware HEVC encoder, so its software encoder cannot keep 60 Hz at 2048x1366; it is a functional check only (file structure, orientation, 3:2 scaling, colour, audio, Photos). The Vision Pro has a hardware HEVC encoder; device numbers are not measured yet.
- The remaining long intervals on macOS are the app's own render stalls on the main thread (they appear as "Slow Mac frame" with or without recording, for example 69 ms at a picture reveal), not the recorder.
- File check (ffprobe): `hevc` 2048x1366 bt709, `pcm_s24le` 48 kHz stereo; peak -1.15 dBFS, RMS -15.9 dB on a Lo-Fi section, matching the master's ceiling.
- The Photos step was checked in the simulator after `xcrun simctl privacy <udid> grant photos-add com.saygoodnight.Liminal` ("Recording added to Photos").

## The Vision Pro movie that was out of sync, and the fix (2026-11-21, D47)

On the device the live picture and sound were in sync, but the saved movie's drop cuts were seconds late: the picture was late by 7.2 s at the first cut, 17.3, 27.3 and 37.4 s at the next three, and the last 42 s had no sound. Measured from the file (`scripts/av-sync-check.py --legacy`):

| | Device movie (before) | Cause |
|---|---|---|
| Video | 9189 frames, every step exactly 1/60 s, 153.15 s | The render loop runs at about 81.6 fps; "two frames in one slot take consecutive slots" gave every frame its own slot, so the picture ran 1.36x slower than real time (0.36 s late per second) |
| Audio | 123.000 s of media, an edit list skipping the first 12.113 s, a hard splice at exactly sample 480,000 (10.000 s, the ring's capacity; prediction-error ratio 126 against 1.9 median at other buffer joins) | The first frame reached the recorder 12.1 s after the tap started; the drain waited for it, the 10 s ring filled, about 2.1 s of audio was dropped and the rest was stamped by sample count, so everything after the splice was 2.1 s early |
| Fit | offset = 2.76 s + 0.360 x t; residuals within 51 ms | Both causes, nothing else |

After the fix (same check, `--log` with the run's log):

| Run | Video | Audio | Drop cuts vs their audible downbeat | Kick onsets vs the transport grid |
|---|---|---|---|---|
| visionOS Simulator, Lo-Fi, 90 s, 768x512 H.264, render 77 fps | 5387 frames, every step 1/60 s, 89.783 s; 1653 surplus, 94 repeated | 89.783 s, no edit list, no splice, no silence except 44 ms padded at the end, drift -0.47 ms | +12.1, +2.8, -6.5 ms | 94 kicks, median +9.3 ms |
| visionOS Simulator, Lo-Fi + footage and dialogue, 150 s, 768x512 H.264, render 78 fps, every tap buffer traced | 8989 frames, every step 1/60 s, 149.817 s; 2785 surplus, 24 repeated, max slot error 12.4 ms | 149.817 s, equal to the video to the sample, 1498 tap buffers all contiguous, 0 inserted silence except the end pad, drift -0.81 ms | -3.6, +3.7, -5.6, +1.7, +9.0 ms | 138 kicks, median +23.6 ms |
| macOS, Lo-Fi, 90 s, 1824x1216 HEVC | 5393 frames over 89.88 s from 5387 rendered at 59.93 fps, 0 surplus, 6 repeated, max slot error 10.6 ms, 0 dropped | 89.883 s, 0 discontinuities, 0 overruns, drift -0.49 ms, latency 1.2 ms | (file not readable from the terminal: the app's sandbox) | |
| macOS, Lo-Fi + footage and dialogue, 150 s, traced | 8992 frames from 8985 rendered at 59.95 fps, 1 surplus, 8 repeated, max slot error 12.0 ms | 149.867 s, 1498 tap buffers all contiguous and none containing exact zeros, drift -0.80 ms | (live log: drawn -7.0 to -18.3 ms before the downbeat, lead 25 ms) | |

- The clock the recorder relies on was checked sample for sample with `tools/TapTimingCheck.swift` on macOS (player -> mixer -> tapped mixer -> output, five `play(at:)` impulses): tap host time + index / rate equalled the scheduled host time within half a sample (-0.02 to -0.48 samples), tap buffers were 4800 frames with no sample-time gaps.
- The kick-onset median is detector lag (a 5 ms RMS of a 40-140 Hz band peaks after the attack), the drummer's hand-played timing and the take's first hit sitting 4-8 ms after the boundary (drop-transitions 3.2); it moves with the take, never by a buffer (21-100 ms), and does not step anywhere in a movie.
- `driftSeconds` grows about 5 ppm on both platforms (-0.47 ms at 90 s, -0.81 ms at 150 s): the output's real sample rate against the host clock. The video follows it; uncorrected it would be about 19 ms per hour.
- **Independent re-check (2026-11-21, a second agent).** The before numbers hold: the audio media is 5,904,000 frames (exactly 1230 tap buffers of 4800, 123.0 s), the edit list starts at 12.113 s, so the real span after the first frame is 123.0 - 12.113 + 2.113 = 113.0 s and 9188 frames give 81.3 fps. Three findings were fixed: (1) every movie ended in 70-100 ms of padded silence, because the tap was removed at Stop before the last tap buffer (100 ms) arrived; (2) the slotter's near-60 Hz hysteresis switched on after a single hiccup in a 78-82 fps stream (an EMA of the frame step pulled into the 0.8-1.2 window), placing frames up to 12.4 ms off; (3) the check script took a drop build's flash frame (279 ms early) for the cut. After the fixes: visionOS Simulator, Lo-Fi with footage and dialogue, seed 41, 150 s, traced: 8988 frames, every step 1/60 s, 149.800 s; audio 149.800 s with 0 silence frames, 0 discontinuities, no splice, no zero runs; max slot error 8.3 ms (was 12.3-12.4); five drop cuts -0.9, +6.4, +13.8, +4.4, -4.9 ms from their logged downbeats (the app logged those cuts drawn 10.5, 5.8, 11.4, 11.5 and 6.1 ms after downbeat minus lead, so each movie offset is the live offset within one slot). Seed 23, 120 s (before the tail fix): cuts +3.6, -5.7, +1.6, -7.7 ms, the same at 21 s as at 105 s (no drift); a separate script decoding the raw samples and frames found the same cut frames and the kicks 0-10 ms after the downbeats. macOS 90 s: 5392 frames from 59.87 fps rendering, 0 silence frames, 0 discontinuities, drift -0.48 ms.
- With footage and dialogue on, the simulator's own rendered mix twice contained exact-zero runs inside contiguous tap buffers (69 ms and 12 ms in 150 s; one 47 ms run in an earlier untraced run). The trace shows the zeros arrive in the tap's buffers with contiguous sample and host times, so they are in what the engine rendered (and played), not lost by the recorder; the same 150 s on macOS had none. Not checked on the device. `scripts/av-sync-check.py` lists them as warnings.
- A cut lands within one 60 Hz slot (±8.3 ms) of where it was shown live, plus the cut's own early bias (a drop is evaluated half a frame late so it errs early). On the device, the 28 ms visionOS display lead is still an estimate shared with the live cut: the movie reproduces what the app intends, and the remaining live error, if any, is the same in the movie.
- Not yet measured on the device: the fixed build's movie. Check it with `scripts/av-sync-check.py MOVIE --log LOG` (expect PASS) or, without a log, with the structure checks alone.

## Testing

`-LiminalRecordAt <start>,<seconds>` starts a recording `<start>` seconds after playback is ready and stops it `<seconds>` later, keeping the file without the Photos step (no permission prompt during automation). Add `,photos` to include the Photos step. It is an automation flag, so use `-LiminalImageAPIFresh YES` or `-LiminalImageAPIOffline YES` with it. Example:

```sh
open Liminal.app --args -LiminalAutoPlay YES -archive.enabled YES -LiminalImageAPIFresh YES -LiminalRecordAt 5,60
```

Read the `Recording finished:` log line for frame and drop counts. In the visionOS Simulator the file is in the app's data container under `Documents/Recordings`.

**Simulator timing checks.** The simulator's software HEVC encoder writes about 35 fps even at 384x256, so a full-size simulator movie drops frames in the encoder queue. `-LiminalRecordSize WxH` and `-LiminalRecordCodec h264` (DEBUG) record smaller and with H.264, which keeps up at 768x512. `-LiminalRecordTrace YES` logs every tap buffer's host time, sample time and track position, and any exact-zero run inside it (`REC mark ...`):

```sh
xcrun simctl launch <udid> com.saygoodnight.Liminal -LiminalAutoPlay YES -LiminalOpenDome YES \
  -LiminalMusicSeed 7 -LiminalTestImage <dir of jpgs> -LiminalRecordAt 8,90 -LiminalRecordSize 768x512 -LiminalRecordCodec h264
```

### Checking a recording

Pull the movie off the Vision Pro (the app's `Documents/Recordings` folder), with the headset connected and the app closed:

```sh
xcrun devicectl device copy from --device <device name or id> --domain-type appDataContainer \
  --domain-identifier com.saygoodnight.Liminal --source "Documents/Recordings/<name>.mov" --destination ~/Desktop/<name>.mov
```

For the log of the same run use Console or `log stream` on the device, or run the check without `--log` for the structure checks alone. Keep movies and logs out of git.

`python3 -I scripts/av-sync-check.py MOVIE.mov --log APP.log` checks a movie from the file alone, plus the app's log of the same run (`log stream --level info --predicate 'subsystem == "com.saygoodnight.Liminal"'`, or `xcrun simctl spawn <udid> log stream ...`):

- constant 60 fps (every pts step 1/60 s), both tracks starting at 0 with no edit list and ending within a frame of each other;
- the audio media whole: no strong hard splice on a tap-buffer join (a closed-up overrun scores over 100; weaker candidates, usually musical edges, are warnings), and exact-zero runs inside the movie listed as warnings (padded lost audio, or zeros the engine rendered);
- each drop cut against its audible downbeat (`Lo-Fi image reveal at downbeat` uptimes on the movie clock from the `Recording clock` line): within 25 ms or it fails;
- the kick onsets against the transport's beat grid.

It exits 1 on a failure and writes `avsync.json` (and a plot with `--plot`). `--legacy` adds the analysis that diagnosed the device movie. The unit tests are `-only-testing:LiminalTests/RecordingTimingTests` (render streams at 48, 60, 83, 90 and 120 Hz with jitter, 10-minute drift, overruns, restarts, pre-roll) and `RecordingTimingAdversarialTests` (hiccups in an 81.6 fps stream, throttling between 45 and 120 fps, a 59.94 Hz display for 10 minutes, a stall longer than the repeat limit, out-of-order completions, latency changes above and below the host tolerance, 44.1 kHz 512-frame buffers, ring wrap-around, and the device's stalled consumer through the real ring). With `--log`, each logged downbeat is matched to the biggest one-frame change within 100 ms that the picture settles after, so a heavy drop build's last flash frame is not taken for the cut.
