"""M3 crest, PLR and PSR; M4 gain reduction; M5 pumping."""

import csv
import io

import numpy as np
from scipy import signal as sps

from .audio import db10, db20


def crest_db(sig):
    x = np.asarray(sig, dtype=np.float64)
    if not x.size:
        return None
    rms = np.sqrt(np.mean(x ** 2))
    peak = np.max(np.abs(x))
    return float(db20(peak) - db20(rms)) if rms > 0 and peak > 0 else None


def windowed_crest(sig, rate, seconds=1.0, floor_db=-50.0):
    """Crest per window for windows whose RMS is above the floor."""
    x = np.asarray(sig, dtype=np.float32)
    n = int(rate * seconds)
    out = []
    for a in range(0, len(x) - n + 1, n):
        w = x[a:a + n].astype(np.float64)
        rms = np.sqrt(np.mean(w ** 2))
        if db20(rms) > floor_db:
            out.append(float(db20(np.max(np.abs(w))) - db20(rms)))
    return out


def measure_crest(cap, loud, true_peak_dbtp):
    out = {"buses": {}}
    names = ["drums", "bass", "dry", "texture", "wet", "dialogue-chops", "footage", "lofi", "pre-master", "master"]
    for name in names:
        s = cap.stem(name)
        if s is None:
            continue
        a = np.asarray(s, dtype=np.float32)
        peak = float(np.max(np.abs(a))) if a.size else 0.0
        win = windowed_crest(a, cap.rate)
        out["buses"][name] = {
            "samplePeakDbfs": float(db20(peak)) if peak > 0 else None,
            "rmsDbfs": float(db20(np.sqrt(np.mean(a.astype(np.float64) ** 2)))) if a.size else None,
            "crestDb": crest_db(a),
            "crest1sMedianDb": float(np.median(win)) if win else None,
            "crest1sMinDb": float(np.min(win)) if win else None,
            "crest1sMaxDb": float(np.max(win)) if win else None,
        }
    out["master"] = out["buses"].get("master", {})
    out["plrDb"] = None if true_peak_dbtp is None else float(true_peak_dbtp - loud["integratedLufs"])
    stmax = loud.get("shortTermMaxLufs")
    out["psrDb"] = None if (true_peak_dbtp is None or stmax is None) else float(true_peak_dbtp - stmax)
    return out


def parse_gr_csv(data):
    """master-gr.csv (frame,glue_db,clip_db,limiter_db) -> dict of arrays, reductions as positive dB."""
    text = data.decode() if isinstance(data, bytes) else data
    rows = list(csv.DictReader(io.StringIO(text)))
    if not rows:
        return None
    return {k: np.array([float(r[k]) for r in rows]) for k in ("frame", "glue_db", "clip_db", "limiter_db")}


def _stats(x, threshold=None):
    x = np.abs(np.asarray(x, dtype=np.float64))
    out = {"meanDb": float(x.mean()), "p95Db": float(np.percentile(x, 95)), "maxDb": float(x.max())}
    if threshold is not None:
        out["aboveFraction"] = float((x > threshold).mean())
    return out


def engine_trace_stats(trace):
    glue, clip, lim = (np.abs(trace[k]) for k in ("glue_db", "clip_db", "limiter_db"))
    return {"glue": _stats(glue), "clip": {**_stats(clip), "engagedFraction": float((clip > 0.01).mean())},
            "limiter": _stats(lim, 3.0), "hops": int(len(glue))}


def envelope_db(x, rate, hop_seconds=0.01):
    """10 ms RMS envelope (dB) of a stereo/mono signal (mean-square over channels)."""
    a = np.asarray(x, dtype=np.float32)
    if a.ndim == 2:
        a = np.sqrt((a.astype(np.float64) ** 2).mean(axis=1)).astype(np.float32)
    n = int(round(rate * hop_seconds))
    k = len(a) // n
    p = (a[: k * n].astype(np.float64).reshape(k, n) ** 2).mean(axis=1)
    return db10(p)


def latency_frames(manifest):
    """Legacy manifest latency (sum of the reported unit latencies); see `master_latency` for the real one."""
    lat = manifest.get("latencySamples")
    if isinstance(lat, (int, float)):
        return float(lat)
    if isinstance(lat, dict):
        if "total" in lat:
            return float(lat["total"])
        return float(sum(v for v in lat.values() if isinstance(v, (int, float))))
    return 0.0


def estimate_latency(master, pre, rate, seconds=10.0, max_lag=4096):
    """Latency of `master` behind `pre` in frames, from the cross-correlation of the loudest stretch."""
    n = min(len(master), len(pre))
    seg = int(seconds * rate)
    if n < seg // 2:
        return None
    a = np.asarray(pre[:n], dtype=np.float32).mean(axis=1)
    hop = rate
    ms = np.array([np.mean(a[i:i + hop] ** 2) for i in range(0, n - hop, hop)])
    start = int(np.argmax(np.convolve(ms, np.ones(max(1, int(seconds))), "valid"))) * hop if len(ms) else 0
    stop = min(n, start + seg)
    x = a[start:stop].astype(np.float64)
    y = np.asarray(master[start:stop], dtype=np.float32).mean(axis=1).astype(np.float64)
    c = sps.fftconvolve(y, x[::-1], mode="full")
    mid = len(x) - 1
    window = c[mid - 64: mid + max_lag + 1]
    return int(np.argmax(np.abs(window))) - 64


def master_latency(cap):
    """(frames, source): the engine's `latencyFrames` when the manifest has it, else cross-correlation."""
    eng = cap.master_dynamics().get("latencyFrames")
    if isinstance(eng, (int, float)):
        return int(eng), "engine"
    master, pre = cap.stem("master"), cap.stem("pre-master")
    if master is not None and pre is not None:
        est = estimate_latency(master, pre, cap.rate)
        if est is not None:
            return est, "cross-correlation"
    return int(round(latency_frames(cap.manifest))), "manifest latencySamples"


def inferred_gain_trace(cap, hop_seconds=0.01):
    """Master gain in dB per 10 ms (negative = reduction) from master and pre-master envelopes."""
    master, pre = cap.stem("master"), cap.stem("pre-master")
    if master is None or pre is None:
        return None
    lat, lat_source = master_latency(cap)
    m = np.asarray(master[lat:], dtype=np.float32) if lat > 0 else np.asarray(master)
    p = np.asarray(pre[: len(m)], dtype=np.float32)
    m = m[: len(p)]
    em, ep = envelope_db(m, cap.rate, hop_seconds), envelope_db(p, cap.rate, hop_seconds)
    active = ep > -60
    gain = np.where(active, em - ep, np.nan)
    low = active & (ep < np.nanpercentile(ep[active], 40)) if active.any() else active
    static = float(np.nanmedian(gain[low])) if low.any() else 0.0
    trace = np.where(active, gain - static, 0.0)
    return {"gainDb": trace, "staticGainDb": static, "hopSeconds": hop_seconds, "preEnvDb": ep,
            "latencyFrames": lat, "latencySource": lat_source}


def pumping_index(gain_db, hop_seconds):
    """RMS of the gain trace band-passed 0.5 to 8 Hz (dB)."""
    fs = 1.0 / hop_seconds
    g = np.asarray(gain_db, dtype=np.float64)
    if len(g) < int(fs * 4):
        return None
    sos = sps.butter(2, [0.5, min(8.0, fs / 2 * 0.9)], btype="band", fs=fs, output="sos")
    y = sps.sosfiltfilt(sos, g)
    return float(np.sqrt(np.mean(y ** 2)))


def kick_dip(gain_db, hop_seconds, kick_frames, rate):
    """Mean gain 20 to 80 ms after each kick minus the gain 30 ms before, as a positive dip (dB)."""
    g = np.asarray(gain_db, dtype=np.float64)
    dips = []
    for k in kick_frames:
        t = k / rate
        a0, a1 = int(round((t + 0.02) / hop_seconds)), int(round((t + 0.08) / hop_seconds)) + 1
        b = int(round((t - 0.03) / hop_seconds))
        if b < 0 or a1 >= len(g):
            continue
        dips.append(g[b] - g[a0:a1].mean())
    if not dips:
        return None
    return float(np.mean(dips)), len(dips)


def measure_dynamics(cap, trace_data):
    out = {}
    if trace_data is not None:
        out["engine"] = engine_trace_stats(trace_data)
        meta = cap.master_dynamics()
        if meta:
            # Per-sample meters in the manifest against the per-hop trace file: both are engine data.
            out["engine"]["manifest"] = {k: meta.get(k) for k in ("profile", "ceilingDbtp", "latencyFrames", "glue", "clip", "limiter")}
            out["engine"]["clipEngagedFractionSamples"] = (meta.get("clip") or {}).get("engagedFraction")
            diffs = {}
            for stage in ("glue", "limiter"):
                for k in ("meanDb", "p95Db", "maxDb"):
                    mv = (meta.get(stage) or {}).get(k)
                    if isinstance(mv, (int, float)):
                        diffs[f"{stage}.{k}"] = float(out["engine"][stage][k] - mv)
            out["engine"]["traceMinusManifestDb"] = diffs
    inferred = inferred_gain_trace(cap)
    if trace_data is not None:
        # Prefer the engine's own trace for pumping: total reduction averaged to ~10 ms.
        hop_frames = float(np.median(np.diff(trace_data["frame"]))) if len(trace_data["frame"]) > 1 else 64.0
        rows = max(1, int(round(cap.rate * 0.01 / hop_frames)))
        total = -(np.abs(trace_data["glue_db"]) + np.abs(trace_data["clip_db"]) + np.abs(trace_data["limiter_db"]))
        k = len(total) // rows
        eng_gain = total[: k * rows].reshape(k, rows).mean(axis=1)
        eng_hop = rows * hop_frames / cap.rate
        out["pumpingIndexDb"] = pumping_index(eng_gain, eng_hop)
        kd = kick_dip(eng_gain, eng_hop, cap.kick_attack_frames(), cap.rate)
        if kd:
            out["kickDipDb"], out["kickDipCount"] = kd
        out["pumpingSource"] = "engine"
        out["_gain"], out["_hop"] = eng_gain, eng_hop
    if inferred is not None:
        gain = inferred["gainDb"]
        red = -np.minimum(gain, 0)
        active = inferred["preEnvDb"] > -60
        r = red[active] if active.any() else red
        out["inferred"] = {
            "meanReductionDb": float(r.mean()), "p95ReductionDb": float(np.percentile(r, 95)),
            "maxReductionDb": float(r.max()), "above3dbFraction": float((r > 3).mean()),
            "staticGainDb": inferred["staticGainDb"],
        }
        out["inferred"]["latencyFrames"] = inferred["latencyFrames"]
        out["inferred"]["latencySource"] = inferred["latencySource"]
        out["inferred"]["pumpingIndexDb"] = pumping_index(gain, inferred["hopSeconds"])
        if trace_data is not None:
            eng_red_raw = -out["_gain"]
            n = len(red)
            t_eng = (np.arange(len(eng_red_raw)) + 0.5) * out["_hop"]
            t_inf = (np.arange(n) + 0.5) * inferred["hopSeconds"]
            eng_red = np.interp(t_inf, t_eng, eng_red_raw)
            keep = active[:n]
            e, i = eng_red[:n][keep], red[:n][keep]
            out["crossCheck"] = {
                "engineTotalP95Db": float(np.percentile(e, 95)), "inferredP95Db": float(np.percentile(i, 95)),
                "p95DisagreementDb": float(abs(np.percentile(e, 95) - np.percentile(i, 95))),
                "engineTotalMeanDb": float(e.mean()), "inferredMeanDb": float(i.mean()),
                "engineTotalMaxDb": float(e.max()), "inferredMaxDb": float(i.max()),
                "correlation": float(np.corrcoef(e, i)[0, 1]) if e.std() > 0 and i.std() > 0 else None,
                "warn": bool(abs(np.percentile(e, 95) - np.percentile(i, 95)) > 1.0),
            }
        kd = kick_dip(gain, inferred["hopSeconds"], cap.kick_attack_frames(), cap.rate)
        if kd:
            out["inferred"]["kickDipDb"] = kd[0]
        if "pumpingIndexDb" not in out:
            out["pumpingIndexDb"] = out["inferred"]["pumpingIndexDb"]
            out["pumpingSource"] = "inferred"
            if kd:
                out["kickDipDb"], out["kickDipCount"] = kd
            out["_gain"], out["_hop"] = gain, inferred["hopSeconds"]
    return out
