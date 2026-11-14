# Audio-visual coupling: decisions

Design decisions for `docs/plans/av-coupling.md`. Nothing is implemented yet; these are for review before the implementation pass.

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
- What: `pulseColor` (60 ms attack, 450 ms release) drives bloom and vibrance; `pulseMotion` (180 ms attack, 900 ms release) drives distortion and chromatic aberration.
- Why: a quick glow reads as a response to a note; a quick geometric shift reads as a twitch, more so in a headset. The releases are longer than typical note gaps so dense passages become a slow swell, not a flicker. Maximum deltas are small (bloom +0.12 on 0.5, vibrance +0.06) and never touch global luminance directly.

## C6. Hue is tied to harmony and brightness; `hueBaseShift` becomes owned by the reactor on both platforms
- What: chord root and tonic map to a hue offset by their position on the circle of fifths (+-0.06 and +-0.10 turns, eased over 4 s and 12 s). Music brightness sets the drift rate (0.018 to 0.042 turns/s). With sync off each platform keeps today's rate (macOS 0.03, visionOS 0).
- Why: a deterministic mapping means the same chord gives the same tint and returning to the home chord returns the colour, which is what makes it feel connected, not random. Circle-of-fifths distance makes closely related chords close in colour.
- Consequence to review: visionOS has no base hue drift today and gains one while sync is on. The hue stage already has moving spatial waves, so this shifts the phase of an existing motion; listed as an open question in the plan.

## C7. Scene intensity scales base amounts only, inside tested ranges
- What: intensity scales the base (pre-transition-boost) distortion, log-sphere, fractal noise and chromatic values by roughly 0.85x to 1.2x, feedback mix 0.26 to 0.34, and Ken Burns speed 0.85x to 1.35x. Hard clamps on every value.
- Why: the transition boost (up to 10x) is already tuned and should not grow. Staying near the existing ranges means the look was already vetted. Feedback mix is kept under 0.34 so trails cannot build up.

## C8. Scene change = small ghost-tap burst that never exceeds the existing tap count
- What: 2 extra taps, 0.4 s apart, only while fewer than 4 are active and only when Echo > 0, plus a `ghostTapMaxDistance` swell 0.06 to 0.08.
- Why: each active tap is one more texture sample. Four is the steady-state count at Echo = 1, so the shader never runs more taps than it already does. Respecting Echo = 0 keeps the user's choice to turn trails off.

## C9. Image mood is built from metadata first, pixels as fallback
- What: `VisualMoodBuilder` blends measured values (brightness, saturation, warmth from dominant colours, contrast) with the prompt's intent (`spec.warmth`, `spec.energy`, moods). Without metadata it measures the image on the existing 32x32 pass.
- Why: the model does not always follow the prompt, so measured colour should lead; the prompt adds intent the pixels cannot show (mood words). The fallback covers the test pattern and caches without sidecars.
- Also: five `Mood` values (eerie, euphoric, majestic, intimate, lush) do not match any row of `VisualCoupling.table` today; the plan adds them to existing rows.

## C10. Mood and `imageDidChange` are sent where the crossfade actually starts
- What: visionOS in the render loop's new-generation branch; macOS in `VisualDisplayView.onChange(of: currentImage)`. Metadata is read with `imageBuffer.loadCurrentWithMetadata()` in both.
- Why: those are the exact moments the 1.5 s crossfade begins, so the conductor's chord change lands on the visual midpoint. The atomic read avoids pairing an image with the previous image's metadata (the two `@Published` mirrors have no ordering guarantee).
- Not sent from `ImageQueue`: on visionOS the render loop notices the image up to a frame later, and the first image has no crossfade.

## C11. The toggle gates music -> visuals only
- What: "Sync visuals to music" (default on, key `visual.syncToMusic`) fades the visual modulation. Image -> music stays active.
- Why: that is what the label says. The image -> music side is already capped and smoothed over 8 s (D63) and has no visual side effect to turn off.
- Alternative: gate both directions. Listed as an open question.

## C12. Visual activity is computed from un-modulated oscillators
- What: `visualActivity(time:transitionProgress:)` uses the plain time-based distortion wave and the crossfade bump.
- Why: if it used the music-modulated values, the music would drive the visuals which would drive the music. Breaking the loop here costs nothing.

## C13. The views get the engine as a plain `let`, not `@ObservedObject`
- What: `VisualDisplayView` and `ImmersiveDomeView` take `let music: GenerativeEngine` and only call its `nonisolated` members.
- Why: no SwiftUI invalidation when the engine publishes (the visionOS architecture note forbids `@Published` reads in the render path), and both directions (bus read, mood posts) are available from one reference.

## C14. Verification is offline first
- What: a seeded offline test drives the real conductor and the reactor at simulated 90 fps for 10 minutes and asserts caps, per-frame slew limits, a spectral no-strobe bound, and that coupling actually happens. A `-LiminalSyncLog` line and `-LiminalSyncStrength` flag cover the live check; `-LiminalFreezeTime` bypasses the reactor.
- Why: taste limits like "never strobing" need numbers that can be re-run, and the simulator cannot judge audio-visual timing reliably. Bypassing under frozen time keeps the existing deterministic screenshots valid.
