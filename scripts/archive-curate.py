#!/usr/bin/env python3
"""archive-curate.py: build the bundled seed list of Internet Archive footage (docs/plans/archive-video.md 1.4).

Runs the same queries as Liminal/Archive/ArchiveCatalog.swift against advancedsearch.php (sequential,
2 s apart, generic User-Agent, no key), applies the same client-side filters (years 1950-1969, black and
white unless the query allows colour, the exclusion terms), and prints the survivors' titles for a human
pass. With --write it stores them as Liminal/Archive/archive-seeds.json.

    python3 scripts/archive-curate.py [--rows 100] [--write] [--save-raw DIR]

--save-raw keeps each raw JSON response (one is trimmed into the unit-test fixture); --from-raw DIR
re-filters saved responses without any request.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEEDS = os.path.join(ROOT, "Liminal", "Archive", "archive-seeds.json")

# Mirror of ArchiveCatalog.queries / exclusions (keep in step).
QUERIES = [
    ("newsreel", 'collection:prelinger AND (newsreel OR "news magazine" OR telenews OR "screen magazine")', False),
    ("trippy", 'collection:prelinger AND (abstract OR experimental OR kaleidoscope OR optical OR hypnosis OR dream OR surreal)', True),
    ("educational", 'collection:prelinger AND subject:(animation OR cartoon OR "visual effects" OR psychology OR science OR future)', False),
    ("spaceage", 'collection:prelinger AND (rocket OR satellite OR "outer space" OR computer OR electronic OR television)', True),
    ("bw", 'collection:prelinger AND color:"B&W"', False),
]
EXCLUDE = ["war", "bomb", "casualty", "casualties", "surgery", "operation", "disease", "nazi", "hitler",
           "execution", "biological", "venereal", "accident", "crash", "autopsy", "civil defense",
           "propaganda", "korea", "vietnam", "fallout", "radiation", "germ", "hygiene", "birth", "death",
           "funeral", "fire", "riot", "flicker", "strobe", "murder", "kidnapping", "revolt", "strike",
           "hospital", "mental", "police", "crime", "protest", "ammunition", "atom", "atomic", "nuclear",
           "gun", "prison", "drug", "narcotic", "alcohol", "seale", "panther", "puberty", "adolescence", "sex",
           "larynx", "campaign", "debate", "nixon", "nixons", "eisenhower", "kennedy", "candidacy", "miss america",
           "dew line", "turmoil"]


def full_query(q):
    terms = " OR ".join('"%s"' % t if " " in t else t for t in EXCLUDE)
    return "(%s) AND mediatype:movies AND year:[1950 TO 1969] AND NOT (%s)" % (q, terms)


def excluded(text):
    t = text.lower()
    return any(re.search(r"\b%s\b" % re.escape(w), t) for w in EXCLUDE)


def is_bw(color):
    if color is None:
        return None
    c = (color if isinstance(color, str) else " ".join(color)).lower().replace(" ", "")
    if "b&w" in c or "bw" == c or "black" in c:
        return True
    if c.startswith("c") or "color" in c or "colour" in c:
        return False
    return None


def search(q, rows):
    params = [("q", full_query(q)), ("rows", str(rows)), ("page", "1"), ("output", "json"), ("sort[]", "downloads desc")]
    for f in ["identifier", "title", "year", "sound", "color", "licenseurl", "runtime"]:
        params.append(("fl[]", f))
    url = "https://archive.org/advancedsearch.php?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "Liminal/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=100)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--save-raw")
    ap.add_argument("--from-raw", help="re-filter responses saved by --save-raw (no requests)")
    a = ap.parse_args()
    seeds, seen = [], set()
    for i, (name, q, allow_colour) in enumerate(QUERIES):
        if a.from_raw:
            with open(os.path.join(a.from_raw, "search-%s.json" % name)) as f:
                data = json.load(f)
        else:
            if i:
                time.sleep(2)
            data = search(q, a.rows)
        if a.save_raw:
            os.makedirs(a.save_raw, exist_ok=True)
            with open(os.path.join(a.save_raw, "search-%s.json" % name), "w") as f:
                json.dump(data, f)
        docs = data.get("response", {}).get("docs", [])
        kept = 0
        for d in docs:
            ident = d.get("identifier")
            title = d.get("title") or ""
            if isinstance(title, list):
                title = " ".join(title)
            year = d.get("year")
            try:
                year = int(str(year if not isinstance(year, list) else year[0])[:4])
            except (TypeError, ValueError):
                year = None
            if not ident or ident in seen or year is None or not (1950 <= year <= 1969):
                continue
            if excluded(title):
                continue
            bw = is_bw(d.get("color"))
            if bw is False and not allow_colour:
                continue
            seen.add(ident)
            kept += 1
            seeds.append({"id": ident, "title": title.strip(), "year": year, "query": name,
                          "color": bw is False})
            print("%-10s %4d %s  %-40s %s" % (name, year, "C " if bw is False else "BW", ident[:40], title[:70]))
        print("# %s: %d docs, %d kept (numFound %s)" % (name, len(docs), kept,
                                                       data.get("response", {}).get("numFound")), file=sys.stderr)
    print("# total %d seeds" % len(seeds), file=sys.stderr)
    if a.write:
        with open(SEEDS, "w") as f:
            json.dump({"source": "scripts/archive-curate.py", "collection": "prelinger",
                       "seeds": seeds}, f, indent=1, ensure_ascii=False)
            f.write("\n")
        print("# wrote %s" % SEEDS, file=sys.stderr)


if __name__ == "__main__":
    main()
