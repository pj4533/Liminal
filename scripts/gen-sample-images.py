#!/usr/bin/env python3
"""Generate images for a prompt file and lay them out on a labelled contact sheet.

    scripts/gen-sample-images.py --prompts prompts.txt --out DIR
        [--model gemini-3.1-flash-image] [--aspect 3:2] [--size 1K]
        [--limit N] [--concurrency 3] [--cols 4] [--thumb-width 640] [--retries 2]

Input is plain text (one prompt per line, '#' comments) or the JSONL written by
`scripts/print-prompts.sh --jsonl`. Output: NN.jpg per prompt, manifest.json and
contact-sheet.jpg. The API key comes from GEMINI_API_KEY or Liminal/Secrets.swift;
it is sent in the x-goog-api-key header and never printed or written.
"""

import argparse
import base64
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_key():
    key = os.environ.get("GEMINI_API_KEY")
    if key:
        return key
    path = os.path.join(ROOT, "Liminal", "Secrets.swift")
    try:
        with open(path) as f:
            match = re.search(r'"(AIza[^"]+)"', f.read())
    except OSError:
        match = None
    if not match:
        sys.exit("No API key: set GEMINI_API_KEY or fill Liminal/Secrets.swift")
    return match.group(1)


def load_prompts(path):
    items = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("{"):
                spec = json.loads(line)
                items.append({"prompt": spec["text"], "style": spec.get("styleID", ""),
                              "palette": spec.get("paletteID", ""), "subject": spec.get("subjectID", ""),
                              "transformation": spec.get("transformationID", ""),
                              "strong": spec.get("needsStrongSurreal", False)})
            else:
                items.append({"prompt": line, "style": "", "palette": "", "subject": "", "transformation": "",
                              "strong": False})
    return items


def generate(key, model, prompt, aspect, size, retries):
    body = {"contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"responseModalities": ["IMAGE"], "imageConfig": {"aspectRatio": aspect}}}
    if size:
        body["generationConfig"]["imageConfig"]["imageSize"] = size
    data = json.dumps(body).encode()
    last = "unknown"
    for attempt in range(retries + 1):
        req = urllib.request.Request(API.format(model=model), data=data, method="POST",
                                     headers={"Content-Type": "application/json", "x-goog-api-key": key})
        start = time.time()
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                payload = json.load(resp)
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
            try:
                last += ": " + json.load(e).get("error", {}).get("message", "")[:120]
            except Exception:
                pass
            if e.code in (429, 500, 503) and attempt < retries:
                time.sleep(5 * (attempt + 1))
                continue
            return None, last, time.time() - start
        except Exception as e:  # network, timeout
            last = type(e).__name__
            if attempt < retries:
                time.sleep(3)
                continue
            return None, last, time.time() - start
        candidates = payload.get("candidates") or []
        for cand in candidates:
            for part in (cand.get("content") or {}).get("parts") or []:
                inline = part.get("inlineData")
                if inline and inline.get("data"):
                    return base64.b64decode(inline["data"]), "ok", time.time() - start
        reason = candidates[0].get("finishReason") if candidates else payload.get("promptFeedback", {}).get("blockReason")
        return None, f"no image ({reason})", time.time() - start
    return None, last, 0


def contact_sheet(out_dir, rows, cols, thumb_width):
    sheet_path = os.path.join(out_dir, "contact-sheet.jpg")
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return ffmpeg_sheet(out_dir, rows, cols, thumb_width, sheet_path)
    thumb_h = int(thumb_width * 2 / 3)
    label_h = 28
    n = len(rows)
    grid_rows = (n + cols - 1) // cols
    sheet = Image.new("RGB", (cols * thumb_width, grid_rows * (thumb_h + label_h)), (20, 20, 20))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
    except Exception:
        font = ImageFont.load_default()
    for i, row in enumerate(rows):
        x, y = (i % cols) * thumb_width, (i // cols) * (thumb_h + label_h)
        if row["status"] == "ok":
            img = Image.open(os.path.join(out_dir, row["file"])).convert("RGB")
            img.thumbnail((thumb_width, thumb_h))
            sheet.paste(img, (x + (thumb_width - img.width) // 2, y + (thumb_h - img.height) // 2))
        else:
            draw.rectangle([x, y, x + thumb_width - 1, y + thumb_h - 1], fill=(90, 90, 90))
            draw.text((x + 10, y + thumb_h // 2), row["status"][:60], fill=(255, 255, 255), font=font)
        label = f'{i:02d} {row["style"]} / {row["palette"]}'.strip()
        draw.text((x + 6, y + thumb_h + 4), label, fill=(230, 230, 230), font=font)
    sheet.save(sheet_path, quality=88)
    return sheet_path


def ffmpeg_sheet(out_dir, rows, cols, thumb_width, sheet_path):
    if not shutil.which("ffmpeg"):
        print("Neither Pillow nor ffmpeg available; skipping contact sheet", file=sys.stderr)
        return None
    thumb_h = int(thumb_width * 2 / 3) // 2 * 2
    inputs, filters, labels = [], [], []
    for i, row in enumerate(rows):
        if row["status"] == "ok":
            inputs += ["-i", os.path.join(out_dir, row["file"])]
        else:
            inputs += ["-f", "lavfi", "-i", f"color=gray:s={thumb_width}x{thumb_h}"]
        text = f'{i:02d} {row["style"]} {row["palette"]}'.replace(":", " ").replace("'", "")
        filters.append(f"[{i}:v]scale={thumb_width}:{thumb_h}:force_original_aspect_ratio=decrease,"
                       f"pad={thumb_width}:{thumb_h}:(ow-iw)/2:(oh-ih)/2,"
                       f"drawtext=text='{text}':x=6:y=h-26:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.6[t{i}]")
        labels.append(f"[t{i}]")
    pad = (-len(rows)) % cols
    for k in range(pad):
        idx = len(rows) + k
        inputs += ["-f", "lavfi", "-i", f"color=black:s={thumb_width}x{thumb_h}"]
        filters.append(f"[{idx}:v]null[t{idx}]")
        labels.append(f"[t{idx}]")
    layout = "|".join(f"{(j % cols) * thumb_width}_{(j // cols) * thumb_h}" for j in range(len(labels)))
    graph = ";".join(filters) + ";" + "".join(labels) + f"xstack=inputs={len(labels)}:layout={layout}[out]"
    cmd = ["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", graph, "-map", "[out]",
           "-frames:v", "1", sheet_path]
    subprocess.run(cmd, check=False)
    return sheet_path if os.path.exists(sheet_path) else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prompts", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default="gemini-3.1-flash-image")
    ap.add_argument("--strong-model", default=None,
                    help="model for prompts tagged needsStrongSurreal (default: same as --model)")
    ap.add_argument("--aspect", default="3:2")
    ap.add_argument("--size", default="1K")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--concurrency", type=int, default=3)
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--thumb-width", type=int, default=640)
    ap.add_argument("--retries", type=int, default=2)
    args = ap.parse_args()

    key = load_key()
    items = load_prompts(args.prompts)
    if args.limit:
        items = items[:args.limit]
    os.makedirs(args.out, exist_ok=True)

    def work(index_item):
        index, item = index_item
        model = args.strong_model if (item["strong"] and args.strong_model) else args.model
        data, status, latency = generate(key, model, item["prompt"], args.aspect, args.size, args.retries)
        row = dict(item, index=index, model=model, latency=round(latency, 1), status=status, file=None)
        if data:
            ext = "png" if data[:4] == b"\x89PNG" else "jpg"
            row["file"] = f"{index:02d}.{ext}"
            with open(os.path.join(args.out, row["file"]), "wb") as f:
                f.write(data)
        print(f"{index:02d} {status:>10} {latency:5.1f}s {item['style']} / {item['palette']}", file=sys.stderr)
        return row

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        rows = sorted(pool.map(work, enumerate(items)), key=lambda r: r["index"])

    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(rows, f, indent=2)
    sheet = contact_sheet(args.out, rows, args.cols, args.thumb_width)
    ok = sum(1 for r in rows if r["status"] == "ok")
    print(f"{ok}/{len(rows)} images, sheet: {sheet}", file=sys.stderr)


if __name__ == "__main__":
    main()
