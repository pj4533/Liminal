# Getting started

[← Project overview](../README.md) · [Documentation index](README.md)

## Requirements

- macOS 26.0+ (deployment target) or visionOS (simulator or Apple Vision Pro)
- Xcode with the macOS and visionOS SDKs
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

3. Copy `Secrets.swift.template` to `Liminal/Secrets.swift` (required to provide the `Secrets` type, even when using an environment variable). Leave the placeholder for cache-only use. For generation, either fill in the key in this gitignored file (never commit it), or duplicate the `Liminal` scheme as `Liminal-Dev` and add a `GEMINI_API_KEY` environment variable under Run > Arguments

4. Build and run (Cmd-R). Pick the macOS or visionOS destination.

## Play Lo-Fi

Choose **Lo-Fi** in the Music section to set the BPM and optionally pin a scale. Tempo and scale changes apply at a 16-bar boundary. The app bundles twenty sampled acoustic programs (pianos, plucked strings and guitars) and generates new phrases and bass lines each session. Enable **Archive footage** and leave **Footage audio** at its 50% default to hear the tuned mix. The original film plays in the background while fragments of the same voice land on the beat. The film and main image change together on eight-bar boundaries.

On a first run, play online to fill the film cache. It holds ten pinned titles and two rotating discoveries. Cached footage and its sampled speech can play offline on Mac and Vision Pro. [Pinned films and sources](experience.md#pinned-films-and-rotating-discoveries)

For a private build with your own Slow Burn recordings (Vol. 1–4), follow the [optional drum setup](experience.md#lo-fi) before building.


## Build from the command line

```bash
# macOS
xcodebuild -scheme Liminal -destination 'platform=macOS' build

# visionOS Simulator (list devices with: xcrun simctl list devices)
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build

# unit tests (macOS)
xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests
```

Never build for iOS destinations; the app targets macOS and visionOS only.


