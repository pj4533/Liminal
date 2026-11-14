# Generative Ambient Music via Pure Synthesis: Research

Goal: make Liminal's engine (3 voices, Markov notes, delay/MoogLadder/CostelloReverb) far richer and more evolving, using only synthesis (no samples, no services), cheap on CPU on visionOS.

## Sources

Fetched/searched this session (verified claims only):
- Reverb Machine, "How Brian Eno Created Ambient 1: Music for Airports" - https://reverbmachine.com/blog/deconstructing-brian-eno-music-for-airports/ (tape loops of different lengths phase against each other; short loops of 1 to 4 notes, even a single piano note; Eno has said ~22 loops). Note: the sources do not confirm "mathematically incommensurable" lengths; the principle is simply unequal lengths.
- Reason Studios, "Building shimmer reverb" - https://reasonstudios.com/news/post/building-shimmer-reverb (reverb -> octave pitch shift -> back into reverb; pre-delay; shifted return on its own level).
- Eventide ShimmerVerb / Tiptop Z-DSP Shimmer product pages (pitch intervals of 4th/5th/octave, +/-12 st, filters in feedback loop, pitch shifters either inside or parallel to the reverb).
- Coverage of Eno/Chilvers "Reflection" app (BrooklynVegan, AV Club, Tiny Mix Tapes, Village Voice): the album is one take of a process; the app generates endless variation; rules change with time of day (thinner, slower notes at certain times). Endel (art.art interviews): "functional" soundscapes, minimal non-gamified UI (company claims).

From general domain knowledge (not re-verified here; treat as design heuristics): Stars of the Lid / Basinski (slow-evolving layered drones, tape decay/degradation), Harold Budd soft piano, Chowning FM (bell/electric piano ratios), Frippertronics (long delay feedback with layered sustained input), granular synthesis (Roads, Microsound), Karplus-Strong plucked strings, Generative.fm (Alex Bainter; open-source generative systems built on Tone.js with many incommensurate scheduling loops), Eno's Bloom (Eno/Chilvers) and Scape.

## Observations about the current engine

- Three voices (drone/pad/shimmer), one scale at a time, Markov note choice, timers on MainActor (Timer-based scheduling is jitter-prone but fine for ambient).
- Single serial effects chain (delay -> Moog -> Costello). All voices share it, so no per-layer space, no stereo movement.
- Little macro structure: no sections, no key/mode motion, no rare events, no link to imagery beyond the shimmer note event.

## Prioritized techniques (all synthesis-only)

Tier 1: biggest perceptual gain for lowest CPU/risk

1. **Incommensurate loop/scheduler clocks (Eno).** Give each layer its own period drawn from non-integer-ratio values (e.g. 17.3s, 23.1s, 29.7s, 31.9s) and let each repeat a short motif of 1 to 4 notes. Cycle alignment shifts every pass, creating "never repeats" feel at near-zero cost. Hint: a `LoopLayer` with its own `Task.sleep`/timer, motif array, per-repeat probability of dropping/changing a note, and a slow random-walk on its period.
2. **Pad voices that really move.** Detuned oscillators (3 to 7, +/- 3 to 12 cents) with slow independent LFOs on detune, plus per-voice slow filter sweeps. Use `MorphingOscillator` (SoundpipeAudioKit) with a slowly drifting `index` across sine/triangle/square/saw tables, or `DynamicOscillator` with `waveform` morphing. Beating partials come free from small detuning; vary beat rate 0.05 to 0.5 Hz.
3. **Per-voice filter + per-voice reverb sends and stereo placement.** Put a `PannerStereo`/`Panner` per voice with slow sinusoidal or random-walk pan (periods 20 to 90s, golden-ratio spaced like SmoothOscillator). Give each layer a lowpass (`LowPassButterworthFilter` or `KorgLowPassFilter`/`MoogLadder`) driven by ParameterDrift. Cheap and adds width.
4. **Macro-form: scenes with tension/release arcs.** A `SceneDirector` that every 60 to 180s picks the next scene (density, register, brightness, mode, active layers) and interpolates all targets over 10 to 30s. Use a slow "intensity" curve (sum of 2 to 3 slow sines, 5 to 20 min) to scale note density, filter cutoff, reverb, layer count. Never hard-cut; crossfade amplitude and cutoff.
5. **Harmonic rhythm: slow chord/pedal movement.** Hold a root pedal 40 to 120s while upper voices move through voicings (sus2/sus4, add9, quartal stacks, maj7/6, m9). Chord change every 20 to 60s with voice leading by minimal motion (each voice moves to the nearest chord tone, max 2 to 3 semitones). Slow overlap: new notes fade in (5 to 10s attack) before old ones release (8 to 15s).
6. **Key/mode drift over long timescales.** Modulate between related modes (Ionian/Lydian/Mixolydian/Dorian/Aeolian; modal interchange; relative or circle-of-fifths neighbors) every several minutes; change only 1 to 2 scale degrees per move so it feels like a gradual color shift. Use pitch-class set sharing to select next mode.

Tier 2: new textures

7. **Shimmer reverb (pitch-shifted feedback).** `PitchShifter` (Soundpipe) +12 st (and optionally +7) on a reverb send, mixed back with low gain (<=0.35) through a lowpass at about 4 to 6 kHz inside the loop to stop runaway; keep loop gain < 1. Mix parallel "shimmer return" in its own level. CPU: PitchShifter is cheap relative to a convolution reverb; use one shared instance, not per voice. Drive amount from imagery energy.
8. **Better reverb.** Replace/augment `CostelloReverb` with `ZitaReverb` (richer, longer, with damping/mid-frequency decay) if available in the pinned SoundpipeAudioKit; use one global instance with per-voice sends to keep CPU bounded. Add 2 to 3s pre-delay to separate dry notes from tail.
9. **Tape-delay character (Frippertronics/Basinski).** Long feedback delay (3 to 9s, near 0.7 to 0.85 feedback) with lowpass + slight wow/flutter (time modulation of `VariableDelay.time` by 0.2 to 1% at 0.3 to 3 Hz) and soft saturation (`TanhDistortion`, low drive) in the loop, so repeats degrade and blur. Basinski-style "decay": each pass loses highs and adds noise; slowly lower loop cutoff over a scene.
10. **Soft FM keys (Budd/Chowning).** `FMOscillator` with carrier:modulator ratio 1:1 or 1:14 (electric piano/bell family), modulation index decaying quickly (0.5 to 2 to near 0 over 1.5s) via envelope, slow release, very low velocity. Gives soft piano-like notes without samples. Detune a second FM voice by 2 to 5 cents for chorus.
11. **Plucked/bowed textures.** `PluckedString` (Karplus-Strong) with long decay for harp-like accents in the upper register, or `Clarinet`/`Flute` physical models (Soundpipe) at very low gain with filtered output for breathy tones. Sparse (one note per 8 to 20s).
12. **Noise textures: air, rumble, swell.** `PinkNoise`/`BrownianNoise` through a `BandPassButterworthFilter`/resonant filter with slowly swept center (200 Hz to 6 kHz) and amplitude LFO; looks like wind/tape hiss/breath. Use as transition risers: swell over 6 to 12s, exponential decay. Very low CPU. Keep at -30 to -40 dBFS.
13. **Granular-style clouds from synthesized sources.** Soundpipe has no live grain engine for synthesized input, so emulate it: spawn many short (80 to 400 ms) sine/FM "grains" with random pitch from the current chord (spread +/-1 octave), random pan, Hann-like envelope, density 2 to 30 per second following intensity. Implementation options: pool of 16 to 32 pre-created `Oscillator + AmplitudeEnvelope` nodes (never allocate in the render path), retrigger round-robin from a lightweight scheduler. Alternative: feed a short `Delay` with a pitch-shifted tap for "freeze"/cloud feel.
14. **Drones with beating partials.** Root + fifth + octave drone made of 2 to 3 oscillators per partial with slightly different detuning (0.03 to 0.3 Hz offsets); add a sub (sine) one octave under; harmonic series partials at 2f, 3f, 5f that fade in/out slowly (additive pad, 6 to 12 `Oscillator`s). Cheap and very "Stars of the Lid".

Tier 3: melody, events and rhythm

15. **Motif development instead of pure Markov.** Keep a 3 to 5 note motif; each repeat apply transformation randomly (transpose by scale step, invert, drop a note, augment rhythm x2, retrograde), with occasional return to the original. Combine with weighted random walk (stepwise bias, rare leaps, repeat notes, rest probability 30 to 50%). Markov chain order-2 for the shimmer voice, motif-based for a "lead" layer.
16. **Call and response.** Two registers/voices: when voice A plays a phrase, voice B answers after a random 2 to 6s with the same contour transposed (diatonic) or its inversion at lower velocity, panned opposite.
17. **Sparse soft percussion that stays ambient.** Soft mallets: FM bell/marimba (ratio 1:3.5 or 1:4, short envelope) at low density, pitched to the chord; "drips": short sine blips with a filtered delay and pan scatter (Bloom-like); sub-bass heartbeat optional at < 40 bpm equivalent with long envelope. Use probabilistic Euclidean/irregular placement (not a grid). Lowpass heavily and send mostly to reverb.
18. **Rare "events" (flourishes).** Every 2 to 6 minutes at random: arpeggio cascade up through the chord (12 to 20 notes, 120 to 300ms apart, decreasing velocity), a reversed-swell (noise or pad that rises then cuts into reverb), a deep sub pulse, an octave-up shimmer burst, or a "key change" shimmer pad. Cooldowns prevent clustering. Pair each with a visual hook (see 21).
19. **Stereo and spatial movement.** Slow auto-pan per layer (technique 3), a stereo widener via tiny differing delays on L/R (Haas, 5 to 25ms, modulated), and moving filter. For visionOS spatial audio: keep render in stereo (cheap) unless spatial audio is explicitly desired; consider per-layer `AVAudioEnvironmentNode` positions only if CPU proven fine.
20. **Dynamic range & anti-clipping.** Master `Compressor` (soft, ratio 2:1 to 3:1, slow attack/release) plus `PeakLimiter` at the end; per-layer gain staging with headroom -6 to -10 dBFS; all parameter changes ramped (AudioKit `RampDuration` or timer-smoothed) to avoid zipper noise/clicks.

Linking music to visuals

21. **Image-change events -> transition swells.** On each image crossfade: start a noise riser + shimmer-return swell over the crossfade duration, then bloom of 1 to 3 chord tones (long attack) at crossfade midpoint; harmonic rhythm advances (new chord) on image change so music and visuals share beats. Use a shared clock: the same `transitionProgress` that drives shader crossfade drives swell amplitude.
22. **Color/brightness -> timbre and mode.** Compute cheaply per image (average luminance, mean hue, saturation, and edge/contrast energy; do it once at image load in the image pipeline and publish through a small `ImageMood` struct): brightness -> filter cutoff + register + major/Lydian vs minor/Aeolian bias; saturation -> FM index/shimmer amount; warm hue (red/orange) -> lower register, more drone, close voicing; cool hue (blue/teal) -> wider quartal voicings, more air noise; contrast/edge energy -> grain density and note density. Smooth with 5 to 10s lag.
23. **Shader parameters as modulation sources.** The shader pipeline already has oscillators (Ken Burns, distortion, hue shift). Expose a read-only `VisualState` (distortion amount, hue shift phase, ghost-tap intensity) and map them to audio targets (distortion -> detune spread / granular density; hue phase -> slow filter LFO phase; ghost taps -> delay feedback taps). Rule: the audio should follow visuals at slow rates (<= 1 Hz) to avoid obvious "audio-reactive" tackiness.
24. **Shared global clock.** One monotonic `MusicClock` (seconds) used by `SmoothOscillator`-like modulation for both audio and visuals so slow movements correlate across modalities.
25. **Time-of-day / session-length adaptation (Reflection/Endel).** Thin and slow things in "late" hours or after long sessions; slowly lower intensity for sleep-friendly mode; offer a "Calm / Flow / Bright" macro control.

## Design principles from modern generative apps

- Variety comes from many slow, independent processes (Generative.fm, Eno loops), not one clever one; sum of incommensurate cycles.
- Constrain the pitch set tightly (consonance guaranteed) and move the constraint slowly; surprising but never dissonant.
- Silence and density curves matter as much as notes: Reflection lowers density at some times; build gaps (rests) into every layer.
- Functional/non-gamified UI (Endel): fewer controls than currently; consider macro knobs (Mood, Density, Space) instead of raw effect sliders.
- Everything long and smooth: attacks 2 to 10s, crossfades 10 to 30s; avoid sudden changes except designed events.

## Performance guidance for real-time Swift/AudioKit

- Build the graph once at init; never add/remove nodes while playing (clicks, graph rebuild stalls). Use gain-gated, pre-created voices.
- Soundpipe nodes run in the audio unit render thread (C); the Swift cost is only parameter setting. Use `AUParameter.value` setters (as EffectsChain already does) at low rate (<= 20 Hz) per parameter, batched in one MainActor timer; prefer ramped changes.
- Budget: about 24 to 40 oscillators, 1 to 2 reverbs, 1 shimmer pitch shifter, 1 delay is comfortably light on Apple silicon; avoid per-voice reverbs and avoid > 2 `PitchShifter`s.
- Keep scheduling off busy MainActor paths: a single scheduler tick (e.g., 20 to 30 Hz) that dispatches events rather than a Timer per voice.
- Pre-compute scales/voicings; no allocation in tight loops.
- Verify offline: render with AudioKit `renderToFile`-style tool or `AVAudioEngine` manual rendering mode, analyze with numpy/scipy (peak, RMS, spectral centroid over time, spectral flux, autocorrelation for repetition) to check non-repetition, no clipping, and slow evolution.

## Recommended implementation order

1. 20 (limiter/gain) + 3 (per-voice pan/filter) + 2 (moving pads)
2. 4/5/6 (scenes, chord/pedal movement, mode drift)
3. 7/8/9 (shimmer, better reverb, tape delay)
4. 10/17/15/16 (FM bell/keys, drips, motifs)
5. 12/14/13 (noise, additive drone, grain clouds)
6. 18 (events) then 21 to 23 (visual links)
