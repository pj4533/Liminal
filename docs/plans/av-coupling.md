# Audio-visual coupling: plan

Status: design only, nothing implemented. Decisions and their reasons are in `docs/decisions/av-coupling.md` (C1 to C14).

Goal: the music should follow the imagery (each new image changes how the music feels) and the visuals should feel alive with the music (motion and colour breathe with scenes, chords and notes), without strobing, without new shader work and without new uniforms.

## 0. What exists today

| Piece | Where | State |
|---|---|---|
| Music snapshot | `Liminal/Audio/MusicState.swift`: `MusicStateBus.read()` (seqlock, lock-free, any thread), `now()` | published 10 Hz plus on every event, nobody reads it |
| Visual inputs to music | `GenerativeEngine.setVisualMood / imageDidChange / setVisualActivity` (all `nonisolated`, post to a locked inbox) | implemented in `VisualCoupling.swift` and `MusicConductor`, never called |
| Image description | `ImageMetadata` (spec: moods, energy, warmth, palette; measured brightness, saturation, 5 dominant colours) via `imageBuffer.loadCurrentWithMetadata()` | stored, never consumed |
| Effect parameters | `EffectsUniformsComputer.compute(time:transitionProgress:hasSaliencyMap:ghostTapCount:vibrance:)` | pure function of time |
| macOS call site | `VisualDisplayView.effectUniforms` in `ContentView.swift:337`, evaluated in SwiftUI `body` on MainActor at 60 Hz (`EffectController` timer) | |
| visionOS call site | `ImmersiveDomeView.swift:415` inside the render loop `Task` (MainActor today) | |
| Crossfade start, macOS | `VisualDisplayView.onChange(of: visualEngine.currentImage)` -> `TimerDrivenCrossfade.transitionTo` (1.5 s) | |
| Crossfade start, visionOS | render loop, `generation != transitionState.lastGeneration` at `ImmersiveDomeView.swift:359` (1.5 s) | |

Facts that shape the design:

- The shader computes `speed * time` (turbulence, hue waves). Changing a speed uniform at large `time` jumps the phase. So no speed uniform is modulated; rates are changed by integrating a phase on the CPU.
- Ghost taps are skipped by the shader while `transitionProgress > 0.001`, and they do nothing when the Echo slider is 0.
- `hueBaseShift` is `time * 0.03` on macOS and `0` on visionOS.
- `MusicState.events(after:)` allocates. The per-frame path uses only counters (`sceneIndex`, `chordChangeCount`, `keyChangeCount`, `lastOnsetTime`).
- `MusicState` goes stale after Stop (the conductor timer is cancelled) while `bus.now()` keeps counting.
- `VisualCoupling.table` matches only 5 of the 10 `Mood` values (serene, ominous, playful, electric, melancholy).

## 1. New code (three small files, no new uniforms)

```
Liminal/Visual/MusicModulation.swift   // value type handed to the uniforms computer
Liminal/Visual/MusicReactor.swift      // smoothing state, one per render loop
Liminal/Visual/VisualMoodBuilder.swift // ImageMetadata + pixels -> VisualMood
```

### 1.1 `MusicModulation` (plain floats, `nonisolated`, `Sendable`)

```swift
nonisolated struct MusicModulation: Sendable, Equatable {
    var amount: Float = 0        // master wet 0...1 (toggle, music alive), eased
    var energy: Float = 0.4      // smoothed scene intensity 0...1
    var pulseColor: Float = 0    // onset envelope, fast (colour and glow)
    var pulseMotion: Float = 0   // onset envelope, slow (geometry)
    var shimmer: Float = 0       // smoothed shimmer return level 0...1
    var air: Float = 0           // smoothed air layer level 0...1
    var hueBaseShift: Float = 0  // integrated hue phase + harmony offset (turns)
    var motionLead: Float = 0    // seconds added to the Ken Burns clock
    var ghostBurstSerial: UInt32 = 0  // increments on a scene change
    var ghostReach: Float = 0    // 0...1 swell after a scene change
    static let neutral = MusicModulation()
}
```

### 1.2 `MusicReactor` (`nonisolated struct`, owned by one render loop, not shared)

```swift
mutating func update(state: MusicState, now: Double, effectTime: Float,
                     enabled: Bool, baseHueRate: Float) -> MusicModulation
```

`now` is `bus.now()` and is passed in, so the offline check can drive it with simulated time. `dt = now - lastNow`, clamped to `0...0.1`. A call with `dt == 0` returns the cached result, so the two evaluations per tick on macOS (body plus the Ken Burns log `onChange`) are harmless.

Per call:

1. `alive = now > 0 && now - state.time < 0.5`. `amountTarget = (enabled && alive) ? 1 : 0`, eased with a 1.5 s time constant. Every deviation from neutral below is multiplied by `amount`, so the toggle, Play and Stop all fade in and out and can never pop.
2. One-pole smoothing (`x += (target - x) * (1 - exp(-dt / tau))`):

| Signal | Source | tau |
|---|---|---|
| `energy` | `state.intensity` | 2.0 s |
| `bright` (internal) | `state.brightness` | 2.0 s |
| `shimmer` | `state.shimmerLevel` (clamped 0...1) | 1.0 s |
| `air` | `state.level(.air)` | 1.5 s |
| `pulseColor` | `state.pulse(at: now, decay: 0.35)` | attack 60 ms, release 450 ms |
| `pulseMotion` | same target | attack 180 ms, release 900 ms |
| `harmonyHue` | see 3 | 4 s (chord), 12 s (key) |
| `ghostReach` | 1 on scene change, then 0 | attack 1.5 s, release 6 s |

   Both pulse followers are clamped to `0...1`. Dense passages merge into a slowly varying level instead of a flicker, because the release is longer than the gap between notes.
3. Harmony to hue (stateless target, smoothed): `fifths(pc) = ((pc * 7) % 12)`, minus 12 when above 6, giving -5...6. `chordTarget = 0.06 * fifths((chordRoot - tonic + 12) % 12) / 6` and `keyTarget = 0.10 * fifths(tonic) / 6`. Each is smoothed separately and summed, so the offset stays within +-0.16 turns. The same chord always gives the same tint and returning home returns the colour.
4. Brightness to hue drift (phase accumulator, never a speed uniform): `huePhase += dt * lerp(baseHueRate, 0.03 * (0.6 + 0.8 * bright), amount)`, wrapped with `fmod(_, 1)`. Rate range 0.018...0.042 turns/s. `baseHueRate` is today's behaviour: 0.03 on macOS, 0 on visionOS. `hueBaseShift = huePhase + amount * harmonyHue`.
5. Intensity to motion speed: `motionLead += dt * amount * (0.5 * energy - 0.15)`, so the Ken Burns clock runs at 0.85x to 1.35x. When sync is off the lead simply stops growing, so there is no jump.
6. Scene change: when `state.sceneIndex` differs from the last seen value (and it is not the first read), `ghostBurstSerial &+= 1` and `ghostReach` target is set to 1 for one update.
7. `reset()` clears everything; called when the effect clock restarts (macOS `EffectController.start()` sets time to 0).

With `-LiminalFreezeTime` set, the call sites pass `.neutral` and skip the reactor, so existing deterministic screenshots do not change.

### 1.3 `EffectsUniformsComputer.compute(..., music: MusicModulation = .neutral)`

The computer stays a pure function and the single place where music values become uniform values. With `.neutral` the output is identical to today's except that the caller no longer sets `hueBaseShift` itself.

`a = music.amount`. All results are clamped to the cap column, which is the hard limit whatever the inputs.

| Uniform | Today | With music | Cap |
|---|---|---|---|
| `kenBurns*` | `computeKenBurns(time)` | `computeKenBurns(time + motionLead)` | same ranges |
| `distortionAmplitude` | base 0.02...0.08, x10 at mid-crossfade | `base * (1 + a * (0.35 * energy - 0.15)) + a * 0.004 * pulseMotion`, then the unchanged transition boost | base <= 0.10 |
| `logSphereAmount`, `fractalNoiseAmount` | oscillators | `* (1 + a * (0.30 * energy - 0.15))` on the base, before the transition boost | 1.2x today's `high` |
| `chromaticAmount` | 0.003...0.015 | `base * (1 + a * (0.30 * energy - 0.10)) + a * 0.002 * pulseMotion` | 0.02 before boost |
| `bloomAmount` | 0.5 | `0.5 + a * (0.12 * pulseColor + 0.10 * shimmer)` | 0.72 |
| `vibranceAmount` | (0.18...0.42) * imageFactor | `+ a * 0.06 * pulseColor * imageFactor` | 0.50 * imageFactor |
| `feedbackMix` | 0.3 | `0.3 + a * (0.08 * energy - 0.04)` | 0.26...0.34 |
| `feedbackWarpAmount` | 0.03 | `0.03 + a * 0.01 * air` | 0.04 |
| `hueBaseShift` | macOS `time * 0.03`, visionOS 0 | `music.hueBaseShift` (see 1.2 steps 3 and 4) | wraps |
| `ghostTapMaxDistance` | 0.06 | `0.06 + a * 0.02 * ghostReach` | 0.08 |
| `fractalHueAmount`, `hueWaveIntensity`, `hueBlendAmount`, `contrastBoost`, `saturationBoost`, `blackPoint`, `distortionSpeed` | unchanged | unchanged | |

Not strobing, by construction: the fastest path is `pulseColor` (60 ms attack), which changes bloom by at most 0.12 of 0.5 and vibrance by at most 0.06, both chroma or glow gains on already bright pixels, not global luminance. Geometry (distortion, chromatic) only moves through the 180 ms follower. No sign flips, no value toggles between two states, no black frames.

Stereo: uniforms are computed once per frame and shared by both eyes, so the modulation is identical in both eyes.

### 1.4 Ghost-tap burst (scene change)

`GhostTapManager.requestBurst(serial: UInt32)`: when the serial changes, `pendingBurst = 2`. In `updateWithCount`, while `pendingBurst > 0`, `delay > 0.01`, `taps.count < 4` and at least 0.4 s since the last spawn, spawn one tap and decrement. The limit of 4 is the steady-state count at Echo = 1 (8 s lifetime, 2 s interval), so the burst never exceeds the number of taps (texture samples) the shader already runs. Together with the `ghostReach` swell the existing trails visibly exhale at a scene change at zero extra GPU cost.

- visionOS: `OffscreenEffectsRenderer.requestGhostBurst(serial:)` forwards to its `ghostTapManager`; called from the render loop with `music.ghostBurstSerial` each frame (cheap compare).
- macOS: `EffectsMetalViewRepresentable` gets `let ghostBurstSerial: UInt32`; `updateNSView` forwards it to `EffectsMetalView`, which forwards to its manager.

## 2. Visuals -> music

### 2.1 `VisualMoodBuilder.mood(metadata: ImageMetadata?, image: CGImage) -> VisualMood` (pure, `nonisolated`)

`ImageColorStats.measure` is extended to also return luma standard deviation and mean `(r - b)` from the same 32x32 pass (still about 0.1 ms, once per image).

| `VisualMood` field | With metadata | Without (test pattern, old cache) |
|---|---|---|
| `brightness` | `measuredBrightness` | measured luma |
| `saturation` | `measuredSaturation` | measured saturation |
| `warmth` | `0.6 * measuredWarmth + 0.4 * (spec.warmth + 1) / 2`, where `measuredWarmth = clamp(0.5 + 1.5 * mean(r - b))` over `dominantColors` weighted 5,4,3,2,1 | pixel `mean(r - b)` only |
| `energy` | `0.5 * spec.energy + 0.5 * clamp(lumaStdDev / 0.25)` | contrast term only |
| `palette` | `dominantColors`, sRGB to linear, up to 5 | empty |
| `moodWords` | `spec.moods` raw values + `spec.subjectCategory.rawValue` | empty |

Audio-side table change (small, in `VisualCoupling.table`): add `eerie` to the dark row, `euphoric` and `lush` to the playful row, `majestic` and `celestial` to the vast row, `intimate` to the calm row, so all 10 `Mood` values map.

### 2.2 Call sites (at crossfade start)

visionOS, `ImmersiveDomeView` render loop, in the `generation != lastGeneration` branch: replace `loadWithGeneration()` with `loadCurrentWithMetadata()` (one atomic read of image, metadata and generation), then

```swift
let wasFirst = transitionState.currentImage == nil
transitionState.transitionTo(framedImage)
music.setVisualMood(VisualMoodBuilder.mood(metadata: metadata, image: framedImage))
if !wasFirst { music.imageDidChange(transitionDuration: 1.5) }
```

macOS, `VisualDisplayView.onChange(of: visualEngine.currentImage)`: `transitionTo` returns `@discardableResult Bool` (true when a crossfade started). Metadata comes from `visualEngine.imageBuffer.loadCurrentWithMetadata()`, not from `visualEngine.currentMetadata`, because the two `@Published` mirrors arrive through separate sinks with no ordering guarantee. Same two calls. The crossfade duration (1.5 s, private in two places) is exposed as one shared constant, `ImageFraming.crossfadeDuration` or similar.

Both calls are `nonisolated` and only append to the conductor inbox under a short lock, so they are safe from the render loop. A mood posted before Play is kept and applied when the conductor begins. The conductor already ignores `imageDidChange` before it has begun and within 10 s of the previous one.

### 2.3 Visual activity

`EffectsUniformsComputer.visualActivity(time:transitionProgress:) -> Float`, pure:

```
activity = clamp(0.25 + 0.5 * distortionWave01(time) + 0.5 * sin(pi * transitionProgress), 0, 1)
```

where `distortionWave01` is the `t` already computed in `computeDistortion`. It is computed from the un-modulated oscillators on purpose, so music cannot feed back into itself through the visuals. The call sites send it with `music.setVisualActivity` at most twice a second and only when it moved by more than 0.02 (the conductor smooths it over 8 s; the effect is the existing +-15 % delay send and pad width nudge).

## 3. Threading and how the engine reaches the renderers

Neither renderer needs a lock or a hop:

- `GenerativeEngine` is `@MainActor`, but `musicState`, `setVisualMood`, `imageDidChange` and `setVisualActivity` are `nonisolated`. The views receive it as a plain `let music: GenerativeEngine` (not `@ObservedObject`), so they do not re-render when the engine publishes.
- macOS: `ContentView` owns `audioEngine` (`ContentView.swift:75`) and passes it at line 82: `VisualDisplayView(visualEngine:settings:isPlaying:music: audioEngine)`. The reactor lives in a small reference box held in `@State` (not observable). `effectUniforms` reads `music.musicState.read()` and `now()` on MainActor, where it already runs.
- visionOS: `LiminalVisionApp` owns `audioEngine` and passes it: `ImmersiveDomeView(visualEngine:settings:music: audioEngine)`. The reactor is a local `var` in the render loop `Task`, next to the perf counters. The loop is MainActor today; nothing here depends on that, so the code keeps working if the loop moves off main.
- `SpatialDioramaView` has no effect uniforms and is not part of this plan.
- Per-frame cost: one seqlock read (a copy of about 400 bytes, no allocation, retries only during the sub-microsecond publish), about 10 one-pole updates and two `exp` calls. No GPU change: same shader, same uniform struct, same sample counts.
- The enabled flag is read from `settings.syncVisualsToMusic` at the call site and passed as a `Bool` (the visionOS loop already reads `settings.delay` every frame the same way).
- `OffscreenEffectsRenderer` and `EffectsMetalView` change only by the ghost-burst forwarder; uniforms still arrive fully computed.

## 4. Setting

`SettingsService`: key `visual.syncToMusic`, `static let defaultSyncVisualsToMusic = true`, `@Published var syncVisualsToMusic: Bool`, loaded in `init`, restored in `resetToDefaults()`.

UI: `Toggle("Sync visuals to music", isOn: $settings.syncVisualsToMusic)` in the Visual section of both settings sheets, next to "Cache Only Mode" (`ContentView.swift:260`, `ControlsView.swift:278`).

The toggle gates music -> visuals only, through `amount` (1.5 s fade either way). Image -> music stays on: it is already capped (D63) and the Style and Density controls stay in charge.

## 5. Verification

DEBUG flags (`DebugLaunchOptions`):

- `-LiminalSyncStrength <x>`: multiplies `amount` (default 1; use 3 to make the coupling obvious in a screenshot or recording; caps still apply).
- `-LiminalSyncLog YES`: one line per second from each call site:

```
🎼 SYNC a=1.00 alive=1 scene=bloom#7 I=0.62 B=0.55 pulse=0.31/0.18 shim=0.22 air=0.40 hue=0.412(+0.031) lead=12.4s | dist=0.0463(x1.07) bloom=0.559 vib=0.318 fb=0.310 chrom=0.0091 reach=0.00 burst=3 | mood b=0.41 w=0.63 s=0.52 e=0.47 [serene,lush,plant] act=0.44
```

  The first block is reactor state, the second is the resulting uniforms with the ratio to the un-modulated value, the third is the last mood and activity sent to the music.

Offline check (no simulator, deterministic): a new test `AVCouplingTests` beside `MusicRenderTests`, off by default, run by `scripts/av-coupling-check.sh`. It starts the engine offline (`conductor.beginOffline()` as `renderOffline` does, seed fixed), advances the conductor in 20 ms steps for 600 s, and between steps runs the reactor and the computer at 90 fps with interpolated `now`. It also posts a synthetic image change every 30 s with alternating dark-cool and bright-warm moods. It writes a CSV of every modulated uniform to `scratchpad/finish/av-coupling/` and asserts:

1. Every uniform stays inside the cap column of 1.3.
2. Slew limits per frame at 90 fps: bloom <= 0.03, vibrance <= 0.015, distortion base <= 0.0006, hue <= 0.002 turns.
3. No strobing: the 3...30 Hz band of the bloom and vibrance series holds under 5 % of their variance.
4. Coupling is real: correlation of the distortion ratio with `intensity` > 0.8; every `sceneChange` produces a burst; every chord change moves the hue target.
5. With `enabled = false`, the output equals `compute(..., music: .neutral)` after 8 s, and the transition from on to off has no step larger than the slew limits.
6. Music side: after a bright-warm mood the smoothed `brightnessNudge` and `warmthDb` in the score log move in the expected direction within 20 s, and a chord change lands within 1 s of each crossfade midpoint.

Live check: macOS and the visionOS simulator with `-LiminalAutoPlay YES -LiminalOpenDome YES -LiminalSyncLog YES`, confirm the log lines move with scenes, then `scripts/perf-run.sh` with sync on and off; fps and GPU time must match within noise (expected, since nothing in the shader changes). Toggle the setting during playback and confirm no visible jump. Existing `-LiminalFreezeTime` screenshots must be pixel-identical to before.

## 6. Implementation order

1. `MusicModulation`, `MusicReactor`, `compute(music:)`, with `.neutral` giving today's output; move the macOS `hueBaseShift` line into the reactor path. Build both platforms.
2. Wire macOS and visionOS call sites, the setting and the toggles.
3. `VisualMoodBuilder`, the two crossfade-start call sites, activity, the mood-word table rows.
4. Ghost burst.
5. Debug flags, offline check, live check, perf run. Tune the amounts in 1.3 (they are starting values).

## 7. Open questions for review

- visionOS gets a slow hue drift it does not have today whenever sync is on (C6). If that is unwanted, set the synced rate there to `0.03 * 0.8 * (bright - 0.5)` (drift only around zero).
- Should the toggle also stop image -> music (C11)?
- Amounts are deliberately small. `-LiminalSyncStrength` exists to find out quickly whether they should be doubled.
