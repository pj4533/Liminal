#!/usr/bin/env python3
"""Relaxation metrics for a rendered music WAV (numpy/scipy only). See docs/plans/music-calm.md.
Usage: analyze-calm.py file.wav [--json out.json] [--merge analysis.json]
  --merge adds the metrics under the key "calm" to an existing analyze-audio.py json (check-music.py reads
  them as calm.<metric>).

What is measured, and why (the user's words: "super high pitched bell and tinks ... too abrasive"):
  brightness   power-weighted share of the mix above 2 / 3 / 5 / 8 kHz (dB re total), spectral centroid,
               and the loudest moments of the top bands (p95 / p99 of 50 ms frames, dBFS).
  sharpness    how fast and how loud things start. Envelopes of the band above 200 Hz and of the band above
               1.5 kHz (10 ms RMS, 5 ms hop); an "attack step" is the linear rise of the envelope inside
               30 ms. Steps above a level are counted per minute and the steepest are reported. Plus crest
               factor and spectral flux of the band above 2 kHz.
  busyness     attack steps per minute and high-band flux (note counts come from the score log).
  loudness     short-term (3 s) level range p10..p95, true peak.
"""
import sys, json, argparse, warnings
warnings.filterwarnings("ignore")
import numpy as np
from scipy.io import wavfile
from scipy.signal import stft, butter, sosfilt, resample_poly

ap = argparse.ArgumentParser()
ap.add_argument("wav"); ap.add_argument("--json"); ap.add_argument("--merge")
ap.add_argument("--quiet", action="store_true")
a = ap.parse_args()

sr, x = wavfile.read(a.wav, mmap=True)
x = np.asarray(x, dtype=np.float32)
if x.ndim == 1: x = np.stack([x, x], 1)
mono = x.mean(1).astype(np.float64)
dur = len(mono) / sr
res = {"duration_s": round(dur, 1)}
db = lambda v: 20*np.log10(np.maximum(v, 1e-9))
pdb = lambda v: 10*np.log10(np.maximum(v, 1e-18))

# ---- brightness: band power shares (dB re total power), from a 4096-point STFT
f, t, Z = stft(mono, sr, nperseg=4096, noverlap=2048)
P = (np.abs(Z)**2)
tot = P.sum()
for hz in (1000, 2000, 3000, 5000, 8000):
    res[f"share_gt{hz//1000}k_dB"] = round(float(pdb(P[f >= hz].sum()/tot)), 1)
# absolute mean power per band (dBFS): stems of one render add up, so a stem's share of the mix's top end is
# 10^((stem - mix)/10)
nfr = P.shape[1]
res["power_dBFS"] = {k: round(float(pdb(P[(f >= lo) & (f < hi)].sum()/nfr)), 1) for k, (lo, hi) in
                     {"all": (0, 1e9), "gt2k": (2000, 1e9), "gt3k": (3000, 1e9), "gt5k": (5000, 1e9), "gt8k": (8000, 1e9)}.items()}
# power-weighted centroid (the legacy centroid_Hz_mean is magnitude-weighted and frame-averaged, which
# counts a quiet bright frame as much as a loud dark one; both are reported)
res["centroid_power_Hz"] = round(float((f[:, None]*P).sum()/tot))
mag = np.sqrt(P) + 1e-12
cent = (f[:, None]*mag).sum(0)/mag.sum(0)
res["centroid_mag_Hz_mean"] = round(float(cent.mean()))
res["centroid_mag_Hz_p95"] = round(float(np.percentile(cent, 95)))
# 95 % spectral roll-off of the whole render and of the brightest minute
cum = np.cumsum(P.sum(1)); res["rolloff95_Hz"] = round(float(f[np.searchsorted(cum, 0.95*cum[-1])]))
ro = []
for s0 in range(0, int(dur) - 59, 60):
    m = (t >= s0) & (t < s0+60); c = np.cumsum(P[:, m].sum(1)); ro.append(float(f[np.searchsorted(c, 0.95*c[-1])]))
res["rolloff95_Hz_max_minute"] = round(max(ro)) if ro else res["rolloff95_Hz"]
# worst minute share above 3 kHz
sh = []
for s0 in range(0, int(dur) - 59, 60):
    m = (t >= s0) & (t < s0+60); sh.append(float(pdb(P[f >= 3000][:, m].sum()/P[:, m].sum())))
res["share_gt3k_dB_max_minute"] = round(max(sh), 1) if sh else res["share_gt3k_dB"]
del Z, P, mag

# ---- band envelopes: 10 ms RMS, 5 ms hop, dBFS
win, hop = int(0.010*sr), int(0.005*sr)
def env_db(sig):
    n = (len(sig) - win)//hop + 1
    c = np.concatenate([[0.0], np.cumsum(sig.astype(np.float64)**2)])
    i = np.arange(n)*hop
    return db(np.sqrt((c[i+win] - c[i])/win))
def band(lo=None, hi=None):
    if lo and hi: sos = butter(4, [lo, hi], "band", fs=sr, output="sos")
    elif lo: sos = butter(4, lo, "high", fs=sr, output="sos")
    else: sos = butter(4, hi, "low", fs=sr, output="sos")
    return sosfilt(sos, mono)

def frames50(e):   # 50 ms frame level = mean power of 10 consecutive 5 ms hops
    n = len(e)//10
    return pdb((10**(e[:n*10]/10)).reshape(n, 10).mean(1))

hf15 = band(lo=1500); e15 = env_db(hf15)
hf2 = band(lo=2000);  e2 = env_db(hf2)
hf5 = band(lo=5000);  e5 = env_db(hf5)
for name, e in (("gt2k", e2), ("gt5k", e5)):
    fr = frames50(e)
    res[f"level_{name}_dBFS_p95"] = round(float(np.percentile(fr, 95)), 1)
    res[f"level_{name}_dBFS_p99"] = round(float(np.percentile(fr, 99)), 1)
    res[f"level_{name}_dBFS_max"] = round(float(fr.max()), 1)

# ---- sharpness: attack steps. step(t) = env(t) - min(env over the previous 30 ms), in LINEAR amplitude, so
# it is large only when something both starts fast and is loud: a tink that reaches -24 dBFS in 8 ms steps by
# -24 dBFS, the same note with a 150 ms attack by about -38, and the 6 dB beating of a quiet detuned pad by
# less than its own level. (A dB-rise measure counted pad beating and sub-bass ripple as attacks.)
# Bands: "body" = above 200 Hz (below that a 10 ms RMS window ripples with the waveform), "hf" = above 1.5 kHz.
def steps(e_db, thr_db, look=6, refractory=20):
    e = 10**(e_db/20)
    lo = np.full_like(e, np.inf)
    for k in range(1, look+1):
        lo[k:] = np.minimum(lo[k:], e[:-k])
    st = e - lo; st[:look] = 0
    out = {}
    for th in thr_db:
        idx = np.flatnonzero(st >= 10**(th/20))
        n, last = 0, -10**9
        for i in idx:
            if i - last >= refractory: n += 1
            last = i
        out[th] = round(n/(dur/60), 2)
    return out, float(db(np.percentile(st, 99.9))), float(db(st.max()))

body = env_db(band(lo=200))
c, p, mx = steps(body, (-24, -30, -36))
res["attacks_gt-24dB_per_min"] = c[-24]; res["attacks_gt-30dB_per_min"] = c[-30]; res["attacks_gt-36dB_per_min"] = c[-36]
res["attack_step_dBFS_p999"] = round(p, 1); res["attack_step_dBFS_max"] = round(mx, 1)
c, p, mx = steps(e15, (-34, -40, -46))
res["hf_attacks_gt-34dB_per_min"] = c[-34]; res["hf_attacks_gt-40dB_per_min"] = c[-40]; res["hf_attacks_gt-46dB_per_min"] = c[-46]
res["hf_attack_step_dBFS_p999"] = round(p, 1); res["hf_attack_step_dBFS_max"] = round(mx, 1)

# ---- high-band crest factor: per 1 s window, peak / RMS of the band above 2 kHz, where it is audible
w = sr; nw = len(hf2)//w
blk = hf2[:nw*w].reshape(nw, w)
r = np.sqrt((blk**2).mean(1)); pk = np.abs(blk).max(1)
aud = r > 10**(-60/20)
cf = db(pk[aud]/r[aud]) if aud.any() else np.array([0.0])
res["hf_crest_dB_p95"] = round(float(np.percentile(cf, 95)), 1)
res["hf_crest_dB_median"] = round(float(np.median(cf)), 1)

# ---- high-band spectral flux: positive change of the linear magnitude above 2 kHz per 23 ms hop (1024),
# in dBFS-like units (flux of a full-scale sine switching on = about 0 dB)
f2, t2, Z2 = stft(mono, sr, nperseg=2048, noverlap=1024)
M = np.abs(Z2[f2 >= 2000])
fl = np.maximum(0, np.diff(M, axis=1)).sum(0)
res["hf_flux_dB_p99"] = round(float(db(np.percentile(fl, 99))), 1)
res["hf_flux_dB_p999"] = round(float(db(np.percentile(fl, 99.9))), 1)
M = np.abs(Z2)
fl = np.maximum(0, np.diff(M, axis=1)).sum(0)
res["flux_dB_p99"] = round(float(db(np.percentile(fl, 99))), 1)
del Z2, M

# ---- loudness: 3 s short-term level, range p10..p95 above a -20 dB relative gate; true peak (4x)
c = np.concatenate([[0.0], np.cumsum(mono**2)])
i = np.arange(0, len(mono) - 3*sr, sr)
st = pdb((c[i+3*sr] - c[i])/(3*sr))
st = st[5:] if len(st) > 20 else st            # skip the fade-in
g = st[st > pdb((10**(st/10)).mean()) - 20]
res["short_term_dB_mean"] = round(float(pdb((10**(g/10)).mean())), 1)
res["loudness_range_dB"] = round(float(np.percentile(g, 95) - np.percentile(g, 10)), 1)
res["short_term_dB_max_minus_mean"] = round(float(g.max() - pdb((10**(g/10)).mean())), 1)
tp = 0.0
for s0 in range(0, len(x), sr*30):
    tp = max(tp, float(np.abs(resample_poly(x[s0:s0+sr*30], 4, 1, axis=0)).max()))
res["true_peak_dBFS"] = round(float(db(tp)), 2)

if not a.quiet: print(json.dumps(res, indent=1))
if a.json: json.dump(res, open(a.json, "w"), indent=1)
if a.merge:
    A = json.load(open(a.merge)); A["calm"] = res; json.dump(A, open(a.merge, "w"), indent=1)
