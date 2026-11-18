# Architecture and dependencies

[← Project overview](../README.md) · [Documentation index](README.md)

## Architecture

```
Ambient audio                       Visual
-----                               ------
GenerativeEngine (facade)           Gemini -> ImageQueue / ImageStore (disk)
 MusicConductor (own queue, 20 ms)   -> ImageUpscaler (CoreML RealESRGAN on macOS,
 SceneDirector + 8 layers               MetalFX on device visionOS) -> 3:2 centre crop
 MixBus: Zita reverb, delay,         EffectsUniformsComputer (single source of truth)
 shimmer, limiter                     -> EffectsMetalView (macOS, MTKView)
        |                             -> OffscreenEffectsRenderer (visionOS, MRT stereo ->
        |  MusicState (lock-free)         DrawableQueue -> RealityKit shell)
        +-----> MusicReactor / MusicModulation -> uniforms
        <----- VisualMoodBuilder: setVisualMood / imageDidChange / setVisualActivity
```

Shader pipeline order (`Liminal/Shaders/EffectsRenderer.metal`): Ken Burns, distortion (turbulence, log-spherical, sinusoidal), stereo parallax and chromatic aberration, crossfade, hue shift (spatial, saliency, fractal), contrast/saturation, ghost taps, stochastic bloom, feedback warping, vibrance. `EffectsUniforms.swift` must match the Metal struct exactly. Images use one orientation convention: texture row 0 is the top. Platform details: `PLATFORM_ARCHITECTURE.md`.

### Lo-Fi audio

The drum player queues one complete, stereo-linked 64-beat recording per take. The bass, dry acoustic instruments, texture, and wet rack have independently scheduled buffers on the same sample grid. The five players start at one audio host time. That downbeat establishes the music clock and releases the visual and footage playback gate on macOS and visionOS. If the accompaniment misses a render deadline, playback schedules a timed rest with the prepared effect tail while the current recording continues.

`LofiScore` builds 32-bar forms with remembered four-bar motifs and their own cadences. A piano anchors each 16-bar take. Two contrasting instrument voices take the middle phrases before the piano returns. Dry attacks use a bounded gain based on the strongest 75 ms window. The renderer then measures the stereo sum of the instrument, texture and its effects, including the future tail. Peak, 400 ms and three-second limits set one downward gain for the phrase. Carried tails retain their previous gain, and the drums and bass bypass this instrument trim. `LofiRenderer` uses recorded acoustic sources, separate note sends, and independent echo, room, and color returns. Grid-timed fragments use isolated acoustic notes for scale-aware pitch shifts, with reverse, flutter, spectral holds, and cross-modulation as alternate recipes. A short plate and a longer hall take both melody and midrange sends, including echoes and grains. It renders off the audio thread and keeps the audible wet tail at phrase joins. Kick candidates from the unchanged drum waveform provide sample-timed visual onsets and anchor nearby scored bass attacks to the drummer’s timing. A linked low-band detector ducks only the bass. A two-beat reverse pickup leads into the eight-bar breakdown. A four-beat octave-layered pickup leads into the next take. The renderer carries their releases across phrase joins. The live player publishes the take’s audible origin and measured beat duration. The footage scheduler preloads the next decoder and centers its dissolve on that same downbeat. The primary image uses the same audible downbeat. The queue reserves a distinct image ahead of time, with bundled art available when generation or cache decoding is late. Both renderers preload the texture. A short, clock-driven dissolve exchanges half the image at the drum boundary. Bloom, color and film strength crest there too.

The melody and midrange rack can pick up a short window from its own colored return and replay three grid-timed fragments, including reversed and octave-down answers. The fragments feed filtered echoes and room sends. A soft low-pass on the upper wet band and a linked peak control keep the return focused on the mids. The renderer carries at least nine seconds or eight beats of available wet tail into the next take at the original pitch and echo spacing.

An incoming footage cue can decode while the current cue plays. Late PCM starts at the matching position in the active excerpt with a short fade. The Lo-Fi archive rack picks a three-tap echo pattern every four audible bars. Each pattern uses beat subdivisions for its main echo, darker stereo answer, and room reflection. The tap levels swell independently. Two delay banks let earlier echoes decay at their original timing across changes. Footage and music are summed independently before the final bus. The combined final path uses light compression, slowly adjusts gain within bounded limits, and protects sample peaks with a conservative output trim. [Research and verification](research/lofi-studio.md) · [Headless capture](development.md#lo-fi-checks)

## Dependencies

- [AudioKit](https://github.com/AudioKit/AudioKit), AudioKitEX and SoundpipeAudioKit: audio synthesis and effects
- [ShaderGraphCoder](https://github.com/praeclarum/ShaderGraphCoder): RealityKit shader materials
- Apple frameworks: SwiftUI, Metal, RealityKit, ARKit, Core ML and MetalFX

Swift packages are pinned in the Xcode workspace’s `Package.resolved`. Bundled depth and upscaling models live in `Liminal/`. The acoustic Lo-Fi samples are distributed under CC0. Footage comes from the Internet Archive, including the Prelinger collection. The repository’s MIT license covers its code. [Instrument credits](lofi-samples.md) · [Curated films and source rights](experience.md)


