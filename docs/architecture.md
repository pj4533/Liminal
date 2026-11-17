# Architecture and dependencies

[← Project overview](../README.md) · [Documentation index](README.md)

## Architecture

```
Audio                               Visual
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


## Dependencies

- [AudioKit](https://github.com/AudioKit/AudioKit), AudioKitEX and SoundpipeAudioKit: audio synthesis and effects
- [ShaderGraphCoder](https://github.com/praeclarum/ShaderGraphCoder): RealityKit shader materials
- Apple frameworks: SwiftUI, Metal, RealityKit, ARKit, Core ML and MetalFX

Swift packages are pinned in the Xcode workspace’s `Package.resolved`. Bundled depth and upscaling models live in `Liminal/`. Footage comes from the Internet Archive, including the Prelinger collection. The [curated film list](experience.md) links to the individual sources and their rights information. The MIT license below covers this repository’s code, not third-party footage or dependencies.


