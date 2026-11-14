# Liminal

> Generative ambient audio-visual experience for macOS

![macOS](https://img.shields.io/badge/macOS-14.0+-000000?style=flat&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?style=flat&logo=swift&logoColor=white)
![Metal](https://img.shields.io/badge/Metal-GPU-8A8A8A?style=flat&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat)

Liminal creates endless, evolving ambient soundscapes synchronized with AI-generated visuals that morph continuously. Run it in the background, let it play, and drift.

<p align="center">
  <img src="liminal_screenshot.png" alt="Liminal Screenshot" width="600">
</p>

## Features

- **Generative Audio** — Eight-layer synthesized ambient engine (drone, pad, lead, keys, drips, air, grains, pluck) with evolving scenes, key drift, rare events and four styles; no samples. See `docs/decisions/music.md`
- **AI Visuals** — Gemini image generation (gemini-3.1-flash-image, 3:2 at 2K) driven by a style/subject/palette prompt system for varied, photoreal-but-surreal imagery; a "Clear All Images" control wipes the cache (see docs/decisions/images.md)
- **GPU Effects** — Metal shaders: Ken Burns motion, fBM distortion, saliency-based hue shifting, feedback trails
- **Indirect Control** — Shape the experience through abstract sliders rather than direct manipulation

## Requirements

- macOS 14.0+
- Xcode 15.0+
- [Gemini API key](https://aistudio.google.com/apikey) (for image generation)

## Setup

1. Clone the repo
   ```bash
   git clone https://github.com/pj4533/Liminal.git
   cd Liminal
   ```

2. Open in Xcode
   ```bash
   open Liminal.xcodeproj
   ```

3. Configure your API key
   - Duplicate the `Liminal` scheme and name it `Liminal-Dev`
   - Edit the scheme → Run → Arguments → Environment Variables
   - Add `GEMINI_API_KEY` with your key

4. Build and run (⌘R)

## Architecture

```
Audio                          Visual
─────                          ──────
8 layers + Scene Director       Gemini API → Image Generation
(MusicConductor, off-main) →   CoreML → RealESRGAN Upscale
        ↓                      Metal → GPU Effects Pipeline
  Mix bus: Zita reverb,               ↓
  delay, shimmer, limiter        Morph Player
                              (GPU Crossfade)
```

## Controls

| Slider | Effect |
|--------|--------|
| **Style** | Drift, Glass, Deep or Garden music palette |
| **Density** | How many notes the pointed layers play |
| **Space** | Reverb size and shimmer |
| **Echo** | Audio delay + visual trail intensity |

Scale picker: "Auto (evolving)" lets key and mode drift; choosing a scale pins it.

## Dependencies

- [AudioKit](https://github.com/AudioKit/AudioKit) — Audio synthesis and effects

## License

MIT © PJ Gray
