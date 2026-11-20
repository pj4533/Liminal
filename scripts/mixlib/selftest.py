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
    for label, snr_db, want in (("0 dB", 0.0, "fail"), ("+9 dB", 9.0, "pass")):
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
    metrics = {"loudness": {"integratedLufs": -13.3, "lraLu": 2.4}, "crest": {"plrDb": 12.1, "master": {"crestDb": 14.0}},
               "truePeak": {"ffmpegDbtp": -0.5, "reconstructionDbtp": -0.6}}
    res = {r["id"]: r for r in evaluate(metrics, cap, criteria)}
    expect(res["C-M1"]["status"] == "pass" and res["C-M3"]["status"] == "pass" and res["C-M5"]["status"] == "pass",
           "nofilm reads C-M1, C-M3 and C-M5 against its music-only window (-13.3 LUFS, PLR 12.1, crest 14.0 pass)")
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


def run_self_test():
    tests = [test_loudness_and_peak, test_masking, test_cadence, test_kick_bass, test_lowband_mono, test_pumping,
             test_full_pipeline_v1, test_plan_fingerprints, test_gain_reduction_trace, test_bass_attack_lag,
             test_all_piece_sii, test_lead_salience, test_lead_time_simulation, test_kick_attack_not_measured,
             test_nofilm_master_gating, test_engine_paths_skip_cleanly]
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

