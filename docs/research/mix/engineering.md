# Lo-fi / boom-bap mix engineering and objective verification

19 November 2026 · Research note for the Liminal mix and mastering implementation (companion to [mpc-chopping-handoff.md](../dialogue-chopping/handoff.md))

## Purpose and evidence grading

This note gives an implementer per-bus effect chains and measurable targets for Liminal's Lo-Fi mode, plus analysis methods that verify a mix without listening. Evidence grades:

- **[S]** standard or primary specification (ITU-R BS.1770, EBU R 128 / Tech 3341/3342, SII ANSI S3.5).
- **[P]** platform guidance (Spotify, Apple), which changes over time and was checked only through secondary pages in this session.
- **[C]** mixing-craft convention from engineering blogs and tutorials. These agree on direction, not on exact values. Treat numbers as starting points to tune by measurement.
- **[H]** hypothesis or inference by this author, to be validated on Liminal renders.

Web research this session reached mostly vendor and tutorial pages (listed in Sources). Numbers marked [C] or [H] are not proven optima. Verify [P] values against current platform documents before relying on them.

Genre context: lo-fi hip hop is conventionally quiet, dusty and restrained. One guide states that crushing the master with a limiter strips the cosy, distant feel, while mainstream hip hop masters sit near -8 to -10 LUFS. The user asks for "loud and competitive", so the targets below define a middle tier ("loud lo-fi") and keep a transient-preserving safety margin.

## 1. Spectral slotting plan (the central design)

Give every bus a primary band and cut the others out of it. Frequencies are [C] unless noted.

| Region | Owner | Others should |
|---|---|---|
| 20-40 Hz | nobody (HPF all except kick/bass at ~30 Hz) | HPF |
| 40-100 Hz | kick body and bass fundamental (shared in time, see kick/bass) | HPF at 100-150 Hz (mids, lead, dialogue, bed) |
| 100-250 Hz | bass harmonics, snare body, warmth | dip mids/keys/lead 2-4 dB here |
| 200-500 Hz | "mud" zone | cut 2-4 dB on mids, lead, dialogue, bed, drum bus |
| 500 Hz-1 kHz | melody/mids body, dialogue fundamentals | keep bed shaped so it does not fill the gap |
| 1-4 kHz | dialogue intelligibility (SII bands carrying most speech information, [S] shape, see section 8) and lead presence | carve 2-3 dB in bed, mids and reverb returns while dialogue plays |
| 4-8 kHz | snare crack, hat, vowel consonants, dialogue sibilance edge | lo-fi LPF the music buses here by design |
| 8-16 kHz | hats, air | lo-fi LPF 8-12 kHz on mids/lead/bed (tape/vinyl character), dialogue de-ess 5-8 kHz |

Complementary EQ rule: when bus A owns a band with a +2 to +3 dB shelf or bell, bus B takes the mirrored -2 to -3 dB with a wide Q (0.7-1.0). Prefer static cuts for lo-fi stability and use dynamic cuts only where events collide (dialogue vs bed/mids; kick vs bass).

Masking measurement (section 9) should confirm that the owner of each band is at least 6 dB above each other bus in that band, except the intended blends (kick/bass, bed under dialogue).

## 2. Drums (AJ Hall takes, bus)

Constraint: the full takes stay as audio. Process them as a bus, not as detected replacement hits.

Chain [C]:
1. HPF 30-40 Hz (12 dB/oct), removes rumble.
2. Corrective EQ: -2 to -3 dB at 250-400 Hz (box), optional +1.5 to +2 dB shelf at 60-80 Hz only if the kick is thin.
3. Bus compression "glue": ratio 2:1 to 4:1, attack 10-30 ms (lets transients through), release 80-200 ms or auto, 1-3 dB gain reduction on peaks (up to ~4 dB for a heavier boom-bap feel).
4. Saturation (tape/soft tanh): drive for 1-2 dB of harmonic lift; it rounds peaks, which lowers crest factor a little.
5. Parallel compression (optional): 6-10:1, fast attack and release, 6-10 dB reduction, blended 15-30 % wet. Adds sustain and room feel for lo-fi dustiness without squashing the attack.
6. Transient shaping (optional): small attack boost (+1 to +3 dB) if the drum bus is softened by tape/LPF; avoid on takes that are already sharp.
7. LPF 10-14 kHz (or gentler shelf -3 dB at 10 kHz) for the lo-fi look; hats may keep more air than the rest of the music.

Targets [H/C]: drum bus crest factor 10-14 dB before the master; kick/snare stays the loudest short-term element in the mix (peak, not RMS).

## 3. Bass (three bounded voices)

Chain [C]:
1. Mono below ~100-120 Hz (sum bass to mono; common practice and compatibility rule). Liminal's bass can stay fully mono, or width only above 150 Hz.
2. HPF 30-35 Hz to remove inaudible energy that eats headroom.
3. Saturation or soft clipping creating 2nd/3rd harmonics (150-800 Hz) so the line is audible on laptop/phone speakers that do not reproduce below ~100 Hz. Blend the harmonics rather than increasing the fundamental level.
4. Compression: ratio 3:1 to 4:1, attack 15-30 ms (keeps the pluck), release 100-200 ms, 2-4 dB of gain reduction, bringing the sustain level consistent.
5. Low-mid carve: -2 to -3 dB at 250-350 Hz if it muddies the mids.
6. Kick/bass relationship, either one of:
   - Sidechain duck of bass from kick, 2-4 dB depth, attack ~1-5 ms, release 60-120 ms (one source calls aggressive sidechaining part of the lo-fi aesthetic; Liminal already has bounded ducking, so keep depth modest to avoid pumping).
   - Dynamic or static split: kick owns 50-70 Hz, bass fundamental sits at 70-100 Hz or higher (tune to key), plus a notch where they collide.
7. Attack alignment: bass pluck onset within ~5 ms of the kick attack when they coincide (the handoff's selected-accent alignment). Check by cross-correlating the 40-200 Hz band envelopes of kick and bass stems.

Verification: low-band mono sum correlation near +1 below 120 Hz; bass+kick sum has no phase cancellation (the sum RMS in 40-120 Hz is at least the larger of the two; a loss of more than 3 dB signals cancellation).

## 4. Mids, keys, texture (recorded shell path)

Chain [C]:
1. HPF 120-200 Hz.
2. Cut 2-4 dB at 250-500 Hz (mud), 1-2 dB dip at 1-3 kHz in the dialogue slot when dialogue plays (dynamic or ducking).
3. Presence: +1 to +2 dB around 1-2.5 kHz when the part must be louder (the user asked for more present, varied mids), then compensate by lowering the lead or lowering the dialogue slot.
4. Tape-style saturation, light (wow/flutter small, 0.1-0.3 % pitch variance is a design choice not a measurement).
5. LPF 6-10 kHz.
6. Stereo width: widen above ~300 Hz (Haas 8-20 ms or chorus), correlation not below +0.3; keep the mid band (200-500 Hz) near mono.
7. Compression/gate: 2:1, slow attack, short release, 1-3 dB, or use rest-triggered volume answers instead of compression for call-and-response.

Answer against the melody: place mid responses in melody rests; as a measurable check, the mids bus RMS in the 400 Hz-3 kHz band should exceed the lead bus by at least +3 dB in the windows where the lead is silent, and be 3-6 dB below the lead when both play.

## 5. Lead / melody

Chain [C]:
1. HPF 150-250 Hz.
2. Presence: +1 to +3 dB 2-4 kHz, mild; cut 300 Hz.
3. Compression 2:1-3:1, 2-3 dB, to keep the theme audible (the user could not hear the return).
4. Delay send: dotted-eighth or quarter, feedback 25-40 %, return high-passed at 300-500 Hz and low-passed at 3-5 kHz ("dark echo"), return level -12 to -18 dB relative to dry.
5. Reverb send: plate/room, pre-delay 20-40 ms, decay 1.2-2.5 s, return HPF 300-500 Hz and LPF 4-6 kHz, level -15 to -20 dB relative to dry; duck the return under the dry signal for clarity (sidechain 3-6 dB) so opening notes of a returning theme are heard dry.
6. Theme return: the first 1-2 notes of the return benefit from +1 to +2 dB level and cleared tails of other layers (the handoff's recognition goal).

## 6. Dialogue chops

Chain [C], following standard dialogue practice:
1. HPF 100-150 Hz (12 to 18 dB/oct).
2. Corrective EQ: cut 250-400 Hz boxiness by 2-3 dB; presence bell +2 to +4 dB at 2-5 kHz.
3. De-ess 5-8 kHz, 3-6 dB reduction on sibilant peaks, or LPF/shelf for archive material that is naturally sharp.
4. Compression 3:1-4:1, attack 5-15 ms, release 60-150 ms, 3-6 dB gain reduction so each cut has an even level (matches the handoff's per-cut leveling); optional final limiter on a cut at -3 dBFS peak.
5. Short slap/dark echo: 80-180 ms single repeat (sync to 1/16 or 1/8 beat), feedback 10-25 %, repeat band-passed to 400 Hz-3 kHz; send -14 to -20 dB below dry. Room: small room, decay <0.8 s, return HPF 300 Hz, LPF 4 kHz, -18 to -24 dB below dry.
6. Low-pass for lo-fi texture at 5-8 kHz only for texture chops; keep featured lines to 7-8 kHz or more for consonant clarity.
7. Duck music under speech: music bus sidechain or arrangement duck of 2-5 dB broad, and 3-6 dB in the 1-4 kHz band via dynamic EQ or split filter (the bed is already boosted/dipped by 1.76x/1.31x context factors in the existing code, so measure before adding). Attack 20-50 ms, release 200-500 ms, to avoid a pumping audible duck.

Intelligibility targets: see section 8; the main proxy is band SNR of dialogue versus all other buses in 500 Hz-4 kHz.

## 7. Film bed / ambience

Chain [C]:
1. HPF 80-150 Hz (remove rumble that eats headroom), LPF 6-10 kHz for lo-fi texture, or LPF 4-6 kHz when the bed overlaps featured speech.
2. Static cut 2-3 dB at 1-4 kHz so the bed and speech do not collide (dialogue slot), and a gentle +1 to +2 dB at 250-500 Hz is not recommended (mud).
3. Level: bed integrated loudness 10-16 LU below the music bus loudness in dense sections and 6-10 LU below in gaps, so it is identifiable between chops (feedback: bed was too low and washed out; the washed-out part is often from stacked filters + high wet reverb, so reduce wet to 10-20 % and keep dry direct sound) [H].
4. Compression 2:1 slow, 1-2 dB, to even film dynamics, or leveling (the existing normalization/trim).
5. Stereo: keep source width but fold 100-250 Hz to mono.
6. Optional gentle noise gating is not advised for ambience.

Measure: bed short-term loudness during gaps between chops must be above the noise floor and within 8-14 LU of the whole mix; bed share of 1-4 kHz energy during speech at least 6 dB below dialogue.

## 8. Master chain (summit bus)

Order [C], then target values:

1. Static mix filter: HPF 25-30 Hz on the master, to prevent infrasonic limiter triggering.
2. Subtractive/tonal EQ: broad tilts only (+/- 1.5 dB).
3. Glue compressor: ratio 1.5:1 to 2:1, attack 30 ms, release auto or ~150 ms, threshold for 1-2 dB gain reduction on peaks (up to 3 dB). Sidechain HPF 80-120 Hz so the kick does not pump the whole mix.
4. Optional multiband (3 bands, split near 120 Hz and 3 kHz): max 1-2 dB reduction per band, mostly to control low-end spikes.
5. Saturation / soft clip: soft clip 1-2 dB of peak trimming (soft clippers can shave 1-3 dB of crest before the limiter and tend to sound cleaner than extra limiter gain reduction). Oversample 2x-4x to avoid aliasing.
6. Final true-peak limiter: lookahead 1-5 ms, release 50-200 ms (auto), oversampled 4x for inter-sample peaks, ceiling -1.0 dBTP (-1.5 or -2 dBTP if the output will be lossy-encoded and loudness exceeds -14 LUFS; one source notes Spotify recommends -2 dBTP for masters louder than -14 LUFS). Gain reduction typical 2-4 dB average, peaks up to 6 dB, no more than 8 dB. If average gain reduction exceeds ~6 dB the limiter pumps, back off the input.
7. Dither only when producing 16-bit exports; the realtime path is float.

### Loudness targets (integrated, ITU-R BS.1770 K-weighting, gated)

| Use | Target | Grade |
|---|---|---|
| EBU R 128 broadcast | -23 LUFS, true peak max -1 dBTP; no fixed LRA maximum in R 128 itself | [S] (Wikipedia and EBU docs) |
| Spotify normalization reference | about -14 LUFS, -1 dBTP ceiling (-2 if louder than -14) | [P] |
| Apple Music / Sound Check | about -16 LUFS | [P] |
| Deezer | about -15 LUFS | [P] |
| Traditional lo-fi / chill | -14 to -18 LUFS, relaxed dynamics | [C, H] |
| "Loud lo-fi" (this project's goal) | -11 to -13 LUFS integrated, short-term max about -9 | [H] |
| Mainstream hip hop mastering | about -8 to -10 LUFS (sources vary; some say -11 to -7) | [C] |

Recommendation: master to about -12 LUFS integrated with -1 dBTP; do not exceed -10. Platform normalization turns louder masters down, so extra limiter gain only costs dynamics.

### Dynamics targets

| Metric | Target | Grade |
|---|---|---|
| Crest factor (sample peak minus RMS, full mix) | 9-12 dB for loud lo-fi, 12-16 dB for relaxed | [C/H] |
| PLR (true peak minus integrated LUFS) | 8-11 dB (below 7 indicates over-limiting; streaming-friendly masters often 9-12) | [C] |
| PSR (true peak minus max short-term LUFS) | 6-9 dB | [C/H] |
| LRA (EBU Tech 3342) | 4-8 LU for this genre; avoid below 3 (flat) and above 10 | [H] |
| Limiter gain reduction | mean 1-3 dB, 95th percentile below 5 dB, max below 8 dB | [C/H] |
| True peak | at or below -1.0 dBTP, zero overs | [S/P] |
| Mono compatibility | mono-sum loudness loss at most 3 dB; band correlation below 120 Hz at least +0.8 | [C] |

### Spectral balance targets

Compare 1/3-octave long-term average spectrum (LTAS) to a reference curve. Typical full-range music slopes about -3 dB/octave (pink noise slope), but lo-fi is steeper above 6-8 kHz by design (tilt of -4.5 to -6 dB/oct above 3 kHz) [C/H]. Practical check: use balanced band shares: sub (20-60) 8-14 %, bass (60-250) 25-35 %, low-mid (250-500) 12-18 %, mid (500-2k) 18-26 %, presence (2-6k) 8-14 %, air (6k+) 2-6 % of energy [H], then compare to 3-5 well-mastered lo-fi references measured with the same tool (more reliable than any published curve). Flag a deviation larger than 3 dB in any octave band.

## 9. Objective analysis methods (verify without listening)

Implementation notes: Python tools exist already (scripts/analyze-lofi.py, plot-lofi.py, measure-lofi-instruments.py). Suggested stack: numpy/scipy, pyloudnorm (BS.1770 meter) or ffmpeg's `ebur128` filter (gives integrated, short-term, momentary, LRA, true peak with `peak=true`), librosa for onsets/spectrograms, optionally `loudness-scanner` or Essentia. Cross-check the Python numbers against `ffmpeg -i x.wav -af ebur128=peak=true -f null -`.

| Method | What to compute | Pass criteria | Grade |
|---|---|---|---|
| Per-bus stem export | Offline render each bus (drums, bass, mids, lead, dialogue, bed) pre-master and the master, same length and sample rate, plus the sum check (sum of stems vs master before the master chain differs below -60 dB) | Stems sum to the pre-master mix | [H] |
| LUFS | Integrated, short-term (3 s), momentary (400 ms) per BS.1770 and Tech 3341; relative gate -10 LU, absolute gate -70 LUFS | Section 8 table | [S] |
| True peak | 4x oversampled peak per BS.1770 Annex 2 (use 8x for Tech 3341 accuracy if needed) | at or below -1.0 dBTP | [S] |
| Loudness range | EBU Tech 3342 (10th to 95th percentile of gated short-term values) | 4-8 LU | [S] method, [H] target |
| Crest factor | per window (1 s) and overall: 20log10(peak/RMS) per bus and master; PLR/PSR from LUFS | Section 8 | [C] |
| Limiter gain reduction | log gain applied each block in the engine; report mean, p95, max, time above 3 dB and release/pump rate | Section 8 | [C/H] |
| Multi-resolution spectrograms | STFT at 4096 (bass resolution, ~10 Hz), 1024 (mid) and 256 (transients) samples; log-frequency, per bus and master; also long-term average spectrum with 1/3-octave bands | Visual check for filled holes, no energy under 25 Hz, HF roll-off as designed | [C] |
| Per-band energy and masking between buses | For octave or Bark bands, per-bus short-term energy; masking index = band energy of target bus minus summed energy of the other buses (dB). Dialogue vs rest in 500-4k: want +6 dB or higher during chops; bed vs music in gaps; lead vs mids | Section 1 slotting table | [H] adaptation of band SNR |
| Kick/bass analysis | Envelope cross-correlation in 40-200 Hz, onset lag (ms) at kick onsets (accent aligned within 5 ms), sum energy vs each part (cancellation test), ducking depth measured as bass RMS reduction in the 100 ms after kick | lag at most 5 ms for aligned accents; no more than 3 dB cancellation; ducking 2-4 dB | [H] |
| Mono / correlation | Pearson correlation L/R per octave band; mid/side energy ratio; mono-sum loudness difference | below 120 Hz correlation at least +0.8; full-band at least +0.3 on average; mono loss at most 3 dB | [C] |
| Spectral balance | Mean 1/3-octave spectrum vs target tilt or reference tracks, tilt slope by regression | within 3 dB per band | [C/H] |
| Speech intelligibility proxies | (a) band SNR of dialogue vs non-dialogue buses in SII octave bands 250, 500, 1k, 2k, 4k, 8 kHz; (b) a simplified SII: sum of band-importance weights times clipped audibility ((SNR+15)/30 clamped to 0..1, the SII audibility rule); (c) STI-style modulation transfer on the mixed signal (speech envelope 0.63-12.5 Hz modulation preservation; requires the clean dialogue as reference), or the `pystoi`/ESTOI (short-time objective intelligibility) between clean dialogue stem and the speech-region of the mix | SII-proxy above 0.6 on featured chops; band SNR at least +6 dB in 1-4 kHz; ESTOI above 0.8 | [S] for SII definition, [H] for thresholds; no mixing-level target was found in sources |
| Onset/transient metrics | Spectral-flux onset detection per band, attack time (10-90 % rise), transient-to-sustain ratio before and after bus processing; peak-to-RMS of drum stem | attack time not lengthened by more than 20 % after bus chain; hit count matches hand labels | [H] |
| Chop-change cadence | From the engine's performance plan log (and verified from the dialogue stem by an onset/energy fingerprint of cut sequence): hash the bank + grammar pattern per bar window; require a different performance signature at least every 16 bars; also measure rest ratio and repeat ratio | signature changes at least every 16 bars; at least one rest/return per 8 bars; analysis finished before schedule time (lead-time log) | [H] project requirement |

Cautions: LUFS is not perceived loudness for narrow-band material; short-term loudness of bed gaps is dominated by the bed, so analyze windows separately. Do not average across sections (dialogue present vs absent); compute per section and per 4-bar window.

## 10. Lo-fi specifics (artifact and tape layer)

Lo-fi character is a deliberate band-limited, saturated, slightly modulated color:
- Tape/vinyl emulation: saturation, soft high-roll-off at 8-12 kHz, wow/flutter at 0.2-1 Hz depth 0.1-0.5 %, noise floor at -50 to -60 dBFS (not counted toward loudness; check that it does not raise the noise floor above the bed in gaps).
- Keep lo-fi coloration on the music buses (mids/lead/bed) before the master; the drums and dialogue keep more top end so they stay legible.
- Apply a master-level LPF no lower than 14-16 kHz; a 6-8 kHz global LPF kills hat transients and conflicts with the loudness goals.
- Minimal EQ is a common recommendation, but with six buses competing, static complementary cuts (section 1) are the minimal EQ.

## 11. Implementation checklist and thresholds for the verification script

1. Export stems: drums, bass, mids, lead, dialogue chops, film bed, master (pre- and post-limiter), plus the limiter gain trace (CSV).
2. Run loudness (ebur128/pyloudnorm), true peak, LRA, crest, PLR, PSR.
3. Run per-bus band energy table and masking matrix; fail if the owner-of-band margin from section 1 is under +3 dB.
4. Run low-band correlation and mono-sum loss; fail if the correlation is under +0.8 below 120 Hz.
5. Run the kick/bass lag and cancellation test.
6. Run dialogue intelligibility proxy (SII-like plus band SNR), then the bed-audibility check during gaps.
7. Run chop cadence check from the plan log: fail if two consecutive 16-bar windows have the same signature.
8. Emit PNG spectrograms (multi-resolution) and a JSON summary to the scratchpad; only small curated figures go under docs/media/mix/.
9. Make thresholds configurable; start with the values in this note and recalibrate on 3 reference lo-fi tracks and Liminal renders.

## Open questions

- No source found for numeric ducking depth versus speech at SNR level; section 6 values are craft convention [C] and must be tuned by the band-SNR proxy.
- Platform loudness values come from secondary pages; confirm against Spotify and Apple documentation.
- Genre targets for LRA, PLR and band shares are hypotheses [H]; derive them from reference tracks measured with the same tools.
- Spectral share percentages are rough; the tilt of the reference should replace them.

## Sources

Standards and specifications (not all fetched in this session; cited from established knowledge, verify before quoting):
- ITU-R BS.1770 loudness and true-peak algorithm: https://www.itu.int/rec/R-REC-BS.1770
- EBU R 128 (-23 LUFS, -1 dBTP): https://tech.ebu.ch/docs/r/r128.pdf and https://en.wikipedia.org/wiki/EBU_R_128
- EBU Tech 3341 (metering) and Tech 3342 (loudness range): https://tech.ebu.ch/docs/tech/tech3341.pdf and https://tech.ebu.ch/docs/tech/tech3342.pdf
- ANSI/ASA S3.5 Speech Intelligibility Index (band importance, audibility): overview at https://pmc.ncbi.nlm.nih.gov/articles/PMC3292607 and https://metricgate.com/docs/speech-intelligibility-index-sii/
- SII vs STI and tonal balance: https://www.ioa.org.uk/system/files/proceedings/g_leembruggen_is_sii_better_than_sti_at_recognising_the_effects_of_poor_tonal_balance_on_intelligibility.pdf

Platform loudness (secondary):
- https://www.soundbridge.io/mastering-for-streaming-your-2026-platform-guide
- https://www.forasoft.com/learn/audio-for-video/articles-audio/lufs-targets-per-platform-2026
- https://www.softube.com/blog/mastering-for-spotify-why-everything-you-know-is-wrong-and-what-to-do-about-it
- https://www.robkleiner.com/resources/mastering-music-for-streaming-platforms

Lo-fi and hip-hop mixing craft (tutorials, opinion-heavy):
- https://www.antarestech.com/blog/the-complete-guide-to-mixing-lo-fi-music
- https://audient.com/tutorial/5-lo-fi-production-tips
- https://www.edmprod.com/lofi-hip-hop/
- https://www.sageaudio.com/articles/how-to-mix-hip-hop
- https://www.lofiweekly.com/2021/11/17/5-mixing-tips-for-lofi-hip-hop-producers
- https://www.ujam.com/blog/top-5-production-mixing-tips-for-lofi/
- https://www.masteringthemix.com/blogs/learn/tips-for-mastering-hip-hop
- https://splice.com/blog/?p=4806
- https://blog.landr.com/mixing-beats
- https://violetrecording.com/how-to-master-hip-hop/
