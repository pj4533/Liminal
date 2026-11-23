# Liminal: bass and midrange translation research handoff

[← Mix research](README.md)

> **Status (22 November 2026).** This is the research handoff the bass translation work started from, written at revision 5d21cdc and kept as it was (the sections that describe the code describe 5d21cdc, before the strummed hooks of D128). What was measured and built from it, and what shipped, is in [D129](../../decisions/music.md#d129-bass-translation-round-2-clean-cue-partials-and-a-cue-duck-kept-capture-only-2026-11-22); the tooling is the translation report in [mix-verification.md](../../mix-verification.md#translation-report). Nothing in it was heard when it was written, and nothing built from it has been heard either.

**For PJ’s Apple Liminal coding session · 22 November 2026**

The practical objective is to keep an identifiable bass line and a convincing groove on small speakers while retaining real low-frequency weight and warmth on headphones. Preserve Liminal’s warm, spacious, mid-1990s boom-bap character: silence, contrast, film atmosphere, chops, and musical movement matter as much as spectral coverage. This is a mix-translation project. It is not a mandate to make every playback device sound identical or to maximize brightness and loudness.

The recommended sequence is **measure the existing production graph, compare controlled variants of the existing bass controls, relieve specific masking where demonstrated, and revisit master dynamics only if residual evidence points there**. Stereo cancellation, absent reproduced bandwidth, masking, uneven note envelopes, and overloaded dynamics are different problems. A universal EQ/limiter recipe would obscure that distinction.

This document contains the baseline, research interpretation, experiment design, acceptance process, and a copyable coding brief. A supplementary code audit existed outside the repository; it is not needed to use this handoff.

## 1. Scope, revision, and evidence boundaries

The sole implementation target is [pj4533/Liminal](https://github.com/pj4533/Liminal), Apple application main at **`5d21cdc93db1f2c7bb8d494605d0637fba407d27`**, committed **2026-11-22 17:37:52 UTC / 12:37:52 EST**. The research checkout was clean at `/app/state/repos/Liminal-research` after fetching. All implementation links below are pinned to that revision. A coding session must inspect any newer main diff before using these observations.

Current scope is Lo-Fi music with curated institution/NASA API images, macOS and visionOS targets. Earlier documents describing Ambient-only music or Gemini/image generation are historical. Use the current [repository instructions](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/AGENTS.md#L3-L8) and [graph construction](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/GenerativeEngine.swift#L63-L76) as the scope anchor.

Four kinds of statement appear here:

- **Code fact:** traced settings or routing in the pinned source. This establishes what the code expresses, not perceived sound or a successful current build.
- **Published evidence:** a paper, manual, or technical source supports a bounded mechanism. The [source ledger](#11-source-ledger-and-reading-provenance) states exactly what was read and its limits.
- **Inference:** a plausible explanation for a translation issue that still needs captured audio and listening.
- **Proposed starting value or experiment:** our engineering design for comparison, not a published optimum, hearing threshold, or verified improvement.

No audio was heard, no fresh audio render was made, no application build or product test was run, and no playback-device qualification occurred during this research. No current sonic defect is established. Sixteen external sources were successfully read within the boundaries recorded below; one attempted source could not be accessed and supports no conclusion. Manuals describe techniques; they do not establish that Liminal needs them or imply purchasing a plugin.

## 2. The existing graph already addresses several obvious concerns

### Bass generation and processing

**Code facts.** `LofiBassVoice.swift` uses a phase-exact sub architecture split at 160 Hz. Sub amplitude is 0.30; partials 1–4 have relative levels 0, −14, −17, and −21 dB. Normal tone choices rotate every four phrases, or 16 bars, among round/flatwound, upright, and synth, avoiding immediate repetition. Sample bodies are deliberately dark: another 110 Hz high-pass, 360/400 Hz low-pass, and body RMS approximately 13/12.5 dB below the steady sub. Strikes add roughly 80–100 ms of content weighted around 300–650 Hz. The synth option continues to higher partials. This is already a harmonically supported bass, not a bare sine requiring its first overtone. [Voice architecture and constants](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiBassVoice.swift#L5-L173).

The bass chain high-passes at 30 Hz, adds a parallel asymmetric tanh stage with drive 2, bias 0.08, blend 0.15, 2× oversampling, and forward/backward 200–450 Hz filtering. A 4:1 compressor has a 6 dB knee, 25 ms attack, 150 ms release, threshold relative to the phrase reference by −9 dB, and makeup capped at +5 dB. Subsequent tone is +0.5 dB at 80 Hz, −1 dB at 300 Hz, a 24 dB/octave 1.4 kHz low-pass, and −4.45 dB trim. [Bass chain](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiStemChains+Bass.swift#L4-L91).

The renderer sums bass to mono before processing and copies it to the right channel afterward. Kick ducking is split at 150 Hz: full depth in the low band and one-third depth above. Scored bass-anchored kicks are excluded. The onset alignment uses a −6 dB landmark on the 40–160 Hz Hilbert envelope, rather than assuming note-start timestamps represent audible rises. Keep those musical protections when changing spectra or envelopes. [Bass finishing](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiRenderer+Bass.swift#L40-L85), [sidechain implementation](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiSidechains.swift#L54-L151), [onset measurement](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiBassVoice.swift#L180-L231).

**Implication, not diagnosis:** low-frequency stereo width is not an established cause in this dry stem. If the bass changes substantially on mono playback, inspect the full path after that stem, including returns and other material. Bass throws are separate wet contributions; changing the dry chain need not alter them identically. [Throw rendering](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiRenderer+Bass.swift#L14-L38).

### Mids, pad, and returns

**Code facts.** Shell voices pan ±0.15, fold low content to mono below 300 Hz, high-pass at 180 Hz, cut 3 dB at 400 Hz, and low-pass at 7 kHz. The pad uses shared phase and zero detune; its chain already includes mono below 300 Hz, HP300, −3 dB at 380 Hz, −4.5 dB at 2 kHz, and LP2200. Proposing another generic 300 Hz pad high-pass would duplicate an existing decision. [Shell/pad chains](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiStemChains+Mids.swift#L4-L78), [pad voice](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiPadVoice.swift#L8-L57).

Levels are not independent fixed faders. Shells and pad are matched relative to lead, with bounded adjustments, while phrase/program balancing also affects delivered contributions. Instrument a candidate before and after these stages: an apparent improvement or failure may partly reflect compensation by existing gain logic. [Texture level controls](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiRenderer+Texture.swift#L87-L195), [lead/program balance](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiRenderer.swift#L455-L577).

Returns combine several spatial effects and gestures. Existing wet processing includes dynamic tone, HP350/LP4500, a 2 dB cut at 2.5 kHz, onset-sensitive lead ducking up to 5 dB, static trim, carried tails, and additional guards. Archive chops have their own mono dry contribution and filtered echo/room; film follows a separate archive bus before the final master. Do not add internal returns twice when reconstructing a mix, or assume every source enters the same intermediate bus. [FX rack](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiEffects.swift#L7-L172), [wet processing](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiRenderer.swift#L279-L410), [final graph](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/GenerativeEngine.swift#L63-L76).

### Existing master and calibration

**Code facts.** Both intermediate buses enter master at −2 dB. The normal custom finisher adds +4 dB input, making effective input +2 dB relative to the unstaged sum. It includes HP25, glue threshold −12 dB, ratio 1.7, knee 6 dB, attack/release 30/180 ms, detector HP100, 4× soft clipping beginning at −2 dBFS, and a true-peak limiter at −1 dBTP with 0.15 dB margin, 3 ms lookahead, and 80/350 ms release behavior. The fallback uses a different chain with −4.8 dB safety trim. [Master selection and staging](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiMasterBus.swift#L8-L105), [kernel settings](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/DSP/LofiMasterKernel.swift#L7-L63).

Live calibration measures final output, targets −14 LUFS normally and −18 in fallback, observes 64 beats, and ramps gain over 2.5 seconds while considering dynamics load. These are project choices. They are not imposed by a loudness standard. Record which route and calibration state produced every comparison. [Live calibration](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/Liminal/Audio/Lofi/LofiMasterBus.swift#L173-L255).

## 3. What translation means here

“Midrange” means a frequency region. “Mid” in mid/side processing means the common-channel signal. “Mids” in Liminal names a musical role/stem. Those meanings must stay separate in code reviews and reports: reducing a Mids stem is not equivalent to cutting all midrange or altering an M/S Mid channel.

A mono fold cannot restore low-frequency energy that a speaker cannot reproduce. Conversely, removing a fundamental does not necessarily remove perceived pitch: a coherent set of surviving harmonics can still convey note identity. The virtual-bass study in [S1](https://eurasip.org/Proceedings/Eusipco/Eusipco2024/pdfs/0000046.pdf) supports treating bass intensity and overall quality as separate outcomes, with evidence bounded to its stimuli and headphone listening. It does not prove a phone result for Liminal.

For a concrete design illustration, a 55 Hz note has harmonics at 110, 165, 220, and 275 Hz. If a restricted path weakens 55 Hz, some upper components may still identify the note. Preserve their harmonic relationship, timing, and note envelope. An octave layer alone can become a separately perceived higher pitch; its presence is not proof that the original line retains its musical weight. The experiment should ask whether listeners follow the intended notes and rhythm, and whether headphones still deliver convincing depth.

Do not assume all phones are mono or share one cutoff frequency. The relevant playback path includes speaker arrangement, orientation, operating-system processing, volume, and device behavior. A linear high-pass/low-pass stress filter isolates bandwidth as a variable; it is not a validated phone model. Klippel’s [listening-test explanation, S7](https://klippel.de/listeningtest/?page=how_it_works) supports the distinction between level-dependent transducer distortion and a simple linear response, without establishing music preference.

Optional width belongs above an intelligible core and must survive the actual mono test. Do not add delay-based widening or detuning to essential bass merely to make the stereo demonstration larger. A spacious upper arrangement can coexist with a centered bass. FabFilter’s [stereo-processing documentation, S8](https://www.fabfilter.com/help/pro-q/using/stereo) describes independent channel/M/S operations; that capability alone guarantees neither compatibility nor audibility.

The project should preserve two distinct experiences: physical low-end contribution where playback supports it, and recognizable bass phrasing where it does not. Deleting real low end from the universal mix to win a phone audition would sacrifice the first experience. The [MaxxBass guide, S3](https://assets.wavescdn.com/pdf/plugins/maxxbass-v16-update.pdf) describes independent original/harmonic controls and a workflow for a particular small-speaker replacement task; use that distinction to clarify objectives, not as a universal mastering prescription.

## 4. Diagnose the failure mode before changing DSP

Use the same production excerpt and aligned stems in the following comparison matrix. Keep an untouched PCM reference and use explicit arithmetic mono `(L + R) / 2`; log any other downmix law separately. Loudness matching for listening should be a separate documented step, so raw losses remain measurable.

| Comparison | What an adverse result would suggest | Next investigation |
|---|---|---|
| Full-range stereo versus arithmetic mono | A component loses contribution through folding | Inspect polarity, phase relationships, and stereo returns at that event |
| Full-range mono versus restricted-band mono | Important identity depends on removed bandwidth | Inspect existing source/parallel harmonics and their sustained envelope |
| Bass solo versus bass in the same full mix | Competing material hides a usable bass cue | Identify the specific shell, pad, chop, film, or return window |
| Dry contribution versus delivered wet/full mix | Spatial path alters clarity or apparent envelope | Trace sends, returns, filters, and tail overlap |
| Quiet/normal versus moderately loud device playback | Playback or mix dynamics change with level | Separate bus overload from device nonlinear behavior |
| Headphones with acceptable translation but wrong weight | Universal tonal balance may be wrong | Adjust source level/EQ before adding enhancement |

These are diagnostic hypotheses, not automatic verdicts. More than one may occur. A mono loss in a return and insufficient harmonic audibility can coexist, requiring different fixes. A correlation meter helps locate relationships but cannot establish whether a bass note is heard or whether its timbre is desirable.

Start with a short excerpt containing a held bass note and a busy midrange passage, then repeat on sparse material. If a harmonic change only helps in solo, it has not solved mix translation. If a master change only makes a phone louder, repeat with matched route level before interpreting it. If stereo and mono both fail similarly after band restriction, a width repair is unlikely to address the central symptom.

At each stage ask which signal was measured. The bass stem is dual mono, but the final mix contains spatial returns and unrelated low-mid material. Full-mix M/S energy does not identify bass behavior by itself. Capture source, post-chain bass, post-phrase contribution, relevant wet components, and final output so the investigation can trace the first point at which the cue becomes unusable.

## 5. Prioritized musical experiments

Everything in this section is a proposed design. Numerical trial values are hypotheses, not sourced defaults or recommended final constants. Run one controlled change at a time before combining winners.

### First: extend capture and audition instrumentation

Reuse the existing production capture graph rather than building a convenient alternate synthesizer. Add labelled mono, restricted-band, and combined auditions to the existing analysis workflow, with the transforms recorded in output metadata. Keep these diagnostic files separate from raw captured stems. Include time-aligned comparisons so a listener can repeat the same two bars without searching.

Make the baseline reproducible before hearing candidates. Save a configuration manifest and record the normal/fallback master route. Freeze or explicitly log calibration during controlled comparisons, then separately test settled live calibration. Otherwise, a candidate’s extra harmonic energy may alter the gain trajectory and confound the apparent timbre change.

### Second: vary the existing bass harmonic spectrum and envelope

Keep an identical clean sub across first-round variants. Compare the existing 200–450 Hz parallel band against exploratory 180–700 Hz and 250–900 Hz versions. Choose notes and harmonic distributions deliberately: these bands interact differently with a low 55 Hz note and a higher-register note. Existing blend 0.15 is the baseline; introduce one conservative alternate blend only after a same-blend bandwidth comparison. Do not equate a “drive” number across different nonlinear formulas.

Compare sustained harmonic support with onset-only support. An attack may identify rhythm while a long note disappears afterward; sustained enhancement may solve that or create fatigue and masking. Report attack and sustain separately. Preserve low-band rise placement and compare kick interaction, not just a static spectrum. Every normal bass tone must participate because its body and strike content differ and rotates at 16-bar boundaries.

Consider the generator’s existing partial controls before asking stronger distortion to do all the work. Directly shaping upper partials could provide a cleaner, more predictable cue at lower processing cost; that is an inference to benchmark, not a claim about the current winner. If needed, compare generator shaping and parallel saturation with equal clean sub and matched delivered loudness. A body low-pass adjustment is another candidate, not an automatic “open it up” instruction.

Reject any result that wins mainly by added level, makes the bass sound like a separate octave instrument, or erases tone identity. Keep the headphone version warm and grounded. An 80 Hz boost alone cannot establish success in a path that removes that region, and can change kick/master loading. Do not begin with a global low shelf when the question concerns a particular note cue.

### Third: make room in the actual competing source

Use event-level evidence to identify masking rather than scooping the whole mix. First consider voicing, register, sustain, arrangement density, and overlap. A held shell release may occupy the exact moment a bass sustain needs recognition. A quieter or shorter competing tail can preserve warmth more naturally than a broad permanent cut.

Then compare modest static versus frequency-selective dynamic reduction in the competing shell, pad, or wet return. The illustrative area of interest is the bass cue actually measured, potentially within 200–900 Hz, not a mandatory fixed band. The 200–500 Hz region contains both warmth and useful bass overtones; blanket removal can damage both. Lead and chops also need intelligibility across this territory and into 1–4 kHz. Evaluate the whole phrase, including speech clarity and the perceived body of the ensemble.

A detector and an affected EQ band are separate design choices; [Pro-Q dynamic EQ documentation, S9](https://www.fabfilter.com/help/pro-q/using/dynamic-eq) describes that distinction and external-sidechain operation. Applying the concept here means specifying which event controls which source, with what maximum reduction and recovery. It does not mean installing that product or assuming a published setting transfers.

Do not solve every collision with more broadband bass ducking. Preserve current anchored-kick exclusions and split low/high duck depths. If changing harmonic onset content, verify the measured low-band alignment still represents musical coincidence. A clearer bass can expose an overly weak kick, so listen for independence and combined groove rather than optimizing bass in isolation.

### Fourth: inspect wet-only masking without flattening the space

Keep a stable dry core. Existing lead-onset wet ducking already makes room; inspect it before adding another detector. Is a specific return sustaining over bass recognition, or is the apparent issue the pad’s own body? Measure and audition those alternatives independently.

Filtering an effect input changes what excites the effect. Filtering its wet output shapes the result. Filtering inside a feedback loop changes repeated spectral evolution and can affect stability. They are not interchangeable edits. Where evidence supports a return correction, choose the narrowest relevant location and preserve tail continuity at phrase transitions. A global high-pass on all ambience is not a substitute for understanding topology.

The [Ableton reference sections read, S13](https://www.ableton.com/en/manual/live-audio-effect-reference/) provide examples of detector filtering, wet/reverb tone controls, saturation quality, and separate mono/width tools. They support these concepts, not a guaranteed Liminal outcome. Any feedback-path experiment needs a bounded stability/tail test at extreme allowed settings as well as a normal musical audition.

### Fifth: revisit dynamics only if the remaining symptom requires it

A limiter controls peaks and density; it does not generate a missing harmonic identity by itself. Determine whether the bass problem is uneven attack, weak sustain, or occasional overload, then inspect existing bass compression before editing it. A release that modulates within low-frequency cycles can change waveform behavior. At 55 Hz a cycle is about 18.18 ms, but that arithmetic is not a universal release-time rule.

Attack, lookahead, release, and stereo-link behavior trade transient shape against gain control; [Pro-L advanced documentation, S11](https://www.fabfilter.com/help/pro-l/using/advancedsettings) explains those controls and aggressive-limiting considerations. Use it to frame tests, not to substitute another master. Keep the current −1 dBTP ceiling and fallback safety behavior unless a separately justified dynamics task changes them.

True peak concerns reconstructed intersample excursions, which differ from sample peaks; [Pro-L true-peak documentation, S12](https://www.fabfilter.com/help/pro-l/using/truepeaklimiting) describes that distinction and oversampling-related tradeoffs. Measure the actual final output. Test a coded/exported path only if the application actually provides that path; do not invent a codec requirement or claim one ceiling guarantees all downstream encoders.

## 6. DSP engineering constraints for the coding session

The following are proposed implementation guardrails. The current phrase renderer and realtime master have different contracts. Forward/backward filtering uses future samples and is suitable to an offline buffer; it cannot be copied directly into a live callback. A live equivalent needs its own causal design and latency accounting. Keep filter coefficients sample-rate dependent and compare behavior at supported runtime rates.

For parallel paths, align latency and verify bypass unity before interpreting an EQ or saturation result. Different phase responses can change recombination. Linear phase is not automatically a higher-quality choice: [Pro-Q processing-mode documentation, S10](https://www.fabfilter.com/help/pro-q/using/processingmode) explains relative-phase, latency, and pre-ringing tradeoffs. The appropriate mode depends on the path and musical event.

The existing 2× bass oversampling is neither automatically adequate nor automatically defective. Test the actual nonlinearity with sweeps and musical material, comparing alias products, passband response, latency, and cost against a higher-rate candidate. Nonlinear waveshaping can create above-Nyquist harmonics that alias; [Parker, Zavalishin, and Le Bivic, S2](https://www.dafx.de/paper-archive/2016/dafxpapers/20-DAFx-16_paper_41-PN.pdf) develops continuous-time/antiderivative mitigation with tradeoffs. It does not establish a universally sufficient oversampling factor.

Antiderivative antialiasing is an optional future investigation, not a prerequisite for this project. If explored, account for its delay/filtering, numerically sensitive near-equal sample cases, and interaction with oversampling. Do not adopt a complex new nonlinear architecture before the simpler existing partial controls and band/envelope changes have been compared.

A biased saturation curve also warrants a DC check on rendered signals. Subtracting the curve’s value at zero does not guarantee zero mean for every input distribution. Test silence, asymmetric waveforms, decays, and extreme allowed amplitudes for finite output, DC, and denormal behavior. Verify that bypass, transitions, and carried tails do not click. Apply gain smoothing where controls change.

If width is later adjusted in an appropriate stereo path, the explanatory transform is `M=(L+R)/2`, `S=(L−R)/2`, then `L′=M+S′`, `R′=M−S′`. Filtering Side may require matching delay in Mid. Removing Side cannot recover a signal already cancelled in Mid. Test crossover phase, bypass gain, and mono reconstruction. This is an optional reasoning aid for stereo returns, not a request to add another width stage to the already mono bass stem.

Keep render configuration immutable for a fixture and save it with results. Realtime work must remain bounded: preallocate, avoid locks/allocations/network operations in callbacks, and keep analysis outside the audio thread. Benchmark any extra oversampling or detectors under the actual master/render scheduling model. An offline render passing numerical checks does not demonstrate glitch-free realtime playback.

## 7. Reproducible measurements and listening

### Fixture coverage and provenance

Use deterministic seeds with all bass tones, low and high register, short and held notes, velocity variation, anchored and unanchored kicks, sparse and dense mids, real sample/chop/drum content, and low/high wet settings. Include silence and decaying tails, phrase joins, and 16-bar tone changes. After short controlled fixtures, run 30–60 minutes of generation to catch cumulative or transition-dependent behavior. This longer duration is a proposed qualification task, not something performed here.

For every render save source SHA, seed, program, bass tone, exact configuration, runtime master route, fallback status, sample rate, active normalization/calibration, and start/end times. Save aligned PCM stems and final output. Include source and processing-stage taps where needed, with a routing manifest so internal returns are neither omitted nor double-counted. Record whether sample/film assets were present and the exact material identity or authorized local identifier.

Reuse [mix-verification prerequisites and tools](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/docs/mix-verification.md#L8-L47). Capture requires macOS/Xcode, FFmpeg, Python scientific packages, and relevant private drums/cached film assets. The existing matrix covers reference 70 BPM/32 bars, long 62/64, fast 80/32, repeated-film 70/64, and no-film 70/16. These are starting coverage, not a complete translation qualification. [Matrix definition](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/scripts/mix-matrix.sh#L51-L60).

### Metrics that reveal mechanisms

Report sample peak, true peak, integrated loudness, 3-second loudness, crest, and per-band RMS. Proposed diagnostic bands are 20–80, 80–160, 160–400, 400–900, and 900–2000 Hz. Report exact filter design, order, phase, edge handling, and measurement windows; two scripts using the same band names need not measure identically.

Capture gain-reduction distributions and timestamps, not just a maximum. Align these with note attacks, sustain, kick events, and perceived problems. Measure harmonic/attack/sustain audibility proxies for known bass notes, clearly labelling them as proxies rather than quality scores. A spectrum containing 220 Hz does not prove the listener recognizes the 55 Hz bass line in a busy arrangement.

For event-window mono loss, calculate:

```text
Pstereo = (mean(L²) + mean(R²)) / 2
Pmono   = mean(((L + R) / 2)²)
mono_energy_change_dB = 10 log10(Pmono / Pstereo)
```

Use the same filters and windows for both energies and gate silence/near-silence before taking ratios. Equal centered channels give 0 dB. Equal-power uncorrelated channels give approximately −3.01 dB over a suitable window. Opposite-polarity equal channels cancel. Consequently, −3 dB is not a universal failure threshold. Report event context and frequency band. Diffuse tails can decorrelate by design while the dry musical core remains stable.

The direct dry bass should permit an L/R null test within a stated floating-point tolerance because the renderer copies mono to both channels. That expected identity does not apply to the final mix or separate wet throws. Add M/S band energy as a location aid, and inspect individual events rather than relying on a whole-file average.

The existing C-M10 gate uses low-band/full correlations and a mono-loss criterion; C-B3 bass-balance checks are warnings, while other criteria cover loudness, peaks, dynamics, and balance. These are project thresholds, not perceptual laws. Preserve them initially and document any proposed change. [Criteria](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/scripts/mix-criteria.json#L5-L45), [low-end analysis](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/scripts/mixlib/lowend.py#L11-L26).

### Stress filters and real devices

Proposed stress auditions use high-pass examples at 120, 180, and 250 Hz, plus a 6–8 kHz low-pass. Label them by the exact transform, never by a phone model name. Their job is to reveal dependence on spectral regions. If measured device impulse responses become available, they improve a linear model but still do not guarantee reproduction of level-dependent processing or distortion.

Actual listening should include available phone speakers, laptop/tablet speakers, inexpensive earbuds, quality headphones, and desktop speakers. Record device model, OS, volume, route, active DSP, and listening conditions. Where relevant compare portrait/landscape and the device mono setting on/off. Use quiet, normal, and moderately loud route levels; avoid assuming one slider position produces equivalent acoustic level across devices.

Rate note recognition, rhythm recognition, apparent weight, mud, harshness, kick independence, speech clarity, stereo space, and preference separately. A candidate can improve note recognition while damaging warmth or speech. Blind randomized volume-matched A/B with repeated excerpts is the proposed acceptance method. Include authorized genre references for aesthetic orientation; do not turn reference matching into an automatic spectral target.

For listening matches apply documented linear gain after a candidate. Do not peak-normalize: that can confound transient differences with loudness. Keep raw dynamics files for measurement. Existing audition generation targets −16 LUFS and may add limiting, so those clips cannot be the source of truth for raw peak or compressor behavior. [Audition implementation](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/scripts/mixlib/auditions.py#L1-L26).

## 8. Existing commands and proposed acceptance stages

The commands below are documented existing entry points, not claims that they were run. Run them from the Apple checkout on the required Mac after reading the pinned [mix-verification guide](https://github.com/pj4533/Liminal/blob/5d21cdc93db1f2c7bb8d494605d0637fba407d27/docs/mix-verification.md). Paths must be writable and outside the repository. Private assets and cached film are prerequisites for the corresponding options. Use a separate derived-data directory and respect the capture lock.

```sh
S=/private/tmp/liminal-translation-session
mkdir -p "$S"
DD="$S/dd" scripts/mix-report.sh --out "$S/ref" --private-drums --film-reel --bars 32 --seed 1042 --bpm 70
python3 scripts/mix-report.py "$S/ref" --auditions
python3 scripts/mix-report.py --self-test
```

The first command is a fresh reference capture/report. The second analyses that capture and generates listening files, with the audition-processing caveat above. The third checks synthetic measurement/criterion behavior. For a complete established matrix, choose a fresh output directory and a real existing baseline directory:

```sh
DD="$S/dd" scripts/mix-matrix.sh --out "$S/matrix" --baseline "$S/baseline" --strict
```

Do not treat this as a ready-to-run before/after command until the baseline exists. Use documented `bassTone` hooks and inspection of their current contract for tone-specific fixtures; this handoff deliberately does not invent an unverified hook invocation. Additional translation transforms and note-aligned reports are proposed tooling tasks, not existing CLI flags.

Acceptance proceeds in stages. First require routing reconstruction, deterministic fixture identity, correct mono arithmetic, and stable silence handling. Validate measurement changes with synthetic cases and the existing self-test. The EBU [test-set landing page, S15](https://tech.ebu.ch/publications/ebu_loudness_test_set) offers a further meter-validation resource; its archive was not downloaded or executed here.

Next require no unexplained regression in existing project gates, finite output, headroom, timing, fallback behavior, or tail continuity. Define fixture-specific numerical tolerances before evaluating candidates. Any new bound for “meaningful core mono loss” is provisional until tied to a known core event and listening; do not present a chosen dB number as an international standard.

Then require the musical comparison to improve a named outcome without unacceptable losses elsewhere. Preserve clean-sub contribution in the initial harmonic trials and document whether final weight remains acceptable on headphones. Finally test realtime playback with settled calibration and actual devices, including longer generation. Product tests and proxy metrics can reject defects; they cannot establish a listener’s preference or the desired groove.

The [EBU loudness overview, S14](https://tech.ebu.ch/loudness) distinguishes momentary, short-term, and integrated measurements and places −23 LUFS in broadcast context. It does not make that value an app target. The current −14 LUFS calibration should stay a controlled project variable until evidence justifies revisiting it. The [ITU BS.1770-5 metadata, S16](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en) identifies the applicable recommendation version; no unread algorithm text is relied upon here.

## 9. Coding tickets, order, and rollback

**Ticket 1 — baseline instrumentation.** Extend existing capture/reporting with explicit stereo, arithmetic mono, restricted-band, and combined auditions; aligned event windows; harmonic attack/sustain proxies; and a complete render manifest. Add meaningful synthetic checks for transform math and failure detection. Deliver raw baseline files, report, and listening clips with processing clearly distinguished. No sonic change is required to complete this ticket.

**Ticket 2 — controlled bass variants.** Add a bounded, reproducible render configuration around existing partial/enhancement controls. Preserve baseline as the default. Compare the proposed harmonic bands and envelope variants with identical sub, fixed seed/material, and measured level compensation. Include all normal tones and boundaries. Deliver an option table showing what changed, what did not, calibration conditions, measured outcomes, and blind listening results or an explicit “listening pending.”

**Ticket 3 — targeted mid/wet space.** Proceed only when a captured event identifies competition. Choose a source/envelope correction first, then a modest static or dynamic spectral candidate if needed. Retain the existing pad high-pass, lead-onset wet behavior, bass/kick alignment protections, and tail carry unless that specific behavior is under test. Deliver evidence that lead/chop clarity and warmth survive.

**Ticket 4 — master integration, conditional.** Open only if residual dynamics evidence remains after source and masking work. Inspect existing bass compressor and custom master; keep one coherent master path. Compare final true peak, gain-reduction timing, live calibration, and fallback. Avoid combining this ticket with the first harmonic experiment, because simultaneous gain architecture changes would make attribution difficult.

**Ticket 5 — listening qualification.** Run actual-device sessions with blind matched excerpts, record the device matrix and separate ratings, then test settled live playback and long generation. State explicitly which devices and excerpts were unavailable. The deliverable is a measured comparison plus audio artifacts, not a claim that “tests prove it sounds better.”

Use explicit profile/config toggles for experiments and a one-step return to baseline behavior. Save configuration with captures and keep speculative constants out of the unconditional default until accepted. Roll back a candidate that improves a stress filter but loses headphone depth, increases harshness, weakens kick independence, obscures speech, destabilizes tails, or violates headroom/performance constraints. Those are proposed project acceptance decisions, not universal rules of mixing.

## 10. Copyable brief for the next coding session

> Work only in Apple `pj4533/Liminal`. Research baseline is main `5d21cdc93db1f2c7bb8d494605d0637fba407d27` from 2026-11-22 17:37:52 UTC. Read current repository instructions and `docs/mix-verification.md`; inspect every newer diff before relying on this snapshot. Current music is Lo-Fi with curated API imagery. Treat older architectural descriptions as historical when they disagree with source.
>
> Objective: retain warm, spacious mid-1990s boom-bap while making the bass line/rhythm identifiable on small speakers and keeping real depth on headphones. First reproduce and instrument the existing production graph. Separate stereo cancellation, restricted bandwidth, masking, note-envelope/level variation, and overload. Existing bass is already dual mono with partials, saturation, compression, split kick duck, and a protected custom master. Measure before adding processing.
>
> Deliver baseline captures and labelled mono/bandwidth auditions, then controlled variants of existing bass harmonic spectrum/envelope with identical clean sub. Use all bass tones and relevant low/high note fixtures. Treat 180–700 and 250–900 Hz bands as exploratory alternatives to existing 200–450, not proven defaults. Record phrase/program compensation and freeze/log calibration for controlled comparison. Never blindly transplant constants.
>
> If evidence identifies masking, correct the specific competing source or wet path while preserving warmth, dry core, tail continuity, anchored-kick exclusions, onset alignment, and lead/chop intelligibility. Revisit existing dynamics only for a demonstrated remaining problem. Preserve true-peak headroom, fallback, and realtime constraints.
>
> Run relevant existing tests, measurement self-tests, matrix and distortion checks on the Mac with required assets. Keep captures outside the repository. Provide source/config manifests, aligned PCM, raw metrics, matched listening clips, known limitations, rollback, and actual-device A/B results where available. Do not claim live sonic improvement from code inspection, a successful build, or proxy tests alone.

## 11. Source ledger and reading provenance

This ledger distinguishes substantive reading from metadata and access failure. Research reading was completed by the source-review lane; the handoff synthesizes its bounded findings. No linked audio demonstration was heard and no tutorial video was watched. Repeated citations refer to the same source, not additional independent evidence. No vendor numeric recipe is adopted as a validated Liminal setting.

| ID | Source and type | Reading boundary | What it supports and what it cannot establish |
|---|---|---|---|
| S1 | Gou, Song, Shi, Li, [“Self-Supervised Mean Opinion Score Prediction of Phase-Vocoder-Based Virtual Bass System,” EUSIPCO 2024](https://eurasip.org/Proceedings/Eusipco/Eusipco2024/pdfs/0000046.pdf), research paper | All five pages, printed 46–50, visually read | Eight clips (four violin, four vocal/drum), five harmonic-attenuation settings, 21 listeners aged 22–33, adjustable headphone level. Bass intensity and overall quality are distinct outcomes. No actual mobile-speaker trial; nonlinear-device behavior excluded. Prediction scope is narrow and does not replace listening. |
| S2 | Parker, Zavalishin, Le Bivic, [“Reducing the Aliasing of Nonlinear Waveshaping Using Continuous-Time Convolution,” DAFx 2016](https://www.dafx.de/paper-archive/2016/dafxpapers/20-DAFx-16_paper_41-PN.pdf), research paper | All eight pages, printed 137–144, visually read | Explains aliasing and an antiderivative-style mitigation with oversampling and implementation tradeoffs. Not evidence for one sufficient factor or a required replacement of Liminal’s saturator. |
| S3 | [Waves MaxxBass User Guide v16](https://assets.wavescdn.com/pdf/plugins/maxxbass-v16-update.pdf), vendor manual | Printed pages 3–11 of 13 total, visually read | Original/harmonics controls, peak changes, multi-speaker checking, and a device-specific replacement workflow. Promotional extension claims are not independently validated here. |
| S4 | Nick Messitte, [“How to EQ bass to sit well in a mix,” July 24, 2025](https://www.izotope.com/community/blog/how-to-eq-bass), vendor educational article | Complete substantive text | Contextual role, kick/harmonic competition, dynamic EQ, harmonic audibility, and mono checking. Subjective guidance rather than a controlled experiment or transferable constants. |
| S5 | Ian Stewart, [“Mastering low end: essential processing tips and tools,” September 2, 2025](https://www.izotope.com/community/blog/mastering-low-end), vendor educational article | Complete substantive text | Room/headphone differences, harmonic support, and meters used with listening. No objective target curve or proof of this app’s needs. |
| S6 | Team iZotope, [“5 Ways to Boost Bass in a Mix,” July 1, 2019](https://www.izotope.com/community/blog/5-ways-to-boost-bass-in-a-mix), vendor educational article | Complete substantive text | Musical role, risks of excessive high-passing, transient/sustain distinctions, and upper-width mono checks. Older product examples; no universal localization boundary is adopted. |
| S7 | [Klippel, “Listening Test—How it works”](https://klippel.de/listeningtest/?page=how_it_works), technical test explanation | Complete page; linked paper/audio not read or performed | Level-dependent transducer nonlinearity. Its distortion-detection task does not measure preference for a generated mix. |
| S8 | [FabFilter Pro-Q 4, Stereo options](https://www.fabfilter.com/help/pro-q/using/stereo), product help | Complete help page | Channel/M/S processing semantics. No blanket guarantee for mono bass or a successful Liminal patch. |
| S9 | [FabFilter Pro-Q 4, Dynamic EQ](https://www.fabfilter.com/help/pro-q/using/dynamic-eq), product help | Complete help page | Detector versus affected band, adaptive gain, external-sidechain concepts. No proof a particular band or amount is needed. |
| S10 | [FabFilter Pro-Q 4, Processing mode](https://www.fabfilter.com/help/pro-q/using/processingmode), product help | Complete help page; tutorial video not viewed | Relative phase, linear-phase latency, and pre-ringing tradeoffs. No universally superior mode. |
| S11 | [FabFilter Pro-L 2, Advanced settings](https://www.fabfilter.com/help/pro-l/using/advancedsettings), product help | Complete help page | Dynamics-control and channel-link compromises, including aggressive-limiting aliasing considerations. Not a proposed replacement chain. |
| S12 | [FabFilter Pro-L 2, True peak limiting](https://www.fabfilter.com/help/pro-l/using/truepeaklimiting), product help | Complete help page | Reconstructed versus sample peaks, metering/limiting distinctions and oversampling costs. No universal ceiling or codec guarantee. |
| S13 | [Ableton Live 12 Audio Effect Reference](https://www.ableton.com/en/manual/live-audio-effect-reference/), product manual | Only complete sections 29.9 Compressor, 29.32 Reverb, 29.34 Saturator, 29.40 Utility | Concept examples for detector filtering, wet tone/decay, saturation quality, and separate mono/width operations. Other sections were not read. |
| S14 | [EBU Loudness](https://tech.ebu.ch/loudness), standards overview | Complete overview; linked standards not read | Momentary 400 ms, short-term 3 s, and integrated terminology; −23 broadcast context. Not an app loudness mandate. |
| S15 | [EBU Loudness test set, March 30, 2016](https://tech.ebu.ch/publications/ebu_loudness_test_set), validation-resource landing page | Complete landing page only; archive not downloaded/tested | Describes 70 files, version 5.0, primarily meter compliance. It does not validate musical quality or our implementation. |
| S16 | [ITU-R BS.1770-5, November 2023](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en), standard metadata | Complete landing metadata only | Identifies recommendation/version, approval November 22, 2023, and in-force status. Full algorithm text was not read and is not attributed here. |
| S17 | [AES loudness project resource](https://aes.org/resources/audio-topics/loudness-project/learn-more/), attempted access | Research access returned 403; separate access attempts timed out | No substantive content read. Not counted among successful sources or used as evidence. |

S4–S6 provide contextual support for source-aware treatment and listening-led low-end decisions; the detailed fixture design, candidate bands, workflow, tickets, and acceptance process above are our proposed synthesis. Their value must be established in Liminal’s production graph and actual listening conditions.
