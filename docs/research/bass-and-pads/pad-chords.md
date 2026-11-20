# Pad-like chords under a lead (lo-fi / boom bap / dub)

Provenance: [S] = from a fetched/searched source; [J] = my engineering judgment/synthesis (starting point, verify with Liminal's mix-report).

## Sources
- https://www.izotope.com/en/learn/5-tips-for-mixing-pads (HP a pad ~430 Hz in one example; narrow pad stereo; medium pre-delay reverb panned opposite)
- https://www.soundonsound.com/techniques/making-space-your-mix (pre-cut EQ dip where lead lives)
- https://www.soundonsound.com/techniques/how-use-reverb-pro-1?page=2 (reverb HP 240 Hz, -5 dB at 580 Hz; HP 100-300 Hz common)
- https://www.soundonsound.com/node/4910076?page=2 (short reverb + long reverb with 30-70 ms pre-delay; roll off lows and highs of reverb)
- https://www.soundonsound.com/techniques/creating-sense-depth-your-mix (12-18 dB/oct low-pass automation ducks pads more subtly than level)
- https://www.mixonline.com/blog/the-mix-consultancy-creating-space-in-a-mix (LP what doesn't need air)
- https://blog.landr.com/lo-fi-mixing , https://www.antarestech.com/blog/the-complete-guide-to-mixing-lo-fi-music (reverb decay under ~1.2 s rule of thumb, roll off reverb highs, HP 150-200 Hz)
- https://www.loopmasters.com/articles/4494-How-To-Mix-Smooth-Hip-Hop-Electric-Piano-Chords

## Recommendations
1. Hold length [J]: each chord sustains the full chord duration (1-2 bars at 72 BPM = 3.3-6.7 s), legato overlap of next chord 150-300 ms; re-voice only on chord change; no re-attack within a chord. Voice-lead (common tones held, move minimal steps).
2. Voicing [J]: 3-4 note shell (root optional since bass owns it; use 3rd, 7th, 9th/5th). Range roughly C3-C5 (MIDI 48-72), center ~G3-C4; keep top note below the lead's lowest typical note (leave >= a 3rd/4th gap); drop-2 voicings for width in the lower mids; no notes under ~130 Hz (bass owns that).
3. Envelope [S/J]: attack 150-400 ms (swell, soft; 50 ms min), release 1.0-2.5 s, slight slow tremolo/chorus (0.2-0.4 Hz, shallow) for motion. Sources: Rhodes/EP held with long release, string-ish warm pad, swelled/reversed piano, tape-stretched or frozen/granular piano. Avoid organ/choir buzz.
4. Filtering [S/J]: HP 200-250 Hz (12 dB/oct) pre-reverb (iZotope example up to 430 Hz; HP 150-250 typical); LP 2.5-4 kHz (12-18 dB/oct) so lead owns the 3-6 kHz presence band; peaking cut 3-4 dB around 300-450 Hz if mud shows (SOS cut -5 dB @580 as a reverb example); dip 2-3 dB at the lead's fundamental/presence band (1-3 kHz) via a static EQ or the LP.
5. Reverb on pad [S/J]: send heavy (wet 40-60% of pad level), decay 2-3.5 s for the pad only (rule of thumb of <1.2 s applies to lead/drums, not pads), pre-delay 30-70 ms, reverb input HP 240-300 Hz and LP 4-5 kHz, damping high. Keep reverb return lower than the dry pad by ~3-6 dB so it blooms rather than washes.
6. Level [J]: pad RMS ~6-9 dB under the lead, ~3-6 dB under the previous (sparse) chord level only if its sustain raises integrated energy: held notes add energy, so cut peak gain ~2-3 dB vs staccato chords to keep loudness equal (sustained duty cycle roughly 2-4x).
7. Ducking [S/J]: pad sidechained to the lead at 1.5-3 dB reduction, attack 10-30 ms, release 200-400 ms; kick duck 1-2 dB (already existing kick duck pattern: keep it gentle; pad shouldn't pump). Alternative per SOS: automated low-pass dip (12 dB/oct, 3 kHz -> 1.8 kHz) when lead notes sound.
8. Stereo [S/J]: pad width 100-140% (wide chorus/Haas 8-20 ms or detune +-6 cents between L/R), side-weighted; keep below 250 Hz mono; lead/bass/kick centered. Reverb return decorrelated/opposite-panned (iZotope).

## Frequency analysis checks (mix-report) [S/J]
- Compare band energy 200-500 Hz before/after: pad must not raise that band by more than ~1 dB over current mix; target the same total mud-band energy as now (use 1/3-octave RMS on the master and chords stem).
- Masking: per 1/3-octave band 1-4 kHz, lead stem minus pad stem >= 6 dB in lead's presence band while lead sounds; check stem-vs-stem spectral overlap.
- Low end: pad stem energy below 150 Hz <= -30 dB relative to its peak band; bass/kick unaffected (LUFS and true-peak of master unchanged within +-0.5 LU).
- Spectral centroid of pad stem 600-1200 Hz; lead centroid > 1.2x pad centroid.
- Sustained-pad crest factor low (6-9 dB); check limiter reduction does not increase (>0.5 dB more is a fail).
- A/B: loudness-matched vs current render; lead intelligibility metric must not drop; chop cadence unaffected.
