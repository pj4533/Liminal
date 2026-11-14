# Final QA of feature/finish (decisions)

This is the end-to-end check before merge, run in the visionOS Simulator (fresh install) and on macOS. Screenshots and logs were reviewed by eye.

## Results
- **Fresh install (visionOS):** after uninstalling and reinstalling, the app launched with 0 cached images and every control was readable with no truncation. Play started the music engine (`🎵 Engine started`) and real Gemini generation (`✅ gemini-3.1-flash-image 2528x1696 ... in 13.4s`). Enter Dome showed vivid imagery with effects, and Exit Dome closed it. With `-LiminalTestPattern`, the orientation card's arrow points up in the dome.
- **Controls:** each one was changed in the Simulator and checked in the screenshot, in the persisted defaults (`audio.style`, `audio.notes`, `audio.reverb`, `audio.delay`, `audio.scale`, `visual.syncToMusic`) and, where there is one, in the log:
  - Style: Drift, then Glass, then Garden.
  - Density 50% to 83%, Space 50% to 28%, Echo 50% to 72%.
  - Scale: pinned to Dorian (`🎼 Scale: Dorian`).
  - Sync visuals to music: when turned off, SYNC `a=` faded from 1.00 to 0.00 and every uniform ratio returned to x1.00. When turned back on, the amount resumed.
  - Clear All Images: the confirmation read "Delete all 12 images (42.1 MB)?". After confirming, the log showed `cleared 13 images (45214114 bytes)`. ImageStore held 0 files about 1.5 s later, the UI read "0 cached images, Zero KB", and generation restarted.
  - Reset All Settings: everything returned to its default.
- **Coupling:** the SYNC lines show pulse, bloom, vibrance and chromatic moving with the music. The mood is sent for the first image and again on each crossfade (`imageDidChange=true`), and activity is sent as well. Both platforms showed this.
- **Perf (visionOS Simulator, 30 s live, not frozen):** 81.8 fps, p95 frame interval 12.3 ms, GPU mean 0.168 ms, GPU p95 0.279 ms, GPU max 0.60 ms, 1.83 dropped frames per 5 s. This is in line with the earlier ~77-82 fps and ~0.17 ms.
- **macOS:** the app launched and Play started the engine, VisualEngine and Gemini generation. Imagery is upright and vibrant, and the SYNC and mood lines appear in the log.
- **Unit tests (macOS, LiminalTests):** 35 passed, 0 failed.

## Changes made
**Q1. Coupling and generation log values are now `privacy: .public`.** On macOS, `log stream` redacted `setVisualMood b=<private> w=<private> ...`, the Pipeline style/palette ids and the Gemini latency, so a QA pass could not read them. None of these values are sensitive; the API key is never logged. Only these four lines were changed. Older debug lines (KB, EFFECT and others) are still redacted on macOS. They are shown in full in the Simulator, so I left them alone to keep the diff small.

**Q2. Added `scripts/sim-drag.sh` and `scripts/sim-drag.swift`.** SwiftUI Sliders in the visionOS Simulator ignore a tap and also ignore `peekaboo drag`. They only move when CGEvent `leftMouseDragged` events carry `mouseEventDeltaX/Y`. The helper uses the same 3840x2160 screenshot coordinates as `sim-tap.sh`. The motion is damped and not constant (+160 px moved the value 11-22 points), so check the screenshot after each drag. This is documented in the sim-automation README.

## Observed, not changed
- **macOS Stop button stays blue.** On visionOS it turns red. ui.md U4 specifies red only for visionOS, so this is intentional.
- **Reset All Settings has no confirmation.** It only resets settings, not images. This matches ui.md.
- **With `-LiminalTestPattern` (debug only),** the Playback status read "0 images cached" while Images & Storage read "1 cached image". On a normal launch the two counts agreed (4/4, 12/12), so this only affects the debug flag.
- **`🎧 visionOS audio: requested=0.100s, granted=0.085s ⚠️ MISMATCH`** is an informational log line from the Simulator's audio session. Audio started normally.
