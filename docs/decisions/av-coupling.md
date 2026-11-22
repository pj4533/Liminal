# Audio-visual coupling: decisions

Design decisions for `docs/plans/av-coupling.md` (music drives the visuals only), then implementation decisions. The music side is `MusicState` (published by the Lo-Fi transport), `MusicReactor` and `MusicModulation`.

## Implementation (I1 to I12)

All amounts are the plan's starting values (section 1.3), unchanged. No shader or uniform-struct edits.

- I1. The reactor's smoothers and accumulators run on the effect-clock delta, not the bus clock. Why: the macOS hue drift must keep running when the music is not alive, and a clock that goes backwards (macOS `EffectController.start()` resets to 0) resets the reactor automatically. The bus clock is used for aliveness and the onset envelope.
- I2. `amount` snaps to its target within 0.005. Why: sync off then gives exactly the un-coupled output (step at most 0.0006 in bloom).
- I3. With sync off, `hueBaseShift` and the Ken Burns lead keep the phase offset they built up (they stop changing; no jump back). They are the only two values that differ from the un-coupled output.
- I5. The ghost-reach swell holds its target at 1 for 2 s after a phrase change (attack 0.8 s, release 6 s). Why: holding it for a single update with a 1.5 s attack would barely move it.
- I6. A burst that cannot fire within 3 s (4 taps already active) is dropped. A burst tap counts as a spawn, so the regular schedule restarts after it.
- I8. macOS `hueBaseShift` is now wrapped to 0...1. Before, it was `time * 0.03` unbounded and added in half precision in the shader, so it lost precision over time. With `-LiminalFreezeTime` set, the old `time * 0.03` is kept exactly.
- I9. Open questions C6 and C11 use the plan's defaults: visionOS drifts the hue while sync is on, and the toggle gates the visual modulation.
- I10. The fast onset follower (`pulseColor`) attack is 90 ms, not the planned 60 ms. Why: at 60 ms an offline run measured 5.02 % of the bloom variance in the 3 to 30 Hz band, just over the 5 % no-strobe limit. At 90 ms it is 4.4 %, and a note still reads as an immediate glow. Every other amount is the plan's value.
- I11. The "Sync visuals to music" toggle sits in the Visuals section of both control panels (macOS checkbox, visionOS switch).
- I12. `AVCouplingTests` checks the caps, the neutral modulation and the reactor without music with fixed inputs; there is no long offline run. `-LiminalSyncLog` and `-LiminalSyncStrength` cover the live check.

### Amounts in use

| Music signal | Visual target | Amount | Cap |
|---|---|---|---|
| intensity (2 s) | distortion base | x(1 + 0.35E - 0.15) | 0.10 |
| intensity | log-sphere, fractal noise base | x(1 + 0.30E - 0.15) | 1.2x old high |
| intensity | chromatic base | x(1 + 0.30E - 0.10) | 0.02 |
| intensity | feedback mix | 0.3 + 0.08E - 0.04 | 0.26...0.34 |
| intensity | Ken Burns rate | 0.85x...1.35x via motionLead | |
| onset fast (90/450 ms) | bloom, vibrance | +0.12, +0.06 x imageFactor | 0.72, 0.50 x imageFactor |
| onset slow (180/900 ms) | distortion, chromatic | +0.004, +0.002 | as above |
| music brightness | hue drift | 0.018...0.042 turns/s | wraps |
| chord vs tonic, tonic | hue offset (4 s, 12 s) | +-0.06, +-0.10 turns | |
| phrase change, kick trail | ghost burst of 2 taps (< 4 active, Echo > 0), reach swell | 0.06 -> 0.08 | 0.08 |


## C1. No new uniforms and no shader edits
- What: every music-driven change goes through uniforms that already exist. The Metal struct and the fragment shader are untouched.
- Why: the shader was just optimised and GPU cost must stay flat. Ten existing uniforms give enough handles (distortion, bloom, vibrance, feedback, chromatic, hue shift, Ken Burns, ghost reach).

## C2. A stateful `MusicReactor` at the call site, a pure `EffectsUniformsComputer`
- What: smoothing, accumulators and event detection live in `MusicReactor` (one per render loop). It produces a `MusicModulation` value that is passed to `compute(..., music:)`. The computer does not read the bus itself.
- Why: the computer is called twice per tick on macOS (SwiftUI body and a logging `onChange`) and is documented as the single source of truth for mapping to uniforms; keeping it pure keeps that true and makes it testable with fixed inputs. State needs an owner with a clear lifetime, which is the render loop.
- Alternative rejected: reading `musicState` inside the computer with static state. It would need locking or would break when called twice per frame.

## C3. Rates are changed by integrating phase on the CPU, never by changing a speed uniform
- What: hue drift speed and Ken Burns speed are driven by accumulators (`huePhase`, `motionLead`). `distortionSpeed` and the shader's `time` are not modulated.
- Why: the shader multiplies speed by time, so a small speed change at t = 1000 s jumps the phase by a large amount, which would look like a glitch.

## C4. One master `amount` with a 1.5 s ease gates everything
- What: all deviations from the un-modulated value are multiplied by `amount`, which eases to 1 when the toggle is on and the music is alive, else to 0.
- Why: one mechanism covers the toggle, Play, Stop and a stale state after Stop (`now - state.time >= 0.5 s`), and guarantees no pop in any of them.

## C5. Two onset followers: fast for colour, slow for geometry
- What: `pulseColor` (90 ms attack, 450 ms release) drives bloom and vibrance; `pulseMotion` (180 ms attack, 900 ms release) drives distortion and chromatic aberration.
- Why: a quick glow reads as a response to a note; a quick geometric shift reads as a twitch, more so in a headset. The releases are longer than typical note gaps so dense passages become a slow swell, not a flicker. Maximum deltas are small (bloom +0.12 on 0.5, vibrance +0.06) and never touch global luminance directly.

## C6. Hue is tied to harmony and brightness; `hueBaseShift` becomes owned by the reactor on both platforms
- What: chord root and tonic map to a hue offset by their position on the circle of fifths (+-0.06 and +-0.10 turns, eased over 4 s and 12 s). Music brightness sets the drift rate (0.018 to 0.042 turns/s). With sync off each platform keeps today's rate (macOS 0.03, visionOS 0).
- Why: a deterministic mapping means the same chord gives the same tint and returning to the home chord returns the colour, which is what makes it feel connected, not random. Circle-of-fifths distance makes closely related chords close in colour.
- Consequence to review: visionOS has no base hue drift today and gains one while sync is on. The hue stage already has moving spatial waves, so this shifts the phase of an existing motion; listed as an open question in the plan.

## C7. Phrase intensity scales base amounts only, inside tested ranges
- What: intensity scales the base (pre-transition-boost) distortion, log-sphere, fractal noise and chromatic values by roughly 0.85x to 1.2x, feedback mix 0.26 to 0.34, and Ken Burns speed 0.85x to 1.35x. Hard clamps on every value.
- Why: the transition boost (up to 10x) is already tuned and should not grow. Staying near the existing ranges means the look was already vetted. Feedback mix is kept under 0.34 so trails cannot build up.

## C8. Phrase change = small ghost-tap burst that never exceeds the existing tap count
- What: 2 extra taps, 0.4 s apart, only while fewer than 4 are active and only when Echo > 0, plus a `ghostTapMaxDistance` swell (a kick-keyed rhythm trail fires the same burst at most every 6 s) 0.06 to 0.08.
- Why: each active tap is one more texture sample. Four is the steady-state count at Echo = 1, so the shader never runs more taps than it already does. Respecting Echo = 0 keeps the user's choice to turn trails off.



## C11. The toggle fades the visual modulation
- What: "Sync visuals to music" (default on, key `visual.syncToMusic`) fades the visual modulation in and out through `amount`.
- Why: that is what the label says. The music never reads the pictures.


## C13. The views get the engine as a plain `let`, not `@ObservedObject`
- What: `VisualDisplayView` and `ImmersiveDomeView` take `let music: GenerativeEngine` and only read its `nonisolated` `musicState` bus.
- Why: no SwiftUI invalidation when the engine publishes (the visionOS architecture note forbids `@Published` reads in the render path).

## C14. Verification is by caps tests and a live log
- What: `AVCouplingTests` drives the computer with extreme modulation and asserts every cap, that `.neutral` equals the un-coupled output, and that the reactor stays off without music. A `-LiminalSyncLog` line and `-LiminalSyncStrength` flag cover the live check; `-LiminalFreezeTime` bypasses the reactor.
- Why: taste limits like "never strobing" need numbers that can be re-run. Bypassing under frozen time keeps the deterministic screenshots valid.
