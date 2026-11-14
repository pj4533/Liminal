# Current music engine

State after PASS 1 and PASS 2 of the rewrite (`docs/plans/music.md`; decisions in `docs/decisions/music.md`, D3-D78). The three-voice engine this replaced is described briefly at the end, together with its baseline measurements.

Packages resolved (Package.resolved): AudioKit 5.6.5, AudioKitEX 5.6.2, SoundpipeAudioKit 5.7.3, KissFFT, Tonic 2.1.0. DunneAudioKit is not a dependency. Everything is synthesized: no samples, no services.

## Shape

- `GenerativeEngine` (`@MainActor ObservableObject`, Liminal/Audio/GenerativeEngine.swift) is a facade. It builds the static audio graph once, starts and stops the AVAudioEngine and forwards controls to `MusicConductor` with `post(_:)`, never waiting on it.
- `MusicConductor` (MusicConductor.swift) runs on its own serial queue `liminal.music` from a 20 ms `DispatchSourceTimer`. It owns time, the seeded RNG, harmony, scenes, layers, rare events and visual coupling, and it is the only writer of AU parameters. Offline renders call the same `advance(to:)` every 20 ms of rendered audio. Nothing on the music path touches MainActor.
- `MusicStateBus` (MusicState.swift) is a seqlock the render loop can read from any thread: scene, phase, intensity, brightness, key, chord, layer levels, shimmer level, last onset and a ring of the last 8 events.

## Signal graph (static, built once)

```
8 layers -> 9 LayerStrips (Lead has a second strip for its answer voice)
  strip = source [-> layer filter] -> Fader(level) -> Panner(pan) --+--> dryBus
                                                                    +--> Fader(reverbSend) -> reverbBus
                                                                    +--> Fader(delaySend)  -> delayBus
delayBus  -> VariableDelay(0.85-1.35 s, wow 0.2 %) -> LPF 2.5-5 kHz -> delayReturn --+--> master
                                                                                     +--> Fader(0.5) -> reverbBus
reverbBus -> ZitaReverb (wet; predelay 60 ms, RT60 3-8 s) -> reverbReturn -> master
reverbBus -> HPF 400 -> PitchShifter +12 -> LPF 5 kHz -> CostelloReverb(fb 0.9) -> shimmerReturn (<= -12 dB, bloom -8 dB) -> master
master Mixer -> HPF 28 Hz -> masterTrim (+3 dB) -> PeakLimiter -> Fader(-1.5 dB) -> engine.output
```

| Layer | File | Sound | Nodes |
|---|---|---|---|
| Drone | Layers/DroneLayer.swift | 6 `Oscillator`s on the pedal: sub, two beating roots, fifth, octave, a roaming partial; LPF 220-1100 Hz | 6 osc, LPF |
| Pad | Layers/PadLayer.swift | 4 voices x detuned pair of `MorphingOscillator`s on 4 band-limited tables, `MoogLadder` 450-6000 Hz, voice-led one voice at a time | 8 osc, ladder |
| Lead + answer | Layers/LeadLayer.swift | 2+2 `VoiceLayer`s (sine + triangle, ramp envelopes), developing motifs, answer replies 40 % of the time, mirrored pan | 8 osc, LPF, 2 strips |
| Drips | Layers/DripsLayer.swift | 4 `FMOscillator`s, sine blip or mallet (1:4) preset per scene, fixed pans -0.8...0.8 | 4 FM |
| Keys / bells | Layers/KeysLayer.swift | 6 `FMOscillator`s, soft keys 1:1 / bell 1:3.5 / glass 1:7, index decays per note, singles, dyads, rolls, phrases | 6 FM, LPF |
| Air | Layers/AirLayer.swift | `PinkNoise` through a band-pass sweeping 300 Hz-5 kHz, pan walk +-0.7, riser for transitions | noise, BPF |
| Grains | Layers/GrainLayer.swift | 8 sine grains (Poisson cloud, 0.5-10/s), 30 % sharp "glints", 4 fixed pan groups | 8 osc |
| Pluck | Layers/PluckLayer.swift | 3 `PluckedString`s, broken chords 250-600 ms apart, mostly to the delay | 3 pluck, LPF |

Cost rules (D33, D68): envelopes are sample-accurate amplitude ramps on the generators, not `AmplitudeEnvelope` nodes; fixed pans use `Mixer.pan`, not `Panner` nodes; a layer silent for 5 s stops its generators; modulation runs at 10 Hz. Release offline render: about 20x realtime on the dev Mac (3.3x the old engine's wall time).

## How the music is made

- **Harmony** (Harmony.swift): one `HarmonicField` (tonic, mode, chord, pedal). Chords are scale-degree templates filtered by a semitone-clash rule; roots move by a Markov chain; chord length lerp(30, 12, intensity) s. The pad voice-leads by minimal motion. The drone pedal holds the tonic (or fifth), and after 40 s may step to the chord root or back (D73). Key and mode drift every 3-8 minutes by one-note pitch-set moves within the style palette, at scene boundaries.
- **Form** (SceneDirector.swift): scenes (stillness, drift, bloom, constellation, tide) of 45-240 s with an intensity arc; layers enter when intensity passes per-scene thresholds; a session curve (7-19 min periods) scales the peaks. Each layer also leans in and out by +-4 dB on its own 45-110 s channel (D72).
- **Rare events** (MusicEvents.swift): every 120-360 s (first after 75-180 s), 8-minute cooldown per kind: arpeggio cascade, shimmer bloom, air swell, sub pulse, bell toll, hush. Events can borrow layers that are not in the scene (`BaseLayer.borrow`).
- **Styles**: Drift (default), Glass, Deep, Garden: palette, scene-kind weights, layer weights, register and brightness bias, form tempo, shimmer amount, keys presets, drips preset (D64).
- **Visual coupling** (VisualCoupling.swift): `setVisualMood` (brightness, warmth, saturation, energy, mood words) is smoothed over 8 s and mapped to capped nudges: brightness and register, warmth tilt of drone/air +-3 dB and chord tension, FM index x0.7-1.4, density x0.7-1.4, shimmer, scene-kind weights and key-move bias from a mood-word table. `imageDidChange` makes an air swell over the transition, advances the chord at the midpoint, re-blooms pad voices and sometimes adds a keys or drips accent. `setVisualActivity` nudges pad detune and delay sends +-15 %. Calling these hooks from the image pipeline is a later integration step.

## Controls (ContentView.swift macOS, visionOS/ControlsView.swift)

| Control | Setting key | Engine |
|---|---|---|
| Style picker (Drift, Glass, Deep, Garden) | `audio.style` | `style` |
| Density slider | `audio.notes` | `density` |
| Space slider | `audio.reverb` | `space` (reverb return and RT60, delay feedback, shimmer) |
| Echo slider | `audio.delay` | `delay` (delay sends and feedback; also drives the visual ghost-tap trail) |
| Scale picker, "Auto (evolving)" first | `audio.scaleAuto`, `audio.scale` | `pinnedScale` (nil = auto) |

`GenerativeEngine.apply(_ settings:)` pushes all of them at launch and after a reset. `shimmerNotePlayed` still fires on the main queue for drips notes.

## Offline render harness

- `GenerativeEngine.renderOffline(seconds:to:limiterBypassed:configure:)` (OfflineRender.swift) renders in manual mode, calling `conductor.advance` every 20 ms, and writes `<label>.score.json` (scenes, layer entries, chords, keys, pedals, rare events, 1 Hz levels, note counts, tick perf) beside the WAV.
- `scripts/render-music.sh <label> [seconds] [seed] [bypass]` (`CONFIG=Release` for realistic speed, `SOLO=<layer>` mutes the others and forces that layer on, `probe` runs the node probes), `scripts/analyze-audio.py`, `scripts/check-music.py <label> --pass 2 --dir <out>` (gates in `scripts/music-criteria.json`).
- Config `mode=bench` prints a node cost table; build Release with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=LIMINAL_BENCH` to bench optimized DSP. `mode=realtime` runs the realtime conductor path against a manual-rendering engine.

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

## The three-voice engine (replaced)

Three independent voices (bass 2x sine, mid 4x triangle, shimmer 1x sine) each through an `AmplitudeEnvelope`, summed into a `VariableDelay`, `MoogLadder` and `CostelloReverb`. Per voice a Markov chain over scale degrees picked notes on main-thread Timers (bass every 8-15 s, mid 4-8 s, shimmer by the Notes slider), with instant frequency jumps, unseeded randomness, no chords, keys, sections or panning, and no limiter (peak -0.14 dBFS). Headlines of its 5-minute baseline: RMS std 8.6 dB, centroid 285 Hz, 95 onsets, 6 pitch classes, spectral novelty between minutes about 0.002, side/mid -5.4 dB.

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
