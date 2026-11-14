#!/usr/bin/env python3
"""Check the PASS 1 probe renders (Liminal/Audio/MusicProbes.swift). Usage: analyze-probes.py <dir>"""
import sys, warnings, numpy as np
warnings.filterwarnings("ignore")
from scipy.io import wavfile
d = sys.argv[1]
def load(n):
    sr, x = wavfile.read(f"{d}/{n}.wav"); return sr, x.astype(np.float64)
ok = True
def check(name, cond, info):
    global ok; ok &= bool(cond); print(f"{'PASS' if cond else 'FAIL'} {name}: {info}")

sr, a = load("probe-fanout3"); _, b = load("probe-fanout1")
pa, pb = np.abs(a[sr//2:]).max(), np.abs(b[sr//2:]).max()
check("fanout", abs(pa/pb - 1.75) < 0.05, f"peak 3 sends {pa:.4f} / 1 send {pb:.4f} = {pa/pb:.3f} (expect 1.75)")

sr, x = load("probe-ramp"); m = x[:, 0]
rms = np.array([np.sqrt(np.mean(m[i*sr//2:(i+1)*sr//2]**2)) for i in range(20)])  # 0.5 s windows, first 10 s
lin = np.linspace(0.25, 9.75, 20)/10 * rms[-1] / (9.75/10)
err = np.abs(rms - lin).max() / rms[-1]
check("gain ramp 10 s", err < 0.05 and rms[0] < 0.02, f"rms@0.25s {rms[0]:.4f} @9.75s {rms[-1]:.4f}, max dev from linear {err*100:.1f}%")
def freq(seg):
    zc = np.where(np.diff(np.signbit(seg)))[0]; return (len(zc)/2) / (len(seg)/sr)
f0, f1, fm = freq(m[int(11*sr):int(12*sr)]), freq(m[int(16.5*sr):int(17.5*sr)]), freq(m[int(13.9*sr):int(14.1*sr)])
check("freq ramp", abs(f0-220) < 3 and abs(f1-440) < 3 and 300 < fm < 360, f"{f0:.0f} Hz -> mid {fm:.0f} Hz -> {f1:.0f} Hz")

sr, x = load("probe-zita-limiter")
check("zita+limiter", np.isfinite(x).all() and np.abs(x).max() <= 1.0 and np.abs(x[int(4*sr):]).max() > 1e-3,
      f"peak {np.abs(x).max():.3f}, tail peak {np.abs(x[int(4*sr):]).max():.4f}, nan {int((~np.isfinite(x)).sum())}")

sr, x = load("probe-morph"); m = x[:, 0]
d2 = np.abs(np.diff(m, 2)); p = d2.max(); med = np.percentile(d2, 99.9)
check("morph clicks", p < 6*med, f"max 2nd diff {p:.5f} vs p99.9 {med:.5f} (ratio {p/med:.1f})")
sys.exit(0 if ok else 1)
