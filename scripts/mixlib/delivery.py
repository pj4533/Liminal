"""Delivered stems: each section stem at final-mix level.

Every section stem goes through the same pre-master staging gain, master latency, 25 Hz high-pass, static
finisher gain and time-varying glue/clip/limiter gain reduction (`master-gr.csv`) as the real mix, so the
stems sum back to `master.wav` (like pressing solo on a mixer channel). Used by `scripts/solo-stems.py` and
`scripts/translation-report.py`.

The latency and the static gain are fitted against `master.wav` from `pre-master.wav`. The clip stage is
modelled as a gain, so the sum of the delivered stems differs from the master by a small residual (about
-57 dB re the master on the 2026-11 captures); `MasterChain.sum_residual_db` reports it.
"""

import json
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt

from .audio import read_wav

# (delivered name, capture stem). The order is the order of the solo files.
DELIVERED = [("drums", "drums"), ("bass", "bass"), ("texture", "texture"), ("dry", "dry"), ("wet", "wet"),
             ("chops", "dialogue-chops"), ("footage", "footage")]
REFUSE_RESIDUAL_DB = -40.0


def gain_envelope(trace, frames):
    """Linear gain per master frame from a master-gr.csv array (frame, glue, clip, limiter dB)."""
    trace = np.asarray(trace, dtype=np.float64)
    if trace.ndim != 2 or len(trace) == 0:
        return np.ones(frames)
    total = trace[:, 1] + trace[:, 2] + trace[:, 3]
    return 10 ** (-np.interp(np.arange(frames), trace[:, 0], total) / 20)


def read_trace(path):
    return np.loadtxt(path, delimiter=",", skiprows=1, ndmin=2)


class MasterChain:
    """The finisher as a linear model: delay, high-pass, static gain and the traced gain reduction."""

    def __init__(self, rate, stage, latency, gain, env, highpass_hz=25.0):
        self.rate = int(rate)
        self.stage = float(stage)
        self.latency = int(latency)
        self.gain = float(gain)
        self.env = np.asarray(env, dtype=np.float64)
        self.highpass_hz = float(highpass_hz)
        self.sos = butter(2, self.highpass_hz, "highpass", fs=self.rate, output="sos")
        self.sum_residual_db = None

    def apply(self, x, staged=True):
        """x: (n,) or (n, 2) section stem (pre staging when `staged`). Returns float64 at master level."""
        x = np.asarray(x, dtype=np.float64)
        y = np.zeros_like(x)
        n, lat = len(x), self.latency
        if lat < n:
            y[lat:] = x[:n - lat]
        y = sosfilt(self.sos, y, axis=0)
        g = self.gain * (self.stage if staged else 1.0)
        env = self.env[:n] if len(self.env) >= n else np.pad(self.env, (0, n - len(self.env)), constant_values=1.0)
        return y * (g * (env[:, None] if y.ndim == 2 else env))

    def describe(self):
        return {"stagingDb": float(20 * np.log10(self.stage)), "latencyFrames": self.latency,
                "finisherGainDb": float(20 * np.log10(abs(self.gain) + 1e-12)), "highpassHz": self.highpass_hz,
                "highpass": "causal 2nd-order Butterworth (scipy sosfilt)",
                "sumResidualDb": self.sum_residual_db}


def fit_chain(master, pre, rate, stage, nominal_latency, env, highpass_hz=25.0, search=60, fit_seconds=30.0):
    """Fit latency (nominal +- search frames) and static gain of the finisher against `master`.

    The latency search runs on the loudest `fit_seconds` of the capture (a causal filter commutes with a
    delay, so the filtered pre-master is shifted rather than refiltered); the gain is then fitted on the
    whole file at the chosen latency."""
    master = np.asarray(master, dtype=np.float64)
    pre = np.asarray(pre, dtype=np.float64)
    n = min(len(master), len(pre))
    master, pre = master[:n], pre[:n]
    chain = MasterChain(rate, stage, nominal_latency, 1.0, env, highpass_hz)
    hp_pre = sosfilt(chain.sos, pre, axis=0)
    seg = int(fit_seconds * rate)
    if n > seg:
        hop = rate
        ms = np.array([np.mean(pre[i:i + hop] ** 2) for i in range(0, n - hop, hop)])
        width = max(1, int(fit_seconds))
        start = int(np.argmax(np.convolve(ms, np.ones(width), "valid"))) * hop if len(ms) >= width else 0
        a, b = start, min(n, start + seg)
    else:
        a, b = 0, n
    envn = chain.env[:n] if len(chain.env) >= n else np.pad(chain.env, (0, n - len(chain.env)), constant_values=1.0)
    best = None
    lo = max(0, int(nominal_latency) - search)
    for lat in range(lo, int(nominal_latency) + search + 1):
        if a + lat >= b:
            break
        idx0 = max(a, lat)
        r = hp_pre[idx0 - lat: b - lat] * envn[idx0:b][:, None]
        m = master[idx0:b]
        den = float(np.sum(r * r))
        if den <= 0:
            continue
        g = float(np.sum(r * m)) / den
        res = float(np.mean((m - g * r) ** 2))
        if best is None or res < best[1]:
            best = (lat, res)
    lat = best[0] if best else int(nominal_latency)
    r = np.zeros_like(hp_pre)
    r[lat:] = hp_pre[:n - lat]
    r *= envn[:, None]
    den = float(np.sum(r * r))
    g = float(np.sum(r * master)) / den if den > 0 else 1.0
    chain.latency, chain.gain = lat, g
    return chain


def load_chain(cap_dir, master=None, pre=None):
    """Fit the master chain of a capture directory. Returns (chain, master array)."""
    cap_dir = Path(cap_dir)
    man = json.loads((cap_dir / "manifest.json").read_text())
    dyn = (man.get("diagnostics") or {}).get("masterDynamics") or {}
    if master is None:
        master, rate = read_wav(cap_dir / "master.wav")
    else:
        rate = int(man["sampleRate"])
    if pre is None:
        pre, _ = read_wav(cap_dir / "pre-master.wav")
    stage = 10 ** (dyn.get("preMasterStagingDb", 0.0) / 20)
    trace_path = cap_dir / (dyn.get("traceFile") or "master-gr.csv")
    env = gain_envelope(read_trace(trace_path), len(master)) if trace_path.is_file() else np.ones(len(master))
    hp = (dyn.get("settings") or {}).get("highpassHz", 25)
    chain = fit_chain(master, pre, rate, stage, dyn.get("latencyFrames", 200), env, hp)
    return chain, master


def delivered_stems(cap_dir, chain=None, master=None, refuse_db=REFUSE_RESIDUAL_DB):
    """{name: (n, 2) float64} for the seven section stems at final-mix level, plus the fitted chain.

    A missing stem is all zeros. Raises ValueError when the stems do not sum back to the master within
    `refuse_db` (a wrong latency or gain trace)."""
    cap_dir = Path(cap_dir)
    if chain is None:
        chain, master = load_chain(cap_dir, master)
    elif master is None:
        master, _ = read_wav(cap_dir / "master.wav")
    n = len(master)
    out = {}
    for name, stem in DELIVERED:
        path = cap_dir / f"{stem}.wav"
        if path.is_file():
            x, _ = read_wav(path)
            out[name] = chain.apply(np.asarray(x[:n], dtype=np.float64))
        else:
            out[name] = np.zeros((n, 2))
    check_sum(out, master, chain, refuse_db)
    return out, chain


def check_sum(stems, master, chain, refuse_db=REFUSE_RESIDUAL_DB):
    """Sets `chain.sum_residual_db` (sum of stems minus master, re the master RMS) and refuses above `refuse_db`."""
    master = np.asarray(master, dtype=np.float64)
    total = None
    for y in stems.values():
        total = y.copy() if total is None else total + y
    diff = master[:len(total)] - total
    res = 20 * np.log10(np.sqrt(np.mean(diff ** 2)) / max(np.sqrt(np.mean(master ** 2)), 1e-20) + 1e-20)
    chain.sum_residual_db = float(res)
    if res > refuse_db:
        raise ValueError(f"delivered stems do not sum to the master: residual {res:.1f} dB > {refuse_db:.0f} dB "
                         f"(latency {chain.latency}, gain {20 * np.log10(abs(chain.gain) + 1e-12):+.2f} dB)")
    return res
