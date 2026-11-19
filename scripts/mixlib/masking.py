"""M8 band energy and masking matrix."""

import numpy as np

from .audio import BAND_NAMES, BANDS, SECTION_ORDER, db10


def section_band_energy(grid, grids, mask=None):
    """Mean-square per band per section (dict section -> list over BANDS), optionally restricted
    to the hops where `mask` is True."""
    out = {}
    for sec, g in grids.items():
        if g is None:
            continue
        p = (g["PL"] + g["PR"]) * 0.5
        if mask is not None:
            p = p[mask[: len(p)]] if mask.any() else p[:0]
        mean = p.mean(axis=0) if len(p) else np.zeros(p.shape[1])
        out[sec] = [float(mean[grid.sl(lo, hi)].sum()) for lo, hi in BANDS]
    return out


def masking_matrix(energy):
    """Each section's band level (dB) and its margin over the power sum of the others (dB)."""
    sections = [s for s in SECTION_ORDER if s in energy]
    level = {s: [float(db10(e)) for e in energy[s]] for s in sections}
    margin = {}
    for s in sections:
        row = []
        for b in range(len(BANDS)):
            others = sum(energy[o][b] for o in sections if o != s)
            row.append(None if energy[s][b] <= 1e-18 else float(db10(energy[s][b]) - db10(max(others, 1e-18))))
        margin[s] = row
    return {"bands": BAND_NAMES, "sections": sections, "levelDb": level, "marginDb": margin}


def measure_masking(cap, grid, grids):
    out = {"overall": masking_matrix(section_band_energy(grid, grids))}
    intervals = cap.chop_intervals()
    if intervals and grids.get("dialogue") is not None:
        nfr = next(len(g["PL"]) for g in grids.values() if g is not None)
        mask = grid.frames_mask(intervals, nfr)
        if mask.any():
            out["duringChops"] = masking_matrix(section_band_energy(grid, grids, mask))
            out["chopActiveFraction"] = float(mask.mean())
    return out


def low_band_clearance(matrix_energy, sections=("mids", "lead", "space", "dialogue", "bed")):
    """C-B1 helper: in 20-120 Hz how far each section sits under the louder of drums and bass (dB)."""
    out = {}
    drums, bass = matrix_energy.get("drums"), matrix_energy.get("bass")
    if drums is None and bass is None:
        return out
    low = lambda e: e[0] + e[1]
    ref = max(low(drums) if drums else 0.0, low(bass) if bass else 0.0)
    for s in sections:
        if s in matrix_energy:
            out[s] = float(db10(ref) - db10(max(low(matrix_energy[s]), 1e-18)))
    return out
