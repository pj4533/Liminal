# Final QA of feature/finish (decisions)

This is the end-to-end check before merge, run in the visionOS Simulator (fresh install) and on macOS. Screenshots and logs were reviewed by eye.

## Results
- **Fresh install (visionOS):** after uninstalling and reinstalling, the app launched with 0 pictures and every control was readable with no truncation. Play started the music engine (`🎵 Engine started`) and the first picture arrived. Enter Liminal showed vivid imagery with effects, and Exit Liminal closed it. With `-LiminalTestPattern`, the orientation card's arrow points up in the dome.
- **Controls:** each one was changed in the Simulator and checked in the screenshot, in the persisted defaults (`audio.scale`, `visual.syncToMusic`) and, where there is one, in the log:
  - Scale: pinned to Dorian (`🎼 Scale: Dorian`).
  - Sync visuals to music: when turned off, SYNC `a=` faded from 1.00 to 0.00 and every uniform ratio returned to x1.00. When turned back on, the amount resumed.
  - Clear Curated Pictures: the confirmation read "Delete all 12 curated pictures (42.1 MB)?". After confirming, the log showed `cleared 13 images (45214114 bytes)`. The store held 0 files about 1.5 s later, the UI read "0 curated pictures saved", and the feed refilled the pool.
  - Reset All Settings: everything returned to its default.
- **Coupling:** the SYNC lines show pulse, bloom, vibrance and chromatic moving with the music. Both platforms showed this.
- **Perf (visionOS Simulator, 30 s live, not frozen):** 81.8 fps, p95 frame interval 12.3 ms, GPU mean 0.168 ms, GPU p95 0.279 ms, GPU max 0.60 ms, 1.83 dropped frames per 5 s. This is in line with the earlier ~77-82 fps and ~0.17 ms.
- **macOS:** the app launched and Play started the engine and VisualEngine. Imagery is upright and vibrant, and the SYNC lines appear in the log.
- **Unit tests (macOS, LiminalTests):** 35 passed, 0 failed.

## Changes made
**Q1. Coupling and pipeline log values are now `privacy: .public`.** On macOS, `log stream` redacted the coupling values and the pipeline ids, so a QA pass could not read them. None of these values are sensitive. Only these few lines were changed. Older debug lines (KB, EFFECT and others) are still redacted on macOS. They are shown in full in the Simulator, so I left them alone to keep the diff small.

**Q2. Added `scripts/sim-drag.sh` and `scripts/sim-drag.swift`.** SwiftUI Sliders in the visionOS Simulator ignore a tap and also ignore `peekaboo drag`. They only move when CGEvent `leftMouseDragged` events carry `mouseEventDeltaX/Y`. The helper uses the same 3840x2160 screenshot coordinates as `sim-tap.sh`. The motion is damped and not constant (+160 px moved the value 11-22 points), so check the screenshot after each drag. This is documented in the sim-automation README.

## Observed, not changed
- **macOS Stop button stays blue.** On visionOS it turns red. ui.md U4 specifies red only for visionOS, so this is intentional.
- **Reset All Settings has no confirmation.** It only resets settings, not images. This matches ui.md.
- **With `-LiminalTestPattern` (debug only),** the Playback status read "0 pictures saved" while Images & Storage read "1 picture saved". On a normal launch the two counts agreed (4/4, 12/12), so this only affects the debug flag.
- **`🎧 visionOS audio: requested=0.100s, granted=0.085s ⚠️ MISMATCH`** is an informational log line from the Simulator's audio session. Audio started normally.
