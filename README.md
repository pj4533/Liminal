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

[![Play the 10-second Lo-Fi preview with stereo sound](docs/media/lofi-preview.jpg)](https://cdn.jsdelivr.net/gh/pj4533/Liminal@c52ee4df212da9e543f308776e1291421f77c50e/docs/media/lofi-preview.mp4)

**[Play with sound · 10 seconds · 1.4 MB](https://cdn.jsdelivr.net/gh/pj4533/Liminal@c52ee4df212da9e543f308776e1291421f77c50e/docs/media/lofi-preview.mp4)** · [MP4 in the repository](docs/media/lofi-preview.mp4)

Lo-Fi at 72 BPM with AJ Hall’s drums. The audio is the app’s own offline render, and the picture is a cached image and the film passed through the app’s shader. A line from *UFO Interview* (National Archives, 1966) is cut into word pieces. The pieces stutter, pause and reorder on the beat, with echo throws and a dark room, and sit inside the music. The film’s own soundtrack plays far behind as an effected bed. [Original film](https://archive.org/details/342-usaf-42990)

## An atmosphere that keeps changing

- **Two music modes** — drift through slow Ambient scenes or play Lo-Fi with deep bass and twenty sampled acoustic programs: pianos, plucked strings and guitars that strum and fingerpick. With a local drum pack, 16-bar takes play through their original fills.
- **Film dialogue, chopped like an MPC** — each 16-bar loop takes a fresh line from the films and cuts it into word and syllable pieces. The pieces repeat, pause, reorder and land on the beat in every bar, with echo throws, reversed pickups and a long dark room. The chops sit inside the music while the original soundtrack plays far behind as an effected bed.
- **Living imagery** — generated scenes blend through effects that respond to the music. In Lo-Fi, the picture warps through one of a dozen transition styles during the drum fill and lands on the new image on the downbeat.
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
| [Lo-Fi instrument recordings](docs/lofi-samples.md) | Sources and credits for all twenty sampled programs |
| [Architecture](docs/architecture.md) | Music, image and rendering pipelines; dependencies |
| [Development](docs/development.md) | Tests, launch flags, scripts, and contribution guidance |
| [Design decisions](docs/decisions/README.md) | The reasoning behind the experience |

## License

[MIT](LICENSE) © PJ Gray. See [dependencies and media attribution](docs/architecture.md#dependencies) for third-party material.
