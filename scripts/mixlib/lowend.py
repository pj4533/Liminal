"""M9 low-band mono and M10 kick and bass."""

import numpy as np
from scipy import signal as sps

from .audio import BAND_NAMES, BANDS, db10
from .loudness import mono_fold_loss


def measure_lowband_mono(cap, grid, master_grid, master_sig):
    """Per-band L/R correlation (energy weighted), mid/side ratio, and mono fold loss."""
    g = master_grid
    out = {"bands": BAND_NAMES, "correlation": [], "midSideDb": []}
    for lo, hi in BANDS:
        sl = grid.sl(lo, hi)
        pl, pr, c = (g[k][:, sl].sum(dtype=np.float64) for k in ("PL", "PR", "C"))
        out["correlation"].append(float(c / np.sqrt(max(pl * pr, 1e-30))))
        mid, side = (pl + pr + 2 * c) / 4, (pl + pr - 2 * c) / 4
        out["midSideDb"].append(float(db10(mid) - db10(max(side, 1e-20))))
    pl, pr, c = (g[k].sum(dtype=np.float64) for k in ("PL", "PR", "C"))
    out["fullBandCorrelation"] = float(c / np.sqrt(max(pl * pr, 1e-30)))
    sl = grid.sl(20, 120)
    pl, pr, c = (g[k][:, sl].sum(dtype=np.float64) for k in ("PL", "PR", "C"))
    out["below120Correlation"] = float(c / np.sqrt(max(pl * pr, 1e-30)))
    out["monoLossLu"] = float(mono_fold_loss(master_sig, cap.rate))
    return out


def band_signal(sig, rate, lo, hi, order=4):
    mono = np.asarray(sig, dtype=np.float64)
    if mono.ndim == 2:
        mono = mono.mean(axis=1)
    sos = sps.butter(order, [lo, min(hi, rate / 2 * 0.95)], btype="band", fs=rate, output="sos")
    return sps.sosfiltfilt(sos, mono)


def _window_rms(x, starts, length):
    out = np.zeros(len(starts))
    for i, s in enumerate(starts):
        a, b = max(0, s), min(len(x), s + length)
        out[i] = np.sqrt(np.mean(x[a:b] ** 2)) if b > a else 0.0
    return out


def measure_kick_bass(cap):
    """M10 windows after each kick: 40-120 Hz RMS of drums, bass and sum; duck depth; attack lag."""
    if not cap.has("drums") or not cap.has("bass"):
        return {"skipped": "drums or bass stem missing"}
    kicks = [k for k in cap.kicks() if 0 <= k < cap.frames]
    if not kicks:
        return {"skipped": "no kick landmarks or candidates"}
    rate = cap.rate
    drums, bass = cap.signal(["drums"]), cap.signal(["bass"])
    d_low = band_signal(drums, rate, 40, 120)
    b_low = band_signal(bass, rate, 40, 120)
    s_low = d_low + b_low
    ks = np.array(kicks)
    win = int(0.12 * rate)
    rd, rb, rs = (_window_rms(x, ks, win) for x in (d_low, b_low, s_low))
    louder = np.maximum(rd, rb)
    keep = louder > 1e-5
    sum_vs_louder = db20(rs[keep] / louder[keep]) if keep.any() else np.array([])
    # Duck depth: bass 40-250 Hz RMS 100 ms after against 100 ms before, kicks where the bass sounds.
    b_wide = band_signal(bass, rate, 40, 250)
    w100 = int(0.1 * rate)
    before = _window_rms(b_wide, ks - w100, w100)
    after = _window_rms(b_wide, ks, w100)
    ok = (before > 10 ** (-50 / 20)) & (after > 1e-6)
    duck = db20(before[ok] / after[ok]) if ok.any() else np.array([])
    out = {
        "kicks": int(len(ks)), "kicksCompared": int(keep.sum()),
        "drums40to120DbMedian": float(db20(np.median(rd[keep]))) if keep.any() else None,
        "bass40to120DbMedian": float(db20(np.median(rb[keep]))) if keep.any() else None,
        "sumVsLouderDbMedian": float(np.median(sum_vs_louder)) if len(sum_vs_louder) else None,
        "sumVsLouderDbWorst": float(np.min(sum_vs_louder)) if len(sum_vs_louder) else None,
        "duckDepthDbMedian": float(np.median(duck)) if len(duck) else None,
        "duckKicks": int(ok.sum()),
    }
    notes = [n for entry in (cap.diagnostics.get("bass") or []) for n in entry.get("notes", [])
             if n.get("alignedKickFrame") is not None and n.get("attackFrame") is not None]
    if notes:
        lag = np.abs(np.array([n["attackFrame"] - n["alignedKickFrame"] for n in notes], dtype=float)) / rate * 1000
        out["alignedAccents"] = int(len(lag))
        out["lagMsMedian"] = float(np.median(lag))
        out["lagMsP90"] = float(np.percentile(lag, 90))
    else:
        out["lagSkipped"] = "no diagnostics.bass notes"
    return out


def db20(x):
    return 20 * np.log10(np.maximum(x, 1e-12))
