#!/usr/bin/env python3
"""Report on a DialogueSalienceProbeTests log: connective-word share, partial-word share and why,
salient-word reach, and the probe's snippets as WAV files.

usage: dialogue-salience-report.py <xcodebuild.log> <out-dir> [--json]

Definitions (keep them fixed for before/after comparisons):
- a "play" is one SALIENCE-HIT (one chop event). "Heard" words are accepted transcript words (voiced
  cores) the play covers by at least 30 %.
- function-only: every heard word is in DialogueLineInterest.functionWords.
- audible partial: an edge lands more than 30 ms inside a heard word's core AND the signal is still
  sounding there (start: the 30 ms before is above -15 dB of the play's peak; end: the last 12 ms above
  -20 dB and the 30 ms after above -15 dB). A `half` fragment is a syllable split by design; any other
  audible partial is accidental, attributed to the mechanism of the edge (gate, choke, valley, pieceCut,
  onsetTrim, lineStart/lineEnd; `dropped` when the word was dropped from the accepted words).
- salient: a heard word weighing >= 0.7 (DialogueLineInterest.wordWeights); lexicon salient >= 0.85, or an
  all-caps 2-5 letter token (an initialism).
- split fragments: `half` (the pre-D130 syllable halves of any piece), `syllable` (a syllable of a salient
  multi-syllable word) and `letter` (a letter of an initialism) are splits by design; their audible
  partials are counted under their own category, never as accidental. The split checks count, over all
  split plays: halves of function words (every heard word a function word, or an edge inside one), halves
  inside one-syllable words (an edge inside a word of one syllable by a text count), and initialism cuts
  off a letter boundary (any play other than a `letter` with an edge inside an initialism).
- tightness: `onsetMs` of sub-line plays (the D126 independent detector, the steepest rise of a 10 ms log
  envelope in 300 Hz to 3.4 kHz of the rendered chop, against the accent).
- variety: `SALIENCE-LOOP` lines (chop-beat unmarked same-cut pairs, longest run, distinct cuts per 2-bar
  cell, onsets per bar, dry occupancy per 8 bars).
- strikingPassedOver: loops (T) whose window ranked a line of interest >= 0.6 while the chosen line is at
  least 0.15 lower.
"""
import base64
import collections
import json
import re
import statistics
import sys
from pathlib import Path


def parse(text, bad):
    try:
        return json.loads(text, strict=False)
    except json.JSONDecodeError:
        bad.append(text[:80])
        return None


def load(path):
    hits, windows, snippets, bad = [], [], {}, []
    global LOOPS, FOOTAGE, CORPUS, ATTEMPTS, AUDITIONS
    LOOPS = []
    FOOTAGE = []
    CORPUS, ATTEMPTS, AUDITIONS = [], [], []
    for line in open(path, errors="replace"):
        if line.startswith("SALIENCE-CORPUS "):
            CORPUS += [x for x in [parse(line[16:], bad)] if x]
        elif line.startswith("SALIENCE-ATTEMPT "):
            ATTEMPTS += [x for x in [parse(line[17:], bad)] if x]
        elif line.startswith("SALIENCE-AUDITION "):
            AUDITIONS += [x for x in [parse(line[17:], bad)] if x]
        elif line.startswith("SALIENCE-FOOTAGE "):
            FOOTAGE += [x for x in [parse(line[16:], bad)] if x]
        elif line.startswith("SALIENCE-LOOP "):
            LOOPS += [x for x in [parse(line[14:], bad)] if x]
        elif line.startswith("SALIENCE-HIT "):
            hits += [x for x in [parse(line[13:], bad)] if x]
        elif line.startswith("SALIENCE-WINDOW "):
            windows += [x for x in [parse(line[16:], bad)] if x]
        elif line.startswith("SALIENCE-SNIPPET "):
            parts = line.split(" ", 2)
            if len(parts) == 3:
                snippets[parts[1]] = parts[2].strip()
    if bad:
        print(f"skipped {len(bad)} unreadable lines", file=sys.stderr)
    return hits, windows, snippets


def aud_start(x):
    return x["preDB"] > -15


def aud_end(x):
    return x["tailDB"] > -20 and x["postDB"] > -15


def heard(x):
    return [w for w in x["words"] if w["cov"] >= 0.3] if x.get("renderAudible", True) else []


def initialism(t):
    letters = "".join(c for c in t if c.isalpha())
    return 2 <= len(letters) <= 5 and letters.isupper()


def classify(x):
    s = x.get("startIn") if "startIn" in x and aud_start(x) else None
    e = x.get("endIn") if "endIn" in x and aud_end(x) else None
    if not s and not e:
        return "clean", []
    # D130 stage 2: a letter of an initialism is a clean cut (its edges are letter boundaries); a
    # syllable of a salient word is a split by design; a half (no transcript) stays a half.
    if x["kind"] == "letter":
        return "clean", []
    if x["kind"] in SPLIT_KINDS:
        return x["kind"], []
    if x["stutter"]:
        return "stutter", []
    mechs = []
    for edge, side in ((s, "start"), (e, "end")):
        if edge:
            mechs.append(f"{side}:{edge['mech']}" + (":dropped" if edge["drop"] else ""))
    return "accidental", mechs


SPLIT_KINDS = ("half", "syllable", "letter")
LOOPS = []
FOOTAGE = []
CORPUS, ATTEMPTS, AUDITIONS = [], [], []


def syllables(t):
    w = "".join(c for c in t.lower() if c.isalpha())
    if not w:
        return 0
    if initialism(t):
        return len("".join(c for c in t if c.isalpha()))
    groups = re.findall(r"[aeiouy]+", w)
    n = len(groups)
    if w.endswith("e") and not w.endswith(("le", "ee", "ye")) and n > 1:
        n -= 1
    return max(1, n)


def edge_words(x):
    return [e["word"] for e in (x.get("startIn"), x.get("endIn")) if e]


def split_checks(h):
    fn_texts = {w["t"] for x in h for w in x["words"] if w.get("fn")}
    function_halves = one_syllable = initial_off = 0
    for x in h:
        edges = edge_words(x)
        if x["kind"] in SPLIT_KINDS:
            if x["functionOnly"] or any(e in fn_texts for e in edges):
                function_halves += 1
            if any(syllables(e) == 1 and not initialism(e) for e in edges):
                one_syllable += 1
        if x["kind"] != "letter" and any(initialism(e) for e in edges):
            initial_off += 1
    return {"halvesOfFunctionWords": function_halves, "halvesInsideOneSyllableWords": one_syllable,
            "initialismCutsOffLetter": initial_off}


def pct(v, q):
    if not v:
        return None
    s = sorted(v)
    return round(s[min(len(s) - 1, int(round((len(s) - 1) * q)))], 1)


def tightness(h):
    v = [x["onsetMs"] for x in h if "onsetMs" in x]
    return {"n": len(v), "median": pct(v, 0.5), "p5": pct(v, 0.05), "p95": pct(v, 0.95),
            "over35": sum(1 for q in v if abs(q) > 35)}


def variety(mode):
    rows = [r for r in LOOPS if r["mode"] == mode]
    if not rows:
        return None
    def mean(k, sub=None):
        vals = [r[k] if sub is None else sub(r) for r in rows]
        return round(sum(vals) / len(vals), 3)
    pairs = sum(r["chopPairs"] for r in rows)
    with_three = [r for r in rows if r["offered"] >= 3]
    chop_bars = [n for r in rows for n in r["onsetsPerBar"][2:6]]
    build_bars = [n for r in rows for n in r["onsetsPerBar"][6:8]]
    return {
        "loops": len(rows),
        "chopSamePairs": sum(r["chopSame"] for r in rows), "chopPairs": pairs,
        "chopSameFillPairs": sum(r.get("chopSameFill", 0) for r in rows),
        "chopSameShare": round(sum(r["chopSame"] for r in rows) / max(1, pairs), 3),
        "chopLongestRunMax": max(r["chopLongestRun"] for r in rows), "chopLongestRunMean": mean("chopLongestRun"),
        "chopPer2BarsMean": mean("chopPer2Bars"), "chopLeast2Bars": min(r["chopLeast2Bars"] for r in rows),
        "cellsUnder3WhereOffered": sum(1 for r in with_three for c in r["cells2Bars"] if c < 3),
        "cellsWhereOffered": 3 * len(with_three),
        "onsetsPerBarChop": round(sum(chop_bars) / max(1, len(chop_bars)), 2),
        "onsetsPerBarBuild": round(sum(build_bars) / max(1, len(build_bars)), 2),
        "onsetsPerBarAll": round(sum(n for r in rows for n in r["onsetsPerBar"]) / max(1, 16 * len(rows)), 2),
        "emptyBars": sum(1 for r in rows for n in r["onsetsPerBar"] if n == 0),
        "occupancyMean": round(sum(o for r in rows for o in r["occupancy"]) / (2 * len(rows)), 3),
        "occupancyMax": max(o for r in rows for o in r["occupancy"]),
    }


def striking_passed_over(hits, windows):
    """Loops (T) whose window still offered a ranked line of interest >= 0.6 while the chosen line is at
    least 0.15 lower. D130 stage 2: a ranked line that overlaps a line an earlier loop of the window
    already led is not on offer (the ledger and the said-once rule block it), so it no longer counts;
    before, every second loop of a window with one striking line counted as passed over."""
    loops = {}
    for x in hits:
        if x["mode"] == "T" and x["kind"] != "pad":
            loops[(x["film"], x["chunk"], x["loop"])] = (x["interest"], x.get("lineS"), x.get("lineE"))
    ranked = {(w["film"], w["chunk"]): w.get("ranked", []) for w in windows}
    n = n_any = 0
    for (f, c, l), (i, s, e) in loops.items():
        earlier = [(a, b) for (f2, c2, l2), (_, a, b) in loops.items() if (f2, c2) == (f, c) and l2 < l and a is not None]
        def open_line(r):
            return not any(min(r["e"], b) - max(r["s"], a) > 0.25 * min(r["e"] - r["s"], b - a) for a, b in earlier)
        lines = ranked.get((f, c), [])
        best_any = max([r["interest"] for r in lines] or [-1])
        best = max([r["interest"] for r in lines if open_line(r)] or [-1])
        n_any += best_any >= 0.6 and i <= best_any - 0.15
        n += best >= 0.6 and i <= best - 0.15
    return {"loops": len(loops), "passedOver": n, "passedOverIncludingPlayed": n_any}


def spell_figures(hits):
    """Loops (per mode) with a spell figure: two or more letters or syllables of one piece played in
    source order on consecutive hits, then that piece whole."""
    by_loop = collections.defaultdict(list)
    for x in hits:
        if x["kind"] != "pad":
            by_loop[(x["mode"], x["film"], x["chunk"], x["loop"])].append(x)
    out = collections.Counter()
    for (mode, *_), xs in by_loop.items():
        xs.sort(key=lambda x: (x["block"], x["slot"]))
        found = False
        for i in range(len(xs)):
            run = []
            j = i
            while j < len(xs) and xs[j]["kind"] in ("letter", "syllable") and (not run or (
                    xs[j].get("parent") == run[-1].get("parent") and xs[j]["frag"] > run[-1]["frag"])):
                run.append(xs[j])
                j += 1
            if len(run) >= 2 and j < len(xs) and xs[j]["frag"] == run[0].get("parent"):
                expected = run[0].get("spellUnits", [])
                ids = [x["frag"] for x in run]
                steps = [x["block"] * 64 + x["slot"] for x in run]
                strides = {b - a for a, b in zip(steps, steps[1:])}
                whole = xs[j]["block"] * 64 + xs[j]["slot"]
                # Complete source-order units on a uniform eighth/sixteenth grid, completed
                # on the first beat after the final unit (never a prefix or a distant word).
                if ids == expected and strides in ({1}, {2}) and whole == (steps[-1] // 4 + 1) * 4:
                    found = True
                    break
        out[mode] += found
    return dict(out)


def norm(t):
    return "".join(c for c in t.lower() if c.isalnum())


def metrics(hits, windows):
    out = {}
    for mode in sorted({h["mode"] for h in hits}):
        planned = [x for x in hits if x["mode"] == mode]
        h = [x for x in planned if x.get("renderAudible") is True]
        if not h:
            out[mode] = {"plays": 0, "planned": len(planned), "renderCoverage": render_coverage(planned)}
            continue
        n = len(h)
        cats = collections.Counter()
        mechs = collections.Counter()
        for x in h:
            c, m = classify(x)
            cats[c] += 1
            mechs.update(m)
        best = [max([w["w"] for w in heard(x)] or [-1]) for x in h]
        salient_whole = sum(1 for x in h if any(w["w"] >= 0.7 and w["cov"] >= 0.9 for w in x["words"]))
        salient_cut = sum(1 for x in h if any(w["w"] >= 0.7 and 0.3 <= w["cov"] < 0.9 for w in x["words"]))
        loops = {}
        for x in h:
            if x["kind"] != "pad":
                loops[(x["film"], x["chunk"], x["loop"])] = (x["line"], x["interest"])
        ints = [v[1] for v in loops.values()]
        out[mode] = {
            "plays": n, "planned": len(planned), "renderCoverage": render_coverage(planned),
            "kinds": dict(collections.Counter(x["kind"] for x in h)),
            "padFallbackShare": round(sum(x["kind"] == "pad" for x in h) / n, 3),
            "gateEnds": dict(collections.Counter(x["gateEnd"] for x in h)),
            "functionOnly": round(sum(x["functionOnly"] for x in h) / n, 3),
            "noWordHeard": round(sum(1 for b in best if b < 0) / n, 3),
            "bestHeardBelow0.5": round(sum(1 for b in best if 0 <= b < 0.5) / n, 3),
            "salientHeard": round(sum(1 for b in best if b >= 0.7) / n, 3),
            "salientWhole": round(salient_whole / n, 3),
            "salientCut": round(salient_cut / n, 3),
            "categories": {k: round(v / n, 3) for k, v in cats.items()},
            "spellUnitShare": round(sum(x["kind"] in ("letter", "syllable") for x in h) / n, 3),
            "audiblePartial": round((cats["half"] + cats["accidental"] + cats["stutter"]) / n, 3),
            "accidentalMechanisms": dict(mechs.most_common()),
            "halfLetterSplits": sum(1 for x in h if x["kind"] == "half" and (x["ftext"].endswith("-") or x["ftext"].startswith("-"))),
            "splitChecks": split_checks(h),
            "tightness": tightness(h),
            "variety": variety(mode),
            "loops": len(loops),
            "untextedLines": sum(1 for v in loops.values() if v[0] == "-"),
            "lineInterestMedian": round(statistics.median(ints), 3) if ints else None,
            "lineInterestAtLeast0.6": round(sum(i >= 0.6 for i in ints) / len(ints), 3) if ints else None,
        }
    for mode in sorted({h["mode"] for h in hits}):
        out[mode]["renderCoverage"]["inventoryPlanned"] = sum(w.get("renderOutcomes", {}).get(mode, {}).get("planned", 0) for w in windows)
    # Salient words in the windows and why their lines do or do not compete.
    total = ranked = chosen = 0
    reasons = collections.Counter()
    for w in windows:
        texts = [c.split("|", 2)[2] for c in w.get("chosen", []) if c.startswith("T|")]
        for s in w.get("salient", []):
            if s["lexicon"] < 0.85 and not initialism(s["t"]):
                continue
            total += 1
            lines = [u for u in s["units"] if u["level"] != "stab"]
            if any(u["rank"] >= 0 for u in lines):
                ranked += 1
                chosen += any(s["t"] in t for t in texts)
                continue
            if not lines:
                reasons["no line unit" if not s["units"] else "stab only"] += 1
                continue
            why = set()
            for u in lines:
                why.add("rejected:" + u["rejected"] if u["rejected"] else
                        "longer than 4 s" if u["sec"] > 4.0 else "shorter than 0.7 s" if u["sec"] < 0.7 else
                        "under 3 nuclei" if u["nuclei"] < 3 else "too quiet" if u["sound"] < 0.12 else "other")
            reasons[" | ".join(sorted(why))] += 1
    out["salientWords"] = {"inWindows": total, "inRankedLine": ranked, "inChosenLine": chosen,
                           "unrankedReasons": dict(reasons.most_common())}
    out["strikingPassedOver"] = striking_passed_over(hits, windows)
    out["spellFigureLoops"] = spell_figures(hits)
    out["windows"] = len(windows)
    out["transcribed"] = sum(w["transcribed"] for w in windows)
    out["transcribeMs"] = [round(q) for q in statistics.quantiles([w["transcribeMs"] for w in windows if w["transcribed"]], n=10)] \
        if sum(w["transcribed"] for w in windows) > 10 else None
    out["corpus"] = CORPUS[-1] if len(CORPUS) == 1 else {}
    out["attempts"] = ATTEMPTS
    out["windowOutcomes"] = [{k: w.get(k) for k in ("film", "chunk", "offset", "decode", "decodedFrames", "sampleRate", "playbackOutcome", "nativeRMSdB", "reason", "windows", "renderOutcomes", "speechWindows", "model", "transcriptOutcome", "transcriptWords", "transcriptLocale", "transcriptModelVersion", "transcribed")} for w in windows]
    return out


def render_coverage(hits):
    return dict(planned=len(hits), rendered=sum(x.get("rendered") is True for x in hits),
                audible=sum(x.get("renderAudible") is True for x in hits),
                onsetEligible=sum(x.get("onsetEligible") is True for x in hits),
                onsetDetected=sum(x.get("onsetEligible") is True and x.get("onsetStatus") == "detected" for x in hits))


def reheard_table(hits):
    """Denominator: sampled rendered snippets, separated by mode, content and whole-piece status.
    Recognition is an exact normalized token match; controls retain their own rows.
    """
    rows = collections.defaultdict(lambda: [0, 0, 0])
    for x in hits:
        if "snippet" not in x or x.get("renderAudible") is not True:
            continue
        main = max(heard(x), key=lambda w: w["cov"], default=None)
        content = bool(main and not main.get("fn") and main["cov"] >= .9 and x["kind"] == "piece")
        identity = "control" if x.get("control") else "wholeContent" if content else "other"
        key = f"{x['mode']}/{identity}/{x['kind']}/{x['gateEnd']}"
        rows[key][0] += 1
        rows[key][1] += bool(x.get("reheard"))
        tokens = {norm(t) for t in re.findall(r"[^\W_]+(?:['’][^\W_]+)*", x.get("reheard", ""))}
        rows[key][2] += bool(main and norm(main["t"]) in tokens)
    return {k: {"n": v[0], "anything": v[1], "mainWord": v[2]} for k, v in sorted(rows.items())}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    hits, windows, snippets = load(sys.argv[1])
    out = Path(sys.argv[2])
    bugs = out / "bugs"
    bugs.mkdir(parents=True, exist_ok=True)
    written = 0
    corrupt = []
    for name, data in snippets.items():
        if data == "file":
            continue
        # The test host's own log output can interleave with a long line: keep only an intact WAV.
        run = re.match(r"[A-Za-z0-9+/=]*", data).group(0)
        try:
            wav = base64.b64decode(run + "=" * (-len(run) % 4))
        except ValueError:
            corrupt.append(name)
            continue
        if len(wav) < 44 or wav[:4] != b"RIFF" or int.from_bytes(wav[4:8], "little") + 8 != len(wav):
            corrupt.append(name)
            continue
        (bugs / name).write_bytes(wav)
        written += 1
    rows = ["name\tfilm\tmode\tkind\tgateEnd\tgate\tdur\tcategory\tmechanism\tfragment\theard(cov)\treheard\tpreDB\ttailDB\tpostDB\tline"]
    for x in hits:
        if "snippet" not in x:
            continue
        c, m = classify(x)
        rows.append("\t".join(str(v) for v in [
            x["snippet"], x["film"], x["mode"], x["kind"], x["gateEnd"], x["gate"], x["dur"],
            "control" if x.get("control") else c, ",".join(m) or "-", x["ftext"],
            " ".join(f"{w['t']}({w['cov']})" for w in x["words"]), x.get("reheard", ""),
            x["preDB"], x["tailDB"], x["postDB"], x["line"]]))
    (bugs / "index.tsv").write_text("\n".join(rows) + "\n")
    summary = metrics(hits, windows)
    summary["footage"] = FOOTAGE
    summary["auditions"] = AUDITIONS
    summary["reheard"] = reheard_table(hits)
    summary["snippetsWritten"] = written
    summary["snippetsCorrupt"] = corrupt
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    if "--json" in sys.argv:
        print(json.dumps(summary))
    else:
        for mode in ("T", "A"):
            if mode in summary and summary[mode]["plays"] > 0:
                m = summary[mode]
                print(f"[{mode}] plays {m['plays']} functionOnly {m['functionOnly']} audiblePartial {m['audiblePartial']} "
                      f"accidental {m['categories'].get('accidental', 0)} half {m['categories'].get('half', 0)} "
                      f"salientHeard {m['salientHeard']} salientWhole {m['salientWhole']} lineInterestMedian {m['lineInterestMedian']}")
                print(f"     mechanisms {m['accidentalMechanisms']}")
                print(f"     splits {m['splitChecks']} tightness {m['tightness']}")
                print(f"     variety {m['variety']}")
        print(f"salient words {summary['salientWords']} strikingPassedOver {summary['strikingPassedOver']}")
        print(f"wrote {written} WAVs and index.tsv to {bugs}; summary.json in {out}")


if __name__ == "__main__":
    main()
