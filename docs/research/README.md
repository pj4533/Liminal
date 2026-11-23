# Research

[← Documentation](../README.md)

Investigations behind Liminal's design, grouped by topic. Research may describe unfinished or historical work: the source and the [decision records](../decisions/README.md) say what the app does now, and [plans](../plans/) hold the implementation plans built from these notes.

## Producers and craft

The people and crews whose techniques we studied, one file each, with what Liminal took from them. Start here for any "how did RZA / Premier / Dilla do it" question.

| Doc | Contents |
| --- | --- |
| [Producers index](producers/README.md) | Who was studied, what was taken, evidence grades, and who had no usable sources |
| [DJ Premier](producers/dj-premier.md), [J Dilla](producers/j-dilla.md), [Pete Rock](producers/pete-rock.md), [RZA and the Wu-Tang Clan](producers/rza-and-wu-tang.md) | The four with the most sourced material |
| [Madlib](producers/madlib.md), [The Alchemist](producers/the-alchemist.md), [Griselda producers](producers/griselda.md), [Ski Beatz](producers/ski-beatz.md), [Todd Edwards](producers/todd-edwards.md), [Kaytranada](producers/kaytranada.md), [Bob Power and Roger Linn](producers/bob-power-and-roger-linn.md) | The rest |

## Lo-Fi music

| Doc | Contents |
| --- | --- |
| [Lo-Fi composition and production](lofi-production/README.md) | Index of the Lo-Fi composition notes |
| [Studio research](lofi-production/studio.md) | Composition, mixing, effect design, and automated audio checks |
| [Handoff follow-through](lofi-production/handoff-checklist.md) | Arrangement, instrument levels, eight-bar image changes and measured dialogue, effects and soundtrack levels |
| [Strummed hook craft](lofi-production/strum-hook-craft.md) | Strum mechanics, chord vocabulary, density caps and pattern archetypes (input to D128) |
| [Bass and pad research](bass-and-pads/README.md) | Boom bap and dub bass, pad chords under a lead, CC0 bass samples, and the plan for the 2026-11-20 rework |
| [Instrument research](instruments/README.md) | Index of the instrument notes |
| [Instrument source survey](instruments/sources.md) | Redistributable piano, guitar and string recordings, licences, and the ones rejected |
| [Instrument qualification](instruments/qualification.md) | Sampler comparison, articulation, pitch, and phrase memory |
| [Strummed instrument survey](instruments/strum-survey.md) | Guitar, harp and zither recordings considered for strums, measurements, licences, what was added or rejected (D128) |

## Dialogue chopping

| Doc | Contents |
| --- | --- |
| [Dialogue chopping index](dialogue-chopping/README.md) | Index of the chopping notes |
| [Handoff](dialogue-chopping/handoff.md) | The brief for dialogue chopping, bass, drum landmarks, theme return and transcription |
| [Craft](dialogue-chopping/craft.md) | Chop points, bank size, cadence, exact repetition, tight onsets and gates |
| [Technical](dialogue-chopping/technical.md) | SpeechAnalyzer, onset detection, time stretch, bass synthesis, vDSP, LUFS |
| [Speech transcription qualification](dialogue-chopping/transcription-qualification.md) | Apple SpeechAnalyzer measurements and the acoustic fallback |

## Mix

| Doc | Contents |
| --- | --- |
| [Mix index](mix/README.md) | Index of the mix notes |
| [Mix engineering](mix/engineering.md) | Per-bus effect chains, spectral space and master finishing practice |
| [Bass translation handoff](mix/translation-handoff.md) | Keeping the bass line identifiable on small speakers and in mono while headphones keep the low end; plan, experiments, source ledger (D129) |
| [Mix distortion](mix/distortion/README.md) | How distortion was detected by measurement, gain staging, and the drive sweep behind D121 |

## Visuals

| Doc | Contents |
| --- | --- |
| [Visual research index](visuals/README.md) | Index of the image and transition notes |
| [Drop transitions](visuals/drop-transitions.md) | Glitch and datamosh craft, drop-edit timing and audiovisual sync tolerances behind T44-T50 |
| [Image API survey](visuals/image-apis/survey.md) | Which public image APIs work in 2026, their keys, resolution and rights |
| [Image collections](visuals/image-apis/collections.md) | The curated collections, measured sizes, rejections and live ingest results |
| [More image institutions](visuals/image-apis/other-institutions.md) | Commons, NASA, Cleveland and Met sources |
| [Library of Congress collections](visuals/image-apis/loc-collections.md) | Which Prints and Photographs collections reach 2000 px, rights, kept and rejected |
| [Image providers to add](visuals/image-apis/new-providers.md) | Institutions that need a new provider, ranked |
| [OpenPics notes](visuals/image-apis/openpics.md) | Endpoints and lessons from the earlier OpenPics app |

## Tooling

| Doc | Contents |
| --- | --- |
| [visionOS Simulator automation](visionos-sim-automation/README.md) | How to drive and measure the visionOS Simulator from Claude Code: MCP servers, Apple tooling, GUI automation, performance measurement |

## Conventions

- One topic per folder, with an index when a folder has more than two notes. Folder names are topics, file names drop the topic prefix.
- Evidence about a person lives in [producers](producers/README.md) and nowhere else. A topic note keeps the general rules and links to the producer file.
- Dates and decision numbers (D114, D128) tie each note to the code. Move files with `git mv` so history follows, and check that every relative link still resolves after a move.
