#!/usr/bin/env python3
"""Validate a synchronized Liminal Lo-Fi studio capture and retain JSON evidence."""

import argparse
from array import array
from contextlib import ExitStack
import json
import math
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile


BUSES = (
    "drums", "bass", "dry", "texture", "wet", "footage-dry", "footage-delay",
    "footage-room", "lofi", "footage", "pre-master", "glue", "master",
)
FOOTAGE_BUSES = ("footage-dry", "footage-delay", "footage-room", "footage")
ROUTING_TOLERANCE = 2e-6
SILENCE_FLOOR = 1e-7
OCCUPANCY_FLOOR = 10 ** (-50 / 20)
CHUNK_FRAMES = 8192
FLOAT_GUID = bytes.fromhex("0300000000001000800000aa00389b71")


class AudioCheckError(RuntimeError):
    """An input or measurement could not be verified."""


class FloatWave:
    def __init__(self, path, files):
        self.path = path
        self.file = files.enter_context(path.open("rb"))
        header = self.file.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise AudioCheckError(f"{path.name}: expected a little-endian RIFF WAV")

        actual_bytes = path.stat().st_size
        riff_end = 8 + int.from_bytes(header[4:8], "little")
        if riff_end > actual_bytes:
            raise AudioCheckError(f"{path.name}: truncated RIFF container")

        fmt = None
        data = None
        while self.file.tell() + 8 <= riff_end:
            name, size = struct.unpack("<4sI", self.file.read(8))
            start = self.file.tell()
            if start + size > riff_end:
                raise AudioCheckError(f"{path.name}: truncated WAV chunk {name!r}")
            if name == b"fmt ":
                fmt = self.file.read(min(size, 40))
            elif name == b"data":
                data = (start, size)
            if fmt is not None and data is not None:
                break
            self.file.seek(start + size + (size & 1))

        if fmt is None or len(fmt) < 16 or data is None:
            raise AudioCheckError(f"{path.name}: missing WAV format or audio data")
        encoding, channels, self.rate, _, align, bits = struct.unpack("<HHIIHH", fmt[:16])
        ieee_float = encoding == 3 or (
            encoding == 0xFFFE and len(fmt) >= 40 and fmt[24:40] == FLOAT_GUID
        )
        if not ieee_float or channels != 2 or bits != 32 or align != 8 or self.rate <= 0:
            raise AudioCheckError(f"{path.name}: expected stereo float32 PCM")
        if data[1] % align:
            raise AudioCheckError(f"{path.name}: audio includes an incomplete PCM frame")
        self.frames = data[1] // align
        self.file.seek(data[0])

    def read(self, frames):
        data = self.file.read(frames * 8)
        if len(data) != frames * 8:
            raise AudioCheckError(f"{self.path.name}: short read during PCM analysis")
        samples = array("f", data)
        if sys.byteorder != "little":
            samples.byteswap()
        return samples


def amplitude_db(amplitude):
    return 20 * math.log10(amplitude) if amplitude > 0 else None


class BusStats:
    def __init__(self, rate):
        self.samples = 0
        self.nonfinite = 0
        self.sample_peak = 0.0
        self.power = 0.0
        self.active_frames = 0
        self.longest_active_frames = 0
        self.active_run = 0
        self.window_frames = max(1, round(rate * 0.05))
        self.window_fill = 0
        self.window_power = 0.0

    def finish_window(self):
        if not self.window_fill:
            return
        rms = math.sqrt(self.window_power / (2 * self.window_fill))
        if rms >= OCCUPANCY_FLOOR:
            self.active_frames += self.window_fill
            self.active_run += self.window_fill
            self.longest_active_frames = max(self.longest_active_frames, self.active_run)
        else:
            self.active_run = 0
        self.window_fill = 0
        self.window_power = 0.0

    def add(self, samples):
        self.samples += len(samples)
        sample_index = 0
        while sample_index < len(samples):
            frame_count = min(self.window_frames - self.window_fill,
                              (len(samples) - sample_index) // 2)
            sample_end = sample_index + frame_count * 2
            window = samples[sample_index:sample_end]
            high = max(window)
            low = min(window)
            energy = sum(sample * sample for sample in window)
            if not math.isfinite(energy):
                valid = [sample for sample in window if math.isfinite(sample)]
                self.nonfinite += len(window) - len(valid)
                high = max(valid, default=0)
                low = min(valid, default=0)
                energy = sum(sample * sample for sample in valid)
            self.sample_peak = max(self.sample_peak, abs(high), abs(low))
            self.power += energy
            self.window_power += energy
            self.window_fill += frame_count
            if self.window_fill == self.window_frames:
                self.finish_window()
            sample_index = sample_end

    def summary(self):
        self.finish_window()
        return {
            "nonfiniteSamples": self.nonfinite,
            "samplePeakDbfs": amplitude_db(self.sample_peak),
            "rmsDbfs": amplitude_db(math.sqrt(self.power / max(1, self.samples))),
            "activeFraction50ms": self.active_frames * 2 / max(1, self.samples),
            "longestActiveFrames50ms": self.longest_active_frames,
        }


def summary_number(log, heading, label):
    summary = log.rsplit("Summary:", 1)[-1]
    match = re.search(
        rf"^\s*{heading}:\s*\n\s*{label}:\s*(-?\d+(?:\.\d+)?|-inf)\s",
        summary,
        flags=re.MULTILINE,
    )
    if not match:
        raise AudioCheckError(f"FFmpeg report is missing {heading}")
    value = float(match.group(1))
    return value if math.isfinite(value) else None


def master_meter(path, log_path, *, capture_level_frames=False):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise AudioCheckError("FFmpeg is required for independent loudness and true peak")
    version = subprocess.run([ffmpeg, "-version"], capture_output=True, text=True,
                             check=True).stdout.splitlines()[0]
    metadata = "ametadata=mode=print:file=-"
    if not capture_level_frames:
        metadata += ":key=lavfi.r128.true_peak"
    command = [
        ffmpeg, "-hide_banner", "-nostats", "-i", str(path),
        "-af", f"ebur128=peak=sample+true:framelog=quiet:metadata=1,{metadata}", "-f", "null", "-",
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    log_path.write_text(result.stderr, encoding="utf-8")
    if result.returncode:
        raise AudioCheckError(f"FFmpeg meter failed, see {log_path.name}")
    peaks = re.findall(r"^lavfi\.r128\.true_peak=(\d+(?:\.\d+)?)$", result.stdout, re.MULTILINE)
    metadata_peak = amplitude_db(max(map(float, peaks), default=0))
    summary_peak = summary_number(result.stderr, "True peak", "Peak")
    report = {
        "version": version,
        "integratedLufs": summary_number(result.stderr, "Integrated loudness", "I"),
        "loudnessRangeLu": summary_number(result.stderr, "Loudness range", "LRA"),
        "samplePeakDbfs": summary_number(result.stderr, "Sample peak", "Peak"),
        "truePeakDbtp": metadata_peak if metadata_peak is not None else summary_peak,
        "summaryTruePeakDbtp": summary_peak,
    }
    if capture_level_frames:
        for key, label in (("M", "momentary"), ("S", "shortTerm")):
            report[label] = [float(value) for value in re.findall(
                rf"^lavfi\.r128\.{key}=(-?\d+(?:\.\d+)?)$", result.stdout, re.MULTILINE
            )]
    return report


def analyze(run, true_peak_limit, report):
    manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
    rate = manifest["sampleRate"]
    frames = manifest["frames"]
    has_footage = manifest["hasFootage"]
    if (type(rate) not in (int, float) or not math.isfinite(rate) or rate <= 0
            or not rate == int(rate) or type(frames) is not int or frames <= 0
            or type(has_footage) is not bool or not manifest["schema"]):
        raise AudioCheckError("manifest requires a schema, positive sample rate and frame count, and hasFootage boolean")
    report.update({
        "captureSchema": manifest["schema"],
        "sampleRate": rate,
        "frames": frames,
        "hasFootage": has_footage,
        "occupancyFloorDbfs": amplitude_db(OCCUPANCY_FLOOR),
    })

    # Older captures metered chops before their archive effects. Only the new
    # post-fader tap is a sixth summand of the music bus.
    dialogue_on_music = manifest.get("dialogueOnMusicBus", False)
    buses = BUSES + (("dialogue-chops",) if dialogue_on_music else ())
    if "dialogue-fx" in manifest.get("topology", []):
        buses += ("dialogue-fx",)
    stats = {name: BusStats(rate) for name in buses}
    routing_peak = 0.0
    first_bad_frame = None
    stem_peak = 0.0
    first_bad_stem_frame = None
    nonfinite_routing_samples = 0
    with ExitStack() as files:
        taps = {name: FloatWave(run / f"{name}.wav", files) for name in buses}
        for name, tap in taps.items():
            if tap.rate != rate or tap.frames != frames:
                raise AudioCheckError(
                    f"{name}: expected {frames} frames at {rate} Hz, got {tap.frames} at {tap.rate} Hz"
                )

        for offset in range(0, frames, CHUNK_FRAMES):
            count = min(CHUNK_FRAMES, frames - offset)
            buffers = {name: tap.read(count) for name, tap in taps.items()}
            for name, samples in buffers.items():
                stats[name].add(samples)
            dialogue = buffers.get("dialogue-chops")
            for index, (drums, bass, dry, texture, wet, music) in enumerate(zip(
                    *(buffers[name] for name in ("drums", "bass", "dry", "texture", "wet", "lofi")))):
                residual = abs(drums + bass + dry + texture + wet + (dialogue[index] if dialogue is not None else 0) - music)
                if math.isfinite(residual):
                    stem_peak = max(stem_peak, residual)
                    if first_bad_stem_frame is None and residual > ROUTING_TOLERANCE:
                        first_bad_stem_frame = offset + index // 2
            for index, (combined, music, footage) in enumerate(zip(
                    buffers["pre-master"], buffers["lofi"], buffers["footage"])):
                residual = abs((music + footage) - combined)
                if not math.isfinite(residual):
                    nonfinite_routing_samples += 1
                    continue
                routing_peak = max(routing_peak, residual)
                if first_bad_frame is None and residual > ROUTING_TOLERANCE:
                    first_bad_frame = offset + index // 2

    report["buses"] = {name: bus.summary() for name, bus in stats.items()}
    report["routing"] = {
        "preMasterSumPeakResidual": routing_peak,
        "musicStemSumPeakResidual": stem_peak,
        "firstMusicFrameOutsideTolerance": first_bad_stem_frame,
        "tolerance": ROUTING_TOLERANCE,
        "firstFrameOutsideTolerance": first_bad_frame,
        "nonfiniteSamples": nonfinite_routing_samples,
    }

    failures = report["failures"]
    for name, bus in stats.items():
        if bus.nonfinite:
            failures.append(f"{name}: {bus.nonfinite} nonfinite samples")
    if first_bad_stem_frame is not None:
        failures.append(f"lofi differs from the captured music stems at frame {first_bad_stem_frame}")
    if first_bad_frame is not None:
        failures.append(f"pre-master differs from the lofi + footage sum at frame {first_bad_frame}")
    if not has_footage:
        for name in FOOTAGE_BUSES + tuple(n for n in ("dialogue-chops", "dialogue-fx") if n in stats):
            if stats[name].sample_peak > SILENCE_FLOOR:
                failures.append(f"{name}: audio appeared with hasFootage=false")
    elif stats["footage"].sample_peak <= SILENCE_FLOOR:
        failures.append("footage: combined footage bus is silent with hasFootage=true")
    if stats["lofi"].sample_peak <= SILENCE_FLOOR:
        failures.append("lofi: combined music bus is silent")
    if stats["master"].sample_peak <= SILENCE_FLOOR:
        failures.append("master: combined output is silent")
    failures.extend(stale_motif_lines(manifest))
    if stats["master"].nonfinite:
        return

    meter = master_meter(run / "master.wav", run / "ffmpeg-ebur128.log")
    report["masterMeter"] = meter
    peak = meter["truePeakDbtp"]
    if peak is not None and peak > true_peak_limit:
        failures.append(f"master: {peak:.2f} dBTP exceeds ceiling {true_peak_limit:.2f} dBTP")
    if (peak is None or meter["samplePeakDbfs"] is None) and stats["master"].sample_peak > SILENCE_FLOOR:
        failures.append("master: FFmpeg reported no peaks for a non-silent input")
    reference_peak = report["buses"]["master"]["samplePeakDbfs"]
    if reference_peak is not None and meter["samplePeakDbfs"] is not None:
        if abs(reference_peak - meter["samplePeakDbfs"]) > 0.11:
            failures.append("master: FFmpeg sample peak disagrees with direct PCM peak")


def stale_motif_lines(manifest):
    """Fresh samples every loop (user direction, 19 November 2026): in motif mode each 16-bar loop
    (four phrases) leads with its own line. Fails when a loop's main bank is the previous loop's."""
    chops = [c for c in manifest.get("dialogueChops") or [] if c.get("cell") and isinstance(c.get("block"), int)]
    loops = {}
    for chop in chops:
        loops.setdefault(chop["block"] // 4, []).append(chop["bankID"])
    keys = sorted(loops)
    failures = []
    for a, b in zip(keys, keys[1:]):
        if b != a + 1:
            continue
        main_a = max(set(loops[a]), key=loops[a].count)
        main_b = max(set(loops[b]), key=loops[b].count)
        if main_a == main_b:
            failures.append(f"dialogue: loop {b} repeats loop {a}'s line (bank {main_b}); every loop needs a fresh line")
    return failures


def engine_ceiling(run):
    """The master finisher's own ceiling (diagnostics.masterDynamics.ceilingDbtp) when the capture has one."""
    try:
        manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
        dynamics = (manifest.get("diagnostics") or {}).get("masterDynamics") or {}
        ceiling = dynamics.get("ceilingDbtp")
        if dynamics.get("operational", True) and isinstance(ceiling, (int, float)) and math.isfinite(ceiling):
            return float(ceiling)
    except (OSError, ValueError):
        pass
    return None


def measure(run, true_peak_limit):
    report_path = run / "analysis.json"
    limit_source = "argument"
    if true_peak_limit is None:
        true_peak_limit = engine_ceiling(run)
        limit_source = "manifest masterDynamics.ceilingDbtp"
        if true_peak_limit is None:
            true_peak_limit, limit_source = -1.5, "default"
    report = {
        "schema": "liminal-lofi-analysis-v1",
        "truePeakLimitDbtp": true_peak_limit,
        "truePeakLimitSource": limit_source,
        "failures": [],
        "reproduce": ["python3", "scripts/analyze-lofi.py", str(run),
                      "--max-true-peak", str(true_peak_limit)],
    }
    try:
        analyze(run, true_peak_limit, report)
    except (AudioCheckError, OSError, KeyError, ValueError, TypeError, subprocess.CalledProcessError) as error:
        report["failures"].append(str(error))
    report["passed"] = not report["failures"]
    report_path.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    return report


def write_fixture_wave(path, samples, rate, *, extensible=False, channel_mask=None):
    channels = channel_mask.bit_count() if channel_mask is not None else 2
    frame_bytes = channels * 4
    data = samples.tobytes()
    if sys.byteorder != "little":
        copy = array("f", samples)
        copy.byteswap()
        data = copy.tobytes()
    if extensible or channel_mask is not None:
        fmt = struct.pack("<HHIIHHHHI", 0xFFFE, channels, rate, rate * frame_bytes,
                          frame_bytes, 32, 22, 32, channel_mask or 3) + FLOAT_GUID
    else:
        fmt = struct.pack("<HHIIHH", 3, channels, rate, rate * frame_bytes, frame_bytes, 32)
    payload = b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt
    payload += b"data" + struct.pack("<I", len(data)) + data
    path.write_bytes(b"RIFF" + struct.pack("<I", len(payload)) + payload)


def require(condition, reason):
    if not condition:
        raise AudioCheckError(reason)


def self_test():
    rate = 48000
    frames = 48000
    with tempfile.TemporaryDirectory(prefix="liminal-lofi-analysis-") as temp:
        run = Path(temp)
        manifest = {"schema": "analyzer-self-test", "sampleRate": rate,
                    "frames": frames, "hasFootage": False}
        (run / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        silence = array("f", [0]) * (frames * 2)
        transient = array("f", silence)
        transient[24000 * 2] = 0.25
        for name in BUSES:
            signal = transient if name in {"drums", "lofi", "pre-master", "glue", "master"} else silence
            write_fixture_wave(run / f"{name}.wav", signal, rate, extensible=name == "pre-master")
        good = measure(run, -1.5)
        require(good["passed"], f"valid transient failed: {good['failures']}")
        require(abs(good["masterMeter"]["samplePeakDbfs"] + 12.04) < 0.11,
                "known transient sample peak was not detected")
        require(good["buses"]["footage"]["samplePeakDbfs"] is None, "silence generated a sample peak")

        write_fixture_wave(run / "drums.wav", silence, rate)
        disconnected = measure(run, -1.5)
        require(not disconnected["passed"] and disconnected["routing"]["firstMusicFrameOutsideTolerance"] == 24000,
                "a missing drum stem passed while the pre-master sum remained valid")
        write_fixture_wave(run / "drums.wav", transient, rate)

        write_fixture_wave(run / "footage.wav", transient, rate)
        bad = measure(run, -1.5)
        require(any("pre-master differs" in item for item in bad["failures"]), "routing mutation passed")
        require(any("hasFootage=false" in item for item in bad["failures"]), "silent-bus mutation passed")
        require(bad["routing"]["firstFrameOutsideTolerance"] == 24000, "routing failure time was wrong")
        write_fixture_wave(run / "footage.wav", silence, rate)

        intersample = array("f")
        fade_frames = rate // 10
        for frame in range(frames):
            envelope = min(1, frame / fade_frames, (frames - 1 - frame) / fade_frames)
            sample = 0.99 * envelope * math.sin(math.pi * (frame % 4) / 2 + math.pi / 4)
            intersample.extend((sample, sample))
        write_fixture_wave(run / "master.wav", intersample, rate)
        over = measure(run, -1.5)
        require(any("exceeds ceiling" in item for item in over["failures"]), "intersample peak passed")
        require(over["masterMeter"]["samplePeakDbfs"] < -2.9
                and over["masterMeter"]["truePeakDbtp"] > -0.3, "intersample measurement disagreed with known maxima")
        write_fixture_wave(run / "master.wav", silence, rate)
        empty = measure(run, -1.5)
        require(any("output is silent" in item for item in empty["failures"]), "silent master passed")

        nan = array("f", transient)
        nan[-1] = math.nan
        write_fixture_wave(run / "master.wav", nan, rate)
        nonfinite = measure(run, -1.5)
        require(any("nonfinite samples" in item for item in nonfinite["failures"]), "NaN passed")
        (run / "manifest.json").unlink()
        missing = measure(run, -1.5)
        require(any("manifest.json" in item for item in missing["failures"]), "missing manifest passed")
    print("Lo-Fi analyzer self-test passed (transient, routing, silence, intersample peak, NaN and manifest)")


def kilohertz_tones(segments, rate):
    """Each segment supplies its duration and peak level per channel."""
    samples = array("f")
    period = rate // 1000
    for duration, levels in segments:
        gains = [10 ** (level / 20) for level in levels]
        cycle = array("f")
        for frame in range(period):
            sine = math.sin(math.tau * frame / period)
            cycle.extend(sine * gain for gain in gains)
        samples.extend(cycle * round(duration * 1000))
    return samples


def stereo_tones(segments, rate):
    return kilohertz_tones(((duration, [level, level]) for duration, level in segments), rate)


def ebu_subset():
    """Generate selected cases from EBU Tech 3341 and 3342 at 48 kHz."""
    rate = 48000
    integrated = {
        1: ([(20, -23)], -23),
        2: ([(20, -33)], -33),
        3: ([(10, -36), (60, -23), (10, -36)], -23),
        4: ([(10, -72), (10, -36), (60, -23), (10, -36), (10, -72)], -23),
        5: ([(20, -26), (20.1, -20), (20, -26)], -23),
    }
    periods = {15: (4, 0, 0.50), 16: (4, 45, 0.50), 17: (6, 60, 0.50),
               18: (8, 67.5, 0.50), 19: (4, 45, 1.41)}
    with tempfile.TemporaryDirectory(prefix="liminal-ebu-subset-") as temp:
        run = Path(temp)
        fixture = run / "case.wav"
        log_path = run / "ffmpeg.log"
        for case, (segments, expected) in integrated.items():
            write_fixture_wave(fixture, stereo_tones(segments, rate), rate)
            observed = master_meter(fixture, log_path)["integratedLufs"]
            require(abs(observed - expected) <= 0.101, f"EBU integrated case {case}: {observed} LUFS")
            print(f"EBU 3341 case {case}: {observed:.2f} LUFS integrated")

        surround = kilohertz_tones([(20, [-28, -28, -24, -30, -30])], rate)
        # 5.0 order is Front Left, Front Right, Front Center, Back Left, Back Right.
        write_fixture_wave(fixture, surround, rate, channel_mask=0x37)
        observed = master_meter(fixture, log_path)["integratedLufs"]
        require(abs(observed + 23) <= 0.101, f"EBU integrated case 6: {observed} LUFS")
        print(f"EBU 3341 case 6: {observed:.2f} LUFS integrated (5.0)")

        periodic = [
            (9, [(1.34, -20), (1.66, -30)] * 5, "shortTerm", 30),
            (12, [(0.18, -20), (0.22, -30)] * 25, "momentary", 10),
        ]
        for case, segments, label, settling_windows in periodic:
            write_fixture_wave(fixture, stereo_tones(segments, rate), rate)
            observed = master_meter(fixture, log_path, capture_level_frames=True)[label][settling_windows:]
            require(bool(observed) and all(abs(value + 23) <= 0.101 for value in observed),
                    f"EBU {label} case {case}: outside tolerance after initial window")
            print(f"EBU 3341 case {case}: {min(observed):.2f} to {max(observed):.2f} LUFS {label}")

        loudness_ranges = {1: ([-20, -30], 10), 2: ([-20, -15], 5),
                           3: ([-40, -20], 20), 4: ([-50, -35, -20, -35, -50], 15)}
        for case, (levels, expected) in loudness_ranges.items():
            samples = stereo_tones([(20, level) for level in levels], rate)
            write_fixture_wave(fixture, samples, rate)
            observed = master_meter(fixture, log_path)["loudnessRangeLu"]
            require(abs(observed - expected) <= 1.001, f"EBU 3342 range case {case}: {observed} LU")
            print(f"EBU 3342 case {case}: {observed:.2f} LU range")

        for case, (period, phase, amp) in periods.items():
            samples = array("f")
            for frame in range(rate):
                envelope = min(1, frame / 480, (rate - 1 - frame) / 480)
                sample = amp * envelope * math.sin(math.tau * (frame % period) / period + math.radians(phase))
                samples.extend((sample, sample))
            write_fixture_wave(run / "case.wav", samples, rate)
            observed = master_meter(run / "case.wav", run / "ffmpeg.log")["truePeakDbtp"]
            expected = 3 if case == 19 else -6
            require(expected - 0.401 <= observed <= expected + 0.201,
                    f"EBU true-peak case {case}: {observed} dBTP")
            print(f"EBU 3341 case {case}: {observed:.2f} dBTP")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, nargs="?", help="directory containing manifest.json and synchronized WAVs")
    parser.add_argument("--max-true-peak", type=float, default=None,
                        help="dBTP ceiling; defaults to the engine's masterDynamics.ceilingDbtp from the manifest, else -1.5")
    parser.add_argument("--self-test", action="store_true", help="exercise known and deliberately invalid fixtures")
    parser.add_argument("--ebu-subset", "--ebu-stereo-subset", action="store_true",
                        help="run selected analytic EBU 3341 and 3342 meter fixtures")
    options = parser.parse_args()
    if options.ebu_subset:
        ebu_subset()
        return 0
    if options.self_test:
        self_test()
        return 0
    if options.capture is None or not options.capture.is_dir():
        parser.error("provide an existing capture directory or --self-test")
    if options.max_true_peak is not None and not math.isfinite(options.max_true_peak):
        parser.error("--max-true-peak must be finite")
    run = options.capture.resolve()
    report = measure(run, options.max_true_peak)
    for failure in report["failures"]:
        print(failure, file=sys.stderr)
    print(run / "analysis.json")
    return int(not report["passed"])


if __name__ == "__main__":
    sys.exit(main())
