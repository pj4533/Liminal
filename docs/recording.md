# Recording

[← Docs index](README.md)

The **Record** button sits under Play/Stop in the Playback section, on macOS and in the visionOS control window. It records what Liminal renders and what it plays, then saves the movie to the Photos library so it is easy to share. It is not a screen recording: no window, controls, cursor or passthrough appear in the movie.

## Using it

1. Press **Play**. Record is available once playback is ready.
2. Press **Record**. The status line under the button counts up ("Recording 1:23").
3. Press **Stop Recording**, or Stop playback (which finishes the movie first). The button shows "Saving…" while the file is closed, then the status says "1:23 saved to Photos".

The first time, the system asks for permission to **add** to the photo library (add-only access: Liminal cannot read your photos). If access is refused, the movie is still kept in the app's `Documents/Recordings` folder and the status says so. On macOS that folder is `~/Library/Containers/com.saygoodnight.Liminal/Data/Documents/Recordings`; on visionOS it is in the app's container (reachable through Files only if file sharing is enabled; Photos is the intended route).

## What is in the movie

| | macOS | visionOS |
|---|---|---|
| Picture | The effects view's drawable, every frame, at its pixel size (for example 1824x1216 for a 912x608 pt view on a Retina display) | The 2048² effects texture that is mapped onto the immersive shell, scaled back to the picture's 3:2 (2048x1366) |
| Video codec | HEVC, about 0.35 bit per pixel at 60 Hz, at least 40 Mbit/s (46 Mbit/s at 1824x1216, 58 Mbit/s at 2048x1366), no frame reordering, Rec. 709 tags | same |
| Frame rate | 60 Hz | 60 Hz (the render loop's rate) |
| Audio | The final mix after the master chain, **lossless 24-bit LPCM**, stereo, at the engine's rate (48 kHz) | same |
| Container | QuickTime `.mov`, named `Liminal yyyy-MM-dd at HH.mm.ss.mov` | same |

**visionOS and the immersive space.** An app cannot record the composited headset view (passthrough, the room, your head movement); only the system's *Record My View* in Control Center can, and it records at the system's resolution. Liminal records its own rendered picture instead, the same image that is projected on the dome, at full quality. To capture the headset view as you experienced it, use Control Center → Record My View alongside (or instead of) the Record button.

## How it works

`Liminal/Recording/`:

- **`FrameRecorder`** (nonisolated, one shared instance).
  - **Video.** Each renderer calls `capture(_:commandBuffer:hostTime:)` after encoding its frame and before committing the command buffer: macOS in `EffectsMetalView.draw` (source: the drawable texture), visionOS in `OffscreenEffectsRenderer.renderAndPresent` (source: the bgra8Unorm view of the shell drawable). The recorder takes a pixel buffer from its own `CVPixelBufferPool` (IOSurface-backed, Metal compatible, at least 16 buffers), wraps it with `CVMetalTextureCache`, and encodes one full-screen-triangle pass (`RecorderCopy.metal`, bilinear) into it **in the same command buffer**. Both sources hold sRGB-encoded values in a `bgra8Unorm` texture, so the copy passes values through unchanged. When the command buffer completes, the pixel buffer is appended to the HEVC track on the recorder's serial `writerQueue`. Nothing waits on the GPU, and the render thread only encodes the small pass.
  - **Even frame times.** Each frame is stamped with its expected presentation time on the host clock (macOS: draw time plus the measured present latency; visionOS: about one frame after submission), then snapped to the nearest 60 Hz slot from the first frame. Two frames in one slot take consecutive slots. Render-timing jitter of a few milliseconds therefore does not make the movie judder; a slot is skipped only when the app really did not render a frame.
  - **No drops from the recorder.** The real-time hardware HEVC encoder keeps up at 60 Hz; frames that arrive while the encoder is busy wait in a queue of up to 2 s (120 frames) instead of being dropped. On stop the queue is flushed before the track is finished.
  - **Audio.** `GenerativeEngine.recordTap`, a unity `Mixer` after the master chain and the graph's final node, carries the recorder's tap (1024-frame buffers). `AVAudioEngine.mainMixerNode` is never touched: AudioKit does not use it, and accessing it makes AVAudioEngine try to connect one while running, which throws. The Lo-Fi master calibration keeps its own tap on `master.output`. The tap block only copies floats into `AudioRing`, a single-producer single-consumer ring of interleaved stereo (10 s, atomics, no locks, no allocation). Every 20 ms `writerQueue` drains it into `CMSampleBuffer`s and appends them to the LPCM track, stamped from the first buffer's host time plus the output's presentation latency (read once at start), so the audio is placed where it is heard. On stop the audio is cut at the end of the last video frame.
  - **Stats.** `Recording finished: … frames over … s (… fps), max interval … ms, … long, … dropped, audio … s, … audio overruns` is logged when a movie is closed.
- **`RecordingController`** (main actor): builds the writer, encoder session and copy pipeline **off the main actor** (on macOS the main thread draws the frames, and this setup took about 0.4 s), installs the tap, publishes the phase for the button, finishes on Stop or when playback stops, and saves to Photos with `PHPhotoLibrary.requestAuthorization(for: .addOnly)` and `PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL:)`.
- **`RecordControls`**: the button and status line in both control panels.

**Permissions.** `Info.plist` has `NSPhotoLibraryAddUsageDescription`. The macOS sandbox gets the Photos entitlement from the build setting `ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY = YES` (`com.apple.security.personal-information.photos-library`). No other permission is needed: the recorder reads the app's own frames and audio, not the screen or microphone.

## Measurements (2026-11-21)

| Run | Frames | Rate | Long intervals (>25 ms) | Dropped by recorder | Audio |
|---|---|---|---|---|---|
| macOS, Lo-Fi, API pictures, footage on, 60 s, 1824x1216 | 3588 over 59.9 s | 59.92 fps | 3 (max 66.7 ms, one app stall of 71 ms) | 0 | 59.8 s, 0 overruns |
| macOS, 30 s, setup still on the main thread | 1788 over 30.0 s | 59.57 fps | 7 (max 116.7 ms) | 0 | 30.0 s |
| visionOS Simulator, 45 s, 2048x1366 | 106 | 2.3 fps | | 2611 | 45.0 s, 0 overruns |

- The simulator has no hardware HEVC encoder, so its software encoder cannot keep 60 Hz at 2048x1366; it is a functional check only (file structure, orientation, 3:2 scaling, colour, audio, Photos). The Vision Pro has a hardware HEVC encoder; device numbers are not measured yet.
- The remaining long intervals on macOS are the app's own render stalls on the main thread (they appear as "Slow Mac frame" with or without recording, for example 69 ms at a picture reveal), not the recorder.
- File check (ffprobe): `hevc` 2048x1366 bt709, `pcm_s24le` 48 kHz stereo; peak -1.15 dBFS, RMS -15.9 dB on a Lo-Fi section, matching the master's ceiling.
- The Photos step was checked in the simulator after `xcrun simctl privacy <udid> grant photos-add com.saygoodnight.Liminal` ("Recording added to Photos").

## Testing

`-LiminalRecordAt <start>,<seconds>` starts a recording `<start>` seconds after playback is ready and stops it `<seconds>` later, keeping the file without the Photos step (no permission prompt during automation). Add `,photos` to include the Photos step. The flag is in `DebugLaunchOptions.blocksImageGeneration`, so it never spends Gemini budget. Example:

```sh
open Liminal.app --args -LiminalAutoPlay YES -audio.musicMode lofi -archive.enabled YES -LiminalImageSource api -LiminalRecordAt 5,60
```

Read the `Recording finished:` log line for frame and drop counts. In the visionOS Simulator the file is in the app's data container under `Documents/Recordings`.
