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
