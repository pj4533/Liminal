"""M15 chop cadence from the scheduled events, the plan log and stage timings."""

import numpy as np


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
        d = int(c.get("durationFrames") or 0)
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

    # 4-bar block fingerprints and identical consecutive blocks
    by_block = {}
    for e in ev:
        by_block.setdefault(window_index(e["frame"], block), []).append(e)
    sixteenth = cap.beat_frames / 4
    block_fp = {b: sorted((e["key"], int(round((e["frame"] - b * block) / sixteenth))) for e in evs)
                for b, evs in by_block.items()}
    repeats = set()
    for plan in cap.diagnostics.get("dialoguePlans") or []:
        for blk in plan.get("blocks", []):
            if blk.get("variation") == "repeat" and blk.get("phrase") is not None:
                repeats.add(int(blk["phrase"]))
    identical = [b for b in sorted(block_fp) if b - 1 in block_fp and block_fp[b] == block_fp[b - 1]
                 and block_fp[b] and b not in repeats]
    out["identicalConsecutiveBlocks"] = identical
    out["blocksWithDialogue"] = len(block_fp)

    # Family or bank run length from the plan log, else 8-bar fingerprint differences
    labels = {}
    for plan in cap.diagnostics.get("dialoguePlans") or []:
        for blk in plan.get("blocks", []):
            if blk.get("phrase") is not None and blk.get("family") is not None:
                labels[int(blk["phrase"])] = (blk.get("family"), plan.get("bankID"))
    if labels:
        seq = [labels[k] for k in sorted(labels)]
        longest = run = 1
        for a, b in zip(seq, seq[1:]):
            run = run + 1 if a == b else 1
            longest = max(longest, run)
        out["familyRunBars"] = {"source": "plan", "longestBars": longest * 4}
    else:
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
        boundary_hits.append({"boundary": w, "events": sum(1 for e in ev if edge - 2 * cap.beat_frames <= e["frame"] < edge)})
    out["eventsLastTwoBeats"] = boundary_hits

    overlaps = 0
    for a, b in zip(ev, ev[1:]):
        if b["frame"] < a["end"] - int(0.001 * rate):
            overlaps += 1
    out["dryOverlaps"] = overlaps

    timings = cap.manifest.get("dialogueTimings") or []
    totals = np.array([t["totalMs"] for t in timings if t.get("totalMs") is not None], dtype=float)
    if len(totals):
        out["stageTiming"] = {"count": int(len(totals)), "totalMsMean": float(totals.mean()),
                              "totalMsP95": float(np.percentile(totals, 95)), "totalMsMax": float(totals.max())}
        for stage in ("classifyMs", "analyzeMs", "bankMs", "planMs", "renderMs"):
            vals = [t[stage] for t in timings if t.get(stage) is not None]
            if vals:
                out["stageTiming"][stage + "Max"] = float(max(vals))
    leads = [(e["frame"] - int(e["raw"]["committedFrame"])) / rate for e in ev if e["raw"].get("committedFrame") is not None]
    if leads:
        out["leadSecondsMin"] = float(min(leads))

    # Hook statements: first two events of each 16-bar window must share pad and transform
    hooks = []
    if out["usedPadIDs"]:
        for w, evs in sorted(by_w16.items()):
            first = sorted(evs, key=lambda e: e["frame"])[:2]
            if len(first) == 2:
                hooks.append(bool(first[0]["key"][:3] == first[1]["key"][:3]))
        out["hookSamePad"] = hooks

    # Accent distance from kick attacks
    accents = [int(e["raw"]["accentFrame"]) for e in ev if e["raw"].get("accentFrame") is not None]
    kicks = np.array(cap.kick_attack_frames(), dtype=float)
    if accents and len(kicks):
        dist = np.array([np.min(np.abs(kicks - a)) for a in accents]) / rate * 1000
        out["accentKickDistanceMsP10"] = float(np.percentile(dist, 10))
        out["accentsAtLeast50msFraction"] = float((dist >= 50).mean())
        out["accents"] = len(accents)
    return out
