#!/usr/bin/env python3
"""CPU model of the geometric part of EffectsRenderer.metal (distortedUV) and of today's
EffectsUniformsComputer oscillators, for measuring how far and how roughly the picture is warped.

    python3 scripts/fx_model.py scan [--step 5] [--end 900]     # uniforms + warp statistics over time
    python3 scripts/fx_model.py check UNIFORMS.json              # compare the oscillator port with a
                                                                 # shader-bench --render-only JSON
    python3 scripts/fx_model.py scan --proposed [--intensity 0.5]  # same for the proposed look
    python3 scripts/fx_model.py golden                           # proposed uniforms at fixed inputs
                                                                 # (golden values for the unit test)

Warp statistics (UV units: 1.0 = the full picture width or height), on a 192x128 grid:
  disp_p50 / disp_p95   how far a pixel's sample point moves, beyond Ken Burns
  strain_p90            Frobenius norm of the displacement gradient: 0 = rigid shift,
                        0.5 = local shapes visibly bent, > 1 = shredded
  fold                  fraction of the picture where the map folds over or crushes
                        (det of the sampling map's Jacobian < 0.25): shapes there are destroyed
Smooth water (large disp, small strain) keeps a subject readable; high strain and folds do not.
This is a model for measurement and design only. The app never runs it.
"""
import json
import math
import sys

import numpy as np

PHI = 1.618034
TWO_PI = 6.2831853

# ---- today's oscillators (EffectsUniformsComputer, music neutral, no transition)

def distortion(t):
    wave = (math.sin(t * 0.04 * PHI) + math.sin(t * 0.025) * 0.7 + math.sin(t * 0.06 / PHI) * 0.4) / 2.1
    return 0.02 + 0.06 * (wave + 1) / 2

def log_sphere(t):
    wave = (math.sin(t * 0.035 * PHI * PHI) + math.sin(t * 0.022 / PHI) * 0.7) / 1.7
    return 0.003 + 0.017 * (wave + 1) / 2

def fractal_noise(t):
    wave = (math.sin(t * 0.028 * PHI) + math.sin(t * 0.045 / (PHI * PHI)) * 0.6) / 1.6
    return 0.005 + 0.025 * (wave + 1) / 2

def chromatic(t):
    wave = (math.sin(t * 0.07 * PHI) + math.sin(t * 0.03) * 0.6) / 1.6
    return 0.003 + 0.012 * (wave + 1) / 2

def fractal_hue(t):
    wave = (math.sin(t * 0.032 / PHI) + math.sin(t * 0.05 * PHI * PHI) * 0.5) / 1.5
    return 0.05 + 0.20 * (wave + 1) / 2

def color_cycle(t):
    c = (math.sin(t * 0.1) + math.sin(t * 0.1 * PHI) * 0.7 + math.sin(t * 0.1 * PHI * PHI) * 0.5
         + math.sin(t * 0.037) * 0.6) / 2.8
    return (c + 1) / 2

def ken_burns(t):
    scale = 1.2 + 0.15 * math.sin(t * 0.05) + 0.05 * math.sin(t * 0.03)
    ox = (60 * math.sin(t * 0.04) + 20 * math.sin(t * 0.025)) / 100
    oy = (60 * math.cos(t * 0.035) + 20 * math.cos(t * 0.02)) / 100
    return scale, ox, oy

def uniforms(t):
    s, ox, oy = ken_burns(t)
    c = color_cycle(t)
    hb = (0.35 + 0.65 * c) * mix(tri(i, 0.15, 0.40, 0.55), tri(i, 0.25, 0.65, 0.75))
    hw = min(c * mix(tri(i, 0.02, 0.12, 0.24), tri(i, 0.05, 0.28, 0.40)), 0.20, 0.065 / max(hb, 1e-3))
    return {"time": t, "kenBurnsScale": s, "kenBurnsOffsetX": ox, "kenBurnsOffsetY": oy,
            "distortionAmplitude": distortion(t), "distortionSpeed": 0.08,
            "logSphereAmount": log_sphere(t), "fractalNoiseAmount": fractal_noise(t),
            "chromaticAmount": chromatic(t), "fractalHueAmount": fractal_hue(t),
            "hueBlendAmount": c * 0.8, "hueWaveIntensity": c * 0.6}

# ---- PROPOSED look (docs/plans/effects-balance.md). Prototype of the numbers; the app's
# EffectsUniformsComputer is the implementation and must reproduce `proposed()` (plan section 7.1).

DEFAULT_INTENSITY = 0.5
MACRO_OMEGA = TWO_PI / 420.0              # clarity-cycle periods: 420 s, 260 s, 160 s
MACRO_PHASE = (-0.3, -1.2, -2.4)          # starts clear, first wild stretch after about a minute
MACRO_LO, MACRO_HI = -0.45, 0.55          # smoothstep window on the macro wave
MACRO_BIAS = 0.60                         # (intensity - 0.5) * bias is added to the wave
FRESH_FADE, FRESH_HOLD_END, FRESH_END = 1.5, 4.5, 11.0   # seconds since the crossfade started
K_TURB, K_LOG, K_NOISE = 12.8, 26.0, 28.0  # strain_p90 per unit amount (measured, fx_model scan)
LOG_MASK = (0.10, 0.42)                   # periphery mask on the log-spherical offset (radius)

def tri(i, a, b, c):
    """Piecewise-linear in intensity through (0, a), (0.5, b), (1, c)."""
    i = min(max(i, 0.0), 1.0)
    return a + (b - a) * i * 2 if i <= 0.5 else b + (c - b) * (i - 0.5) * 2

def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)

def macro_wave(t):
    w = MACRO_OMEGA
    return (math.sin(w * t + MACRO_PHASE[0]) + 0.6 * math.sin(w * PHI * t + MACRO_PHASE[1])
            + 0.35 * math.sin(w * PHI * PHI * t + MACRO_PHASE[2])) / 1.95

def macro_drive(t, intensity):
    return smoothstep(MACRO_LO, MACRO_HI, macro_wave(t) + (intensity - 0.5) * MACRO_BIAS)

def fresh(age):
    """0 while a new image settles, 1 once it has been seen. age = seconds since its crossfade began."""
    if age is None:
        return 1.0
    return 1.0 - smoothstep(0.0, FRESH_FADE, age) * (1.0 - smoothstep(FRESH_HOLD_END, FRESH_END, age))

def strain_budget(i):
    return tri(i, 0.30, 0.90, 1.45)

def proposed(t, intensity=DEFAULT_INTENSITY, age=None, tp=0.0):
    i = intensity
    d = macro_drive(t, i) * fresh(age)
    mix = lambda a, b: a + (b - a) * d
    t01 = (distortion(t) - 0.02) / 0.06
    l01 = (log_sphere(t) - 0.003) / 0.017
    n01 = (fractal_noise(t) - 0.005) / 0.025
    a_clear = tri(i, 0.010, 0.028, 0.036)
    a_t = a_clear + (tri(i, 0.016, 0.058, 0.072) - a_clear) * d * (0.55 + 0.45 * t01)
    a_l = tri(i, 0.0, 0.011, 0.020) * smoothstep(0.45, 0.90, d) * (0.35 + 0.65 * l01)
    a_n = tri(i, 0.0, 0.011, 0.022) * smoothstep(0.20, 0.80, d) * (0.35 + 0.65 * n01)
    # Recognisability budget: the radial and the crystalline warp give way before the water does.
    budget = strain_budget(i)
    st = K_TURB * a_t
    if st > budget:
        a_t, a_l, a_n = budget / K_TURB, 0.0, 0.0
    else:
        rest = math.hypot(K_LOG * a_l, K_NOISE * a_n)
        room = math.sqrt(budget * budget - st * st)
        if rest > room:
            a_l, a_n = a_l * room / rest, a_n * room / rest
    b = math.sin(math.pi * min(max(tp, 0.0), 1.0))
    a_t += tri(i, 0.05, 0.16, 0.40) * b
    a_l += tri(i, 0.0, 0.006, 0.020) * b
    a_n += tri(i, 0.004, 0.020, 0.060) * b
    c = color_cycle(t)
    hb = (0.35 + 0.65 * c) * mix(tri(i, 0.15, 0.40, 0.55), tri(i, 0.25, 0.65, 0.68))
    hw = min(c * mix(tri(i, 0.02, 0.12, 0.24), tri(i, 0.05, 0.28, 0.40)), 0.20, 0.065 / max(hb, 1e-3))
    s = 1.18 + 0.10 * math.sin(t * 0.05) + 0.04 * math.sin(t * 0.03)
    s = 1 + (s - 1) * (1 - tri(i, 0.0, 0.30, 0.60) * macro_drive(t, i))   # Ken Burns relief (E27)
    _, ox, oy = ken_burns(t)
    return {"time": t, "kenBurnsScale": s, "kenBurnsOffsetX": ox, "kenBurnsOffsetY": oy,
            "distortionAmplitude": a_t, "distortionSpeed": 0.08,
            "logSphereAmount": a_l, "fractalNoiseAmount": a_n,
            "chromaticAmount": min(chromatic(t) * mix(tri(i, 0.3, 1.0, 1.3), tri(i, 0.4, 1.3, 1.6)), 0.02) * (1 + 3 * b),
            "fractalHueAmount": fractal_hue(t) * mix(tri(i, 0.2, 0.75, 1.0), tri(i, 0.3, 1.0, 1.15)),
            "hueBlendAmount": hb,
            "hueWaveIntensity": hw,
            "feedbackMix": mix(tri(i, 0.10, 0.25, 0.31), tri(i, 0.14, 0.30, 0.34)),
            "bloomAmount": tri(i, 0.30, 0.50, 0.50),
            "_drive": d}

# ---- distortedUV (float; the shader's half precision does not matter at this scale)

def _flow(s, c, octaves):
    """flowOctaves: s, c are (3, H, W) sin/cos of the position."""
    e = 0.0
    w = 1.0
    for _ in range(octaves):
        a = s[[2, 0, 1]] - 0.5
        b = 1.0 - c[[1, 0, 2]]
        e = e + np.sin((a * b).sum(0)) * w
        s, c = 2 * s * c, 1 - 2 * s * s
        w *= 0.5
    return e

def turbulence(pos, time, speed):
    x, y = pos[0].copy(), pos[1].copy()
    m = np.array([[0.6, 0.8], [-0.8, 0.6]])  # Metal half2x2(0.6,-0.8,0.8,0.6) as a row-major matrix
    rot = m.copy()
    freq = 2.0
    ht = math.fmod(speed * time, TWO_PI)
    for i in range(8):
        phase = freq * (rot[1, 0] * x + rot[1, 1] * y) + ht + i
        s = np.sin(phase) / freq
        x = x + rot[0, 0] * s
        y = y + rot[1, 0] * s
        rot = rot @ m
        freq *= 1.4
    return np.stack([x - pos[0], y - pos[1]])

def log_spherical(uv, time, amount, mask=None):
    cx, cy = uv[0] - 0.5, uv[1] - 0.5
    r = np.hypot(cx, cy)
    rs = np.maximum(r, 0.001)
    p = np.stack([np.log2(rs) - math.fmod(time * 0.3, TWO_PI),
                  np.exp(1.0 - cy / rs),
                  np.arctan2(cy, cx) + math.cos(time * 0.5) * 0.2])
    e = p[1] - 1.0 + _flow(np.sin(p), np.cos(p), 6)
    d = e * amount
    if mask is not None:  # proposed periphery mask: smoothstep(mask[0], mask[1], R)
        m = np.clip((r - mask[0]) / (mask[1] - mask[0]), 0, 1)
        d = d * m * m * (3 - 2 * m)
    return np.stack([cx / rs * d, cy / rs * d])

def fractal_noise_field(uv, time, amount):
    p = np.stack([uv[0] * 6, uv[1] * 6, np.full_like(uv[0], math.fmod(time * 0.15, TWO_PI))])
    k = np.array([17.0, 31.0, 7.0])[:, None, None]
    nx = _flow(np.sin(p), np.cos(p), 5)
    ny = _flow(np.sin(p + k), np.cos(p + k), 5)
    return np.stack([nx, ny]) * amount

def distorted_uv(u, w=192, h=128, parts=("turbulence", "logsphere", "noise")):
    """Returns (kb_uv, final_uv), each (2, h, w), before the shader's final clamp."""
    xs = (np.arange(w) + 0.5) / w
    ys = (np.arange(h) + 0.5) / h
    tx, ty = np.meshgrid(xs, ys)
    kx = (tx - 0.5) / u["kenBurnsScale"] - u["kenBurnsOffsetX"] * 0.05 + 0.5
    ky = (ty - 0.5) / u["kenBurnsScale"] - u["kenBurnsOffsetY"] * 0.05 + 0.5
    kb = np.stack([kx, ky])
    uv = kb.copy()
    if "turbulence" in parts:
        uv = uv + turbulence(uv * 3.0, u["time"], u.get("distortionSpeed", 0.08)) * u["distortionAmplitude"]
    thr = 0.00002 if "_drive" in u else 0.001   # proposed uniforms imply the proposed shader edits
    if "logsphere" in parts and u["logSphereAmount"] > thr:
        uv = uv + log_spherical(uv, u["time"], u["logSphereAmount"], LOG_MASK if "_drive" in u else None)
    if "noise" in parts and u["fractalNoiseAmount"] > thr:
        uv = uv + fractal_noise_field(uv, u["time"], u["fractalNoiseAmount"])
    return kb, uv

def warp_stats(u, parts=("turbulence", "logsphere", "noise")):
    kb, uv = distorted_uv(u, parts=parts)
    d = uv - kb
    mag = np.hypot(d[0], d[1])
    h, w = mag.shape
    # Gradients per unit of *screen* UV (what the eye sees), not source UV.
    dxx = np.gradient(uv[0], axis=1) * w
    dxy = np.gradient(uv[0], axis=0) * h
    dyx = np.gradient(uv[1], axis=1) * w
    dyy = np.gradient(uv[1], axis=0) * h
    s = 1.0 / u["kenBurnsScale"]  # the Ken Burns map alone has Jacobian s * I
    strain = np.sqrt((dxx - s) ** 2 + dxy ** 2 + dyx ** 2 + (dyy - s) ** 2) / s
    det = (dxx * dyy - dxy * dyx) / (s * s)
    out = (uv < 0) | (uv > 1)
    return {"disp_p50": float(np.percentile(mag, 50)), "disp_p95": float(np.percentile(mag, 95)),
            "disp_max": float(mag.max()), "strain_p50": float(np.percentile(strain, 50)),
            "strain_p90": float(np.percentile(strain, 90)), "fold": float((det < 0.25).mean()),
            "clamped": float((out[0] | out[1]).mean())}

PARTSETS = {"all": ("turbulence", "logsphere", "noise"), "turbulence": ("turbulence",),
            "logsphere": ("logsphere",), "noise": ("noise",)}

GOLDEN_INPUTS = [  # (time, intensity, image age or None, transitionProgress)
    (0, 0.5, None, 0), (100, 0.5, 25, 0), (100, 0.0, 25, 0), (100, 0.25, 25, 0), (100, 1.0, 25, 0),
    (190, 0.5, 9, 0), (330, 0.5, 3, 0), (540, 1.0, 12, 0), (600, 0.5, 7, 0), (600, 0.5, 0.75, 0.5),
    (760, 0.75, 22, 0), (2000, 0.5, 15, 0),
]

def cmd_golden():
    out = []
    for t, i, age, tp in GOLDEN_INPUTS:
        u = proposed(t, i, age, tp)
        out.append({"time": t, "intensity": i, "age": age, "tp": tp,
                    **{k: round(v, 6) for k, v in u.items() if k != "time"}})
    print(json.dumps(out, indent=1))

def cmd_scan(step, end, proposed_intensity=None):
    rows = []
    t = 0.0
    while t <= end:
        u = uniforms(t) if proposed_intensity is None else proposed(t, proposed_intensity, t % 30.0)
        row = {"t": t, **{k: u[k] for k in ("distortionAmplitude", "logSphereAmount", "fractalNoiseAmount",
                                             "hueBlendAmount", "kenBurnsScale")}}
        for name, parts in PARTSETS.items():
            st = warp_stats(u, parts)
            for k in ("disp_p95", "strain_p90", "fold"):
                row[f"{name}_{k}"] = st[k]
        rows.append(row)
        t += step
    keys = list(rows[0])
    print(",".join(keys))
    for r in rows:
        print(",".join(f"{r[k]:.4f}" for k in keys))
    a = {k: np.array([r[k] for r in rows]) for k in keys}
    def line(k):
        v = a[k]
        return f"{k:28s} min {v.min():.4f}  p50 {np.median(v):.4f}  p90 {np.percentile(v, 90):.4f}  max {v.max():.4f}"
    print("\n# summary over time", file=sys.stderr)
    for k in keys[1:]:
        print(line(k), file=sys.stderr)
    for lim in (0.5, 1.0):
        print(f"time with all_strain_p90 > {lim}: {100 * (a['all_strain_p90'] > lim).mean():.0f} %", file=sys.stderr)
    print(f"time with all_fold > 0.02: {100 * (a['all_fold'] > 0.02).mean():.0f} %", file=sys.stderr)

def cmd_check(path):
    uni = json.load(open(path))["uniforms"]
    worst = 0.0
    for name, got in uni.items():
        want = uniforms(got["time"])
        for k, v in want.items():
            if name.endswith("_full") or "_" not in name:
                worst = max(worst, abs(v - got[k]))
    print(f"max |model - app| over the un-overridden scenarios: {worst:.2e}")

if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["scan"]:
        step = float(args[args.index("--step") + 1]) if "--step" in args else 5.0
        end = float(args[args.index("--end") + 1]) if "--end" in args else 900.0
        inten = None
        if "--proposed" in args:
            inten = float(args[args.index("--intensity") + 1]) if "--intensity" in args else DEFAULT_INTENSITY
        cmd_scan(step, end, inten)
    elif args[:1] == ["golden"]:
        cmd_golden()
    elif args[:1] == ["check"] and len(args) == 2:
        cmd_check(args[1])
    else:
        sys.exit(__doc__)
