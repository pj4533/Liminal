# Liminal instrument sources: ranked shortlist (deduplicated, usable=true only)

Bass sources (upright, flatwound electric, FM and sub) are surveyed separately in [bass-and-pads/bass-sources.md](../bass-and-pads/bass-sources.md).

Survey of 2026-11-19 for D114. **Integrated in D114:** Osiris Piano (UC, vl1), Upright Piano KW (soft layer), VCSL Kawai grand and Folk Harp, Shinyguitar (acoustic and electric), Emilyguitar and the Martin HD28, alongside the FreePats Spanish classical guitar. See [Lo-Fi instrument recordings](../../lofi-samples.md) for exactly what is bundled. **Not yet integrated:** the chord-strum sets (Robohymn, Carbonthief), which would need a chord-sample playback path of their own rather than the single-note sampler (the guitar programs strum by stacking single notes instead), and everything else below. Fuchs & Möhr, KeyPleezer (CC BY-SA, which conflicts with the repository's licence), Freesound packs (login required) and Iowa MIS (anechoic, needs slicing) remain candidates only.

**Deduplication:** I merged the duplicate entries for Osiris, Shinyguitar, Emilyguitar, Black & Green, TEDAgame, Salamander, and the three University of Iowa MIS entries (piano, guitar, general).

**Rule for every pick:** downmix to mono, resample to 32 kHz, trim the leading noise and tail-fade. "Soft layer" means the lowest velocity layer listed.

**Credit lines:** each pick has a ready-to-paste line for `docs/lofi-samples.md`. For CC0 and public-domain sources the credit is a courtesy. For CC-BY and CC BY-SA sources it is a legal requirement, and you must also state that the files were modified: "downmixed to mono, resampled to 32 kHz, trimmed".

## A. Pianos (lo-fi, felt, upright, soft EP)

**1. Osiris Piano (Karoryfer Samples + Versilian Studios), v0.925**
- **License:** CC0 1.0. The repo LICENSE file says so, GitHub detects it as CC0-1.0, and the changelog has "Beta 0.923: CC0 license added".
- **Why:** it was recorded *una corda* (soft pedal) and very quiet, and the maker calls it a "quiet piano". It is the closest thing to a felt-style grand with a verified license.
- **URL:** https://github.com/sfzinstruments/Osiris_Piano/releases/download/v0.925/Osiris_Piano_0925.zip (459 MB, 16-bit FLAC)
- **Pull:**
  - Folder `UC` (noise-reduced, pedal up) and `UC-Sus` for a pedal-down variant.
  - Mic A or B, layer `vl1`.
  - About 8 roots, every 3–4 semitones from C2 to C6. The set is sampled on white keys only, so use C2, E2, A2, C3, E3, A3, C4, E4, A4, C5, E5, A5, C6.
  - Optional: the `UC-noisy` folder as a deliberately "old/tape" texture.
  - Trim the noise before each note onset.
- **Credit:** "Osiris Piano by Karoryfer Samples and Versilian Studios, CC0 1.0, github.com/sfzinstruments/Osiris_Piano"

**2. Fuchs & Möhr felt upright (Tom Guder, Polyphone 683 / 850)**
- **License:** public domain, in the author's own words on the primary source: "The soundfont is 'Public Domain'". He says the WAV pack is "3 layers, 16 bit, wav, stereo and public domain".
- **Caveats:** there is no formal CC0 deed, and German law does not fully recognise public-domain dedications. Before shipping, get a one-line CC0 confirmation from the author (YouTube @tomguder or a Polyphone PM) and archive the forum post as the provenance record.
- **Why:** it is a real felt upright, slightly out of tune. This is exactly the requested sound.
- **URL:** https://drive.google.com/file/d/1XbIZgTdKoR2KxIyKM-CkEweS3HI4ieHu/view (FuchsUndMoehrSamplesWAV16bit.zip, 619 MB). Downloading needs Drive's confirm token. Avoid the third-party reduced 33 MB version, which has no stated license.
- **Pull:**
  - The softest of the 3 layers, plus the middle layer as a second option.
  - Roots every minor third, keep about 8 (C2, F#2, C3, F#3, C4, F#4, C5, F#5).
  - Listen for room noise from the garden hut where it was recorded.
- **Credit:** "Fuchs & Möhr felt upright samples by Tom Guder, released into the public domain (polyphone.io/en/forum/your-creations/850)"

**3. Upright Piano KW (FreePats)**
- **License:** CC0 1.0. Both the FreePats page and the `readme.txt` / `cc0.txt` inside the archive say so.
- **Why:** a homely Kawai upright recorded in a living room, with room tone.
- **URL:** https://freepats.zenvoid.org/Piano/UprightPianoKW/UprightPianoKW-SFZ+FLAC-20220221.7z (33 MB, the full set with 2 velocity layers)
- **Pull:**
  - The soft layer from the full 2022 set.
  - About 7 roots at C and F# from C2 to C6.
  - Do not use the "small" set (loud `vH` layer only) or the "small bright" set.
- **Credit:** "Upright Piano KW, recorded by Gonzalo and Roberto, FreePats project (freepats.zenvoid.org), CC0 1.0"

**4. K18 Upright Piano (Rudi Fiasco)**
- **License:** CC BY 4.0, set by the author's own archive.org upload (licenseurl plus the description text).
- **Why:** an intimate close-miked upright with 6 velocity layers, plus key-release and pedal noises that add "old piano" character.
- **URL:** https://archive.org/download/K18UprightPiano/K18-Upright-Piano.tar.xz (424 MB). archive.org is slow, so fetch it in the background.
- **Pull:**
  - The `p` and `mp` layers (files named like `C4.p.wav`).
  - About 8 roots every minor third from C2 to C6.
  - A few release-noise samples.
  - Read the bundled `readme.txt` before committing; I did not check it.
- **Credit:** "K18 Upright Piano by Rudi Fiasco (archive.org/details/K18UprightPiano), CC BY 4.0 (creativecommons.org/licenses/by/4.0/). Modified: downmixed to mono, resampled to 32 kHz, trimmed."

**5. Greg Sullivan E-Pianos: Hohner Pianet T and Wurlitzer EP200 (sfzinstruments repack)**
- **License:** CC BY 3.0. The repo README says "with the author permission with the request for attribution", and the repo carries the full CC BY 3.0 LICENSE.
- **Caveat:** I could not read the author's own site, so the grant rests on what the repo maintainers say the author agreed to.
- **Why:** this is the only soft electric piano found with a redistributable license. The Pianet is woody, the Wurlitzer is mellow and close to a Rhodes.
- **URL:** https://github.com/sfzinstruments/GregSullivan.E-Pianos/archive/refs/heads/master.zip (21.5 MB, mono FLAC)
- **Pull:**
  - **Pianet T:** the `P` layer, about 6 roots. These are natural 14 s decays with clean tails.
  - **Wurlitzer:** the `pp` and `mp` layers. They are looped sustains, so honour the `smpl` loop points or add a release envelope, and carry over the SFZ's per-region tune offsets of −2 to −12 cents.
  - Skip the CP80, which is bright.
- **Credit:** "E-piano samples by Greg Sullivan (sullivang.net), SFZ mapping by kinwie / sfzinstruments, CC BY 3.0 (creativecommons.org/licenses/by/3.0/). Modified: resampled, trimmed."

**6. VCSL Kawai grand, plus the unused layers of pianos already bundled**
- **License:** CC0. This is the same repo Liminal already uses, so no new licensing work is needed.
- **Why:** it adds a softer grand colour than the Steinway B, plus softer velocities and round robins for the existing `yamaha` and `upright` families.
- **URLs:**
  - https://github.com/sgossner/VCSL/tree/master/Chordophones/Zithers/Grand%20Piano%2C%20Kawai/Sustains
  - …/Upright%20Piano%2C%20Yamaha/Sustains
- **Pull:**
  - Kawai `v1`/`v2`, about 7 roots. Note that the folder is flagged "Legacy", so compare it against the "Grand Piano, Kawai - Legacy" folder.
  - Yamaha Sustains `vl1`, `rr2` takes, as round robins.
  - Measure the actual pitch of each file before naming it by MIDI note; other VCSL sets are labelled an octave off.
- **Credit:** use the existing VCSL credit line.

**7. KeyPleezer LivingRoom Upright, Micro SFZ (Anders Eklöv)**
- **License:** CC BY-SA 4.0 for the audio, per `_License/License.md` inside the zip.
- **ShareAlike:** the converted WAVs must stay CC BY-SA 4.0. Keep them in their own folder with their own license notice, and say in the README that these files are not MIT. Use this only if the share-alike obligation is acceptable.
- **Why:** a vintage, intimate upright with pedal-on and pedal-off sets and a "muted" patch.
- **URL:** https://downloads.keypleezer.com/dl-free-version-micro-sfz/v100/livingroom-upright-piano-micro-sfz.zip (93 MB)
- **Pull:** the `p` layer, pedal off and pedal on, 6–8 roots.
- **Credit:** "LivingRoom Upright Piano (Micro SFZ) by Anders Eklöv / KeyPleezer (keypleezer.com), CC BY-SA 4.0. Converted to mono 32 kHz and trimmed; the modified files are also CC BY-SA 4.0."

**8. University of Iowa MIS Piano (Steinway B)**
- **License:** a written grant, not a named license: "may be downloaded and used for any projects, without restrictions", with "application developers" named as intended users. Commit the quoted statement and the access date (2026-11-19) next to the samples.
- **Why:** a clean, neutral grand that is chromatic and has 3 dynamics. Use it for the "grand" slot only, not as a lo-fi piano.
- **URL:** https://theremin.music.uiowa.edu/MISPiano.html (individual AIFFs, e.g. `.../Piano.pp.C4.aiff`)
- **Pull:** the `pp` layer, about 8 roots. Trim the silence at head and tail.
- **Credit:** "University of Iowa Electronic Music Studios MIS (Lawrence Fritts); piano performed by Evan Mazunik"

**9. Salamander Grand Piano V3 (Alexander Holm)**
- **License:** CC BY 3.0. The README, LICENSE and archive.org item all agree.
- **Why it ranks low:** a bright concert Yamaha C5. It needs a low-pass and tape treatment to fit.
- **URL:** https://freepats.zenvoid.org/Piano/SalamanderGrandPiano/SalamanderGrandPianoV3+20161209_44khz16bit.tar.xz
- **Pull:** velocity layers `v1`–`v4` only, about 8 roots, and keep the hammer-release noise.
- **Credit:** "Salamander Grand Piano V3 by Alexander Holm, CC BY 3.0. Modified: selected notes, mono, 32 kHz, trimmed."

**10. TEDAgame "88 piano keys, long reverb" (Freesound pack 25405)**
- **License:** CC0. Two sound pages say so, and the author writes "Consider it public domain". Check that every sound in the pack shows CC0 before bundling.
- **Why it ranks low:** a 60-year-old Steinhoff upright, detuned and dusty, which suits a secondary "character" piano. But it was recorded as MP3 and re-encoded to OGG, so it is lossy twice over, and its tails were artificially boosted to 200%.
- **URL:** https://freesound.org/people/TEDAgame/packs/25405/ (needs a Freesound login)
- **Pull:** every 3rd–4th key, trimmed to 3–4 s with a fade. Listen for codec swirl in the highs.
- **Credit:** "88 piano keys, long reverb by TEDAgame, Freesound pack 25405, CC0"

## B. Guitars (nylon, steel, clean electric/jazz)

**1. Karoryfer Shinyguitar (archtop jazz guitar, mic and magnetic pickup)**
- **License:** CC0 1.0 (LICENSE file, GitHub detects CC0-1.0). Its signature caveat applies only to the Sforzando bank XML, which we would not ship.
- **Why:** the best clean jazz-box tone found, in two parallel sets:
  - `Samples/acoustic`: the woody, unamplified sound through a microphone.
  - `Samples/electric`: the classic dark jazz-pickup tone.
- **URL:** https://github.com/sfzinstruments/karoryfer.shinyguitar/releases/download/v1.002/Karoryfer.Shinyguitar.v1.002.zip (368 MB). Individual files can also be fetched raw, e.g. `Samples/{acoustic|electric}/<note>_vl<n>_rr<n>_1.wav`.
- **Pull:**
  - From both sets: `vl1`/`vl2`, `rr1`–`rr2`.
  - Roots: e2, a2, c3, eb3, gb3, a3, c4, eb4, a4, c5.
  - A few `mute_*` and release samples.
- **Credit:** "Shinyguitar by Karoryfer Lecolds, played and mapped by D. Smolken, CC0 1.0"

**2. Karoryfer Emilyguitar (clean electric guitar, flatwound strings, recorded DI)**
- **License:** CC0 1.0, both in the repo and in the LICENSE inside the release zip.
- **Why:** flatwound strings give a round, dull attack that suits mellow comping. It needs a cab/room treatment and a low-pass because it was recorded direct.
- **Note:** the "chord" patches only layer the single-note samples, so Liminal can stack notes itself.
- **URL:** https://github.com/sfzinstruments/karoryfer.emilyguitar/releases/download/v1.001/Karoryfer.Emilyguitar.v1.001.zip (103 MB)
- **Pull:** the `p` and `mp` layers, `rr1`–`rr2`, about 8 of the 18 roots (e2, a2, c3, gb3, a3, c4, eb4, a4, c5).
- **Credit:** "Emilyguitar by Karoryfer Lecolds (D. Smolken), CC0 1.0"

**3. Martin HD28 steel-string acoustic (Jeff Learman, Discord SFZ GM Bank 026)**
- **License:** the SFZ header says "License: Creative Commons CC0". The author committed that file himself, and the bank's policy forbids NC licenses.
- **Why:** the cleanest CC0 steel-string guitar found. It is a warm dreadnought.
- **URL:** https://github.com/sfzinstruments/Discord-SFZ-GM-Bank/tree/master/Discord%20GM/Melodic/026-Acoustic%20Guitar%20(steel)
- **Pull:**
  - Roots: E2, Bb2, E3, Bb3, E4, B4, F5.
  - It has 1 velocity layer and no round robins, so add slight pitch, filter or start-offset variation to avoid a machine-gun effect on repeated notes.
  - Copy the CC0 header line into the credits as the provenance record.
- **Credit:** "Martin HD28 steel-string guitar samples by Jeff Learman, Discord SFZ GM Bank, CC0"

**4. quartertone ClassicalGuitar-multisampled (Freesound pack 11573) + ClassicalGuitarHarmonics (pack 11598)**
- **License:** CC BY 4.0. All 281 sounds are marked Attribution, and the pages I opened link to by/4.0.
- **Why:** a nylon guitar with 5 real velocity layers, plus a rare set of bell-like harmonics.
- **URLs:**
  - https://freesound.org/people/quartertone/packs/11573/
  - https://freesound.org/people/quartertone/packs/11598/
  - Both need a Freesound login.
- **Pull:**
  - MIDI roots 40, 45, 47, 50, 52, 55, 59, 64, 69, 76, at velocities v01–v03.
  - The files end in crossfade-looped tails (loop points in the header). Ignore the loop and fade each tail by hand.
  - 3–4 harmonics, e.g. 12th fret on strings 3–5.
- **Credit:** "Classical guitar samples by quartertone (freesound.org/people/quartertone), packs ClassicalGuitar-multisampled and ClassicalGuitarHarmonics, CC BY 4.0 (creativecommons.org/licenses/by/4.0/). Modified: trimmed, resampled to 32 kHz mono."

**5. University of Iowa MIS Guitar (Raimundo 118 nylon)**
- **License:** the same "any projects, without restrictions" grant as the MIS piano.
- **Why:** a second nylon guitar with pp, mf and ff dynamics, adding real dynamic layers alongside FreePats Spanish Classical. It is very dry (anechoic), so it needs a room.
- **URL:** https://theremin.music.uiowa.edu/sound%20files/MIS/Piano_Other/guitar/Guitar.mono.1644.1.zip (120 MB)
- **Pull:**
  - Slice single notes out of the chromatic runs per string using onset detection.
  - Roots: E2, A2, D3, G3, B3, E4, A4, at pp and mf.
- **Credit:** "University of Iowa EMS MIS (Lawrence Fritts); Raimundo 118 guitar played by Brian Penkrot, 2011"

**6. Karoryfer Black And Green Guitars (Gretsch / Hofner hollowbodies)**
- **License:** CC0 1.0.
- **Why it ranks lower:** the files are literally named "twang", so these are brighter and more rockabilly than jazz. Use them as a secondary clean electric.
- **URL:** https://github.com/sfzinstruments/karoryfer.black-and-green-guitars/releases/download/v1.000/Karoryfer_Black_And_Green_Guitars_1000.zip (482 MB)
- **Pull:**
  - Hofner Club ord at `p`/`mf`, `rr1`, about 6 roots, low-passed at about 3.5 kHz.
  - Skip the `fb_*` feedback files, the behind-the-bridge files, and the `f` layer.
- **Credit:** "Black And Green Guitars by Karoryfer Lecolds, recorded by Brian Wood, CC0"

**Minor single-note sources** (CC0, low priority):
- SpeedY Nylon Single Notes, Freesound pack 469: only a few open strings, so use it for accents and harmonics.
- josefpres "guitar tones" / "Random guitar notes 002": a cheap Strat, partly run through a harmonizer.

## C. Guitar phrases and strums

**1. Robohymn "quiet strat" chord series (Renoise forum)**
- **License:** CC0. Each set's `LICENSE.txt` reads "CC0, Public Domain", and `description.html` repeats it.
- **Why:** the best find for lo-fi chords. It covers extended chords (maj7, min7, maj9, min9, 11th, 13th, m13, sus4, plus maj and min). Each root comes as slow, medium and fast strums with about 10 s of ring, played on neck/middle pickups with the tone knob at about 4. The author says the set is "best suited to mellower stuff".
- **Caveat:** the samples are raw DI, so they need a low-pass at 3–4 kHz, compression and soft cab colouring.
- **URL base:** https://files.renoise.com/forum/downloads/Instruments/ with these folders:
  - `Robohymn-strat_major_7th_%28maj7%2C_M7%29_chords%2C_variable_strum/`
  - `…minor_7th_%28min7%2C_m7%29…`
  - `…major_9th…`
  - `…minor_9th…`
  - The other qualities follow the same pattern.
- **Pull:**
  - Unzip each `.xrni` and take the `SampleData/*.flac` files (48 kHz).
  - Use maj7, min7, maj9, min9 and m13 first.
  - Take medium and slow strums, about 4 roots per quality, and pitch-shift ±2 semitones from there.
- **Credit:** "Strat chord strums by robohymn (Renoise forum), CC0"

**2. SpeedY nylon chord packs (Freesound 472 Open Chords, 475 Extra Open Chords, 476 Bar Chord Style)**
- **License:** CC0, verified for all 106 sounds with the license filter.
- **Why:** real nylon up and down strums in many voicings. These 2005 home recordings need auditioning and slicing.
- **URL:** https://freesound.org/people/SpeedY/packs/472/ (and /475/, /476/; login needed)
- **Pull:** clean full-voicing down and up strums on about 8 common chords. Skip the slaps.
- **Credit:** "Nylon guitar chords by SpeedY (freesound.org/people/SpeedY), CC0"

**3. Carbonthief Strummed Guitar Chords (Renoise forum)**
- **License:** CC0, per its `LICENSE.txt`.
- **Why:** dark DI strums with 7–12 s of ring, all 12 major and 12 minor triads.
- **Caveat:** the noise floor is about −49 dB, so gate the tails.
- **URL:** https://files.renoise.com/forum/downloads/Instruments/Carbonthief-Strummed_Guitar_Chords/Strummed%20Guitar%20Chords.xrni
- **Pull:** all 24 FLACs are small, so take them and gate or fade the tails.
- **Credit:** "Strummed Guitar Chords by Carbonthief (Renoise forum), CC0"

**4. jon_s Acoustic Guitar strums (Freesound pack 33427)**
- **License:** CC BY 3.0 on all 12 sounds.
- **Why:** a soft steel-string Larrivée 000 with downstrokes and upstrokes. The chords are D, A and F with no third, plus 3 single notes you can add to make a chord major or minor.
- **URL:** https://freesound.org/people/jon_s/packs/33427/ (login needed)
- **Pull:** the soft down and soft up versions of all three chords, plus the A2, C#3 and F#3 notes.
- **Credit:** "Acoustic guitar strums by jon_s (freesound.org/people/jon_s/packs/33427), CC BY 3.0. Modified: resampled, trimmed."

**5. CC0 jazzy phrases on Freesound** (audition by ear; about 10 of the 30 are usable)
- **Which:** Sub-d pack 3031 (archtop ii–V–I cadences at 109 bpm) and FullMetalJedi pack 19836 ("Rozenbaum Chords Bossa" and "Dm Chord Variation" on nylon).
- **URLs:**
  - https://freesound.org/people/Sub-d/packs/3031/
  - https://freesound.org/people/FullMetalJedi/packs/19836/
- **Use:** occasional phrase drops, time-stretched like the archive chops.
- **Skip:** MinigunFiend (washy reverb) and Billyguiro (MP3 source).

**6. Lower-priority phrase sources** (CC0; phrase-player only, curate heavily)
- **godlesswonder GuitarStrum, Freesound pack 3056:** all 12 major and 12 minor triads at 120 bpm, Strat with chorus.
- **holizna lo-fi loops (packs 34856, 34857, 34268, 45568):** take only the "Lofi Guitar Loop EM 119 BPM" files and the plain "Lofi Piano Loop" files. Avoid the organ, vibes and synth loops.
- **BaDoink pack 30473:** recorded on a laptop mic, country-leaning. Consider only the NoFX takes ("Mi Amore", "Jazz Loop").
- **josefpres "Guitar loops":** take only the dry, drum-free takes.

## D. Strings and plucks

**1. D. Smolken Double Bass (1958 Otto Rubner), pizzicato**
- **License:** CC0 1.0.
- **Why:** a warm, round jazz upright with 4 round robins per note.
- **URL:** https://github.com/sfzinstruments/dsmolken.double-bass/releases/download/v1.001/DSmolken.double_bass.v1.001.zip (265 MB)
- **Pull:** from `pizz/`, the `p` and `m` dynamics, takes a–b, at roots C1, G1, D2, A2, E3.
- **Credit:** "Double bass samples by D. Smolken (1958 Otto Rubner), CC0"

**2. VSCO 2 CE articulations not yet bundled**
- **License:** CC0. This is the repo already in use; pin commit 440300901dfe.
- **Pull:**
  - Solo Contrabass `Pizz` at `v1`.
  - Cello Section `susvib` at `v1`, as a soft pad.
  - Violin Section `Pizz` at `v1`, low-passed.
  - Contrabass `SusNV` at `v1`.
- **URL:** https://github.com/sgossner/VSCO-2-CE/tree/master/Strings

**3. Karoryfer x Bigcat Cello (performed by Kamila Borowiak)**
- **License:** CC0 1.0. Do not ship its `.nki` files or the WIPS scripts.
- **Why:** an intimate solo cello. The pizzicato makes a soft counter-melody, and the no-vibrato sustains make low pads.
- **URL:** https://github.com/sfzinstruments/karoryfer-bigcat.cello/releases/download/v1.001/Karoryfer_Bigcat_cello.v1.001.zip (133 MB)
- **Pull:** from `Samples/pizzcato`, takes _1 and _2, at about 6 A and C roots. From `Samples/sus`, 4 roots.
- **Credit:** "Karoryfer x bigcat cello, performed by Kamila Borowiak, Karoryfer Lecolds & bigcat instruments, CC0"

**4. VCSL Folk Harp (Etherealwinds Harp II CE)**
- **License:** CC0.
- **Why:** a softer partner to the bundled KSHarp.
- **Caveat:** the files sound an octave above their labels; `C4` measures about 523 Hz.
- **URL:** https://github.com/sgossner/VCSL/tree/master/Chordophones/Composite%20Chordophones/Folk%20Harp
- **Pull:** layer `v2`, files labelled C3, F#3, C4, F#4, C5.

**5. Cithara Barbarica (10-string lyre, sfzinstruments)**
- **License:** CC0 1.0.
- **Why:** the warmest of the plucks here. Its energy above 3 kHz sits about 14 dB below the overall level, and the noise floor is about −104 dB.
- **Caveat:** it is tuned to the fixed set E, F#, G#, B, C#, D#, and needs about +9 cents of correction.
- **URL:** https://github.com/sfzinstruments/cithara-barbarica/releases/download/v1.000/cithara-barbarica_v1000.zip
- **Pull:** the finger and muted-finger articulations, rr1–rr2, on all 10 strings. Skip the nail and sul tasto plucks.
- **Credit:** "Cithara Barbarica, sfzinstruments, CC0"

**6. VCSL Kalimba, Tanzania set**
- **License:** CC0.
- **Why:** the soft kalimba the user would accept. It peaks at −13 dBFS and rings for about 5 s.
- **URL:** https://github.com/sgossner/VCSL/tree/master/Idiophones/Plucked%20Idiophones/Kalimba%2C%20Tanzania
- **Pull:**
  - About 10 tines, with a per-file cents correction measured at import.
  - Low-pass at 3–4 kHz.
  - Skip the Kenya set (hot), the mbira sets (buzz) and the Nyunga Nyunga.

**7. FreePats Ukulele (Flight Fireball tenor, recorded by Mateusz Dąbrowski)**
- **License:** CC0 1.0.
- **Use:** a high pluck or arpeggio voice from C4 to C6, plus `chuck.wav` as a muted-strum accent. Apply the SFZ's tune offsets of −11 to +3 cents.
- **URL:** https://github.com/freepats/ukulele1/releases/download/2026-08-11/Ukulele-SFZ+WAV-20260811.7z
- **Credit:** "Ukulele samples by Mateusz Dąbrowski / FreePats, CC0"

**8. VCSL Strumstick, finger plucks**
- **License:** CC0.
- **Why:** a woody, dulcimer-like colour.
- **URL:** https://github.com/sgossner/VCSL/tree/master/Chordophones/Composite%20Chordophones/Strumstick/Finger
- **Pull:** layers `vl1`/`vl2` at D2, A2, D3, G3, D4, G4.

**9. University of Iowa MIS cello and violin pizzicato**
- **License:** the same MIS grant as above.
- **URL:** https://theremin.music.uiowa.edu/MIS-Pitches-2012/MISCello2012.html
- **Pull:** the 2012 per-note files, e.g. `Cello.pizz.pp.sulC.C2.stereo.aif`, at pp.

**10. Colour plucks only** (CC0, VCSL / sfzinstruments)
- **Dan Tranh:** use `Normal` at mf with a low-pass. It is pentatonic and has a strong folk character.
- **Hungarian prime zither:** use the melody strings only. Its strums carry a G drone, so they lock to G-centred keys.
- **Skip FreePats Concert Harp:** it is the same K. Smith harp that is already bundled from VSCO.

## Rejected but notable

- **Headroom Piano / Intimate Piano (Bengt Nilsson, sfzinstruments):** the CC BY 4.0 LICENSE was added by the repo maintainer. The author's only recorded condition was permission to make the SFZ mapping if the instrument name is kept. The original Kontakt freebie had no stated terms. It is a high-quality, warm grand, so it is worth writing to bengtnilsson.com for written confirmation.
- **Splendid Grand Piano (Akai Steinway):** the "public domain" claim is secondhand. Akai's original zip is gone (404), and the people who redistributed it called the rights "undefined".
- **The Indigo Upright Piano (Softy107):** the only terms are an informal "free to use as long as credit is given". There is no grant to redistribute, and GitHub shows no license. It is also deliberately out of tune.
- **FreePats FSS Steel-String Guitar:** GPL-3.0+. Its exception covers musical compositions, not software, so it adds copyleft obligations. FreePats itself has deprecated this license. Use the CC0 Martin HD28 instead.
- **Signature Sounds Spanish and Folk Guitar Loops:** a self-declared CC0 that includes unsourced "CC0 found files". There is no provenance, and there is no direct download (only a checkout flow).
- **Fuchs & Möhr reduced 33 MB SF2 (third party, ziyametedemircan):** no license of its own. Use the author's raw WAV pack instead.
- **Ableton free packs, Spitfire LABS, Pianobook (default terms), Splice, and most freeware Kontakt libraries:** their EULAs let you use the sounds in your own music but forbid redistributing the samples themselves. That rules them out for a public repo. This is a category-level rejection taken from the brief; I did not re-read each EULA in this pass.

## Practical notes

- **Freesound sources** (quartertone, SpeedY, jon_s, TEDAgame, the phrase packs) need a free login or an OAuth2 API token for the original files. The MP3/OGG previews are lossy and must not be bundled.
- **Share-alike:** only KeyPleezer carries a share-alike obligation. All the CC-BY items need attribution plus a "modified" note in `docs/lofi-samples.md`.
- **Order to integrate first, for the user's stated priorities:**
  1. Osiris (UC vl1)
  2. Upright KW (soft layer)
  3. Shinyguitar (acoustic and electric)
  4. Robohymn maj7/min7/maj9/min9 strums
  5. Martin HD28
  6. quartertone nylon
  7. D. Smolken pizz bass
  8. Pianet T
- **Fuchs & Möhr** goes in once the author confirms CC0.
