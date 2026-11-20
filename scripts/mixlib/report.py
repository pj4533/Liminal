"""Run every measurement, evaluate scripts/mix-criteria.json, write the JSON and Markdown report."""

import json
import math
import time
import traceback
from pathlib import Path

import numpy as np

from . import cadence, dialogue, dynamics, lowend, masking, music, spectral
from .audio import BAND_NAMES, SECTION_ORDER, BandGrid, Capture, db10
from .loudness import ffmpeg_ebur128, measure_loudness, true_peak_db

SCHEMA = "liminal-mix-report-v1"
SKIP_OK = ("no dialogue", "no footage")


def safe(metrics, key, fn, *args):
    t0 = time.time()
    try:
        value = fn(*args)
    except Exception as exc:  # a missing input must never crash the report
        value = {"error": f"{type(exc).__name__}: {exc}", "trace": traceback.format_exc(limit=3)}
    if isinstance(value, dict):
        value["_seconds"] = round(time.time() - t0, 2)
    metrics[key] = value
    return value


def downsample_series(x, step):
    x = np.asarray(x, dtype=float)
    return [None if not math.isfinite(v) else round(float(v), 2) for v in x[::step]]


def run_analysis(cap, want_plots=True, log=print):
    """Return (metrics, aux). `aux` carries large arrays for plotting."""
    metrics = {"case": cap.case, "schema": cap.schema, "rate": cap.rate, "frames": cap.frames,
               "hasFootage": cap.has_footage, "seconds": cap.frames / cap.rate}
    aux = {}
    master = cap.stem("master")
    grid = BandGrid(cap.rate)
    aux["grid"] = grid
    t0 = time.time()

    def stage(name):
        log(f"  [{time.time() - t0:6.1f}s] {name}")

    stage("loudness and true peak")
    loud = measure_loudness(master, cap.rate)
    ff = ffmpeg_ebur128(cap.path / "master.wav") if cap.path and (cap.path / "master.wav").is_file() else {}
    loud["ffmpeg"] = ff
    loud["ffmpegDiffLu"] = (loud["integratedLufs"] - ff["integratedLufs"]) if ff.get("integratedLufs") is not None else None
    aux["loud"] = loud
    metrics["loudness"] = {
        "integratedLufs": loud["integratedLufs"], "lraLu": loud["lraLu"], "ffmpeg": ff,
        "ffmpegDiffLu": loud["ffmpegDiffLu"], "momentaryMaxLufs": loud["momentaryMaxLufs"],
        "shortTermMaxLufs": loud["shortTermMaxLufs"],
        "shortTermSeries1Hz": downsample_series(loud["shortTerm"], 10),
        "momentarySeries1Hz": downsample_series(loud["momentary"], 10),
    }
    recon = true_peak_db(master)
    sample_peak = float(20 * np.log10(max(float(np.max(np.abs(master))), 1e-12)))
    metrics["truePeak"] = {"ffmpegDbtp": ff.get("truePeakDbtp"), "reconstructionDbtp": recon,
                           "samplePeakDbfs": sample_peak}
    tp = ff.get("truePeakDbtp") if ff.get("truePeakDbtp") is not None else recon

    stage("crest, PLR, PSR")
    safe(metrics, "crest", dynamics.measure_crest, cap, loud, tp)

    stage("band energy grids")
    grids = {}
    for sec in SECTION_ORDER:
        grids[sec] = grid.for_section(cap, sec) if cap.has_section(sec) else None
    master_grid = grid.get(("stem", "master"), lambda: cap.signal(["master"]))
    aux["grids"], aux["master_grid"] = grids, master_grid
    present = {s: g for s, g in grids.items() if g is not None}

    stage("gain reduction and pumping")
    trace = None
    raw = cap.extra_files.get("master-gr.csv")
    if raw is None and cap.path and (cap.path / "master-gr.csv").is_file():
        raw = (cap.path / "master-gr.csv").read_bytes()
    if raw is not None:
        try:
            trace = dynamics.parse_gr_csv(raw)
        except Exception as exc:
            metrics["gainReductionTraceError"] = str(exc)
    dyn = safe(metrics, "dynamics", dynamics.measure_dynamics, cap, trace)
    aux["dynamics"] = dyn

    stage("spectrum, tilt, band shares")
    named = {s: g for s, g in present.items()}
    named["master"] = master_grid
    safe(metrics, "spectrum", spectral.measure_ltas, cap, grid, named)
    p = (master_grid["PL"] + master_grid["PR"]) * 0.5
    total = float(p.mean(axis=0).sum())
    below25 = float(p.mean(axis=0)[grid.sl(0, 25)].sum())
    metrics["masterBelow25HzDbUnderTotalGrid"] = float(db10(total) - db10(max(below25, 1e-20)))
    try:
        metrics["masterBelow25HzDbUnderTotal"] = spectral.energy_below_db_under_total(master, cap.rate)
        metrics["masterBelow25HzMethod"] = "Welch, 0.7 Hz bins (the 4096-point grid leaks 40 to 60 Hz into 0 to 25 Hz)"
    except Exception as exc:
        metrics["masterBelow25HzDbUnderTotal"] = metrics["masterBelow25HzDbUnderTotalGrid"]
        metrics["masterBelow25HzMethod"] = f"4096-point grid ({exc})"

    stage("masking matrix")
    safe(metrics, "masking", masking.measure_masking, cap, grid, present)
    overall = masking.section_band_energy(grid, present)
    metrics["lowBandClearanceDb"] = masking.low_band_clearance(overall)
    metrics["bandEnergyDb"] = {s: [round(float(db10(e)), 2) for e in v] for s, v in overall.items()}

    stage("low-band mono")
    safe(metrics, "lowbandMono", lowend.measure_lowband_mono, cap, grid, master_grid, master)
    stage("kick and bass")
    safe(metrics, "kickBass", lowend.measure_kick_bass, cap)
    if present.get("bass") is not None and present.get("drums") is not None:
        e = overall
        metrics["bassVsDrums60to250Db"] = float(db10(max(e["bass"][1] + e["bass"][2], 1e-20))
                                                - db10(max(e["drums"][1] + e["drums"][2], 1e-20)))
        pb = ((present["bass"]["PL"] + present["bass"]["PR"]) * 0.5).mean(axis=0)
        fund = float(pb[grid.sl(40, 150)].sum())
        harm = float(pb[grid.sl(150, 800)].sum())
        metrics["bassHarmonicsVsFundamentalDb"] = float(db10(max(harm, 1e-20)) - db10(max(fund, 1e-20)))

    stage("dialogue intelligibility and bed")
    safe(metrics, "dialogue", dialogue.measure_dialogue, cap, grid, present)
    safe(metrics, "bed", dialogue.measure_bed, cap, grid, present)
    stage("mids, lead, theme return")
    safe(metrics, "midsLead", music.measure_mids_lead, cap, grid, present)
    safe(metrics, "themeReturn", music.measure_theme_return, cap, grid, present)
    safe(metrics, "spaceVsLead", music.measure_space_vs_lead, cap, grid, present)
    stage("cadence")
    safe(metrics, "cadence", cadence.measure_cadence, cap)
    metrics["stemChains"] = cap.stem_chains()
    metrics["engineDiagnostics"] = sorted((cap.diagnostics or {}).keys())
    metrics["taps"] = [n for n in ("dialogue-dry", "bed-post", "master-in", "glue") if cap.has(n)]
    metrics["routing"] = (cap.analysis or {}).get("routing")
    metrics["analysisPassed"] = (cap.analysis or {}).get("passed")
    stage("done")
    return metrics, aux


# ---------------------------------------------------------------------------------- criteria

def _in(v, lohi):
    if v is None:
        return None
    lo, hi = lohi
    return (lo is None or v >= lo) and (hi is None or v <= hi)


class Check:
    """Accumulates sub-checks for one criterion."""

    def __init__(self):
        self.values, self.fails, self.skipped, self.passed, self.notes = {}, [], [], 0, []

    def note(self, text):
        self.notes.append(text)

    def test(self, name, value, ok, note=None):
        self.values[name] = None if value is None else (round(value, 4) if isinstance(value, float) else value)
        if value is None or ok is None:
            self.skipped.append(name if note is None else f"{name}: {note}")
        elif ok:
            self.passed += 1
        else:
            self.fails.append(name)

    def result(self):
        if not self.passed and not self.fails:
            out = {"status": "skipped", "reason": "; ".join(self.skipped) or "no inputs", "values": self.values}
            if self.notes:
                out["notes"] = self.notes
            return out
        out = {"status": "fail" if self.fails else "pass", "values": self.values}
        if self.fails:
            out["failedChecks"] = self.fails
        if self.skipped:
            out["skippedChecks"] = self.skipped
        if self.notes:
            out["notes"] = self.notes
        return out


def g(m, *path, default=None):
    cur = m
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return default
        cur = cur[p]
    return cur


def ev_C_M1(m, b, c):
    c.test("integratedLufs", g(m, "loudness", "integratedLufs"), _in(g(m, "loudness", "integratedLufs"), b["integratedLufs"]))


def ev_C_M2(m, b, c):
    f, r = g(m, "truePeak", "ffmpegDbtp"), g(m, "truePeak", "reconstructionDbtp")
    c.test("ffmpegDbtp", f, None if f is None else f <= b["ffmpegDbtpMax"])
    c.test("reconstructionDbtp", r, None if r is None else r <= b["reconstructionDbtpMax"])


def ev_C_M3(m, b, c):
    v = g(m, "crest", "plrDb")
    c.test("plrDb", v, _in(v, b["plrDb"]))


def ev_C_M4(m, b, c):
    s, p = g(m, "loudness", "shortTermMaxLufs"), g(m, "crest", "psrDb")
    c.test("shortTermMaxLufs", s, None if s is None else s <= b["shortTermMaxLufsMax"])
    c.test("psrDb", p, None if p is None else p >= b["psrDbMin"])


def ev_C_M5(m, b, c):
    v = g(m, "crest", "master", "crestDb")
    c.test("masterCrestDb", v, _in(v, b["crestDb"]))


def ev_C_M6(m, b, c):
    src = "engine" if g(m, "dynamics", "engine") else "inferred"
    if src == "engine":
        s = g(m, "dynamics", "engine", "limiter")
        mean, p95, mx, above = s["meanDb"], s["p95Db"], s["maxDb"], s["aboveFraction"]
    else:
        s = g(m, "dynamics", "inferred")
        if not s:
            return
        mean, p95, mx, above = s["meanReductionDb"], s["p95ReductionDb"], s["maxReductionDb"], s["above3dbFraction"]
    c.values["source"] = src
    cc = g(m, "dynamics", "crossCheck")
    if cc:
        c.values["inferredP95DisagreementDb"] = round(cc["p95DisagreementDb"], 3)
        if cc["warn"]:
            c.note(f"engine total reduction p95 {cc['engineTotalP95Db']:.2f} dB against {cc['inferredP95Db']:.2f} dB inferred "
                   f"from pre-master and master: disagreement {cc['p95DisagreementDb']:.2f} dB is above 1 dB")
    c.test("meanDb", mean, mean <= b["meanDbMax"])
    c.test("p95Db", p95, p95 <= b["p95DbMax"])
    c.test("maxDb", mx, mx <= b["maxDbMax"])
    c.test("above3dbFraction", above, above <= b["above3dbFractionMax"])


def ev_C_M7(m, b, c):
    s = g(m, "dynamics", "engine", "glue")
    if not s:
        c.test("glue", None, None, "no master-gr.csv")
        return
    c.test("p95Db", s["p95Db"], s["p95Db"] <= b["p95DbMax"])
    c.test("meanDb", s["meanDb"], _in(s["meanDb"], b["meanDb"]))


def ev_C_M8(m, b, c):
    p, k = g(m, "dynamics", "pumpingIndexDb"), g(m, "dynamics", "kickDipDb")
    c.test("pumpingIndexDb", p, None if p is None else p <= b["pumpingIndexDbMax"])
    c.test("kickDipDb", k, None if k is None else k <= b["kickDipDbMax"])


def ev_C_M9(m, b, c):
    v = g(m, "dynamics", "engine", "clipEngagedFractionSamples")
    hop = g(m, "dynamics", "engine", "clip", "engagedFraction")
    if v is None:
        v = hop  # no per-sample meter in the manifest: the per-hop fraction overstates it
    else:
        c.values["clipEngagedFractionHops"] = None if hop is None else round(hop, 4)
    c.test("clipEngagedFraction", v, None if v is None else v <= b["engagedFractionMax"], "no master-gr.csv")


def ev_C_M10(m, b, c):
    lo, fb, ml = (g(m, "lowbandMono", k) for k in ("below120Correlation", "fullBandCorrelation", "monoLossLu"))
    c.test("below120Correlation", lo, None if lo is None else lo >= b["below120CorrelationMin"])
    c.test("fullBandCorrelation", fb, None if fb is None else fb >= b["fullBandCorrelationMin"])
    c.test("monoLossLu", ml, None if ml is None else ml <= b["monoLossLuMax"])


def ev_C_M11(m, b, c):
    v = g(m, "masterBelow25HzDbUnderTotal")
    c.test("below25HzDbUnderTotal", v, None if v is None else v >= b["below25HzDbUnderTotalMin"])
    t = g(m, "spectrum", "signals", "master", "tiltDbPerOctave")
    c.test("tiltDbPerOctave", t, _in(t, b["tiltDbPerOctave"]))


def ev_C_M12(m, b, c):
    v = g(m, "loudness", "lraLu")
    c.test("lraLu", v, _in(v, b["lraLu"]))


def ev_C_B1(m, b, c):
    clr = m.get("lowBandClearanceDb") or {}
    for s, v in clr.items():
        c.test(f"{s}UnderDb", v, v >= b["clearanceDbMin"])


def ev_C_B2(m, b, c):
    kb = m.get("kickBass") or {}
    if kb.get("skipped"):
        c.test("kickBass", None, None, kb["skipped"])
        return
    for key, bound in (("lagMsMedian", "lagMsMedianMax"), ("lagMsP90", "lagMsP90Max")):
        v = kb.get(key)
        c.test(key, v, None if v is None else v <= b[bound], kb.get("lagSkipped", "no diagnostics.bass"))
    v = kb.get("sumVsLouderDbMedian")
    c.test("sumVsLouderDbMedian", v, None if v is None else v >= b["sumMedianDbMin"], kb.get("sumSkipped"))
    v = kb.get("sumVsLouderDbWorst")
    c.test("sumVsLouderDbWorst", v, None if v is None else v >= b["sumWorstDbMin"], kb.get("sumSkipped"))
    v = kb.get("duckDepthDbMedian")
    c.test("duckDepthDbMedian", v, _in(v, b["duckDepthDb"]), kb.get("duckSkipped"))
    for k in ("kicksWithBass", "duckKicks", "alignedAccents", "lagMsMax"):
        if kb.get(k) is not None:
            c.values[k] = kb[k]


def ev_C_B3(m, b, c):
    v = m.get("bassVsDrums60to250Db")
    c.test("bassVsDrums60to250Db", v, _in(v, b["bassVsDrumsDb"]))
    h = m.get("bassHarmonicsVsFundamentalDb")
    c.test("bassHarmonicsVsFundamentalDb", h, None if h is None else h >= b["harmonicsVsFundamentalDbMin"])


def ev_C_B4(m, b, c):
    d = g(m, "crest", "buses", "drums") or {}
    c.test("drumCrestDb", d.get("crestDb"), _in(d.get("crestDb"), b["crestDb"]))
    pk = d.get("samplePeakDbfs")
    c.test("drumPeakDbfs", pk, None if pk is None else pk <= b["peakDbfsMax"])
    chains = [e for e in (m.get("stemChains") or []) if e.get("bus") == "drums"]
    ratios = [float(e[k]) for e in chains for k in ("kickAttackRatio", "attackTimeRatio", "attackRatio") if e.get(k) is not None]
    peaks = [float(e["outPeakDb"]) for e in chains if e.get("outPeakDb") is not None]
    if peaks:
        c.test("drumBusOutPeakDb", max(peaks), max(peaks) <= b["peakDbfsMax"])
    c.test("kickAttackRatioMax", max(ratios) if ratios else None, None if not ratios else max(ratios) <= b["kickAttackRatioMax"],
           "no diagnostics.stemChains attack-time ratio")


def ev_C_B5(m, b, c):
    ml = m.get("midsLead") or {}
    if ml.get("skipped"):
        c.test("midsLead", None, None, ml["skipped"])
        return
    v = g(ml, "bothPlay", "leadMinusMidsDb")
    c.test("leadMinusMidsDb", v, _in(v, b["leadMinusMidsDb"]))
    r = g(ml, "leadRestMidsPlay", "leadMinusMidsDb")
    c.test("midsOverLeadInRestsDb", None if r is None else -r, None if r is None else -r >= b["midsOverLeadInRestsDbMin"],
           ml.get("leadRestMidsPlaySkipped", "no lead rest where the mids play"))
    arts = ml.get("articulationsPer16BarsEngine") or ml.get("articulationsPer16Bars")
    if ml.get("articulationsPer16BarsEngine"):
        c.values["articulationSource"] = "engine musicLevels"
    if arts:
        low = min(arts.values())
        c.test("minArticulationsPer16Bars", low, low >= b["articulationsPer16BarsMin"])


def ev_C_B6(m, b, c):
    tr = m.get("themeReturn") or {}
    if tr.get("skipped"):
        c.test("themeReturn", None, None, tr["skipped"])
        return
    for t in tr["takes"]:
        k = f"take{t['take']}"
        r, th, co = t["returnSalienceDb"], t["themeSalienceDb"], t["onsetCorrelation"]
        c.test(f"{k}ReturnSalienceDb", r, None if r is None else r >= b["returnSalienceDbMin"])
        if "returnHookChopFree" in t:
            free = t["returnHookChopFree"]
            if b.get("returnHookChopFree"):
                c.test(f"{k}ReturnHookChopFree", free, free)
            if t.get("returnSalienceWithDialogueDb") is not None:
                c.values[f"{k}ReturnSalienceWithDialogueDb"] = t["returnSalienceWithDialogueDb"]
        c.test(f"{k}ReturnMinusThemeDb", None if (r is None or th is None) else r - th,
               None if (r is None or th is None) else r - th >= 0)
        c.test(f"{k}OnsetCorrelation", co, None if co is None else co >= b["onsetCorrelationMin"])
        c.test(f"{k}SameProgram", t["sameProgram"], t["sameProgram"])


def ev_C_B7(m, b, c):
    v = g(m, "spaceVsLead", "median")
    c.test("leadMinusSpaceDbMedian", v, None if v is None else v >= b["leadMinusSpaceDbMin"])


def ev_C_B8(m, b, c):
    d = m.get("dialogue") or {}
    if d.get("skipped"):
        c.test("dialogue", None, None, d["skipped"])
        return
    c.test("siiMean", d.get("siiMean"), d["siiMean"] >= b["siiMeanMin"])
    c.test("siiP10", d.get("siiP10"), None if d.get("siiP10") is None else d["siiP10"] >= b["siiP10Min"],
           f"only {d.get('chops')} featured chops")
    c.test("snr1to4kMeanDb", d.get("snr1to4kMeanDb"), d["snr1to4kMeanDb"] >= b["snr1to4kMeanDbMin"])
    s = d.get("loudnessSpreadLu")
    c.test("loudnessSpreadLu", s, None if s is None else s <= b["loudnessSpreadLuMax"], f"only {d.get('chops')} featured chops")


def ev_C_B9(m, b, c):
    bed = m.get("bed") or {}
    if bed.get("skipped"):
        c.test("bed", None, None, bed["skipped"])
        return
    # Bounds absent from the criteria file are reported without gating (the user direction of 19 November
    # 2026 replaced "direct to wet at least +3 dB" and "roll-off at least 3 kHz", see the measurements doc).
    def opt(key, v, ok):
        if ok is None:
            c.values[key] = None if v is None else round(float(v), 4)
        else:
            c.test(key, v, ok)
    v = bed.get("directToWetDb")
    if "directToWetDbMax" in b:
        c.test("directToWetDb", v, None if v is None else v <= b["directToWetDbMax"], bed.get("directToWetSkipped"))
    elif "directToWetDbMin" in b:
        c.test("directToWetDb", v, None if v is None else v >= b["directToWetDbMin"], bed.get("directToWetSkipped"))
    else:
        opt("directToWetDb", v, None)
    v = bed.get("audibilityIndex")
    c.test("audibilityIndex", v, _in(v, b["audibilityIndex"]), bed.get("gapsSkipped"))
    v = bed.get("bedUnderMixInGapsDb")
    if "bedUnderMixInGapsDbMin" in b:
        c.test("bedUnderMixInGapsDb", v, None if v is None else v >= b["bedUnderMixInGapsDbMin"], bed.get("gapsSkipped"))
    v = bed.get("dialogueOverBed1to4kDb")
    c.test("dialogueOverBed1to4kDb", v, None if v is None else v >= b["dialogueOverBedDbMin"])
    v = bed.get("rolloff85HzBedPost", bed.get("rolloff85Hz"))
    if bed.get("rolloff85HzBedPost") is not None:
        c.values["rolloffSource"] = "bed-post"
    opt("rolloff85Hz", v, None if "rolloffHzMin" not in b else v is not None and v >= b["rolloffHzMin"])


def ev_C_B10(m, b, c):
    r = m.get("routing")
    if not r:
        c.test("routing", None, None, "analysis.json missing")
        return
    c.test("preMasterSumPeakResidual", r.get("preMasterSumPeakResidual"), r.get("preMasterSumPeakResidual", 1) <= b["residualMax"])
    c.test("musicStemSumPeakResidual", r.get("musicStemSumPeakResidual"), r.get("musicStemSumPeakResidual", 1) <= b["residualMax"])


def _cad(m):
    cad = m.get("cadence") or {}
    return cad


def ev_C_D1(m, b, c):
    diffs = _cad(m).get("window16Differences")
    if diffs is None:
        c.test("window16Differences", None, None, "no cadence")
        return
    if not diffs:
        c.test("pairs", None, None, "fewer than two complete 16-bar windows with dialogue")
        return
    low = min(d["difference"] for d in diffs)
    c.values["source"] = "plan log, recomputed from scheduled events" if _cad(m).get("plan") else "scheduled events"
    c.test("minDifference", low, low >= b["differenceMin"])
    c.values["pairs"] = len(diffs)
    lg = _cad(m).get("window16LoggedDisagreement")
    if lg is not None and lg > 1e-9:
        c.note(f"window differences from the logged elements differ from the recomputed ones by up to {lg:.3f}")


def ev_C_D2(m, b, c):
    fam = _cad(m).get("familyRunBars")
    if not fam:
        c.test("familyRunBars", None, None, "no cadence")
    elif fam["source"] == "plan":
        c.values["source"] = "plan log"
        c.test("longestFamilyRunBars", fam["longestBars"], fam["longestBars"] <= b["runBarsMax"])
    else:
        v = fam.get("minDifference")
        c.test("minDifference8Bars", v, None if v is None else v > 0, "needs two 8-bar windows with dialogue")


def ev_C_D3(m, b, c):
    cad = _cad(m)
    if "identicalConsecutiveBlocks" not in cad:
        c.test("identicalBlocks", None, None, "no cadence")
        return
    n = len(cad["identicalConsecutiveBlocks"])
    c.test("identicalConsecutiveBlocks", n, n == 0)
    fa = cad.get("fingerprintAgreement")
    if fa is not None:
        c.test("fingerprintDisagreements", len(fa["disagreements"]), len(fa["disagreements"]) == 0)
        c.values["blocksChecked"] = fa["blocksChecked"]
        for d in fa["disagreements"][:5]:
            c.note(f"phrase {d['phrase']}: " + "; ".join(d["reasons"]))


def ev_C_D4(m, b, c):
    cad = _cad(m)
    if cad.get("motif"):
        c.test("rests", None, None, "not applicable in motif mode: the user direction of 19 November 2026 puts a piece in every bar (C-D9 gates it)")
        return
    if "restsPer8Bars" not in cad:
        c.test("rests", None, None, "no cadence")
        return
    if cad["restsPer8Bars"]:
        low = min(r["emptyBars"] for r in cad["restsPer8Bars"])
        c.test("minEmptyBarsPer8", low, low >= b["emptyBarsMin"])
        occ = max(o["occupancy"] for o in cad["occupancyPer8Bars"])
        c.test("maxOccupancyPer8", occ, occ <= b["occupancyMax"])
    else:
        c.test("windows", None, None, "no complete 8-bar window with dialogue")
    last = [x.get("sounding", x["events"]) for x in cad["eventsLastTwoBeats"]]
    c.test("dryAudioInLastTwoBeats", sum(last), sum(last) == 0)


def ev_C_D5(m, b, c):
    cad = _cad(m)
    v = cad.get("dryOverlaps")
    c.test("dryOverlaps", v, None if v is None else v == 0)


def ev_C_D6(m, b, c):
    st = _cad(m).get("stageTiming")
    if not st:
        c.test("stageTiming", None, None, "no dialogueTimings")
    else:
        c.test("totalMsP95", st["totalMsP95"], st["totalMsP95"] <= b["totalMsP95Max"])
        c.test("totalMsMax", st["totalMsMax"], st["totalMsMax"] <= b["totalMsMax"])
        c.values["cues"] = st["count"]
    lead = _cad(m).get("leadSecondsMin")
    c.test("leadSecondsMin", lead, None if lead is None else lead >= b["leadSecondsMin"], "no committedFrame in chops")


def ev_C_D7(m, b, c):
    cad = _cad(m)
    h = cad.get("hookSamePad")
    if cad.get("plan") and not h:
        c.test("hookSamePadFraction", None, None, "no echo-family block (no repeated hook statement) in this capture")
        return
    c.test("hookSamePadFraction", None if not h else float(np.mean(h)), None if not h else all(h), "no padID in chops")
    if h:
        c.values["hooks"] = len(h)


def ev_C_D8(m, b, c):
    cad = _cad(m)
    v = cad.get("accentsAtLeast50msFraction")
    few = cad.get("accents") is not None and cad["accents"] < 5
    c.test("accentsAtLeast50msFraction", v, None if (v is None or few) else v >= b["fractionMin"],
           f"only {cad.get('accents')} stressed accents" if few else "no stressed accentFrame in chops, or no kick landmarks")
    if cad.get("accents") is not None:
        c.values["accents"] = cad["accents"]


def ev_C_D9(m, b, c):
    mo = _cad(m).get("motif")
    if not mo or not mo["loops"]:
        c.test("motifLoops", None, None, "no motif plan log or no complete 16-bar loop")
        return
    loops = mo["loops"]
    empty = sum(len(x["emptyBars"]) for x in loops)
    c.test("emptyBars", empty, empty <= b["emptyBarsMax"])
    full = max(x["fullLine"] for x in loops)
    c.test("maxFullLinePer16", full, full <= b["fullLineMax"])
    shares = [x["subLineShare"] for x in loops if x["subLineShare"] is not None]
    c.test("minSubLineShare", min(shares) if shares else None, None if not shares else min(shares) >= b["subLineShareMin"])
    missing = [x["loop"] for x in loops if not set(b["cellsEveryLoop"]) <= set(x["cells"])]
    c.test("loopsMissingCells", len(missing), not missing)
    occ = [x["occupancy"] for x in loops]
    c.test("minOccupancy", min(occ), min(occ) >= b["occupancy"][0])
    c.test("maxOccupancy", max(occ), max(occ) <= b["occupancy"][1])
    c.values["loops"] = len(loops)
    for x in loops:
        c.note(f"loop {x['loop'] + 1}: onsets per bar {x['onsetsPerBar']}, full line {x['fullLine']}, "
               f"sub-line {fmt(x['subLineShare'])}, occupancy {fmt(x['occupancy'])}, cells {', '.join(x['cells'])}")


EVALUATORS = {k[3:].replace("_", "-"): v for k, v in globals().items() if k.startswith("ev_C_")}
EVALUATORS = {"C-" + k[2:] if not k.startswith("C-") else k: v for k, v in EVALUATORS.items()}


def load_criteria(path):
    return json.loads(Path(path).read_text())["criteria"]


def evaluate(metrics, cap, criteria):
    results = []
    has_dialogue = bool(cap.chops()) or cap.has_section("dialogue") and bool(cap.chop_intervals())
    for crit in criteria:
        entry = {"id": crit["id"], "description": crit["description"], "level": crit["level"]}
        cases = crit.get("cases", "*")
        if cases != "*" and cap.case not in cases:
            entry.update(status="skipped", reason=f"not applicable to case {cap.case}")
            results.append(entry)
            continue
        requires = crit.get("requires", [])
        if "footage" in requires and not cap.has_footage:
            entry.update(status="skipped", reason="no footage")
        elif "dialogue" in requires and not has_dialogue:
            entry.update(status="skipped", reason="no dialogue")
        else:
            bounds = {**crit.get("bounds", {}), **(crit.get("boundsByCase", {}).get(cap.case) or {})}
            check = Check()
            fn = EVALUATORS.get(crit["id"])
            try:
                if fn is None:
                    raise KeyError("no evaluator")
                fn(metrics, bounds, check)
                entry.update(check.result())
            except Exception as exc:
                entry.update(status="skipped", reason=f"{type(exc).__name__}: {exc}", values=check.values)
        if entry["status"] == "fail" and entry["level"] == "warn":
            entry["status"] = "warn"
        results.append(entry)
    return results


def summarize(results):
    counts = {"pass": 0, "fail": 0, "warn": 0, "skipped": 0}
    for r in results:
        counts[r["status"]] += 1
    strict_failures = [r["id"] for r in results if r["level"] == "fail" and (
        r["status"] == "fail" or (r["status"] == "skipped" and r.get("reason") not in SKIP_OK
                                  and "not applicable" not in str(r.get("reason", ""))))]
    return {"counts": counts, "strictFailures": strict_failures}


# ---------------------------------------------------------------------------------- writing

def _clean(o):
    if isinstance(o, dict):
        return {k: _clean(v) for k, v in o.items() if not k.startswith("_") or k == "_seconds"}
    if isinstance(o, (list, tuple)):
        return [_clean(v) for v in o]
    if isinstance(o, np.ndarray):
        return _clean(o.tolist())
    if isinstance(o, (np.floating, float)):
        v = float(o)
        return round(v, 4) if math.isfinite(v) else None
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    return o


def scalar_values(results):
    out = {}
    for r in results:
        for k, v in (r.get("values") or {}).items():
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                out[f"{r['id']}.{k}"] = float(v)
    return out


def write_report(outdir, cap, metrics, results, baseline=None, criteria=None, auditions=None):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    summary = summarize(results)
    doc = {"schema": SCHEMA, "capture": str(cap.path), "case": cap.case, "captureSchema": cap.schema,
           "gitRevision": cap.manifest.get("gitRevision"), "summary": summary,
           "criteria": _clean(results), "metrics": _clean(metrics)}
    if auditions is not None:
        doc["auditions"] = _clean(auditions)
    (outdir / "mix-report.json").write_text(json.dumps(doc, indent=1, allow_nan=False) + "\n")
    (outdir / "mix-report.md").write_text(markdown(doc, baseline, criteria))
    return doc


def fmt(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        return f"{v:.2f}" if abs(v) < 1e5 else f"{v:.3g}"
    return str(v)


STATUS_ORDER = {"fail": 0, "warn": 1, "skipped": 2, "pass": 3}

MEASUREMENT = {
    "C-M1": "BS.1770-4 integrated loudness of master.wav (M1, cross-checked with ffmpeg ebur128)",
    "C-M2": "true peak by ffmpeg ebur128 and by an independent 16x reconstruction (M2)",
    "C-M3": "true peak minus integrated loudness (PLR, M3)",
    "C-M4": "short-term loudness maximum and true peak minus that maximum (PSR, M3)",
    "C-M5": "sample peak minus RMS of the master (crest factor, M3)",
    "C-M6": "limiter gain reduction from the engine trace master-gr.csv, cross-checked against a trace inferred from pre-master and master (M4)",
    "C-M7": "glue compressor gain reduction from master-gr.csv (M4)",
    "C-M8": "RMS of the master gain trace in the 0.5 to 8 Hz band and its dip 20 to 80 ms after kick landmarks (M5)",
    "C-M9": "fraction of samples on which the soft clipper engaged, from the engine meters (M4)",
    "C-M10": "L/R correlation below 120 Hz and full band, and mono fold-down loudness loss (M9)",
    "C-M11": "master energy below 25 Hz against the total (Welch estimate) and the 250 Hz to 8 kHz spectral tilt (M7)",
    "C-M12": "loudness range of the master (M1)",
    "C-B1": "per-section energy in 20 to 120 Hz against the louder of drums and bass (M8)",
    "C-B2": "bass attack against the aligned kick attack (diagnostics.bass), the 40 to 120 Hz kick plus bass sum, and the bass duck depth under kicks (M10)",
    "C-B3": "bass against drums in 60 to 250 Hz, and bass harmonics against its fundamental (M8)",
    "C-B4": "drum bus crest and peak, and kick attack time against the unprocessed take (M3, stemChains)",
    "C-B5": "mids against lead in 400 Hz to 3 kHz when both play and in lead rests, and mid articulation count (M13)",
    "C-B6": "lead salience over the first two return notes, theme to return onset correlation, and the program of each (M14)",
    "C-B7": "lead minus space level in lead-active phrases (M13)",
    "C-B8": "octave-band SNR of the dialogue against every other section during chops, as the SII proxy and 1 to 4 kHz SNR (M11)",
    "C-B9": "bed direct to wet ratio, bed audibility in the gaps between chops, bed against dialogue in 1 to 4 kHz, and bed 85 percent roll-off (M12)",
    "C-B10": "stem sums against the Lo-Fi bus and the pre-master (M16)",
    "C-D1": "difference between consecutive 16-bar windows of position-tagged (padKey, slot) elements, recomputed from the scheduled events (M15)",
    "C-D2": "longest run of bars with the same family and bank in the plan log (M15)",
    "C-D3": "consecutive identical blocks, and agreement of logged and recomputed fingerprints (M15)",
    "C-D4": "empty bars per 8, dry audio in the last two beats before an 8-bar boundary, and occupancy (M15)",
    "C-D5": "overlap between scheduled dry events (M15)",
    "C-D6": "per-cue stage timings and the lead of each event ahead of its commit (M15)",
    "C-D7": "pad and transform of the two statements of each echo hook (M15)",
    "C-D8": "distance of stressed accents from confident kick landmarks (M15)",
    "C-D9": "motif mode: piece onsets in every bar of each 16-bar loop, full-line statements, sub-line share, cells and occupancy (M15)",
}

# Sections whose energy decides a criterion, and the bands to rank them in (indices into BAND_NAMES).
DRIVER_BANDS = {
    "C-B1": (0, 2, ("mids", "lead", "space", "dialogue", "bed")), "C-B8": (5, 6, ("dialogue",)),
    "C-B9": (5, 6, ("bed",)), "C-B5": (4, 6, ("mids", "lead")), "C-B6": (4, 6, ("lead",)), "C-B7": (4, 6, ("lead", "space")),
    "C-B3": (1, 2, ("bass", "drums")), "C-B2": (1, 1, ("bass", "drums")), "C-B4": (0, 8, ("drums",)),
}
RIVAL_STYLE = ("C-B8", "C-B9", "C-B6", "C-B7", "C-B5")
MASTER_DRIVERS = ("C-M1", "C-M2", "C-M3", "C-M4", "C-M5", "C-M6", "C-M7", "C-M8", "C-M9", "C-M11", "C-M12")


def _bound_text(bounds):
    parts = []
    for k, v in bounds.items():
        if isinstance(v, (list, tuple)):
            lo, hi = v
            parts.append(f"{k} {fmt(lo)} to {fmt(hi)}")
        elif k.endswith("Max"):
            parts.append(f"{k[:-3]} <= {fmt(v)}")
        elif k.endswith("Min"):
            parts.append(f"{k[:-3]} >= {fmt(v)}")
        else:
            parts.append(f"{k} {fmt(v)}")
    return "; ".join(parts) if parts else "-"


def _criteria_bounds(criteria, case):
    out = {}
    for c in criteria or []:
        out[c["id"]] = {**c.get("bounds", {}), **(c.get("boundsByCase", {}).get(case) or {})}
    return out


def _headline_values(r, limit=4):
    vals = r.get("values") or {}
    failed = list(r.get("failedChecks", []))
    keys = [k for k in vals if k in failed] + [k for k in vals if k not in failed]
    shown = []
    for k in keys:
        v = vals[k]
        if v is None or (isinstance(v, str) and k not in failed):
            continue
        shown.append((k, v))
        if len(shown) >= limit:
            break
    return shown


def verdict_rows(doc, baseline, criteria):
    """Rows sorted failures first: (id, level, values text, bounds text, baseline text, status)."""
    bounds = _criteria_bounds(criteria, doc["case"])
    base = {r["id"]: r for r in (baseline or {}).get("criteria", [])}
    rows = []
    for r in doc["criteria"]:
        shown = _headline_values(r)
        keys = [k for k, _ in shown]
        b = base.get(r["id"], {})
        bvals = b.get("values") or {}
        btext = ", ".join(f"{k}={fmt(bvals[k])}" for k in keys if k in bvals)
        if not btext:
            btext = f"({b.get('status', '-')})" if b else "-"
        rows.append((r["id"], r["level"], ", ".join(f"{k}={fmt(v)}" for k, v in shown) or (r.get("reason") or "-"),
                     _bound_text(bounds.get(r["id"], {})), btext, r["status"]))
    order = {r["id"]: i for i, r in enumerate(doc["criteria"])}
    rows.sort(key=lambda x: (STATUS_ORDER[x[5]], 0 if x[1] == "fail" else 1, order[x[0]]))
    return rows


def _db_sum(values):
    return float(10 * np.log10(sum(10 ** (v / 10) for v in values) + 1e-20))


def _drivers(m, cid):
    energy = m.get("bandEnergyDb") or {}
    if cid in DRIVER_BANDS and energy:
        lo, hi, owners = DRIVER_BANDS[cid]
        level = {s: _db_sum(v[lo:hi + 1]) for s, v in energy.items()}
        if cid in RIVAL_STYLE:
            rivals = sorted(((s, v) for s, v in level.items() if s not in owners), key=lambda t: -t[1])[:2]
            text = ", ".join(f"{s} ({v:.1f} dB)" for s, v in rivals)
            own = ", ".join(f"{s} ({level[s]:.1f} dB)" for s in owners if s in level)
            return f"{own} against {text} in {BAND_NAMES[lo]} to {BAND_NAMES[hi]} Hz"
        top = sorted(level.items(), key=lambda t: -t[1])[:3]
        return "loudest in that range: " + ", ".join(f"{s} ({v:.1f} dB)" for s, v in top)
    if cid in MASTER_DRIVERS and energy:
        total = {s: _db_sum(v) for s, v in energy.items()}
        top = sorted(total.items(), key=lambda t: -t[1])[:3]
        return "loudest sections overall: " + ", ".join(f"{s} ({v:.1f} dB)" for s, v in top)
    return None


def failure_paragraphs(doc, baseline):
    base = {r["id"]: r for r in (baseline or {}).get("criteria", [])}
    out = []
    for r in sorted(doc["criteria"], key=lambda r: (STATUS_ORDER[r["status"]], 0 if r["level"] == "fail" else 1)):
        if r["status"] not in ("fail", "warn"):
            continue
        shown = ", ".join(f"{k} = {fmt(r['values'][k])}" for k in r.get("failedChecks", []) if k in (r.get("values") or {}))
        drv = _drivers(doc["metrics"], r["id"])
        b = base.get(r["id"])
        text = (f"**{r['id']}** ({r['level']}-level, {r['status']}). {r['description']}. Measured: "
                f"{MEASUREMENT.get(r['id'], 'see the criteria table')}. Out of bounds: {shown or 'see values'}.")
        if drv:
            text += f" Stems driving it: {drv}."
        if b:
            text += f" Baseline: {b['status']}."
        for note in r.get("notes", []):
            text += f" Note: {note}."
        out.append(text)
    return out


def markdown(doc, baseline=None, criteria=None, auditions=None):
    m = doc["metrics"]
    s = doc["summary"]["counts"]
    auditions = auditions if auditions is not None else doc.get("auditions")
    lines = [f"# Mix report: {doc['case']}", "",
             f"Capture `{doc['capture']}` ({doc['captureSchema']}), revision `{doc.get('gitRevision')}`.", "",
             f"Criteria: {s['pass']} pass, {s['fail']} fail, {s['warn']} warn, {s['skipped']} skipped. "
             f"Strict failures: {', '.join(doc['summary']['strictFailures']) or 'none'}.", "",
             "## Verdict", "",
             "Failures first. A `fail` status on a fail-level criterion gates `--strict`; a `warn` status is reported only.", "",
             "| Criterion | Level | Value | Bounds | Baseline value | Status |", "|---|---|---|---|---|---|"]
    for cid, level, val, bnd, bval, status in verdict_rows(doc, baseline, criteria):
        lines.append(f"| {cid} | {level} | {val} | {bnd} | {bval} | {status} |")
    paras = failure_paragraphs(doc, baseline)
    if paras:
        lines += ["", "### Why each criterion failed", ""] + [p + "\n" for p in paras]
    lines += ["", "## Headline", "",
              "| Measure | Value |", "|---|---|",
              f"| Integrated loudness | {fmt(g(m, 'loudness', 'integratedLufs'))} LUFS (ffmpeg {fmt(g(m, 'loudness', 'ffmpeg', 'integratedLufs'))}, diff {fmt(g(m, 'loudness', 'ffmpegDiffLu'))} LU) |",
              f"| True peak | {fmt(g(m, 'truePeak', 'ffmpegDbtp'))} dBTP (reconstruction {fmt(g(m, 'truePeak', 'reconstructionDbtp'))}) |",
              f"| PLR / PSR | {fmt(g(m, 'crest', 'plrDb'))} / {fmt(g(m, 'crest', 'psrDb'))} dB |",
              f"| Master crest | {fmt(g(m, 'crest', 'master', 'crestDb'))} dB |",
              f"| Short-term max / LRA | {fmt(g(m, 'loudness', 'shortTermMaxLufs'))} LUFS / {fmt(g(m, 'loudness', 'lraLu'))} LU |",
              f"| Pumping index / kick dip | {fmt(g(m, 'dynamics', 'pumpingIndexDb'))} / {fmt(g(m, 'dynamics', 'kickDipDb'))} dB ({g(m, 'dynamics', 'pumpingSource')}) |",
              f"| Master correlation below 120 Hz / full band | {fmt(g(m, 'lowbandMono', 'below120Correlation'))} / {fmt(g(m, 'lowbandMono', 'fullBandCorrelation'))} |",
              f"| Mono fold loss | {fmt(g(m, 'lowbandMono', 'monoLossLu'))} LU |",
              f"| Tilt 250 Hz to 8 kHz | {fmt(g(m, 'spectrum', 'signals', 'master', 'tiltDbPerOctave'))} dB/oct |",
              f"| Engine diagnostics found | {', '.join(m.get('engineDiagnostics') or []) or 'none'}; taps: {', '.join(m.get('taps') or []) or 'none'} |",
              "", "## Criteria detail", "", "| Id | Level | Status | Values | Notes |", "|---|---|---|---|---|"]
    base = {}
    if baseline:
        base = {r["id"]: r for r in baseline.get("criteria", [])}
    for r in doc["criteria"]:
        vals = ", ".join(f"{k}={fmt(v)}" for k, v in (r.get("values") or {}).items())
        note = r.get("reason") or "; ".join((r.get("failedChecks") and ["failed: " + ", ".join(r["failedChecks"])] or [])
                                            + (r.get("skippedChecks") or []) + (r.get("notes") or []))
        lines.append(f"| {r['id']} | {r['level']} | {r['status']} | {vals} | {note} |")
    if baseline:
        lines += ["", "## Against baseline", "", "| Id | Value | Baseline | Candidate | Delta |", "|---|---|---|---|---|"]
        for r in doc["criteria"]:
            b = base.get(r["id"], {})
            for k, v in (r.get("values") or {}).items():
                bv = (b.get("values") or {}).get(k)
                if isinstance(v, (int, float)) and isinstance(bv, (int, float)) and not isinstance(v, bool):
                    lines.append(f"| {r['id']} | {k} | {fmt(bv)} | {fmt(v)} | {fmt(v - bv)} |")
    if auditions:
        from .auditions import auditions_markdown
        lines += [""] + auditions_markdown(auditions).rstrip("\n").split("\n")
    lines += ["", "## Notes", "",
              "Power sums assume uncorrelated sections. Band edges 20-60, 60-120, 120-250, 250-500, 500-1k, 1-2k, 2-4k, 4-8k, 8-16k Hz. "
              "A skipped sub-check is listed in Notes and does not fail a criterion."]
    return "\n".join(lines) + "\n"


def _esc(x):
    import html
    return html.escape(str(x))


def write_html(outdir, doc, baseline=None, criteria=None):
    """Static report/index.html: verdict table, per-criterion detail, auditions and every PNG, no external assets."""
    import re
    outdir = Path(outdir)
    s = doc["summary"]["counts"]
    rows = verdict_rows(doc, baseline, criteria)
    css = ("body{font:14px/1.45 -apple-system,Helvetica,Arial,sans-serif;margin:24px;max-width:1280px;background:#fff;color:#1b1b1b}"
           "table{border-collapse:collapse;margin:12px 0;width:100%}th,td{border:1px solid #d0d0d0;padding:4px 8px;text-align:left;vertical-align:top}"
           "th{background:#f0f0f0}.fail{background:#fde2e2}.warn{background:#fff3cd}.skipped{background:#eceff3;color:#555}.pass{background:#e3f4e3}"
           "img{max-width:100%;border:1px solid #ddd;margin:6px 0}h1,h2{margin-top:28px}code{font-size:12px}"
           "@media (prefers-color-scheme:dark){body{background:#16181c;color:#e6e6e6}th{background:#262a30}th,td{border-color:#444}"
           ".fail{background:#5a2323}.warn{background:#5a4b1c}.skipped{background:#2a2e35;color:#aaa}.pass{background:#1f4023}img{border-color:#444}}")
    parts = [f"<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
             f"<title>Mix report {_esc(doc['case'])}</title><style>{css}</style></head><body>",
             f"<h1>Mix report: {_esc(doc['case'])}</h1>",
             f"<p>Capture <code>{_esc(doc['capture'])}</code> ({_esc(doc['captureSchema'])}), revision <code>{_esc(doc.get('gitRevision'))}</code>.<br>"
             f"{s['pass']} pass, {s['fail']} fail, {s['warn']} warn, {s['skipped']} skipped. "
             f"Strict failures: {_esc(', '.join(doc['summary']['strictFailures']) or 'none')}.</p>",
             "<h2>Verdict</h2><table><tr><th>Criterion</th><th>Level</th><th>Value</th><th>Bounds</th><th>Baseline value</th><th>Status</th></tr>"]
    for cid, level, val, bnd, bval, status in rows:
        parts.append(f"<tr class='{status}'><td>{_esc(cid)}</td><td>{level}</td><td>{_esc(val)}</td><td>{_esc(bnd)}</td>"
                     f"<td>{_esc(bval)}</td><td>{status}</td></tr>")
    parts.append("</table>")
    paras = failure_paragraphs(doc, baseline)
    if paras:
        parts.append("<h2>Why each criterion failed</h2>")
        for p in paras:
            parts.append("<p>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", _esc(p)) + "</p>")
    if doc.get("auditions"):
        parts.append("<h2>Auditions</h2><table><tr><th>File</th><th>LUFS</th><th>dBTP</th><th>What to listen for</th></tr>")
        for e in doc["auditions"]:
            if e.get("file"):
                parts.append(f"<tr><td><a href='auditions/{_esc(e['file'])}'>{_esc(e['file'])}</a><br><audio controls preload='none' "
                             f"src='auditions/{_esc(e['file'])}'></audio></td><td>{e['lufs']:.2f}</td><td>{e['truePeakDbtp']:.2f}</td>"
                             f"<td>{_esc(e['title'])}. {_esc(e['listen'])}</td></tr>")
            else:
                parts.append(f"<tr class='skipped'><td>{_esc(e['title'])}</td><td colspan='3'>skipped: {_esc(e.get('skipped', ''))}</td></tr>")
        parts.append("</table>")
    parts.append("<h2>Criteria detail</h2><table><tr><th>Id</th><th>Status</th><th>Values</th><th>Notes</th></tr>")
    for r in doc["criteria"]:
        vals = ", ".join(f"{k}={fmt(v)}" for k, v in (r.get("values") or {}).items())
        note = r.get("reason") or "; ".join((r.get("skippedChecks") or []) + (r.get("notes") or []))
        parts.append(f"<tr class='{r['status']}'><td>{_esc(r['id'])}</td><td>{r['status']}</td><td>{_esc(vals)}</td><td>{_esc(note)}</td></tr>")
    parts.append("</table><h2>Figures</h2>")
    for png in sorted(outdir.glob("*.png")):
        parts.append(f"<h3>{_esc(png.stem)}</h3><img src='{_esc(png.name)}' alt='{_esc(png.stem)}' loading='lazy'>")
    parts.append("</body></html>")
    (outdir / "index.html").write_text("\n".join(parts))


def matrix_summary(out, cases, baseline=None, criteria=None):
    """Write OUT/matrix-summary.md and .json from OUT/<case>/report/mix-report.json. Returns (markdown, strict_failed)."""
    out = Path(out)
    docs, base_docs = {}, {}
    for case in cases:
        path = out / case / "report" / "mix-report.json"
        docs[case] = json.loads(path.read_text()) if path.is_file() else None
        if baseline:
            bpath = Path(baseline) / case / "report" / "mix-report.json"
            base_docs[case] = json.loads(bpath.read_text()) if bpath.is_file() else None
    ids, levels = [], {}
    for doc in docs.values():
        for r in (doc or {}).get("criteria", []):
            if r["id"] not in ids:
                ids.append(r["id"])
            levels[r["id"]] = r["level"]
    by_case = {c: {r["id"]: r for r in d["criteria"]} if d else {} for c, d in docs.items()}
    totals = {c: (d["summary"]["counts"] if d else None) for c, d in docs.items()}
    strict = {c: (d["summary"]["strictFailures"] if d else ["no report"]) for c, d in docs.items()}

    lines = ["# Mix matrix summary", "",
             f"Cases: {', '.join(cases)}. Baseline: {baseline or 'none'}.", "",
             "## Counts", "", "| Case | pass | warn | fail | skipped | strict failures |", "|---|---|---|---|---|---|"]
    grand = {"pass": 0, "warn": 0, "fail": 0, "skipped": 0}
    for c in cases:
        t = totals[c]
        if t:
            for k in grand:
                grand[k] += t[k]
            lines.append(f"| {c} | {t['pass']} | {t['warn']} | {t['fail']} | {t['skipped']} | {', '.join(strict[c]) or 'none'} |")
        else:
            lines.append(f"| {c} | - | - | - | - | no report |")
    lines.append(f"| **total** | {grand['pass']} | {grand['warn']} | {grand['fail']} | {grand['skipped']} | |")

    lines += ["", "## Criteria by case", "",
              "| Criterion | Level | " + " | ".join(cases) + " |", "|---|---|" + "---|" * len(cases)]
    for cid in ids:
        row = []
        for c in cases:
            r = by_case[c].get(cid)
            row.append("-" if r is None else r["status"])
        lines.append(f"| {cid} | {levels[cid]} | " + " | ".join(row) + " |")

    lines += ["", "## Failing fail-level criteria (the wave 4 to-do list)", ""]
    for c in cases:
        fails = [cid for cid in ids if by_case[c].get(cid, {}).get("status") == "fail" and levels[cid] == "fail"]
        lines.append(f"- {c}: {'no report (the capture failed or was not run)' if docs[c] is None else ', '.join(fails) or 'none'}")
    lines += ["", "Warn-level criteria that warn:", ""]
    for c in cases:
        warns = [cid for cid in ids if by_case[c].get(cid, {}).get("status") == "warn"]
        lines.append(f"- {c}: {'no report' if docs[c] is None else ', '.join(warns) or 'none'}")

    if baseline:
        lines += ["", "## Against baseline", "",
                  "Headline value of each criterion: the first failed check, else the first numeric value.", "",
                  "| Case | Criterion | Value | Baseline | Candidate | Delta | Baseline status | Status |", "|---|---|---|---|---|---|---|---|"]
        for c in cases:
            bd = {r["id"]: r for r in (base_docs.get(c) or {}).get("criteria", [])}
            for cid in ids:
                r, b = by_case[c].get(cid), bd.get(cid)
                if r is None or b is None:
                    continue
                vals = r.get("values") or {}
                keys = [k for k in r.get("failedChecks", []) if isinstance(vals.get(k), (int, float))]
                keys += [k for k, v in vals.items() if isinstance(v, (int, float)) and not isinstance(v, bool) and k not in keys]
                for k in keys[:1]:
                    bv = (b.get("values") or {}).get(k)
                    if isinstance(bv, (int, float)):
                        lines.append(f"| {c} | {cid} | {k} | {fmt(bv)} | {fmt(vals[k])} | {fmt(vals[k] - bv)} | {b['status']} | {r['status']} |")
                    else:
                        lines.append(f"| {c} | {cid} | {k} | - | {fmt(vals[k])} | - | {b['status']} | {r['status']} |")
    md = "\n".join(lines) + "\n"
    (out / "matrix-summary.md").write_text(md)
    (out / "matrix-summary.json").write_text(json.dumps({
        "cases": cases, "totals": totals, "strictFailures": strict,
        "grid": {c: {cid: r["status"] for cid, r in by_case[c].items()} for c in cases},
        "values": {c: {cid: r.get("values", {}) for cid, r in by_case[c].items()} for c in cases}}, indent=1) + "\n")
    return md, any(strict[c] for c in cases)


def print_comparison(doc, baseline):
    base = {r["id"]: r for r in baseline.get("criteria", [])}
    print(f"{'criterion value':44s} {'baseline':>12s} {'candidate':>12s} {'delta':>10s}")
    for r in doc["criteria"]:
        b = base.get(r["id"], {})
        print(f"{r['id']:6s} {r['status']:8s} (baseline {b.get('status', '-')})")
        for k, v in (r.get("values") or {}).items():
            bv = (b.get("values") or {}).get(k)
            if isinstance(v, (int, float)) and isinstance(bv, (int, float)) and not isinstance(v, bool):
                print(f"   {k:41s} {bv:12.3f} {v:12.3f} {v - bv:10.3f}")
            elif v is not None or bv is not None:
                print(f"   {k:41s} {fmt(bv):>12s} {fmt(v):>12s}")
