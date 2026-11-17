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


