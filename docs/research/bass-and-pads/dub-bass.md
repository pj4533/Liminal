# Dub reggae bass: research for Liminal Lo-Fi bass rework

Confidence note: web sources (forums, magazine features) confirm tone/gear/mix practice qualitatively.
Numeric settings below marked (synth) are engineering translations by the researcher, not quoted from sources.

## Sources
- https://www.premierguitar.com/on-bass-entering-the-reggae-trance
- https://www.guitarworld.com/features/aston-family-man-barrett-interview
- https://www.guitarworld.com/features/how-family-man-turned-robbie-shakespeare-into-a-real-bass-player
- https://bassculture.substack.com/p/the-fender-jazz-bass-backbone-of
- https://bassculture.substack.com/p/the-heart-of-dub-filter-sweeps-and
- https://www.soundonsound.com/techniques/dub-mixing (Terrano, 2007)
- https://www.musicradar.com/tuition/tech/25-dub-tips-34138
- https://gearspace.com/threads/dub-bass-settings.335752/
- https://www.talkbass.com/threads/reggae-dub-live-bass-sound.495233/

## Tone
- Fender Jazz (neck pickup, tone rolled off) or Hofner violin bass, flatwound strings, foam/palm mute. Result: round, fundamental-heavy, almost no pick/string noise, upright-like.
- Recipe (synth): sine/triangle fundamental + very soft 2nd/3rd harmonic (-12 to -18 dB vs fundamental) so it still reads on small speakers. Low-pass 400-700 Hz (12 dB/oct), no resonance. Notes at 41-65 Hz (E1-C2) dominate; avoid sub-35 Hz energy.
- EQ from forums: big low boost around 60-100 Hz, flat mids, cut above ~2-3 kHz. Gentle 250-350 Hz dip if muddy against chords.
- Compression: slow-ish attack 20-30 ms (let the thump through), release 100-200 ms, ratio 4:1, 3-6 dB GR, to make it even rather than loud. Light tape/tube-style saturation (tanh, drive ~2-4 dB) adds harmonics at 150-400 Hz that carry on small speakers.

## Bassline writing
- Bass is the lead of the riddim: simple, melodic, repeated 1-2 bar figure with small variation every 2nd/4th bar (a passing tone or octave leap), played in the pocket, slightly behind the beat.
- Space is the instrument: typically 4-6 notes per bar at most, many rests. Root on beat 1 (or just after, with the one-drop leaving beat 1 empty in roots reggae; in boom bap hybrid keep a root on the kick), fifth, minor third, flat seven, octave jump as ornament.
- Note lengths: mostly 1/4 to 1/2 beat muted/short (ca. 150-350 ms at 72 BPM, beat = 833 ms), with one longer sustained note (1 to 2 beats, 800-1600 ms) per bar for weight. Rolled/pitch-slide into the target (30-60 ms slide, up to a 4th) on occasional notes.
- Pentatonic minor / Dorian shapes; stay inside the chord's key. Keep strict repetition: the dub trance comes from loop + slight variation.
- One-drop interplay: kick+snare land on beat 3 in one-drop; in boom bap bass should lock to kick hits on the same sample-grid and answer snare gaps, then drop out where snare/chop accents sit.

## Dub mixing techniques that apply
- Dropping out: mute bass for 1 bar (or half bar) before a section change, then slam it back on beat 1 with a reverb/echo tail on the last note. Use sparingly: once per 8-16 bars.
- Filter sweeps: LPF sweep on bass from ~150 Hz up to ~700 Hz over 1-2 bars (or the reverse) as a movement device; HPF on effects.
- Spring reverb / tape echo on bass: thrown, not constant. Send only on selected notes (the last note of a phrase, the accent before a drop), return high-passed so no low end is smeared.
- Keep low end dry and mono: everything below ~120 Hz mono and unprocessed; echo/reverb sends HPF at 200-300 Hz, LPF the echo return at 2-3 kHz (tape darkening), echo feedback 30-45%, dotted-eighth or quarter delay (at 72 BPM quarter = 833 ms, dotted-8th = 625 ms).
- Echo ducked under the dry bass (sidechain or simply send-only-on-gaps) to avoid wash.
- Short spring-ish reverb: 0.8-1.4 s decay, predelay 20-40 ms, HPF 250 Hz, wet at -18 to -24 dB relative to dry for thrown hits; never a constant wet bus on bass.

## What blends with boom bap at 70-90 BPM
- Hybrid reference points: Massive Attack (Protection era), Mad Professor remixes, Prince Fatty, Dubkasm: long round bass notes locked to kick, sparse bar-4 variation, effects on transitions only.
- Take from dub: roundness, fundamental weight, rests, melodic repeated figure, thrown echo/spring on phrase ends, drop-outs, LPF movement.
- Take from boom bap: kick-synchronised short punchy attack (first 5-15 ms with a click/transient harmonic at ~800 Hz-1.2 kHz, -20 dB), tight 80-250 ms decays, sidechain duck from kick (the app already has a kick duck).
- Do not take: constant long delay/reverb, wide stereo bass, tape-wobble pitch modulation on the main sustained notes.

## Concrete implementation summary (synth)
1. Voice: sine (or soft triangle) + 2nd harmonic -14 dB + 3rd -20 dB; 3 ms attack for sustain notes, 1 ms with 8 ms pitch-click down 12 semitones for punchy notes; LPF 500 Hz base, envelope opens to 900 Hz for 40 ms on note start.
2. Articulations: short punch (120-250 ms), medium (400-600 ms), long (1-1.6 s). Ratio roughly 50/30/20 per bar.
3. Compression 4:1, 25 ms attack, 150 ms release, 4 dB GR; soft saturation ahead of it.
4. Effects: one thrown send per 4-8 bars on the last note, echo 625 ms, FB 35%, HPF 250 / LPF 2.5 kHz, return -20 dB; mono below 120 Hz, side content above only.
5. Drop-out: bar 8 or 16 of a phrase, 1 beat to 1 bar, return on beat 1 with a longer note.
