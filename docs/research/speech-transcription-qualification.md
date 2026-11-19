# On-device speech transcription: qualification record

Date: 2026-11-19. Scope: plan [mpc-chopping.md](../plans/mpc-chopping.md) section 7, the optional `AppleSpeechTranscriptProvider` behind `TranscriptProvider`. The acoustic dialogue path never depends on it.

## Environment

- Xcode 27.2 (27B52), macOS SDK 27.2, Speech.framework user-module-version 3605.24.1.14.2.
- Host: macOS 27.2.1 (build 26B131), Apple silicon.
- Probe: `LiminalTests/DialogueTranscriptionTests/qualificationProbe()`, enabled by `/private/tmp/liminal-transcription-probe-<uid>.json` containing `{"checkout": "<source root>"}`. The config was deleted after the run.

## Asset status, before and after

| | `isAvailable` | Status | Installed English locales |
|---|---|---|---|
| Before the probe | true | **ready** | en-US, en-GB, en-AU, en-CA, en-IE, en-IN, en-NZ, en-SG, en-ZA |
| After the probe | true | **ready** | the same nine |

The model was already installed on this Mac, probably by the system or another app. This session started no download: no code path ran `AssetInventory.assetInstallationRequest`, the probe only reads status, and the app launch for the screenshot used the default "If installed" mode.

## Measurements (macOS, 30 s of each cached film, 20 s deadline)

Three cached films, 30 s each from 25% into the film, decoded at 48 kHz as in `LofiMixRenderTests`. "Cancel" is how far past a forced 300 ms deadline the provider returned nil.

| Film | Words | Mean confidence | Wall, first run | RTF, first run | Wall, second run | RTF, second run | Cancel past deadline |
|---|---|---|---|---|---|---|---|
| Office Courtesy: Meeting the Public | 94 | 0.92 | 3488 ms (cold) | 0.116 | 896 ms | 0.030 | 0.5 / 1.0 ms |
| Design for Dreaming | 44 | 0.84 | 734 ms | 0.024 | 396 ms | 0.013 | 3.4 / 1.6 ms |
| UFO Interview | 83 | 0.81 | 1116 ms | 0.037 | 873 ms | 0.029 | 1.5 / 9.1 ms |

The probe ran twice. The first run logged `Cannot use modules with unallocated locales [en_US] ... This will be an error in a future release!`. The provider then gained a once-per-launch `AssetInventory.reserve(locale:)`, which reserves an installed asset and is not documented to download anything. The second run had no warning. Its first film ran warm because the model stays loaded with `modelRetention: .lingering`.

Sample word timings, in film seconds, from the first run:

- Office Courtesy, from 173.27 s: "Let's" 173.39–173.87, "talk" 173.87–173.99, "about" 173.99–174.17, "it again later on." to 175.01, "It's no use, Ruth." 175.07–176.33.
- Design for Dreaming, from 140.53 s: "Oh," 141.31–142.15, "I want a party at two." to 145.21, "Okay," 146.53–147.07.
- UFO Interview, from 67.39 s: "This" 67.39–67.57, "is a right Patterson Air Force," to 69.79, "646" 70.51–71.71.

Runs come back word-level, with punctuation attached to the word. Each run carries `audioTimeRange` and, when requested, `transcriptionConfidence`.

Verdict for macOS: qualified. Worst-case cold latency is about 3.5 s for 30 s of audio. That fits within the scheduling lead only if the coordinator gives transcription its own deadline, which it does. Cancellation returns within 10 ms of the deadline.

## Usage description

Not needed. File/buffer analysis with `SpeechAnalyzer` worked in the test host with no `NSSpeechRecognitionUsageDescription` and no authorization prompt. `Liminal/Info.plist` is unchanged, and no microphone key was added.

## Differences from the research note

- Confidence is `transcriptionConfidence` (a `Double` in `AttributeScopes.SpeechAttributes`). It arrives only when `.transcriptionConfidence` is in `attributeOptions`, so the provider requests `[.audioTimeRange, .transcriptionConfidence]` instead of `[.audioTimeRange]` alone.
- `SpeechTranscriber` exposes no model version. `modelVersion` is "SpeechTranscriber, <OS version and build>".
- `AssetInventory.Status` is `unsupported / supported / downloading / installed`. Readiness uses `isAvailable` plus the supported and installed locale lists, in that order. A download this app starts reports its own progress.
- Locale reservation is not fully automatic for buffer analysis on macOS 27.2 (see the warning above).
- SDK 27 adds `AnalyzerInputConverter` and `AnalyzerInput(buffer: CMReadySampleBuffer)` (OS 27+). They are not used, because the provider must also run on OS 26.

## visionOS

The visionOS Simulator build (Apple Vision Pro, visionOS 27.2 SDK) compiles the same code. This is a compile check only: no inference ran in the simulator.

## Open items for hardware

1. Apple Vision Pro: check `isAvailable`, the installed locales, real-time factor and memory, and whether utility-priority inference disturbs the 2048² render or Lo-Fi audio.
2. When the model is missing, check that "Download model" installs it once, that progress appears, and that the status becomes Ready. This was not exercised because the Mac already had the model.
3. Check whether a signed Release build behaves the same with no usage description (only the debug test host was checked).
4. Measure word-boundary accuracy against hand labels; the refinement in plan 7 snaps to energy minima.
