# Documentation

[← Liminal](../README.md)

| Guide | Contents |
| --- | --- |
| [Getting started](getting-started.md) | Requirements, API keys, builds and tests |
| [Experience and controls](experience.md) | Music, visuals, the ten pinned films, rotating discoveries, source credits and playback settings |
| [Lo-Fi studio research](research/lofi-studio.md) | Composition, mixing, effect design, and automated audio checks |
| [Lo-Fi handoff follow-through](research/lofi-handoff-checklist.md) | Arrangement, instrument levels, eight-bar image changes and measured dialogue, effects and soundtrack levels |
| [Mix verification](mix-verification.md) | How to capture per-bus stems and measure loudness, true peak, masking, low end, intelligibility and chop cadence, and how to read the report |
| [MPC chopping research handoff](research/mpc-chopping-handoff.md) | The brief for dialogue chopping, bass, drum landmarks, theme return and transcription |
| [Lo-Fi mix engineering](research/lofi-mix-engineering.md) | Per-bus effect chains, spectral space and master finishing practice |
| [Speech transcription qualification](research/speech-transcription-qualification.md) | Apple SpeechAnalyzer measurements and the acoustic fallback |
| [MPC chopping plan](plans/mpc-chopping.md) | Work packages, acceptance criteria and deferred items |
| [MPC chopping measurements](plans/mpc-chopping-measurements.md) | Baseline and final matrix results, criteria changes and listening checks |
| [Lo-Fi instrument qualification](research/lofi-instrument-qualification.md) | Sampler comparison, articulation, pitch, and phrase memory |
| [Lo-Fi instrument recordings](lofi-samples.md) | Sources for the twenty piano, plucked string and guitar programs |
| [Instrument source survey](research/instrument-sources.md) | Redistributable piano, guitar and string recordings, licences, and the ones rejected |
| [Bass and pad research](research/bass-and-pads/README.md) | Boom bap and dub bass, pad chords under a lead, CC0 bass samples, and the plan for the 2026-11-20 rework |
| [Mix distortion research](research/mix-distortion/README.md) | How distortion was detected by measurement, gain staging, and the drive sweep behind D121 |
| [Bass tone redo plan](plans/bass-tone-redo.md) | The warm sustained sub with a short strike on the kick, its gates and measurements (D119; rotation D120) |
| [Drop transitions research](research/drop-transitions.md) | Glitch and datamosh craft, drop-edit timing and audiovisual sync tolerances behind T44-T50 |
| [Drop transitions plan](plans/drop-transitions.md) | Lo-Fi image changes that build over the drum fill and cut clean on the downbeat (T44-T50) |
| [Image sources (AI and API)](image-sources/README.md) | Overview of API image mode, what the user sees, no Gemini spend, and the flow |
| [API image pipeline](image-sources/pipeline.md) | End to end: rotation, search paging and ledger, download, trimming, gates and thresholds, pool, display, Lo-Fi timing, credits, logs, flags |
| [API image sources](image-sources/sources.md) | Every source in `image-collections.json`: searches, measured sizes, high-resolution routes, rights, weights, pins and credits |
| [API image providers](image-sources/providers.md) | LoC, NASA, Commons, Cleveland, the Met, Digital Commonwealth, AIC and Smithsonian: endpoints, paging, fields, high-resolution tricks and pitfalls |
| [Adding an API image source](image-sources/adding-a-source.md) | Researching a collection, the JSON fields, writing a provider with fixtures and tests, and live verification |
| [API image research history](image-sources/research-history.md) | From OpenPics to the 2026-11-21 research passes, and every rejected source with its reason |
| [Image API survey](research/image-apis/survey.md) | Which public image APIs work in 2026, their keys, resolution and rights |
| [Image collections](research/image-apis/collections.md) | The curated collections API mode rotates through, measured sizes, rejections and live ingest results |
| [More image institutions](research/image-apis/other-institutions.md) | Second research pass outside the Library of Congress: Commons, NASA, Cleveland and Met sources |
| [Image providers to add](research/image-apis/new-providers.md) | Institutions that need a new provider, ranked; Digital Commonwealth and AIC were implemented |
| [OpenPics notes](research/image-apis/openpics.md) | Endpoints and lessons from the earlier OpenPics app |
| [API image mode plan](plans/image-api-mode.md) | The AI vs API source toggle, provider layer, pool, gates and outcome (D36-D44) |
| [Architecture](architecture.md) | Audio and rendering pipelines, dependencies and attribution |
| [Development reference](development.md) | Debug flags, automation scripts and contributing |
| [Decision records](decisions/README.md) | Design rationale and review index |
| [Agent guide](../AGENTS.md) | Repository map and working conventions |
| [Claude Code guide](../CLAUDE.md) | Agent guide plus concurrency, audio and rendering contracts for Claude Code |

Implementation plans live in [plans](plans/), and investigations in [research](research/). These include historical and proposed work; consult source and decision records for current behavior.
