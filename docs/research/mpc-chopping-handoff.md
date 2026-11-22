# Liminal dialogue chopping and mix handoff

19 November 2026 · Research and implementation plan for a separate Liminal coding session

## Brief and first change

Make arbitrary incoming footage dialogue become a recognizable, intelligible rhythmic performance inside the existing lo-fi beat. Prepare the source as a producer would prepare useful samples: find a compelling phrase, retain its context, make a small bank of related cuts, play that bank against the drummer, keep a successful pattern, and vary it with purpose. Preserve the continuous film soundtrack as an audible background. Strengthen bass impact, mid responses and recognition of the theme's return without filling every gap.

**Implement an acoustic phrase hierarchy, stable virtual pad bank and bounded performance grammar first.** Add optional local transcription to refine words and admit conservative phrase reordering after this musical foundation works. This first increment uses the current sampler and scheduling path; it does not require a new synthesizer, cloud inference, handpicked production dialogue or a new style control.

The implementation baseline is **`pj4533/Liminal` at `a290f8377c208c9b50725fdcb9c104bc23f4e1bc`**, audited on 19 November after the 18 November evening changes. [Pinned repository](https://github.com/pj4533/Liminal/tree/a290f8377c208c9b50725fdcb9c104bc23f4e1bc). The 18 November handoff remains historical context; its older code baseline and missing-feature inventory do not describe this commit. Rebase the proposed changes onto later code if the coding session starts elsewhere.

This is a standalone research handoff, not an implemented feature. The evidence covers 21 craft/history source groups and 14 technical source families, with different pages from one guide grouped together. Producer interviews, collaborator memories, later analysis and manufacturer procedures have different authority; the appendix distinguishes them. No source audio was listened to, no Apple build or device/model benchmark was run, and no output quality threshold was achieved. PJ's listening feedback supplies the reported problems. Numerical starting bounds below are hypotheses to qualify, not producer rules or proven optima.

## Feedback translated into work

| PJ's feedback | Response in the current engine | Evidence of success |
|---|---|---|
| Film background is too low and washed out | Rebalance bed dry gain, stacked filtering and wet balance; preserve its separate bus and existing Footage control | Film remains identifiable between chops and does not dominate speech or music at matched playback level |
| Theme/variation/breakdown/return is hard to hear | Keep motif memory and 32-bar form; restore a recognizable lead presentation and space for opening return notes | Listeners recognize the returning idea without seeing section labels |
| Mids need presence, variation and interaction | Raise and articulate the active recorded shell path; choose responses from melody rests/cadences | Mids answer/support melody rather than obscure or duplicate it |
| Bass needs punch and tone variation | Compare bounded attack/body/release voices, kick attack alignment and headroom before raising level | Stronger perceived impact with controlled low-band overlap and no extra masking |
| Accompaniment should follow AJ Hall | Derive confident landmarks and a sparse shared timing field from the full take | Selected accents connect; pickups, gaps and the original drummer survive |
| Dialogue must act like manually chopped samples | Source-derived hierarchy → stable bank → constrained, seeded phrase performance | Recognizable anchor, intelligible transformation, silence and return on unseen footage |
| Cheap/local transcription may help | Qualify one local backend; retain acoustic fallback for unavailable models, permission, locale, confidence or deadline | Offline inference where supported, no silent server fallback, no interruption to bed/music |

## Current implementation and the specific improvement

The central task is to develop features already underway. The current mechanisms below are code findings at the pin. Perceived gaps are PJ's listening observations; possible causes and detector limitations are hypotheses until measured. Preserve the working mechanism while improving how clearly its musical purpose reaches the listener.

| Area | Already implemented | Perceived gap or code hypothesis | Exact extension | Preserve and verify |
|---|---|---|---|---|
| Dialogue selection | Three-band envelopes propose syllabic gestures and longer lines; SoundAnalysis weights speech/music/singing | PJ hears samples but wants a more intentional manual-chopping performance; envelopes do not identify words | Retain hierarchy/adjacency, rank complete phrases and build a stable bank from each actual incoming clip | Preserve acoustic fallback; reconstruct source order and compare against current sampler |
| Dialogue arrangement | Fragment pickups can lead into an intact quote | PJ wants meaningful out-of-order phrases, varied beat placements and recognizable musical development | Add a few constrained pattern families, stable repeats, explicit rests and returns; enable safe reorder only with suitable transcript evidence | Preserve full-line gesture as anchor; test intelligibility, recognition and occupancy |
| Dialogue time/rate | Existing decode/rate conversion and scheduled chop buffers | A rate change is not independent pitch-preserving fitting; source/cue clocks need explicit mapping for ASR | Compare native and linked-rate candidates, retain source-to-output maps, fit selected stress anchors | Preserve sample-time scheduling; test accent position and time-domain conversions |
| Film bed | Separate continuous audio, normalization/trim/filter chain, and 1.76×/1.31× context boosts | PJ still cannot hear it clearly and finds it washed out; cause could include dry attenuation and stacked filters | Audit dry/wet and bandwidth at a fixed control value, lift useful direct presence, maintain bounded dips under featured lines | Preserve control, zero/silence behavior and separate role; listen in combined mix |
| Film readiness | Cue tokens, detached decode and visibility/catch-up checks | Current chop preparation precedes bed posting; adding ASR there could worsen readiness | Publish bed independently and attach optional plans at a later valid boundary | Preserve token checks; timeout/cancel ASR and verify bed still starts |
| Theme/form | Original motif memory, exact theme/return note relationships and 32-bar form | PJ likes melodies but cannot clearly hear the formal return | Retain reference attack/register/timbre, expose first return notes and clear competing tails | Preserve generator and instrument breadth; test listener recognition, not just event equality |
| Mids | Two-note rolled shells with bounded entrances; active path is recorded instruments | PJ wants louder, more varied responses to melody | Adjust sampled-shell presence/articulation; select stab/answer/rolled variants from melody gaps/cadences | Preserve two-note voice leading; compare active renders, not synth-fallback-only edits |
| Bass tone | Fundamental plus harmonics, tanh drive and existing amplitude envelope | PJ wants stronger impact and timbral variety; a pure-sine diagnosis would be incorrect | Shape attack/body/release and a small palette with stable tuned sustain, then assess optional recordings | Preserve existing voice as comparison; equal-level listening, mono sum and limiter diagnostics |
| Bass timing | Nearby-kick replacement within 0.075 beats and subsequent pocket offset | PJ wants more convincing shared human interaction; current local snapping is narrower than that goal | Qualify attack landmarks, align selected accents and share sparse timing relationships with other roles | Preserve AJ's full audio and nonaligned pickups; measure labeled onsets and audible impact |
| Drum detection | Low-band novelty, relative threshold and suppression; no hit reconstruction | Quiet/fill events may be missed or merged; this is a testable hypothesis, not a reported measurement | Add multiband/adaptive metadata, confidence and onset-vs-peak distinction; escalate only after failures | Preserve full takes; compare hand annotations and whole-take listening |
| Mix/headroom | Final dynamics/safety chain and bounded bass ducking | More level on every layer could spend headroom instead of clarifying the requested parts | Export buses, meter combined output, use arrangement and bounded ducking around featured events | Preserve safety processing; compare perceived level, peaks, crest and gain reduction |

The pinned file map below identifies the code for each row. Subsequent sections develop these extensions; producer examples motivate operations within this existing engine rather than proposing that the feature starts from nothing.

## Preserve the engine and add musical decisions around it

Keep the full AJ Hall takes as audio. The detector supplies accompaniment metadata; it never replaces a take with reconstructed kick/snare samples. Preserve sample-time transport, queued buffers, original melody generation, 32-bar theme/variation/breakdown/return, twelve instrument programs, two-note mid shells, bass and the film/chop separation. Keep BPM, key and Footage audio controls as the user-facing controls. Producer techniques belong inside composition and preparation, not in a new collection of imitation presets.

The current sampler already provides a useful foundation. Three-band envelopes in `LofiDialogueSampler` propose acoustic gestures and longer lines, and a fragment pickup can lead to an intact quote. `LofiSpeechFocus` adds bounded SoundAnalysis speech/music/singing evidence, retaining heuristic candidates if classifier results do not arrive. These are useful acoustic decisions, not recognized words. Extend the retained source records and planner rather than replacing them with a transcript-only path. [Sampler](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiDialogueSampler.swift#L28), [speech focus](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiSpeechFocus.swift#L18).

The additive pipeline is:

```text
incoming footage → immutable source PCM / source clock
                 ├─ decoded continuous film bed → existing bed bus
                 └─ bounded analysis worker
                    → speech/clarity candidates + optional local transcript
                    → phrase / clause / word-group / stress hierarchy
                    → acoustic boundary refinement
                    → stable source-derived pad bank
current/next take + transport revision + section + occupancy
                    → seeded constrained performance plan
                    → selected-unit render/cache
                    → revision/deadline check
                    → existing sample-time scheduled chop bus
```

Bed readiness must be independent of optional semantic analysis. `ArchiveFootageService.scheduleAudio` currently prepares chops before posting the continuous buffer. Inserting ASR into that await chain could delay the bed that PJ already cannot hear. Decode/publish the valid bed promptly, and attach a later bank only at a safe future boundary. [Scheduling seam](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Archive/ArchiveFootageService.swift#L256).

## Producer practices and their useful translations

### DJ Premier: make a few related pieces carry identity

In the RBMA account of “The Question Remains,” Premier describes repeatedly restarting a short stab from a damaged record, pitching a copy down, assigning it to another pad and alternating versions. The useful principle is a small, related vocabulary with deliberate performance. One strong source event and its expressive sibling can establish identity more clearly than a stream of unrelated cuts. His Wax Poetics account also describes equipment learning and responding to the artist in the room, reinforcing selection from the actual situation rather than a universal recipe. These are Premier's own accounts of particular practices, not exhaustive rules for his catalog. [Premier RBMA](https://www.redbullmusicacademy.com/lectures/dj-premier-you-know-my-steez/), [Premier Wax Poetics](https://magazine.waxpoetics.com/article/dj-premier-takes-it-personal/).

For Liminal, reserve an original phrase, a short recognizable subphrase and one alternate articulation or modest linked pitch/rate version. Keep their pad identities stable for several appearances. Let repetition announce the vocabulary before an alternate surprises the listener. A “Premier-inspired operation” here means related sample variants and repeated stabs; it does not mean a Premier sound preset, copying a record, or claiming stylistic equivalence. Do not down-pitch every word automatically. A voice's identity and intelligibility can be more useful than a conspicuous effect.

### J Dilla: expressive choices and relationships among timing layers

Dilla's own 2001 interview discusses sixteenth-note rhythms and extended listening to a pattern before deciding what it needs. That account supports deliberate revision and patient selection. A reproduced Scratch Q&A connects limited sampling memory with chopping, values imperfections in live recordings and describes a then-current sampled-groove-first process. The reproduction has transcription problems and the original scan was not inspected, so it should carry less weight than the preserved 2001 interview. Neither source supplies a universal numerical swing setting. [Dilla, Soul Under Control](https://www.stonesthrow.com/news/soul-under-control/), [reproduced Scratch interview](https://www.sirpierre.se/2013/12/dagens-dilla-j-dilla-still-lives-through-scratch-magazine-mayjune-2006.html).

Collaborators add a different kind of evidence. Questlove recalls Dilla retaining many dynamically different drum hits from an extended break, and complicates his initial quantization answer rather than leaving it at “off.” T3 recalls selective quantization and constructing whole melodies from small pieces; Young RJ describes learning from Dilla. These are firsthand memories of working practice, with the normal limits of retrospective accounts. They support expressive alternatives and selective relationships, not applying random timing to every event. [Questlove RBMA](https://www.redbullmusicacademy.com/lectures/uestlove-phrenology-of-hip-hop/), [T3 and Young RJ](https://antigravitymagazine.com/column/red-light-fever-t3-young-rj-of-slum-village-on-j-dillas-production/).

Later analysis offers an additional interpretation. Dan Charnas describes comparing grids and waveforms: evenly spaced hats can feel swung because of a displaced snare. His discussion of Another Batch also describes evolving programming and slowed samples. These are Charnas's historical/research interpretations, not Dilla explaining his own exact settings; the underlying measurements were not inspected here. The useful inference is that groove emerges among layers, and cannot be captured by one global late offset or a quantization-off switch. [Charnas interview](https://rockandrollglobe.com/hip-hop/hip-hop-still-runs-on-dilla-time/), [Charnas on Another Batch](https://pitchfork.com/features/article/the-obscure-j-dilla-beat-tape-that-changed-music-forever/).

Apply this by keeping alternative expressive source units, retaining a selected pattern and changing one dimension at a time: an answer, an accent, a rest or a rate variant. Preserve AJ's existing timing rather than imposing “Dilla swing” over him. Bass may share selected kick attacks, mids may answer a backbeat and speech may anticipate a gap; their relationships should be stable within a phrase. Dynamic and timing choices must remain related across repeats. Uniform independent jitter would obscure the decisions this evidence makes interesting.

### Pete Rock: playback speed is an expressive choice

Pete Rock's discussion of “The Joy” distinguishes the appeal of high-speed sampling from his choice to retain the original-speed singing for that record. It is a source-specific judgment, not a command to always repitch or never repitch. Keep native cadence as a real candidate. Compare it with linked pitch/rate playback when a shorter or darker gesture fits; retain the original when speech character matters more. [Pete Rock, Microphone Check transcript](https://www.withradio.org/2014-07-01/pete-rock-real-could-be-another-word-for-original).

This also corrects terminology. Rate conversion couples duration and pitch. Pitch-preserving time-stretch attempts to change duration independently and may smear consonants or tails. Pitch shifting alone is a third operation. The planner must identify which transform it requests and map time accordingly. Do not label all slower playback “time stretch,” or assume that speech needs pitch correction to become musical.

### Ski Beatz: choose attractive sounds before fitting tempo

Ableton's written demonstration describes Ski listening with the metronome off, marking desirable source events without tying them to session tempo, slicing those markers, playing the bank and tapping a tempo. Selection precedes tempo establishment in that example. It directly challenges a universal stretch-whole-source-before-chopping recipe. The written account of a modern Ableton demonstration is not proof of a historical MPC feature. [Ski Beatz demonstration](https://www.ableton.com/de/blog/ski-beatz/).

Liminal already has a drummer and tempo, so it should not let speech replace that authority. Transfer the selection principle: first find clear, characterful units, then ask which can fit the current beat. A sentence is not a periodic drum loop and may have no meaningful native BPM. Fit one or several stress anchors, not an imaginary evenly spaced syllable grid. A shorter good phrase can beat a perfectly bar-sized bad one.

### Todd Edwards: prepared banks and vocal texture, as a cross-genre comparison

Edwards describes preparing sample banks, trying compatible sounds and rejecting failures, with historical memory limits influencing sampling speed and artifacts. His 5 Magazine account also emphasizes preparation effort and the possibility of spacious tracks despite larger sampling capacity. This is house/garage vocal collage practice, included because the bank-preparation decisions transfer; it is not presented as a boom-bap exemplar. [Edwards RBMA](https://www.redbullmusicacademy.com/lectures/todd-edwards/?template=RBMA_Lecture/transcript), [Edwards 5 Magazine](https://5mag.net/features/todd-edwards-interview-2012/).

Separate readable speech from vocal texture. Most featured dialogue should convey recognizable original language. Occasional tiny slices can act as percussion or atmosphere, but should have a distinct role and a strict density budget. A modern MPC Slice Motion tutorial demonstrates deliberately restricted random stutter and envelope changes; that is useful sound design, not evidence that random syllables form meaningful sentences. [Vocal Slice Motion](https://www.mpc-tutor.com/mpc3-tutorial-slice-motion-vocals/).

### Bob Power and Roger Linn: timing needs intention and clean boundaries

Power explains how source timing carries the feel of its original context, and how replay can remove interesting friction. Linn describes systematic swing, velocity-sensitive performance, accurate playback and trimmed samples rather than a secret random timing engine. Together these support preserving internal phrasing while choosing particular relationships to the current drummer. They do not establish that every timing mismatch is desirable. [Bob Power RBMA](https://www.redbullmusicacademy.com/lectures/bob-power-it-always-takes-longer/), [Roger Linn interview](https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/).

Treat a sample's linguistic entrance and its rhythmic accent separately. A consonant can precede the stressed vowel that should coincide with a drum. Schedule the necessary lead-in before that accent rather than cutting it off. Repeated gestures should retain their contour. These are internal composition rules, not artist-specific timing presets.

## The manual workflow translated into an autonomous loop

The MPC manuals and worked tutorials distinguish selecting boundaries, auditioning them, assigning playback behavior, reconstructing source order, performing a new pattern and editing it. Equal regions and automatic thresholds are proposal tools; manual correction remains part of the method. The MPC2000XL manual documents offline time-stretch/BPM Match with beat-count input and quality choices, so historical hardware should not be described as universally transparent realtime warping. Modern firmware adds other options without rewriting that history. [MPC2000XL manual](https://www.mpc-tutor.com/files/mpc-manual/MPC2000XL_manual.pdf), [XL chopping](https://www.mpc-tutor.com/chopping-samples-on-the-akai-mpc2000xl/), [Renaissance/Studio chopping](https://www.mpc-tutor.com/mpc-renaissance-mpc-studio-chopping-tutorial/).

| Manual action | Autonomous equivalent | Guard against |
|---|---|---|
| Listen for something worth keeping | Rank complete speech/phrase candidates using clarity, acoustic character and room | Selecting only because a duration divides a bar |
| Trim and audition | Refine suggested cuts with source audio and inspect reconstruction | Trusting a transcript timestamp or zero crossing alone |
| Put related pieces on pads | Persist a source-specific bank with alternate roles | Rebuilding vocabulary every bar |
| Play against the beat | Choose a constrained phrase grammar and stress placements | Quantizing every syllable or randomly permuting words |
| Set choke and note behavior | Store protected endings, group exclusivity and release policy | Two dry voices speaking or amputation of final consonants |
| Keep a good take and edit it | Cache the event plan and alter one dimension at a section opportunity | Unrelated transformations replacing recognizable development |
| Resample/commit when useful | Render only selected transforms off the realtime path | Repeated model/DSP work in playback callbacks |

The sampler should be autonomous about its input, not indiscriminate about output. Any incoming clip can enter this pipeline. A clip without usable dialogue can legitimately produce no dialogue performance while the film and music continue. Evaluation fixtures must never become a hidden production catalog of preselected quotes.

## Candidate hierarchy, ranking and bank records

**Current → gap → extension:** `LofiDialogueSampler` already cuts acoustic gestures, ranks source material with speech-focus evidence and prepares longer lines. PJ's requested improvement is how those ingredients become a coherent, recognizable performance, with optional meaningful rearrangement. Extend the existing candidate records into a hierarchy and stable bank, preserving the intact-line anchor and acoustic fallback; validate original-order reconstruction before adding more transformations.

Analyze a bounded source window and retain a few useful utterances before generating arrangements. A starting experiment is a 12–30 second analysis window, three to six candidate utterances around 0.7–6 seconds each, and eight to sixteen bank references, including alternate views of the same PCM. These limits bound work and search; adjust after actual footage and device measurements. Do not amplify near-silence to make it pass a speech detector.

Build a hierarchy from utterance to pause group, short phrase, recognized word/group where available, and occasional expressive stress or texture. SoundAnalysis and envelopes can support speech likelihood and boundary proposals; they cannot identify word meaning. A transcript can propose boundaries and source-contained phrases, but acoustic refinement still decides whether a consonant/tail survives. Preserve parentage and source adjacency so a planner can recover a natural line rather than treating all regions as interchangeable.

Rank useful sound before tempo fit. Positive evidence includes speech/classifier confidence, intelligibility, intact entrance/exit, distinctive stress, available silence and source relevance. Penalize clipping, multiple competing speakers, soundtrack masking, uncertain boundaries and excessively destructive transforms. Then evaluate rhythmic fit among the strongest candidates. Implement scores as named components with logged values; do not let a barely clearer phrase lose to a mechanical duration match through an opaque weight sum. Tune weights using comparisons and rejection reasons.

The core records can remain small immutable value types. Names below describe contracts rather than required Swift API names:

```text
SourceAudio:
  contentID, cueToken, originalSampleRate, originalRangeFrames
  immutablePCMReference, decodeRevision, sourceToDecodedMapping

SpeechUnit:
  unitID, parentID, level, sourceRangeFrames, sourceNeighbors
  textTokenRange?, text?, recognitionConfidence?, boundaryConfidence
  speechScore, interferenceScore, stressAnchorsSourceFrames[]
  protectedSpans[], naturalTailRange, speakerIDIfReliable?
  permittedTransformPolicies[], fallbackRole

PadBank:
  bankID, analysisVersion, orderedUnitReferences[], roles[]
  anchorUnitID, siblingGroups[], dryChokeGroup, expiryPolicy

TransportSnapshot:
  epoch, revision, takeID, sampleOrigin, currentTempo, committedNextTempo?
  section, futureBoundaryFrames[], latestCommitFrame

PerformanceEvent:
  padID, targetAccentFrame, sourceAccentFrame, transformID
  renderedStartFrame, gainContour, gatePolicy, releasePolicy
  protectedEndFrame, expectedRenderedText?, occupancyEndFrame

PerformancePlan:
  sourceID, cueToken, bankID, analysisVersion, seed, transportRevision
  patternFamily, events[], dryAndWetOccupancy, deadline, rejectionReasons
```

Keep an untransformed anchor, a shorter original-order version, a few complete subphrases, one or two accent words only when safely recognized, and at most a small number of transformed siblings. Rest is an arrangement operation, not a fake audio pad. Chronological pad ordering and stable identifiers make inspection and reconstruction easier even without a visible pad grid. Avoid unreliable speaker labels; uncertainty should reduce reorder freedom, not invent certainty.

Seed from content identity/source range, analysis version, bank identity, take, section and variation counter. Cache accepted analysis separately from rendered variants. A seed only guarantees repeatable decisions with identical analysis and algorithm versions; nondeterministic recognizer output needs caching/versioning. Thread completion order must never choose the winning phrase. Log what source tokens a plan intends to play, its transform, original/arranged order and why candidates were rejected.

## Cadence fitting and three design choices

**Current → gap → extension:** decoded rate changes and scheduled sampling already give Liminal timing tools. They do not establish a speech BPM or independent pitch-preserving warping. Add an explicit comparison among natural cadence and permitted transforms, and schedule perceptual stress rather than merely a file boundary. Preserve the sample-time path and validate source-to-render mappings before evaluating musical fit.

| Design | Strength | Cost and limitation | Decision |
|---|---|---|---|
| Acoustic hierarchy, native/linked-rate units, stable bank and grammar | Builds on current code, immediate fallback, cheap repeated performances | No claim of semantic reordering without words | First implementation |
| Same planner with one local transcript backend | Protects phrases, names and negation; admits narrow intelligible rearrangements | Asset/platform/locale readiness and word-boundary errors | Add after acoustic musical behavior works |
| Fit whole utterance to a span before slicing | Can preserve a common treatment for genuinely rhythmic material | Can distort speech pauses and consonants; extra rendering | Optional comparison, never universal default |

Within the first two designs, compare three treatments for each chosen unit: its native cadence; modest linked pitch/rate playback; and optional pitch-preserving duration fitting if a qualified renderer supports it and the result helps. A phrase that fits only with extreme processing should lose to a shorter phrase, a freer entry or a rest. Do not select a stretch library until the existing path's actual limitations are heard and target-platform support is verified.

Map a small number of stress anchors to plausible musical spans and entrances: a pickup, one bar, two bars, or a freer breakdown line. Natural speech does not need a BPM. A known musical loop can have an established beat count; arbitrary dialogue usually does not. If only one stress is reliable, anchor it and preserve the rest of the phrase's cadence. If several stresses cannot fit within conservative deformation, change units instead of forcing every syllable onto subdivisions.

For linked playback rate `r`, duration and accent distance from cut start scale by `1/r`. For a nonlinear pitch-preserving renderer, retain its explicit source-to-output time map; a single ratio may not describe local stress positions. The scheduled start is `targetAccent + deliberatePhraseOffset - renderedAccentOffset`. That offset belongs to a whole gesture or stable profile, not a fresh random displacement per syllable. Recompute after rendering and include release/FX occupancy when checking the next event.

```text
prepare(source, cue, transport):
  publishBedWhenDecodedAndCueValid(source, cue)
  candidates = analyzeBoundedSource(source)           // off realtime path
  transcript = optionalReadyLocalBackend(source, deadline)
  hierarchy = refineBoundaries(candidates, transcript, source)
  bank = buildStableBank(rankBySoundThenFit(hierarchy))
  if cancelledOrSourceGone(cue): discard
  cache(bank)
  boundary = nextFeasibleBoundary(currentTransport(), bank)
  if noBoundaryBeforeDeadline: useAcousticFallbackOrRest()
  snapshot = currentTransport().revisionedSnapshot(boundary)
  patterns = enumerateBoundedGrammar(bank, snapshot.section)
  for pattern in patterns:
    enforceSourceTextGuardsAndProtectedSpans(pattern)
    compareNativeAndAllowedTransforms(pattern, snapshot)
    placeFewStressAnchorsAgainstHumanTiming(pattern, snapshot)
    enforceDryVoiceExclusivityAndTailOccupancy(pattern)
  chosen = seededChoiceAmongAcceptablePlans(patterns)
  rendered = renderSelectedUnitsAndCache(chosen)
  if cueTokenAndTransportRevisionStillValid(snapshot):
    queueImmutablePlanAtSafeBoundary(rendered)
  else: remapForStillValidFutureBoundaryOrDiscard()
```

Use a bounded enumeration, not an unconstrained search that fills every available subdivision. Start with a few pattern families and two to five phrase events per four bars, plus at most one brief ornament, as a tuning experiment. Add an occupancy budget because four long lines are very different from four stabs. Include wet tails and concurrent lead/mid activity; an absence of new notes does not imply an audible gap.

## Grammar, intelligibility and an illustrative performance

**Current → gap → extension:** fragment pickups followed by an intact quote already create a rudimentary gesture and return. Build on that vocabulary with retained patterns, explicit gaps and narrowly admissible phrase changes. The improvement is audible development of the same source, not merely more cuts. Verify recognition and intelligibility against the existing gesture at the same mix level.

Start with `anchor`, `echo`, `call-response`, `sparse-reorder` and `texture-fill`. The anchor states the source line clearly. Echo repeats a meaningful beginning or accent. Call-response leaves a gap and answers with a related ending. Variation preserves the beginning and changes one answer, omission or articulation. Return reuses the known line with enough mix space for recognition. Keep successful patterns across more than one appearance rather than cycling operations on every bar.

Reordering requires source-contained complete units and explicit restrictions. Protect negation with its predicate, names with their phrase, determiners with nouns and tightly joined pronoun/verb spans. Preserve uncertain spans as a whole. Never create new words, splice phonemes into invented speech or advertise POS tagging as meaning comprehension. Initial templates should be narrow: repeat a whole clause, omit a separable parenthetical, move an intact adverbial, or exchange independent clauses only when their relation survives. If a template cannot establish safety, play original order. Protecting grammar does not guarantee preserved intent; sensitive ambiguous cases should remain intact.

Consider this invented sentence solely as a design illustration: **“When the lights go down, we keep moving.”** It is not captured audio, a timing measurement or a claim of what a model would detect. Assume the source actually permits clean cuts at the clause boundary. `A` is the complete sentence; `B` is “When the lights go down”; `C` is “we keep moving”; `D` is a complete “keep moving” if its entrance is safe. Capitals mark a proposed accent, dots a rest, and bracketed labels show original audio units rather than synthesized text.

```text
Four bars, illustrative gesture placement rather than exact transcription:
Establish:   [A: When the LIGHTS go DOWN, we keep MOVING] . . .
Echo:        [B: When the LIGHTS go DOWN] . . [B] . .
Answer:      [B] . . . [C: we keep MOVING] . .
Variation:   [B] . . [D: keep MOVING] . [D] . .
Sparse move: [C: we keep MOVING] . . [B: When the LIGHTS go DOWN] . .
Return:      [A at native cadence] . . . .
```

The sparse move is admissible only if the two clauses remain clear as performed and the splice preserves the source's qualification; it must not become “we keep moving” divorced from context in a misleading way. A low-confidence transcript cannot authorize it. The same input can therefore produce a rhythmic performance without word reordering. Native stress spacing stays inside each unit, with selected accents related to AJ's kick/backbeat landmarks and deliberate silence around them. A second bank from different footage gets the same method, not these words or fixed event placements.

Default related dialogue to one exclusive dry voice. A later event can choke a prior member with a smooth release, while a protected complete line should finish its critical ending. If an event would cut a required word, move it, shorten the chosen unit or remove it. Set one-shot versus held/gated behavior explicitly. A small ambience tail may survive, but a distinct delayed sentence must count as another intelligible foreground event. Manufacturer definitions distinguish note-on, one-shot, note-off and mute groups; do not conflate them. [Playback modes](https://www.mpc-tutor.com/mpc-program-tutorial-note-off/), [Akai pad guide](https://www.akaipro.com/guides/mpc-sample/pad_play.htm).

Seek low-energy or zero-crossing regions near allowed boundaries and use adaptive fades. A zero crossing alone does not make a linguistically safe join; fixed padding can swallow adjacent words. Preserve stop consonants and breath context, and compare reconstructed source order before any rearrangement. Test original, transformed and choke-ending versions independently. Texture units can accept stronger articulation but must be labeled and budgeted separately from understandable speech.

## Local transcription on macOS and visionOS

**Current → gap → extension:** speech-likelihood classification and acoustic boundaries already work without recognition. They cannot identify names, negation or clause structure, which limits intelligible reordering. Add one optional local metadata adapter with acoustic refinement and rejection states; preserve the classifier-only route and bed readiness. Verify local behavior, boundary quality and useful musical improvement separately.

| Option | Verified support/documentation | Required gates | Recommended role |
|---|---|---|---|
| Apple `SpeechAnalyzer` + `SpeechTranscriber` | Current Apple metadata lists macOS 26 and visionOS 26; asynchronous analysis, audio time ranges and managed assets | Installed SDK/build settings, device capability, locale, assets, input format and cancellation | First candidate for qualifying one backend |
| Apple legacy `SFSpeechRecognizer` | macOS 10.15+, visionOS 1.0+; segments expose timestamp/duration/confidence | Authorization, availability, `supportsOnDeviceRecognition`, then `requiresOnDeviceRecognition = true` | Local-only alternative where actually supported |
| whisper.cpp | MIT; macOS/Apple Silicon acceleration documented; experimental word timestamps | Native bridge, target build, model license/storage, real latency and boundary accuracy; visionOS absent from README checklist | Prototype only if Apple coverage fails |
| WhisperKit in Argmax OSS Swift | MIT package declares macOS 13 and visionOS 1; on-device transcription/timing features documented | Select OSS library and model, compile/deploy, measure memory/latency/timing | Alternative if Swift packaging is decisive |
| Existing acoustic sampler | Already present without transcript semantics | Speech/clarity heuristics and existing bounded classifier | Always retain for unavailable/late/uncertain analysis |

Current Apple documentation supersedes early launch descriptions that excluded visionOS. It still does not prove that this project's installed SDK and physical Vision Pro can use the API. The project sets macOS deployment to 26 and supports `macosx xros xrsimulator`; the audit found no explicit visionOS minimum. Inspect resolved Xcode settings on the Mac before integration. [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), [project settings](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal.xcodeproj/project.pbxproj#L360).

Use `isAvailable`, supported/installed locales and `AssetInventory` readiness as distinct checks. Supported locales can include downloadable assets; they are not proof of installed offline models. Request audio time-range attributes explicitly, use an accepted audio format, and finalize accepted text before making permanent edit identities. Model installation can require network traffic even though inference is local and needs no paid API key. Manage installation once through an explicit assets-ready lifecycle; do not download on every cue. [Audio ranges](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption/audiotimerange), [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory).

For legacy Speech, never start a potentially server-backed request when offline support is absent. Check support first, then require on-device recognition. Permission refusal is a normal fallback state. Apple defines a transcription segment as a word or group of words; do not treat every result as one exact word boundary. [On-device support](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition), [required local mode](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition), [segments](https://developer.apple.com/documentation/speech/sftranscriptionsegment).

Start semantic templates with clear English, preferably one speaker. Unsupported language, overlap, singing and music-heavy clips remain valid inputs through the acoustic/original-order/rest path. Run recognition once on a cached source range before rate transformations. The decoder already can slow footage: retain original mono analysis PCM or explicitly map ASR source seconds through decode rate into cue frames. Never mix source-film seconds, decoded frames, musical beats and output host time without a conversion record.

Whisper alternatives also need skepticism about silence hallucinations and uneven language/accent performance. Upstream whisper.cpp lists tiny at 75 MiB disk/~273 MB memory and base at 142 MiB/~388 MB; these are its upstream model-format figures, not Liminal or Core ML measurements. WhisperKit model footprints must be measured separately. Do not run several backends per cue by default, add an HTTP service or make Foundation Models a dependency for this first version. [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [Argmax OSS Swift](https://github.com/argmaxinc/argmax-oss-swift), [Whisper limitations](https://github.com/openai/whisper/blob/main/model-card.md).

NaturalLanguage can tag lexical classes and help protect phrases. It does not supply syntax, coreference, intent or a truth-preserving rearrangement guarantee. Reconcile transcript ranges with local energy, consonants and silence, then reject implausible durations, repeated hallucinated language, unsupported ranges and low-confidence boundaries. Keep the original audio and source token ranges available for review. [NLTagger](https://developer.apple.com/documentation/naturallanguage/nltagger).

## Human timing and bass impact

The current full-take detector uses low-band novelty, a global maximum-relative threshold and 110 ms suppression, then subtracts one analysis hop. Quiet kicks, fills and nearby hits could be missed or merged; that is a code hypothesis to test against hand labels. A waveform maximum is not a kick onset, and a low-frequency event is not necessarily a kick. Preserve attack, body peak, confidence and uncertainty separately. [Current take analysis](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiDrumTake.swift#L106).

Upgrade metadata first with low/mid/high novelty, adaptive local thresholds and cross-band/context evidence. Account for filter delay, window placement, resampling and detector latency separately. aubio's onset API distinguishes detection and peak picking and exposes delay; it supports calibration as an engineering requirement, not adopting its library or assuming success on AJ Hall. Use manual attack labels on complete takes, especially ghosts and fills. Escalate to stem separation only if measured errors still cause musical failures after this simpler path. Validate latency/leakage and license before adding any separation model. Keep the original mixed take audible. [aubio onset API](https://aubio.org/doc/latest/onset_8h.html).

Create a sparse timing field: structural kicks for chosen bass accents, backbeats for mid answers and interpolated subdivisions for pickups and speech. Preserve role-specific offsets and within-gesture timing. Current bass only adopts a nearby kick within 0.075 beats before applying pocket offsets; that is not a shared timing model for all layers. At 70 BPM, 0.075 beats is about 64 ms, a calculation from code rather than measured timing error. [Bass score](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiScore.swift#L340).

Bass already includes fundamental plus second/third harmonics and tanh shaping, with an 18 ms attack and 310 ms release. It is not a pure sine waiting for basic saturation. Compare three bounded voices: a short round sub with a fast click-safe rise and modest settling pitch contour; a harmonic/plucked voice with a transient bright component over a stable body; and a longer round answer with controlled release. Keep the sustained pitch in the existing harmony. Choose a voice per phrase/section and vary reproducibly rather than selecting an unrelated tone each hit. [Current synth](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiSynth.swift#L14), [envelope mechanisms](https://www.ableton.com/en/manual/live-instrument-reference/).

Align audible attack, not file start or bass body peak. Recorded bass needs attack landmarks and pitch-rate correction; synthesis needs a stable phase policy and smooth edges. Test the actual kick/bass combination in mono and across pitches. A polarity flip or fixed delay is not a universal cure. Shorten overlapping sub releases, allocate register and use bounded ducking where necessary. Existing bass ducking is capped at 30%; raising every source may simply increase final gain reduction. [Sidechains](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiSidechains.swift#L28), [kick/bass practice](https://www.izotope.com/community/blog/how-to-mix-kick-and-bass).

An 808-like decay is an optional color, not a boom-bap requirement. A small licensed instrument bank can add plucked electric/double bass or sampled 808 character later without violating the ban on preselected dialogue. Verify redistribution rights, tuning, leading silence and baked effects. VSCO 2 CE is CC0 and lists contrabass pizzicato samples; none were downloaded or auditioned in this research. Composition-use permission alone is insufficient for shipping raw sample assets in an app. [VSCO official library](https://versilian-studios.com/vsco-community/), [CC0 license](https://github.com/sgossner/VSCO-2-CE/blob/master/LICENSE).

## Film bed, theme return and mids

The bed is already boosted 1.76 times outside chop windows and 1.31 times underneath them. Its decode conditioning targets −26 dBFS RMS with capped boost/soft clipping; its voice path also applies −10.5 dB base trim, wet/dry processing and 220–2400 Hz filtering with two low-pass stages. These facts make another blanket gain boost an incomplete answer. Compare dry trim, useful bandwidth and wet balance at a fixed Footage setting, preserving silence guards and a monotonic control whose zero remains zero. Let the background remain identifiable between featured lines and dip only as much as needed under them. [Decode](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Archive/ArchiveAudio.swift#L78), [bed processing](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/ArchiveVoice.swift#L45).

Make room through arrangement and bounded spectral choices rather than permanent blanket ducking. Speech classification does not isolate a clean speech stem from soundtrack music. Try a clearer candidate before expensive separation. Compare dry bed, bed returns, chop dry and chop returns independently, then in the full mix. Avoid turning a louder bed into more dark reverberation that masks the very words it is meant to reveal. Preserve the current separate paths and scheduled sample timeline. [Chop and scheduling path](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/ArchiveVoice.swift#L158).

Theme and return already reuse the remembered motif. Score equality establishes the composition's formal relationship, not listener recognition across changes in instrument attack, register and wetness. Save a reference presentation alongside pitches/rhythm, and reveal the first identifying notes at return: familiar articulation/timbre or a clear dry lead, reduced competing tails, and a real preceding contrast. Let color evolve after the listener has heard the return. Preserve the twelve-instrument breadth rather than solving recognition by eliminating it. [Theme](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiScore.swift#L160), [return](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiScore.swift#L320).

The active renderer uses recorded instruments for both lead and texture/mids. The synth fallback's long texture attack is not the active mid path to fix. Raise and articulate the sampled shells, then rotate a few responses derived from melody gaps/cadence: an offbeat short stab, a longer answer or a rolled two-note shell with bounded velocity/length/send variation. Preserve close voice leading and register. Supporting a held lead or answering its ending is often clearer than doubling every attack. Include wet tails in the occupancy planner so a breakdown can actually sound sparse. [Recorded renderer](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiRenderer.swift#L68), [mid shell](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiScore.swift#L370).

## Scheduling, cancellation and bounded cost

Snapshot cue token, source/range/rate, transport epoch and revision, current and committed-next tempo/key, section and latest safe commit frame. Existing playback has job/epoch cancellation, but the take-grid snapshot lacks an explicit transport revision. A transcript can remain valid after a tempo change while its rendered musical plan becomes stale. Cache analysis independently; invalidate/remap the plan against the new transport. [Playback cancellation](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiPlayback.swift#L150), [take grid](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiScore.swift#L90).

Bound analyzed duration, candidates, bank variants, grammar expansion and concurrent jobs. Check cancellation inside long loops and after await points. No model inference, asset installation, file/network I/O or unbounded allocation belongs on the realtime callback or critical scheduling queue. Render selected transforms once and cache them. A late bank can wait for another valid boundary; it must not force an immediate entrance or move already committed audio. If its clip departed, discard it.

Choose a deadline from measured scheduling lookahead, not a speculative ASR speed claim. Instrument decode, classification, recognition, alignment, transformation and queueing separately; record latency percentiles, memory, misses and thermal state on Mac and physical Vision Pro. Cache key inputs include source identity/range, locale, model/version and analysis settings; rendered variants also include transform policy/tempo. A model update may change text and should change the analysis version.

Fallback order is a readable original-order line, a shorter readable phrase, a brief clearly nonsemantic accent, a still-relevant cached bank, or rest. Avoid repeating a stale quote indefinitely. Unavailable locale, missing/evicted model, denied permission, silence, overlap, low confidence or an exceeded deadline must preserve film/music readiness. Optional metadata cannot become a prerequisite for playback.

## File map at the pinned commit

All following paths are in `pj4533/Liminal` at the baseline above; links are commit-pinned and remain meaningful if filenames later move.

| File / seam | Planned responsibility |
|---|---|
| [ArchiveFootageService.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Archive/ArchiveFootageService.swift#L256) | Separate bed publication from optional analysis; manage cue lifetimes |
| [ArchiveAudio.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Archive/ArchiveAudio.swift#L78) | Retain source-time mapping, immutable PCM and decode conditioning |
| [LofiDialogueSampler.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiDialogueSampler.swift#L28) | Hierarchy, ranking, stable bank and performance records; factor helpers if needed |
| [LofiSpeechFocus.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiSpeechFocus.swift#L18) | Preserve acoustic/classifier fallback; integrate optional metadata through an adapter |
| [ArchiveVoice.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/ArchiveVoice.swift#L158) | Scheduled chops, choke/tail policy and bed balance |
| [LofiDrumTake.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiDrumTake.swift#L106) | Multiband attack landmarks while preserving complete take playback |
| [LofiScore.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiScore.swift#L320) | Shared sparse timing, melody responses, reference return and bank grammar placement |
| [LofiSynth.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiSynth.swift#L14) | Bounded bass attack/body/release alternatives |
| [LofiRenderer.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiRenderer.swift#L68) | Active recorded mid articulation and diagnostic stem export |
| [LofiPlayback.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiPlayback.swift#L150) | Revision-bearing snapshots, queued boundary commits and cancellation |
| [LofiMasterBus.swift](https://github.com/pj4533/Liminal/blob/a290f8377c208c9b50725fdcb9c104bc23f4e1bc/Liminal/Audio/Lofi/LofiMasterBus.swift#L25) | Final headroom and gain-reduction diagnostics |

## Implementation phases and acceptance

**Phase 1 — preserve a reference and implement the speech foundation.** Freeze source/seed/BPM/key/drum take, establish full-mix and separate bus exports, and separate bed readiness from chop analysis. Introduce source-frame hierarchy and stable banks with native playback, source-order reconstruction, original-line anchor and conservative call-response/repetition. Add occupancy, protected endings and revision checks. Make bed clarity, active mid balance and first return presentation small parallel mix adjustments, not a new engine.

**Phase 2 — qualify one local recognizer and conservative reordering.** Build the chosen Apple path on supported Mac and visionOS targets, verify local behavior/asset lifecycle, then add final transcript ranges, acoustic refinement, source-token guards and a few safe templates. Compare it against the acoustic foundation on the same inputs. Only prototype a Whisper backend if documented Apple availability or measured quality/budget fails the actual targets.

**Phase 3 — improve shared timing and bass.** Label attacks on representative full takes, qualify multiband landmarks, introduce a sparse timing field, and compare the three bass voices at matched loudness. Make mid answers and speech accents use appropriate references. Evaluate theme recognition across the full form and all instrument families. Optional bass recordings follow a specific demonstrated palette gap.

**Phase 4 — expand only from observed failures.** Consider pitch-preserving fitting, separation or additional templates if rejected-candidate logs and listening identify recurring needs. Keep original-order/native variants as comparisons. Do not make model count or transformation complexity a proxy for musical quality.

Unit and fixture checks should cover source/decode/render time mappings, stable seed/version behavior, hierarchy containment, protected spans, source-order reconstruction, transformed accent positions, choke exclusivity and occupancy. Verify no out-of-range PCM reads, duplicate/missing source syllables, nonfinite samples or stale revision commits. A deterministic fixture suite should include speech with breaths, plosives, whispers, accents, music underneath, overlapping speakers, silence, singing and unsupported language. Use annotated timestamps and text spans as evaluation truth; production still consumes unseen incoming footage.

Integration checks should exercise cue replacement, stop/restart, BPM/key changes during recognition, next-take transition, late decode, recognizer timeout/cancellation, asset eviction, denied permission and device route latency changes. Confirm bed scheduling does not wait for transcript success and optional failures do not stop accompaniment. Offline tests should deny network for inference after assets are ready and inspect backend behavior; merely omitting an API key is insufficient evidence of local-only operation. Validate continuity at boundaries and complete-turn cancellation, not just function outputs.

Apple qualification requires resolved build settings, macOS and visionOS builds, representative hardware runs and real offline/asset/locale testing. Record p50/p95 stage timings, peak memory, cache growth, deadline misses and thermal behavior, then choose budgets. The private AJ assets must be present for drum-dependent tests; a test that skips when assets are absent cannot validate timing with those recordings. Use a combined output harness that actually schedules lo-fi music plus bed/chops rather than assuming a conductor-only offline render covers playback.

Listening acceptance should compare current sampler, acoustic grammar and transcript-assisted grammar using the same take, seed, key and matched playback loudness. Ask whether the original phrase is recognizable, words remain understandable, transformed patterns feel intentional, rests survive and the later return is recognized. Include unfamiliar footage, multiple seeds and negative cases. Inspect intended rendered text against actual source audio and ask whether a reorder misleadingly changes qualification. Reject clips/plans rather than accepting all transcripts to improve a success count.

For mix analysis use multi-resolution spectrograms with time-domain envelopes/onset labels, kick/bass windows, mono low-band sum/correlation, crest factor, limiter activity and reconstructed-peak measurements. A spectrogram cannot establish intelligibility or punch alone; waveform equality cannot establish theme recognition. Compare bass voices at matched perceived level and check small playback systems/headphones as well as the primary device. Set quantitative thresholds after establishing a baseline; this plan does not invent achieved loudness, latency, timing-error or recognition targets.

The Driftbot repository's `bin/ci-local` validates its Python/TypeScript suites, not Swift audio behavior. This change is documentation only; Markdown/source checks apply here. The Liminal coding session must use its current project test/build instructions on the Mac and retain exact commands, platform/SDK versions, private-asset availability and listening observations with results.

## Annotated craft and history sources

The following entries retain the research reading scopes. Interviews were read in the listed passages, not consumed end to end. Embedded music, tutorial audio and video were not auditioned. Line references describe the retrieved text, not permanent publisher anchors. Manufacturer documents establish their controls and procedures; they do not prove that the proposed algorithm sounds good. The two Charnas entries are later analysis rather than primary testimony about Dilla's actions.

### S1. Ski Beatz: Unique techniques — Ableton, 26 January 2010

URL: https://www.ableton.com/de/blog/ski-beatz/

Read: the complete substantive written demonstration, lines 55–70, particularly its six workflow bullets. This is Ableton's contemporaneous written account of its own filmed producer demonstration; the embedded video was not watched. Ski listens with the metronome off, adds roughly 10–15 markers to desirable events without relating them to session tempo, slices at those markers, plays the resulting keyboard bank, taps a tempo with his other hand, and records. Purpose: quickly discover a new performance from selected sounds. Modern Ableton technique, not evidence that an MPC60 had Warp Markers.

### S2. DJ Premier — Red Bull Music Academy lecture, Toronto 2007; host Jeff “Chairman” Mao

URL: https://www.redbullmusicacademy.com/lectures/dj-premier-you-know-my-steez/

Read: transcript passage on “The Question Remains,” lines 318–348, plus adjoining discussion of sample search. Premier describes repeatedly restarting one short stab from a damaged record, pitching a copy down, assigning it to another pad, and alternating between the versions. He also describes searching for sounds to match an imagined beat. Purpose: transform a familiar source through a small playable vocabulary. Do not extrapolate this one example into “Premier always uses this technique.” Embedded music was not auditioned.

### S3. DJ Premier takes it personal — Wax Poetics original interview, current web edition

URL: https://magazine.waxpoetics.com/article/dj-premier-takes-it-personal/

Read: equipment history and production-process passages, lines 80–106, also retrieved as direct HTML. Original print-era interview date was not established; current search indexing suggests a later web republication. Premier recounts learning loops on an S900 and moving to an MPC60 for programming after Eddie Sancho introduced it. He describes making beats in the room from a fresh start, responding to the artist. Purpose: sampling is situated selection and responsive making. This is historical first-person testimony, not a complete technical specification.

### S4. Pete Rock: “Real Could Be Another Word For Original” — NPR Microphone Check, Ali Shaheed Muhammad and Frannie Kelley, 1 July 2014

URL: https://www.withradio.org/2014-07-01/pete-rock-real-could-be-another-word-for-original

Read: transcript exchange about “The Joy,” 33 versus 45 RPM, lines 654–676, with article attribution. Rock explains choosing the original-speed singing for that record, while recognizing the appeal of higher-speed sampling elsewhere. He identifies the beat as an SP-1200 production from 1997/98. Purpose: playback speed changes character, and the right choice depends on the ear and source. Only the relevant transcript was read; the 84-minute audio was not heard.

### S5. Todd Edwards — RBMA New York 2013 lecture; host Emma Warren

URL: https://www.redbullmusicacademy.com/lectures/todd-edwards/?template=RBMA_Lecture/transcript

Read: transcript preparation passages, lines 450–478, and audience questions, lines 700–730. Edwards describes laying drums down, finding a sound, trying it, rejecting it if it fails, and later preparing banks to experiment with. He recalls sampling 33 RPM records at 45 to conserve memory, then playing them lower, producing artifacts. He discusses texture selection and losses from excessive pitch movement. Purpose: choose compatible material and exploit constraints deliberately. This is house/garage practice, included for vocal collage craft, not presented as a 90s boom-bap recipe. Transcript only.

### S6. Todd Edwards: The 5 Magazine Interview — Czarina Mirani, 30 November 2012

URL: https://5mag.net/features/todd-edwards-interview-2012/

Read: sample-count, memory, sample-bank preparation, and perfectionism answers, lines 61–77, via page and direct HTML. Edwards reports early sampling-time limits of roughly 5–15 seconds, later denser constructions, and time-consuming attention to pitch and preparation. He notes renewed appetite for older spacious tracks. Purpose: quality depends on choosing and preparing usable ingredients; available memory does not require density. First-person historical account; not evidence of a universal hardware memory limit or optimal density.

### S7. Bob Power — RBMA Rome 2004 lecture; host Torsten Schmidt

URL: https://www.redbullmusicacademy.com/lectures/bob-power-it-always-takes-longer/

Read: sampling/replay and timing discussion, lines 533–559, with adjacent material for context; also retrieved direct HTML. Power explains that a sampled part carries timing from its original musical context, and removing that friction when replaying can remove interest. Purpose: preserve meaningful relationships rather than sterilizing everything into one pocket. Entire lecture and embedded music were not consumed.

### S8. Roger Linn on Swing, Groove & the Magic of the MPC's Timing — Greg Scarth and Roger Linn, Attack Magazine, 2 July 2013

URL: https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/

Read: full substantive first-page email interview via direct publisher HTML after web-reader timeouts; reader comments excluded. Linn explains delaying even sixteenths, velocity-sensitive performance, pressure-controlled repeated notes, accurate playback, and tightly trimmed samples. He rejects secret random timing as his implementation's explanation. Purpose: controlled timing and dynamics enable expression. His design account is primary for his machines, not a claim to know every Dilla production decision. This supports avoiding a vague “humanize with random offsets” shortcut.

### S9. Akai MPC2000XL Operator's Manual — Akai, revision header 2001, mirrored primary document

URL: https://www.mpc-tutor.com/files/mpc-manual/MPC2000XL_manual.pdf

Read: printed pp.40–41 (Timing Correct), 103–104 (zones and linked boundaries), 106–107 (time stretch/BPM Match); PDF indices 51–52, 114–115, 117–118. Relevant text was available in the browser PDF reader; screenshots were requested, with later stretch-page screenshots timing out. Not a cover-to-cover read. The original manual specifies equal zones with manual refinement; Timing Correct includes swing and shift; time-stretch uses executable edits with quality/speed preset tradeoffs and explicit beat-count input for BPM Match. Historical correction: this XL supports offline stretch; do not generalize transparent realtime warping to every 90s MPC.

### S10. Chopping Samples on the Akai MPC2000XL — Andy Avgousti / MPC-Tutor, last modified 27 June 2023

URL: https://www.mpc-tutor.com/chopping-samples-on-the-akai-mpc2000xl/

Read: worked zone selection/refinement, slicing, reconstruction and timing correction, lines 13–71; stutter section also available in search/page text. The tutorial first divides a known musical loop, then corrects boundaries and reconstructs the original before changing it. Its end-margin example exposes a real limitation: extra tail can still click. Tutorial audio was not auditioned.

### S11. Introduction to Chopping in the MPC Renaissance & MPC Studio — Andy Avgousti / MPC-Tutor, last modified 27 June 2023

URL: https://www.mpc-tutor.com/mpc-renaissance-mpc-studio-chopping-tutorial/

Read: worked regions, pad audition, problem detection, shared-point editing, conversion, original reconstruction and finger-drummed rearrangement, lines 13–138. The explicit hand division is useful: one hand selects and auditions pads while the other adjusts boundaries; visual checks are followed by listening. Equal regions are an initial proposal, with late starts and prematurely cut tails corrected. New events reconstruct the break at its known tempo, then a performed version rearranges it. Modern software/controller workflow; no audio audition here.

### S12. How to Use the New “Note Off” Feature — Andy Avgousti / MPC-Tutor, last modified 27 June 2023

URL: https://www.mpc-tutor.com/mpc-program-tutorial-note-off/

Read: Sample Play definitions and worked hat experiment, lines 13–38. One-shot plays a sample through; note-on follows a held pad; a mute group lets a later member choke a playing member; note-off is a distinct mode triggered on release. Purpose: control articulation as well as onset. Modern MPC2.10+ tutorial, not evidence that all historical instruments offered its new note-off option. Remaining tutorial/audio not needed for the dialogue conclusion.

### S13. Using Slice Motion on Vocal Samples — Andy Avgousti / MPC-Tutor, MPC3.4+; displayed modification date questionable

URL: https://www.mpc-tutor.com/mpc3-tutorial-slice-motion-vocals/

Read: substantive worked tutorial, lines 13–117, from phrase isolation through slicing, restricted/random motion, envelope adjustment, recording and automation. It acknowledges a word fused to its predecessor, uses 32 equal regions for an intentional vocal stutter, restricts selectable ranges, softens clicks with envelopes, and records changing articulation/dynamics. Purpose: turn voice into rhythmic texture. No downloadable project/audio was loaded, and its metadata date was not trusted.

### S14. MPC Series: Standalone Mode Sampler Overview — Akai Professional support; undated

URL: https://support.akaipro.com/en/support/solutions/articles/69000838263-akai-pro-mpc-series-standalone-mode-sampler-overview

Read: complete substantive article, especially gain staging, recording modes, internal resampling and live Slice+ markers, lines 15–76. Manufacturer instructions show inserting boundaries while monitoring/recording, then editing the recorded MIDI arrangement. Purpose: capture decisions during listening and retain editability afterward. The article's absolute “without any loss” internal-resampling wording is not adopted as a general DSP guarantee. Modern firmware appearance varies, and these controls do not establish historical behavior.

### S15. MPC Sample User Guide: Pad Play and Tutorial — Akai Professional, 2026 web guide

URLs: https://www.akaipro.com/guides/mpc-sample/pad_play.htm and https://www.akaipro.com/guides/mpc-sample/tutorial.htm

Read: pad chopping controls and note-on behavior, lines 26–112; tutorial recording/sequence/editing passages, lines 31–145 and 174–210. Counted as one manufacturer guide, not two independent authorities. Threshold, equal-region and manual pad-tapped cuts are distinct modes; slices can be merged/split; note-on and one-shot differ; sequence changes can queue at an ending; recording quantization is optional. Modern 2026 hardware reference only. Manufacturer procedure is reliable for the documented behavior, not evidence that new automatic modes sound better.

### S16. J Dilla: Soul Under Control — Datwon Thomas, Platform.net, February 2001; preserved by Stones Throw, 7 May 2001

URL: https://www.stonesthrow.com/news/soul-under-control/

Read: production passages, lines 79–126, including Runnin, Fantastic Vol. 1 and the final habits question. First-person Dilla testimony: sixteenth-note rhythms and spending up to two hours listening to a pattern before choosing what it needs. This supports deliberate selection and sustained listening; it does not establish an exact quantization setting. No source audio was listened to.

### S17. J Dilla Still Lives Through — Scratch, May/June 2006; reproduced transcription

URL: https://www.sirpierre.se/2013/12/dagens-dilla-j-dilla-still-lives-through-scratch-magazine-mayjune-2006.html

Read: substantive Q&A through direct HTML. The original magazine scan was not inspected. This is reproduced primary testimony with weaker provenance and apparent transcription errors, so paraphrase cautiously. Dilla connects limited sampler memory with chopping, values imperfections in live recordings, describes a then-current sampled-groove-first process, and discusses MPC3000 familiarity and mono pads. A description of what he was doing lately is not a universal lifelong workflow. No hardware settings are inferred from garbled wording.

### S18. Questlove — RBMA Seattle 2005 lecture; host Monk One

URL: https://www.redbullmusicacademy.com/lectures/uestlove-phrenology-of-hip-hop/

Read: relevant transcript, lines 450–461; embedded media not consumed. Firsthand collaborator testimony: Questlove recalls Dilla retaining many dynamically different kicks, snares and hats from an extended break. His quantization answer moves from no to yes-and-no. This supports expressive alternates and selective timing choices, not universal quantization-off or a numerical Dilla offset.

### S19. Red Light Fever: T3 & Young RJ of Slum Village on J Dilla's Production — Robert Offner, ANTIGRAVITY, June 2014

URL: https://antigravitymagazine.com/column/red-light-fever-t3-young-rj-of-slum-village-on-j-dillas-production/

Read: whole short article, lines 17–32. T3 describes selective quantization and whole melodies built from small pieces; Young RJ says Dilla taught him. These are collaborator memories. The author's wabi-sabi framing is not Dilla's stated philosophy. Analog-warmth testimony does not establish a required analog processing chain.

### S20. Hip-Hop Still Runs On Dilla Time — Michaelangelo Matos interviews Dan Charnas, Rock and Roll Globe, 9 August 2022

URL: https://rockandrollglobe.com/hip-hop/hip-hop-still-runs-on-dilla-time/

Read: timing Q&A, lines 100–124. Charnas describes comparing waveforms with a grid: evenly spaced hats can feel swung because of an early snare. This is Charnas's research account and secondary evidence about Dilla, not Dilla's own explanation; underlying files and measurements were not inspected. It supports considering relationships among timing layers rather than reducing groove to quantize-off.

### S21. The Obscure J Dilla Beat Tape That Changed Music Forever — Dan Charnas, Pitchfork, 9 February 2023

URL: https://pitchfork.com/features/article/the-obscure-j-dilla-beat-tape-that-changed-music-forever/

Read: substantive historical discussion, lines 40–80, about Another Batch versus Donuts, evolving freehand programming, slowed samples and timing displacement. Later historical analysis; broad originality claims belong to the author. Not direct Dilla statements or an inspected production session.

## Annotated technical sources and access limits

The 14 families below group related API pages and subpages. Apple documents were first attempted through Sosumi, which returned internal errors, then read through official DocC JSON. For an Apple documentation path, the machine-readable equivalent is `https://developer.apple.com/tutorials/data` plus that path plus `.json`. API availability metadata establishes documented platforms; installed SDK/device execution remains a separate gate.

1. **Apple, legacy Speech family:** [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer), [supportsOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition), [requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition). Read overview, setup, availability metadata and complete property discussions. API authority; older generic overview includes server-service guidance, so use the explicit offline properties.
2. **Apple, legacy transcript segments:** [SFTranscriptionSegment](https://developer.apple.com/documentation/speech/sftranscriptionsegment). Read complete overview and metadata; timestamps/durations/confidence describe recognizer segments, not proven acoustic edit boundaries.
3. **Apple, new analyzer/transcriber:** [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), plus `isAvailable`, `supportedLocales`, `installedLocales` child docs. Read overview, asynchronous lifecycle, formats/resources and property abstracts/metadata. [Apple sample article](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app) metadata inspected only to compare platform lists, not treated as proof of visionOS exclusion.
4. **Apple, time attributes/assets:** [audioTimeRange](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption/audiotimerange), [TimeRangeAttribute](https://developer.apple.com/documentation/foundation/attributescopes/speechattributes/timerangeattribute), [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory). Read timing definitions and full asset installation/management overview; no timing-error guarantee or model size supplied.
5. **Apple, language tagging:** [NLTagger](https://developer.apple.com/documentation/naturallanguage/nltagger), [Identifying parts of speech](https://developer.apple.com/documentation/naturallanguage/identifying-parts-of-speech). Read overview/example explanation and platform metadata; tags are useful hints, not a semantic proof. Serialize use or isolate taggers per queue.
6. **ggml authors, whisper.cpp:** [README](https://github.com/ggml-org/whisper.cpp/blob/master/README.md), [MIT license](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE). Read platform/features, model/memory table, Core ML introduction and experimental word timestamps; upstream documentation/performance claims, no local benchmark.
7. **Argmax, WhisperKit/Argmax OSS:** [README](https://github.com/argmaxinc/argmax-oss-swift), [Package.swift](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Package.swift), [MIT license](https://github.com/argmaxinc/argmax-oss-swift/blob/main/LICENSE). Read OSS/commercial distinction, library products/platforms and timing capability; package declaration is stronger than an inference about visionOS packaging but still not build proof.
8. **OpenAI Whisper model authors:** [model card](https://github.com/openai/whisper/blob/main/model-card.md). Read model table, intended/evaluated use and limitations, including hallucinations and language/accent unevenness. Original model disclosure, not independent validation on archival dialogue.
9. **aubio authors, onset API:** [onset.h reference](https://aubio.org/doc/latest/onset_8h.html). Read detection behavior and threshold/silence/minimum interval/delay methods. DSP API authority, not recommendation to adopt its dependency or assume its license suits distribution.
10. **Ableton, Live Instrument Reference:** [manual](https://www.ableton.com/en/manual/live-instrument-reference/). Inspected oscillator/envelope and drum-sampler pitch-envelope sections. Vendor manual supports synthesis mechanisms; proposed voice settings are original.
11. **Ableton, Live Audio Effect Reference:** [manual](https://www.ableton.com/en/manual/live-audio-effect-reference/). Inspected compression/limiting cautions, reverb predelay and effect architecture. Vendor manual supports tradeoffs, not compulsory numerical presets.
12. **Kevin McHugh/iZotope, How to Mix Kick and Bass:** [tutorial](https://www.izotope.com/community/blog/how-to-mix-kick-and-bass). Read unmasking, arrangement/decay and frequency-selective ducking discussion; vendor tutorial with original audio examples, not blind listening evidence or a rule to retune AJ Hall.
13. **iZotope, 7 tips for mixing the low end:** [tutorial](https://www.izotope.com/community/blog/7-tips-for-mixing-the-low-end). Inspected kick/bass resonance and balancing discussion; corroborative vendor practice, no product purchase required.
14. **Versilian Studios/VSCO 2 CE:** [official library](https://versilian-studios.com/vsco-community/), [repository license](https://github.com/sgossner/VSCO-2-CE/blob/master/LICENSE), [sample tree](https://github.com/sgossner/VSCO-2-CE/tree/master/Strings/Solo%20Contrabass/Pizz). Read public-domain/CC0 statement/license and repository tree listing contrabass pizzicato notes/layers. No audio downloaded or auditioned; suitability/tuning remain qualification work.

Access exclusions: Sound On Sound's “Mix Tips: Kick & Bass” returned HTTP 403, so its search snippet is not counted as a read source. An older iZotope `/en/learn/mixing-kick-and-bass.html` URL returned 404; the current `/community/blog/` tutorial above was read. Spitfire's official redistribution guidance was read as a caution during discovery, but no LABS instrument is recommended or counted toward the 14 useful families; commercial-recording permission alone is insufficient evidence for bundling raw samples.

Additional craft access exclusions: Sound On Sound's Premier interview and sample-slicing article returned HTTP 403; snippets were discovery only. YouTube descriptions/chapter lists were not counted as watched demonstrations. The MPC3 vocal tutorial's displayed modification date conflicts with its version content and was not used for historical dating. No Every publications were used. No additional independently read sources are implied by references inside these interviews.

## Companion evidence and handoff boundary

The working evidence files (MPC practice evidence and local speech/audio evidence, 2026-11-19) were not kept in the repository. The main handoff includes their actionable findings and annotated sources so a single downloaded Markdown file remains usable without those siblings. The companion reports retain more intermediate reasoning; implementation decisions above supersede any different ordering proposed there.

The coding session should finish the acoustic bank/grammar increment and its acceptance comparisons before expanding semantic or DSP complexity. Its deliverable is a working extension to this engine with explicit fallback and device evidence, preserving the existing controls and the drummer's performance. This research handoff changes no application code, assets or deployed runtime.
