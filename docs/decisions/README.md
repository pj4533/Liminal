# Decision docs index

Each workstream has a decision log with the reasons (what, why, alternatives, numbers). This index gives a one-line summary and the main items worth reviewing first. Plans that preceded the decisions are in `docs/plans/`.

| Doc | Summary |
|-----|---------|
| [performance.md](performance.md) | visionOS render path cut from 3 command buffers to one MRT stereo pass, direct-to-drawable, CPU dome breathing, shader ALU savings; 2048x2048 kept |
| [images.md](images.md) | New Gemini image pipeline: gemini-nano-banana-2.1 (latest model, D35) at 3:2 2K, spending cap (D34), style x subject x transformation x palette prompts, Clear All Images, cache epoch bump |
| [music.md](music.md) | Three-voice engine replaced by an eight-layer generative engine with scenes, drifting key and mode, four styles, off-main conductor; then reworked to be calm and relaxing after listening feedback (D91-D106) |
| [vibrance.md](vibrance.md) | Color-loss fix: correct visionOS sRGB encoding, real feedback on visionOS, chroma-preserving blends, final vibrance stage, per-image factor |
| [orientation.md](orientation.md) | One image orientation convention (row 0 = top), removed two cancelling flips, 3:2 crop, 112.5 x 75 degree dome, test-card debug flags |
| [av-coupling.md](av-coupling.md) | Music drives clamped visual uniforms and ghost bursts; each image sends a mood to the music; "Sync visuals to music" toggle (C1-C14, I1-I12) |
| [ui.md](ui.md) | Control UI redesign on both platforms: shared components, four sections, 1240x800 visionOS window, no truncation, new sim tap coordinates |
| [effects-balance.md](effects-balance.md) | Effects made images unrecognisable: measured per-effect damage, slow clarity cycle, fresh-image hold, strain budget (water first, radial masked off the centre), "Effect intensity" setting (E1-E14; implementation pending) |
| [final-qa.md](final-qa.md) | End-to-end QA of the merged branch on a fresh visionOS install and macOS; sim-drag helper, public log values |

## Please review (top items per workstream)

### Performance
- The numbers are from the visionOS Simulator (host Mac GPU) and a Mac-GPU bench; nothing has been measured on a real Vision Pro. Check frame times on device.
- Round 2 shader optimizations are kept even though one (noise double-angle, 911eb7e) is slightly below the 35 dB parity rule on 2 scenarios (32.6 and 34.5 dB; waived, see its entry).
- Render target stays 2048x2048 per eye; "dropped" experiments are listed in the doc if you want to revisit any.

### Images
- Spend: pacing keeps 2 images pending, but 2K Gemini images cost more than before. Do you want an hourly cap setting?
- Another provider (Flux, gpt-image, Midjourney) was not tested; revisit only if you want more style control (D31).
- Teal skew and `studioProduct` frequency in the prompt mix may want tuning (D32). First launch deletes old cached images (cacheEpoch 2, D14).

### Music
- Key decisions: D3/D4 conductor off MainActor, D30/D31 "Auto" scale lets the key drift unless a scale is pinned, D64 four styles, D70/D72 session curve, D89 brightness soft knee.
- Calm redesign (D91-D106), after feedback that the bells and tinks were abrasive: drone and pad kept; drips, keys, pluck, grains and air re-voiced as soft, slow, filtered and mostly reverb; dark 8 s reverb, shimmer replaced by a dark halo, 7 kHz master low-pass; longer scenes, fewer events. Gates in `scripts/music-criteria.json` now measure calm (old ones kept as `music-criteria-legacy.json`).
- Watch items: the pad's 'bloom' scene is now the brightest moment; D106 lowered the dark-limit gate to 200 Hz for the Deep style. Listen for taste, not just metrics.

### Vibrance
- No effect amount was reduced and nothing was removed; vibrance is a final stage (V4) plus a per-image factor (V5). Check that the saturation boost (+26.8% mean) suits your taste.
- Open (V8): the encoding fix and feedback binding are verified in the Simulator only; check on a device.

### Orientation
- Verified upright on all paths with a test card, but only in the Simulator and on macOS; confirm on a device.
- The dome arc changed from 110 to 112.5 degrees so that 3:2 is undistorted (O6); sources are centre-cropped to 3:2, so image edges are cut.

### AV coupling
- I10: the note-glow attack is 90 ms (plan: 60 ms) to stay under the 5% flicker-band limit. All other amounts are the plan's starting values; tune with `-LiminalSyncStrength`.
- I9/C6/C11: visionOS gains a slow hue drift while sync is on, and the toggle gates music-to-visuals only (the music still hears the images).
- Only 10 of 17 synthetic image changes produced a chord change within 1 s (the conductor skips it when the chord is under 8 s old).

### UI
- U4/U5: macOS Stop stays blue, visionOS turns red; destructive buttons use a red icon with plain text for legibility on glass. Reset All Settings has no confirmation.
- The visionOS settings sheet is gone (everything lives in the 1240x800 window); check the layout in a real headset.
- Simulator tap coordinates changed (see ui.md and `scripts/sim-tap.sh`).

### Final QA
- Remaining observations, not changed: older macOS debug lines still show as `<private>` in `log stream`; the Playback status can say "0 images cached" in test-pattern-only mode; a harmless "audio requested=0.100s granted=0.085s MISMATCH" line appears in the Simulator.
