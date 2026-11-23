# Local Codex handoff: finish Liminal dialogue work

23 November 2026. **Work remains unfinished. Run locally; do not start paid services or more remote Actions jobs.** PJ asked to stop remote work and hand off sooner. All our remote jobs were confirmed stopped; the final runs below were cancelled at the user's budget request, not classified as test failures. No merge, main push, device install or deployment has been performed. This document supersedes the operational state in the morning [handoff](HANDOFF-2026-11-23.md); keep that document for the original requirements.

## Get all work without touching the laptop's dirty checkout

The public branch **`origin/wip/dialogue-salience-finish` contains everything**, including source, tests, infrastructure and this handoff. The original `origin/wip/dialogue-salience-stage2` at `b97b575` is preserved. Main is unchanged by this handoff. In the existing laptop repository:

```sh
git fetch origin
git worktree add -b codex/dialogue-finish ../Liminal-dialogue-finish origin/wip/dialogue-salience-finish
cd ../Liminal-dialogue-finish
git status --short
git rev-parse HEAD
```

Do not stash/reset/clean the original checkout, force-push, merge main or overwrite existing private installations. If that worktree/branch name exists, inspect it and choose a fresh name. Preserve unrelated edits. Stage explicit paths only. Read `AGENTS.md`, `CLAUDE.md`, [original handoff](HANDOFF-2026-11-23.md), [plan](dialogue-salience/plan.md), [diagnosis](dialogue-salience/diagnosis.md), [acceptance ledger](dialogue-salience/acceptance-ledger.md), [task 2](dialogue-salience/task2-chop-feel.md), [media](dialogue-salience/real-media-verification.md), [private preparation](dialogue-salience/private-drum-verification.md) and [mix verification](../mix-verification.md).

| Revision | Meaning |
|---|---|
| `47a01fe267a3972241ed6918d031fffe55f26ed2` | Exact stage-1/main baseline used for real-media comparison; not the task-2 fixture baseline |
| `b97b575` | Original laptop stage-2 WIP, preserved |
| `06c1095` | Instrumented task-2 before; production before is `3d4c3a6` |
| `fc4f391` | Latest production hook-pocket fix with passing focused tests and 18/18 fixture metrics |
| `70ace3f` | Additional test-only long-word fixture; first execution not confirmed |
| `73e8d4234f66a1bebbf5fbab1f9c9fea9a653b17` | Consolidated source/test/docs revision used by final Apple/public-media attempts |
| `2c87c22` | Exact historical capture signing adapter; added after those media captures |
| `445b9dce07f3f1de4d924ca4b0ceae1c524a3006` | Infrastructure state before this final documentation commit; private workflow/transport included |

Short revision names are unambiguous in the fetched branch; use full baseline SHA for checkouts. Final handoff commit follows `445b9dc`, with no production changes.

## What changed and what is actually verified

Salience work implements content-first ranking, protected word-boundary rescue, deliberate letter/syllable units with complete on-grid whole-word landings, content-safe gates/clearance, stored line interest and shared footage selection. Task 2 adds bounded per-line linked pitch/speed, rendered attack remeasurement, persistent seeded move history, complete figure rollback and fresh usable hook pockets before long words reserve their neighbours. Opening correction retains samples and lifts only the bounded opening envelope. Source and synthetic tests are evidence for these mechanisms, not authentic intelligibility or finished acceptance. Musical/timing thresholds were not weakened.

Verification now inventories every expected decode/transcript/render outcome, actual audible buffers and eligible attacks, exact corpus/cache provenance, mode-separated re-hearing, complete audition figures, per-revision mix cases and actual transcription use. Missing data cannot become a pass. Historical baseline gets strict asserted measurement/compiler/capture adapters, with their diff retained. Whole-suite coverage resolves declaring scope in shared Swift files (Motif and LineLedger are separate); a successful zero-test selector cannot qualify. Private helpers preserve bytes and verify exact resources. These infrastructure fixes do not certify the sound.

| Evidence | Verified observation and limit |
|---|---|
| [45218799677](https://github.com/pj4533/Liminal/actions/runs/45218799677), `fc4f391` | 14 tests / 2 whole suites, coverage 14/14; **18/18 feel gates**, 108 loops, 72 cross-line pairs. Synthetic fixtures only. |
| [45208957813](https://github.com/pj4533/Liminal/actions/runs/45208957813), earlier `e1` | Broad 90 tests / 10 suites passed in 1753 seconds with complete coverage, but then only 15/18 feel metrics; later source changed. |
| [45214973934](https://github.com/pj4533/Liminal/actions/runs/45214973934), `e452a83` | 44 tests / 4 suites passed, including Motif 24 and Variety 8. Not final full suite. |
| `df2dc89` timing/headroom | Same native/linked inventory 104 pads, zero >35ms each, median about .92→.98ms; p95 4/9.5/10.3ms at 62/72/84 BPM. Of 56 paired full renders, six corrected; max RMS +.562dB, K-energy +1.169dB, all peaks <.857. Synthetic only. |
| [45189257392](https://github.com/pj4533/Liminal/actions/runs/45189257392) | Exact adapted `47a01fe` and candidate independently built for testing; whole SalienceProbe/FootageSalience suites and execution coverage passed. Does not replace final builds or actual opt-in probe. |
| [45221402727](https://github.com/pj4533/Liminal/actions/runs/45221402727), `73e8d4` | macOS app/test-bundle and visionOS Simulator builds passed. Full suite expected 632 methods / 84 suites; cancelled mid-execution by user request. No full-suite pass; new `70ace3f` fixture execution unconfirmed. Public combined mix pending. |
| [45221406217](https://github.com/pj4533/Liminal/actions/runs/45221406217), `73e8d4` | Stage-3 tests 31 / 2 suites passed in 72s; partial public media, with corpus/speech/mix gaps below. Cancelled by request. |
| [45227791928](https://github.com/pj4533/Liminal/actions/runs/45227791928), `445b9dc` | Private ciphertext authenticated and 100-file bundle installed. Cancelled during native tests; overall **UNMET**, no native/matrix pass. |
| Local handoff check | `python3 -m unittest discover -s scripts -p 'test_*.py'`: **61 passed**, no Apple build executed in this Linux container. |

Final task-2 report versus `06c1095`: chop-beat grid .090208→.067177, rest .918789→.891614, quiet .640732→.623636; full grid .121956→.064830; full reverses 108→285, zero repeated reverse positions. Preserve all 18 definitions, full/chop scopes and histograms; do not substitute listener entropy claims for the held-out-seed predictor.

## Evidence locations and preservation

These are container/host state paths, **not included in git and not automatically present on the laptop**. Transfer locally if accessible, or reproduce locally. Do not reupload large artifacts or private plaintext. The copied baseline contains text/statistics and manifest only, no audio.

- Durable task-2 before: `/app/state/liminal-verification/task2-baseline/feel-attachments/` (copied from volatile `/tmp/liminal-feel-before/feel-attachments`).
- Final task-2 comparison: `/app/state/liminal-verification/run45218799677/feel-report-vs-06c1095.json`; raw text/attachments in that run directory.
- Partial media: `/app/state/liminal-verification/run45221406217/partial-real-media-gates-73e8d4234f66a1bebbf5fbab1f9c9fea9a653b17/`.
- Same run's small auditions/app artifacts: sibling directories `partial-real-media-auditions-73e8d4234f66a1bebbf5fbab1f9c9fea9a653b17/` and `partial-real-media-app-73e8d4234f66a1bebbf5fbab1f9c9fea9a653b17/`. Export existence is not qualification/listening.
- Prerequisites, dataset provenance, exact baseline adapter diff, speech alternatives and baseline partials are siblings in that run directory.
- One unique approximately **1.44GB after artifact remains remote, not downloaded** in run 45221406217, linked above; retention may expire. No need to download it to start local source checks.
- Private sanitized summary: `/app/state/liminal-verification/run45227791928/summary/summary.json`. Approximately 2MB `private-evidence.enc` retained locally; detailed private evidence needs its local key, never print it.

## Remaining authentic-media blockers and observed failures

Fresh public comparison expects **12 films × 8 windows = 96**, 72 BPM, seed 1, identical source derivatives/hashes, offsets, speech model and eligibility. Baseline completed **95/96**, so qualification fails. Missing `Timothy_Leary_Archives_198`, chunk 7, offset **3648.989s**, derivative `198_512kb.mp4`: container duration 3739.99s / stream 3738.17s. This is not an EOF boundary skip. Decode error detail was not logged; diagnose locally and retain exact exception/output. Do not silently skip the window, replace only one revision's file, or relax completeness. Baseline logged 9349/9349 rendered/audible plays and 8829/8829 eligible/detected onsets; this does not repair the missing window.

After acoustic mode logged 8820 plays, onset n=7668, **47 over35ms**. The original stage-1/4 zero-over35 target is unmet on these observations. Do not call it a regression or a passing no-worse comparison until baseline uses the identical eligible inventory. Authentic T evidence is absent: SpeechTranscriber was unavailable on current/new SDK Intel/ARM hosted virtual machines, with empty supported/installed locale sets. Provision on the physical Mac using the provided standalone script, then prove actual model transcripts per speech-eligible window. External text, DictationTranscriber, acoustic fallback or merely installed model metadata cannot qualify this backend.

Partial after public strict mix results:

- ref: 18 pass, 6 fail, 6 warn, 2 skip; failures **C-M1, C-M3, C-M9, C-B6, C-B8, C-D6**.
- fast: 21 pass, 4 fail, 5 warn, 2 skip; failures **C-M9, C-B6, C-B8, C-D6**.
- Complete same/transcribe inventories and paired baseline comparison are still needed. The old baseline capture lacked the hosted signing adapter; `2c87c22` repairs preparation for a new local comparison. Record strict results separately from no-new-targeted-fail C-B8/C-B9/C-D1…D9. Required transcription skip remains unmet.

An earlier `61e4b` app launch survived 200s and logged four archive-audio events, but also decode/network errors and late chops. The final small app artifact is retained for review; **no clean playback/visual/listening acceptance is claimed**. Require hook, footage and salient-pick logs, inspect errors and actually view/listen. The historical **159 salient occurrences** and **19 curated original audio cases** are unavailable; fresh corpus counts are not historical certification. Reconstruct from diagnosis film/time table where possible, record exact missing cases, and retain unverified historical gates without inventing equivalent thresholds.

## Private pack: available, preparation verified, execution unfinished

The source is **not missing**. All four packs were found at `/host/external/PJ Archive/Music Production/Samples/Drum Kits`. On the Mac locate the actual mounted source; do not assume its `/Volumes` spelling. Prepared bundle: `/app/state/liminal-private-verification/bundle`, **100 eligible of 112 original**, original bytes preserved. Volume original/eligible counts: 25/20, 25/23, 25/25, 37/32. Grid SHA256 `f04ed987acd0d693aa46b717fcac4a1ef6c2b07e3153d90dd41ebbba9ff0dbee`.

The canonical-name repairs include the Vol.4 BUBBA_KUSH `DRUM_BREA` typo and BISCOFF_BUTTER trailing `!`; Vol.2 also has a space before BPM. See the tested parser; never rename/change source bytes or discard these files. Install exactly the same fresh 100-file corpus/grid in both checkouts. This is a regenerated D122 catalog, **not** the unavailable historical installed cache. Preserve old installations separately; installer deliberately refuses collisions.

Local direct preparation/install requires no remote encryption:

```sh
# Set these to verified local paths outside git; output must not already exist.
python3 scripts/private-verification-assets.py prepare "$PRIVATE_SOURCE" "$PRIVATE_BUNDLE"
python3 scripts/private-verification-assets.py install "$PRIVATE_BUNDLE" "$PWD" "$BASELINE"
```

Use either this direct install OR `verify-private-drums.py setup`, which performs installation plus adapters, not both on the same checkout. The latter's local phases are `setup`, `native`, `prepare`, `baseline`, `after`, `final`, each with `--after PATH --baseline PATH --out PATH --bundle PATH`. Review the script and use clean dedicated checkouts; collect native exact built-resource hashes and complete matrix evidence. The private final gate stays UNMET until every phase is complete and real transcription is used.

The repository is public. Keep drums, grids, builds, raw private logs and mixed captures out of git/uploads. Local private directories/keys remain mode700/600. Ephemeral Actions `LIMINAL_PRIVATE_DRUMS_KEY_20261123` and `LIMINAL_PRIVATE_DRUMS_URL_20261123` secrets were deleted. Draft release `private-drums-20261123` ID455744712 and asset783833664 were deleted and confirmed; no plaintext remote artifacts were published. Local ciphertext/keys were retained privately. Do not recreate secrets, releases or remote runs from the old transport instructions. Standard `macos-26`/`macos-26-intel` public-runner compute is described as free by [GitHub](https://docs.github.com/en/billing/concepts/product-billing/github-actions); account billing was not audited and no all-services $0 guarantee is made. PJ's controlling instruction is local execution and no paid services.

## Local completion sequence

Run serially, one Xcode/app/capture at a time. Use a private derived-data directory, explicit destination, preserve logs/xcresults. Build once then `test-without-building`; allow more than 65 minutes for the complete suite if needed. Command-line `CODE_SIGNING_ALLOWED=NO` is for verification only; do not modify project/device signing or install on Vision Pro. The commands below are adapted from committed workflows/scripts; they were not executed in this Linux container.

1. Run Python, build candidate and complete **all** unchanged LiminalTests first. Enumerate suites using `declared_tests`, exactly as `.github/workflows/apple-verification.yml` does, then pass every name to the coverage checker. The checker proves execution, while xcodebuild exit separately proves success. Confirm `70ace3f` test actually ran; do not skip failing tests.

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
# Set VERIFY_OUT and DD to fresh absolute local directories outside git.
mkdir -p "$VERIFY_OUT"
set -o pipefail
xcodebuild -quiet build-for-testing CODE_SIGNING_ALLOWED=NO -project Liminal.xcodeproj -scheme Liminal -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -derivedDataPath "$DD" 2>&1 | tee "$VERIFY_OUT/build.log"
xcodebuild test-without-building CODE_SIGNING_ALLOWED=NO -project Liminal.xcodeproj -scheme Liminal -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -derivedDataPath "$DD" -resultBundlePath "$VERIFY_OUT/unit-tests.xcresult" -only-testing:LiminalTests 2>&1 | tee "$VERIFY_OUT/unit-tests.log"
python3 - <<'PY_SUITES' > "$VERIFY_OUT/required-suites.txt"
from pathlib import Path
import runpy
parser = runpy.run_path('scripts/verify-swift-test-coverage.py')
print('\n'.join(sorted(name for name, tests in parser['declared_tests'](Path('LiminalTests')).items() if tests)))
PY_SUITES
suites=()
while IFS= read -r suite; do suites+=("$suite"); done < "$VERIFY_OUT/required-suites.txt"
python3 scripts/verify-swift-test-coverage.py "$VERIFY_OUT/unit-tests.log" LiminalTests "${suites[@]}" > "$VERIFY_OUT/test-coverage.json"
xcrun xcresulttool export attachments --path "$VERIFY_OUT/unit-tests.xcresult" --output-path "$VERIFY_OUT/attachments"
python3 scripts/dialogue-feel-report.py "$VERIFY_OUT/attachments" --baseline "$FEEL_BASELINE" > "$VERIFY_OUT/feel-comparison.json"
```

Set `FEEL_BASELINE` to the preserved before attachment directory before comparison; use the preserved before fixture text and the exact same definitions to reproduce all18 gates. Preserve exit statuses, not just the final pipeline command. Full suite has three known prior issues: installed drum landmark and drum-bus-target tests (rerun with available authentic pack), and `LofiPadTests/phraseBoundaryBreathIsBridgedByTheTail` seed2077, observed dip6.206758 against6. Distinguish baseline/candidate; do not weaken limits. Build visionOS Simulator with `xcodebuild -scheme Liminal -destination 'generic/platform=visionOS Simulator' CODE_SIGNING_ALLOWED=NO build` if source changes invalidate the prior successful build. No device installation.

2. On the physical Mac compile/run `scripts/provision-verification-speech.swift` through the `speech` phase of `verify-real-media.sh`; record hardware, availability, supported/installed locales and actual transcript output. Provisioning is standalone and opt-in; no model downloads in production cue paths.
3. Prepare/install identical private100 corpus on candidate and exact47a baseline, run native tests and exact built-resource identity checks. Use clean separate baseline checkout(s), since adapters intentionally modify source and each setup asserts original text. Never apply adapters twice. `verify-private-drums.py setup` and `verify-real-media.sh prepare` own overlapping adapters; use separate baseline worktrees for independent harnesses.
4. Review `verify-real-media.sh` before running: it uses the current user's canonical `~/Library/Application Support/Liminal/ArchiveFootage` cache and writes it. Back up/preserve any existing cache and use an isolated local test account/environment if needed. Prepare fresh12-film cache/provenance, fix the chunk7 decode cause and achieve paired96/96 with same eligibility/model. A preparation ffmpeg check does not replace the actual AVFoundation decode coverage.
5. Run exact baseline then candidate public/private matrices and probes serially. The harness signature is `scripts/verify-real-media.sh AFTER BASELINE OUT PHASE`, phases `prepare speech baseline after gates auditions app final`; inspect before invoking and stop for real prerequisites, not skip them. Preserve `baseline-verification-adapters.patch`; measurement/compiler/capture-only baseline adapters must not change DSP. `BUILD=0` probe reuse requires a matching compiled bundle.
6. Recompute T/A metrics, both fresh/evolving footage experiments, re-hearing and complete mix cases; resolve source defects and rerun affected tests. Keep raw strict result, paired no-new-targeted-fail and historical certification distinct. Run app phase, inspect logs, use Peekaboo and actually view the app. Listen to dry and mixed authentic clips.
7. Produce **3–4 qualifying short m4a examples**, including a real complete initialism and a drug/proper-name syllable figure: one parent, all units in order, uniform1/2step spacing, beat-aligned whole-word landing, export containment, exact source/render provenance. Acoustic extras cannot count. Include whole-word context, dry+mix, and explicit human listening outcome. Reconstruct/listen to historical19 cases where available; report unavailable ones.
8. Update ledger/decision rationale/architecture/experience/maps for final results and failures, commit explicitly, and report a reviewable result. Main merge/push is deferred; no auto-trigger branch pushes or new remote verification under current instructions. Keep every missing requirement visible.

## Acceptance checklist: omit nothing

The [ledger](dialogue-salience/acceptance-ledger.md) retains all original numerical thresholds and historical values. Final authentic values remain open: T accidental≤.05; A≤.20; T function-only≤.03 (stage1≤.08); halves/one-syllable splits/off-letter initialism cuts zero; no-word≤.05; best-word<.5≤.45; salient heard/whole≥.35/.25; median interest≥.60; untexted≤8; striking passed over≤5; historical ranked/chosen≥110/50 of159; protectedCut≤10; exact T whole-content re-hearing≥60%. Keep A visible and controls separate.

Timing: median within±2ms of paired baseline, p5/p95 reported, original zero>35ms target plus separate task2 no-worse count; all eligible attacks actually rendered/detected. Variety: unmarked same-cut pairs/longest run no worse, every2bar cell≥3 cuts when offered, onset every bar, density/occupancy reported, D125 hooks/D126 arc/D127 variety preserved. Complete spelling and deterministic replay required.

Stage3: persist/version/merge/coalesce/actual analyzed bounds, timely+late learning independent of publication cancellation, no bed/music delay; empty-index/RNG compatibility; sound-only .65 override, feasible top5≥.6/unplayed,3–10s lead,20s shown-start avoidance, actual-rate cue containment; recency≤2× and eligibility preserved. Synthetic1000 candidate picks salient fraction .55–.75. **Each** fresh/evolving500-before+500-after experiment independently needs≥2× and≥.60 salient share, random≥.25, every audio film≥half baseline share. Stage3 unit pass does not prove real experiment. Scanner stays off (`false`); no scanner-on/performance acceptance claimed.

Task2: one linked cadence ratio per line bounded±2.5semitones, retained revisions/identity, resample once off realtime, all pad attack remeasurement, same-inventory timing, deterministic cross-line moves with no consecutive same move/position, more reverses, all18 pattern gates, preserved hook/arc/snare/density/whole words and atomic chains. Final full suite and authentic evidence still needed.

Delivery: exact baseline/candidate builds, full suite, both public/private complete ref/fast/same/transcribe inventories, no new fail-level C-B8/C-B9/C-D1…D9 (D9 onset every bar,≤2lines/16bars,subline≥.6,occupancy .30–.62), 200s clean app/hook/salient-pick evidence, human view/listen and3–4 qualified auditions. Source fixes, successful builds and cancellation are not acceptance certificates.

Separate original user loose ends remain untouched: D129 phone-speaker bass check; Gemini cache deletion/extraction approval; unknown recording splice near2:14.8 on21November;4pins:1discovery and image-interest60→65% preferences. Vision Pro remains on the user's existing build; never uninstall or install without a request. Do not expand dialogue completion into those tasks.
