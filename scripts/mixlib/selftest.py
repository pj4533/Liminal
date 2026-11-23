"""Synthetic fixtures with known answers for the measurement library."""

import sys
import tempfile
from pathlib import Path

if __name__ == "__main__" and not __package__:
    # `python3 scripts/mixlib/selftest.py` runs the same tests as `python3 scripts/mix-report.py --self-test`.
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from mixlib.selftest import run_self_test as _run

    sys.exit(_run())

import numpy as np

from . import cadence, dialogue, dynamics, lowend, masking, music
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


def v2_plan_manifest(tamper=None):
    """Two takes with a plan log whose fingerprints are the engine's FNV-1a over (family, padKey, slot)."""
    from .cadence import block_fingerprint
    take = RATE * 60 / 70 * 64
    phrase = RATE * 60 / 70 * 16
    sixteenth = RATE * 60 / 70 / 4
    m = manifest(int(np.ceil(take * 2)))
    chops, plans = [], []
    pad_keys = {0: 0x1111AAAA2222BBBB, 1: 0x3333CCCC4444DDDD, 2: 0x5555EEEE6666FFFF}
    for cue in range(2):
        blocks = []
        for k in range(4):
            phrase_index = cue * 4 + k
            family = ["anchor", "callResponse", "textureFill", "echo"][(k + 2 * cue) % 4]
            # The two windows use different pads and slots, so they differ.
            items = [(cue, 5 + 8 * k + cue), ((cue + 1) % 3, 33 + k)]
            events, elements = [], []
            for pad, slot in items:
                start = phrase_index * phrase + slot * sixteenth
                chops.append({"frame": int(start), "durationFrames": int(RATE * 0.3), "cue": cue, "block": phrase_index,
                              "family": family, "padID": pad, "slot": slot, "role": "stab", "transform": "native",
                              "accentFrame": int(start + 2000), "committedFrame": int(cue * take), "sourceStart": pad * 1000,
                              "sourceEnd": pad * 1000 + 100, "speed": 1.0, "reversed": False})
                events.append({"padID": pad, "slot": slot, "startTime": round(start / RATE, 3), "transform": "native",
                               "padKey": format(pad_keys[pad], "x")})
                elements.append((pad_keys[pad], slot))
            blocks.append({"phrase": phrase_index, "family": family, "section": "theme", "change": "establish",
                           "noDialogue": False, "events": events, "fingerprint": format(block_fingerprint(family, elements), "x")})
        plans.append({"cue": cue + 1, "bankID": format(cue + 7, "x"), "revision": 0, "blocks": blocks})
    if tamper == "fingerprint":
        plans[0]["blocks"][1]["fingerprint"] = "deadbeef"
    if tamper == "slot":
        chops[3]["slot"] += 1
    m["dialogueChops"] = chops
    m["diagnostics"] = {"dialoguePlans": plans}
    return m


def test_plan_fingerprints():
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] in ("C-D1", "C-D2", "C-D3")]
    results = {}
    for label, tamper in (("consistent", None), ("tampered fingerprint", "fingerprint"), ("moved slot", "slot")):
        cap = Capture(manifest=v2_plan_manifest(tamper), arrays={})
        cad = cadence.measure_cadence(cap)
        res = evaluate({"cadence": cad}, cap, criteria)
        results[label] = (cad, result(res, "C-D3"))
    cad, r = results["consistent"]
    expect(cad["plan"]["fingerprintAgreement"]["blocksChecked"] == 8 and not cad["fingerprintAgreement"]["disagreements"],
           "logged and recomputed fingerprints agree on a consistent plan log (8 blocks)")
    expect(r["status"] == "pass", "C-D3 passes when fingerprints agree")
    for label in ("tampered fingerprint", "moved slot"):
        cad, r = results[label]
        expect(len(cad["fingerprintAgreement"]["disagreements"]) >= 1 and "fingerprintDisagreements" in r.get("failedChecks", []),
               f"{label}: the disagreement between logged and recomputed fingerprints is detected")
    cap = Capture(manifest=v2_plan_manifest(), arrays={})
    d1 = result(evaluate({"cadence": cadence.measure_cadence(cap)}, cap, criteria), "C-D1")
    expect(d1["status"] == "pass" and d1["values"]["pairs"] == 1, f"C-D1 reads the plan log (min difference {d1['values'].get('minDifference')})")


def trace_csv(limiter_db_by_second, seconds, hop=64):
    rows = ["frame,glue_db,clip_db,limiter_db"]
    for f in range(0, seconds * RATE, hop):
        rows.append(f"{f},0.000,0.000,{limiter_db_by_second[min(f // RATE, seconds - 1)]:.3f}")
    return "\n".join(rows).encode()


def test_gain_reduction_trace():
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-M6"]
    seconds = 20
    reduction = [4.0 if (s // 2) % 2 else 0.0 for s in range(seconds)]
    t = np.arange(seconds * RATE) / RATE
    sec = np.minimum(t.astype(int), seconds - 1)
    # Louder seconds are the reduced ones; the master is the pre-master with that gain applied.
    amp = np.array([0.2 if r > 0 else 0.05 for r in reduction])[sec]
    pre = amp * np.sin(2 * np.pi * 440 * t)
    gain = 10 ** (-np.array(reduction)[sec] / 20)
    arrays = {"pre-master": stereo(pre), "master": stereo(pre * gain)}
    for label, trace, want_warn in (("matching trace", reduction, False), ("zero trace", [0.0] * seconds, True)):
        m = manifest(len(pre), diagnostics={"masterDynamics": {"latencyFrames": 0, "ceilingDbtp": -1.0}})
        cap = Capture(manifest=m, arrays=arrays)
        dyn = dynamics.measure_dynamics(cap, dynamics.parse_gr_csv(trace_csv(trace, seconds)))
        r = result(evaluate({"dynamics": dyn}, cap, criteria), "C-M6")
        cc = dyn["crossCheck"]
        expect(cc["warn"] == want_warn, f"{label}: engine p95 {cc['engineTotalP95Db']:.2f} dB, inferred {cc['inferredP95Db']:.2f} dB, "
               f"disagreement {cc['p95DisagreementDb']:.2f} dB, warn={cc['warn']}")
        expect(r["values"].get("source") == "engine" and bool(r.get("notes")) == want_warn,
               f"{label}: C-M6 uses the engine trace and {'notes' if want_warn else 'does not note'} the disagreement")


def kick_burst_track(frames, kicks, shift_frames=0, amp=0.5):
    out = np.zeros(frames)
    burst = np.exp(-np.arange(int(0.3 * RATE)) / (0.08 * RATE)) * tone(60, 0.3, amp)
    for k in kicks:
        k = k + shift_frames
        out[k:k + len(burst)] += burst[: max(0, min(len(burst), frames - k))]
    return out


def test_bass_attack_lag():
    """C-B2 lag comes from the audio: the bass stem is the kick burst shifted by a known amount, while the
    engine's self-report claims zero lag in every case."""
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-B2"]
    frames = RATE * 8
    kicks = [int(RATE * (0.5 + 0.857 * i)) for i in range(8)]
    drums = kick_burst_track(frames, kicks)
    for label, late_ms, want in (("on the kick", 0.0, "pass"), ("8 ms late", 8.0, "fail"), ("8 ms early", -8.0, "fail"),
                                 ("3 ms late", 3.0, "pass")):
        late = int(round(RATE * late_ms / 1000))
        bass = kick_burst_track(frames, kicks, late, amp=0.4)
        notes = [{"frame": k - 100, "attackFrame": k, "alignedKickFrame": k, "midi": 36} for k in kicks]
        diag = {"bass": [{"phrase": 0, "voice": "roundSub", "notes": notes}],
                "landmarks": [{"take": 0, "name": "t", "kicks": [{"frame": k, "peakFrame": k + 500, "strength": 1, "confidence": 1}
                                                                for k in kicks]}]}
        cap = Capture(manifest=manifest(frames, diagnostics=diag), arrays={"drums": stereo(drums), "bass": stereo(bass)})
        kb = lowend.measure_kick_bass(cap)
        r = result(evaluate({"kickBass": kb}, cap, criteria), "C-B2")
        failed = "lagMsMedian" in (r.get("failedChecks") or [])
        expect(failed == (want == "fail") and abs(kb["lagMsSignedMedian"] - late_ms) < 0.3
               and kb["lagSource"].startswith("audio") and kb["engineLag"]["medianMs"] == 0.0,
               f"bass {label}: audio lag {kb['lagMsSignedMedian']:+.2f} ms (engine self-report {kb['engineLag']['medianMs']:.1f} ms) "
               f"gives lagMsMedian {'fail' if failed else 'pass'}")
        expect(abs(kb["peakLagMsSignedMedian"] - late_ms) < 0.3, f"bass {label}: envelope-peak lag {kb['peakLagMsSignedMedian']:+.2f} ms")


def noise(seconds, amp, seed):
    return np.random.default_rng(seed).normal(0, amp, int(seconds * RATE))


def test_all_piece_sii():
    """C-B8 all-piece SII: short dry pieces (0.3 s, never merged into a featured chop) of white noise over a
    white-noise bed at a known SNR. The proxy is 0.5 at 0 dB and rises 1/30 per dB."""
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-B8"]
    seconds = 12
    frames = RATE * seconds
    starts = [int(RATE * (0.5 + 0.8 * i)) for i in range(12)]
    piece = int(0.3 * RATE)
    # Tucked chops (19 November 2026): the floor 0.30 is about -6 dB, so 0 dB pieces pass and -9 dB fail.
    for label, snr_db, want in (("-9 dB", -9.0, "fail"), ("0 dB", 0.0, "pass")):
        rival = noise(seconds, 0.02, 3)
        speech = np.zeros(frames)
        src = noise(seconds, 0.02 * 10 ** (snr_db / 20), 4)
        for f in starts:
            speech[f:f + piece] = src[f:f + piece]
        m = manifest(frames, dialogueChops=[{"frame": f, "durationFrames": piece, "dryFrames": piece, "cue": 0,
                                             "sourceStart": 0, "sourceEnd": piece, "speed": 1.0} for f in starts])
        cap = Capture(manifest=m, arrays={"dialogue-chops": stereo(speech), "texture": stereo(rival)})
        grid = BandGrid(RATE)
        grids = {sec: grid.for_section(cap, sec) for sec in ("dialogue", "mids") if cap.has_section(sec)}
        d = dialogue.measure_dialogue(cap, grid, grids)
        ap = d["allPieces"]
        r = result(evaluate({"dialogue": d}, cap, criteria), "C-B8")
        status = "fail" if "allPiecesSiiMean" in (r.get("failedChecks") or []) else "pass"
        theory = 0.5 + snr_db / 30
        expect(ap["count"] == 12 and "featuredSkipped" in d and abs(ap["siiMean"] - theory) < 0.06 and status == want,
               f"{label} pieces: {ap['count']} scored, all-piece SII {ap['siiMean']:.3f} (theory {theory:.2f}), "
               f"featured skipped, allPiecesSiiMean {status}")


def test_featured_snr_time_weighting():
    """A half-second solo and a two-second line contribute in proportion to their time."""
    rng = np.random.default_rng(181)
    rival = rng.normal(0, 0.025, 4 * RATE)
    hits = [(RATE // 4, RATE // 2), (RATE, 2 * RATE)]
    for levels, should_fail in [([8, 0], False), ([5.7, 5.7], True)]:
        speech = np.zeros_like(rival)
        for (start, length), level in zip(hits, levels):
            speech[start:start + length] = rival[start:start + length] * 10 ** (level / 20)
        events = [{"frame": a, "durationFrames": n, "dryFrames": n} for a, n in hits]
        cap = Capture(manifest=manifest(len(rival), dialogueChops=events),
                      arrays={"dialogue-chops": stereo(speech), "texture": stereo(rival)})
        grid = BandGrid(RATE)
        grids = {s: grid.for_section(cap, s) for s in ("dialogue", "mids")}
        measured = dialogue.measure_dialogue(cap, grid, grids)
        expected = np.average(levels, weights=[n for _, n in hits])
        expect(abs(measured["snr1to4kMeanDb"] - expected) < 0.15 and
               abs(measured["snr1to4kEventMeanDb"] - np.mean(levels)) < 0.15,
               "featured SNR reports both presented-time and per-event means")
        criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-B8"]
        checks = result(evaluate({"dialogue": measured}, cap, criteria), "C-B8").get("failedChecks") or []
        expect(("snr1to4kMeanDb" in checks) == should_fail, "C-B8 retains its upper SNR bound")


def test_authored_chop_levels():
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-B8"]
    grid = BandGrid(RATE)
    phrase = tone(950, 0.6, 0.1)
    for residual, include_gain, fail in [(0, True, False), (-4, True, True), (0, False, True)]:
        dry = np.zeros(3 * RATE)
        events = []
        for i, gain in enumerate([0, -3, 0]):
            a = i * RATE + RATE // 5
            dry[a:a + len(phrase)] = phrase * 10 ** ((gain + (residual if i == 1 else 0)) / 20)
            e = {"frame": a, "durationFrames": len(phrase), "dryFrames": len(phrase)}
            if include_gain:
                e["authoredGainDB"] = gain
            events.append(e)
        cap = Capture(manifest=manifest(len(dry), dialogueChops=events),
                      arrays={"dialogue-chops": stereo(dry), "dialogue-dry": stereo(dry),
                              "texture": stereo(tone(950, 3, 0.1))})
        grids = {s: grid.for_section(cap, s) for s in ("dialogue", "mids")}
        d = dialogue.measure_dialogue(cap, grid, grids)
        checks = result(evaluate({"dialogue": d}, cap, criteria), "C-B8").get("failedChecks") or []
        expect(abs(d["rawLoudnessSpreadLu"] - abs(-3 + residual)) < 0.01 and
               (("loudnessSpreadLu" in checks) == fail), "authored trim, unmatched pad and legacy raw spread")
    overlap = [{"frame": 0, "durationFrames": 100, "authoredGainDB": 0},
               {"frame": 90, "durationFrames": 40, "authoredGainDB": -3}]
    spans = dialogue.authored_levels(overlap)
    expect(dialogue.untrimmed_dry_lufs(np.zeros((130, 2)), RATE, 0, 130, spans, -20) is None,
           "overlapping differently trimmed events retain the raw check")


def test_lead_salience():
    """C-B11: a 1 kHz lead over a 2 kHz dialogue at a known level difference in every lead note."""
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-B11"]
    seconds = 10
    frames = RATE * seconds
    ons = [int(RATE * (0.5 + 0.9 * i)) for i in range(10)]
    score = [{"section": "theme", "range": [0, frames],
              "notes": [{"role": "lead", "on": on, "off": on + int(0.6 * RATE)} for on in ons]}]
    for label, diff_db, want in (("lead 6 dB over the dialogue", 6.0, "pass"), ("lead 6 dB under", -6.0, "warn")):
        lead = np.zeros(frames)
        carrier = tone(1000, seconds, 0.1)
        for on in ons:
            lead[on:on + int(0.6 * RATE)] = carrier[on:on + int(0.6 * RATE)]
        talk = tone(2000, seconds, 0.1 * 10 ** (-diff_db / 20))
        cap = Capture(manifest=manifest(frames), arrays={"dry": stereo(lead), "dialogue-chops": stereo(talk)}, score=score)
        ls = music.measure_lead_salience(cap)
        r = result(evaluate({"leadSalience": ls}, cap, criteria), "C-B11")
        expect(ls["notes"] == 10 and abs(ls["medianLeadMinusDialogueDb"] - diff_db) < 0.3
               and abs(ls["medianLeadMinusOthersDb"] - diff_db) < 0.3 and r["status"] == want,
               f"{label}: lead minus dialogue {ls['medianLeadMinusDialogueDb']:+.2f} dB, under the dialogue in "
               f"{ls['underDialogueFraction']:.0%} of notes, C-B11 {r['status']}")


def test_lead_time_simulation():
    """C-D6 reads the live-order fields: p50, p95 and max of the stage totals, the per-cue lead, and the
    optional thermal and memory fields; an event committed under 0.30 s ahead fails."""
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-D6"]
    for label, lead_s, want in (("1.2 s lead", 1.2, "pass"), ("0.2 s lead", 0.2, "fail")):
        m = manifest(RATE * 20)
        timings, chops = [], []
        for cue, total in enumerate((400.0, 600.0, 800.0)):
            start = RATE * (2 + 5 * cue)
            committed = start - int(lead_s * RATE)
            timings.append({"cue": cue, "classifyMs": total / 2, "analyzeMs": total / 4, "bankMs": 10, "planMs": 5,
                            "renderMs": total / 4 - 15, "totalMs": total, "wallMs": total + 20,
                            "analysisStartFrame": committed - int((total + 20) / 1000 * RATE), "committedFrame": committed,
                            "leadSeconds": lead_s, "thermalState": "nominal", "residentMB": 300 + cue})
            chops.append({"frame": start, "durationFrames": RATE // 4, "committedFrame": committed, "cue": cue,
                          "sourceStart": 0, "sourceEnd": 10, "speed": 1.0})
        m["dialogueTimings"], m["dialogueChops"] = timings, chops
        cap = Capture(manifest=m, arrays={})
        cad = cadence.measure_cadence(cap)
        r = result(evaluate({"cadence": cad}, cap, criteria), "C-D6")
        st = cad["stageTiming"]
        expect(st["totalMsP50"] == 600.0 and abs(st["totalMsP95"] - 780.0) < 1e-6 and st["totalMsMax"] == 800.0
               and st["residentMB"]["max"] == 302 and st["thermalState"]["last"] == "nominal"
               and cad["leadModel"].startswith("live-order") and r["status"] == want,
               f"{label}: stage totals p50 {st['totalMsP50']:.0f} / p95 {st['totalMsP95']:.0f} / max {st['totalMsMax']:.0f} ms, "
               f"lead min {cad['leadSecondsMin']:.2f} s, C-D6 {r['status']}")
    m = manifest(RATE * 4)
    m["dialogueTimings"] = [{"cue": 0, "totalMs": 100.0}]
    st = cadence.measure_cadence(Capture(manifest={**m, "dialogueChops": [{"frame": RATE, "durationFrames": 100, "cue": 0}]},
                                         arrays={}))["stageTiming"]
    expect("thermalState" not in st and st["count"] == 1, "missing optional timing fields are tolerated")


def test_kick_attack_not_measured():
    """C-B4 without a stemChains attack ratio says 'not measured' instead of passing it silently."""
    criteria = [c for c in load_criteria(CRITERIA) if c["id"] == "C-B4"]
    m = {"crest": {"buses": {"drums": {"crestDb": 12.0, "samplePeakDbfs": -6.0}}}, "stemChains": [{"bus": "drums", "outPeakDb": -6.0}]}
    cap = Capture(manifest=manifest(RATE), arrays={})
    r = result(evaluate(m, cap, criteria), "C-B4")
    expect(r["values"].get("kickAttackRatio") == "not measured" and any("not measured" in x for x in r.get("skippedChecks", []))
           and any("NOT MEASURED" in n for n in r.get("notes", [])),
           "C-B4 marks the kick attack ratio 'not measured' when stemChains has none")
    m["stemChains"][0]["kickAttackRatio"] = 1.5
    r = result(evaluate(m, cap, criteria), "C-B4")
    expect(r["status"] == "warn" and "kickAttackRatioMax" in r.get("failedChecks", []), "a stemChains attack ratio of 1.5 warns C-B4")


def test_nofilm_master_gating():
    """The master criteria evaluate on nofilm with its own loudness window; film-only criteria stay skipped."""
    criteria = load_criteria(CRITERIA)
    cap = Capture(manifest={**manifest(RATE), "hasFootage": False}, arrays={}, case="nofilm")
    metrics = {"loudness": {"integratedLufs": -14.8, "lraLu": 2.4}, "crest": {"plrDb": 13.6, "master": {"crestDb": 15.5}},
               "truePeak": {"ffmpegDbtp": -0.5, "reconstructionDbtp": -0.6}}
    res = {r["id"]: r for r in evaluate(metrics, cap, criteria)}
    expect(res["C-M1"]["status"] == "pass" and res["C-M3"]["status"] == "pass" and res["C-M5"]["status"] == "pass",
           "nofilm reads C-M1, C-M3 and C-M5 against its music-only window (-14.8 LUFS, PLR 13.6, crest 15.5 pass)")
    on_ref = {r["id"]: r for r in evaluate(metrics, Capture(manifest=manifest(RATE), arrays={}, case="ref"), criteria)}
    expect(on_ref["C-M1"]["status"] == "fail", "the same -14.8 LUFS fails C-M1 on ref (-14.5 to -12.5 LUFS)")
    expect(res["C-M2"]["status"] == "fail", "nofilm keeps the true-peak bound (-0.5 dBTP fails C-M2)")
    expect(res["C-B8"]["status"] == "skipped" and res["C-D1"]["status"] == "skipped", "dialogue and bed criteria stay skipped on nofilm")


def test_engine_paths_skip_cleanly():
    """No plan log, landmarks, trace or bass diagnostics: the criteria skip or fall back, never error."""
    m = manifest(RATE * 8)
    m["dialogueChops"] = [{"frame": RATE, "durationFrames": RATE // 2, "sourceStart": 1, "sourceEnd": 2, "speed": 1.0, "cue": 0}]
    cap = Capture(manifest=m, arrays={})
    cad = cadence.measure_cadence(cap)
    res = evaluate({"cadence": cad}, cap, [c for c in load_criteria(CRITERIA) if c["id"].startswith("C-D")])
    expect(all(r["status"] != "error" for r in res) and result(res, "C-D8")["status"] == "skipped",
           "C-D criteria evaluate without a plan log, and C-D8 skips without accents")


def test_bass_tone():
    """scripts/bass-tone.py on a synthetic capture: a 55 Hz tone with a decaying 600 Hz burst on each note
    reads its strike contrast and timing, sounding ratio and dark sustain."""
    import importlib.util
    import json
    spec = importlib.util.spec_from_file_location("bass_tone", Path(__file__).resolve().parent.parent / "bass-tone.py")
    bt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bt)
    beat = int(RATE * 60 / 70)
    frames = 16 * beat
    x = np.zeros(frames)
    notes, rows = [], []
    for k in range(8):
        on = k * 2 * beat
        off = on + 2 * beat - int(0.08 * RATE)
        t = np.arange(off + int(0.07 * RATE) - on) / RATE
        env = np.minimum(1, t / 0.004) * np.where(t < (off - on) / RATE, 1.0, 0.0)
        burst = 0.3 * np.exp(-t / 0.008) * np.sin(2 * np.pi * 600 * t)
        x[on:on + len(t)] += 0.3 * np.sin(2 * np.pi * 55 * t) * env + burst
        notes.append({"frame": on, "alignedKickFrame": on, "attackFrame": on, "stroke": "walk"})
        rows.append({"role": "bass", "on": on, "off": off, "midi": 33, "strike": 1.0, "release": 0.07,
                     "stroke": "walk", "velocity": 0.8, "send": 0, "color": 0.5})
    with tempfile.TemporaryDirectory() as d:
        write_wav(Path(d) / "bass.wav", x, RATE)
        write_wav(Path(d) / "drums.wav", np.zeros(frames), RATE)
        (Path(d) / "score.json").write_text(json.dumps([{"section": "theme", "range": [0, frames], "notes": rows}]))
        (Path(d) / "manifest.json").write_text(json.dumps(manifest(frames, diagnostics={"bass": [
            {"phrase": 0, "voice": "flatwound", "notes": notes}]})))
        r = bt.analyze(d)
    s = r["strike"]
    expect(s["struckNotes"] == 8, f"bass-tone: 8 struck notes ({s['struckNotes']})")
    expect(s["contrastMedian"] > 20, f"bass-tone: burst contrast {s['contrastMedian']:.1f} dB over 20")
    expect(s["timingAbsMedian"] <= 6, f"bass-tone: burst peak {s['timingAbsMedian']:.1f} ms from the kick")
    expect(s["brightestFirstShare"] == 1.0, "bass-tone: the first 15 ms is the brightest window")
    expect(r["soundingMedian"] >= 0.95, f"bass-tone: sounding ratio {r['soundingMedian']:.2f}")
    expect(r["thirds"][1000] < -40, f"bass-tone: little at 1 kHz ({r['thirds'][1000]:.1f} dB)")


# ------------------------------------------------------------------------------------- translation report

def test_translation_mono_change():
    """Identical channels 0 dB, independent equal-power noise -3.01 dB, inverted channels cancelled, silence gated."""
    from . import translation as tr
    rng = np.random.default_rng(3)
    a, b = rng.standard_normal(RATE * 4) * 0.1, rng.standard_normal(RATE * 4) * 0.1

    def change(x, y):
        m = (x + y) / 2
        return tr.mono_change_db(float(np.mean(x ** 2)), float(np.mean(y ** 2)), float(np.mean(m ** 2)))
    v, st = change(a, a)
    expect(st == "ok" and abs(v) < 1e-9, f"translation: identical channels fold at 0 dB ({v})")
    v, st = change(a, b)
    expect(st == "ok" and abs(v + 3.01) <= 0.15, f"translation: independent noise folds at -3.01 dB ({v:.2f})")
    v, st = change(a, -a)
    expect(st == "cancelled" and v == float("-inf"), f"translation: inverted channels reported as cancelled ({st}, {v})")
    v, st = change(np.zeros(100), np.zeros(100))
    expect(st == "gated" and v is None, "translation: silence is gated, never divided")
    # The same through the STFT band powers used by the report.
    hops = tr.BandHops(RATE)
    h = hops.compute(np.stack([a, b], axis=1))
    j = hops.col("400-900")
    v, _ = tr.mono_change_db(float(h["L"][:, j].mean()), float(h["R"][:, j].mean()), float(h["M"][:, j].mean()))
    expect(abs(v + 3.01) <= 0.3, f"translation: band mono change of independent noise {v:.2f} dB")


def test_translation_transforms():
    """mono-hp180 attenuates 55 Hz by its analytic response, passes 400 Hz, and the 7 kHz low-pass cuts 12 kHz."""
    from . import translation as tr
    sos = tr.filter_sos(180, RATE)
    for f, check in ((55, None), (400, 0.3), (12000, None)):
        x = tone(f, 4, 0.5)
        y = tr.apply_transform(stereo(x), "mono-hp180", RATE)[RATE:, 0]
        got = 20 * np.log10(np.sqrt(np.mean(y ** 2)) / (0.5 / np.sqrt(2)))
        _, hresp = __import__("scipy.signal", fromlist=["sosfreqz"]).sosfreqz(sos, worN=[f], fs=RATE)
        analytic = 20 * np.log10(abs(hresp[0]))
        if f == 55:
            expect(abs(got - analytic) <= 0.5 and got < -40, f"translation: 55 Hz through mono-hp180 {got:.1f} dB (analytic {analytic:.1f})")
        elif f == 400:
            expect(abs(got) <= check, f"translation: 400 Hz through mono-hp180 {got:.2f} dB")
        else:
            expect(got < -10, f"translation: 12 kHz attenuated by the 7 kHz low-pass ({got:.1f} dB)")
    # Mono arithmetic: opposite channels fold to silence, a one-sided signal halves.
    x = tone(500, 1, 0.4)
    y = tr.apply_transform(stereo(x, -x), "mono", RATE)
    expect(np.max(np.abs(y)) < 1e-6, "translation: (L + R) / 2 of opposite channels is silent")
    y = tr.apply_transform(stereo(x, np.zeros_like(x)), "mono", RATE)
    expect(np.allclose(y[:, 0], x / 2, atol=1e-6), "translation: (L + R) / 2 of a one-sided signal is half of it")


def test_translation_band_rms():
    """Two tones of known amplitude land in their own bands within 0.2 dB."""
    from . import translation as tr
    x = tone(113, 6, 0.3) + tone(600, 6, 0.05)
    hops = tr.BandHops(RATE)
    h = hops.compute(stereo(x))
    for band, amp in (("80-160", 0.3), ("400-900", 0.05)):
        got = tr.db10(float(h["M"][20:-20, hops.col(band)].mean()))
        want = 20 * np.log10(amp / np.sqrt(2))
        expect(abs(got - want) <= 0.2, f"translation: band {band} reads {got:.2f} dB, expected {want:.2f}")
    leak = tr.db10(float(h["M"][20:-20, hops.col("2000-5000")].mean()))
    expect(leak < -80, f"translation: nothing in 2-5 kHz ({leak:.1f} dB)")


def _note(f0, seconds, partials, rate=RATE):
    t = np.arange(int(seconds * rate)) / rate
    return sum(a * np.sin(2 * np.pi * k * f0 * t) for k, a in partials)


def test_translation_proxies():
    """Pure 55 Hz is not identifiable at HP180; 220 + 275 Hz partials over noise 12 dB under them are; the same
    partials 12 dB under the noise are not; one partial alone is not; the masker is the stem holding the noise."""
    from . import translation as tr
    rng = np.random.default_rng(5)
    n = RATE
    ref = {c: -20.0 for c in tr.CUTOFFS}
    pure = _note(55, 1, [(1, 0.3)])
    quiet = rng.standard_normal(n) * 1e-4
    p = tr.window_proxies(pure, {"texture": quiet}, RATE, 55.0, solo_ref_db=ref)["180"]
    expect(not p["identifiable"] and not p["identifiableSolo"] and p["survivalDb"] < -40,
           f"translation: pure 55 Hz at HP180 not identifiable, survival {p['survivalDb']:.1f} dB")
    bass = _note(55, 1, [(1, 0.3), (4, 0.03), (5, 0.03)])
    noise = rng.standard_normal(n)
    # Scale the noise so its third octave at 220 Hz sits 12 dB under (or over) the 220 Hz partial.
    freqs, pn = tr.power_spectrum(noise, RATE)
    third = float(pn[tr.third_octave(freqs, 220.0)].sum())
    partial = 0.03 ** 2 / 2
    under = noise * np.sqrt(partial / third * 10 ** (-12 / 10))
    over = noise * np.sqrt(partial / third * 10 ** (12 / 10))
    p = tr.window_proxies(bass, {"texture": under, "wet": under * 0.1}, RATE, 55.0, solo_ref_db=ref)["180"]
    expect(p["identifiable"] and p["audibleHarmonics"] >= 2, f"translation: partials 12 dB over the noise identifiable ({p['harmonics']})")
    p = tr.window_proxies(bass, {"texture": over, "wet": over * 0.1}, RATE, 55.0, solo_ref_db=ref)["180"]
    expect(not p["identifiable"] and p["identifiableSolo"], "translation: partials 12 dB under the noise not identifiable, but solo they are")
    expect(p["maskers"] and set(p["maskers"]) == {"texture"}, f"translation: the masker is the stem holding the noise ({p['maskers']})")
    single = _note(55, 1, [(1, 0.3), (4, 0.03)])
    p = tr.window_proxies(single, {"texture": under}, RATE, 55.0, solo_ref_db=ref)["180"]
    expect(not p["identifiable"] and not p["identifiableSolo"], "translation: one partial alone is not identifiable")
    expect(tr.window_proxies(np.zeros(n), {"texture": under}, RATE, 55.0, solo_ref_db=ref) is None,
           "translation: a silent bass window is gated")


def _synthetic_capture(d, latency=200, gain_db=4.0, stage_db=-2.0, seconds=6, trace=None):
    """Stems, pre-master, master and a gain trace with a known chain (the delivered-stem fixture)."""
    import json
    from . import delivery
    rng = np.random.default_rng(9)
    n = RATE * seconds
    stems = {"drums": rng.standard_normal((n, 2)) * 0.05, "bass": stereo(tone(55, seconds, 0.2)).astype(np.float64),
             "texture": rng.standard_normal((n, 2)) * 0.02, "dry": stereo(tone(440, seconds, 0.05)).astype(np.float64),
             "wet": rng.standard_normal((n, 2)) * 0.02, "dialogue-chops": np.zeros((n, 2)), "footage": rng.standard_normal((n, 2)) * 0.01}
    stage = 10 ** (stage_db / 20)
    pre = sum(stems.values()) * stage
    hop = 64
    frames = np.arange(0, n, hop)
    gr = trace if trace is not None else np.column_stack([frames, 1.0 + 0.5 * np.sin(frames / RATE), np.zeros(len(frames)),
                                                          np.where((frames > 2 * RATE) & (frames < 3 * RATE), 0.8, 0.0)])
    env = delivery.gain_envelope(gr, n)
    chain = delivery.MasterChain(RATE, 1.0, latency, 10 ** (gain_db / 20), env)
    master = chain.apply(pre, staged=False)
    for k, v in stems.items():
        write_wav(Path(d) / f"{k}.wav", v.astype(np.float32), RATE)
    write_wav(Path(d) / "pre-master.wav", pre.astype(np.float32), RATE)
    write_wav(Path(d) / "master.wav", master.astype(np.float32), RATE)
    with open(Path(d) / "master-gr.csv", "w") as f:
        f.write("frame,glue_db,clip_db,limiter_db\n")
        for row in gr:
            f.write(f"{int(row[0])},{row[1]:.6f},{row[2]:.6f},{row[3]:.6f}\n")
    m = manifest(n, diagnostics={"masterDynamics": {"preMasterStagingDb": stage_db, "latencyFrames": latency,
                                                    "settings": {"highpassHz": 25}, "traceFile": "master-gr.csv"}})
    (Path(d) / "manifest.json").write_text(json.dumps(m))
    return stems, master


def test_translation_delivery():
    """Delivered stems with a known gain trace sum back to the master under -80 dB; a wrong latency is refused."""
    from . import delivery
    with tempfile.TemporaryDirectory() as d:
        _synthetic_capture(d, latency=203)
        stems, chain = delivery.delivered_stems(d)
        expect(chain.latency == 203, f"translation: fitted latency {chain.latency} (203)")
        expect(chain.sum_residual_db < -80, f"translation: delivered stems sum to the master at {chain.sum_residual_db:.1f} dB")
        expect(abs(20 * np.log10(chain.gain) - 4.0) < 0.01, f"translation: fitted finisher gain {20 * np.log10(chain.gain):+.3f} dB")
        wrong = delivery.MasterChain(RATE, chain.stage, chain.latency + 7, chain.gain, chain.env)
        try:
            delivery.delivered_stems(d, wrong)
            expect(False, "translation: a wrong latency must be refused")
        except ValueError:
            pass


def test_translation_pair_match():
    """Pair gains are linear, equal across the three transforms of a pair, and match full-range loudness within 0.1 LU."""
    from . import translation as tr
    from .loudness import measure_loudness
    rng = np.random.default_rng(11)
    base = stereo(tone(60, 8, 0.2) + tone(300, 8, 0.05)) + rng.standard_normal((RATE * 8, 2)) * 0.01
    cand = base * 10 ** (2.5 / 20) + stereo(tone(240, 8, 0.03))
    stress = ("mono-hp180", "mono-hp250")
    sb = {t: tr.apply_transform(base, t, RATE) for t in stress}
    sc = {t: tr.apply_transform(cand, t, RATE) for t in stress}
    g = tr.pair_gains(base, cand, RATE, sb, sc)
    lb = measure_loudness(base * 10 ** (g["baseGainDb"] / 20), RATE)["integratedLufs"]
    lc = measure_loudness(cand * 10 ** (g["candGainDb"] / 20), RATE)["integratedLufs"]
    expect(abs(lb - lc) <= 0.1, f"translation: matched loudness {lb:.2f} vs {lc:.2f} LUFS")
    expect(g["baseGainDb"] <= 0 and g["candGainDb"] <= 0, "translation: pair gains only turn down")
    # The stress files of a pair take the same capture gains plus one common gain: their difference is the
    # same as the full-range pair's.
    for t in stress:
        expect(set(g["stressCommonGainDb"]) == set(stress), "translation: one common stress gain per transform")
    diff = g["candGainDb"] - g["baseGainDb"]
    expect(abs(diff - (g["candGainDb"] + g["stressCommonGainDb"]["mono-hp180"] - g["baseGainDb"] - g["stressCommonGainDb"]["mono-hp180"])) < 1e-12,
           "translation: equal relative gain across transforms")


def test_translation_integrity():
    """An injected DC offset, a NaN and a phrase-boundary step are each reported."""
    import json
    from . import translation as tr
    with tempfile.TemporaryDirectory() as d:
        n = RATE * 8
        pf = n // 2
        bass = tone(55, 8, 0.2)
        bass[:pf] += 0.01                       # DC in phrase 0
        wet = tone(300, 8, 0.05)
        wet[pf:] += 0.2                         # a step at the boundary
        master = stereo(tone(100, 8, 0.1))
        master[RATE, 1] = np.nan
        write_wav(Path(d) / "bass.wav", stereo(bass), RATE)
        write_wav(Path(d) / "wet.wav", stereo(wet), RATE)
        write_wav(Path(d) / "master.wav", master, RATE)
        m = manifest(n)
        m["grid"]["phraseFrames"] = pf
        (Path(d) / "manifest.json").write_text(json.dumps(m))
        g = tr.integrity_block(Path(d), m)
    expect(g["bassDcDbfsPerPhrase"][0] > -45 and g["bassDcDbfsPerPhrase"][1] < -60,
           f"translation: DC reported in phrase 0 only ({g['bassDcDbfsPerPhrase']})")
    expect(g["nonFinite"].get("master") == 1 and not g["allFinite"], f"translation: the NaN is reported ({g['nonFinite']})")
    st = g["boundarySteps"]["wet"]
    expect(st["maxAtBoundary"] > 0.15 and st["maxAtBoundary"] > 5 * st["p9999Elsewhere"],
           f"translation: the boundary step is reported ({st['maxAtBoundary']:.3f} vs {st['p9999Elsewhere']:.3f})")
    expect(g["bassLrNullMaxAbs"] == 0.0, "translation: dual-mono bass nulls exactly")


TRANSLATION_TESTS = [test_translation_mono_change, test_translation_transforms, test_translation_band_rms,
                     test_translation_proxies, test_translation_delivery, test_translation_pair_match,
                     test_translation_integrity]


def run_translation_self_test():
    return _run_tests(TRANSLATION_TESTS)


def _run_tests(tests):
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


def run_self_test():
    return _run_tests([test_loudness_and_peak, test_masking, test_cadence, test_kick_bass, test_lowband_mono, test_pumping,
                       test_full_pipeline_v1, test_plan_fingerprints, test_gain_reduction_trace, test_bass_attack_lag,
                       test_all_piece_sii, test_featured_snr_time_weighting, test_authored_chop_levels, test_lead_salience, test_lead_time_simulation, test_kick_attack_not_measured,
                       test_nofilm_master_gating, test_engine_paths_skip_cleanly, test_bass_tone] + TRANSLATION_TESTS)
