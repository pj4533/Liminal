# Technical research for MPC-style dialogue chopping and mix work

Date: 2026-11-19. Companion to [mpc-chopping-handoff.md](mpc-chopping-handoff.md). Scope: Swift on macOS 26 / visionOS 26 (Xcode 27.2).

Evidence labels: **[doc]** read on sosumi.ai during this session; **[wwdc]** WWDC25 session 277 transcript via sosumi.ai; **[known]** standard DSP literature or prior knowledge, not re-fetched this session; **[verify]** must be tested on the target machine before relying on it. No code in this note has been compiled or benchmarked.

## 1. Apple Speech: SpeechAnalyzer, SpeechTranscriber, DictationTranscriber

### 1.1 API shape [doc]

- `SpeechAnalyzer` is a `final actor` (Sendable), available iOS/iPadOS/Mac Catalyst/macOS/tvOS/**visionOS 26.0+**.
  - `init(modules:options:)`; convenience inits that start immediately: `init(inputSequence:modules:options:analysisContext:volatileRangeChangedHandler:)` and `init(inputAudioFile:modules:options:analysisContext:finishAfterFile:volatileRangeChangedHandler:)`.
  - Structured: `analyzeSequence(_:)` (async sequence of `AnalyzerInput`) and `analyzeSequence(from: AVAudioFile)` both return the last sample time (`CMTime?`) when input is consumed.
  - Autonomous: `start(inputSequence:)`, `start(inputAudioFile:finishAfterFile:)`.
  - Finishing: `finalizeAndFinish(through:)`, `finalizeAndFinishThroughEndOfInput()`, `finish(after:)`, `cancelAndFinishNow()`; `finalize(through:)`; `cancelAnalysis(before:)`.
  - `prepareToAnalyze(in: AVAudioFormat?)` preloads resources to cut startup delay. `bestAvailableAudioFormat(compatibleWith:)` and `(compatibleWith:considering:)` return the format the modules want; convert buffers to it first.
  - `AnalyzerInput(buffer:)` or `AnalyzerInput(buffer:bufferStartTime:)`; `bufferStartTime` is the timecode when audio has gaps, which is how to feed non-contiguous chunks with correct timing.
- `SpeechTranscriber` (module): `init(locale:preset:)` or `init(locale:transcriptionOptions:reportingOptions:attributeOptions:)`. Static `supportedLocales` (includes downloadable), `installedLocales`, `isAvailable`. Docs say to check these and fall back to `DictationTranscriber` when unsupported. Available on all platforms except watchOS.
- `SpeechTranscriber.Preset` (final names) [doc]: `transcription`, `transcriptionWithAlternatives`, `timeIndexedTranscriptionWithAlternatives`, `progressiveTranscription`, `timeIndexedProgressiveTranscription`. The WWDC transcript uses beta names (`.offlineTranscription`, `.progressiveLiveTranscription`); use the final names above or the explicit initializer.
- For offline file work the explicit form is simplest: `SpeechTranscriber(locale:, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])`. Without `.volatileResults` only final results arrive [wwdc].
- Results: `for try await result in transcriber.results`; `result.text` is an `AttributedString`; `result.isFinal`; `result.range`. Each run carries `audioTimeRange: CMTimeRange` when `.audioTimeRange` was requested [wwdc]. Iterate `result.text.runs` and read `run.audioTimeRange` for per-word timing (runs are word-level in practice [verify]). A confidence attribute (`transcriptionConfidence` in the `SpeechAttributes` scope) is documented in the framework [known][verify exact spelling]; request via attribute options if present, else treat all as unknown and rely on acoustic checks.
- Time base: audio time is relative to the first sample fed (plus any `bufferStartTime`). The planner must keep an explicit map from source file time to analyzer time to cue time.

### 1.2 Minimal offline recipe for a cached clip

```swift
let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [], attributeOptions: [.audioTimeRange])
guard SpeechTranscriber.isAvailable else { return nil }          // fall back
try await ensureAssets(for: t, locale: locale)                    // see 1.3
let analyzer = SpeechAnalyzer(modules: [t])
async let words = collectWords(t.results)                         // consume concurrently
let file = try AVAudioFile(forReading: url)                       // 16 kHz mono extract is cheaper
if let last = try await analyzer.analyzeSequence(from: file) {
    try await analyzer.finalizeAndFinish(through: last)
} else { await analyzer.cancelAndFinishNow() }
return try await words
```

Wrap in a `Task` with a deadline: race against `Task.sleep`; on timeout call `analyzer.cancelAndFinishNow()` and cancel the task. Results must start consuming before analysis, otherwise the sequence can stall [wwdc pattern]. Run at `.utility` priority, never on the audio thread; nothing in this path touches the realtime renderer. Transcribing a trimmed speech-bearing region (not the whole film) keeps work inside the scheduling lead.

### 1.3 Asset lifecycle (AssetInventory) [doc][wwdc]

1. Check `SpeechTranscriber.supportedLocales` then `installedLocales` (compare via `identifier(.bcp47)`).
2. `AssetInventory.assetInstallationRequest(supporting: [transcriber])` returns an optional request; `try await request.downloadAndInstall()`; `request.progress` is a `Progress`. Downloads may finish instantly if preinstalled or shared with another app.
3. Locale reservation is automatic; apps have a limited number (`maximumReservedLocales`, `reservedLocales`, `release(reservedLocale:)`; the WWDC transcript says `allocatedLocales`/`deallocate`, an earlier naming). Assets persist across launches and are shared; the system can drop unused ones.
4. `AssetInventory.status(forModules:)` reports state without starting a download.
5. Models live in system storage, outside app memory and bundle size [wwdc]. A first-run download needs network once; Liminal must treat "not installed" as acoustic-fallback, kick off the download only from an explicit user setting or at idle, and never block playback on it. Offline afterwards, no silent server fallback.

### 1.4 Authorization, Info.plist, sandbox

- The WWDC session shows only microphone permission for live capture. `SpeechTranscriber` file analysis is not documented as using `SFSpeechRecognizer.requestAuthorization`, so `NSSpeechRecognitionUsageDescription` is likely not required for on-device SpeechAnalyzer on files, whereas legacy `SFSpeechRecognizer` does require it **[verify by running a signed build with the key absent]**. Adding the key is harmless; do not add a microphone key since Liminal does not capture the mic. Do not change signing settings.
- Sandbox: network only for the one-time asset download (the app already has client network for Gemini/Internet Archive). No extra entitlement is documented for the model [verify].
- Locale: the Archive footage is mostly English; `Locale(identifier: "en_US")` is the safe default. Filter per clip by SoundAnalysis/language guess or skip transcription for non-English.

### 1.5 visionOS and simulator

Symbols exist on visionOS 26.0+ [doc]. Whether the simulator has the model/Neural Engine path, or `isAvailable` returns true, is unknown **[verify]**; code must treat `isAvailable == false`, missing assets and thrown errors as normal and use the acoustic path. Tests should inject a `TranscriptProvider` protocol with a fixture implementation and avoid requiring the real framework in CI.

### 1.6 DictationTranscriber and legacy SFSpeechRecognizer

- `DictationTranscriber`: same languages/devices as the iOS 10 on-device recognizer; no Siri/dictation enablement needed; use as the fallback when `SpeechTranscriber` locale is unsupported [wwdc]. Same `SpeechAnalyzer` module interface.
- Legacy `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true`, `supportsOnDeviceRecognition` check, `shouldReportPartialResults = false`; `SFTranscriptionSegment` gives `timestamp`, `duration`, `confidence` [known]. Needs authorization and `NSSpeechRecognitionUsageDescription`; has per-request length limits and macOS/visionOS availability caveats [known][verify]. Treat as a last resort; prefer the analyzer API.

### 1.7 Latency expectations

No numbers are published [wwdc]. Plan to measure: real-time factor on a 30 s speech excerpt on Apple silicon, first-run model load, and cancel latency. Design rule: the planner gets a deadline equal to the scheduling lead minus margin; a plan built from acoustic analysis is always published first and the transcript-refined plan replaces it at the next valid bar boundary only if it arrives in time.

## 2. Onset detection and drum landmarks

Sources: Bello et al. tutorial on onset detection; Dixon 2006; Böck and Widmer superflux; madmom; librosa `onset_strength`; aubio specdiff/complex/hfc [known].

- **Multiband spectral flux** (recommended base): STFT with 1024 window at 44.1/48 kHz and hop 128-256 (3-5 ms). Log-compress magnitude `log(1+C|X|)` with C near 100-1000, half-wave-rectified frame difference, summed per band. Bands for drums: kick 30-150 Hz, snare body+crack 150-3k and 3-8k, hat 6-16k. Use superflux's max-filter over the previous frame across ±1 bin to suppress vibrato/ringing false positives. Compute per-band novelty independently, do not sum before picking, so a quiet hat under a loud kick survives.
- **HFC** (sum of k·|X_k|²) favors broadband clicks/hats; **complex-domain** (phase deviation + magnitude) helps soft tonal onsets (bass notes, sample bed) but costs more. For drum takes: multiband log flux; for pitched bass/mids: complex-domain or energy flux on 80-800 Hz.
- **Adaptive threshold**: `thr[n] = median(odf[n-m..n+m]) * λ + δ` (or mean + λ·std), m ≈ 0.1-0.2 s, with a minimum inter-onset gap per band (kick 50 ms, snare 60 ms, hat 25 ms). Peak-pick local maxima over `odf > thr`, pre/post-max windows 3-5 frames, post-avg window, wait time. These are starting values to tune on hand labels.
- **Attack vs peak**: STFT flux peaks lag the true attack by up to a window half-length. Refine: take the candidate frame, search backward in the time-domain band-passed (or raw) envelope to the point where it crosses ~10-20% of local peak (or the last zero-crossing before it), giving the attack landmark; store `attackTime`, `peakTime`, `peakLevel`, and band. Compensate analysis latency by `windowSize/2 - hopOffset` and verify against a click track with known positions.
- **Kick/snare/hat discrimination without ML**: ratio features at the landmark in a 20-40 ms window: low-band (30-150) energy fraction, spectral centroid, high-band fraction, 150-400 Hz body, zero-crossing rate. Kick: LF fraction > ~0.6, centroid low; hat: HF fraction > ~0.6 with short decay; snare: mid + HF with broad noise. Add decay time (time to -20 dB) to split open vs closed hat. Emit a confidence and drop ambiguous hits rather than guessing.
- **Sparse shared timing field**: quantize attack landmarks against the bar grid, keep only high-confidence kick/snare, and publish an offset-in-ms per beat position with decay, so other roles snap toward them without altering AJ's audio.
- Runs offline per take (already cached beat-grid catalog); no realtime cost.

## 3. Speech segmentation without ASR

- **Syllable nuclei** (de Jong and Wempe 2009, Praat script) [known]: intensity contour (smoothed ~ 50 Hz hop), peaks above `median + 2 dB` (threshold relative to the 99th percentile minus 25 dB), require a dip of at least 2 dB between peaks, and require voicing at the peak (pitch exists). Without Praat use an energy envelope in 300-3000 Hz plus a voicing proxy (autocorrelation peak > 0.3 in 70-400 Hz, or low zero-crossing rate). Output: nuclei times, speech rate, usable as stress/beat anchors.
- **Phrase boundaries**: smoothed energy (10 ms frame) below an adaptive floor (`noise + 6 dB`) for at least 150-250 ms marks a pause; breaths and bed music make this unreliable, so combine with SoundAnalysis speech confidence and the existing three-band envelopes. Rank phrases by duration 0.8-4 s, ratio of speech frames, level consistency and clean edges.
- **Cut points**: cut at the nearest local energy minimum within ±30 ms of the boundary, preferably at a zero crossing; keep plosive preservation by *starting* a cut 10-25 ms before a burst (burst detection: sharp wideband HF rise after near-silence) and ending after the tail or decay of the final vowel, never inside a closure that sounds like clipping. Apply 2-6 ms raised-cosine fades for hard cuts (5-15 ms when the edge is energetic), and keep context ("pre-roll") before an anchor.
- **Stress anchors** for beat alignment: local maxima of `energy + a·pitch-slope` among nuclei; align the stressed syllable's attack to the grid, not the phrase start.
- With ASR on: word times from `audioTimeRange` replace nuclei boundaries (still snap to the nearest energy minimum), and enable reordering only when the transcript covers the phrase with sufficient confidence and sentence-level punctuation.

## 4. Pitch-preserving time stretch on Apple

| Option | Notes |
|---|---|
| `AVAudioUnitTimePitch` (AUNewTimePitch) | System quality, rate 1/32-32, `overlap` 3-32; realtime graph node. Latency and phasey/transient smearing on speech at large ratios; fine within 0.85-1.15. Offline use: `AVAudioEngine` manual rendering mode or `AudioUnit` offline render to produce a cached buffer ahead of time. |
| `AVAudioUnitVarispeed` / plain resample | Linked pitch and speed; zero artifacts, pitch shifts by `12·log2(rate)` semitones. Within about ±3-4% it is barely audible on speech, ±10% is a noticeable chipmunk/lag. Boom-bap chop style tolerates this and even wants it. |
| WSOLA (time-domain) | Best for speech: window ~20-30 ms, hop 50%, search range ±5-10 ms via cross-correlation (vDSP_conv or FFT). Preserves transients if you bypass stretching near detected onsets. Cheap, offline-friendly, implementable with Accelerate. |
| Phase vocoder (vDSP FFT) | Smooth for tonal sound but smears plosives and gives phasiness; use phase locking and transient resets. Worth it only for textural fills. |

Linked-rate maths: output duration = source duration / r; pitch ratio = r; semitones = 12·log2(r). To fit a stressed anchor at source time `s` onto grid time `g` with phrase start at `p`: choose `r = (s - p) / (g - p_out)` and clamp (e.g. 0.92-1.08); if outside, either shift the start (earlier pickup) or choose a different pad. Keep the source-to-output time map so ASR word times and cue times convert cleanly. Preferred policy: use native rate, then linked rate within ±5%, then offline WSOLA for larger fits, rendering ahead into a cached `AVAudioPCMBuffer` so the realtime path only schedules a buffer at a sample time (no allocation or DSP on the audio thread).

## 5. Bass synthesis for punchy hip-hop

[known] production practice:

- **Voices to compare** (three bounded):
  1. *Round sub*: sine/triangle fundamental, slow attack 3-8 ms, long sustain, gentle tanh; best under busy kicks.
  2. *808-style*: sine with pitch envelope from about +12 to +24 semitones above target, decaying in 20-60 ms (exponential), amplitude decay 300-900 ms, soft saturation for harmonics so it reads on small speakers. Tune to the key.
  3. *Plucked/sampled upright or electric*: short click plus body; filter envelope low-pass 300-1500 Hz closing in 80-200 ms. Existing sampled bass can serve as the comparator.
- **Transient click**: 2-5 ms band-limited noise or 1-3 kHz burst mixed at around -20 dB under the body; adds attack without raising low-end energy.
- **Saturation**: tanh or asymmetric waveshaping with oversampling (2x, or 4x if aliasing is visible) at the shaper only; add second/third harmonics (parallel, 15-30% wet) while keeping sub energy below 120 Hz mono. High-pass saturated parallel path at ~120 Hz.
- **Kick/bass alignment**: align the bass attack landmark to the kick attack within ±1-2 ms or deliberately offset by >5 ms; avoid partial overlap that causes phase cancellation. Check by summing kick+bass 30-120 Hz and comparing RMS to the incoherent sum (should not drop below it by more than ~1-2 dB); check polarity by correlating the low-passed waveforms in the first 30 ms; flip bass polarity if negative. Duck bass 2-4 dB for 60-120 ms (fast attack, 80-150 ms release) triggered by kick landmarks rather than sidechain-pumping the whole bus.
- Keep sub below 120 Hz mono; high-pass non-bass buses at 100-250 Hz.

## 6. Accelerate (vDSP) implementations

### 6.1 STFT
Use `vDSP.DiscreteFourierTransform`/`vDSP_DFT` or `vDSP.FFT` (`FFT<DSPSplitComplex>`, `vDSP_create_fftsetup`). Pattern: precomputed Hann window (`vDSP.window(ofType:usingSequence:count:isHalfWindow:)`), multiply with `vDSP.multiply`, real FFT of size N=1024/2048 via `vDSP_fft_zrip`, magnitudes with `vDSP.squareMagnitudes` or `vDSP_zvabs`, mel/band sums with a sparse matrix or `vDSP_dotpr`. Allocate buffers once per analyzer (offline analysis threads only). Scaling: `vDSP_fft_zrip` output is doubled; divide by 2 (and by N for energy normalization). Use `vDSP_Length(log2(N))`.

### 6.2 LUFS (ITU-R BS.1770-4 / EBU R128) [known]
- K-weighting: stage 1 high shelf (+4 dB, ~1.68 kHz, Q≈0.707) and stage 2 high-pass (~38 Hz, Q≈0.5). Coefficients at 48 kHz are published in BS.1770; for other rates derive via the bilinear transform. Implement as two biquads (`vDSP.Biquad` or `vDSP_biquad`) per channel; resample to 48 kHz first when the render is 44.1.
- Mean-square over 400 ms blocks with 75% overlap; channel weights 1.0 for L/R. Loudness = `-0.691 + 10·log10(Σ G_i z_i)`.
- Integrated: absolute gate -70 LUFS, then relative gate (mean of gated blocks - 10 LU). Short-term: 3 s window; momentary: 400 ms. Loudness range: 10th to 95th percentile of short-term blocks after relative gate (-20 LU).
- Targets: streaming music around -14 LUFS integrated; "competitive" lo-fi is frequently -12 to -9 LUFS short-term with true peak <= -1 dBTP. The user wants loud and clean; recommend reporting -14, -11 and -9 candidates with crest factor (peak minus RMS in dB; keep PLR >= ~9 dB to avoid squashed sound).

### 6.3 True peak
BS.1770-4 Annex 2: upsample 4x (48 kHz material), take absolute max; 48-tap polyphase FIR. Simple implementation: oversample by 4 with a windowed-sinc polyphase filter, apply with `vDSP_desamp`-style convolution or `vDSP_conv`; report dBTP. For limiting, use lookahead 1.5-5 ms, true-peak detection on 4x oversampled signal, and release 50-200 ms auto-release. Report limiter gain reduction stats (mean, 95th percentile, max, fraction of time GR > 3 dB); target mean GR 1-3 dB, peaks <= 6 dB, no consistent fast modulation.

### 6.4 Verification analyses to build (offline Swift or Python scripts beside existing `scripts/analyze-lofi.py`)
- Per-bus stem export (drums, bass, mids, melody, dialogue, bed, master) by tapping the offline render graph.
- Multi-resolution spectrograms (window 4096 for low end, 1024 mid, 256 transients), PNG under the scratchpad.
- Per-band energy per bus in about 8 bands; masking matrix: for each band, bus level minus summed other buses' level; flag bands where a featured bus sits below others by > 6 dB.
- Mono low-band sum: L+R vs L, S/M ratio and correlation below 120 Hz.
- Kick/bass window analysis: windows 0-120 ms after each kick landmark; low-band RMS of kick, bass and their sum.
- Dialogue intelligibility proxies: speech-band (300-3400 Hz) level versus the rest of the mix, band SNR in 1/3-octave bands weighted by SII band importance, or an STOI approximation on the chop stem vs mix; ensure ducking 2-5 dB under chops.
- Chop-change cadence: log pattern id/bank id per bar from the scheduler; assert change at least every 16 bars; detect repeats via hashing the cue sequence.
- Documentation: extend `docs/development.md#lo-fi-checks` with commands and thresholds.

## 7. Per-bus effect chains and master (good-practice reference) [known]

| Bus | Chain sketch | Spectral space |
|---|---|---|
| Drums | HPF 30 Hz, gentle tape saturation, bus comp 2:1 slow attack (preserve transients), short room | Owns 50-100 Hz kick and 2-5 kHz snare/hat air |
| Bass | LPF about 5 kHz after saturation, HPF 35 Hz, mono below 120 Hz, kick-triggered duck | 40-120 Hz plus 700 Hz-1 kHz harmonics |
| Mids/shells | HPF 200 Hz, notch/scoop 300-500 Hz, light chorus, plate reverb sent high-passed | 300-3 kHz, ducked under lead/dialogue by 2-3 dB |
| Melody/lead | HPF 150 Hz, presence 2-4 kHz lift +1.5 dB, delay (1/8 dotted) filtered, reverb pre-delay 20-40 ms | 500 Hz-4 kHz |
| Dialogue chops | HPF 120-150 Hz, low-mid cut 250 Hz, 2-4 kHz presence, de-ess 6-8 kHz, short slap delay and small room, ducks bed 3-6 dB | 300 Hz-4 kHz |
| Film bed | HPF 100 Hz, LPF about 8 kHz, wide stereo, dip under chops (bounded), lowered reverb | Gets air above 5 kHz and the 150-300 Hz body |
| Master | Gentle bus compressor 1.5-2:1 (1-2 dB GR), tilt EQ, mono-sum check, soft clip or saturation 0.5-1 dB, true-peak lookahead limiter (ceiling -1.0 dBTP) | Target -11 to -9 LUFS short-term, PLR >= 9 dB |

## 8. Implementation guidance for the coding session

1. Keep all analysis (onset, segmentation, transcript, stretch rendering) on a utility-priority actor; publish immutable plan structs to the scheduler at bar boundaries.
2. Transcript provider protocol with `AppleSpeechTranscriptProvider`, `NullProvider`, and a test fixture; 100% acoustic fallback; per-plan deadline; token checks so late results are discarded.
3. Deterministic seeding for pattern grammar so tests can assert cadence (change within 16 bars).
4. Add Swift Testing tests for cut points, onset landmarks on synthetic clicks, WSOLA length accuracy, K-weighting against a reference tone (1 kHz at -23 LUFS), and true peak on an intersample-peak signal (a sine at fs/4 with a 45 degree phase offset reads about +3 dB over sample peak).
5. Do not change signing or entitlements as a workaround; test `isAvailable` and install state at runtime.

## Open items to verify empirically
- Whether SpeechTranscriber file analysis needs a speech-recognition usage description on macOS and visionOS.
- Model availability and speed on the visionOS simulator versus device.
- Confidence attribute name and run granularity.
- Real-time factor and cancel latency.
- Onset threshold constants on AJ Hall takes against hand labels.

## Sources

- https://sosumi.ai/documentation/speech/speechanalyzer
- https://sosumi.ai/documentation/speech/speechtranscriber
- https://sosumi.ai/documentation/speech/speechtranscriber/preset
- https://sosumi.ai/documentation/speech/assetinventory
- https://sosumi.ai/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app
- https://sosumi.ai/videos/play/wwdc2025/277 (WWDC25 Bring advanced speech-to-text to your app with SpeechAnalyzer)
- https://sosumi.ai/documentation/speech/dictationtranscriber (not fetched; referenced by the session)
- ITU-R BS.1770-4 and EBU R128 / Tech 3341 (LUFS, true peak, gating)
- Bello et al., "A Tutorial on Onset Detection in Music Signals," IEEE TSALP 2005
- Dixon, "Onset Detection Revisited," DAFx 2006
- Böck and Widmer, "Maximum Filter Vibrato Suppression for Onset Detection," DAFx 2013
- aubio, librosa (`onset_strength`, `onset_detect`) and madmom documentation
- de Jong and Wempe, "Praat script to detect syllable nuclei and measure speech rate automatically," Behavior Research Methods 2009
- Verhelst and Roelands, "An overlap-add technique based on waveform similarity (WSOLA)," ICASSP 1993
- Apple Accelerate vDSP documentation (https://sosumi.ai/documentation/accelerate/vdsp)
- Apple AVAudioUnitTimePitch / AVAudioUnitVarispeed documentation (https://sosumi.ai/documentation/avfaudio/avaudiounittimepitch)
