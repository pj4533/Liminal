# Reproducible real-media verification, 23 November 2026

**Final status / local-only continuation:** see [CODEX local handoff](../HANDOFF-2026-11-23-CODEX-LOCAL.md). All remote jobs were cancelled at PJ's request; do not restart workflows. Run45221406217 at73e8d4 passed31 stage3 tests/2suites and prepared12 films, but actual baseline decode completed95/96 windows (Timothy_Leary_Archives_198 chunk7,3648.989s, not EOF). Corpus qualification remains unmet. No authentic T evidence: tested hosted Intel/ARM VMs with current/new SDK report SpeechTranscriber unavailable. Physical Mac provisioning/actual transcripts remain necessary. After A has47>35ms attacks out of7668 eligible measures; paired comparability incomplete. Partial ref/fast strict failures and remaining inventories are enumerated in the local handoff.

Integrity45189257392 independently compiled exact adapted47a01fe and candidate and passed whole probe/footage suites. Final Apple45221402727 at73e8d4 passed macOS/test-bundle and visionOS Simulator builds, but full632methods/84suites execution was user-cancelled; no full-suite pass. New test70ace3f execution unconfirmed. Latest private45227791928 authenticated/installed100-file corpus, then user-cancelled during native tests; overallUNMET. Sources are available, correcting the earlier inventory below. Historical159/19-case certification, authentic audition classes, clean app playback and human listening remain open.

Run `scripts/verify-real-media.sh` phases serially on the Mac. The harness explicitly prepares public
Archive media, provisions the on-device English SpeechTranscriber asset in a separate
executable, and then uses the application's installed-only transcription path. No production cue or
probe downloads a speech model. Provisioning failures retain their exact diagnostics; acoustic
results never satisfy the transcript-evidence gate.

`scripts/prepare-verification-media.py` enumerates the canonical thirteen pins and prepares twelve
successfully decoded audio-bearing MP4 films. It uses Archive metadata filenames, accepted MP4 formats,
and decoded track inspection, rather than assuming a filename. The local harness writes the paired cache to `OUT/ArchiveFootage`. Both debug apps resolve the same directory through the verification environment. The isolated cache has the actual
`ArchiveClipStore.Index` Codable root and Swift Date encoding. Metadata, download URLs, SHA256 hashes,
durations, track facts and failed routes are preserved as provenance outside Git.

Both stage 1 (`47a01fe`) and after use this same cache, eight chunks, 72 BPM and seed 1. The historical
12-film identities are unavailable; the old absolute count of 159 salient words is not represented as
an identical dataset. Fresh baseline denominators and after denominators are recorded with every gate.
The updated matrix harness is copied into the baseline. Compiler-only adapters qualify
`Self.cuePartials` to fix a historical local/function name collision, and expand the hook distinct-fragment
expression into equivalent typed loops. Their exact diff is preserved
in `baseline-verification-adapters.patch`. No baseline signal-processing behavior changes.

The footage experiment shares `FootageSalience.prepare` with the production decoder. It includes
pinned/discovery eligibility, current/on-screen exclusion, recency weighting, duration/audio filtering,
shown-start avoidance and final `ArchiveAudioCuePlan` containment. Its independent paired simulations
separate fresh-index policy sampling from evolving playback. The latter advances recency, use counts,
shown starts and its own line ledger, conservatively consuming completely contained salient lines.
This is a finite-pool depletion stress test, not a claim that every contained line was chosen by the
performer. Neither result replaces the other. The doubling, 0.60 salient, 0.25 random and per-film
half-baseline-share thresholds stay unchanged; depletion failures remain failures in the output.

Index learning runs on a serial utility queue after cue publication finishes. It captures source,
analysis and transcript values independently of the cue task's cancellation lifetime. Cached timely
and late transcripts both feed it. Scanned spans stop at actual feature bounds, including non-unit
source playback rates; sources without features do not mark a span scanned.

The local harness preserves the probe reports and raw snippets, strict reference/fast/same/transcribe mix
reports, rendered m4a snippet auditions when the corresponding real initialism/syllable hits exist,
and a 200-second automated app launch with offline video, a fresh image pool and deterministic seeds.
Run the full macOS suite and the visionOS Simulator build on the same Mac before media review; a media prerequisite failure exports diagnostics immediately
and does not launch unrelated expensive suites. The historical baseline is checked out by its
full commit ID to keep the comparison tied to the recorded source.
Missing authentic audition types fail explicitly instead of substituting unrelated audio.

Private AJ Hall sources were subsequently found: all four packs at `/host/external/PJ Archive/Music Production/Samples/Drum Kits`. Prepared fresh corpus100eligible/112originals is available under `/app/state/liminal-private-verification/bundle`, byte-preserved, grid SHA256 `f04ed987acd0d693aa46b717fcac4a1ef6c2b07e3153d90dd41ebbba9ff0dbee`. This corrects the earlier missing-source finding. It is not the historical installed cache. Use `private-verification-assets.py` for local preparation/validation/install into clean paired checkouts; see [private preparation](private-drum-verification.md). Public results cannot qualify private gates. Remote native execution was cancelled before completion; no private matrix pass is claimed. Keep private fixtures and verification evidence on the Mac outside Git.

Local verification before the remote run: report regressions 13 passed, media preparation unit tests
2 passed, gate isolation/missing-evidence tests 2 passed; Bash syntax checks and `git diff --check`
passed. Swift compilation, SpeechTranscriber availability, full media gates and app behavior require
the remote artifacts; this document does not claim their success in advance.


## Hosted availability and independent execution follow-up

Run [45180018915](https://github.com/pj4533/Liminal/actions/runs/45180018915) passed
31 stage-3 tests in two suites (61.951 seconds), prepared twelve authentic films with zero
preparation failures, and compiled the standalone provisioner. Its runtime reported
`SpeechTranscriber.isAvailable == false` on macOS 26.7.2 / Xcode 26.6 / SDK 26.5.
The throwing Swift entry point then trapped; the follow-up reports errors cleanly and flushes
device capabilities, supported locales and installed locales before exit.

[Apple's API documentation](https://developer.apple.com/documentation/speech/speechtranscriber)
defines availability by the device's hardware/capabilities and recommends another transcriber
when unsupported; it does not publish an exhaustive hardware support list. An
[Apple DTS response](https://developer.apple.com/forums/thread/802863) likewise recommends
the runtime availability check. [Apple's authorization guidance](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
explicitly limits the server-recognition permission process to `SFSpeechRecognizer` and excludes
`SpeechAnalyzer` modules. Microphone entitlements do not enable prerecorded-file model hardware.
[GitHub's standard runner specification](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
lists macOS 26 as a three-core M1 virtual machine. This makes VM capability a plausible cause,
not a demonstrated universal restriction on all virtual machines. The workflow now records
`uname`, architecture, sysctl model/virtualization facts and hardware profiler output, tests the
native executable and an ad hoc signed application bundle, and runs availability/provisioning
on the standard `macos-26-intel` and `xcode-27` alternatives. No paid larger runner or new service
is enabled. macOS 15 cannot run this macOS-26-only API; mobile/vision simulators cannot establish
physical-device compatibility. DictationTranscriber or externally injected text would be a
different backend and cannot qualify the application's Apple SpeechTranscriber end-to-end gate.

Preparation, speech, baseline, after, gates, auditions and app phases now have separate time
budgets and immediate artifacts. Speech failure does not prevent acoustic probes, strict public
ref/fast/same captures or the 200-second app run. The transcribe matrix's unavailable-model
`skipped.txt` is preserved, and the final required-gate check still fails on unmet transcript,
private-matrix and audition requirements. The public cache is saved with Actions cache outside
Git; both revisions continue to use exactly the same cache within a run. Acoustic six-second
performed figures can be exported as explicitly named acoustic m4a listening evidence; they
cannot satisfy the required initialism/proper-noun syllable audition classes. Original
zero-attacks-over-35ms gates and later task-2 no-worse counts are now emitted separately.

## Verification integrity follow-up (23 November)

Measurements now require an explicit twelve-film/eight-window inventory at 72 BPM/seed 1,
including Archive derivative URL/hash identities, attempts, successful decoded frame counts,
speech-eligible/nonspeech denominators, Apple model version/locale and per-window transcript
outcomes. Missing decode or eligible transcript windows fail corpus qualification. Nonspeech
windows remain in the inventory; an absent transcript there does not itself fail speech coverage.
Per-hit rendered and audible coverage is separate from planned source overlap. The independent
onset denominator includes every planned sub-line non-reverse event; missing/undetectable
eligible attacks fail coverage. Reverses are explicitly excluded from that detector, while
still requiring rendered signal. Historical baseline `47a01fe` receives only the checked
`scripts/baseline-probe-measurement.patch`, the same report parser, matrix wrapper and asserted
compiler-only bass/hook adapters plus the later exact capture-signing adapter (`prepare-baseline-capture.py`,2c87c22); the exact diff is retained with preparation artifacts.
No baseline planner, renderer, musical thresholds or detector algorithm is rewritten.

Re-heard denominators retain mode, control, whole-piece and content identity. The 60% gate
uses only sampled rendered **T whole content pieces outside controls**, with an exact normalized
recognized-token match ("trip" cannot match "tripping"). Controls and A remain reported.
Fresh salient-word counts and rates are separate from the historical 110/50-of-159 gates;
those gates remain unverified without an explicit verified `historicalMatch` provenance record.
They cannot be made green by coincidentally observing 159 fresh occurrences.

Auditions qualify only from logged actual rendered figures: complete ordered units from one
parent, a uniform one/two-step grid, next-beat whole landing, and complete containment in the
exported window. Three or four qualifying examples must include a real initialism and a
recognized drug/proper-name syllable figure. The probe matches substance names against an explicit list and proper names against the
sentence's named-entity tags. It checks the source word core against the rendered landing,
retains the source line and rerenders the same events dry with piece effects bypassed.
The stereo musical example runs the archive bed, chops, ducking, effects, all music stems
and master on the probe clock. Its drum source is the public mix-test performance fixture.
Acoustic examples stay in the extras inventory.

The auditions phase writes performed, context, dry and mixed AAC files plus source times,
derivative identity, render revision and hashes in `auditions/provenance.json`. A human
reviewer listens to each selected context, dry and mixed file and records what they heard,
including recognizability, unit order and the whole-word landing against the music.
For each example, add an entry keyed by its name to `OUT/audition-reviews.json` with
`sha256` mapping `context`, `dry` and `mix` to the reviewed M4A hashes, a written
`outcome` and a Boolean `accepted`. Rerun the auditions phase to check the reviews
against those exact exports. Missing or rejected listening keeps acceptance open.

Media cache sidecars authenticate chosen metadata filename/URL/hash and source metadata hash;
legacy or mismatching cache entries are refetched. ffprobe facts are metadata only. Actual
FFmpeg decoded sample counts cover the eight probe windows, with no full-film decode claim.
Required ref/fast/same/transcribe cases are inventoried per revision; unavailable transcription
is unmet, and ready status without actual used recognized words cannot qualify. Raw strict
results remain separate from the paired no-new-targeted-fail result. Private after captures
now receive the private baseline. Preparation assertion/copy/adapter failures stop the phase
and preserve failure status. The app's process-survival step is separate from automated
hook/footage/salient-pick evidence; neither establishes human visual or listening acceptance.

Local Python/shell regressions verify these failure paths. A separate `verification-integrity`
workflow compiles the adapted historical probe and candidate and runs the new detector/selection
regressions without downloading media or running duplicate captures. Its existence/start does
not establish a passing Apple build, real-media acceptance, or resolution of the remaining DSP gates.


Integrity run `45187285260` failed historical Swift compilation: the generated probe adapter
accidentally duplicated a window loop, leaving the final log outside the function. Patch
applicability had passed and did not establish compilation. The repair removes that duplicate;
regressions now inspect the fully applied exact historical source. The historical hook-metrics
expression that exceeded the compiler's type-check budget is expanded to typed loops preserving
the identical four-group distinct-fragment mean. `prepare-baseline-compiler.py` asserts both
historical source expressions exactly, and the resulting adapter diff remains an artifact.

The integrity workflow now attempts baseline and candidate build-for-testing independently;
a baseline failure cannot suppress candidate compiler diagnostics. Whole-suite selectors and
`verify-swift-test-coverage.py` require each suite and every source-declared `@Test` method to
finish, so successful zero-test selections cannot qualify. This also repairs the regression
workflow's omitted Motif method selectors. The public capture's inner xcodebuild accepts only
an explicitly set `LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED=YES|NO`; the hosted harness sets `NO`,
while direct/default and device/project signing remain unchanged. The repaired exact baseline and candidate builds plus whole probe/footage tests passed in45189257392. This does not establish authentic-media acceptance. Local Python regressions at final handoff passed61/61.
