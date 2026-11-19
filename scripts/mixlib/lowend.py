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


def bass_note_intervals(cap):
    """(on, off) frames of the scored bass notes, from score.json."""
    out = []
    for ph in cap.score or []:
        out += [(int(n["on"]), int(n["off"])) for n in ph.get("notes", []) if n.get("role") == "bass"]
    return sorted(out)


def measure_kick_bass(cap):
    """M10 windows after each kick: 40-120 Hz RMS of drums, bass and sum; duck depth; attack lag.

    Kicks come from the landmarks (attack frames of confident kicks) when the manifest has them. The
    sum and duck measurements only use kicks where the bass actually sounds; the bass is silent under
    most kicks, and a median over those kicks would measure the drums alone."""
    if not cap.has("drums") or not cap.has("bass"):
        return {"skipped": "drums or bass stem missing"}
    if cap.has_landmarks():
        kicks, source = cap.kick_attack_frames(min_confidence=0.5), "landmarks (confidence 0.5 or more)"
    else:
        kicks, source = cap.kicks(), "kickCandidates"
    kicks = [k for k in kicks if 0 <= k < cap.frames]
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
    both = (rd > 1e-3) & (rb > 1e-3)  # both parts above about -60 dBFS RMS
    louder = np.maximum(rd, rb)
    sum_vs_louder = db20(rs[both] / louder[both]) if both.any() else np.array([])
    out = {
        "kickSource": source, "kicks": int(len(ks)), "kicksWithBass": int(both.sum()),
        "drums40to120DbMedian": float(db20(np.median(rd[rd > 1e-5]))) if (rd > 1e-5).any() else None,
        "bass40to120DbMedian": float(db20(np.median(rb[both]))) if both.any() else None,
    }
    if len(sum_vs_louder) >= 3:
        out["sumVsLouderDbMedian"] = float(np.median(sum_vs_louder))
        out["sumVsLouderDbWorst"] = float(np.min(sum_vs_louder))
    else:
        out["sumSkipped"] = f"only {int(both.sum())} kicks with both drums and bass above -60 dBFS in 40 to 120 Hz"
    # Duck depth: bass level 8 to 48 ms after the kick against 48 to 8 ms before it, for kicks inside a
    # sustaining bass note (so the note's own onset and release are not measured).
    b_wide = band_signal(bass, rate, 40, 250)
    notes = bass_note_intervals(cap)
    w = int(0.04 * rate)
    margin = int(0.06 * rate)
    duck = []
    for k in kicks:
        if notes:
            if not any(on + margin <= k - margin and off >= k + margin + w for on, off in notes):
                continue
        before = _window_rms(b_wide, [k - int(0.048 * rate)], w)[0]
        after = _window_rms(b_wide, [k + int(0.008 * rate)], w)[0]
        if before > 10 ** (-50 / 20) and after > 1e-6:
            duck.append(float(db20(before / after)))
    if duck:
        out["duckDepthDbMedian"] = float(np.median(duck))
        out["duckDepthDbMax"] = float(np.max(duck))
        out["duckKicks"] = len(duck)
        out["duckSource"] = "sustained bass notes from score.json" if notes else "all kicks (no score.json)"
    else:
        out["duckSkipped"] = "no kick falls inside a sustaining bass note"
    attacks = [n for entry in (cap.diagnostics.get("bass") or []) for n in entry.get("notes", [])
               if n.get("attackFrame") is not None]
    aligned = [n for n in attacks if n.get("alignedKickFrame") is not None]
    if aligned:
        signed = np.array([n["attackFrame"] - n["alignedKickFrame"] for n in aligned], dtype=float) / rate * 1000
        lag = np.abs(signed)
        out["alignedAccents"] = int(len(lag))
        out["bassNotes"] = int(len(attacks))
        out["lagMsSignedMedian"] = float(np.median(signed))
        out["lagMsMedian"] = float(np.median(lag))
        out["lagMsP90"] = float(np.percentile(lag, 90))
        out["lagMsMax"] = float(lag.max())
        out["lagSource"] = "diagnostics.bass attackFrame against alignedKickFrame"
    elif attacks:
        out["lagSkipped"] = "diagnostics.bass has no note aligned to a kick"
    else:
        out["lagSkipped"] = "no diagnostics.bass notes"
    return out


def db20(x):
    return 20 * np.log10(np.maximum(x, 1e-12))
