# J Dilla

[← Producers](README.md)

**Who.** Detroit producer (Slum Village, Jay Dee, *Donuts*). Studied for how his groove comes from relationships among timing layers and from selective, deliberate choices, not from one global "off the grid" setting. Studied 2026-11-19 (handoff, dialogue chopping) and 2026-11-22 (strums, bass).

## Signature techniques (as the sources describe them)

- **Deliberate revision and long listening.** In his 2001 interview he discusses sixteenth-note rhythms and spending up to two hours listening to a pattern before deciding what it needs. First-person testimony. It supports patient selection; it gives no quantization setting.
- **Limited sampler memory shaped chopping; imperfection in live playing is valued.** From a reproduced Scratch Q&A (2006) that has transcription problems and whose scan was not inspected, so it carries less weight. It describes a then-current "sampled groove first" process, not a lifelong one.
- **Alternatives kept.** Questlove recalls Dilla retaining many dynamically different kicks, snares and hats from one extended break, and his answer on quantization goes from "no" to "yes and no". T3 of Slum Village recalls selective quantization and whole melodies built from small pieces; Young RJ says Dilla taught him. These are collaborators' memories.
- **Groove among layers.** Dan Charnas describes comparing grids and waveforms: evenly spaced hats can feel swung because the snare is displaced. He also describes evolving freehand programming and slowed samples on *Another Batch*. These are Charnas's research interpretations, not Dilla explaining his settings; the underlying measurements were not inspected.
- **Bass.** Low-passed piano and sax give the low end of "Runnin'" (and of ATCQ's *The Low End Theory*); he is reported to have often played bass on a Minimoog, warm and round. See [boom bap bass](../bass-and-pads/boombap-bass.md). Two further low-end articles returned 403.
- **Influence.** Kaytranada's laid-back placement is tied to Dilla by Rolling Stone ([Kaytranada](kaytranada.md)).

## What Liminal took

- **Preserve the drummer's own timing** and change one dimension at a time (an answer, an accent, a rest, a rate variant) rather than impose "Dilla swing". Bass shares chosen kick attacks, mids answer a backbeat, speech anticipates a gap, and the relationships stay stable within a phrase ([handoff](../dialogue-chopping/handoff.md), "J Dilla").
- **A consistent late placement, never random jitter.** [D127](../../decisions/music.md#d127-the-chop-beat-mixes-its-pieces-plays-off-the-drums-and-has-a-feel-per-loop-2026-11-2122) gives each loop a feel (grid, laid, rush, drunk, ahead) as fixed per-position offsets of at most 25 ms on the "and", "e" and "a". "Laid" is the drag with the "e" latest. The user's direction there was "With swing. Or Dilla style. Playing off the drumbeats." The code comment in `DialogueChopBeat.swift` cites it.
- **Considered and not lifted.** In [D125](../../decisions/music.md#d125-the-motif-becomes-a-hook-one-2-bar-cell-on-fixed-steps-varied-only-at-the-phrase-ends-2026-11-21) the verification pass declined to shift the downbeat signature onto off-beat sixteenths, because that conflicted with "land pieces on downbeats".
- **Strum research input.** A fixed lag of 0 to +30 ms per pattern and a "lagged loose loop" archetype (Dilla or Madlib) are in [strum hook craft §3.1 and §4](../lofi-production/strum-hook-craft.md#31-placement-against-the-drums). The shipped hook ([D128](../../decisions/music.md#d128-strummed-hooks-played-off-the-drums-in-the-guitar-and-harp-phrases-with-one-echo-throw-2026-11-22)) uses its own tuned constants and fewer archetypes.

## Sources

- [Dilla, "Soul Under Control", Datwon Thomas, Platform.net, Feb 2001, preserved by Stones Throw](https://www.stonesthrow.com/news/soul-under-control/). Production passages (lines 79-126).
- [Scratch, "J Dilla Still Lives Through", May/June 2006, reproduced transcription](https://www.sirpierre.se/2013/12/dagens-dilla-j-dilla-still-lives-through-scratch-magazine-mayjune-2006.html). Weaker provenance.
- [Questlove, RBMA Seattle 2005 lecture, host Monk One](https://www.redbullmusicacademy.com/lectures/uestlove-phrenology-of-hip-hop/). Transcript lines 450-461.
- [Red Light Fever: T3 and Young RJ of Slum Village on J Dilla's production, ANTIGRAVITY, June 2014](https://antigravitymagazine.com/column/red-light-fever-t3-young-rj-of-slum-village-on-j-dillas-production/). The author's wabi-sabi framing is not Dilla's stated philosophy.
- [Hip-Hop Still Runs On Dilla Time, Michaelangelo Matos interviews Dan Charnas, Rock and Roll Globe, 9 Aug 2022](https://rockandrollglobe.com/hip-hop/hip-hop-still-runs-on-dilla-time/). Timing Q&A, lines 100-124.
- [The Obscure J Dilla Beat Tape That Changed Music Forever, Dan Charnas, Pitchfork, 9 Feb 2023](https://pitchfork.com/features/article/the-obscure-j-dilla-beat-tape-that-changed-music-forever/). Later historical analysis.
- Bass: [The Low-Pass Theory, Kenyon Review](https://kenyonreview.org/2015/06/the-low-pass-theory-part-1/), [RouteNote](https://create.routenote.com/blog/?p=20624).
