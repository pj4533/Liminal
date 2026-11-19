"""Synthetic fixtures with known answers for the measurement library."""

import tempfile
from pathlib import Path

import numpy as np

from . import cadence, dynamics, lowend, masking
from .audio import BandGrid, Capture, write_wav
from .loudness import measure_loudness, true_peak_db
from .report import evaluate, load_criteria, run_analysis, write_report

RATE = 48000
CRITERIA = Path(__file__).resolve().parent.parent / "mix-criteria.json"


def tone(freq, seconds, amp, phase=0.0, rate=RATE):
    t = np.arange(int(seconds * rate)) / rate
    return amp * np.sin(2 * np.pi * freq * t + phase)


def stereo(x, y=None):
    return np.stack([x, x if y is None else y], axis=1).astype(np.float32)


def manifest(frames, **extra):
    base = {"schema": "liminal-lofi-capture-v2", "sampleRate": RATE, "frames": frames, "hasFootage": True,
            "bpm": 70.0, "scoredFrames": frames,
            "grid": {"beatFrames": RATE * 60 / 70, "barFrames": RATE * 60 / 70 * 4,
                     "phraseFrames": RATE * 60 / 70 * 16, "takeFrames": RATE * 60 / 70 * 64}}
    base.update(extra)
    return base


def result(results, cid):
    return next(r for r in results if r["id"] == cid)


class Failure(AssertionError):
    pass


def expect(cond, message):
    if not cond:
        raise Failure(message)
    print(f"  ok  {message}")


def test_loudness_and_peak():
    amp = 10 ** (-23 / 20)
    sig = stereo(tone(997, 12, amp))
    lufs = measure_loudness(sig, RATE)["integratedLufs"]
    expect(abs(lufs + 23.0) < 0.1, f"997 Hz stereo sine reads {lufs:.2f} LUFS (expected -23.0 within 0.1)")
    n = np.arange(RATE)
    fade = np.minimum(1.0, np.minimum(n, n[::-1]) / 4800.0)  # no abrupt edges to ring
    quarter = stereo(fade * 0.5 * np.sin(2 * np.pi * n / 4 + np.pi / 4))
    sample_peak = 20 * np.log10(np.max(np.abs(quarter)))
    tp = true_peak_db(quarter)
    expect(abs((tp - sample_peak) - 3.01) < 0.1, f"fs/4 sine at 45 degrees reads +{tp - sample_peak:.2f} dB over sample peak")


def test_masking():
    frames = RATE * 4
    arrays = {"drums": stereo(tone(1500, 4, 0.2)), "dry": stereo(tone(1500, 4, 0.1))}
    cap = Capture(manifest=manifest(frames), arrays=arrays)
    grid = BandGrid(RATE)
    grids = {s: grid.for_section(cap, s) for s in ("drums", "lead") if cap.has_section(s)}
    energy = masking.section_band_energy(grid, grids)
    mat = masking.masking_matrix(energy)
    band = 5  # 1-2 kHz
    d, l = mat["marginDb"]["drums"][band], mat["marginDb"]["lead"][band]
    expect(abs(d - 6.02) < 0.3 and abs(l + 6.02) < 0.3, f"two-bus masking margins {d:.2f} and {l:.2f} dB (expected +6.02 and -6.02)")


def chop_events(frame_lists, cap_manifest):
    events = []
    for cue, frames in enumerate(frame_lists):
        for i, (frame, src) in enumerate(frames):
            events.append({"frame": int(frame), "durationFrames": RATE // 4, "sourceStart": src, "sourceEnd": src + 10,
                           "speed": 1.0, "reversed": False, "cue": cue})
    cap_manifest["dialogueChops"] = events


def test_cadence():
    criteria = load_criteria(CRITERIA)
    take = RATE * 60 / 70 * 64
    sixteenth = RATE * 60 / 70 / 4
    pattern = [(3 * 16 * sixteenth + k * 8 * sixteenth, 100 + k) for k in range(4)]

    def build(second):
        m = manifest(int(np.ceil(take * 2)))
        a = [(f, s) for f, s in pattern]
        b = [(f + take, s2) for f, s2 in second]
        chop_events([a + b], m)
        return Capture(manifest=m, arrays={})

    same = build(pattern)
    cad = {"cadence": cadence.measure_cadence(same)}
    res = evaluate(cad, same, [c for c in criteria if c["id"] == "C-D1"])
    expect(result(res, "C-D1")["status"] == "fail", "identical consecutive 16-bar windows fail C-D1")
    changed = build([(f + 5 * sixteenth, s + 50) for f, s in pattern])
    cad = {"cadence": cadence.measure_cadence(changed)}
    res = evaluate(cad, changed, [c for c in criteria if c["id"] == "C-D1"])
    expect(result(res, "C-D1")["status"] == "pass", "a changed 16-bar window passes C-D1")


def test_kick_bass():
    criteria = load_criteria(CRITERIA)
    frames = RATE * 8
    drums = np.zeros(frames)
    kicks = [int(RATE * (0.5 + 0.857 * i)) for i in range(8)]
    burst = np.exp(-np.arange(int(0.3 * RATE)) / (0.08 * RATE)) * tone(60, 0.3, 0.5)
    for k in kicks:
        drums[k:k + len(burst)] += burst
    for label, sign, expected in (("antiphase", -1.0, "fail"), ("in phase", 1.0, "pass")):
        m = manifest(frames, kickCandidates=[{"frame": k, "strength": 1.0} for k in kicks])
        cap = Capture(manifest=m, arrays={"drums": stereo(drums), "bass": stereo(sign * drums)})
        metrics = {"kickBass": lowend.measure_kick_bass(cap)}
        res = evaluate(metrics, cap, [c for c in criteria if c["id"] == "C-B2"])
        r = result(res, "C-B2")
        sum_ok = "sumVsLouderDbWorst" not in (r.get("failedChecks") or [])
        if sign < 0:
            expect(r["status"] == "fail" and not sum_ok, f"antiphase bass against the kick fails C-B2 (worst sum {r['values']['sumVsLouderDbWorst']} dB)")
        else:
            expect(sum_ok, f"in-phase bass keeps the C-B2 kick-plus-bass sum (worst {r['values']['sumVsLouderDbWorst']} dB)")


def test_lowband_mono():
    criteria = load_criteria(CRITERIA)
    frames = RATE * 6
    low = tone(60, 6, 0.3)
    for label, right in (("antiphase", -low), ("mono", low)):
        sig = stereo(low + tone(2000, 6, 0.05), right + tone(2000, 6, 0.05))
        cap = Capture(manifest=manifest(frames), arrays={"master": sig})
        grid = BandGrid(RATE)
        mg = grid.compute(sig)
        metrics = {"lowbandMono": lowend.measure_lowband_mono(cap, grid, mg, sig)}
        r = result(evaluate(metrics, cap, [c for c in criteria if c["id"] == "C-M10"]), "C-M10")
        want = "fail" if label == "antiphase" else "pass"
        expect(r["status"] == want, f"{label} low band gives C-M10 {r['status']} (correlation below 120 Hz {r['values']['below120Correlation']})")


def test_pumping():
    criteria = load_criteria(CRITERIA)
    seconds = 20
    carrier = tone(440, seconds, 0.3) + tone(1234, seconds, 0.1)
    t = np.arange(len(carrier)) / RATE
    for label, depth, want in (("4 Hz 2 dB wobble", 2.0, "fail"), ("steady gain", 0.0, "pass")):
        gain = 10 ** (depth * np.sin(2 * np.pi * 4 * t) / 20)
        arrays = {"pre-master": stereo(carrier), "master": stereo(carrier * gain)}
        cap = Capture(manifest=manifest(len(carrier), latencySamples={}), arrays=arrays)
        dyn = dynamics.measure_dynamics(cap, None)
        r = result(evaluate({"dynamics": dyn}, cap, [c for c in criteria if c["id"] == "C-M8"]), "C-M8")
        expect(r["status"] == want, f"{label}: pumping index {dyn['pumpingIndexDb']:.2f} dB gives C-M8 {r['status']}")


def test_full_pipeline_v1():
    """A v1-style capture with missing optional inputs must produce a report, never a crash."""
    seconds = 8
    n = RATE * seconds
    with tempfile.TemporaryDirectory(prefix="mixlib-selftest-") as tmp:
        d = Path(tmp) / "ref"
        d.mkdir()
        rng = np.random.default_rng(1)
        stems = {"drums": tone(60, seconds, 0.2) * (np.sin(2 * np.pi * 2 * np.arange(n) / RATE) > 0),
                 "bass": tone(55, seconds, 0.15), "dry": tone(700, seconds, 0.05), "texture": tone(500, seconds, 0.03),
                 "wet": tone(1500, seconds, 0.01), "dialogue-chops": rng.normal(0, 0.01, n),
                 "footage-dry": rng.normal(0, 0.01, n), "footage-delay": rng.normal(0, 0.003, n),
                 "footage-room": rng.normal(0, 0.003, n)}
        for k, v in stems.items():
            write_wav(d / f"{k}.wav", stereo(v), RATE)
        footage = stems["footage-dry"] + stems["footage-delay"] + stems["footage-room"]
        write_wav(d / "footage.wav", stereo(footage), RATE)
        music = sum(stems[k] for k in ("drums", "bass", "dry", "texture", "wet", "dialogue-chops"))
        write_wav(d / "lofi.wav", stereo(music), RATE)
        write_wav(d / "pre-master.wav", stereo(music + footage), RATE)
        write_wav(d / "master.wav", stereo((music + footage) * 0.9), RATE)
        import json
        (d / "manifest.json").write_text(json.dumps({"schema": "liminal-lofi-capture-v1", "sampleRate": RATE, "frames": n,
                                                      "hasFootage": True, "bpm": 70.0, "kickCandidates": []}))
        cap = Capture(d)
        metrics, aux = run_analysis(cap, log=lambda *_: None)
        results = evaluate(metrics, cap, load_criteria(CRITERIA))
        write_report(d / "report", cap, metrics, results)
        expect((d / "report" / "mix-report.json").is_file() and (d / "report" / "mix-report.md").is_file(),
               f"v1 capture produced a report ({len(results)} criteria evaluated)")


def run_self_test():
    tests = [test_loudness_and_peak, test_masking, test_cadence, test_kick_bass, test_lowband_mono, test_pumping,
             test_full_pipeline_v1]
    failures = 0
    for t in tests:
        print(t.__name__)
        try:
            t()
        except Exception as exc:
            failures += 1
            print(f"  FAIL {type(exc).__name__}: {exc}")
    print("self-test " + ("FAILED" if failures else "passed"))
    return 1 if failures else 0
