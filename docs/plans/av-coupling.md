# Audio-visual coupling: plan

Status: implemented. Decisions and their reasons are in `docs/decisions/av-coupling.md` (C1 to C14, I1 to I12).

Goal: the visuals feel alive with the music (motion and colour breathe with phrases, chords and notes) without strobing, without new shader work and without new uniforms. The coupling runs one way: music drives the visuals.

## 0. What exists

| Piece | Where |
|---|---|
| Music snapshot | `Liminal/Audio/MusicState.swift`: `MusicStateBus.read()` (seqlock, lock-free, any thread) and `now()`. The Lo-Fi transport is the single writer. |
| Effect parameters | `EffectsUniformsComputer.compute(...)`, a pure function that takes a `MusicModulation` |
| macOS call site | `VisualDisplayView.effectUniforms` in `ContentView.swift`, evaluated on the main actor each frame |
| visionOS call site | `ImmersiveDomeView`'s render loop |

Facts that shape the design:

- The shader computes `speed * time` (turbulence, hue waves). Changing a speed uniform at large `time` jumps the phase, so no speed uniform is modulated; rates change by integrating a phase on the CPU.
- Ghost taps are skipped by the shader while `transitionProgress > 0.001`, and they do nothing when the Echo slider is 0.
- `hueBaseShift` is `time * 0.03` on macOS and `0` on visionOS when the coupling is off.
- `MusicState` goes stale after Stop while `bus.now()` keeps counting, so the reactor treats a snapshot older than 0.5 s as not alive.

## 1. Code (no new uniforms)

```
Liminal/Visual/MusicModulation.swift   // value type handed to the uniforms computer
Liminal/Visual/MusicReactor.swift      // smoothing state, one per render loop
```

### 1.1 `MusicState`

Time, start uptime, phrase index, intensity, brightness, tonic, chord root, the last onset's time and velocity, the take grid and the recorded beat duration, plus `pulse(at:decay:)`.

### 1.2 `MusicModulation` and `MusicReactor`

`MusicModulation` holds plain floats: `amount` (master wet 0...1, eased), `energy`, `pulseColor`, `pulseMotion`, `fillAccent`, `hueBaseShift`, `motionLead`, `ghostBurstSerial` and `ghostReach`. `.neutral` reproduces the un-coupled output.

`MusicReactor.update(state:now:effectTime:enabled:baseHueRate:)` is a `nonisolated struct` owned by one render loop. `dt = now - lastNow`, clamped to 0.1 s; a call with `dt == 0` returns the cached result, so two evaluations per tick are harmless. Per call:

1. `alive = now > 0 && now - state.time < 0.5`. `amount` eases toward 1 when enabled and alive, else 0, with a 1.5 s time constant. Every deviation from neutral is multiplied by it, so the toggle, Play and Stop fade and never pop.
2. One-pole smoothing: `energy` from `state.intensity` (2 s), `bright` from `state.brightness` (2 s), `pulseColor` (90 ms attack, 450 ms release) and `pulseMotion` (180 ms attack, 900 ms release) from `state.pulse(at: now, decay: 0.35)`, both clamped to 0...1.
3. Harmony to hue: the circle-of-fifths position of the chord root relative to the tonic gives +-0.06 turns (4 s), and of the tonic gives +-0.10 turns (12 s). The same chord always gives the same tint.
4. Brightness to hue drift (a phase accumulator): 0.018...0.042 turns/s, wrapped to 0...1. `baseHueRate` is the un-coupled rate (0.03 on macOS, 0 on visionOS).
5. Intensity to motion: `motionLead` runs the Ken Burns clock at 0.85x to 1.35x. With sync off it stops growing, so there is no jump.
6. Phrase change: when `state.phraseIndex` changes, `ghostBurstSerial` increments and the reach target holds at 1 for 2 s. A kick landmark with enough velocity also schedules one rhythm trail 0.75 beat later, at most every 6 s.
7. `reset()` clears everything when the effect clock restarts. With `-LiminalFreezeTime` the call sites pass `.neutral` and skip the reactor.

### 1.3 `EffectsUniformsComputer.compute(..., music:)`

The computer stays pure and is the single place where music values become uniform values. With `a = music.amount`, every result is clamped to the cap column.

| Uniform | With music | Cap |
|---|---|---|
| `kenBurns*` | `computeKenBurns(time + motionLead)` | same ranges |
| `distortionAmplitude` | `base * (1 + a * (0.35 * energy - 0.15)) + a * 0.004 * pulseMotion`, then the unchanged transition boost | base <= 0.10 |
| `logSphereAmount`, `fractalNoiseAmount` | `* (1 + a * (0.30 * energy - 0.15))` on the base, before the transition boost | 1.2x the old high |
| `chromaticAmount` | `base * (1 + a * (0.30 * energy - 0.10)) + a * 0.002 * pulseMotion` | 0.02 before boost |
| `bloomAmount` | `0.5 + a * 0.12 * pulseColor` | 0.72 |
| `vibranceAmount` | `+ a * (0.06 * pulseColor + 0.07 * fillAccent) * imageFactor` | 0.50 * imageFactor |
| `feedbackMix` | `base + a * (0.08 * energy - 0.04)` | base +-0.04, at most 0.34 |
| `hueBaseShift` | `music.hueBaseShift` | wraps |
| `ghostTapMaxDistance` | `0.06 + a * 0.02 * ghostReach` | 0.08 |

Not strobing, by construction: the fastest path is `pulseColor`, which changes bloom by at most 0.12 of 0.5 and vibrance by at most 0.06, both gains on already bright pixels, not global luminance. Geometry only moves through the 180 ms follower. No sign flips, no toggling between two states, no black frames. Uniforms are computed once per frame and shared by both eyes.

### 1.4 Ghost-tap burst

`GhostTapManager.requestBurst(serial:)`: when the serial changes, two taps are pending. While taps are pending, fewer than 4 are active and 0.4 s has passed since the last spawn, one tap spawns. Four is the steady-state count at Echo = 1, so the shader never runs more taps than it already does. visionOS forwards the serial through `OffscreenEffectsRenderer.requestGhostBurst(serial:)`; macOS forwards it through `EffectsMetalViewRepresentable`.

## 2. Threading

The views receive the engine as a plain `let music: GenerativeEngine` and read only its `nonisolated` `musicState` bus, so they do not re-render when the engine publishes. On macOS the reactor lives in a reference box held in `@State`; on visionOS it is a local `var` in the render loop task. Per frame: one seqlock read, about a dozen one-pole updates and a few `exp` calls, no allocation, no GPU change.

## 3. Setting

`SettingsService`: key `visual.syncToMusic`, default on. UI: "Sync visuals to music" in the Visuals section of both control panels. It fades `amount` over 1.5 s.

## 4. Verification

- `AVCouplingTests`: every cap under extreme modulation, `.neutral` equal to the un-coupled output, the reactor off without music, the circle-of-fifths mapping.
- DEBUG flags: `-LiminalSyncStrength <x>` multiplies `amount` (use 3 to make the coupling obvious in a capture; caps still apply), and `-LiminalSyncLog YES` prints one line per second with the reactor state (`a`, `alive`, `phrase`, `I`, `B`, pulses, hue) and the resulting uniforms.
- Live: macOS and the visionOS simulator with `-LiminalAutoPlay YES -LiminalOpenDome YES -LiminalSyncLog YES`, then `scripts/perf-run.sh` with sync on and off; fps and GPU time must match within noise.

## 5. Open questions

- visionOS gets a slow hue drift it does not have un-coupled whenever sync is on (C6). If that is unwanted, set the synced rate there to `0.03 * 0.8 * (bright - 0.5)`.
- Amounts are deliberately small. `-LiminalSyncStrength` exists to find out quickly whether they should be doubled.
