#!/usr/bin/env python3
"""Bass translation report: does the bass line survive a mono fold and a band limit, in the mix?

  python3 scripts/translation-report.py CAPTURE [CAPTURE ...] [--baseline CAPTURE ...] [--out DIR]
                                        [--auditions DIR] [--excerpt BAR:BARS] [--force]
  python3 scripts/translation-report.py --pair BASE CAND --auditions DIR [--excerpt BAR:BARS]
  python3 scripts/translation-report.py --self-test

Reads check-lofi.sh / mix-report.sh captures (never captures, never takes the lock). For each capture it
writes CAPTURE/translation/translation.json and translation.md (reused on the next run unless --force or the
tool version changed). With several captures it also pools their notes (summary and diagnosis over all of
them) into --out (default: the first capture's translation folder) as pooled.json / pooled.md. --baseline
gives one baseline capture per capture, in the same order (or a directory holding captures named like the
candidates, e.g. a mix-matrix.sh output): the report then adds candidate-minus-baseline deltas per capture
and pooled.

Transforms, metrics and proxies are documented in scripts/mixlib/translation.py and docs/mix-verification.md
("Translation report"). Raw transformed files are never normalized; --pair listening files are matched by
one linear gain per capture (no limiter, no peak normalization) and every gain is printed and stored.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mixlib import translation as tr  # noqa: E402


def fmt(v, spec="+.1f", none="-"):
    if v is None:
        return none
    if isinstance(v, bool):
        return "yes" if v else "no"
    try:
        if not np.isfinite(v):
            return "-inf" if v < 0 else "inf"
    except TypeError:
        return str(v)
    return format(v, spec)


def pct(v):
    return "-" if v is None else f"{100 * v:.0f}%"


def load_or_analyze(cap, force=False):
    cap = Path(cap)
    out = cap / "translation" / "translation.json"
    if out.is_file() and not force:
        r = json.loads(out.read_text())
        if r.get("toolVersion") == tr.TOOL_VERSION and out.stat().st_mtime >= (cap / "manifest.json").stat().st_mtime:
            return r
    r = tr.analyze(cap)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(r, indent=1, default=_json_default))
    (out.parent / "translation.md").write_text(markdown(r))
    return r


def _json_default(o):
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    raise TypeError(type(o))


def summary_rows(summary, groups, kind="sustain"):
    lines = ["| group | notes | windows | surv 180 | margin 120 | margin 180 | p10 180 | margin 250 | ident 180 | solo 180 | pair re mix 180 | lift 180 | ident 250 | solo 250 |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for name, s in groups:
        k = s.get(kind, {})
        c120, c180, c250 = (k.get(str(c), {}) for c in (120, 180, 250))
        lines.append(f"| {name} | {s['notes']} | {k.get('windows', 0)} | {fmt(c180.get('survivalDbMedian'))} | "
                     f"{fmt(c120.get('cueMarginDbMedian'))} | {fmt(c180.get('cueMarginDbMedian'))} | {fmt(c180.get('cueMarginDbP10'))} | "
                     f"{fmt(c250.get('cueMarginDbMedian'))} | {pct(c180.get('identifiable'))} | {pct(c180.get('identifiableSolo'))} | {fmt(c180.get('bestPairDbReMixMedian'))} | {fmt(c180.get('liftToIdentifiableDbMedian'))} | "
                     f"{pct(c250.get('identifiable'))} | {pct(c250.get('identifiableSolo'))} |")
    return lines


def diagnosis_lines(d):
    s, b, m, e, o = d["stereo"], d["bandwidth"], d["masking"], d["envelope"], d["overload"]
    shares = ", ".join(f"{k} {100 * v:.0f}%" for k, v in list(m["maskerShareSustain"].items())[:4]) or "none"
    return [
        "| mode | met | evidence |", "|---|---|---|",
        f"| stereo cancellation | {fmt(s['met'])} | master 160-900 Hz mono change over bass notes, median {fmt(s['master160to900MedianDb'], '+.2f')} dB (rule < -1.5); "
        f"stems over 25 % of 180-1000 Hz losing > 3 dB: {', '.join(s['stemsOver25PctLosingOver3Db']) or 'none'}; bass L/R null max {fmt(s['bassLrNullMaxAbs'], '.1e')} |",
        f"| missing bandwidth | {fmt(b['met'])} | bass solo survival at HP180 sustain {fmt(b['sustainSurvivalDbMedian'])} dB (rule < -10), "
        f"identifiableSolo {pct(b['sustainIdentifiableSolo'])} (rule < 60 %); attack {fmt(b['attackSurvivalDbMedian'])} dB, {pct(b['attackIdentifiableSolo'])} |",
        f"| masking | {fmt(m['met'])} | identifiableSolo minus identifiable at HP180: sustain {fmt(m['sustainSoloMinusMixPoints'], '+.0f')} points "
        f"(rule >= 20), attack {fmt(m['attackSoloMinusMixPoints'], '+.0f')}; masked harmonics (sustain) by stem: {shares}; "
        f"targeted (one stem over half): {fmt(m['targeted'])} |",
        f"| envelope | {fmt(e['met'])} | attack minus sustain identifiable {fmt(e['attackMinusSustainPoints'], '+.0f')} points (rule >= 25); "
        f"per-pitch cue spread {fmt(e['pitchSpreadDb'], '.1f')} dB, per-tone {fmt(e['toneSpreadDb'], '.1f')} dB (rule > 6) |",
        f"| overload | {fmt(o['met'])} | notes with clip + limiter over 1 dB: {pct(o['notesOver1DbFraction'])} (rule > 5 %); "
        f"distortion gates failed: {o['distortionGatesFailed'] if o['distortionGatesFailed'] is not None else 'not given'} |",
    ]


def markdown(r):
    m = r["manifest"]
    L = [f"# Translation report: {Path(r['capture']).name}", "",
         f"seed {m['seed']}, {m['bpm']} BPM, {m['bars']} bars, footage {m['hasFootage']} ({', '.join(t for t in m['filmTitles'] if t) or 'none'}), "
         f"revision {str(m['gitRevision'])[:10]}, hooks {m['hooks'] or 'none'}, renderTuning {m['renderTuning']}, "
         f"master {m['masterDynamics']['profile']} ({m['masterDynamics']['calibration']}).", "",
         f"Bass tone per phrase: {' '.join(str(t) for t in m['bassTonePerPhrase'])}.", "",
         f"Delivered stems: latency {r['delivery']['latencyFrames']} frames, finisher gain {fmt(r['delivery']['finisherGainDb'], '+.2f')} dB, "
         f"sum residual {fmt(r['delivery']['sumResidualDb'], '.1f')} dB re master.", "",
         "## Master per transform", "",
         "| transform | LUFS | ST max | TP dBTP | crest | " + " | ".join(tr.BAND_NAMES) + " |",
         "|---|---|---|---|---|" + "---|" * len(tr.BAND_NAMES)]
    for t in tr.TRANSFORMS:
        lo, b = r["loudness"][t], r["bands"]["master"][t]
        L.append(f"| {t} | {fmt(lo['integratedLufs'])} | {fmt(lo['shortTermMaxLufs'])} | {fmt(lo['truePeakDbtp'], '+.2f')} | {fmt(lo['crestDb'], '.1f')} | "
                 + " | ".join(fmt(b[n]["rmsDb"]) for n in tr.BAND_NAMES) + " |")
    L += ["", "## Delivered stems, band RMS (stereo, dBFS; in bass notes in brackets)", "",
          "| stem | " + " | ".join(tr.BAND_NAMES) + " |", "|---|" + "---|" * len(tr.BAND_NAMES)]
    for k, v in r["bands"]["stems"].items():
        L.append(f"| {k} | " + " | ".join(f"{fmt(v['stereo'][n]['rmsDb'])} ({fmt(v['stereo'][n]['inBassNotesDb'])})" for n in tr.BAND_NAMES) + " |")
    L += ["", "## Mono fold over bass notes (median of per-note windows, dB; pooled energy in brackets)", "",
          "| signal | share 180-1k | " + " | ".join(tr.BAND_NAMES + tr.AUX_NAMES) + " |", "|---|---|" + "---|" * (len(tr.BAND_NAMES) + 2)]
    mono = r["monoChange"]
    for sig, bands in mono["bassNotes"].items():
        share = mono["share180to1000"].get(sig)
        L.append(f"| {sig} | {pct(share)} | " + " | ".join(
            f"{fmt(bands[n]['medianDb'], '+.2f')} ({fmt(bands[n]['pooledDb'], '+.2f')})" for n in tr.BAND_NAMES + tr.AUX_NAMES) + " |")
    if mono.get("chops", {}).get("master"):
        b = mono["chops"]["master"]
        L += ["", "Master over chop intervals: " + ", ".join(f"{n} {fmt(b[n]['medianDb'], '+.2f')}" for n in tr.BAND_NAMES)]
    s = r["summary"]
    L += ["", "## Note proxies, sustain (medians; ident = identifiable fraction)", ""]
    L += summary_rows(s, [("pooled", s["pooled"])] + list(s["toneRegister"].items()) + list(s["cells"].items()))
    L += ["", "## Note proxies, attack", ""]
    L += summary_rows(s, [("pooled", s["pooled"])] + list(s["toneRegister"].items()), "attack")
    sp = s["spread"]
    L += ["", f"Sustain cue level at HP180 per pitch: " + ", ".join(f"MIDI {k} {v:.1f}" for k, v in sp["perPitchMedianDb"].items())
          + f" (spread {fmt(sp['pitchSpreadDb'], '.1f')} dB); per tone: " + ", ".join(f"{k} {v:.1f}" for k, v in sp["perToneMedianDb"].items())
          + f" (spread {fmt(sp['toneSpreadDb'], '.1f')} dB).", "", "## Ten worst sustains at mono-hp180", "",
          "| bar | time s | MIDI | cell | margin dB | identifiable | maskers | chops | strums | program |", "|---|---|---|---|---|---|---|---|---|---|"]
    for w in s["worst"]:
        L.append(f"| {w['bar'] + 1} | {w['time']:.2f} | {w['midi']} | {w['cell']} | {w['cueMarginDb']:+.1f} | {fmt(w['identifiable'])} | "
                 f"{', '.join(sorted(set(w['maskers']))) or '-'} | {w['chops']} | {w['strums']} | {w['program']} |")
    d = r["dynamics"]
    if d.get("available"):
        i, o = d["insideBassNotes"] or {}, d["outsideBassNotes"] or {}
        L += ["", f"Master reduction inside bass notes: glue {fmt(i.get('glueMeanDb'), '.2f')}, clip {fmt(i.get('clipMeanDb'), '.3f')}, "
              f"limiter {fmt(i.get('limiterMeanDb'), '.3f')} dB mean (outside {fmt(o.get('glueMeanDb'), '.2f')}, {fmt(o.get('clipMeanDb'), '.3f')}, "
              f"{fmt(o.get('limiterMeanDb'), '.3f')}); notes with clip + limiter over 1 dB: {d['notesOver1Db']} ({pct(d['notesOver1DbFraction'])})."]
    g = r["integrity"]
    steps = g["boundarySteps"]
    L += ["", f"Integrity: all finite {fmt(g['allFinite'])} {g['nonFinite'] or ''}; bass DC max {fmt(g.get('bassDcMaxDbfs'), '.1f')} dBFS; "
          f"bass L/R null max {fmt(g.get('bassLrNullMaxAbs'), '.1e')}; boundary step max " + ", ".join(
              f"{k} {fmt(v['maxAtBoundary'], '.4f')} (p99.99 {fmt(v['p9999Elsewhere'], '.4f')})" for k, v in steps.items()) + "."]
    L += ["", "## Diagnosis (plan section 2, provisional project thresholds)", ""] + diagnosis_lines(r["diagnosis"])
    if r.get("comparison"):
        L += ["", "## Against baseline", ""] + comparison_lines(r["comparison"])
    return "\n".join(L) + "\n"


def comparison_lines(c):
    L = ["| measure | delta |", "|---|---|"]
    for t, v in c.get("master", {}).items():
        L.append(f"| master {t} LUFS / crest | {fmt(v['integratedLufs'], '+.2f')} / {fmt(v['crestDb'], '+.2f')} (TP {fmt(v['truePeakDbtp'], '+.2f')} dBTP) |")
        L.append(f"| master {t} bands | " + ", ".join(f"{k} {fmt(x, '+.2f')}" for k, x in v["bands"].items()) + " |")
    if c.get("bassStem", {}).get("integratedLufs") is not None or c.get("bassStem", {}).get("bands"):
        L.append(f"| bass stem LUFS | {fmt(c['bassStem'].get('integratedLufs'), '+.2f')} |")
        L.append("| bass stem bands | " + ", ".join(f"{k} {fmt(x, '+.2f')}" for k, x in c["bassStem"].get("bands", {}).items()) + " |")
    for k, v in c["proxies"].items():
        L.append(f"| {k} | margin {fmt(v['cueMarginDbMedian'], '+.2f')} dB, p10 {fmt(v['cueMarginDbP10'], '+.2f')}, survival "
                 f"{fmt(v['survivalDbMedian'], '+.2f')}, identifiable {fmt(None if v['identifiable'] is None else 100 * v['identifiable'], '+.0f')} pts, "
                 f"solo {fmt(None if v['identifiableSolo'] is None else 100 * v['identifiableSolo'], '+.0f')} pts |")
    for cell, v in c.get("cells", {}).items():
        L.append(f"| cell {cell} | sustain margin 120/180/250 {fmt(v['sustain/120'], '+.2f')} / {fmt(v['sustain/180'], '+.2f')} / "
                 f"{fmt(v['sustain/250'], '+.2f')} dB; identifiable 180 {fmt(None if v['identifiable180'] is None else 100 * v['identifiable180'], '+.0f')} pts |")
    L.append(f"| efficiency (sustain margin 180 gain minus bass stem LUFS gain) | {fmt(c.get('efficiencyDb'), '+.2f')} dB |")
    L.append(f"| per-pitch spread change | {fmt(c.get('pitchSpreadDeltaDb'), '+.2f')} dB |")
    return L


def pooled_markdown(p, title="Pooled translation summary"):
    s = p["summary"]
    L = [f"# {title}", "", "Captures: " + ", ".join(Path(c).name for c in p["captures"]), "",
         "## Sustain proxies", ""] + summary_rows(s, [("pooled", s["pooled"])] + list(s["toneRegister"].items()) + list(s["cells"].items()))
    L += ["", "## Attack proxies", ""] + summary_rows(s, [("pooled", s["pooled"])] + list(s["toneRegister"].items()) + list(s["cells"].items()), "attack")
    sp = s["spread"]
    L += ["", f"Per-pitch sustain cue level at HP180: " + ", ".join(f"MIDI {k} {v:.1f}" for k, v in sp["perPitchMedianDb"].items())
          + f" (spread {fmt(sp['pitchSpreadDb'], '.1f')} dB); per tone " + ", ".join(f"{k} {v:.1f}" for k, v in sp["perToneMedianDb"].items()) + "."]
    L += ["", "Masked harmonics at HP180 by stem: sustain " + ", ".join(f"{k} {100 * v:.0f}%" for k, v in s["maskers"]["sustain"]["share"].items())
          + f" ({s['maskers']['sustain']['maskedHarmonics']}); attack " + ", ".join(f"{k} {100 * v:.0f}%" for k, v in s["maskers"]["attack"]["share"].items())
          + f" ({s['maskers']['attack']['maskedHarmonics']})."]
    L += ["", "## Diagnosis", ""] + diagnosis_lines(p["diagnosis"])
    if p.get("comparison"):
        L += ["", "## Against baseline (pooled)", ""] + comparison_lines(p["comparison"])
    return "\n".join(L) + "\n"


def resolve_baselines(caps, baselines):
    if not baselines:
        return [None] * len(caps)
    if len(baselines) == 1 and len(caps) > 1 or (len(baselines) == 1 and not (Path(baselines[0]) / "manifest.json").is_file()):
        root = Path(baselines[0])
        return [root / Path(c).name if (root / Path(c).name / "manifest.json").is_file() else None for c in caps]
    if len(baselines) != len(caps):
        sys.exit("--baseline takes one capture per capture, or one directory of captures named like them")
    return [Path(b) for b in baselines]


def parse_excerpt(text):
    if not text:
        return None
    a, b = text.split(":")
    return int(a) - 1, int(b)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="*")
    ap.add_argument("--baseline", nargs="+", default=[])
    ap.add_argument("--out", help="pooled output directory (default: first capture's translation folder)")
    ap.add_argument("--auditions", help="write excerpt listening files here (with --pair: the A-B-A-B files)")
    ap.add_argument("--excerpt", help="BAR:BARS, 1-based start bar (default: picked from the note table)")
    ap.add_argument("--pair", nargs=2, metavar=("BASE", "CAND"))
    ap.add_argument("--no-aac", action="store_true")
    ap.add_argument("--force", action="store_true", help="recompute cached per-capture results")
    ap.add_argument("--json", help="also write the pooled (or single) JSON here")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        from mixlib.selftest import run_translation_self_test
        return run_translation_self_test()
    excerpt = parse_excerpt(args.excerpt)
    if args.pair:
        if not args.auditions:
            sys.exit("--pair needs --auditions DIR")
        base = load_or_analyze(args.pair[0], args.force)
        meta = tr.pair(args.pair[0], args.pair[1], args.auditions, base, excerpt, not args.no_aac)
        g = meta["gains"]
        print(f"base {g['baseLufs']:.2f} LUFS gain {g['baseGainDb']:+.2f} dB; candidate {g['candLufs']:.2f} LUFS gain {g['candGainDb']:+.2f} dB; "
              "stress common gains " + ", ".join(f"{k} {v:+.2f} dB" for k, v in g["stressCommonGainDb"].items()))
        print(f"wrote {len(meta['files'])} A-B-A-B files to {args.auditions}")
        return 0
    if not args.captures:
        ap.error("give at least one capture")
    results = [load_or_analyze(c, args.force) for c in args.captures]
    bases = resolve_baselines(args.captures, args.baseline)
    base_results = []
    for r, b, c in zip(results, bases, args.captures):
        if b is not None:
            br = load_or_analyze(b, args.force)
            base_results.append(br)
            r["comparison"] = tr.compare(r, br)
            out = Path(c) / "translation"
            (out / "translation.md").write_text(markdown(r))
            (out / "comparison.json").write_text(json.dumps(r["comparison"], indent=1, default=_json_default))
        print(f"{Path(c).name}: {Path(c) / 'translation' / 'translation.md'}")
        d = r["diagnosis"]
        print("  modes met: " + (", ".join(k for k, v in d.items() if v["met"]) or "none"))
        sus = r["summary"]["pooled"].get("sustain", {}).get("180", {})
        print(f"  sustain HP180: margin {fmt(sus.get('cueMarginDbMedian'))} dB, identifiable {pct(sus.get('identifiable'))}, "
              f"solo {pct(sus.get('identifiableSolo'))}, survival {fmt(sus.get('survivalDbMedian'))} dB")
        if r.get("comparison"):
            cmp = r["comparison"]["proxies"]["sustain/180"]
            print(f"  vs baseline: sustain margin 180 {fmt(cmp['cueMarginDbMedian'], '+.2f')} dB, efficiency "
                  f"{fmt(r['comparison']['efficiencyDb'], '+.2f')} dB")
        if args.auditions and len(results) == 1:
            tr.auditions(c, r, args.auditions, excerpt, not args.no_aac)
    out_json = None
    if len(results) > 1:
        p = tr.pool(results)
        if base_results and len(base_results) == len(results):
            p["comparison"] = tr.compare_pooled(p, tr.pool(base_results))
        out = Path(args.out) if args.out else Path(args.captures[0]) / "translation"
        out.mkdir(parents=True, exist_ok=True)
        (out / "pooled.json").write_text(json.dumps(p, indent=1, default=_json_default))
        (out / "pooled.md").write_text(pooled_markdown(p))
        print(f"pooled: {out / 'pooled.md'}")
        print("  pooled modes met: " + (", ".join(k for k, v in p["diagnosis"].items() if v["met"]) or "none"))
        out_json = p
    elif results:
        out_json = results[0]
    if args.json and out_json is not None:
        Path(args.json).write_text(json.dumps(out_json, indent=1, default=_json_default))
    return 0


if __name__ == "__main__":
    sys.exit(main())
