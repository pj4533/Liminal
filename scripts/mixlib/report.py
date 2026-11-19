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
    metrics["masterBelow25HzDbUnderTotal"] = float(db10(total) - db10(max(below25, 1e-20)))

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
        self.values, self.fails, self.skipped, self.passed = {}, [], [], 0

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
            return {"status": "skipped", "reason": "; ".join(self.skipped) or "no inputs", "values": self.values}
        out = {"status": "fail" if self.fails else "pass", "values": self.values}
        if self.fails:
            out["failedChecks"] = self.fails
        if self.skipped:
            out["skippedChecks"] = self.skipped
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
    v = g(m, "dynamics", "engine", "clip", "engagedFraction")
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
    for key, bound, op in (("lagMsMedian", "lagMsMedianMax", "max"), ("lagMsP90", "lagMsP90Max", "max")):
        v = kb.get(key)
        c.test(key, v, None if v is None else v <= b[bound], kb.get("lagSkipped", "no diagnostics.bass"))
    v = kb.get("sumVsLouderDbMedian")
    c.test("sumVsLouderDbMedian", v, None if v is None else v >= b["sumMedianDbMin"])
    v = kb.get("sumVsLouderDbWorst")
    c.test("sumVsLouderDbWorst", v, None if v is None else v >= b["sumWorstDbMin"])
    v = kb.get("duckDepthDbMedian")
    c.test("duckDepthDbMedian", v, _in(v, b["duckDepthDb"]))


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
    c.skipped.append("kickAttackRatio: needs diagnostics.landmarks of the unprocessed take")


def ev_C_B5(m, b, c):
    ml = m.get("midsLead") or {}
    if ml.get("skipped"):
        c.test("midsLead", None, None, ml["skipped"])
        return
    v = g(ml, "bothPlay", "leadMinusMidsDb")
    c.test("leadMinusMidsDb", v, _in(v, b["leadMinusMidsDb"]))
    r = g(ml, "leadRestMidsPlay", "leadMinusMidsDb")
    c.test("midsOverLeadInRestsDb", None if r is None else -r, None if r is None else -r >= b["midsOverLeadInRestsDbMin"])
    arts = ml.get("articulationsPer16Bars")
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
    c.test("siiP10", d.get("siiP10"), d["siiP10"] >= b["siiP10Min"])
    c.test("snr1to4kMeanDb", d.get("snr1to4kMeanDb"), d["snr1to4kMeanDb"] >= b["snr1to4kMeanDbMin"])
    s = d.get("loudnessSpreadLu")
    c.test("loudnessSpreadLu", s, None if s is None else s <= b["loudnessSpreadLuMax"])


def ev_C_B9(m, b, c):
    bed = m.get("bed") or {}
    if bed.get("skipped"):
        c.test("bed", None, None, bed["skipped"])
        return
    v = bed.get("directToWetDb")
    c.test("directToWetDb", v, None if v is None else v >= b["directToWetDbMin"], bed.get("directToWetSkipped"))
    v = bed.get("audibilityIndex")
    c.test("audibilityIndex", v, _in(v, b["audibilityIndex"]), bed.get("gapsSkipped"))
    v = bed.get("dialogueOverBed1to4kDb")
    c.test("dialogueOverBed1to4kDb", v, None if v is None else v >= b["dialogueOverBedDbMin"])
    v = bed.get("rolloff85Hz")
    c.test("rolloff85Hz", v, None if v is None else v >= b["rolloffHzMin"])


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
        c.test("pairs", None, None, "fewer than two 16-bar windows with dialogue")
        return
    low = min(d["difference"] for d in diffs)
    c.test("minDifference", low, low >= b["differenceMin"])


def ev_C_D2(m, b, c):
    fam = _cad(m).get("familyRunBars")
    if not fam:
        c.test("familyRunBars", None, None, "no cadence")
    elif fam["source"] == "plan":
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


def ev_C_D4(m, b, c):
    cad = _cad(m)
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
    last = [x["events"] for x in cad["eventsLastTwoBeats"]]
    c.test("eventsInLastTwoBeats", sum(last), sum(last) == 0)


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
    lead = _cad(m).get("leadSecondsMin")
    c.test("leadSecondsMin", lead, None if lead is None else lead >= b["leadSecondsMin"], "no committedFrame in chops")


def ev_C_D7(m, b, c):
    h = _cad(m).get("hookSamePad")
    c.test("hookSamePadFraction", None if not h else float(np.mean(h)), None if not h else all(h), "no padID in chops")


def ev_C_D8(m, b, c):
    v = _cad(m).get("accentsAtLeast50msFraction")
    c.test("accentsAtLeast50msFraction", v, None if v is None else v >= b["fractionMin"], "no accentFrame in chops")


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
                                  and not str(r.get("reason", "")).startswith("not applicable")))]
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


def write_report(outdir, cap, metrics, results, baseline=None):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    summary = summarize(results)
    doc = {"schema": SCHEMA, "capture": str(cap.path), "case": cap.case, "captureSchema": cap.schema,
           "gitRevision": cap.manifest.get("gitRevision"), "summary": summary,
           "criteria": _clean(results), "metrics": _clean(metrics)}
    (outdir / "mix-report.json").write_text(json.dumps(doc, indent=1, allow_nan=False) + "\n")
    (outdir / "mix-report.md").write_text(markdown(doc, baseline))
    return doc


def fmt(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        return f"{v:.2f}" if abs(v) < 1e5 else f"{v:.3g}"
    return str(v)


def markdown(doc, baseline=None):
    m = doc["metrics"]
    s = doc["summary"]["counts"]
    lines = [f"# Mix report: {doc['case']}", "",
             f"Capture `{doc['capture']}` ({doc['captureSchema']}), revision `{doc.get('gitRevision')}`.", "",
             f"Criteria: {s['pass']} pass, {s['fail']} fail, {s['warn']} warn, {s['skipped']} skipped. "
             f"Strict failures: {', '.join(doc['summary']['strictFailures']) or 'none'}.", "",
             "## Headline", "",
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
             "", "## Criteria", "", "| Id | Level | Status | Values | Notes |", "|---|---|---|---|---|"]
    base = {}
    if baseline:
        base = {r["id"]: r for r in baseline.get("criteria", [])}
    for r in doc["criteria"]:
        vals = ", ".join(f"{k}={fmt(v)}" for k, v in (r.get("values") or {}).items())
        note = r.get("reason") or "; ".join((r.get("failedChecks") and ["failed: " + ", ".join(r["failedChecks"])] or [])
                                            + (r.get("skippedChecks") or []))
        lines.append(f"| {r['id']} | {r['level']} | {r['status']} | {vals} | {note} |")
    if baseline:
        lines += ["", "## Against baseline", "", "| Id | Value | Baseline | Candidate | Delta |", "|---|---|---|---|---|"]
        for r in doc["criteria"]:
            b = base.get(r["id"], {})
            for k, v in (r.get("values") or {}).items():
                bv = (b.get("values") or {}).get(k)
                if isinstance(v, (int, float)) and isinstance(bv, (int, float)) and not isinstance(v, bool):
                    lines.append(f"| {r['id']} | {k} | {fmt(bv)} | {fmt(v)} | {fmt(v - bv)} |")
    lines += ["", "## Notes", "",
              "Power sums assume uncorrelated sections. Band edges 20-60, 60-120, 120-250, 250-500, 500-1k, 1-2k, 2-4k, 4-8k, 8-16k Hz. "
              "A skipped sub-check is listed in Notes and does not fail a criterion."]
    return "\n".join(lines) + "\n"


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
