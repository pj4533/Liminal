# Reproducible real-media verification, 23 November 2026

The `Real media verification` workflow runs serially on macOS 26. It explicitly prepares public
Archive media, provisions the runner's on-device English SpeechTranscriber asset in a separate
executable, and then uses the application's installed-only transcription path. No production cue or
probe downloads a speech model. Provisioning failures retain their exact diagnostics; acoustic
results never satisfy the transcript-evidence gate.

`scripts/prepare-verification-media.py` enumerates the canonical thirteen pins and prepares twelve
successfully decoded audio-bearing MP4 films. It uses Archive metadata filenames, accepted MP4 formats,
and decoded track inspection, rather than assuming a filename. The isolated cache has the actual
`ArchiveClipStore.Index` Codable root and Swift Date encoding. Metadata, download URLs, SHA256 hashes,
durations, track facts and failed routes are preserved as provenance outside Git.

Both stage 1 (`47a01fe`) and after use this same cache, eight chunks, 72 BPM and seed 1. The historical
12-film identities are unavailable; the old absolute count of 159 salient words is not represented as
an identical dataset. Fresh baseline denominators and after denominators are recorded with every gate.
The updated matrix harness is copied into the baseline. One compiler-only adapter qualifies
`Self.cuePartials` to fix the historical local/function name collision; its exact diff is preserved
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

The workflow preserves the probe reports and raw snippets, strict reference/fast/same/transcribe mix
reports, rendered m4a snippet auditions when the corresponding real initialism/syllable hits exist,
and a 200-second automated app launch with offline video, a fresh image pool and deterministic seeds.
Focused stage 3 tests run before media preparation. Full-suite and visionOS verification remain
in the dedicated Apple workflow; a media prerequisite failure exports diagnostics immediately
and does not launch unrelated expensive suites. The historical baseline is checked out by its
full commit ID, because actions/checkout treats a short SHA as a remote ref rather than fetching it.
Missing authentic audition types fail explicitly instead of substituting unrelated audio.

Private AJ Hall recordings are never fetched or fabricated. Documented preparation requires copying
the user's purchased 64-beat breaks into `Liminal/SlowBurnDrums/` and the private
`Liminal/Audio/Lofi/SlowBurnBeatGrid.json`; see `docs/experience.md` and `docs/mix-verification.md`.
No private pack, beat-grid JSON or installed-library cache was found in the available Liminal
checkouts or the known `/app/state` artifact inventory. There is no documented public distribution
route for those purchased recordings. The workflow records exact file checks. It runs an explicitly
labelled public/bundled matrix separately, and runs the private matrix only if the real prerequisites
exist. Public fallback results cannot qualify the private matrix.

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
