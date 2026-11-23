"""M11 dialogue intelligibility proxies and M12 film bed."""

import numpy as np

from .audio import OCTAVE_CENTERS, SII_WEIGHTS, SECTION_ORDER, chop_duration_frames, db10
from .loudness import k_weighted
from .spectral import spectral_rolloff

MIN_CHOP_SECONDS = 0.5
# Every dry piece at least this long is scored too (stabs and stutters, not only featured lines).
MIN_PIECE_SECONDS = 0.12


def band_mean(grid, g, mask, lo, hi):
    p = ((g["PL"] + g["PR"]) * 0.5)[:, grid.sl(lo, hi)].sum(axis=1, dtype=np.float64)
    sel = p[mask[: len(p)]] if mask is not None else p
    return float(sel.mean()) if len(sel) else 0.0


def sii_proxy(snr_db):
    return float(sum(w * np.clip((s + 15) / 30, 0, 1) for w, s in zip(SII_WEIGHTS, snr_db)))


def octave_snr(grid, target, others, mask):
    """Octave-band SNR (dB) of `target` against the power sum of `others` over the masked hops."""
    out = []
    for c in OCTAVE_CENTERS:
        lo, hi = c / 2 ** 0.5, c * 2 ** 0.5
        t = band_mean(grid, target, mask, lo, hi)
        o = sum(band_mean(grid, g, mask, lo, hi) for g in others)
        out.append(float(db10(max(t, 1e-18)) - db10(max(o, 1e-18))))
    return out


def snr_1_to_4k(grid, target, others, mask):
    t = band_mean(grid, target, mask, 1000, 4000)
    o = sum(band_mean(grid, g, mask, 1000, 4000) for g in others)
    return float(db10(max(t, 1e-18)) - db10(max(o, 1e-18)))


def segment_lufs(sig, rate, a, b):
    pre = int(0.5 * rate)
    lo = max(0, a - pre)
    seg = np.asarray(sig[lo:b], dtype=np.float64)
    k = k_weighted(seg, rate)[a - lo:]
    return float(-0.691 + db10(np.sum(np.mean(k ** 2, axis=0)))) if len(k) else None


def authored_levels(events):
    """Gain spans include baked effects tails. Split gains cannot be undone in an overlapping sum."""
    if not events or any(c.get("authoredGainDB") is None for c in events):
        return None
    spans = sorted((c["frame"], c["frame"] + chop_duration_frames(c), float(c["authoredGainDB"])) for c in events)
    return spans if all(np.isfinite(gain) for _, _, gain in spans) else None


def untrimmed_dry_lufs(dry, rate, a, b, spans, dry_lufs):
    """Undo the actual dry gain before K weighting, including its settling time; mixed gains cannot be separated."""
    start = max(0, a - int(0.5 * rate))
    merged = []
    for lo, hi, gain in spans:
        if hi <= start or lo >= b:
            continue
        left, right = max(lo, start) - start, min(hi, b) - start
        if merged and left < merged[-1][1]:
            first, previous_end, previous_gain = merged[-1]
            if previous_gain != gain:
                return None
            merged[-1] = (first, max(previous_end, right), gain)
        else:
            merged.append((left, right, gain))
    edits = [(lo, hi, gain) for lo, hi, gain in merged if gain]
    if not edits:
        return dry_lufs
    x = np.array(dry[start:b], dtype=np.float64, copy=True)
    for lo, hi, gain in edits:
        x[lo:hi] *= 10 ** (-gain / 20)
    return segment_lufs(x, rate, a - start, b - start)


def dry_pieces(cap, min_seconds=MIN_PIECE_SECONDS):
    """(start, end) of every scheduled dry piece at least `min_seconds` long, one per chop (not merged).
    The dry length excludes a motif echo throw's rendered tail."""
    out = []
    for c in cap.chops():
        f, d = c.get("frame"), chop_duration_frames(c)
        if c.get("dryFrames"):
            d = min(d, int(c["dryFrames"]))
        if f is not None and d >= min_seconds * cap.rate:
            out.append((int(f), int(f) + int(d)))
    return sorted(out)


def _score(grid, d, others, intervals, nfr):
    per = []
    for a, b in intervals:
        mask = grid.frames_mask([(a, b)], nfr)
        snr = octave_snr(grid, d, others, mask)
        per.append({"startFrame": int(a), "endFrame": int(b), "snrOctaveDb": snr, "sii": sii_proxy(snr),
                    "snr1to4kDb": snr_1_to_4k(grid, d, others, mask)})
    return per


def measure_dialogue(cap, grid, grids):
    """Featured chops (merged dry intervals of at least 0.5 s) and, separately, every dry piece of at least
    0.12 s. Both use the octave-band SII proxy of the dialogue against the power sum of every other section."""
    if not cap.has_section("dialogue"):
        return {"skipped": "no dialogue"}
    d = grids.get("dialogue")
    others = [g for s, g in grids.items() if s != "dialogue" and g is not None]
    nfr = len(d["PL"])
    chops = [(a, b) for a, b in cap.chop_intervals(dry=True) if b - a >= MIN_CHOP_SECONDS * cap.rate]
    pieces = dry_pieces(cap)
    if not pieces and not cap.chops():
        # No manifest events (a v1 capture): the activity intervals of the dialogue stem stand in.
        pieces = [(a, b) for a, b in cap.chop_intervals(dry=True) if b - a >= MIN_PIECE_SECONDS * cap.rate]
    out = {"octaveCenters": OCTAVE_CENTERS}
    if pieces:
        pp = _score(grid, d, others, pieces, nfr)
        sii = np.array([p["sii"] for p in pp])
        few = len(pp) < 3
        out["allPieces"] = {"count": len(pp), "minSeconds": MIN_PIECE_SECONDS, "siiMean": float(sii.mean()),
                            "siiP10": None if few else float(np.percentile(sii, 10)), "fewPieces": few,
                            "snr1to4kMeanDb": float(np.mean([p["snr1to4kDb"] for p in pp])),
                            "events": len(cap.chops()), "perPiece": pp}
    else:
        out["allPiecesSkipped"] = f"no dry piece of at least {MIN_PIECE_SECONDS} s"
    if not chops:
        out["featuredSkipped"] = "no dialogue chops of at least 0.5 s"
        if not pieces:
            return {"skipped": "no dialogue chops of at least 0.5 s or pieces of at least 0.12 s"}
        return out
    dsig = cap.section_signal("dialogue")
    per = _score(grid, d, others, chops, nfr)
    for p in per:
        p["lufs"] = segment_lufs(dsig, cap.rate, p["startFrame"], min(p["endFrame"], len(dsig)))
    spans = authored_levels(cap.chops())
    if cap.has("dialogue-dry"):
        dry = cap.signal(["dialogue-dry"])
        gains = []
        for p in per:
            a, b = p["startFrame"], min(p["endFrame"], len(dry))
            dl = segment_lufs(dry, cap.rate, a, b)
            p["dryLufs"] = dl
            if dl is not None and p["lufs"] is not None:
                wet_delta = p["lufs"] - dl
                gains.append(wet_delta)
                if spans is not None:
                    normalized = untrimmed_dry_lufs(dry, cap.rate, a, b, spans, dl)
                    if normalized is not None:
                        p["levelMatchedDryLufs"] = normalized
                        p["levelMatchedLufs"] = normalized + wet_delta
        dry_info = {"chains": float(np.median(gains)) if gains else None}
    else:
        dry_info = None
    sii = np.array([p["sii"] for p in per])
    snr14 = np.array([p["snr1to4kDb"] for p in per])
    durations = [p["endFrame"] - p["startFrame"] for p in per]
    lufs = np.array([p["lufs"] for p in per if p["lufs"] is not None])
    corrected = sum("levelMatchedLufs" in p for p in per)
    effective = [p.get("levelMatchedLufs", p["lufs"]) for p in per if p["lufs"] is not None]
    basis = "authored-gain-corrected" if corrected == len(per) else "partial" if corrected else "raw"
    few = len(per) < 3  # a 10th percentile and a spread over one or two chops say nothing
    out.update({"chops": len(per), "siiMean": float(sii.mean()), "siiP10": None if few else float(np.percentile(sii, 10)),
                "fewChops": few,
                "snr1to4kMeanDb": float(np.average(snr14, weights=durations)),
                "snr1to4kEventMeanDb": float(snr14.mean()), "loudnessSpreadLu": float(np.ptp(effective)) if len(effective) and not few else None,
                "rawLoudnessSpreadLu": float(np.ptp(lufs)) if len(lufs) and not few else None,
                "spreadBasis": basis, "authoredGainWindows": corrected,
                "perChop": per,
                "dialogueDryTap": None if dry_info is None else {"processedMinusDryLuMedian": dry_info["chains"]}})
    return out


def measure_bed(cap, grid, grids):
    if not cap.has("footage") and not cap.has_section("bed"):
        return {"skipped": "no footage"}
    out = {}
    dry, delay, room = (cap.signal([n]) for n in ("footage-dry", "footage-delay", "footage-room"))
    if dry is not None and delay is not None and room is not None:
        wet = np.asarray(delay, np.float64) + np.asarray(room, np.float64)
        rms = lambda x: np.sqrt(np.mean(np.asarray(x, np.float64) ** 2))
        out["directToWetDb"] = float(20 * np.log10(max(rms(dry), 1e-12) / max(rms(wet), 1e-12)))
    else:
        out["directToWetSkipped"] = "footage-dry, delay or room stem missing"
    bed = grids.get("bed")
    if bed is None:
        out["skipped"] = "no bed section"
        return out
    nfr = len(bed["PL"])
    chops = [(a, b) for a, b in cap.chop_intervals() if b - a >= MIN_CHOP_SECONDS * cap.rate]
    start = int((cap.manifest.get("footageStartFrames") or [0])[0])
    end = cap.scored_frames
    gaps, cursor = [], start
    for a, b in cap.chop_intervals():
        if a - cursor >= MIN_CHOP_SECONDS * cap.rate:
            gaps.append((cursor, a))
        cursor = max(cursor, b)
    if end - cursor >= MIN_CHOP_SECONDS * cap.rate:
        gaps.append((cursor, end))
    others = [g for s, g in grids.items() if s not in ("bed", "dialogue") and g is not None]
    if gaps:
        mask = grid.frames_mask(gaps, nfr)
        snr = octave_snr(grid, bed, others, mask)
        out["gapSnrOctaveDb"] = snr
        out["audibilityIndex"] = sii_proxy(snr)
        out["gaps"] = len(gaps)
        out["gapSeconds"] = float(sum(b - a for a, b in gaps) / cap.rate)
        bsig = cap.section_signal("bed")
        parts = np.concatenate([np.asarray(bsig[a:b], dtype=np.float64) for a, b in gaps], axis=0)
        out["gapLufs"] = float(-0.691 + db10(np.sum(np.mean(k_weighted(parts, cap.rate) ** 2, axis=0))))
        # Music plus chops in the same gaps (every section but the bed), for "bed at least 10 dB under".
        rest = [s for s in SECTION_ORDER if s != "bed" and cap.has_section(s)]
        if rest:
            msig = np.asarray(cap.section_signal(rest[0]), dtype=np.float64)
            for s in rest[1:]:
                msig = msig + np.asarray(cap.section_signal(s), dtype=np.float64)
            mparts = np.concatenate([msig[a:b] for a, b in gaps], axis=0)
            out["mixInGapsLufs"] = float(-0.691 + db10(np.sum(np.mean(k_weighted(mparts, cap.rate) ** 2, axis=0))))
            out["bedUnderMixInGapsDb"] = out["mixInGapsLufs"] - out["gapLufs"]
    else:
        out["gapsSkipped"] = "no gaps of at least 0.5 s between chops"
    if chops and grids.get("dialogue") is not None:
        mask = grid.frames_mask(chops, nfr)
        out["dialogueOverBed1to4kDb"] = float(db10(max(band_mean(grid, grids["dialogue"], mask, 1000, 4000), 1e-18))
                                              - db10(max(band_mean(grid, bed, mask, 1000, 4000), 1e-18)))
    active = grid.power(bed) > 10 ** (-60 / 10)
    out["rolloff85Hz"] = spectral_rolloff(grid, bed, 0.85, active_frames=active if active.any() else None)
    if cap.has("bed-post"):
        post = grid.for_stem(cap, "bed-post")
        if post is not None:
            act = grid.power(post) > 10 ** (-60 / 10)
            out["rolloff85HzBedPost"] = spectral_rolloff(grid, post, 0.85, active_frames=act if act.any() else None)
            out["bedBandwidthSource"] = "bed-post tap"
    return out
