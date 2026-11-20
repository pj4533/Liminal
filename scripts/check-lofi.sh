#!/bin/bash
# Capture a synchronized sample-clock render and measure it with an independent meter.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from threading import Thread

parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path)
parser.add_argument("--seed", default=1042, type=int)
parser.add_argument("--bpm", default=70.0, type=float)
parser.add_argument("--bars", default=16, choices=(4, 8, 12, 16, 32, 64), type=int)
parser.add_argument("--scale", help="Pin the same C-rooted scale as the app, e.g. Dorian (default: Auto)")
parser.add_argument("--block", default=1024, type=int)
parser.add_argument("--postroll-beats", default=0, choices=range(0, 17), type=int)
parser.add_argument("--limiter", help="Debug comparison only, use apple-peak-limiter or a qualified FourCC/version")
parser.add_argument("--private-drums", action="store_true")
parser.add_argument("--drum-name", help="Pin an installed take by its filename stem when using --private-drums")
parser.add_argument("--wait-lock", default=1200, type=int, metavar="SECONDS",
                    help="Wait this long for another capture to release the shared config path (default 1200)")
parser.add_argument("--capture-attempts", default=4, type=int, choices=range(1, 9), metavar="N",
                    help="Capture again when a tap drops a block under machine load (default 4 attempts)")
parser.add_argument("--hook", action="append", default=[], metavar="KEY=VALUE",
                    help="Capture hook option passed to LofiCaptureHooks (repeatable), e.g. masterProfile=ambient")
parser.add_argument("--max-true-peak", type=float, help="Pass through to analyze-lofi.py (default: the manifest's master ceiling, else -1.5)")
parser.add_argument("--next-drum-name", help="Use a second installed performance at the 16-bar switch")
parser.add_argument("--transcribe", action="store_true",
                    help="Transcribe each footage cue with the installed on-device Apple speech model before the "
                         "render (same as --hook transcription=apple). Never downloads; without the model the "
                         "capture falls back to the acoustic plan and manifest.dialogueTranscripts says why")
source = parser.add_mutually_exclusive_group()
source.add_argument("--footage", type=Path)
source.add_argument("--cached-footage", action="store_true")
source.add_argument("--film-reel", action="store_true", help="Change to another locally cached film every eight bars")
source.add_argument("--same-film", action="store_true", help="Repeat one cached film at the same offset every eight bars")
source.add_argument("--no-footage", action="store_true")
args = parser.parse_args()
if not 58 <= args.bpm <= 82 or not 128 <= args.block <= 4096 or not 0 <= args.seed < 2**64:
    parser.error("use BPM 58–82, block 128–4096, and an unsigned 64-bit seed")
if args.postroll_beats and args.bars % 16 != 0:
    parser.error("capture complete 16-bar takes to measure postroll")
if args.next_drum_name and (not args.private_drums or args.bars < 32):
    parser.error("--next-drum-name requires --private-drums and at least 32 bars")
if args.drum_name and not args.private_drums:
    parser.error("--drum-name requires --private-drums")
if args.footage and not args.footage.is_file():
    parser.error("footage path does not exist")
hooks = {"masterProfile": "lofi"}
for item in args.hook:
    key, sep, value = item.partition("=")
    if not sep or not key:
        parser.error("--hook expects KEY=VALUE")
    hooks[key] = value
if args.transcribe:
    if args.no_footage:
        parser.error("--transcribe needs footage")
    hooks["transcription"] = "apple"
out =args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix="liminal-lofi-")).resolve()
if out.is_relative_to(Path.cwd()) or (out.exists() and any(out.iterdir())):
    parser.error("use an empty output directory outside the repository")
out.mkdir(parents=True, exist_ok=True)
print(f"Lo-Fi capture directory {out}", flush=True)

# A sandboxed test host can authenticate to this loopback receiver without exposing its
# container or changing app entitlements. Nothing listens beyond the lifetime of the test.
token = secrets.token_urlsafe(24)
prefix = "/" + token + "/"
artifact_name = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}\.(wav|json|csv)$")


class Receiver(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != prefix + "input" or not args.footage:
            return self.send_error(404)
        self.send_response(200)
        self.send_header("Content-Length", str(args.footage.stat().st_size))
        self.end_headers()
        with args.footage.open("rb") as file:
            shutil.copyfileobj(file, self.wfile)

    def do_PUT(self):
        name = self.path.removeprefix(prefix)
        if name == self.path or not artifact_name.fullmatch(name):
            return self.send_error(404)
        try:
            length = int(self.headers.get("Content-Length", ""))
            if not 0 < length <= 256 * 1024 * 1024:
                return self.send_error(413)
            temp = out / (name + ".partial")
            with temp.open("xb") as file:
                while length:
                    data = self.rfile.read(min(length, 1 << 20))
                    if not data:
                        raise OSError("incomplete capture upload")
                    file.write(data)
                    length -= len(data)
            temp.replace(out / name)
        except (OSError, ValueError):
            return self.send_error(422)
        self.send_response(201)
        self.end_headers()


config_path = Path(f"/private/tmp/liminal-lofi-audio-config-{os.getuid()}.json")
configuration = dict(checkout=str(Path.cwd().resolve()), hooks=hooks, sameFilm=args.same_film, runToken=secrets.token_hex(16),
                     revision=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                     trackedDiffSHA256=hashlib.sha256(subprocess.check_output(
                         ["git", "diff", "--binary", "HEAD"])).hexdigest(),
                     seed=args.seed, tempo=args.bpm, scale=args.scale, bars=args.bars, noFootage=args.no_footage,
                     cachedFootage=args.cached_footage, filmReel=args.film_reel, privateDrums=args.private_drums, drumName=args.drum_name, nextDrumName=args.next_drum_name, block=args.block,
                     postrollBeats=args.postroll_beats, limiter=args.limiter,
                     explicitFootageSuffix=args.footage.suffix if args.footage else None)
with ThreadingHTTPServer(("127.0.0.1", 0), Receiver) as server:
    configuration["receiver"] = f"http://127.0.0.1:{server.server_port}{prefix}"
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    deadline = time.monotonic() + args.wait_lock
    announced = False
    while True:
        try:
            descriptor = os.open(config_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            config_file = os.fdopen(descriptor, "w")
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                parser.error(f"another Lo-Fi capture owns {config_path} (waited {args.wait_lock} s)")
            if not announced:
                print(f"Waiting for another Lo-Fi capture to release {config_path}", flush=True)
                announced = True
            time.sleep(5)
    try:
        with config_file:
            json.dump(configuration, config_file)
        log_path = out / "xcodebuild.log"
        # AVAudioEngine delivers tap buffers on its own queue. The offline render does not wait for
        # it, so on a busy machine a tap can fall behind and drop a block; the test then stops with
        # `skippedTapFrames`. That failure says nothing about the mix, so wait for the load to fall
        # and capture again. Every other failure is reported at once.
        for attempt in range(1, args.capture_attempts + 1):
            with log_path.open("w") as log:
                xcode = subprocess.run([
                    "xcodebuild", "test", "-scheme", "Liminal", "-destination", "platform=macOS",
                    "-derivedDataPath", os.environ.get("DD", "/private/tmp/liminal-overhaul-mac"),
                    "-parallel-testing-enabled", "NO", "-only-testing:LiminalTests/LofiMixRenderTests",
                ], stdout=log, stderr=subprocess.STDOUT)
            dropped = xcode.returncode and "skippedTapFrames" in log_path.read_text(errors="replace")
            if not dropped or attempt == args.capture_attempts:
                break
            shutil.copyfile(log_path, out / f"xcodebuild-attempt{attempt}.log")
            for stale in out.iterdir():
                if stale.suffix in (".wav", ".json", ".csv", ".partial"):
                    stale.unlink()
            quiet_by = time.monotonic() + 180
            while os.getloadavg()[0] > (os.cpu_count() or 4) and time.monotonic() < quiet_by:
                time.sleep(5)
            print(f"A capture tap dropped a block on a busy machine (attempt {attempt} of {args.capture_attempts}, "
                  f"load {os.getloadavg()[0]:.1f}); capturing again", flush=True)
        if xcode.returncode:
            for line in log_path.read_text(errors="replace").splitlines():
                if re.search(r"error:|recorded an issue|tap .*samples|TEST FAILED", line):
                    print(line, file=sys.stderr)
            sys.exit(xcode.returncode)
    finally:
        config_path.unlink()
        server.shutdown()
if not (out / "manifest.json").is_file():
    sys.exit(f"The test did not export a manifest. See {out / 'xcodebuild.log'}")
analysis = [sys.executable, "scripts/analyze-lofi.py", str(out)]
if args.max_true_peak is not None:
    analysis += ["--max-true-peak", str(args.max_true_peak)]
sys.exit(subprocess.run(analysis).returncode)
PY
