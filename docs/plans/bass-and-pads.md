# Lo-Fi bass and pad rework: implementation plan

Repo `/Users/pj4533/Developer/Liminal`, base `main` at d5c6521. Approved baseline capture: `$S/final-main` (seed 2077, 72 BPM). Research inputs are in `docs/research/bass-and-pads/`.

Numbers below marked "start" are starting values to be tuned against the capture; numbers marked "gate" are acceptance limits.

## 0. Decisions in one page

**Bass.** A two-layer voice replaces the three synthetic colours:
- A synthesized sub (sine, 2nd at -14 dB, 3rd at -20 dB) owns everything below 150 Hz. It is phase-exact, so the kick alignment stays measurable.
- A sampled body (CC0 upright or flatwound electric, high-passed at 150 Hz) carries note identity from 150 Hz to about 2.5 kHz. This is the "carry" that the current near-pure sub lacks (bass 250-500 Hz is 20 dB under its 60-120 Hz today).
- The line becomes a repeated two-bar riddim figure built from the take's own kicks: 3 to 5 notes per bar, three note lengths, rests, pickups, one drop-out per 16 bars.
- Effects: more harmonic saturation, a per-note filter envelope, a quiet mono tape slap on the upper band, and dub throws (echo plus spring) on selected notes. Throws go into the existing wet stem, so the low end stays dry and mono and routing identity (C-B10) holds.
- C-B2 is kept unchanged. Every note that lands on a confident kick is anchored the way beats 0 and 8 are today; the behind-the-beat notes are never placed near a kick, so they are not timed by C-B2.

**Pads.** The chord channel becomes a held three-voice pad plus an occasional answer shell:
- The pad sounds for almost the whole phrase (one chord per phrase is how the score already works), with one legato inner revoicing at bar 3.
- The sound is a granular "frozen" sustain of the phrase's own lead sample, so it stays in the acoustic family but has a 0.3 s swell and no re-attacks.
- It sits lower in level (6.5 dB under the lead in 400 Hz to 3 kHz, was 3.5), higher in register floor (HPF 220 Hz), darker (LPF 2.8 kHz), ducks 2 dB under lead notes, and sends mostly to plate and room.
- The dry pad breathes at each phrase boundary (release ends at the edge, new swell starts) and the reverb tail, which already carries across phrases, bridges it. This keeps every dry stem a fixed n-frame buffer and leaves `LofiPlayback` and the late-phrase fallback untouched. A true dry carry is specified as an optional step (P7) only if the breath is audible.

**Not changed:** drum takes and their chain, lead scoring and level, chops, film bed, master chain, `LofiPlayback`, `LofiBus`, any realtime path. Everything new runs in the offline per-phrase render.

## 1. Work packages and file ownership

Four steps: PREP (serial, small), then BASS and PADS in parallel worktrees, then MIX (serial).

### 1.1 PREP: split the shared files (one commit on `main`, behaviour identical)

Both packages need `LofiScore.swift`, `LofiRenderer.swift` and `LofiStemChains.swift`. PREP moves each package's region into its own file so the parallel work never touches the same hunk. No audio change: the six Lo-Fi suites in section 5.1 must pass unmodified, including the sample-exact bass test.

1. `LofiScore.swift`: make `Harmony` internal (drop `private`). Move `bassLine`, `kickRises`, `bassVoice(seed:section:phrase:)`, `bassAccent*`, `bassShortestLength` verbatim to new `Liminal/Audio/Lofi/LofiScore+Bass.swift`. Move `mids`, `voicing`, `midOnsetClearance`, `midLatestEnd` verbatim to new `LofiScore+Mids.swift`.
2. `LofiScore.Note`: add defaulted fields `var stroke: BassStroke = .walk` and `var slide: Int = 0` (semitones of glide-in). Add `enum BassStroke: Int, Sendable { case thump, walk, hold, ghost }`. Append `pad` to `Articulation`. Add `var bassSweep: ClosedRange<Double>? = nil` to `LofiScore`.
3. `LofiRenderer.swift`: move to new `LofiRenderer+Bass.swift` three functions with the current code inside: `addBass(_:score:clock:samples:left:right:)` (the `.bass` case of the note loop), `finishBass(...)` (the block from "Bass: mono chain" through the kick duck and the copy to R), and `reportBass(...)`. Add a no-op `addBassThrow(score:clock:frames:into:)` called once just before `LofiStemChains.applySpace`. Move to new `LofiRenderer+Texture.swift`: `addTexture(...)` (the texture branch of the note loop), `midsLevel`, `upperShellVoices`, the `mids*` constants, `reportMusicLevels(...)`, and `mixTexture(...)` (the two `vDSP` lines that write the texture stem).
4. `LofiStemChains.swift`: move `Bass` + `applyBass` to `LofiStemChains+Bass.swift`, and `Mids` + `applyMids` to `LofiStemChains+Mids.swift`.

After PREP, `LofiScore.swift`, `LofiRenderer.swift` and `LofiStemChains.swift` are frozen for BASS and PADS. If either needs a change there, it sends the exact diff to the orchestrator, who applies it on `main` and both rebase.

### 1.2 Ownership table

| Package | May create or edit | Tests it may edit |
|---|---|---|
| BASS | `LofiBassVoice.swift`, `LofiScore+Bass.swift`, `LofiRenderer+Bass.swift`, `LofiStemChains+Bass.swift`, `LofiSidechains.swift`, new `LofiBassSamples.swift`, new `LofiBassThrow.swift`, new `InstrumentSamples/LofiBass-*.wav`, `scripts/prepare-lofi-samples.py`, `scripts/lofi-sample-recipes.sh`, `docs/lofi-samples.md` | Bass tests listed in 2.8, in `LofiRhythmTests`, `LofiArrangementTests` (bass tests only), `LofiCompositionTests` (bass assertions only), `LofiStemChainTests` (bass and kick-duck tests only), `LofiProductionTests`; new `LofiBassLineTests.swift`, `LofiBassVoiceTests.swift` |
| PADS | `LofiScore+Mids.swift`, `LofiRenderer+Texture.swift`, `LofiStemChains+Mids.swift`, `LofiEffects.swift`, `LofiSynth.swift` (texture branch), new `LofiPadVoice.swift` | Mids tests listed in 3.8, in `LofiArrangementTests` (mids tests only), `LofiCompositionTests` (shell assertions only), `LofiGuitarPhrasingTests`, `LofiStemChainTests` (mids and space tests only); new `LofiPadTests.swift` |
| MIX | Any constant in the files above, `ArchiveVoice.MusicDuck` values, `scripts/mix-criteria.json` (only with a written reason), new `scripts/stem-bands.py`, all docs in section 7 | Any, with a reason |

Shared test files (`LofiArrangementTests`, `LofiCompositionTests`, `LofiStemChainTests`): each package edits only its own `@Test` functions and adds new tests in its own new file, so merges are hunk-disjoint. `LofiGuitarPhrasingTests` l.47 (bass identical across programs) stays true and BASS must not break it. Neither package writes docs except `docs/lofi-samples.md` (BASS); each leaves a `NOTES-<package>.md` in the scratchpad with measurements for MIX to fold into the docs.

### 1.3 Worktrees

- `git worktree add ../Liminal-bass -b pkg/bass main` and `../Liminal-pads -b pkg/pads main`, after the PREP commit.
- Copy the gitignored inputs into each worktree and never stage them: `Liminal/Secrets.swift`, `Liminal/SlowBurnDrums/`, `Liminal/Audio/Lofi/SlowBurnBeatGrid.json`. Check `git status` shows them ignored before every commit.
- One Liminal process at a time across all worktrees. Every `xcodebuild test` and every capture is wrapped in a shared lock: `until mkdir <scratchpad>/liminal-run.lock 2>/dev/null; do sleep 20; done; <command>; rmdir <scratchpad>/liminal-run.lock`. Captures also pass `--wait-lock 3600`.
- Commit as you go on the package branch. Do not push.

## 2. BASS package

### 2.1 Source

Synth sub plus sampled body, two body kits, one kit per 16-bar take (seeded), so a take is consistent and takes differ.

| Kit | Library | Licence | Use |
|---|---|---|---|
| `upright` | Karoryfer Sneakybass v1.000, https://github.com/sfzinstruments/karoryfer.sneakybass (branch `main`) | CC0-1.0 | `ghost` and `mute` for short notes, `finger` for medium and long. Boom-bap upright thump. |
| `flatwound` | Karoryfer Swagbass v1.001, https://github.com/sfzinstruments/karoryfer.swagbass (branch `master`) | CC0-1.0 | `fff` for short notes, `f` for medium and long, `p` for ghosts. Dub flatwound roundness. |

No sub sample is bundled: the sub is synthesized (research found no verified CC0 tuned 808, and a synthesized sub is what keeps the alignment exact).

**Pull list** (start; about 44 files, under 4 MB prepared). Download single files with `https://github.com/sfzinstruments/<repo>/raw/refs/heads/<branch>/<path>` into a new empty directory under the scratchpad; run nothing from it; read with `python3 -I`.
- Sneakybass: `ghost`, `mute`, `finger` at e2, g2, a2, c3, eb3, round robins 1 and 2 (30 files). Labels are probably an octave above concert pitch (the research measured about 41 Hz on "e2"): measure first.
- Swagbass: `p`, `f`, `fff` at a1, c2, eb2, gb2, a2, round robin 1 (15 files).

**Prepare recipe.** Extend `scripts/prepare-lofi-samples.py` (keep lead behaviour as default): `--prefix LofiBass` (output `LofiBass-<kit>-<stroke>-<midi>[-<rr>].wav`, stroke one of `short`, `long`, `ghost`), `--retune` (resample by the measured deviation so each file is within 3 cents; refuse over 50 cents as now), and a pitch search floor of 30 Hz. Per group: `--highpass 25 --lowpass 5000 --duration 1.4 --fade 0.25` for `short` and `ghost`, `--duration 2.2 --fade 0.5` for `long`; `--body-db -10`. Add both groups as cases in `scripts/lofi-sample-recipes.sh`, then run `prepare-lofi-samples.py measure` on the results and record pitch, body level and roll-off in `NOTES-bass.md`. Files go to `Liminal/Audio/Lofi/InstrumentSamples/` (the synchronized group bundles them; `LofiSampleBank` ignores the `LofiBass` prefix). Tight tuning matters because the body's 150-260 Hz overlaps the sub's 2nd and 3rd harmonics.

`LofiBassSamples.swift` (new, `nonisolated`, `Sendable`): loads `LofiBass-*`, returns the nearest root for (kit, stroke, midi) with round robin chosen by a note hash. Mono only, 3 s limit, same decoding as `LofiSampleBank.load`.

**Fallback.** With no sample (or if a kit fails the measure step), the body is the existing `pluck` bright burst (2nd to 4th harmonics fading over 90 ms). If Sneakybass proves unusable after measurement, ship `flatwound` only and note it; do not substitute an unverified library.

### 2.2 Voice (`LofiBassVoice.swift`)

Keep `classic` bit for bit (frozen test). Remove `roundSub`, `pluck`, `longAnswer` from score selection; delete them and their tests once the new voices pass, unless reused as the fallback body. Add `upright` and `flatwound`.

Per note, by `stroke`:

| Stroke | Sounding length at 72 BPM | Sub rise | Sub shape | Body sample | Release |
|---|---|---|---|---|---|
| `thump` | 0.15-0.30 beats (125-250 ms) | 1.5 ms | pitch falls 12 semitones to the note over 8 ms; level decays 10 dB across the note | short | 60 ms |
| `walk` | 0.5-0.75 beats (400-600 ms) | 3 ms | steady | long | 90 ms |
| `hold` | 1.0-2.0 beats (0.8-1.6 s) | 4 ms | decays 3 dB per second | long | 160 ms |
| `ghost` | 0.12-0.20 beats, velocity 0.30-0.50 | 3 ms | steady | ghost | 50 ms |

- Sub: zero start phase, phase-accumulating, `tanh` drive 1.2, harmonics 2nd 0.20 and 3rd 0.10. `slide` glides in from that many semitones below over 45 ms (raised cosine).
- Body: high-pass 150 Hz (24 dB/oct), then a 12 dB/oct low-pass with no resonance whose cutoff is `650 + 300 v + 1100 v e^(-t/0.04)` Hz (v = velocity), so velocity drives brightness as well as level. Body level start: 8 dB under the sub's RMS.
- `thump` only: 3 ms Hann click at 1 kHz, 20 dB under the body.
- Mono, all envelope corners raised cosines, exact zero after the release.
- `lowRiseLead(midi:stroke:)` renders the complete voice (both layers) and is cached per (voice, stroke, midi, sample rate) in a `Mutex`-guarded dictionary. It is called off the audio thread only.
- Loudness: the two kits within 1 dB RMS of each other per stroke at MIDI 28, 33, 38, 41.

### 2.3 Chain (`LofiStemChains+Bass.swift`, `LofiRenderer+Bass.swift`)

In order, all mono, start values:

1. HPF 30 Hz (unchanged; fundamentals stay at 41 Hz and above, C-M11 already warns).
2. Parallel harmonics: drive 4, bias 0.2 to 0.08 (more odd-order, tape-like), band 150 Hz to 1.2 kHz (add the low-pass), mix 0.20 to 0.28.
3. Compressor 4:1, knee 6 dB, attack 25 ms, release 150 ms, threshold p95 minus 7 dB, makeup up to 5 dB. Target 3 to 5 dB mean reduction on held notes, max 6.5.
4. EQ: +1.5 dB at 80 Hz (Q 0.9), -2 dB at 280 Hz (Q 1, unchanged), +2 dB at 700 Hz (Q 0.8), LPF 2.8 kHz (was 4.5 kHz).
5. Tape slap on the band above 220 Hz only: one repeat at an eighth of a beat (104 ms at 72 BPM), feedback 0.15, low-pass 1.8 kHz, 15 dB under that band. Mono, so the stem stays L = R.
6. Output trim set so C-B3 bass against drums in 60-250 Hz reads -2 to +1 dB.
7. `headroom`, 4 ms edge, then the kick duck. Split the duck at 150 Hz: full depth (4 dB, 3 ms, 100 ms, landmark keyed, unchanged) below, one third of the depth above, so the kick clears the sub while the body keeps sounding.
8. Breakdown phrases with `score.bassSweep`: the body low-pass base sweeps 250 to 900 Hz across the given beats (dub filter movement), once per 8 phrases at most.

### 2.4 Throws (`LofiBassThrow.swift`, `addBassThrow`)

- A bass note with `send > 0` is thrown. Its body layer alone (no sub) is rendered into a send array, high-passed at 250 Hz.
- Echo: 0.75 beats (625 ms at 72 BPM), feedback 0.35, in-loop low-pass 2.5 kHz with `tanh`, right tap 12 ms later than left. Spring: decay 1.1 s, pre-delay 30 ms, 6 dB under the echo.
- The return is added to the space arrays before `applySpace` (which high-passes at 350 Hz), so it takes the lead-keyed space duck, the chop duck on the wet fader, `returnCarryGain` in the return phrase, and the carried `Tail`. No new stem, tap or fader.
- Level: the throw's strongest 400 ms sits 20 dB (gate 18 to 24) under the bass stem's strongest 400 ms, measured in the finished wet stem.
- Frequency: start one guaranteed throw per 16 bars (the last note before the drop-out) plus a 50 percent chance on the last note of the phrases at take positions 1 and 3. About one per 8 bars. Never on consecutive notes.

### 2.5 Line writing (`LofiScore+Bass.swift`)

The phrase is 4 bars. The line is a two-bar cell stated in bars 1-2 and repeated in bars 3-4 with a change in bar 4. The cell is seeded per take (`phrase / 4`), so the same figure runs for 16 bars and changes with the drum take.

1. **Kick slots.** Quantize the take's confident kicks (confidence at least 0.6) in the phrase to sixteenths. Without a timing field, use the legacy kick list and the 0.075 beat snap.
2. **Anchored notes.** Beat 0 always carries the root. Each other kick slot gets a note with probability 0.75 (always for the kick nearest each bar line). Every such note is anchored exactly as beats 0 and 8 are now: it starts `lowRiseLead` before the kick's low-band rise and records a `BassAnchor`. Stroke is `thump` when another note or kick follows within a beat, else `walk`.
3. **One weight note per two bars.** A `hold` of 1.0 to 2.0 beats on the root or fifth, on beat 0 or the kick nearest beat 2.5.
4. **Gap answers.** One or two per cell, at sixteenths at least 0.25 beats from any confident kick or snare (`timing.snares`), preferring the "and of 2", "a of 3" and "and of 4". Strokes `thump`, or a `ghost` 0.25 beats before a main note. These sit behind the beat: grid plus pocket 0.020 to 0.045 beats plus the timing-field lean, as now.
5. **Pickup.** A `thump` at 7.5 or 7.75 and at 15.5: fifth, octave, or an approach tone a step below the root.
6. **Kick safety.** A non-anchored note is never within 0.20 beats of a confident kick; if it would be, it moves onto the kick and becomes anchored. The predecessor of any anchored note ends its release 30 ms before it (existing clearance, now for every anchor).
7. **Density and rests** (gates for tests): 3 to 5 notes per bar in theme, variation and return; 2 to 3 in the answer's bars 3-4; 1 to 2 per bar in the breakdown. Sounding length per bar at most 2.6 beats. Per phrase 6.5 to 9.5 beats of 16 sounding. Stroke mix near 50/30/20 thump/walk/hold, ghosts at most 2 per phrase.
8. **Pitch.** Root 45 to 55 percent of notes, fifth 20 to 25, octave at most 10, flat seven, minor third or approach tone at most 20, all from the phrase's scale. Structural notes stay in MIDI 28...41; octave leaps and pickups may reach 53. At most one `slide` per phrase (2 to 5 semitones, into a non-anchored `walk` or `hold`).
9. **Sections.** Theme: the cell. Variation: the cell with a changed bar 4 and one octave leap. Answer: bars 1-2 on the fifth-degree root, then home. Breakdown: half density, the filter sweep, and a drop-out over the last 2 to 4 beats with the note before it thrown. Return: beat 0 is a `hold` at velocity 0.90 (the slam back), then the full cell.
10. Every note ends, release included, by beat 16. `beat >= 0`.

### 2.6 Level target

Bass as important as the drums: bass stem within -1.0 to +0.5 LU of the drum stem in `solo-stems.py`, active 45 to 65 percent (28 today). C-B3 60-250 Hz -3 to +1 dB against drums; harmonics ratio at least -12.5 dB (-14.7 today).

### 2.7 C-B2

Unchanged definition and thresholds. More notes are anchored, so `alignedAccents` rises from 8 to at least 24 per 32 bars and the measure gets stronger. Package gate: lag median at most 3 ms, p90 at most 8 ms, kick plus bass sum median at least 0 dB and worst at least -3 dB, duck 1.5 to 4.5 dB.

### 2.8 Tests

Rewrite, each with a one-line reason in the test comment:
- `LofiRhythmTests` l.155 (iterate the new voices and strokes; rise lead -5 to 40 ms), l.534 and l.585 (replace the shaped-voice checks: mono, exact pitch of the sub within 5 cents, zero after release, no content above 5 kHz within -60 dB, kits loudness matched within 1 dB, `thump` click-free step bound). Keep l.318 and l.464 as they are.
- `LofiArrangementTests` l.36 (every anchored note within 2 ms of its kick's low rise at 62, 70, 72, 81 BPM; non-bass notes identical with and without timing), l.73, l.95 (kit per take; render equals `addBass` plus chain sample for sample).
- `LofiCompositionTests` l.51 (structural 28...41, ornaments up to 53), l.116.
- `LofiStemChainTests` l.336 (reduction max 2.5 to 6.5 dB, harmonics rise at least 6 dB, still L = R), kick-duck tests (low band 1.5 to 4.5 dB, upper band about a third).

Add (`LofiBassLineTests`, `LofiBassVoiceTests`), over seeds 0..<100: the density, rest, stroke-mix and pitch-share gates of 2.5; bars 3-4 repeat bars 1-2 except in bar 4; one cell per take; no unanchored note within 0.20 beats of a confident kick; a drop-out in every breakdown and a `hold` on the next beat 0; at most one throw per phrase; throw return has less than -40 dB below 200 Hz relative to its peak band and its level gate; rendering is deterministic and finite; `lowRiseLead` cache returns the uncached value.

## 3. PADS package

### 3.1 Score (`LofiScore+Mids.swift`)

- **Pad chord:** three voices from the phrase's chord (`chordDegree`, as today): third, seventh, and fifth or ninth when the scale has it. No root; the bass owns it. Breakdown: two voices (third and seventh).
- **Register:** MIDI 48...62, centred near (52, 57, 60). Adjacent voices 3 to 7 semitones apart. Top voice at least 2 semitones under the lowest lead note of the phrase where that leaves it at 55 or higher, and never above 62.
- **Voice leading:** cost is three times the motion from the home voicing, as `voicing` does now, so chords at phrase changes share common tones.
- **Hold:** two voices are single notes from beat 0 to the release point. The third voice plays beats 0 to 8.25, then a second note from 8.0 a scale step or two away (0.25 beats of overlap, about 210 ms): the legato revoicing. Articulation `pad`.
- **Release point:** `16 - release / beatSeconds - 0.02` beats (about 14.95 at 72 BPM), so the release ends inside the phrase. `midLatestEnd` applies only to shells.
- **Return phrase:** the pad starts at `quiet` (at least 2 beats, the existing reveal window) with a 0.45 s swell, so C-B6 holds.
- **Answers that remain:** the existing `answer` and `rolled` shells, played by the lead's sample as today. At most one per phrase, only in theme, answer and variation phrases, only after a landing lead note followed by at least 2 beats of rest, keeping `midOnsetClearance`. Per 16-bar take: at least one (in the phrase with the longest rest) and at most two (second at 40 percent). Stabs are removed. This also keeps C-B5's two articulations per 16 bars (`pad` plus `answer` or `rolled`).
- **Active target:** pad sounding at least 85 percent of a non-return phrase; chords stem active at least 70 percent overall in `solo-stems.py` (21 today).

### 3.2 Pad voice (`LofiPadVoice.swift`)

- Source: the phrase program's sample nearest each pitch (layer 2), region 0.18 to 1.4 s after its onset.
- Sustain: overlapping Hann grains, 420 ms plus or minus 60, hop a third of a grain with 15 percent jitter, random start inside the region, each grain normalized to the region's median grain RMS so the sample's decay does not pulse. Seeded, deterministic.
- Width: left and right use independent grain streams and plus or minus 5 cents of detune.
- Envelope: raised-cosine attack 0.30 s, release 0.85 s. Tremolo 0.3 Hz, plus or minus 0.8 dB, different phase per voice. Two-pole low-pass at 2.4 kHz in the voice.
- No sample: the additive pad branch of `LofiSynth` with the same envelope.
- The pad send is the dry pad scaled by `note.send` (0.60 to 0.75), not a second render.

### 3.3 Chain and pocket (`LofiStemChains+Mids.swift`)

New `Pad` settings and `applyPad`: HPF 220 Hz (12 dB/oct), -3 dB at 380 Hz (Q 1), -2 dB at 2 kHz (Q 0.8, room for lead and chops), LPF 2.8 kHz (12 dB/oct), mono below 300 Hz. The `+1.5 dB at 1.6 kHz` of the shell chain is not used on the pad. Shell chain: HPF 160 to 200 Hz, otherwise unchanged.

### 3.4 Ducking

- Under the lead: a 2 dB duck on the dry pad keyed by the dry lead (attack 20 ms, hold 30 ms, release 300 ms), reusing the `spaceDuck` follower with its own settings. Offline, in `mixTexture`.
- Under chops: the existing texture-fader duck (-1 dB) and wet-fader duck (-1.5 dB) stay. MIX may deepen the mids value to at most -2.5 dB if C-B8 regresses.
- No kick duck on the pad.

### 3.5 Level (`LofiRenderer+Texture.swift`)

- Pad and shells get separate gains before they are summed into the texture stem.
- Pad: `padUnderLeadDB` 6.5 in 400 Hz to 3 kHz over the frames where lead and pad both sound, same meter and clamp scheme as `midsLevel`; peak ceiling 0.35.
- Shells: `midsUnderLeadDB` 3.5 to 4.5.
- `InstrumentBalance` meters the pad through its own `padMeterTrim`, calibrated so `balanceTrim` moves at most 0.2 dB from the baseline on seed 2077 (a held pad must not turn the lead down through the 3-second window).
- Target in the mix: chords stem -24 to -22 LUFS (was -18.4 at 21 percent active), which is 4 to 6 LU under the melody. Total chord energy rises about 1 to 2 dB while its level while sounding drops about 5 dB.

### 3.6 Reverb (`LofiEffects.swift`)

- `processReturns` gains a `pad` input with its own feeds: plate 0.90, late room 0.55, Ensemble 0.20, echo 0.08 (the shell feeds stay as they are). A held chord in the feedback echo is what would wash out.
- Pad send is pre-filtered HPF 280 Hz, LPF 4 kHz, and delayed 45 ms.
- Target: the pad's own return 3 to 6 dB under the dry pad in 400 Hz to 3 kHz (unit test rendering one phrase with and without the pad send).
- Budget: wet stem at most +0.7 LU over the baseline. The lead-keyed space duck is unchanged.
- The granulator's texture anchor (`mids.first`) becomes the first shell note, or none: do not granulate the pad.

### 3.7 Phrase boundary

The dry pad's release ends at the phrase edge and the next swell starts at beat 0, so the dry stem dips for about half a second under the drum fill while the plate and room tail carries across. Gate (unit test over two consecutive phrases): texture plus wet in 300 Hz to 3 kHz, 100 ms windows, dips at most 6 dB under its mid-phrase level across the boundary. If it fails or the listening check hears a hole, do P7.

**P7 (optional, strong model).** Dry pad carry: `Phrase` gains `textureTail` (the pad's frames past n after chain and gain) and a `fallbackTexture` buffer whose head carries the phrase's own tail; the next render adds the carried tail to its head; the 4 ms edge is skipped on the pad component only when a carry is present; `LofiPlayback.enqueue` takes a `texture:` override for a repeated phrase, as it does for `wet`. This touches `LofiRenderer.swift` and `LofiPlayback.swift`, so it is done on `main` after the merge, with a test that a repeated phrase has no step larger than the mid-phrase maximum at the boundary.

### 3.8 Tests

Rewrite, with a reason in each:
- `LofiArrangementTests` l.142 (new invariants: pad voice count, register 48...62, spacing, one revoicing with 0.25 overlap, end inside the phrase, shells at most one per phrase and one to two per take, clearance, articulations), l.217, l.266.
- `LofiCompositionTests` l.60, `LofiGuitarPhrasingTests` l.39.
- `LofiStemChainTests` l.162, l.436 (pad width only above 300 Hz), l.555, l.580, and l.417 must still pass with the pad (texture below 120 Hz at least 12 dB under drums and bass; expect over 30).

Add (`LofiPadTests`): pad active at least 85 percent of a non-return phrase; no pad energy before `quiet` in a return; stem exactly zero at both edges; pad 5.5 to 7.5 dB under the lead in 400 Hz to 3 kHz on rendered phrases for every program; pad band energy below 150 Hz at least 30 dB under its peak band; spectral centroid 500 to 1200 Hz and under the lead's; grain sustain level ripple at most 1.5 dB peak to peak in 100 ms windows; the wet-return ratio of 3.6; the boundary gate of 3.7; deterministic and finite.

## 4. MIX package

1. On `main`: `git merge pkg/bass`, then `git merge pkg/pads` (no squash, no push). Expect conflicts only in the three shared test files, resolved by keeping both sides' tests. Build and run the six suites.
2. Add `scripts/stem-bands.py CAPTURE [--baseline CAPTURE]`: per stem (`drums`, `bass`, `texture`, `dry`, `wet`, `dialogue-chops`, `footage`, `pre-master`), mean-square dB in 40-120, 120-300, 300-800 Hz and 1-4 kHz, whole-file and active-only (gated 30 dB under the stem's peak window), with deltas to the baseline. Reuse `scripts/mixlib/audio.py` loading. This is the reusable form of the per-channel breakdown.
3. Capture, report, solo stems, bands (section 5.3). Rebalance only with these controls, in this order, one change per capture:
   - bass `outputTrimDB`, body level, harmonics mix (for C-B3 and the bass bands);
   - `padUnderLeadDB`, pad EQ corners, pad send feeds (for C-B5, C-B11, the 120-800 Hz bands);
   - `Space.outputTrimDB` (down to -2.5 dB) or `duckDepthDB` (up to 5) if C-B7 falls;
   - `MusicDuck.midsDB` (to -2.5 at most) if C-B8 falls;
   - bass-throw return level;
   - last resort for loudness: the master finisher input gain, at most 0.5 dB, recorded in the D-entry.
4. Run `scripts/mix-matrix.sh --strict` (five cases, one at a time).
5. Listening files for the user: `solo-stems.py CAP OUT --wav` for the bass, chords and reverb-echo stems, and `master.wav`, baseline against new, loudness matched.
6. Docs (section 7), then commit.

A criterion threshold changes only if the new design makes its old meaning wrong, with the reason written in `docs/plans/mpc-chopping-measurements.md` and `docs/mix-verification.md`. None is expected.

## 5. Verification protocol

### 5.1 Build and tests (every package, after every substantive change)

```sh
xcodebuild -scheme Liminal -destination 'platform=macOS' build
xcodebuild test -scheme Liminal -destination 'platform=macOS' \
  -only-testing:LiminalTests/LofiTests -only-testing:LiminalTests/LofiCompositionTests \
  -only-testing:LiminalTests/LofiGuitarPhrasingTests -only-testing:LiminalTests/LofiProductionTests \
  -only-testing:LiminalTests/ArchiveVoiceRenderTests -only-testing:LiminalTests/LofiDialogueSamplerTests \
  -only-testing:LiminalTests/ArchiveCachePolicyTests \
  -only-testing:LiminalTests/LofiRhythmTests -only-testing:LiminalTests/LofiArrangementTests \
  -only-testing:LiminalTests/LofiStemChainTests
```

The first seven are the list in `docs/development.md#lo-fi-checks`; the last three are the suites that pin bass and mids. New suites (`LofiBassLineTests`, `LofiBassVoiceTests`, `LofiPadTests`) are added to the command and to `docs/development.md`. Before a package hands off, and in MIX: also `LofiMixRenderTests`, `LofiLiveBusTests`, `LofiCaptureHooksTests`, and the visionOS build (`-destination 'platform=visionOS Simulator,name=Apple Vision Pro' build`), since new bundled samples and new files join both targets. Tests are Swift Testing; timed tests carry `.responsivePool`. Render budget: a phrase render must stay inside the existing budget test; report the phrase render time before and after in the package notes.

### 5.2 Rules for captures

One capture or test process at a time (lock in 1.3). Never press Play; never launch the app flagless; no Gemini generation. Captures stay in the scratchpad, out of git.

### 5.3 Capture and analysis (each package once its tests pass, MIX after every rebalance)

```sh
S=$S
scripts/check-lofi.sh --out $S/cap-<pkg>-<n> --bars 32 --bpm 72 --seed 2077 --private-drums --film-reel --wait-lock 3600
python3 scripts/mix-report.py $S/cap-<pkg>-<n> --baseline $S/final-main --no-plots --strict
python3 scripts/solo-stems.py $S/cap-<pkg>-<n> $S/solo-<pkg>-<n>
python3 scripts/stem-bands.py $S/cap-<pkg>-<n> --baseline $S/final-main   # MIX; packages use an inline numpy equivalent
```

Final MIX run only: once with plots (drop `--no-plots`) to read `kick-bass.png`, `mids-lead.png`, the masking heatmap and `ltas.png` against the healthy shapes in `docs/mix-verification.md`.

### 5.4 Package gates (single-package capture, before hand-off)

BASS alone: strict has no new failure; C-B2 and C-B3 at the 2.6-2.7 gates; C-B1 pass; drum stem identical to the baseline's (max difference under 1e-6); bass stem active 45 to 65 percent; master LUFS at most 0.8 LU above baseline (MIX trims the rest); wet stem at most +0.3 LU.

PADS alone: strict has no new failure; C-B5 lead minus mids 5.0 to 7.5 dB, rests at least 3 dB, articulations at least 2; C-B6 at least 6 dB; C-B11 median at least -2.6 dB; C-B8 inside its bounds; chords active at least 70 percent; chords stem -24 to -22 LUFS; wet stem at most +0.7 LU; master LUFS within 0.3 LU of baseline.

### 5.5 Final acceptance (MIX, seed 2077, 72 BPM, 32 bars)

| Measure | Baseline | Gate |
|---|---|---|
| Strict failures | 0 | 0, and no warn ID beyond the baseline's five (C-M5, C-M11, C-M12, C-B7, C-D8) |
| Master integrated | -12.82 LUFS | -13.0 to -12.3 |
| True peak, PLR | -1.20 dBTP, 11.62 | at most -1.0; 9 to 12.5 |
| Limiter mean, p95 | 0.01, 0.03 dB | at most 0.5, 1.5 |
| Drums stem | -17.4 LUFS | raw stem identical; -17.4 plus or minus 0.3 |
| Bass stem | -17.6 LUFS, 28 percent | within -1.0 to +0.5 LU of drums; active 45 to 65 percent |
| Chords stem | -18.4 LUFS, 21 percent | -24 to -22 LUFS; active at least 70 percent |
| Melody stem | -18.2 LUFS | within 0.5 LU |
| Reverb-echo stem | -19.5 LUFS | -20.0 to -18.8 |
| Chops, film bed | -21.0, -24.0 LUFS | within 0.5 LU; bed at least 10 dB under the music and never a duck key (C-B9 pass) |
| C-B1 | mids 43 dB under | pass, mids at least 30 dB |
| C-B2 lag, sum, duck | 1.29 / 2.65 ms, +0.67 dB, 2.37 dB | median at most 3 ms, p90 at most 8 ms; sum at least 0 dB median, -3 worst; duck 1.5 to 4.5; aligned accents at least 24 |
| C-B3 | -1.07 dB, -14.69 dB | -3 to +1 dB; harmonics at least -12.5 dB |
| C-B5 | 3.39 dB | 5.0 to 7.5 dB; rests at least 3 dB; articulations at least 2 |
| C-B6 | 17.1 dB | at least 6 (aim 12) |
| C-B7 | 2.48 dB (warn) | at least 2.2; aim 2.5 or more |
| C-B8 | SII 0.38, SNR 0.34 dB | SII at least 0.35; SNR at least -0.7 and inside -3 to +2.5; chop cadence unchanged |
| C-B11 | -1.59 dB, 36 percent | median at least -2.6; under dialogue at most 42 percent |
| C-B10, C-M10 | pass, 1.00 | pass; correlation below 120 Hz at least 0.95 |
| C-M11 | 44.5 dB (warn) | not more than 1 dB worse |

Band gates from `stem-bands.py` (active-only unless stated):
- Bass: 40-120 Hz within 1.5 dB of the drums' 40-120 Hz; 120-300 Hz up 5 to 9 dB on the baseline bass; 300-800 Hz up 8 to 14 dB; 1-4 kHz at most -55 dB.
- Chords: 40-120 Hz at most -60 dB; 120-300 Hz at least 4 dB lower than baseline while sounding and not higher whole-file; 300-800 Hz whole-file within +2 dB of baseline; 1-4 kHz at least 8 dB under the melody stem's.
- Pre-master: 40-120 Hz at most +1.5 dB; 120-300 and 300-800 Hz at most +1.0 dB each; 1-4 kHz within 0.5 dB.

Then `scripts/mix-matrix.sh --strict`: no failure in any of the five cases.

## 6. Model assignment

| Step | Model | Why |
|---|---|---|
| This plan; arbitration when a gate cannot be met | fable | Planning and trade-offs only |
| PREP split (1.1) | sonnet | Mechanical move guarded by sample-exact tests; escalate to opus if a test fails twice |
| BASS: download, licence re-check, prepare, measure, credits | haiku or sonnet | Scripted and checkable |
| BASS: voice, chain, split duck, throws (2.2-2.4) | opus | DSP with phase, alignment and click constraints |
| BASS: line writing (2.5) and its tests | opus | Musical rules against timing-field constraints |
| PADS: pad voice and effects feeds (3.2, 3.6) | opus | Granular DSP, level and wash control |
| PADS: scoring, chain, levels (3.1, 3.3-3.5) | sonnet, opus review | Well specified |
| Test rewrites in both packages | sonnet | Follows the listed invariants |
| Running builds, tests, captures and collecting numbers | haiku | Mechanical; one at a time |
| MIX: `stem-bands.py`, merge | sonnet | Mechanical |
| MIX: rebalancing decisions from the reports | opus | Judgment against many coupled gates |
| P7 dry carry, only if needed | opus | Touches playback scheduling |
| Docs | sonnet | From the package notes |

## 7. Docs (MIX, same change as the final constants)

- `docs/decisions/music.md`: **D116** bass voice, line and effects; **D117** pad chords; **D118** rebalance and measurements. Each dated 2026-11-20 or later, with baseline and final numbers from section 5.5, what was tried and rejected, and the user's direction quoted.
- `docs/architecture.md`: Lo-Fi section (two-layer bass voice, anchoring of every on-kick note, throws into the wet stem, pad voice, pad and shell gains, new files). Update the repository map in `CLAUDE.md` and `AGENTS.md` for the new files.
- `docs/experience.md`: what the listener hears (riddim bass with drop-outs and throws; held pad with occasional answers).
- `docs/lofi-samples.md`: one row per `LofiBass-*` file with its source URL at a pinned commit, plus "Sneakybass by Karoryfer Samples, CC0" and "Swagbass by Karoryfer Samples, CC0"; note the 25 Hz high-pass and retune.
- `docs/development.md`: the wider Lo-Fi test list, `stem-bands.py`, `--prefix` and `--retune` of the prepare script.
- `docs/mix-verification.md` and `docs/plans/mpc-chopping-measurements.md`: only if a criterion changes; otherwise add the new healthy shapes (bass body in 120-800 Hz, pad active most of the phrase) to the interpretation section.

## 8. Rules that hold throughout

- Never commit `Liminal/Secrets.swift`, `Liminal/SlowBurnDrums/`, `Liminal/Audio/Lofi/SlowBurnBeatGrid.json`, captures, or downloaded source libraries. Do not hand-edit `project.pbxproj`; do not change signing.
- Nothing new on a realtime render path or tap: no allocation, lock or blocking there. All new work is in the offline phrase render; the `lowRiseLead` cache lock is taken only on the render worker.
- Late-phrase fallback unchanged: every dry stem stays a fixed n-frame buffer on the same grid; no silent rests.
- Drum takes untouched: same samples, grid, fills and tapers. The drum stem must be identical to the baseline.
- Film bed stays at least 10 dB under the music and is never a duck key; dialogue chops and their ducks are not retuned except `MusicDuck.midsDB` within the stated bound.
- Swift concurrency: new types are `nonisolated` and `Sendable`; heavy work stays off the main actor.
- No Gemini spend: captures use `check-lofi.sh` only.

## 9. Risks

- **Sample pitch labels and tuning** (Sneakybass): measured before use; `--retune`; flatwound-only fallback.
- **Body and sub beating in 150-260 Hz:** 24 dB/oct high-pass on the body and 3-cent tuning; if still audible, raise the crossover to 180 Hz.
- **Headroom:** more bass activity and a held pad both add energy; expect about +0.5 to +0.8 LU before MIX trims. The limiter has room (mean 0.01 dB) but C-M1's upper gate here is -12.3.
- **C-B7** is already a warning at 2.48 dB; the pad's reverb budget and the space trim in MIX exist for it.
- **C-B5** now measures a long overlap instead of 1.44 s; the 6.5 dB target sits mid-window on purpose.
- **Render time:** more bass notes and granular pads; cache `lowRiseLead`, reuse the pad render for its send, and check the phrase budget test.
- **Phrase-boundary breath** on the pad: gated in 3.7, with P7 as the fix.

## Outcome (2026-11-20)

Built as planned: the two-layer riddim bass (synthesized phase-exact sub plus a Karoryfer Sneakybass or Swagbass body, anchored to the take's kicks, split kick duck, dub throws into the wet stem) is D116; the held granular pad with one answer shell is D117; the rebalance is D118. Section 5.5 gates all pass on the seed 2077 capture (`cap-mix-14`) against `final-main`, with no strict failure, drums identical, bass -17.9 LUFS at 49 % active, chords -23.6 LUFS at 89 %, master -12.40 LUFS, true peak -1.20 dBTP.

Differences from the plan:
- Sneakybass `ghost` and `mute` are unpitched thumps and were not bundled. `upright` has only short and long strokes, and an upright ghost plays the short note softly. The sample pitch estimator needed bass changes (30 Hz floor, narrower search, partial averaging, iterated `--retune`).
- The anchoring share of the kick's low rise moved from 0.47 to 0.40 after the matrix showed the 70 BPM takes sitting about 5 ms late. Kick target error across all takes is still up to 24 ms late (p90) on slow kicks; an exact fix needs a smooth-rise landmark.
- The pad's 500-1200 Hz centroid target could not hold with this melody and sits under the lead's centroid instead. Instrument balance meters the pad's reverb, so theme phrases come down 0.5 to 0.9 dB (plan 0.2). P7 (dry pad carry across phrases) was not needed by the boundary gate.
- The rebalance used two controls outside plan 4.3 (the shell 1.6 kHz boost, removed, and `bassKickRiseShare`). Debug render time forced `while` loops on the phrase render path.
- Not met: `mix-matrix.sh --strict` still fails in `long`, `fast` and `same`, all on criteria that also fail on the pre-merge main (C-B8, C-D6, C-D9, C-B6). C-B7 aim 2.5 dB reached 2.43 dB (warn, as in the baseline).
- Thin margins: C-B5 0.03 dB, C-B11 0.09 dB, bass 120-300 Hz 0.11 dB, chords 1-4 kHz 0.12 dB, chords 300-800 Hz 0.25 dB, bass 1-4 kHz 0.27 dB.
- No listening check was done by the agents; that is the next step.
