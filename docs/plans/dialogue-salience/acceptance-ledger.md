# Dialogue handoff acceptance ledger — 23 November 2026

Scope: all open dialogue tasks in [HANDOFF-2026-11-23.md](../HANDOFF-2026-11-23.md),
[plan.md](plan.md), [diagnosis.md](diagnosis.md), [stage2-3-implementation.md](stage2-3-implementation.md),
[task2-chop-feel.md](task2-chop-feel.md) and [real-media-verification.md](real-media-verification.md).
This is an evidence snapshot at `b4d207b` plus documentation changes, not a completion certificate.
Statuses: **verified** = specified observation exists at the named revision; **failing** = observed
miss; **pending** = evidence not complete; **blocked** = a concrete missing prerequisite is identified.
A source implementation is not a verified behavior. Retain raw evidence, exact revisions and commands
when updating a row. Never turn a criterion green solely because a fix was committed or CI started.

## Evidence inventory and scope

| Evidence | Observation | Status |
|---|---|---|
| Historical diagnosis/base2, 12 films, 95 windows, 72 BPM | T 9,318 plays; A 10,170; 159 salient-word occurrences; detailed definitions in diagnosis | verified historical report, raw original cache identity unavailable |
| Stage 1 `9e7e23d` / baseline fixture checkout `47a01fe267a3972241ed6918d031fffe55f26ed2` | Historical post-stage-1 measurements in music D130; misses below | verified historical report; not final acceptance |
| Before fixture run [45172042529](https://github.com/pj4533/Liminal/actions/runs/45172042529), `06c1095` | 108 loops, 72 consecutive pairs, all 72 changing source line; raw `/tmp/liminal-feel-before/feel-attachments/` | verified |
| After fixture/regression run [45175446431](https://github.com/pj4533/Liminal/actions/runs/45175446431), `da23b73` | All 18 scoped pattern gates pass, regression 35 tests / 69 issues; local raw/report `/app/state/liminal-verification/run45175446431/` | verified measurements, failing candidate |
| Structural-hook repair `a024ce7`, diagnosis [45179434556](https://github.com/pj4533/Liminal/actions/runs/45179434556) | Hook/backbeat preservation and stored/detected onset diagnostics added; completion not established here | pending |
| Media [45177726652](https://github.com/pj4533/Liminal/actions/runs/45177726652) | Historical short-SHA checkout failed; unrelated suites do not prove media | failing historical attempt |
| Media [45180018915](https://github.com/pj4533/Liminal/actions/runs/45180018915), `b4d207b` | Full-SHA baseline checkout succeeded; remaining prerequisites/results not established here | pending |
| Public-media smoke | Authentic World of LSD / `aapb-cpb-aacip-514-n00zp3ws90` downloaded and decoded, 2907.901 s; metadata/hash/track provenance `/app/state/liminal-verification/public-media-smoke/provenance/` | verified one source only |
| Private AJ Hall pack, beat grid, installed-library cache | Absent in both available checkouts and documented `/app/state` inventory; purchased assets cannot be fabricated or replaced by public drums | blocked private matrix |
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
same-seed planning. Source/tests exist, but final focused regressions are **pending** and current
candidate failures below prevent blanket acceptance. Acoustic `notSpeech` exclusions and missed
salient-word reasons must be reported, not omitted.

## Task 1 stage 3: stored learning and production selection

| Requirement | Evidence needed / status |
|---|---|
| Persist scanned spans + ranked lines; mutex, coalesced atomic save, in-memory tests; ≥.45 and ≤6 per30s; lexicon invalidation | Implementation present; round-trip/merge/version test results pending latest run |
| Timely + late cached transcript learning after publication, independent cancellation, no cache lock held | `1a05dab` source and runtime tests; latest runtime/stage3 results pending |
| Actual analyzed bounds, source-rate conversion; no features means no scanned span | source + `scannedSpanUsesAnalyzedFramesAndSourceRate`; latest result pending |
| No bed/music delay; cue-token/revision and acoustic fallback preserved | focused runtime/timing evidence and 200s launch pending |
| Catalog start retained; independent clip/piece RNG; empty index identical | production `FootageSalience.prepare` shared with probe; seed regression pending |
| Sound-only .65 override, weighted feasible top5 ≥.6, unplayed, 3–10s lead, ≥20s shown-start avoidance, complete actual cue containment incl. rate/preroll/clamp | unit + production-shared real simulation evidence pending |
| Sound-only recency boost ≤2×; pinned/discovery eligibility/current exclusion/duration/audio filtering preserved; every clip eligible | unit + simulation per-film counts pending |
| 1,000 synthetic sound picks while candidates last | salient fraction .55–.75; pending latest test |
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
| Fresh twelve-film public provenance | pending complete decode set; one World of LSD route verified only; preserve metadata/hash/failures and exact corpus |
| Installed English SpeechTranscriber | pending explicit provisioner/model output; acoustic fallback cannot qualify T evidence; no production download |
| Paired real probe | pending eight chunks/72BPM/seed1, same cache/model; raw logs/snippets + before/after summaries + every target above |
| Historical 19 cases | pending availability/reproduction/relisten: 01 whole LSD;02 choke;03 gate;04–05 LS/D;06 whole marijuana;07 choke;08 gate;09–10 UFO;11–12 trip;13 Smaller;14 grebe;15 Air Force;16 is;17 Yes they;18 Pure cane;19 The kids. Original scratch WAVs lost; use diagnosis film/time table and report missing cases, never label unchosen lines passed |
| Strict bundled/public matrix | pending ref,fast,same,transcribe before/after, distinctly labelled; baseline compiler adapter exact patch retained |
| Strict private AJ Hall matrix | blocked absent purchased pack/grid; no documented public distribution route; authentic prerequisite must become available |
| C-B8,C-B9,C-D1…D9 | pending no new fail-level failures versus paired baseline; historical baseline ref B8/B9, fast B2/B8, same B9, transcribe B9; historical D1…D9 pass. C-D9 onset every bar, ≤2 lines/16bars, subline≥.6, occupancy .30–.62. Do not alter gains/criteria to conceal planner failures |
| macOS build | pending final revision result with explicit destination; historical hosted builds do not prove final |
| Focused dialogue + FootageSalience/FootageWeaver suites | pending final rerun after regression repairs; preserve exact tests/issues/logs |
| Full unchanged LiminalTests, serial, once at final code | pending completed result; distinguish the known three pre-existing failures below from new failures |
| visionOS Simulator build | pending actual successful build/SDK evidence; workflow SDK-absent exit0 is unverified, not pass |
| Scanner perf | scanner off, so scanner-on `perf-run.sh --lofi` conditional not activated; no on-device perf claim |
| 200-second macOS automated run | pending real hook/salient-pick log review, no connective hits/partial figures, no audio/timing errors; AutoPlay,lofi,archive,offline video,fresh image pool and deterministic seeds |
| 3–4 short m4a auditions | pending authentic initialism letters on beat plus drug/proper-name syllables; whole-word context, mix and source provenance. Missing type fails, unrelated clip is no substitute |
| Human listening | pending user judgment; automated rendering/export is not listening approval |
| Docs/maps/decision rationale | documentation updated with current design, historical reasons and outstanding failures; acceptance remains open |
| Main merge | pending coherent reviewed branch merge; do not discard other work |
| Commits and push | pending final code/docs staged explicitly, tested, committed, pushed as authorized; verify remote SHA equals intended commit and record it |
| Final report | pending every missed target and concrete block, final run IDs/revisions, no unsupported live/device/finished claim |

Known prior failures (handoff only; still identify separately in final suite):
`LofiRhythmTests/installedTakesHaveSaneLandmarks`,
`LofiStemChainTests/installedTakesLandInsideTheDrumBusTargets`,
`LofiPadTests/phraseBoundaryBreathIsBridgedByTheTail` (seed2077, since D128).
Missing private-library data can change test applicability; a skip is not a private-data pass.

## Separate user-gated loose ends: no action in this task

Vision Pro remains on `7ccedce`; never uninstall, and no new device install without the user's request.
D129 phone-speaker bass listening remains open (headphones were fine); rollback lever is documented
there. Old unused Gemini ImageStore deletion requires explicit user approval; device backup exists,
Mac extraction was blocked by sandbox access. The unknown recording splice at ~2:14.8 in the
21 November device recording remains a separate investigation awaiting user hearing feedback.
Footage 4-pins:1-discovery ratio and possible image-interest 60→65% changes are separate user choices.
No changes to those systems are authorized by this ledger.
