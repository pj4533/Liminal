# Boom bap bass research

Sourcing note: no primary interviews with Pete Rock / Premier / Dilla give bass compressor values. Web sources are general guides. Items marked [S] are sourced; [R] are rule-of-thumb synthesis (verify by Liminal's own mix-matrix analysis).

## Sources of bass sound
- [S] Low-pass a sample loop to isolate its bass, keeping the original feel; or filter out the lows and write a new line locked to the drums (Pete Rock, Premier, Just Blaze cited). https://www.native-instruments.com/blogs/blog/what-is-boom-bap
- [S] Low-pass filtered piano/sax = low end character of ATCQ Low End Theory / Dilla "Runnin'" (sax highs removed). https://kenyonreview.org/2015/06/the-low-pass-theory-part-1/ ; https://22020945artsac.myblog.arts.ac.uk/?p=21
- [S] Dilla often played bass on a Minimoog (warm, round). https://create.routenote.com/blog/?p=20624
- [S] Attack Magazine 90s boom bap: sine-like bass (Operator "Sinelike Basic Bass"), sample lows rolled off, bass sidechained to kick, "very simple pattern". https://www.attackmagazine.com/technique/beat-dissected/90s-boom-bap-hip-hop/
- [S] Boom-bap 808: clean, warm, shorter sustain than trap, programmed melodically; boost low end via EQ/saturation if sample bass is weak. https://www.audeobox.com/learn/mpc-software/classic-hip-hop-workflow/
- [S] Pitch-down in sampler lowers pitch and tempo together (gritty, dark). https://modeaudio.com/magazine/masters-of-sampling-dj-premier

## Writing
- [S] Framework root, fifth, octave-down, root; octave drops add weight on small speakers; play fewer notes than instinct; pluck not hold; leave space. https://lofiweekly.com/2026/11/16/boom-bap-bass-lines/ , https://titanaudio.io/blog/how-to-write-a-bassline
- [S] Start notes on kick hits, or in gaps between kicks for bounce. Shorten notes that blur next kick.
- [S] Ghost notes 30-50% velocity, just before a main note; velocity must drive level AND filter cutoff to sound smaller.
- [R] At 72 BPM swung: 16th = 208 ms; 8th = 417 ms; quarter = 833 ms. Notes mostly 1/8 to 1/4 length (200-600 ms), long note (1 bar) once per 2-4 bars. Root on beat 1 locked with kick (same onset within ~5 ms), answer note on "and of 2" or "a of 3" (syncopated), fifth/octave pickup before bar end; rests are part of the line.

## Kick interaction
- [S] Sidechain only below ~120 Hz so bass top end remains (one source); sub-only ducking in another. https://www.sageaudio.com/articles/top-10-low-end-tips
- [R] Duck 2-4 dB, attack 1-5 ms, release 80-150 ms (about 1/8 note at 72 BPM = 417 ms; shorter is punchier); or a short duck envelope ~100 ms. Kick sits 40-200 Hz peak around 60 Hz; kick 60 Hz boost + 150 Hz dip on kick channel (Attack). Offset: bass fundamental ~45-55 Hz if kick ~60-70 Hz; separate pitches or alternate in time.

## Tone / mix
- [S] Sub does not translate on small speakers; use saturation and layering for harmonics (parallel saturation). https://iconcollective.edu/low-end-mixing-tips , https://www.sageaudio.com/articles/the-best-low-end-mixing-tricks
- [S] Odd-order (tape-like) saturation on bass so harmonics do not overlap kick's. 
- [S] Mono below 100 Hz (one source); others up to 250 Hz. Correlation under 0.9 = poor mono translation.
- [S] Hobbyist: boombap loop high-pass ~60 Hz to avoid kick conflict; (musicproductionwiki, unverified)
- [R] Bands: sub 40-70 Hz (fundamental, level 0 reference), body 80-200 Hz, "reads on small speakers" 300-900 Hz harmonics via parallel saturation (blend ~-12 to -18 dB under dry), low-pass the layer at ~2-3 kHz for dark sample character; high-pass at 30 Hz. Compression 3:1 to 4:1, attack 10-30 ms (let transient through), release 100-200 ms, 3-5 dB GR. Level: bass peak about 1-3 dB below kick in the 40-100 Hz band (equal-importance with drums per user brief; check with mix-matrix low-end criteria).

Gaps: Reverb "Engineering Dilla" article and Soundfly Dilla low-end article returned 403; no compressor settings from named producers.
