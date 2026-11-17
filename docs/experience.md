# The Liminal experience

[← Project overview](../README.md) · [Documentation index](README.md)

## Features

- **Generative Audio**: eight-layer synthesized ambient engine (drone, pad, lead, keys, drips, air, grains, pluck) with evolving scenes, key drift, rare events and four styles (Drift, Glass, Deep, Garden); no samples. See `decisions/music.md`
- **AI Visuals**: Gemini image generation (gemini-nano-banana-2.1, the configured primary model, 3:2 at 2K; hourly and daily spending cap) driven by a style/subject/transformation/palette prompt system for varied, photoreal-but-surreal imagery. See `decisions/images.md`
- **GPU Effects**: one Metal fragment shader with Ken Burns motion, turbulence distortion, chromatic aberration, a family of 12 image transitions that hide the swap inside a surge of the live effects (picked without repeats, docs/decisions/transitions.md), hue shifts, ghost taps, stochastic bloom, feedback warping and a final vibrance stage that keeps colors vivid; a slow clarity cycle and a strain budget keep the image recognisable, scaled by the Effect intensity setting
- **Audio-visual coupling**: the music drives the visuals (note glow, scene intensity, chord-tied hue, ghost-tap burst on scene change) and each new image sends a mood (brightness, warmth, saturation, energy, mood words) back to the music. A "Sync visuals to music" switch turns the music-to-visuals direction off. See `decisions/av-coupling.md`
- **macOS and visionOS**: a window with a control panel on macOS; on visionOS a control window plus one immersive space: a 3D shell that wraps 337.5 x 120 degrees around you (the image straight ahead, mirrored continuations to the sides, above and below), pushed into real depth from the ML depth map, with every effect on it (one 2048x2048 effects render). See `decisions/spatial.md`
- **Archive footage**: while it is on, old film (from the Internet Archive, mostly 1950s and ’60s black and white) is always woven subtly into the picture under every effect: a continuous stream of short pieces (8-30 s from random points of the cached films) that crossfade into each other, each with its own look, warp and level, some swelling slowly to more prominent, slowed to 0.6-0.85x. About a third of the pieces are plain blends, and the same recipe never plays twice in a row; the rest let film and effects drive each other: the film bends the picture like thick glass (Undertow), draws itself as a contour map with split colour along it (Fringe), leaves glowing trails where it moves (Wake), paints regions of rotated hue (Aurora), folds the tone curve (Solar), lights and shades the picture like a projector (Glow), is embossed into the picture (Relief), cuts the picture into lit glass shards (Facets), posterises the picture into crawling bands (Poster), plays as shadow theatre in the picture's shadows (Shadowplay) or behind the subject on the depth map (Backdrop, visionOS), turns into a slow mandala (Kaleido) or halftone ink (Print). Effect intensity and the clarity cycle scale them, and the still image stays the anchor (checked in the visionOS Simulator at 79.4 fps with footage on); see `decisions/footage-fx.md`. Most pieces with usable audio bring a quiet wash of the film’s sound usually at original speed, with occasional slowed clips. Echo, reverb, and direct sound follow separate, irregular curves. Both echo and reverb stay present even when the words come forward. Roughly one in five audio cues uses the pronounced slowdown on purpose. Clips are fetched politely and cached (1 GB, 12 clips) and replayed with new segments. See `decisions/archive-video.md`
- **Indirect Control**: shape the experience through abstract sliders rather than direct manipulation


Psychedelic and experimental footage and vintage drug education films get extra weight in the rotating pool. When online, Liminal fills up to eight of its 12 cache slots with the titles below and rotates the rest. When a pinned film is available, at least every other piece comes from the curated set. All pieces use the same visual and audio effects. The cache remembers previous start times and looks for a fresh stretch whenever a film returns.

| Pinned film | Year | Source |
| --- | --- | --- |
| Drug Addiction | 1951 | [Prelinger Archives](https://archive.org/details/DrugAddi1951) |
| Narcotics: Pit of Despair, Part II | 1967 | [Prelinger Archives](https://archive.org/details/Narcotic1967_2) |
| Drug Abuse: The Chemical Tomb | 1969 | [Prelinger Archives](https://archive.org/details/DrugAbus1969) |
| The Flow of Zen by Alan Watts | 1969 | [Internet Archive](https://archive.org/details/alan-watts-the-flow-of-zen) |
| UFO Interview | 1966 | [National Archives via FedFlix](https://archive.org/details/342-usaf-42990) |
| LSD: The Spring Grove Experiment | 1966 | [CBS documentary via Internet Archive](https://archive.org/details/lsdthespringgroveexperiment) |
| Ergot: The Story of a Parasitic Fungus | 1958 | [Wellcome Collection](https://wellcomecollection.org/works/b92v49xa) · [Internet Archive copy](https://archive.org/details/Ergotthestoryofaparasiticfungus-wellcome) |
| Design for Dreaming | 1956 | [Prelinger Archives](https://archive.org/details/Designfo1956) |

Large films can join the rotation. Liminal prefers smaller playable versions when available. For larger downloads, it tries to keep an excerpt of up to four minutes and removes the temporary source afterward.

During archive playback, new images can borrow objects, materials, and shapes from a grayscale frame of the playing film. Liminal keeps its usual psychedelic prompt and palette and asks the model to place those details in a new scene without people or faces. The main model still targets 3:2 at 2K. Image generation can start before a film is ready, in which case it uses the usual text prompt. Cache-only mode continues to reuse saved images.

Liminal can sample a fresh excerpt from a cached film before generating the next image. If the image is ready near its reveal and the planned excerpt still fits, the film joins the reveal. Otherwise Liminal can revisit an unused start near the reference time while the image is on screen. Normal footage keeps playing if neither match is available.

## Controls

| Control | Effect |
|--------|--------|
| **Style** | Drift, Glass, Deep or Garden music palette |
| **Density** | How many notes the pointed layers play |
| **Space** | Reverb size and dark halo |
| **Echo** | Audio delay and visual ghost-trail intensity |
| **Scale** | "Auto (evolving)" lets key and mode drift; choosing a scale pins it |
| **Effect intensity** | How far the effects bend the picture, Subtle to Wild (default 50%). The effects breathe between clear and wild stretches over minutes, and each new image starts clear. See `decisions/effects-balance.md` |
| **Sync visuals to music** | Music drives hue, motion, bloom and ghost bursts (on by default) |
| **Debug effect** | Debug visualization of the effect (macOS panel) |
| **Cache only** | Skip generation and recycle cached images |
| **New images per hour / day** | Spending cap on Gemini image generation (default 20 / 50); past it, cached images are shown |
| **Reset Generation Counts** | Starts the rolling hourly and daily usage counts at zero. Future generations still count toward the configured limits. |
| **Clear All Images** | Wipes every cached image after confirmation and restarts generation |
| **Archive footage** | Old film always woven subtly into the scene (on by default); turning it off fades picture and sound out in 2 s |
| **Change speed** | Slow / Medium / Fast: a new piece of film drifts in every 20-30 / 12-20 / 8-12 s (default Medium) |
| **Footage audio** | Level of the film's own sound when a piece brings it, 0 = silent, 50% = the tuned default, 100% = +6 dB |
| **Clear Footage** | Deletes the cached films (keeps the ones on screen) |
| **Reset All Settings** | Restores defaults |

On macOS the panel scrolls, and Cache only, Clear All Images and Reset live in a "Storage & Settings" sheet (Cmd-,). The Archive Footage card (both platforms) also shows what is on screen, the cache size and the film source credit. On visionOS all controls are in the control window (Playback, Music, Archive Footage, Visuals, Images & Storage), plus Enter/Exit Liminal (the immersive space) and a Depth slider for how far the relief comes toward you. While immersed, tap the scene outside the controls to hide the window or bring it back.


