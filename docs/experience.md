# The Liminal experience

[← Project overview](../README.md) · [Documentation index](README.md)

## Features

- **Generative audio** includes Ambient with eight synthesis layers and four styles, and [Lo-Fi](#lo-fi) with sampled acoustic pianos, plucked strings and clean guitars, a warm riddim bass in three rotating tones, a held pad, MPC-style dialogue chops, and optional local drum recordings. The [music decision record](decisions/music.md) covers the Ambient engine.
- **AI Visuals**: Gemini image generation (gemini-nano-banana-2.1, the configured primary model, 3:2 at 2K; hourly and daily spending cap) driven by a style/subject/transformation/palette prompt system for varied, photoreal-but-surreal imagery. See `decisions/images.md`
- **GPU Effects**: one Metal fragment shader with Ken Burns motion, turbulence distortion, chromatic aberration, a family of 12 image transitions that hide the swap inside a surge of the live effects (picked without repeats, docs/decisions/transitions.md), hue shifts, ghost taps, stochastic bloom, feedback warping and a final vibrance stage that keeps colors vivid; a slow clarity cycle and a strain budget keep the image recognisable, scaled by the Effect intensity setting
- **Audio-visual coupling**: the music drives the visuals (note glow, scene intensity, chord-tied hue, ghost-tap burst on scene change) and each new image sends a mood (brightness, warmth, saturation, energy, mood words) back to the music. A "Sync visuals to music" switch turns the music-to-visuals direction off. See `decisions/av-coupling.md`
- **macOS and visionOS**: a window with a control panel on macOS. On visionOS, a control window and a fully immersive space with imagery in every direction. The image ahead and its mirrored continuations have 3D relief. Above, below, and behind you, they fade into a softer surround that shares the same effects and image transitions. See `decisions/spatial.md`
- **Archive footage** blends excerpts from cached films into the generated scene. One shot can leave glowing trails where a figure moves, while the next bends the picture like glass or casts a shadow against the depth map on Vision Pro. In Ambient, the change-speed setting controls the length of each shot. In Lo-Fi, the drum fills cue the edits and the sampler can turn words from the shot into a rhythmic phrase. [Footage effects](decisions/footage-fx.md) · [Film audio and scheduling](decisions/archive-video.md)
- **Indirect Control**: shape the experience through abstract sliders rather than direct manipulation


## Pinned films and rotating discoveries

Psychedelic and experimental footage and vintage drug education films get extra weight in the rotating pool. Liminal plays four short excerpts from the pinned films for every discovery when both are available. The 12-film cache holds ten pinned films and two rotating discoveries. Pinned films download in the background during online playback and can play offline once cached. After a discovery has played twice, Liminal brings in a new title in the background once the old one has faded out. All pieces use the same visual and audio effects. The cache remembers previous start times and looks for a fresh stretch whenever a film returns.

| Pinned film | Year | Source |
| --- | --- | --- |
| The World of LSD | 1967 | [Firing Line via the American Archive of Public Broadcasting](https://archive.org/details/aapb-cpb-aacip-514-n00zp3ws90) |
| History of Marijuana Legislation, Part One | 1967–1974 | [KCRA-TV footage via the Center for Sacramento History](https://archive.org/details/VAM026) |
| The Mind-Benders: LSD and the Hallucinogens | c. 1970 | [National Archives via Public.Resource.Org](https://archive.org/details/gov.archives.arc.13260) |
| The Flow of Zen by Alan Watts | 1969 | [Internet Archive](https://archive.org/details/alan-watts-the-flow-of-zen) |
| UFO Interview | 1966 | [National Archives via FedFlix](https://archive.org/details/342-usaf-42990) |
| A Conversation on LSD | 1979 | [Timothy Leary Archives](https://archive.org/details/Timothy_Leary_Archives_198) · [Recording date](https://upload.erowid.org/culture/characters/stolaroff_myron/stolaroff_myron_video1.shtml) |
| Ergot: The Story of a Parasitic Fungus | 1958 | [Wellcome Collection](https://wellcomecollection.org/works/b92v49xa) · [Internet Archive copy](https://archive.org/details/Ergotthestoryofaparasiticfungus-wellcome) |
| Design for Dreaming | 1956 | [Prelinger Archives](https://archive.org/details/Designfo1956) |
| Horizons of Science: Thinking Machines | 1959 | [Educational Testing Service via Internet Archive](https://archive.org/details/horizons-of-science-thinking-machines) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Hear Here | 1969 | [Stanford Artificial Intelligence Laboratory via Internet Archive](https://archive.org/details/sailfilm_hear) |

Liminal prefers smaller playable versions when available and keeps full copies of pinned titles when they fit in the 3 GB cache. For larger discovery downloads it tries to keep an excerpt of up to four minutes and removes the temporary source afterward. Each launch deletes footage files the cache index does not list and abandoned download files in the app's temporary folder; nothing that can play is removed.

During archive playback, new images can borrow objects, materials, and shapes from a grayscale frame of the playing film. Liminal keeps its usual psychedelic prompt and palette and asks the model to place those details in a new scene without people or faces. The main model still targets 3:2 at 2K. Image generation can start before a film is ready, in which case it uses the usual text prompt. Cache-only mode continues to reuse saved images.

Liminal can sample a fresh excerpt from a cached film before generating the next image. If the image is ready near its reveal and the planned excerpt still fits, the film joins the reveal. Otherwise Liminal can revisit an unused start near the reference time while the image is on screen. Normal footage keeps playing if neither match is available.

If Gemini reports a billing error, Liminal cycles through cached images while it waits to retry. The first retry is after about a minute, with longer pauses if billing errors continue. Restarting Liminal clears the pause.

## Lo-Fi

Choose **Lo-Fi** in the Music section. Set the **BPM** and optionally pin a **Scale**. Changes wait for a 16-bar boundary. Each installed drum take plays in its original order for all 16 bars, with tempo and pitch changing together to fit the selected BPM. The next take is selected around that tempo. Lo-Fi gets the next picture ready ahead of each eight-bar boundary. If the queue and cache have no different image ready, two bundled Liminal pictures can alternate offline. When you press Play, **Preparing beat…** is shown until the music is ready. The image effects and archival footage start with the music clock.

A piano hook opens each take: a grand, a quiet felt-like grand or an upright, each with more or less tape wobble, darkness and room. A plucked string answers in one middle phrase, and a clean guitar plays the other: nylon, steel, an archtop or a flatwound electric. The guitar plays like a guitarist rather than a keyboard. It strums chords with the strings a few milliseconds apart, now and then strumming upward, picks broken chords after a held note, adds double stops, and slides into some notes from a step below. Every instrument is level matched so none of them stands out of the mix. The opening piano and hook return together. A two-beat pickup swells into the drummer’s eight-bar fill. When the drummer starts the fill, the picture starts to break up: torn strips, sliding macroblocks, a datamosh smear, a resolution crush, a VHS roll, pixel-sort streaks, a zoom punch, a slit-scan shear, stutter cuts, a stepping kaleidoscope fracture, closing shutters, static, blocks of the next picture bleeding through, or a tile shuffle (six of the ambient styles also run this way). The break-up jolts with the drummer's own hits, gets faster and heavier through the fill, and often ends in a flash, a blackout, an inverted frame or a CRT-style collapse. On the downbeat the new picture is simply there, clean, with no fade in; the film's piece change finishes on the same hit. The change after eight bars is a lighter version of the same drop, without the bright flashes. The style, colour treatment and ending change from one image change to the next. The returning piano marks the next drum take. Melody and midrange accompaniment feed crossed beat echoes, a short plate and a longer hall, reversed fragments, and pitched replays that follow the scale. Some phrases replay soft fragments of their own effects. The character shifts between grain clouds, resonance, tape color, and spectral holds, with long tails and a softened upper range.

For a private build with AJ Hall’s Slow Burn packs (Vol. 1–4 are supported), copy each pack’s 64-beat breaks (Vol. 1 `BREAKS!`, Vol. 2 and Vol. 3 `DRUM BREAKS!`, Vol. 4 `FINAL BREAKS`) into `Liminal/SlowBurnDrums/` before building, renamed to `AJ_HALL_DRUM_BREAK_<NAME>_<BPM>_BPM.wav` (Vol. 1, 2 and 4 use `A.J._HALL_…` and `@AJHALL89_…` prefixes). A break that is not exactly 64 beats at its labeled tempo is skipped. At each 16-bar take the player picks at random among the breaks within 4 BPM of the closest one to the set tempo, never the take that just played, and plays it at the set tempo like a turntable’s pitch control (D122). Xcode copies those local files into the app, and playback checks the labeled tempo against each recording’s length to recover its beat grid. The recordings and any local beat-grid catalog are ignored by Git. A build without sample files can also use the verified library from an earlier install on that device, or play the generated accompaniment without drums.

The 25 verified recordings each span 16 bars. Liminal plays each break in its original order at a nearby tempo and chooses the next break after one pass.

Ambient and the footage soundtrack share slowly changing phasing and a second echo that feeds the reverb. In Lo-Fi, the original soundtrack moves beneath the instruments. Echo patterns change every four bars, with a main echo, a darker stereo answer, and a reflection that opens into the room. The spacing follows the drums and the taps swell and fade as the pattern changes. The bass makes a little room for strong kicks. The film, instruments, and rhythm share light compression and bounded loudness adjustment at the output.

With **Footage audio** up, Lo-Fi listens for the rise and fall of syllables in the incoming shot. A few words can become a hook that lands two or three times over two bars. The original soundtrack drifts in and out through phaser, echo and reverb. The sampler favors spoken lines, softens each cut to suit the mix, and lets a dark, beat-timed echo and room trail the words. Occasionally a short pickup plays backwards. Sometimes a pickup quotes one syllable, or a repeated line pauses and finishes on an offbeat. When the speaker carries on for a few words, you can hear two pieces in succession and then the whole line together on the downbeat of bar two or four. The sampler leaves space for the drummer’s eight-bar fill. It works from the current film locally, including when playback uses the cache offline.

Dialogue chops play in every bar, cut from a small stable bank of related pieces (eight to twelve) taken from the current film: whole phrases, word groups and single stabs, with the occasional texture. Most hits are pieces of one line rather than the whole line, which plays at most twice per 16 bars. Every 16-bar loop leads with a fresh line. When the current film has nothing usable (narration buried under music, say), the loop takes a fresh line from one of the last few films heard rather than repeating the previous loop. Chops sit inside the drummer's feel and land on the downbeats. They are tucked into the music, at about the level of the melody, darker and wetter than the dry voice, with echo throws of several repeats on most cell endings, reversed pickups into turnarounds and a long, dark room.

The **Dialogue understanding** setting in the Archive Footage card controls whether Liminal may read the words. Off uses acoustic analysis only. Installed only (the default) uses Apple's on-device speech model when the system already has it. Allow download lets Liminal fetch the model once. The transcript only improves where cuts fall and lets a clause repeat or reorder when that is safe; the acoustic path is always built first and is what plays when the model is off, missing or late. Nothing is sent off the device.

An excerpt whose audio falls below the silence threshold can play with visuals alone. The music continues while Liminal waits for the next footage cue.

## Controls

| Control | Effect |
|--------|--------|
| **Music mode** | Ambient or Lo-Fi |
| **BPM** | Lo-Fi playback tempo |
| **Style** | Ambient palette. Choose Drift, Glass, Deep, or Garden. |
| **Scale** | Ambient harmony. Auto lets key and mode drift. Choosing a scale pins it. |
| **Effect intensity** | How far the effects bend the picture, Subtle to Wild (default 50%). The effects breathe between clear and wild stretches over minutes, and each new image starts clear. See `decisions/effects-balance.md` |
| **Sync visuals to music** | Music drives hue, motion, bloom and ghost bursts (on by default) |
| **Debug effect** | Debug visualization of the effect (macOS panel) |
| **Cache only** | Skip generation and recycle cached images |
| **New images per hour / day** | Spending cap on Gemini image generation (default 20 / 50); past it, cached images are shown |
| **Reset Generation Counts** | Starts the rolling hourly and daily usage counts at zero. Future generations still count toward the configured limits. |
| **Clear All Images** | Wipes every cached image after confirmation and restarts generation |
| **Archive footage** | Old film always woven subtly into the scene (on by default); turning it off fades picture and sound out in 2 s |
| **Change speed** | Ambient changes film every 20–30, 12–20, or 8–12 seconds (Slow, Medium, Fast). Lo-Fi follows the eight-bar drum fills. |
| **Footage audio** | Mutes both the film and its sampled drops at 0%. The mix is tuned at 50%. Turning it up gives the film up to 6 dB more level, while the musical drops gain at most 1.2 dB. |
| **Clear Footage** | Deletes the cached films (keeps the ones on screen) |
| **Reset All Settings** | Restores defaults |

In Lo-Fi the bass is the foundation, about as loud as the drums. It plays a short riddim figure built on the drummer's own kicks, a two-bar cell that runs through a drum take and changes with the next one. The notes ring on into each other as one continuous, warm tone, with a breath now and then before a pickup, and every note that lands on a kick is struck with it: a short, hard slap on the kick's attack that is gone within a tenth of a second, while a deep synthesized sub and a dark body carry the note. The body has three tones, a rolled-off flatwound electric, an upright and a purely synthesized one, and the bass changes to a different tone at each 16-bar break, so a long session never settles on one sound. Nothing in the bass is bright or thin; the kick supplies the high end of each hit. Now and then a last note is thrown into a dub echo and spring, and breakdowns open the bass's filter and drop it out for a beat or two before the return slams back in. The chords are a soft held pad under the melody: the phrase's own instrument frozen into a slow swell that holds the whole phrase and moves one inner voice halfway through, darker and quieter than the melody, ducking a little under its notes. Once or twice per drum take a short chord answers the melody in a rest. Nothing in the mix is meant to jump out. When a phrase's opening hook returns later in a take, the return is brought forward: the mids and effect returns stay under it, the first two notes get a small accent, and the film bed steps down for a bar so the theme is recognized. The film bed itself stays dark, effected and well under the music, audible in the gaps between chops.

Liminal varies note density, reverb, and echo slowly and independently. The mix stays sparse while the balance between the bass, musical textures, and their tails evolves.

On macOS the panel scrolls, and Cache only, Clear All Images and Reset live in a "Storage & Settings" sheet (Cmd-,). The Archive Footage card (both platforms) also shows what is on screen, the cache size and the film source credit. On visionOS all controls are in the control window (Playback, Music, Archive Footage, Visuals, Images & Storage), plus Enter/Exit Liminal (the immersive space) and a Depth slider for how far the relief comes toward you. While immersed, tap the scene outside the controls to hide the window or bring it back.


