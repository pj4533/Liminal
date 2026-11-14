# Current music engine (baseline, before the music rewrite)

Packages resolved (Package.resolved): AudioKit 5.6.5, AudioKitEX 5.6.2, SoundpipeAudioKit 5.7.3, KissFFT, Tonic 2.1.0.
**DunneAudioKit is NOT a dependency** (so no DunneAudioKit Sampler/Synth/Chorus/Flanger/StereoDelay/TransientShaper). Chorus/flanger-like effects must be built from `VariableDelay`/`Vibrato`/`Ensemble`/`Phaser`.

Active class: `GenerativeEngine` (`@MainActor ObservableObject`, Liminal/Audio/GenerativeEngine.swift). `AudioEngine.swift` (`LiminalAudioEngine`, one pad voice) is an older prototype and is not referenced by the UI.

## Signal graph

```
Voice 0 Bass    : 2x Oscillator(sine, detune +-0.8%)    -> Mixer -> AmplitudeEnvelope(A 4s, R 8s)  --\
Voice 1 Mid pad : 4x Oscillator(triangle, +-1.5%)       -> Mixer -> AmplitudeEnvelope(A 2.5s, R 6s) --+-> voiceMixer (Mixer)
Voice 2 Shimmer : 1x Oscillator(sine)                   -> Mixer -> AmplitudeEnvelope(A 10ms, R 0.3s)--/
voiceMixer -> [VariableDelay(0.5s) mixed by DryWetMixer(balance=delayMix)]
           -> MoogLadder(cutoff 3k-12k, res 0.15)
           -> CostelloReverb(fb 0.92, cutoff 8k) ; DryWetMixer(filter, reverb, balance=reverbMix)
           -> engine.output  (AudioKit AudioEngine -> AVAudioEngine mainMixer)
```
Everything is mono-sourced oscillators; no panning, so stereo width comes only from CostelloReverb's decorrelated tails. No limiter/compressor on the master bus. Amplitudes: bass 0.25, mid 0.2, shimmer 0.08 (divided across oscillators) - these are summed, the feedback delay + reverb add gain, so headroom is thin (baseline peak -0.14 dBFS).

Oscillators run continuously (`Oscillator` with `Table(.sine/.triangle)`); an `AmplitudeEnvelope` gates audibility. Oscillators are plain wavetable `Oscillator` (not Dynamic, due to click issue noted in code).

## Note generation

- Scale: `Scale(type:, rootMIDI: 48)` (C3). 40+ `ScaleType`s in Scale.swift (modes, pentatonics, Japanese, Arabic, symmetric...). Default pentatonic major. Scale is selectable (`currentScale`); the root never changes (no key changes/modulation).
- Per voice a `MarkovChain` over scale *degrees* (bassDrone / midPad / highShimmer presets). `changeNote` picks `degree = chain.next()`, then `availableNotes[degree % count]` within the voice's MIDI range (bass 36-48, mid 48-72, shimmer 72-84). Note: the degree indexes into the range-filtered note list, so it is not a true scale degree - mapping is approximate and notes cluster at the low end of each range.
- Timing (Swift `Timer` on the main run loop, one-shot, rescheduled each time): bass note every 8-15 s, mid every 4-8 s, shimmer every `noteDuration + gap` where gap is set by the "Notes" slider (0.5-2.5 .. 2-8 s) and noteDuration 50-150 ms (plucky blips, sine, 0.3 s release).
- Frequency changes are **instant** `$frequency.parameter.value =` jumps (no glide) on sustained voices; the envelope is not retriggered, so bass/mid change pitch abruptly while sounding.
- Harmonic intervals: mid voice 25% of the time splits its oscillators (upper half goes +P5/+oct/+m3/+M3). Octave displacement 10% for bass/mid.
- No chords, no harmonic progression, no rhythm/meter, voices are independent (do not know each other's note).
- Randomness: `Float.random` / `Double.random`, unseeded -> every run differs.

## What varies over time vs. what is static

Varies: note pitches (random Markov), shimmer onset timing, ParameterDrift at 10 Hz (`ParameterDrift`, golden-ratio 3-sine sum per channel): reverb mix +-0.15, delay feedback +-0.15, delay mix +-0.15 (all around slider centre), MoogLadder cutoff sweeps 3000-12000 Hz (period ~ 1.5 / 0.04 rad/s...), per-voice amplitude breathing (bass 0.18-0.28, mid 0.14-0.23, shimmer 0.05-0.10, prime-ish periods 17/23/31 s*pi).
Static: timbre of oscillators (fixed waveform per voice, fixed detune), delay time (0.5 s), reverb feedback (0.92), filter resonance, scale/root, stereo image (no pan), voice count, overall density, dynamics/arc (no sections, no build/release), harmonic rhythm, no noise/texture layer, no modulation of the voices themselves (no vibrato, tremolo, FM).

## Controls exposed (ControlsView.swift visionOS, ContentView.swift macOS)

`GenerativeEngine` published: `delay` 0-1 (-> feedback 0.3-0.8, mix 0.2-0.7), `reverb` 0-1 (-> mix 0.3-0.9), `notes` 0-1 (shimmer gap), `currentScale`. Plus `shimmerNotePlayed` PassthroughSubject<Int,Never> (MIDI note) which the visuals can subscribe to (existing image link). `start()/stop()/shutdown()`.

## Threading

Whole class is `@MainActor`. Timers fire on main run loop, hop into `Task { @MainActor }`. Parameter writes use `AUParameter.value` (thread-safe, lock-free to the render thread). Drift timer = 10 Hz main-thread work (about a dozen parameter writes + `Date()`): cheap, but any main-thread stall delays note/param updates (audio render thread itself is unaffected). Audio render is AudioKit's AUv3 DSP on the system audio thread. visionOS: session `.playback + mixWithOthers`, 48 kHz, 100 ms IO buffer, spatial audio bypassed.

## Baseline measurements (5 min, label `baseline`)

See bottom of this file / `scripts/analyze-audio.py` output. Headlines: peak -0.14 dBFS (no clipping samples but only 0.14 dB of headroom), RMS wanders -45..-5 dBFS (std 8.6 dB, loudest at the end), centroid ~285 Hz (very dark, p5-p95 94-507 Hz), only 95 onsets in 5 min, 6 pitch classes, ~8.6 chord changes/min but low-register fifths, spectral novelty between minutes ~0.002 (nearly static timbre), stereo side/mid -5.4 dB.

## Available DSP building blocks

All SoundpipeAudioKit nodes are AUv3 wrappers of Soundpipe C; params are `@Parameter` AUValues (ramped by AudioKit's `rampDuration` where noted). "[C]" = cheap, "[M]" = medium, "[H]" = heavy CPU.

### Generators (SoundpipeAudioKit)
- `Oscillator(waveform: Table)` - wavetable; Table(.sine/.triangle/.square/.sawtooth/.positiveSine ...) or custom harmonic tables (`Table(.harmonic([..]))`). params: frequency, amplitude, detuningOffset, detuningMultiplier. [C]
- `DynamicOscillator` - same but `setWaveform` live (click issue per code comments). [C]
- `MorphingOscillator(waveformArray:[Table], index:)` - crossfades between up to N tables with `index` (0..N-1): evolving timbre pads. [C]
- `FMOscillator` - baseFrequency, carrierMultiplier, modulatingMultiplier, modulationIndex, amplitude: bells, glass, evolving FM pads. [C]
- `PWMOscillator` - pulseWidth (modulate for chorusing, string-pad sound). [C]
- `PhaseDistortionOscillator` - phaseDistortion param, waveform-bending timbres. [C]
- `PhaseLockedVocoder(file/table)` - granular-ish time/pitch stretch of a *loaded* wavetable: needs source sample data (we could feed it a self-synthesized buffer: not a sample asset). `position`, `pitchRatio`. [M]
- Noise: `WhiteNoise`, `PinkNoise`, `BrownianNoise` (amplitude only) - breath, wind, texture beds when filtered. [C]
- Physical models: `PluckedString` (Karplus-Strong; trigger()), `MetalBar` (struck bar/bell; boundary conditions, scanSpeed, strike width/velocity, decay), `VocalTract` (Kelly-Lochbaum voice; frequency, tonguePosition, tongueDiameter, tenseness, nasality: choir "ah/oh" drones). Triggerable via `trigger(frequency:amplitude:)`. No flute/bowed/drip in this package (those are STK, not in AudioKit 5 Soundpipe wrappers) - bowed/flute-like sounds must be approximated (PWM/Morphing + noise + vibrato + formants). [C-M]
- Apple (AudioKit core): `PlaygroundOscillator`, `PlaygroundNoiseGenerator` (simple), `AppleSampler` (needs samples; no).

### Filters (SoundpipeAudioKit)
`MoogLadder`, `DiodeLadderFilter`, `KorgLowPassFilter`, `RolandTB303Filter`, `ThreePoleLowpassFilter` (resonant LPFs); `LowPassButterworthFilter`, `HighPassButterworthFilter`, `BandPassButterworthFilter`, `BandRejectButterworthFilter`; `ResonantFilter`, `ModalResonanceFilter` (ringing, bell-like: feed noise to get tuned drones), `StringResonator` (tuned comb: turns noise/pads into pitched resonances), `FormantFilter` (vowel-ish), `EqualizerFilter`, `PeakingParametricEqualizerFilter`, `LowShelf/HighShelfParametricEqualizerFilter`, `ToneFilter`/`ToneComplementFilter` (1-pole), `DCBlock`. Apple: `LowPassFilter`, `HighPassFilter`, `BandPassFilter`, `HighShelfFilter`, `LowShelfFilter`, `ParametricEQ`. All [C].

### Reverb / delay / time
`ZitaReverb` (best quality: predelay, crossover, low/mid RT60, damping, 2 EQ bands; [M]), `CostelloReverb` (current; feedback + cutoff; [C-M]), `ChowningReverb` (Chowning's classic, dated sound), `CombFilterReverb`, `FlatFrequencyResponseReverb` (allpass: diffusion/shimmer building block), `Convolution` (IR needs a file: could convolve with a self-synthesized IR; [H]), Apple `Reverb` (AVAudioUnitReverb presets), `VariableDelay(time, feedback)` (time modulation = chorus/flange/vibrato; max time set at init), Apple `Delay` (AVAudioUnitDelay with lowpass in feedback path).

### Modulation / pitch / dynamics / distortion
`Tremolo`, `Vibrato`, `AutoPanner` (sine LFO pan), `Panner`, `Phaser` (many params, lfoBPM), `Ensemble` (9 voices of detuned pitch shifts + pans: lush choir/chorus; [M-H]), `PitchShifter` (shift in semitones, windowSize, crossfade: octave-up shimmer reverb loop; [M]), `PitchCorrect`, `AutoWah`, `Vocoder`/`Talkbox` (modulator input needed), `BitCrusher`, `Clipper`, `TanhDistortion`, `DynamicRangeCompressor`, `Balancer`, Apple `Compressor`, `PeakLimiter`, `DynamicsProcessor`, `Expander`, `Distortion`, `Decimator`, `RingModulator`, `TimePitch`/`VariSpeed`/`NewPitch`.
`AmplitudeEnvelope` (ADSR gate), AudioKitEX: `Fader` (ramped gain), `DryWetMixer`, `DryWetDualMixer`, `StereoFieldLimiter`, `CallbackInstrument`, `RenderMeasurer`; `Mixer`, `MatrixMixer`, `Mixer3D`, `EnvironmentalNode` (Apple spatial).

### Automation & sequencing
AudioKitEX `NodeParameter.automate(events:)` / `ramp(to:duration:)` / `AutomationCurve` run sample-accurately on the audio thread - ideal for slow filter sweeps and swells without main-thread timers. `Sequencer`, `SequencerTrack`, `MIDI` on Sequencing (AudioKitEX sequencer works with `Triggerable` nodes, `MIDICallbackInstrument`).
Taps (visual link): `AmplitudeTap`, `FFTTap`, `RawDataTap` (KissFFT) - can drive imagery from the audio.

## Offline render harness

- `Liminal/Audio/OfflineRender.swift`: `OfflineClock` (simulated clock) and `GenerativeEngine.renderOffline(seconds:to:configure:)` - puts the AVAudioEngine in offline manual-rendering mode and steps 50 ms of audio at a time, advancing the clock (note timers) and calling `applyDrift()` every 100 ms. `GenerativeEngine` now schedules via `schedule(after:)` which uses the clock when `offlineClock != nil`, Timers otherwise (realtime behavior unchanged). Any new timed behavior must go through `schedule(after:)` to be rendered offline.
- `LiminalTests/MusicRenderTests.swift`: no-op unless `/private/tmp/liminal-render-config.txt` says `enabled=1` (written by the script).
- `scripts/render-music.sh <label> [seconds]` builds+runs the test (macOS), writes `music-eval/<label>.wav` (32-bit float stereo) and `<label>.json`, prints the analysis. A 60 s render takes ~20 s including incremental build; 5 min renders much faster than real time.
- `scripts/analyze-audio.py file.wav [--json out]` (numpy+scipy only).
- Caveats: renders are random (unseeded); the offline path skips the visionOS audio session and the real-time Timer jitter.

### Baseline analysis JSON
```json
{
 "file": "/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad/music-eval/baseline.wav",
 "sr": 48000,
 "duration_s": 300.0,
 "peak_dBFS": -0.14,
 "true_peak_dBFS": -0.14,
 "clip_samples(|x|>=0.999)": 0,
 "over_0dBFS_samples(|x|>1)": 0,
 "nan_samples": 0,
 "rms_dBFS_mean": -24.83,
 "rms_dBFS_min_max": [
  -44.7,
  -5.0
 ],
 "rms_dB_std_over_time": 8.63,
 "rms_dB_per_30s": [
  -18.1,
  -25.6,
  -30.6,
  -28.8,
  -20.5,
  -30.1,
  -33.9,
  -26.9,
  -20.3,
  -13.4
 ],
 "silence_gaps_gt0.5s": {
  "count": 0,
  "total_s": 0
 },
 "centroid_Hz_mean": 285.0,
 "centroid_Hz_std": 132.0,
 "centroid_Hz_p5_p95": [
  94,
  507
 ],
 "bandwidth_Hz_mean": 521.0,
 "bandwidth_Hz_std": 201.0,
 "centroid_per_30s": [
  220,
  273,
  321,
  351,
  214,
  356,
  427,
  313,
  204,
  165
 ],
 "onsets_total": 95,
 "onsets_per_30s": [
  7,
  12,
  7,
  7,
  3,
  12,
  6,
  6,
  16,
  19
 ],
 "pitch_class_hist": {
  "C": 0.02,
  "C#": 0.194,
  "D": 0.007,
  "D#": 0.071,
  "E": 0.092,
  "F": 0.017,
  "F#": 0.11,
  "G": 0.038,
  "G#": 0.215,
  "A": 0.027,
  "A#": 0.198,
  "B": 0.011
 },
 "pitch_classes_gt5pct": 6,
 "pitch_class_entropy_bits": 2.99,
 "chord_changes_per_min": 8.6,
 "distinct_chords_2s_windows": 15,
 "novelty_between_minutes_chroma_cosdist": [
  0.403,
  0.211,
  0.185,
  0.464
 ],
 "novelty_between_minutes_spec_cosdist": [
  0.0009,
  0.0019,
  0.0015,
  0.0024
 ],
 "self_similarity_10s_mean_offdiag": 0.7479,
 "self_similarity_10s_min": 0.5075,
 "stereo_side_over_mid_dB": -5.4,
 "stereo_LR_correlation": 0.554
}
```
