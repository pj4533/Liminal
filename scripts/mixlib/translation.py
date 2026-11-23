"""Bass translation measurements: how much of the bass line survives mono folds and band limits.

Everything is measured on delivered stems (`mixlib.delivery`: each stem at final-mix level, summing to the
master), so "in the mix" means what the listener gets. The transforms are named by what they do, never by a
playback device:

  stereo        the master as is
  mono          (L + R) / 2
  mono-hpC      mono, then a causal 4th-order Butterworth high-pass at C Hz (C = 120, 180, 250) and a causal
                2nd-order Butterworth low-pass at 7 kHz (scipy sosfilt)
  stereo-hp180  the same filters per channel (separates the band limit from the fold)

Band levels use zero-phase 4th-order Butterworth band-passes (as `mixlib.lowend.band_signal`). They are
applied as the filter pair's power response |H|^4 to a 4096-point Hann STFT (10 ms hop), which equals the
energy of `sosfiltfilt` up to the window's smoothing. Transform responses on band powers and on the note
windows are applied the same way (|H|^2 of the causal filters): power does not depend on phase.

Note proxies (labelled proxies, not hearing thresholds) are computed on Hann-windowed, zero-padded FFTs of
each note window of the delivered bass (mono) and of the sum of the six other delivered stems (mono):

  survivalDb       bass energy after the transform over its full-band energy
  cueMarginDb      bass over competitors, both after the transform, from the cutoff to 1 kHz
  H_k              bass power within +-max(4 %, 2 / T) of k f0 minus the competitors' third octave around k f0
  audible          H_k >= -6 dB; `identifiable` = two adjacent audible harmonics (spacing f0) between the
                   cutoff and 1 kHz
  identifiableSolo the same with no competitors: a harmonic counts when it is at most 45 dB under the
                   transformed master's whole-file RMS
  maskers          for each harmonic audible solo but not in the mix, the stem with the most third-octave power
"""

import json
import math
import shutil
import subprocess
from pathlib import Path

import numpy as np
from scipy import fft as sfft
from scipy import signal as sps

from . import delivery
from .audio import read_wav
from .loudness import measure_loudness, true_peak_db

TOOL_VERSION = 3
BANDS = [(20, 80), (80, 160), (160, 400), (400, 900), (900, 2000), (2000, 5000)]
BAND_NAMES = ["20-80", "80-160", "160-400", "400-900", "900-2000", "2000-5000"]
AUX_BANDS = [(160, 900), (180, 1000)]
AUX_NAMES = ["160-900", "180-1000"]
CUTOFFS = [120, 180, 250]
TRANSFORMS = ["stereo", "mono", "mono-hp120", "mono-hp180", "mono-hp250", "stereo-hp180"]
LOWPASS_HZ = 7000.0
SILENCE_DB = -70.0
AUDIBLE_DB = -6.0
SOLO_FLOOR_DB = 45.0
CUE_TOP_HZ = 1000.0
ATTACK_S = 0.120
SUSTAIN_SKIP_S = 0.150
SUSTAIN_MIN_S = 0.250
HELD_BEATS = 1.5
LOW_REGISTER_MAX_MIDI = 34
STFT_NFFT = 4096
STFT_HOP_S = 0.01
VOICE_TONE = {"flatwound": "round", "upright": "upright", "synth": "synth", "classic": "classic"}
OTHERS = ["drums", "texture", "dry", "wet", "chops", "footage"]


def db10(x):
    return float(10 * np.log10(max(float(x), 1e-30)))


# ---------------------------------------------------------------------------------------------- transforms

def transform_spec(name):
    """(mono, cutoff Hz or None, low-pass) for a transform name."""
    if name == "stereo":
        return False, None, False
    if name == "mono":
        return True, None, False
    if name.startswith("mono-hp"):
        return True, float(name[len("mono-hp"):]), True
    if name.startswith("stereo-hp"):
        return False, float(name[len("stereo-hp"):]), True
    raise ValueError(f"unknown transform {name}")


def filter_sos(cutoff, rate):
    """The causal stress filter: 4th-order Butterworth high-pass at `cutoff` and 2nd-order low-pass at 7 kHz."""
    hp = sps.butter(4, cutoff, "highpass", fs=rate, output="sos")
    lp = sps.butter(2, LOWPASS_HZ, "lowpass", fs=rate, output="sos")
    return np.vstack([hp, lp])


def apply_transform(sig, name, rate):
    """sig (n, 2). Returns (n, 2) float64; mono transforms are dual mono."""
    mono, cutoff, _ = transform_spec(name)
    x = np.asarray(sig, dtype=np.float64)
    if mono:
        m = x.mean(axis=1)
        x = np.stack([m, m], axis=1)
    if cutoff is not None:
        x = sps.sosfilt(filter_sos(cutoff, rate), x, axis=0)
    return x


def filter_power(cutoff, freqs, rate):
    """|H|^2 of the stress filter at `freqs` (1 when cutoff is None)."""
    if cutoff is None:
        return np.ones(len(freqs))
    _, h = sps.sosfreqz(filter_sos(cutoff, rate), worN=np.asarray(freqs, dtype=np.float64), fs=rate)
    return np.abs(h) ** 2


def band_power_weight(lo, hi, freqs, rate):
    """Power response of the zero-phase 4th-order Butterworth band-pass (|H|^4)."""
    sos = sps.butter(4, [lo, min(hi, rate / 2 * 0.95)], btype="band", fs=rate, output="sos")
    _, h = sps.sosfreqz(sos, worN=np.asarray(freqs, dtype=np.float64), fs=rate)
    return np.abs(h) ** 4


def describe_filters():
    return {
        "transforms": {t: _describe_transform(t) for t in TRANSFORMS},
        "bands": "zero-phase 4th-order Butterworth band-pass (sosfiltfilt equivalent), applied as |H|^4 to a "
                 f"{STFT_NFFT}-point Hann STFT with a {STFT_HOP_S * 1000:.0f} ms hop; edges zero-padded",
        "noteWindows": "Hann window, zero-padded FFT (>= 16384 points); transform applied as |H|^2",
        "monoLaw": "(L + R) / 2",
        "silenceGateDbfs": SILENCE_DB,
    }


def _describe_transform(name):
    mono, cutoff, lp = transform_spec(name)
    parts = ["(L + R) / 2 dual mono" if mono else "both channels"]
    if cutoff is not None:
        parts.append(f"causal 4th-order Butterworth high-pass {cutoff:.0f} Hz")
    if lp:
        parts.append(f"causal 2nd-order Butterworth low-pass {LOWPASS_HZ:.0f} Hz")
    return ", ".join(parts) + "; never normalized"


# ---------------------------------------------------------------------------------------- band power hops

class BandHops:
    """Per-hop mean-square power of L, R and the mono fold per (band, filter) column."""

    FILTERS = [None] + CUTOFFS

    def __init__(self, rate, nfft=STFT_NFFT, hop_seconds=STFT_HOP_S):
        self.rate = rate
        self.nfft = nfft
        self.hop = int(round(rate * hop_seconds))
        freqs = np.arange(nfft // 2 + 1) * rate / nfft
        self.columns = []
        cols = []
        bands = list(zip(BAND_NAMES, BANDS)) + list(zip(AUX_NAMES, AUX_BANDS)) + [("full", None)]
        for f in self.FILTERS:
            fw = filter_power(f, freqs, rate)
            for name, edges in bands:
                bw = np.ones(len(freqs)) if edges is None else band_power_weight(edges[0], edges[1], freqs, rate)
                cols.append(fw * bw)
                self.columns.append((name, f))
        self.weights = np.stack(cols, axis=1).astype(np.float32)
        self.window = np.hanning(nfft + 1)[:-1].astype(np.float32)
        self.scale = np.float32(2.0 / (nfft * float(np.sum(self.window.astype(np.float64) ** 2))))

    def col(self, band, cutoff=None):
        return self.columns.index((band, cutoff))

    def compute(self, sig):
        sig = np.asarray(sig)
        n = len(sig)
        nfr = n // self.hop + 1
        half = self.nfft // 2
        K = self.weights.shape[1]
        out = {k: np.zeros((nfr, K), dtype=np.float32) for k in ("L", "R", "M")}
        base = np.arange(self.nfft)[None, :]
        chunk = 1000
        for a in range(0, nfr, chunk):
            b = min(nfr, a + chunk)
            s0, s1 = a * self.hop - half, (b - 1) * self.hop + half
            lo, hi = max(s0, 0), min(s1, n)
            seg = np.zeros((s1 - s0, 2), dtype=np.float32)
            seg[lo - s0: hi - s0] = np.asarray(sig[lo:hi], dtype=np.float32)
            idx = np.arange(b - a)[:, None] * self.hop + base
            XL = sfft.rfft(seg[:, 0][idx] * self.window, workers=-1)
            XR = sfft.rfft(seg[:, 1][idx] * self.window, workers=-1)
            XM = (XL + XR) * 0.5
            with np.errstate(all="ignore"):
                for key, X in (("L", XL), ("R", XR), ("M", XM)):
                    out[key][a:b] = ((X.real ** 2 + X.imag ** 2) * self.scale) @ self.weights
        return out

    def hop_range(self, a, b, nfr):
        return max(0, a // self.hop), min(nfr, max(a // self.hop + 1, b // self.hop + 1))


def mono_change_db(p_left, p_right, p_mono, gate_db=SILENCE_DB):
    """The handoff's event-window mono energy change. Returns (dB or None, status).

    status: "ok", "gated" (stereo power under the gate), or "cancelled" (mono power zero: reported as -inf)."""
    p_stereo = (p_left + p_right) / 2
    if p_stereo <= 10 ** (gate_db / 10):
        return None, "gated"
    if p_mono <= p_stereo * 1e-12:
        return float("-inf"), "cancelled"
    return 10 * math.log10(p_mono / p_stereo), "ok"


# ------------------------------------------------------------------------------------------ note windows

def power_spectrum(x, rate, min_nfft=16384):
    """(freqs, one-sided power) of a Hann-windowed segment, normalized so the sum is the mean square."""
    x = np.asarray(x, dtype=np.float64)
    n = len(x)
    nfft = max(min_nfft, 1 << int(math.ceil(math.log2(max(n, 2)))))
    w = np.hanning(n + 2)[1:-1] if n > 2 else np.ones(n)
    X = np.fft.rfft(x * w, nfft)
    p = (np.abs(X) ** 2) * (2.0 / (nfft * max(np.sum(w ** 2) / n, 1e-12) * n))
    p[0] *= 0.5
    return np.arange(len(p)) * rate / nfft, p


def third_octave(freqs, f):
    return (freqs >= f * 2 ** (-1 / 6)) & (freqs < f * 2 ** (1 / 6))


def window_proxies(bass, others, rate, f0, cutoffs=CUTOFFS, solo_ref_db=None, gate_db=SILENCE_DB):
    """Proxies for one note window.

    bass: mono delivered bass segment. others: {stem: mono delivered segment}. solo_ref_db: {cutoff: dB of the
    transformed master's whole-file mean square}. Returns None when the bass is under the gate."""
    freqs, pb = power_spectrum(bass, rate)
    full = float(pb.sum())
    if db10(full) < gate_db:
        return None
    stem_p = {k: power_spectrum(v, rate)[1] for k, v in others.items()}
    comp = None
    for v in others.values():
        comp = np.array(v, dtype=np.float64) if comp is None else comp + v
    pc = power_spectrum(comp, rate)[1] if comp is not None else np.zeros_like(pb)
    T = len(bass) / rate
    out = {"levelDb": db10(full)}
    for c in cutoffs:
        w = filter_power(c, freqs, rate)
        bw, cw = pb * w, pc * w
        band = (freqs >= c) & (freqs <= CUE_TOP_HZ)
        cue_b, cue_c = float(bw[band].sum()), float(cw[band].sum())
        harmonics = []
        kmin = max(1, int(math.ceil(c / f0 - 1e-9)))
        kmax = int(math.floor(CUE_TOP_HZ / f0 + 1e-9))
        ref = None if solo_ref_db is None else solo_ref_db.get(c)
        for k in range(kmin, kmax + 1):
            fk = k * f0
            hw = max(0.04 * fk, 2.0 / T)
            near = np.abs(freqs - fk) <= hw
            third = third_octave(freqs, fk)
            hb, hc = float(bw[near].sum()), float(cw[third].sum())
            h = db10(hb) - db10(hc)
            solo = ref is not None and db10(hb) >= ref - SOLO_FLOOR_DB
            row = {"k": k, "hz": fk, "bassDb": db10(hb), "snrDb": h, "audible": h >= AUDIBLE_DB, "audibleSolo": solo}
            if solo and h < AUDIBLE_DB and stem_p:
                row["masker"] = max(stem_p, key=lambda s: float((stem_p[s] * w)[third].sum()))
            harmonics.append(row)
        out[str(c)] = {
            "survivalDb": db10(float(bw.sum())) - db10(full),
            "cueMarginDb": db10(cue_b) - db10(cue_c),
            "cueLevelDb": db10(cue_b),
            "audibleHarmonics": sum(h["audible"] for h in harmonics),
            "identifiable": _adjacent(harmonics, "audible"),
            "identifiableSolo": _adjacent(harmonics, "audibleSolo"),
            "maskers": [h["masker"] for h in harmonics if "masker" in h],
            # The strongest pair of adjacent harmonics (the weaker of the two) re the transformed master's
            # whole-file mean square: how far under the mix the best solo cue sits.
            "bestPairDbReMix": (max(min(a["bassDb"], b["bassDb"]) for a, b in zip(harmonics, harmonics[1:]))
                                - ref) if ref is not None and len(harmonics) > 1 else None,
            # How much the bass harmonics would have to rise (all together, competitors unchanged) for the best
            # adjacent pair to reach the audible line: the dB size of the missing cue. Negative = already there.
            "liftToIdentifiableDb": (AUDIBLE_DB - max(min(a["snrDb"], b["snrDb"]) for a, b in zip(harmonics, harmonics[1:])))
                                    if len(harmonics) > 1 else None,
            "harmonics": [{"k": h["k"], "snrDb": round(h["snrDb"], 2), "bassDb": round(h["bassDb"], 2)} for h in harmonics],
        }
    return out


def _adjacent(harmonics, key):
    flags = {h["k"]: h[key] for h in harmonics}
    return any(flags.get(k) and flags.get(k + 1) for k in flags)


# ------------------------------------------------------------------------------------------- note table

def bass_notes(manifest, score, rate, latency=0):
    """One row per scored bass note with its windows on the delivered (master) timeline."""
    grid = manifest.get("grid") or {}
    beat = float(grid.get("beatFrames") or 60 / float(manifest.get("bpm", 70)) * rate)
    bar = float(grid.get("barFrames") or beat * 4)
    phrase_frames = float(grid.get("phraseFrames") or bar * 4)
    diag = (manifest.get("diagnostics") or {}).get("bass") or []
    voices = {int(d.get("phrase", i)): d.get("voice") for i, d in enumerate(diag)}
    anchored = {}
    for d in diag:
        for n in d.get("notes", []):
            anchored[int(n["frame"])] = n.get("alignedKickFrame") is not None
    chops = [(int(c["frame"]), int(c["frame"]) + int(c.get("durationFrames") or 0))
             for c in manifest.get("dialogueChops") or [] if c.get("frame") is not None]
    strums, strum_events = [], []
    for ph in score or []:
        strums += [(int(n["on"]), int(n["off"])) for n in ph.get("notes", []) if n.get("role") == "strum"]
        strum_events += [int(e["on"]) for e in ph.get("strumEvents") or [] if "on" in e]
    rows = []
    for p_index, ph in enumerate(score or []):
        for n in ph.get("notes", []):
            if n.get("role") != "bass" or float(n.get("velocity", 1)) <= 0:
                continue
            on, off = int(n["on"]), int(n["off"])
            phrase = int(on // phrase_frames)
            voice = voices.get(phrase)
            midi = int(n["midi"])
            strike_on = int(n["strikeOn"]) if n.get("strikeOn") is not None else on
            row = {
                "on": on, "off": off, "midi": midi, "f0": 440.0 * 2 ** ((midi - 69) / 12),
                "seconds": (off - on) / rate, "beats": (off - on) / beat, "bar": int(on // bar),
                "time": on / rate, "phrase": phrase, "section": ph.get("section"), "program": ph.get("program"),
                "voice": voice, "tone": VOICE_TONE.get(voice, voice or "unknown"),
                "register": "low" if midi <= LOW_REGISTER_MAX_MIDI else "high",
                "held": (off - on) >= HELD_BEATS * beat, "stroke": n.get("stroke"),
                "strike": float(n.get("strike", 0) or 0), "velocity": float(n.get("velocity", 1)),
                "thrown": float(n.get("send", 0) or 0) > 0, "anchored": anchored.get(on, False),
                "strums": sum(1 for a, b in strums if a < off and b > on),
                "strumEvents": sum(1 for e in strum_events if on <= e < off),
                "chops": sum(1 for a, b in chops if a < off and b > on),
                "attack": [strike_on + latency, strike_on + latency + int(ATTACK_S * rate)],
            }
            s0 = on + int(SUSTAIN_SKIP_S * rate)
            row["sustain"] = [s0 + latency, off + latency] if off - s0 >= int(SUSTAIN_MIN_S * rate) else None
            row["cell"] = f"{row['tone']}/{row['register']}/{'held' if row['held'] else 'short'}"
            rows.append(row)
    rows.sort(key=lambda r: r["on"])
    return rows


# ---------------------------------------------------------------------------------------------- analysis

def analyze(cap_dir, progress=print):
    """Full translation analysis of one capture directory. Returns a JSON-serializable dict."""
    cap_dir = Path(cap_dir)
    manifest = json.loads((cap_dir / "manifest.json").read_text())
    score = json.loads((cap_dir / "score.json").read_text()) if (cap_dir / "score.json").is_file() else []
    rate = int(manifest["sampleRate"])
    progress(f"{cap_dir.name}: fitting the master chain")
    chain, master = delivery.load_chain(cap_dir)
    master = np.asarray(master, dtype=np.float64)
    stems, chain = delivery.delivered_stems(cap_dir, chain, master)
    n = len(master)
    lat = chain.latency
    notes = bass_notes(manifest, score, rate, lat)
    comp = sum(stems[k] for k in OTHERS)

    progress(f"{cap_dir.name}: band powers")
    hops = BandHops(rate)
    H = {"master": hops.compute(master), "competitors": hops.compute(comp)}
    for k, v in stems.items():
        H[k] = hops.compute(v)
    nfr = H["master"]["L"].shape[0]

    result = {"tool": "translation-report", "toolVersion": TOOL_VERSION, "capture": str(cap_dir),
              "filters": describe_filters(), "delivery": chain.describe(),
              "manifest": manifest_block(manifest, cap_dir)}

    # Whole-file band RMS per transform (master and every delivered stem) and loudness per transform.
    note_hops = _mask([tuple(r["attack"][:1]) + (r["off"] + lat,) for r in notes], hops, nfr)
    result["bands"] = {"names": BAND_NAMES, "master": {}, "stems": {}}
    for t in TRANSFORMS:
        result["bands"]["master"][t] = _band_table(H["master"], hops, t, note_hops)
    for k in list(stems) + ["competitors"]:
        result["bands"]["stems"][k] = {t: _band_table(H[k], hops, t, note_hops) for t in ("stereo", "mono", "mono-hp180", "mono-hp250")}

    progress(f"{cap_dir.name}: loudness per transform")
    result["loudness"] = {}
    solo_ref = {}
    for t in TRANSFORMS:
        x = apply_transform(master, t, rate)
        loud = measure_loudness(x, rate)
        st = loud["shortTerm"]
        rms = float(np.sqrt(np.mean(x ** 2)))
        peak = float(np.max(np.abs(x)))
        result["loudness"][t] = {
            "integratedLufs": _f(loud["integratedLufs"]), "shortTermMaxLufs": _f(loud["shortTermMaxLufs"]),
            "shortTermMedianLufs": _f(float(np.median(st[np.isfinite(st)]))) if len(st) and np.isfinite(st).any() else None,
            "samplePeakDbfs": 20 * math.log10(max(peak, 1e-12)), "truePeakDbtp": _f(true_peak_db(x)),
            "rmsDbfs": 20 * math.log10(max(rms, 1e-12)), "crestDb": 20 * math.log10(max(peak, 1e-12) / max(rms, 1e-12))}
        mono, cutoff, _ = transform_spec(t)
        if mono and cutoff is not None:
            solo_ref[int(cutoff)] = db10(np.mean(x[:, 0] ** 2))
    bass_loud = measure_loudness(stems["bass"], rate)
    result["bassStem"] = {"integratedLufs": _f(bass_loud["integratedLufs"]),
                          "rmsDbfs": 20 * math.log10(max(float(np.sqrt(np.mean(stems["bass"] ** 2))), 1e-12)),
                          "lrNullMaxAbs": None}
    result["soloReferenceDb"] = {str(k): v for k, v in solo_ref.items()}

    progress(f"{cap_dir.name}: mono fold over bass notes and chops")
    result["monoChange"] = mono_tables(H, hops, notes, manifest, lat, nfr)

    progress(f"{cap_dir.name}: note proxies ({len(notes)} notes)")
    bass_m = stems["bass"].mean(axis=1)
    others_m = {k: stems[k].mean(axis=1) for k in OTHERS}
    for r in notes:
        for kind in ("attack", "sustain"):
            w = r.get(kind)
            if not w:
                r[kind + "Proxies"] = None
                continue
            a, b = max(0, w[0]), min(n, w[1])
            if b - a < int(0.05 * rate):
                r[kind + "Proxies"] = None
                continue
            r[kind + "Proxies"] = window_proxies(bass_m[a:b], {k: v[a:b] for k, v in others_m.items()}, rate,
                                                 r["f0"], solo_ref_db=solo_ref)
    # The phrase's competitor density in 180-1000 Hz (mono), for excerpt picks and the dense/sparse split.
    density = phrase_density(H["competitors"], hops, manifest, lat, nfr)
    for r in notes:
        r["phraseDensityDb"] = density.get(r["phrase"])
    result["notes"] = notes
    result["phraseDensityDb"] = {str(k): v for k, v in density.items()}
    result["dynamics"] = dynamics_block(cap_dir, manifest, notes, n)
    result["integrity"] = integrity_block(cap_dir, manifest)
    result["bassStem"]["lrNullMaxAbs"] = result["integrity"].get("bassLrNullMaxAbs")
    result["summary"] = summarize(notes)
    result["diagnosis"] = diagnose(result)
    return result


def _f(x):
    return None if x is None or not np.isfinite(x) else float(x)


def _mask(intervals, hops, nfr):
    m = np.zeros(nfr, dtype=bool)
    for a, b in intervals:
        lo, hi = hops.hop_range(int(a), int(b), nfr)
        m[lo:hi] = True
    return m


def _band_table(h, hops, transform, note_mask):
    mono, cutoff, _ = transform_spec(transform)
    out = {}
    for name in BAND_NAMES + AUX_NAMES + ["full"]:
        j = hops.col(name, None if cutoff is None else int(cutoff))
        p = h["M"][:, j] if mono else (h["L"][:, j] + h["R"][:, j]) * 0.5
        whole = float(np.mean(p, dtype=np.float64))
        notes = float(np.mean(p[note_mask], dtype=np.float64)) if note_mask.any() else None
        out[name] = {"rmsDb": db10(whole), "inBassNotesDb": None if notes is None else db10(notes)}
    return out


def mono_tables(H, hops, notes, manifest, lat, nfr):
    """Event-window mono change per band, for the master and every delivered stem, over bass notes and chops."""
    windows = {"bassNotes": [(r["on"] + lat, r["off"] + lat) for r in notes],
               "chops": [(int(c["frame"]) + lat, int(c["frame"]) + int(c.get("durationFrames") or 0) + lat)
                         for c in manifest.get("dialogueChops") or [] if c.get("frame") is not None]}
    out = {}
    for wname, wins in windows.items():
        out[wname] = {}
        for sig in ["master"] + list(delivery_names()) + ["competitors"]:
            h = H.get(sig)
            if h is None:
                continue
            per_band = {}
            for band in BAND_NAMES + AUX_NAMES:
                j = hops.col(band, None)
                vals, gated, cancelled = [], 0, 0
                tl = tr = tm = 0.0
                for a, b in wins:
                    lo, hi = hops.hop_range(a, b, nfr)
                    if hi <= lo:
                        continue
                    pl, pr, pm = (float(h[k][lo:hi, j].mean(dtype=np.float64)) for k in ("L", "R", "M"))
                    v, status = mono_change_db(pl, pr, pm)
                    if status == "gated":
                        gated += 1
                        continue
                    if status == "cancelled":
                        cancelled += 1
                    vals.append(v)
                    tl += pl * (hi - lo); tr += pr * (hi - lo); tm += pm * (hi - lo)
                pooled, _ = mono_change_db(tl, tr, tm, gate_db=-300) if (tl + tr) > 0 else (None, "gated")
                finite = [v for v in vals if np.isfinite(v)]
                per_band[band] = {"windows": len(vals), "gated": gated, "cancelled": cancelled,
                                  "medianDb": float(np.median(finite)) if finite else None,
                                  "p10Db": float(np.percentile(finite, 10)) if finite else None,
                                  "pooledDb": pooled}
            out[wname][sig] = per_band
    # Share of 180-1000 Hz energy (stereo power) per delivered stem inside the bass notes.
    j = hops.col("180-1000", None)
    mask = _mask(windows["bassNotes"], hops, nfr)
    energy = {k: float(((H[k]["L"][:, j] + H[k]["R"][:, j]) * 0.5)[mask].sum(dtype=np.float64))
              for k in delivery_names() if k in H}
    total = sum(energy.values()) or 1.0
    out["share180to1000"] = {k: v / total for k, v in energy.items()}
    return out


def delivery_names():
    return [d[0] for d in delivery.DELIVERED]


def phrase_density(h, hops, manifest, lat, nfr):
    grid = manifest.get("grid") or {}
    pf = float(grid.get("phraseFrames") or 0)
    if pf <= 0:
        return {}
    j = hops.col("180-1000", None)
    out = {}
    scored = int(manifest.get("scoredFrames") or manifest.get("frames"))
    for p in range(int(round(scored / pf))):
        lo, hi = hops.hop_range(int(p * pf) + lat, int((p + 1) * pf) + lat, nfr)
        if hi > lo:
            out[p] = db10(float(h["M"][lo:hi, j].mean(dtype=np.float64)))
    return out


def dynamics_block(cap_dir, manifest, notes, frames):
    dyn = (manifest.get("diagnostics") or {}).get("masterDynamics") or {}
    path = cap_dir / (dyn.get("traceFile") or "master-gr.csv")
    if not path.is_file():
        return {"available": False}
    tr = delivery.read_trace(path)
    if len(tr) == 0:
        return {"available": False}
    idx = np.arange(frames)
    glue, clip, lim = (np.interp(idx, tr[:, 0], tr[:, k]) for k in (1, 2, 3))
    inside = np.zeros(frames, dtype=bool)
    over = 0
    per_note = []
    for r in notes:
        a, b = max(0, r["on"]), min(frames, r["off"])
        if b <= a:
            continue
        inside[a:b] = True
        peak = float(np.max(clip[a:b] + lim[a:b]))
        r["clipLimiterMaxDb"] = peak
        per_note.append(peak)
        over += peak > 1.0
    def stats(m):
        if not m.any():
            return None
        return {"glueMeanDb": float(glue[m].mean()), "clipMeanDb": float(clip[m].mean()),
                "limiterMeanDb": float(lim[m].mean()), "clipLimiterMaxDb": float((clip[m] + lim[m]).max())}
    return {"available": True, "insideBassNotes": stats(inside), "outsideBassNotes": stats(~inside),
            "notesOver1Db": int(over), "notesOver1DbFraction": over / len(per_note) if per_note else None,
            "calibration": manifest.get("masterCalibration"), "profile": dyn.get("profile")}


def integrity_block(cap_dir, manifest):
    """Finite stems, bass DC per phrase, bass L/R null, phrase-boundary steps and wet boundary RMS."""
    out = {"nonFinite": {}, "bassDcDbfsPerPhrase": [], "boundarySteps": {}, "wetBoundaryRmsDb": []}
    rate = int(manifest["sampleRate"])
    grid = manifest.get("grid") or {}
    pf = float(grid.get("phraseFrames") or 0)
    scored = int(manifest.get("scoredFrames") or manifest.get("frames"))
    bounds = [int(round(p * pf)) for p in range(1, int(round(scored / pf)))] if pf > 0 else []
    for wav in sorted(cap_dir.glob("*.wav")):
        x, _ = read_wav(wav)
        bad = int(np.count_nonzero(~np.isfinite(np.asarray(x))))
        if bad:
            out["nonFinite"][wav.stem] = bad
    out["allFinite"] = not out["nonFinite"]
    if (cap_dir / "bass.wav").is_file():
        b, _ = read_wav(cap_dir / "bass.wav")
        b = np.asarray(b, dtype=np.float64)
        out.update(integrity_arrays(b, bounds, pf, scored))
    for name in ("bass", "wet", "master"):
        if (cap_dir / f"{name}.wav").is_file():
            x, _ = read_wav(cap_dir / f"{name}.wav")
            out["boundarySteps"][name] = boundary_steps(np.asarray(x, dtype=np.float64), bounds, rate)
    if (cap_dir / "wet.wav").is_file():
        x, _ = read_wav(cap_dir / "wet.wav")
        out["wetBoundaryRmsDb"] = boundary_rms(np.asarray(x, dtype=np.float64), bounds, rate)
    return out


def integrity_arrays(bass, bounds, pf, scored):
    """Bass L/R null (max |L - R| over finite frames) and the DC (mean) of each phrase, dBFS."""
    out = {}
    ok = np.isfinite(bass).all(axis=1)
    out["bassLrNullMaxAbs"] = float(np.max(np.abs(bass[ok, 0] - bass[ok, 1]))) if ok.any() else None
    dcs = []
    if pf > 0:
        for p in range(int(round(scored / pf))):
            seg = bass[int(p * pf): int((p + 1) * pf)].mean(axis=1)
            seg = seg[np.isfinite(seg)]
            dcs.append(20 * math.log10(max(abs(float(seg.mean())) if len(seg) else 0.0, 1e-12)))
    out["bassDcDbfsPerPhrase"] = dcs
    out["bassDcMaxDbfs"] = max(dcs) if dcs else None
    return out


def boundary_steps(x, bounds, rate, ms=2.0):
    """Largest sample-to-sample step within `ms` of each boundary, and the file's 99.99th percentile step."""
    m = x.mean(axis=1) if x.ndim == 2 else x
    d = np.abs(np.diff(m))
    d = np.where(np.isfinite(d), d, np.inf)
    w = int(ms * rate / 1000)
    steps = [float(np.max(d[max(0, b - w): b + w])) for b in bounds if b + w < len(d)]
    return {"maxAtBoundary": max(steps) if steps else None, "perBoundary": steps,
            "p9999Elsewhere": float(np.percentile(d[np.isfinite(d)], 99.99)) if np.isfinite(d).any() else None}


def boundary_rms(x, bounds, rate, ms=50.0):
    w = int(ms * rate / 1000)
    out = []
    for b in bounds:
        if b - w < 0 or b + w > len(x):
            continue
        before = float(np.sqrt(np.mean(x[b - w:b] ** 2)))
        after = float(np.sqrt(np.mean(x[b:b + w] ** 2)))
        out.append({"frame": b, "beforeDb": 20 * math.log10(max(before, 1e-12)),
                    "afterDb": 20 * math.log10(max(after, 1e-12))})
    return out


def manifest_block(m, cap_dir):
    diag = m.get("diagnostics") or {}
    dyn = diag.get("masterDynamics") or {}
    bass = diag.get("bass") or []
    levels = diag.get("musicLevels") or []
    return {
        "gitRevision": m.get("gitRevision"), "trackedDiffSHA256": m.get("trackedDiffSHA256"), "seed": m.get("seed"),
        "bpm": m.get("bpm"), "bars": round(float(m.get("scoredFrames", m.get("frames", 0))) /
                                           float((m.get("grid") or {}).get("barFrames") or 1)),
        "sampleRate": m.get("sampleRate"), "frames": m.get("frames"), "hasFootage": m.get("hasFootage"),
        "sameFilm": m.get("sameFilm"), "filmTitles": [f.get("title") for f in m.get("filmReel") or []],
        "drumSourceHash": m.get("drumSourceHash"), "hooks": m.get("hooks") or {},
        "renderTuning": diag.get("renderTuning"), "audition": diag.get("audition"),
        "bassTonePerPhrase": [VOICE_TONE.get(d.get("voice"), d.get("voice")) for d in bass],
        "programPerPhrase": [l.get("program") for l in levels],
        "masterDynamics": {"profile": dyn.get("profile"), "settings": dyn.get("settings"),
                           "calibration": m.get("masterCalibration"), "ceilingDbtp": dyn.get("ceilingDbtp"),
                           "latencyFrames": dyn.get("latencyFrames"), "preMasterStagingDb": dyn.get("preMasterStagingDb")},
        "providers": m.get("providers"), "system": m.get("system"),
    }


# --------------------------------------------------------------------------------------------- summaries

def _q(vals, q):
    vals = [v for v in vals if v is not None and np.isfinite(v)]
    return float(np.percentile(vals, q)) if vals else None


def summarize(notes):
    cells = sorted({r["cell"] for r in notes})
    out = {"pooled": _summary(notes), "cells": {c: _summary([r for r in notes if r["cell"] == c]) for c in cells},
           "tones": {t: _summary([r for r in notes if r["tone"] == t]) for t in sorted({r["tone"] for r in notes})},
           "registers": {g: _summary([r for r in notes if r["register"] == g]) for g in ("low", "high")},
           "toneRegister": {}}
    for t in sorted({r["tone"] for r in notes}):
        for g in ("low", "high"):
            sel = [r for r in notes if r["tone"] == t and r["register"] == g]
            if sel:
                out["toneRegister"][f"{t}/{g}"] = _summary(sel)
    out["spread"] = spread(notes)
    out["worst"] = worst(notes)
    out["maskers"] = masker_table(notes)
    return out


def _summary(rows):
    s = {"notes": len(rows), "held": sum(r["held"] for r in rows)}
    for kind in ("attack", "sustain"):
        ps = [r.get(kind + "Proxies") for r in rows]
        ps = [p for p in ps if p]
        k = {"windows": len(ps)}
        for c in CUTOFFS:
            cs = [p[str(c)] for p in ps]
            if not cs:
                continue
            k[str(c)] = {
                "survivalDbMedian": _q([x["survivalDb"] for x in cs], 50),
                "cueMarginDbMedian": _q([x["cueMarginDb"] for x in cs], 50),
                "cueMarginDbP10": _q([x["cueMarginDb"] for x in cs], 10),
                "cueLevelDbMedian": _q([x["cueLevelDb"] for x in cs], 50),
                "audibleHarmonicsMedian": _q([x["audibleHarmonics"] for x in cs], 50),
                "identifiable": float(np.mean([x["identifiable"] for x in cs])),
                "identifiableSolo": float(np.mean([x["identifiableSolo"] for x in cs])),
                "bestPairDbReMixMedian": _q([x.get("bestPairDbReMix") for x in cs], 50),
                "liftToIdentifiableDbMedian": _q([x.get("liftToIdentifiableDb") for x in cs], 50),
                "liftToIdentifiableDbP75": _q([x.get("liftToIdentifiableDb") for x in cs], 75),
            }
        s[kind] = k
    return s


def spread(notes, cutoff=180, min_notes=3):
    """Envelope evenness: the spread of the per-pitch (and per-tone) median sustain cue level at `cutoff`."""
    def level(r):
        p = r.get("sustainProxies")
        return p[str(cutoff)]["cueLevelDb"] if p else None
    by_pitch, by_tone = {}, {}
    for r in notes:
        v = level(r)
        if v is None:
            continue
        by_pitch.setdefault(r["midi"], []).append(v)
        by_tone.setdefault(r["tone"], []).append(v)
    pitch = {str(k): float(np.median(v)) for k, v in sorted(by_pitch.items()) if len(v) >= min_notes}
    tone = {k: float(np.median(v)) for k, v in sorted(by_tone.items()) if len(v) >= min_notes}
    return {"cutoff": cutoff, "perPitchMedianDb": pitch, "perToneMedianDb": tone,
            "pitchSpreadDb": (max(pitch.values()) - min(pitch.values())) if len(pitch) > 1 else None,
            "toneSpreadDb": (max(tone.values()) - min(tone.values())) if len(tone) > 1 else None}


def worst(notes, cutoff=180, count=10):
    rows = [(r["sustainProxies"][str(cutoff)]["cueMarginDb"], r) for r in notes if r.get("sustainProxies")]
    rows.sort(key=lambda x: x[0])
    return [{"bar": r["bar"], "time": round(r["time"], 3), "midi": r["midi"], "tone": r["tone"], "cell": r["cell"],
             "cueMarginDb": round(v, 2), "identifiable": r["sustainProxies"][str(cutoff)]["identifiable"],
             "maskers": r["sustainProxies"][str(cutoff)]["maskers"], "chops": r["chops"], "strums": r["strums"],
             "program": r["program"]} for v, r in rows[:count]]


def masker_table(notes, cutoff=180):
    out = {}
    for kind in ("attack", "sustain"):
        counts = {}
        for r in notes:
            p = r.get(kind + "Proxies")
            if not p:
                continue
            for m in p[str(cutoff)]["maskers"]:
                counts[m] = counts.get(m, 0) + 1
        total = sum(counts.values())
        out[kind] = {"cutoff": cutoff, "maskedHarmonics": total,
                     "share": {k: v / total for k, v in sorted(counts.items(), key=lambda x: -x[1])} if total else {}}
    return out


# --------------------------------------------------------------------------------------------- diagnosis

def diagnose(result, notes=None, mono=None, dynamics=None, gates_failed=None):
    """The plan's section 2 rules on one capture (or on pooled notes). Thresholds are project provisions."""
    notes = result["notes"] if notes is None else notes
    s = _summary(notes)
    mono = result.get("monoChange") if mono is None else mono
    dynamics = result.get("dynamics") if dynamics is None else dynamics
    out = {}
    # Stereo cancellation.
    master = (mono or {}).get("bassNotes", {}).get("master", {}).get("160-900", {})
    share = (mono or {}).get("share180to1000", {})
    stems = (mono or {}).get("bassNotes", {})
    folding = [k for k, v in share.items() if v > 0.25 and (stems.get(k, {}).get("180-1000", {}).get("pooledDb") or 0) < -3]
    null = (result.get("integrity") or {}).get("bassLrNullMaxAbs")
    out["stereo"] = {"master160to900MedianDb": master.get("medianDb"), "stemsOver25PctLosingOver3Db": folding,
                     "bassLrNullMaxAbs": null,
                     "met": bool((master.get("medianDb") is not None and master["medianDb"] < -1.5) or folding)}
    sus = s.get("sustain", {}).get("180", {})
    att = s.get("attack", {}).get("180", {})
    out["bandwidth"] = {"sustainSurvivalDbMedian": sus.get("survivalDbMedian"),
                        "sustainIdentifiableSolo": sus.get("identifiableSolo"),
                        "attackSurvivalDbMedian": att.get("survivalDbMedian"),
                        "attackIdentifiableSolo": att.get("identifiableSolo"),
                        "met": bool(sus and sus["survivalDbMedian"] is not None and sus["survivalDbMedian"] < -10
                                    and sus["identifiableSolo"] < 0.6)}
    gap = None if not sus else 100 * (sus["identifiableSolo"] - sus["identifiable"])
    gap_att = None if not att else 100 * (att["identifiableSolo"] - att["identifiable"])
    mt = masker_table(notes)
    top = max(mt["sustain"]["share"].items(), key=lambda x: x[1]) if mt["sustain"]["share"] else (None, 0)
    out["masking"] = {"sustainSoloMinusMixPoints": gap, "attackSoloMinusMixPoints": gap_att,
                      "sustainIdentifiable": sus.get("identifiable"), "attackIdentifiable": att.get("identifiable"),
                      "maskerShareSustain": mt["sustain"]["share"], "maskerShareAttack": mt["attack"]["share"],
                      "topMasker": top[0], "topMaskerShare": top[1], "targeted": top[1] > 0.5,
                      "met": bool(gap is not None and gap >= 20)}
    sp = spread(notes)
    env_gap = None if not (sus and att) else 100 * (att["identifiable"] - sus["identifiable"])
    out["envelope"] = {"attackMinusSustainPoints": env_gap, "pitchSpreadDb": sp["pitchSpreadDb"],
                       "toneSpreadDb": sp["toneSpreadDb"],
                       "met": bool((env_gap is not None and env_gap >= 25) or (sp["pitchSpreadDb"] or 0) > 6
                                   or (sp["toneSpreadDb"] or 0) > 6)}
    frac = (dynamics or {}).get("notesOver1DbFraction")
    out["overload"] = {"notesOver1DbFraction": frac, "distortionGatesFailed": gates_failed,
                       "met": bool((frac or 0) > 0.05 or gates_failed)}
    return out


def pool(results, gates_failed=None):
    """Pooled summary and diagnosis over several captures' results (all their notes, energy-pooled mono)."""
    notes = [dict(r, capture=Path(res["capture"]).name) for res in results for r in res["notes"]]
    mono = {"bassNotes": {}, "share180to1000": {}}
    # Mono change pooled: median of the per-capture medians, and the stems' shares averaged.
    for sig in ["master"] + delivery_names():
        for band in BAND_NAMES + AUX_NAMES:
            vals = [res["monoChange"]["bassNotes"].get(sig, {}).get(band, {}).get("medianDb") for res in results]
            pooled = [res["monoChange"]["bassNotes"].get(sig, {}).get(band, {}).get("pooledDb") for res in results]
            vals = [v for v in vals if v is not None]
            pooled = [v for v in pooled if v is not None and np.isfinite(v)]
            mono["bassNotes"].setdefault(sig, {})[band] = {"medianDb": float(np.median(vals)) if vals else None,
                                                          "pooledDb": float(np.median(pooled)) if pooled else None}
    for k in delivery_names():
        mono["share180to1000"][k] = float(np.mean([res["monoChange"]["share180to1000"].get(k, 0) for res in results]))
    over = sum(res["dynamics"].get("notesOver1Db", 0) for res in results if res["dynamics"].get("available"))
    dyn = {"notesOver1DbFraction": over / max(1, len(notes))}
    nulls = [res["integrity"].get("bassLrNullMaxAbs") for res in results]
    fake = {"notes": notes, "integrity": {"bassLrNullMaxAbs": max([v for v in nulls if v is not None], default=None)}}
    return {"captures": [res["capture"] for res in results], "summary": summarize(notes),
            "diagnosis": diagnose(fake, notes, mono, dyn, gates_failed), "monoChange": mono}


def compare(cand, base):
    """Candidate minus baseline on the same fixture: the deltas the variants are ranked by."""
    def get(d, *path):
        for p in path:
            if d is None:
                return None
            d = d.get(p) if isinstance(d, dict) else None
        return d

    def delta(*path):
        a, b = get(cand, *path), get(base, *path)
        return None if a is None or b is None else a - b

    out = {"master": {}, "bassStem": {}, "proxies": {}}
    for t in ("stereo", "mono", "mono-hp180", "mono-hp250"):
        out["master"][t] = {"integratedLufs": delta("loudness", t, "integratedLufs"),
                            "truePeakDbtp": get(cand, "loudness", t, "truePeakDbtp"),
                            "crestDb": delta("loudness", t, "crestDb"),
                            "bands": {b: delta("bands", "master", t, b, "rmsDb") for b in BAND_NAMES}}
    out["bassStem"] = {"integratedLufs": delta("bassStem", "integratedLufs"),
                       "bands": {b: delta("bands", "stems", "bass", "stereo", b, "rmsDb") for b in BAND_NAMES}}
    for scope in ("pooled",):
        for kind in ("attack", "sustain"):
            for c in CUTOFFS:
                key = f"{kind}/{c}"
                out["proxies"][key] = {m: delta("summary", scope, kind, str(c), m)
                                       for m in ("cueMarginDbMedian", "cueMarginDbP10", "survivalDbMedian",
                                                 "identifiable", "identifiableSolo", "cueLevelDbMedian",
                                                 "bestPairDbReMixMedian", "liftToIdentifiableDbMedian")}
    out["cells"] = {}
    for cell in sorted(set(get(cand, "summary", "toneRegister") or {}) | set(get(base, "summary", "toneRegister") or {})):
        out["cells"][cell] = {f"sustain/{c}": delta("summary", "toneRegister", cell, "sustain", str(c), "cueMarginDbMedian")
                              for c in CUTOFFS}
        out["cells"][cell]["identifiable180"] = delta("summary", "toneRegister", cell, "sustain", "180", "identifiable")
    gain = out["proxies"]["sustain/180"]["cueMarginDbMedian"]
    loud = out["bassStem"]["integratedLufs"]
    out["efficiencyDb"] = None if gain is None or loud is None else gain - loud
    out["pitchSpreadDeltaDb"] = delta("summary", "spread", "pitchSpreadDb")
    return out


def compare_pooled(cand, base):
    return compare({"summary": cand["summary"]}, {"summary": base["summary"]})


# --------------------------------------------------------------------------------------- auditions, pairs

def pick_excerpts(result, bars=8):
    """(label, start bar, why) for the worst held note in a dense phrase, the sparsest phrase and the lowest
    register. Starts are phrase-aligned (four bars) and distinct when the capture allows it."""
    notes = result["notes"]
    total_bars = int(result["manifest"]["bars"] or 0)
    dens = {int(k): v for k, v in (result.get("phraseDensityDb") or {}).items()}
    med = float(np.median(list(dens.values()))) if dens else 0
    used = []

    def start_for(bar):
        return int(max(0, min(max(0, total_bars - bars), (bar // 4) * 4)))

    def choose(ranked):
        """First candidate start not used yet (else the first)."""
        starts = [start_for(b) for b, _ in ranked]
        for (b, why), s in zip(ranked, starts):
            if s not in used:
                used.append(s)
                return s, why
        if ranked:
            used.append(starts[0])
            return starts[0], ranked[0][1]
        return None, None

    picks = []
    held = sorted(((r["sustainProxies"]["180"]["cueMarginDb"], r) for r in notes
                   if r["held"] and r.get("sustainProxies") and dens.get(r["phrase"], -999) >= med), key=lambda x: x[0])
    s, why = choose([(r["bar"], f"held MIDI {r['midi']} ({r['tone']}) at bar {r['bar'] + 1}, sustain cue margin {v:.1f} dB "
                      f"at mono-hp180, dense phrase {r['phrase']}") for v, r in held])
    if s is not None:
        picks.append(("dense", s, why))
    voiced = {r["phrase"] for r in notes}
    sparse = sorted((v, p) for p, v in dens.items() if p in voiced)
    s, why = choose([(p * 4, f"phrase {p}: least competitor energy in 180-1000 Hz ({v:.1f} dB)") for v, p in sparse])
    if s is not None:
        picks.append(("sparse", s, why))
    if notes:
        lowest = min(r["midi"] for r in notes)
        counts = {}
        for r in notes:
            if r["midi"] <= lowest + 2:
                counts[start_for(r["bar"])] = counts.get(start_for(r["bar"]), 0) + (2 if r["midi"] == lowest else 1)
        ranked = sorted(counts, key=lambda k: -counts[k])
        s, why = choose([(k, f"lowest register (MIDI {lowest} to {lowest + 2}), weight {counts[k]}") for k in ranked])
        if s is not None:
            picks.append(("low", s, why))
    return picks


def excerpt_frames(manifest, start_bar, bars, latency):
    bar = float((manifest.get("grid") or {}).get("barFrames"))
    a = int(round(start_bar * bar)) + latency
    return a, a + int(round(bars * bar))


def write_audio(path_base, x, rate, aac=True, encode_trim_db=-1.0):
    """24-bit WAV and (optionally) AAC 256k with a common -1 dB trim before the encode."""
    import soundfile as sf
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    over = int(np.count_nonzero(np.abs(x) > 1.0))
    wav = Path(str(path_base) + ".wav")
    sf.write(wav, np.clip(x, -1, 1), rate, subtype="PCM_24")
    info = {"wav": str(wav), "samplesOverFullScale": over}
    if aac and shutil.which("ffmpeg"):
        tmp = Path(str(path_base) + ".tmp.wav")
        sf.write(tmp, (x * 10 ** (encode_trim_db / 20)).astype(np.float32), rate, subtype="FLOAT")
        m4a = Path(str(path_base) + ".m4a")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(tmp), "-c:a", "aac", "-b:a", "256k", str(m4a)],
                       check=True)
        tmp.unlink()
        info["m4a"] = str(m4a)
        info["encodeTrimDb"] = encode_trim_db
    return info


def fade(x, rate, ms=5.0):
    x = np.array(x, dtype=np.float64)
    k = min(len(x) // 2, int(ms * rate / 1000))
    if k > 0:
        r = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, k))
        x[:k] *= r[:, None]
        x[-k:] *= r[::-1][:, None]
    return x


def auditions(cap_dir, result, out_dir, excerpt=None, aac=True, progress=print):
    """Excerpt files for one capture: stereo, mono, mono-hp180, mono-hp250 and the delivered bass solo."""
    cap_dir, out_dir = Path(cap_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((cap_dir / "manifest.json").read_text())
    rate = int(manifest["sampleRate"])
    chain, master = delivery.load_chain(cap_dir)
    stems, _ = delivery.delivered_stems(cap_dir, chain, master)
    picks = [("excerpt", excerpt[0], "requested")] if excerpt else pick_excerpts(result)
    bars = excerpt[1] if excerpt else 8
    written = []
    for label, start, why in picks:
        a, b = excerpt_frames(manifest, start, bars, chain.latency)
        b = min(b, len(master))
        for t in ("stereo", "mono", "mono-hp180", "mono-hp250"):
            x = apply_transform(np.asarray(master[a:b]), t, rate) if t == "stereo" else apply_transform(master, t, rate)[a:b]
            info = write_audio(out_dir / f"{label}-bars{start + 1}-{start + bars}-{t}", fade(x, rate), rate, aac)
            written.append(dict(info, label=label, why=why, transform=t, startFrame=a, endFrame=b, gainDb=0.0))
        info = write_audio(out_dir / f"{label}-bars{start + 1}-{start + bars}-bass-solo", fade(stems["bass"][a:b], rate), rate, aac)
        written.append(dict(info, label=label, why=why, transform="bass solo (delivered)", startFrame=a, endFrame=b, gainDb=0.0))
        progress(f"  {label}: bars {start + 1}-{start + bars} ({why})")
    (out_dir / "auditions.json").write_text(json.dumps({"capture": str(cap_dir), "files": written}, indent=2))
    return written


def pair_gains(base_master, cand_master, rate, base_stress=None, cand_stress=None, peak_ceiling_db=-1.0):
    """One linear gain per capture so both full-range masters read the same integrated loudness (the louder one
    is turned down, never up), plus one common gain for the stress pairs. Returns a dict of dB values."""
    lb = measure_loudness(np.asarray(base_master, dtype=np.float64), rate)["integratedLufs"]
    lc = measure_loudness(np.asarray(cand_master, dtype=np.float64), rate)["integratedLufs"]
    target = min(lb, lc)
    out = {"baseLufs": lb, "candLufs": lc, "baseGainDb": target - lb, "candGainDb": target - lc, "stressCommonGainDb": {}}
    if base_stress and cand_stress:
        for name in base_stress:
            bs = np.asarray(base_stress[name]) * 10 ** (out["baseGainDb"] / 20)
            cs = np.asarray(cand_stress[name]) * 10 ** (out["candGainDb"] / 20)
            lbs = measure_loudness(bs, rate)["integratedLufs"]
            lcs = measure_loudness(cs, rate)["integratedLufs"]
            louder = max(lbs, lcs)
            g = target - louder
            peak = max(float(np.max(np.abs(bs))), float(np.max(np.abs(cs))), 1e-12)
            g = min(g, peak_ceiling_db - 20 * math.log10(peak))
            out["stressCommonGainDb"][name] = g
    return out


def pair(base_dir, cand_dir, out_dir, base_result=None, excerpt=None, aac=True, progress=print):
    """A-B-A-B listening files (base, candidate, base, candidate over the same bars, 5 ms fades, 0.5 s gaps)
    for stereo, mono-hp180 and mono-hp250, matched by one linear gain per capture."""
    base_dir, cand_dir, out_dir = Path(base_dir), Path(cand_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    mb = json.loads((base_dir / "manifest.json").read_text())
    mc = json.loads((cand_dir / "manifest.json").read_text())
    rate = int(mb["sampleRate"])
    if abs(float(mb["grid"]["barFrames"]) - float(mc["grid"]["barFrames"])) > 1e-6 or mb.get("seed") != mc.get("seed"):
        raise ValueError("--pair needs two captures of the same seed and tempo")
    cb, xb = delivery.load_chain(base_dir)
    cc, xc = delivery.load_chain(cand_dir)
    xb, xc = np.asarray(xb, dtype=np.float64), np.asarray(xc, dtype=np.float64)
    stress = ("mono-hp180", "mono-hp250")
    sb = {t: apply_transform(xb, t, rate) for t in stress}
    sc = {t: apply_transform(xc, t, rate) for t in stress}
    gains = pair_gains(xb, xc, rate, sb, sc)
    picks = [("excerpt", excerpt[0], "requested")] if excerpt else pick_excerpts(base_result) if base_result else [("excerpt", 0, "start")]
    bars = excerpt[1] if excerpt else 8
    gap = np.zeros((int(0.5 * rate), 2))
    written = []
    for label, start, why in picks:
        ab0, ab1 = excerpt_frames(mb, start, bars, cb.latency)
        ac0, ac1 = excerpt_frames(mc, start, bars, cc.latency)
        L = min(ab1 - ab0, ac1 - ac0, len(xb) - ab0, len(xc) - ac0)
        for t in ("stereo",) + stress:
            common = gains["stressCommonGainDb"].get(t, 0.0)
            gb = 10 ** ((gains["baseGainDb"] + common) / 20)
            gc = 10 ** ((gains["candGainDb"] + common) / 20)
            b = (xb if t == "stereo" else sb[t])[ab0:ab0 + L] * gb
            c = (xc if t == "stereo" else sc[t])[ac0:ac0 + L] * gc
            seq = np.concatenate([fade(b, rate), gap, fade(c, rate), gap, fade(b, rate), gap, fade(c, rate)])
            info = write_audio(out_dir / f"{label}-bars{start + 1}-{start + bars}-{t}-ABAB", seq, rate, aac)
            written.append(dict(info, label=label, why=why, transform=t, baseGainDb=gains["baseGainDb"] + common,
                                candGainDb=gains["candGainDb"] + common, order="base, candidate, base, candidate"))
        progress(f"  {label}: bars {start + 1}-{start + bars} ({why})")
    meta = {"base": str(base_dir), "candidate": str(cand_dir), "gains": gains, "files": written,
            "note": "linear gains only: no limiter, no peak normalization"}
    (out_dir / "pair.json").write_text(json.dumps(meta, indent=2, default=float))
    return meta
