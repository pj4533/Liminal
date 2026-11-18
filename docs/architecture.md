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

`LofiScore` generates four-bar phrases and alternates piano and plucked-string families. `LofiRenderer` prepares the drum and bass stem and the separate pitched music and effects stem off the audio thread. The renderer balances dry melody against a louder wet return with crossed beat-synced delays, granular resampling, diffusion, reverb, and soft octave shimmer. It carries the filtered tail into the next phrase. `LofiPlayback` starts both stems on the same audio clock and publishes its own music state for the visuals.

The archive voice keeps its place in the shared mix with a one-beat echo and a half-beat reflection in Lo-Fi. Speech-band activity lowers the pitched stem, and light compression combines the rhythm, melody, and soundtrack at the output. [Experience and controls](experience.md#lo-fi)

## Dependencies

- [AudioKit](https://github.com/AudioKit/AudioKit), AudioKitEX and SoundpipeAudioKit: audio synthesis and effects
- [ShaderGraphCoder](https://github.com/praeclarum/ShaderGraphCoder): RealityKit shader materials
- Apple frameworks: SwiftUI, Metal, RealityKit, ARKit, Core ML and MetalFX

Swift packages are pinned in the Xcode workspace’s `Package.resolved`. Bundled depth and upscaling models live in `Liminal/`. The acoustic Lo-Fi samples are distributed under CC0. Footage comes from the Internet Archive, including the Prelinger collection. The repository’s MIT license covers its code. [Instrument credits](lofi-samples.md) · [Curated films and source rights](experience.md)


