# Bass and pad research (2026-11-20)

Research for reworking two Lo-Fi channels after a listening check of the solo stems (`scripts/solo-stems.py`):

- **Bass.** The user asked for a total rework: "foundational. As important as the drum loop... tight, and punchy. It needs to hit hard, but also carry. It needs effects", with elements of boom bap and dub reggae, and "effects, but not too washed out". The drum takes stay unchanged.
- **Chords.** "More pad-like. It is too sparse. It reads more like a mids based melody... fighting the melody too much. It needs to tuck in there in the middle better... longer, held longer, more reverb", while keeping the mix as tucked as it is now.

The baseline was the approved mix at commit 6679c4d, seed 2077 and 72 BPM, measured at its final-mix level:

| Stem | Loudness while playing | Active |
|---|---|---|
| Drums | -17.4 LUFS | 100% |
| Bass | -17.6 LUFS | 28% |
| Chords | -18.4 LUFS | 21% |
| Melody | -18.2 LUFS | 29% |
| Reverb and echo | -19.5 LUFS | 99% |
| Chops | -21.0 LUFS | 98% |
| Film bed | -24.0 LUFS | 98% |

Four web research passes and one read of the code produced these notes. Each note marks which numbers come from a cited source and which are the researcher's engineering judgement.

| File | What it covers |
|---|---|
| [boombap-bass.md](boombap-bass.md) | Boom bap bass: sources (filtered sample lows, Minimoog, sine, boom bap 808), writing (root, fifth and octave, fewer notes, ghosts, gaps between kicks), kick interaction and sidechain, saturation, bands and compression |
| [dub-bass.md](dub-bass.md) | Dub reggae bass: flatwound Jazz Bass tone, riddim writing with space and repetition, drop-outs, filter sweeps, thrown spring and tape echo with the low end kept dry and mono, what blends with boom bap |
| [pad-chords.md](pad-chords.md) | Pads that sit under a lead: hold and legato revoicing, 3-4 note shells below the lead, swell envelopes, pocket EQ, heavy but controlled reverb, ducking, width, and the frequency checks for mud and masking |
| [bass-sources.md](bass-sources.md) | Redistributable bass samples. CC0 shortlist: Karoryfer Sneakybass (upright: finger, ghost, mute), Swagbass (flatwound electric), Ergo EUB, FreePats Finger Bass YR and Lately Bass. Rejected: non-commercial or EULA licences (Rickenbacker 4001, Pianobook, Spitfire LABS, Ableton, Splice, samplefocus) |
| [code-scout.md](code-scout.md) | How the bass and chord (texture/mids) channels worked before the rework: types, constants, tests, criteria and constraints |
| [bass-tone-diagnosis.md](bass-tone-diagnosis.md) | Stage-by-stage diagnosis of the D116 bass stem ("tinny", "too filtered but not completely"): band shares, the sampled body as the source of everything above 300 Hz, the late noisy upright bloom, choppy notes, chain additions, ruled-out causes (2026-11-20, `$S` is the session scratchpad) |
| [bass-tone-research-audit.md](bass-tone-research-audit.md) | Audit of the D116 bass code against dub and boom bap sources: nine deviations, third-octave targets, sources and gaps (2026-11-20) |

The bass tone was reworked afterwards (D119, plan [bass-tone-redo.md](../../plans/bass-tone-redo.md)) from the two bass-tone files above. The implementation plan built from the first notes is [docs/plans/bass-and-pads.md](../../plans/bass-and-pads.md). In brief:

- **Bass:** a synthesized sub under a sampled CC0 upright or flatwound body. The line is a two-bar riddim cell locked to the kicks, with thump, walk, hold and ghost strokes, drop-outs, filter sweeps and dub throws sent into the reverb and echo stem.
- **Chords:** a held three-voice grain pad below the lead, with one legato revoicing per phrase, a pocket EQ, and reverb feeds that leave out the feedback echo.

Sample files downloaded to inspect these libraries were kept out of the repository.
