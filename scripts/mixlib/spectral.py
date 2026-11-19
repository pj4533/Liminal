"""M6 spectrograms and M7 long-term spectrum."""

import numpy as np
from scipy import fft as sfft
from scipy import signal as sps

from .audio import BAND_NAMES, BANDS, THIRD_CENTERS, db10


def spectrogram(sig, rate, nfft, max_cols=1400):
    """Mean-pooled power spectrogram of the mono mix. Returns (freqs, times, power[bins, cols])."""
    mono = np.asarray(sig, dtype=np.float32).mean(axis=1) if sig.ndim == 2 else np.asarray(sig, np.float32)
    hop = nfft // 2
    win = np.hanning(nfft + 1)[:-1].astype(np.float32)
    nfr = max(1, (len(mono) - nfft) // hop + 1)
    pool = max(1, int(np.ceil(nfr / max_cols)))
    cols = (nfr + pool - 1) // pool
    out = np.zeros((nfft // 2 + 1, cols), dtype=np.float64)
    counts = np.zeros(cols)
    chunk = max(1, 2_000_000 // nfft)
    base = np.arange(nfft)[None, :]
    scale = 1.0 / float(np.sum(win.astype(np.float64) ** 2))
    for a in range(0, nfr, chunk):
        b = min(nfr, a + chunk)
        idx = (np.arange(a, b)[:, None] * hop) + base
        spec = sfft.rfft(mono[idx] * win, workers=-1)
        p = (spec.real ** 2 + spec.imag ** 2) * scale
        col = np.arange(a, b) // pool
        np.add.at(out.T, col, p)
        np.add.at(counts, col, 1)
    out /= np.maximum(counts, 1)[None, :]
    freqs = np.arange(nfft // 2 + 1) * rate / nfft
    times = (np.arange(cols) * pool + pool / 2) * hop / rate
    return freqs, times, out


def third_octave_levels(grid, g):
    """Average third-octave band power (dB, mean-square) and densities per band for one signal."""
    p = ((g["PL"] + g["PR"]) * 0.5).mean(axis=0)
    levels, density = [], []
    for c in THIRD_CENTERS:
        lo, hi = c / 2 ** (1 / 6), c * 2 ** (1 / 6)
        sl = grid.sl(lo, hi)
        total = float(p[sl].sum())
        levels.append(float(db10(total)))
        density.append(float(db10(total / (hi - lo))))
    return levels, density


def tilt_db_per_octave(centers, density, lo=250.0, hi=8000.0):
    c = np.array(centers)
    d = np.array(density)
    ok = (c >= lo) & (c <= hi) & np.isfinite(d) & (d > -150)
    if ok.sum() < 3:
        return None
    return float(np.polyfit(np.log2(c[ok]), d[ok], 1)[0])


def band_shares(grid, g):
    p = ((g["PL"] + g["PR"]) * 0.5).mean(axis=0)
    energy = np.array([p[grid.sl(lo, hi)].sum() for lo, hi in BANDS])
    return (energy / max(energy.sum(), 1e-20)).tolist()


def spectral_rolloff(grid, g, fraction=0.85, active_frames=None):
    """Frequency under which `fraction` of the energy lies, using per-group energy."""
    p = (g["PL"] + g["PR"]) * 0.5
    if active_frames is not None:
        p = p[active_frames]
    if not len(p):
        return None
    e = p.mean(axis=0)
    c = np.cumsum(e)
    if c[-1] <= 0:
        return None
    i = int(np.searchsorted(c, fraction * c[-1]))
    i = min(i, len(grid.edges) - 2)
    # Interpolate inside the group on a linear scale.
    lo, hi = grid.edges[i], grid.edges[i + 1]
    prev = c[i - 1] if i else 0.0
    frac = (fraction * c[-1] - prev) / max(e[i], 1e-20)
    return float(lo + (hi - lo) * min(1.0, max(0.0, frac)))


def measure_ltas(cap, grid, names):
    """M7: per-section and master third-octave spectrum, tilt, band shares."""
    out = {"centers": THIRD_CENTERS, "bandNames": BAND_NAMES, "signals": {}}
    for name, g in names.items():
        if g is None:
            continue
        levels, density = third_octave_levels(grid, g)
        out["signals"][name] = {"levelDb": levels, "densityDb": density,
                                "tiltDbPerOctave": tilt_db_per_octave(THIRD_CENTERS, density),
                                "bandShares": band_shares(grid, g)}
    return out


def energy_below_db_under_total(sig, rate, cutoff=25.0, decimate=16):
    """How far (dB) the energy below `cutoff` Hz is under the total, from a Welch estimate with 0.7 Hz bins.

    The 4096-point analysis grid has 11.7 Hz bins and a Hann main lobe of 23 Hz, so 40 to 60 Hz
    bass leaks into its 0 to 25 Hz groups; this estimate does not."""
    x = np.asarray(sig, dtype=np.float32)
    mono = x if x.ndim == 1 else x.mean(axis=1)
    low = sps.decimate(mono.astype(np.float64), decimate, ftype="fir", zero_phase=True)
    r = rate / decimate
    f, pxx = sps.welch(low, fs=r, window="hann", nperseg=min(len(low), 1 << 16), noverlap=None)
    full_total = float(np.mean(mono.astype(np.float64) ** 2))
    below = float(np.trapezoid(pxx[f <= cutoff], f[f <= cutoff]))
    return float(db10(full_total) - db10(max(below, 1e-20)))
