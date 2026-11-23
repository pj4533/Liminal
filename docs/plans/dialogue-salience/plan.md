# Plan: recognisable dialogue chops, no accidental partial words, footage weighted to salient speech

Date: 22 November 2026. Repo: `/Users/pj4533/Developer/Liminal`, branch `main`, base commit `3fc2446`.
Input: `/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/salience/diagnosis.md`
(read it first; the cause numbers below refer to its section 3).

User request, in short: more chops like "psilocybin" / "DMT" (recognisable, catchable on the beat), fewer
connective words and partial words as hits, and find the "sounds like a bug" cases. Keep D125 hooks, D126
tightness and arc, D127 variety.

## Ground rules for every stage

- Do NOT edit: `Liminal/Visual/ImageSources/*`, `image-collections.json`, `Liminal/Archive/ArchiveCatalog.swift`,
  `scripts/archive-curate.py`. A parallel workflow owns them.
- The working tree already holds that workflow's uncommitted edits in `AGENTS.md`, `CLAUDE.md`,
  `Liminal/Utils/DebugLaunchOptions.swift`, `LiminalTests/CuratedImageTests.swift`, `docs/architecture.md`,
  `docs/development.md`, `docs/experience.md`, `docs/image-sources/*` and two untracked files. Never
  `git add -A`, `git add .`, `git commit -a`, `git stash` or `git checkout --` anything. Commit with explicit
  paths only. When one of those shared files needs an edit of ours: copy the file aside, make the edit,
  `diff -u copy file > own.patch`, `git apply --cached own.patch` (so the index gets only our hunk). If that
  does not apply cleanly, leave the edit in the working tree uncommitted and say so in the stage report.
  Prefer putting our documentation in `docs/decisions/music.md` (clean) and new files.
- Avoid new debug launch flags (the flags file is shared). Use constants in `DialogueMotifTuning` /
  a new tuning enum, and injectable parameters for tests.
- Builds: always `-destination`. Serialise every `xcodebuild` (one at a time on the machine; the parallel
  workflow builds too). Use the lock shim: prefix commands with
  `PATH=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/bin:$PATH`
  and a private derived-data dir
  (`DD=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/dd-sal-mac`, pass `-derivedDataPath $DD`).
- No Gemini. The probe and tests use the installed on-device speech model only. Never press Play in a
  flagless launch.
- Contracts that must hold: nothing new on realtime audio paths; dialogue analysis never delays the film
  bed or the music; plans keep the cue token and revision; the acoustic fallback stays; `Atomic`/`Mutex`
  only; code off the main actor is `nonisolated` / an actor / detached.
- Tests are Swift Testing. A test that encodes the old behaviour on purpose (for example "5 to 7 chop-beat
  onsets a bar", halves in the fills) is replaced, with the reason listed in the decision record. Never
  loosen a tightness test.
- Each stage ends with: macOS build, the dialogue test suites
  (`-only-testing:LiminalTests/DialogueMotifTests`, `DialogueChopVarietyTests`, `DialogueTightnessTests`,
  `DialogueGateTests`, `DialogueOnsetTests`, `DialogueLineInterestTests`, `DialogueRuntimeTests`,
  `DialogueEngineTests`, plus any new suite), a probe run into its own out dir, and one commit on `main`
  (plain sentence-case subject, the attribution trailer the session specifies). Do not push.

Probe command (about 6 min; `BUILD=0` reuses a build):

```sh
PATH=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/bin:$PATH \
DD=/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/dd-sal-mac \
/Users/pj4533/Developer/Liminal/scripts/dialogue-salience-probe.sh \
  /private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/salience/<out> 8 72
```

Baseline: `/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/salience/summary.json`
(T: functionOnly 0.172, accidental 0.256, half 0.248, audiblePartial 0.520, salientHeard 0.173,
salientWhole 0.059, noWordHeard 0.157, bestHeardBelow0.5 0.659, lineInterestMedian 0.50, untextedLines 40/160;
salientWords inRankedLine 58 and inChosenLine 28 of 159, protectedCut 65).

## What the code does today (verified by reading it)

- `Cutter.cut` (`DialogueMotif.swift` ~889): with words, groups join only by length (<0.25 s, ≤3 words), so
  function-only groups exist ("It's a", "Yes, they"). The boundary is `quietest(lo..<hi)` or the midpoint,
  then `snap` searches ±60 ms inside the whole two-group span, so it lands inside a word. Halves are cut for
  any piece ≥0.26 s at the valley nearest the middle, with no regard to words, syllables or weight.
- `trimmed()` (~973): the weak-lead guard only re-runs the attack search; the start can still sit inside the
  first word.
- `gatedEnd` (~1343): closes at `step + gate` minus 6 ms, or a cut point up to 35 ms earlier. Never later.
- `perform` choke (~1440): any later hit chokes the previous piece wherever it is.
- `GrooveVocabulary.preferred` (`DialogueChopBeat.swift` 85-99): halves first, no weights, `others` unweighted.
  `arrange`: build rolls, turn and outro tag hammer `sa` at gate 1.
- `DialogueLineInterest`: no "dmt", initialisms only via the lexicon or mid-sentence capital (0.8), numbers 0.5.
- `rankLines` (~627): `sound × fit × length × bonus × (0.35 + 0.65·interest)`; pool = top 3 within 85 %.
  Untexted units get `acousticInterest` 0.45 even when a transcript exists.
- `DialogueHierarchy.refine` (:37-88): a unit whose edge cuts a protected span is rejected (`protectedCut`) and
  not re-cut. `Builder.addWordGroup(parent:words:tokens:spans:)` (:507) already builds a word-aligned unit with
  acoustic edge refinement, but is only called for clauses of phrases that were not rejected.
- Footage: `ArchiveFootageService.prepare` (~595-640) picks the clip with `weaver.chooseClipForPlayback`
  (recency weights) and the start with `ArchiveCatalog.segmentStart` (random, avoiding shown starts). The sound
  cue starts at `segmentStart + soundDelay·rate` (`ArchiveAudioCuePlan`), and the dialogue engine analyses up to
  32 s from there. Nothing knows where the salient speech is. `DialogueLineLedger` is the model for a small
  persisted, mutex-guarded, per-film store.

## Design decision to carry through (state it in the decision record)

Whole words are longer than a sixteenth (0.21 s at 72 BPM; content words run 0.4 to 0.9 s). Playing words
whole therefore means fewer onsets per bar in the chop beat and build than D127's 5 to 7, unless the line
offers short whole units (letters of an initialism, syllables of a salient word, short one-syllable words).
The plan keeps the grid, the feel, the hook skeleton, the arc and the "no same cut twice in a row" rule, and
lets the fill drop a site rather than play a fragment that cannot finish. Expect roughly 3 to 6 onsets a bar.
This is the trade the user asked for ("less partial words"); record it as such and leave the density to the ear.

---

## Stage 1. Measure more, then stop cutting words by accident

Goal: accidental partials near zero and no by-design halves of function words, one-syllable words or
initialisms. No change yet to which line is chosen.

### 1a. Probe additions first, and a new baseline (no logic change yet)

In `LiminalTests/DialogueSalienceProbeTests.swift` and `scripts/dialogue-salience-report.py` add, then run
the probe into `.../salience/base2` and keep it:

- **Tightness per play**: the D126 independent detector (steepest rise of a 10 ms log envelope, 300 Hz to
  3.4 kHz, on the rendered chop) against the event's accent; `onsetMs` per `SALIENCE-HIT`. Report per mode for
  sub-line plays: median, p5, p95, count over 35 ms. See `DialogueTightnessTests.hits` for an existing helper.
- **Variety per loop** (reuse `LiminalTests/DialogueChopMetrics.swift`): chop-beat unmarked same-cut pairs,
  longest run, distinct cuts per 2-bar cell (mean and least), onsets per bar for chop beat and build,
  dry occupancy per 8-bar section.
- **Ranking**: `strikingPassedOver` (a ranked line of interest ≥0.6 existed, a line ≥0.15 lower was chosen;
  diagnosis counted 44/160).
- **Fragment classes** (used from 1b on): `kind` gains `letter` and `syllable`; a play is `clean` when both
  edges are at word, letter or real acoustic boundaries. The report adds: halves of function words, halves
  inside one-syllable words, initialism cuts not at a letter boundary.

Also capture the mix baseline before changing logic: `scripts/mix-matrix.sh` for cases ref, fast, same and
transcribe (read its options first; one capture at a time; captures stay out of git), saved under
`.../salience/matrix-base`. Record the fail-level results for C-B8, C-B9, C-D1 to C-D9.

### 1b. Fixes (files: `DialogueMotif.swift`, `DialogueChopBeat.swift`, `DialogueHierarchy.swift`, `DialogueModels.swift` as needed)

1. **Word groups carry a content word** (cause 3, connective pieces). `Cutter.cut` takes the word weights.
   A function word (weight 0) attaches forward to the next content word, or backward when a pause of
   `groupPauseSeconds` or more follows it or it ends the line. A group holds at most 4 words and about 0.9 s.
   Result: no function-only piece unless the whole line is function words.
2. **Boundaries only where the sound dips** (cause 3). For a boundary between groups: search only between the
   two neighbouring words' cores widened by the transcript's 60 ms uncertainty, and accept it only when it is a
   real dip (start hypothesis: at least 9 dB under the lower neighbouring nucleus peak, or a quiet run of
   15 ms or more). No dip: merge the two groups (co-articulated speech is not cut). If a merged piece would pass
   about 1.1 s, take its deepest dip anyway. Keep at least one cut so the line stays usable. Replace the
   ±60 ms whole-span `snap` with a snap bounded to the dip. Apply the same "real dip" test to the acoustic
   branch's valley cuts (A mode).
3. **Line edges on word boundaries** (cause 5). In `refine`, a transcribed line-level unit whose edge sits
   more than 30 ms inside an accepted word core is extended to that word's edge (through the same acoustic
   edge refinement `addWordGroup` uses) when the result stays within the line limits, else pulled back to the
   previous word boundary. Do the `protectedCut` rescue here too: for a unit rejected as `protectedCut`, widen
   its token range to cover the protected span and add it with `addWordGroup` instead of losing it.
4. **Onset trim never eats the word** (cause 4). In `trimmed()`, a transcribed piece whose first kept word has
   weight above 0 never starts more than `wordStartSlackSeconds` after that word's start: clamp the start to
   the word start (zero-crossing snapped), keep the detected beat frame as the accent. The lead-in before the
   step may then be up to about 90 ms for such a piece (the consonant); the accent still lands on the step, so
   the tightness numbers must not move. Whole weak lead function words may still be trimmed off.
5. **Splits only where they are whole units** (cause 1). Replace "halves of any piece ≥0.26 s":
   - With a transcript: split only inside a word of weight ≥0.7 that has two or more syllables by a text
     count (vowel groups, silent final e) and as many nuclei; cut at the valleys between its nuclei into 2 to 4
     `syllable` fragments in order ("psi", "lo", "cy", "bin"). An initialism (all capitals, or dotted, or a run
     of single capital-letter tokens) splits only when its nuclei count equals its letter count, into `letter`
     fragments; otherwise it is atomic. Never split a function word, a one-syllable word, or across words.
   - Without a transcript: a split only at a real dip (rule 2), so it is a word or syllable gap.
   - `halves: [Int: [Int]]` may now hold 2 to 4 ordered units; update `headHalf`, `GrooveVocabulary`, `split`,
     `arrange` and the hook log letters accordingly. Each fragment records the whole-word spans it contains.
6. **A hit plays to a word end** (cause 2). `gatedEnd`: when the gate target falls inside a word (transcript)
   or while the piece is still sounding with no cut point (acoustic), end at the first word end or real dip at
   or after the target when that is within about 0.30 s, else at the last one before it that keeps
   `minimumGateSeconds`; only when neither exists use the old gate. Keep the 6 ms lead and the release shape.
7. **No choke inside a content word**. In `perform`, a new hit may not choke the previous piece inside a word
   of weight above 0 (or mid-sound with no cut point): the candidate step is skipped (an unfixed hit moves
   on by 8ths as today; a fixed fill hit is dropped). Deliberate stutters (`item.stutter`, `follow`) are exempt,
   and stage 2 restricts them to units that are whole at one step.
8. **Fit the cut to the room**. `arrange`/`groove` receive the beat duration (store it on the motif so
   `carried` has it). Each chop-beat, turn, build and tag hit takes a cut whose length to its word end fits the
   steps before the next hit (tolerance about 20 ms); a 1-step site takes only a letter, a syllable of a
   salient word or a short whole word; a site nothing fits is dropped (the `dropped` set exists). Coverage
   repair still guarantees an onset in every bar and uses a whole content piece.
9. **Untexted units when a transcript exists** (cause 6): interest 0.15 (below `plainInterest`), so they only
   lead when the window has no transcribed line. Without any transcript `acousticInterest` stays 0.45.
10. **Pad-bank fallback** (cause 7, 55 plays): when a transcript exists, skip pads whose edges sit more than
    30 ms inside a word core. If this is not a small change in `DialogueBankBuilder`, leave it and report the
    residual.

Unit tests (new `DialogueWordCutTests`, on `DialogueFixtures` speech with transcripts): no fragment edge more
than 30 ms inside a word core except `syllable` edges inside salient words; no function-only piece when the
line has a content word; no split of a one-syllable or function word; an initialism splits only by letters;
a gated hit ends at a word end; a choke never lands inside a content word; a piece never starts past its
first content word's start plus the slack; same seed gives the same plan.

Stage 1 targets on the probe (T mode unless noted): `categories.accidental` ≤0.05 (A ≤0.20);
halves of function words 0, inside one-syllable words 0, initialism cuts off a letter boundary 0;
`functionOnly` ≤0.08; tightness median within ±2 ms of `base2`, none over 35 ms; chop-beat unmarked
same-cut pairs not above `base2`. Curated cases 01 to 19 in `bugs/curated/` (find them by film and seconds in
the new `index.tsv`): no LSD / marijuana / UFO / trip play is cut inside the word.

## Stage 2. Salience: what counts as a cool word, which line leads, how it is chopped

Goal: hits are recognisable words; connective words are heard only inside a whole-line statement.
Files: `DialogueLineInterest.swift`, `DialogueMotif.swift`, `DialogueChopBeat.swift`, `DialogueHierarchy.swift`,
tests, probe report.

1. **Word salience** (`DialogueLineInterest`). Add a `wordSalience` result per word (weight, kind, syllable
   count, letters for an initialism) and keep `wordWeights` as a view of it.
   - Initialisms: 2 to 5 capital letters, dotted forms ("U.F.O."), and runs of single capital-letter tokens
     ("D M T") merged into one word: 0.95. Exclude "I", "A", "OK".
   - Lexicon: add dmt, thc, pcp, mdma, lysergic, ergot, cannabis, hashish, amphetamin*, barbitur*, ketamine,
     ayahuasca, psychoactive, tranquil*, nasa, cia, fbi, ussr, dna, esp and similar; review `falseFriends`.
   - Numbers: years, counts with "hundred / thousand / million / billion", "zero", percentages: 0.65.
     Plain small numbers stay 0.5.
   - Names 0.8 as today, also when sentence-initial if the tagger says name. Concrete nouns: any noun that is
     not a function word 0.35; long nouns 0.45.
   - Line interest: the peak word dominates (start: 0.60 peak + 0.20 second + 0.20 content share), same shape
     penalties, plus 0.05 for an initialism or a drugs-category word. Bump the lexicon version constant used by
     stage 3's index.
2. **Salient words become candidate lines** (salience gap 2). After `refine`, for each word of weight ≥0.85 not
   inside a ranked line, add a word group of its clause (2 to 6 words, 0.5 to 4 s, word-aligned through
   `addWordGroup`), covering the `protectedCut`, "no unit", "too short" and "longer than 4 s" cases. Allow a
   short striking line: relaxed minimum 0.45 s and 2 nuclei when its peak weight is ≥0.85. `Cutter.cut` may
   return a single piece when that piece has letter or syllable units.
3. **Ranking and pick** (salience gap 3). Interest outweighs sound: sort by tier first (striking ≥0.6, then
   ≥`plainInterest`, then the rest), then by a value in which sound is compressed (start: `sqrt(sound)`) and
   interest is `(0.2 + 0.8·interest)²`. The seeded pool keeps only lines within 0.10 interest of the leader
   (and the existing value share). Add a small term for choppability (count of whole content pieces plus
   letter/syllable units, capped). D123 ledger rules, said-once rule and the tiers in `resolve` are unchanged.
4. **Hits carry content** (connective share).
   - `hookRoles`: signature = highest weight (ties later), must be weight >0 when the line has one; response and
     third never weight 0 while a content piece or a unit of the signature exists.
   - `GrooveVocabulary.preferred`: every site lists whole content pieces and the signature's/response's letter
     or syllable units by descending weight (ghost and push sites by length among those that fit), never a
     weight-0 cut. Weight-0 pieces are played only by fragment 0 (the line) and by the outro's in-order walk of
     the whole line (O0), which is a line statement.
   - The return piece, intro tags, turn, breakdown slots and repair use content pieces only.
5. **Spell figures** (the "DMT on the beat" case).
   - An initialism signature is spelled one letter per step in source order: 8ths by default, 16ths when every
     letter fits a sixteenth, then the whole word on the next beat. A salient multi-syllable signature does the
     same with its syllables ("psi-lo-cy-bin", then "psilocybin").
   - Use it in: the build (replace the `sa` hammer in the halving and ping-pong variants; the ladder keeps
     whole pieces in source order), the outro tag (steps 56 to 60, ending with a cut that fits before the next
     loop's downbeat), and as an in-order run inside the chop-beat fill (reuse the `orderOK` run logic so units
     of one word ascend into the signature hit).
   - Stutters repeat only a letter, a syllable of a salient word or a whole word no longer than a step.
   - A signature with no units (one syllable, unsplittable): the build alternates whole content pieces with
     rests. No 1-step stab of a longer word anywhere.
6. Keep: the four hook templates and the two-loop rotation, R on a snare step, the arc sections and
   `chooseArc`, the feels, the non-reorder rule, the dry budget and occupancy caps, coverage repair.

Tests: extend `DialogueLineInterestTests` ("DMT", "D M T", "U.F.O.", "LSD" ≥0.9; "psilocybin", "mescaline" 1.0;
"1967", "ten thousand" ≥0.6; "and the" 0; a line with "Drug research" outranks "It took us a year and a half
of paperwork" at equal sound); new `DialogueSalienceTests` (no weight-0 hit outside line statements; spell
figure in order on consecutive steps and ending on the whole word; syllable units only in salient
multi-syllable words; a striking line is not passed over for one 0.15 lower; same seed, same plan). Update
`DialogueChopVarietyTests` / `DialogueMotifTests` bounds that encode onsets per bar or halves, with reasons.

Probe report: classify `letter` (clean) and `syllable` (by design, salient word only), add the share of
plays that are spell units and the count of loops with a spell figure.

Stage 2 targets (T): `functionOnly` ≤0.03; `noWordHeard` ≤0.05; `bestHeardBelow0.5` ≤0.45; `salientHeard`
≥0.35 and `salientWhole` ≥0.25; `lineInterestMedian` ≥0.60; `untextedLines` ≤8; `strikingPassedOver` ≤5;
`salientWords.inRankedLine` ≥110 and `inChosenLine` ≥50 of 159, `protectedCut` ≤10; re-heard main word in whole
content pieces ≥60 % (baseline 15/52). Stage 1 targets still hold.

## Stage 3. Footage weighting: steer sound cues to where the salient speech is

Goal: the piece that supplies the dialogue more often starts where an unplayed striking line is, with a
random share kept so variety stays. No edit to `ArchiveCatalog.swift`; nothing waits on analysis.

1. **`DialogueSalienceIndex`** (new, `Liminal/Audio/Lofi/Dialogue/`, modelled on `DialogueLineLedger`:
   `nonisolated final class`, `Mutex`, coalesced utility-queue save to
   `Application Support/Liminal/DialogueSalience.json`, in-memory under tests). Per content id: the scanned
   film-second spans, and per span the lines worth knowing (start, end, interest, peak word, peak weight;
   interest ≥0.45, at most 6 per 30 s). Carries the lexicon version; entries of an older version are re-scored
   from stored words or dropped.
2. **Fill from played cues** (free): where `DialogueCueCoordinator` stores a transcript (`store(_:transcript:refined:)`,
   also late ones), record the cue's span and its ranked transcribed lines. Already off the audio thread at
   utility priority.
3. **Fill ahead of time** (`DialogueSalienceScanner`, new actor): while Lo-Fi plays with footage, scan cached
   films with audio in 30 s windows, least recently shown film first, coarse to fine. A window is decode plus
   on-device transcript plus `DialogueLineInterest` on the text (no acoustic analysis). Rules: installed model
   only, never a download; background priority; one window at most every 10 s; never while a cue's
   transcription or planning is in flight, and cancel when one starts (the cue's 1.2 s first-plan wait must
   not move); off entirely in test hosts and when `DebugLaunchOptions.blocksImageGeneration` automation is
   active unless a test injects it. If the cue-transcript timing in the probe (`transcribeMs`) or
   `scripts/perf-run.sh --lofi` gets worse with the scanner on, ship items 1, 2, 4 and 5 and leave the scanner
   off behind its constant, and say so.
4. **Segment start** (`ArchiveFootageService.prepare`, plus a new pure `nonisolated enum FootageSalience` in
   `Liminal/Archive/`): keep the `ArchiveCatalog.segmentStart` call exactly as it is. For a piece that will
   carry sound, with chance 0.65 replace its result by a salient start: among indexed lines of this film with
   interest ≥0.6, not in the ledger, and at least 20 s from every shown start, pick one weighted by interest
   (weighted random among the top 5, not the maximum) and place the start so the line falls 3 to 10 s
   (seeded) after the sound cue's source start (`segmentStart + soundDelay·rate`), clamped to the film. No
   candidate: keep the catalog's start. Draw from a separate RNG seeded from the clip id and piece index, so
   the weaver's stream is untouched and an empty index gives bit-identical starts to today.
5. **Film choice** (`FootageWeaver.chooseClip`): optional `boost` per clip id (default empty = today's
   behaviour) multiplying the recency weight by `1 + min(1, unplayedStrikingLines / 6)`, used only for sound
   requests. At most 2×; nothing is excluded; pinned/discovery rotation unchanged (A31: no caps).
6. Log one line per salient pick (film, line seconds, interest, peak word).

Tests (new `FootageSalienceTests`): empty index gives the same clip and start as before for a set of seeds;
with an index, at least 55 % and at most 75 % of 1,000 sound picks are salient starts while candidates last;
the chosen line lies inside the dialogue span; ledger-played lines and shown starts are avoided; every clip
is still chosen; the index round-trips and drops entries of an old lexicon version.

Probe: add a `SALIENCE-FOOTAGE` simulation: fill the index from the probe's own transcripts, simulate 500
sound-piece picks per film set with and without the index, and report the share of picks whose 32 s
dialogue span holds an unplayed line of interest ≥0.6, the share taken by the random path, and each film's
share. Targets: salient share at least double the no-index share and ≥0.60; random path ≥0.25; every film
with audio at least half its no-index share.

## Stage 4. Verify against the baselines, document, commit

1. Full probe run (`.../salience/after`), compare with `summary.json` and `base2`; list every target above as
   met or missed with numbers. Re-listen list: the 19 curated cases, found again by film and seconds.
2. Tightness: probe `onsetMs` sub-line median within ±2 ms of `base2`, none over 35 ms; `DialogueTightnessTests`
   unchanged and passing.
3. Variety: unmarked same-cut pairs and longest run not above `base2`; every 2-bar cell at least 3 distinct
   cuts where the line offers 3; report onsets per bar and occupancy next to `base2` (the expected drop in
   onsets is the design decision above, not a regression to hide).
4. Mix: `scripts/mix-matrix.sh --strict` for ref, fast, same, transcribe against `matrix-base`: no new
   fail-level failure in C-B8, C-B9, C-D1 to C-D9 (C-D9: onset in every bar, line at most twice, sub-line share
   ≥0.6, occupancy 0.30 to 0.62). A new failure is fixed in the planner (density, budget) and never by changing
   gains or the criteria.
5. Full builds: macOS and visionOS Simulator. `xcodebuild test ... -only-testing:LiminalTests` once, serialised.
   `scripts/perf-run.sh --lofi` if the scanner ships on.
6. A 200 s macOS app run with automation flags (`-LiminalAutoPlay YES -audio.musicMode lofi -archive.enabled YES
   -LiminalVideoOffline YES`), reading the hook log lines for spell figures, no weight-0 hits, salient-pick lines.
7. Docs: `docs/decisions/music.md` D130 (direction with the user's words, measured before, change, measured
   after, tests replaced on purpose, not checked by ear / on device). `docs/architecture.md` dialogue pipeline
   section, `docs/experience.md`, `docs/development.md` (probe usage), `CLAUDE.md`/`AGENTS.md` repository map
   for the new files: these are shared files, use the own-hunk patch method. Commit on `main`. Do not push.

## Acceptance summary (same probe: 8 chunks, 72 BPM, T mode unless noted)

| metric | before | target |
|---|---|---|
| function-word-only hits | 0.172 | ≤0.03 |
| accidental partials | 0.256 | ≤0.05 (A: 0.396 to ≤0.20) |
| halves of function / one-syllable words, initialism cuts off a letter | 755 / most of 1,836 | 0 / 0 / 0 |
| no word heard | 0.157 | ≤0.05 |
| salient word heard / heard whole | 0.173 / 0.059 | ≥0.35 / ≥0.25 |
| chosen line interest, median | 0.50 | ≥0.60 |
| striking line passed over | 44/160 | ≤5 |
| salient words in a ranked / chosen line | 58 / 28 of 159 | ≥110 / ≥50 |
| footage picks with an unplayed striking line (simulation) | measured without index | ≥2× and ≥0.60, random path ≥0.25 |
| tightness, sub-line onset vs step | base2 median | within ±2 ms, none >35 ms |
| chop-beat same-cut pairs, longest run | base2 | not higher |
| C-B8, C-B9, C-D1 to C-D9 | matrix-base | no new fail-level failure |

Residuals to report honestly: A-mode numbers (no words at plan time), `notSpeech` salient words (music under
narration), onsets per bar, anything not heard by ear or on a device.
