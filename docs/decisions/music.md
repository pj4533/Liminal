# Music decisions log

Format: decision / why / alternatives.

## D1. Offline harness drives the real GenerativeEngine through a simulated clock
- What: `GenerativeEngine.schedule(after:)` replaces direct `Timer`s; `OfflineClock` replaces timers in offline renders. Harness lives in the app target (`OfflineRender.swift`) so the test target needs no AudioKit linkage.
- Why: lets a 5-minute piece render in seconds using the exact production code path, so analysis reflects reality.
- Alternatives: pumping RunLoop in real time (slow); re-implementing the generator inside the test (drifts from production); AudioKit `renderToFile` alone (cannot advance Timers).
- Note: unseeded randomness, so numbers vary run to run; compare trends, not decimals.

## D2. Analysis uses numpy/scipy only
- Why: no extra deps; chord detection = triad/sus/power-chord chroma templates over 2 s windows; onsets = log-spectral flux peaks; novelty = cosine distance of per-minute mean log-spectrum / chroma.

---

# Design decisions (plan: docs/plans/music.md)

Made autonomously at design time, before any of the new engine is built. Items marked "verify" depend on a PASS 1 probe and name their fallback.

## D3. Evolve `GenerativeEngine` into a facade over a new `MusicConductor`; keep the class name and public surface
- Why: both UIs and the offline harness keep compiling; the old three-voice logic cannot grow layers, form or shared harmony.
- Alternatives: patch features into the existing class (it is MainActor and Timer bound, see D4); a parallel second engine with a toggle (two code paths to maintain, no benefit).

## D4. The conductor runs on a dedicated serial queue with a 20 ms `DispatchSourceTimer`, not on MainActor
- Why: visionOS's 90 fps loop starves MainActor (documented in `AtomicImageBuffer.swift`), and today every note is a main-run-loop Timer. `AUParameter` writes are thread-safe.
- Alternatives: keep MainActor Timers (late or bunched notes under load); a Swift actor with `Task.sleep` (timing less predictable, harder to step offline); sequencing on the audio thread via `CallbackInstrument` or AudioKitEX `Sequencer` (runs Swift on the render thread: glitch risk).

## D5. One `advance(to:)` entry point for realtime and offline; `OfflineClock` and `schedule(after:)` are replaced by `MusicScheduler`
- Why: the offline render exercises exactly the production logic and becomes deterministic. Supersedes the mechanism in D1, keeps its intent.
- Alternatives: keep the MainActor `OfflineClock` beside a realtime queue (two scheduling paths).

## D6. Event tick 50 Hz, continuous modulation 10 Hz with 0.1 s ramps
- Why: 20 ms onset jitter is inaudible in ambient material but keeps arpeggio cascades even; 10 Hz ramped modulation is smooth and costs a few dozen parameter writes.
- Alternatives: a single 10 Hz tick (100 ms jitter is audible in cascades and grains); sample-accurate scheduling (not needed, far more complex).

## D7. All gains, cutoffs, pans and frequencies are ramped via `NodeParameter.ramp` (verify)
- Why: removes the abrupt pitch jumps and zipper steps of the current engine with no extra nodes.
- Fallback: conductor-side 50 Hz glides on `AUParameter.value`.
- Alternatives: `Fader`/envelope nodes per parameter (more nodes); AudioKitEX automation curves (heavier API, same effect).

## D8. Seeded SplitMix64 RNG, forked per subsystem
- Why: reproducible offline renders (fixes the "unseeded" caveat in D1) and stable streams when a layer is added. Realtime uses a random seed per launch.
- Alternatives: `SystemRandomNumberGenerator` (not reproducible); one shared stream (any change reshuffles everything).

## D9. Build the whole graph once; inactive layers sit at gain 0
- Why: adding or removing nodes while playing clicks and can stall. Research doc guidance.
- Alternatives: dynamic graphs per scene (rejected for glitch risk).

## D10. Per-layer strip: one filter, level fader, panner, reverb send, delay send; one shared reverb and one shared delay
- Why: per-layer space and stereo placement were the biggest structural gap; shared effects keep CPU bounded.
- Alternatives: per-voice filters and pans (node count explodes); the current single serial chain (no depth, no width).

## D11. `ZitaReverb` replaces `CostelloReverb` as the main reverb; Costello is kept only inside the shimmer path
- Why: Zita has separate low/mid decay and damping and is the best reverb in the pinned package. Costello is cheap and adequate for an already-diffuse shimmer.
- Note: Zita's predelay is limited to 10-100 ms in this version, so the research doc's 2-3 s predelay is not possible; the delay bus supplies long pre-echo.
- Alternatives: Apple `Reverb` presets (less control); `Convolution` (heavy, needs an impulse response).

## D12. Shimmer is feed-forward: reverb send, `PitchShifter` +12, lowpass, small reverb, own return (PASS 2)
- Why: AudioKit graphs cannot contain feedback cycles, and feed-forward cannot run away.
- Alternatives: true feedback shimmer (not expressible in the graph); `Ensemble` (heavier); no shimmer (loses a signature ambient colour).

## D13. Tape character sits after the delay, not inside its loop
- Why: `VariableDelay`'s feedback is internal and cannot be filtered. Lowpass and light `TanhDistortion` after the delay, plus the reverb, give the blur.
- Alternatives: build a multi-tap delay from several delay nodes with filters between (more nodes for a subtle gain).

## D14. Master: 28 Hz highpass, `PeakLimiter`, then a fixed -1.5 dB trim; no bus compressor
- Why: the baseline had 0.14 dB of headroom. The trim after the limiter guarantees true peak at or below -1 dBFS. Ambient dynamics should breathe, so levels are controlled by gain staging and the limiter must stay idle (enforced by a limiter-bypassed render peaking at or below -3 dBFS).
- Alternatives: compressor plus limiter as the research doc suggests (pumping risk on long swells; can be revisited by ear in PASS 2); `StereoFieldLimiter` (does something else).

## D15. Eight layers: drone, pad, lead (+answer), keys/bells, drips/mallets, air, grains, pluck
- Why: covers bed, harmony, melody, soft percussion and three kinds of texture, at about 44 generators.
- Alternatives considered and dropped: `VocalTract` choir (hard to keep from sounding synthetic-vocal), `MetalBar` bells (FM bells are cheaper and more controllable), `PhaseLockedVocoder` granular (needs a loaded buffer), `Ensemble` chorus (heavy).

## D16. The existing shimmer voice survives as the Drips layer and still fires `shimmerNotePlayed`
- Why: it is the recognisable sound of the current app and the only existing audio-to-visual link. It moves to a four-voice FM pool so notes can overlap and later become mallets.
- Alternatives: delete it (loses continuity); keep the single-oscillator version (notes cut each other off).

## D17. Drips and keys use `FMOscillator` pools; index 0 gives a pure sine
- Why: one voice type covers blips, soft keys, bells, glass and mallets by preset, so percussion needs no extra layer.
- Alternatives: separate sine, bell and mallet pools (more nodes).

## D18. Pad uses `MorphingOscillator` pairs with custom band-limited tables (verify)
- Why: timbre morphing was absent (spectral novelty 0.002). Default square and saw tables alias and are too harsh.
- Fallback: two fixed-table oscillators per voice cross-faded by amplitude, if morphing clicks.
- Alternatives: `PWMOscillator` (stringier, one dimension of change); `DynamicOscillator` (known click issue in this codebase).

## D19. Shared `HarmonicField` (tonic, mode, chord); every layer resolves scale degrees through it at play time
- Why: the old voices did not know each other's notes. A shared field guarantees consonance and makes chord and key changes apply everywhere at once. Also fixes the "degree indexes a range-filtered list" bug.
- Alternatives: per-layer scales (current behaviour); a fixed chord chart (repeats).

## D20. Chords are scale-degree templates filtered by one rule: no semitone clash inside the chord, no tritone over the pedal
- Why: works on any of the 50 scales without hand-written tables and keeps everything sweet.
- Alternatives: a hand-written chord table per mode (only practical for seven-note modes); chromatic chord vocabulary (risks leaving the ambient idiom).

## D21. Chord roots move by a `MarkovChain` preset; harmonic rhythm 18-60 s tied to intensity; drone holds a pedal for 40-120 s
- Why: reuses existing code; pedal under moving voicings is the core ambient harmony move. Target is 1-3 real chord changes per minute.
- Alternatives: random chord choice (aimless); functional progressions (too song-like).

## D22. Pad voice leading by minimal total motion, one voice at a time through a dip, retune, swell
- Why: chord changes become slow cross-fades with three voices always sounding. Long portamento between chord tones was rejected as seasick.
- Alternatives: retrigger all voices together (audible seam); pure glides.

## D23. Key and mode drift = any (tonic, mode) in the style palette whose pitch set differs by at most one note; only at scene boundaries, every 3-8 minutes
- Why: one generic rule yields parallel-mode, relative and fifth moves, each a gentle colour shift. Weighting by brightness lets imagery steer it later.
- Alternatives: a fixed mode cycle (predictable); free modulation (jarring); no modulation (static over 30 minutes).

## D24. Form is scenes of five kinds (stillness, drift, bloom, constellation, tide) with a raised-cosine intensity arc; layers enter by per-scene thresholds on that curve
- Why: gives sparse, bloom, dissolve without scripted cues, and the order in which layers enter changes each scene. A floor of 0.12 and overlapping scenes prevent silence.
- Alternatives: explicit per-layer timelines per scene (more code, more repetition); a single free-running intensity LFO without scenes (no contrast in instrumentation).

## D25. A slow session curve (437 s and 1151 s sines) scales scene peaks
- Why: blooms differ in size over 7-19 minutes, so the piece has shape beyond one scene.
- Alternatives: time-of-day adaptation (deferred; needs product input).

## D26. Each note layer is an Eno-style loop with a non-integer period re-rolled per scene and drifting 4 % per cycle; the lead develops a 3-5 note motif
- Why: cheapest source of endless variation; motif development (transpose, invert, retrograde, drop, augment, recall) gives melody an identity that pure Markov lacked.
- Note: the research doc found no evidence that Eno's loops were "mathematically incommensurable"; unequal, drifting periods are enough.
- Alternatives: keep Markov for melody (kept only for drips and chord roots).

## D27. `MusicState` is a fixed-size POD struct published through a seqlock on `Synchronization.Atomic`; events ride in an 8-slot ring with sequence numbers
- Why: the render loop can read at 90 fps without locks or MainActor; the single writer never blocks. Deployment targets (macOS 26, visionOS 26) have `Synchronization`.
- Alternatives: `os_unfair_lock` as in `AtomicImageBuffer` (simple, but a reader can briefly block the conductor); `@Published` (MainActor, starved on visionOS); Combine subjects (allocation, threading ambiguity); a lock-free queue for events (more code than a ring for at most a few events per second).

## D28. Layer levels in `MusicState` are conductor targets, not measured audio; no taps
- Why: taps cost CPU and deliver on other threads. Targets are smooth and exactly what the visuals need.
- Alternatives: `AmplitudeTap` per layer (eight taps); one master tap (possible later if a true output meter is wanted).

## D29. Visual inputs are `setVisualMood(VisualMood)`, `imageDidChange(transitionDuration:)` and optional `setVisualActivity`, smoothed over 8 s and capped
- Why: the music should follow imagery slowly and never sound "audio-reactive" in reverse; user Style and Density stay dominant. Image changes advance the chord so both media share moments.
- Scope: hooks and minimal mapping in PASS 1, full mapping in PASS 2. Calling them from the image pipeline is a later integration step outside this workstream.
- Alternatives: the music reading shader uniforms directly (couples workstreams); mood words driving style switches outright (too jumpy).

## D30. UI becomes Style picker, Density slider, Space slider, Scale picker with "Auto (evolving)" first (PASS 2)
- Why: macro controls match what a listener wants to change; raw delay and reverb sliders expose plumbing. Reusing the `audio.notes` and `audio.reverb` keys preserves saved values.
- Alternatives: keep three effect sliders (no way to choose character); add many per-layer mixers (not simple).
- PASS 1 changes no UI: Notes maps to density, Reverb to space, Delay to delay send and feedback.

## D31. The default Scale value "Pentatonic Major" is treated as Auto until the user touches the picker (PASS 1), then an explicit `audio.scaleAuto` setting (PASS 2)
- Why: existing users should get evolving harmony without a settings migration; anyone who chose a scale keeps it.
- Alternatives: always honour the stored scale (most users would never hear key drift).

## D32. Four styles: Drift (default), Glass, Deep, Garden
- Why: enough range to matter, few enough to tune properly. Each is a table of palette, layer weights, scene weights and biases.
- Alternatives: a continuous mood pad (harder to tune and explain); a dozen presets (untuned).

## D33. Node budget about 125 nodes (44 generators, 2 reverbs, 1 pitch shifter, 1 delay), enforced by measurement
- Why: slightly above the research doc's 24-40 oscillator guideline, so it is gated: offline render at least 15x realtime and at most 4x the baseline wall time, with a stated order of cuts (grains, keys, rumble).
- Alternatives: cap at 40 generators now (would drop grains before knowing they are a problem).

## D34. Acceptance is numeric and seeded: three 5-minute seeds and one 30-minute render against `scripts/music-criteria.json`, plus a score log
- Why: turns "more varied, more layers" into checks: centroid, novelty, onsets, chord rate, layer activity, silence, peak, stereo, repetition, CPU. The score log (scenes, layer levels, chords, events) is how "layers audible" and determinism are verified without stem renders.
- Alternatives: solo-stem renders per layer (eight times the render time); listening only (not repeatable). Listening remains necessary and is not replaced by the numbers.

## D35. Split: PASS 1 = conductor, scheduler, state bus, harmony, scenes, mix bus, four layers (drone, pad, lead, drips), harness; PASS 2 = four more layers, shimmer, tape, rare events, visual mapping, styles, UI, cleanup
- Why: PASS 1 already fixes headroom, stereo, form and harmony at about 60 nodes and is a safe floor if PASS 2's CPU cost needs trimming.

## D36. Remove `AudioEngine.swift` (unused prototype) and `EffectsChain.swift` (replaced by `MixBus`) in PASS 2 cleanup
- Why: dead code after the change. `VoiceLayer`, `MarkovChain`, `Scale`, `ParameterDrift` are kept and extended.

---

# PASS 1 implementation decisions

Made while building PASS 1 (conductor, harmony, scenes, mix bus, drone/pad/lead/drips). Numbers quoted are from Release-config renders, seeds 1-3, 5 minutes (`CONFIG=Release scripts/render-music.sh s<seed> 300 <seed>`), unless noted.

## D37. Probes passed; no fallbacks needed
- What: `MusicProbes.swift` (DEBUG only, `scripts/render-music.sh probe`, checked by `scripts/analyze-probes.py`) rendered four small graphs offline.
- Results: fan-out of one `Panner` into three `Fader`s/`Mixer`s sums exactly (peak ratio 1.750 for gains 1+0.5+0.25); a 10 s `Fader` gain ramp is linear within 0.4 % in offline manual rendering; a 4 s `Oscillator` frequency ramp is exact; `ZitaReverb` + `PeakLimiter` run offline with no NaN, peak held at 1.0; `MorphingOscillator` with the custom tables shows no clicks under 0.25 s frequency/index changes (max second difference 1.3x the 99.9th percentile).
- Also learned: `Panner` at centre is equal-power (-3 dB), so every strip trim includes a 1.414 make-up factor.
- Alternatives: none needed; the D7/D10/D14/D18 fallbacks in plan section 13 stay documented but unused.

## D38. All music types are explicitly `nonisolated`
- What: every type on the music path (RNG, state, scheduler, harmony, scenes, conductor, mix bus, layers, `VoiceLayer`, `MarkovChain`, `Scale`, `ParameterDrift`) is declared `nonisolated`; only `GenerativeEngine` is `@MainActor`.
- Why: the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Without the annotation every new class would silently be MainActor-isolated and the conductor queue would trip runtime isolation checks (or force hops onto the starved main thread). The drips-to-`shimmerNotePlayed` closure is built in a `nonisolated static` function for the same reason.
- Alternatives: change the project default (affects other workstreams); `@preconcurrency`/`nonisolated(unsafe)` sprinkling (fragile).

## D39. The plan's `Scene` type is named `MusicScene`
- Why: `Scene` collides with SwiftUI's `Scene` protocol in the app target (`LiminalApp: App` stopped compiling).

## D40. `LayerContext` is a class; layers derive from a `BaseLayer` that owns activation fades, scheduled-block cancellation and generator power-down
- What: the plan sketched `LayerContext` as a struct. It is a final class held by the conductor, because layers capture it in scheduled blocks and it carries `emit`. `BaseLayer` provides `after(_:ctx:_:)` (blocks are dropped after silence/power-down via a generation counter), `ensureLoop` (one self-rescheduling loop per generation), and stops its generators (AudioKit `stop()` = bypass = zero DSP) after 5 s of silence.
- Why: removes duplicated bookkeeping from every layer and makes silent layers free. `HarmonyEngine` is reachable through the context so the pad can voice-lead.
- Alternatives: per-layer copies of the same logic; struct context passed `inout` (cannot be captured by scheduled blocks).

## D41. Layer level fades are software envelopes (`SoftEnv`, smoothstep) written as 0.12 s ramps at 10 Hz
- Why: a 30 s `ramp` on the level fader would be overridden by any later write (breathing, swells). Advancing the fade in software and writing short ramps keeps one writer per parameter and gives `MusicState.layerLevels` the exact current value. Same mechanism for pad voice swells/dips and drone glides.
- Alternatives: one long `ramp` per fade (conflicts with modulation); a second fader per strip (more nodes).

## D42. Gain staging retuned by measurement, not by the plan's peak table alone
- What: strip trims (peak-equivalent): drone -24 dB, pad -4 dB, lead -15 dB, drips -17 dB (each times the 1.414 pan make-up). Drone partials rebalanced (sub 0.22, roots 0.22, fifth 0.10, octave 0.08, roam 0.10).
- Why: the first render was 61 % energy below 120 Hz, 0.06 % above 2 kHz, and the drone's F/C were 79 % of the chroma (pad chords inaudible). Solo renders (`SOLO=<layer>`) showed the drone 12 dB above the pad. After retuning: drone about 7 dB below the pad in RMS, 6-7 pitch classes above 5 %.
- Alternatives: keep the plan's per-layer peak targets (they assumed equal crest factors; the pad's 8 detuned oscillators have a much lower RMS per peak than the drone).

## D43. Harmonic rhythm faster than the plan: chord length lerp(42, 16, intensity) +-25 %, clamped 14-50 s
- Why: the plan's lerp(55, 20) gives about 1.4 changes per minute at typical intensity, below its own 2-8 per minute gate and slower than wanted for "more movement". Now 2.2-3.0 measured changes per minute.
- Also: chord-root Markov weights flattened (tonic 1.6 instead of 3.0) and `openFifth` down-weighted (0.5/0.15), because the tonic chord plus a tonic pedal made the harmony read as one long chord.
- Alternatives: keep slow harmony and only change voicings (still static in chroma).

## D44. Brightness macro widened: `B = 0.5 + 0.3 scene + 0.3 (I - 0.4) + 0.2 (mood - 0.5) + 0.12 drift`
- Why: with the plan's 0.25/0.2/0.1 coefficients the centroid standard deviation was 210-248 Hz (gate 250). Cutoff ranges also moved up: pad 450-6000 Hz (was 350-4900), drone 220-1100 Hz (was 180-900).

## D45. Drone pedal range 36-47 (C2-B2), not 33-45
- Why: with a 33 pedal the sub partial (pedal - 12) sits at 27 Hz, below the 28 Hz master high-pass. 36-47 keeps the sub at 33-62 Hz.

## D46. Lead uses two alternating `VoiceLayer`s in PASS 1
- Why: with one gated voice, retuning for the next note bends the previous note's 3-5 s release tail. Alternating voices lets tails overlap cleanly; PASS 2's answer voice gets its own pair.
- Alternatives: one voice with a long glide (sounds like a slide whistle in the tail).

## D47. Drips get per-voice `Panner`s and a brightness-dependent FM colour
- What: 4 extra panner nodes; ratio 1:2 by default, 1:3 or 1:3.5 in bright scenes, index (0.4 + 1.6 B) x velocity decaying over 0.7 s.
- Why: per-note pan +-0.8 (plan) needs per-voice panning because notes overlap; the pure-sine blip had almost no energy above 2 kHz.

## D48. Scene layer sets are drawn from the layers that exist
- Why: in PASS 1 the "feature" layer of a drift scene was often keys/grains/pluck (not built yet), leaving drone + pad only and no melody for minutes. Constellation scenes always include drips. PASS 2 widens the pools automatically as layers are added.

## D49. The opening drone fades in over 4-6 s (other entries 8-30 s)
- Why: the first render's first 30 s averaged -34 dBFS; the app should not start in near-silence after pressing Play.

## D50. Analyzer chroma uses its own 16384-point FFT; chord-change rate counts changes that persist 6 s
- What: `analyze-audio.py` computed chroma from 4096-point frames starting at 55 Hz. With 11.7 Hz bins (wider than a semitone below about 200 Hz) the drone on F2 showed up as E and F#, which are not in the key. Chroma now comes from a 16384-point STFT (2.9 Hz bins, 60-2000 Hz) on the same frame grid. `chord_changes_per_min_stable` ignores template flicker shorter than three 2 s windows (raw value is still reported).
- Baseline re-analysed with the new analyzer (`baseline-v2.json`): self-similarity mean 0.666 (was 0.75), chroma novelty 0.465, stable chord changes 4.0/min.
- Alternatives: keep the old chroma (it measured the drone's spectral leakage, not harmony).

## D51. New harness pieces
- `scripts/check-music.py <label> --pass N [--bypass <label>]`: PASS/FAIL table against `scripts/music-criteria.json` (gates tagged with the pass that enforces them), using the analysis JSON and the score log.
- `scripts/render-music.sh <label> [seconds] [seed] [bypass]`, `CONFIG=Release` for optimized DSP, `SOLO=<layer>` to mute all other layers, `probe` label for the node probes.
- Test modes (config file `mode=`): `render` (default), `probe`, `bench` (node cost table), `realtime` (realtime conductor smoke test, below).
- The score log (`<label>.score.json`) lists scenes, layer enter/exit, chords, keys, pedal moves, note counts and 1 Hz levels; everything except `perf` is deterministic per seed.

## D52. Realtime smoke test instead of a speaker run
- What: `mode=realtime` runs the real conductor start path (own queue, 20 ms `DispatchSourceTimer`, debug `dispatchPrecondition(.notOnQueue(.main))`) against the engine in manual-rendering mode pumped at wall-clock pace, so nothing plays out loud during automated runs. 20 s result: state time 19.98 s, audio peak 0.10, no isolation traps.
- Not done in PASS 1: the 10-minute live macOS listening/dropout session from section 11 (needs a person listening); visionOS hardware check is out of scope per the plan.

## D53. PASS 1 results and the one unmet gate
- Gates met on seeds 1-3 (5 min, Release): true peak -7.5 to -9.1 dBFS, 0 clipped samples, 0 NaN; limiter-bypassed peak -9.1 dBFS (limiter idle); no silence; RMS mean -25.1 to -25.6 dBFS, RMS std 4.5-5.0 dB; centroid mean 520-590 Hz, std 259-332 Hz; stable chord changes 2.2-3.0 per minute; side/mid -6.6 to -7.0 dB, L/R correlation 0.64-0.67, below-120 Hz correlation 0.97-1.0; 4 layers active, at most 3 at once (4 possible), 4 scene changes per 10 min; conductor tick mean 0.004-0.009 ms, max 0.24-1.5 ms across runs; identical score log for the same seed.
- Speed: Release offline render 22-25x realtime; 300 s takes 12-13 s against 4.38 s for the baseline engine (2.8-3.0x, gate 4x). Debug builds are about 9x realtime because the AudioKit/Soundpipe C++ is unoptimized (bench: a Fader costs about 21 ns/frame, a Panner 42 ns/frame in Debug); `CONFIG=Release` is the meaningful number.
- Unmet: `self_similarity_10s_mean_offdiag` 0.78-0.83 (gate 0.65; re-analysed baseline 0.67). Why: the metric averages a log-spectrum cosine and a chroma cosine. The log-spectrum half is 0.99 for every render including the baseline, so the gate effectively requires a chroma cosine of 0.31 or less between any two 10 s windows. A held tonic pedal plus voice-led chords that share common tones keep chroma similarity at 0.57-0.75; the baseline's unrelated random notes score 0.34. Pushing it lower in PASS 1 would mean removing the pedal or forcing unrelated harmony, which works against the ambient brief. Proposal for review: replace this gate with chroma novelty between minutes (0.10-0.45, already a PASS 2 gate) plus the 30-minute key-change and minute-pair chroma-distance gates, or re-target it to 0.80 for PASS 1 and reassess after PASS 2 adds four layers and key drift over longer renders. The gate is left at 0.65 in `music-criteria.json` so the gap stays visible.
- PASS 2 gates still failing, as expected with four layers: onsets (4-19 per 5 min, gate 150-600), energy above 2 kHz (0.3-1.2 %, gate 1.5 %), centroid p95, spectral novelty, minimum simultaneous layers.
- 3-minute `pass1` render (Debug harness, seed 1): true peak -9.6 dBFS, RMS -26.0 dBFS, centroid 500 Hz (std 311), side/mid -6.7 dB. The 10-minute gates (scene changes, layers active) cannot be met in 3 minutes and fail there by construction.

## D54. `AudioEngine.swift` removed in PASS 1, `EffectsChain.swift` kept until PASS 2
- Why: the unused `LiminalAudioEngine` prototype called `VoiceLayer.start/stop`, which the ramped `VoiceLayer` no longer has; deleting it was cheaper than keeping dead code compiling (D36 planned its removal anyway). `EffectsChain` still compiles and is now unused; it goes in the PASS 2 cleanup as planned.
