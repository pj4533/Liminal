# Strummed and plucked hooks in Wu-Tang era and lo-fi beats: craft research and Liminal rules

> Status: input to D128 (`docs/decisions/music.md`). The numbers below are research starting values; the shipped hook (`LofiStrumHook`) uses its own tuned constants and fewer archetypes (five, A-E), and does not implement the per-take detune. Where this note and D128 differ, D128 and the source win.

22 November 2026 (D128). Production-craft research done before the strummed hook was built. This note covers how RZA-era Wu-Tang and related boom-bap and lo-fi producers used guitar and other strummed or plucked parts, and turns that into pattern rules and archetypes Liminal can implement. It builds on `docs/research/dialogue-chopping/craft.md` (the 4/8/16-bar cadence, exact repetition, and placement on off-beat sixteenths) and on D114 (`LofiGuitarPhrasing`: strums 8 to 25 ms per string, about 25 percent up-strums, fingerpicking, double stops and grace notes around an unchanged melody).

## How to read this note

Each claim is marked **SOURCED** (a quote or fact fetched in this pass), **SECONDARY** (a journalist's or reviewer's description, not the producer's own), **GENERAL** (general musicianship and production knowledge with no source found this pass), or **HYPOTHESIS** (a number to tune against renders). No audio was auditioned. Every number in the rules is a starting value and should be a named constant.

Liminal context: phrases are 4 bars (16 beats) at 58 to 82 BPM, so one sixteenth lasts 183 to 259 ms and one bar lasts 2.9 to 4.1 s. Step numbers below run 0 to 15 within a bar. The kick usually falls on 0 and the snare on 4 and 12 (beats 2 and 4), but the private drum takes vary, so rules that reference the snare should read the take's actual landmarks (`LofiDrumLandmarks`) rather than assume steps 4 and 12.

## 1. What the sources say

### 1.1 RZA used the guitar as a sound to sample, not as a part to play (SOURCED)
- Engineer testimony from the 36 Chambers sessions: RZA treated the guitar "like it was a sound he was going to sample", and the mixing trick was "to not have anything step on anything else, especially the vocals". Quotes and sources: [RZA and the Wu-Tang Clan](../producers/rza-and-wu-tang.md).
- **Rule:** the guitar is one more sample pad. It contributes a few notes or one gesture, not a continuous rhythm part, and it must never step on the dialogue chops, which act as the vocal here.

### 1.2 One strum as the main stab of a beat (SECONDARY)
- "Incarcerated Scarfaces" takes the first strum of "Wang Dang Doodle" as the main stab, answered by an off-key piano sample; "All I Need" scatters bandpass-filtered hits so each loop differs ([RZA and the Wu-Tang Clan](../producers/rza-and-wu-tang.md)).
- **Rule:** the core Wu-Tang gesture is one chord strum used as a stab, repeated exactly, with a second off-key element answering it. Make the single-stab archetype the most common one.

### 1.3 Soft nylon guitar under a cut (SECONDARY plus GENERAL)
- "Ice Cream" (1995) is built on Earl Klugh's soft, warm, nylon-string jazz guitar. Lifted into a beat, that becomes a short broken-chord figure that repeats against the drums ([RZA and the Wu-Tang Clan](../producers/rza-and-wu-tang.md)).
- **Rule:** a gentle nylon broken-chord figure (one bar, sounded and then repeated exactly) is the second core archetype. It suits the existing Nylon Fingerstyle and Archtop programs.

### 1.4 Detuned "harmony of its own" (SOURCED)
- RZA on Fresh Air (2005) describes deliberately detuned samples, "one-eighth of a step, just out of tune", that have "a harmony of its own"; kung-fu film "stings and stabs"; and a move from one- and two-bar to four-bar loops. Quotes: [RZA and the Wu-Tang Clan](../producers/rza-and-wu-tang.md).
- **Rules:**
  - Allow a fixed detune of up to about 25 cents (an eighth of a tone) on the strum part for the whole take. That is about 12 cents at most against the key, which reads as old-sample character, not error. Keep it constant within a take, because random drift sounds sloppy rather than sampled.
  - A "sting" is a sudden one-off pluck or tremolo at a bar line, edited in rather than played as a riff. Allow at most one per 8 bars.
  - Liminal's phrase is already 4 bars, the RZA loop length. A strum hook should be a 2- or 4-bar statement, not a 1-bar ostinato.
  - Make the guitar "hit with the piano": when a piano phrase and a guitar stab coincide, put them on the same step (unison), not a sixteenth apart (flam).

### 1.5 Too much guitar was the failure case (SOURCED)
- On *8 Diagrams* (2007) Raekwon complained that RZA was "trying to do too much of this guitar stuff" ([RZA and the Wu-Tang Clan](../producers/rza-and-wu-tang.md)).
- **Rule:** this is the documented "don't overdo it" lesson. Played-sounding guitar (solos, continuous comping, busy fingerwork) is what the group itself rejected. The classic era used short sampled gestures. Hard caps follow in section 3.

### 1.6 Kung-fu film music came mostly from library records (SECONDARY)
- Shaw Brothers scores drew heavily on the De Wolfe production-music library; Wu-Tang mostly sampled the films' dialogue and sound rather than those cues. The "Eastern" colour in Wu beats comes mostly from minor-pentatonic plucked lines, sudden stings and cue edits, not from an authentic guzheng or pipa part (general knowledge). See [RZA and the Wu-Tang Clan](../producers/rza-and-wu-tang.md).
- **Rule:** an Eastern colour can be suggested with the existing harp or plucked-string programs playing a minor-pentatonic sting (archetype 9). Any new Asian plucked instrument must pass the high bar on its own (see [the instrument survey](../instruments/strum-survey.md)). Do not add one for the reference alone.

### 1.7 Madlib, Alchemist, Griselda, Dilla, Pete Rock (SECONDARY or gap)
- Madlib's sped-up guitar strums under Quasimoto ([Madlib](../producers/madlib.md)); the Alchemist's "basic loop" with imagined structure ([The Alchemist](../producers/the-alchemist.md)); Griselda's short, dusty, unresolved loops with dropouts, which is general knowledge only ([Griselda producers](../producers/griselda.md)); Dilla's consistent late placement rather than random jitter ([J Dilla](../producers/j-dilla.md); mpc-chopping craft 2.3 and 5, now [dialogue craft](../dialogue-chopping/craft.md)). No usable method detail was found for Pete Rock or Dilla guitar use.
- **Rule:** the "loose loop" family is legitimate: one fragment repeated with little change. Lag is a fixed per-pattern offset, never per-note randomness.

### 1.8 Boom-bap arrangement and space (SECONDARY, tutorial level)
- The kick says "boom," the snare answers "bap," the sample creates a world, and the rapper is the main event. Keep "the midrange and phrase endings open." Let stabs stand out and avoid overcomplicating the arrangement. Stagger stab samples across a four-bar loop for a spacious arrangement. Sources: [Beatstorapon](https://beatstorapon.com/blog/how-to-make-a-boom-bap-beat/), [Sample Focus](https://samplefocus.com/blog/dj-premier-breakbeat-hip-hop-samples.md), [Native Instruments](https://www.native-instruments.com/en/blogs/blog/what-is-boom-bap).
- **Rule:** stabs answer the snare. They land just after it, or in the gap before the next kick, never on top of it. In Liminal the dialogue chops are the "rapper," so a strum gesture must not overlap a protected chop phrase (section 3.4).

### 1.9 Strum mechanics (SOURCED where noted, otherwise GENERAL)
- Measured: a motorized pick took about 28 ms to cross the strings (45 ms to the first string and 73 ms to the last, at 240 fps). A keyboard rhythm-guitar patent sets the string delay at about 2.2 percent of the strum period. A forum producer offsets the lowest of three notes by 30 ms and the next by 15 ms for a downstroke. Sources: [NIME 2017](https://vbn.aau.dk/ws/files/295153538/nime2017_paper0086.pdf), [USPTO 7420114](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7420114), [TOPLAP forum](https://forum.toplap.org/t/struming-and-microtiming/1849).
- Rake (SOURCED): the pick drags across one or more muted strings just before the target note, giving a click or "snappy, staccato attack"; only the target sounds. Source: [Sweetwater, rake](https://www.sweetwater.com/insync/rake/), [LickLibrary](https://www.licklibrary.com/glossary/rakes).
- GENERAL technique for synthesis from single-note samples:
  - **Direction.** A down-strum goes low to high, with the low string first. An up-strum goes high to low, usually hits only the top 2 to 4 strings, is lighter (about 0.7 to 0.85 of the down-strum level) and tighter (about 0.6 to 0.8 of the down spread).
  - **Spread.** A crisp pick stab is about 5 to 12 ms per string (15 to 50 ms across 4 or 5 strings). A relaxed thumb or slow strum is about 15 to 35 ms per string. A deliberate harp-like roll is 40 to 80 ms. The current 8 to 25 ms covers the middle range. A stab wants the tight end and a held chord the loose end. Whether the first or the last string lands on the grid is a choice: a downbeat strum anticipates so the top (melody) string lands on time, while a stab after the snare lands its first string on the step.
  - **Velocity taper.** On a down-strum the first one or two strings are slightly louder, the inner strings slightly softer, and the top string recovers if it carries the melody. Overall within ±3 dB. Fewer strings means each one slightly louder.
  - **Which strings ring.** Guitar voicings skip strings and leave gaps. Use 3 or 4 notes for a stab and 5 for a big chord. Keep the lowest note at E2 to A2 (MIDI 40 to 45) or higher, and above the bass part's register (Liminal's floor is `lowestPitch` 45).
  - **Choke.** A stab is held for 1 to 2 sixteenths, then all strings are damped together with a 10 to 30 ms release. That choke is the "chk" and is what makes it a stab rather than a chord. A held chord rings for 1 to 4 beats.
  - **Dead notes and chucks.** A muted strum sounds a short noise burst at about -12 to -18 dB relative to a sounding strum. It is approximated by very short (20 to 40 ms) low-passed copies of the strum, or by the sample's attack transient only.
  - **Swing.** Swing comes from the up-strums on the "e" and "a" of the beat (steps 1, 3, 5, ...). Late off-beats (about 54 to 60 percent swing) should match the drum take's own feel rather than be imposed.

## 2. Chord vocabulary (GENERAL, matches lo-fi chord guides)

Lo-fi and Wu harmony is minor and extended. Lo-fi chord guides lean on m7, maj7, dominant 7 and 9 chords ([Splice](https://splice.com/blog/lo-fi-chord-progressions/), [Guitar World](https://www.guitarworld.com/lessons/chords/5-lo-fi-guitar-chords)). For strums, from most to least common:

| Use | Chords | Notes |
|---|---|---|
| Default stab | m7 (1-b3-b7, or 1-5-b7-b3 on top), minor add9 | 3 or 4 strings. Keep the top note on b3, b7 or 9, never doubled with the lead's note |
| Warm hold | m9, m11 shell (1-b7-b3-11), maj7 on bVI or bIII | Slow strum, longer ring |
| Tension stab (rare) | dominant 7#9 (1-3-b7-#9), 7b9 | At most once per 8 bars, on the turnaround bar, short choke |
| Passing | dim7 or half-diminished (m7b5) | One sixteenth to one eighth into the next chord, only in a turnaround |
| Oblique hook | a pedal top note with the inner voice falling b7, 6, b6 (a minor line cliché) | Wu and Griselda dark colour |
| Single note | b3 or b7 with a quarter- or half-tone bend or slide into it, or a two-note dyad (b3 plus b7, or 5 plus root) | Bluesy, minimal. Often better than a full chord |

**Rules:** strum chords come from the phrase's chord (`chord`) and scale, never from new harmony. Prefer voicings in MIDI 50 to 72 (D3 to C5) for stabs so they sit between the bass and the lead. A held chord may reach down to 45. No major triad as a stab, since a bright major stab breaks the vibe. Major colour appears only as a maj7 or add9 hold.

## 3. Placement, density and space rules

### 3.1 Placement against the drums
1. **Answer the snare.** The default stab positions are 1 to 2 sixteenths after a snare (steps 5, 6, 13 and 14) or the "and" before the next kick (step 7 or 15). Never put a stab's first sounding string within about 40 ms of a snare transient unless the pattern deliberately doubles the snare (archetype 6 only).
2. **Keep the kick clear.** Avoid down-strums whose low strings land within about 30 ms of a kick, because they mask each other in the low mids. Over a busy kick pattern, prefer stabs with the top 3 strings only.
3. **Downbeats are rare.** A strum on step 0 is reserved for the first bar of a statement (the "drop") or a held chord. That is at most 1 bar in 4.
4. **Fixed lag.** One offset per pattern, from 0 to +30 ms late (Dilla-like) and occasionally -10 ms (pushed). It is fixed for the statement and never random per note.
5. **Pickup rakes.** A rake of 2 or 3 dead strings may lead into a stab, starting 30 to 80 ms before it. This is the "and-a" texture.

### 3.2 Density caps (HYPOTHESIS, the anti-mess guarantees)
- Strum-mode events (a stab, strum, dyad or sting counts as one event; a rake counts with its target) are limited to **3 per bar and 6 per 4 bars** by default, and 8 per 4 bars in the busiest archetype.
- At least **one bar in every four** has no strum event. At least **one beat of silence** follows each event before the next event (except a down-up pair, which counts as one event).
- Over 8 bars, strum events sound in at most **50 percent of bars**.
- Only **one plucked part is busy at a time.** When the guitar is in strum mode, the existing melody line from the same program thins (it keeps its landmark notes) rather than both playing fully. The melody contract (pitch, onset, length) holds for the notes that remain. If D114's contract forbids removing melody notes, the strum pattern must instead fit the melody's gaps (see 4.2).
- **Choke always wins.** Strum-mode stabs default to a short hold of 1 to 2 sixteenths. Only archetypes 4, 8 and 10 ring longer.

### 3.3 Repetition and change (from the [dialogue craft note](../dialogue-chopping/craft.md) 3.1 and 3.2)
- Statement: a 2- or 4-bar strum pattern, repeated **exactly** (same steps, voicing, spread and velocities) at least twice. Exactness is what makes a sample-like hook. Random per-repeat jitter must not be added.
- Micro change every 4 bars: one of omit one stab, move one stab by one sixteenth, swap the voicing's top note, or add or remove a pickup rake.
- Macro change every 8 bars: switch archetype, or drop the strum part for a bar.
- Hard ceiling of 16 bars: the archetype or its voicing set must change by the next 16-bar boundary.
- Before a section change: drop strums for 1 bar, or play a single sting (archetype 9) into it.

### 3.4 Space for the "vocal" (dialogue chops)
- While a protected dialogue phrase sounds, the strum part plays only stabs no longer than one sixteenth, in steps the chop leaves empty, or rests. A chop gap of one beat or more is the best place for a stab: the call and response is chop, then stab.
- Stabs avoid the 1-4 kHz consonant band. Low-pass strum-mode audio at about 3 to 4.5 kHz (lower than the lead) and high-pass it at about 150 to 220 Hz so the low strings never touch the bass or the kick.

### 3.5 Effects (GENERAL, matching what the user heard "hit just right")
- **Echo is the magic, but only on the last stab.** Put a delay throw (dotted eighth or quarter, synced, feedback 25 to 40 percent, filtered about 400 Hz to 3 kHz, gently saturated) on the final stab of a statement or a 4-bar phrase, never on every stab. The tail fills the bar that the density rule leaves empty, so space and echo work together.
- Reverb: a short dark room or plate (pre-delay 15 to 35 ms, decay 0.8 to 1.6 s, HF damping), sent at a similar level to the lead's.
- Sample character: a fixed detune (≤25 cents, 1.4), a little extra wow, an optional band-pass on 1 stab in 4 (the RZA "All I Need" bandpass hits make each loop differ), and mild bit or rate reduction only if the existing chain does not already supply it.
- Mix level (HYPOTHESIS): a strum-mode stab peaks 3 to 6 dB under the lead's typical note and stays at least 6 dB under the dialogue chops. Its delay tail returns 8 to 12 dB under the dry stab.

## 4. Pattern archetype library

Notation: `S` is a down-strum stab (choked after the given length), `u` an up-strum on the top 3 strings, `H` a held down-strum, `d` a dyad (2 notes), `n` a single note (with an optional bend or slide), `x` a dead or muted strum, `r` a rake into the next event, `T` a delay throw on that event, and `.` a rest. There are 16 steps per bar. For example, `....|..S.|....|....` means one stab on step 6. "Bars" lists which bars of the 2- or 4-bar statement play.

| # | Name | Grid (one bar) | Bars | Voicing / length | Density | When to use |
|---|---|---|---|---|---|---|
| 1 | **Lone stab** (Incarcerated Scarfaces) | `....|.S..|....|....` (step 5) or step 6 | bars 1 and 3 of 4. Bar 4 may add a `T` | m7, 3 strings, 1-sixteenth choke, 6-10 ms spread | 2 per 4 bars | Default. Busy drums, active dialogue, intro of a take |
| 2 | **Two-chord answer** | `....|..S.|....|..S.` (steps 6 and 14), second chord different (i then bVII, or i then iv) | every other bar | both 3 strings, 1-sixteenth choke | 4 per 4 bars | Main hook sections. Answers both snares |
| 3 | **Down-up chk-a** | `....|....|..Su|....` (steps 10 and 11) | bar 2 of each 2 | S: 4 strings; u: 3 top strings at 0.75 level, 0.7 of the spread | 2 per 4 bars (a pair counts once) | Medium energy. Leaves the snare on 12 exposed |
| 4 | **Klugh broken chord** (Ice Cream) | `n.n.|n...|..n.|....` rising root, 5, b7/9 then a top note on step 10 | bar 1 of 2, exact repeat | single notes ringing (let-ring), 0.5 to 1.5 beats each | 4 notes per 2 bars, counting as 2 events | Nylon or archtop programs, calm sections |
| 5 | **Rake into the 4-bar drop** | `....|....|....|...r` then `H` on step 0 of the next statement | once per 4 bars | rake of 2 or 3 dead strings, 40-70 ms, then a 4-5 string held chord at a loose 15-30 ms spread, rings 2 beats | 1 per 4 bars | Section starts, after a breakdown |
| 6 | **Ghost chuck backbeat** | `....|x...|....|x...` (with the snare), at -14 to -18 dB | 2 bars of 4 at most | dead strum 25-40 ms, low-passed at 2.5 kHz | 4 quiet per 4 bars, counted as 1 event | Rare. Only with sparse drum takes, never in a breakdown |
| 7 | **Detuned dyad hook** | `...d|..d.|....|....` (steps 3 and 6) | every bar for 2 bars, then 2 rest | b3 plus b7, top voice +10 to +20 cents | 4 per 4 bars | Dark takes, a Wu or Griselda colour |
| 8 | **Held chord plus echo** | `H...|....|....|....` with `T` | bar 1 of 4 only | m9 or maj7 (bVI), 5 strings, 20-35 ms spread, rings 1-2 bars, delay throw | 1 per 4 bars | Breakdowns and the "hit just right" moments. The safest richness |
| 9 | **Sting** (kung-fu cut) | `....|....|....|..nn` or a 3-note descending minor pentatonic on steps 13 to 15 | once per 8 bars, before a bar line | single notes, short, top register (MIDI 64-76), heavy delay | 1 per 8 bars | Before section changes. Harp, plucked strings, or guitar |
| 10 | **Line cliché** | `S...|....|S...|....` the same top note with the inner voice b7, then 6, then b6 across bars | 4 bars, one chord per bar on step 0 or 8 | 3 strings, 1-2 beat ring | 4 per 4 bars | Minor i chord held for 4 bars. Turns stasis into motion |
| 11 | **Lagged loose loop** (Dilla or Madlib) | `..S.|....|..S.|....` (steps 2 and 10) +20-30 ms late | all 4 bars, exact repeat | 3 strings, 1-sixteenth choke | 8 per 4 bars (the busiest) | Only when dialogue is resting or sparse |
| 12 | **Turnaround push** | bar 4: `....|....|S...|..p.` with a passing dim7 or 7#9 on step 14 into the next downbeat | the last bar of 8 | stab 3 strings and a passing chord 3 strings, 1-sixteenth each | 2 per 8 bars | Into the 8- or 16-bar boundary |
| 13 | **Bent single note answer** | `....|..n.|....|....` with b3 bent a quarter tone to b3, or slid up from a whole step below | bars 2 and 4 | single note, 1 beat ring | 2 per 4 bars | Pairs with 1 (stab in bars 1 and 3, bend in 2 and 4): call and response inside the guitar |

Combined defaults: 1 plus 13, or 2 plus 8, give about 3 to 5 events per 4 bars, the "a little bit more" level the user asked for. Archetypes 6 and 11 are the most crowded and need sparse drums or resting dialogue.

### 4.1 Selection weights by context (HYPOTHESIS)
- Intro or first statement of a program: 1 (50 percent), 8 (30 percent), 4 (20 percent).
- Hook or main section: 2, 1+13, 3, 7, 10, 4 (each about 15 percent), with 11 at 10 percent.
- Breakdown: 8 (60 percent), 4 (30 percent), rest (10 percent). Never 6, 11 or 12.
- Turnaround bar (bar 8 or 16): 12 or 9, at most one, otherwise rest.
- Program fit: nylon and archtop lean towards 4, 8, 13 and 10. Steel and flatwound lean towards 1, 2, 3, 7 and 11. Harp and plucked strings only use 8, 9 and 4 (no strums), because a harp is plucked, not strummed.

### 4.2 Fitting the existing melody contract (`LofiGuitarPhrasing`, D114)
- D114 keeps every melody note and adds `.ornament` notes. To add strum-mode patterns without breaking that contract:
  - Place archetype events only in melody gaps: no strum onset may fall within 1 sixteenth of a melody onset, except a strum built under a melody note, as D114 already does.
  - Count melody notes towards the density cap (3.2). If the melody already has 3 or more onsets in a bar, that bar takes no strum events.
  - Strum-mode pattern choice is per 4-bar phrase from the phrase's RNG fork, so a seed always replays the same hook.
- The archetype grids can be scored as `.ornament` notes with per-note level, length and timing offset. The choke is the note length plus a 10 to 30 ms release. Dead notes need a short-length and low-pass path, or can be left out at first, since they are optional.

## 5. Summary of key rules

1. One gesture, repeated exactly. The core Wu-Tang move is a single chord strum used as a stab, answered by something slightly off-key. Archetypes 1, 2 and 13 are the backbone.
2. Stabs answer the snare, 1 to 2 sixteenths after it, and stay out of the kick's low end and out of protected dialogue.
3. Choke by default. A short hold of 1 to 2 sixteenths with a damped release is what turns a chord into a hook. Ring only for held-chord archetypes.
4. Caps: 3 events per bar, 6 per 4 bars (8 at most), one empty bar in four, at most half the bars over 8.
5. Echo only on the last stab of a statement. The throw fills the space the caps leave.
6. Minor and extended voicings (m7, m9, add9, dyads, a single bent b3). Never a bright major triad stab. A fixed detune of at most 25 cents per take.
7. Cadence: micro change every 4 bars, archetype change every 8, forced by 16. Exact repeats in between.
8. Mechanics: crisp stabs 5 to 12 ms per string, held strums 15 to 35 ms, up-strums on the top 3 strings at 0.7 to 0.85 level, pickup rakes 30 to 80 ms ahead, a fixed lag of 0 to +30 ms per pattern.
9. Too much guitar is the documented failure (*8 Diagrams*). No continuous comping, no solos, and no busy fingerpicking in strum mode.

## Gaps

- No first-hand method detail was found for 4th Disciple, True Master, Pete Rock, Dilla, Daringer or Beat Butcha guitar use.
- No human measurement of strum spread was found, only a motorized pick (about 28 ms across the strings) and a forum producer's 15 and 30 ms offsets. The ranges in 1.9 are general knowledge and need render checks.
- None of the songs were auditioned. The step positions in the archetypes are idiomatic, not transcriptions.

## Sources

Wu-Tang, Madlib and Alchemist sources are listed with their notes in [producers](../producers/README.md). The rest:

- https://beatstorapon.com/blog/how-to-make-a-boom-bap-beat/
- https://samplefocus.com/blog/dj-premier-breakbeat-hip-hop-samples.md
- https://www.native-instruments.com/en/blogs/blog/what-is-boom-bap
- https://splice.com/blog/lo-fi-chord-progressions/
- https://www.guitarworld.com/lessons/chords/5-lo-fi-guitar-chords
- https://vbn.aau.dk/ws/files/295153538/nime2017_paper0086.pdf
- https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7420114
- https://forum.toplap.org/t/struming-and-microtiming/1849
- https://www.sweetwater.com/insync/rake/
- https://www.licklibrary.com/glossary/rakes
