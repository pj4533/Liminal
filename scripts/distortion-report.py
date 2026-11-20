#!/usr/bin/env python3
"""Distortion and headroom report for one check-lofi.sh capture (measured, not by ear).

  python3 scripts/distortion-report.py CAPTURE [--out DIR] [--aac FILE ...] [--encode-test [--encode-trim DB]]
                                       [--against CAPTURE [--moved STEM,...]] [--json OUT.json] [--strict]
  python3 scripts/distortion-report.py --bass-samples

Applies the usual engineering checks to every stem WAV and bus tap of a capture and prints one table per
section (also written as JSON to OUT_DIR/distortion-report.json):

1. Levels: sample peak, 4x-oversampled true peak (BS.1770-4 Annex 2 style; scipy polyphase FIR rather than
   the 48-tap reference filter), runs of three or more consecutive samples within 0.01 dB of the file's own
   peak or at/above full scale (the Sound Forge / MATLAB clip-run test; the 0.01 dB form also fires on the
   slow crest of any low note, so `flat` counts runs of identical samples, a digital flat top), an
   amplitude-histogram ratio (sample density in the top 10% of the peak over the 50-90% band, per unit
   width; it rises when a stage piles samples up under a ceiling, after Laguna and Lerch, and is meant to
   be compared between a stage's input and output, not read alone), RMS
   against the -18 dBFS nominal, crest factor, integrated loudness and PLR (true peak minus loudness).
2. Stage null tests. Two taps that bracket a stage are aligned (cross-correlation), the output is matched
   to the input by a 5.3 ms block gain (256-sample Hann blocks, 50% overlap), and the residual is what a
   gain change cannot explain: waveform-shape change, i.e. distortion. Reported: residual re output
   overall, while the stage is reducing gain and while it is not (the linear floor), octave-band residual
   re the output band, kurtosis, spectral flatness and the tonal share of the residual. The finisher
   (master-in -> master) also gets a model of its own 64-frame gain trace (master-gr.csv, as
   scripts/solo-stems.py). Also: the sum of the six music stems against the lofi tap (mixer linearity).
3. Gain reduction: mean, p95, p99 and max of glue, clip, limiter and total from master-gr.csv, share of
   time over 1 and 3 dB, and for every clip or limiter event (hops over 0.1 dB) which stem carried the
   peak (projection of each stage-scaled stem on the master input in +-1 ms around the event's peak), and
   how many events start within 80 ms after a bass onset or a drum kick.
4. Bass: on sustained bass notes (score.json role bass, at least 300 ms after a 100 ms onset skip) the
   levels of harmonics 2 to 10 re the fundamental, THD (h2..h10) and THD of the upper orders (h5..h10,
   above the additive sub's designed partials), the inharmonic share (30 to 1400 Hz energy off the
   harmonic series: IMD and aliasing products), grouped by the phrase's bass voice
   (diagnostics.bass[].voice); the energy of bass.wav above 2.5 kHz (the chain low-passes at 1.4 kHz, so
   it is made after the chain: kick duck and edge envelopes) in the 30 ms after kicks against the rest;
   and the same high band of the solo bass at final-mix level with and without the master gain trace.
5. Lossy encoding: for each --aac file (m4a/mp4), the float decode's peak, true peak and samples over full
   scale, and the 16-bit decode's clipped samples. With --encode-test the capture's master and the solo
   stems at final-mix level are encoded to AAC at 256k and 160k with ffmpeg's aac encoder (the settings
   scripts/solo-stems.py and the README preview use) and measured against their sources.

6. Gates (--strict): the `distortion` block of scripts/mix-criteria.json (G1 to G7 of
   docs/plans/mix-distortion.md section 4.1). Each gate names a path into this report's JSON and a bound;
   a gate whose metric is absent (a voice not in the capture, a stage engaged under 10 ms) is skipped.
   Exit status 1 when any gate fails.
7. --against CAPTURE: sample-exact null of each stem and the lofi tap against another capture of the same
   seed (G7). The five rendered music stems are bit-identical run to run; the film soundtrack decode is
   not (about -135 dB re itself between two runs of one build, 20 November 2026), which reaches the
   footage tap at about -92 dB and, through the chops' film source, dialogue-chops and lofi at about
   -105 and -115 dB. So the music stems and the film-derived taps are gated separately.
   --moved names stems allowed to differ (their rows are reported, not gated).
8. Drum tape stage: the null test across the drum bus tape saturation that LofiStemChains runs on each
   take in a capture (manifest diagnostics.stemChains, tapeResidualDb and tapeResidual1to4kDb; same block
   gain model as section 2), overall and in 1 to 4 kHz. Intended colour: a follow-up only above -30 dB.
9. --bass-samples (no capture): per bundled LofiBass-*-long-* sample, the body band (zero-phase
   high-pass 160 Hz 2-pole and 110 Hz 4-pole, low-pass 360 Hz upright / 400 Hz flatwound, 4-pole, as
   LofiBassVoice), the energy in 120 to 450 Hz off exact multiples of the measured fundamental and off
   the tracked (stretched) partials, and the partial offsets in cents.

Also: the wet stem's share of samples in boundedWet's shoulder (above 0.25 linked peak; the tap follows
the duck fader, so a lower bound) with the implied reduction, and bass.wav samples above the headroom
guard's 0.74 knee.

Reference thresholds printed with the numbers: -1 dBTP programme ceiling (EBU R128 / EBU Tech 3341;
AES TD1008 for lossy-codec input), -18 dBFS RMS nominal per track (common gain-staging guidance: Avid,
Sound On Sound), end-of-chain limiting of about 2 dB typical (iZotope), zero clip runs.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf
from scipy.signal import butter, resample_poly, sosfilt, sosfiltfilt, welch
from scipy.stats import kurtosis

STEMS = ["drums", "bass", "dry", "texture", "wet", "dialogue-chops", "footage"]
MUSIC = ["drums", "bass", "dry", "texture", "wet", "dialogue-chops"]
TAPS = ["lofi", "pre-master", "glue", "master-in", "master"]
# Taps with no film-derived content: bit-identical between captures of one seed and build.
FILM_FREE = ["drums", "bass", "dry", "texture", "wet"]
NOMINAL_RMS = -18.0
CEILING_DBTP = -1.0
SHARE_CEILING_DBTP = -1.5
OCTAVES = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(HERE, "..", "Liminal", "Audio", "Lofi", "InstrumentSamples")
# Share clips are lowered by this before the lossy encode (scripts/solo-stems.py ENCODE_TRIM_DB, D121).
ENCODE_TRIM_DB = -1.0


def db(x, floor=1e-12):
    return float(20 * np.log10(max(float(x), floor)))


def pdb(x, floor=1e-24):
    return float(10 * np.log10(max(float(x), floor)))


def read(cap, name):
    path = os.path.join(cap, f"{name}.wav")
    if not os.path.isfile(path):
        return None, None
    x, sr = sf.read(path, dtype="float64", always_2d=True)
    return x, sr


def true_peak(x, factor=4):
    return max(float(np.abs(resample_poly(x[:, c], factor, 1)).max()) for c in range(x.shape[1]))


def runs(mask, min_len=3):
    """Number of runs of at least min_len consecutive True values, per channel summed."""
    total = 0
    for c in range(mask.shape[1]):
        m = mask[:, c].astype(np.int8)
        d = np.diff(np.concatenate(([0], m, [0])))
        starts, ends = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
        total += int(np.sum((ends - starts) >= min_len))
    return total


def flat_runs(x, floor, min_len=3):
    """Runs of >= min_len consecutive samples with the same value (to 1e-6 relative) above floor: a digital
    flat top. Unlike the 0.01 dB test it does not fire on the slow crest of a low note (a 40 Hz sine stays
    within 0.01 dB of its peak for about 19 samples at 48 kHz)."""
    total = 0
    for c in range(x.shape[1]):
        v = x[:, c]
        same = (np.abs(np.diff(v)) <= 1e-6 * np.abs(v[1:])) & (np.abs(v[1:]) >= floor)
        total += runs(same[:, None], min_len - 1)
    return total


def loudness(x, sr):
    try:
        import pyloudnorm as pyln
        v = pyln.Meter(sr).integrated_loudness(x)
        return float(v) if np.isfinite(v) else None
    except Exception:
        return None


def level_row(x, sr):
    a = np.abs(x)
    peak = float(a.max())
    if peak <= 0:
        return {"silent": True}
    tp = true_peak(x)
    rms = np.sqrt(np.mean(x ** 2))
    w = int(0.4 * sr)
    n = len(x) // w
    win = np.sqrt(np.mean(x[: n * w].reshape(n, w, -1) ** 2, axis=(1, 2)))
    active = win[win > max(win) * 10 ** (-30 / 20)]
    hist_top = np.sum(a >= 0.9 * peak) / 0.1
    hist_band = np.sum((a >= 0.5 * peak) & (a < 0.9 * peak)) / 0.4
    lufs = loudness(x, sr)
    return {
        "peakDbfs": db(peak), "truePeakDbtp": db(tp), "rmsDbfs": db(rms),
        "activeRmsDbfs": db(np.sqrt(np.mean(active ** 2))) if len(active) else None,
        "crestDb": db(peak) - db(rms),
        "runsAtOwnPeak": runs(a >= peak * 10 ** (-0.01 / 20)),
        "flatRunsAtPeak": flat_runs(x, peak * 10 ** (-0.5 / 20)),
        "runsAtFullScale": runs(a >= 1.0),
        "runsWithin0p1dBofFS": runs(a >= 10 ** (-0.1 / 20)),
        "samplesOverFS": int(np.sum(a > 1.0)),
        "flatTopRatio": float(hist_top / hist_band) if hist_band > 0 else None,
        "lufs": lufs, "plrDb": db(tp) - lufs if lufs is not None else None,
    }


def align(x, y, max_lag=4000, seconds=20, sr=48000):
    """Integer lag L so that y[t] ~ x[t - L], from the loudest stretch of x."""
    m = x.mean(axis=1)
    n = min(len(m), int(seconds * sr))
    hop = n // 2
    best, start = -1, 0
    for s in range(0, max(1, len(m) - n), hop):
        e = float(np.sum(m[s:s + n] ** 2))
        if e > best:
            best, start = e, s
    a = m[start:start + n]
    b = y.mean(axis=1)[start:start + n + max_lag]
    size = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(b, size) * np.conj(np.fft.rfft(a, size)), size)[: max_lag + 1]
    return int(np.argmax(c))


def shift(x, lag):
    y = np.zeros_like(x)
    if lag >= 0:
        y[lag:] = x[: len(x) - lag]
    else:
        y[:lag] = x[-lag:]
    return y


def block_gain_model(x, y, n=256):
    """y ~ G(t) x(t), G a 50%-overlap Hann interpolation of weighted least-squares block gains."""
    hop = n // 2
    w = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)  # periodic Hann, sums to 1 at hop n/2
    frames = (len(x) // hop) * hop
    xy = np.sum(x[:frames] * y[:frames], axis=1).reshape(-1, hop)
    xx = np.sum(x[:frames] ** 2, axis=1).reshape(-1, hop)
    num = xy @ w[:hop]
    num[:-1] += xy[1:] @ w[hop:]
    den = xx @ w[:hop]
    den[:-1] += xx[1:] @ w[hop:]
    g = np.where(den > 1e-10, num / np.maximum(den, 1e-30), 1.0)
    # G over segment k: w[hop + i] g[k - 1] + w[i] g[k]
    gk = g
    gprev = np.concatenate(([g[0]], g[:-1]))
    G = (gprev[:, None] * w[hop:][None, :] + gk[:, None] * w[:hop][None, :]).reshape(-1)
    G = np.concatenate((G, np.full(len(x) - frames, g[-1])))
    return x * G[:, None], G


def octave_table(r, ref, sr):
    f, pr = welch(r, fs=sr, nperseg=8192, axis=0)
    _, po = welch(ref, fs=sr, nperseg=8192, axis=0)
    pr, po = pr.sum(axis=1), po.sum(axis=1)
    out = {}
    for c in OCTAVES:
        sel = (f >= c / np.sqrt(2)) & (f < min(c * np.sqrt(2), sr / 2))
        out[str(c)] = {"residualReOutputDb": pdb(pr[sel].sum() / max(po[sel].sum(), 1e-30)),
                       "residualDbfs": pdb(pr[sel].sum() * (f[1] - f[0]))}
    return out


def residual_character(r, sr):
    m = r.mean(axis=1)
    f, p = welch(m, fs=sr, nperseg=4096)
    p = p[(f > 20) & (f < 20000)]
    flat = float(np.exp(np.mean(np.log(p + 1e-30))) / (np.mean(p) + 1e-30))
    from scipy.ndimage import median_filter
    base = median_filter(p, size=31)
    tonal = float(p[p > base * 10].sum() / max(p.sum(), 1e-30))
    return {"kurtosis": float(kurtosis(m, fisher=True)), "spectralFlatness": flat, "tonalShare": tonal}


def null_test(x, y, sr, engaged=None, prefilter=None):
    if prefilter is not None:
        x = sosfilt(prefilter, x, axis=0)
    lag = align(x, y, sr=sr)
    xs = shift(x, lag)
    model, G = block_gain_model(xs, y)
    r = y - model
    out = {"lagFrames": lag, "residualReOutputDb": pdb(np.sum(r ** 2) / max(np.sum(y ** 2), 1e-30)),
           "residualRmsDbfs": db(np.sqrt(np.mean(r ** 2))), "gainRangeDb": [db(np.percentile(G, 1)), db(np.percentile(G, 99))]}
    if engaged is not None:
        for key, mask in (("whileReducing", engaged), ("whileLinear", ~engaged)):
            if mask.sum() > sr * 0.05:
                out[key] = {"residualReOutputDb": pdb(np.sum(r[mask] ** 2) / max(np.sum(y[mask] ** 2), 1e-30)),
                            "seconds": float(mask.sum() / sr)}
    out["octaves"] = octave_table(r, y, sr)
    if engaged is not None and engaged.sum() > 8192:
        out["octavesWhileReducing"] = octave_table(r[engaged], y[engaged], sr)
    out["character"] = residual_character(r, sr)
    return out, r, lag


def gr_trace(cap, frames):
    path = os.path.join(cap, "master-gr.csv")
    if not os.path.isfile(path):
        return None
    gr = np.loadtxt(path, delimiter=",", skiprows=1)
    return gr


def gr_stats(gr, hop_frames, sr, latency, stems, master_in, bass_on, kicks):
    out = {}
    names = ["glue", "clip", "limiter"]
    total = gr[:, 1] + gr[:, 2] + gr[:, 3]
    for i, name in enumerate(names + ["total"]):
        v = gr[:, i + 1] if name != "total" else total
        out[name] = {"meanDb": float(v.mean()), "p95Db": float(np.percentile(v, 95)), "p99Db": float(np.percentile(v, 99)),
                     "maxDb": float(v.max()), "over1dB": float(np.mean(v > 1)), "over3dB": float(np.mean(v > 3)),
                     "engaged": float(np.mean(v > 0.01))}
    # Events: contiguous hops where clip + limiter > 0.1 dB.
    hard = gr[:, 2] + gr[:, 3]
    out["clipPlusLimiter"] = {"maxDb": float(hard.max()), "engaged": float(np.mean(hard > 0.1))}
    mask = hard > 0.1
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    starts, ends = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
    events = []
    for s, e in zip(starts, ends):
        f0 = int(gr[s, 0]) - latency
        f1 = int(gr[e - 1, 0]) + hop_frames - latency
        f0, f1 = max(0, f0), min(len(master_in), f1)
        if f1 <= f0:
            continue
        seg = np.abs(master_in[f0:f1]).max(axis=1)
        pk = f0 + int(np.argmax(seg))
        a, b = max(0, pk - sr // 1000), min(len(master_in), pk + sr // 1000)
        x = master_in[a:b]
        xx = float(np.sum(x * x))
        shares = {k: float(np.sum(v[a:b] * x) / xx) if xx > 0 else 0.0 for k, v in stems.items()}
        dom = max(shares, key=shares.get)
        near_bass = bool(np.any((pk - bass_on >= 0) & (pk - bass_on <= int(0.08 * sr)))) if len(bass_on) else False
        near_kick = bool(np.any((pk - kicks >= 0) & (pk - kicks <= int(0.08 * sr)))) if len(kicks) else False
        events.append({"peakFrame": pk, "clipMaxDb": float(gr[s:e, 2].max()), "limiterMaxDb": float(gr[s:e, 3].max()),
                       "dominant": dom, "shares": shares, "afterBassOnset": near_bass, "afterKick": near_kick})
    summary = {"count": len(events)}
    for thr in (0.1, 0.5, 1.0, 1.5):
        m = gr[:, 2] > thr
        summary[f"clipBurstsOver{thr}dB"] = int(np.sum(np.diff(np.concatenate(([0], m.astype(np.int8), [0]))) == 1))
    if events:
        doms = {}
        for ev in events:
            doms[ev["dominant"]] = doms.get(ev["dominant"], 0) + 1
        summary["dominantCounts"] = dict(sorted(doms.items(), key=lambda kv: -kv[1]))
        summary["meanShare"] = {k: float(np.mean([ev["shares"][k] for ev in events])) for k in stems}
        summary["afterBassOnsetFraction"] = float(np.mean([ev["afterBassOnset"] for ev in events]))
        summary["afterKickFraction"] = float(np.mean([ev["afterKick"] for ev in events]))
        summary["worst"] = sorted(events, key=lambda ev: -(ev["clipMaxDb"] + ev["limiterMaxDb"]))[:8]
    out["events"] = summary
    return out


def bass_notes(cap):
    score = json.load(open(os.path.join(cap, "score.json")))
    man = json.load(open(os.path.join(cap, "manifest.json")))
    voices = {e["phrase"]: e.get("voice") for e in man.get("diagnostics", {}).get("bass", [])}
    notes = []
    for p, phrase in enumerate(score):
        for n in phrase["notes"]:
            if n["role"] == "bass":
                notes.append({"on": n["on"], "off": n["off"], "midi": n["midi"], "phrase": p, "voice": voices.get(p, "?"),
                              "stroke": n.get("stroke")})
    return notes


def harmonic_analysis(x, sr, notes):
    """Per sustained note: harmonic levels re the fundamental, THD, inharmonic share."""
    rows = []
    for n in notes:
        a = n["on"] + int(0.10 * sr)
        b = min(n["off"], len(x), a + sr)
        if b - a < int(0.30 * sr):
            continue
        seg = x[a:b]
        L = len(seg)
        win = np.hanning(L)
        size = 1 << int(np.ceil(np.log2(L * 8)))
        spec = np.abs(np.fft.rfft(seg * win, size)) ** 2
        f = np.fft.rfftfreq(size, 1 / sr)
        f_nom = 440 * 2 ** ((n["midi"] - 69) / 12)
        sel = (f > f_nom * 0.96) & (f < f_nom * 1.04)
        f0 = float(f[sel][np.argmax(spec[sel])])
        half = max(2.5 * sr / L, 2.0)
        harm = []
        mask = np.zeros_like(f, dtype=bool)
        for k in range(1, 11):
            band = (f >= k * f0 - half) & (f <= k * f0 + half)
            mask |= band
            harm.append(float(spec[band].sum()))
        rng = (f >= 30) & (f <= 1400)
        total = spec[rng].sum()
        inh = spec[rng & ~mask].sum()
        h1 = harm[0]
        rows.append({"on": n["on"], "midi": n["midi"], "voice": n["voice"], "f0": f0, "seconds": L / sr,
                     "levelDbfs": db(np.sqrt(np.mean(seg ** 2))),
                     "harmonicsDb": [pdb(h / h1) for h in harm[1:]],
                     "thdPct": float(100 * np.sqrt(sum(harm[1:]) / h1)),
                     "thdUpperPct": float(100 * np.sqrt(sum(harm[4:]) / h1)),
                     "inharmonicDb": pdb(inh / total)})
    groups = {}
    for r in rows:
        groups.setdefault(r["voice"], []).append(r)
    summary = {}
    for v, rs in groups.items():
        hm = np.array([r["harmonicsDb"] for r in rs])
        summary[v] = {"notes": len(rs), "medianHarmonicsDb": {f"h{k + 2}": float(np.median(hm[:, k])) for k in range(9)},
                      "medianThdPct": float(np.median([r["thdPct"] for r in rs])),
                      "maxThdPct": float(np.max([r["thdPct"] for r in rs])),
                      "medianThdUpperPct": float(np.median([r["thdUpperPct"] for r in rs])),
                      "maxThdUpperPct": float(np.max([r["thdUpperPct"] for r in rs])),
                      "medianInharmonicDb": float(np.median([r["inharmonicDb"] for r in rs])),
                      "maxInharmonicDb": float(np.max([r["inharmonicDb"] for r in rs]))}
    return summary, rows


def hf_energy(x, sr, lo=2500):
    sos = butter(6, lo, "highpass", fs=sr, output="sos")
    return sosfilt(sos, x, axis=0)


def windows_db(sig, starts, sr, length, ref_total):
    if not len(starts):
        return None
    e = 0.0
    n = 0
    for s in starts:
        seg = sig[s:s + length]
        e += float(np.sum(seg ** 2))
        n += len(seg)
    return pdb(e / max(n, 1) / ref_total) if n else None


def decode(path, sample_fmt="f32le", rate=48000):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-vn", "-f", sample_fmt, "-ac", "2", "-ar", str(rate), "-"],
                         check=True, capture_output=True).stdout
    if sample_fmt == "f32le":
        return np.frombuffer(raw, dtype="<f4").astype(np.float64).reshape(-1, 2)
    return np.frombuffer(raw, dtype="<i2").reshape(-1, 2)


def aac_row(path):
    x = decode(path)
    s16 = decode(path, "s16le")
    return {"file": path, "peakDbfs": db(np.abs(x).max()), "truePeakDbtp": db(true_peak(x)),
            "samplesOverFS": int(np.sum(np.abs(x) > 1.0)), "runsAtFullScale": runs(np.abs(x) >= 1.0),
            "clipped16bit": int(np.sum((s16 == 32767) | (s16 == -32768)))}


def encode_compare(src_wav, bitrate, tmpdir):
    out = os.path.join(tmpdir, os.path.basename(src_wav).replace(".wav", f"-{bitrate}.m4a"))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", src_wav, "-c:a", "aac", "-b:a", bitrate, out], check=True)
    src, _ = sf.read(src_wav, dtype="float64", always_2d=True)
    row = aac_row(out)
    row.update({"bitrate": bitrate, "sourcePeakDbfs": db(np.abs(src).max()), "sourceTruePeakDbtp": db(true_peak(src))})
    row["truePeakRiseDb"] = row["truePeakDbtp"] - row["sourceTruePeakDbtp"]
    os.remove(out)
    return row


def final_mix_stems(cap, sr, master, pre, man):
    """Solo stems at final-mix level, as scripts/solo-stems.py (with and without the gain trace)."""
    dyn = man.get("diagnostics", {}).get("masterDynamics", {})
    stage = 10 ** (dyn.get("preMasterStagingDb", 0.0) / 20)
    gr = np.loadtxt(os.path.join(cap, "master-gr.csv"), delimiter=",", skiprows=1)
    env = 10 ** (-np.interp(np.arange(len(master)), gr[:, 0], gr[:, 1] + gr[:, 2] + gr[:, 3]) / 20)
    hp = butter(2, dyn.get("settings", {}).get("highpassHz", 25), "highpass", fs=sr, output="sos")
    lat = dyn.get("latencyFrames", 200)

    def chain(x, g, use_env=True):
        y = shift(x, lat)
        y = sosfilt(hp, y, axis=0) * g
        return y * env[:, None] if use_env else y

    r = chain(pre, 1.0)
    g = float(np.sum(r * master) / np.sum(r * r))
    return chain, g, stage, env


def bass_sample_audit():
    """Body-band content of every bundled long bass sample (section 9 of the docstring)."""
    rows = []
    for kit, lp in (("upright", 360.0), ("flatwound", 400.0)):
        for p in sorted(glob.glob(os.path.join(SAMPLES, f"LofiBass-{kit}-long-*.wav"))):
            x, sr = sf.read(p, dtype="float64")
            if x.ndim > 1:
                x = x.mean(axis=1)
            fields = os.path.basename(p)[:-4].split("-")
            midi = int(fields[3])
            on = int(np.argmax(np.abs(x) >= np.abs(x).max() * 0.01))
            y = sosfiltfilt(butter(2, 160, "highpass", fs=sr, output="sos"), x)
            y = sosfiltfilt(butter(4, 110, "highpass", fs=sr, output="sos"), y)
            y = sosfiltfilt(butter(4, lp, "lowpass", fs=sr, output="sos"), y)
            a, b = on + int(0.1 * sr), min(len(x), on + int(1.1 * sr))
            L = b - a
            size = 1 << int(np.ceil(np.log2(L * 8)))
            win = np.hanning(L)
            sp = np.abs(np.fft.rfft(y[a:b] * win, size)) ** 2
            raw = np.abs(np.fft.rfft(x[a:b] * win, size)) ** 2
            fr = np.fft.rfftfreq(size, 1 / sr)
            f_nom = 440 * 2 ** ((midi - 69) / 12)
            sel = (fr > f_nom * 0.96) & (fr < f_nom * 1.04)
            f0 = float(fr[sel][np.argmax(raw[sel])])
            half = max(2.5 * sr / L, 2.0)
            exact = np.zeros_like(fr, dtype=bool)
            tracked = np.zeros_like(fr, dtype=bool)
            cents = {}
            for k in range(1, 25):
                exact |= (fr >= k * f0 - half) & (fr <= k * f0 + half)
                near = (fr > k * f0 * 0.94) & (fr < k * f0 * 1.06)
                fk = float(fr[near][np.argmax((sp if k * f0 > 150 else raw)[near])])
                tracked |= (fr >= fk - half) & (fr <= fk + half)
                if 2 <= k <= 4 or 160 < k * f0 < lp:
                    cents[k] = float(1200 * np.log2(fk / (k * f0)))
            rng = (fr >= 120) & (fr <= 450)
            tot = sp[rng].sum()
            rows.append({"file": os.path.basename(p), "kit": kit, "midi": midi,
                         "roundRobin": int(fields[4]) if len(fields) > 4 else 1, "f0": f0,
                         "offExactDb": pdb(sp[rng & ~exact].sum() / tot),
                         "offTrackedDb": pdb(sp[rng & ~tracked].sum() / tot), "partialCents": cents})
    return rows


def null_against(cap, other, names, moved):
    """Sample-exact residual of each tap against the same tap of another capture, dB re that tap."""
    rows = {}
    for name in names:
        x, _ = read(cap, name)
        y, _ = read(other, name)
        if x is None or y is None:
            continue
        n = min(len(x), len(y))
        r = x[:n] - y[:n]
        rows[name] = {"residualDb": pdb(np.sum(r ** 2) / max(np.sum(y[:n] ** 2), 1e-30)),
                      "lengthDiffFrames": int(len(x) - len(y)), "moved": name in moved}
    music = [v["residualDb"] for k, v in rows.items() if not v["moved"] and k in FILM_FREE]
    film = [v["residualDb"] for k, v in rows.items() if not v["moved"] and k not in FILM_FREE]
    return {"against": os.path.abspath(other), "taps": rows,
            "maxMusicResidualDb": max(music) if music else None, "maxFilmDerivedResidualDb": max(film) if film else None}


def lookup(report, path):
    v = report
    for key in path:
        if isinstance(v, dict) and key in v:
            v = v[key]
        elif isinstance(v, list) and isinstance(key, int) and -len(v) <= key < len(v):
            v = v[key]
        else:
            return None
    return v


def evaluate_gates(report, criteria_path):
    block = json.load(open(criteria_path)).get("distortion", {})
    rows = []
    for g in block.get("gates", []):
        if g.get("requires") and lookup(report, g["requires"]) is None:
            rows.append({**g, "value": None, "status": "skipped"})
            continue
        if g.get("each"):
            items = lookup(report, g["each"]) or []
            values = [lookup(it, g["path"]) for it in items]
            values = [v for v in values if v is not None]
            value = (max(values) if "max" in g else min(values)) if values else None
        else:
            value = lookup(report, g["path"])
        if value is None:
            value = g.get("absentValue")
        if value is None:
            rows.append({**g, "value": None, "status": "skipped"})
            continue
        ok = ("max" not in g or value <= g["max"]) and ("min" not in g or value >= g["min"])
        rows.append({**g, "value": float(value), "status": "pass" if ok else "fail"})
    return rows


def fmt(v, nd=1):
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def main():
    np.seterr(all="ignore")  # Accelerate-backed matmul raises spurious FP warnings on macOS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--out", help="output directory (default CAPTURE/report)")
    ap.add_argument("--aac", nargs="*", default=[], help="delivered m4a/mp4 files to decode and measure")
    ap.add_argument("--encode-test", action="store_true", help="encode master and solo stems to AAC 256k/160k and measure")
    ap.add_argument("--encode-trim", type=float, default=ENCODE_TRIM_DB,
                    help=f"gain applied before the --encode-test encodes, as the share-clip encode (default {ENCODE_TRIM_DB} dB)")
    ap.add_argument("--against", help="another capture of the same seed: sample-exact stem nulls (G7)")
    ap.add_argument("--moved", default="", help="comma-separated stems allowed to differ from --against")
    ap.add_argument("--bass-samples", action="store_true", help="audit the bundled long bass samples (no capture)")
    ap.add_argument("--strict", action="store_true", help="evaluate the distortion gates; exit 1 on a failure")
    ap.add_argument("--criteria", default=os.path.join(HERE, "mix-criteria.json"))
    ap.add_argument("--json", help="also write the JSON here")
    args = ap.parse_args()
    if args.bass_samples:
        rows = bass_sample_audit()
        print("Bass body samples (120-450 Hz after the body band; dB re the band)")
        print(f"{'file':34s}{'f0':>7s}{'offExact':>10s}{'offTracked':>12s}  partial offsets (cents, k=2,3,4 and body band)")
        for r in rows:
            print(f"{r['file']:34s}{r['f0']:7.1f}{r['offExactDb']:10.1f}{r['offTrackedDb']:12.1f}  "
                  + " ".join(f"{k}:{c:+.0f}" for k, c in r["partialCents"].items()))
        if args.json:
            with open(args.json, "w") as f:
                json.dump(rows, f, indent=1)
        return 0
    if not args.capture:
        ap.error("CAPTURE is required unless --bass-samples")
    cap = os.path.abspath(args.capture)
    out_dir = args.out or os.path.join(cap, "report")
    os.makedirs(out_dir, exist_ok=True)
    man = json.load(open(os.path.join(cap, "manifest.json")))
    report = {"capture": cap, "gitRevision": man.get("gitRevision"), "seed": man.get("seed")}

    audio = {}
    for name in STEMS + TAPS:
        x, sr = read(cap, name)
        if x is not None:
            audio[name] = x
    sr = man.get("sampleRate", 48000)

    # 1. Levels
    print("1. Levels (dBFS; true peak 4x; runs = >=3 consecutive samples)", flush=True)
    print(f"{'tap':15s}{'peak':>7s}{'TP':>7s}{'rms':>7s}{'actRms':>7s}{'crest':>7s}{'LUFS':>7s}{'PLR':>6s}"
          f"{'runPk':>6s}{'flat':>5s}{'runFS':>6s}{'run.1':>6s}{'>FS':>5s}{'flatTop':>8s}")
    levels = {}
    for name in STEMS + TAPS:
        if name not in audio:
            continue
        row = level_row(audio[name], sr)
        levels[name] = row
        if row.get("silent"):
            print(f"{name:15s} silent")
            continue
        print(f"{name:15s}{fmt(row['peakDbfs']):>7s}{fmt(row['truePeakDbtp']):>7s}{fmt(row['rmsDbfs']):>7s}"
              f"{fmt(row['activeRmsDbfs']):>7s}{fmt(row['crestDb']):>7s}{fmt(row['lufs']):>7s}{fmt(row['plrDb']):>6s}"
              f"{row['runsAtOwnPeak']:>6d}{row['flatRunsAtPeak']:>5d}{row['runsAtFullScale']:>6d}{row['runsWithin0p1dBofFS']:>6d}{row['samplesOverFS']:>5d}"
              f"{fmt(row['flatTopRatio'], 2):>8s}", flush=True)
    report["levels"] = levels
    print(f"   thresholds: master TP <= {CEILING_DBTP} dBTP (EBU R128/Tech 3341), share clips <= {SHARE_CEILING_DBTP} dBTP; "
          f"stem RMS ~ {NOMINAL_RMS} dBFS nominal; zero clip runs")

    # GR trace and engaged masks
    gr = gr_trace(cap, len(audio.get("master", [])))
    dyn = man.get("diagnostics", {}).get("masterDynamics", {})
    hop = dyn.get("traceHopFrames", 64)
    lat = dyn.get("latencyFrames", 200)
    engaged_master = None
    if gr is not None and "master" in audio:
        tot = np.interp(np.arange(len(audio["master"])), gr[:, 0], gr[:, 2] + gr[:, 3])
        engaged_master = tot > 0.1

    # 2. Null tests
    print("\n2. Stage null tests (residual a 5.3 ms gain cannot explain, dB re the stage output)", flush=True)
    nulls = {}
    pairs = [("pre-master", "glue", None), ("glue", "master-in", None), ("master-in", "master", "finisher")]
    for a, b, kind in pairs:
        if a not in audio or b not in audio:
            continue
        pre = None
        if kind == "finisher":
            pre = butter(2, dyn.get("settings", {}).get("highpassHz", 25), "highpass", fs=sr, output="sos")
        res, r, lag = null_test(audio[a], audio[b], sr, engaged=engaged_master if kind else None, prefilter=pre)
        if kind == "finisher" and gr is not None:
            t = np.arange(len(r))
            clip = np.interp(t, gr[:, 0], gr[:, 2])
            lim = np.interp(t, gr[:, 0], gr[:, 3])
            glue = np.interp(t, gr[:, 0], gr[:, 1])
            band = butter(4, [1000, 4000], "bandpass", fs=sr, output="sos")
            rb, yb = sosfilt(band, r, axis=0), sosfilt(band, audio[b], axis=0)
            split = {}
            for key, mask in (("clipOver0p1", clip > 0.1), ("clipOver1", clip > 1.0),
                              ("limiterOnly", (lim > 0.1) & (clip <= 0.01)),
                              ("glueOnlyOver1", (glue > 1.0) & (clip <= 0.01) & (lim <= 0.01)),
                              ("noClipNoLimiter", (clip <= 0.01) & (lim <= 0.01))):
                if mask.sum() > sr * 0.01:
                    split[key] = {"seconds": float(mask.sum() / sr),
                                  "residualReOutputDb": pdb(np.sum(r[mask] ** 2) / max(np.sum(audio[b][mask] ** 2), 1e-30)),
                                  "band1to4kReOutputBandDb": pdb(np.sum(rb[mask] ** 2) / max(np.sum(yb[mask] ** 2), 1e-30))}
            res["byStage"] = split
        nulls[f"{a}->{b}"] = res
        line = f"   {a}->{b}: lag {lag}, residual {fmt(res['residualReOutputDb'])} dB ({fmt(res['residualRmsDbfs'])} dBFS)"
        if "whileReducing" in res:
            line += (f"; while clip/limiter > 0.1 dB {fmt(res['whileReducing']['residualReOutputDb'])} dB "
                     f"({fmt(res['whileReducing']['seconds'], 2)} s), linear {fmt(res['whileLinear']['residualReOutputDb'])} dB")
        print(line, flush=True)
        if kind == "finisher":
            for k, v in res.get("byStage", {}).items():
                print(f"      {k:16s} {v['seconds']:7.2f} s  residual {v['residualReOutputDb']:6.1f} dB  (1-4 kHz band {v['band1to4kReOutputBandDb']:6.1f} dB)")
            ch = res["character"]
            print(f"      residual kurtosis {fmt(ch['kurtosis'])}, flatness {fmt(ch['spectralFlatness'], 3)}, tonal share {fmt(ch['tonalShare'], 2)}")
            print("      octave residual re output (dB): " + "  ".join(f"{k}:{fmt(v['residualReOutputDb'])}" for k, v in res["octaves"].items()))
            if "octavesWhileReducing" in res:
                print("      same, while reducing:          " + "  ".join(f"{k}:{fmt(v['residualReOutputDb'])}" for k, v in res["octavesWhileReducing"].items()))
            # Gain-trace model (as solo-stems.py): what the 64-frame trace leaves.
            x = shift(sosfilt(pre, audio[a], axis=0), lat)
            env = 10 ** (-np.interp(np.arange(len(x)), gr[:, 0], gr[:, 1] + gr[:, 2] + gr[:, 3]) / 20)
            m = x * env[:, None]
            g = float(np.sum(m * audio[b]) / np.sum(m * m))
            rt = audio[b] - g * m
            res["traceModel"] = {"staticGainDb": db(g), "residualReOutputDb": pdb(np.sum(rt ** 2) / np.sum(audio[b] ** 2))}
            if engaged_master is not None:
                for key, mask in (("whileReducing", engaged_master), ("whileLinear", ~engaged_master)):
                    res["traceModel"][key] = pdb(np.sum(rt[mask] ** 2) / max(np.sum(audio[b][mask] ** 2), 1e-30))
            print(f"      64-frame gain-trace model: residual {fmt(res['traceModel']['residualReOutputDb'])} dB "
                  f"(reducing {fmt(res['traceModel'].get('whileReducing'))}, linear {fmt(res['traceModel'].get('whileLinear'))})")
            # High band growth: master vs aligned input above 10 kHz, during reduction.
            hi = butter(6, 10000, "highpass", fs=sr, output="sos")
            xh, yh = sosfilt(hi, x, axis=0), sosfilt(hi, audio[b], axis=0)
            if engaged_master is not None and engaged_master.sum():
                em = engaged_master
                res["above10k"] = {"outMinusInReducingDb": pdb(np.sum(yh[em] ** 2) / max(np.sum((g * xh[em]) ** 2), 1e-30)),
                                   "outMinusInLinearDb": pdb(np.sum(yh[~em] ** 2) / max(np.sum((g * xh[~em]) ** 2), 1e-30))}
                print(f"      energy above 10 kHz, output re gain-matched input: reducing {fmt(res['above10k']['outMinusInReducingDb'], 2)} dB, "
                      f"linear {fmt(res['above10k']['outMinusInLinearDb'], 2)} dB")
    if all(k in audio for k in MUSIC + ["lofi"]):
        s = sum(audio[k] for k in MUSIC)
        r = audio["lofi"] - s
        nulls["stems->lofi"] = {"residualReOutputDb": pdb(np.sum(r ** 2) / np.sum(audio["lofi"] ** 2))}
        print(f"   sum of six music stems -> lofi: residual {fmt(nulls['stems->lofi']['residualReOutputDb'])} dB (sample exact, no fit)")
    if all(k in audio for k in ["lofi", "footage", "pre-master"]):
        stage = 10 ** (dyn.get("preMasterStagingDb", 0.0) / 20)
        r = audio["pre-master"] - stage * (audio["lofi"] + audio["footage"])
        nulls["lofi+footage->pre-master"] = {"residualReOutputDb": pdb(np.sum(r ** 2) / np.sum(audio["pre-master"] ** 2))}
        print(f"   staged lofi + footage -> pre-master: residual {fmt(nulls['lofi+footage->pre-master']['residualReOutputDb'])} dB")
    report["nulls"] = nulls

    # 3. Gain reduction and who carries the peaks
    notes = bass_notes(cap)
    bass_on = np.array([n["on"] for n in notes])
    kicks = np.array([k["frame"] for k in man.get("kickCandidates", [])])
    if gr is not None and "master-in" in audio:
        stage = 10 ** (dyn.get("preMasterStagingDb", 0.0) / 20)
        stems = {k: audio[k] * stage for k in STEMS if k in audio}
        lag_in = align(audio["pre-master"], audio["master-in"], sr=sr) if "pre-master" in audio else 0
        stems = {k: shift(v, lag_in) for k, v in stems.items()}
        g = gr_stats(gr, hop, sr, lat, stems, audio["master-in"], bass_on + lag_in, kicks + lag_in)
        report["gainReduction"] = g
        print("\n3. Master gain reduction (dB; over1/over3 = share of time)", flush=True)
        for k in ["glue", "clip", "limiter", "total"]:
            v = g[k]
            print(f"   {k:8s} mean {v['meanDb']:.2f}  p95 {v['p95Db']:.2f}  p99 {v['p99Db']:.2f}  max {v['maxDb']:.2f}  "
                  f"over1 {v['over1dB']:.2%}  over3 {v['over3dB']:.2%}  engaged {v['engaged']:.2%}")
        ev = g["events"]
        print(f"   clip/limiter events: {ev['count']}; clip bursts over 0.1/0.5/1/1.5 dB: {ev['clipBurstsOver0.1dB']}/"
              f"{ev['clipBurstsOver0.5dB']}/{ev['clipBurstsOver1.0dB']}/{ev['clipBurstsOver1.5dB']}")
        if ev["count"]:
            print(f"   dominant stem at the event peak: {ev['dominantCounts']}")
            print("   mean projection share: " + ", ".join(f"{k} {v:.2f}" for k, v in ev["meanShare"].items()))
            print(f"   events within 80 ms after a bass onset {ev['afterBassOnsetFraction']:.0%}, after a kick {ev['afterKickFraction']:.0%}")
            for w in ev["worst"][:5]:
                print(f"     frame {w['peakFrame']} ({w['peakFrame'] / sr:.2f} s): clip {w['clipMaxDb']:.2f} limiter {w['limiterMaxDb']:.2f} "
                      f"dominant {w['dominant']} " + " ".join(f"{k}:{v:.2f}" for k, v in w["shares"].items() if abs(v) > 0.05))
        print("   reference: end-of-chain limiting typically <= ~2 dB (iZotope); sustained > 6 dB a distortion risk")

    if "wet" in audio:
        pk = np.abs(audio["wet"]).max(axis=1)
        y = np.minimum(pk, 0.25 + 0.13 * 0.9999)
        x = np.where(pk > 0.25, 0.25 + 0.13 * np.arctanh(np.clip((y - 0.25) / 0.13, 0, 0.9999)), pk)
        red = 20 * np.log10(np.maximum(x, 1e-12) / np.maximum(pk, 1e-12))
        report["wetShoulder"] = {"seconds": float(np.sum(pk > 0.25) / sr), "share": float(np.mean(pk > 0.25)),
                                 "impliedMaxReductionDb": float(red.max()), "secondsOver1dB": float(np.sum(red > 1) / sr)}
        w = report["wetShoulder"]
        print(f"\n   wet boundedWet shoulder (lower bound): {w['seconds']:.2f} s above 0.25, implied max reduction "
              f"{w['impliedMaxReductionDb']:.2f} dB, {w['secondsOver1dB'] * 1000:.0f} ms over 1 dB")

    # 4. Bass
    if "bass" in audio:
        print("\n4. Bass (bass.wav, pre-master stem)", flush=True)
        b = audio["bass"].mean(axis=1)
        summary, rows = harmonic_analysis(b, sr, notes)
        report["bass"] = {"byVoice": summary, "notes": rows, "samplesOverHeadroomKnee": int(np.sum(np.abs(audio["bass"]) > 0.74))}
        print(f"   samples above the headroom guard knee (0.74): {report['bass']['samplesOverHeadroomKnee']}")
        for v, s in summary.items():
            hs = " ".join(f"{k}:{x:.0f}" for k, x in s["medianHarmonicsDb"].items())
            print(f"   {v:10s} {s['notes']:2d} notes  median {hs} dB re h1")
            print(f"   {'':10s} THD median {s['medianThdPct']:.1f}% (max {s['maxThdPct']:.1f}), upper h5-h10 median "
                  f"{s['medianThdUpperPct']:.2f}% (max {s['maxThdUpperPct']:.2f}), inharmonic median {s['medianInharmonicDb']:.1f} dB "
                  f"(max {s['maxInharmonicDb']:.1f})")
        hfb = hf_energy(b, sr)
        tot = float(np.mean(b ** 2))
        L = int(0.03 * sr)
        kick_starts = [int(k) for k in kicks if k + L < len(b)]
        kmask = np.zeros(len(b), dtype=bool)
        for k in kick_starts:
            kmask[k:k + L] = True
        rest = hfb[~kmask]
        report["bass"]["above2k5"] = {
            "wholeReStemDb": pdb(np.mean(hfb ** 2) / tot),
            "afterKicksReStemDb": windows_db(hfb, kick_starts, sr, L, tot),
            "restReStemDb": pdb(np.mean(rest ** 2) / tot),
            "peakDbfs": db(np.abs(hfb).max())}
        a2 = report["bass"]["above2k5"]
        print(f"   bass.wav above 2.5 kHz: whole {fmt(a2['wholeReStemDb'])} dB re stem power, 30 ms after kicks "
              f"{fmt(a2['afterKicksReStemDb'])} dB, elsewhere {fmt(a2['restReStemDb'])} dB; peak {fmt(a2['peakDbfs'])} dBFS")
        if "master" in audio and "pre-master" in audio and gr is not None:
            chain, gfin, stage, env = final_mix_stems(cap, sr, audio["master"], audio["pre-master"], man)
            with_env = chain(audio["bass"] * stage, gfin, True).mean(axis=1)
            no_env = chain(audio["bass"] * stage, gfin, False).mean(axis=1)
            h1, h0 = hf_energy(with_env, sr), hf_energy(no_env, sr)
            report["bass"]["soloFinalMix"] = {
                "above2k5WithTraceReStemDb": pdb(np.mean(h1 ** 2) / np.mean(with_env ** 2)),
                "above2k5WithoutTraceReStemDb": pdb(np.mean(h0 ** 2) / np.mean(no_env ** 2)),
                "peakDbfs": db(np.abs(with_env).max()), "truePeakDbtp": db(true_peak(with_env[:, None]))}
            sf_ = report["bass"]["soloFinalMix"]
            print(f"   solo bass at final-mix level: above 2.5 kHz {fmt(sf_['above2k5WithTraceReStemDb'])} dB with the master gain trace, "
                  f"{fmt(sf_['above2k5WithoutTraceReStemDb'])} dB without; peak {fmt(sf_['peakDbfs'])} dBFS, TP {fmt(sf_['truePeakDbtp'])} dBTP")

    # 5. Lossy encoding
    aac = {"delivered": [], "encodeTest": []}
    if args.aac:
        print("\n5a. Delivered AAC files (float decode; 16-bit decode clipped samples)", flush=True)
        for p in args.aac:
            row = aac_row(p)
            aac["delivered"].append(row)
            print(f"   {os.path.basename(os.path.dirname(p))}/{os.path.basename(p):24s} peak {row['peakDbfs']:6.2f}  TP {row['truePeakDbtp']:6.2f}  "
                  f">FS {row['samplesOverFS']:5d}  runsFS {row['runsAtFullScale']:3d}  clipped16 {row['clipped16bit']:5d}", flush=True)
    if args.encode_test and "master" in audio and gr is not None:
        print("\n5b. Encode test: capture master and solo stems at final-mix level -> AAC (ffmpeg aac)", flush=True)
        chain, gfin, stage, env = final_mix_stems(cap, sr, audio["master"], audio["pre-master"], man)
        trim = 10 ** (args.encode_trim / 20)
        print(f"   encode trim {args.encode_trim:+.1f} dB on every source (the share-clip encode)")
        with tempfile.TemporaryDirectory() as tmp:
            srcs = [("master", audio["master"] * trim)] + [(k, chain(audio[k] * stage, gfin) * trim) for k in STEMS if k in audio]
            for name, y in srcs:
                wav = os.path.join(tmp, f"{name}.wav")
                sf.write(wav, y.astype(np.float32), sr, subtype="FLOAT")
                for br in ("256k", "160k"):
                    row = encode_compare(wav, br, tmp)
                    row["file"] = name
                    aac["encodeTest"].append(row)
                    print(f"   {name:15s} {br}: source TP {row['sourceTruePeakDbtp']:6.2f} -> {row['truePeakDbtp']:6.2f} dBTP "
                          f"(rise {row['truePeakRiseDb']:+.2f}), >FS {row['samplesOverFS']}, clipped16 {row['clipped16bit']}", flush=True)
                os.remove(wav)
    report["aac"] = aac
    report["encodeTrimDb"] = args.encode_trim
    worst = {}
    for kind in ("delivered", "encodeTest"):
        rows = aac[kind] if kind == "delivered" else [r for r in aac[kind] if r["bitrate"] == "256k"]
        if rows:
            worst[kind] = {"maxTruePeakDbtp": max(r["truePeakDbtp"] for r in rows),
                           "samplesOverFS": sum(r["samplesOverFS"] for r in rows),
                           "clipped16bit": sum(r["clipped16bit"] for r in rows)}
    m256 = [r for r in aac["encodeTest"] if r["file"] == "master" and r["bitrate"] == "256k"]
    if m256:
        worst["master256k"] = m256[0]
    report["aacSummary"] = worst

    # Clip detection over every tap (G4).
    rows = [v for v in levels.values() if not v.get("silent")]
    report["summary"] = {"flatRunsAtPeakAllTaps": sum(v["flatRunsAtPeak"] for v in rows),
                         "runsAtFullScaleAllTaps": sum(v["runsAtFullScale"] for v in rows),
                         "samplesOverFSAllTaps": sum(v["samplesOverFS"] for v in rows)}

    # Drum tape stage (measured in the capture by LofiStemChains.tapeNull).
    takes = [r for r in man.get("diagnostics", {}).get("stemChains", [])
             if r.get("bus") == "drums" and "tapeResidualDb" in r]
    if takes:
        report["drumTape"] = {"takes": [{"take": r.get("take"), "residualReOutputDb": r["tapeResidualDb"],
                                         "band1to4kReOutputBandDb": r["tapeResidual1to4kDb"],
                                         "roundingDb": r.get("saturationRoundingDb")} for r in takes],
                              "maxResidualReOutputDb": max(r["tapeResidualDb"] for r in takes),
                              "maxBand1to4kReOutputBandDb": max(r["tapeResidual1to4kDb"] for r in takes)}
        print("\n8. Drum tape stage (null across the tanh stage, per take; follow-up only above -30 dB in 1-4 kHz)")
        for t in report["drumTape"]["takes"]:
            print(f"   take {t['take']}: rounding {fmt(t['roundingDb'], 2)} dB, residual {fmt(t['residualReOutputDb'])} dB re output, "
                  f"1-4 kHz {fmt(t['band1to4kReOutputBandDb'])} dB re the band")

    if args.against:
        names = STEMS + ["lofi"]
        moved = {m for m in args.moved.split(",") if m}
        report["against"] = null_against(cap, args.against, names, moved)
        print(f"\n7. Sample-exact nulls against {args.against} (dB re that tap; moved: {sorted(moved) or 'none'})")
        for k, v in report["against"]["taps"].items():
            print(f"   {k:15s} {v['residualDb']:8.1f} dB  length diff {v['lengthDiffFrames']}{'  (moved)' if v['moved'] else ''}")

    status = 0
    if args.strict:
        gates = evaluate_gates(report, args.criteria)
        report["gates"] = gates
        print("\n6. Distortion gates (scripts/mix-criteria.json, distortion block)")
        for g in gates:
            bound = " ".join(x for x in (f"<= {g['max']}" if "max" in g else "", f">= {g['min']}" if "min" in g else "") if x)
            val = "-" if g["value"] is None else f"{g['value']:.2f}"
            print(f"   {g['status']:7s} {g['id']:4s} {g['name']:52s} {val:>9s}  {bound}")
        failed = [g for g in gates if g["status"] == "fail"]
        print(f"   {len(gates) - len(failed)} of {len(gates)} pass or skipped; failures: {', '.join(g['id'] + ' ' + g['name'] for g in failed) or 'none'}")
        status = 1 if failed else 0

    path = os.path.join(out_dir, "distortion-report.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=1, default=float)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(report, f, indent=1, default=float)
    print(f"\nReport: {path}")
    return status


if __name__ == "__main__":
    sys.exit(main())
