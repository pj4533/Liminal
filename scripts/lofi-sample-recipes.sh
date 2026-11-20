#!/bin/bash
# Rebuild the Lo-Fi lead sample groups added on 2026-11-19 (D114) from their CC0 sources.
#
#   scripts/lofi-sample-recipes.sh <group> <source-dir> [out-dir]
#
# Download and extract each source yourself into its own empty directory (never run anything
# from it); docs/lofi-samples.md lists the exact URLs and pinned commits. <source-dir> is the
# folder that directly holds the recordings named below.
#
#   group     source                                                          folder
#   kawai     VCSL c1ea7bcc                                                   Chordophones/Zithers/Grand Piano, Kawai/Sustains
#   osiris    sfzinstruments/Osiris_Piano 18c6afcc                            UC/A
#   uprightkw FreePats UprightPianoKW-SFZ+FLAC-20220221.7z                    samples
#   folkharp  VCSL c1ea7bcc                                                   Chordophones/Composite Chordophones/Folk Harp
#   nylon     FreePats SpanishClassicalGuitar-SFZ+FLAC-20190618.7z            samples
#   steel     sfzinstruments/Discord-SFZ-GM-Bank 7a9c478f                     Discord GM/Melodic/026-Acoustic Guitar (steel)
#   archtop   sfzinstruments/karoryfer.shinyguitar 57243cca                   Samples/acoustic
#   jazzbox   sfzinstruments/karoryfer.shinyguitar 57243cca                   Samples/electric
#   flatwound sfzinstruments/karoryfer.emilyguitar b4920dc6                   notes
#
# Every pair is SOURCE-NAME=MIDI with MIDI the measured concert pitch (prepare refuses a file
# more than 50 cents away). VCSL Kawai, VCSL Folk Harp and Osiris files sound an octave above
# their labels, so a file labelled C2 becomes MIDI 48. To add a group, add a case and run
# `scripts/prepare-lofi-samples.py measure` on the result.
set -euo pipefail
group="$1"
src="$2"
out="${3:-$(cd "$(dirname "$0")/.." && pwd)/Liminal/Audio/Lofi/InstrumentSamples}"
prep="$(cd "$(dirname "$0")" && pwd)/prepare-lofi-samples.py"
args=()
# add PATTERN PAIR...: PATTERN contains {} for the source name; an optional :LAYER follows MIDI.
add() {
  local pattern="$1"; shift
  local pair name root
  for pair in "$@"; do
    name=${pair%%=*}; root=${pair#*=}
    args+=(--source "$src/${pattern//\{\}/$name}=$root")
  done
}
case "$group" in
  kawai)
    # Softest layer (v1) is the default layer 2; v2 is the accent layer 3.
    add 'GPiano_sus_{}_v1_rr1_Player.wav' C2=48 E2=52 G#2=56 C3=60 E3=64 G#3=68 C4=72
    add 'GPiano_sus_{}_v2_rr1_Player.wav' C2=48:3 E2=52:3 G#2=56:3 C3=60:3 E3=64:3 G#3=68:3 C4=72:3
    opts=() ;;
  osiris)
    # Una corda, pedal up, noise-reduced, mic A, softest layer: the felt-like quiet grand.
    add 'Piano_UC_MicA_{}_vl1.flac' C2=48 E2=52 A2=57 C3=60 E3=64 A3=69 C4=72
    opts=() ;;
  uprightkw)
    # Soft (vL) layer of the living-room Kawai upright. D#3 is skipped for its 2-5 kHz ring.
    add '{}vL.flac' C3=48 F#3=54 A3=57 C4=60 D#4=63 F#4=66 A4=69 C5=72
    opts=() ;;
  folkharp)
    # Second velocity layer. 5 kHz roll-off.
    add 'EWHarp_Normal_{}_v2_RR1.wav' C2=48 E2=52 G#2=56 C3=60 E3=64 G#3=68 C4=72
    opts=(--lowpass 5000) ;;
  nylon)
    add '{}.flac' C3=48 E3=52 G3=55 B3=59 D4=62 F4=65 A4=69 B4=71
    opts=() ;;
  steel)
    # Martin HD28 dreadnought, one layer. B4 and D5 ring under 1.3 s, so 68 covers the top.
    # The brightest guitar here: a fourth-order 3.5 kHz roll-off keeps its pick off the 2-5 kHz band.
    add 'MartinGM2_{}_1.wav' 046_Bb2=46 052__E3=52 055__G3=55 058_Bb3=58 061_Db4=61 064__E4=64 068_Ab4=68
    opts=(--lowpass 3500 --order 4) ;;
  archtop)
    # Shinyguitar through the microphone: the woody, unamplified archtop. A4 is skipped (bright).
    add '{}_vl1_rr1_1.wav' a2=45 c3=48 gb3=54 a3=57 c4=60 eb4=63 gb4=66 c5=72
    opts=(--lowpass 6000) ;;
  jazzbox)
    # Shinyguitar's magnetic pickup: the dark jazz tone.
    add '{}_vl1_rr1_2.wav' a2=45 c3=48 gb3=54 a3=57 c4=60 eb4=63 gb4=66 c5=72
    opts=(--lowpass 5000) ;;
  flatwound)
    # Emilyguitar, flatwounds recorded direct with every knob on ten: softest layer, darkened
    # toward a small amp with a fourth-order 3.5 kHz low-pass.
    add '{}_p_rr1.wav' a2=45 eb3=51 a3=57 c4=60 eb4=63 gb4=66 c5=72
    opts=(--lowpass 3500 --order 4) ;;
  *)
    echo "unknown group: $group" >&2
    exit 2 ;;
esac
python3 -I "$prep" prepare --group "$group" --duration 2.4 --out "$out" ${opts[@]+"${opts[@]}"} "${args[@]}"
