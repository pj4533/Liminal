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
    for line in open(path, errors="replace"):
        if line.startswith("SALIENCE-HIT "):
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
    return [w for w in x["words"] if w["cov"] >= 0.3]


def initialism(t):
    letters = "".join(c for c in t if c.isalpha())
    return 2 <= len(letters) <= 5 and letters.isupper()


def classify(x):
    s = x.get("startIn") if "startIn" in x and aud_start(x) else None
    e = x.get("endIn") if "endIn" in x and aud_end(x) else None
    if not s and not e:
        return "clean", []
    if x["kind"] == "half":
        return "half", []
    if x["stutter"]:
        return "stutter", []
    mechs = []
    for edge, side in ((s, "start"), (e, "end")):
        if edge:
            mechs.append(f"{side}:{edge['mech']}" + (":dropped" if edge["drop"] else ""))
    return "accidental", mechs


def norm(t):
    return "".join(c for c in t.lower() if c.isalnum())


def metrics(hits, windows):
    out = {}
    for mode in sorted({h["mode"] for h in hits}):
        h = [x for x in hits if x["mode"] == mode]
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
            "plays": n,
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
            "audiblePartial": round((cats["half"] + cats["accidental"] + cats["stutter"]) / n, 3),
            "accidentalMechanisms": dict(mechs.most_common()),
            "halfLetterSplits": sum(1 for x in h if x["kind"] == "half" and (x["ftext"].endswith("-") or x["ftext"].startswith("-"))),
            "loops": len(loops),
            "untextedLines": sum(1 for v in loops.values() if v[0] == "-"),
            "lineInterestMedian": round(statistics.median(ints), 3) if ints else None,
            "lineInterestAtLeast0.6": round(sum(i >= 0.6 for i in ints) / len(ints), 3) if ints else None,
        }
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
    out["windows"] = len(windows)
    out["transcribed"] = sum(w["transcribed"] for w in windows)
    out["transcribeMs"] = [round(q) for q in statistics.quantiles([w["transcribeMs"] for w in windows if w["transcribed"]], n=10)] \
        if sum(w["transcribed"] for w in windows) > 10 else None
    return out


def reheard_table(hits):
    rows = collections.defaultdict(lambda: [0, 0, 0])
    for x in hits:
        if "snippet" not in x:
            continue
        c, _ = classify(x)
        key = "control" if x.get("control") else f"{x['kind']}/{x['gateEnd']}/{c}"
        main = max(heard(x), key=lambda w: w["cov"], default=None)
        rows[key][0] += 1
        rows[key][1] += bool(x.get("reheard"))
        if main and x.get("reheard") and norm(main["t"])[:4] in norm(x["reheard"]):
            rows[key][2] += 1
    return {k: {"n": v[0], "anything": v[1], "mainWord": v[2]} for k, v in sorted(rows.items(), key=lambda kv: -kv[1][0])}


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
    summary["reheard"] = reheard_table(hits)
    summary["snippetsWritten"] = written
    summary["snippetsCorrupt"] = corrupt
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    if "--json" in sys.argv:
        print(json.dumps(summary))
    else:
        for mode in ("T", "A"):
            if mode in summary:
                m = summary[mode]
                print(f"[{mode}] plays {m['plays']} functionOnly {m['functionOnly']} audiblePartial {m['audiblePartial']} "
                      f"accidental {m['categories'].get('accidental', 0)} half {m['categories'].get('half', 0)} "
                      f"salientHeard {m['salientHeard']} salientWhole {m['salientWhole']} lineInterestMedian {m['lineInterestMedian']}")
                print(f"     mechanisms {m['accidentalMechanisms']}")
        print(f"salient words {summary['salientWords']}")
        print(f"wrote {written} WAVs and index.tsv to {bugs}; summary.json in {out}")


if __name__ == "__main__":
    main()
