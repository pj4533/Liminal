# Liminal

> Generative ambient audio-visual experience for macOS

![macOS](https://img.shields.io/badge/macOS-14.0+-000000?style=flat&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?style=flat&logo=swift&logoColor=white)
![Metal](https://img.shields.io/badge/Metal-GPU-8A8A8A?style=flat&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat)

Liminal creates endless, evolving ambient soundscapes synchronized with AI-generated visuals that morph continuously. Run it in the background, let it play, and drift.

## Features

- **Generative Audio** — Three-voice ambient synthesis with Markov-chain note selection across 47 musical scales
- **AI Visuals** — Gemini-powered image generation with native CoreML upscaling (RealESRGAN 4x)
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
Bass Voice (drone)             Gemini API → Image Generation
Mid Voice (pad)         →      CoreML → RealESRGAN Upscale
Shimmer Voice (pings)          Metal → GPU Effects Pipeline
        ↓                              ↓
  Effects Chain                  Morph Player
  (Reverb + Delay)            (GPU Crossfade)
```

## Controls

| Slider | Effect |
|--------|--------|
| **Delay** | Audio delay feedback + visual trail intensity |
| **Reverb** | Reverb mix depth |
| **Notes** | Shimmer voice note frequency |

Scale picker changes the musical mode (Pentatonic, Dorian, Lydian, etc.)

## Dependencies

- [AudioKit](https://github.com/AudioKit/AudioKit) — Audio synthesis and effects

## License

MIT © PJ Gray
