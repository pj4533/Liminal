"""M11 dialogue intelligibility proxies and M12 film bed."""

import numpy as np

from .audio import OCTAVE_CENTERS, SII_WEIGHTS, SECTION_ORDER, db10
from .loudness import k_weighted
from .spectral import spectral_rolloff

MIN_CHOP_SECONDS = 0.5


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


def measure_dialogue(cap, grid, grids):
    if not cap.has_section("dialogue"):
        return {"skipped": "no dialogue"}
    d = grids.get("dialogue")
    others = [g for s, g in grids.items() if s != "dialogue" and g is not None]
    chops = [(a, b) for a, b in cap.chop_intervals() if b - a >= MIN_CHOP_SECONDS * cap.rate]
    if not chops:
        return {"skipped": "no dialogue chops of at least 0.5 s"}
    nfr = len(d["PL"])
    dsig = cap.section_signal("dialogue")
    per = []
    for a, b in chops:
        mask = grid.frames_mask([(a, b)], nfr)
        snr = octave_snr(grid, d, others, mask)
        per.append({"startFrame": int(a), "endFrame": int(b), "snrOctaveDb": snr, "sii": sii_proxy(snr),
                    "snr1to4kDb": snr_1_to_4k(grid, d, others, mask),
                    "lufs": segment_lufs(dsig, cap.rate, a, min(b, len(dsig)))})
    if cap.has("dialogue-dry"):
        dry = cap.signal(["dialogue-dry"])
        gains = []
        for p in per:
            a, b = p["startFrame"], min(p["endFrame"], len(dry))
            dl = segment_lufs(dry, cap.rate, a, b)
            p["dryLufs"] = dl
            if dl is not None and p["lufs"] is not None:
                gains.append(p["lufs"] - dl)
        dry_info = {"chains": float(np.median(gains)) if gains else None}
    else:
        dry_info = None
    sii = np.array([p["sii"] for p in per])
    snr14 = np.array([p["snr1to4kDb"] for p in per])
    lufs = np.array([p["lufs"] for p in per if p["lufs"] is not None])
    few = len(per) < 3  # a 10th percentile and a spread over one or two chops say nothing
    return {"chops": len(per), "siiMean": float(sii.mean()), "siiP10": None if few else float(np.percentile(sii, 10)),
            "fewChops": few,
            "snr1to4kMeanDb": float(snr14.mean()), "loudnessSpreadLu": float(lufs.max() - lufs.min()) if len(lufs) and not few else None,
            "perChop": per, "octaveCenters": OCTAVE_CENTERS,
            "dialogueDryTap": None if dry_info is None else {"processedMinusDryLuMedian": dry_info["chains"]}}


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
