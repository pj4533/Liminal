# Boom-bap dialogue chopping: craft research and Liminal rules

19 November 2026 · Independent check of the craft and history claims in [mpc-chopping-handoff.md](mpc-chopping-handoff.md), plus new material for the automatic dialogue chopping engine.

## How to read this note

Each item is marked **CONFIRMED** (re-read in a source here), **CORRECTED** (the handoff wording needs adjusting), **NEW** (not in the handoff), or **UNVERIFIED** (a search did not surface support). Every item ends with a **Rule** that is implementable. Numeric ranges are starting hypotheses for tuning against renders, not producer-stated values. Where a source is a secondary author rather than the producer, the item says so. No audio was auditioned. Search snippets were summarized by tooling; only passages fetched directly are quoted.

Several requested subjects returned little reliable first-hand material: Knxwledge, RZA, 9th Wonder and Madlib dialogue/skit chopping had no usable chopping-method detail in the searches. These are listed as gaps, not filled by inference.

## 1. Re-verification of handoff claims

### 1.1 DJ Premier, "The Question Remains" (CONFIRMED, with detail)
The RBMA transcript says the source was a Bob James record damaged by a paper stuck to it, that he "kept chopping it and kept starting it over right at that one little stab", then "pitched it down one time and Guru was like, 'Yo, let's just leave it like that'" and "put it on a different pad and then flip-flopped from then." He also says "I started doing stab-type samples just to strip down more" and defines stabs as "a short dash." The MPC60 is not mentioned in that lecture text, so any claim tying this account to a specific machine is unsupported there. Source: [RBMA lecture](https://www.redbullmusicacademy.com/lectures/dj-premier-you-know-my-steez/).

Rule: bank = one anchor stab (native) plus one sibling that differs by a single pitch/rate step (suggest -2 to -4 semitones linked rate, range 0.79-0.89x), placed on a different pad, and alternated ("flip-flop") rather than layered. Alternate by a fixed pattern for at least 2 repeats before changing.

### 1.2 Premier pitch/tempo figures (NEW, secondary, lower weight)
A ModeAudio article states, in the author's words (no Premier quotes), that "Mass Appeal" uses a roughly 2 second Vic Juris section slowed 118 to 96 BPM and pitched down about 4 semitones, and that "N.Y. State of Mind" drums are a nearly unedited break slowed about 16 BPM from ~100. These come from the author's analysis via WhoSampled and are not Premier testimony. Source: [ModeAudio](https://modeaudio.com/magazine/masters-of-sampling-dj-premier).

Rule: treat a drop of 2-4 semitones (about 16-20 percent slower) as the upper "dark" end of the linked-rate candidate set; most variants should be 0 to -2 semitones. Keep native as the default candidate.

### 1.3 Pete Rock, "The Joy" (CONFIRMED, nuanced)
In the Microphone Check transcript he says he wanted "to sample the actual singing on 33, the way it was made" and mentions that "certain things only sound right on 45." He also says he "stopped sampling half a bar loops to one bar loops to making it bigger." The second quote is NEW and counters a "tiny chop only" bias: longer, near-intact phrases are a legitimate producer choice. He says the beat was an older SP-1200 beat he redid on the MPC with the vocal added. Source: [Microphone Check](https://www.withradio.org/2014-07-01/pete-rock-real-could-be-another-word-for-original).

Rule: keep long (1-2 bar, 2-6 s) native-speed phrases as first-class candidates. Per-phrase candidate set: native, one modest linked-rate variant. Never apply a global pitch change.

### 1.4 Ski Beatz, Todd Edwards, Dilla, Bob Power, Linn, Charnas (NOT RE-READ)
These were not re-fetched in this pass. They are neither confirmed nor corrected here. Treat the handoff's own caveats about them as the authority.

### 1.5 MPC play modes (CONFIRMED)
Akai documentation: with note-on enabled a sample plays only while the pad is held; otherwise it is a one-shot played in full. Pads in the same mute group silence each other, last played wins (32 groups on the MPC X, per-program). Note-off has no separate official definition in the material found; forum posts describe it like note-on. A forum note says drum programs default to one-shot while keygroup programs default to note-on. Sources: [Akai pad guide](https://www.akaipro.com/guides/mpc-sample/pad_play.htm), [MPC manual pages](https://www.manualslib.com/manual/724425/Akai-Mpc.html?page=49). The handoff's "do not conflate" advice stands; the note-off point should be marked as manufacturer-ambiguous.

Rule: implement exactly two policies. One-shot (default for whole phrases, finish with a 5-15 ms release fade at natural tail) and gated (texture only). Dialogue chops share one mute group: a new dry event chokes the prior with a 8-20 ms fade unless the prior is "protected" and within 80 ms of its end, in which case the new event is delayed or dropped.

## 2. New craft material

### 2.1 Pad bank construction in tutorials (NEW)
Vocal-chop tutorials describe spreading slices across 16 pads with slightly different start points, noting slices carry different consonants, giving a varied palette. Sources: [Yamaha Hub part 1](https://hub.yamaha.com/proaudio/recording/creating-vocal-chops-and-other-sampler-tricks-part-1), [MusicRadar MPC-style on Push](https://www.musicradar.com/tuition/tech/how-to-perform-mpc-style-sampling-tricks-using-ableton-push-2-643660). These are generic tutorials, not boom-bap testimony.

Rule: bank size 8-12 pads is enough (handoff allows 8-16). Choose slices so first phonemes differ (plosive, fricative, vowel onset) to keep the bank varied.

### 2.2 Re-pitching and formants (NEW, tutorial level)
Sonicbids notes that pitching without formant preservation sounds chipmunk-like going up and demonic going down. Source: [Sonicbids](https://blog.sonicbids.com/music-production-tutorial-how-to-chop-vocals). For old-school hardware-style flips the coloration is the point; for intelligibility it is a cost.

Rule: apply rate shifts only inside -4 to +2 semitones. Upward shifts beyond +2 only for texture-fill events, never for protected phrases.

### 2.3 Kaytranada-style placement (NEW, analysis level)
A LiveSchool analysis of one track describes chops mostly on off-beat sixteenths (second, third or fourth sixteenth of the beat), swung chops, a repeated chop that stays the same until a breakdown, and pitch change on every fourth repeat. A Sample Focus guide describes deliberately unquantized notes for a laid-back feel. Rolling Stone ties his influence to Dilla. Sources: [LiveSchool](https://liveschool.net/?p=8950), [Sample Focus](https://samplefocus.com/blog/make-kaytranada-type-beat.md), [Rolling Stone](https://www.rollingstone.com/music/music-features/kaytranada-new-album-TIMELESS-interview-1235019415/). These are third-party analyses of a house/R&B-adjacent producer; no first-hand vocal-chop method was found.

Rule: bias stressed-syllable landmarks toward off-beat sixteenths ("e" and "a" of the beat) rather than the downbeat, and put the clearest word on a position at least 60-120 ms away from a kick landmark. Change one parameter (pitch step, one omitted hit) on every fourth repeat of a pattern.

### 2.4 Madlib (partially UNVERIFIED)
Sources describe a loose, improvised, loop-oriented approach with the SP-303 and tape, "dirtier than the original", and say his methods vary (contrast with Premier's consistent style). Nothing reliable was found on how he handled spoken skit or dialogue samples. Sources: [Micro-Chopping Madlib](https://medium.com/micro-chop/micro-chopping-madlib-5d77b91a5ea5), [Madvillainy story](https://medium.com/micro-chop/i-dont-remember-the-samples-i-use-hell-no-the-story-of-madvillainy-e6b378d4689c).

Rule: allow an occasional "loose" pattern family in which a single dialogue loop repeats with minimal change and no grid correction; cap its use to at most one in four performances.

### 2.5 Premier scratch hooks (UNVERIFIED mechanics)
Searches found that Premier's hooks are collage-like cut vocal samples and that he described cutting the "Rite Where You Stand" hook, but no source gave which cuts or how they were performed. Sources are secondary lists, not usable for parameters. Do not assert scratch behavior; if scratch-style gestures are added later they are an invention, not a documented technique.

### 2.6 RZA, 9th Wonder, Knxwledge (UNVERIFIED)
No reliable chopping-method detail found. A 9th Wonder NPR exchange frames craft as what you do with a sample rather than which sample you choose, and notes that how a producer loops or chops distinguishes them (secondary summary). Source: [NPR transcript](https://www.npr.org/transcripts/848488734). RZA material found was low quality and is not used. Do not cite these producers for any parameter.

## 3. Arrangement, repetition and change cadence

### 3.1 Block lengths and cadence (NEW, tutorial level)
Producer-education sources recommend 4, 8 and 16 bar blocks; hooks 8 or 16 bars; verses 16 (sometimes 12) and lighter than hooks to leave room for vocals; advice to add or remove one element every 4 to 8 bars, and to drop elements for a bar before a section. Sources: [Viberate](https://www.viberate.com/blog/music-analytics/song-structure-for-modern-producers-from-loop-to-full-track/), [Violet Recording](https://violetrecording.com/how-to-structure-a-beat/), [Loopmasters](https://www.loopmasters.com/cloud/blog/4463-Finishing-Tracks-7-Ways-to-Turn-an-Eight-Bar-Loop-into-a-Full-Arrangement). These are generic structure guides; they fit the user's requirement but are not boom-bap-specific evidence.

Rule (cadence, satisfies "change at least every 16 bars"):
- Micro change every 4 bars: one of omit a hit, swap one pad, shift one stress by one sixteenth, or toggle the sibling.
- Macro change every 8 bars: switch pattern family or answer role.
- Hard ceiling 16 bars: the performance fingerprint (ordered list of pad ids and placements) must differ from the previous 16 bars by at least 25 percent of events. Enforce and log; a check can compare fingerprints across 16-bar windows.
- Rest bars: at least one fully empty dialogue bar per 8, and a 1-2 bar dropout before a section change.
- Return: re-state the anchor phrase unchanged at the start of a new 16-bar block or at the form return.

### 3.2 Exact repetition makes speech musical (NEW, academic)
Deutsch's speech-to-song illusion: a spoken phrase repeated exactly several times (about ten in the original demonstrations) begins to sound like song. It did not occur when repetitions were slightly transposed or when syllables were shuffled. Phrases with stable syllable pitches and regular accent spacing are more conducive. It is stronger for unfamiliar languages and weaker for tone-language speakers. The effect is cited in Steve Reich's looped speech works (Come Out, It's Gonna Rain). Sources: [Wikipedia summary](https://en.wikipedia.org/wiki/Speech-to-song_illusion), [Deutsch page](https://deutsch.ucsd.edu/psychology/pages.php?i=212), [2011 paper](https://typeset.io/pdf/illusory-transformation-from-speech-to-song-6a5240zn48.pdf), [Frontiers 2015](https://frontiersin.org/articles/10.3389/fpsyg.2015.00048/pdf). The ten-repeat figure applies to laboratory loops with no other music; with a beat, a fewer-repeat threshold is plausible but unmeasured here.

Implications and rule:
- Repeats must be bit-identical for the first 2-3 statements; the musical quality comes from exactness. Do not add per-repeat random pitch or order jitter to a hook.
- Variation is then a deliberate departure (an event the listener notices because the identity was established), consistent with the handoff's "vary one dimension."
- Shuffled syllable order defeats the song effect, which supports restricting reorder to whole units and keeping original order as the default.
- Prefer candidate phrases with strong stable vowels and regular stress spacing; add a "regular accent" score component (inter-stress interval variance low).

### 3.3 Context on automatic chopping research (NEW, limited)
Searches did not find a dedicated academic paper on automatic MPC-style chopping of speech. Related infrastructure exists: onset detection to peak picking (for example SuperFlux, MIREX onset sets) underlies beat slicers, a 2014 ICMC/SMC paper that segments loops by onsets and rewrites rhythm for live performance and remixing, and a patent on picking loop points at onsets. Sources: [ICMC-SMC 2014 paper](https://speech.di.uoa.gr/ICMC-SMC-2014/images/VOL_1/0536.pdf), [Sound on Sound automatic beat slicing](https://www.soundonsound.com/techniques/automatic-beat-slicing), [lecture notes on beat tracking and remixing](https://www.dcc.fc.up.pt/~mcoimbra/lectures/SM_1415/SM_1415_T9_SoundMusic.pdf). The claims here are from a search summary; the cited paper's details were not read. Treat this as a pointer, not support for specific numbers.

Rule: for speech, use onset functions on band-split envelopes (the existing three-band envelope) but pick boundaries at syllable nuclei or energy valleys between words, not purely at transients. Plosive onsets are good starts; fricative and vowel-initial words need a 10-30 ms pre-roll so the entrance is not clipped.

## 4. Chop points, selection and placement rules

These synthesize the sources above with the handoff; sourcing is noted where a number is a design hypothesis.

| Topic | Evidence | Rule / range for Liminal |
|---|---|---|
| Phrase choice | Premier uses a very short stab; Pete Rock moved to longer loops; Ski selects before tempo (handoff) | Keep both: stab units 0.15-0.6 s; phrase units 0.7-3 s; line anchors up to 6 s |
| Start point | Plosive/onset-aligned starts, tutorial slices with different consonants | Start 5-20 ms before onset; use 3-8 ms fade-in; rejected if cut lands inside a vowel unless unit flagged texture |
| End point | Protected final consonants and tail (handoff) | End at energy valley plus natural tail; 8-20 ms release; never cut inside the last phoneme |
| Placement vs kick | Off-beat sixteenth bias (Kaytranada analysis); backbeat answers | Accent on the "e"/"a" 16ths or 1/8 offbeat by default; avoid putting the stressed vowel within 50 ms of a kick transient so they do not mask; reserve one anchor per 8 bars to land on the snare |
| Pitch | Premier -pitch; Pete Rock native; formant caution | Native 60 percent, -1 to -4 st 30 percent, up to +2 st 10 percent of events |
| Choke | MPC mute groups | One dry-voice group; fade 8-20 ms |
| Occupancy | Sparse hooks leave vocals room | Dialogue active no more than 45-55 percent of bar time averaged over 8 bars; at least one rest bar per 8 |
| Pad bank | Tutorials: 16 pads | 8-12 pads; roles anchor, short stab, answer, sibling (pitched), tail/texture |
| Change cadence | Section 3.1 | micro 4, macro 8, hard 16 bars |

All numbers in the "Rule / range" column are initial settings to tune and should be exposed as named constants.

## 5. Timing

Without a verified numeric source, keep to the handoff: preserve AJ's timing; apply a single stable offset per gesture. Kaytranada guides and the Linn and Dilla sources point the same way (selective, consistent timing choices rather than random jitter). Suggested hypothesis: per-gesture offset in the range -20 to +25 ms relative to the target grid or landmark, fixed within a pattern, never random per syllable.

## 6. Summary of corrections and additions to the handoff

- CONFIRMED: Premier restart/pitch-down/different-pad account; Pete Rock native-speed choice; MPC one-shot vs note-on vs mute group semantics.
- CORRECTED (minor): the RBMA text does not mention the MPC60; avoid tying that anecdote to a specific machine. Note-off has no distinct official definition in found manuals.
- NEW: Pete Rock moved to longer loops; speech-to-song repetition findings (exactness matters, shuffling and transposition destroy the effect); concrete cadence rule (4/8/16); off-beat sixteenth placement as a Kaytranada-style bias; rate shift budget and formant caution.
- UNVERIFIED gaps: Premier scratch hook mechanics, RZA, 9th Wonder, Knxwledge, Madlib dialogue chopping, academic work specifically on automatic chopping of speech.

## Sources

- https://www.redbullmusicacademy.com/lectures/dj-premier-you-know-my-steez/
- https://modeaudio.com/magazine/masters-of-sampling-dj-premier
- https://www.withradio.org/2014-07-01/pete-rock-real-could-be-another-word-for-original
- https://www.akaipro.com/guides/mpc-sample/pad_play.htm
- https://www.manualslib.com/manual/724425/Akai-Mpc.html?page=49
- https://en.wikipedia.org/wiki/Speech-to-song_illusion
- https://deutsch.ucsd.edu/psychology/pages.php?i=212
- https://typeset.io/pdf/illusory-transformation-from-speech-to-song-6a5240zn48.pdf
- https://frontiersin.org/articles/10.3389/fpsyg.2015.00048/pdf
- https://liveschool.net/?p=8950
- https://samplefocus.com/blog/make-kaytranada-type-beat.md
- https://www.rollingstone.com/music/music-features/kaytranada-new-album-TIMELESS-interview-1235019415/
- https://medium.com/micro-chop/micro-chopping-madlib-5d77b91a5ea5
- https://medium.com/micro-chop/i-dont-remember-the-samples-i-use-hell-no-the-story-of-madvillainy-e6b378d4689c
- https://www.npr.org/transcripts/848488734
- https://hub.yamaha.com/proaudio/recording/creating-vocal-chops-and-other-sampler-tricks-part-1
- https://www.musicradar.com/tuition/tech/how-to-perform-mpc-style-sampling-tricks-using-ableton-push-2-643660
- https://blog.sonicbids.com/music-production-tutorial-how-to-chop-vocals
- https://www.viberate.com/blog/music-analytics/song-structure-for-modern-producers-from-loop-to-full-track/
- https://violetrecording.com/how-to-structure-a-beat/
- https://www.loopmasters.com/cloud/blog/4463-Finishing-Tracks-7-Ways-to-Turn-an-Eight-Bar-Loop-into-a-Full-Arrangement
- https://speech.di.uoa.gr/ICMC-SMC-2014/images/VOL_1/0536.pdf
- https://www.soundonsound.com/techniques/automatic-beat-slicing
- https://www.dcc.fc.up.pt/~mcoimbra/lectures/SM_1415/SM_1415_T9_SoundMusic.pdf
