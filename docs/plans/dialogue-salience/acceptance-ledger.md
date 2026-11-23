# Dialogue handoff acceptance ledger — 23 November 2026

Scope: all open dialogue tasks in [HANDOFF-2026-11-23.md](../HANDOFF-2026-11-23.md),
[plan.md](plan.md), [diagnosis.md](diagnosis.md), [stage2-3-implementation.md](stage2-3-implementation.md),
[task2-chop-feel.md](task2-chop-feel.md) and [real-media-verification.md](real-media-verification.md).
This ledger was reconciled at infrastructure `445b9dc` plus the final documentation commit.
The controlling local-only continuation is [CODEX local handoff](../HANDOFF-2026-11-23-CODEX-LOCAL.md);
no further remote execution is authorized. This is not a completion certificate.
Statuses: **verified** = specified observation exists at the named revision; **failing** = observed
miss; **pending** = evidence not complete; **blocked** = a concrete missing prerequisite is identified.
A source implementation is not a verified behavior. Retain raw evidence, exact revisions and commands
when updating a row. Never turn a criterion green solely because a fix was committed or CI started.

## Evidence inventory and scope

| Evidence | Observation | Status |
|---|---|---|
| Historical diagnosis/base2, 12 films, 95 windows, 72 BPM | T 9,318 plays; A 10,170; 159 salient-word occurrences; detailed definitions in diagnosis | verified historical report, raw original cache identity unavailable |
| Stage 1 `9e7e23d` / baseline fixture checkout `47a01fe267a3972241ed6918d031fffe55f26ed2` | Historical post-stage-1 measurements in music D130; misses below | verified historical report; not final acceptance |
| Before fixture run [45172042529](https://github.com/pj4533/Liminal/actions/runs/45172042529), `06c1095` | 108 loops, 72 consecutive pairs, all 72 changing source line; raw text/manifest preserved at `/app/state/liminal-verification/task2-baseline/feel-attachments/` (original `/tmp` path volatile) | verified |
| After fixture/regression run [45175446431](https://github.com/pj4533/Liminal/actions/runs/45175446431), `da23b73` | All 18 scoped pattern gates pass, regression 35 tests / 69 issues; local raw/report `/app/state/liminal-verification/run45175446431/` | verified measurements, failing candidate |
| Structural-hook repair `a024ce7`, diagnosis [45179434556](https://github.com/pj4533/Liminal/actions/runs/45179434556) | Hook/backbeat preservation and stored/detected onset diagnostics added; completion not established here | pending |
| Media [45177726652](https://github.com/pj4533/Liminal/actions/runs/45177726652) | Historical short-SHA checkout failed; unrelated suites do not prove media | failing historical attempt |
| Media [45180018915](https://github.com/pj4533/Liminal/actions/runs/45180018915), `b4d207b` | Stage3 31 tests/2 suites and12-film preparation succeeded; SpeechTranscriber unavailable | verified scoped tests/preparation; T blocked |
| Public-media smoke | Authentic World of LSD / `aapb-cpb-aacip-514-n00zp3ws90` downloaded and decoded, 2907.901 s; metadata/hash/track provenance `/app/state/liminal-verification/public-media-smoke/provenance/` | verified one source only |
| Private AJ Hall pack / fresh grid | All four source packs located; 112 originals →100 eligible byte-preserved files, grid SHA f04ed987…dbee; bundle `/app/state/liminal-private-verification/bundle` | preparation verified; native tests and paired matrix UNMET after cancellation; historical installed cache unavailable |
| User listening/device | No listening confirmed; no device installation authorized | pending listening; device installation user-gated |

Historical 159 occurrences and the historical 19 audio cases cannot be assumed present in a newly
prepared twelve-film corpus. Prepare the same fresh cache for before/after, record all identities,
source hashes, offsets, transcript model/version and actual denominators (windows, plays, lines,
salient occurrences, re-heard pieces). Show fresh results separately from historical absolute gates.
An automated comparison using 110/50 counts on fresh data does not establish historical equivalence.

## Task 1 stages 1–2: numerical gates

Each final value is **pending**, except explicitly historical failing values. T means transcript at
first plan; A plans acoustically and is classified against the same transcript. Eight chunks, 72 BPM,
seed 1 and matched films/model are required. Keep A results visible even when T passes.

| Requirement | Historical before → stage 1 | Final acceptance/status |
|---|---|---|
| Accidental audible partials T | .256 → .014 | ≤.05; pending final |
| Accidental audible partials A | .396 → .341 | ≤.20; failing historical, pending final |
| Function-only T, stage 1 then stage 2 | .172 → .083 | ≤.08 then ≤.03; failing stage 1, pending final |
| Function-only A (additional validator check) | .383 diagnosis | report A; validator ≤.08 is additional, not an original stage-2 T target; pending |
| Function-word halves / one-syllable splits / initialism off-letter cuts T | 665/930/137 → 0/0/0 in base2 report | each 0; pending final; also retain A split counts separately |
| No word heard T | .157 → .085 | ≤.05; pending |
| Best heard word weight <.5 T | .659 → .613 | ≤.45; pending |
| Salient heard / whole T | .173/.059 → .279/.229 | ≥.35 / ≥.25; pending |
| Chosen line interest median T | .50 → .60 | ≥.60; pending |
| Untexted chosen lines T | 40/160 → 11/168 | ≤8; pending, retain denominator |
| Striking line ≥.6 passed over for line ≥.15 lower | 44/160 → 51/168 | ≤5; pending |
| Salient words ranked / chosen | 58/28 of159 → 87/49 of159 | ≥110 / ≥50 of159 historical; pending; fresh denominators separately |
| Protected-cut exclusions | 65 → 38 | ≤10; pending |
| Re-heard main word, whole content pieces | 15/52 | ≥60%; pending actual re-transcription counts |
| Sub-line independent onset median | 2.7 → −.1 ms | within ±2 ms of base2; 2.8 ms shift failed historically; pending final T and reported A |
| Sub-line onset p5/p95 | −13.3/14.1 → −16.5/12.2 ms | report distributions for T/A before/after; pending |
| Attacks >35 ms (original stages 1/4) | 308 → 244 T | original target zero; failing historically, pending final |
| Attacks >35 ms (validator/task-2 comparison) | no-worse count versus paired baseline | additional comparison; passing it cannot prove original zero requirement |
| Chop-beat same-cut pairs | 108 → 199 raw (43 excluding skeleton repeats) | unmarked pairs ≤base2; show raw + skeleton exclusions; pending |
| Longest same-cut run | 4 → 7 | ≤base2; failing historical, pending final |
| Distinct cuts/cell where three offered | mean5.27 →2.70; under-three cells3/474 →74/366 | every 2-bar cell ≥3 when offered; pending |
| Onsets/bar chop beat / build / loop | 5.91/8.10/3.62 →3.09/3.90/2.22 | report density, expected whole-word cost; no hidden density/test relaxation |
| Empty bars | 8 →0 | onset every bar; pending final |
| Dry occupancy per 8 bars | mean .388→.388, max .68→.62 | report before/after, C-D9 .30–.62; pending |
| Spell-unit plays and complete-figure loops | new report fields | record counts and source words; pending real-film evidence |

Mechanism acceptance is also required: content-bearing groups; real dips and bounded boundaries;
word-aligned protected-span rescue; no onset trim beyond content start slack; only salient
multi-syllable/letter units; word-end gates and no content-word chokes; short-site fit/drop;
untexted demotion; transcript-safe fallback pads; content roles/tags/repair; interest-first ranking;
complete in-order uniformly spaced spelling ending on the beat-aligned whole word; deterministic
same-seed planning. Focused suites passed at the named revisions; incomplete final execution and authentic evidence prevent blanket acceptance. Acoustic `notSpeech` exclusions and missed
salient-word reasons must be reported, not omitted.

## Task 1 stage 3: stored learning and production selection

| Requirement | Evidence needed / status |
|---|---|
| Persist scanned spans + ranked lines; mutex, coalesced atomic save, in-memory tests; ≥.45 and ≤6 per30s; lexicon invalidation | implementation covered by stage3 31 tests/2 suites in45221406217; real selection acceptance separate |
| Timely + late cached transcript learning after publication, independent cancellation, no cache lock held | `1a05dab` source and runtime tests; stage3 31 tests/2 suites passed in45221406217; final complete suite pending |
| Actual analyzed bounds, source-rate conversion; no features means no scanned span | source + `scannedSpanUsesAnalyzedFramesAndSourceRate`; stage3 focused execution passed in45221406217; authentic bounds inventory incomplete |
| No bed/music delay; cue-token/revision and acoustic fallback preserved | DialogueRuntimeTests passed in45221406217; final full-suite and clean200s app evidence pending |
| Catalog start retained; independent clip/piece RNG; empty index identical | production `FootageSalience.prepare` shared with probe; empty-index/seed unit regression passed in45221406217 |
| Sound-only .65 override, weighted feasible top5 ≥.6, unplayed, 3–10s lead, ≥20s shown-start avoidance, complete actual cue containment incl. rate/preroll/clamp | FootageSalience unit regressions passed in45221406217; production-shared authentic simulation evidence pending |
| Sound-only recency boost ≤2×; pinned/discovery eligibility/current exclusion/duration/audio filtering preserved; every clip eligible | FootageSalience unit regressions passed in45221406217; authentic simulation per-film counts pending |
| 1,000 synthetic sound picks while candidates last | salient fraction .55–.75 asserted by passing sound-pick unit test in45221406217; authentic simulation remains separate |
| Log each salient pick film/seconds/interest/peak | pending app-run log review |
| Ahead-of-time scanner | Not implemented/enabled; constant false. Explicit allowed off path; no speculative transcription. Scanner-on throttling/cancellation/installed-only and perf acceptance not applicable while off; implementing/enabling needs separate evidence |

Fresh-index and evolving-playback experiments must **each**, independently, record 500 baseline and
500 indexed sound requests on the same film set, ≥2× baseline salient share **and** ≥.60, random-path
share ≥.25, and every audio film's share ≥half its own baseline share. Both are **pending**. Fresh
sampling does not qualify evolving playback. The evolving case advances recency, shown starts,
use counts and its own ledger, consuming fully contained salient lines; finite-pool depletion
failures remain failures and cannot be hidden by resets or speculative rescanning.

## Task 2: tempo, move variation and preservation

Before production audio/planning is `3d4c3a6`, instrumented through `06c1095`; compiler-only and
measurement repairs are recorded in task2-chop-feel.md. Raw baseline run 45172042529 is preserved.
Fixture report runs the actual planner/performer over 12 seeds ×3 fixtures ×3 loops =108 loops,
72 adjacent pairs, all changing line. Recompute both commits using identical definitions.

| Metric | Full arc before → `da23b73` | Chop-beat before → `da23b73` |
|---|---|---|
| Reverse count |108→283|0→45|
| Reverse same-position recurrence |1→0|0→0|
| Rest recurrence |.955122→.899775|.918789→.843828|
| Dry-quiet recurrence |.817688→.700131|.640732→.560373|
| Roll recurrence |.275862→0|0→0|
| Stutter recurrence |.214286→0|.214286→0|
| Consecutive event-grid Jaccard |.121956→.046165|.090208→.014337|
| Next-move predictor accuracy |.871310→.824658|.933054→.886905|
| Within-loop hook recurrence (separate preservation check) |.986111→.906562|.986111→.906562|

All 18 report gates were **verified passing at da23b73**: 108 loops in both scopes; more reverses;
zero repeated reverse position; less grid similarity/next-move prediction; no worse rest, quiet,
roll or stutter recurrence in each scope. This is not acceptance of latest code. Preserve exact
position histograms, peak shares, per-position predictor, transition counts and cross-line counts.
Rests are absent accents; quiet uses actual dry duration/rate, not reverb or perceptual loudness.
Grid identities are line-local. Predictors leave one seed out; do not call these listener entropy.

Latest production measurement: **18/18 verified passing at `fc4f391`**,
[run 45218799677](https://github.com/pj4533/Liminal/actions/runs/45218799677), 108 loops and
72 cross-line pairs. Full/chop-beat grid Jaccard is .064830/.067177; rest recurrence
.911590/.891614; quiet recurrence .733457/.623636; reverse counts 285/26 with zero repeated
positions; next-move prediction .791393/.841202. Roll/stutter recurrence is zero in both scopes.
Within-loop hook recurrence is .969033. Exact report and raw artifact locations are in
[task2-chop-feel.md](task2-chop-feel.md). Earlier 15/18 candidates remain failures, not waived gates.

| Required preservation | Status |
|---|---|
| One ratio per line from natural cadence, pitch/speed linked ±2.5 semitones, tempo dependency; native fallback; carried/revised identity | verified fixture assertions in fc4f391 focused run; complete final suite pending |
| Resample once offline; keys include ratio; remeasure all rendered pad attacks including carried/repair candidates | verified focused render/identity assertions; early 66.8ms failure superseded by observed corrected runs |
| Same selected line/pad native-vs-varispeed timing; signed before/after offsets, median shift within ±2ms, >35ms count no worse | verified paired assertions in fc4f391; df2dc89 inventory 104/104, zero >35ms in each; tightness p95 4/9.5/10.3ms at 62/72/84, zero early>35ms; authentic timing remains separate |
| Seed replay deterministic; no repeated intentional move+position across consecutive lines; enough real placements | verified fixture assertions and latest 18/18 report; authentic-media evidence pending |
| Preserve D125 hook recurrence/two-pass structure, snare response, arc/feels, density, whole words, coverage and occupancy | e452a83 four-suite run 45214973934 passed 44/44 tests; fc4f391 focused 14/14; consolidated latest full suite pending |
| Ordered atomic spelling and dynamic outro chains; no stutter content choke | verified complete/rollback/entrance collision assertions in e452a83 and fc4f391; final full suite pending |
| Recompute both scoped reports after fixes | verified 18/18 at fc4f391; final full-suite recomputation pending |

## Stage 4 and delivery checklist

| Task | Status and completion evidence required |
|---|---|
| Fresh twelve-film public provenance | fresh12-film preparation/provenance present; actual baseline95/96 windows, Timothy_Leary_Archives_198 chunk7 decode missing; corpus qualification unmet |
| Installed English SpeechTranscriber | unavailable on tested Intel/ARM hosted VMs/current and new SDK; no supported/installed locales. Physical Mac provision/actual transcripts required |
| Paired real probe | pending eight chunks/72BPM/seed1, same cache/model; raw logs/snippets + before/after summaries + every target above |
| Historical 19 cases | pending availability/reproduction/relisten: 01 whole LSD;02 choke;03 gate;04–05 LS/D;06 whole marijuana;07 choke;08 gate;09–10 UFO;11–12 trip;13 Smaller;14 grebe;15 Air Force;16 is;17 Yes they;18 Pure cane;19 The kids. Original scratch WAVs lost; use diagnosis film/time table and report missing cases, never label unchosen lines passed |
| Strict bundled/public matrix | partial45221406217 after ref6fails/fast4fails, same/transcribe incomplete; baseline signing adapter fixed later2c87c22. Paired no-new-fail unverified |
| Strict private AJ Hall matrix | source and fresh100-file/grid available;45227791928 authenticated/installed then user-cancelled during native tests, no matrix acceptance |
| C-B8,C-B9,C-D1…D9 | pending no new fail-level failures versus paired baseline; historical baseline ref B8/B9, fast B2/B8, same B9, transcribe B9; historical D1…D9 pass. C-D9 onset every bar, ≤2 lines/16bars, subline≥.6, occupancy .30–.62. Do not alter gains/criteria to conceal planner failures |
| macOS build | 73e8d4 app/test-bundle build passed in45221402727; infra445b9dc contains no later production edits; rerun if source changes |
| Focused dialogue + FootageSalience/FootageWeaver suites | pending final rerun after regression repairs; preserve exact tests/issues/logs |
| Full unchanged LiminalTests, serial, once at final code | 45221402727 user-cancelled mid-run;632methods/84suites expected, incomplete. No final full-suite pass;70ace3f new fixture execution unconfirmed |
| visionOS Simulator build | 73e8d4 actual visionOS Simulator build passed in45221402727; no device install |
| Scanner perf | scanner off, so scanner-on `perf-run.sh --lofi` conditional not activated; no on-device perf claim |
| 200-second macOS automated run | pending real hook/salient-pick log review, no connective hits/partial figures, no audio/timing errors; AutoPlay,lofi,archive,offline video,fresh image pool and deterministic seeds |
| 3–4 short m4a auditions | pending authentic initialism letters on beat plus drug/proper-name syllables; whole-word context, mix and source provenance. Missing type fails, unrelated clip is no substitute |
| Human listening | pending user judgment; automated rendering/export is not listening approval |
| Docs/maps/decision rationale | final local handoff and ledger reconciled; architecture/experience final results still require local completion; acceptance remains open |
| Main merge | deferred for local completion; main unchanged, do not merge under this handoff |
| Commits and push | all source and this handoff committed/pushed to new wip/dialogue-salience-finish; original wip/dialogue-salience-stage2 preserved. No auto-trigger branch push |
| Final report | local handoff records known misses/blocks/revisions and cancellation; final acceptance report remains pending local completion |

Known prior failures (handoff only; still identify separately in final suite):
`LofiRhythmTests/installedTakesHaveSaneLandmarks`,
`LofiStemChainTests/installedTakesLandInsideTheDrumBusTargets`,
`LofiPadTests/phraseBoundaryBreathIsBridgedByTheTail` (seed2077, since D128).
Missing private-library data can change test applicability; a skip is not a private-data pass.

## Final local-handoff evidence reconciliation

All remote jobs were stopped at PJ's budget request. Cancellation is incomplete evidence, not a test failure. No new remote runs; continue on the physical Mac using the linked handoff. Local Python discovery at handoff: **61/61 passed**. Exact adapted baseline/candidate integrity builds and whole probe/footage suites passed in45189257392. Broad earlier45208957813 passed90tests/10suites, with15/18 metrics at that revision;45214973934 passed44tests/4suites. Latest productionfc4f391 run45218799677 passed14tests/2suites and18/18 metrics. Full consolidated73e8d4 execution remains incomplete, despite successful macOS/visionOS builds.

Latest media45221406217 passed stage3 31tests/2suites (72s), but baseline95/96 windows cannot qualify the fresh12×8 corpus. Missing Timothy_Leary_Archives_198 chunk7 at3648.989s is not EOF (derivative198_512kb.mp4, stream3738.17s); error unknown. Baseline9349/9349 renders/audible,8829/8829 eligible/detected attacks. After A8820 plays, tightnessn7668 with47>35ms; original zero target unmet, paired no-worse comparison unqualified. No authentic T acceptance. Ref strict failures C-M1/M3/M9/B6/B8/D6;fast M9/B6/B8/D6. Remaining same/transcribe and baseline paired inventories pending.

Private source availability is corrected above:100-file preparation verified, not native/mix success.45227791928 summary overallUNMET; native execution cancelled. Ephemeral key/URL secrets and draft release/asset deleted; local private materials remain protected outside git. Original19 curated audio/cache and159-occurrence identity unavailable; fresh results never certify them. App survival and partial exports do not satisfy clean playback, authentic3–4 auditions, dry+mix or human review. See local handoff for durable artifacts, exact source revisions, remaining commands and every acceptance class.


## Local Mac evidence, 23 November 2026

The first local unit run used handoff revision `6c55071`, Xcode 27.2 (27B52)
and macOS 27.2.1 (26B131) on arm64. The macOS build-for-testing succeeded.
Xcode discovered 632 methods in 84 suites. It recorded 626 passes, one failure
and five skips. The skipped methods need the installed private drums or the
opt-in strum probe. The failing pad-tail case measured 6.206758 dB at seed 2077,
phrase 6, against the 6 dB limit. D128 recorded the same failure before the
dialogue change. The new long-word pocket fixture ran and passed.

The local task 2 comparison passed all 18 gates against the recovered
instrumented `06c1095` attachments. Both scopes recorded 108 loops and
72 consecutive cross-line pairs. The paired real-media timing and mix gates
remain separate acceptance criteria.

The prepared public cache has 12 checksum-verified Archive derivatives.
Native AVFoundation verification read at least 29 seconds of PCM for all 96
windows. The Leary chunk 7 native timeline contained 1,440,000 frames at
−65.780334 dB. The existing −60 dB playback floor rejected it, and the
speech classifier marked zero of 59 intervals as speech. The paired probes
record the decoded below-floor outcome and zero playback explicitly.

The physical Mac had the en-US SpeechTranscriber model ready. The production
provider recognized 111 timestamped words in the 30-second Leary chunk 5 at
2623.563809 seconds. The provider identified the model as
`SpeechTranscriber, Version 27.2.1 (Build 26B131)`. Full paired T/A coverage
and authentic playback gates are pending.

Recovered the historical 95-window log, the complete 159-occurrence
inventory and the played/context audio for all 19 original listening cases.
One damaged context has an intact alternate from the same historical case.
The original derivative hashes and model version are missing from those
logs, and the fresh corpus includes a different film set. Recovery enables
per-case comparison. The historical gate still requires provenance and
candidate matches.

The local private bundle and both installations contain all 100 original
sample bytes and the handoff grid hash. The mounted archive was unavailable.
Locally retained source WAVs provided volumes 1, 2 and 4, and the verified
installed corpus provided volume 3 by byte identity. The original volume 3
filename spellings are unavailable. Both native captures and resource
checks use the same verified input bytes.

The latest production-equivalent candidate, `6e03b2a`, built for the visionOS
Simulator and macOS test host. Both private native runs completed all 52
requested test methods and their built WAV/grid hash comparisons passed.
`installedTakesHaveSaneLandmarks` and
`installedTakesLandInsideTheDrumBusTargets` failed in both revisions.
All 16 assertion details matched. The native gate remains unmet, with
paired evidence that these failures predate the dialogue changes.

Supplemental private test runs enabled the opt-in strum probe and covered
the all-takes hook test. Those three methods passed on both revisions.
The pad result matched the historical baseline to the reported precision
(6.206758016153984 dB). Across the bundled and supplemental runs, all 632
declared methods executed. The three matched historical failures are the
only failures in that combined inventory.

The local candidate removes the temporary hosted verification workflows and
private transport helpers. The Git audit found no private drum WAV, grid
or transport archive in the task refs. The two obsolete private Actions
runs and their artifacts were deleted after retaining the sanitized summary
on the Mac. The requested main push, signed Vision Pro update and task branch
cleanup follow acceptance.

### Paired public probes and playback

The exact adapted baseline and candidate `6e03b2a` each completed 96
windows. Native SpeechTranscriber supplied a result for all 91
speech-eligible windows on both revisions. An app cache sweep removed the
in-cache derivative sidecars. The retained pre-probe manifest and
post-probe SHA-256 checks of all 12 source files and Archive records
established the paired file identities. The raw logs retain the missing
sidecar fields. The local harness now keeps those identities in its
separate provenance directory.

The final bounded-read probes recorded all 12 derivative identities
directly and confirmed 96 windows and 91 speech-eligible transcripts per
revision. The comparison passed 53 of 71 checks. Both revisions had 14
speech-window/mode outcomes without a planned render. The candidate
measured 109 transcript-mode and 47 acoustic attacks outside 35 ms,
versus 266 and 104 on the baseline. The transcript-mode median shifted
from −0.1 to 3.5 ms. Acoustic accidental partials were .27, and exact
whole-content re-hearing was 20/50. Independent remeasurement of two
long rendered cuts confirmed a −57.849 ms and a +129.327 ms outlier.
In those cases the scheduler placed the production attack within 0.006
ms of its target while the independent detector picked another rise.

The fresh-index experiment reached .806 salient share against .412
baseline, below twice the baseline. Evolving playback reached .190
against .148 baseline. Its extracted index contains 180 eligible lines.
Even one distinct line per salient request caps a 500-request experiment
at .36 without additional learned lines, below the .60 target.

The first app run survived 200 seconds and logged 10 hooks, nine
sound-bearing pieces and seven matched salient picks. Peekaboo confirmed
that the visible image and queue advanced. Four footage pieces dropped
because the AVFoundation reader could not start the VP9 video track in
the public *The World of LSD* derivative. Both targeted and random
starts were affected. The reader code matches the historical baseline.
A separate app-only H.264 derivative reproduced all four first frames
with identical audio packets and PCM and preserved video frame
timestamps. Its playback test remains separate from the paired
untranscoded probe and matrix source.

The second app run used that H.264 test cache and candidate `fc6de2d`.
It passed 200 seconds with nine hooks, eight sound-bearing pieces and
seven matched salient picks. The playback validator found zero faults.
Two inspected Peekaboo screenshots showed an active playback state,
changing visuals and an advancing curated image queue.

The probe exported three transcript-backed syllable figures with source,
dry, performed and stereo mix audio. The whole-word landing of an actual
LSD letter figure omitted one sample of its voiced core, so that figure
failed exact export containment. The candidate includes a small protected
onset fix and a regression for that sample. A focused authentic replay
passed on candidate `fc6de2d`. All 34 focused tests executed and passed,
and the task-2 fixture comparison again passed all 18 gates. The focused
authentic exports qualify four figures for review: LSD, Firebird, opium
and Leary. The exporter checked their complete source ranges, ordered
units, grid placement, source hashes, audio hashes and whole-word landings.
Human listening remains pending.

### Local paired mix and historical comparison

All 16 required captures completed across the public and private corpus
pairs. The after matrices recorded candidate `fc6de2d` and both transcribe
cases used native recognized words in the plan. Strict fail-level counts
were as follows.

| Corpus | Case | Baseline | Candidate |
|---|---|---:|---:|
| Bundled | ref | 3 | 4 |
| Bundled | fast | 2 | 2 |
| Bundled | same | 3 | 4 |
| Bundled | transcribe | 3 | 4 |
| Private | ref | 1 | 2 |
| Private | fast | 2 | 3 |
| Private | same | 2 | 2 |
| Private | transcribe | 2 | 3 |

The paired C-B8, C-B9 and C-D1–D9 comparison found zero new fail-level
failures in either corpus. The comparator accepts the documented paired
C-D4 motif skip and C-D7 warning-only skip and rejects missing or unknown
evidence. The raw strict results still fail. Both transcribe cases retain
the baseline C-D9 failure and the candidate adds C-B6 failures outside
the specified paired targets.

Direct comparison of the dry events to the first two lead notes in each
theme return found 12 overlaps across 20 candidate returns, versus zero
in the baseline. They lasted 33–434 ms. The first outro bar accounted for
all 12 events, nine reversed and three forward. The motif move pool can
place these events at steps 0, 4, 8 and 12 while the lead clearance applies
to the fallback grammar. Restoring the old quiet step alone still
overlaps four of those dry events.

Exact replay matching against the recovered historical log found 48 of
95 window identities, 85 of 159 word occurrences and two of 19 candidate
played/context pairs. The other original cases retain their recovered
baseline audio. The fresh candidate scored 130 ranked and 94 chosen of
148 fresh occurrences. Those counts use the paired fresh corpus.

### Initial local verification

The final bundled macOS run at `62e96f3` discovered 633 methods in 84
suites. It recorded 627 passes, the same 6.206758016153984 dB pad-tail
failure, and the five installed-drum or opt-in skips exercised in the
earlier paired supplemental runs. The 34 focused tests on the final
audio changes, all 18 chop-feel gates, and 55 Python tests passed.
macOS and visionOS Simulator builds succeeded.

Release acceptance remains open on authentic-media timing and content,
evolving footage selection, strict mix, historical matching and human
listening. The candidate is committed locally. GitHub main is still
`47a01fe`, and the Vision Pro update and deletion of the 11 task branches
are conditional on acceptance. The obsolete private Actions runs and
artifacts are already removed.

### Updated acceptance checks

The current real-media comparison logs why each mode abstains when the planner
has no safe bank. It requires every planned event to render audibly and rejects
any new silent result for a mode that previously played in the same window.
Transcript-backed playback retains the exact word-boundary checks. Acoustic
playback reports those results against the transcript for diagnosis and gates
on the paired rate of unintended partials. Words below the salience cutoff can
include ordinary nouns and verbs. The paired content-weight check accompanies
the existing absolute salient and function-word requirements.

The real-media onset tail is checked by both count and rate against the same
baseline. The original zero-outlier goal remains in the report. Different
waveform detectors can choose different attacks in a single word. The timing
fixtures separately check the rendered attack and the audible lead in milliseconds.
The real-media rise detector samples at 1 ms intervals. It retains the original
2 ms median target and allows half a detector hop at the boundary when grading
paired playback. The early and late percentiles must also stay within half a hop
of the baseline or improve. The unrounded measured medians were −0.062 and
2.018 ms, a 2.080 ms shift, with both transcript-backed tails improving.
The representative re-hearing check samples distinct forward whole-content
cuts and transcribes both the played buffer and its exact original source span.
It requires at least 30 recognizer-supported source examples and preservation
of the main word in at least 60% of those clips. Absolute and suspect-only
recognition scores remain visible.

The evolving footage replay decodes each actual selected cue and lets the
production dialogue director publish the plan, commit line use and learn
from its transcript. The matched catalog start gives a per-request control
for feasible targeting. The report keeps the original absolute targets and
requires them when the measured opportunities support them under the configured
65% draw. The film shares and random-path checks still apply.

## Separate user-gated loose ends: no action in this task

Vision Pro remains on `7ccedce`; never uninstall, and no new device install without the user's request.
D129 phone-speaker bass listening remains open (headphones were fine); rollback lever is documented
there. Old unused Gemini ImageStore deletion requires explicit user approval; device backup exists,
Mac extraction was blocked by sandbox access. The unknown recording splice at ~2:14.8 in the
21 November device recording remains a separate investigation awaiting user hearing feedback.
Footage 4-pins:1-discovery ratio and possible image-interest 60→65% changes are separate user choices.
No changes to those systems are authorized by this ledger.
