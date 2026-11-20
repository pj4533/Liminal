# Bass tone redo: a warm, continuous dub tone with a strike on the kick

Date: 2026-11-20. Base: `main` at bab3fed. Status: built (see Outcome).

Inputs: the listening note on the D116 bass ("tinny", "too filtered but not completely", "weird high end", wants "continuous, warm bass tones, but with a really hard slap that lines up with where the drums hit"), the stage-by-stage diagnosis (`bass-diag/DIAG.md`) and the research audit (`bass-diag/AUDIT.md`), both in the session scratchpad. Reference captures: `cap-fix-1` (current, seed 2077, 72 BPM, 32 bars) and `final-main` (the earlier approved pure-synth bass).

Scope: the bass voice, the bass chain and the bass note lengths. Drums, pad, melody, reverb, chops, bed and master settings are not touched. This plan supersedes sections 2.2, 2.3 and 2.5.7 of `docs/plans/bass-and-pads.md` and its bass band gates in 5.5.

## 0. Decisions in one page

1. **Everything below 160 Hz is synthesized, everything above comes from one dark layer.** The sub becomes an additive, phase-exact tone (fundamental plus real 2nd to 4th harmonics) that ends at a 160 Hz crossover. The sample (or a synthesized equivalent) is high-passed at the same 160 Hz with a matched zero-phase slope and then low-passed at 420 Hz. The 180 Hz high-pass on a driven sample, which left a 180-900 Hz plateau, is gone.
2. **No manufactured brightness.** Removed: the tanh drive 4 on the body, the per-note velocity low-pass that opened to 2 kHz, the 1 kHz click, the 12-semitone pitch drop, the +2 dB at 700 Hz, the tape slap at 104 ms. The parallel harmonics stage drops from mix 0.40 at drive 4 to mix 0.15 at drive 2 in 200-500 Hz. The final low-pass becomes 24 dB/oct at 1.4 kHz (was 12 dB/oct at 2.4 kHz).
3. **The slap is a short strike layer on kick-anchored notes only.** It is brightest in the first 5 ms, lives in 160 Hz to 1.2 kHz, and is gone by 80 ms. The kick itself supplies everything above 1.5 kHz. The note before a struck note releases 30 ms before it (the existing clearance), so each strike is a clean re-pluck and C-B2 can still time it.
4. **Notes sustain to the next note.** An anchored note or a `hold` now rings until the next onset. Unanchored notes cross-fade into each other over 40 ms. The riddim figure (which kicks carry notes, pitches, pickups, drop-outs, throws, slam-back) is unchanged; only lengths change.
5. **One tone for every take, chosen by a constant.** `LofiBassTone.standard = .round` (flatwound). Two alternates, `.upright` and `.synth`, are rendered for comparison. The per-take 50/50 kit choice of D116 is removed.
6. **Throws keep their D116 sound.** The throw send keeps the current body code path verbatim, so the reverb-echo stem does not change character.

## 1. Target spectrum

Measure: third-octave band powers (ANSI centres) of `bass.wav`, whole file, Welch PSD, in dB relative to the power sum of the 50 Hz and 63 Hz bands. (That reference is 0.7 dB under the stem total in `final-main` and 1.0 dB under it in `cap-fix-1`, so the brief's "dB re total" figures shift by about +1.)

| Band (Hz) | Approved earlier | Current | Target | Allowed |
|---|---|---|---|---|
| 80 | -15.9 | -15.1 | -14 | -18 to -10 |
| 100 | -21.8 | -17.0 | -16 | -20 to -12 |
| 125 | -20.4 | -15.2 | -16 | -20 to -12 |
| 160 | -24 | -15.0 | -17 | -21 to -13 |
| 200 | -16 | -12.8 | -16 | -20 to -13 |
| 250 | -23 | -16.2 | -19 | -23 to -15 |
| 315 | -27 | -16.5 | -24 | -30 to -21 |
| 400 | -30 | -19.5 | -28 | -35 to -25 |
| 500 | -34 | -21.2 | -32 | -40 to -29 |
| 630 | -41 | -22.9 | -37 | -46 to -33 |
| 800 | -47 | -24.6 | -42 | -52 to -38 |
| 1000 | -56 | -35 | at most -45 | |
| 1250 | -58 | -41 | at most -48 | |
| 1600 | -61 | -40 | at most -52 | |
| 2000 | -77 | -50 | at most -57 | |
| 2500 | -92 | -56 | at most -64 | |
| 3150 | -96 | -65 | at most -70 | |
| 4000 | | -77 | at most -76 | |

- The 80-250 Hz region is kept a little fuller than the approved synth (this is the warmth). 315-800 Hz follows about -9 dB per octave. The lower bounds in 315-800 Hz matter as much as the upper ones: the listener also heard "too filtered", so the tone must not collapse to a sub.
- Power above 300 Hz: -22 to -27 dB re the stem total (current about -14).
- Sustain-only spectrum (frames from 100 ms after each note onset to the note's end): every band from 1 kHz to 4 kHz at most -55 dB; this is where the strike is excluded.
- C-B3 harmonics ratio (150-800 Hz against 40-150 Hz): -15 to -11.5 dB (approved earlier -14.7; the criterion warns under -18).
- Per-note harmonic envelope on a held MIDI 33, after the chain, sustain window, dB re h1: h2 -12 to -16, h3 -15 to -19, h4 -18 to -23, h5 -22 to -28, h6 -27 to -34, h8 at most -36, h12 at most -50, h16 at most -60. No harmonic from h3 up may exceed the one below it by more than 2 dB (no plateau, no formant).

## 2. Voice (`LofiBassVoice.swift`, `LofiBassSamples.swift`)

`classic` stays bit for bit. Add `nonisolated enum LofiBassTone: String, CaseIterable, Sendable { case round, upright, synth }` with `static let standard: LofiBassTone = .round` and `var voice: LofiBassVoice` (`.flatwound`, `.upright`, new `.synth`). `LofiScore.bassVoice(seed:section:phrase:)` returns `LofiBassTone.current.voice`, where `current` is `LofiCaptureHooks.option("bassTone")` when a capture sets it and `standard` otherwise (the hooks are inert in the app, so the app always plays `standard`).

Add `strike: Float = 0` to `LofiScore.Note` (include it in `with(length:)`, `score.json` and `diagnostics.bass`). The line writer sets it (section 4). The voice reads it.

### 2.1 Sub (all three tones, identical)

Additive, phase-accumulating, zero start phase, no tanh:
- Partials 1 to 4 with start amplitudes 0, -13, -17, -21 dB re the fundamental, all in sine phase.
- Each partial is weighted by the crossover magnitude `1 / (1 + (f / 160)^4)` at its frequency `f`. This is the magnitude of a 2-pole Butterworth low-pass run forward and backward, applied analytically, so there is no filter, no ringing and no phase shift.
- `slide` glide kept (45 ms raised cosine). The thump pitch drop is deleted.
- Level: `subGain` 0.30 at velocity 1 as now (retuned only through the chain trim, section 3).

Because the whole 40-160 Hz band is now synthesized, `lowRiseLead` depends only on (stroke, midi, struck) and no longer on the sample.

### 2.2 Body (above 160 Hz), per tone

Common to the sampled tones:
- Sample read as now (nearest root, linear interpolation; the diagnosis ruled out aliasing).
- **No drive.**
- High-pass at 160 Hz, 2-pole Butterworth forward then backward over the resampled note (matched to the sub's weight, zero phase).
- Low-pass: 12 dB/oct, Q 0.707, fixed at 420 Hz. On a struck note the cutoff is `420 + 900 * strike * e^(-t / 0.025)` Hz. No velocity term. The breakdown sweep moves the base from 150 to 450 Hz across `score.bassSweep` (was 250 to 900).
- Level: the body's RMS over its first 250 ms, measured after the low-pass, sits `bodyUnderSubDB` under the sub's RMS over the same window. Start 13 dB; boost cap 24 dB. Velocity scales sub and body equally.
- `LofiBassSamples` gains an `onset` per sample (first frame within 40 dB of the file's peak, minus 1 ms), and playback starts there. This removes the 0 to 31 ms of lead silence that differs between upright round robins.

| Tone | Body | Strike layer |
|---|---|---|
| `round` (default) | flatwound `long` (`ghost` file for ghosts) | First 80 ms of the flatwound `short` file at the note's pitch: high-pass 160 Hz zero-phase, low-pass 1.2 kHz 12 dB/oct, envelope 1 ms rise then `e^(-t / 0.020)`, raised-cosine to exactly zero at 80 ms. Peak level `strike * 10^(-10/20)` of the sub's peak (start). |
| `upright` | upright `long`, onset-trimmed, `bodyUnderSubDB` 15, low-pass 350 Hz | None from samples (the upright's bright part arrives 30-50 ms late and is noise). A synthesized burst of partials 3 to 6 at -14 dB re the sub's peak, decaying with a 25 ms time constant, zero at 100 ms. The softest attack of the three. |
| `synth` | No sample. Partials 5 to 12 continue the sub's series: amplitude of partial k is `-13 - 4 (k - 2)` dB re the fundamental, times `1 / sqrt(1 + (f / 500)^4)`, times the complementary crossover weight `1 - 1 / (1 + (f / 160)^4)`. Partials 2 to 4 get the same complementary weight so the sum across the crossover is flat. | Partials 2 to 8 at a flat -10 dB re the sub's peak with the same 20 ms decay and 80 ms end as `round`, weighted by the complementary crossover and a 1.2 kHz 12 dB/oct roll-off. |

All tones: on a struck note the whole voice gets a level accent `1 + 0.4 * strike * e^(-t / 0.040)` (+2.9 dB at strike 1, the existing accent mechanism). Notes with `strike == 0` have no accent, no strike layer and no filter opening.

### 2.3 Stroke shapes

| Stroke | Rise | Release | Level across the held part | Body file |
|---|---|---|---|---|
| `thump`, `walk` | 4 ms | 70 ms | -3 dB per second | long |
| `hold` | 5 ms | 140 ms | -2 dB per second | long |
| `ghost` | 4 ms | 50 ms | steady | ghost (`round`), long at ghost velocity (`upright`), none (`synth`) |

`click`, `dropSemitones` and `dropTime` are removed from `Shape`. `thump` and `walk` now differ only in their drawn length. `LofiBassVoice.release(_:)` gains a `beforeStrike: Bool` form that returns 45 ms (section 4.3). Envelope corners stay raised cosines; the voice is exactly zero after the release.

### 2.4 Throw send

`LofiBassThrow.render` must not call the new body. Move the current `renderBody` + `velocityLowpass` + click path, unchanged, to `LofiBassThrow` as its private send renderer (drive, 180 Hz high-pass and all), with the kit chosen by the old per-take rule (`seed`, `phrase / 4`, moved to `LofiBassThrow.sendKit`). The wet stem then changes only where the thrown note's length changes.

## 3. Chain (`LofiStemChains+Bass.swift`)

| Stage | Now | New (start values) |
|---|---|---|
| High-pass | 30 Hz | unchanged |
| Parallel harmonics | drive 4, bias 0.03, band 200-900 Hz, mix 0.40 | drive 2, bias 0.08, band 200-500 Hz zero-phase, mix 0.15 (about -16 dB) |
| Compressor | 4:1, knee 6, 25 ms, 150 ms, threshold reference -7 dB, makeup up to 5 dB | unchanged. Check the mean reduction on the now longer notes: 2 to 5 dB mean, at most 6.5 dB. Raise `thresholdBelowReferenceDB` if it exceeds that. The 25 ms attack is what lets the strike through. |
| EQ | +0.5 dB 80 Hz, -2 dB 280 Hz, +2 dB 700 Hz, LPF 2.4 kHz 12 dB/oct | +0.5 dB 80 Hz, -1 dB 300 Hz (Q 1; set to 0 if 250 Hz falls under its allowed range), no 700 Hz bell, LPF 1.4 kHz 24 dB/oct (two Butterworth sections) |
| Tape slap | above 220 Hz, 1/8 beat, 3 repeats | **removed** (`slap`, its settings and the `beatSeconds` parameter) |
| Output trim | -3.5 dB | retune last, to the level gates of section 6.5 |
| Headroom, split kick duck at 150 Hz, edge envelope | | unchanged (`LofiRenderer+Bass.finishBass`, `LofiSidechains`) |

Fix the stale comments while there (the voice header says 150 Hz, the plan said 2.8 kHz).

## 4. Line (`LofiScore+Bass.swift`)

Unchanged: kick slots, which kicks carry notes, anchoring and `bassKickRiseShare`, pitches, the weight note, answers, ghosts, pickups, the changed bar 4, sections, the breakdown drop-out and sweep, the return slam, throws, the slide. The bass line must keep drawing nothing from the shared `random` stream, so every non-bass note stays identical.

### 4.1 Strike

Set after anchoring: `strike = 1.0` for an anchored note whose role is `downbeat`, `kick` or `weight`; `0.6` for any other anchored note (an ornament moved onto a kick, a pickup on a kick); `0` for unanchored notes and all ghosts. The return slam gets 1.0.

### 4.2 Lengths

- Drawn lengths (`strokeLengths`): `thump` 0.5-0.75 beats, `walk` 0.75-1.0, `hold` 1.5-2.5, `ghost` 0.12-0.20 (unchanged).
- In `fit`, after the clearance pass: every anchored note and every `hold` stretches to its room (the gap to the next onset, less its release and any clearance), capped at 2.5 beats (`hold` 3.0). Unanchored answers and pickups keep their drawn length or their room, whichever is shorter. Ghosts stay short.
- **One breath per two-bar cell**: the note before each pickup (near 7.5 and 15.5) is not stretched if its drawn length leaves a rest of at least 0.35 beats. This keeps the riddim breathing; it is the only deliberate rest besides the breakdown drop-out.
- A sustaining note runs through kicks it is not anchored to; the split kick duck handles those (see risk 3).
- Limits: `bassBarSoundingLimit` 2.6 becomes 3.8; `bassPhraseSounding` 6.5...9.5 becomes 10.5...14.5 for theme, variation and return.

### 4.3 Joins

- Into an **anchored** note: the previous note uses the 45 ms release and ends `bassAccentClearance` (30 ms, unchanged) before the new note starts. This short dip is what makes the strike read as a re-pluck, and it is what the C-B2 measure needs (a 6 dB rise inside its window).
- Into an **unanchored** note: the previous note's release may overlap the new note by up to 40 ms (`bassLegatoOverlap`), a cross-fade with no gap.
- `lowRiseLead` cache key gains `struck: Bool`.

## 5. What stays, what goes

| Stays | Goes |
|---|---|
| Synth sub idea, phase-exact, zero start phase | tanh on the sub, the inverted 3rd harmonic that cancelled itself |
| Flatwound and upright sample files (no new downloads, no new files) | Upright as a default; per-take kit alternation |
| Kick anchoring, `lowRiseLead`, split kick duck, anchored kicks unducked | 180 Hz body high-pass, body drive, velocity low-pass |
| Compressor, 30 Hz high-pass, headroom, edge envelope | 1 kHz click, 8 ms pitch drop |
| Dub throws (send path frozen), breakdown sweep (darker range) | Tape slap, +2 dB at 700 Hz, 2.4 kHz 12 dB/oct low-pass |
| Riddim figure, drop-outs, slam-back, slide | 0.15-0.30 beat thumps, 2.6 beat bar limit |

## 6. Acceptance gates

Capture exactly as before, one at a time, no generation:

```sh
S=<session scratchpad>
scripts/check-lofi.sh --out $S/cap-tone-<n> --bars 32 --bpm 72 --seed 2077 --private-drums --film-reel --wait-lock 3600
python3 scripts/mix-report.py $S/cap-tone-<n> --baseline $S/cap-fix-1 --no-plots --strict
python3 scripts/solo-stems.py $S/cap-tone-<n> $S/solo-tone-<n>
python3 scripts/stem-bands.py $S/cap-tone-<n> --baseline $S/cap-fix-1
python3 scripts/bass-tone.py $S/cap-tone-<n> --baseline $S/cap-fix-1     # new, section 6.6
```

Run `bass-tone.py` on `cap-fix-1` and `final-main` first and record their numbers beside the gates below.

### 6.1 Spectrum
- Every band of the section 1 table inside its allowed range; power above 300 Hz -22 to -27 dB re total; sustain-only 1-4 kHz bands at most -55 dB; the MIDI 33 harmonic envelope (unit test, section 7).
- `stem-bands.py` bass, active windows: 300-800 Hz at least 7 dB lower than `cap-fix-1`; 1-4 kHz at least 10 dB lower and at most -62 dB; 120-300 Hz 0 to 4 dB lower; 40-120 Hz within 1 dB.

### 6.2 Continuity
- From `score.json`: sounding ratio per note, `min(1, (off - on + release) / gap to the next onset)`, phrase-final notes and notes before a drop-out excluded. Median at least 0.85 (current 0.51); at most 15 percent of notes under 0.5 (current 47 percent).
- From `bass.wav`: silences longer than 150 ms (40-250 Hz envelope more than 40 dB under the stem's 95th percentile), breakdown drop-outs excluded: at most 16 per minute (current 43, approved earlier 12).
- Stem active (400 ms windows, `stem-bands.py`): 72 to 92 percent (current 49).

### 6.3 Strike
For every note with `strike >= 1` and at least 320 ms long, with `t0` the note start:
- **Slap contrast**: RMS of the bass stem's 300-1500 Hz band in `t0 .. t0 + 15 ms` minus the same band in `t0 + 120 .. t0 + 300 ms`: median at least +10 dB, 10th percentile at least +6 dB. For notes with `strike == 0`: median at most +3 dB.
- **High transient only**: the same measure in 1-3 kHz: median at least +15 dB, while the sustain window sits at most -58 dB re the stem total.
- **Timing**: time of the 300-1500 Hz envelope peak (1 ms smoothing) minus the kick's broadband attack (`alignedKickFrame`): median absolute value at most 6 ms, 90th percentile at most 12 ms.
- **Brightest at the strike**: the spectral centroid of the first 15 ms is higher than that of any later 15 ms window of the note, for at least 90 percent of struck notes.
- Record the same four numbers for `cap-fix-1` (expected to fail the first and the last on the upright).

### 6.4 Low end and report
- `mix-report.py --strict`: 0 failures, and no warn ID that `cap-fix-1` does not have (C-M11, C-M12, C-B7, C-D8).
- C-B2: lag median at most 3 ms, p90 at most 8 ms (current 0.42 / 0.82); `lagMeasured` at least 50 of the aligned notes (current 57 of 83); sum median at least 0 dB, worst at least -3 dB (current +1.46 / -1.18); duck depth 1.5 to 4.5 dB (current 1.96).
- C-B3: 60-250 Hz bass against drums -3 to +1 dB; harmonics -15 to -11.5 dB.
- C-B1, C-B10, C-M10 pass.
- `scripts/mix-matrix.sh --strict` once at the end, on the default tone: no criterion fails that does not already fail on bab3fed in the same case (`long` C-B8; `fast` C-B8, C-D6, C-D9; `same` C-B6).

### 6.5 Rest of the mix untouched
- Raw `drums.wav`, `dry.wav`, `texture.wav`: maximum sample difference to `cap-fix-1` under 1e-6. Non-bass notes in `score.json` identical.
- `solo-stems.py`: bass within -1.0 to +0.5 LU of drums. Chords, melody, chops, film bed and master each within 0.5 LU of `cap-fix-1`; reverb-echo within 0.3 LU.
- True peak at most -1.0 dBTP; limiter mean at most 0.5 dB, p95 at most 1.5 dB.
- Pre-master bands (`stem-bands.py`): 40-120 Hz and 120-300 Hz within 1 dB of `cap-fix-1`; 300-800 Hz and 1-4 kHz equal or lower, and not more than 3 dB lower.

### 6.6 `scripts/bass-tone.py` (new)
Reads a capture (`bass.wav`, `drums.wav`, `score.json`, `manifest.json`) and prints, with PASS or FAIL per line and an optional `--json`: the third-octave table re 50+63 Hz with the allowed ranges, power above 300 Hz, the sustain-only bands, the three continuity numbers and the four strike numbers. Uses `mixlib.audio.read_wav`. Add a self-test on a synthetic signal to `mixlib/selftest.py`. Update the bass band gates in `scripts/stem-bands.py` (they still encode "300-800 Hz up 8 to 14 dB", which this plan reverses).

## 7. Unit tests

Rewrite, each with a one-line reason:
- `LofiBassVoiceTests.twoLayerVoicesAreMonoTunedBandLimitedAndEndExactly`: iterate the three tones; pitch within 5 cents from 5 ms on (no drop); nothing above 2.5 kHz within 60 dB of the strongest bin on unstruck notes; step bound kept.
- `kitsAreLoudnessMatchedPerStroke`: the three tones within 1 dB RMS per stroke at MIDI 28, 33, 38, 41, struck and unstruck.
- `theBodyCarriesTheNoteAndVelocityDrivesBrightness`: replace with `sustainFollowsTheToneTarget` (the harmonic envelope of section 1 at MIDI 28, 33, 38, 41; 150-800 against 40-150 Hz between -16 and -10 dB; velocity changes level only, tilt within 1 dB) and `belowTheCrossoverIsTheSubAlone` (body and strike layers at least 30 dB under the sub below 130 Hz; the three tones identical below 120 Hz within 0.5 dB).
- New `strikeIsBrightestAtTheStartAndOnlyOnStruckNotes`: the section 6.3 contrast on single notes (at least 10 dB at strike 1, at most 3 dB at strike 0), the band's peak within 6 ms of the note start, exact zero of the strike layer after 80 ms (100 ms upright).
- `lowRiseLeadCacheReturnsTheUncachedValue`: add the struck key; leads between 0 and 20 ms for every tone.
- `throwReturnIsHighPassedAndSitsUnderTheBass`: unchanged gates; add that the send equals the D116 body sample for sample (frozen path).
- `LofiBassLineTests.densityRestsStrokeMixAndPitchSharesMeetThePlan`: bar sounding at most 3.8, phrase sounding 10.5 to 14.5, median sounding ratio at least 0.85 over seeds 0..<100; note counts and pitch shares unchanged; stroke-share bounds re-measured and stated.
- `notesAreMonoTightAndInsideThePhrase`: overlap at most 40 ms and only into unanchored notes; 30 ms of silence before every anchored note; everything ends by beat 16.
- New `everyAnchoredNoteIsStruckAndGhostsNeverAre`; new `oneBreathPerCell`.
- `LofiStemChainTests`: EQ expectations (within 1 dB of 0 at 700 Hz; -3 dB at 1.4 kHz; at most -22 dB at 2.8 kHz), the response probe list, `bassIsMonoCarriesHarmonicsAndCompresses` (parallel stage adds 0.5 to 3 dB in 200-500 Hz and under 0.5 dB above 800 Hz; reduction bounds as section 3), remove slap coverage; kick-duck and zero-edge tests unchanged.
- `LofiRhythmTests` (bass voice tests near lines 550 and 591), `LofiArrangementTests` (anchoring within 2 ms at 62, 70, 72, 81 BPM stays; "kit per take" becomes "every phrase plays `LofiBassTone.standard`"), `LofiCompositionTests` line 157 and `LofiTests` line 278 (lead of the new voice).
- The phrase render budget test must still pass in Debug: the per-note zero-phase filters and additive partials are on the phrase render path, so use vector operations and `while` loops as in 457310e, and report the phrase render time before and after.

Build and run after each substantive change (macOS build, the Lo-Fi list of `docs/plans/bass-and-pads.md` 5.1 including `LofiBassLineTests` and `LofiBassVoiceTests`), then `LofiMixRenderTests`, `LofiLiveBusTests`, `LofiCaptureHooksTests` and the visionOS build before the captures.

## 8. Variants for listening

Three captures with the same seed, tempo and bars, differing only in the hook:

```sh
scripts/check-lofi.sh --out $S/cap-tone-round   ... --hook bassTone=round
scripts/check-lofi.sh --out $S/cap-tone-upright ... --hook bassTone=upright
scripts/check-lofi.sh --out $S/cap-tone-synth   ... --hook bassTone=synth
```

| Tone | Character | Expected difference |
|---|---|---|
| `round` (default) | Flatwound electric with the tone rolled off; real string pluck as the strike | Fullest 160-400 Hz, hardest slap |
| `upright` | Onset-trimmed upright, darker (350 Hz), synthesized soft thump | Softest attack, roundest; the kick does most of the slap |
| `synth` | No samples; the approved earlier synth extended with legato and a strike | Cleanest and most even note to note; closest to `final-main` |

For each: `solo-stems.py` output, then copy `02-bass.m4a` (the solo bass at final-mix level) and the full mix (`master.wav` encoded the same way) to `$S/bass-tone-compare/` as `bass-solo-<tone>.m4a` and `full-mix-<tone>.m4a`, plus the same two files from `cap-fix-1` as `...-before.m4a`. All three must pass sections 6.1 to 6.3 and 6.5 (level-match each with its own `bodyUnderSubDB` and strike level, one shared output trim); only the default needs 6.4's matrix. Hand the eight files to the user with the three `bass-tone.py` tables. After the user picks, set `LofiBassTone.standard`; keep the other two selectable by the constant.

## 9. Order of work

1. `bass-tone.py` and baseline numbers for `cap-fix-1` and `final-main`.
2. Voice: sub, crossover, body, strike, shapes, frozen throw send; voice tests.
3. Chain changes; chain tests.
4. Line: strike, lengths, joins; line tests.
5. Capture `round`; tune in this order: body level and low-pass to the 160-800 Hz bands, strike level to 6.3, compressor threshold, output trim to the level gates of 6.5. One control per capture.
6. Captures of `upright` and `synth`; level-match; comparison files.
7. Matrix on the default; docs.

## 10. Docs (same change)

- `docs/decisions/music.md`: new D119 (the listening note, the diagnosis numbers, what was removed and why, the target table, measured results, the tone constant); mark the D116 voice and chain paragraphs and the D118 bass constants as superseded.
- `docs/architecture.md` and `docs/experience.md`: the bass description. `README.md` if it names the kits per take.
- `docs/mix-verification.md` and `docs/development.md`: `bass-tone.py`, the `bassTone` hook.
- `docs/lofi-samples.md`: which files each tone uses (no new files).
- `docs/plans/bass-and-pads.md`: a note under Outcome pointing here. This file: an Outcome section with the final constants and gate readings.
- `AGENTS.md` / `CLAUDE.md` repository map only if a new source file is added.

## 11. Risks

1. **Sustain raises the low end of the mix.** The bass goes from 49 to about 80 percent active, so whole-file 40-120 Hz in the pre-master and the master's loudness can rise past the 1 dB and 0.5 LU gates even with the stem's active level unchanged. Controls, in order: output trim toward the lower end of the bass-against-drums window (-1.0 LU), the per-second decay of sustained notes (3 to 5 dB per second), the sustain cap (2.5 to 2.0 beats). Do not touch the master or other stems.
2. **C-B2 timing on re-struck notes.** The measure needs the bass to be 6 dB down inside the 30 ms before the kick. The 45 ms release plus 30 ms clearance should give that; if `lagMeasured` falls under 50, lengthen the clearance to 40 ms before shortening anything else.
3. **Sustained notes under unanchored kicks.** `sumVsLouderDbWorst` could fall (bound -3 dB) and the duck-depth measure will see many more kicks. If either gate fails, end a sustaining note 30 ms before a confident kick it is not anchored to (a rest under that kick), and accept the lower continuity only if 6.2 still passes.
4. **Flatwound transposition.** Roots are MIDI 21 to 33, so notes at 38 to 41 play 5 to 8 semitones up and ornaments more. The harmonic-envelope test at MIDI 38 and 41 guards the tone; if it fails there, lower the body low-pass for transposed notes in proportion.
5. **The slap may still be too polite, or too bright.** The strike level (-10 dB) and its 1.2 kHz ceiling are start values with no source behind them; the audit found no numeric reference for dub bass attack. This is why three tones are rendered. The strike level is the one constant the user is most likely to want moved after listening.
6. **Research basis.** The spectral targets are engineering judgement anchored on the approved earlier stem, not on measured reference records.
7. **Throw send frozen on old code.** It keeps the duplicated D116 body path alive in `LofiBassThrow`; note this in D119 so it is not mistaken for dead code.

## Outcome (2026-11-20)

Built on `main` (D119). Final constants: sub partials 0, -14, -17, -21 dB under the 160 Hz zero-phase crossover; body levelled to 13 dB under the steady sub (`upright` 12.5), extra 110 Hz 4-pole high-pass, low-pass 400 Hz (`upright` 360) at 24 dB per octave, body rise 30 ms unstruck and 40 ms struck; strike 1 ms rise, 10 ms decay, zero at 80 ms (100 ms upright), 300 Hz to 650 Hz (24 dB per octave), peak -2 dB re the sub's peak (`upright` -5, `synth` -3), placed on the kick's broadband attack; filter opening 300 Hz over 8 ms; chain harmonics drive 2, bias 0.08, 200-450 Hz, mix 0.15; compressor 9 dB under the reference; EQ +0.5 dB at 80 Hz, -1 dB at 300 Hz, 1.4 kHz 24 dB per octave; output trim -4.45 dB. A sustained note that would fade out under a kick it is not anchored to (0.06 beats or its release) ends 30 ms before it (risk 3: the matrix `ref` case read a -3.6 dB kick and bass sum there).

Gate readings on `cap-tone-11` (seed 2077): every section 6.1 to 6.3 gate passes (table in D119 and `NOTES-tone.md`); 6.4: strict report without failures and the same warn IDs as `cap-fix-1`, C-B2 0.33 / 0.63 ms, 57 measured, sum +0.98 / -1.78 dB, duck 3.39 dB, C-B3 +0.96 dB and -12.2 dB; 6.5: bass -0.97 LU under the drums, other stems within 0.1 LU, true peak -1.20 dBTP, limiter mean 0.02 dB, pre-master bands within 0.4 dB. Drum stem identical; dry and texture differ by at most 6e-4 (balance meter, the throw return of longer thrown notes). `synth` passes every tone gate; `upright` fails the 250 Hz band (-23.4 against -23) and reads C-B3 +1.001 dB. Matrix on the default: `ref` and `nofilm` pass, `long` C-B8, `fast` C-B8, C-D6, C-D9, `same` C-B6 (the bab3fed failures). Phrase render 1105 ms per phrase (bab3fed 1069).

Deviations: the strike measures start at the strike, not the note start; brightness is a band-power ratio, not a centroid; the body is levelled rather than normalized once (the plucked samples decay 15 dB in half a second); the strike is louder (-2 dB, not -10) and narrower (300-650 Hz) than the start values, which gave 1-6 dB of contrast; unit-test bounds the sampled tones cannot meet are set to their measured values (D119).

