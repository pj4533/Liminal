<p align="center">
  <img src="docs/media/banner.jpg" alt="Liminal — Sound. Colour. Space. Generative ambience for macOS and Apple Vision Pro" width="100%">
</p>

<p align="center">
  <a href="docs/getting-started.md">Get started</a> ·
  <a href="docs/README.md">Documentation</a> ·
  <a href="docs/development.md#contributing">Contribute</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26+-161b22?logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/visionOS-immersive-161b22?logo=apple&logoColor=white" alt="visionOS immersive">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-71d6c5" alt="MIT license"></a>
</p>

Liminal pairs evolving ambient music with surreal AI imagery, flowing visual effects, and fragments of archival film. Let it fill a window on your Mac or surround you on Apple Vision Pro. Press play and drift.

## See it in motion

[![Play the 10-second Lo-Fi preview with stereo sound](docs/media/lofi-preview.jpg)](https://cdn.jsdelivr.net/gh/pj4533/Liminal@872b0da4607a7c9b1239565da0f929c26c34df8f/docs/media/lofi-preview.mp4)

**[Play with sound · 10 seconds · 1.5 MB](https://cdn.jsdelivr.net/gh/pj4533/Liminal@872b0da4607a7c9b1239565da0f929c26c34df8f/docs/media/lofi-preview.mp4)** · [MP4 in the repository](docs/media/lofi-preview.mp4)

Captured live on macOS at 69 BPM with AJ Hall’s drums. The picture changes on the eight-bar fill. The film layer and sampled voice come from *Horizons of Science: Thinking Machines* (Educational Testing Service, 1959). Liminal composites the picture and filters, chops, and echoes its soundtrack. [Original film](https://archive.org/details/horizons-of-science-thinking-machines) · [Film license (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)

## An atmosphere that keeps changing

- **Two music modes** — drift through slow Ambient scenes or play Lo-Fi with deep bass and twelve sampled instruments. With a local drum pack, 16-bar takes play through their original fills.
- **Film dialogue in the beat** — hear the original soundtrack underneath the groove. Liminal picks out spoken phrases on-device, plays pieces of a line across the beat, then brings the words back together on a downbeat. Each cut has its own level, dark echo, and room reverb.
- **Living imagery** — generated scenes blend through effects that respond to the music. In Lo-Fi, the image and film change together at the eight- and sixteen-bar drum fills.
- **Immersive space** — depth gives the imagery relief as it wraps around you on Vision Pro.
- **Traces of old film** — Ten pinned films include *Thinking Machines* and Stanford’s *Hear Here*, a 1969 demonstration of speech recognition. Two more slots rotate through discoveries from the Internet Archive. [Film list and credits](docs/experience.md#pinned-films-and-rotating-discoveries)
- **Make it yours** — choose an Ambient style, set the Lo-Fi BPM, or pin a scale in either mode. Adjust footage volume, visual intensity, and image-generation limits.

<details>
<summary>See the macOS app</summary>

![Liminal running on macOS with its music and visual controls](liminal_screenshot.png)

</details>

## Get started

You’ll need Xcode with the macOS or visionOS SDK, and a [Gemini API key](https://aistudio.google.com/apikey) to generate new images.

```sh
git clone https://github.com/pj4533/Liminal.git
cd Liminal
cp Secrets.swift.template Liminal/Secrets.swift
open Liminal.xcodeproj
```

Add your key to the local `Liminal/Secrets.swift`, select the **Liminal** scheme and a **Mac or Apple Vision Pro** destination, then run. Never commit your key.

See the [setup guide](docs/getting-started.md) for environment-key configuration, requirements, and command-line builds.

## Explore the project

| Guide | What you’ll find |
| --- | --- |
| [Experience & controls](docs/experience.md) | Features, settings, and playback behavior |
| [Lo-Fi instrument recordings](docs/lofi-samples.md) | Sources and credits for all twelve sampled instruments |
| [Architecture](docs/architecture.md) | Music, image and rendering pipelines; dependencies |
| [Development](docs/development.md) | Tests, launch flags, scripts, and contribution guidance |
| [Design decisions](docs/decisions/README.md) | The reasoning behind the experience |

## License

[MIT](LICENSE) © PJ Gray. See [dependencies and media attribution](docs/architecture.md#dependencies) for third-party material.
