"""Capture access, WAV IO, and the shared band-energy grid."""

import json
import struct
from pathlib import Path

import numpy as np
from scipy import fft as sfft

DEFAULT_SECTIONS = {
    "drums": ["drums"], "bass": ["bass"], "mids": ["texture"], "lead": ["dry"],
    "space": ["wet"], "dialogue": ["dialogue-chops"], "bed": ["footage"],
}
SECTION_ORDER = ["drums", "bass", "mids", "lead", "space", "dialogue", "bed"]
BANDS = [(20, 60), (60, 120), (120, 250), (250, 500), (500, 1000), (1000, 2000), (2000, 4000),
         (4000, 8000), (8000, 16000)]
BAND_NAMES = ["20-60", "60-120", "120-250", "250-500", "500-1k", "1-2k", "2-4k", "4-8k", "8-16k"]
OCTAVE_CENTERS = [250, 500, 1000, 2000, 4000, 8000]
SII_WEIGHTS = [0.08, 0.14, 0.22, 0.30, 0.20, 0.06]
THIRD_CENTERS = [1000 * 2 ** (n / 3) for n in range(-12, 12)]
HOP_SECONDS = 0.01
NFFT = 4096


def db10(x):
    return 10 * np.log10(np.maximum(x, 1e-20))


def db20(x):
    return 20 * np.log10(np.maximum(x, 1e-10))


def read_wav(path):
    """Return (memmap float32 (frames, channels), rate) for an IEEE-float WAV."""
    path = Path(path)
    with path.open("rb") as f:
        header = f.read(12)
        if header[:4] != b"RIFF" or header[8:12] != b"WAVE":
            raise ValueError(f"{path.name}: not a RIFF WAV")
        fmt = data = None
        while True:
            head = f.read(8)
            if len(head) < 8:
                break
            name, size = struct.unpack("<4sI", head)
            start = f.tell()
            if name == b"fmt ":
                fmt = f.read(min(size, 40))
            elif name == b"data":
                data = (start, min(size, path.stat().st_size - start))
                break
            f.seek(start + size + (size & 1))
    if fmt is None or data is None:
        raise ValueError(f"{path.name}: missing fmt or data chunk")
    enc, channels, rate, _, align, bits = struct.unpack("<HHIIHH", fmt[:16])
    if bits != 32 or enc not in (3, 0xFFFE):
        raise ValueError(f"{path.name}: expected float32 PCM")
    frames = data[1] // align
    mm = np.memmap(path, dtype="<f4", mode="r", offset=data[0], shape=(frames, channels))
    return mm, rate


def write_wav(path, samples, rate):
    """Write float32 stereo (frames, 2); a 1-D array is duplicated to both channels."""
    samples = np.asarray(samples, dtype="<f4")
    if samples.ndim == 1:
        samples = np.stack([samples, samples], axis=1)
    data = np.ascontiguousarray(samples).tobytes()
    fmt = struct.pack("<HHIIHH", 3, 2, int(rate), int(rate) * 8, 8, 32)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<I", 16) + fmt)
        f.write(b"data" + struct.pack("<I", len(data)) + data)


def chop_duration_frames(c):
    """durationFrames when the manifest has it (v2), else the source span over the speed (v1)."""
    d = c.get("durationFrames")
    if d:
        return int(d)
    try:
        return int(round((c["sourceEnd"] - c["sourceStart"]) / max(float(c.get("speed", 1.0)), 0.05)))
    except (KeyError, TypeError):
        return 0


def merge_intervals(items, gap=0):
    out = []
    for a, b in sorted(items):
        if out and a <= out[-1][1] + gap:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def stem_activity_intervals(sig, rate, threshold_db=-60.0, win=0.05):
    n = int(rate * win)
    m = np.asarray(sig, dtype=np.float32).mean(axis=1)
    k = len(m) // n
    if k == 0:
        return []
    p = db10((m[: k * n].reshape(k, n).astype(np.float64) ** 2).mean(axis=1))
    out, start = [], None
    for i, v in enumerate(p > threshold_db):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start * n, i * n))
            start = None
    if start is not None:
        out.append((start * n, k * n))
    return out


class Capture:
    """A capture directory, or in-memory arrays for self-tests."""

    def __init__(self, path=None, case=None, manifest=None, arrays=None, score=None, analysis=None,
                 extra_files=None):
        self.path = Path(path) if path else None
        self.arrays = arrays or {}
        self._cache = {}
        if manifest is None:
            manifest = json.loads((self.path / "manifest.json").read_text())
        self.manifest = manifest
        if score is None and self.path and (self.path / "score.json").is_file():
            score = json.loads((self.path / "score.json").read_text())
        self.score = score
        if analysis is None and self.path and (self.path / "analysis.json").is_file():
            analysis = json.loads((self.path / "analysis.json").read_text())
        self.analysis = analysis
        self.extra_files = extra_files or {}
        self.rate = int(manifest["sampleRate"])
        self.frames = int(manifest["frames"])
        self.has_footage = bool(manifest.get("hasFootage", False))
        self.sections = {k: list(v) for k, v in (manifest.get("sections") or DEFAULT_SECTIONS).items()}
        self.schema = manifest.get("schema", "")
        self.diagnostics = manifest.get("diagnostics") or {}
        grid = manifest.get("grid") or {}
        self.beat_frames = float(grid.get("beatFrames") or 60 / float(manifest.get("bpm", 70)) * self.rate)
        self.bar_frames = float(grid.get("barFrames") or self.beat_frames * 4)
        self.phrase_frames = float(grid.get("phraseFrames") or self.bar_frames * 4)
        self.take_frames = float(grid.get("takeFrames") or self.phrase_frames * 4)
        self.scored_frames = int(manifest.get("scoredFrames") or self.frames)
        self.case = case or self._guess_case()

    def _guess_case(self):
        if self.path and self.path.name in ("ref", "long", "fast", "same", "nofilm"):
            return self.path.name
        return "ref" if self.has_footage else "nofilm"

    def has(self, name):
        return name in self.arrays or bool(self.path and (self.path / f"{name}.wav").is_file())

    def stem(self, name):
        """Stereo float32 array-like (frames, 2), or None."""
        if name in self._cache:
            return self._cache[name]
        arr = None
        if name in self.arrays:
            arr = self.arrays[name]
        elif self.path and (self.path / f"{name}.wav").is_file():
            arr, rate = read_wav(self.path / f"{name}.wav")
            if rate != self.rate:
                raise ValueError(f"{name}: rate {rate} differs from manifest {self.rate}")
        self._cache[name] = arr
        return arr

    def section_names(self, section):
        return [n for n in self.sections.get(section, []) if self.has(n)]

    def has_section(self, section):
        return bool(self.section_names(section))

    def signal(self, names, start=0, stop=None):
        """Sum of stems as float32 (n, 2), or None when none exist."""
        if isinstance(names, str):
            names = [names]
        out = None
        for n in names:
            s = self.stem(n)
            if s is None:
                continue
            seg = np.asarray(s[start:stop], dtype=np.float32)
            out = seg.copy() if out is None else out + seg
        return out

    def section_signal(self, section, start=0, stop=None):
        return self.signal(self.section_names(section), start, stop)

    def chops(self):
        return list(self.manifest.get("dialogueChops") or [])

    def chop_intervals(self, dry=False):
        """Merged (start, end) frame intervals of scheduled dialogue (gaps up to 0.1 s merged). `dry` uses
        each chop's dry length when the manifest records one (a motif echo throw renders its tail into the
        chop buffer; the tail is an effect, measured with the returns, not speech)."""
        raw = []
        for c in self.chops():
            f, d = c.get("frame"), chop_duration_frames(c)
            if dry and c.get("dryFrames"):
                d = min(d, int(c["dryFrames"]))
            if f is not None and d:
                raw.append((int(f), int(f) + int(d)))
        if not raw and self.has_section("dialogue"):
            raw = stem_activity_intervals(self.section_signal("dialogue"), self.rate)
        return merge_intervals(raw, int(0.1 * self.rate))

    def kicks(self):
        """Kick frames (landmark peak when present, else candidates), capture frames."""
        frames = []
        for take in self.diagnostics.get("landmarks") or []:
            frames += [int(k.get("peakFrame", k.get("frame"))) for k in take.get("kicks", [])]
        if not frames:
            frames = [int(k["frame"]) for k in self.manifest.get("kickCandidates", [])]
        return sorted(set(frames))

    def kick_attack_frames(self, min_confidence=None):
        """Kick attack frames in capture frames. `min_confidence` keeps only confident landmarks."""
        frames = []
        for take in self.diagnostics.get("landmarks") or []:
            for k in take.get("kicks", []):
                if k.get("frame") is None:
                    continue
                if min_confidence is not None and float(k.get("confidence", 1.0)) < min_confidence:
                    continue
                frames.append(int(k["frame"]))
        return sorted(set(frames)) or (self.kicks() if min_confidence is None else [])

    def has_landmarks(self):
        return any(t.get("kicks") for t in self.diagnostics.get("landmarks") or [])

    def plans(self):
        return list(self.diagnostics.get("dialoguePlans") or [])

    def stem_chains(self):
        return list(self.diagnostics.get("stemChains") or [])

    def master_dynamics(self):
        d = self.diagnostics.get("masterDynamics")
        return d if isinstance(d, dict) else {}


class BandGrid:
    """Mean-square power per frequency group per 10 ms hop, from one STFT pass per signal.

    Groups are the cells of the union of every band edge any measurement needs, so each analysis
    band is a contiguous sum of groups. Power of L, R and the L*R cross term are kept.
    """

    def __init__(self, rate, nfft=NFFT, hop_seconds=HOP_SECONDS):
        self.rate = rate
        self.nfft = nfft
        self.hop = int(round(rate * hop_seconds))
        edges = {0.0, rate / 2 + 1}
        for lo, hi in BANDS:
            edges.update((lo, hi))
        edges.update((25, 40, 100, 150, 400, 800, 3000, 10000, 12000))
        for c in OCTAVE_CENTERS:
            edges.update((c / 2 ** 0.5, c * 2 ** 0.5))
        for c in THIRD_CENTERS:
            edges.update((c / 2 ** (1 / 6), c * 2 ** (1 / 6)))
        self.edges = np.array(sorted(e for e in edges if e <= rate / 2 + 1))
        freqs = np.arange(nfft // 2 + 1) * rate / nfft
        group = np.clip(np.searchsorted(self.edges, freqs, side="right") - 1, 0, len(self.edges) - 2)
        self.ngroups = len(self.edges) - 1
        self.matrix = np.zeros((nfft // 2 + 1, self.ngroups), dtype=np.float32)
        self.matrix[np.arange(len(freqs)), group] = 1.0
        self.window = np.hanning(nfft + 1)[:-1].astype(np.float32)
        self.scale = np.float32(2.0 / (nfft * float(np.sum(self.window.astype(np.float64) ** 2))))
        self.cache = {}

    def idx(self, hz):
        return int(np.argmin(np.abs(self.edges - hz)))

    def sl(self, lo, hi):
        return slice(self.idx(lo), self.idx(hi))

    def frame_count(self, frames):
        return frames // self.hop + 1

    def compute(self, sig):
        """sig: (frames, 2). Returns dict PL, PR, C of shape (hops, groups)."""
        n = len(sig)
        nfr = self.frame_count(n)
        half = self.nfft // 2
        out = {k: np.zeros((nfr, self.ngroups), dtype=np.float32) for k in ("PL", "PR", "C")}
        base = np.arange(self.nfft)[None, :]
        chunk = 1200
        for a in range(0, nfr, chunk):
            b = min(nfr, a + chunk)
            s0, s1 = a * self.hop - half, (b - 1) * self.hop + half
            lo, hi = max(s0, 0), min(s1, n)
            seg = np.zeros((s1 - s0, 2), dtype=np.float32)
            seg[lo - s0: hi - s0] = np.asarray(sig[lo:hi], dtype=np.float32)
            idx = np.arange(b - a)[:, None] * self.hop + base
            XL = sfft.rfft(seg[:, 0][idx] * self.window, workers=-1)
            XR = sfft.rfft(seg[:, 1][idx] * self.window, workers=-1)
            with np.errstate(all="ignore"):  # Accelerate raises spurious FP flags in float32 matmul
                out["PL"][a:b] = ((XL.real ** 2 + XL.imag ** 2) * self.scale) @ self.matrix
                out["PR"][a:b] = ((XR.real ** 2 + XR.imag ** 2) * self.scale) @ self.matrix
                out["C"][a:b] = ((XL * XR.conj()).real * self.scale) @ self.matrix
        return out

    def get(self, key, sig_fn):
        if key not in self.cache:
            sig = sig_fn()
            self.cache[key] = None if sig is None else self.compute(sig)
        return self.cache[key]

    def for_section(self, cap, section):
        return self.get(("sec", section), lambda: cap.section_signal(section))

    def for_stem(self, cap, name):
        return self.get(("stem", name), lambda: cap.signal([name]))

    @staticmethod
    def power(g, sl=None):
        """Per-hop mean-square (mean of L and R) summed over the groups in `sl`."""
        p = (g["PL"] + g["PR"]) * 0.5
        return (p[:, sl] if sl is not None else p).sum(axis=1, dtype=np.float64)

    def frames_mask(self, intervals, nfr):
        mask = np.zeros(nfr, dtype=bool)
        for a, b in intervals:
            mask[max(0, a // self.hop): min(nfr, b // self.hop + 1)] = True
        return mask
