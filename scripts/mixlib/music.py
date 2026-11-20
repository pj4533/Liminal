"""M13 mids and lead; M14 theme return."""

import numpy as np

from .audio import db10
from .dialogue import band_mean


def _notes(phrase, role):
    return [n for n in phrase.get("notes", []) if n.get("role") == role]


def _intervals(notes):
    return [(int(n["on"]), int(n["off"])) for n in notes]


def _mask(grid, intervals, nfr):
    return grid.frames_mask(intervals, nfr)


def articulation_class(note, beat_in_phrase):
    if note.get("articulation") is not None:
        return ("a", str(note["articulation"]))
    length_beats = note.get("lengthBeats")
    return ("o", round(beat_in_phrase % 1.0, 1) > 0.05, "long" if (length_beats or 0) >= 1.2 else "short")


def articulation_counts(cap):
    """Distinct texture articulations per 16 bars (one take = four phrases). Without an explicit
    `articulation` field, a class is (on-beat or off-beat onset, short or long note)."""
    if not cap.score:
        return None
    takes = {}
    for i, ph in enumerate(cap.score):
        notes = _notes(ph, "texture")
        by_onset = {}
        for n in notes:
            by_onset.setdefault(int(n["on"]), []).append(n)
        for on, group in by_onset.items():
            n = group[0]
            beat = (on - ph["range"][0]) / cap.beat_frames
            length = (int(n["off"]) - on) / cap.beat_frames
            n = {**n, "lengthBeats": length}
            takes.setdefault(i // 4, set()).add(articulation_class(n, beat))
    return {str(k): len(v) for k, v in sorted(takes.items())}


def engine_articulation_counts(cap):
    """Distinct mid articulations per 16 bars from `diagnostics.musicLevels[].midArticulations`
    (one entry per phrase, in phrase order; four phrases make one take)."""
    levels = cap.diagnostics.get("musicLevels") or []
    if not levels or not any("midArticulations" in e for e in levels):
        return None
    per_take = {}
    for e in levels:
        phrase = e.get("phrase")
        if phrase is None:
            continue
        take = int(phrase) // max(1, int(round(cap.take_frames / cap.phrase_frames)))
        per_take.setdefault(take, set()).update(str(a) for a in e.get("midArticulations", []))
    return {str(k): len(v) for k, v in sorted(per_take.items())}


def measure_mids_lead(cap, grid, grids):
    lead, mids = grids.get("lead"), grids.get("mids")
    if not cap.score or lead is None or mids is None:
        return {"skipped": "score.json, lead or mids stem missing"}
    nfr = len(lead["PL"])
    lead_iv = [iv for ph in cap.score for iv in _intervals(_notes(ph, "lead"))]
    tex_iv = [iv for ph in cap.score for iv in _intervals(_notes(ph, "texture"))]
    lead_m, tex_m = _mask(grid, lead_iv, nfr), _mask(grid, tex_iv, nfr)
    both, rests = lead_m & tex_m, tex_m & ~lead_m
    out = {"articulationsPer16Bars": articulation_counts(cap)}
    engine = engine_articulation_counts(cap)
    if engine:
        out["articulationsPer16BarsEngine"] = engine
    for label, m in (("bothPlay", both), ("leadRestMidsPlay", rests)):
        if m.sum() < 50:
            out[label + "Skipped"] = f"{m.sum() * grid.hop / cap.rate:.2f} s of material, need at least 0.5 s"
        if m.sum() >= 50:
            l, t = band_mean(grid, lead, m, 400, 3000), band_mean(grid, mids, m, 400, 3000)
            out[label] = {"leadDb": float(db10(max(l, 1e-18))), "midsDb": float(db10(max(t, 1e-18))),
                          "leadMinusMidsDb": float(db10(max(l, 1e-18)) - db10(max(t, 1e-18))),
                          "seconds": float(m.sum() * grid.hop / cap.rate)}
    space = grids.get("wet") or grids.get("space")
    return out


def onset_envelope(sig, rate, start, stop, hop=0.01):
    x = np.asarray(sig[start:stop], dtype=np.float32)
    if x.ndim == 2:
        x = x.mean(axis=1)
    n = int(rate * hop)
    k = len(x) // n
    env = db10((x[: k * n].astype(np.float64).reshape(k, n) ** 2).mean(axis=1) + 1e-12)
    return np.maximum(np.diff(env), 0)


def measure_theme_return(cap, grid, grids):
    lead = grids.get("lead")
    if not cap.score or lead is None:
        return {"skipped": "score.json or lead stem missing"}
    nfr = len(lead["PL"])
    lead_sig = cap.section_signal("lead")
    # User direction of 19 November 2026 (docs/plans/mpc-chopping.md): the chops are a featured layer, so
    # salience is judged against mids, space and bed; the value with the dialogue as a rival is reported too.
    rivals = [g for g in (grids.get(s) for s in ("mids", "space", "bed")) if g is not None]
    rivals_dialogue = rivals + [g for g in (grids.get("dialogue"),) if g is not None]
    chops = cap.chop_intervals(dry=True) if cap.has_section("dialogue") else []

    def hook_windows(phrase):
        notes = sorted(_notes(phrase, "lead"), key=lambda n: n["on"])[:2]
        return [(int(n["on"]), min(int(n["off"]), int(n["on"]) + int(1.0 * cap.rate))) for n in notes]

    def salience(phrase, rival_set):
        iv = hook_windows(phrase)
        if not iv:
            return None
        m = _mask(grid, iv, nfr)
        l = band_mean(grid, lead, m, 500, 4000)
        if l < 1e-10:  # lead silent in these notes (about -100 dBFS): salience is undefined, not very negative
            return None
        o = sum(band_mean(grid, g, m, 500, 4000) for g in rival_set)
        return float(db10(max(l, 1e-18)) - db10(max(o, 1e-18)))

    def hook_chop_free(phrase):
        """No dry chop overlaps the first two return notes (the salience window). The motif's returnOpen
        cell places one quiet piece late in the return's first bar, after the hook has opened (plan 5.3)."""
        return not any(s < b and e > a for s, e in chops for a, b in hook_windows(phrase))

    def band_levels(phrase):
        iv = hook_windows(phrase)
        if not iv:
            return None
        m = _mask(grid, iv, nfr)
        return {s: round(float(db10(max(band_mean(grid, grids[s], m, 500, 4000), 1e-18))), 2)
                for s in ("lead", "mids", "space", "bed", "dialogue") if grids.get(s) is not None}

    takes = {}
    for i, ph in enumerate(cap.score):
        takes.setdefault(i // 4, {})[ph.get("section")] = (i, ph)
    results = []
    for take, secs in sorted(takes.items()):
        if "theme" not in secs or "returnTheme" not in secs:
            continue
        (_, theme), (_, ret) = secs["theme"], secs["returnTheme"]
        env_t = onset_envelope(lead_sig, cap.rate, *theme["range"])
        env_r = onset_envelope(lead_sig, cap.rate, *ret["range"])
        n = min(len(env_t), len(env_r))
        corr = float(np.corrcoef(env_t[:n], env_r[:n])[0, 1]) if n > 10 and env_t[:n].std() > 0 and env_r[:n].std() > 0 else None
        results.append({"take": take, "themeSalienceDb": salience(theme, rivals), "returnSalienceDb": salience(ret, rivals),
                        "returnSalienceWithDialogueDb": salience(ret, rivals_dialogue),
                        "returnHookChopFree": hook_chop_free(ret), "returnBandLevelsDb": band_levels(ret),
                        "onsetCorrelation": corr, "themeProgram": theme.get("program"),
                        "returnProgram": ret.get("program"), "sameProgram": theme.get("program") == ret.get("program")})
    if not results:
        return {"skipped": "no take with both a theme and a return phrase"}
    return {"takes": results}


def measure_space_vs_lead(cap, grid, grids):
    """C-B7 helper: per lead-active phrase, wet minus lead level (dB)."""
    lead, wet = grids.get("lead"), grids.get("space")
    if not cap.score or lead is None or wet is None:
        return None
    nfr = len(lead["PL"])
    margins = []
    for ph in cap.score:
        iv = _intervals(_notes(ph, "lead"))
        if not iv:
            continue
        m = _mask(grid, iv, nfr)
        if m.sum() < 5:
            continue
        l, w = band_mean(grid, lead, m, 20, 16000), band_mean(grid, wet, m, 20, 16000)
        margins.append(float(db10(max(l, 1e-18)) - db10(max(w, 1e-18))))
    return {"leadMinusSpaceDb": margins, "median": float(np.median(margins)) if margins else None}
