"""Figures for the mix report (Matplotlib, Agg backend, about 110 dpi)."""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from . import lowend  # noqa: E402
from .audio import BAND_NAMES, SECTION_ORDER, THIRD_CENTERS  # noqa: E402
from .cadence import events_of  # noqa: E402
from .spectral import spectrogram  # noqa: E402

DPI = 110
FIGURES = ["spectrogram-4096", "spectrogram-1024", "spectrogram-256", "ltas", "band-energy", "masking-matrix",
           "masking-during-chops", "lowband-mono", "kick-bass", "loudness", "gain-reduction", "intelligibility",
           "bed", "mids-lead", "theme-return", "cadence"]
COLORS = {"drums": "#444444", "bass": "#1f77b4", "mids": "#2ca02c", "lead": "#d62728", "space": "#9467bd",
          "dialogue": "#ff7f0e", "bed": "#8c564b", "master": "#000000"}


def g(m, *path):
    cur = m
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur


def save(fig, outdir, name):
    fig.tight_layout()
    fig.savefig(Path(outdir) / f"{name}.png", dpi=DPI)
    plt.close(fig)


def empty(outdir, name, message):
    fig, ax = plt.subplots(figsize=(6, 2))
    ax.axis("off")
    ax.text(0.5, 0.5, f"{name}: {message}", ha="center", va="center", wrap=True)
    save(fig, outdir, name)


def plot_spectrograms(cap, outdir):
    rows = [(s, cap.section_signal(s)) for s in SECTION_ORDER] + [("master", cap.signal(["master"]))]
    for nfft in (4096, 1024, 256):
        fig, axes = plt.subplots(len(rows), 1, figsize=(11, 1.35 * len(rows) + 0.6), sharex=True)
        for ax, (name, sig) in zip(axes, rows):
            ax.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=8)
            if sig is None:
                ax.text(0.5, 0.5, "absent", transform=ax.transAxes, ha="center", fontsize=8)
                ax.set_yticks([])
                continue
            f, t, p = spectrogram(np.asarray(sig), cap.rate, nfft)
            keep = f >= 20
            db = 10 * np.log10(np.maximum(p[keep], 1e-14))
            top = np.percentile(db, 99.5)
            ax.pcolormesh(t, f[keep], db, vmin=top - 70, vmax=top, cmap="magma", shading="auto", rasterized=True)
            ax.set_yscale("log")
            ax.set_ylim(40, min(16000, cap.rate / 2))
            ax.tick_params(labelsize=7)
        axes[-1].set_xlabel("seconds")
        fig.suptitle(f"Spectrogram, FFT {nfft} ({cap.case})", fontsize=10)
        save(fig, outdir, f"spectrogram-{nfft}")


def plot_ltas(m, outdir):
    sig = g(m, "spectrum", "signals")
    if not sig:
        return empty(outdir, "ltas", "no spectrum")
    fig, ax = plt.subplots(figsize=(9, 5))
    for name, v in sig.items():
        ax.plot(THIRD_CENTERS, v["densityDb"], label=f"{name} ({v['tiltDbPerOctave'] if v['tiltDbPerOctave'] is None else round(v['tiltDbPerOctave'], 1)} dB/oct)",
                color=COLORS.get(name), lw=2 if name == "master" else 1.2)
    ax.set_xscale("log")
    ax.set_xlabel("Hz")
    ax.set_ylabel("power density, dB per Hz")
    ax.grid(alpha=0.3, which="both")
    ax.legend(fontsize=8)
    ax.set_title("Long-term third-octave spectrum (tilt 250 Hz to 8 kHz)")
    save(fig, outdir, "ltas")


def plot_band_energy(m, outdir):
    e = m.get("bandEnergyDb")
    if not e:
        return empty(outdir, "band-energy", "no band energy")
    fig, ax = plt.subplots(figsize=(10, 4.5))
    n = len(e)
    for i, (s, v) in enumerate(e.items()):
        ax.bar(np.arange(len(BAND_NAMES)) + (i - n / 2) * 0.8 / n, v, width=0.8 / n, label=s, color=COLORS.get(s))
    ax.set_xticks(range(len(BAND_NAMES)), BAND_NAMES)
    ax.set_ylabel("mean-square level, dB")
    ax.legend(ncol=n, fontsize=8)
    ax.set_title("Band energy per section")
    ax.grid(alpha=0.3, axis="y")
    save(fig, outdir, "band-energy")


def plot_matrix(m, key, name, title, outdir):
    mm = g(m, "masking", key)
    if not mm:
        return empty(outdir, name, "no data (no chops or no dialogue)")
    secs = mm["sections"]
    data = np.array([[np.nan if v is None else v for v in mm["marginDb"][s]] for s in secs])
    fig, ax = plt.subplots(figsize=(9, 4.2))
    im = ax.imshow(data, cmap="RdBu", vmin=-30, vmax=30, aspect="auto")
    ax.set_xticks(range(len(BAND_NAMES)), BAND_NAMES)
    ax.set_yticks(range(len(secs)), secs)
    for i in range(data.shape[0]):
        for j in range(data.shape[1]):
            if np.isfinite(data[i, j]):
                ax.text(j, i, f"{data[i, j]:.0f}", ha="center", va="center", fontsize=8)
    fig.colorbar(im, label="section level minus power sum of the others (dB)")
    ax.set_title(title)
    save(fig, outdir, name)


def plot_lowband(m, outdir):
    lb = m.get("lowbandMono")
    if not lb or "correlation" not in lb:
        return empty(outdir, "lowband-mono", "no data")
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))
    axes[0].bar(BAND_NAMES, lb["correlation"], color="#1f77b4")
    axes[0].axhline(0.8, color="r", ls="--", lw=0.8)
    axes[0].axhline(0.3, color="r", ls=":", lw=0.8)
    axes[0].set_ylim(-1, 1)
    axes[0].set_title("Master L/R correlation per band")
    axes[1].bar(BAND_NAMES, lb["midSideDb"], color="#2ca02c")
    axes[1].set_title(f"Mid over side (dB); mono fold loss {lb['monoLossLu']:.2f} LU")
    for ax in axes:
        ax.tick_params(axis="x", labelsize=7, rotation=30)
        ax.grid(alpha=0.3, axis="y")
    save(fig, outdir, "lowband-mono")


def plot_kick_bass(cap, m, outdir):
    kb = m.get("kickBass")
    if not kb or kb.get("skipped"):
        return empty(outdir, "kick-bass", (kb or {}).get("skipped", "no data"))
    rate = cap.rate
    kicks = [k for k in cap.kicks() if 0 <= k < cap.frames][:400]
    d = lowend.band_signal(cap.signal(["drums"]), rate, 40, 120)
    b = lowend.band_signal(cap.signal(["bass"]), rate, 40, 120)
    pre, post, step = int(0.05 * rate), int(0.25 * rate), int(0.005 * rate)
    t = np.arange(-pre, post, step) / rate * 1000
    curves = {"drums": [], "bass": [], "sum": []}
    for k in kicks:
        if k - pre < 0 or k + post > len(d):
            continue
        for name, x in (("drums", d), ("bass", b), ("sum", d + b)):
            seg = x[k - pre: k + post]
            curves[name].append(np.sqrt((seg[: (len(seg) // step) * step].reshape(-1, step) ** 2).mean(axis=1)))
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for name, rows in curves.items():
        if rows:
            ax.plot(t[: len(rows[0])], 20 * np.log10(np.maximum(np.median(rows, axis=0), 1e-6)), label=name)
    ax.axvline(0, color="k", lw=0.6)
    ax.set_xlabel("ms from kick")
    ax.set_ylabel("40-120 Hz RMS (dBFS, median over kicks)")
    ax.legend()
    ax.grid(alpha=0.3)
    ax.set_title(f"Kick and bass: sum vs louder median {kb.get('sumVsLouderDbMedian')}, duck {kb.get('duckDepthDbMedian')} dB, lag {kb.get('lagMsMedian', 'n/a')} ms")
    save(fig, outdir, "kick-bass")


def plot_loudness(m, outdir):
    st, mo = g(m, "loudness", "shortTermSeries1Hz"), g(m, "loudness", "momentarySeries1Hz")
    if not st:
        return empty(outdir, "loudness", "no data")
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.plot(np.arange(len(mo)), [np.nan if v is None else v for v in mo], lw=0.8, label="momentary", alpha=0.6)
    ax.plot(np.arange(len(st)), [np.nan if v is None else v for v in st], lw=1.6, label="short-term")
    ax.axhline(g(m, "loudness", "integratedLufs"), color="k", ls="--", lw=0.8, label="integrated")
    ax.axhspan(-13, -11, color="g", alpha=0.08)
    ax.set_ylim(-40, -5)
    ax.set_xlabel("seconds")
    ax.set_ylabel("LUFS")
    ax.legend()
    ax.grid(alpha=0.3)
    ax.set_title("Loudness (green band: ref target)")
    save(fig, outdir, "loudness")


def plot_gain_reduction(aux, m, outdir):
    dyn = aux.get("dynamics") or {}
    gain = dyn.get("_gain")
    if gain is None:
        return empty(outdir, "gain-reduction", "no gain trace")
    hop = dyn["_hop"]
    t = np.arange(len(gain)) * hop
    fig, axes = plt.subplots(2, 1, figsize=(11, 5.5), sharex=False)
    axes[0].plot(t, gain, lw=0.6)
    axes[0].set_ylabel(f"master gain dB ({dyn.get('pumpingSource')})")
    axes[0].set_xlabel("seconds")
    axes[0].grid(alpha=0.3)
    axes[0].set_title(f"Master gain; pumping index {g(m, 'dynamics', 'pumpingIndexDb')}, kick dip {g(m, 'dynamics', 'kickDipDb')} dB")
    red = -np.minimum(gain, 0)
    axes[1].hist(red[red > 0.01] if (red > 0.01).any() else red, bins=60, color="#444")
    axes[1].set_xlabel("reduction dB (active hops)")
    axes[1].set_yscale("log")
    save(fig, outdir, "gain-reduction")


def plot_intelligibility(m, outdir):
    d = m.get("dialogue")
    if not d or d.get("skipped"):
        return empty(outdir, "intelligibility", (d or {}).get("skipped", "no data"))
    per = d["perChop"]
    fig, axes = plt.subplots(1, 3, figsize=(13, 4))
    axes[0].bar(range(len(per)), [p["sii"] for p in per], color="#ff7f0e")
    axes[0].axhline(0.55, color="r", ls="--", lw=0.8)
    axes[0].set_title(f"SII proxy per chop (mean {d['siiMean']:.2f}, p10 {d['siiP10']:.2f})")
    snr = np.array([p["snrOctaveDb"] for p in per])
    im = axes[1].imshow(snr.T, aspect="auto", cmap="RdBu", vmin=-20, vmax=20)
    axes[1].set_yticks(range(len(d["octaveCenters"])), d["octaveCenters"])
    axes[1].set_title("octave SNR (dB) by chop")
    fig.colorbar(im, ax=axes[1])
    axes[2].bar(range(len(per)), [p["lufs"] if p["lufs"] is not None else np.nan for p in per], color="#8c564b")
    axes[2].set_title(f"per-chop LUFS (spread {d.get('loudnessSpreadLu')})")
    save(fig, outdir, "intelligibility")


def plot_bed(m, outdir):
    b = m.get("bed")
    if not b or b.get("skipped"):
        return empty(outdir, "bed", (b or {}).get("skipped", "no data"))
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))
    if b.get("gapSnrOctaveDb"):
        axes[0].bar([str(c) for c in (250, 500, 1000, 2000, 4000, 8000)], b["gapSnrOctaveDb"], color="#8c564b")
        axes[0].set_title(f"Bed SNR in gaps; audibility {b.get('audibilityIndex'):.2f}")
        axes[0].set_ylabel("dB")
    sig = g(m, "spectrum", "signals", "bed")
    if sig:
        axes[1].plot(THIRD_CENTERS, sig["densityDb"], color="#8c564b")
        axes[1].set_xscale("log")
        axes[1].set_title(f"Bed spectrum; roll-off {b.get('rolloff85Hz')} Hz; direct/wet {b.get('directToWetDb')} dB")
    for ax in axes:
        ax.grid(alpha=0.3)
    save(fig, outdir, "bed")


def plot_mids_lead(m, outdir):
    ml = m.get("midsLead")
    if not ml or ml.get("skipped"):
        return empty(outdir, "mids-lead", (ml or {}).get("skipped", "no data"))
    fig, axes = plt.subplots(1, 2, figsize=(10, 4))
    labels, lead, mids = [], [], []
    for key in ("bothPlay", "leadRestMidsPlay"):
        if key in ml:
            labels.append(key)
            lead.append(ml[key]["leadDb"])
            mids.append(ml[key]["midsDb"])
    x = np.arange(len(labels))
    axes[0].bar(x - 0.2, lead, 0.4, label="lead", color=COLORS["lead"])
    axes[0].bar(x + 0.2, mids, 0.4, label="mids", color=COLORS["mids"])
    axes[0].set_xticks(x, labels)
    axes[0].set_ylabel("400 Hz to 3 kHz level (dB)")
    axes[0].legend()
    arts = ml.get("articulationsPer16Bars") or {}
    axes[1].bar(list(arts.keys()), list(arts.values()), color=COLORS["mids"])
    axes[1].axhline(2, color="r", ls="--", lw=0.8)
    axes[1].set_title("Mid articulations per 16 bars (take)")
    save(fig, outdir, "mids-lead")


def plot_theme_return(m, outdir):
    tr = m.get("themeReturn")
    if not tr or tr.get("skipped"):
        return empty(outdir, "theme-return", (tr or {}).get("skipped", "no data"))
    takes = tr["takes"]
    fig, axes = plt.subplots(1, 2, figsize=(10, 4))
    x = np.arange(len(takes))
    axes[0].bar(x - 0.2, [t["themeSalienceDb"] or np.nan for t in takes], 0.4, label="theme")
    axes[0].bar(x + 0.2, [t["returnSalienceDb"] or np.nan for t in takes], 0.4, label="return")
    axes[0].axhline(6, color="r", ls="--", lw=0.8)
    axes[0].set_xticks(x, [f"take {t['take']}" for t in takes])
    axes[0].set_ylabel("lead salience dB")
    axes[0].legend()
    axes[1].bar(x, [t["onsetCorrelation"] or 0 for t in takes], color="#d62728")
    axes[1].axhline(0.8, color="r", ls="--", lw=0.8)
    axes[1].set_ylim(0, 1)
    axes[1].set_xticks(x, [f"take {t['take']} {'same' if t['sameProgram'] else 'DIFFERENT'} program" for t in takes], fontsize=7)
    axes[1].set_title("Onset envelope correlation theme vs return")
    save(fig, outdir, "theme-return")


def plot_cadence(cap, m, outdir):
    cad = m.get("cadence")
    if not cad or cad.get("skipped"):
        return empty(outdir, "cadence", (cad or {}).get("skipped", "no dialogue"))
    ev = events_of(cap)
    fig, axes = plt.subplots(2, 1, figsize=(12, 6), gridspec_kw={"height_ratios": [3, 1.4]})
    bar = cap.bar_frames
    for e in ev:
        axes[0].plot([e["frame"] / bar, max(e["end"], e["frame"] + 1) / bar], [hash(e["key"]) % 17] * 2, lw=3)
    for edge in np.arange(0, cap.scored_frames / bar + 1, 8):
        axes[0].axvline(edge, color="k", lw=0.8)
    for edge in np.arange(0, cap.scored_frames / bar + 1, 16):
        axes[0].axvline(edge, color="r", lw=1.2)
    axes[0].set_xlabel("bar (red: 16-bar windows, black: 8 bars)")
    axes[0].set_ylabel("source key (hashed)")
    axes[0].set_title(f"Dialogue events: {cad['events']}, dry overlaps {cad.get('dryOverlaps')}")
    diffs = cad.get("window16Differences") or []
    axes[1].bar([f"{d['from']}->{d['to']}" for d in diffs], [d["difference"] for d in diffs], color="#ff7f0e")
    axes[1].axhline(0.25, color="r", ls="--", lw=0.8)
    axes[1].set_ylim(0, 1)
    axes[1].set_title("16-bar window difference (1 - |intersection| / max size)")
    save(fig, outdir, "cadence")


def make_all(cap, metrics, aux, outdir, log=print):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    jobs = [("spectrograms", lambda: plot_spectrograms(cap, outdir)),
            ("ltas", lambda: plot_ltas(metrics, outdir)),
            ("band-energy", lambda: plot_band_energy(metrics, outdir)),
            ("masking-matrix", lambda: plot_matrix(metrics, "overall", "masking-matrix", "Masking: section minus the others (overall)", outdir)),
            ("masking-during-chops", lambda: plot_matrix(metrics, "duringChops", "masking-during-chops", "Masking during chop-active windows", outdir)),
            ("lowband-mono", lambda: plot_lowband(metrics, outdir)),
            ("kick-bass", lambda: plot_kick_bass(cap, metrics, outdir)),
            ("loudness", lambda: plot_loudness(metrics, outdir)),
            ("gain-reduction", lambda: plot_gain_reduction(aux, metrics, outdir)),
            ("intelligibility", lambda: plot_intelligibility(metrics, outdir)),
            ("bed", lambda: plot_bed(metrics, outdir)),
            ("mids-lead", lambda: plot_mids_lead(metrics, outdir)),
            ("theme-return", lambda: plot_theme_return(metrics, outdir)),
            ("cadence", lambda: plot_cadence(cap, metrics, outdir))]
    for name, job in jobs:
        try:
            job()
        except Exception as exc:
            log(f"  plot {name} failed: {type(exc).__name__}: {exc}")
            if name == "spectrograms":
                for n in (4096, 1024, 256):
                    empty(outdir, f"spectrogram-{n}", f"failed: {exc}")
            else:
                empty(outdir, name, f"failed: {exc}")


def compare_plots(cand, base, cand_results, base_results, outdir):
    """Spectrum overlay, loudness overlay and criteria table against a baseline report dict."""
    outdir = Path(outdir)
    fig, ax = plt.subplots(figsize=(9, 5))
    for label, doc, style in (("baseline", base, "--"), ("candidate", cand, "-")):
        s = g(doc["metrics"], "spectrum", "signals", "master")
        if s:
            ax.plot(THIRD_CENTERS, s["densityDb"], style, label=label)
    ax.set_xscale("log")
    ax.set_xlabel("Hz")
    ax.set_ylabel("master density dB/Hz")
    ax.legend()
    ax.grid(alpha=0.3, which="both")
    ax.set_title("Master long-term spectrum, baseline vs candidate")
    save(fig, outdir, "compare-spectrum")

    fig, ax = plt.subplots(figsize=(10, 4))
    for label, doc, style in (("baseline", base, "--"), ("candidate", cand, "-")):
        st = g(doc["metrics"], "loudness", "shortTermSeries1Hz")
        if st:
            ax.plot(np.arange(len(st)), [np.nan if v is None else v for v in st], style, label=f"{label} ({g(doc['metrics'], 'loudness', 'integratedLufs')} LUFS)")
    ax.set_ylim(-40, -5)
    ax.legend()
    ax.grid(alpha=0.3)
    ax.set_xlabel("seconds")
    ax.set_ylabel("short-term LUFS")
    save(fig, outdir, "compare-loudness")

    base_by = {r["id"]: r for r in base["criteria"]}
    rows = [[r["id"], r["level"], base_by.get(r["id"], {}).get("status", "-"), r["status"]] for r in cand["criteria"]]
    fig, ax = plt.subplots(figsize=(7, 0.28 * len(rows) + 1))
    ax.axis("off")
    table = ax.table(cellText=rows, colLabels=["criterion", "level", "baseline", "candidate"], loc="center")
    table.auto_set_font_size(False)
    table.set_fontsize(7)
    colors = {"pass": "#c8e6c9", "fail": "#ffcdd2", "warn": "#fff9c4", "skipped": "#eeeeee"}
    for i, row in enumerate(rows, start=1):
        for j in (2, 3):
            table[i, j].set_facecolor(colors.get(row[j], "white"))
    save(fig, outdir, "compare-criteria")
