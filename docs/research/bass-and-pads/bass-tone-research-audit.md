# Bass research audit (2026-11-20)

## Verdict
The bass is "tinny" because the sampled body is high-passed at 180 Hz (code; docs say 150), so what is left of the
Sneakybass/Swagbass note is only its >180 Hz string/attack band, which is then driven (tanh drive 4 upright / 2 flatwound),
opened by a per-note low-pass sweep to 650+300v+1100v Hz, boosted at 700 Hz, saturated again in parallel (200-900 Hz, mix 0.4),
given a 1 kHz click and a pitch-chirping sub on thump notes, and sent through a 220 Hz-up slap. The recorded samples are
themselves dark (research: Sneakybass finger E2 -63 dB above 2 kHz; Swagbass -41..-54 dB), so ALL the high end is manufactured.
Measured: 315-800 Hz is +10..+23 dB, 1-2 kHz +20 dB, 2.5-4 kHz +36 dB versus the approved pure-synth bass.
Notes are also short (thump 0.15-0.30 beats + 60 ms release; bar limit 2.6 of 4 beats), so it never reads as continuous.

## Deviations (code -> why it plausibly causes the symptom -> source)
1. Body high-pass 180 Hz, 24 dB/oct (LofiBassVoice.bodyHighpass). The sample's warmth (80-180 Hz) is discarded; only
   string noise/attack remains. Producers layer a sub UNDER a full-range dark body, or low-pass the body; they do not
   remove the body's low end. A 150-180 Hz split also leaves sub and body out of phase at the crossover unless both are
   linear-phase/same-order (here sub is a synth, body is minimum-phase biquads: cancellation/hollowness near 150-200 Hz).
   Sources: iconcollective bass-layering, musictech sub sculpting (split ~80 Hz, check phase).
2. Pre-crossover tanh drive 4 on the upright body (bodyDrive). Near-sine input + hard tanh = strong 3rd/5th/7th
   harmonics landing exactly in 500-1500 Hz: buzzy/"kazoo" odd-order content. Warm saturation is gentle and mostly low-order.
3. Per-note velocity low-pass opens to base(650-950 Hz)+1100v Hz (up to ~2 kHz) with 40 ms decay (velocityLowpass). Every note
   gets a bright "tine" strike. Dub tone is dark and fixed; sweeps are a deliberate slow movement device (150 -> 700 Hz over
   1-2 bars), not per-note. dub-bass.md itself says LPF 400-700 Hz base, envelope opening only to 900 Hz for 40 ms.
4. Parallel harmonics 200-900 Hz, drive 4, mix 0.40 (LofiStemChains.Bass) ON TOP of the driven body: double distortion, ~-8 dB
   under the dry band. Research target was parallel blend -12..-18 dB (mix 0.13-0.25) and only where the source is clean sine.
5. EQ +2 dB at 700 Hz (Q 0.8) and LPF 2.4 kHz single 12 dB/oct biquad. 700 Hz is the "honk/nasal" band; sources: flat mids, dip
   250-350, cut >2-3 kHz, "cut presence all the way" (talkbass roots thread). A 12 dB/oct 2.4k leaves -36..-66 dB up to 4 kHz
   audible as hiss/tin; "too filtered but not completely" is exactly a gentle high corner with plenty above it.
6. 3 ms Hann click at 1 kHz on thump notes (click 0.1 of body target) + sub pitch drop of 12 semitones over 8 ms
   (thump). The chirp's tanh harmonics sweep 100 -> 1.2 kHz in 8 ms: a "zap". The 1 kHz click was a rule-of-thumb in dub-bass.md
   (R, unsourced); actual dub bass has no click: the transient is the kick, bass attack is soft (3-10 ms). talkbass/Premier Guitar
   describe foam/palm-muted flatwounds, "almost no pick noise".
7. Tape slap above 220 Hz at 0.125 beat (~104 ms at 72 BPM), 3 repeats, LPF 1.8k (slap()). A 104 ms comb on the
   220-1800 Hz band gives metallic/chorused colour on exactly the band we hear as tinny. Dub echo is thrown on selected notes,
   >= dotted-8th (625 ms), return HPF 250 / LPF 2-3 kHz, low end dry (dub-bass.md; soundonsound dub-mixing). No source puts a
   short slap on a sustained dub bass.
8. Note length/articulation. thump 0.15-0.30 beat (125-250 ms), release 60 ms; walk 0.5-0.75; hold 1-2 beats; bar total <= 2.6
   beats; phrase 6.5-9.5 beats of 16. Each note restarts the sub phase (zero start phase) and re-triggers accent/LPF strike,
   so notes do not ring into each other. Dub lines: mostly 1/4-1/2 beat muted + one 1-2 beat sustained, BUT with strongly
   overlapping releases and rests only as a rhythmic device (Premier Guitar "reggae trance", Family Man interview).
   For "continuous warm" the sub should be near-continuous (long overlaps, legato glide <= 30-60 ms between pitches) and only
   a short brightness/punch layer retriggers at kick hits.
9. Doc/code drift: header comment says 150 Hz HP; code 180; plan says LPF 2.8k, code 2.4k. Fix docs with the change.

## What should be true (targets)
Third-octave bass stem, dB re total power (old approved -> new -> TARGET):
- 50-63 Hz: -7.8/-1.6 -> -4.1/-3.9 -> keep (-4..-8)
- 80-125 Hz: -16.6/-22.5/-21.1 -> -16.1/-18/-16.2 -> -14..-18 (warm weight; more here is OK)
- 160-250 Hz: -25/-17/-24 -> -16/-13.8/-17.2 -> -16..-20 (fullness, lowest-order harmonics 2nd/3rd)
- 315-800 Hz: -28/-31/-35/-42/-48 -> -17.5/-20.5/-22.2/-23.9/-25.6 -> -26/-30/-34/-40/-46 (back to approved slope ~ -9 dB/oct; sum above 300 Hz <= -22 dB)
- 1-2 kHz: <= -50; 2.5-4 kHz: <= -75 (approved was -57..-97). Natural dark upright/flatwound already sits near -60 above 2 kHz.
Overall high corner: 12 dB/oct at ~700-900 Hz, or 24 dB/oct at ~1.2 kHz; no boost 500-1000 Hz; dip 250-350 Hz 1-2 dB only if chords mask.
Sub+body: both full range below split, body NOT high-passed below ~60 Hz only (30 Hz HPF is fine); if layering with synth sub,
low-pass the body at 300-500 Hz instead of high-passing it, or high-pass at <=100 Hz with the sub low-passed at the same
Butterworth/LR corner and zero-phase to align. Saturation: gentle (tanh drive <=1.5-2), applied to sub/body BEFORE the final LPF so
the low-pass tames products; parallel blend -15 dB; slight even content (bias) is fine. Attack: 5-10 ms soft rise, no click,
no pitch chirp; accent only through level (<= +2 dB, 40 ms). Compression 4:1 attack 20-30 ms release 100-200 ms 3-5 dB GR (already).
Echo: only the existing throws; remove constant slap or move to >= 625 ms, HPF 250, LPF 2.5k, -20 dB.
Legato: thump length >= 0.5 beat, release 150-250 ms so notes overlap; keep rests as rhythmic drop-outs (1 beat per 8-16 bars).
Kick lock: the kick's own transient provides the "slap" at the downbeat; keep the existing kick-duck above/below 150 Hz and the rise-lead alignment.

## Sources (read this session via search; qualitative unless stated)
- https://bassculture.substack.com/p/eq-tips-for-reggae-and-dub-production
- https://bassculture.substack.com/p/the-heart-of-dub-filter-sweeps-and  (sweeps are a deliberate movement device)
- https://www.talkbass.com/threads/reggae-dub-live-bass-sound.495233/  (Jazz bass flatwounds, roll off most of the tone, cut presence)
- https://www.talkbass.com/threads/reggae-bass-effects.1043449/
- https://www.kvraudio.com/forum/viewtopic.php?p=9181858  (dub bass rarely filtered except sweeps; heavy saturation under a low LP)
- https://iconcollective.edu/bass-layering-tips ; https://musictech.net/tutorials/weekend-workshop-sculpt-sub-bass/ ; https://www.sageaudio.com/articles/the-best-low-end-mixing-tricks  (layer split ~80 Hz, same-corner HP/LP, phase check, mono <120 Hz)
- https://www.premierguitar.com/on-bass-entering-the-reggae-trance ; https://www.guitarworld.com/features/aston-family-man-barrett-interview ; https://www.soundonsound.com/techniques/dub-mixing (from docs/research/bass-and-pads/dub-bass.md; not re-fetched)
- https://www.attackmagazine.com/technique/beat-dissected/90s-boom-bap-hip-hop/ (sine-like bass, sample lows rolled off)
Gaps: no source gives spectral dB numbers for Family Man/Tubby bass; targets above are engineering judgement anchored on the
user-approved earlier pure-synth stem. Search did not settle even-vs-odd or pre/post-filter saturation order with a citation.
