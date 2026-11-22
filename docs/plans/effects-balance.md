# Effects balance: plan

Goal (user, on the Vision Pro): "the effects are making the image unrecognizable ... i love the sort of
water effect, but the radial is too much ... i want all the same effects, just add limits and a slow
change to how much they are used ... maybe even make this a setting?"

At the default setting the subject must be recognisable most of the time and its orientation obvious,
while the picture still looks clearly psychedelic. No effect is removed. Render resolution and GPU cost
do not go up.

Decisions and their reasons: `docs/decisions/effects-balance.md`.

## 1. Tooling added for this work

| Tool | What it does |
|---|---|
| `scripts/shader-bench.sh --render-only --out DIR [--set k=v,..] [--scenarios F.json] [--png-size 768x512] [--left-only]` | Frames only, no timing. `--set` overrides uniforms after the app computes them (switch an effect off). `--scenarios` renders a list of `{name, time, tp, set, intensity, age}`. Prints each scenario's uniforms as JSON. |
| `scripts/fx-structure.py render / analyze` | Per-effect attribution: reference (no effects), full, each effect knocked out, each effect alone, geometry only, colour only; luma metrics against the reference. |
| `scripts/fx_model.py scan / check / golden` | CPU model of the shader's warp field (validated against shader output, SSIM 0.90 to 0.97) and of the oscillators (matches the app to 5e-7). Gives displacement, strain and fold statistics, and holds the prototype of the proposed numbers (`proposed()`). |
| `scripts/fx-judge-set.py` | Renders a blind judge set with neutral file names and a private key (section 8). |

`shader-bench.sh` no longer applies the `07-depth.png` fixture to a different `--image` (a mismatched depth
map shifted parallax and fractal hue at random). Default runs are unchanged.

Fixtures: `$FX_FIXTURES` = a directory of photos with known subjects plus `truth.json` (not in the repo).

## 2. Diagnosis

Frames: 6 fixtures x 8 times (20 to 871 s), real shader at 2048x2048, frozen time, 30 feedback frames,
scored at 768x512 against the same frame with every effect off (Ken Burns kept).

### 2.1 Per-effect structure loss (1 - metric; mean [worst frame])

| effect | alone: HOG | alone: SSIM | alone: layout SSIM (96x64) | alone: edges | removed from full: HOG gain |
|---|---|---|---|---|---|
| turbulence (water) | 0.092 [0.167] | 0.690 | 0.615 | 0.324 | +0.021 |
| fractal noise | 0.090 [0.156] | 0.675 | 0.578 | 0.306 | +0.020 |
| log-spherical (radial) | 0.086 [0.173] | 0.603 | 0.495 | 0.258 | +0.019 |
| feedback trails | 0.033 | 0.132 | 0.105 | 0.023 | +0.006 |
| chromatic aberration | 0.018 | 0.035 | 0.003 | 0.014 | 0.000 |
| ghost taps | 0.013 | 0.045 | 0.024 | 0.008 | -0.001 |
| fractal hue | 0.011 | 0.040 | 0.050 | 0.028 | -0.005 |
| hue waves | 0.008 | 0.039 | 0.029 | 0.015 | +0.002 |
| bloom | 0.007 | 0.024 | 0.015 | 0.005 | -0.003 |
| vibrance | 0.004 | 0.010 | 0.004 | 0.000 | +0.002 |
| **all three warps, no colour** | 0.145 [0.254] | 0.712 | 0.731 | 0.413 | |
| **colour stages only** | 0.053 [0.077] | 0.302 | 0.218 | 0.096 | |
| **full pipeline** | 0.154 [0.256] | 0.711 | 0.734 | 0.444 | |

The metrics are on luma, so a hue rotation alone costs nothing. HOG (gradient-orientation histograms)
is the closest proxy for "can I tell what it is"; SSIM over-punishes a smooth shift.

### 2.2 Warp field statistics, today (`fx_model.py scan`; single effects over 0 to 900 s, combined over 0 to 3600 s)

Units: 1.0 = the whole picture. `strain` = size of the displacement gradient (0 rigid, 0.5 shapes bent,
above 1 shredded). `fold` = share of the picture where the map folds over.

| | amount min / median / max | displacement p95, median over time (max) | strain p90, median (max) |
|---|---|---|---|
| turbulence | 0.022 / 0.053 / 0.075 | 0.041 (0.062) | 0.69 (1.15) |
| log-spherical | 0.003 / 0.012 / 0.020 | 0.063 (0.117) | 0.45 (0.85) |
| fractal noise | 0.005 / 0.019 / 0.030 | 0.034 (0.058) | 0.48 (0.85) |
| **combined** | | 0.086 (0.154) | **1.02 (1.68)** |

Combined strain is the root-sum-square of the three (checked: 1.41 predicted, 1.45 measured at t = 20).
Strain per unit amount: turbulence 12.8, log-spherical 42 (26 with the periphery mask of section 6),
fractal noise 28.

Combined strain p90 is below 0.4 for **0 %** of the time and above 0.7 for **93 %** of the time. The seven
oscillators are decorrelated on purpose, so at any moment at least one warp is high. There is never a clear
stretch.

### 2.3 Is the radial the culprit?

Partly. What the measurements show:

1. **No single effect is the cause.** Each warp alone leaves the subject readable (contact sheets in the
   scratch output: hourglass, jellyfish). Removing any one of them from the full pipeline recovers only
   about 0.02 HOG loss out of 0.154. The damage comes from three warps stacked (each one warps the
   already-warped coordinates), all the time.
2. **The radial has the largest displacement** (p95 0.063 of the picture against 0.041 for the water) and
   the most recognisable signature: a pucker at the exact centre of the source image, where the subject of
   a photo usually is, plus a one-sided squeeze of the top half (the `exp(1 - y/R) - 1` term pushes the top
   of the picture by up to 6.4 x amount = 0.128, the bottom by 0). That is what reads as "radial".
3. **The water has the highest strain** (0.69 median), but it is smooth and coherent, which is why it is
   liked and still readable alone at 0.072.
4. **Fractal noise is as damaging as the radial** and went unnoticed: it is a high-frequency shatter.
5. **Colour is the second layer.** Colour stages alone cost 0.30 SSIM: hue waves at intensity up to 0.6 put
   several full rainbow cycles across the picture and break figure from ground. On top of a stacked warp
   this is what makes a frame unreadable rather than just wobbly.
6. Ken Burns at scale 1.4 shows only 51 % of the picture area.
7. Images change every 30 s with a 1.5 s crossfade in which turbulence is multiplied by 10 (up to 0.8). A new
   image is never shown clean.

## 3. Design overview

Three multipliers decide how wild the picture is; all are computed on the CPU in `EffectsUniformsComputer`.

```
drive d = macroDrive(time, intensity) x fresh(imageAge)          0 = clear stretch, 1 = wild stretch
amounts = mix(clearValue(intensity), wildValue(intensity), d)    per effect, then its own oscillator
warps   = fitted to the strain budget(intensity)                 radial and noise give way before the water
```

- `intensity` is the new user setting, 0...1, default 0.5.
- The water (turbulence) is always present. Log-spherical and fractal noise only exist in the wilder part of
  the cycle. Colour stays psychedelic in clear stretches but with few hue bands.

## 4. Numbers (starting values)

`tri(I; a, b, c)` = piecewise-linear in intensity through (0, a), (0.5, b), (1, c).
`mix(x, y)` = x + (y - x) * d. `smoothstep` as in Metal. phi = 1.618034.

### 4.1 Clarity cycle (macro envelope)

```
w0 = 2 pi / 420                                    periods 420 s, 260 s, 160 s (golden-ratio steps)
wave(t) = ( sin(w0 t - 0.3) + 0.6 sin(w0 phi t - 1.2) + 0.35 sin(w0 phi^2 t - 2.4) ) / 1.95
macroDrive(t, I) = smoothstep(-0.45, 0.55, wave(t) + 0.5 * (I - 0.5))
```

| intensity | time clear (drive < 0.15) | time wild (drive > 0.7) | mean drive |
|---|---|---|---|
| 0.25 | 47 % | 25 % | 0.35 |
| 0.5 | 39 % | 32 % | 0.43 |
| 1.0 | 16 % | 52 % | 0.62 |

Fastest change 0.031 per second, so clear to wild takes at least 32 s. A session starts clear; the first
wild stretch arrives after about a minute (drive 0.12 at 30 s, 0.9 at 60 s, 1.0 from 75 s to 150 s, back to 0
by 285 s).

### 4.2 Fresh-image hold

`age` = seconds on the effect clock since the current image's crossfade began (nil before the first
crossfade). `k` is 1: images change every 30 s.

```
fresh(age) = 1 - smoothstep(0, 1.5, age) * (1 - smoothstep(4.5 k, 11 k, age))      nil -> 1
```

The drive falls to 0 while the crossfade runs (hidden under the transition melt), stays 0 until 3 s after
the fade-in ends, and is back to its cycle value 11 s after the crossfade began. Continuous as long as the
previous image was up for 11 k seconds.

### 4.3 Warps

`t01`, `l01`, `n01` = today's 0...1 oscillators of turbulence, log-sphere and fractal noise (unchanged
frequencies). Music factors as today (section 5).

| uniform | formula | I = 0 | I = 0.5 | I = 1 | today |
|---|---|---|---|---|---|
| `distortionAmplitude` clear `Ac` | | 0.010 | 0.024 | 0.030 | 0.02 (min) |
| `distortionAmplitude` wild `Aw` | `Ac + (Aw - Ac) * d * (0.55 + 0.45 t01)` | 0.016 | 0.056 | 0.080 | 0.08 (max) |
| `logSphereAmount` `L` | `L * smoothstep(0.45, 0.90, d) * (0.35 + 0.65 l01)` | 0 | 0.011 | 0.020 | 0.003...0.02 |
| `fractalNoiseAmount` `N` | `N * smoothstep(0.20, 0.80, d) * (0.35 + 0.65 n01)` | 0 | 0.011 | 0.026 | 0.005...0.03 |
| strain budget `B` | see below | 0.30 | 0.90 | 1.45 | none (1.02 median, 1.68 max) |

Recognisability budget, applied after the music factors and before the transition boost:

```
st = 12.8 * a_t
if st > B:        a_t = B / 12.8;  a_l = a_n = 0
else:             rest = hypot(26 * a_l, 28 * a_n);  room = sqrt(B^2 - st^2)
                  if rest > room:  a_l *= room / rest;  a_n *= room / rest
absolute caps afterwards: a_t <= 0.10, a_l <= 0.020, a_n <= 0.036
```

Transition boost, additive (today it is a multiple of the base, x10 / x3 / x5), `b = sin(pi * tp)`:

| | I = 0 | I = 0.5 | I = 1 | today at the median base |
|---|---|---|---|---|
| `distortionAmplitude += b *` | 0.05 | 0.16 | 0.40 | 0.48 |
| `logSphereAmount += b *` | 0 | 0.006 | 0.020 | 0.023 |
| `fractalNoiseAmount += b *` | 0.004 | 0.020 | 0.060 | 0.076 |

Resulting warp over an hour with a 30 s hold per picture (`fx_model.py`):

| | strain p90: p10 / median / p90 / max | displacement p95: median / max | time strain < 0.4 | time strain > 0.7 |
|---|---|---|---|---|
| today | 0.74 / 1.02 / 1.28 / 1.68 | 0.084 / 0.154 | 0 % | 93 % |
| I = 0 | 0.12 / 0.14 / 0.19 / 0.24 | 0.008 / 0.013 | 100 % | 0 % |
| I = 0.25 | 0.21 / 0.26 / 0.44 / 0.56 | 0.014 / 0.040 | 85 % | 0 % |
| **I = 0.5** | 0.31 / 0.38 / 0.73 / 0.94 | 0.022 / 0.077 | 54 % | 13 % |
| I = 0.75 | 0.35 / 0.49 / 0.96 / 1.22 | 0.029 / 0.109 | 29 % | 34 % |
| I = 1 | 0.40 / 0.67 / 1.22 / 1.51 | 0.040 / 0.142 | 10 % | 48 % |

At I = 1 the wild stretches sit at today's level (today's p90 is 1.28); they just no longer last all the
time.

### 4.4 Colour and the rest

`c` = `SmoothOscillator.value(at: time)` (today's colour cycle). `ch(t)`, `fh(t)` = today's chromatic and
fractal-hue oscillators (0.003...0.015 and 0.05...0.25).

| uniform | formula | clear (I = 0 / 0.5 / 1) | wild (I = 0 / 0.5 / 1) | today |
|---|---|---|---|---|
| `hueBlendAmount` | `c * mix(clear, wild)` | 0.15 / 0.40 / 0.60 | 0.25 / 0.70 / 0.80 | `c * 0.8` |
| `hueWaveIntensity` | `c * mix(clear, wild)` | 0.02 / 0.10 / 0.30 | 0.05 / 0.30 / 0.60 | `c * 0.6` |
| `fractalHueAmount` | `fh(t) * mix(clear, wild)` | 0.2 / 0.5 / 0.8 | 0.3 / 0.85 / 1.0 | `fh(t)` |
| `chromaticAmount` | `min(ch(t) * mix(clear, wild) * music, 0.02) * (1 + 3 b)` | 0.3 / 0.6 / 0.9 | 0.4 / 0.9 / 1.0 | `ch(t)` |
| `feedbackMix` | `mix(clear, wild)` + music | 0.10 / 0.20 / 0.27 | 0.14 / 0.28 / 0.30 | 0.30 |
| `bloomAmount` | constant + music | 0.30 / 0.50 / 0.50 | same | 0.50 |
| `kenBurnsScale` | `1.18 + 0.10 sin(0.05 t) + 0.04 sin(0.03 t)` | 1.04...1.32 | | 1.00...1.40 |

Unchanged: Ken Burns offsets, `feedbackWarpAmount`, `bloomRadius`, ghost taps (count, distance, bursts),
vibrance and black point, contrast and saturation boost, saliency, stereo offset, `distortionSpeed`.

## 5. Music coupling inside the budget

The music factors keep their form and are applied to the new base values:

| value | music | limit |
|---|---|---|
| `a_t` | `* (1 + a (0.35 e - 0.15)) + a * 0.004 * pulseMotion` | then the strain budget, then 0.10 |
| `a_l`, `a_n` | `* (1 + a (0.30 e - 0.15))` | then the strain budget, then 0.020 / 0.036 |
| chromatic | `* (1 + a (0.30 e - 0.10)) + a * 0.002 * pulseMotion` | 0.02 before the transition boost |
| feedback mix | `+ a (0.08 e - 0.04)` | base - 0.04 ... min(base + 0.04, 0.34) |
| bloom | `+ a (0.12 pulseColor)` | 0.72 * base / 0.5 |
| vibrance, feedback warp, ghost reach, hue shift, Ken Burns lead | as today | as today |

Because the budget runs after the music factors, loud music can raise the water but can never push the
combined warp past `B`; the radial and the noise shrink to make room. `Caps.logSphereBase`,
`Caps.fractalNoiseBase`, `Caps.distortionBase` become the absolute caps above; `Caps.feedbackMixLow/High`
become relative to the base. `AVCouplingTests` assert the old caps and need the new ones.

## 6. Shader edits (three lines, `EffectsRenderer.metal`)

1. Periphery mask on the log-spherical offset, in `logSphericalTransform`:
   `float displacement = ef * intensity * smoothstep(0.10, 0.42, R);`
   The centre of the source image (the subject) is left alone; the kaleidoscope lives in the periphery.
   Strain per unit amount drops from 42 to 26; the centre pucker is gone.
2. `if (uniforms.logSphereAmount > 0.001)` becomes `> 0.00002`.
3. `if (uniforms.fractalNoiseAmount > 0.001)` becomes `> 0.00002`.
   Both amounts now pass through zero. At the old threshold the warp would pop in by up to 0.006 of the
   picture; at the new one by 0.0001.

GPU cost (shader-bench interleaved A/B, 5 x 300 frames, M4, all scenarios with the log-sphere active): B/A
median 0.998 (trials 0.986 to 1.010), within noise. In clear stretches both branches are skipped: 3.23 ms
against 3.98 ms per stereo frame, so the average cost goes down.

No uniform is added; the Metal struct is untouched.

## 7. Where the code goes

### 7.1 `EffectLook` and the computer

New `Liminal/Visual/EffectLook.swift` (add it to `APP_SRCS` in `scripts/shader-bench.sh` and to both
targets):

```swift
nonisolated struct EffectLook: Sendable, Equatable {
    var intensity: Float = EffectLook.defaultIntensity   // the user setting, 0...1
    var imageAge: Float? = nil                           // s since the current crossfade began
    static let defaultIntensity: Float = 0.5
    static func tri(_ i: Float, _ a: Float, _ b: Float, _ c: Float) -> Float
    static func macroWave(time: Float) -> Float
    static func macroDrive(time: Float, intensity: Float) -> Float
    func fresh() -> Float
    func drive(time: Float) -> Float                     // macroDrive * fresh
    static func strainBudget(_ i: Float) -> Float
}
```

`EffectsUniformsComputer.compute(..., music:, look: EffectLook = EffectLook())` implements sections 4 and 5.
All constants live in one `enum Tuning` so the
tuning pass edits one place.

Then replace the `fail(...)` at the "WIRE-UP POINT" in `scripts/shader-bench.swift` (`computeUniforms`) by
the real call, and make intensity 0.5 / age nil the bench default so the GPU benchmark measures the shipped
look.

The Swift must reproduce `fx_model.proposed()`: `python3 scripts/fx_model.py golden` prints the uniforms for
12 fixed inputs; a unit test in `LiminalTests` compares them (tolerance 1e-4). If the numbers are retuned,
change both and regenerate.

### 7.2 Setting and UI

- `SettingsService`: `@Published var effectIntensity: Float`, key `visual.effectIntensity`, default 0.5,
  included in `resetToDefaults()`.
- macOS `ContentView` and visionOS `ControlsView`: `ValueSlider(title: "Effect intensity", value: $settings.effectIntensity)`
  next to "Sync visuals to music". Caption: "How far the effects bend the picture. Low keeps the image clear."
- `DebugLaunchOptions`: `-LiminalEffectIntensity X` overrides the setting (simulator checks, perf runs).
- The renderers ease the value they pass toward the setting with a 0.5 s one-pole so a drag does not step.

### 7.3 Renderers

- macOS (`ContentView.currentUniforms`) and visionOS (`ImmersiveDomeView` render loop): keep
  `transitionStartEffectTime: Float?`, set when a crossfade starts (the same place the crossfade starts); pass `imageAge = effectTime - start`.
  Reset to nil when the effect clock restarts.
- The second `compute` call that builds the `neutral` uniforms for the sync log must pass the same `look`.

### 7.4 Tests

- Golden parity with `fx_model.py golden`.
- For 10 000 random (time, intensity, age, music) inputs: `12.8 a_t`, `26 a_l`, `28 a_n` root-sum-square
  <= budget + 1e-4 at tp = 0; every uniform within its absolute cap; all finite.
- Monotonic: for fixed time and age, strain load does not decrease as intensity rises (0, 0.25, 0.5, 0.75, 1).
- Slew: max step of each uniform per 1/90 s over 900 s at I = 1 is below 0.002 (no pops).
- `MusicModulation.neutral` and sync off give the un-coupled output.

## 8. Evaluation protocol

### 8.1 Frame grid

```
FX_FIXTURES=<fixture dir> python3 scripts/fx-judge-set.py --out <fx>/judge --key <fx>/judge-key
```

Defaults: 6 fixtures (`r2-04, r2-08, r2-11, r2-07, r2-05, f-02`; r2-07 replaced the top-down r2-03 in round 1) x 10 (time, image age) pairs x intensities
0.25, 0.5, 1.0 = 180 frames at 768x512, left eye, 30 feedback frames. The times
(20, 100, 190, 255, 330, 425, 540, 600, 675, 760 s) sample the default clarity cycle in its long-run
proportions (4 clear, 3 wild, 3 between); the ages (20, 25, 9, 14, 3, 28, 12, 7, 17, 22 s) sample a 30 s image
interval (1 held clear, 2 ramping, 7 settled).

- `--mode app` (default): the app's own uniform code with intensity and age. Works once 7.1 is wired.
- `--mode proto`: the prototype numbers of this plan (`fx_model.proposed`) and the three shader edits patched
  into a temporary copy. Works today; used to validate this plan.
- `--mode current`: the pipeline as shipped, for the baseline (60 frames).

Output: `<out>/frame-001.png ...` shuffled, nothing else. A quarter of the frames (`--flip-fraction 0.25`)
are shown rotated 180 degrees as orientation decoys. `<key>/key.json` maps frame to fixture, subject text,
intensity, time, age, rotation and uniforms; `<key>/refs/` holds the effect-free frames; `<key>/metrics.csv`
and `<key>/summary.md` hold the objective metrics. `--key` must be outside `--out`.

### 8.2 Objective gates (printed by the tool)

| intensity | mean HOG loss | max strain p90 | max fold |
|---|---|---|---|
| 0.25 | <= 0.07 | <= 0.60 | <= 0.002 |
| 0.5 | <= 0.10 | <= 1.00 | <= 0.005 |
| 1.0 | <= 0.14 | <= 1.60 | <= 0.030 |

Measured on the same frame set:

| | mean HOG loss | max HOG loss | mean strain p90 | max strain p90 | max displacement p95 | max fold |
|---|---|---|---|---|---|---|
| shipped pipeline | 0.149 | 0.256 | 1.01 | 1.45 | 0.123 | 0.025 |
| prototype I = 0.25 | 0.054 | 0.090 | 0.30 | 0.48 | 0.035 | 0 |
| prototype I = 0.5 | 0.077 | 0.133 | 0.48 | 0.78 | 0.062 | 0.0006 |
| prototype I = 1.0 | 0.112 | 0.198 | 0.79 | 1.30 | 0.111 | 0.0025 |

The objective gates are necessary, not sufficient: they were set from frames judged by eye during the
design. The blind judges decide.

### 8.3 Blind judges

- At least 3 judges, each a fresh agent with no access to the repository, the fixtures, the key, or this
  plan. A judge gets only the frame directory, in batches of at most 20 frames.
- Per frame the judge answers:
  1. `subject`: what is the picture of, in a few words (or "cannot tell").
  2. `orientation`: `upright`, `upside-down`, `sideways`, or `cannot tell`.
  3. `trippiness`: 1 to 5. 1 = an ordinary photo; 2 = lightly stylised; 3 = clearly psychedelic (colour or
     warp obviously altered); 4 = strongly psychedelic; 5 = overwhelming.
- A separate scorer with the key marks `subject` as recognised when the judge names the main object of the
  subject text or an obvious synonym (for example "hourglass", "jellyfish", "ferris wheel",
  "romanesco / cauliflower / broccoli", "accordion", "blossoming tree"). `orientation` is correct when it
  matches the key's rotation (0 = upright, 180 = upside-down).
- Each frame's result is the majority of the judges; trippiness is the mean.

Pass criteria:

| intensity | recognised | orientation correct | mean trippiness |
|---|---|---|---|
| 0.25 | >= 90 % | | |
| 0.5 (default) | >= 75 % | >= 85 % | >= 3.0 |
| 1.0 | | | >= 4.0 |

Also run the shipped pipeline (`--mode current`) once through the same judges as the baseline.

### 8.4 Tuning order when a gate fails

- Default not recognised enough: lower `B(0.5)` (0.90 to 0.75), then `Aw(0.5)` (0.056 to 0.048), then the
  hue-wave wild value (0.30 to 0.22). Do not touch the clear values first.
- Default not trippy enough: raise colour first (hue blend clear 0.40 to 0.50, hue wave clear 0.10 to 0.14,
  fractal hue clear 0.5 to 0.7), then the water `Ac(0.5)` (0.024 to 0.030). Colour costs far less structure
  than warp (section 2.1).
- I = 1 not trippy enough: raise `MACRO_BIAS` (0.5 to 0.8, more wild time), then `B(1)` to 1.6.
- Orientation wrong: lower `L` and the hue-wave wild value.

### 8.5 Other checks

- GPU: `scripts/shader-bench.sh --shader-b Liminal/Shaders/EffectsRenderer.metal --shader <main's shader>`,
  B/A within noise (at most 1.02).
- visionOS simulator with `-LiminalAutoPlay YES -LiminalOpenDome YES -LiminalTestImage <fixture>` and
  `-LiminalEffectIntensity 0.25 / 0.5 / 1`: screenshots at a clear and a wild moment, PERF log line, slider
  present in the controls window and persisted across a relaunch.
- macOS: slider present, value persisted.

## 9. Known limits

- The frozen-time renders understate feedback smear on moving content.
- Strain coefficients (12.8 / 26 / 28) are fits; the measured maximum at I = 0.5 is 0.94 against a budget of
  0.90. The gate allows 1.00.
