# Dialogue salience and partial-word diagnosis (22 November 2026)

User request: weight the chops toward footage that says something recognisable and cool (the
"psilocybin" / "DMT" chop), chop fewer connective words and fewer partial words, and find out why some
chops "almost sound like a bug". No app logic was changed. This diagnosis adds a probe and a report
script only.

## How it was measured

- Probe: `LiminalTests/DialogueSalienceProbeTests.swift` (opt-in, it runs only when
  `/private/tmp/liminal-salience-probe-<uid>.json` names the checkout). It covers all 12 cached films
  with audio. Each film gets 8 windows of 30 s, spread over the film's interior with the weaver's own
  margins (95 windows). Each window gets SoundAnalysis speech windows and an on-device `SpeechTranscriber`
  transcript (installed model only, 91 of 95 windows transcribed, 0.34-0.79 s each). Each window then
  plans two takes (four 8-bar pieces) at 72 BPM through `DialogueMotif.plan`, as
  `DialogueCueCoordinator.build` does. Two modes run: **T**, with the transcript at the first plan, and
  **A**, the acoustic fallback, with no transcript but classified against the same transcript. When the
  motif returns nil, the probe also plays the grammar's pad-bank fallback.
- Every played chop event (a "play") is logged with:
  - its fragment (line / piece / syllable half / pad);
  - the source frames it actually plays (onset trim, gate, choke);
  - the accepted transcript words it covers and the share of each;
  - whether its start or end lands more than 30 ms inside a word, and the mechanism that put the edge
    there;
  - the signal level around both edges, relative to the play's peak.
- **Audible partial** means an edge more than 30 ms inside a word's voiced core while the signal is
  still sounding there. At the start, the 30 ms before the edge is above -15 dB. At the end, the last
  12 ms is above -20 dB and the 30 ms after is above -15 dB. The transcript's word timing alone is too
  coarse to trust (see cause 6).
- **Function-only** means every heard word (covered at least 30 %) is in
  `DialogueLineInterest.functionWords`.
- **Re-hearing:** each snippet's played chop was transcribed again on its own, padded with 0.6 s of
  silence. The result is a rough intelligibility check.
- Snippets: `bugs/NNN-<film>-<film seconds>s-<mode>-<mechanism>-played.wav` (the chop exactly as
  rendered) and `-context.wav` (the source line ±0.35 s). `bugs/index.tsv` lists each one with its
  fragment, heard words and coverage, re-heard text and edge levels.

## 1. What is played (T: 9,318 plays, of which 55 come from the pad-bank fallback; A: 10,170)

| | T (transcript) | A (acoustic fallback) |
|---|---|---|
| plays | 9,318 (incl. 55 pad fallback) | 10,170 |
| fragment kinds | piece 59 %, **syllable half 38 %**, whole line 3 % | piece 72 %, half 26 %, line 3 % |
| how the dry piece ends | natural 48 %, gate 25 %, **choke 21 %**, valley 6 % | natural 60 %, gate 22 %, choke 16 %, valley 2 % |
| **function-word-only hits** | **17.2 %** | **38.3 %** |
| no word heard at all (coverage under 30 %) | 15.7 % | 21.7 % |
| best heard word weight under 0.5 (plain or connective) | 65.8 % | 69.2 % |
| a salient word (weight ≥ 0.7) is heard | 17.4 % | 8.8 % |
| …and played whole (≥ 90 % of the word) | **5.9 %** | 2.5 % |
| **audible partial word (any edge)** | **52.0 %** | 57.1 % |
| of which syllable half (by design) | 24.8 % | 15.4 % |
| of which accidental (piece, line) | **25.6 %** | 39.6 % |
| of which deliberate stutter | 1.5 % | 2.1 % |
| chosen line interest, median | 0.50 (35.6 % of loops ≥ 0.6) | 0.45 (all acoustic) |
| loops whose line has no text although a transcript exists | 40 of 160 (25 %) | n/a |

The function-only texts most often played (T) are "and" (196), "the" (174), "in", "a", "of", "is",
"again.", "or", "the only", "to", "that's", "as", "for", "well" and "they". In A mode the list is
"the", "and", "a", "see,", "to", "of", "that" and so on.

Re-hearing (the share where the recogniser finds the fragment's main word in the chop alone): whole
lines 39/45; full-length clean pieces 15/52; gated or choked pieces 38/114; **syllable halves 7/82**.
Listeners face the same problem: a half or a 1-step gate rarely says anything recognisable.

## 2. Partial words: where they come from (T mode, accidental plays by edge mechanism)

| mechanism | plays | what happens |
|---|---|---|
| end: **gate** (`gate:gate`) | 817 | The D126 gate is shorter than the word. A 1-sixteenth gate is 0.21 s at 72 BPM and a 2-sixteenth gate 0.41 s. Content words in these films run 0.4-0.9 s. Median shortfall 0.14 s. 991 of the gated cuts are 1-step gates. |
| end: **choke** | 653 | The next hit (often 1-2 steps later) chokes the previous one mid-word. |
| start: **pieceCut** | 430 | The cutter's word-group boundary lands inside a word. Median 0.055 s in (so the ±60 ms `snap` crossed the boundary), tail to 0.24 s. |
| end: pieceCut | 265 | Same mechanism at the piece's end. |
| start: **onsetTrim** | 124 | `trimmed()` moved the start past the word's start: the D126 waveform onset skips a weak first syllable or consonant ("Pure cane", "The kids", "Granted,", "consciousness"). |
| end: lineEnd / start: lineStart | 114 / 43 | The line unit's own edge is inside a word (an acoustic unit boundary). |
| end: valley | 111 | The gate snapped to a valley inside the word. |

Syllable halves (`kind=half`, 3,519 plays, 38 %) are the other half of the problem. 1,832 of them are
letter splits inside one word. Examples:

- "tr-" / "-ip" (from "trip"), "fro-" (from "frog")
- "UF-" / "-O" (from "UFO"), "-D." (from "LSD"), "pey-" / "-ote," (from "peyote")
- "suct-" / "-ion", "Chevr-", "enfor-", "accr-"

755 halves play a function word on its own ("is", "that", "on", "as", "These").

## 3. The causes, ranked by how often you hear them

1. **Syllable halves are a large share of the chop beat.** The chop beat's fill vocabulary
   (`DialogueChopBeat.preferred`, DialogueChopBeat.swift:85-99) lists the halves `sa, sb, ra, rb` first
   for gap, ghost, push, kick and snare sites. Build rolls and the outro (DialogueMotif.swift:1252,
   1261 and 1303) also hammer the signature half `sa` at gate 1. Halves are cut for any piece of
   0.26 s or more (`splitPieceSeconds`, :41; split at :940). That includes one-syllable words like
   "trip", "frog" and "bugs", because a burst or diphthong produces two nuclei. It also includes
   **initialisms**: "UFO" becomes "UF-" / "-O" and "LSD" becomes "-D.". This is the strongest
   "sounds like a bug" case. It is by design (D125/D126), but it makes 38 % of plays a fragment that the
   recogniser hears 9 % of the time.
2. **The gate is shorter than the word (D126), and chokes add to it.** Gates come from the chop beat
   (`DialogueChopBeat.swift:262-293`: gate 1 for ghost/push/kick/snare, 1 or 2 for gap/answer) and from
   the arrangement (`gate: 1` / `gate: 2` items). `gatedEnd` (DialogueMotif.swift:1343) closes at the
   grid step or a cut point up to 35 ms earlier. It never extends to the word's end. The salient words
   suffer most: "LSD" was played 105 times but mostly at 20-40 % coverage (gate 1 or choke). "UFO"
   pieces were gated at 0.42 s of a 0.5 s word. Across all gated cuts, the most often cut words
   include "waters", "lsd", "recognizers", "grebe", "peyote", "drugs", "tomorrow" and "electronics".
3. **Word-group cuts snap into words.** `Cutter.cut` (DialogueMotif.swift:889) places a group boundary
   at the quietest point between two words' cores. Recogniser words are contiguous on a 60 ms grid, so
   the gap is often zero. `snap` then searches ±60 ms inside the whole two-group span and lands in a
   word's closure or a weak syllable (median 55 ms in). In A mode the acoustic valleys between nuclei
   split words even more (start 1,176 and end 1,493 pieceCut plays).
4. **Onset trim skips into the word** (`trimmed()`, :973). The weak-lead guard only re-runs the attack
   search with a lower peak share, so a soft first consonant or syllable can still be trimmed off
   ("Pure cane" heard as "-ure cane", "The kids", "Granted," and "consciousness" heard as "-ciousness").
5. **Untexted lines and the acoustic fallback.** In 25 % of T-mode loops the chosen line is an
   acoustic unit with no text. Its interest is `acousticInterest` 0.45, which outranks the plain
   transcribed lines at 0.30-0.45. Its pieces are then cut acoustically with no word boundaries. The A
   path (transcription unavailable or late) has 38 % function-only hits and 40 % accidental partials.
   In this probe the transcript always arrived inside `transcriptFirstWait` (1.2 s), but on a busy
   device a late transcript leaves the first piece acoustic.
6. **Transcript timing is coarse.** `SpeechTranscriber` word times here are contiguous and quantised to
   60 ms. Words absorb pauses ("whirligig" 1.14 s, "bugs" 0.90 s). `acceptedWords` trims them to voiced
   cores, but a cut placed by word timing alone can still be 50-100 ms off. That is why the probe
   requires signal continuity before it calls a cut audible.
7. **The pad-bank fallback** (motif nil) covered 77 of 760 pieces in the probe, but these are mostly
   windows with little speech. It produced only 55 plays (0.6 %), yet 27 of them are function-only
   and 40 are audible partials at pad edges (`kind=pad`, mechanism `padEdge`).
   Reordering (`DialogueReorderGuard`) does not cut words. It only changes the order of whole pieces.

## 4. Salience: does the system pick the cool words?

Mostly not. There are three reasons.

- **The footage window is dialogue-blind.** The weaver picks a clip by recency
  (`FootageWeaver.chooseClip`) and a random segment start avoiding earlier starts
  (`ArchiveCatalog.segmentStart`, called at ArchiveFootageService.swift:620). The dialogue engine
  analyses whatever 30 s that piece plays. Nothing prefers a window that contains a high-interest line.
  The only cross-window preference is the motif crate: with no transcript yet, `resolve` first digs a
  striking (≥ 0.6) transcribed line from the last four films (DialogueMotif.swift:429).
- **Lines that hold the salient words are rejected before ranking.** Across the 95 windows there are
  159 salient-word occurrences (lexicon weight ≥ 0.85, or an all-caps initialism). Examples are LSD
  ×20+, UFO ×12, marijuana, mescaline, psilocybin, peyote, drugs, hallucinogen, psychedelic, brain,
  machine, computer and consciousness. Only **58 are inside any ranked line, and only 28 inside a line
  actually chosen**. The other 101 have these reasons:
  - **65 `protectedCut`** (DialogueHierarchy.swift:66): an acoustic unit's edge falls inside a
    tagger-protected span ("the UFO phenomena,", "hiding information about UFO.", "that marijuana
    will", "in Los Angeles"). The unit is rejected and never re-cut on word boundaries. Clause word
    groups are only built from phrases that were not rejected.
  - 17 `notSpeech` (music under the narration).
  - 12 have no unit at all.
  - 6 are shorter than 0.7 s. A one-word exclamation like "space", "explodes." or "LSD" alone cannot
    be a line.
  - 13 are in lines longer than 4 s.
- **Ranking is dominated by sound, and the pool is a coin flip.** `value = sound × fit × length ×
  bonus × (0.35 + 0.65 × interest)` (DialogueMotif.swift:627). Sound varies about 7× across lines;
  interest only 2.9×. The pick is seeded among the top 3 within 85 % of the leader (:540). In 44 of 160
  loops a line of interest ≥ 0.6 was ranked but one at least 0.15 lower was chosen. Examples:
  - "It took us a year and a half of paperwork." (0.45) over "Drug research, that type." (0.93), in the
    Leary window that also holds LSD, mescaline and psilocybin;
  - "Yes, they do look on them as qualified observers." (0.39) over "qualified observers." (0.63);
  - "-" (an untexted unit) over "The kids today are into electronics." (0.88).
- **The lexicon misses DMT-type words.** "dmt" is not in `DialogueLineInterest.categories`. "LSD" only
  matches because it is listed. Initialisms get the name weight 0.8 only when they are capitalised and
  not sentence-initial. Nothing rewards a short, spell-out-able token (initialisms, numbers,
  one-to-two-syllable punchy nouns). When such a word is chosen, causes 1 and 2 then play it as "UF-",
  "-D." or a 0.2 s gate.

Where the cool words are (film seconds, from the windows probed):

- Timothy_Leary_Archives_198, around 2623-2650: LSD, mescaline, psilocybin, marijuana, "Drug research".
  Also around 2110: LSD, Harvard, Los Angeles.
- aapb-cpb-aacip-514-n00zp3ws90 (Leary debate): around 60-90 (Timothy Leary, drugs, LSD), 847 (trip,
  LSD), 1241 (IBM, Voltaire), 1635 (LSD, consciousness), 2029 (psychedelic, microscope, telescope,
  invisible), 2423 (pill, LSD, mind).
- gov.archives.arc.13260: around 244 (LSD, hallucinogen, drugs), 428 (LSD, peyote, monster), 613
  (dose, LSD), 797 (Food and Drug Administration, hallucinogens), 1166 (hallucinated, LSD, sun), 1350
  (LSD).
- VAM026: around 562 (drugs), 813 (opium), 1064 (narcotics, prophet), 1315 (marijuana, San
  Francisco), 1566 (LSD), 1817 (marijuana, drug).
- 342-usaf-42990: 72-200 throughout (UFO, Air Force, telescopes, observatory).
- MovieTra1950_3: around 10-40 ("mind explodes", "a free trip", "straitjacket").
- horizons-of-science-thinking-machines: "brain", "machine" and "computers" throughout.
- Designfo1956: "Firebird", "Cadillac", "highway of tomorrow".
- Secrets of the Pond, Ergot, Alan Watts and sailfilm_hear are mostly plain narration. Ergot has
  "lysergic acid" around 1012.

## 5. Concrete reproducible cases (in `bugs/curated/`; all 686 cases are in `bugs/` and `bugs/index.tsv`)

Each case has a `-played.wav` (the chop exactly as rendered) and a `-context.wav` (the source line
±0.35 s). The film seconds are the source time of the play. "Re-heard" is what the recogniser makes of
the chop alone.

| file | film @ s | what | re-heard |
|---|---|---|---|
| 01-LSD-whole-OK | Timothy_Leary_Archives_198 @ 2642.2 | "LSD." as a whole 0.61 s piece (the target sound) | "LSD." |
| 02-LSD-choked-0.43s | same | choked by the next hit at 0.43 s (word 72 % played) | "Oh, is the..." |
| 03-LSD-gated-0.44s | same | 2-step gate, 74 % played | "Oh, is the..." |
| 04-LSD-half-LS / 05-LSD-half-D | same, 2642.2 / 2642.6 | the syllable halves "LS-" and "-D." | "Oh, is." / "See." |
| 06-marijuana-whole-OK | VAM026 @ 1328.1 | whole piece, 0.60 s | "And marijuana." |
| 07-marijuana-choked / 08-marijuana-gate1 | same | choke at 0.40 s / 1-step gate at 0.20 s (34 %) | "And Merrill." / nothing |
| 09-UFO-half / 10-UFO-gated | 342-usaf-42990 @ 184.9 / 184.6 | "-O" half; "UFO" gated at 0.42 s | nothing / nothing |
| 11-trip-half / 12-trip-half-ip | MovieTra1950_3 @ 29.7 / 29.8 | one-syllable "trip" split into "tr-" / "-ip" | nothing |
| 13-Smaller-gated | Secrets of the Pond @ 60.0 | "Smaller," 2-step gate, ends mid-vowel (tail -7 dB) | "Small aren't." |
| 14-grebe-choked | Secrets of the Pond @ 400.3 | "grebe," choked | "Great." |
| 15-AirForce-choked | 342-usaf-42990 @ 82.6 | "The Air Force" choked inside "Force" | "The airport." |
| 16-fn-is / 17-fn-Yes-they | Pond @ 256.6 / usaf @ 134.9 | function-word stabs ("is", "Yes, they") | nothing / "Yes." |
| 18-Pure-cane-onsetTrim | Ergot @ 832.3 | onset trim skips the "P", then choke | "Oh, okay." |
| 19-The-kids-onsetTrim | aapb-cpb-aacip-514-n00zp3ws90 @ 480.7 | onset trim into "The", choked before "kids" | "The uh." / nothing |

To reproduce any case, run the probe (below). It is deterministic per cache, model and code (two full
runs gave identical motif hit counts). Find the case in `bugs/index.tsv` by film and seconds, and the
full hit record (fragment, played frames, words, edges, levels) in `probe.log` (`SALIENCE-HIT`).

## 6. What would move the numbers (input for the fix step, not done here)

- Initialisms and short salient words become atomic: no syllable halves, and gates extended to the
  word's end. An initialism may split only at letter boundaries (so "D-M-T" lands one letter per
  step).
- Halves only for content words of two or more real syllables. Never function words, never
  one-syllable words. The fills should prefer whole content-word pieces over halves.
- Gates stretch to the word end, or to the next cut point after it, when the word carries weight. A
  choke should not land inside a salient word.
- Group cuts: snap only within the two words' boundary gap, plus a few ms, never inside a core. Onset
  trim never past a word start by more than the slack.
- Untexted units: when a transcript exists, rank them below transcribed lines (an `acousticInterest`
  under `plainInterest`).
- Salience: re-cut `protectedCut` units on word boundaries (word-aligned line units from the
  transcript). Weight interest more strongly than sound. Pick the leader when its interest is much
  higher. Add initialism, number and drug terms (DMT, LSD, THC, UFO, ...) to the lexicon. Let the
  footage service prefer a segment whose transcript holds a striking line (for example, through the
  crate, or a per-film salience index built from earlier transcripts).

## Re-run (before/after)

```sh
PATH=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/bin:$PATH \
DD=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/dd-sal-mac \
  scripts/dialogue-salience-probe.sh /private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/salience/after 8 72
```

(`scripts/dialogue-salience-probe.sh` builds for testing, runs only `DialogueSalienceProbeTests` with
`-parallel-testing-enabled NO` so the probe lines reach the log, then runs
`scripts/dialogue-salience-report.py`. Add `BUILD=0` to reuse a build. About 6 minutes for 95 windows.
The probe, report and runner are committed in 3fc2446.)

It writes `probe.log`, `summary.json` (the table above, by mode) and `bugs/`. It is deterministic for
the same cache, model and code. Two runs gave identical hit counts. Compare `summary.json` against
`/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/salience/summary.json`.
