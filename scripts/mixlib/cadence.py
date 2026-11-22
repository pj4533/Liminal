"""M15 chop cadence from the scheduled events, the plan log and stage timings."""

import numpy as np

from .audio import chop_duration_frames

FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK64 = (1 << 64) - 1
# DialogueFamily.allCases order: the grammar's families, then the motif cells (wave 4 `chop-motif`).
FAMILY_IDS = {"anchor": 0, "echo": 1, "callResponse": 2, "sparseReorder": 3, "textureFill": 4, "rest": 5,
              "statement": 6, "stutter": 7, "splitPause": 8, "reorder": 9, "callAnswer": 10, "sparse": 11,
              "returnOpen": 12, "turnaround": 13, "hook": 14,
              "intro": 15, "chopBeat": 16, "build": 17, "breakdown": 18, "outro": 19}


def fnv_add(h, x):
    """DialogueHash.add(UInt64): FNV-1a over the eight little-endian bytes."""
    x &= MASK64
    for i in range(8):
        h ^= (x >> (8 * i)) & 0xFF
        h = (h * FNV_PRIME) & MASK64
    return h


def block_fingerprint(family, elements):
    """DialoguePerformer.fingerprint: the family id then (padKey, slot) per element."""
    h = fnv_add(FNV_OFFSET, FAMILY_IDS.get(family, 99))
    for pad_key, slot in elements:
        h = fnv_add(h, int(pad_key))
        h = fnv_add(h, int(slot))
    return h


def _hex(v):
    try:
        return int(str(v), 16)
    except (TypeError, ValueError):
        return None


def plan_blocks(cap):
    """Logged blocks by phrase (the highest revision wins): family, bank, logged fingerprint and elements,
    and the scheduled events (from `dialogueChops`) recomputed into elements and a fingerprint."""
    chops_by_block = {}
    for c in cap.chops():
        if c.get("block") is not None and c.get("frame") is not None:
            chops_by_block.setdefault(int(c["block"]), []).append(c)
    blocks = {}
    for plan in cap.plans():
        pad_keys = {}
        for blk in plan.get("blocks", []):
            for e in blk.get("events", []):
                if e.get("padKey") is not None:
                    pad_keys[(e.get("padID"), e.get("transform"))] = _hex(e["padKey"])
        for blk in plan.get("blocks", []):
            if blk.get("phrase") is None:
                continue
            phrase = int(blk["phrase"])
            rev = plan.get("revision", 0)
            if phrase in blocks and blocks[phrase]["revision"] > rev:
                continue
            logged = [(_hex(e.get("padKey")), int(e.get("slot", 0))) for e in blk.get("events", [])]
            sched = sorted(chops_by_block.get(phrase, []), key=lambda c: c["frame"])
            recomputed, unresolved = [], 0
            for c in sched:
                key = pad_keys.get((c.get("padID"), c.get("transform")))
                if key is None:
                    unresolved += 1
                recomputed.append((key if key is not None else -1, int(c.get("slot", -1))))
            blocks[phrase] = {
                "phrase": phrase, "plan": plan, "revision": rev, "cue": plan.get("cue"),
                "family": blk.get("family"), "bank": plan.get("bankID"), "section": blk.get("section"),
                "change": blk.get("change"), "noDialogue": bool(blk.get("noDialogue")),
                "loggedFingerprint": _hex(blk.get("fingerprint")), "logged": logged,
                "events": blk.get("events", []), "scheduled": sched, "recomputed": recomputed,
                "unresolved": unresolved,
                "recomputedFingerprint": block_fingerprint(sched[0].get("family") if sched else blk.get("family"), recomputed),
            }
    return blocks


def fingerprint_agreement(cap, blocks):
    """Compare logged fingerprints and event lists with those recomputed from the scheduled events."""
    out, bad = {"blocksChecked": 0, "disagreements": []}, []
    rate = cap.rate
    for phrase, b in sorted(blocks.items()):
        if b["noDialogue"] and not b["scheduled"] and not b["logged"]:
            continue
        out["blocksChecked"] += 1
        reasons = []
        if b["unresolved"]:
            reasons.append(f"{b['unresolved']} scheduled events have a pad the log does not mention")
        if len(b["scheduled"]) != len(b["events"]):
            reasons.append(f"{len(b['scheduled'])} scheduled events against {len(b['events'])} logged")
        else:
            for c, e in zip(b["scheduled"], b["events"]):
                if abs(c["frame"] / rate - float(e.get("startTime", 0.0))) > 0.002:
                    reasons.append(f"event start {c['frame'] / rate:.3f} s against logged {e.get('startTime')} s")
                    break
        if b["logged"] != b["recomputed"]:
            reasons.append("pad key or slot sequence differs")
        elif b["loggedFingerprint"] is not None and b["loggedFingerprint"] != b["recomputedFingerprint"]:
            reasons.append(f"fingerprint {b['loggedFingerprint']:x} logged against {b['recomputedFingerprint']:x} recomputed")
        if reasons:
            bad.append({"phrase": phrase, "reasons": reasons})
    out["disagreements"] = bad
    return out


def window_elements(blocks, per_window, source="recomputed"):
    """Position-tagged elements per window of `per_window` blocks: (block in window, padKey, slot)."""
    wins = {}
    for phrase, b in blocks.items():
        if b["noDialogue"] and not b[source]:
            continue
        for pad_key, slot in b[source]:
            wins.setdefault(phrase // per_window, []).append((phrase % per_window, pad_key, slot))
    return wins


def window_difference(a, b):
    """The engine's `1 - |F(n) and F(n-1)| / max(|F(n)|, |F(n-1)|)` over multisets."""
    m = max(len(a), len(b))
    if m == 0:
        return 1.0
    counts = {}
    for e in a:
        counts[e] = counts.get(e, 0) + 1
    shared = 0
    for e in b:
        if counts.get(e, 0) > 0:
            counts[e] -= 1
            shared += 1
    return 1.0 - shared / m


def plan_cadence(cap):
    """C-D1 to C-D3 and C-D7 from the plan log, with the scheduled-event recomputation alongside."""
    blocks = plan_blocks(cap)
    if not blocks:
        return None
    per_window = max(1, int(round(cap.take_frames / cap.phrase_frames)))
    complete = int(cap.scored_frames / cap.take_frames + 1e-3)
    out = {"source": "plan", "blocks": len(blocks), "fingerprintAgreement": fingerprint_agreement(cap, blocks)}
    rec = window_elements(blocks, per_window, "recomputed")
    log = window_elements(blocks, per_window, "logged")
    diffs = []
    for w in sorted(rec):
        if w + 1 in rec and w + 1 < max(complete, 1) and w < max(complete, 1):
            d_rec = window_difference(rec[w], rec[w + 1])
            d_log = window_difference(log.get(w, []), log.get(w + 1, []))
            diffs.append({"from": w, "to": w + 1, "difference": d_rec, "loggedDifference": d_log,
                          "sizes": [len(rec[w]), len(rec[w + 1])]})
    out["window16Differences"] = diffs
    out["window16LoggedDisagreement"] = max((abs(d["difference"] - d["loggedDifference"]) for d in diffs), default=0.0)

    # Family or bank runs; a rest block (no dialogue) ends a run and does not count as one.
    run = longest = 0
    prev = None
    for phrase in sorted(blocks):
        b = blocks[phrase]
        if b["noDialogue"] or not b["scheduled"] and not b["logged"]:
            run, prev = 0, None
            continue
        label = (b["family"], b["bank"])
        run = run + 1 if prev == label and (phrase - 1) in blocks else 1
        prev = label
        longest = max(longest, run)
    out["familyRunBars"] = {"source": "plan", "longestBars": longest * int(round(cap.phrase_frames / cap.bar_frames)),
                            "families": sorted({b["family"] for b in blocks.values() if not b["noDialogue"]})}

    identical = []
    for phrase in sorted(blocks):
        a, b = blocks.get(phrase - 1), blocks[phrase]
        if a and a["recomputed"] and b["recomputed"] and a["recomputed"] == b["recomputed"] and b["change"] != "repeat":
            identical.append(phrase)
    out["identicalConsecutiveBlocks"] = identical
    out["blocksWithDialogue"] = sum(1 for b in blocks.values() if b["scheduled"])

    hooks = []
    for phrase in sorted(blocks):
        b = blocks[phrase]
        if b["family"] == "echo" and len(b["recomputed"]) >= 2:
            hooks.append(bool(b["recomputed"][0] == b["recomputed"][1]
                              and b["scheduled"][0].get("transform") == b["scheduled"][1].get("transform")))
    out["hookSamePad"] = hooks
    out["echoBlocks"] = len(hooks)
    return out


COMMIT_MARGIN = 0.30  # DialogueCueCoordinator.commitMargin
STAGES = ("decodeMs", "transcribeMs", "classifyMs", "analyzeMs", "bankMs", "planMs", "renderMs")
# Optional per-cue fields another package adds to dialogueTimings (tolerated when absent).
OPTIONAL_TIMING_FIELDS = ("thermalState", "residentMB", "cacheEntries", "cacheBytes")


def _pct(vals):
    v = np.asarray(vals, dtype=float)
    return {"p50": float(np.percentile(v, 50)), "p95": float(np.percentile(v, 95)), "max": float(v.max()),
            "mean": float(v.mean())}


def stage_timing(timings):
    """Per-cue stage totals (p50, p95, max) and each stage's spread, from manifest.dialogueTimings. The
    live-order wall time (`wallMs`, harness simulation of the scheduling lead) is summarised when present,
    and the optional thermal, memory and cache fields are passed through."""
    totals = [t["totalMs"] for t in timings if t.get("totalMs") is not None]
    if not totals:
        return None
    p = _pct(totals)
    out = {"count": len(totals), "totalMsMean": p["mean"], "totalMsP50": p["p50"], "totalMsP95": p["p95"], "totalMsMax": p["max"]}
    for stage in STAGES:
        vals = [t[stage] for t in timings if t.get(stage) is not None]
        if vals:
            q = _pct(vals)
            out[stage + "P50"], out[stage + "P95"], out[stage + "Max"] = q["p50"], q["p95"], q["max"]
    walls = [t["wallMs"] for t in timings if t.get("wallMs") is not None]
    if walls:
        q = _pct(walls)
        out["wallMsP50"], out["wallMsP95"], out["wallMsMax"] = q["p50"], q["p95"], q["max"]
    cue_leads = [t["leadSeconds"] for t in timings if t.get("leadSeconds") is not None]
    if cue_leads:
        out["cueLeadSecondsMin"] = float(min(cue_leads))
        out["cueLeadSecondsP50"] = float(np.percentile(cue_leads, 50))
    for key in OPTIONAL_TIMING_FIELDS:
        vals = [t[key] for t in timings if t.get(key) is not None]
        if not vals:
            continue
        if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in vals):
            out[key] = {"max": float(max(vals)), "last": float(vals[-1])}
        else:
            counts = {}
            for v in vals:
                counts[str(v)] = counts.get(str(v), 0) + 1
            out[key] = {"counts": counts, "last": str(vals[-1])}
    out["perCue"] = [{k: t.get(k) for k in ("cue", "totalMs", "wallMs", "analysisStartFrame", "committedFrame",
                                           "earliestStartFrame", "firstEventFrame", "leadSeconds", "liveLeadSeconds",
                                           "eventsUnderCommitMargin", "transcribeMs", "decodeMs") + OPTIONAL_TIMING_FIELDS
                      if t.get(k) is not None} for t in timings]
    return out


def lead_model(cap, timings):
    """How the capture set committedFrame: `live-order simulation` when the harness recorded the
    analysis start and wall times (fix1-C), else the older synchronous plan at the cue frame."""
    if any(t.get("analysisStartFrame") is not None for t in timings):
        return "live-order simulation: analysis starts the live scheduling lead before the bed; committed after measured wall time"
    if cap.chops() and any(c.get("committedFrame") is not None for c in cap.chops()):
        return "synchronous plan at the cue frame (committedFrame = cue frame; the lead floor holds by construction)"
    return None


def event_key(c):
    if c.get("padID") is not None:
        return ("pad", str(c.get("padID")), str(c.get("transform")), c.get("sourceStart"), c.get("sourceEnd"))
    return ("src", c.get("cue"), c.get("sourceStart"), c.get("sourceEnd"), c.get("speed"), c.get("reversed"))


def events_of(cap):
    out = []
    for c in cap.chops():
        if c.get("frame") is None:
            continue
        f = int(c["frame"])
        d = chop_duration_frames(c)
        out.append({"frame": f, "end": f + d, "key": event_key(c), "raw": c})
    return sorted(out, key=lambda e: e["frame"])


def fingerprint(events, cap, window_frames, block_frames):
    """Set of (block within window, key, sixteenth slot within block) for events starting in a window."""
    sixteenth = cap.beat_frames / 4
    items = set()
    for e in events:
        b = int(e["frame"] // block_frames)
        slot = int(round((e["frame"] - b * block_frames) / sixteenth))
        items.add((int(b % round(window_frames / block_frames)), e["key"], slot))
    return items


def difference(a, b):
    if not a and not b:
        return 0.0
    return 1.0 - len(a & b) / max(len(a), len(b))


def window_index(frame, size):
    return int(frame // size)


def measure_cadence(cap):
    ev = events_of(cap)
    if not ev:
        return {"skipped": "no dialogue"}
    rate = cap.rate
    block = cap.phrase_frames
    window16 = cap.take_frames
    window8 = cap.bar_frames * 8
    out = {"events": len(ev), "usedPadIDs": any(e["key"][0] == "pad" for e in ev)}
    plan = plan_cadence(cap)

    # 16-bar fingerprints
    by_w16 = {}
    for e in ev:
        by_w16.setdefault(window_index(e["frame"], window16), []).append(e)
    complete = int(cap.scored_frames / window16 + 1e-3)
    wins = sorted(w for w in by_w16 if w < max(complete, 1))
    diffs = []
    for w in wins:
        if w + 1 in by_w16 and w + 1 < max(complete, 1):
            a = fingerprint(by_w16[w], cap, window16, block)
            b = fingerprint(by_w16[w + 1], cap, window16, block)
            diffs.append({"from": w, "to": w + 1, "difference": difference(a, b), "sizes": [len(a), len(b)]})
    out["window16Differences"] = diffs
    out["window16DifferencesEventKeys"] = diffs

    # 4-bar block fingerprints and identical consecutive blocks
    by_block = {}
    for e in ev:
        by_block.setdefault(window_index(e["frame"], block), []).append(e)
    sixteenth = cap.beat_frames / 4
    block_fp = {b: sorted((e["key"], int(round((e["frame"] - b * block) / sixteenth))) for e in evs)
                for b, evs in by_block.items()}
    repeats = set()
    for logged_plan in cap.plans():
        for blk in logged_plan.get("blocks", []):
            if blk.get("change") == "repeat" and blk.get("phrase") is not None:
                repeats.add(int(blk["phrase"]))
    identical = [b for b in sorted(block_fp) if b - 1 in block_fp and block_fp[b] == block_fp[b - 1]
                 and block_fp[b] and b not in repeats]
    out["identicalConsecutiveBlocks"] = identical
    out["blocksWithDialogue"] = len(block_fp)

    # Family or bank run length from the plan log, else 8-bar fingerprint differences
    if not plan:
        by_w8 = {}
        for e in ev:
            by_w8.setdefault(window_index(e["frame"], window8), []).append(e)
        pairs = []
        for w in sorted(by_w8):
            if w + 1 in by_w8:
                a = {(e["key"], int(round((e["frame"] % window8) / sixteenth))) for e in by_w8[w]}
                b = {(e["key"], int(round((e["frame"] % window8) / sixteenth))) for e in by_w8[w + 1]}
                pairs.append(difference(a, b))
        out["familyRunBars"] = {"source": "fingerprint-8-bar", "minDifference": min(pairs) if pairs else None}

    if plan:
        out["plan"] = plan
        for key in ("window16Differences", "familyRunBars", "identicalConsecutiveBlocks", "blocksWithDialogue"):
            out[key] = plan[key]
        out["fingerprintAgreement"] = plan["fingerprintAgreement"]
        out["window16LoggedDisagreement"] = plan["window16LoggedDisagreement"]

    # Rests, occupancy and the last two beats before each 8-bar boundary
    scored_windows = int(cap.scored_frames / window8 + 1e-3)
    rests, occupancy = [], []
    for w in range(scored_windows):
        a, b = w * window8, (w + 1) * window8
        inside = [e for e in ev if e["end"] > a and e["frame"] < b]
        if not inside:
            continue
        bars_empty = 0
        for k in range(8):
            ba, bb = a + k * cap.bar_frames, a + (k + 1) * cap.bar_frames
            if not any(e["end"] > ba and e["frame"] < bb for e in inside):
                bars_empty += 1
        merged, cur = [], None
        for e in sorted(inside, key=lambda e: e["frame"]):
            s, t = max(e["frame"], a), min(e["end"], b)
            if cur and s <= cur[1]:
                cur[1] = max(cur[1], t)
            else:
                cur = [s, t]
                merged.append(cur)
        rests.append({"window": w, "emptyBars": bars_empty})
        occupancy.append({"window": w, "occupancy": float(sum(t - s for s, t in merged) / (b - a))})
    out["restsPer8Bars"] = rests
    out["occupancyPer8Bars"] = occupancy
    boundary_hits = []
    for w in range(1, scored_windows + 1):
        edge = w * window8
        a = edge - 2 * cap.beat_frames
        boundary_hits.append({"boundary": w,
                              "events": sum(1 for e in ev if a <= e["frame"] < edge),
                              "sounding": sum(1 for e in ev if e["end"] > a and e["frame"] < edge)})
    out["eventsLastTwoBeats"] = boundary_hits

    overlaps = 0
    for a, b in zip(ev, ev[1:]):
        if b["frame"] < a["end"] - int(0.001 * rate):
            overlaps += 1
    out["dryOverlaps"] = overlaps

    timings = cap.manifest.get("dialogueTimings") or []
    st = stage_timing(timings)
    if st:
        out["stageTiming"] = st
    leads = [(e["frame"] - int(e["raw"]["committedFrame"])) / rate for e in ev if e["raw"].get("committedFrame") is not None]
    if leads:
        out["leadSecondsMin"] = float(min(leads))
        out["leadSecondsP10"] = float(np.percentile(leads, 10))
        out["leadEvents"] = len(leads)
        out["eventsUnderCommitMargin"] = int(sum(1 for v in leads if v < COMMIT_MARGIN - 1e-6))
    out["leadModel"] = lead_model(cap, timings)

    # Hook statements: engine data (the repeated head of each echo block); without a plan log, the first
    # two events of each 16-bar window.
    if not plan and out["usedPadIDs"]:
        hooks = []
        for w, evs in sorted(by_w16.items()):
            first = sorted(evs, key=lambda e: e["frame"])[:2]
            if len(first) == 2:
                hooks.append(bool(first[0]["key"][:3] == first[1]["key"][:3]))
        out["hookSamePad"] = hooks
    elif plan:
        out["hookSamePad"] = plan["hookSamePad"]

    # Accent distance from confident kick attacks. Texture slices have no stressed accent.
    accent_events = [e for e in ev if e["raw"].get("accentFrame") is not None and e["raw"].get("role") != "texture"]
    accents = [int(e["raw"]["accentFrame"]) for e in accent_events]
    confident = cap.has_landmarks()
    kicks = np.array(cap.kick_attack_frames(min_confidence=0.5) if confident else cap.kick_attack_frames(), dtype=float)
    out["accentKickSource"] = "landmarks (confidence 0.5 or more)" if confident else "kickCandidates"
    if accents and len(kicks):
        dist = np.array([np.min(np.abs(kicks - a)) for a in accents]) / rate * 1000
        out["accentKickDistanceMsP10"] = float(np.percentile(dist, 10))
        out["accentsAtLeast50msFraction"] = float((dist >= 50).mean())
        out["accents"] = len(accents)
        # Chance level: the share of eighth-note grid points in the scored range that are 50 ms or more from
        # a kick. Accents placed on the grid without regard to the kicks would score about this.
        eighth = cap.beat_frames / 2
        grid = np.arange(0, cap.scored_frames, eighth)
        if len(grid):
            gd = np.array([np.min(np.abs(kicks - x)) for x in grid]) / rate * 1000
            out["eighthGridAtLeast50msFraction"] = float((gd >= 50).mean())
    motif = measure_motif(cap, ev)
    if motif:
        out["motif"] = motif
    return out


def measure_motif(cap, ev):
    """Motif mode (user direction of 19 November 2026, plan section 5): per complete 16-bar loop, the
    piece onsets per bar, full-line statements, the share of sub-line pieces, the cells heard and the
    occupancy. None when the plan log has no motif (the grammar's rest rules, C-D4, then apply)."""
    motifs = {}
    for plan in cap.plans():
        for m in [plan.get("motif")] + list(plan.get("motifs") or []):
            if m and m.get("loop") is not None:
                motifs[int(m["loop"])] = m
    if not motifs:
        return None
    loop_frames = cap.take_frames
    loops = []
    for w in range(int(cap.scored_frames / loop_frames + 1e-3)):
        a = w * loop_frames
        inside = [e for e in ev if a <= e["frame"] < a + loop_frames]
        onsets = [sum(1 for e in inside if a + k * cap.bar_frames <= e["frame"] < a + (k + 1) * cap.bar_frames) for k in range(16)]
        frags = {f["id"]: f for f in (motifs.get(w) or {}).get("fragments", [])}
        pieces = [e["raw"].get("piece") for e in inside if e["raw"].get("piece") is not None]
        sub = [bool(frags.get(p, {}).get("subLine")) for p in pieces]
        merged, cur = [], None
        for e in sorted(inside, key=lambda e: e["frame"]):
            s, t = e["frame"], min(e["end"], a + loop_frames)
            if cur and s <= cur[1]:
                cur[1] = max(cur[1], t)
            else:
                cur = [s, t]
                merged.append(cur)
        cells = sorted({e["raw"].get("cell") for e in inside if e["raw"].get("cell")})
        loops.append({"loop": w, "line": (motifs.get(w) or {}).get("line"), "onsetsPerBar": onsets,
                      "emptyBars": [k + 1 for k, n in enumerate(onsets) if n == 0],
                      "fullLine": sum(1 for p in pieces if p == 0),
                      "subLineShare": float(np.mean(sub)) if sub else None,
                      "occupancy": float(sum(t - s for s, t in merged) / loop_frames), "cells": cells})
    return {"loops": loops}
