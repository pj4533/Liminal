# Bass diagnosis: why the bass stem sounds tinny, over-filtered and oddly bright (main bab3fed, 2026-11-20)

## Method
- I worked in a throwaway worktree. The only change was making `renderSub`, `renderBody`, `velocityLowpass` and `envelope` non-private, plus a temporary Swift test (`BassDiagTests`). The test rendered every stage for both kits, all four strokes and MIDI 28/33/38 at velocity 0.8 with tempo 72. It also rendered phrase 1 of cap-fix-1 (seed 2077, 14 notes, taken from score.json and diagnostics.bass) with the upright, flatwound and classic voices.
- Checks on the replicas: the body replica matches `renderBody` to 2.5e-7. The chain replica matches `applyBass` to 6e-8. The upright phrase replica correlates 0.9989 with the app's cap-fix-1 phrase 1. The kick duck and edge envelope change every band by only -0.1 dB.
- Files: WAVs in `wav/`, scripts in `py/`, tables in `notes.txt`, `phrase.txt`, `harm.txt`, `attack.txt`, `onset.txt`, `lag.txt`, `burst.txt` and `time.txt`. The figure is `spectrograms.png`.
- Settings that differ from the task brief: the body high-pass is 180 Hz, not 150 Hz. The harmonics band is 200-900 Hz, the 80 Hz EQ boost is +0.5 dB and the LPF is at 2.4 kHz. All 8 phrases of cap-fix-1 used the upright kit.

## Stem facts (band share, dB re the stem's total power)
| band | old approved (final-main) | new (cap-fix-1, phrase 1) |
|---|---|---|
| 40-80 | -0.4 | -0.8 |
| 80-150 | -12.9 | -13.6 |
| 150-300 | -15.6 | -10.6 |
| 300-600 | -25.5 | -15.2 |
| 600-1200 | -40.6 | -19.2 |
| 1.2-2.5k | -56.3 | -35.1 |
| centroid | 74 Hz | 91 Hz |

The 80-150 Hz warmth band did not change. Everything from 150 Hz to 2.5 kHz rose by 5 to 21 dB. The tilt is now inverted: 150-300 sits above 80-150, and 300-600 is only 1.6 dB under it (in the old stem it was 12.6 dB under).

## Ranked causes

1. **The sampled body layer accounts for the whole problem above 300 Hz, and its spectrum is a band-passed plateau.** On the upright phrase the body provides 600-1200 Hz at -42.6 dBFS against the sub's -69.1, and 1.2-2.5 kHz at -53.9 against -91.9. This happens because the body has its fundamental removed (24 dB/oct high-pass at 180 Hz) and is then low-passed by a 2-pole filter at about 890 Hz (`650+300v`). That leaves a 180-900 Hz telephone band set only 11 dB under the sub's RMS. The harmonic envelope is the clearest view. After the chain, the classic hold on MIDI 33 has h2..h8 at -18 -19 -30 -34 -42 -47 -54 dB. The upright version has -14 -11 -15 -18 -19 -30 -26 dB and stays near -40 dB through h16. That is a flat plateau from h3 to h12 instead of a roll-off of about 6 dB per harmonic. The upright also needs tanh drive 4 to get any body at all, which adds 5.8-9.2 dB above 150 Hz. Its files are almost pure sines: content above 180 Hz is 12-19 dB under the fundamental for roots 33-39. **This is the "tinny" sound and the "too filtered, but not completely" sound.**

2. **The upright body's upper content arrives 30-50 ms late as an inharmonic burst, so the strike and the bright part are two separate events.** In the rendered notes, the upright body reaches its -6 dB rise at 29-41 ms and peaks at 41-56 ms. At the sub's peak (3-11 ms) it is still 28-35 dB under its own peak. The flatwound body rises at 0-2 ms and peaks at 3-27 ms. The raw upright files (the `short` and `long` files are the same recordings) peak 50-174 ms after onset. Their content above 180 Hz is 18-58 dB down at 10 ms.

   In the upright body's 600-2500 Hz band, level by window relative to the whole note:
   - 0-20 ms: -22 to -50 dB
   - 20-70 ms: -3 to +10 dB
   - 70-150 ms: -8 to +1 dB

   Only 25-49% of that energy lies within ±20% f0 of a harmonic. Those windows cover 40% of the spectrum, so 40% means noise-like. This is finger, string or room noise, not tone; the vertical streaks in `spectrograms.png` show it. The round robins also disagree on lead silence: 0 vs 31 ms at root 28, 0 vs 12 ms at 33, 4 vs 10 ms at 39. **This is the "weird high end", and it is why there is no hard slap.** The strike is the sub's 12-semitone 8 ms pitch drop alone, and a delayed noisy midrange bloom follows it.

3. **The line is choppy, not continuous.** Across cap-fix-1 there are 100 notes. 49% are thumps lasting 0.12-0.20 s plus a 60 ms release. The median sounding length divided by the inter-onset interval is 0.51, and 47% of notes sound for less than half their slot (thump 0.48, walk 0.49, hold 0.86). The stem has 43 silences longer than 150 ms per minute, against 12 per minute in the old stem. Because the hit and the sustain are separate short notes, the bass never holds a warm tone through the bar.

4. **A warmth hole between the sub and the body.** The sub's 3rd harmonic is cancelled: it measures -56 dB re h1, because the inverted `-0.10` third cancels the 3rd that tanh(1.2x) generates. The sub contributes h2 at -16 dB, h4 at -25 dB and almost nothing else. The body high-pass at 180 Hz (24 dB/oct) removes the body's h2/h3 below about 180 Hz. On MIDI 28 the voice's h3 (124 Hz) is at -39 dB, against -19 dB in classic, while h5 (206 Hz) is at -13 dB. The result is a scooped low-mid with a formant above it.

5. **The chain adds more midrange on top of the body.** On the upright phrase, absolute band changes per stage:
   - Parallel harmonics (200-900 Hz, mix 0.40): +3.6 dB at 150-300, +5.6 dB at 300-600, +3.4 dB at 600-1200.
   - EQ (+2 dB at 700 Hz, -2 dB at 280 Hz): +1.5 dB at 600-1200, -1.0 dB at 150-300.
   - Compressor: about -0.4 dB (GR mean 0.4-1.9 dB, max 4.4 dB, makeup 1.3-2.8 dB).
   - LPF at 2.4 kHz: only -1.1 dB at 1.2-2.5k and -4.9 dB at 2.5-5k, so it leaves the 1-2.4 kHz noise in place.

6. **The 1 kHz thump click is minor.** It carries 0-18% of the body's 1-2.5 kHz energy on thumps. Its peak relative to the 10-60 ms window is +1.8 dB on upright MIDI 38 and -27 dB on upright 33.

7. **The tape slap is negligible on upright** (≤0.2 dB at 95-135 ms). On flatwound thumps it raises the band above 220 Hz at about 104 ms by 2.3-4.6 dB, which is a faint flam. It was not active in the capture.

## Ruled out
- Comb filtering or phase cancellation between the sub and the body: the coherent sum minus the power sum is within ±1.1 dB in 80-600 Hz on all 24 notes, and within ±0.2 dB on most.
- Resampling aliasing (32 kHz to 48 kHz, linear interpolation): the body above 5 kHz is -57 dB before the LPF.
- Truncation or fade clicks: every envelope corner is a raised cosine, and the body is exactly zero after the release.
- The kick duck: -0.1 dB in every band.

## What this points to (for the fixer)
- Make the body a harmonic, rolled-off mid layer: lower the 180 Hz crossover, use a gentler slope, or give the sub a real h2/h3. Keep the content above 600 Hz well under -30 dB re total and set the low-pass envelope so that brightness is highest at the strike.
- Drop the upright finger samples or trim them to their onset. Their delayed, noisy bloom cannot be the slap. If a sample has to provide the slap, flatwound `short` has its brightness at 3 ms. The alternative is a synthesized pluck transient that decays over about 50-150 ms.
- Remove or narrow the parallel harmonics band and the +2 dB at 700 Hz.
- Rewrite the line so that the kick-anchored strike begins a sustained note (legato ratio about 0.85-1), instead of a 0.16 s thump followed by a separate note.
