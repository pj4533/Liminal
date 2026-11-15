# Music: calm redesign (diagnosis and plan)

Status: implemented (decisions D91-D106 in `docs/decisions/music.md`, which record where the implementation differs from this plan: the beds keep the old brightness curve, the pad is in every scene, air tops out at 1.2 kHz, the lead is 5 dB quieter, the body-band step metric uses a 25 ms window, the Deep centroid floor is 200 Hz). `music-criteria-calm.json` below is now `scripts/music-criteria.json`; the old gates are in `music-criteria-legacy.json`.

## 1. The feedback and what it means

On the 10-minute demo (`verify3-a`, seed 707) the user said:

> I don't like the super high pitched bell and tinks. It's too abrasive. Needs to be smoother. I like the bass and pads. But anything high pitched or harsh needs a lot of reverb and smoothing. The whole thing needs to be RELAXING. redo it.

Reading: keep the drone and the pad. Everything else becomes soft, warm, slow and mostly reverb. Reference points are Eno's "Music for Airports", Stars of the Lid and Hiroshi Yoshimura: few events, long tails, no edges.

The previous acceptance gates pushed the other way on purpose (centroid 450-1400 Hz, at least 150 onsets per 5 minutes, at least 1.5 % of power above 2 kHz, decisions D84-D89 added strike transients so the onset detector would find notes). Those gates are the reason the demo sounds the way it does, and they are replaced in section 6.

## 2. Diagnosis

### Method

- Seed 707, 600 s, limiter bypassed (so stems add up linearly). One stem per layer with the score unchanged: `only=<layer>` zeroes the other layers' trims without forcing anything on. Dry stems (`mute=reverb,delay,shimmer`) for the struck layers. A "calm reference" with drips, keys, pluck and grains muted (`calmref-*`, seeds 707, 101, 808), which is the closest thing to the target the current code can produce.
- Metrics: `scripts/analyze-calm.py` (power above 2 / 3 / 5 / 8 kHz, top-band levels, attack steps, crest, flux, loudness range). An attack step is the linear rise of a 10 ms RMS envelope inside 30 ms, so it is large only when something is both fast and loud.
- `xcodebuild test` could not run during this work: `testmanagerd` is blocked on a LocalAuthentication prompt (`_XCT_enableAutomationModeWithReply`) from an earlier UI-test session, and every control session times out after 120 s. Renders were made with a standalone binary compiled from the same `Liminal/Audio` sources (scratchpad `calm-cli/build.sh`); its seed-707 output correlates 1.0 with `verify3-a-bypass.wav`. `scripts/render-music.sh` will work again once that prompt is answered or the daemon restarts.

### Who makes the top end (share of the mix's power, seed 707)

| stem | all | > 2 kHz | > 3 kHz | > 5 kHz | > 8 kHz | HF attacks / min (> -40 dBFS) | steepest HF step |
|---|---|---|---|---|---|---|---|
| drips | 15.5 % | 66 % | **81 %** | **89 %** | **93 %** | 18.3 | -11.1 dBFS |
| pluck | 8.7 % | 15 % | 11 % | 6 % | 4 % | 27.9 | -21.3 |
| keys | 6.3 % | 8 % | 4 % | 2.5 % | 0.2 % | 5.4 | -24.2 |
| pad | 52.5 % | 8.5 % | 1.9 % | 0.1 % | 0 | 9.2 (beating of the detuned pairs, none above -34 dBFS) | -34.6 |
| air | 0.2 % | 2.1 % | 2.2 % | 1.0 % | 0.4 % | 0 | -45.0 |
| lead | 5.1 % | 0 | 0 | 0 | 0 | 0 | -59.8 |
| drone | 11.7 % | 0 | 0 | 0 | 0 | 0 | none |
| grains | silent on this seed (never reached its threshold) | | | | | | |

Whole mix: 37.5 HF attacks per minute above -34 dBFS (49.6 above -40), 55 notes per minute (pluck 285, drips 160, keys 91, lead 13 in 10 minutes), power centroid 740 Hz, -13.9 dB of the power above 3 kHz.

### Findings

1. **Drips are the "super high pitched tinks".** `DripsLayer` plays MIDI 72-101 (523 Hz-2.8 kHz fundamentals) through FM ratios 2, 3, 3.5 and 4 with an 8 ms attack and a +0.9 index strike transient (D85). It has no filter. It carries 81-93 % of everything above 3 kHz. The dry stem measures the same as the wet one: the drips are heard dry, on top of the mix, not in the reverb.
2. **Pluck is the other half of the tinks.** Karplus-Strong attacks (noise burst) in an ostinato of 16-40 steps at 0.42-1.05 s (D84): 285 notes, 28 fast attacks per minute, crest factor 23.8 dB above 2 kHz.
3. **Keys are the "bell".** Presets `bell` (ratio 1:3.5, inharmonic) and `glass` (1:7), 3-4 ms attacks, a hammer transient that multiplies the index by 1.4-1.9, register up to MIDI 90, low-pass open to 7 kHz. Fewer notes than the other two on this seed (91), far more on others (seed 101 keys stem: 9 % of its power above 3 kHz, steps to -17.8 dBFS). The arpeggio cascade and bell toll rare events use the same voice at velocity 0.95-1.0.
4. **Grains** did not sound on seed 707 but did on 101 and 202 (117-189 grains): sine grains up to MIDI 106 (3.7 kHz), 30 % of them "glints" with 12-30 ms attacks.
5. **Air** sweeps a noise band to 6.5 kHz and has risers on image changes and on the air-swell event (which cuts off in 0.35 s). Small in level, but it is the only source of hiss.
6. **Shimmer (octave-up reverb) is not the problem at default settings.** Muting it changed nothing measurable (98-100 % of the top-band power remains). It is still an octave-up pitch shifter that a bloom raises to -8 dB, and it costs a pitch shifter and a second reverb, so it is retuned rather than kept (section 4).
7. **Lead is already soft** (0.4-1.5 s attacks, no HF). One defect: when a ringing voice is reused, `setAmplitude(..., over: 0.05)` steps its level in 50 ms (steepest body step -23.8 dBFS).
8. **Drone and pad are clean**: 0 loud attacks, nothing above 5 kHz. The pad's own top end (8.5 % of the mix above 2 kHz) only appears when the brightness macro is near its 0.92 ceiling.
9. **Styles**: Glass is the brightest (power centroid 1016 Hz, -12.0 dB above 3 kHz, 52.7 HF attacks > -40 dBFS per minute), Garden has the worst single minute (roll-off 6.6 kHz), Deep is the least sharp but still fails every brightness gate. No style is relaxing today.
10. **Form**: 6 scenes in 10 minutes, chord every 11-27 s, up to 5-6 layers at once, a pointed voice forced into every scene kind (D84).

### What "calm" measures

The calm reference (drone, pad, lead, air only) on three seeds: power centroid 309-368 Hz, -26 to -31 dB above 3 kHz, 0.0 HF attacks per minute, onsets 5-10 per 5 minutes. It still has spectral novelty 0.077-0.105 and self-similarity 0.51-0.58 (the old static three-voice baseline: 0.75), so slow evolution does not depend on the struck layers.

## 3. Per-layer changes

Shared mechanism, new: `LayerStrip` gets an optional dry gain (one `Fader` between panner and dry bus, only for strips that ask for it: drips, keys, pluck, grains, four nodes). With send gains at 0.8-1.0 and dry at 0.25-0.5 these layers become mostly wet.

`LayerID`, `MusicState`, `setVisualMood`, `imageDidChange`, `setVisualActivity`, `shimmerNotePlayed` and `RareEventKind` raw values do not change. Layers are re-voiced in place.

| layer | today | plan |
|---|---|---|
| **Drone** | 6 partials, LPF 220-1100 Hz | Unchanged. |
| **Pad** | 4 detuned pairs, ladder 450-6000 Hz by brightness | Unchanged code. It gets darker in bright scenes only because the brightness macro tops out at 0.70 instead of 0.92 (ladder at most 2.8 kHz). |
| **Lead** | sine + triangle, attack 0.4-1.5 s, MIDI 55-88, LPF 1.2-6 kHz, loop 13-23 s | Becomes the main melodic voice. Register 55-79. LPF `expMap(b, 900, 2400)`. Attack 0.6-1.8 s, release 4-7 s. Triangle mix 0.6 -> 0.3. Level changes on a reused voice ramp over 0.4 s (fixes finding 7). Loop 18-34 s. Sends: reverb 0.8, delay 0.45. Trim unchanged (-17 dB). |
| **Drips** -> soft motes | FM 1:2-1:4, MIDI 72-101, 8 ms attack, strike transient, no filter, dry | Sine carrier, ratio 1, index at most 0.15, no strike transient, no mallet preset, no inharmonic ratios. Register MIDI 60-79 (C4-G5), register shift clamped to -3...+2. Attack 120-350 ms, single decay 2.5-5 s. New strip LPF `expMap(b, 1400, 2200)`. Trim -12.5 -> -20 dB, dry 0.3, reverb send 1.0, delay 0.5. Loop 2.5-6 s -> 9-20 s, 1-2 notes per cluster (weights 0.7 / 0.3), 0.9-2.5 s apart. About 4-7 notes per minute while active (was about 30). |
| **Keys** -> felt keys | FM bell 1:3.5 and glass 1:7, 3-4 ms attack, hammer x1.4-1.9, MIDI 57-90, LPF 1.5-7 kHz, loop 4-9 s | Presets `felt` (1:1, index 0.9 -> 0.1 over 1.2 s), `warm` (1:2, 0.5 -> 0.05), `hollow` (1:3, 0.25 -> 0). Integer ratios only, index never above 1.0, no hammer. Attack 80 / 120 / 140 ms, decay 4-8 s. Register MIDI 48-76, shift clamped -4...+3. LPF `expMap(b, 900, 2600)`. Velocity 0.35-0.7. Trim -14 -> -17 dB, dry 0.5, reverb 0.9, delay 0.3. Loop 14-30 s. Figures: single note, dyad, slow roll (3 notes 250-500 ms apart), 2-3 note phrase with 1.2-3 s gaps. The 6-12 note "music box" arpeggio is removed. At most 6 notes per minute. |
| **Pluck** -> soft harp | Karplus-Strong, ostinato 0.42-1.05 s, MIDI 52-86, LPF 1.8-4 kHz | `PluckedString` replaced by three `Oscillator`s on a soft table (fundamental, 0.25 second, 0.08 third harmonic) with ramp envelopes: attack 45-90 ms, decay 2.5-4 s. Ostinato removed. Phrases of 2-4 notes, 0.8-1.8 s apart, every 20-45 s. Register MIDI 48-72. LPF `expMap(b, 700, 1800)`. Trim -10 -> -16 dB, dry 0.4, reverb 0.8, delay 0.5. Fewer nodes than today. |
| **Grains** -> mist | sine grains MIDI 64-106, 12-150 ms attacks, up to 10 per second | Chord tones in MIDI 60-84, octave drops only. Attack 150-400 ms, release 0.8-2 s, no glints. Rate at most 1.5 per second. Trim -16 -> -22 dB, dry 0.25, reverb 1.0, delay 0.2. |
| **Air** -> breath | noise band 450 Hz-6.5 kHz, risers, cut-off swell | Band centre `expMap(pos, 250, 1400)`. Riser offset 0.5 -> 0.2 and gain `1 + 1.6 r` -> `1 + 0.6 r`. Breath period 30-70 s. Air-swell event: rise 10-14 s, no cut, decay 6 s. Image-change swell keeps its timing at the lower gain. Trim -19 -> -22 dB. |

## 4. Mix bus

| part | today | plan |
|---|---|---|
| Reverb (Zita) | RT60 3-8 s (5.5 at default), damping 3-6.5 kHz, return -12...-2 dB | RT60 `6 + 6 * space` (9 s at default), low band 0.6 x mid (keeps D74), damping `expMap(b, 1800, 3200)`, return `-9 + 8 * space` dB. One `LowPassButterworthFilter` at 4 kHz on the return. |
| Delay | 0.85-1.35 s, feedback 0.35-0.75, LPF 2.5-4.2 kHz after the delay (repeats are not damped inside the loop) | Time 1.3-2.1 s. A second LPF before the delay (1.6-2.2 kHz) so every repeat is dark; the existing one moves to 2.0-2.8 kHz. Feedback 0.3-0.55. Return `-10 + 5 * amount` dB. |
| Shimmer | HPF 400 -> pitch shift +12 -> LPF 5 kHz -> Costello | Pitch shifter removed from the graph. It becomes a dark halo: HPF 300 -> LPF 1.8 kHz -> Costello (feedback 0.93, cutoff 2.5 kHz). Return capped at -14 dB, bloom to -10 dB (was -12 / -8). `MusicState.shimmerLevel` still reports it. |
| Master | HPF 28 Hz -> trim -> limiter | One `LowPassButterworthFilter` at 7 kHz after the HPF, as a safety net. Master gain retuned so RMS stays in gate (expected +1 to +2 dB). Limiter unchanged; it must stay idle (bypass peak gate). |
| Brightness macro | `0.5 + 0.6 bias + 0.35 (i - 0.4) + ...`, knee 0.6, ceiling 0.92 | `0.42 + 0.4 bias + 0.2 (i - 0.4) + nudge + 0.1 drift`, knee 0.5, ceiling 0.70. |

Node count: +4 dry faders, +3 filters, -1 pitch shifter, pluck strings swapped for oscillators. CPU should fall (the pitch shifter was one of the three heavy nodes).

## 5. Scenes, form and styles

- Scene lengths: stillness 120-210 s, drift 180-300, bloom 180-300, constellation 150-240, tide 180-300 (were 45-90, 90-180, 120-240, 90-150, 80-140). Fall fraction 0.3-0.45.
- Peaks: bloom 0.55-0.8, constellation 0.4-0.6. Scene brightness bias: stillness -0.3, drift -0.1, bloom +0.15, constellation +0.05, tide -0.2.
- At most one struck layer (keys, drips, pluck) per scene, plus optionally lead or grains. Stillness and tide no longer force a pointed voice (reverses D84). Constellation becomes "a few soft lights": one struck layer and the mist.
- Layer cap `3 + round(2 * density)` (4 at default, was 5). Fade in 15-40 s, out 20-50 s.
- Harmonic rhythm `lerp(40, 22, intensity)` +-25 %, clamped 18-55 s (was 27 -> 11, 10-40). Key moves every 180-360 s. Pedal holds at least 60 s.
- Rare events: one every 240-600 s, first after 150-300 s. Arpeggio cascade becomes a slow fall (4-6 felt notes, 0.9-1.6 s apart, velocity at most 0.6). Bell toll becomes three low warm notes at velocity at most 0.6. Sub pulse +3 dB. Hush and halo bloom stay.
- Image-change accent: probability 0.35 -> 0.2, velocity 0.45.
- Styles, all relaxing:
  - Drift: neutral, unchanged palette.
  - Glass: register bias 3 -> 1, brightness bias 0.25 -> 0.08, keys 1.3 / grains 1.4 / drips 1.2, halo 1.2, form tempo 1.0, constellation weight 1.8 -> 1.0. "Glass" now means soft, hollow, high-ish tones in a long tail.
  - Deep: form tempo 1.25, constellation 0.3, otherwise unchanged.
  - Garden: pluck 2 -> 1.3, drips 1.2, keys 1.2, pad 0.55 -> 0.8, form tempo 1.0, constellation 0.9. The mallet drips preset is gone.

## 6. Acceptance gates

`scripts/music-criteria-calm.json`, checked with:

    scripts/check-music.py <label> --criteria scripts/music-criteria-calm.json --bypass <label>-bypass --other <other-seed>

10-minute renders, at least two seeds per style. When the redesign lands this file replaces `music-criteria.json`.

Calibration: "now" is the demo render (seed 707), "calm ref" is the current engine with the struck layers muted (seeds 707 / 101 / 808). The demo fails 26 of these gates; the calm reference passes every audio gate.

### Brightness

| gate | metric | threshold | now | calm ref |
|---|---|---|---|---|
| centroid_power | power-weighted centroid | 220-480 Hz | 740 | 368 / 309 |
| share_gt2k | power above 2 kHz re total | <= -17 dB | -11.7 | -19.8 / -20.7 |
| share_gt3k | power above 3 kHz | <= -24 dB | -13.9 | -26.2 / -31.1 |
| share_gt3k_minute | same, worst minute | <= -17 dB | -10.9 | -18.3 / -23.7 |
| share_gt5k | power above 5 kHz | <= -36 dB | -18.5 | -36.5 / -44.8 |
| share_gt8k | power above 8 kHz | <= -46 dB | -25.1 | -47.6 / -55.0 |
| level_gt2k_p99 | 50 ms frames above 2 kHz, p99 | <= -33 dBFS | -23.8 | -37.1 / -36.3 |
| level_gt5k_p95 | 50 ms frames above 5 kHz, p95 | <= -52 dBFS | -39.4 | -54.0 / -58.9 |
| level_gt5k_p99 | same, p99 | <= -46 dBFS | -29.4 | -49.6 / -56.7 |
| rolloff95 | 95 % roll-off | <= 1300 Hz | 2648 | 938 / 820 |
| rolloff95_minute | same, worst minute | <= 2400 Hz | 3949 | 2074 / 2273 |

The old frame-averaged magnitude centroid is dropped: it weights a near-silent frame as much as a loud one (the calm reference reads 663-1142 Hz on it).

### Sharpness

| gate | metric | threshold | now | calm ref |
|---|---|---|---|---|
| hf_attacks | steps above -34 dBFS in the band above 1.5 kHz, per minute | <= 0.5 | 37.5 | 0.0 |
| hf_step_p999 | HF step, 99.9th percentile | <= -34 dBFS | -20.0 | -39.5 / -38.4 |
| hf_step_max | steepest HF step | <= -28 dBFS | -11.1 | -34.2 / -34.7 |
| attacks_loud | steps above -24 dBFS, band above 200 Hz, per minute | <= 1 | 8.9 | 0.9 / 0.0 |
| attacks | steps above -30 dBFS, per minute | <= 8 | 29.0 | 3.0 / 0.3 |
| step_p999 | body step, 99.9th percentile | <= -23 dBFS | -19.9 | -24.4 / -32.5 |
| step_max | steepest body step | <= -16 dBFS | -11.9 | -20.2 / -29.4 |
| hf_crest | crest factor above 2 kHz, p95 of 1 s windows | <= 17 dB | 20.2 | 14.0 / 14.2 |
| hf_flux | positive spectral flux above 2 kHz, p99 | <= -26 dB | -13.9 | -30.7 / -33.5 |
| flux | full-band flux, p99 | <= -19 dB | -10.6 | -23.9 / -24.2 |

A note that reaches -24 dBFS with an 80 ms attack steps by about -32 dBFS in 30 ms; the same note with an 8 ms attack steps by -24. The step gates therefore read as "nothing audible starts faster than about 30 ms".

### Busyness

| gate | metric | threshold | now |
|---|---|---|---|
| onsets | detected onsets per 5 minutes | <= 100 (20 per minute) | 240 |
| pointed_notes | keys + drips + pluck notes per minute (score log) | <= 10 | 53.6 |
| pointed_notes_minute | same, busiest minute | <= 18 | 127 |
| layers_max | layers sounding at once | <= 4 | 5 |
| rare_events | per 10 minutes | <= 3 | 2 |

### Loudness

| gate | metric | threshold | now |
|---|---|---|---|
| true_peak | true peak | <= -3.0 dBFS (was -1.0) | -4.51 |
| bypass_peak | true peak, limiter bypassed | <= -3.0 dBFS | -4.51 |
| loudness_range | 3 s short-term level, p10 to p95 | 2.5-9 dB | 7.0 |
| short_term_max | loudest 3 s above the mean | <= 6 dB | 4.7 |
| rms_mean | mean 1 s RMS | -28...-20 dBFS | -25.9 |
| rms_std | | 1.5-5 dB | 3.78 |
| rms_per30_span | | 2-10 dB | 8.4 |

### Still music (slow evolution) and seeds

| gate | metric | threshold | now |
|---|---|---|---|
| spec_novelty | minute-to-minute spectral distance, median | >= 0.02 | 0.088 |
| chroma_novelty | minute-to-minute chroma distance, median | 0.08-0.45 | 0.235 |
| selfsim_mean | 10 s self-similarity | <= 0.75 | 0.565 |
| selfsim_min | | <= 0.45 | 0.136 |
| chord_rate | stable chord changes per minute (audio) | 0.8-4 | 2.8 |
| chord_changes | chord changes per 10 minutes (score) | 12-30 | 30 |
| distinct_chords | per 5 minutes | >= 6 | 21.5 |
| pcs_gt5, pc_entropy | pitch classes above 5 %, entropy | 4-8, 2.3-3.3 bits | 7, 3.08 |
| scene_changes_10m | scene changes per 10 minutes | 1.5-4.5 | 5 |
| layers_active | layers heard for 30 s or more | >= 4 | 7 |
| layers_min | layers sounding after the first minute | >= 2 | 2 |
| seeds_differ | of scene kinds, scene times, first 8 chords, initial key: how many differ from the other seed | >= 3 | 4 |

Unchanged technical gates: no clipped or NaN samples, silence at most 4 s, quietest second at least -50 dBFS, side/mid -12...-4 dB, L/R correlation 0.2-0.85, sub-120 Hz correlation at least 0.9, conductor tick mean 0.2 ms and max 2 ms.

Removed: `centroid_mean` 450-1400, `centroid_std` >= 250, `centroid_p95` >= 1500, `centroid_ratio` >= 2, `share_gt2k` >= 1.5 %, `band_2k_8k` >= 3 %, `onsets` >= 150, `onset_ratio` >= 3, `layers_max` <= 6, `scene_changes_10m` >= 4.

## 7. Build order

1. Mix bus: halo, reverb, delay pre-filter, master low-pass, brightness macro. Render: every brightness gate should move before any layer changes.
2. `LayerStrip` dry gain; drips, then pluck, then keys, then grains, air, lead. One stem render after each (`ONLY=<layer>`): the stem alone must pass the sharpness gates.
3. Scene director, conductor timings, rare events, styles.
4. Retune trims and master gain against `rms_mean` and `bypass_peak`.
5. Full check on two seeds for each of the four styles; listen to a 10-minute demo before calling it done. The gates say "not harsh"; they do not say "beautiful".
6. Swap `music-criteria-calm.json` in as `music-criteria.json`, fold `analyze-calm.py` into the render script (done), update `docs/decisions/music.md` (D91 onward) and `docs/plans/music.md` section 11.

## 8. Risks

- **Too dull.** With every source under 2.6 kHz the mix can turn to mud. The centroid floor (220 Hz), `layers_active` and the novelty gates guard the measurable part; the listening pass guards the rest. If it is dull, raise the felt keys' and motes' level, not their brightness.
- **Mostly-wet layers and the limiter.** A 9 s reverb accumulates energy. `bypass_peak` and `short_term_max` catch it; the return gain is the control.
- **Visual coupling.** Fewer `noteOn` events and no cascade reach the render loop through `MusicState`. The other workstream reads the same fields; event rates drop by about 5x, and `shimmerNotePlayed` fires 4-7 times a minute instead of about 30.
- **Glass and Garden lose their identity.** They keep their palettes and layer weights; the difference becomes register and voice choice inside a narrow, dark range. If they end up indistinguishable from Drift, widen the register biases (which the layer clamps bound) before touching brightness.
- **Seed tails.** 55 gates and many seeds: a narrow miss on a new seed is likely. Thresholds sit 2-6 dB inside what the calm reference measures where that was possible; `share_gt5k` (-36 against -36.5 on seed 707, with the air still sweeping to 6.5 kHz) has the least margin until the air change lands.
