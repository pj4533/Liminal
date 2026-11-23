#!/usr/bin/env python3
"""Fetch authentic public Archive films into an isolated ArchiveClipStore cache.

Requires ffprobe. Never supplies private drums. Saves original metadata, selected URLs,
SHA256 and decoded track facts in a separate provenance directory. No fixed file names.
Run on the verification Mac before the installed-only probes, outside the application.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
from urllib.parse import quote
from urllib.request import Request, urlopen

PINS = ["aapb-cpb-aacip-514-n00zp3ws90", "VAM026", "gov.archives.arc.13260",
        "alan-watts-the-flow-of-zen", "342-usaf-42990", "Timothy_Leary_Archives_198",
        "Ergotthestoryofaparasiticfungus-wellcome", "Designfo1956",
        "horizons-of-science-thinking-machines", "sailfilm_hear", "LivingSt1958",
        "SoundAndTheS", "SpringCo1952"]


def fetch(url, path):
    for attempt in range(4):
        try:
            with urlopen(Request(url, headers={"User-Agent": "Liminal-verification/1.0"}), timeout=120) as response:
                with path.open("wb") as output:
                    while block := response.read(1024 * 1024):
                        output.write(block)
            return
        except Exception:
            path.unlink(missing_ok=True)
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def candidates(metadata):
    return sorted((f for f in metadata.get("files", [])
                   if f.get("name", "").lower().endswith(".mp4")
                   and not f["name"].lower().endswith("_edit.mp4")
                   and f.get("format", "").lower() in ("h.264", "h.264 ia", "512kb mpeg4", "mpeg4")),
                  key=lambda f: (int(f.get("size") or 0), f["name"]))


def inspect(path):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams",
        "-show_format", "-of", "json", str(path)], text=True))


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_record(path):
    try:
        record = json.loads(path.read_text())
        return record if isinstance(record, dict) else {}
    except (OSError, ValueError):
        return {}


def matches_record(destination, record, identifier, file, url, metadata_hash):
    return (destination.is_file() and record.get('id') == identifier and record.get('url') == url and
            record.get('archiveFile') == file and record.get('metadataSHA256') == metadata_hash and
            record.get('sha256') == digest(destination))


def cached_matches(destination, sidecar, identifier, file, url, metadata_hash):
    return matches_record(destination, read_record(sidecar), identifier, file, url, metadata_hash)


def decoded_windows(path, duration):
    """Decode the exact eight 30-second probe windows; ffprobe alone proves no decoding."""
    usable, margin = duration - 31, min(.2 * duration, 60)
    lo, hi = (margin, usable - margin) if usable > 2 * margin else (0, usable)
    rows = []
    for chunk in range(8):
        offset = lo + (hi - lo) * chunk / 7
        audio = subprocess.check_output(['ffmpeg', '-v', 'error', '-ss', str(offset), '-i', str(path),
            '-t', '30', '-vn', '-ar', '48000', '-ac', '1', '-f', 'f32le', '-'])
        frames = len(audio) // 4
        if frames < 29 * 48000:
            raise RuntimeError(f'chunk {chunk} decoded only {frames} frames')
        rows.append(dict(chunk=chunk, offset=offset, frames=frames, sampleRate=48000))
    return rows


def prepare(cache, provenance, count):
    if provenance.resolve().is_relative_to(cache.resolve()):
        raise ValueError('provenance directory must be outside the managed footage cache')
    cache.mkdir(parents=True, exist_ok=True)
    provenance.mkdir(parents=True, exist_ok=True)
    previous = {r['id']: r for r in read_record(provenance / 'dataset.json').get('films', [])
                if isinstance(r, dict) and 'id' in r}
    clips, records, failures = [], [], []
    for identifier in PINS:
        if len(clips) == count:
            break
        try:
            metadata_path = provenance / f"{identifier}.metadata.json"
            if not metadata_path.exists():
                fetch(f"https://archive.org/metadata/{identifier}", metadata_path)
            metadata = json.loads(metadata_path.read_text())
            metadata_hash = digest(metadata_path)
            errors = []
            for file in candidates(metadata):
                url = f"https://archive.org/download/{identifier}/{quote(file['name'], safe='/')}"
                destination = cache / f"{identifier}.mp4"
                try:
                    legacy = destination.with_suffix('.provenance.json')
                    sidecar = provenance / legacy.name
                    identity_args = (identifier, file, url, metadata_hash)
                    if not (cached_matches(destination, sidecar, *identity_args)
                            or cached_matches(destination, legacy, *identity_args)
                            or matches_record(destination, previous.get(identifier, {}), *identity_args)):
                        destination.unlink(missing_ok=True)
                        legacy.unlink(missing_ok=True)
                        partial = destination.with_suffix(".part")
                        fetch(url, partial)
                        partial.rename(destination)
                    facts = inspect(destination)
                    video = next(s for s in facts["streams"] if s["codec_type"] == "video")
                    assert any(s["codec_type"] == "audio" for s in facts["streams"]), "no audio track"
                    duration = float(facts["format"]["duration"])
                    assert duration >= 60, f"too short: {duration}"
                    coverage = decoded_windows(destination, duration)
                    identity = dict(id=identifier, url=url, archiveFile=file, metadataSHA256=metadata_hash,
                                    sha256=digest(destination))
                    serialized = json.dumps(identity, indent=2)
                    sidecar.write_text(serialized)
                    # Standalone probes without a verification directory use this legacy copy.
                    legacy.write_text(serialized)
                    info = metadata.get("metadata", {})
                    clips.append(dict(id=identifier, title=str(info.get("title", identifier)),
                        fileName=destination.name, bytes=destination.stat().st_size, duration=duration,
                        width=video["width"], height=video["height"], hasAudio=True, black=0, white=1,
                        isColour=True, licence=str(info.get("licenseurl", "See original Archive metadata")),
                        added=0, useCount=0, shownStarts=[]))
                    records.append(dict(**identity, facts=facts, decodedWindows=coverage,
                        decodingScope='Eight probe windows only; not full-film decode'))
                    print(f"prepared {identifier}: {duration:.1f}s", flush=True)
                    break
                except Exception as error:
                    destination.unlink(missing_ok=True)
                    errors.append(f"{file['name']}: {error}")
            else:
                raise RuntimeError("; ".join(errors) or "no supported mp4")
        except Exception as error:
            failures.append(dict(id=identifier, error=str(error)))
            print(f"unavailable {identifier}: {error}", flush=True)
    (cache / "index.json").write_text(json.dumps(dict(clips=clips, bad=[], filePolicyVersion=2, recentDiscoveries=[])))
    (provenance / "dataset.json").write_text(json.dumps(dict(requested=count, prepared=len(clips),
        films=records, failures=failures, dateEncoding="Swift Codable seconds since 2001-01-01", historicalDatasetIdentical=False), indent=2))
    if len(clips) != count:
        raise RuntimeError(f"only {len(clips)}/{count} authentic audio-bearing films prepared; see dataset.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    parser.add_argument("--count", type=int, default=12, choices=range(1, 14))
    args = parser.parse_args()
    prepare(args.cache, args.provenance, args.count)
