#!/usr/bin/env python3
"""Analyze a rendered music WAV (numpy/scipy only).
Usage: analyze-audio.py file.wav [--json out.json]
Reports: peak/true-peak/clipping, RMS over time, silence gaps, spectral centroid/bandwidth
trajectory + variance, onset density per 30s, pitch-class histogram, chord-change rate,
novelty / self-similarity between minutes, stereo width.
"""
import sys, json, argparse, warnings
warnings.filterwarnings("ignore")
import numpy as np
from scipy.io import wavfile
from scipy.signal import stft, resample_poly, find_peaks

ap = argparse.ArgumentParser()
ap.add_argument("wav"); ap.add_argument("--json")
a = ap.parse_args()

sr, x = wavfile.read(a.wav)
if x.dtype.kind == "i": x = x / np.iinfo(x.dtype).max
x = x.astype(np.float64)
if x.ndim == 1: x = np.stack([x, x], 1)
L, R = x[:, 0], x[:, 1]
mono = x.mean(1)
dur = len(mono) / sr
res = {"file": a.wav, "sr": sr, "duration_s": round(dur, 1)}

# ---- levels
peak = float(np.abs(x).max())
tp = float(np.abs(resample_poly(x, 4, 1, axis=0)).max())  # 4x oversampled true-peak estimate
res["peak_dBFS"] = round(20*np.log10(peak+1e-12), 2)
res["true_peak_dBFS"] = round(20*np.log10(tp+1e-12), 2)
res["clip_samples(|x|>=0.999)"] = int((np.abs(x) >= 0.999).sum())
res["over_0dBFS_samples(|x|>1)"] = int((np.abs(x) > 1.0).sum())
res["nan_samples"] = int(np.isnan(x).sum())

# ---- RMS over time (1s windows)
w = sr
n = len(mono)//w
rms = np.array([np.sqrt(np.mean(mono[i*w:(i+1)*w]**2)) for i in range(n)])
rms_db = 20*np.log10(rms+1e-9)
res["rms_dBFS_mean"] = round(float(np.mean(rms_db)), 2)
res["rms_dBFS_min_max"] = [round(float(rms_db.min()), 1), round(float(rms_db.max()), 1)]
res["rms_dB_std_over_time"] = round(float(rms_db.std()), 2)
per30 = [round(float(rms_db[i:i+30].mean()), 1) for i in range(0, n, 30)]
res["rms_dB_per_30s"] = per30

# ---- silence gaps (windows of 100ms below -60 dBFS lasting > 0.5s)
w2 = sr//10
r100 = np.array([np.sqrt(np.mean(mono[i*w2:(i+1)*w2]**2)) for i in range(len(mono)//w2)])
sil = r100 < 10**(-60/20)
gaps, run = [], 0
for s in sil:
    if s: run += 1
    else:
        if run >= 5: gaps.append(run/10)
        run = 0
if run >= 5: gaps.append(run/10)
res["silence_gaps_gt0.5s"] = {"count": len(gaps), "total_s": round(sum(gaps), 1)}

# ---- spectral features
f, t, Z = stft(mono, sr, nperseg=4096, noverlap=2048)
mag = np.abs(Z) + 1e-12
cent = (f[:, None]*mag).sum(0)/mag.sum(0)
bw = np.sqrt((((f[:, None]-cent)**2)*mag).sum(0)/mag.sum(0))
res["centroid_Hz_mean"] = round(float(cent.mean()), 0)
res["centroid_Hz_std"] = round(float(cent.std()), 0)
res["centroid_Hz_p5_p95"] = [round(float(np.percentile(cent, 5))), round(float(np.percentile(cent, 95)))]
res["bandwidth_Hz_mean"] = round(float(bw.mean()), 0)
res["bandwidth_Hz_std"] = round(float(bw.std()), 0)
res["centroid_per_30s"] = [round(float(cent[(t >= s) & (t < s+30)].mean())) for s in range(0, int(dur), 30)]

# ---- onset density: spectral flux on log-magnitude (positive), peak-picked
lm = np.log1p(100*mag[(f > 100) & (f < 8000)])
flux = np.maximum(0, np.diff(lm, axis=1)).sum(0)
flux = (flux - np.median(flux))
thr = np.median(np.abs(flux))*6 + 1e-9
pk, _ = find_peaks(flux, height=thr, distance=int(0.2*sr/2048))
pt = t[1:][pk]
res["onsets_total"] = int(len(pk))
res["onsets_per_30s"] = [int(((pt >= s) & (pt < s+30)).sum()) for s in range(0, int(dur), 30)]

# ---- chroma, pitch-class histogram, chord changes
# Chroma uses its own long FFT (16384 points, 2.9 Hz bins, same 2048 hop and frame times as the main
# STFT): with 4096-point frames, bins below ~400 Hz are wider than a semitone and smear pitch classes.
def long_chroma(sig, sr, nfft=16384, hop=2048, lo=60, hi=2000, batch=256):
    pad = np.concatenate([np.zeros(nfft//2), sig, np.zeros(nfft//2)])
    nfr = len(t)
    fr = np.fft.rfftfreq(nfft, 1/sr); sel = (fr >= lo) & (fr <= hi)
    pcs = (np.round(69 + 12*np.log2(fr[sel]/440)).astype(int)) % 12
    win = np.hanning(nfft)
    out = np.zeros((12, nfr))
    for b0 in range(0, nfr, batch):
        idx = np.arange(b0, min(nfr, b0+batch))
        frames = np.stack([pad[i*hop:i*hop+nfft] if i*hop+nfft <= len(pad) else
                           np.pad(pad[i*hop:], (0, nfft-len(pad[i*hop:]))) for i in idx])
        P = np.abs(np.fft.rfft(frames*win, axis=1)[:, sel])**2
        for k in range(12):
            out[k, idx] = P[:, pcs == k].sum(1)
    return out
chroma = long_chroma(mono, sr)
chroma /= chroma.sum(0, keepdims=True) + 1e-12
hist = chroma.mean(1)
names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
res["pitch_class_hist"] = {n: round(float(h), 3) for n, h in zip(names, hist)}
res["pitch_classes_gt5pct"] = int((hist > 0.05).sum())
hp = hist/hist.sum()
res["pitch_class_entropy_bits"] = round(float(-(hp*np.log2(hp+1e-12)).sum()), 2)
# chord = best triad/power template per 2s window
hop = t[1]-t[0]
win = int(2.0/hop)
temps, labels = [], []
for r in range(12):
    for nm, ints in (("maj", [0,4,7]), ("min", [0,3,7]), ("sus", [0,5,7]), ("5", [0,7])):
        v = np.zeros(12); v[[(r+i) % 12 for i in ints]] = 1
        temps.append(v/np.linalg.norm(v)); labels.append(names[r]+nm)
temps = np.array(temps)
chords = []
for i in range(0, chroma.shape[1]-win, win):
    c = chroma[:, i:i+win].mean(1)
    chords.append(int(np.argmax(temps @ c)))
changes = sum(1 for i in range(1, len(chords)) if chords[i] != chords[i-1])
res["chord_changes_per_min"] = round(changes/(dur/60), 1)
res["distinct_chords_2s_windows"] = len(set(chords))
res["chord_sequence_head"] = [labels[c] for c in chords[:20]]

# ---- novelty / self-similarity between minutes (mean log-spectrum + chroma, cosine distance)
def segvec(s0, s1):
    m = (t >= s0) & (t < s1)
    if m.sum() < 2: return None
    spec = np.log(mag[:, m]).mean(1)[(f > 50) & (f < 10000)]
    spec = spec/np.linalg.norm(spec)
    ch = chroma[:, m].mean(1); ch = ch/np.linalg.norm(ch)
    return spec, ch
mins = [segvec(s, s+60) for s in range(0, int(dur)-59, 60)]
mins = [m for m in mins if m]
res["novelty_between_minutes_chroma_cosdist"] = [round(1-float(mins[i][1] @ mins[i+1][1]), 3) for i in range(len(mins)-1)]
res["novelty_between_minutes_spec_cosdist"] = [round(1-float(mins[i][0] @ mins[i+1][0]), 4) for i in range(len(mins)-1)]
# 10s-segment self-similarity: mean off-diagonal similarity (1 = totally static)
segs = [segvec(s, s+10) for s in range(0, int(dur)-9, 10)]
segs = [s for s in segs if s]
if len(segs) > 2:
    F = np.array([np.concatenate([s[0], s[1]]) for s in segs]); F /= np.linalg.norm(F, axis=1, keepdims=True)
    S = F @ F.T
    iu = np.triu_indices(len(S), 1)
    res["self_similarity_10s_mean_offdiag"] = round(float(S[iu].mean()), 4)
    res["self_similarity_10s_min"] = round(float(S[iu].min()), 4)

# ---- stereo
mid, side = (L+R)/2, (L-R)/2
res["stereo_side_over_mid_dB"] = round(float(10*np.log10((side**2).mean()/((mid**2).mean()+1e-12)+1e-12)), 1)
res["stereo_LR_correlation"] = round(float(np.corrcoef(L, R)[0, 1]), 3)

# ---- additions for the PASS gates (docs/plans/music.md section 11)
# silence: longest run of 1 s windows below -60 dBFS, quietest 1 s window (first 5 s excluded: fade-in)
q = rms_db[5:] if len(rms_db) > 10 else rms_db
run = best = 0
for v in q:
    run = run + 1 if v < -60 else 0; best = max(best, run)
res["max_silence_s"] = int(best)
res["min_rms_1s_dBFS_after5s"] = round(float(q.min()), 1)
res["rms_per30_span_dB"] = round(float(max(per30) - min(per30)), 1) if per30 else 0
cp = [c for c in res["centroid_per_30s"] if c == c and c > 0]
res["centroid_per30_max_over_min"] = round(max(cp)/min(cp), 2) if cp else 0
# band energy shares (power), overall and max share per minute
pw = mag**2
bands = {"lt120": (0, 120), "120_500": (120, 500), "500_2k": (500, 2000), "2k_8k": (2000, 8000)}
tot = pw.sum()
res["band_share"] = {k: round(float(pw[(f >= lo) & (f < hi)].sum()/tot), 4) for k, (lo, hi) in bands.items()}
res["band_share"]["gt2k"] = round(float(pw[f >= 2000].sum()/tot), 4)
bm = {}
for k, (lo, hi) in bands.items():
    shares = []
    for s0 in range(0, int(dur)-59, 60):
        m = (t >= s0) & (t < s0+60)
        shares.append(float(pw[(f >= lo) & (f < hi)][:, m].sum()/pw[:, m].sum()))
    bm[k] = round(max(shares), 4) if shares else 0
res["band_share_max_minute"] = bm
# stereo correlation below 120 Hz
from scipy.signal import butter, sosfiltfilt
sos = butter(4, 120, "low", fs=sr, output="sos")
lL, lR = sosfiltfilt(sos, L[: sr*120]), sosfiltfilt(sos, R[: sr*120])
res["stereo_corr_below120"] = round(float(np.corrcoef(lL, lR)[0, 1]), 3)
# onsets per 30 s max/min (min floored at 1)
o30 = res["onsets_per_30s"]
res["onsets_per30_max_over_min"] = round(max(o30)/max(1, min(o30)), 2) if o30 else 0
res["onsets_per_5min"] = round(res["onsets_total"] / (dur/300), 1)
# chord changes that persist >= 3 windows (6 s): ignores single-window template flicker
stable, cur, runlen, changes_st = [], None, 0, 0
for c in chords:
    if c == cur: runlen += 1
    else: cur, runlen = c, 1
    if runlen == 3 and (not stable or stable[-1] != c):
        stable.append(c)
res["chord_changes_per_min_stable"] = round(max(0, len(stable)-1)/(dur/60), 2)
res["distinct_chords_stable"] = len(set(stable))
res["distinct_chords_per_5min"] = round(len(set(chords)) / max(1, dur/300), 1)
# chroma-only 10 s self-similarity, and median chroma distance over all minute pairs
if len(segs) > 2:
    C = np.array([s[1] for s in segs]); Sc = C @ C.T; iu = np.triu_indices(len(Sc), 1)
    res["chroma_self_similarity_10s_mean"] = round(float(Sc[iu].mean()), 4)
if len(mins) > 1:
    Cm = np.array([m[1] for m in mins]); D = 1 - Cm @ Cm.T; iu = np.triu_indices(len(D), 1)
    res["chroma_dist_minute_pairs_median"] = round(float(np.median(D[iu])), 3)
nv = res["novelty_between_minutes_spec_cosdist"]
res["spec_novelty_median"] = round(float(np.median(nv)), 4) if nv else 0
nc = res["novelty_between_minutes_chroma_cosdist"]
res["chroma_novelty_median"] = round(float(np.median(nc)), 3) if nc else 0
# RMS envelope autocorrelation: max for lags 20-600 s
e = rms_db - rms_db.mean()
if len(e) > 60:
    ac = np.correlate(e, e, "full")[len(e)-1:]; ac /= ac[0] + 1e-12
    hi = min(600, len(e)//2)
    res["rms_autocorr_max_20_600s"] = round(float(ac[20:hi].max()), 3) if hi > 20 else None
res["pitch_classes_gt3pct"] = int((hist > 0.03).sum())

print(json.dumps(res, indent=1))
if a.json:
    json.dump(res, open(a.json, "w"), indent=1)
