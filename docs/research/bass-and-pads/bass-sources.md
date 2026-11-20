# Bass sample sources (CC0 only shortlist)

Research only. Nothing added to the repo. Small inspection downloads are in `downloads/` (not executed).
Repo state checked: `InstrumentSamples/` ships LofiLead-* only (upright = VSCO/KW pizz, flatwound/jazzbox/archtop guitar leads). No bass samples are bundled; `LofiBassVoice` is pure synthesis (sine + 2nd/3rd harmonic, 0.005-0.018 s rise, 0.18-0.42 s release). `docs/research/instrument-sources.md` already lists D. Smolken pizz double bass (CC0) as pick #7 and VSCO Contrabass Pizz; the licence rules (CC0 first, no EULA freebies, Pianobook/Spitfire/Ableton/Splice rejected, CC-BY only with a modified note) are applied here too.

All repos below: GitHub spdx `CC0-1.0`, `LICENSE` = "Creative Commons Legal Code / CC0 1.0 Universal" (checked via API 2026-11-20). Download pattern that works: `https://github.com/sfzinstruments/<repo>/raw/refs/heads/<branch>/<path>` (plain raw URLs 404 for some paths; zips are release assets).

## Ranked top 3 for this use
1. **Karoryfer Sneakybass** (double bass, pluck / ghost / mute) - best boom bap + dub character.
2. **Karoryfer Swagbass** (flatwound bass guitar, "dark and percussive") - best "tight and punchy electric" layer, plus 3 velocity layers and released notes.
3. **FreePats Finger Bass YR + FreePats Lately Bass** (tiny CC0 bundle; clean DI finger bass as a sub/body layer, FM "Lately Bass" as a ready sub/tone) - cheap, tiny, zero licence risk; use as layers rather than a main voice.
Runners-up: Karoryfer Ergo EUB (pizz, reaches E0), Big Little Bass (very low, 2 vel layers), Growlybass.

## Candidate details

### Sneakybass (Karoryfer, double bass played pizzicato at "sneaky late-night volume")
- Repo `sfzinstruments/karoryfer.sneakybass` (branch main), release v1.000 `Sneakybass_v1.000.zip`, 340 MB zip, 415 MB WAV. https://github.com/sfzinstruments/karoryfer.sneakybass ; article https://bedroomproducersblog.com/2022/12/09/karoyfer-sneakybass/
- Licence: LICENSE = CC0 1.0 Universal.
- Articulations (folders): `finger` (148 wavs, normal pluck), `pluck` (148), `ghost` (144; compared to palm-muting), `mute` (148; compared to slap/dead), `noise` (72 fingering/release), 4 round robins per note, chromatic ~every semitone over 3 octaves (c2..c5 per filename pattern `sneakybass_<note>_<art>_rr<n>.wav`), release noises 2 RR.
- Format: 44.1 kHz, 24-bit, STEREO WAV, 2-2.5 s each. Inspected: ghost D2 decays -20 dB at 0.4 s, -40 dB at 0.95 s (short, tight, almost no energy above 2 kHz: -66 dB); mute E2 -20 dB at 0.35 s; finger E2 sustains (-20 dB at 1.15 s, -63 dB above 2 kHz = very warm/dark).
- Judgement: best fit. Ghost and mute are the short punchy boom bap notes; finger is the longer dub note. Very dark, so needs a touch of added attack/saturation to cut through lo-fi. Stereo files need mono fold (the repo's prep script already folds to mono). Pitch labels need verification: E2 measured dominant ~41 Hz and ~65 Hz peaks (likely body/2nd harmonic); run the repo's `prepare-lofi-samples.py measure` as in the existing 2026-11-19 recipe (they found octave-label errors elsewhere).
- Credit string suggestion: "Sneakybass by Karoryfer Samples, CC0".

### Swagbass (Karoryfer; bass guitar with 10-year-old FLATWOUND strings, "darker, more percussive")
- Repo `sfzinstruments/karoryfer.swagbass` (master), v1.001 zip 145 MB; https://github.com/sfzinstruments/karoryfer.swagbass ; description https://www.kvraudio.com/news/karoryfer-releases-two-free-bass-sample-libraries-wav-sfz-26183
- Licence: CC0 1.0 (LICENSE file; GitHub spdx CC0-1.0).
- Content: `notes/` 240 wavs = notes every minor third (A1, C2, Eb2, Gb2, A2, C3 ... up to C5/Eb5), 3 velocity layers (p / f / fff), 5 round robins; `release/` 51 (release thunks), `noises/` 50 (fingering, palm mute, slap-muted, strum noises); `a3_open_*` open-string variants. 5 SFZ mappings (clean, shiny, "things"). Mono 44.1 kHz 24-bit, 5.6 s each.
- Inspected: A1 f peak -9 dB, -20 dB at 2.85 s; Eb2 fff -20 dB at 0.75 s; energy above 2 kHz -41 to -54 dB (dark). Lowest sampled note A1 (55 Hz); no E1/low-B, so E1 and below need pitch-shift down a minor third to a fourth (acceptable for sub notes, or layer with Lately/sine sub).
- Judgement: good punchy fingered/flatwound electric, true multi-velocity; "mutedc/mutedd" noise files hint at palm-mute use, but pitched palm-muted notes are not separate. Excellent for the tight "boom bap" body; combine with sub layer. Sparser pitch grid (minor thirds) needs +/-2 semitone repitching, fine with the existing sampler.

### Ergo EUB (Karoryfer; electric upright, piezo)
- Repo `sfzinstruments/karoryfer.ergo`, release v1.001 `Karoryfer.Ergo_EUB.v1.001.zip` 200 MB. CC0-1.0. https://github.com/sfzinstruments/karoryfer.ergo
- `ergo/pizz` 165 wavs (e0..A3, minor-third grid, 3 velocities p/mf/f, 2 RR), `ergo/arco` 172, `ergo/kicks` 61 (body-thump one-shots, tuned a/c; could be tonal "boom" accents).
- Mono, 44.1 kHz, 32-bit float. Pizz E0 f: 6.4 s, -20 dB at 3.6 s, content almost all below 150 Hz (>2 kHz -27 dB). Reaches true low E0/E1 which Swagbass/Sneakybass do not: a good "fundamental/dub" voice. Notes sustain long, so must be gated/shortened by envelope.

### Growlybass (Karoryfer; Squier Jazz bass) / Fashionbass / Pastabass (Bass VI) / Black and Blue Basses / Big Little Bass
- All CC0-1.0 (API checked). Sizes: Growlybass 167 MB (pp/p/f/ff sustain, staccato, release, 14 notes; mono 24-bit; v1.002), Fashionbass 316 MB, Pastabass 315 MB (Bass VI, baritone, higher range), Black and Blue 1.0 GB (2 five-string basses; darkblack reg p/mp/mf/f, ghost, stac, btb; best articulation depth but huge), Big Little Bass 264 MB (Washburn AB95 hollowbody; README: "Royalty-free for all commercial and non-commercial use. CC-0 license."; p/f, b1 lowest, 5 RR; note B1 sample runs ~10 s with f0 ~31 Hz sub).
- Growlybass staccato is a clean short bass-guitar pluck; bright (>2 kHz only -9.5 dB at staccato) - useful as the attack-transient layer. Black and Blue "ghost" and "stac" are the closest to a recorded palm-mute/dead-note kit, but 1 GB means pull only 5-8 files.
- URLs: https://github.com/sfzinstruments/karoryfer.growlybass , .fashionbass , .pastabass , https://github.com/sfzinstruments/karoryfer.black-and-blue-basses , https://github.com/sfzinstruments/karoryfer.big-little-bass

### FreePats Finger Bass YR (Yamaha RBX, finger) and Pick variation
- https://freepats.zenvoid.org/ElectricGuitar/clean-electric-bass.html ; release https://github.com/freepats/electric-bass-YR/releases/download/2019-09-30/FingerBassYR-SFZ+FLAC-20190930.7z (3.2 MB; pick version similar size).
- Licence quote (page + README.txt): "sent for inclusion in FreePats on September 2019, under the terms of the Creative Commons CC0 1.0 public domain dedication." LICENSE.txt in the archive.
- 12 chromatic samples E1(key 28)..D#2, one velocity, mono 44.1 kHz 24-bit FLAC, 2.6-5.7 s; very clean DI tone (>2 kHz -51 to -68 dB), SFZ `ampeg_release=0.5`, last sample mapped up to key 45. Direct, one-layer, tiny. Good low-register sustained fundamentals (E1 reaches 41 Hz), weak as a character voice on its own (no articulations).
- Credit: "Finger Bass YR by Andrea Biasior / FreePats, CC0".

### FreePats Lately Bass (FM, TX81Z "Lately Bass" patch by Yingchun Soul, via Dexed)
- https://github.com/freepats/lately-bass/releases/download/2024-04-09/LatelyBass-SFZ+FLAC-20240409.7z (1.2 MB). README: "Published under the terms of Creative Commons CC0 public domain dedication".
- 11 mono 44.1 kHz 16-bit samples, a tritone-spaced multisample C1 to F#5 (C1 5.7 s, fundamental 32.8 Hz), sustained but with a plucky FM attack; >2 kHz at -58 dB in the bass register. Judgement: the classic 80s/90s FM "Lately" bass is a snappy tonal sub; cheap to try as the "new tone" layer under the sampled pluck (sub support in dub). Also covers pitched lead-ish register, not needed.

### Others examined
- **D. Smolken / Karoryfer Meatbass** (1958 Otto Rubner upright, pizz): CC0-1.0 (spdx). Release `DSmolken.double_bass.v1.001.zip` 265 MB (and `karoryfer.meatbass` v1.001 255 MB). Already in the repo's plan (instrument-sources D.1). A cleaner, more jazz upright than Sneakybass; sustains long. Use if Sneakybass proves too dark/too articulation-heavy.
- **VSCO 2 CE Contrabass Pizz** (CC0, already in use as VSCO source): older sample quality, fixed pitch grid.
- **Rickenbacker 4001** (project16 multisample): CC-BY-NC-SA-3.0 per sfzinstruments catalog -> REJECT (non-commercial).
- **Standard Bass** (sfzinstruments): licence listed "Custom" -> skip. **Kalimbass** (MIT, electric kalimba bass) is not suitable as a boom-bap bass. **Baconwulf / Beefowulf / Karniszbass / Secret Agent Bass**: commercial -> reject. (Beefowulf is the R&B/hip-hop bass; paid.)
- **Squier Bass VI / "Precision Bass (Markus Fiedler)"**: licence unconfirmed -> do not use.
- **Pianobook, Spitfire LABS, Ableton, Splice, samplefocus 808 kits**: EULA/"royalty free" licences forbid redistributing the sample files -> reject (samplefocus listings say "Standard Licensing - Royalty Free", not CC0).
- **Salamander, Philharmonia, Iowa MIS double bass**: Salamander has no bass; Philharmonia is free-use but not a clean redistribution grant; Iowa MIS has its own "free to use" grant already weighed in instrument-sources. Not pursued further for bass.
- **808 / sine sub**: no verified CC0 tuned 808 multisample found in this pass. Recommendation: do not source one; synthesise the sub (tuned sine + short pitch drop, which `LofiBassVoice.roundSub` already approximates) and layer it under the sampled pluck. Freesound CC0 808s exist but need per-file licence audit and login; a tuned-808 search with the CC0 filter is a follow-up if desired.

## Implementation notes
- Keep the repo's pipeline: `scripts/prepare-lofi-samples.py` (fold to mono, 32 kHz, 45 Hz high-pass, -10 dBFS body match, pitch measure within 50 cents). Bass notes need a lower high-pass (about 25 Hz) and probably 44.1 kHz (the pipeline's 32 kHz is fine since bass content < 4 kHz and the attack click can be restored with a short synthesised transient).
- Pull list suggestion (about 40-60 files, under ~10 MB at 32 kHz mono 16-bit): Sneakybass finger+ghost+mute, e2/g2/a2/c3/eb3 roots, rr1-rr2, at about 1.2 s with a 0.2 s tail; Swagbass f and fff, a1/c2/eb2/gb2/a2 (low register) rr1-rr2, trimmed to ~1.5 s; Ergo pizz e0/Gb0/A0/C1 f for sub reinforcement or FreePats Lately C1/F#1.
- Attribution lines go in `docs/lofi-samples.md` as with the existing CC0 entries.
