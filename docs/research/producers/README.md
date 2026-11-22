# Producers and crews

[← Research](../README.md)

One file per producer, engineer or crew whose methods we studied for the Lo-Fi music, and what Liminal did with each. Each file has the same shape: who they are, their techniques **as the sources describe them** (with how much weight each source carries), what Liminal took or declined (linked to the decision records in [docs/decisions/music.md](../../decisions/music.md)), and the sources.

The topic notes keep the general craft rules and link here for the producer evidence, so a claim about a producer lives in exactly one place. Evidence grades used throughout: sourced or confirmed (a quote or fact read in the source), secondary (a journalist's or analyst's description), general (musicianship knowledge, no source), hypothesis (a number to tune). Nobody listened to any record in the research; every "what Liminal took" is a design translation, not a copy of anyone's sound.

| Producer | Studied for | What Liminal took | Decisions |
| --- | --- | --- | --- |
| [DJ Premier](dj-premier.md) | A small stab vocabulary: restart one stab, pitch a sibling, flip-flop pads | Related pieces with stable roles, repeated exactly, short stabs; declined the pitched sibling | [D125](../../decisions/music.md#d125-the-motif-becomes-a-hook-one-2-bar-cell-on-fixed-steps-varied-only-at-the-phrase-ends-2026-11-21), [D126](../../decisions/music.md#d126-tight-gated-dialogue-chops-waveform-onsets-per-hit-gates-and-a-step-grid-that-follows-only-its-own-drum-hit-2026-11-21) |
| [J Dilla](j-dilla.md) | Groove among timing layers, selective choices, bass | Preserve the drummer's timing; fixed per-loop feel offsets of at most 25 ms, never random jitter | [D127](../../decisions/music.md#d127-the-chop-beat-mixes-its-pieces-plays-off-the-drums-and-has-a-feel-per-loop-2026-11-2122) |
| [Pete Rock](pete-rock.md) | Playback speed as a character choice; longer phrases | Native rate stays a real candidate; the chops are native rate only | [D125](../../decisions/music.md#d125-the-motif-becomes-a-hook-one-2-bar-cell-on-fixed-steps-varied-only-at-the-phrase-ends-2026-11-21) |
| [RZA and the Wu-Tang Clan](rza-and-wu-tang.md) | Guitar used as a sample: one stab, exact repeats, detune, too much guitar as failure | The strummed hook: a few choked stabs off the drums, one echo throw, hard caps | [D128](../../decisions/music.md#d128-strummed-hooks-played-off-the-drums-in-the-guitar-and-harp-phrases-with-one-echo-throw-2026-11-22) |
| [Madlib](madlib.md) | A loose, loop-oriented method | Research rules only; not adopted | none |
| [The Alchemist](the-alchemist.md) | A basic loop with imagined structure | Supports the loose-loop idea; not adopted | none |
| [Griselda producers](griselda.md) | Short, dusty, unresolved loops (general knowledge only) | Nothing; no sources found | none |
| [Ski Beatz](ski-beatz.md) | Choose attractive sounds first, fit tempo later | Select characterful units, then fit stress anchors to the beat | [D124](../../decisions/music.md#d124-dialogue-lines-are-chosen-by-how-interesting-their-words-are-2026-11-21)-[D127](../../decisions/music.md#d127-the-chop-beat-mixes-its-pieces-plays-off-the-drums-and-has-a-feel-per-loop-2026-11-2122) |
| [Todd Edwards](todd-edwards.md) | Prepared sample banks and vocal texture (house, cross-genre) | A stable pad bank; speech kept separate from texture | [D125](../../decisions/music.md#d125-the-motif-becomes-a-hook-one-2-bar-cell-on-fixed-steps-varied-only-at-the-phrase-ends-2026-11-21) |
| [Kaytranada](kaytranada.md) | Chops on off-beat sixteenths | The "e" and "a" placement bias | [D126](../../decisions/music.md#d126-tight-gated-dialogue-chops-waveform-onsets-per-hit-gates-and-a-step-grid-that-follows-only-its-own-drum-hit-2026-11-21), [D127](../../decisions/music.md#d127-the-chop-beat-mixes-its-pieces-plays-off-the-drums-and-has-a-feel-per-loop-2026-11-2122) |
| [Bob Power and Roger Linn](bob-power-and-roger-linn.md) | Sampler timing and feel | One stable offset per gesture; no random "humanize" | [D127](../../decisions/music.md#d127-the-chop-beat-mixes-its-pieces-plays-off-the-drums-and-has-a-feel-per-loop-2026-11-2122) |

## Studied with no usable detail

- **9th Wonder and Knxwledge.** No reliable chopping-method detail surfaced. A 9th Wonder NPR exchange frames craft as what you do with a sample rather than which sample you choose ([NPR transcript](https://www.npr.org/transcripts/848488734), a secondary summary). Do not cite either for any parameter.
- **Just Blaze.** Named, with Premier and Pete Rock, only in a boom-bap bass guide for low-passing a loop ([boom bap bass](../bass-and-pads/boombap-bass.md)).
- **4th Disciple, True Master, Daringer, Beat Butcha.** No method detail found ([Griselda producers](griselda.md), [strum hook craft](../lofi-production/strum-hook-craft.md)).

## Not producers, but in the sources

- **Questlove and Dan Charnas** are collaborator and historian sources for [J Dilla](j-dilla.md).
- **Aston "Family Man" Barrett** and reggae bass players are evidence for dub bass, not beatmaking: see [dub bass](../bass-and-pads/dub-bass.md).
- **AJ Hall** is the drummer of Liminal's private drum takes; his timing is preserved, not studied as a producer ([mix engineering](../mix/engineering.md)).

## Adding a producer

Create `producers/<name>.md` in the shape above, add a row here, and link it from the topic note's short summary rather than copying the evidence. Put the general rules (numbers, caps, archetypes) in the topic note and keep only the producer-specific evidence and outcome in the producer file.
