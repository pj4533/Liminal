#!/usr/bin/env python3
"""Measure the strummed guitar and harp phrases of a Lo-Fi capture (D128, plan section 3.2).

  python3 scripts/strum-report.py CAPTURE_DIR [--baseline DIR] [--off DIR] [--json OUT]

CAPTURE_DIR is a check-lofi.sh / mix-report.sh capture (manifest.json, score.json, dry.wav, wet.wav,
dialogue-chops.wav, master.wav; report/mix-report.json when mix-report.py ran). --baseline is the
"before" capture with the same seed and forced program; --off is the same build captured with
`--hook strumHook=off`. With either, the script prints the C2 to C10 deltas and one PASS, FAIL, WARN
or N/A line per criterion.

Per phrase it reports the program, section and take position, the ornament and strum note counts,
strum events (`strum` notes grouped by onsets within 120 ms), strings per event, the bars with an
event, the distance from each event to the nearest kick and snare landmark, onset coincidence and
time overlap with dry chops, the dry (`dry.wav`) and wet (`wet.wav`) loudness, the 2-5 kHz share of
the dry stem, the 1-4 kHz level of the dry lead under the chops while they overlap, the echo ratios
of C9 and the lead gain from `diagnostics.musicLevels`. Melody-attached ornament strums (two or more
ornaments within 120 ms under a lead note) are counted too, so a capture made before the hook line
existed has a number.

Echo ratios are read from the wet stem, which also carries the melody's own echo and room; a plain
stab's ratio is therefore a lower bound. Phrase loudness is BS.1770 gated integrated loudness over
the span; the two-beat windows are ungated K-weighted means.
"""

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from scipy import signal as sps

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from mixlib.audio import Capture, db10, db20  # noqa: E402
from mixlib.loudness import integrated_lufs, k_weighted, sub_block_ms  # noqa: E402

GROUP_SECONDS = 0.120
GHOST_STRENGTH = 0.45      # DialogueMotifTuning.ghostStrength
CONFIDENT = 0.5            # landmarks the hook reads (plan 2.5)
STRUM_PROGRAM_WORDS = ("nylon", "steel", "archtop", "flatwound", "hollowbody", "harp")
SITES = ("answer", "push", "withKick", "gap")


def is_strum_program(name):
    return any(w in (name or "").lower() for w in STRUM_PROGRAM_WORDS)


def finite(x):
    return x is not None and isinstance(x, (int, float)) and math.isfinite(x)


def rnd(x, n=2):
    return round(float(x), n) if finite(x) else None


def lufs(sig, rate):
    if sig is None or len(sig) < int(0.4 * rate):
        return None
    v = integrated_lufs(sub_block_ms(sig, rate))
    return v if math.isfinite(v) else None


def mean_lufs(sig, rate, a, b):
    """Ungated K-weighted mean over frames a..b, with 0.5 s of preroll for the filter."""
    if sig is None or b <= a:
        return None
    lo = max(0, a - int(0.5 * rate))
    k = k_weighted(np.asarray(sig[lo:b], dtype=np.float64), rate)[a - lo:]
    if not len(k):
        return None
    v = float(-0.691 + db10(np.sum(np.mean(k ** 2, axis=0))))
    return v if v > -100 else None


def band_share_db(sig, rate, lo, hi):
    if sig is None or len(sig) < 4096:
        return None
    mono = np.asarray(sig, dtype=np.float64).mean(axis=1)
    if not np.any(mono):
        return None
    f, p = sps.welch(mono, fs=rate, nperseg=4096)
    total = p.sum()
    return float(db10(p[(f >= lo) & (f < hi)].sum() / total)) if total > 0 else None


def envelope_db(sig, rate, a, b, win=0.02):
    """Peak 20 ms RMS (dB, the louder channel) over frames a..b."""
    if sig is None:
        return None
    a, b = max(0, a), min(len(sig), b)
    n = int(win * rate)
    if b - a < n:
        return None
    seg = np.asarray(sig[a:b], dtype=np.float64)
    blocks = (len(seg) // n)
    sq = (seg[: blocks * n] ** 2).reshape(blocks, n, -1).mean(axis=1)
    return float(db10(sq.max()))


def bandpass(sig, rate, lo, hi):
    sos = sps.butter(4, [lo, hi], btype="bandpass", fs=rate, output="sos")
    return sps.sosfilt(sos, np.asarray(sig, dtype=np.float64).mean(axis=1))


def group_onsets(notes, rate):
    """Chain notes whose onsets fall within 120 ms of the previous one."""
    gap = int(GROUP_SECONDS * rate)
    groups = []
    for n in sorted(notes, key=lambda n: int(n["on"])):
        if groups and int(n["on"]) - int(groups[-1][-1]["on"]) <= gap:
            groups[-1].append(n)
        else:
            groups.append([n])
    return groups


class Landmarks:
    def __init__(self, cap):
        self.kicks, self.snares = [], []
        for take in cap.diagnostics.get("landmarks") or []:
            for k in take.get("kicks", []):
                if float(k.get("confidence", 1)) >= CONFIDENT:
                    self.kicks.append(int(k["frame"]))
            for s in take.get("snares", []):
                if float(s.get("confidence", 1)) >= CONFIDENT and float(s.get("strength", 1)) > GHOST_STRENGTH:
                    self.snares.append(int(s["frame"]))
        self.kicks = np.array(sorted(set(self.kicks)), dtype=np.int64)
        self.snares = np.array(sorted(set(self.snares)), dtype=np.int64)
        self.present = bool(len(self.kicks) or len(self.snares))

    @staticmethod
    def nearest(arr, frame):
        if not len(arr):
            return None
        i = np.searchsorted(arr, frame)
        best = min((abs(int(arr[j]) - frame) for j in (i - 1, i) if 0 <= j < len(arr)), default=None)
        return best

    @staticmethod
    def within(arr, frame, frames):
        return bool(len(arr)) and Landmarks.nearest(arr, frame) is not None and Landmarks.nearest(arr, frame) <= frames

    def site(self, frame, beat, rate):
        """The site an onset sits on, inferred from the landmarks (the manifest's own site wins)."""
        tol = int(0.040 * rate)
        if self.within(self.kicks, frame, tol):
            return "withKick"
        for back in (0.5, 0.25):
            if self.within(self.snares, int(frame - back * beat), tol):
                return "answer"
        busy = self.within(self.kicks, frame, int(0.125 * beat)) or self.within(self.snares, frame, int(0.125 * beat))
        if self.within(self.kicks, int(frame + 0.5 * beat), tol) and not busy:
            return "push"
        return "gap" if not busy else "other"


def measure(path):
    cap = Capture(Path(path))
    rate, beat, bar = cap.rate, cap.beat_frames, cap.bar_frames
    score = cap.score or []
    levels = {int(e["phrase"]): e for e in cap.diagnostics.get("musicLevels") or [] if e.get("phrase") is not None}
    marks = Landmarks(cap)
    dry, wet = cap.stem("dry"), cap.stem("wet")
    chops_stem = cap.stem("dialogue-chops")
    master = cap.stem("master")
    chop_rows = cap.chops()
    chop_onsets = np.array(sorted(int(c["frame"]) for c in chop_rows if c.get("frame") is not None), dtype=np.int64)
    chop_dry = cap.chop_intervals(dry=True) if chop_rows else []
    report_doc = None
    rp = Path(path) / "report" / "mix-report.json"
    if rp.is_file():
        report_doc = json.loads(rp.read_text())

    phrases, events_all = [], []
    for i, ph in enumerate(score):
        a, b = (int(x) for x in ph["range"])
        notes = ph.get("notes", [])
        lead = [n for n in notes if n.get("role") == "lead"]
        orn = [n for n in notes if n.get("role") == "ornament"]
        strum = [n for n in notes if n.get("role") == "strum"]
        lead_onsets = sorted(int(n["on"]) for n in lead)
        # Melody-attached ornament strums: 2+ ornaments within 120 ms with a higher lead note there.
        attached = []
        for g in group_onsets(orn, rate):
            if len(g) < 2:
                continue
            lo, hi = min(int(n["on"]) for n in g), max(int(n["on"]) for n in g)
            top = max(int(n["midi"]) for n in g)
            if any(lo - GROUP_SECONDS * rate <= int(n["on"]) <= hi + GROUP_SECONDS * rate and int(n["midi"]) > top
                   for n in lead):
                attached.append({"frame": lo, "strings": len(g) + 1})
        manifest_events = ph.get("strumEvents") or []
        events = []
        for k, g in enumerate(group_onsets(strum, rate)):
            start = min(int(n["on"]) for n in g)
            end = max(int(n["off"]) for n in g)
            ev = {"phrase": i, "frame": start, "end": end, "strings": len(g),
                  "bar": int((start - a) // bar), "beatInPhrase": rnd((start - a) / beat, 3),
                  "thrown": max(float(n.get("send", 0)) for n in g) >= 0.8,
                  "send": rnd(max(float(n.get("send", 0)) for n in g), 3)}
            if marks.present:
                kick = Landmarks.nearest(marks.kicks, start)
                snare = Landmarks.nearest(marks.snares, start)
                ev["kickMs"] = rnd(kick / rate * 1000, 1) if kick is not None else None
                ev["snareMs"] = rnd(snare / rate * 1000, 1) if snare is not None else None
                ev["inferredSite"] = marks.site(start, beat, rate)
            me = next((m for m in manifest_events if abs(float(m.get("beat", -99)) - (start - a) / beat) < 0.2), None)
            if me and me.get("site") is not None:
                site = me["site"]
                ev["site"] = SITES[site] if isinstance(site, int) and 0 <= site < len(SITES) else str(site)
                if me.get("kind") is not None:
                    ev["kind"] = me["kind"]
            near_chop = Landmarks.nearest(chop_onsets, start)
            ev["chopOnsetMs"] = rnd(near_chop / rate * 1000, 1) if near_chop is not None else None
            dry_end = min(end, start + int(0.6 * beat)) if not ev["thrown"] else end
            ov = sum(max(0, min(dry_end, cb) - max(start, ca)) for ca, cb in chop_dry)
            ev["chopOverlapFraction"] = rnd(ov / max(1, dry_end - start), 3)
            # C9: the dry stab's peak, then the loudest wet moment between 0.6 and 2 beats later.
            dry_peak = envelope_db(dry, rate, start, start + int(0.15 * rate))
            echo_peak = envelope_db(wet, rate, start + int(0.6 * beat), start + int(2.0 * beat))
            ev["dryPeakDb"] = rnd(dry_peak)
            audible = finite(dry_peak) and finite(echo_peak) and dry_peak > -90 and echo_peak > -120
            ev["echoUnderDryDb"] = rnd(dry_peak - echo_peak) if audible else None
            events.append(ev)
        events_all += events
        lv = levels.get(i, {})
        lead_gain = lv.get("leadGain")
        focus = bool(events) or is_strum_program(ph.get("program"))
        row = {
            "phrase": i, "take": i // 4, "position": i % 4, "section": ph.get("section"),
            "program": ph.get("program"), "focus": focus,
            "leadNotes": len(lead), "ornamentNotes": len(orn), "strumNotes": len(strum),
            "attachedOrnamentStrums": len(attached),
            "attachedStringsMean": rnd(np.mean([s["strings"] for s in attached]) if attached else None),
            "events": len(events), "barsWithEvent": sorted({e["bar"] for e in events}),
            "stringsPerEvent": [e["strings"] for e in events],
            "leadGainDb": rnd(db20(lead_gain), 3) if finite(lead_gain) else None,
            "dryLufs": rnd(lufs(None if dry is None else dry[a:b], rate)),
            "wetLufs": rnd(lufs(None if wet is None else wet[a:min(len(wet), b + int(2 * beat))], rate)),
            "dryShare2to5kDb": rnd(band_share_db(None if dry is None else dry[a:b], rate, 2000, 5000)),
            "nextTwoBeatsWetDb": rnd(mean_lufs(wet, rate, b, b + int(2 * beat))) if b < cap.scored_frames else None,
        }
        if not lead_onsets:
            row["leadOnsets"] = 0
        phrases.append(row)

    # C6: dry lead under the chops in 1-4 kHz while a hook event and a dry chop overlap.
    overlap = None
    if events_all and chops_stem is not None and dry is not None and chop_dry:
        diffs = []
        hop = int(0.010 * rate)
        for e in events_all:
            dry_end = e["end"] if e["thrown"] else min(e["end"], e["frame"] + int(0.6 * beat))
            for ca, cb in chop_dry:
                lo, hi = max(e["frame"], ca), min(dry_end, cb)
                if hi - lo < 2 * hop:
                    continue
                pre = int(0.05 * rate)
                d = bandpass(dry[max(0, lo - pre):hi], rate, 1000, 4000)[lo - max(0, lo - pre):]
                c = bandpass(chops_stem[max(0, lo - pre):hi], rate, 1000, 4000)[lo - max(0, lo - pre):]
                m = len(d) // hop
                if not m:
                    continue
                pd = (d[: m * hop] ** 2).reshape(m, hop).mean(axis=1)
                pc = (c[: m * hop] ** 2).reshape(m, hop).mean(axis=1)
                keep = pc > 1e-9
                diffs += list(db10(pc[keep]) - db10(np.maximum(pd[keep], 1e-14)))
        if diffs:
            overlap = {"hops": len(diffs), "chopsOverDryMedianDb": rnd(np.median(diffs)),
                       "chopsOverDryP10Db": rnd(np.percentile(diffs, 10))}

    bars_total = int(round(cap.scored_frames / bar))
    bars_with = sum(len(p["barsWithEvent"]) for p in phrases)
    summary = {
        "capture": str(path), "case": cap.case, "seed": cap.manifest.get("seed"), "bpm": cap.manifest.get("bpm"),
        "gitRevision": cap.manifest.get("gitRevision"), "hooks": cap.manifest.get("hooks"),
        "audition": cap.diagnostics.get("audition"), "privateDrums": bool(cap.manifest.get("privateSources")),
        "landmarks": marks.present, "bars": bars_total,
        "chops": len(chop_rows), "hookEvents": len(events_all), "barsWithHookEvent": bars_with,
        "barsWithHookEventShare": rnd(bars_with / bars_total, 4) if bars_total else None,
        "attachedOrnamentStrums": sum(p["attachedOrnamentStrums"] for p in phrases),
        "masterLufs": rnd(lufs(master, rate)),
        "chopOnsetCoincidence": rnd(np.mean([e["chopOnsetMs"] is not None and e["chopOnsetMs"] <= 60
                                             for e in events_all]), 3) if events_all else None,
        "chopTimeOverlapShare": rnd(np.mean([e["chopOverlapFraction"] > 0 for e in events_all]), 3) if events_all else None,
        "chopOverlap1to4k": overlap,
    }
    if events_all and marks.present:
        summary["nearSnareShare"] = rnd(np.mean([e.get("snareMs") is not None and e["snareMs"] <= 40
                                                 for e in events_all]), 3)
        sites = [e.get("site") or e.get("inferredSite") for e in events_all]
        summary["siteHistogram"] = {s: sites.count(s) for s in sorted(set(sites))}
        summary["drumSiteShare"] = rnd(np.mean([s in ("answer", "push", "withKick") for s in sites]), 3)
    thrown = [e["echoUnderDryDb"] for e in events_all if e["thrown"] and finite(e["echoUnderDryDb"])]
    plain = [e["echoUnderDryDb"] for e in events_all if not e["thrown"] and finite(e["echoUnderDryDb"])]
    summary["echoThrownUnderDryDb"] = [rnd(x) for x in thrown]
    summary["echoPlainUnderDryDbMin"] = rnd(min(plain)) if plain else None
    return {"summary": summary, "phrases": phrases, "events": events_all,
            "criteria": criteria_values(report_doc)}


def criteria_values(doc):
    """The mix-report values the strum criteria compare (C4, C5, C8)."""
    if not doc:
        return None
    out = {}
    for c in doc.get("criteria", []):
        if c.get("id") in ("C-B1", "C-B5", "C-B6", "C-B7", "C-B8", "C-B9", "C-B11", "C-M2", "C-M6", "C-M9"):
            v = dict(c.get("values") or {})
            if c["id"] == "C-B6":
                sal = [x for k, x in v.items() if k.endswith("ReturnSalienceDb") and "WithDialogue" not in k and finite(x)]
                v = {"returnSalienceMinDb": min(sal) if sal else None,
                     **{k: x for k, x in v.items() if k.endswith("ReturnSalienceDb") and "WithDialogue" not in k}}
            out[c["id"]] = {"status": c.get("status"), "level": c.get("level"), "values": v}
    return out


class Verdicts:
    def __init__(self):
        self.lines = []

    def add(self, cid, status, text):
        self.lines.append((cid, status, text))

    def check(self, cid, ok, text, warn=False):
        if ok is None:
            self.add(cid, "N/A", text)
        else:
            self.add(cid, "PASS" if ok else ("WARN" if warn else "FAIL"), text)


def by_phrase(m):
    return {p["phrase"]: p for p in m["phrases"]}


def crit(m, cid, key=None):
    c = (m.get("criteria") or {}).get(cid)
    if c is None:
        return None
    return c if key is None else c["values"].get(key)


def compare(cur, base, off):
    v = Verdicts()
    cp = by_phrase(cur)
    focus = [p for p in cur["phrases"] if p["events"]] or [p for p in cur["phrases"] if p["focus"]]
    hooked = [p for p in cur["phrases"] if p["events"]]

    # C2: lead gain equal to hook-off.
    if off:
        op = by_phrase(off)
        deltas = [abs(p["leadGainDb"] - op[i]["leadGainDb"]) for i, p in cp.items()
                  if i in op and finite(p["leadGainDb"]) and finite(op[i]["leadGainDb"])]
        v.check("C2", max(deltas) <= 0.05 if deltas else None,
                f"lead gain max |on - off| {max(deltas):.3f} dB over {len(deltas)} phrases" if deltas else "no lead gains")
    else:
        v.add("C2", "N/A", "needs --off")

    # C3: dry and wet loudness of hook phrases; master integrated.
    for label, ref in (("off", off), ("before", base)):
        if not ref:
            continue
        rp = by_phrase(ref)
        d = [(p["phrase"], p["dryLufs"] - rp[p["phrase"]]["dryLufs"]) for p in focus
             if p["phrase"] in rp and finite(p["dryLufs"]) and finite(rp[p["phrase"]]["dryLufs"])]
        w = [(p["phrase"], p["wetLufs"] - rp[p["phrase"]]["wetLufs"]) for p in focus
             if p["phrase"] in rp and finite(p["wetLufs"]) and finite(rp[p["phrase"]]["wetLufs"])]
        if d:
            v.check("C3", max(x for _, x in d) <= 1.5,
                    f"dry vs {label}: " + ", ".join(f"p{i} {x:+.2f} LU" for i, x in d))
        if w:
            v.check("C3", max(x for _, x in w) <= 2.0,
                    f"wet (+2 beats) vs {label}: " + ", ".join(f"p{i} {x:+.2f} LU" for i, x in w))
    if base and finite(cur["summary"]["masterLufs"]) and finite(base["summary"]["masterLufs"]):
        dm = cur["summary"]["masterLufs"] - base["summary"]["masterLufs"]
        v.check("C3", abs(dm) <= 0.3, f"master {cur['summary']['masterLufs']:.2f} LUFS, {dm:+.2f} LU vs before")

    # C4: C-B5, C-B11, C-B6, C-B7 against before.
    b5 = crit(cur, "C-B5", "leadMinusMidsDb")
    v.check("C4", (3 <= b5 <= 8) if finite(b5) else None, f"C-B5 lead minus mids {b5} dB (3 to 8)")
    if base:
        for cid, key, tol, name in (("C-B11", "medianLeadMinusOthersDb", 0.5, "C-B11 median lead minus others"),
                                    ("C-B6", "returnSalienceMinDb", 0.5, "C-B6 return salience (min)")):
            x, y = crit(cur, cid, key), crit(base, cid, key)
            v.check("C4", (x >= y - tol) if finite(x) and finite(y) else None,
                    f"{name} {x} vs before {y} dB")
        s6 = crit(cur, "C-B6")
        v.check("C4", (s6["status"] == "pass") if s6 else None, f"C-B6 status {s6['status'] if s6 else None}")
        x, y = crit(cur, "C-B7", "leadMinusSpaceDbMedian"), crit(base, "C-B7", "leadMinusSpaceDbMedian")
        if finite(x) and finite(y):
            v.check("C4", x >= 3 if y >= 3 else True, f"C-B7 lead minus space {x} vs before {y} dB")

        # C5: dialogue.
        for key, tol in (("siiMean", 0.01), ("siiP10", 0.01), ("snr1to4kMeanDb", 0.3)):
            x, y = crit(cur, "C-B8", key), crit(base, "C-B8", key)
            v.check("C5", (x >= y - tol) if finite(x) and finite(y) else None, f"C-B8 {key} {x} vs before {y}")
        s9, b9 = crit(cur, "C-B9"), crit(base, "C-B9")
        x, y = crit(cur, "C-B9", "audibilityIndex"), crit(base, "C-B9", "audibilityIndex")
        if s9 and b9:
            v.check("C5", s9["status"] == b9["status"] and (abs(x - y) <= 0.02 if finite(x) and finite(y) else True),
                    f"C-B9 {s9['status']} (before {b9['status']}), audibility {x} vs {y}")
    else:
        v.add("C4", "N/A", "C-B11, C-B6, C-B7 need --baseline")
        v.add("C5", "N/A", "needs --baseline")

    # C6: sharing with the chops.
    s = cur["summary"]
    if hooked and s["chops"]:
        v.check("C6", s["chopOnsetCoincidence"] <= 0.15, f"onsets within 60 ms of a chop {s['chopOnsetCoincidence']:.1%}")
        ov = s.get("chopOverlap1to4k")
        if ov:
            v.check("C6", ov["chopsOverDryMedianDb"] >= 6 and ov["chopsOverDryP10Db"] >= 3,
                    f"chops over dry lead in 1-4 kHz median {ov['chopsOverDryMedianDb']} dB, p10 {ov['chopsOverDryP10Db']} dB")
        v.check("C6", s["chopTimeOverlapShare"] <= 0.5, f"events overlapping a dry chop {s['chopTimeOverlapShare']:.1%}",
                warn=True)
    else:
        v.add("C6", "N/A", "no hook events" if not hooked else "no chops in this capture")

    # C7: drums.
    if hooked and s.get("nearSnareShare") is not None and s["privateDrums"]:
        v.check("C7", s["nearSnareShare"] <= 0.05, f"within 40 ms of a snare {s['nearSnareShare']:.1%}")
        v.check("C7", s["drumSiteShare"] >= 0.70, f"answer, push or with-kick {s['drumSiteShare']:.1%} {s['siteHistogram']}")
    else:
        v.add("C7", "N/A", "no hook events" if not hooked else "needs private-drum landmarks")

    # C8: tone.
    if base:
        bp = by_phrase(base)
        t = [(p["phrase"], p["dryShare2to5kDb"] - bp[p["phrase"]]["dryShare2to5kDb"]) for p in focus
             if p["phrase"] in bp and finite(p["dryShare2to5kDb"]) and finite(bp[p["phrase"]]["dryShare2to5kDb"])]
        if t:
            v.check("C8", max(x for _, x in t) <= 1.5,
                    "dry 2-5 kHz share vs before: " + ", ".join(f"p{i} {x:+.2f} dB" for i, x in t))
        for cid in ("C-B1", "C-M2", "C-M6", "C-M9"):
            x, y = crit(cur, cid), crit(base, cid)
            if x and y:
                v.check("C8", x["status"] == "pass" if y["status"] == "pass" else True,
                        f"{cid} {x['status']} (before {y['status']})")

    # C9: echo.
    if hooked:
        th, pl = s["echoThrownUnderDryDb"], s["echoPlainUnderDryDbMin"]
        v.check("C9", all(6 <= x <= 12 for x in th) if th else None, f"thrown echo under dry stab {th} dB (6 to 12)")
        v.check("C9", pl >= 18 if finite(pl) else None, f"plain echo under dry stab, min {pl} dB (at least 18)")
        if off:
            op = by_phrase(off)
            n = [(p["phrase"], p["nextTwoBeatsWetDb"] - op[p["phrase"]]["nextTwoBeatsWetDb"]) for p in hooked
                 if p["phrase"] in op and finite(p["nextTwoBeatsWetDb"]) and finite(op[p["phrase"]]["nextTwoBeatsWetDb"])]
            if n:
                v.check("C9", max(x for _, x in n) <= 1.5,
                        "next phrase's first two beats of wet vs off: " + ", ".join(f"p{i} {x:+.2f} dB" for i, x in n))
    else:
        v.add("C9", "N/A", "no hook events")

    # C10: amount.
    if s["bars"] >= 64:
        share = s["barsWithHookEventShare"]
        v.check("C10", 0.08 <= share <= 0.22 if finite(share) else None, f"bars with a hook event {share:.1%} of {s['bars']}")
    for p in hooked:
        v.check("C10", 2 <= p["events"] <= 5, f"p{p['phrase']} {p['program']}: {p['events']} events")
    audition = s.get("audition") or {}
    if audition.get("guitarSlot") == 2 and audition.get("guitarProgram"):
        slots = [p for p in cur["phrases"] if p["position"] == 2 and is_strum_program(p["program"])
                 and "harp" not in (p["program"] or "").lower()]
        for p in slots:
            v.check("C10", (2 <= p["events"] <= 5) if hooked else None,
                    f"forced position-2 guitar phrase p{p['phrase']}: {p['events']} events")
    return v


def print_measure(m):
    s = m["summary"]
    print(f"Capture {s['capture']} (case {s['case']}, seed {s['seed']}, {s['bpm']} BPM, {s['bars']} bars, "
          f"rev {str(s['gitRevision'])[:7]})")
    print(f"  audition {s['audition']}  hooks {s['hooks']}")
    print(f"  hook events {s['hookEvents']}, bars with an event {s['barsWithHookEvent']} "
          f"({s['barsWithHookEventShare']}), melody-attached ornament strums {s['attachedOrnamentStrums']}, "
          f"master {s['masterLufs']} LUFS")
    print("  phr take pos section      program              lead orn strum att  ev  leadGain  dryLUFS  wetLUFS  2-5k")
    for p in m["phrases"]:
        mark = "*" if p["focus"] else " "
        print(f" {mark}{p['phrase']:3d} {p['take']:4d} {p['position']:3d} {str(p['section']):12s} {str(p['program']):20s} "
              f"{p['leadNotes']:4d} {p['ornamentNotes']:3d} {p['strumNotes']:5d} {p['attachedOrnamentStrums']:3d} "
              f"{p['events']:3d} {p['leadGainDb']!s:>8} {p['dryLufs']!s:>8} {p['wetLufs']!s:>8} {p['dryShare2to5kDb']!s:>6}")
    if m["events"]:
        print("  events: phrase bar beat strings thrown site kickMs snareMs chopMs echoUnderDry")
        for e in m["events"]:
            print(f"    p{e['phrase']} bar {e['bar']} beat {e['beatInPhrase']} x{e['strings']} "
                  f"{'thrown' if e['thrown'] else 'plain '} {e.get('site') or e.get('inferredSite')} "
                  f"{e.get('kickMs')} {e.get('snareMs')} {e['chopOnsetMs']} {e['echoUnderDryDb']}")
    c = m.get("criteria")
    if c:
        print("  mix report: " + ", ".join(f"{k} {v['status']}" for k, v in c.items()))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", type=Path)
    ap.add_argument("--baseline", type=Path, help="the before capture (same seed and forced program)")
    ap.add_argument("--off", type=Path, help="the same build captured with --hook strumHook=off")
    ap.add_argument("--json", type=Path, help="write the measurements and verdicts here")
    args = ap.parse_args()
    for p in (args.capture, args.baseline, args.off):
        if p is not None and not (p / "manifest.json").is_file():
            ap.error(f"{p} has no manifest.json")
    cur = measure(args.capture)
    base = measure(args.baseline) if args.baseline else None
    off = measure(args.off) if args.off else None
    print_measure(cur)
    doc = {"schema": "liminal-strum-report-v1", "current": cur}
    failed = False
    if base or off:
        if base:
            doc["baseline"] = {"summary": base["summary"], "phrases": base["phrases"], "criteria": base["criteria"]}
        if off:
            doc["off"] = {"summary": off["summary"], "phrases": off["phrases"], "criteria": off["criteria"]}
        v = compare(cur, base, off)
        print("\nCriteria (plan 3.2):")
        for cid, status, text in v.lines:
            print(f"  {status:4s} {cid:4s} {text}")
        doc["verdicts"] = [{"id": cid, "status": st, "text": t} for cid, st, t in v.lines]
        failed = any(st == "FAIL" for _, st, _ in v.lines)
    if args.json:
        args.json.write_text(json.dumps(doc, indent=1, default=lambda o: o.item() if hasattr(o, "item") else str(o)))
        print(f"\nWrote {args.json}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
