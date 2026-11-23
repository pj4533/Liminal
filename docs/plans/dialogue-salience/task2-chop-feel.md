# Chop feel implementation and measurement, 23 November 2026

Task 2 of `HANDOFF-2026-11-23.md`; fixture acceptance is separate from real-film/mix/listening acceptance.

**Final local handoff:** [CODEX local continuation](../HANDOFF-2026-11-23-CODEX-LOCAL.md) supersedes earlier pending-run notes. Latest productionfc4f391 run45218799677 passed14tests/2suites (coverage14/14) and18/18 gates,108loops/72cross-line pairs. Consolidated73e8d4 builds passed macOS/visionOS, but full632methods/84suites run45221402727 was cancelled by user request, not failed/completed. Added long-word test70ace3f execution is unconfirmed. All remote jobs stopped; continue locally, no paid services. Synthetic success does not qualify authentic T, mixes or listening.

Before text/manifest from06c1095 is now durable at `/app/state/liminal-verification/task2-baseline/feel-attachments/`; original `/tmp/liminal-feel-before/feel-attachments` is volatile. Latest report `/app/state/liminal-verification/run45218799677/feel-report-vs-06c1095.json`. Full/chop grids .121956→.064830 / .090208→.067177; chop rest .918789→.891614, quiet .640732→.623636; full reverses108→285 with zero repeated positions. Native/linked104-pad timing and56-pad headroom evidence remain synthetic. Original timing/variety thresholds unchanged.

## Playback

`DialogueVarispeed` measures the median interval between the chosen line's acoustic syllable onsets
(discarding gaps outside 80–800 ms). When fewer onsets are available, line duration / nucleus count
is the fallback. It chooses the closest quarter-beat, half-beat, beat or two-beat interval in pitch
space, limiting linked speed/pitch to ±2.5 semitones. No independent random pitch is added. Each
source line and all its cuts share this transform. Same-loop transcript revisions and carried lines
retain it. A new line derives its own ratio from its cadence and the current tempo.

Source PCM, word cores, cut points and frame ranges remain in their original coordinates. The motif
converts output seconds to source frames using native sample rate × playback ratio; planning and
clean gates use the same conversion. Pad keys/bank IDs include the transform. The existing offline
renderer resamples once, with its existing rate-adjusted fades and source-feature lookup. All full
resampled pad renders are cached and their attacks are remeasured, including repair candidates and
units a carried loop may later choose; gates copy a prefix of those buffers. Rendered attack frames are mapped back to source coordinates for scheduling. Audio thread,
cue token, revision, cancellation, and bed/music timing paths are unchanged.

## Phrase moves

`DialogueMovePool` takes the previous loop's cells even when the new loop chooses another line.
Transcript recuts retain the prior history rather than avoid their own first arrangement. The pool
varies intro tag starts, build repeat gestures, sparse breakdown word/answer positions, return quiet
entrances and the outro tag as whole groups. Letter/syllable figures keep their order, uniform spacing
and beat-aligned whole-word landing. Dynamic outro chains retain their original processing order.
The two chop-beat cells retain their within-loop hook recurrence and the six arc sections remain.

Reverse pickups use the salient whole signature, from seeded available downbeat targets with enough
room for its entire reversed buffer. Draws span intro, breakdown and the quiet return entrance, with at most one added pickup per
section; actual successful placements depend on word length and the dry occupancy budget. No reverse
or marked stutter/roll repeats its previous loop's position. Repeats that cannot fit whole are omitted;
a marked stutter no longer grants permission to choke inside a content word.

The previous always-on reverse into bar 13 is removed. Sparse words can still leave the same ordinary
empty steps across loops: with roughly three whole-word onsets per bar, disjoint empty grids would
be mathematically impossible. No-repeat applies to intentional gestures; rest/quiet overlap is
measured separately, not asserted to be zero.

## Deterministic measurements

`DialogueFeelMetricsTests/emitPatternAndTimingMeasurements` emits 108 fixture loops: 12 seeds × three
speech/transcription/tempo fixtures × three successive loops. Its `FEEL-METRIC` attachment is raw
measurement evidence. The harness runs the real motif planner and performer; it does not simulate a
second implementation. Films contain multiple lines, and reports count pairs whose line key changes.

`scripts/dialogue-feel-report.py <attachments-or-log> --baseline <baseline-attachments-or-log>` applies
identical definitions to both raw datasets and exits nonzero when its acceptance comparisons fail.
It deduplicates log/attachment copies by film, seed and loop.

- Positions are sixteenths 0–255 of the 16-bar arc (bar = position / 16, step = position mod 16).
  Positions 32–95 are the chop beat. Histograms preserve every exact position. The report also repeats all descriptive measures in a
  `chopBeat` scope covering positions 32–95 only.
- Reverse means a rendered-plan event with the reverse effect. Roll means a marked stutter in the
  build; stutter means a marked repeat elsewhere. A rest is a step with no scheduled accent.
- Quiet means no dry event covers the grid point, using the event's actual source frame range and
  linked playback ratio. Echo/reverb tails are excluded; this is dry scheduling occupancy, not a
  waveform loudness claim. Intentional quiet moves for transition prediction start contiguous quiet
  gaps of at least four sixteenths.
- Recurrence is the fraction of a preceding loop's move positions repeated in the next loop.
  Peak position share is the largest single-position count divided by the number of loops.
- Grid similarity is consecutive loops' Jaccard on `(position, piece, gate, effect)` tuples. Piece
  IDs are line-local; this measures arrangement similarity rather than identical audio content.
- Position predictability is leave-one-seed-out balanced accuracy of the per-position majority
  predictor, trained on the same fixture's other seeds. Next-move predictability is the accuracy of
  the previous-class majority transition predictor, also leaving the tested seed out; transitions
  include reverse, roll, stutter and beat-long quiet-gap starts. These are descriptive predictors,
  not claims about listener perception or causal entropy.
- Gates require 108 loops in both sets, more reverses, zero repeated reverse positions, lower
  consecutive grid similarity and next-move predictability, and no worse rest/quiet/roll/stutter
  recurrence. Failed gates must be reported, not redefined after seeing results.

`DialogueChopFeelTests` additionally compares independent D126 attack measurements on native and
speed-matched renders of the same selected lines. Its paired gate keeps median absolute attack-error shift ≤2 ms and
counts of attacks beyond 35 ms no worse. Existing tightness/mix criteria remain unchanged. Other
regressions cover deterministic replay, cross-line history, bounded per-line rates, single resampling,
hook recurrence, and whole-word endings including marked stutters.

## Evidence

The before build uses unchanged production DSP/planning from `3d4c3a6`; measurement and test-build
repairs are in `aa70cb8` through `06c1095`. The first hosted attempts exposed an unsupported xcodebuild
option, a Swift expression type-check timeout in `DialogueHookMetrics`, and Swift Testing macro
expansion errors in `DialogueSalienceTests`. Those were repaired without changing baseline audio or
patterns. Run `45172042529` at `06c1095` is the baseline measurement run.

The baseline measurement passed: 108 loops, 72 consecutive pairs, all 72 changing source lines.
Raw evidence is the `chop-feel-06c10956025d4a932852ea6e5d02ff7808fc395f` artifact on
[run 45172042529](https://github.com/pj4533/Liminal/actions/runs/45172042529).

| Metric | Before | After |
|---|---:|---:|
| Reverse events | 108 | 285 |
| Reverse same-position recurrence | 1.000000 | 0 |
| Rest recurrence | 0.955122 | 0.911590 |
| Quiet-grid recurrence | 0.817688 | 0.733457 |
| Roll recurrence | 0.275862 | 0 |
| Stutter recurrence | 0.214286 | 0 |
| Consecutive grid Jaccard | 0.121956 | 0.064830 |
| Next-move prediction accuracy | 0.871310 | 0.791393 |
| Within-loop hook recurrence | 0.986111 | 0.969033 |

After values are from [run 45218799677](https://github.com/pj4533/Liminal/actions/runs/45218799677)
at production revision `fc4f3913a4b2a68160aa9db858140bcaa207f2cf`. All **18/18** comparisons pass:
108 loops, 72 consecutive pairs, all 72 changing source lines. In the chop-beat-only scope, reverse
count is 0→26, grid Jaccard .090208→.067177, rest recurrence .918789→.891614, quiet recurrence
.640732→.623636 and next-move prediction .933054→.841202. Reverse/roll/stutter same-position
recurrence is zero. The artifact retains exact raw records; the local comparison is
`/app/state/liminal-verification/run45218799677/feel-report-vs-06c1095.json`.

That run passed 14 tests in two whole suites with independent execution coverage 14/14.
The preceding [run 45214973934](https://github.com/pj4533/Liminal/actions/runs/45214973934)
at `e452a83` passed 44 tests across ChopFeel, ChopVariety, FeelMetrics and Motif (coverage 44/44),
including every backbeat, arc, density, recurrence and atomic-figure assertion in those suites.
The consolidated full suite, new long-word pocket regression, mix and authentic-media gates still
require their final run. Paired rendered-audio timing/headroom evidence is recorded below.
Hosted verification is unsigned only through command-line `CODE_SIGNING_ALLOWED=NO`; project
signing settings are unchanged. New source/test files join Xcode's synchronized groups automatically.

Local commands: `python3 scripts/test_dialogue_feel_report.py` (4 passed),
`python3 scripts/test_dialogue_salience_report.py` (8 passed), `git diff --check` (passed).

No scanner enabled, image/catalog/criteria files changed, app installed, Vision Pro build deployed,
private samples added, or real-film mix/listening gates claimed. The real cache probe, strict mix
matrix, app run and short audition clips remain separate acceptance work.

## Regression diagnosis

The 23 November hosted regression run at `da23b73` exposed two faults: translating an entire
chop cell moved responses off their backbeats, and a spelling turnaround in only the second
pass disabled translation for that pass alone. Fill movement now preserves every skeleton
hit and translates only a shared nonstructural hit when both neighbours retain enough room.
Reverse pickups no longer target a cell's far boundary, where their dry tail could block the
next cell's first consonant. The original density, recurrence and backbeat gates remain.

The same run found a resampled pad whose independently measured attack was 66.8 ms late.
The regression records the stored and newly detected offsets to distinguish rejected onset
remeasurement from selection of the wrong syllable peak. `Dialogue regression diagnosis`
runs the musical, word-integrity and timing suites plus the unchanged measurement harness
on `verify/chop-fix/**`; its artifacts preserve failures as well as successes.

Run `45179434556` confirmed that the original source anchor was 8.08 ms while the resampled
pad's measured attack was 74.96 ms: the old +20 ms native correction bound rejected the
measurement. Linked-rate pads now use their rendered attack; native pads retain their prior
bound. No PCM, word boundaries or acceptance thresholds are changed. Independent audible-lead
and attack tests are still required, including their 84 BPM case.

The build's backward moves now require room after bar 7's last word, and a breakdown pickup
replaces one whole word in its bar rather than increasing the sparse section's density. One
shared nonstructural fill can take a filtered colour in both hook passes; its skeleton, source
order and spelling are preserved. The next diagnosis run records every outlying attack and
any missing backbeat's complete arrangement/events to expose remaining source failures.

The final regression pass reserves complete spelling fill sites after ordinary fill selection: the
old requirement for three existing adjacent slots could never coexist with the groove's run limit.
Arrangements now use the measured rendered accents when calculating whole-word clearance. The
random-input safety test retains its protected-anchor requirement and checks bounded shared linked
rates and exact pad durations for motif banks; the grammar fallback still requires a native anchor.
These historical changes subsequently received focused/broad execution described above; final full-suite and authentic acceptance remain incomplete. No acceptance threshold was changed.

Raw fixture evidence at `56fc6f5` also shows the same hook pickup playing in only one pass, with the
following call disappearing in that pass. Pickup clearance now checks output-time intervals on
both sides, includes the preceding cell, and requires space in both repetitions. It cannot trade
a hook word for an optional reverse; sparse breakdown replacements still trade exactly one word.

## Retained-opening and headroom evidence, 23 November

Run `45203560241` at `df2dc896b5e58b4a4ca6446f33bfb1229e65d130` passed all 11 tests
in the complete ChopFeel and Tightness suites, with independent execution coverage 11/11.
At 62/72/84 BPM the independent rendered-attack p95 was 4.0/9.5/10.3 ms, with zero pieces
more than 35 ms early and zero measured non-weak attacks beyond 12 ms. The identical native
and linked-rate inventories each contained 104 pads, with zero attacks beyond 35 ms.

The remaining early attacks were retained quiet syllables followed by a louder syllable that
linked playback brought inside the detector's 300 ms peak window. The correction lifts existing
opening audio by at most 9 dB, eases out over 55 ms and never moves or deletes samples. It is
bounded, not a guarantee that every arbitrarily weak opening can be made the strongest attack.
A second shoulder could previously lower a high transient near the taper's end; the correction
now accepts only a positive amplitude change. A parameterized high-crest test exercises both
polarities throughout the taper and checks sign, gain, length, clipping and unchanged body.

The same run compared 56 distinct full renders with the correction enabled/disabled. Six changed:
RMS increases were 0.025–0.562 dB and K-weighted energy increases 0.040–1.169 dB. Four peaks were
unchanged; two rose from 0.6837 to 0.8126 and 0.7348 to 0.8145. All corrected peaks were below
0.857, samples were finite, and audio after 200 ms was bit-identical. Raw paired values are in
`opening-correction-headroom.txt`. This corpus is synthesized speech-like audio; these results
do not establish authentic-speech intelligibility, integrated-mix acceptance or listening approval.

At that point, broad regression and the 18 before/after feel metrics remained open. The preceding
`ea61e5f` run removed backbeat and breakdown-opening failures but retained two sparse arrangements
(transcript-72, seeds 5 and 8, loop 1: 27 onsets over 16 bars) and three chop-beat metric failures.
Its pre-correction onset failures are superseded by the focused evidence above; newer broad
results subsequently established the arrangement and metric gates described above. No threshold was relaxed.

## Fresh whole-word pockets

The `e1ac382` and `186ccdd` candidates passed the arrangement tests but retained three chop-beat
comparison failures. Their acoustic-72 fixture repeated occupied shapes (grid .167947→.206632,
quiet .750290→.776390), while transcript-72 rest recurrence rose .935096→.950081. Both fixtures
had slightly more onsets than baseline. Moving more existing fills did not change these metrics:
long words had already reserved their neighbours, leaving no legal two-step shift.

The groove picker now receives the previous hook's occupied accent positions before choosing
optional fills. It prefers a fresh usable pocket, retains its seeded drum score and all existing
word-fit, breath and density rules, and never trades an available off-drum pocket for a kick/snare
collision to obtain novelty. The subsequent move pool keeps an already-fresh pocket. Skeleton
calls/answers stay authored; both passes share the result; complete spelling figures remain atomic.
This change produced the passing comparison above without changing any metric or threshold.
Regressions cover competing fills, multiple independent pockets, deterministic history selection,
full-buffer clearance and complete late-figure rollback. The added long-word fixture separately
checks a legal new word/pocket when either shift of the old longer word would collide.
