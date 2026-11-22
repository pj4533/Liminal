# Lo-Fi instrument and arrangement qualification

## Acoustic sampler comparison

At the time of this comparison the acoustic bank contained 43 recordings, 4,917,750 bytes on disk and 9,830,084 bytes of decoded mono Float32 PCM before decoder and array overhead. Steinway has seven roots with two recorded velocities per root. Quiet pipe organ and plucked psaltery cover five and four roots respectively. Their preparations and sources are in the [instrument credits](../../lofi-samples.md).

One matched-source macOS manual render compared Liminal's Swift bank to `AVAudioUnitSampler`. Both received the same Steinway D4 WAV and a MIDI C4 at the 0.5-beat offset, velocity 0.57, duration 0.6 beats, 70 BPM and 48 kHz. The file is a 128,044-byte mono WAV with 256,000 decoded PCM bytes. The dry left-channel timing below uses the first and last sample above 1% of each take's own maximum. A Hann-windowed frequency scan used the same 10,000-frame steady-state region in each take. Apple single-file loading used the WAV as C4, so the matched comparison used a –200-cent global correction for that one recording. A production bank would need per-zone tuning and velocity mapping. [Apple sampler reference](https://sosumi.ai/documentation/avfaudio/avaudiounitsampler)

| Provider | Frequency | Attack after scheduled onset | Release after note-off |
| --- | ---: | ---: | ---: |
| Liminal mapper, envelope and tone | 261.50 Hz | 48 samples / 1.00 ms | 199.44 ms |
| Apple sampler with raw WAV settings | 293.25 Hz | 7 samples / 0.15 ms | 0.94 ms |
| Apple sampler with explicit tuning | 261.50 Hz | 8 samples / 0.17 ms | 0.94 ms |

The source and note placement match after tuning correction. The default Apple release was almost immediate in this configuration. The difference comes from these instrument settings and envelopes. An authored Apple instrument with its own release could behave differently. The current sampler owns root and velocity selection, click-safe envelopes and predictable output on both app targets. The comparison supports keeping it as the default acoustic provider while testing a properly mapped Apple bank against the same score and licensed recordings.

Two separate cold command-line runs spent 25.3–35.8 ms loading and 0.66–1.01 ms synthesizing the Swift note, then 348–417 ms constructing, loading and rendering two offline Apple graphs. Frequency and attack/release measurements matched across both runs. These measurements include different work and framework initialization. They are environment traces and do not qualify CPU cost, first-note latency or resident memory on Vision Pro. Test machine ran macOS 27.2.1 build 26B131 and Xcode 27.2 build 27B52. A shell under the restricted filesystem/runtime sandbox could not instantiate Apple's sampler. The local macOS process had access. No third-party provider was required.

Run from the repository root. The optional output directory gets two level-matched audition WAVs based on the shared sustained 210 ms region. They retain both release envelopes.

```sh
xcrun swiftc -O \
  Liminal/Audio/MusicRNG.swift Liminal/Audio/Scale.swift \
  Liminal/Audio/Lofi/{LofiScore,LofiPreset,LofiSampleBank,LofiVirtualRecord}.swift \
  tools/LofiSamplerComparison.swift -o /tmp/liminal-sampler-compare
/tmp/liminal-sampler-compare /tmp/liminal-sampler-audition
```

## Expanded instrument rotation

The bank now contains 67 recordings. The 24 additions use the Yamaha TX81Z FM piano’s lowest recorded velocity, soft vibraphone and marimba strikes, and straight bass recorder sustains. All 24 had a measured fundamental within 36 cents of the bundled MIDI root. The complete bank occupies 8,861,206 bytes on disk and decodes to 17,714,884 bytes of mono Float32 PCM before array overhead. See the [per-note recording credits](../../lofi-samples.md#credits-and-licences).

One 64-bar stereo render at 70 BPM (seed 1042, Release the Bracken followed by Bags Dude, cached archive audio) exercised every program. For each phrase, the meter measured the loudest 400 ms window in the sum of dry lead, texture and musical effects. The FM piano measured −16.89 dBFS on its statement and −17.68 on its return, vibraphone −17.23, marimba −16.83 and bass recorder −17.48. The eight earlier voices ranged from −19.38 to −16.88 dBFS in the same render. The full master measured −18.1 LUFS integrated and −4.63 dBTP.

## Build, reuse and host by role

| Role | Evidence and decision |
| --- | --- |
| Acoustic piano, organ and strings | Real recorded articulations provide timbres and attacks that already work with the same score. Keep the matched sample bank as the built-in provider. Apple's sampler merits a second test with a tuned multi-zone instrument and explicit release. |
| Bass | Purpose-built synthesis supports a centered fundamental, controlled harmonics, short play-in and a level-stable response to the drum detector. Keep the native bass path. Its tempo and detector alignment belong in the [production qualification](../lofi-production/studio.md), separate from the instrument recording test. |
| Electric keys | STK Rhodey combines two FM pairs with separate envelopes and uses waveform assets. Dynamic sidebands can supply electric-key articulation. They need a separate brightness, alias and sample-rate test before using them as an additional voice. [STK Rhodey](https://raw.githubusercontent.com/thestk/stk/master/src/Rhodey.cpp) [Chowning FM paper](https://web.uvic.ca/~aschloss/course_mat/MU307/MUS307_MATERIALS/Chowning_FM.pdf) |
| Drawbar organ | STK BeeThree combines periodic waves at harmonic ratios with amplitude and vibrato behavior. Liminal's sampled quiet pipe registration is available immediately. An additive drawbar voice would give more registration control and should be checked for kept harmonics below Nyquist and for accent stability. [STK BeeThree](https://raw.githubusercontent.com/thestk/stk/master/src/BeeThree.cpp) |
| Physical pluck | STK Plucked uses an excitation, short feedback delay and filtering. It is a basis for a synthetic articulation with independent pitch and loss controls. The harp, psaltery and pizzicato recordings supply several very different attacks without introducing a new feedback loop in the voice renderer. [STK Plucked](https://raw.githubusercontent.com/thestk/stk/master/src/Plucked.cpp) |
| Discovered AU provider | Discovery is separate from qualification. Require a repeatable load, known state and rendering, bounded latency, tested output and headset availability. Keep provider errors off the built-in score path. See the [plug-in qualification and platform matrix](../lofi-production/studio.md). |

## Virtual records from original phrases

The score can mark one occasional splice in a variation or return. The editor takes a short portion of that phrase's own rendered acoustic lead, filters it, adds mild stereo-linked saturation and smoothly tapers both edges. A seeded replay, reverse or octave-down speed choice puts it in a gap on the eighth-note grid. The edit goes to the musical effects send. The unedited dry phrase continues at its original level and timing. The materialized score records the recipe schema, seed, sample program, source note and position, destination, gain and chosen style. The source bank is traceable to the [licensed WAV credits](../../lofi-samples.md). No private drums or footage enter this preparation. A native test across 512 phrases found 96 edits spanning all three styles. Each fit a planned gap, preserved the dry source and round-tripped its provenance.

## Phrase-level comparison

The offline comparison examined 256 statement and return pairs, taking phrases 0→3 and 4→7 for each of seeds 0–127 with automatic scale selection. It ran the [previous score](https://github.com/pj4533/Liminal/blob/a0c3cddc5a7c2fe928a6e975bd744ad5adecfa25/Liminal/Audio/Lofi/LofiScore.swift) at the same phrase indices with forced statement/return labels for its historical baseline. Its random contour and harmony differ from today's. The controlled reference instead replayed the current onset mask, durations, velocities, timbre, starting pitch, mode and allowed MIDI register 50–69. At each subsequent onset it drew uniformly from nearby in-scale pitches and used a fresh stream for the return, with the same five-semitone step cap and four-semitone final cap as the current generator. It used `MusicRNG(seed: 2 * seed + phrase).fork(551)`. It therefore isolates a local next-pitch policy and absence of motif memory without changing instrumentation or note amount.

| Deterministic outcome | Previous engine | Current grammar | Controlled local walk |
| --- | ---: | ---: | ---: |
| Statement returns with its original note pattern | 0 / 256 | 256 / 256 | 2 / 256 |
| Last note reaches the tonic | 47 / 256 | 256 / 256 | 40 / 256 |
| Mean lead attacks in the statement | 3.35 | 3.68 | 3.68 |
| Mean beat of last dry note-off, out of 16 | 8.86 | 7.71 | 7.71 |
| Mean nominal lead MIDI, historical and current engines | 58.56 | 62.37 | Same allowable register as current |

These counts verify structure and free dry time and do not score quality or prove that the returns will be recognizable over effects. Nominal MIDI and audible frequency also differ where the old sampler mapped some recordings an octave high. The relevant audible comparison is to feed the two pitch policies through the same calibrated provider and effects at matched loudness, then listen for the planned ending, surprise, fatigue and how much room film speech has. Backward reachability constrains accepted notes after timing is decided. It is a small fixed rule using the terminal pitch, informed by published work on constrained sequences, evenly distributed candidate onsets and voice movement. [Markov constraints](https://www.ijcai.org/Proceedings/11/Papers/113.pdf) [Euclidean rhythms](https://www-cgrl.cs.mcgill.ca/~godfried/publications/banff.pdf) [Voice-leading geometry](https://www.brainmusic.org/EducationalActivitiesFolder/Tymoczko_chords2006.pdf)
