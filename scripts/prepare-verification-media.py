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


def prepare(cache, provenance, count):
    cache.mkdir(parents=True, exist_ok=True)
    provenance.mkdir(parents=True, exist_ok=True)
    clips, records, failures = [], [], []
    for identifier in PINS:
        if len(clips) == count:
            break
        try:
            metadata_path = provenance / f"{identifier}.metadata.json"
            if not metadata_path.exists():
                fetch(f"https://archive.org/metadata/{identifier}", metadata_path)
            metadata = json.loads(metadata_path.read_text())
            errors = []
            for file in candidates(metadata):
                url = f"https://archive.org/download/{identifier}/{quote(file['name'], safe='/')}"
                destination = cache / f"{identifier}.mp4"
                try:
                    if not destination.exists():
                        partial = destination.with_suffix(".part")
                        fetch(url, partial)
                        partial.rename(destination)
                    facts = inspect(destination)
                    video = next(s for s in facts["streams"] if s["codec_type"] == "video")
                    assert any(s["codec_type"] == "audio" for s in facts["streams"]), "no audio track"
                    duration = float(facts["format"]["duration"])
                    assert duration >= 60, f"too short: {duration}"
                    info = metadata.get("metadata", {})
                    clips.append(dict(id=identifier, title=str(info.get("title", identifier)),
                        fileName=destination.name, bytes=destination.stat().st_size, duration=duration,
                        width=video["width"], height=video["height"], hasAudio=True, black=0, white=1,
                        isColour=True, licence=str(info.get("licenseurl", "See original Archive metadata")),
                        added=0, useCount=0, shownStarts=[]))
                    records.append(dict(id=identifier, url=url, archiveFile=file, facts=facts,
                        sha256=hashlib.file_digest(destination.open("rb"), "sha256").hexdigest()))
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
