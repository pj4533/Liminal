#!/usr/bin/env python3
"""archive-curate.py: build the bundled seed list of Internet Archive footage (docs/plans/archive-video.md 1.4).

Runs the same queries as Liminal/Archive/ArchiveCatalog.swift against advancedsearch.php (sequential,
2 s apart, generic User-Agent, no key), applies the same client-side filters (years 1950-1969, black and
white unless the query allows colour, the exclusion terms), and prints the survivors' titles for a human
pass. With --write it stores them as Liminal/Archive/archive-seeds.json.

    python3 scripts/archive-curate.py [--rows 100] [--only NAME[,NAME]] [--write [--merge]] [--save-raw DIR]
    python3 scripts/archive-curate.py --print-urls [--only NAME[,NAME]]

--only runs just the named routes. --merge (with --write) keeps every seed already in the file and
appends the new unique ids after them. --print-urls prints each route's full request URL (every
exclusion included) and makes no request.

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
    ("drug-education", 'collection:prelinger AND (title:("drug abuse" OR "drug addiction" OR "drug education" OR narcotics OR marijuana OR marihuana OR LSD OR hallucinogens) OR subject:("drug abuse" OR "drug addiction" OR "drug education" OR "drug prevention" OR marijuana OR LSD))', True),
    ("trippy", 'collection:prelinger AND (psychedelic OR psychedelia OR kaleidoscope OR surreal OR hypnosis OR "light show" OR "optical illusion" OR "abstract film" OR "experimental film" OR "dream sequence")', True),
    ("newsreel", 'collection:prelinger AND (newsreel OR "news magazine" OR telenews OR "screen magazine")', False),
    ("educational", 'collection:prelinger AND subject:(animation OR cartoon OR "visual effects" OR psychology OR science OR future)', False),
    ("spaceage", 'collection:prelinger AND (rocket OR satellite OR "outer space" OR computer OR electronic OR television)', True),
    ("bw", 'collection:prelinger AND color:"B&W"', False),
    # Interest routes (docs/decisions/archive-video.md A32).
    ("machines", 'collection:prelinger AND (computer OR cybernetics OR "magnetic tape" OR "data processing" OR "electronic brain" OR "analog computer")', True),
    ("perception", 'collection:prelinger AND (perception OR "optical illusion" OR consciousness)', True),
    ("recording", 'collection:prelinger AND ("sound recording" OR phonograph OR jukebox OR "magnetic recording" OR "radio broadcasting" OR "record player")', True),
    ("ecosystems", 'collection:prelinger AND (microscope OR pond OR astronomy OR microscopy OR "plant growth" OR "time lapse" OR "water surface")', True),
    ("nightcity", 'collection:prelinger AND ("city lights" OR subway OR "elevated railway" OR "urban transportation" OR "neon sign")', True),
]
EXCLUDE = ["war", "bomb", "casualty", "casualties", "surgery", "operation", "disease", "nazi", "hitler",
           "execution", "biological", "venereal", "accident", "crash", "autopsy", "civil defense",
           "propaganda", "korea", "vietnam", "fallout", "radiation", "germ", "hygiene", "birth", "death",
           "funeral", "fire", "riot", "flicker", "strobe", "murder", "kidnapping", "revolt", "strike",
           "hospital", "mental", "police", "crime", "protest", "ammunition", "atom", "atomic", "nuclear",
           "gun", "prison", "drug", "narcotic", "alcohol", "seale", "panther", "puberty", "adolescence", "sex",
           "larynx", "campaign", "debate", "nixon", "nixons", "eisenhower", "kennedy", "candidacy", "miss america",
           "dew line", "turmoil", "medical", "medicine", "quack", "quacks", "patient"]


def exclusions(name):
    exceptions = {"drug", "narcotic", "alcohol"} if name == "drug-education" else set()
    return [term for term in EXCLUDE if term not in exceptions]


def full_query(q, name):
    terms = " OR ".join('"%s"' % t if " " in t else t for t in exclusions(name))
    return "(%s) AND mediatype:movies AND year:[1950 TO 1969] AND NOT (%s)" % (q, terms)


def excluded(text, name):
    t = text.lower()
    return any(re.search(r"\b%s\b" % re.escape(w), t) for w in exclusions(name))


def is_bw(color):
    if color is None:
        return None
    c = (color if isinstance(color, str) else " ".join(color)).lower().replace(" ", "")
    if "b&w" in c or "bw" == c or "black" in c:
        return True
    if c.startswith("c") or "color" in c or "colour" in c:
        return False
    return None


def search_url(q, rows, name):
    params = [("q", full_query(q, name)), ("rows", str(rows)), ("page", "1"), ("output", "json"), ("sort[]", "downloads desc")]
    for f in ["identifier", "title", "year", "sound", "color", "licenseurl", "runtime"]:
        params.append(("fl[]", f))
    return "https://archive.org/advancedsearch.php?" + urllib.parse.urlencode(params)


def search(q, rows, name):
    url = search_url(q, rows, name)
    req = urllib.request.Request(url, headers={"User-Agent": "Liminal/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=100)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--save-raw")
    ap.add_argument("--from-raw", help="re-filter responses saved by --save-raw (no requests)")
    ap.add_argument("--only", help="comma-separated route names to run (default: all)")
    ap.add_argument("--merge", action="store_true", help="with --write: keep existing seeds, append new ids")
    ap.add_argument("--print-urls", action="store_true", help="print the full request URLs, no requests")
    a = ap.parse_args()
    routes = QUERIES
    if a.only:
        wanted = [n.strip() for n in a.only.split(",") if n.strip()]
        unknown = [n for n in wanted if n not in [r[0] for r in QUERIES]]
        if unknown:
            sys.exit("unknown route(s): %s" % ", ".join(unknown))
        routes = [r for r in QUERIES if r[0] in wanted]
    if a.print_urls:
        for name, q, _ in routes:
            print("# %s" % name)
            print(search_url(q, a.rows, name))
        return
    seeds, seen = [], set()
    existing = []
    if a.merge:
        with open(SEEDS) as f:
            existing = json.load(f).get("seeds", [])
        seen = {s["id"] for s in existing}
    for i, (name, q, allow_colour) in enumerate(routes):
        if a.from_raw:
            with open(os.path.join(a.from_raw, "search-%s.json" % name)) as f:
                data = json.load(f)
        else:
            if i:
                time.sleep(2)
            data = search(q, a.rows, name)
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
            if excluded(title, name):
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
    print("# total %d new seeds" % len(seeds), file=sys.stderr)
    if a.merge:
        seeds = existing + seeds
        print("# merged: %d existing + new = %d" % (len(existing), len(seeds)), file=sys.stderr)
    if a.write:
        with open(SEEDS, "w") as f:
            json.dump({"source": "scripts/archive-curate.py", "collection": "prelinger",
                       "seeds": seeds}, f, indent=1, ensure_ascii=False)
            f.write("\n")
        print("# wrote %s" % SEEDS, file=sys.stderr)


if __name__ == "__main__":
    main()
