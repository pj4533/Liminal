"""Loudness-matched audition files for human listening (24-bit WAV, -16 LUFS, true peak at most -1.0 dBTP).

Written to CAPTURE/report/auditions by `mix-report.py --auditions`:

  master.wav                  the candidate master
  baseline-master.wav         the baseline master over the same bars (with --baseline)
  solo-<section>-bars1-16.wav each of the seven sections alone, bars 1 to 16
  dialogue-in-context.wav     dialogue at full level, every other section 6 dB down
  return-theme-takeN.wav      the theme phrase followed by its return, from the master
"""

import struct
from pathlib import Path

import numpy as np
from scipy import ndimage
from scipy import signal as sps

from .audio import SECTION_ORDER, db20
from .loudness import integrated_lufs, sub_block_ms, true_peak_db

TARGET_LUFS = -16.0
CEILING_DBTP = -1.3  # leaves 0.3 dB under the -1.0 dBTP requirement for 24-bit rounding and meter differences
SECTION_NOTES = {
    "drums": "Kick and snare weight, the take's swing, no clicks at the loop. The kick should punch without the sound turning to mush.",
    "bass": "Note starts landing with the kick, three distinct voices over the section, no boom or rattle below the kick's body.",
    "mids": "Texture and chord stabs: audible answers between melody notes, a few different articulations, nothing muddy under 250 Hz.",
    "lead": "The melody: clear note starts, a theme you could hum back, not buried and not harsh at 2 to 4 kHz.",
    "space": "Reverb and delay returns only: a tail that supports the lead and fades, not a wash that smears the next note.",
    "dialogue": "The chopped voice alone: each cut starts clean on a syllable, silence between phrases, no clicks or truncated words.",
    "bed": "The film soundtrack bed alone: continuous, band limited and in the background, with no hiss or hard loops.",
}


def write_wav24(path, samples, rate):
    """Stereo 24-bit PCM from float samples in -1 to 1."""
    x = np.asarray(samples, dtype=np.float64)
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    q = np.clip(np.round(x * 8388607.0), -8388608, 8388607).astype(np.int32)
    raw = np.empty((len(q), 2, 3), dtype=np.uint8)
    raw[..., 0] = q & 0xFF
    raw[..., 1] = (q >> 8) & 0xFF
    raw[..., 2] = (q >> 16) & 0xFF
    data = raw.tobytes()
    fmt = struct.pack("<HHIIHH", 1, 2, int(rate), int(rate) * 6, 6, 24)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<I", 16) + fmt)
        f.write(b"data" + struct.pack("<I", len(data)) + data)


def lufs(sig, rate):
    return integrated_lufs(sub_block_ms(sig, rate))


def peak_limit(sig, rate, ceiling_db=CEILING_DBTP, lookahead=0.005):
    """Transparent look-ahead peak limiter for a few dB of overs; the envelope uses 4x oversampled peaks."""
    x = np.asarray(sig, dtype=np.float64)
    over = sps.resample_poly(x, 4, 1, axis=0)
    env = np.max(np.abs(over), axis=1)
    n = len(x)
    env = env[: n * 4].reshape(n, 4).max(axis=1)
    ceiling = 10 ** (ceiling_db / 20)
    need = np.minimum(1.0, ceiling / np.maximum(env, 1e-12))
    w = max(2, int(lookahead * rate))
    held = ndimage.minimum_filter1d(need, size=2 * w + 1, mode="nearest")
    gain = ndimage.uniform_filter1d(held, size=w, mode="nearest")
    return x * gain[:, None]


def normalize(sig, rate, target=TARGET_LUFS, tolerance=0.1, passes=6):
    """Gain (and a peak limiter when needed) so the clip reads `target` LUFS with true peak under the ceiling.
    Returns (samples, info) or (None, info) when the clip is silent."""
    x = np.asarray(sig, dtype=np.float64)
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    now = lufs(x, rate)
    if not np.isfinite(now):
        return None, {"skipped": "silent or below the loudness gate"}
    gain_db = target - now
    out = x
    for _ in range(passes):
        out = x * 10 ** (gain_db / 20)
        if true_peak_db(out) > CEILING_DBTP:
            out = peak_limit(out, rate)
        got = lufs(out, rate)
        if abs(got - target) <= tolerance:
            break
        gain_db += target - got
    tp = true_peak_db(out)
    if tp > -1.0:  # fall back to a harder trim; loudness gives way before the peak does
        out = out * 10 ** ((-1.1 - tp) / 20)
        tp = true_peak_db(out)
    return out, {"integratedLufs": float(lufs(out, rate)), "truePeakDbtp": float(tp), "gainDb": float(gain_db)}


def _fade(x, rate, ms=5.0):
    n = int(rate * ms / 1000)
    if len(x) > 2 * n and n > 0:
        ramp = np.linspace(0.0, 1.0, n)
        x = x.copy()
        x[:n] *= ramp[:, None]
        x[-n:] *= ramp[::-1][:, None]
    return x


def _section_sum(cap, names_by_section, exclude=(), start=0, stop=None):
    out = None
    for section in SECTION_ORDER:
        if section in exclude:
            continue
        sig = cap.section_signal(section, start, stop)
        if sig is None:
            continue
        out = sig.astype(np.float64) if out is None else out + sig
    return out


def build_auditions(cap, out_dir, baseline_dir=None, log=print):
    """Write the audition files; returns a list of {file, title, listen, lufs, truePeakDbtp} entries."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    rate = cap.rate
    entries = []

    def emit(name, title, listen, sig):
        if sig is None or len(sig) < rate // 2:
            entries.append({"file": None, "title": title, "listen": listen, "skipped": "no audio"})
            return
        out, info = normalize(sig, rate)
        if out is None:
            entries.append({"file": None, "title": title, "listen": listen, "skipped": info["skipped"]})
            log(f"    {name}: skipped ({info['skipped']})")
            return
        write_wav24(out_dir / name, out, rate)
        entries.append({"file": name, "title": title, "listen": listen, "lufs": info["integratedLufs"],
                        "truePeakDbtp": info["truePeakDbtp"], "seconds": len(out) / rate})
        log(f"    {name}: {info['integratedLufs']:.2f} LUFS, {info['truePeakDbtp']:.2f} dBTP")

    master = cap.stem("master")
    frames = cap.frames
    if master is not None:
        emit("master.wav", "Candidate master",
             "The whole mix at -16 LUFS. Listen for overall balance, loudness without pumping or crackle, "
             "bass and kick together, and the film bed behind the voice.", np.asarray(master[:frames], dtype=np.float32))
    if baseline_dir is not None:
        bwav = Path(baseline_dir) / "master.wav"
        if bwav.is_file():
            from .audio import read_wav
            base, brate = read_wav(bwav)
            n = min(len(base), frames)
            if brate == rate:
                emit("baseline-master.wav", "Baseline master (same bars)",
                     "The unmodified mix over the same bars, matched to the same loudness. Switch between this and master.wav "
                     "at the same timestamp: the candidate should be clearer in the voice and bass, not just louder.",
                     np.asarray(base[:n], dtype=np.float32))
        else:
            entries.append({"file": None, "title": "Baseline master", "listen": "", "skipped": f"no master.wav in {baseline_dir}"})

    bars16 = int(min(16 * cap.bar_frames, frames))
    for section in SECTION_ORDER:
        sig = cap.section_signal(section, 0, bars16)
        emit(f"solo-{section}-bars1-16.wav", f"{section} solo, bars 1 to 16", SECTION_NOTES[section], sig)

    dial = cap.section_signal("dialogue")
    rest = _section_sum(cap, None, exclude=("dialogue",))
    if dial is not None and rest is not None:
        mix = dial.astype(np.float64) + rest * 10 ** (-6 / 20)
        emit("dialogue-in-context.wav", "Dialogue in context (everything else 6 dB down)",
             "Check that every word can be understood with the music and film bed kept low; any word you cannot follow here "
             "will not be intelligible in the real mix.", mix)

    if master is not None and cap.score:
        takes = {}
        for i, ph in enumerate(cap.score):
            takes.setdefault(i // 4, {})[ph.get("section")] = ph
        for take, secs in sorted(takes.items()):
            if "theme" in secs and "returnTheme" in secs:
                a, b = secs["theme"]["range"], secs["returnTheme"]["range"]
                clip = np.concatenate([_fade(np.asarray(master[a[0]:a[1]], np.float32), rate),
                                       _fade(np.asarray(master[b[0]:b[1]], np.float32), rate)], axis=0)
                emit(f"return-theme-take{take}.wav", f"Theme then its return, take {take}",
                     "The first half is the theme phrase, the second half is its return. The melody should be recognisably "
                     "the same tune, with the first notes of the return exposed and not covered by the voice or the pads.", clip)
    return entries


def auditions_markdown(entries, rel="auditions"):
    lines = ["## Auditions", "",
             "Every file is matched to -16 LUFS (24-bit, true peak at most -1.0 dBTP), so level differences do not bias what you hear. "
             "Play them on speakers or headphones you know.", "",
             "| File | Length | LUFS | dBTP | What to listen for |", "|---|---|---|---|---|"]
    for e in entries:
        if e.get("file"):
            lines.append(f"| [{e['file']}]({rel}/{e['file']}) | {e['seconds']:.0f} s | {e['lufs']:.2f} | {e['truePeakDbtp']:.2f} | "
                         f"{e['title']}. {e['listen']} |")
        else:
            lines.append(f"| {e['title']} | - | - | - | skipped: {e.get('skipped', '')} |")
    return "\n".join(lines) + "\n"
