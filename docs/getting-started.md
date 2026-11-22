# Getting started

[← Project overview](../README.md) · [Documentation index](README.md)

## Requirements

- macOS 26.0+ (deployment target) or visionOS (simulator or Apple Vision Pro)
- Xcode with the macOS and visionOS SDKs

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

3. Build and run (Cmd-R). Pick the macOS or visionOS destination.

## Play Lo-Fi

Set the tempo in the Music section and optionally pin a scale. Tempo and scale changes apply at a 16-bar boundary. The app bundles twenty-one sampled acoustic programs (pianos, plucked strings and guitars) and composes new phrases and bass lines each session. Enable **Archive footage** and leave **Footage audio** at its 50% default to hear the tuned mix. The original film plays in the background while fragments of the same voice land on the beat. The film and main image change together on eight-bar boundaries.

On a first run, play online to fill the curated picture pool and the film cache; no key or account is needed. The film cache holds ten pinned titles and two rotating discoveries. Saved pictures and cached footage and its sampled speech can play offline on Mac and Vision Pro. [Pinned films and sources](experience.md#pinned-films-and-rotating-discoveries)

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


