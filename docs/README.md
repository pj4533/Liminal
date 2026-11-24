# Documentation

[← Liminal](../README.md)

| Guide | Contents |
| --- | --- |
| [Getting started](getting-started.md) | Requirements, builds and tests |
| [Recording](recording.md) | 16:9 HEVC movies with 24-bit stereo audio on Mac and Vision Pro, Photos permissions, and verification |
| [Experience and controls](experience.md) | Lo-Fi music, visuals, the thirteen pinned films, rotating discoveries, source credits and playback settings |
| [Research index](research/README.md) | All research by topic: producers and what Liminal took from each, Lo-Fi production, dialogue chopping, instruments, bass and pads, mix and distortion, visuals and image APIs, simulator tooling |
| [Mix verification](mix-verification.md) | How to capture per-bus stems and measure loudness, true peak, masking, low end, intelligibility and chop cadence, and how to read the report |
| [Dialogue release verification](plans/dialogue-salience/acceptance-ledger.md#local-release-verification-on-the-mac) | Local checks for word boundaries, hook timing, learned footage selection and mix balance |
| [MPC chopping plan](plans/mpc-chopping.md) | Work packages, acceptance criteria and deferred items |
| [MPC chopping measurements](plans/mpc-chopping-measurements.md) | Baseline and final matrix results, criteria changes and listening checks |
| [Lo-Fi instrument recordings](lofi-samples.md) | Sources for the twenty-one piano, plucked string and guitar programs |
| [Bass tone redo plan](plans/bass-tone-redo.md) | The warm sustained sub with a short strike on the kick, its gates and measurements (D119; rotation D120) |
| [Drop transitions plan](plans/drop-transitions.md) | Lo-Fi image changes that build over the drum fill and cut clean on the downbeat (T44-T50) |
| [Image sources](image-sources/README.md) | Overview of the curated image pipeline, what the user sees, and the flow |
| [Image pipeline](image-sources/pipeline.md) | End to end: rotation, search paging and ledger, download, trimming, gates and thresholds, pool, display, Lo-Fi timing, credits, logs, flags |
| [Image sources list](image-sources/sources.md) | Every source in `image-collections.json`: searches, measured sizes, high-resolution routes, rights, weights, pins and credits |
| [Image providers](image-sources/providers.md) | LoC, NASA, Commons, Cleveland, the Met, Digital Commonwealth, AIC and Smithsonian: endpoints, paging, fields, high-resolution tricks and pitfalls |
| [Adding an image source](image-sources/adding-a-source.md) | Researching a collection, the JSON fields, writing a provider with fixtures and tests, and live verification |
| [Image research history](image-sources/research-history.md) | From OpenPics to the 2026-11-21 research passes, and every rejected source with its reason |
| [Curated pictures plan](plans/image-api-mode.md) | The provider layer, pool, gates and outcome (D36-D44) |
| [Architecture](architecture.md) | Audio, image and rendering pipelines, dependencies and attribution |
| [Development reference](development.md) | Debug flags, automation scripts and contributing |
| [Decision records](decisions/README.md) | Design rationale and review index |
| [Agent guide](../AGENTS.md) | Repository map and working conventions |
| [Claude Code guide](../CLAUDE.md) | Agent guide plus concurrency, audio and rendering contracts for Claude Code |

Implementation plans live in [plans](plans/), and investigations in [research](research/README.md). These include historical and proposed work; consult source and decision records for current behavior.
