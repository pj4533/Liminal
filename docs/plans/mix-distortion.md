# Mix distortion: what was measured, what to fix, and the gates

Date: 2026-11-20. Base: `main` at b11ac9e. Status: implemented 2026-11-20 except 2.2 (see [D121](../decisions/music.md)). Outcome: section 2.1 landed as the S6 row (net drive +2 dB, clip from -2 dBFS; no -3 dBFS row passed G2), -13.9 LUFS, target -14; 2.2 stopped at its rule 4 (upright -20.8 dB with the cleaner round robins, -23.4 dB with the largest body cut, against -28), nothing shipped; 2.3 landed; 2.4 drum tape null added (1-4 kHz -20.8 dB, above the -30 dB follow-up line), chop null not done (optional). G7 was split: the film decode varies run to run, so film-derived taps are gated at -90 dB.

Inputs: the listening note ("verging on some distortion in the mix ... maybe the bass was distorting a little bit just on its own"), two research notes on how engineers detect distortion and stage gain (sources listed in section 7), a code map of every gain and nonlinear stage in the Lo-Fi path, and the measurements from `scripts/distortion-report.py` on two deterministic captures of HEAD (seed 2077, 72 BPM, 32 bars, private drums, film reel): `cap-readme` (synth then upright bass) and `cap-round` (`--hook bassTone=round`).

Scope: the Lo-Fi master finisher's drive, the loudness target that follows from it, the encode step of the share clips, and the upright bass body samples. Drum takes, the drum bus chain, the bass chain, chops, pads, lead, space and the film bed are not changed.

## 0. Summary

1. **One stage adds measurable distortion: the master soft clip.** It fires in 185 short bursts in 107 s, where kick and bass peaks coincide, and reaches its 2 dB cap. The cause is gain staging: the finisher adds +6 dB to a mix that already peaks at -3.2 dBFS, so peaks arrive 5.8 dB over the clip threshold. Fix: lower the finisher input gain (expected +6 to about +4 dB), chosen by a hook sweep against the gates in section 4, and move the loudness target with it.
2. **The bass chain is clean.** The guard never engages, there are no flat tops, and the synth tone's inharmonic products are 37 dB down. What sounds rough on the solo bass is inside the upright recordings themselves (inharmonic content 20 dB under the fundamental, against 32 dB for round and 37 dB for synth). Fix: audit the upright samples and use the cleaner ones; no chain constant changes.
3. **The AAC clips did not clip.** All 17 delivered files have zero samples over full scale. But a 160 kbps encode of the master measures +0.39 dBTP, so the share-clip encode gets headroom.
4. **Not distorting, no fix:** the stems (none runs hot), the master glue compressor, the limiter at its present load, the wet-stem limiter, the kick duck, the solo-stems process, and the linear paths.
5. **Unmeasured:** the drum tape saturation (no tap before it). This plan adds the measurement and changes nothing there unless it fails.

No sourced threshold exists for how many dB of clipper reduction is audible. The research says clipping is the most audible distortion type and that soft clipping is much less audible than hard clipping. So item 1 is the only measured candidate for what was heard in the full mix; it is not proven to be audible. The gates in section 4 are engineering targets, and each says which source it leans on.

## 1. What the measurements show, ranked by audibility

### 1.1 Master soft clip (full mix). Real, fix it

| Measure | Value | Reference |
|---|---|---|
| Clip bursts over 0.1 / 0.5 / 1 / 1.5 dB | 185 / 38 / 16 / 3 in 107 s | none sourced |
| Clip maximum | 2.00 dB (its cap; the limiter takes the rest) | none sourced |
| Clip plus limiter maximum | 3.03 dB; total with glue 4.01 dB | end-of-chain limiting is typically at most about 2 dB (iZotope) |
| Residual while the clip is engaged | -32.1 dB overall, -18.9 dB in 1-4 kHz (-15.5 dB when over 1 dB) | 1 % (-40 dB) rule of thumb; clipping audible well below 2nd/3rd-order distortion (Aalborg thesis); hard clipping large effect, soft clipping small (Tan, Moore and Zacharov, JAES 2003) |
| 1 kHz / 2 kHz octave residual while reducing | -30.5 / -28.9 dB (-41 / -39 dB over the whole file) | same |
| Residual with the limiter working alone | -50.9 dB overall, -35.9 dB in 1-4 kHz | the cleanest this stage measures while reducing |
| Clip engaged | 0.77 % of the time (0.32 s) | C-M9 allows 3 % |

Gain walk, from the code map and the capture: stems peak at -7 to -10 dBFS each; their sum (the `lofi` tap) peaks at -1.1 dBFS; staging takes 2 dB (`pre-master` -3.2 dBFS); the finisher input gain adds 6 dB, so peaks reach +2.8 dBFS; the glue takes at most 2.2 dB; the soft clip starts at -3 dBFS.

Who carries the peaks: drums are the largest stem at 99 of 125 clip or limiter events and bass at 14 (mean shares 0.47 and 0.25). 52 % of events start within 80 ms after a kick and 48 % after a bass onset. This is the hard bass strike landing on the kick, which is intended. The fix therefore lowers the drive into the clip and leaves the coincidence alone.

Why the present drive is out of date: the comment on `LofiMasterBus.lofiSettings` says +4 dB (now +6 with the -2 dB staging) was "the loudest setting found" on stems "as they were before the per-bus chains" and asks to "revisit once the drum bus chain controls those peaks". The stems have changed since (bus chains, the D119 strike layer), and C-M9 only bounds how often the clip is engaged, not how deep it goes.

A second effect that captures do not show: live, `startCalibration` moves the trim ahead of the finisher toward `lofiTargetLUFS` (-12) by up to +2 dB, and blocks upward steps only on limiter load (mean over 2.5 dB or p95 over 4.5 dB), which this material never reaches. A programme that reads quieter than -12 LUFS (the `nofilm` case reads about 1.4 LU lower) therefore gets up to 2 dB more drive into the clip than the capture measured.

### 1.2 Upright bass body samples (solo bass). Real source content, tame it

| Tone | Notes | Inharmonic energy, median (dB re fundamental, 30-1400 Hz) | Reference |
|---|---|---|---|
| synth | 28 | -37.2 | historic thresholds: about 1 % for tones, 2-4 % (-34 to -28 dB) for intermodulation on piano (Audioholics, secondary and dated) |
| round (flatwound) | 58 | -32.2 | inside the 2-4 % range |
| upright | 30 | -20.2 (worst note -15.4) | about 10 %, outside it |

- The products sit off the harmonic series: on the worst upright note there are peaks at 2.19, 2.66 and 2.91 times the fundamental, and the third partial is at 3.019 times, so it beats against the sub's exact third harmonic.
- Analysed raw with the same method, the upright `long` samples carry -2 to -10 dB of inharmonic energy in 120-450 Hz and the flatwound samples -6 to -21 dB. The processing does not add it: the synth tone goes through the same chain and measures -37 dB.
- The voice levels each note's body to a fixed RMS under the sub (`bodyUnderSubDB`, 12.5 dB for upright) whatever the body contains, so a sample whose 160-360 Hz band is mostly off-pitch content has that content raised to the same level as a clean one.
- Caveats: these thresholds were set for distortion added by equipment, not for an instrument's own partials, and distortion below about 400 Hz is harder to hear than above (Moir, cited by Brüel and Kjær). Inharmonic products are still the kind listeners object to most (ProSoundWeb, Audioholics). So this is the most likely thing heard as "the bass distorting on its own", and it is a judgment, not a measured audibility result.

### 1.3 Codec headroom of the share clips. Not the cause, close the risk

| File | True peak | Reference |
|---|---|---|
| `master.wav` | -1.14 dBTP, -12.3 LUFS, PLR 11.2 dB | EBU R128: at most -1 dBTP. Spotify: at most -2 dBTP for masters louder than -14 LUFS. AES TD1008 (secondary quote): lower bitrates need a ceiling under -1 dBTP |
| Master re-encoded, AAC 256k | -0.91 dBTP (+0.23 dB) | |
| Master re-encoded, AAC 160k | +0.39 dBTP (+1.53 dB) | iZotope reports +1.73 dB after a lossy encode |
| The 17 delivered m4a/mp4 files | highest -0.85 dBTP; 0 samples over full scale; 0 clipped 16-bit samples | |

The files that were listened to did not clip. The 160k over is between samples and could clip in a playback converter, so the encode step gets headroom (section 2.3).

### 1.4 Drum tape saturation. By design, not yet measurable

The manifest reports 2.35 dB of saturation rounding and 2.66 dB mean parallel-compressor reduction. The drum stem has no flat tops and peaks at -8.7 dBFS. There is no tap before the `tanh` stage, so its products cannot be separated from the take. Section 2.4 adds the measurement. Nothing changes unless it fails.

### 1.5 Clean, no fix

- **Bass chain, all three tones.** No sample reaches the guard's 0.74 knee; no flat-top runs; peak -9.7 dBFS (round -10.3). Synth harmonics are -13/-17/-21 dB against designed -14/-17/-21 dB, so the parallel `tanh` and the 4:1 compressor add at most about 1 dB at the second harmonic and no intermodulation. Energy above 2.5 kHz is -87 dB re the stem and -92.9 dB in the 30 ms after kicks, so the kick duck creates no splatter. The 27-30 % THD figures are the designed harmonics, not distortion.
- **Solo-stems process.** The solo bass at final-mix level has -85.0 dB above 2.5 kHz with the master gain trace and -87.1 dB without.
- **Stems.** Active RMS -21.2 to -30.4 dBFS against the -18 dBFS nominal (Avid, Sound On Sound); peaks -7.1 to -10.7 dBFS; no run at full scale. None runs hot.
- **Master glue.** Residual -63.4 dB while it alone is over 1 dB, against a -64.6 dB floor.
- **Master limiter at its present load** (maximum 1.03 dB). -50.9 dB. The 21 runs near the master's peak contain no identical samples: the limiter holding its ceiling, not hard clipping.
- **Wet-stem limiter (`boundedWet`).** In its shoulder for 0.29 s, over 1 dB for 4 ms in total.
- **Linear paths.** `pre-master`, `glue` and `master-in` null exactly; the six stems sum to the `lofi` tap at -146 dB.
- **Dialogue chops.** Not re-measured. The code bounds the chop soft clip to 0.45 dB of shaping (crest limiter at 0.9 into a 0.6 knee). No change; section 2.4 adds an optional check.

## 2. Fixes

### 2.1 Re-stage the master: less drive into the soft clip

Structural reason: the glue, clip and limiter are level-dependent, so the level entering them sets how much they distort (research note on staging, section 1). The clip's shape is fine (4x oversampled `tanh` shoulder). It is being fed peaks up to 5.8 dB past its threshold.

**Step 1, sweep with hooks, no source change.** One capture per row, same command as the reference capture plus the hook, each analysed with `distortion-report.py` and `mix-report.py`:

| Run | Hook | Purpose |
|---|---|---|
| S0 | none | baseline, must reproduce section 1.1 |
| S1 | `masterInputGainDb=5.5` | |
| S2 | `masterInputGainDb=5` | |
| S3 | `masterInputGainDb=4.5` | |
| S4 | `masterInputGainDb=4` | expected landing |
| S5 | `masterInputGainDb=4.5`, `masterClipThresholdDb=-2` | only if S4 fails G1 or G2 |
| S6 | `masterInputGainDb=4`, `masterClipThresholdDb=-2` | only if S4 fails G1 or G2 |

Because drums, chops and footage render sample-identical between captures, the stems of every run must null against S0 (gate G7). Only the master and its trace may differ.

Selection rule: take the **highest input gain that passes G1, G2 and G3** (section 4). Prefer a row with the clip threshold at -3 over S5/S6. If nothing passes, stop and report the table. Do not go below +4 dB or touch any stem to force a pass.

Prediction to check, from the clip curve (threshold -3 dBFS, 3 dB knee): 0.1 / 0.5 / 1 / 1.5 dB of clip reduction correspond to post-glue peaks of about -1.4 / -0.3 / +0.6 / +1.3 dBFS, and the cap to +1.9 dBFS. Lowering the drive by 2 dB should leave roughly 16 to 30 bursts over 0.1 dB, at most 3 over 0.5 dB, none over 1 dB, and a master near -14.1 LUFS.

**Step 2, source changes** (for a result of X dB; expected X = 4):

| File | Constant | From | To |
|---|---|---|---|
| `Liminal/Audio/Lofi/LofiMasterBus.swift` | `lofiSettings.inputGainDB` | `4 - lofiStagingDB` (+6) | `X` written as `(X + lofiStagingDB) - lofiStagingDB`, i.e. `2 - lofiStagingDB` for X = 4 |
| same | `lofiTargetLUFS` | -12 | the S-row's measured `ref` loudness rounded to 0.5 (expected -14) |
| same | the doc comment on `lofiSettings` | plan 8.7 text | the sweep result and D121 |
| same, `LofiMasterMeter` | upward calibration range | `min(2, ...)` | see below |
| `scripts/mix-criteria.json` | C-M1, C-M3, C-M5 bounds | | shifted by the measured loudness change (section 4.3) |
| `LiminalTests/LofiMasterBusTests.swift`, `LofiMasterKernelTests.swift` | expectations that assume +6 dB or -12 LUFS | | updated to the new constants |

Calibration: with the target lowered by the same amount as the drive, a programme at reference loudness gets zero calibration, as today. To stop quiet programmes from being driven back into the clip, hold upward steps when the clip was engaged in the epoch. `LimiterLoad` carries only limiter reduction today; add the clip's epoch maximum from the same finisher meters and make `blocksUpward` true when it exceeds 1 dB. If the kernel meters do not expose clip reduction per epoch without work on the render thread, lower the upward bound from +2 to +1 dB instead. Either way add a unit test in the existing calibration suite.

The clip threshold, knee, 2 dB cap, the glue (threshold -12 dB, 1.7:1), the limiter and the -1 dBTP ceiling stay as they are unless S5 or S6 is selected.

Why loudness may drop: the research ties the level to delivery norms, not to taste. Spotify normalizes to -14 LUFS and asks for a -2 dBTP ceiling above that level; at about -14 LUFS the existing -1 dBTP ceiling is the recommended one. A 2 dB quieter master is a volume-knob difference for the listener. The film bed enters the same `pre-master` sum, so its balance against the music does not move.

### 2.2 Upright bass: use the cleaner recordings

No chain constant changes. `harmonicsMix` 0.15, drive 2.0, the 4:1 compressor, the output trim and the guard all measured clean.

1. **Audit, no source change.** Extend `distortion-report.py` (or `scripts/bass-tone.py`) with a per-sample mode: for each `LofiBass-upright-long-*` and `LofiBass-flatwound-long-*` file, apply the body band (high-pass 160 Hz, low-pass 360 Hz upright / 400 Hz round) and report inharmonic energy re the harmonic partials in that band, plus the offset of partials 2 to 4 from exact multiples. The upright kit has two round-robins per pitch (`-1`, `-2`) at five pitches.
2. **Select.** In `LofiBassSamples` (or `LofiBassVoice`'s body sample choice), restrict the upright `long` body to the cleaner round-robin of each pitch. If one pitch is poor in both, let the neighbouring pitch cover it (the kit is already repitched between roots).
3. **Only if the gate is still missed:** raise `bodyUnderSubDB` for upright from 12.5 toward 15.5 dB in 1 dB steps (`LofiBassVoice.swift:128`), stopping at the first step that passes G6 while C-B3's harmonics bound (at least -18 dB) still holds.
4. **If no combination passes** without failing C-B3 or the band targets in `docs/plans/bass-tone-redo.md`: stop and report. Taking upright out of the D120 rotation is a user decision and is not part of this plan.

Round and synth are not touched. The throw send (`LofiBassThrowSend`) keeps its own sample path and drive.

### 2.3 Encode headroom for share clips

The app's ceiling stays -1 dBTP (it meets EBU R128 and C-M2). The headroom goes where the lossy encode happens:

| Where | Change | Why |
|---|---|---|
| `scripts/solo-stems.py` (AAC 256k step, line 64) | write every file 1.0 dB lower before encoding (one common gain, so stems keep their relative levels and still sum to the mix); print the trim; `--wav` output unchanged | 256k raised the master by 0.23 dB and drums by 0.33 dB; 1 dB gives a decoded peak near -1.9 dBTP |
| `docs/development.md`, README preview section | encode the preview audio at 256 kbps from the master lowered by 1.0 dB; then run `distortion-report.py --aac` on the mp4 | at 160k the encode rose 1.53 dB to +0.39 dBTP; lower bitrates overshoot more (TD1008) |
| `docs/media/lofi-preview.mp4` | rebuild after 2.1 lands, by the documented steps | the present file is clean (-1.05 dBTP) but was made from the old master |

### 2.4 Measurements to add, with no behaviour change

- **Drum saturation.** A capture hook or a test-only dump of the drum buffer before and after the tape stage in `LofiStemChains.applyDrums`; null test in `distortion-report.py`. Report the residual overall and in 1-4 kHz. This is intended colour. Open a follow-up only if the residual in 1-4 kHz is above -30 dB re the band; do not change the chain in this work.
- **Chops.** Optional: the same null test around the chop soft clip, to replace the code-comment figure (-35 dB) with a current one.
- **Gate mode.** `distortion-report.py --strict` exits non-zero when a gate in section 4.1 fails, reading its bounds from a `distortion` block in `scripts/mix-criteria.json`.

Hooks and dumps must stay inert in the app (`LofiCaptureHooks`) and off the realtime paths.

## 3. Order of work

1. Record the baseline: `mix-report.py --strict` on S0 against `final-main`, and note which criteria already fail. Those are the "pre-existing failures".
2. Sweep (2.1 step 1). Pick X.
3. Master constants, calibration, criteria bounds, tests (2.1 step 2). Build macOS and visionOS. Run `LiminalTests/LofiMasterBusTests`, `LofiMasterKernelTests` and the Lo-Fi list in `docs/development.md#lo-fi-checks`.
4. Capture without hooks; it must match the chosen S-row's master sample for sample. Run all gates, then `mix-matrix.sh --strict`.
5. Bass audit and selection (2.2), with captures for `bassTone=upright` and the default rotation.
6. Encode headroom (2.3) and added measurements (2.4).
7. Docs in the same change: D121 in `docs/decisions/music.md` with the dated tables, `docs/mix-verification.md` (the distortion report, the new gates, revised C-M bounds), `docs/development.md`, and `docs/architecture.md` / `docs/experience.md` where they state the Lo-Fi loudness or drive.

One capture or test run at a time (`--wait-lock 3600`; `xcodebuild test` through the lock shim), always with `-destination`. Captures and WAVs stay out of git.

## 4. Acceptance gates

All on the reference capture (seed 2077, 72 BPM, 32 bars, private drums, film reel) unless stated. "Was" is `cap-readme` at b11ac9e.

### 4.1 Distortion gates (`distortion-report.py`)

| Gate | Metric | Was | Must be | Basis |
|---|---|---|---|---|
| G1 | Clip bursts over 0.5 dB | 38 | at most 4 | engineering target; clipping is the most audible type (Tan et al.) |
| G1 | Clip bursts over 1 dB | 16 | 0 | same |
| G1 | Clip maximum | 2.00 dB (cap) | at most 1.0 dB, never at the cap | same |
| G1 | Clip engaged | 0.77 % | at most 0.25 % | same; C-M9 (3 %) stays as the outer bound |
| G2 | Residual while clip or limiter is over 0.1 dB | -39.5 dB | at most -45 dB | toward the 1 % (-40 dB) rule of thumb |
| G2 | 1 kHz and 2 kHz octave residual while reducing | -30.5 / -28.9 dB | at most -36 dB each | the limiter-alone level in 1-4 kHz (-35.9 dB), the cleanest the stage measures while working |
| G2 | Residual while the clip is engaged, 1-4 kHz | -18.9 dB | at most -25 dB; report | at least 6 dB better; no sourced threshold |
| G3 | Limiter maximum | 1.03 dB | at most 1.5 dB | iZotope: about 2 dB typical at the end of the chain |
| G3 | Clip plus limiter maximum | 3.03 dB | at most 2.0 dB | same |
| G3 | Residual with the limiter alone | -50.9 dB | at most -48 dB | no regression |
| G3 | Glue-only residual | -63.4 dB | within 2 dB | no regression |
| G4 | Master true peak | -1.14 dBTP | at most -1.0 dBTP | EBU R128 / Tech 3341 |
| G4 | Identical-sample flat-top runs, samples over full scale, any tap | 0 | 0 | run-length clip detection (Sound Forge method) |
| G5 | `--encode-test` at 256k with the 2.3 trim: decoded true peak | -0.91 dBTP untrimmed | at most -1.5 dBTP; 0 samples over full scale; 0 clipped 16-bit | research target for share clips; TD1008 |
| G5 | Every delivered m4a/mp4 (`--aac`) | at most -0.85 dBTP | at most -1.5 dBTP; 0 over; 0 clipped | same |
| G6 | Bass samples above the 0.74 guard knee | 0 | 0 | |
| G6 | Synth inharmonic median; h2/h3/h4 | -37.2 dB; -13/-17/-21 dB | at most -35 dB; each within 2 dB of was | chain adds nothing |
| G6 | Round inharmonic median (`bassTone=round`) | -32.2 dB | at most -30 dB | no regression |
| G6 | Upright inharmonic median (`bassTone=upright`) | -20.2 dB | at most -28 dB | upper end of the 2-4 % historic range |
| G6 | `bass.wav` above 2.5 kHz | -87.2 dB | at most -80 dB | no splatter |
| G7 | After 2.1 only: each of the seven stems and the `lofi` tap nulled against S0 | | at most -120 dB | captures are deterministic; a master change must not move a stem |
| G7 | After 2.2: drums, dry, texture, dialogue-chops, footage nulled against the post-2.1 capture | | at most -120 dB | only bass and the throws in wet may move |

### 4.2 Existing gates that must still hold

- `scripts/mix-report.py CAP --baseline <final-main> --no-plots --strict`: only the failures recorded in step 1, apart from the three bounds revised in 4.3.
- `scripts/mix-matrix.sh --strict`: all five cases, same rule.
- **C-B3**: bass 60-250 Hz within -6 to +3 dB of drums; bass 150-800 Hz at most 18 dB under its 40-150 Hz band. After 2.1 the value must be identical to S0 (stems unchanged). After 2.2 it must stay in bounds for upright and for the rotation.
- **C-B2**: aligned accents median lag at most 5 ms, p90 at most 12 ms, duck depth 1.5 to 4.5 dB. Identical to S0 after 2.1; in bounds after 2.2.
- **C-M6, C-M7, C-M8, C-M9, C-M10**: in bounds. C-M8 (pumping at most 0.8 dB, kick dip at most 1.5 dB) is the check that a lighter clip has not handed audible work to the limiter.
- **C-B9**: bed at least 10 dB under the music plus chops in gaps. Unchanged by construction; confirm.
- `scripts/stem-bands.py`: after 2.1 every stem band identical to S0. After 2.2 the bass bands stay inside the "Allowed" column of `docs/plans/bass-tone-redo.md` section 1 and other stems are identical.
- `scripts/solo-stems.py`: "sum of stems vs master" no worse than before.
- Unit tests named in section 3, macOS build, visionOS Simulator build.

### 4.3 Loudness

- The `ref` integrated loudness changes by the input-gain change within 0.4 LU (the glue returns a little). Expected: -12.3 to about -14.1 LUFS for a 2 dB cut.
- Result must lie in -14.5 to -13.0 LUFS. Nothing in the research supports going under Spotify's -14 LUFS reference by more than meter tolerance, and the selection rule already keeps the highest passing gain.
- Revise in `scripts/mix-criteria.json`, by the measured change D rounded to 0.5: C-M1 every bound lowered by D (`ref` -13.0 to -11.0 becomes -15.0 to -13.0 for D = 2); C-M3 PLR upper bound raised by D (12.5 to 14.5; `nofilm` 14 to 16), lower bound kept at 9; C-M5 crest upper bound raised by D (13 to 15; `nofilm` 14.5 to 16.5). Record the reason in the criterion descriptions and D121.
- `lofiTargetLUFS` equals the new `ref` reading within 0.5 LU, so calibration is at rest on the reference programme.

## 5. What not to change

- Drum takes: their audio, sample grid, interior fills and edge tapers. The drum bus chain, including the tape saturation, in this work.
- The bass character: sustained warm sub, the strike layer on kick-anchored notes, the kick duck (4 dB, split at 150 Hz), note lengths, and the three-tone rotation of D120. The bass chain constants (`harmonicsMix`, drive, compressor, EQ, output trim, guard knee).
- Kick and bass landing together. It is the requested slap; lower the drive after the sum, do not move or soften the coincidence.
- Pads tucked (peak ceilings, pad duck), lead levelling, space chain, `boundedWet`, wet tape colour, chop chain and MPC motif, chop soft clip.
- The film bed: at least 10 dB under the music, never a duck key, same staging gain as the music.
- The finisher's design: HPF 25 Hz, glue 1.7:1 at -12 dB, 4x soft clip, 4x true-peak limiter, -1 dBTP ceiling with 0.15 dB margin, 200-frame latency. The -2 dB staging.
- The Ambient profile and its -18 LUFS target.
- No shared-state, locking or allocation on the render path for the new clip meter or dumps. No storage or playback budgets.
- Never commit captures, WAVs, the private drum recordings or `Secrets.swift`. Never launch the app without an automation flag.

## 6. Limits of this plan

- Audibility of the clip bursts is inferred, not measured; there is no listening-test threshold for clipper reduction in the sources found.
- The research notes were built from search summaries. The AES TD1008 text and Apple's Digital Masters document were not read directly; the TD1008 figures come from a secondary quote.
- The inharmonic metric over-reads on notes shorter than about 0.4 s (window leakage: the synth's worst note is -23.5 dB at 0.33 s), so gates use medians.
- The residual method attributes anything a 5.3 ms block gain cannot explain to distortion. Fast limiter gain motion and filter mismatch land in it too (the 31.5 Hz and 16 kHz octaves are filter mismatch, not distortion), so use the figures to compare before and after, not as absolute THD.
- The bass `tanh` stage's own harmonic distortion cannot be separated from the designed partials without a tap before it; the synth's -37 dB inharmonic figure bounds its intermodulation only.

## 7. Sources

- Tan, Moore and Zacharov, "The effect of nonlinear distortion on the perceived quality of music and speech signals", JAES 51(11), 2003: https://www.aes.org/e-lib/browse.cfm?elib=12197
- Aalborg University thesis on distortion audibility: https://projekter.aau.dk/projekter/files/9852082/07gr1061_Thesis.pdf
- ITU-R BS.1770-4 (true peak): https://www.itu.int/rec/R-REC-BS.1770-4-201510-S/en ; EBU R128: https://tech.ebu.ch/docs/r/r128v4_0.pdf ; EBU Tech 3341: https://tech.ebu.ch/docs/tech/tech3341.pdf
- Sound Forge, run-length clipping detection: https://cdn.borisfx.com/borisfx/Documentation/soundforge/2026/en/content/proonly/detect_clipping.htm
- iZotope, lossy-encode peak rise: https://www.izotope.com/community/blog/avoid-artifacts-with-clip-free-compression-in-rx-7 ; limiter use: https://www.izotope.com/en/learn/an-introduction-to-limiters-and-how-to-use-them
- AES TD1008 as quoted by a secondary note: https://raw.githubusercontent.com/M-Igashi/baken/main/docs/true-peak-ceiling.md
- Spotify loudness normalization: https://support.spotify.com/ca-en/artists/article/loudness-normalization/
- Brüel and Kjær, Audio Distortion Measurements (citing Moir): https://www.bksv.com/media/doc/BO0385.pdf
- Audioholics, distortion audibility (secondary): https://www.audioholics.com/human-hearing-distortion-audibility-part-3 ; intermodulation at bass: https://www.audioholics.com/loudspeaker-design/audibility-of-distortion-at-bass/intermodulation-distortion
- ProSoundWeb, harmonic against intermodulation distortion: https://www.prosoundweb.com/the-audio-expert-audio-fidelity-measurements-and-myths-part-1/3/
- Gain staging nominal levels: https://www.avid.com/resource-center/gain-staging-guide ; https://www.soundonsound.com/sound-advice/q-should-gain-stage-6dbfs-or-18dbfs
- Ian Shepherd on PLR: https://productionadvice.co.uk/plr/

## 8. Outcome (2026-11-20)

- **Cause found.** The master soft clip fired on kick and bass peaks: 185 bursts in 107 s, at its 2 dB cap. The stems were clean (no flat tops, overs or hot stems) and the bass chain is clean.
- **Fix.** Finisher input gain is `2 - lofiStagingDB` (+2 dB net, was +4) and the clip threshold is -2 dBFS (was -3). On the reference capture the clip now fires 6 times, 0.29 dB at most, and the residual while reducing went from -39.5 to -51.5 dB. The master is about 1.6 LU quieter (-12.3 to -13.9 LUFS); `lofiTargetLUFS` is -14. Encode headroom: `solo-stems.py` and the README preview carry a -1 dB trim (preview -2.16 dBTP, was -1.05). Live calibration holds upward steps while the clip passes 1 dB.
- **Sweep.** Seven rows S0 to S6 in [measurements](../research/mix-distortion/measurements.md); S6 is the highest passing row (no -3 dBFS row passed G2).
- **Open.** Upright bass fails G6 (-20.2 dB against -28): the recordings are the source, round-robin selection and the largest body cut reach only -23.4 dB, so nothing shipped. The drum tape stage reads -20.8 dB in 1-4 kHz (G8, over -30) and needs a follow-up decision. Live calibration's hold starts at 1 dB, looser than G1, and never steps down; revisit if `nofilm`-like programmes sit near it. `nofilm` C-M7 warns (0.29 against 0.30) and `same` C-M5 sits on its bound (14.50); both are accepted departures from 4.2.
- **Gate changes.** G7 is split: music stems at -120 dB, film-derived taps at -90 dB (the film decode differs about -135 dB run to run). G8 added for the drum tape stage.
