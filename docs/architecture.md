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

The drum player queues one complete, stereo-linked 64-beat recording per take. The bass, dry acoustic instruments, texture, and wet rack have independently scheduled buffers on the same sample grid. If the accompaniment misses a render deadline, playback schedules a timed rest with the prepared effect tail while the current recording continues.

`LofiScore` builds 32-bar forms with remembered four-bar motifs and deliberate openings. The instrument program holds for 16 bars. `LofiRenderer` uses recorded acoustic sources, separate note sends, and independent echo, room, and color returns. It renders off the audio thread and keeps the audible wet tail at phrase joins. Kick candidates from the unchanged drum waveform feed visual modulation. A linked low-band detector ducks only the bass.

The archive echo follows a quarter-note and a half-beat reflection, with two delay lanes that let the old tail fade when BPM changes. Speech-band activity has separate dry and wet ducking envelopes. The combined final path uses light compression, slowly adjusts gain within bounded limits, and protects sample peaks with a conservative output trim. [Research and verification](research/lofi-studio.md) · [Headless capture](development.md#lo-fi-checks)

## Dependencies

- [AudioKit](https://github.com/AudioKit/AudioKit), AudioKitEX and SoundpipeAudioKit: audio synthesis and effects
- [ShaderGraphCoder](https://github.com/praeclarum/ShaderGraphCoder): RealityKit shader materials
- Apple frameworks: SwiftUI, Metal, RealityKit, ARKit, Core ML and MetalFX

Swift packages are pinned in the Xcode workspace’s `Package.resolved`. Bundled depth and upscaling models live in `Liminal/`. The acoustic Lo-Fi samples are distributed under CC0. Footage comes from the Internet Archive, including the Prelinger collection. The repository’s MIT license covers its code. [Instrument credits](lofi-samples.md) · [Curated films and source rights](experience.md)


