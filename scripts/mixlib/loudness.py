"""M1 loudness (BS.1770-4, EBU R128 / 3342) and M2 true peak."""

import re
import shutil
import subprocess

import numpy as np
from scipy import signal as sps

from .audio import db10, db20


def k_weight_sos(rate):
    f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    K = np.tan(np.pi * f0 / rate)
    Vh = 10 ** (G / 20)
    Vb = Vh ** 0.4996667741545416
    a0 = 1 + K / Q + K * K
    shelf = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0,
             1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
    f0, Q = 38.13547087602444, 0.5003270373238773
    K = np.tan(np.pi * f0 / rate)
    a0 = 1 + K / Q + K * K
    hp = [1, -2, 1, 1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
    return np.array([shelf, hp])


def k_weighted(x, rate):
    """x: (n,) or (n, ch) -> float64 K-weighted along axis 0."""
    return sps.sosfilt(k_weight_sos(rate), np.asarray(x, dtype=np.float64), axis=0)


def sub_block_ms(x, rate):
    """Per-channel mean-square for each 100 ms sub-block of K-weighted audio: (blocks, ch)."""
    k = k_weighted(x, rate)
    if k.ndim == 1:
        k = k[:, None]
    n = int(round(rate * 0.1))
    blocks = len(k) // n
    sq = k[: blocks * n] ** 2
    return sq.reshape(blocks, n, -1).mean(axis=1)


def _sliding_sum(ms, width):
    """Mean over `width` consecutive sub-blocks (hop of one sub-block = 75 percent overlap for 4)."""
    if len(ms) < width:
        return np.zeros((0, ms.shape[1]))
    c = np.cumsum(np.vstack([np.zeros((1, ms.shape[1])), ms]), axis=0)
    return (c[width:] - c[:-width]) / width


def loudness_of_ms(ms_channels):
    return -0.691 + db10(np.sum(ms_channels, axis=-1))


def integrated_lufs(ms):
    blocks = _sliding_sum(ms, 4)
    if not len(blocks):
        return float("-inf")
    power = blocks.sum(axis=1)
    loud = -0.691 + db10(power)
    keep = loud > -70
    if not keep.any():
        return float("-inf")
    rel = -0.691 + db10(power[keep].mean()) - 10
    keep &= loud > rel
    return float(-0.691 + db10(power[keep].mean())) if keep.any() else float("-inf")


def short_term_series(ms):
    blocks = _sliding_sum(ms, 30)
    return loudness_of_ms(blocks) if len(blocks) else np.zeros(0)


def momentary_series(ms):
    blocks = _sliding_sum(ms, 4)
    return loudness_of_ms(blocks) if len(blocks) else np.zeros(0)


def loudness_range(ms):
    blocks = _sliding_sum(ms, 30)
    if not len(blocks):
        return 0.0
    power = blocks.sum(axis=1)
    loud = -0.691 + db10(power)
    keep = loud > -70
    if keep.sum() < 2:
        return 0.0
    rel = -0.691 + db10(power[keep].mean()) - 20
    sel = loud[keep & (loud > rel)]
    if len(sel) < 2:
        return 0.0
    return float(np.percentile(sel, 95) - np.percentile(sel, 10))


def measure_loudness(sig, rate):
    """sig: (n, 2) master. Returns M1 dict (series at 10 Hz, one value per 100 ms)."""
    ms = sub_block_ms(sig, rate)
    mom, st = momentary_series(ms), short_term_series(ms)
    return {
        "integratedLufs": integrated_lufs(ms),
        "lraLu": loudness_range(ms),
        "momentaryMaxLufs": float(mom.max()) if len(mom) else None,
        "shortTermMaxLufs": float(st.max()) if len(st) else None,
        "momentary": mom, "shortTerm": st, "subBlockMs": ms,
    }


def mono_fold_loss(sig, rate):
    """Stereo LUFS minus the LUFS of the dual-mono fold (L+R)/2, in LU. Positive means cancellation loss."""
    sig = np.asarray(sig, dtype=np.float64)
    mono = sig.mean(axis=1)
    folded = np.stack([mono, mono], axis=1)
    return integrated_lufs(sub_block_ms(sig, rate)) - integrated_lufs(sub_block_ms(folded, rate))


def ffmpeg_ebur128(path):
    """Independent meter: integrated loudness, LRA, sample and true peak (dBFS / dBTP)."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return {"error": "ffmpeg not found"}
    result = subprocess.run([ffmpeg, "-hide_banner", "-nostats", "-i", str(path), "-af",
                             "ebur128=peak=sample+true:framelog=quiet", "-f", "null", "-"],
                            capture_output=True, text=True)
    text = result.stderr.rsplit("Summary:", 1)[-1]

    def number(heading, label):
        m = re.search(rf"^\s*{heading}:\s*\n\s*{label}:\s*(-?\d+(?:\.\d+)?|-inf)\s", text, re.M)
        return float(m.group(1)) if m else None
    return {"integratedLufs": number("Integrated loudness", "I"), "lraLu": number("Loudness range", "LRA"),
            "truePeakDbtp": number("True peak", "Peak"), "samplePeakDbfs": number("Sample peak", "Peak")}


def true_peak_db(sig, factor=16, margin=48, max_segment=1 << 18):
    """Independent 16x polyphase windowed-sinc reconstruction. Only regions within 8 dB of the
    sample peak are upsampled, since nothing lower can reach the maximum. Returns dBTP."""
    sig = np.asarray(sig)
    if sig.ndim == 1:
        sig = sig[:, None]
    peak = float(np.max(np.abs(sig))) if sig.size else 0.0
    if peak <= 0:
        return float("-inf")
    loud = np.any(np.abs(sig) > peak * 0.35, axis=1)
    idx = np.flatnonzero(loud)
    if not len(idx):
        return db20(peak)
    # Group indices into segments separated by more than 2*margin samples.
    breaks = np.flatnonzero(np.diff(idx) > 2 * margin)
    starts = np.concatenate([[idx[0]], idx[breaks + 1]])
    stops = np.concatenate([idx[breaks], [idx[-1]]]) + 1
    best = peak
    for a, b in zip(starts, stops):
        a0, b0 = max(0, a - margin), min(len(sig), b + margin)
        pos = a0
        while pos < b0:
            end = min(b0, pos + max_segment)
            lo, hi = max(0, pos - margin), min(len(sig), end + margin)
            seg = sig[lo:hi].astype(np.float64)
            up = sps.resample_poly(seg, factor, 1, axis=0, window=("kaiser", 9.0))
            core = up[(pos - lo) * factor: (end - lo) * factor]
            if len(core):
                best = max(best, float(np.max(np.abs(core))))
            pos = end
    return float(db20(best))
