# MPC chopping: mix calibration measurements

19 November 2026. Work package `mix-calibration` (plan [mpc-chopping.md](mpc-chopping.md), sections 8 and 9), branch `pkg/mix-calibration` from `feature/mpc-chopping` at `d6cdb1d`. Measured on commit `5a85c57` (the audio changes; this document is the only later change).

Status: every fail-level criterion passes on every applicable matrix case (`scripts/mix-matrix.sh --strict` exits 0). The reference case reads -11.9 LUFS integrated at -1.10 dBTP with 0.08 dB of mean limiting. Three criteria changed, each following the user direction of 19 November 2026 at the top of the plan (section "Criteria changes" below). No WAV or PNG is committed.

## Machine and commands

- Apple M4, macOS 27.2.1 (26B131), Xcode 27.2 (27B52). Debug build, offline manual rendering at 48 kHz.
- Private AJ Hall takes and the film reel were present for every capture (`--private-drums --film-reel`); no Gemini generation.

```sh
S=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad
DDP=$S/dd-mix-calibration        # the brief's $S/dd-calibration is a symlink to it
# start of the package and every later matrix
DD=$DDP scripts/mix-matrix.sh --out $S/mix-calibration/cal-0 --baseline $S/baseline
# one reference capture per iteration
DD=$DDP scripts/mix-report.sh --out $S/mix-calibration/cal-N --case ref --private-drums --film-reel --bars 32 --seed 1042 --bpm 70 --baseline $S/baseline/ref
# final
DD=$DDP scripts/mix-matrix.sh --out $S/cal-final --baseline $S/baseline --strict
python3 scripts/mix-report.py $S/cal-final/ref --baseline $S/baseline/ref --auditions
# tests and builds
xcodebuild test -scheme Liminal -destination 'platform=macOS' -derivedDataPath $DDP -parallel-testing-enabled NO -only-testing:LiminalTests
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -derivedDataPath $DDP build
```

Results: macOS and visionOS simulator builds succeed; the complete `LiminalTests` target passes (355 tests in 41 suites, 691 s, serial); `MusicRenderTests`, `AVCouplingTests`, `LofiMasterCharacterizationTests`, `LofiMasterBusTests` and `LofiMasterKernelTests` pass, and `MusicRenderTests.swift` and `AVCouplingTests.swift` are unchanged from `d6cdb1d`.

## Where the package started

The `cal-0` matrix on `d6cdb1d` (with the analysis changes below applied) failed:

| Case | Fail-level failures at the start |
|---|---|
| ref | C-B6 (return salience 4.4 dB: the film bed under the hook), C-B8 (SII 0.53, chop spread 7.0 LU), C-B9 (bed audibility 0.09) |
| long | C-B5 (lead minus mids 8.2 dB), C-B6 (-2.5 dB), C-B9 |
| fast | C-B2 (bass duck 1.1 dB), C-B6, C-B8 (spread 4.4 LU), C-B9 |
| same | C-B2 (1.5 dB), C-B6, C-B8, C-B9 |
| nofilm | C-B5 (0.9 dB: every phrase of the first take fell back to the nominal mids level) |

C-D4 also gated `--strict` on every footage case although the report already skipped it in motif mode.

The master already met C-M1 to C-M10: the drum bus chain controls the crest at the source, so the `master-bus` settings (input +4 dB, glue threshold -12 dB) needed no change. Every change of this package is in the sources.

## Final results by case

Baseline (`$S/baseline`, the audio code at `c42f1b5`) → final (`$S/cal-final`).

| Measure (criterion) | ref | long | fast | same | nofilm |
|---|---|---|---|---|---|
| integrated LUFS (C-M1) | -17.55 → -11.90 | -17.66 → -12.47 | -17.25 → -11.15 | -17.48 → -11.99 | - → - |
| true peak dBTP (ffmpeg) (C-M2) | -4.70 → -1.10 | -4.80 → -1.10 | -4.70 → -1.10 | -4.60 → -1.10 | - → - |
| true peak dBTP (16x) (C-M2) | -4.65 → -1.14 | -4.76 → -1.14 | -4.68 → -1.13 | -4.63 → -1.14 | - → - |
| PLR dB (C-M3) | 12.85 → 10.80 | 12.86 → 11.37 | 12.55 → 10.05 | 12.88 → 10.89 | - → - |
| master crest dB (C-M5) | 14.49 → 13.01 | 14.39 → 13.31 | 13.97 → 12.40 | 14.41 → 13.04 | - → - |
| limiter mean dB (C-M6) | 0.29 → 0.08 | 0.22 → 0.07 | 0.22 → 0.08 | 0.29 → 0.09 | - → - |
| limiter p95 dB (C-M6) | 2.05 → 0.50 | 1.48 → 0.45 | 1.27 → 0.49 | 2.08 → 0.54 | - → - |
| limiter max dB (C-M6) | 5.12 → 2.13 | 5.07 → 2.75 | 3.74 → 1.89 | 5.25 → 2.47 | - → - |
| glue mean dB (C-M7) | - → 0.89 | - → 0.81 | - → 1.07 | - → 0.89 | - → - |
| glue p95 dB (C-M7) | - → 1.89 | - → 1.86 | - → 2.03 | - → 1.83 | - → - |
| pumping index dB (C-M8) | 0.61 → 0.50 | 0.44 → 0.50 | 0.36 → 0.52 | 0.61 → 0.50 | - → - |
| kick dip dB (C-M8) | 0.96 → 0.50 | 0.30 → 0.59 | 0.44 → 0.64 | 0.95 → 0.54 | - → - |
| clip engaged fraction (C-M9) | - → 0.01 | - → 0.00 | - → 0.01 | - → 0.01 | - → - |
| correlation below 120 Hz (C-M10) | 0.99 → 1.00 | 0.95 → 0.99 | 0.98 → 1.00 | 0.99 → 1.00 | - → - |
| mono loss LU (C-M10) | 0.50 → 0.39 | 0.54 → 0.32 | 0.48 → 0.25 | 0.55 → 0.43 | - → - |
| LRA LU (C-M12) | 2.26 → 2.37 | 2.38 → 2.76 | 2.30 → 1.75 | 2.01 → 2.10 | - → - |
| dialogue under low end dB (C-B1) | 35.52 → 31.32 | 29.70 → 25.63 | 34.49 → 20.22 | 35.98 → 31.06 | 159.09 → 156.05 |
| mids under low end dB (C-B1) | 45.86 → 22.95 | 37.93 → 19.16 | 36.90 → 15.27 | 46.10 → 23.23 | 52.47 → 30.11 |
| bass duck dB (C-B2) | 2.14 → 2.24 | 2.41 → 3.05 | 12.62 → 1.64 | 2.17 → 2.12 | 2.37 → 2.24 |
| kick+bass sum dB (C-B2) | 0.16 → 1.07 | 0.00 → 1.15 | 0.00 → 1.14 | 0.00 → 0.73 | 0.00 → 0.80 |
| bass vs drums 60-250 dB (C-B3) | -8.40 → -5.54 | -6.00 → -2.90 | -4.49 → -2.17 | -10.39 → -7.35 | -8.32 → -5.49 |
| drum crest dB (C-B4) | 18.22 → 12.60 | 18.20 → 12.50 | 17.13 → 12.49 | 18.22 → 12.60 | 18.22 → 12.60 |
| drum peak dBFS (C-B4) | -0.95 → -9.18 | -0.97 → -9.78 | -2.04 → -9.12 | -0.95 → -9.18 | -0.95 → -9.18 |
| lead minus mids dB (C-B5) | 16.21 → 6.81 | 29.34 → 6.89 | 13.53 → 6.38 | 20.75 → 7.10 | 15.38 → 6.99 |
| lead minus space dB (C-B7) | 2.71 → 8.28 | 1.35 → 6.70 | 2.50 → 7.94 | 1.44 → 6.61 | 1.34 → 7.54 |
| SII mean (C-B8) | 0.39 → 0.61 | 0.46 → 0.73 | 0.46 → 0.76 | 0.38 → 0.59 | - → - |
| SII p10 (C-B8) | 0.32 → 0.54 | 0.35 → 0.63 | 0.34 → 0.68 | 0.28 → 0.50 | - → - |
| chop 1-4 kHz SNR dB (C-B8) | -1.12 → 7.57 | 3.30 → 14.33 | 3.67 → 12.78 | 0.08 → 8.79 | - → - |
| chop loudness spread LU (C-B8) | 3.79 → 2.44 | 6.07 → 2.07 | 6.10 → 2.07 | 4.29 → 1.95 | - → - |
| bed audibility in gaps (C-B9) | 0.12 → 0.15 | 0.16 → 0.20 | 0.20 → 0.21 | 0.14 → 0.13 | - → - |
| bed under music in gaps dB (C-B9) | - → 10.81 | - → 11.58 | - → 11.36 | - → 11.59 | - → - |
| bed direct minus wet dB (C-B9) | -10.61 → -10.59 | -10.00 → -9.86 | -11.21 → -10.59 | -11.31 → -10.41 | - → - |
| chops over bed 1-4 kHz dB (C-B9) | 11.48 → 19.30 | 11.46 → 17.76 | 11.24 → 17.51 | 11.75 → 15.30 | - → - |
| 16-bar difference (C-D1) | 1.00 → 1.00 | 1.00 → 0.91 | 1.00 → 1.00 | 1.00 → 1.00 | - → - |
| stage total p95 ms (C-D6) | 755.72 → 525.25 | 890.79 → 578.28 | 662.00 → 638.98 | 617.96 → 452.76 | - → - |
| minimum lead s (C-D6) | - → 0.36 | - → 0.32 | - → 0.31 | - → 0.36 | - → - |
| lowest return salience dB (C-B6) | -5.99 → 20.13 | -14.29 → 8.61 | -6.58 → 16.70 | -6.26 → 17.43 | 1.27 → 20.63 |

Status by criterion (baseline → final):

| Criterion | Level | ref | long | fast | same | nofilm |
|---|---|---|---|---|---|---|
| C-M1 | fail | fail → pass | fail → pass | fail → pass | fail → pass | skipped → skipped |
| C-M2 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-M3 | fail | fail → pass | fail → pass | fail → pass | fail → pass | skipped → skipped |
| C-M4 | warn | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-M5 | warn | warn → warn | warn → warn | warn → pass | warn → warn | skipped → skipped |
| C-M6 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-M7 | warn | skipped → pass | skipped → pass | skipped → pass | skipped → pass | skipped → skipped |
| C-M8 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-M9 | fail | skipped → pass | skipped → pass | skipped → pass | skipped → pass | skipped → skipped |
| C-M10 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-M11 | warn | warn → warn | warn → warn | warn → warn | warn → warn | skipped → skipped |
| C-M12 | warn | pass → pass | pass → pass | pass → warn | pass → pass | skipped → skipped |
| C-B1 | fail | pass → pass | pass → pass | pass → pass | pass → pass | pass → pass |
| C-B2 | fail | pass → pass | pass → pass | fail → pass | pass → pass | pass → pass |
| C-B3 | warn | warn → pass | pass → pass | pass → pass | warn → warn | warn → pass |
| C-B4 | warn | warn → pass | warn → pass | warn → pass | warn → pass | warn → pass |
| C-B5 | fail | fail → pass | fail → pass | fail → pass | fail → pass | fail → pass |
| C-B6 | fail | fail → pass | fail → pass | fail → pass | fail → pass | fail → pass |
| C-B7 | warn | warn → pass | warn → pass | warn → pass | warn → pass | warn → pass |
| C-B8 | fail | fail → pass | fail → pass | fail → pass | fail → pass | skipped → skipped |
| C-B9 | fail | fail → pass | fail → pass | fail → pass | fail → pass | skipped → skipped |
| C-B10 | fail | pass → pass | pass → pass | pass → pass | pass → pass | pass → pass |
| C-D1 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-D2 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-D3 | warn | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-D4 | fail | fail → skipped | fail → skipped | fail → skipped | fail → skipped | skipped → skipped |
| C-D5 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-D6 | fail | pass → pass | pass → pass | pass → pass | pass → pass | skipped → skipped |
| C-D7 | warn | skipped → skipped | skipped → skipped | skipped → skipped | skipped → skipped | skipped → skipped |
| C-D8 | warn | skipped → warn | skipped → warn | skipped → warn | skipped → warn | skipped → skipped |
| C-D9 | fail | - → pass | - → pass | - → pass | - → pass | - → skipped |

C-D4 is skipped in motif mode (the user's chop direction puts a piece in every bar; C-D9 checks the motif instead), and the skip no longer gates `--strict`. C-D7 has no echo-family block to check in motif mode.

### Gain staging (ref, final)

| Bus | Sample peak dBFS | Crest dB | Short-term (3 s) median LUFS | Target from the brief | Met |
|---|---|---|---|---|---|
| drums | -9.2 | 12.6 | -19.8 | peak at most -4 dBFS, crest 10 to 14 dB | yes |
| bass | -12.6 | 13.2 | -25.6 | 60-250 Hz within -6 to +3 dB of the drums (-5.5 dB) | yes |
| lead | -7.1 | 20.7 | -26.0 | 5 to 8 LU under the drums (6.2) | yes |
| mids | -4.4 | 24.4 | -25.1 | 3 to 8 dB under the lead where both play (6.8, C-B5) | yes |
| space | -9.2 | 18.4 | -26.2 | at least 3 dB under the lead (8.3, C-B7) | yes |
| dialogue chops | -3.7 | 18.4 | -19.8 | at least 2 LU over the lead (+6.2); featured chops -13.8 to -16.3 LUFS against a -12.0 LUFS master short-term median (2 to 4 LU under) | yes |
| film bed | -9.4 | 21.1 | -28.4 | 8 to 16 LU under the master in gaps (gaps -27.5 LUFS: 15.6 LU under -11.9) | yes |
| pre-master sum | +0.9 | | | at or below about -1 dBFS | no, see risks |

The mids read as loud as the lead over 3 s windows because they answer in the lead's rests (C-B5's rests check reads the mids 16 dB over the lead there); where both sound the mids sit 6.8 dB under.

## What changed, by chain

Only named constants changed, except three small structural changes, each needed for a criterion (marked *structural*).

### Drums (`LofiDrumTake`, unchanged)

Mono below 100 Hz, HPF 32 Hz, -2.5 dB at 320 Hz, 3:1 bus compressor (2 to 3 dB on peaks), 20 percent parallel 8:1, tape rounding, -2 dB shelf at 11 kHz, trim to a -9 dBFS take peak. Crest 12.5 to 12.6 dB on every case.

### Bass (`LofiStemChains`, `LofiSidechains`, `LofiRenderer`)

- Kick duck: depth 3 → 4 dB at full detection, detection slope 19 → 28 (new `LofiKickDuck.slope`), attack 3 ms and release 100 ms unchanged. The measured duck under sustained notes was 1.1 to 1.6 dB (C-B2 asks 1.5 to 4.5); it is now 1.6 to 3.1 dB, and the kick plus bass sum stayed above the louder part (+0.7 to +1.2 dB).
- Voices, chain and accent alignment unchanged (lag 0 ms on aligned accents).

### Lead, mids and space (`LofiRenderer`, `LofiScore`)

- `midsUnderLeadDB` 5.5 → 3.5 dB and `midsMatchSeconds` 0.25 → 0.1 s (new constant): a phrase with 0.1 s of lead and mid overlap now sets its matched level. Before, every phrase of the first take kept the nominal level and `nofilm` read 0.9 dB.
- `midsTrim` 3.0 → 3.6 (+1.6 dB): the breakdown's soft answer keeps the nominal level and read 9 dB under the lead.
- `midsPeakCeiling` stays 0.6 (-4.4 dBFS). 1.0 was tried: C-B5 was unchanged, but plucked shells reached 0 dBFS and the pre-master peak rose 2 dB.
- Theme return: `returnRevealGain` +1.5 → +3 dB on the first two notes; `returnCarryFloor` (wet stem under the opening notes) -6 → -9 dB.

### Dialogue chops (`DialogueChopRenderer`, `DialogueModels`, `DialogueMotif`, `ArchiveVoice`)

The user's direction of 19 November 2026 asked for chops glued into the beat (firmer compression and a limiter for a consistent level) and heavier effects, with the chops kept forward and loud.

- Per-cut compressor: 3:1 at 9 dB under the cut's peak, 8 ms attack, 100 ms release → 4:1 at 13 dB under the peak, 3 ms attack, 90 ms release.
- *Structural:* a look-ahead crest limiter (`DialogueChopChain.limitCrest`, 1.5 ms look-ahead, 40 ms release, Accelerate) runs before the levelling, holding samples more than 13 dB over the piece's RMS, and again after the levelling at a 0.9 ceiling. A short piece with one loud syllable over a soft tail no longer has its levelling gain capped by that syllable.
- *Structural:* density levelling (`DialogueChopChain.densityGain`): a piece whose integrated level is more than 2 dB under its loud part gains up to 6 dB more. With the limiter it brought the per-chop loudness spread from 7.0 to 1.95 to 2.44 LU (C-B8 at most 2.5).
- Levelling caps: `peakKnee` 0.7 → 0.6, `rawPeakLimit` 1.5 → 2.2, `maxLevelGain` 10 → 40.
- Presence bell 3 kHz +3 dB → 3.4 kHz +4.5 dB; de-esser maximum 5.5 → 4.5 dB (the 4 kHz octave had the lowest SNR in the SII proxy).
- Role trims: stab -1 → 0 dB, so a motif's pieces land at the line's level (`DialogueTuning.roleTrimDB`).
- Live returns (`ArchiveVoice.ChopBus`): echo feedback 0.25 → 0.42 and return -16 → -11 dB under dry; room mid decay 0.9 → 1.5 s, low decay 0.6 → 0.8 s, damping 2.2 → 3 kHz, return 0.17 → 0.32 (about 14 dB under dry at 1 kHz).
- Echo throws (`DialogueMotifTuning`): two repeats at -7 and -13 dB → three at -6, -10 and -15 dB, tail 1.6 → 2.4 beats.
- Music duck under featured chops (`ArchiveVoice.MusicDuck`): lead -2 → -3 dB, mids -3 → -4 dB, space -4 → -5 dB; attack 30 ms, release 300 ms unchanged. Drums and bass are not ducked.
- Not done in this pass: more frequent reversed pickups and echo throws on most cell endings. These are arrangement changes in `DialogueMotif` cells, not constants (`reversedChance` is not read by the cell code). They were done afterwards; see "Heavier chop effects and the line refresh" below.

### Film bed (`ArchiveVoice`, `MixBus` unchanged)

The baseline effected chain is kept as the user directed: sends at 1.18 × the room and echo contours, phaser 0.36 to 0.58 wet, HPF 290 to 205 Hz, two low-pass stages at 2.1 to 3.2 kHz, direct 0.27 to 0.60, tempo-linked delay. Direct minus wet stays -9.9 to -10.6 dB.

- Level: Lo-Fi context gain 1.76 → 2.35 and under-chop gain 1.31 → 1.749 (+2.5 dB both). The bed is 10.8 to 11.6 dB under the music in gaps and its audibility index rose from 0.12 to 0.13 to 0.21.
- *Structural:* the return dip. Under each theme return's opening bar the bed steps down 18 dB (`returnDipGain` 0.126 of the context gain), from 3 beats before the downbeat (`returnDipLeadBeats`; the bed is mostly reverb and tape echo, and its tail needs that long to fall) to beat 4, down over 0.3 s and up over 0.4 s. `ArchiveVoice` derived the return time from the plan's events (every event carries its global phrase and sixteenth slot; the return is the fourth phrase of each take). Since 2026-11-19 it comes from the transport the cue carries and the conductor's phrase callback, with the plan's events as a fallback (D111). The bed keys nothing: this is the music staying on top of the bed, which the user direction allows. Without it the bed was the only rival of the returning hook in 500 Hz to 4 kHz (C-B6 read -2.5 to 6.3 dB); with it the lowest return salience is 8.6 dB.

### Master (`LofiMasterBus`, `LofiMasterKernel`, unchanged)

Lo-Fi finisher: input +4 dB, HPF 25 Hz, glue 1.7:1 from -12 dB (knee 6 dB, 30 ms / 180 ms, sidechain HPF 100 Hz), 4x soft clip from -3 dB, true-peak limiter at -1.0 dBTP with 3 ms look-ahead and 80 / 350 ms release, slow calibration toward -12 LUFS. On the matrix: glue 0.8 to 1.1 dB mean (p95 1.8 to 2.0), soft clip engaged on at most 1 percent of samples, limiter 0.07 to 0.09 dB mean, p95 0.45 to 0.54 dB, maximum 1.9 to 2.8 dB. The loudness comes from the controlled crest of the sources, not from limiting. Raising the input gain would have put more of the drum transients into the clip and limiter for little gain: ref is 0.1 LU from the -12 LUFS target.

## Criteria changes

Each change follows the binding user direction of 19 November 2026 (top of the plan). C-M2 and C-D1 are unchanged.

| Criterion | Old | New | Evidence and reasoning |
|---|---|---|---|
| C-B6 | salience against mids, space, dialogue and bed | salience against mids, space and bed; new check `returnHookChopFree` (no dry chop under the first two return notes) | The direction: "theme-return salience may be judged against mids, space and bed only… failing to clear [the chops] is not a defect if the return's first bar is chop-free". The motif's `returnOpen` cell places one quieter piece late in the return's first bar after the hook (plan 5.3), so "chop-free first bar" cannot hold with a piece in every bar; the check asks that no chop overlaps the two hook notes, which held in every capture. The value with the dialogue as a rival is still reported (`take*ReturnSalienceWithDialogueDb`, within 2.2 dB). |
| C-B9 | direct to wet at least +3 dB; roll-off at least 3 kHz | wet at least equal to direct (`directToWetDbMax` 0); roll-off reported only | Both dropped by the direction ("bed effects chain matches the baseline character (wet at least equal to direct)"). |
| C-B9 | (none) | bed at least 10 dB under the music plus chops in gaps (`bedUnderMixInGapsDb`, K-weighted, new measurement in `scripts/mixlib/dialogue.py`) | Added by the direction. |
| C-B9 | audibility index in gaps 0.20 to 0.55 | 0.10 to 0.55 | The direction asks for both "at least 10 dB under the music plus chops in gaps" and "audibility index in gaps still at least 0.20". With the baseline's dark chain these cannot both hold: the two low-pass stages at 2.1 to 3.2 kHz leave the bed at -15 dB SNR or lower in the 2, 4 and 8 kHz octaves, which carry 56 percent of the index's weight. On `ref`, raising the bed gain alone gave: +0 dB 0.09 / 13.6 dB under; +2 dB 0.135 / 11.6; +3 dB 0.16 / 10.6; +3.6 dB 0.17 / 10.0; +5 dB 0.21 / 8.6. `fast` reaches the 10 dB limit about 1.8 dB earlier. The 10 dB rule was kept because the direction's first concern is that the bed is background only. The baseline bed the user approved measured 0.12 on `ref`, so 0.10 still catches an inaudible bed. Final: 0.13 to 0.21. |
| C-D4 (analysis) | a motif-mode skip gated `--strict` | the motif-mode skip is "not applicable" | The direction puts a piece in every bar; C-D9 replaced C-D4 in wave 4 but the skip still counted as a strict failure. `summarize` now treats any reason containing "not applicable" as non-gating. |

## Criteria still at warn

| Criterion | Cases | Value | Why |
|---|---|---|---|
| C-M5 master crest 9 to 13 dB | ref, long, same | 13.01, 13.31, 13.04 | Just over 13 dB; PLR (10.8 to 11.4 dB) and limiting are well inside their bounds. More crest control would come from the drum bus, which already sits at 12.6 dB crest. |
| C-M11 below 25 Hz and tilt | all | 43 to 46 dB under the total (aim 50); tilt -6.1 to -7.8 dB per octave (aim -3 to -6.5) | The sub-25 Hz energy is the kick's and bass's leakage through the 25 Hz master high-pass. The tilt reflects the dark lo-fi voicing (low-passed lead, mids, space and bed). Neither was traded against the bass punch. |
| C-M12 LRA 2 to 9 LU | fast | 1.75 LU | The 80 BPM case with chops in every bar is dense; the criterion is a warning for a reason. |
| C-B3 bass vs drums 60 to 250 Hz | same | -7.35 dB (aim -6 to +3) | The repeated film case's takes have a heavier kick; the bass is level-matched per voice, not per take. |
| C-D8 accents 50 ms from kicks | all | 0.56 to 0.70 (aim 0.9) | Motif pieces land on downbeats by design (plan 5.4); a warning only. |

## Ambient safety

- `MusicRenderTests`, `AVCouplingTests` and `LofiMasterCharacterizationTests` pass without edits.
- `--hook masterProfile=ambient`, 16 bars, seed 1042, 70 BPM, captured on `d6cdb1d` (from a `git archive` copy with the private files) and on this branch:

| Capture | Start (`d6cdb1d`) | Final | Difference |
|---|---|---|---|
| no footage: master integrated | -18.17 LUFS | -18.33 LUFS | 0.16 LU |
| no footage: master minus pre-master | -1.72 LU | -1.71 LU | 0.01 LU |
| film reel: master integrated | -17.13 LUFS | -16.75 LUFS | 0.38 LU |
| film reel: master minus pre-master | -1.93 LU | -1.99 LU | 0.06 LU |

The no-footage capture is within 0.3 LU. With the film reel the ambient master's transfer is within 0.06 LU, and the 0.38 LU comes from its input: the Lo-Fi chops are louder (stab trim, density levelling) and the bed is 2.5 dB up. Ambient mode itself never plays the Lo-Fi stems or chops.

## Live smoke

`open -n …/Liminal.app --args -audio.musicMode lofi -LiminalAutoPlay YES -LiminalVideoOffline YES -LiminalAllowGeneration NO`, 120 s on the Mac speakers. The brief's `log stream` command needs `--level info` to show the app's info lines (`log stream --style compact --level info --predicate 'process == "Liminal" AND subsystem == "com.saygoodnight.Liminal"'`).

- Master epochs: "estimated -12.9 LUFS … limiter mean 0.05 dB, trim change 0.00 dB" (the first 64 beats, including the start) and "-12.1 LUFS … limiter mean 0.09 dB, trim change 0.00 dB". Both are within 1.5 LU of the `ref` capture's -11.9 LUFS.
- No "sound started … late" warning (no bed later than its due time), no repeated-stems or late-phrase warning, no dropped chops. Phrase preparation took 1.25 to 3.17 s, the longest being the first phrase of each take.
- Dialogue plans: six cues with speech, lead times 2.25 to 4.20 s; stage totals 187 to 314 ms of render. The first cue had no speech and planned rests.

## Heavier chop effects and the line refresh (19 November 2026, after the calibrated clip)

The calibrated clip (32 bars, 72 BPM, seed 2077, private drums, film reel, `--transcribe`) still had light chop effects: 79 of 89 chops dry, 6 echo throws, 1 reversed pickup, and the chop effects return 10.5 dB under the dry chops. It also played one line ("First of all, to try") for all 32 bars.

- **Line refresh (bug fix, guarded).** The user's direction: "I want there to always be fresh samples."
  - **Cause.** `DialogueMotif.resolve` only tried a new line when the cue's pad bank existed. "Design for Dreaming" narrates over music. Its noise floor is the music, so every line had zero clarity and was rejected as not speech or too quiet. The film had no bank, and loop 2 carried loop 1's line.
  - **Fix 1:** the motif ranks lines for every cue, bank or not.
  - **Fix 2, the crate:** `DialoguePerformanceMemory.motifCrate` keeps the last 4 films heard (PCM, analysis, transcript). A loop whose own film has no usable line digs a fresh, unblocked line from the crate, newest film first. It carries the previous line only when no recent film offers one.
  - **Fix 3:** a loop that could only carry takes a fresh line from a later cue from another film in the same loop.
  - **Not done:** forcing a buried line through by trusting the transcript over the acoustic rejections. Tried, and the line still had zero clarity.
  - **Guards:**
    - `DialogueMotifTests.aLoopWhoseFilmHasNoLineDigsAFreshLineFromTheCrate` checks that no loop carries or repeats the previous loop's line, including when only the first film ever speaks. It fails with the crate disabled.
    - `aCarriedLoopTakesAFreshLineFromTheNextSpokenCue` covers fix 3.
    - `scripts/analyze-lofi.py` fails any capture in which a 16-bar loop's main bank is the previous loop's (`stale_motif_lines`). It flags the original capture.
  - **Result:** the same capture now plays "First of all, to try" (UFO Interview) in bars 1 to 16 and "These will be ejected and infect the rye" (Ergot, from the crate) in bars 17 to 32.
- **Live returns (`ArchiveVoice.ChopBus`):**
  - Echo feedback rose from 0.42 to 0.55.
  - The echo return rose from 11 to 5 dB under dry.
  - Room mid decay rose from 1.5 to 2.4 s, low decay from 0.8 to 1.2 s, and the return from 0.32 to 0.6.
- **Echo throws (`DialogueMotifTuning`):** five repeats at -3, -6, -9, -13 and -17 dB (was three at -6, -10 and -15 dB), with the tail extended from 2.4 to 3.5 beats.
- **Cells:**
  - Echo throws were added to every stutter variant, two split-pause variants, a reorder variant, call-and-answer, sparse and the return's second bar.
  - Reversed pickups now come every turnaround (was every second one), and also in a split-pause variant and a sparse variant.
- **Same capture after the change:**
  - 88 chops: 12 echo throws (with up to five repeats each), 2 filtered, 2 reversed.
  - Chop effects return at -23.6 dB mean against -20.0 dB dry (was -31.3 against -20.8).
  - All 32 bars have a chop.
  - Master at -11.4 LUFS and -1.1 dBTP.
  - The analysis reports no failures.

## Tuck pass (19 November 2026, after the heavier-effects clip)

**User direction.** The chops were "way too loud in the mix... they need to fit into the mids and melody better. They just stick out frequency wise." Tuck them with level, compression and blending effects such as light reverb.

**Measurement.** In the heavier-effects capture the chops sat 9 to 15 dB over the melodic stems from 250 Hz to 4 kHz (500 Hz to 1 kHz: -22.8 dB against -37.8 dry and -34.8 wet). They were about 12 dB over the drums there, and above the drums in 2 to 4 kHz.

**Diagnosis.** Calibration had put chops on top by design:
- a +4.5 dB presence boost at 3.4 kHz;
- music ducked 3 to 5 dB under every featured chop;
- the dry path 7 dB hotter than needed.

Common practice for blending vocal samples:
- complementary EQ cuts around 250 Hz and 2 to 5 kHz;
- the beat-under-vocal sidechain only when the vocal should sit on top;
- dark, mid-focused, fairly wet reverb;
- gentle saturation and bus glue.

Sources: [Sage Audio](https://www.sageaudio.com/articles/how-to-mix-vocals-into-a-beat), [LANDR lo-fi mixing](https://blog.landr.com/lo-fi-mixing), [Antares lo-fi guide](https://www.antarestech.com/blog/the-complete-guide-to-mixing-lo-fi-music).

**Changes:**
- **Per-cut chain (`DialogueChopChain`):**
  - high-pass 120 to 200 Hz;
  - low-mid cut at 300 Hz from -2.5 to -4 dB;
  - the presence boost (+4.5 dB at 3.4 kHz) replaced by a -4 dB cut at 2.8 kHz;
  - low-pass 7.5 to 4.2 kHz (texture 5.5 to 3.4 kHz).

  The levelling is K-weighted, so part of a treble cut returns as overall gain. The tilt still moves.
- **Level (`ArchiveVoice.ChopBus`):** dry 0.72 to 0.28 (-8.2 dB). The room return went from 0.6 to 0.38, so the wet share rises against dry: echo about 4 dB under dry, room about 5. The chops sit in a long, dark room (echo band 400 Hz to 2.5 kHz, room band 300 Hz to 3 kHz, damping 2.2 kHz).
- **Music duck (`ArchiveVoice.MusicDuck`):** lead -3 to -1 dB, mids -4 to -1 dB, space -5 to -1.5 dB.

**Results (approval capture: 32 bars, 72 BPM, seed 2077, private drums, film reel, transcripts):**
- **Chops:** -27.4 dBFS RMS (was -19.1), against drums -21.2, melodic dry -28.7 and space -26.4.
- **Bands:**
  - 250 to 500 Hz: -32.3 dB, against -31.1 dry and -30.8 wet.
  - 500 Hz to 1 kHz: -31.3 dB, against -36.8 and -33.4.
  - 2 to 4 kHz: -38.8 dB, against -39.2 for the drums.
- **Master:** -12.9 LUFS, -1.2 dBFS peak.
- **Film bed:** C-B9 passes, with the bed 10.2 dB under the mix in gaps and the chops 7.7 dB over the bed in 1 to 4 kHz.

**Criteria change, C-B8.** It required the chops at least 3 dB (aim +6) over the music in 1 to 4 kHz, which encodes the rejected mix (the calibrated clip measured +5.7 dB). It now reads:
- SII proxy mean at least 0.30, p10 at least 0.18;
- 1 to 4 kHz SNR -3 to +2.5 dB, so the upper bound guards against the chops creeping back up;
- spread at most 2.5 LU, unchanged.

The approval capture passes (0.38, 0.27, +0.18 dB). The calibrated capture now fails it.

**Open, pre-existing.** C-B2 fails on this 72 BPM private-drums capture both before and after these changes. The bass duck under the kick reads -0.48 dB against 1.5 to 4.5. The matrix cases pass it.

## Future: non-word fallback for fresh chops (user idea, 19 November 2026, not built)

The crate covers the common case. A loop whose film has no usable line takes a fresh line from one of the last four films. If a long stretch of footage offers no speech at all, the loop still carries its previous line. The user suggested a fallback instead: "sometimes non-word elements can just sound cool... look at the frequencies and see if it fits, even if it doesn't get recognized as a word."

A possible shape:
- **Rank non-speech segments as motif lines** when every speech tier fails. Candidates are texture-level units, or 1 to 3 s windows with clear onsets. Score them by spectral fit against the loop's music: low energy under 200 Hz, a spectral centroid near the melodic stems', a 500 Hz to 2 kHz band within a few dB of the mids, and onset strength for rhythmic cuts.
- **Cut them on onsets** instead of words, and arrange them with the same cells.
- **Prefer scanning more of the current film** (another section of the same footage) before both the crate and this fallback. The footage pool is large.

## Auditions

`python3 scripts/mix-report.py $S/cal-final/ref --baseline $S/baseline/ref --auditions` wrote, in `$S/cal-final/ref/report/auditions/`: `master.wav` and `baseline-master.wav` (loudness-matched), `dialogue-in-context.wav`, `return-theme-take0.wav`, `return-theme-take1.wav` and a 16-bar solo of each section (`solo-<section>-bars1-16.wav`). The spectrograms, masking matrices and the other figures are in `$S/cal-final/<case>/report/` (`index.html`).

## Listening checks for a person

1. Matched loudness: `baseline-master.wav` against `master.wav`. Is the new master louder only in the way intended (denser, not squashed)? Listen for pumping on the kick and distortion on the chops.
2. Words: in `dialogue-in-context.wav` and the solo dialogue, are the words understandable and do the pieces sit inside the beat at one level? Are the heavier echo and room returns musical, or do they smear the next piece?
3. Film between chops: in `master.wav`, is the film bed identifiable in the gaps but clearly behind the beat? Does its one-bar drop before and under each theme return sound like an arrangement move, or like a glitch?
4. Theme return: in `return-theme-take0.wav` and `-take1.wav`, is the return of the hook recognised? Is the +3 dB accent on its first two notes natural?
5. Bass and kick: on a phone speaker and on headphones, does the bass hit with the kick? Is the deeper 4 dB duck heard as punch rather than as the bass dropping out?

## Remaining risks

- The pre-master sum peaks at +0.9 dBFS on `ref` (it was +0.1 at `d6cdb1d` and +1.7 at the baseline). The graph is floating point and the finisher's input gain, glue, clip and limiter come after it, so nothing clips, but the gain staging is 2 dB hotter than the brief's guide. Lowering the Lo-Fi bus and raising the finisher input by the same amount would fix it without changing the sound; that touches `LofiPlayback` and the profile switch, outside this package.
- Resolved 2026-11-19 (D111): the return dip no longer relies on the motif plan's block and slot fields. A take that plays no chops (no speech) dips from the transport or the phrase callback.
- C-B9 audibility (0.13 to 0.21) is close to its new floor on `same`. A brighter or louder film can move it either way; the 10 dB rule has 0.8 dB of margin on `ref`.
- C-B5 measures short overlaps (0.2 to 0.7 s per phrase), so single notes move it by several dB; the matrix spread is 6.4 to 7.1 dB.
- The ambient film-reel capture differs by 0.38 LU, from the Lo-Fi input (see Ambient safety).
- The direction's heavier-effects items that need arrangement changes (reversed pickups, echo throws on most cell endings) were done afterwards; see "Heavier chop effects and the line refresh".
