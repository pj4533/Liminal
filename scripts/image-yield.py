#!/usr/bin/env python3
"""Per-source and per-query yield of a curated-picture run (docs/decisions/images.md D130).

Reads a Liminal log (a `log stream --level info --predicate 'subsystem == "com.saygoodnight.Liminal"'`
capture, or any text holding the feed's lines) and prints, per source and per query:
requests, raw hits, new candidates, attempted, rejected by stage and reason, admitted (stored),
shown, the admission rate, and the admitted item URLs for review. It also prints the share of
admitted and of shown pictures that came from priority sources (the interest packs), read from
the bundled image-collections.json.

    python3 scripts/image-yield.py run.log [--json out.json] [--collections path] [--urls]

Standard library only. The feed lines it reads (CuratedImageFeed):
    [API] <source> <query key>: N results, M new          (a search page; "pinned" for the pin list)
    API image stored: source=S item=I query="Q" size=...  url=U
    API image rejected: source=S item=I query="Q" stage=T reason=R
    API image shown: source=S item=I title=...  url=U
    [API] preview <source>: requests= hits= new= attempted= rejected= stored= priority=
"""

import argparse
import collections
import json
import os
import re
import sys

REQUEST = re.compile(r"\[API\] (\S+) (.+?): (\d+) results, (\d+) new\s*$")
STORED = re.compile(r'API image stored: source=(\S+) item=(.*?) query="(.*?)" size=(\S+) .*? url=(\S+)\s*$')
REJECTED = re.compile(r'API image rejected: source=(\S+) item=(.*?) query="(.*?)" stage=(\S+) reason=(.*?)\s*$')
SHOWN = re.compile(r"API image shown: source=(\S+) item=(.*?) title=.* url=(\S+)\s*$")
PREVIEW = re.compile(r"\[API\] preview (\S+): (requests=.*)$")
DONE = re.compile(r"\[API\] preview done \((.*?)\)")


def default_collections():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "Liminal", "Visual", "ImageSources", "image-collections.json")


def query_label(key):
    """'q:radio studio||||' -> 'radio studio'; 'q:pond|Painting||1960|1980' -> 'pond [Painting 1960-1980]'."""
    if key == "pinned":
        return "pinned"
    if key.startswith("cat:"):
        return "category " + key[4:]
    if key.startswith("q:"):
        parts = key[2:].split("|")
        q, extra = parts[0], [p for p in parts[1:3] if p]
        if len(parts) >= 5 and (parts[3] or parts[4]):
            extra.append(f"{parts[3]}-{parts[4]}")
        return q + (f" [{' '.join(extra)}]" if extra else "")
    return key


def new_query():
    return {"requests": 0, "hits": 0, "fresh": 0, "attempted": 0, "rejected": 0, "stored": 0, "shown": 0,
            "stages": collections.Counter(), "reasons": collections.Counter(), "admitted": []}


def short_reason(reason):
    # Group "declared 1200x800 too small ..." and "duplicate of loc:123" style reasons.
    r = re.sub(r"\d+x\d+", "WxH", reason)
    r = re.sub(r"duplicate of \S+", "duplicate", r)
    r = re.sub(r"title rejected: .*", "title rejected", r)
    r = re.sub(r"\d+(\.\d+)?%", "N%", r)
    r = re.sub(r"\d+ bytes", "N bytes", r)
    return r[:70]


def parse(lines):
    stats = collections.defaultdict(lambda: collections.defaultdict(new_query))
    item_query = {}
    shown = []
    previews = {}
    done = None
    for line in lines:
        m = STORED.search(line)
        if m:
            src, item, q, size, url = m.groups()
            s = stats[src][q]
            s["attempted"] += 1
            s["stored"] += 1
            s["admitted"].append({"item": item, "size": size, "url": url})
            item_query[(src, item)] = q
            continue
        m = REJECTED.search(line)
        if m:
            src, item, q, stage, reason = m.groups()
            s = stats[src][q]
            s["attempted"] += 1
            s["rejected"] += 1
            s["stages"][stage] += 1
            s["reasons"][f"{stage}: {short_reason(reason)}"] += 1
            continue
        m = SHOWN.search(line)
        if m:
            src, item, url = m.groups()
            shown.append((src, item))
            q = item_query.get((src, item))
            if q is not None:
                stats[src][q]["shown"] += 1
            continue
        m = PREVIEW.search(line)
        if m:
            previews[m.group(1)] = dict(kv.split("=", 1) for kv in m.group(2).split())
            continue
        m = DONE.search(line)
        if m:
            done = m.group(1)
            continue
        m = REQUEST.search(line)
        if m and "preview" not in line:
            src, key, n, fresh = m.groups()
            s = stats[src][key]
            s["requests"] += 1
            s["hits"] += int(n)
            s["fresh"] += int(fresh)
    return stats, shown, previews, done


def load_priority(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(f"warning: cannot read {path}: {e}", file=sys.stderr)
        return set(), {}
    pri = {s["id"] for s in data.get("sources", []) if s.get("priority")}
    weights = {s["id"]: s.get("weight") for s in data.get("sources", [])}
    return pri, weights


def rate(stored, attempted):
    return f"{stored / attempted:.0%}" if attempted else "-"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log")
    ap.add_argument("--json", help="write the numbers to this file")
    ap.add_argument("--collections", default=default_collections(), help="image-collections.json for priority ids")
    ap.add_argument("--urls", action="store_true", help="list every admitted item URL")
    args = ap.parse_args()

    with open(args.log, encoding="utf-8", errors="replace") as f:
        stats, shown, previews, done = parse(f)
    priority, weights = load_priority(args.collections)

    totals = {}
    print(f"{'source / query':58} {'req':>4} {'hits':>5} {'new':>5} {'try':>4} {'rej':>4} {'adm':>4} {'shown':>5} {'rate':>5}")
    for src in sorted(stats, key=lambda s: (s not in priority, s)):
        t = new_query()
        for q, s in stats[src].items():
            for k in ("requests", "hits", "fresh", "attempted", "rejected", "stored", "shown"):
                t[k] += s[k]
            t["stages"].update(s["stages"])
            t["reasons"].update(s["reasons"])
            t["admitted"] += s["admitted"]
        totals[src] = t
        tag = " *" if src in priority else ""
        w = weights.get(src)
        head = f"{src}{tag} (w{w:g})" if isinstance(w, (int, float)) else f"{src}{tag}"
        print(f"{head:58} {t['requests']:>4} {t['hits']:>5} {t['fresh']:>5} {t['attempted']:>4} {t['rejected']:>4} "
              f"{t['stored']:>4} {t['shown']:>5} {rate(t['stored'], t['attempted']):>5}")
        for q in sorted(stats[src], key=lambda k: query_label(k)):
            s = stats[src][q]
            print(f"  {query_label(q)[:56]:56} {s['requests']:>4} {s['hits']:>5} {s['fresh']:>5} {s['attempted']:>4} "
                  f"{s['rejected']:>4} {s['stored']:>4} {s['shown']:>5} {rate(s['stored'], s['attempted']):>5}")
        if t["stages"]:
            print("    rejected by stage: " + ", ".join(f"{k} {v}" for k, v in t["stages"].most_common()))
            print("    top reasons: " + "; ".join(f"{k} ({v})" for k, v in t["reasons"].most_common(4)))
        if args.urls:
            for a in t["admitted"]:
                print(f"    + {a['item']}  {a['size']}  {a['url']}")

    stored_all = sum(t["stored"] for t in totals.values())
    stored_pri = sum(t["stored"] for s, t in totals.items() if s in priority)
    shown_pri = sum(1 for s, _ in shown if s in priority)
    print()
    print(f"admitted: {stored_all}, from priority sources: {stored_pri}"
          + (f" ({stored_pri / stored_all:.1%})" if stored_all else ""))
    print(f"shown: {len(shown)}, from priority sources: {shown_pri}"
          + (f" ({shown_pri / len(shown):.1%})" if shown else ""))
    if previews:
        print(f"preview summary lines: {len(previews)}" + (f", done: {done}" if done else ", no 'preview done' line"))

    if args.json:
        out = {
            "sources": {src: {"priority": src in priority, "weight": weights.get(src),
                              **{k: t[k] for k in ("requests", "hits", "fresh", "attempted", "rejected", "stored", "shown")},
                              "stages": dict(t["stages"]), "reasons": dict(t["reasons"]), "admitted": t["admitted"],
                              "queries": {query_label(q): {k: (dict(v) if isinstance(v, collections.Counter) else v)
                                                           for k, v in s.items()} for q, s in stats[src].items()}}
                        for src, t in totals.items()},
            "admitted": stored_all, "admittedPriority": stored_pri,
            "shown": len(shown), "shownPriority": shown_pri,
            "previews": previews, "previewDone": done,
        }
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)


if __name__ == "__main__":
    main()
