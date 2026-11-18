#!/usr/bin/env python3
"""Produce numeric and visual diagnostics for a synchronized Lo-Fi capture."""
import argparse
import json
import os
from pathlib import Path
import runpy
import tempfile

os.environ.setdefault("MPLCONFIGDIR", tempfile.mkdtemp(prefix="liminal-matplotlib-"))
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy import signal
from scipy.io import wavfile


def db(amplitude):
    return 20 * np.log10(np.maximum(amplitude, 1e-12))


def rms(values, axis=None):
    return np.sqrt(np.mean(np.square(values, dtype=np.float64), axis=axis))


def stream(run, name, expected_rate, frames):
    rate, samples = wavfile.read(run / f"{name}.wav")
    if rate != expected_rate or samples.shape != (frames, 2) or samples.dtype.kind != "f":
        raise ValueError(f"{name} does not match the capture clock and stereo format")
    if not np.isfinite(samples).all():
        raise ValueError(f"{name} contains nonfinite PCM")
    return samples


def band_energies(data, rate, nfft, *, density=False):
    frequency, time, transform = signal.stft(data.T, rate, nperseg=nfft,
                                             noverlap=3 * nfft // 4, boundary=None, padded=False,
                                             scaling="psd" if density else "spectrum")
    power = np.mean(np.abs(transform) ** 2, axis=0)
    if density:
        power[1:-1] *= 2
    return frequency, time, power


def erb_edges():
    erb = lambda hertz: 21.4 * np.log10(1 + 0.00437 * hertz)
    inverse = lambda value: (10 ** (value / 21.4) - 1) / 0.00437
    return inverse(np.arange(np.ceil(erb(100)), np.floor(erb(8000)) + 1))


def diagnostic_plots(run, rate, frames, master, room, drum):
    output = {}
    for nfft in (512, 2048, 8192):
        figure, axes = plt.subplots(3, 1, figsize=(13, 8), sharex=True, layout="constrained")
        arrays = {}
        for axis, (name, data) in zip(axes, (("Master", master), ("Lo-Fi wet", room), ("Drums", drum))):
            frequency, time, power = band_energies(data, rate, nfft)
            selected = (frequency >= 24) & (frequency <= min(16000, rate / 2))
            spectrum = np.asarray(10 * np.log10(np.maximum(power[selected, :], 1e-12)), dtype=np.float32)
            image = axis.pcolormesh(time, frequency[selected], spectrum, shading="auto",
                                    cmap="magma", vmin=-85, vmax=-20)
            axis.set_yscale("log")
            axis.set_ylabel("Hz")
            axis.set_title(name, loc="left")
            key = name.lower().replace(" ", "_")
            arrays[f"{key}_db"] = spectrum
        axes[-1].set_xlabel("Seconds on the capture clock")
        figure.colorbar(image, ax=axes, label="Per-bin squared Hann spectrum (dBFS)", shrink=0.9)
        figure.suptitle(f"Lo-Fi mix · {1000 * nfft / rate:.0f} ms Hann window")
        figure.savefig(run / f"spectrogram-{nfft}.png", dpi=125)
        plt.close(figure)
        np.savez_compressed(run / f"spectrum-{nfft}.npz", time=time, hz=frequency[selected], **arrays)
        output[str(nfft)] = {"windowMs": 1000 * nfft / rate, "hopFrames": nfft // 4}
    return output


def advisory(run, manifest, master, dry, wet, drum, target, background):
    rate = int(manifest["sampleRate"])
    frames = int(manifest["frames"])
    nfft = 2048
    frequency, time, dry_power = band_energies(dry, rate, nfft, density=True)
    _, _, wet_power = band_energies(wet, rate, nfft, density=True)
    _, _, target_power = band_energies(target, rate, nfft, density=True)
    _, _, background_power = band_energies(background, rate, nfft, density=True)
    bin_width = frequency[1] - frequency[0]
    boundaries = erb_edges()
    band_rows = []
    for a, b in zip(boundaries, boundaries[1:]):
        indices = (frequency >= a) & (frequency < b)
        if not np.any(indices):
            continue
        keys = ("dry", "wet", "footageDry", "combinedBackground")
        powers = [np.sum(matrix[indices], axis=0) * bin_width
                  for matrix in (dry_power, wet_power, target_power, background_power)]
        stereo_levels = dict(zip(keys, [float(10 * np.log10(max(1e-12, np.mean(power)))) for power in powers]))
        active = powers[2] > 1e-5
        overlap = (powers[3] > powers[2] * 0.50) & active
        band_rows.append({"lowHz": float(a), "highHz": float(b), "averageDb": stereo_levels,
                          "footageActiveWindows": int(np.sum(active)),
                          "competitionFraction": float(overlap.sum() / active.sum()) if np.any(active) else None})
    score = json.loads((run / "score.json").read_text())
    rests, joins = [], []
    for phrase in score:
        start, end = phrase["range"]
        rest_start, rest_end = phrase.get("endingRest", phrase.get("foregroundRest"))
        attack_overlap = [note["on"] for note in phrase["notes"]
                          if note["role"] != "bass" and note["on"] < rest_end and note["off"] > rest_start]
        rests.append({"section": phrase["section"], "intervalFrames": [rest_start, rest_end],
                      "expectedDryConflicts": attack_overlap,
                      "wetRmsDb": float(db(rms(wet[rest_start:rest_end]))),
                      "fullPhraseWetRmsDb": float(db(rms(wet[start:end])))})
        if start:
            baseline = np.abs(np.diff(drum[max(0, start - rate // 5):min(frames, start + rate // 5)], axis=0))
            step = np.max(np.abs(drum[start] - drum[start - 1]))
            joins.append({"sample": start, "stepDb": float(db(step)),
                          "nearbyStep99Db": float(db(np.percentile(baseline, 99)))})
    centered = master - master.mean(axis=0)
    denominator = np.linalg.norm(centered[:, 0]) * np.linalg.norm(centered[:, 1])
    return {"erbOverlapBands": band_rows,
            "erbMethod": "Stereo PSD. Dry footage compared with waveform sum of Lo-Fi and footage delay and room. "
                         "This is a branch-domain overlap indicator.", "foregroundRests": rests, "drumBoundaries": joins,
            "peakToRmsDb": float(db(np.max(np.abs(master))) - db(rms(master))),
            "midRmsDb": float(db(rms(0.5 * (master[:, 0] + master[:, 1])))),
            "sideRmsDb": float(db(rms(0.5 * (master[:, 0] - master[:, 1])))),
            "stereoCorrelation": float(np.dot(centered[:, 0], centered[:, 1]) / denominator) if denominator else None,
            "spectralWindows": int(len(time))}


def envelope(samples, step):
    spans = len(samples) // step
    return db(rms(samples[:spans * step].reshape(spans, step, 2), axis=(1, 2)))


def space_plot(run, rate, dry, wet, target):
    window = round(rate * 0.050)
    figure, axis = plt.subplots(figsize=(13, 4.1), layout="constrained")
    for name, samples in (("Dry accompaniment", dry), ("Music effects", wet), ("Footage", target)):
        values = envelope(samples, window)
        axis.plot(np.arange(len(values)) * window / rate, values, label=name, linewidth=1)
    score = json.loads((run / "score.json").read_text())
    for index, phrase in enumerate(score):
        start, end = phrase.get("endingRest", phrase.get("foregroundRest"))
        axis.axvspan(start / rate, end / rate, color="steelblue", alpha=0.11,
                     label="Phrase ending rests" if index == 0 else None)
    axis.set(ylim=(-85, 0), xlabel="Seconds on the capture clock", ylabel="50 ms RMS (dBFS)",
             title="Accompaniment and footage across the phrase")
    axis.grid(alpha=0.2)
    axis.legend(loc="lower left", ncol=2)
    figure.savefig(run / "foreground-space.png", dpi=140)
    plt.close(figure)


def compare(run, reference, output, candidate_report, offset):
    manifests = [json.loads((path / "manifest.json").read_text()) for path in (reference, run)]
    score = [json.loads((path / "score.json").read_text()) for path in (reference, run)]
    basis = ("bpm", "seed", "sampleRate", "frames", "drumSourceHash", "hasFootage", "footageSourceHash")
    mismatches = [key for key in basis if manifests[0].get(key) != manifests[1].get(key)]
    if mismatches or score[0] != score[1]:
        raise ValueError(f"Use the same materialized score and source ({', '.join(mismatches) or 'score'})")
    rate = int(manifests[0]["sampleRate"])
    frames = int(manifests[0]["frames"])
    latency_source = "explicit sample offset"
    if offset is None:
        latency = [sum(item.get("latencySamples", {}).values()) for item in manifests]
        offset = round(latency[1] - latency[0])
        latency_source = "reported graph latencies"
    if abs(offset) >= frames - 8192:
        raise ValueError("Latency offset leaves too little shared audio")
    signals = [stream(path, "master", rate, frames) for path in (reference, run)]
    analytics = [json.loads((path / "analysis.json").read_text())["masterMeter"] for path in (reference, run)]
    historical = analytics
    meter = runpy.run_path(str(Path(__file__).with_name("analyze-lofi.py")))["master_meter"]
    output.mkdir(parents=True, exist_ok=True)
    if offset > 0:
        signals = (signals[0][:-offset], signals[1][offset:])
    elif offset < 0:
        signals = (signals[0][-offset:], signals[1][:offset])
    if offset:
        with tempfile.TemporaryDirectory(prefix="liminal-lofi-alignment-") as temp:
            scratch = Path(temp)
            probe = scratch / "align.wav"
            analytics = []
            for samples in signals:
                wavfile.write(probe, rate, samples)
                analytics.append(meter(probe, scratch / "alignment-meter.log"))
    levels = [item["integratedLufs"] for item in analytics]
    peaks = [item["truePeakDbtp"] for item in analytics]
    if any(value is None or not np.isfinite(value) for value in levels + peaks):
        raise ValueError("The paired captures need finite loudness and peak measurements")
    peaks[1] = max(peaks[1], max(candidate_report["reconstructedPeakDb"].values()))
    # Use attenuation or headroom-safe gain. Record gains, keep all originals unchanged.
    common = min(-18, min(level - peak - 1.7 for level, peak in zip(levels, peaks)))
    gains = [common - level for level in levels]
    processed = [samples * np.float32(10 ** (gain / 20)) for samples, gain in zip(signals, gains)]
    matched_meters = []
    for label, samples in zip(("reference", "candidate"), processed):
        wav_path = output / f"{label}-matched.wav"
        wavfile.write(wav_path, rate, samples)
        matched_meters.append(meter(wav_path, output / f"{label}-meter.log"))

    frequency, time, a = band_energies(processed[0], rate, 2048)
    _, _, b = band_energies(processed[1], rate, 2048)
    selected = (frequency >= 24) & (frequency <= min(16000, rate / 2))
    a, b = [10 * np.log10(np.maximum(x[selected], 1e-12)) for x in (a, b)]
    difference = b - a
    difference[np.maximum(a, b) < -85] = 0
    figure, axes = plt.subplots(3, 1, sharex=True, figsize=(13, 8), layout="constrained")
    for axis, spectrum, title in zip(axes, (a, b, difference), ("Reference", "Candidate", "Candidate minus reference")):
        delta = title == "Candidate minus reference"
        image = axis.pcolormesh(time, frequency[selected], spectrum, shading="auto",
                               vmin=-15 if delta else -85, vmax=15 if delta else -20,
                               cmap="coolwarm" if delta else "magma")
        axis.set_yscale("log")
        axis.set_title(title, loc="left")
        axis.set_ylabel("Hz")
        figure.colorbar(image, ax=axis, label="dB")
    axes[-1].set_xlabel("Aligned seconds")
    figure.savefig(output / "matched-spectrograms.png", dpi=125)
    plt.close(figure)
    np.savez_compressed(output / "matched-spectrograms.npz", time=time, hz=frequency[selected],
                        reference_db=a, candidate_db=b, difference_db=difference)
    report = {"expectedLufs": common, "appliedGainsDb": gains, "candidateLagFrames": offset, "latencySource": latency_source,
              "preAlignment": historical, "alignedBeforeGain": analytics, "matchedMeters": matched_meters,
              "alignedFrames": len(processed[0]), "differenceRmsDb": float(db(rms(processed[1] - processed[0]))),
              "providers": [item.get("providers") for item in manifests],
              "captureOrder": [str(reference), str(run)]}
    (output / "comparison.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")


def audition_levels(run, rate, master, integrated, peak):
    variants = []
    for target in (-20, -18, -16):
        desired_gain = target - integrated
        gain = min(desired_gain, -1.5 - peak - 0.2)
        file = f"audition-{abs(target)}-lufs.wav"
        wavfile.write(run / file, rate, master * np.float32(10 ** (gain / 20)))
        variants.append({"path": file, "requestedLufs": target, "estimatedLufs": integrated + gain,
                         "gainDb": gain, "peakHeadroomConstrained": gain < desired_gain})
    return variants


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--auditions", action="store_true")
    parser.add_argument("--against", type=Path, help="reference capture with the same materialized score")
    parser.add_argument("--candidate-lag-frames", type=int,
                        help="override reported latency with a measured candidate lag relative to the reference")
    parser.add_argument("--comparison-out", type=Path)
    args = parser.parse_args()
    if (args.comparison_out is None) != (args.against is None):
        parser.error("pass --against and --comparison-out together")
    run = args.capture.resolve()
    manifest = json.loads((run / "manifest.json").read_text())
    rate = int(manifest["sampleRate"])
    frames = int(manifest["frames"])
    master, dry, wet, drum, target, lofi, echo, room = (stream(run, name, rate, frames) for name in (
        "master", "dry", "wet", "drums", "footage-dry", "lofi", "footage-delay", "footage-room"))
    background = lofi + echo + room
    report = advisory(run, manifest, master, dry, wet, drum, target, background)
    report["spectrograms"] = diagnostic_plots(run, rate, frames, master, wet, drum)
    space_plot(run, rate, dry, wet, target)
    # Cross-check the independent FFmpeg result using different reconstruction kernels/rates.
    # This is an engineering comparison, not an EBU reference certification.
    report["reconstructedPeakDb"] = {}
    for factor in (4, 8, 16):
        maximum = 0.0
        for channel in master.T:
            reconstruction = signal.resample_poly(channel, factor, 1, window=("kaiser", 14))
            maximum = max(maximum, float(np.max(np.abs(reconstruction))))
        report["reconstructedPeakDb"][str(factor)] = float(db(maximum))
    if args.auditions:
        analysis = json.loads((run / "analysis.json").read_text())
        loudness = analysis["masterMeter"]
        report["auditions"] = audition_levels(run, rate, master, loudness["integratedLufs"],
                                              max(report["reconstructedPeakDb"].values()))
    (run / "spectral-analysis.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    if args.against:
        comparison = args.comparison_out.resolve()
        if comparison.is_relative_to(Path.cwd()) or (comparison.exists() and any(comparison.iterdir())):
            parser.error("choose a new or empty comparison directory outside the repository")
        compare(run, args.against.resolve(), comparison, report, args.candidate_lag_frames)
    print(f"Spectral and stereo diagnostics written to {run}")


if __name__ == "__main__":
    main()
