# Strummed and plucked instrument samples: survey (2026-11-22)

> Status: input to D128 (`docs/decisions/music.md`). Outcome: only the Black And Green Hofner (Hollowbody Soul) was added (`docs/lofi-samples.md`); the Gretsch from the same library was rejected for hiss; Kayageum, Robohymn and the muted strokes were deferred. The candidates were downloaded outside the repository and the analysis scripts were scratch tools that are not kept.

Scope: openly licensed recordings that would give Liminal's Lo-Fi guitars more strummed and RZA-style hook material. The bar is dusty, warm and tucked into the mix. Prior work read first: `docs/research/instrument-sources.md`, `docs/research/lofi-instrument-qualification.md`, `docs/lofi-samples.md` and D114 in `docs/decisions/music.md`.

Already bundled, all vl1/rr1 single notes: FreePats nylon, Martin HD28 steel, Shinyguitar mic and pickup, Emilyguitar flatwound. D114 rejected FSBS Clean #2 as too bright. The chord-strum sets (Robohymn, Carbonthief) were left as candidates because they need a chord playback path.

## How the audio was checked

Candidates were downloaded to a scratch folder and analysed with throwaway scripts (FFmpeg decode, numpy). They measure:

- format, peak level, body level (first 75 ms after the onset), attack, and the time to fall 20 dB and 40 dB;
- noise floor: the 3rd-percentile 5 ms RMS, and the spectrum of the quietest 0.5 s;
- pitch (harmonic product spectrum);
- brightness as the 2–5 kHz energy share in the first 0.5 s, the metric D114 used. Its reference points: bundled programs run −25 to −44 dB, Steel is −21 dB, and the rejected FSBS Jazz was −11 dB;
- clipping runs, and strum onset spread from spectral flux.

Nobody listened to anything. Every "vibe" verdict below is a judgement from these measurements and the instrument's known character, so treat each one as a shortlist for a listening pass. Freesound originals need a login; I measured their HQ MP3 previews only, so noise-floor figures for those are approximate.

## Ranked shortlist

### 1. Shinyguitar, the unused layers: round robins, velocities and muted strums (already licensed)
- **URL:** https://github.com/sfzinstruments/karoryfer.shinyguitar (pin 57243cca, as bundled), files under `Samples/acoustic/` and `Samples/electric/` (the electric files end in `_2.wav`).
- **License:** CC0 1.0 (the `LICENSE` file). The readme reads: "This instrument is open source, and you can do whatever you want with it". Its signature caveat covers only the bank XML.
- **Contents:** 17 roots (E2 to C6, a minor third apart), 4 velocity layers and 4 round robins per root in both the microphone and pickup sets, 44.1 kHz/24-bit mono. Extra articulations:
  - `mute_string1`–`6`: a single damped string, 5 round robins each;
  - `mute_strings1`–`4`: damped strums across string groups, 5 round robins, 0.47 s;
  - `release`: 5 round robins per root;
  - `perc_1`: clipped, see below.
- **Measured:**
  - Notes, c3 vl1 rr2/rr3: −81 to −84 dB floor, 15–30 ms attack, −20 dB at 1.5 s, −40 dB at 3.6–3.8 s. 2–5 kHz share −54 to −56 dB (the darkest material found). Pitch −6 c, the same on every take.
  - vl2/vl3: 2–5 kHz share −46 and −39 dB, peaks 7–9 dB hotter.
  - Muted strums: 2–5 kHz share −15 to −27 dB (short, bright chucks), floor −78 to −107 dB, no clipping. The electric chucks are normalised to −0.0 dBFS but not clipped (one sample at maximum).
  - `perc_1_rr1`: clipped (an 18-sample run at full scale). Skip it.
- **Why first:** a real strum needs a different take on each string, or the stacked notes phase together. rr2–rr4 provide that at no licence cost. `mute_strings*` provides the damped "chk" ghost stroke between hook stabs, which is the most Wu-Tang thing in any free set. Low-pass the chucks at about 3 kHz and play them very quietly.
- **Size:** about 0.3 MB per prepared note at the existing 32 kHz mono 2.4 s recipe. Adding rr2–rr3 for 8 roots × 2 sets, plus 4×2 mutes, is about 6 MB.
- **Vibe:** pass. This is the instrument already bundled, so it is guaranteed to match.

### 2. Emilyguitar, muted strokes and round robins (already licensed)
- **URL:** https://github.com/sfzinstruments/karoryfer.emilyguitar (pin b4920dc6), files `noises/muted1–5_rr1–5.wav` and `notes/*_p_rr2.wav`.
- **License:** CC0 1.0 (`LICENSE`).
- **Contents:** 18 roots at p/mp/mf/f with round robins. The `noises/` folder holds 5 muted-stroke groups × 5 round robins, plus fingering and pick-rest noises; `release/` holds 72 files. 44.1 kHz/24-bit, recorded DI on flatwounds.
- **Measured:** muted strokes are 0.2–0.4 s with a −104 to −117 dB floor; `muted1` reaches 0.0 dBFS once but is not clipped. 2–5 kHz share −14 to −32 dB. Notes c4 p rr2: −27 dB 2–5 kHz share, pitch −1 c, but the file is cut at 4.2 s while still ringing (about −50 dB), so a tail fade is needed. That fade is already in the recipe.
- **Why:** dull flatwound chucks pair with the bundled `flatwound` program for dead-string comping stabs.
- **Vibe:** pass for the mutes. The notes are already bundled.

### 3. Robohymn "quiet strat chords": real recorded strums in extended voicings (new playback path)
- **URL:** https://files.renoise.com/forum/downloads/Instruments/ in the folders `Robohymn-strat_{minor_7th,major_7th,major_9th,minor_9th,minor_13th,11th,13th,sus4,major,minor}…_variable_strum/`.
- **License:** `LICENSE.txt` reads "CC0, Public Domain", and `description.html` repeats it.
- **Contents per quality:** the .xrni is a zip. It holds 12 roots (labelled F2–E3) × slow/med/fast strums, 12 upper-octave voicings (labelled F3–E4) and about 46 "Recorded Sample" squeak and mute noises (min7). The audio is 48 kHz mono FLAC (32-bit float), 6–14 s rings. The min7 set is 52 MB, maj7 45 MB.
- **Measured (min7, maj7):**
  - Strum spread from flux onsets: slow 590–800 ms across 5 strings, med 210–310 ms, fast about 50 ms. The upper voicing (C4 label) spreads about 140 ms.
  - Peaks −10 to −16 dBFS, no clipping. Floor −62 to −85 dB, except maj7 F2 med at −55 dB.
  - The quiet regions have peaks at 82–83 Hz, which is the sympathetic open low E rather than mains hum.
  - 2–5 kHz share: low-voiced slow/med strums −33 to −43 dB, fast strums and upper voicings −21 to −30 dB.
  - Tuning: the whole guitar is sharp by +4 to +16 c (about +10 c on average), so each file needs a measured correction.
  - Labels: the HPS reading for "C3" is C2 (+13 c), but this detector jumps octaves (the "A2" min7 also reads an octave low while the maj7 roots read at their labels), so measure each root before naming it.
- **Why:** these are the only CC0 strums with jazz extensions (m7, maj7, m9, maj9, m13), which are the harmony of boom bap and lo-fi. Medium and fast strums are the right speed for a hook stab. The author: "best suited to mellower stuff… raw direct input samples… need EQ and compression".
- **Caveats:**
  - The voicings are fixed, so they only fit when the score's chord quality matches. D114 rejected the dedicated chord sampler for exactly this reason. Use them as an occasional accent where the chord is m7/maj7/m9, transposed no more than ±2 semitones.
  - DI: apply a low-pass at 3–4 kHz, gentle compression and a soft cab or room.
  - Drop the slow strums (too slow for the grid) and the random squeak noises.
- **Vibe:** pass, conditional on the DI treatment. Integrating it is a bigger lift.

### 4. Kayageum (gayageum, Korean 23-string zither), spt3125: the Eastern string
- **URL:** https://freesound.org/people/spt3125/packs/1534/ (sounds 24551–24573, one per string, C2–D5 white keys).
- **License:** each sound page shows Creative Commons 0 (`creativecommons.org/publicdomain/zero/1.0/`).
- **Contents:** 23 single strings plucked "medium-loud with finger, allowed to decay", 44.1 kHz/32-bit stereo, 4–11 s. Recorded with "stereo pair of oktava mk012 mics overhead, XY-ish" (2006). Diatonic C major, so other keys need ±1-semitone pitching from a neighbour string.
- **Measured (HQ previews, 8 strings):**
  - Pitch within −2 to +6 c on A2, C3, A3, C4, A4, C5 and D5. D2 is −13 c.
  - Low and mid strings are warm: 2–5 kHz share −37 to −46 dB, −20 dB at 0.3–1.6 s, −40 dB at 2.7–3 s. The top strings (A4 to D5) are −19 to −22 dB and short (0.5–1.5 s).
  - The tails are gated to digital silence after about 3 s, so they need a tail fade.
  - The previews peak at +1 to +2.5 dBFS. The originals are 32-bit float and probably not clipped, but this must be checked on the originals after logging in.
- **Why:** RZA's Eastern-string colour (koto- and guzheng-like plucks over drums) without the bright twang of the VCSL Dan Tranh. It sits in the guitar register and is warm. No CC0 koto, shamisen or guzheng multisample exists; the kayageum is the same zither family.
- **Use:** a sparse two-to-four-note hook pluck, low-passed, never a strum bed. Limit it to the C2–A4 strings.
- **Caveats:** downloading needs a Freesound login (or an OAuth token). The recording is from 2006, so audition the originals for room noise first.
- **Vibe:** probable pass. It needs a listening check before adoption.

### 5. Black And Green Guitars: Hofner Club p layer and staccato stabs
- **URL:** https://github.com/sfzinstruments/karoryfer.black-and-green-guitars (`Samples/black/ord/twang_*_p_rr*`, `Samples/black/stac/staccato_*_rr*`).
- **License:** CC0 1.0 (`LICENSE`, GitHub CC0-1.0). The readme reads: "Royalty-free for all commercial and non-commercial use."
- **Contents:** black (Hofner) has 430 ord, 188 stac, 188 release and 66 behind-the-bridge files. Green (Gretsch) has ord and hammer. Round robins: 2 at p, 4 at mf/f. 44.1 kHz/24-bit mono.
- **Measured:**
  - Files sound an octave below their label (`c4` measures C3 −6 c).
  - Hofner p: 2–5 kHz share −43 dB, short (−40 dB at 1.4 s).
  - Hofner mf: −28 dB.
  - Staccato: 0.86 s, a 0.2 s choke, −25 dB 2–5 kHz share, −96 dB floor.
  - Gretsch p: −47 dB, a 4.5 s ring.
- **Why:** the staccato stabs are real choked notes, the "played off the drums" short hits that a sampled soul guitar gives. A real choke sounds better than an enveloped long note.
- **Vibe:** pass for Hofner p and staccato, low-passed. Skip mf/f "twang", fb and btb, as the earlier survey said.

### 6. University of Iowa MIS guitar (nylon, per-string chromatic runs)
- **URL:** https://theremin.music.uiowa.edu/MISguitar.html (for example `Guitar.pp.sulG.G3B3.stereo.aif`, `Guitar.mf.sulA.C3B3.stereo.aif`).
- **License:** the MIS grant: "may be downloaded and used for any projects, without restrictions". This is a grant, not a named licence, as noted in the earlier survey.
- **Contents:** each string is played chromatically at pp, mf and ff, 96 kHz/24-bit stereo. Each file is a run of notes with gated silence between them, so it needs onset slicing.
- **Measured:** the pp sulG run peaks at −16 dBFS. Between notes it is gated to −113 dB, and the quiet regions show room rumble at 47–55 Hz. The mf sulA run has a 2–5 kHz share of −21 dB, pp sulG −39 dB.
- **Why:** the same pitch is available on different strings, so a strum can be voiced as a guitarist would play it. It also has real pp dynamics. It is a second nylon, so it is lower priority than material for guitars already in the bank.
- **Vibe:** pass at pp, after a room or reverb treatment (the recording is anechoic).

## Rejected (with reasons)

| Candidate | Licence | Reason |
| --- | --- | --- |
| Carbonthief Strummed Guitar Chords (Renoise) | CC0 | Plain major and minor triads only, so no 7ths or 9ths. Brighter than Robohymn (2–5 kHz −19 to −25 dB). Files end while still ringing at about −50 dB. Robohymn does the same job better. |
| FreePats Ukulele (tenor, 2026-08-11) | CC0 | The recording is clean: 24-bit, ±6 c, floor −61 to −71 dB, high-passed at 190 Hz for fridge noise, plus a `chuck` mute. But it covers C4–C6 only, sustains just 1–3 s, and upper notes measure −17 to −19 dB in 2–5 kHz. A ukulele reads twee or "uplifting ad" rather than dusty. Fails the vibe bar. |
| VCSL Dan Tranh | CC0 | Bright and twangy: 2–5 kHz −17 to −19 dB typical, −9 dB on the F#4 label. Labels are inconsistent: `B1` and `b2` both sound B3, other files sound an octave above their label, and `C#3` is +39 c. It is pentatonic (B C# D# F# G#). The kayageum covers this role more warmly. |
| Hungarian prime zither (sfzinstruments) | CC0 | It has real down and up strums, but over G drones, so it locks to G. The melody strings sit at A4–A6, too high. |
| Discord GM 105-Sitar (Dr. N. B. Raikar) | CC0 | The SFZ says "created for testing purpose only". Measured pitch drifts +3 to +27 c and does not match the mapped key centres; the files are 16-bit stereo. A sitar is also a cliché colour. |
| Discord GM 025/027/028/029/106/107/108 | n/a | Placeholder `*sine` SFZs with no samples. |
| RutgerMuller koto and shamisen improv sessions (Freesound) | CC0 | 10–13 minute amateur improvisations, pentatonic, recorded with the recorder under the instrument. They would need note slicing, and the playing is not usable as hook material. |
| TW!NGTWANG guzheng and koto (itch.io) | none stated | No licence text on the page. The chromatic expansion is paid. |
| Vanyamba "Analog Shamisen", brotherandroid Suiko shamisen (Freesound) | n/a | Synthesized or ROMpler, not recorded instruments. |
| Zeograd Telecaster, Les Paul and Jaguar set (Renoise) | GPL | Converted from FlameStudios GPL samples, the same copyleft problem as FreePats FSS. This is a pity, because it has a Telecaster neck pickup and muted fifths. |
| FlameStudios Kay 5-String Banjo | GPL (`LICENSE.txt`) | Copyleft. The readme reports clipping and noisy samples. A banjo also fails the vibe bar. |
| ganjo (6-string guitar-banjo) | CC0 | Banjo twang does not fit dusty lo-fi. |
| Terkelsen Mandolin, Ovation Guitar, Damien's Funky Guitar, Picked Lapharp (sfzinstruments) | none | No licence file, only a GigaSampler conversion credit. |
| FreePats FSBS Clean #1, Clean #2 and Direct | CC0 | Bridge pickup only. D114 measured Clean #2 at about 15 dB brighter than everything else. |
| Philharmonia guitar, mandolin and banjo | custom | Must not be redistributed "as is" (as samples or as a sampler instrument). Shipping them in the app would breach that. |
| Viola Caipira (Brunobrgs, Renoise) | custom | "Distributing/selling the samples or the xrni file is forbidden." |
| Open String Guitar (tildesounds, Shortcircuit XT) | CC0 | Open strings only (6 pitches × 3 velocities), so the range is too narrow. |
| donkey tugger's Encore and Epiphone acoustics (KVR) | informal | "happy for you to do whatever you want with them" is not a written licence; the files are on Google Drive. Ask the author first. |
| MDM Classical Guitar and other Pianobook packs | Pianobook T&C | The default terms forbid redistributing the samples. |
| quartertone ClassicalGuitar-multisampled | CC BY 4.0 | Still valid, but it is a third nylon and brightish (2–5 kHz −16 to −20 dB on the previews), with looped 3.1 s tails. Not a priority. |
| jon_s soft steel strums (pack 33427) | CC BY 3.0 | Warm (soft down strum 2–5 kHz −28 dB, floor about −73 dB). But it has only three chords, all without thirds (D, A, F), so it is too limited. Keep as a fallback steel strum. |
| SpeedY nylon chord packs 472/475/476 | CC0 | Single strums in 28 s files, gated after about 3–10 s. Clean on the previews (floor about −94 dB). Fixed open-position triads, and it duplicates the bundled nylon's colour. Lower priority than Robohymn. |

## Recommendations (as made before the build; see the status note for what happened)

1. **Pull more layers from Shinyguitar and Emilyguitar first.** Both are already bundled, licensed and on-vibe. Better strums come from rr2–rr4 per string, the vl2 accent layer, and the `mute_strings*` and `muted*` chucks. A "strum" in the existing note-stacking ornament path should use a different round robin per string and an occasional muted chuck on an off-beat sixteenth, played off the drums, and nothing else.
2. **Add Robohymn m7/maj7/m9/maj9, med and fast strums, as a separate accent path.** Use it only where the score chord matches, transposed no more than ±2 semitones, with the DI treatment. This decides whether a chord-sample path is worth building.
3. **Add the Kayageum as one sparse "Eastern pluck" program.** It needs a Freesound login and a listening pass on the originals.
4. **Add the Hofner staccato** as a choke articulation for the short hook stabs.
5. **Do not add** ukulele, banjo, sitar, Dan Tranh, the zither or any GPL guitar.

Nothing from this survey was added to the repository except the Hofner group.
