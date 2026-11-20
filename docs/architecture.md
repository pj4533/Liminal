# Architecture and dependencies

[← Project overview](../README.md) · [Documentation index](README.md)

## Architecture

```
Ambient audio                       Visual
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

### Lo-Fi audio

The drum player queues one complete, stereo-linked 64-beat recording per take. The bass, dry acoustic instruments, texture, and wet rack have independently scheduled buffers on the same sample grid. The five arranged stems start at one audio host time. Their first downbeat establishes the music clock and releases the visual and footage playback gate on macOS and visionOS. A sixth input carries dialogue and its effects onto the Lo-Fi bus at the scheduled hit times. Interior phrases are queued early so decoding the next drum take can overlap playback. If the next phrase still misses its deadline, playback repeats the preceding bass, dry instruments and texture on the same grid, carries the outgoing effect tail once, and reuses the current drum recording if a new take was due.

`LofiScore` builds 32-bar forms with remembered four-bar motifs and their own cadences. An acoustic or electric piano anchors each 16-bar take. Three independently seeded four-program rotations select a keyboard, a plucked string and a contrasting mallet, wind or organ. The two answering instruments take the middle phrases before the opening piano returns. Dry attacks use a bounded gain based on the strongest 75 ms window. The renderer then measures the stereo sum of the instrument, texture and its effects, including the future tail. Peak, 400 ms and three-second limits set one downward gain for the phrase. Carried tails retain their previous gain, and the drums and bass bypass this instrument trim. `LofiRenderer` uses recorded instrument sources, separate note sends, and independent echo, room, and color returns. Grid-timed fragments use isolated acoustic notes for scale-aware pitch shifts, with reverse, flutter, spectral holds, and cross-modulation as alternate recipes. A short plate and a longer hall take both melody and midrange sends, including echoes and grains. It renders off the audio thread and keeps the audible wet tail at phrase joins. Kick candidates from the unchanged drum waveform provide sample-timed visual onsets and anchor nearby scored bass attacks to the drummer’s timing. A linked low-band detector ducks only the bass. A two-beat reverse pickup leads into the eight-bar breakdown. A four-beat octave-layered pickup leads into the next take. The renderer carries their releases across phrase joins. The live player publishes the take’s audible origin and measured beat duration. The footage scheduler preloads the next decoder and centers its dissolve on that same downbeat. The primary image uses the same audible downbeat. The queue reserves a distinct image ahead of time, with bundled art available when generation or cache decoding is late. Both renderers preload the texture. `LofiImageReveal` takes its style from the same `TransitionDirector` as every other crossfade. Its clock-driven timing ends the style's swap window on the drum boundary, so the warp and exchange run through the fill, and the new image is complete on the downbeat. The lead-in is a whole number of beats, at least two. Bloom, color and film strength crest there too.

In Lo-Fi mode the footage worker also analyzes up to 32 seconds of the incoming film audio. It estimates background power in three bands, detects rises in the speech envelope, and joins nearby syllables at quieter boundaries. The sampler alternates two-bar gestures. Short calls can repeat and answer at different speeds. Where a clip has a longer stretch of speech, the sampler looks for at least four onsets and a quiet ending, plays two fragments in order, then brings back the contiguous line on the next bar’s downbeat. The full line stays within 8% of its original speed. All three hits fit before the next group or drum fill. The closest phrase in the same cue can carry a pause or foreshadow a later line. A separate player schedules the finished samples against the drum transport with output latency compensation. The continuous film goes through the archive strip’s band-pass, phaser, dark echo and room. Its direct level stays low, with one brief clarity swell per picture and a soft dip under each drop. The on-device Sound Analysis classifier ranks spoken windows above song and choir; envelope cues remain available if classification produces no results. Each chop gets corrective presence EQ, bounded gain based on K-weighted 50 ms syllable levels, a moving window up to 400 ms and a separate peak guard. A short pickup can reverse. A dotted-eighth echo and a damped stereo room blend with the direct chop before its fader. The whole channel follows the footage control and cue fades. A repeat can divide at an interior syllable onset, pause, then finish on an eighth- or sixteenth-note subdivision. Clips without usable onsets keep the same background treatment.

The melody and midrange rack can pick up a short window from its own colored return and replay three grid-timed fragments, including reversed and octave-down answers. The fragments feed filtered echoes and room sends. A soft low-pass on the upper wet band and a linked peak control keep the return focused on the mids. The renderer carries at least nine seconds or eight beats of available wet tail into the next take at the original pitch and echo spacing.

The archive store protects ten curated titles and reserves two slots for discoveries within a shared 3 GB limit. At launch, off the main actor, the store deletes files its index does not list, and stale `CFNetworkDownload_*.tmp` files and old `liminal-*` fixtures are removed from `tmp/`; indexed clips are never touched by this cleanup. When both groups are available, the weaver schedules a discovery after four curated excerpts. After its second play and outgoing fade, a discovery becomes eligible for replacement. [Film credits](experience.md#pinned-films-and-rotating-discoveries)

An incoming footage cue can decode while the current cue plays. Late PCM starts at the matching position in the active excerpt with a short fade. The Lo-Fi archive rack picks a three-tap echo pattern every four audible bars. Each pattern uses beat subdivisions for its main echo, darker stereo answer, and room reflection. The tap levels swell independently. Two delay banks let earlier echoes decay at their original timing across changes. Footage and music are summed independently before the final bus. The combined final path uses light compression, slowly adjusts gain within bounded limits, and protects sample peaks with a conservative output trim. [Research and verification](research/lofi-studio.md) · [Headless capture](development.md#lo-fi-checks)

### Dialogue chopping pipeline

Lo-Fi turns the film's speech into a small bank of related cuts and plays it against the drum take. The code is in `Liminal/Audio/Lofi/Dialogue/`; every stage is a pure function on preparation threads, and nothing here runs on the render thread.

1. **Source.** `DialogueSource` holds the immutable native-rate PCM of the incoming cue, its film start time and rate, and the cue token. `DialogueCueCoordinator` and `DialogueDirector` decode and run the stages below for each cue while the current cue plays. Analysis covers up to 32 seconds (`DialogueTuning.analysisSeconds`).
2. **Analysis.** `DialogueAnalyzer` combines the SoundAnalysis speech windows with envelopes in three bands, nuclei, voicing, pauses and clipping. A cue led by music or singing gives no bank.
3. **Hierarchy.** `DialogueHierarchy` builds `SpeechUnit`s from utterance to phrase, word group, stab and texture. Units keep their parent and source neighbours, stress anchors, protected spans and tails.
4. **Pad bank.** `DialogueBankBuilder` ranks units by sound before rhythm and keeps 8 to 12 pads (`DialoguePadBank`) with roles anchor, head, answer, stab, sibling and texture. With a transcript, `DialogueReorderGuard` may arrange a bank in a safe template (repeat a clause, omit a parenthetical, move an adverbial, exchange clauses); without one the source order stands.
5. **Motif and performer.** `DialogueMotif` is the default. One line per 16-bar loop is cut into word and syllable pieces and placed so every bar has an onset, following the drummer's timing field. When `DialogueMotif.plan` returns nil, `DialoguePerformer` runs the bounded grammar families (anchor, echo, call-response, sparse-reorder, texture-fill). Both produce a `DialoguePerformancePlan` of blocks and `DialogueEvent`s. The plan changes at least every 16 bars.
6. **Chop render.** `DialogueChopRenderer` renders each event once: linked-rate resample, noise weighting, the chop chain and light per-piece effects (echo throws in motif cells), then caches the buffer.
7. **Scheduling.** `ArchiveVoice.perform` stores a `ChopPlan` and schedules its chops sample-accurately on the transport clock. The film bed keeps playing from its own path and is never held back by analysis. Chops are placed only at or after the commit margin and a gesture the build overran is dropped whole, so a late plan never forces an immediate entrance.
8. **Token and revision rules.** A plan carries `cueToken` and `revision` (and the transport revision it was built against). `ArchiveVoice` keeps the highest revision per token and ignores a stale token or a revision no higher than the stored one. Revision 0 is the acoustic plan. A higher revision (the transcript-refined plan) replaces stored chops from `replaceFrom` on. A route or latency change is handled through the transport revision: `LofiPlayback` bumps `transportRevision`, the director sees the new snapshot revision, keeps the analysis and bank, and replans from the commit margin on, replacing chops that are not yet queued. Queued audio is never moved.
9. **Cache.** `DialogueDirector` keeps 12 analyses keyed by content id, start (to 10 ms), frame count and analysis version. The four newest keep their PCM. Transcript-refined banks are cached per `locale|modelVersion`. Analysis is cached independently of the plan, so a tempo change remaps the plan without redoing analysis.

Transcription is optional (`DialogueTranscriptionMode`: off, installed only by default, or allow one model download). `AppleSpeechTranscriptProvider` uses Apple SpeechAnalyzer and SpeechTranscriber off the scheduling path. The acoustic bank is built first and used whenever transcription is off, unavailable or late.

Handoff record names and their code types, from [the research handoff](research/mpc-chopping-handoff.md):

| Handoff record | Code type | Notes |
| --- | --- | --- |
| `SourceAudio` | `DialogueSource` | `contentID`, `cueToken`, immutable PCM, film start and rate; the frame/second conversion lives here |
| `SpeechUnit` | `SpeechUnit` (levels in `SpeechUnit.Level`) | frames, parent and neighbour ids, text and token range, confidences, stress anchors, protected spans, tail |
| `PadBank` | `DialoguePadBank` of `DialoguePad` | ordered pads, anchor pad, sibling groups, rejections, reorder arrangement |
| `TransportSnapshot` | `DialogueTransportSnapshot` | revision, take index, origin, beat durations (current and next), phrase at origin, kick and snare landmarks, lead notes, groove offsets |
| `PerformanceEvent` | `DialogueEvent` | pad, slot, accent and start time, gain, `chokeAt`, transform, cell and effect |
| (performance plan) | `DialoguePerformancePlan`, `DialogueBlock` | cue token, bank id, transport revision, plan revision |

Handoff fields with no direct counterpart:

- `speakerIDIfReliable` is omitted on purpose. Speaker identity was not reliable enough on this material to rank or group by.
- `expiryPolicy` has no field. A plan expires through the cue token (a departed clip is discarded) and the revision rules above.
- `dryChokeGroup` is not a named group. The one-voice rule is enforced per event through `chokeAt`: a later event's start shortens the earlier one, which ends 2 ms before it.
- `committedNextTempo` is carried as `nextBeatDuration` only; the committed-next key has no field.
- `latestCommitFrame` and `futureBoundaryFrames` are not stored. The planner derives the boundaries from `origin`, `beatDuration` and the phrase index, and the earliest start is a call argument.

### Per-bus chains and the master finisher

Each section has its own chain, built offline on preparation threads by `LofiStemChains` (zero latency: minimum-phase biquads and feed-forward dynamics, so landmarks found on unprocessed audio still point at the same frame) and the chop chain in `DialogueChopRenderer`.

- **Drums**: mono below 100 Hz, high-pass 32 Hz, a 320 Hz cut, a 3:1 bus compressor, 25 percent parallel 8:1 compression, tape-style saturation that rounds peaks until the take's crest reaches the target, a gentle air shelf, and a -4 dB peak ceiling. Kick attacks stay on their original frames.
- **Bass**: high-pass 30 Hz, parallel harmonics (an asymmetric tanh above 120 Hz) so the bass reads on small speakers, a 280 Hz cut, a 4.5 kHz low-pass and a 3.5:1 compressor, then the kick duck. `LofiBassVoice` supplies three bounded voices (`roundSub`, `pluck`, `longAnswer`) next to the classic one.
- **Lead and mids**: each is high-passed and shaped around the other's range (the lead gets 2.8 kHz presence, the mids a 400 Hz cut and 1.6 kHz bump), so the mids can answer the melody without masking it. The mids shell is mono below 300 Hz.
- **Space** (reverb and delay returns): high-pass 350 Hz, low-pass 4.5 kHz, ducked by the dry lead so notes are heard dry first.
- **Dialogue chops**: the chop chain keeps speech intelligible (1 to 4 kHz forward) and glues each cut to a consistent level. The film bed sits under the chops and the music (see decisions D107).
- **Film bed**: the effected soundtrack path in `ArchiveVoice` and the footage mix bus, kept dark, with a one-bar dip under each theme return.

`LofiMasterBus` hosts `LofiMasterKernel`, an audio unit whose render path allocates nothing: input trim, 25 Hz high-pass, a 1.7:1 glue compressor with a 100 Hz sidechain high-pass, a 4x oversampled soft clip, and a 3 ms look-ahead true-peak limiter at -1 dBTP. The kernel exposes meters and a gain-reduction trace for the capture harness (`LofiCaptureHooks`). Targets and measured results are in [mix verification](mix-verification.md) and [the measurements](plans/mpc-chopping-measurements.md).

## Dependencies

- [AudioKit](https://github.com/AudioKit/AudioKit), AudioKitEX and SoundpipeAudioKit: audio synthesis and effects
- [ShaderGraphCoder](https://github.com/praeclarum/ShaderGraphCoder): RealityKit shader materials
- Apple frameworks: SwiftUI, Metal, RealityKit, ARKit, Core ML, Sound Analysis and MetalFX

Swift packages are pinned in the Xcode workspace’s `Package.resolved`. Bundled depth and upscaling models live in `Liminal/`. The acoustic Lo-Fi samples are distributed under CC0. Footage comes from the Internet Archive, including the Prelinger collection. The repository’s MIT license covers its code. [Instrument credits](lofi-samples.md) · [Curated films and source rights](experience.md)


