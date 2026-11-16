#!/usr/bin/env python3
"""Archive footage sound in an offline render (docs/plans/archive-video.md 4 and 7, decisions A14-A18).
numpy/scipy only.

Usage:
  analyze-archive-audio.py --dir DIR --label L [--base B] [--pad P] [--json out.json] [--plot out.png]
Reads, from DIR (scripts/render-music.sh output, same seed and length for all):
  L.wav            the mix with the archive moment          (ARCHIVE=<mp4>)
  L.archive.json   the moment's timings                     (written by MusicRenderTests)
  L-stem.wav       the archive stem                         (ONLY=archive)
  L-bypass.wav     the mix with the limiter bypassed        (bypass=1)       optional
  B.wav            the same render without the archive     (MUTE=archive)   optional
  P.wav            the pad stem without the archive         (ONLY=pad)       optional

Reports the stem's level over the moment's hold against the pad and the whole mix, its peak, its spectrum
(power above 2 / 3 / 5 kHz, centroid, roll-off, the loudest 50 ms of the band above 3 kHz), the fade shapes
(1 s RMS envelope, time to 90 % on the way in, to -20 dB on the way out, deviation from a smoothstep), whether
the limiter did anything (mix vs bypassed twin) and how the mix's true peak and level moved against the base.
Gates (plan 7):
  stem_hold_rms   -45 ... -39 dBFS (at "Footage audio" 0.5)
  stem_peak       <= -24 dBFS (true peak)
  stem_gt3k_max   loudest 50 ms above 3 kHz <= -60 dBFS
  fade_in_90      >= 8 s from the start of the sound to 90 % of the hold level
  fade_out_20dB   <= the picture's fade out (the sound is gone before the picture)
  limiter_idle    bypassed twin true peak <= -3 dBFS and |mix - bypassed| <= 1e-3 once aligned
                  (bypassing removes the limiter's 10 ms look-ahead delay; needs L-bypass.wav)
  mix_peak_delta  |true peak(mix) - true peak(base)| <= 0.5 dB (needs B.wav)
Exit 1 if a gate fails.
"""
import sys, os, json, argparse, warnings
warnings.filterwarnings("ignore")
import numpy as np
from scipy.io import wavfile
from scipy.signal import stft, butter, sosfilt, resample_poly

ap = argparse.ArgumentParser()
ap.add_argument("--dir", required=True); ap.add_argument("--label", required=True)
ap.add_argument("--base"); ap.add_argument("--pad"); ap.add_argument("--json"); ap.add_argument("--plot")
a = ap.parse_args()
P = lambda n: os.path.join(a.dir, n)

def load(path):
    sr, x = wavfile.read(path, mmap=True)
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1: x = np.stack([x, x], 1)
    return sr, x

db = lambda v: 20 * np.log10(np.maximum(v, 1e-12))
pdb = lambda v: 10 * np.log10(np.maximum(v, 1e-24))
def rms_db(x): return float(pdb(np.mean(x ** 2))) if len(x) else -240.0
def true_peak_db(x):
    return float(db(np.max(np.abs(resample_poly(x, 4, 1, axis=0)))))
def env_db(mono, sr, win=1.0, hop=0.25):
    n, h = int(win * sr), int(hop * sr)
    t, e = [], []
    for s in range(0, len(mono) - n, h):
        t.append((s + n / 2) / sr); e.append(rms_db(mono[s:s + n]))
    return np.array(t), np.array(e)
def smoothstep(u): u = np.clip(u, 0, 1); return u * u * (3 - 2 * u)

T = json.load(open(P(a.label + ".archive.json")))
sr, mix = load(P(a.label + ".wav"))
_, stem = load(P(a.label + "-stem.wav"))
smono = stem.mean(1)
b0, f_in, f_out_at, f_out = T["beginAt"], T["fadeIn"], T["fadeOutAt"], T["fadeOut"]
hold = (b0 + f_in, f_out_at)
seg = lambda x, t0, t1: x[int(t0 * sr):int(t1 * sr)]
R = {"timing": T}

# ---- level
R["stem_hold_rms_dBFS"] = round(rms_db(seg(stem, *hold)), 1)
R["stem_moment_rms_dBFS"] = round(rms_db(seg(stem, b0, f_out_at + f_out)), 1)
R["stem_true_peak_dBFS"] = round(true_peak_db(stem), 1)
R["stem_sample_peak_dBFS"] = round(float(db(np.max(np.abs(stem)))), 1)
R["mix_hold_rms_dBFS"] = round(rms_db(seg(mix, *hold)), 1)
R["stem_below_mix_hold_dB"] = round(R["mix_hold_rms_dBFS"] - R["stem_hold_rms_dBFS"], 1)
if a.pad:
    _, pad = load(P(a.pad + ".wav"))
    R["pad_hold_rms_dBFS"] = round(rms_db(seg(pad, *hold)), 1)
    R["stem_below_pad_hold_dB"] = round(R["pad_hold_rms_dBFS"] - R["stem_hold_rms_dBFS"], 1)
# 1 s RMS of the stem, loudest second
_, se = env_db(smono, sr)
R["stem_rms_1s_max_dBFS"] = round(float(se.max()), 1)

# ---- spectrum of the stem over the moment
x = seg(smono, b0, f_out_at + f_out)
f, t, Z = stft(x, sr, nperseg=4096, noverlap=2048)
Pw = np.abs(Z) ** 2; tot = Pw.sum()
for hz in (1000, 2000, 3000, 5000):
    R[f"stem_share_gt{hz // 1000}k_dB"] = round(float(pdb(Pw[f >= hz].sum() / tot)), 1)
R["stem_centroid_Hz"] = round(float((f[:, None] * Pw).sum() / tot))
cum = np.cumsum(Pw.sum(1)); R["stem_rolloff95_Hz"] = round(float(f[np.searchsorted(cum, 0.95 * cum[-1])]))
# octave band levels (power share, dB re total) for the report
bands = [(63, 125), (125, 250), (250, 500), (500, 1000), (1000, 2000), (2000, 4000), (4000, 8000), (8000, 24000)]
R["stem_octaves_dB"] = {f"{lo}-{hi}": round(float(pdb(Pw[(f >= lo) & (f < hi)].sum() / tot)), 1) for lo, hi in bands}
# loudest 50 ms of the band above 3 kHz (the "highs dark" gate)
hp = sosfilt(butter(8, 3000, "highpass", fs=sr, output="sos"), x)
n = int(0.05 * sr)
fr = [rms_db(hp[s:s + n]) for s in range(0, len(hp) - n, n)]
R["stem_gt3k_50ms_max_dBFS"] = round(float(max(fr)), 1)
R["stem_gt3k_50ms_p99_dBFS"] = round(float(np.percentile(fr, 99)), 1)
if a.base:
    _, base = load(P(a.base + ".wav"))
    bm = seg(base.mean(1), b0, f_out_at + f_out)
    fb, tb, Zb = stft(bm, sr, nperseg=4096, noverlap=2048)
    Pb = np.abs(Zb) ** 2
    mm = seg(mix.mean(1), b0, f_out_at + f_out)
    fm, tm, Zm = stft(mm, sr, nperseg=4096, noverlap=2048)
    Pm = np.abs(Zm) ** 2
    for hz in (2000, 3000, 5000):
        R[f"mix_vs_base_gt{hz // 1000}k_power_dB"] = round(float(pdb(Pm[fm >= hz].sum()) - pdb(Pb[fb >= hz].sum())), 2)
    R["mix_vs_base_moment_rms_dB"] = round(rms_db(seg(mix, b0, f_out_at + f_out)) - rms_db(seg(base, b0, f_out_at + f_out)), 2)
    R["base_true_peak_dBFS"] = round(true_peak_db(base), 2)
    R["mix_true_peak_dBFS"] = round(true_peak_db(mix), 2)
    R["mix_peak_delta_dB"] = round(R["mix_true_peak_dBFS"] - R["base_true_peak_dBFS"], 2)
    # Outside the moment (and its reverb tail) the two renders must be the same music.
    pre = int((b0 - 1) * sr)
    R["mix_vs_base_before_max_abs"] = float(np.max(np.abs(mix[:pre] - base[:pre]))) if pre > 0 else 0.0

# ---- fades (1 s RMS, 0.25 s hop)
te, ee = env_db(smono, sr)
hold_db = R["stem_hold_rms_dBFS"]
lin = lambda d: 10 ** (d / 20)
def first(cond):
    i = np.argmax(cond); return float(te[i]) if cond.any() else None
t90 = first((te >= b0) & (ee >= hold_db + db(0.9)))
R["fade_in_to_90pct_s"] = round(t90 - b0, 1) if t90 else None
t_half = first((te >= b0) & (ee >= hold_db + db(0.5)))
R["fade_in_to_50pct_s"] = round(t_half - b0, 1) if t_half else None
after = te >= f_out_at
t20 = first(after & (ee <= hold_db - 20))
R["fade_out_to_-20dB_s"] = round(t20 - f_out_at, 1) if t20 else None
t40 = first(after & (ee <= hold_db - 40))
R["fade_out_to_-40dB_s"] = round(t40 - f_out_at, 1) if t40 else None
R["picture_fade_out_s"] = round(T["pictureEnd"] - T["pictureFadeOutStart"], 1)
# Shape: the strip's gain follows a smoothstep, so the envelope (amplitude, normalised to the hold) should too.
# Reverb smears it by a second or two; report the mean deviation over the fade in amplitude units.
def shape_dev(t0, dur, rising):
    m = (te >= t0 + 1) & (te <= t0 + dur - 1)
    if not m.any(): return None
    u = (te[m] - t0) / dur
    want = smoothstep(u) if rising else 1 - smoothstep(u)
    got = np.clip(lin(ee[m] - hold_db), 0, 1.5)
    return round(float(np.mean(np.abs(got - want))), 3)
R["fade_in_shape_dev"] = shape_dev(b0, f_in, True)
R["fade_out_shape_dev"] = shape_dev(f_out_at, f_out, False)
R["fade_in_samples"] = [[round(float(tt - b0), 1), round(float(e), 1)] for tt, e in zip(te, ee)
                        if b0 - 1 <= tt <= b0 + f_in + 2][::4]
R["fade_out_samples"] = [[round(float(tt - f_out_at), 1), round(float(e), 1)] for tt, e in zip(te, ee)
                         if f_out_at - 1 <= tt <= f_out_at + f_out + 8][::4]

# ---- limiter
bp = P(a.label + "-bypass.wav")
if os.path.exists(bp):
    _, byp = load(bp)
    # Bypassing the PeakLimiter also removes its 10 ms look-ahead delay: align before comparing.
    w0, w1 = int(b0 * sr), int((b0 + 2) * sr)
    lags = range(-1200, 1201)
    errs = [np.max(np.abs(mix[w0:w1, 0] - byp[w0 + l:w1 + l, 0])) for l in lags]
    lag = list(lags)[int(np.argmin(errs))]
    lo, hi = max(0, -lag), min(len(mix), len(byp) - lag)
    R["limiter_bypass_lag_samples"] = lag
    R["limiter_max_abs_diff_aligned"] = float(np.max(np.abs(mix[lo:hi] - byp[lo + lag:hi + lag])))
    R["bypass_true_peak_dBFS"] = round(true_peak_db(byp), 2)

# ---- gates
G = []
def gate(name, ok, val): G.append((name, bool(ok), val))
gate("stem_hold_rms -45...-39 dBFS", -45 <= R["stem_hold_rms_dBFS"] <= -39, R["stem_hold_rms_dBFS"])
gate("stem_true_peak <= -24 dBFS", R["stem_true_peak_dBFS"] <= -24, R["stem_true_peak_dBFS"])
gate("stem_gt3k_50ms_max <= -60 dBFS", R["stem_gt3k_50ms_max_dBFS"] <= -60, R["stem_gt3k_50ms_max_dBFS"])
gate("fade_in_to_90pct >= 8 s", (R["fade_in_to_90pct_s"] or 0) >= 8, R["fade_in_to_90pct_s"])
gate("fade_out_to_-20dB <= picture fade out", R["fade_out_to_-20dB_s"] is not None
     and R["fade_out_to_-20dB_s"] <= R["picture_fade_out_s"], R["fade_out_to_-20dB_s"])
if "bypass_true_peak_dBFS" in R:
    # Idle: the limiter's input never reaches its threshold (the bypassed twin peaks <= -3 dBFS, the music
    # gate), and the limited mix is the bypassed one delayed by the look-ahead (residual < -60 dB).
    gate("limiter_idle: bypassed true peak <= -3 dBFS", R["bypass_true_peak_dBFS"] <= -3, R["bypass_true_peak_dBFS"])
    gate("limiter_idle: |mix - bypassed| aligned <= 1e-3", R["limiter_max_abs_diff_aligned"] <= 1e-3,
         R["limiter_max_abs_diff_aligned"])
if "mix_peak_delta_dB" in R:
    gate("|mix_peak_delta| <= 0.5 dB", abs(R["mix_peak_delta_dB"]) <= 0.5, R["mix_peak_delta_dB"])
R["gates"] = {n: {"pass": ok, "value": v} for n, ok, v in G}

if a.json:
    json.dump(R, open(a.json, "w"), indent=1)
skip = {"timing", "fade_in_samples", "fade_out_samples", "gates", "stem_octaves_dB"}
for k, v in R.items():
    if k not in skip: print(f"{k:34s} {v}")
print("stem_octaves_dB                   ", R["stem_octaves_dB"])
print("fade in  (s after start, dBFS)    ", R["fade_in_samples"])
print("fade out (s after fade start, dBFS)", R["fade_out_samples"])
for n, ok, v in G: print(f"{'PASS' if ok else 'FAIL'}  {n}  ({v})")

if a.plot:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    fig, ax = plt.subplots(2, 1, figsize=(11, 7))
    tm, em = env_db(mix.mean(1), sr)
    ax[0].plot(tm, em, lw=1, label="mix")
    if a.pad: tp, ep = env_db(pad.mean(1), sr); ax[0].plot(tp, ep, lw=1, label="pad stem")
    ax[0].plot(te, ee, lw=1.5, label="archive stem")
    for x0, c in ((T["pictureStart"], "0.6"), (b0, "g"), (f_out_at, "r"), (T["pictureEnd"], "0.6")):
        ax[0].axvline(x0, color=c, ls="--", lw=0.8)
    ax[0].set_ylim(-80, -10); ax[0].set_ylabel("1 s RMS, dBFS"); ax[0].legend(loc="lower left"); ax[0].grid(alpha=0.3)
    ax[0].set_title("Archive sound in the mix (grey: picture in/out, green: sound starts, red: sound fades out)")
    fs, ts, Zs = stft(x, sr, nperseg=4096, noverlap=3072)
    ax[1].pcolormesh(ts + b0, fs, pdb(np.abs(Zs) ** 2), shading="auto", vmin=-140, vmax=-50, cmap="magma")
    ax[1].set_ylim(0, 8000); ax[1].set_ylabel("Hz"); ax[1].set_xlabel("s"); ax[1].set_title("Archive stem spectrogram")
    fig.tight_layout(); fig.savefig(a.plot, dpi=110)

sys.exit(0 if all(ok for _, ok, _ in G) else 1)
