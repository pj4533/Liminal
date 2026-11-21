#!/usr/bin/env python3
"""A/V sync check for Liminal Record movies (docs/recording.md "Checking a recording", D47).

    python3 -I scripts/av-sync-check.py MOVIE.mov [--out DIR] [--grid ORIGIN,BEAT] [--bpm 69]
                                         [--beats-per-cut 32] [--plot] [--legacy]

Everything is measured from the file (no network, no app):

  * container: edit lists (a correct recording has none: both tracks start at 0), every video packet
    pts (a correct recording is constant 60 fps: every step 1/60 s, frames = duration x 60), audio
    packet continuity, and the two tracks' lengths (equal within a frame);
  * audio integrity on the whole audio media: exact-zero runs (silence the recorder inserted for lost
    audio shows here, and nowhere else) and hard splices on tap-buffer boundaries (a 3rd-order
    prediction-error spike far above its neighbourhood: what a dropped buffer leaves when the audio
    is closed up instead of padded);
  * the beat period (onset autocorrelation at 1, 4 and 8 bars of the 2-10 kHz + 40-140 Hz flux);
  * picture cuts (the first frame of a new, stable picture after a big change) and, for each, its
    downbeat: with `--log APP.log` (a `log stream` capture of the run, which has the "Recording clock"
    line and every "Lo-Fi image reveal at downbeat" uptime) the app's own audible downbeat on the movie
    clock; otherwise the kick onset nearest the cut. `offset_ms` = cut time - downbeat (positive:
    picture late). A correct drop cut is within about one 60 Hz frame (8.3 ms plus the cut's own
    early bias) of its downbeat;
  * the kick onsets in the movie's audio against the transport's beat grid (`--grid ORIGIN,BEAT`, or
    from `--log`): whether the audio sits where the transport says it is heard. The onset detector
    (5 ms RMS of a 40-140 Hz band) peaks a few ms after the attack, and recorded drums are played
    by hand, so expect a median of a few ms and an IQR of about +-15 ms, never a buffer (21-100 ms).

`--legacy` adds the analysis that diagnosed the 2026-11-21 device movie (stretched video + a ring
overrun): render rate from cut spacing, the gap from the beat-phase jump across a splice at the ring
capacity, and per-cut offsets from predicted downbeats (D47).

Needs ffmpeg/ffprobe (PATH or /opt/homebrew/bin), numpy and scipy; matplotlib for --plot.
Writes DIR/avsync.json (DIR defaults to MOVIE's folder/avsync-out), prints a summary, and exits 1 when
a check fails (non-uniform video, edit lists, a strong splice, track lengths differ, a cut more than
25 ms off). Exact-zero runs inside the movie and weak splice candidates are warnings: the first is lost
audio the recorder padded (in sync, but missing) or zeros the engine itself rendered (seen in the
visionOS Simulator, D47); the second is usually a musical edge on a block multiple.
Decoded audio and frame differences are cached in DIR; delete it after changing the movie.
"""
import argparse, json, os, shutil, struct, subprocess, sys
import numpy as np
from scipy import ndimage, signal

FF = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FP = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"


# ---------------------------------------------------------------- container
def boxes(f, start, end):
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        size, typ = struct.unpack(">I4s", f.read(8))
        hdr = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]; hdr = 16
        elif size == 0:
            size = end - pos
        yield typ.decode("latin1"), pos + hdr, pos + size
        pos += size


def parse_mov(path):
    out = {"tracks": []}
    with open(path, "rb") as f:
        f.seek(0, 2); end = f.tell()
        moov = next(((s, e) for t, s, e in boxes(f, 0, end) if t == "moov"), None)
        if not moov:
            return out
        for t, s, e in boxes(f, *moov):
            if t == "mvhd":
                f.seek(s); v = f.read(1)[0]; f.seek(s + (20 if v == 1 else 12))
                out["movie_timescale"] = struct.unpack(">I", f.read(4))[0]
            if t != "trak":
                continue
            tr = {}
            for t2, s2, e2 in boxes(f, s, e):
                if t2 == "edts":
                    for t3, s3, e3 in boxes(f, s2, e2):
                        if t3 == "elst":
                            f.seek(s3); v = f.read(1)[0]; f.read(3); n = struct.unpack(">I", f.read(4))[0]
                            ents = []
                            for _ in range(n):
                                if v == 1:
                                    d, mt = struct.unpack(">Qq", f.read(16))
                                else:
                                    d, mt = struct.unpack(">Ii", f.read(8))
                                f.read(4)
                                ents.append({"segment_duration_movie_ts": d, "media_time": mt})
                            tr["edits"] = ents
                if t2 == "mdia":
                    for t3, s3, e3 in boxes(f, s2, e2):
                        if t3 == "mdhd":
                            f.seek(s3); v = f.read(1)[0]; f.seek(s3 + (20 if v == 1 else 12))
                            tr["media_timescale"] = struct.unpack(">I", f.read(4))[0]
                            tr["media_duration"] = struct.unpack(">Q" if v == 1 else ">I", f.read(8 if v == 1 else 4))[0]
                        if t3 == "hdlr":
                            f.seek(s3 + 8); tr["handler"] = f.read(4).decode("latin1")
            out["tracks"].append(tr)
    return out


def packets(path, stream):
    r = subprocess.run([FP, "-v", "error", "-select_streams", stream, "-show_entries", "packet=pts,duration",
                        "-of", "csv=p=0", path], capture_output=True, text=True, check=True)
    rows = [l.split(",") for l in r.stdout.split() if l]
    return np.array([[int(a), int(b)] for a, b, *_ in rows], dtype=np.int64)


# ---------------------------------------------------------------- audio
def decode_audio(path, cache):
    raw = os.path.join(cache, "audio_media.s32")
    if not os.path.exists(raw):
        subprocess.run([FF, "-v", "error", "-ignore_editlist", "1", "-i", path, "-map", "0:a:0", "-c:a", "pcm_s32le",
                        "-f", "s32le", "-y", raw], check=True)
    return np.fromfile(raw, np.int32).reshape(-1, 2).astype(np.float64) / 2 ** 31


def zero_runs(a, min_len=32):
    z = (a[:, 0] == 0) & (a[:, 1] == 0)
    d = np.diff(np.r_[0, z.astype(np.int8), 0])
    st, en = np.where(d == 1)[0], np.where(d == -1)[0]
    return [(int(s), int(e - s)) for s, e in zip(st, en) if e - s >= min_len]


def splices(a, sr, blocks=(4800, 1024), ratio_min=40.0):
    """Hard joins where a dropped tap buffer (ring overrun) would leave one: on a tap-block boundary,
    the 3rd-order prediction error of either channel (or the sum) far above its 2048-sample neighbourhood.
    Random positions score under ~5 at the 99th percentile; a real splice scores 50-120."""
    rs = []
    for x in (a[:, 0], a[:, 1], a.mean(1)):
        e = np.r_[np.zeros(3), np.abs(x[3:] - 3 * x[2:-1] + 3 * x[1:-2] - x[:-3])]
        rs.append(e / (ndimage.uniform_filter1d(e, 2048) + 1e-12))
    r = np.max(rs, axis=0)
    n = len(r)
    out = []
    seen = set()
    for b in blocks:
        for k in range(b, n - 4, b):
            v = float(r[k: k + 4].max())
            if v >= ratio_min and k not in seen:
                seen.add(k)
                out.append({"sample": int(k), "seconds": k / sr, "ratio": v,
                            "block_multiples": [bb for bb in blocks if k % bb == 0]})
    out.sort(key=lambda d: d["sample"])
    return out, r


def band_flux(m, sr, lo, hi, hop):
    sos = signal.butter(4, [lo / (sr / 2), hi / (sr / 2)], "band", output="sos")
    y = signal.sosfiltfilt(sos, m)
    e = np.sqrt(np.convolve(y ** 2, np.ones(240) / 240, "same"))[::hop]
    return np.maximum(np.diff(e, prepend=e[0]), 0)


def beat_period(of, fr, guess):
    x = of - of.mean()
    best = {}
    for mult, name in [(1, "beat"), (4, "bar"), (16, "4bar"), (32, "8bar")]:
        base = guess * mult
        lags = np.arange(int((base - 0.03 * mult ** 0.5) * fr), int((base + 0.03 * mult ** 0.5) * fr) + 1)
        v = np.array([np.dot(x[:-l], x[l:]) / (len(x) - l) for l in lags])
        best[name] = float(lags[int(np.argmax(v))] / fr / mult)
    return best


def grid_phase(of, fr, P, t0, t1):
    t = np.arange(len(of)) / fr
    s = (t >= t0) & (t < t1)
    w = of[s]
    if w.sum() <= 0:
        return 0.0, 0.0
    z = (w * np.exp(2j * np.pi * t[s] / P)).sum() / w.sum()
    return float(abs(z)), float((np.angle(z) / (2 * np.pi) * P) % P)


def circ_mean_phase(of, fr, P, t0, t1, win=5.0, step=2.5):
    zs = []
    for a in np.arange(t0, t1 - win + 1e-9, step):
        R, ph = grid_phase(of, fr, P, a, a + win)
        zs.append(R * np.exp(2j * np.pi * ph / P))
    if not zs:
        return None, None
    z = np.mean(zs)
    ang = np.angle(np.array(zs) * np.conj(z))
    return float((np.angle(z) / (2 * np.pi) * P) % P), float(np.std(ang) / (2 * np.pi) * P)


# ---------------------------------------------------------------- video
def frame_diffs(path, cache, w=192, h=128):
    npy = os.path.join(cache, "vdiff.npy")
    if os.path.exists(npy):
        return np.load(npy)
    cmd = [FF, "-v", "error", "-hwaccel", "videotoolbox", "-i", path, "-map", "0:v:0", "-fps_mode", "passthrough",
           "-vf", f"scale={w}:{h}:flags=area,format=gray", "-f", "rawvideo", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    n = w * h; prev = None; d = []
    while True:
        buf = p.stdout.read(n)
        if len(buf) < n:
            break
        cur = np.frombuffer(buf, np.uint8).astype(np.float32)
        if prev is not None:
            d.append(float(np.abs(cur - prev).mean()))
        prev = cur
    p.wait()
    d = np.r_[0.0, np.array(d)]  # d[k]: change from frame k-1 to frame k
    np.save(npy, d)
    return d


def find_cuts(d, min_sep=300, min_abs=30.0, iso=3.0, settle=4):
    """Hard cuts: the first frame of a new, stable picture. A big change followed by `settle` calm
    frames (a drop's glitch build changes every frame up to the cut; the clean new picture does not).
    Falls back to an isolated spike when nothing settles."""
    cand = []
    for k in range(2, len(d) - settle - 1):
        if d[k] < min_abs:
            continue
        after = max(d[k + 1: k + 1 + settle])
        if after * iso <= d[k] and after < min_abs / 2:
            cand.append(k)
    cuts = []
    for k in sorted(cand, key=lambda k: -d[k]):
        if all(abs(k - c) >= min_sep for c in cuts):
            cuts.append(k)
    return sorted(cuts)


def read_log(path):
    """The app's log lines for this recording: the last 'Recording clock' line (T0, grid, drift) and
    every 'Lo-Fi image reveal at downbeat' (uptime of the audible downbeat a drop cut lands on)."""
    import re
    clock, reveals = None, []
    rc = re.compile(r"Recording clock: Lo-Fi take downbeat at movie ([-\d.]+) s, beat ([\d.]+) s, T0 uptime ([\d.]+)(?:, drift ([-\d.]+) ms)?")
    rr = re.compile(r"image reveal at downbeat ([\d.]+)")
    for line in open(path, errors="replace"):
        m = rc.search(line)
        if m:
            clock = {"origin": float(m.group(1)), "beat": float(m.group(2)), "t0": float(m.group(3)),
                     "drift_s": float(m.group(4)) / 1000 if m.group(4) else 0.0}
        m = rr.search(line)
        if m:
            reveals.append(float(m.group(1)))
    return clock, reveals


# ---------------------------------------------------------------- main
def nearest_onset(env, fr, t, half):
    lo, hi = int((t - half) * fr), int((t + half) * fr)
    lo, hi = max(lo, 0), min(hi, len(env))
    if hi - lo < 3:
        return None
    k = lo + int(np.argmax(env[lo:hi]))
    return k / fr, float(env[k])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("movie")
    ap.add_argument("--out", default=None)
    ap.add_argument("--bpm", type=float, default=69.0, help="tempo guess for the beat search")
    ap.add_argument("--beats-per-cut", type=int, default=32, help="Lo-Fi image interval (32 beats = 8 bars)")
    ap.add_argument("--grid", default=None, help="ORIGIN,BEAT in movie seconds from the 'Recording clock' log line")
    ap.add_argument("--log", default=None, help="the app's log for this recording: grid, T0 and every drop downbeat")
    ap.add_argument("--max-cut-ms", type=float, default=25.0, help="fail when a cut is further than this from its onset")
    ap.add_argument("--legacy", action="store_true", help="stretched-video / ring-overrun analysis (D47)")
    ap.add_argument("--gap", type=float, default=None, help="--legacy: dropped audio (s) at the first splice")
    ap.add_argument("--ring-seconds", type=float, default=10.0, help="--legacy: AudioRing capacity")
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()
    out_dir = args.out or os.path.join(os.path.dirname(os.path.abspath(args.movie)), "avsync-out")
    os.makedirs(out_dir, exist_ok=True)
    R = {"movie": os.path.abspath(args.movie)}
    fails = []

    # ---- container
    mov = parse_mov(args.movie)
    R["container"] = mov
    vtr = next(t for t in mov["tracks"] if t.get("handler") == "vide")
    atr = next(t for t in mov["tracks"] if t.get("handler") == "soun")
    vts, sr = vtr["media_timescale"], atr["media_timescale"]
    a_media_time = atr.get("edits", [{"media_time": 0}])[0]["media_time"]
    v_media_time = vtr.get("edits", [{"media_time": 0}])[0]["media_time"]
    for name, tr in (("video", vtr), ("audio", atr)):
        ed = tr.get("edits", [])
        if len(ed) > 1 or (ed and ed[0]["media_time"] != 0):
            fails.append(f"{name} edit list {ed}")

    vp = packets(args.movie, "v:0")
    vpts = np.sort(vp[:, 0]) - v_media_time
    dv = np.diff(vpts)
    vals, counts = np.unique(dv, return_counts=True)
    v_span = float((vpts[-1] + vp[-1, 1]) / vts)
    R["video"] = {
        "frames": int(len(vpts)), "timescale": vts, "span_s": v_span, "first_pts_s": float(vpts[0] / vts),
        "pts_step_histogram": {f"{v / vts * 1000:.3f} ms": int(c) for v, c in zip(vals, counts)},
        "irregular_steps": int((dv != np.median(dv)).sum()),
        "nominal_fps_from_pts": float(vts / np.median(dv)),
    }
    if R["video"]["irregular_steps"] or abs(R["video"]["nominal_fps_from_pts"] - 60) > 1e-6:
        fails.append(f"video pts not uniform 60 fps: {R['video']['pts_step_histogram']}")
    if vpts[0] != 0:
        fails.append(f"video starts at {vpts[0] / vts:.4f} s")

    apk = packets(args.movie, "a:0")
    cont = np.where(apk[1:, 0] != apk[:-1, 0] + apk[:-1, 1])[0]
    a = decode_audio(args.movie, out_dir)
    n = len(a)
    a_start = a_media_time / sr                     # media seconds at movie time 0
    a_span = (n - a_media_time) / sr
    R["audio"] = {
        "sample_rate": sr, "media_samples": int(n), "media_seconds": n / sr, "movie_seconds": a_span,
        "first_pts_samples": int(apk[0, 0]) if len(apk) else None,
        "edit_media_time_s": a_start, "packet_pts_discontinuities": int(len(cont)),
        "zero_runs_ge_32": [(s / sr, l / sr) for s, l in zero_runs(a)],
    }
    if len(cont):
        fails.append(f"{len(cont)} audio packet discontinuities")
    if abs(a_span - v_span) > 1.0 / 60 + 1.0 / sr:
        fails.append(f"track lengths differ: video {v_span:.4f} s, audio {a_span:.4f} s")
    R["tracks_length_difference_ms"] = (v_span - a_span) * 1000
    m = a.mean(1)
    sp, ratio = splices(a, sr)
    blk = 4800
    bnd = np.arange(blk, n - blk, blk)
    br = np.array([ratio[i: i + 4].max() for i in bnd]) if len(bnd) else np.zeros(1)
    R["audio"]["tap_boundary_ratio_pctl_50_99"] = np.percentile(br, [50, 99]).round(2).tolist()
    # Silence the recorder inserted starts and ends with a hard step too: not a splice.
    zr = [(s, s + l) for s, l in zero_runs(a)]
    hard = [s for s in sp if not any(abs(s["sample"] - z0) < 8 or abs(s["sample"] - z1) < 8 for z0, z1 in zr)]
    R["audio"]["hard_splices"] = hard
    warns = []
    # A closed-up overrun scores 100+ (126 on the 2026-11-21 device movie). Musical edges (dialogue
    # chops, drum hits) that happen to sit on a block multiple score up to about 60, and the fixed
    # recorder's first buffer is partial, so its tap joins are not on multiples of the block anyway.
    strong = [s for s in hard if s["ratio"] >= 80]
    if strong:
        fails.append(f"{len(strong)} hard audio splices (first at {strong[0]['seconds']:.3f} s media, ratio {strong[0]['ratio']:.0f})")
    if len(hard) > len(strong):
        warns.append(f"{len(hard) - len(strong)} weak splice candidates (ratio 40-80: usually musical edges)")
    # Zeros inside the movie: silence the recorder inserted for lost audio, or zeros the engine rendered.
    inner = [z for z in R["audio"]["zero_runs_ge_32"] if 0.05 < z[0] < a_span - 0.2]
    if inner:
        warns.append(f"{len(inner)} exact-zero runs inside the movie: " + ", ".join(f"{t:.3f} s for {l * 1000:.1f} ms" for t, l in inner[:5]))

    # ---- beat
    hop = sr // 1000; fr = sr / hop
    fh = band_flux(m, sr, 2000, 10000, hop)
    fk = band_flux(m, sr, 40, 140, hop)
    of = fh / (fh.std() + 1e-12) + fk / (fk.std() + 1e-12)
    per = beat_period(of, fr, 60 / args.bpm)
    P = per["8bar"]
    R["beat"] = {"period_by_lag": per, "period_s": P, "bpm": 60 / P}

    # ---- cuts: against the app's downbeats (--log), else against the nearest kick onset
    d = frame_diffs(args.movie, out_dir)
    cuts = find_cuts(d)
    clock, reveals = read_log(args.log) if args.log else (None, [])
    if clock and not args.grid:
        args.grid = f"{clock['origin']},{clock['beat']}"
    kick = fk / (fk.std() + 1e-12)
    per_cut = []
    if clock:
        R["log"] = {"clock": clock, "reveal_uptimes": reveals}
        for up in reveals:
            db = up - clock["t0"] - clock["drift_s"]
            if not (0 < db < v_span):
                continue
            # The biggest one-frame change within 100 ms of the downbeat, when it stands out from its
            # second: a heavy drop build (footage flashes, glitch hits) can change the picture more
            # than the cut itself, and the global detector keeps only one cut per 5 s.
            k0 = int(round(db * 60))
            lo, hi = max(1, k0 - 6), min(len(d) - 1, k0 + 7)
            c = None
            if hi > lo:
                around = np.median(d[max(1, k0 - 30): k0 + 31])
                big = [k for k in range(lo, hi) if d[k] >= 15.0 and d[k] >= 2.5 * around]
                # The new picture's first frame: the big change after which the picture settles (a
                # build's last flash frame changes as much, but the frame after it changes again).
                settled = [k for k in big if max(d[k + 1: k + 4], default=0) * 2 <= d[k]]
                pick = settled or big
                if pick:
                    c = max(pick, key=lambda k: d[k])
            if c is None:
                c = min(cuts, key=lambda c: abs(c / 60 - db)) if cuts else None
            row = {"downbeat_s": db, "frame": c, "cut_s": c / 60 if c is not None else None,
                   "offset_ms": (c / 60 - db) * 1000 if c is not None else None}
            hit = nearest_onset(kick, fr, db + a_start, 0.04)
            if hit:
                row["kick_onset_minus_downbeat_ms"] = (hit[0] - a_start - db) * 1000
            per_cut.append(row)
        if any(p["frame"] is None or abs(p["offset_ms"]) > 100 for p in per_cut):
            fails.append("a logged drop downbeat has no cut within 100 ms")
    else:
        for c in cuts:
            t = c / 60.0
            hit = nearest_onset(kick, fr, t + a_start, P / 4)
            if hit is None:
                continue
            per_cut.append({"frame": c, "cut_s": t, "downbeat_s": hit[0] - a_start, "offset_ms": (t - hit[0] + a_start) * 1000})
    R["cuts"] = per_cut
    for p in per_cut:
        if p["offset_ms"] is not None and abs(p["offset_ms"]) > args.max_cut_ms:
            fails.append(f"cut at {p['cut_s']:.3f} s is {p['offset_ms']:+.1f} ms from its downbeat")

    # ---- the app's predicted grid
    if args.grid:
        origin, beat = (float(v) for v in args.grid.split(","))
        rows = []
        k0 = int(np.ceil((0.2 - origin) / beat))
        k1 = int(np.floor((a_span - 0.2 - origin) / beat))
        for k in range(k0, k1 + 1):
            g = origin + k * beat
            hit = nearest_onset(fk / (fk.std() + 1e-12), fr, g + a_start, 0.04)
            if hit and hit[1] > 2.0:          # a kick on this beat
                rows.append((k, g, (hit[0] - a_start - g) * 1000))
        res = np.array([r[2] for r in rows]) if rows else np.zeros(0)
        R["grid"] = {"origin_s": origin, "beat_s": beat, "beats_with_kick": len(rows),
                     "kick_minus_grid_ms_median": float(np.median(res)) if len(res) else None,
                     "kick_minus_grid_ms_iqr": np.percentile(res, [25, 75]).round(2).tolist() if len(res) else None,
                     "per_beat": [{"beat": k, "grid_s": g, "kick_minus_grid_ms": round(r, 2)} for k, g, r in rows]}
        for p in per_cut:
            if p.get("cut_s") is None:
                continue
            kb = round((p["cut_s"] - origin) / beat)
            p["grid_beat"] = kb
            p["cut_minus_grid_ms"] = (p["cut_s"] - (origin + kb * beat)) * 1000

    if args.legacy:
        legacy(R, args, a, sr, of, fr, P, cuts, sp, ratio, a_media_time, mov, vpts)

    R["fails"] = fails
    R["warnings"] = warns
    with open(os.path.join(out_dir, "avsync.json"), "w") as fjs:
        json.dump(R, fjs, indent=1, default=float)

    if args.plot:
        import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
        fig, ax = plt.subplots(2, 1, figsize=(16, 7))
        ax[0].plot(np.arange(len(d)) / 60, d, lw=.5); ax[0].set_title("frame difference vs movie time (s)")
        t = np.arange(len(of)) / fr - a_start
        ax[1].plot(t, of, lw=.3); ax[1].set_title("audio onset strength vs movie time (s); red = cuts")
        for p in per_cut:
            ax[0].axvline(p["cut_s"], color="r", lw=.6); ax[1].axvline(p["cut_s"], color="r", lw=.6)
        ax[1].set_xlim(0, v_span)
        plt.tight_layout(); plt.savefig(os.path.join(out_dir, "avsync.png"), dpi=70)

    v = R["video"]
    print(f"video  {v['frames']} frames, {v['span_s']:.3f} s, steps {v['pts_step_histogram']}")
    print(f"audio  {R['audio']['movie_seconds']:.3f} s at {sr} Hz, edit start {a_start:.4f} s, "
          f"zero runs {len(R['audio']['zero_runs_ge_32'])}, hard splices {len(hard)}, "
          f"tracks differ {R['tracks_length_difference_ms']:+.2f} ms")
    print(f"beat   {P:.5f} s ({60 / P:.2f} BPM)")
    for p in per_cut:
        extra = f", {p['cut_minus_grid_ms']:+.1f} ms from grid beat {p['grid_beat']}" if "grid_beat" in p else ""
        src = "logged downbeat" if clock else "nearest kick onset"
        kk = f", kick onset {p['kick_onset_minus_downbeat_ms']:+.1f} ms from it" if "kick_onset_minus_downbeat_ms" in p else ""
        print(f"cut    frame {p['frame']} at {p['cut_s']:.3f} s: {p['offset_ms']:+.1f} ms from {src} {p['downbeat_s']:.3f} s{kk}{extra}")
    if "grid" in R:
        g = R["grid"]
        print(f"grid   {g['beats_with_kick']} kicks, kick - grid median {g['kick_minus_grid_ms_median']} ms, IQR {g['kick_minus_grid_ms_iqr']}")
    for w in warns:
        print(f"warn   {w}")
    print("PASS" if not fails else "FAIL\n  " + "\n  ".join(fails))
    print(f"json   {os.path.join(out_dir, 'avsync.json')}")
    sys.exit(1 if fails else 0)


def legacy(R, args, a, sr, of, fr, P, cuts, sp, ratio, a_media_time, mov, vpts):
    """The device-movie diagnosis (D47): video stretched by consecutive slots, audio closed up after a
    ring overrun. Predicts each cut's downbeat from the render rate implied by cut spacing."""
    n = len(a)
    atr = next(t for t in mov["tracks"] if t.get("handler") == "soun")
    a_edit_dur = atr.get("edits", [{"segment_duration_movie_ts": n - a_media_time}])[0]["segment_duration_movie_ts"] / mov["movie_timescale"]
    L = {}
    ring = int(round(args.ring_seconds * sr))
    L["ratio_at_ring_capacity"] = float(ratio[max(0, ring - 2): ring + 4].max()) if ring < n else None
    s0 = sp[0]["seconds"] if sp else None
    if s0:
        pb, sb = circ_mean_phase(of, fr, P, 0.0, s0 - 0.05)
        pa, sa = circ_mean_phase(of, fr, P, s0 + 0.3, min(n / sr, s0 + 60))
        L["phase_before_splice"] = [pb, sb]
        L["phase_after_splice"] = [pa, sa]
        L["gap_mod_beat_s"] = (pb - pa) % P if pb is not None and pa is not None else None
    phase_after = circ_mean_phase(of, fr, P, (s0 or 0) + 0.3, n / sr)[0]
    lead = a_media_time / sr
    gap = args.gap
    if gap is None and sp and abs(sp[0]["sample"] - ring) < 8:
        mech = lead - args.ring_seconds
        L["gap_mechanical_min_s"] = mech
        if L.get("gap_mod_beat_s") is not None:
            k = round((mech - L["gap_mod_beat_s"]) / P)
            gap = L["gap_mod_beat_s"] + k * P
    gap = gap or 0.0
    L["gap_used_s"] = gap
    if len(cuts) >= 2:
        df = np.diff(cuts)
        r_cut = float(np.mean(df) / (args.beats_per_cut * P))
        L["render_rate"] = {"frames_between_cuts": df.tolist(), "fps_from_cut_spacing": r_cut,
                            "fps_from_frames_over_real_span": (len(vpts) - 1) / (a_edit_dur + gap)}
        rows = []
        for c in cuts:
            tau = c / r_cut
            pred = tau + lead - gap
            b = round((pred - phase_after) / P)
            grid = phase_after + b * P
            lo, hi = int((grid - 0.08) * fr), int((grid + 0.08) * fr)
            onset = (lo + int(np.argmax(of[lo:hi]))) / fr if 0 <= lo < hi <= len(of) else grid
            rows.append({"frame": c, "cut_pts_s": c / 60, "downbeat_movie_s": onset - lead,
                         "offset_video_minus_audio_s": c / 60 - (onset - lead)})
        L["per_cut"] = rows
        if len(rows) >= 2:
            x = np.array([r["downbeat_movie_s"] for r in rows]); y = np.array([r["offset_video_minus_audio_s"] for r in rows])
            slope, icpt = np.polyfit(x, y, 1)
            L["fit"] = {"intercept_s": float(icpt), "slope": float(slope), "implied_render_fps": float(60 * (1 + slope)),
                        "residual_ms": ((y - (slope * x + icpt)) * 1000).round(1).tolist()}
    R["legacy"] = L


if __name__ == "__main__":
    main()
