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
| [effects-balance.md](effects-balance.md) | Effects made images unrecognisable: measured per-effect damage, slow clarity cycle, fresh-image hold, strain budget (water first, radial masked off the centre), "Effect intensity" setting (E1-E22; implemented: EffectLook, slider on both platforms; round-1 tuning E23-E26: more colour, rainbow cap; round 2 E27-E30: zoom eases out in wild stretches, more fringing and trails, calmer hue blend at full; final E31-E32: default 0.5 passes blind judging with 100 % recognised and 98.3 % orientation, verified in the visionOS 27.2 Simulator) |
| [transitions.md](transitions.md) | Image transitions: offline transition renderer and objective checks, baseline of the shipped crossfade (start pop, end stop, double exposure when calm), design of 12 styles with per-pixel swap masks, C1 envelopes, a no-repeat director and variable duration (T1-T14); implementation, round 0 measurements and GPU cost (T15-T26); tuning rounds 1-2 with blind judges (T27-T37: Ripple, Melt, Facets, Solarize replace Echo, Embers, Undertow, Depthwash); final check in the visionOS 27.2 Simulator and on macOS with `-LiminalTestImage <directory>` and `-LiminalImageInterval` (T38-T42) |
| [final-qa.md](final-qa.md) | End-to-end QA of the merged branch on a fresh visionOS install and macOS; sim-drag helper, public log values |
| [spatial.md](spatial.md) | One unified immersive mode replaces Dome and Spatial Diorama: 337.5 x 120 degree mirror-wrap shell of three tiles, ML depth as real vertex relief (true stereo and parallax), every effect on it from the one 2048x2048 mono render, ARKit placement, Depth slider; sim-verified at 78.5 fps, device checks open (S1-S18); plan in docs/plans/spatial.md |
| [archive-video.md](archive-video.md) | Archive clip cache and playback, footage compositing, film sound and controls (A1–A25), continuous crossfading footage (A27), beat-scheduled film dialogue (A28–A29), the 12-film pool with two rotating discoveries (A30), and the per-clip cap, pinned-inclusive budget and launch sweep (A31). Current playback uses a 3 GB cache with no clip over 600 MB. |
| [footage-fx.md](footage-fx.md) | Footage interaction modes (built: 17 recipes, F10-F19 shader variants, amounts, weaver, round 0; F20-F22 blind verdicts and tuning round 1: every mode shows the film's figure, Ghost film replaced by Facets; F23-F26 tuning round 2: the film as a shaped region with its own treatment, Poster replaces Palette, glass shader group; F27-F28 final verification: visionOS Simulator run with the weaver choosing, 11 recipes in 19 pieces at 79.4 fps with no slow frame at a piece change, parity 0, GPU 1.00-1.17 of main): offline renderer for moving footage through the app's pre-pass (`shader-bench.sh --footage-seq`, `ffx-clip.sh`) and objective scores (`ffx-check.py`); baseline of the four looks (picture safe, film faint and visible only where the picture is dark); design of carrier x key x drive recipes where the film steers the warp, fringes, trails, hue, bloom (F1-F9). Plan: `docs/plans/footage-fx.md` |

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

### Spatial
- Built only in the visionOS Simulator (Mac GPU); nothing measured on a real Vision Pro. Check real ML depth relief, stereo comfort at Depth 0.6 and 1.0 (is the default right?), M2 frame time and heat at 90 Hz, mirror seams and rear fade, ARKit entry pose.
- The -LiminalShellTextureStereo A/B did not run; if geometry alone reads well, `StereoMaterialBuilder` and the stereo render path can go.
- Known, older than this branch: every image change costs one 65-90 ms main-actor frame (cover-crop, colour stats, upload); a candidate for the transitions workstream.

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

### Effects balance
- Default intensity 0.5: judges recognised 100 % of frames, orientation 98.3 %, trippiness 3.06 of 5. Intensity 1.0 rates 3.90, just under the 4.0 target (E31). Check the look on a real Vision Pro and adjust the slider.
- At 0.25 the music-driven whole-image hue shift is not scaled by intensity, so colour still swings (see Final verification).
- The radial (log-spherical) now appears only in wild stretches and is masked off the centre. The water warp leads at every level.

### Transitions
- 12 styles, picked without a recent repeat and weighted by the effect mood; length 2-4.5 s, capped at 0.2 x the image interval. Watch `tx/highlights.mp4` (session scratchpad) and say which ones you like or dislike.
- Round 2 is not judged blind yet. Five styles still go 0.001-0.009 over the 0.050 smoothness limit (T36).
- Every image change has one long frame in the Simulator dome (pre-existing, T39); check on a Vision Pro.

### Final QA
- Remaining observations, not changed: older macOS debug lines still show as `<private>` in `log stream`; the Playback status can say "0 images cached" in test-pattern-only mode; a harmless "audio requested=0.100s granted=0.085s MISMATCH" line appears in the Simulator.

### Archive footage
- Sound level (default about -42 dBFS, 19 dB under the music), look strengths, and "medical" in the exclusions (A25): your call.
- Nothing measured on a real Vision Pro: 90 Hz pacing, decode cost and heat with footage on.
- The floating screen (A23) is not built.

### Footage interaction modes
- 13 modes where film and effects drive each other plus the 4 plain looks; watch `ffx/highlights.mp4` (session scratchpad, one labelled clip per mode) and say which to keep, louder or drop (Kaleido and Print especially).
- Facets costs 1.17x of main's footage frame (over the +15 % target); two-mode crossfades 1.21-1.23x for a few seconds. Check on a Vision Pro.
- Round-2 clips are not judged blind yet; the share of plain looks (about a quarter to a third) is your call.
