# Glitch "drop" transitions: research and shader recipes

Goal: tension build over the outgoing take's fill, then a hard cut exactly on the new loop's first audible hit, new image fully clean from the downbeat on.
Note on sourcing: web search returned mostly secondary material. Sections marked (practice) are established VJ/editing/shader convention synthesized from it plus general knowledge; they are not single-source claims.

## 1. Structure of a visual drop (practice)

- Tension/release: a build (density and intensity rising, often exponential) then a single decisive event on the downbeat. Music-video structure guides describe intro with almost no cuts, build with progressively denser cuts, and the drop as one strong anchor frame, then calm ([Suno MV structure post](https://suno.bi/en/blog/intro-build-drop-mv-structure-method-sunomv-2026), marketing source, treat numbers loosely).
- Hard cut on the kick: VJ beat-sync guidance is to change state on the downbeat in a single frame, like a hard cut triggered by the kick ([VIDVOX docs](https://docs.vidvox.net/vv-edu/handout_module_2), [VJing overview](https://en.wikipedia.org/wiki/VJing)).
- Blank/flash frames: even one black or white frame creates a deliberate temporal gap and pairs well with a sudden audio change ([blank-frame transitions](https://reelmind.ai/blog/the-art-of-the-cut-creating-rhythmic-pacing-with-blank-video-transitions); smash cut: [Adobe](https://www.adobe.com/creativecloud/video/post-production/cuts-in-film/smash-cut.html)).
- Align the effect with a sound that has a sharp attack ([datamoshing guide](https://www.soundstripe.com/blogs/what-is-datamoshing)). Audio producers do the mirror image: the build-up fill/riser, then a short silence or gap, then the hit ([MusicRadar build-up tricks](https://www.musicradar.com/how-to/6-essential-build-up-edit-and-fill-tricks)). Our drum fill plays the riser role; the visual should rise with it.
- Rules that make it feel big:
  1. Monotonic rising intensity; never relax before the cut (no "dip").
  2. The cut frame is the peak of the distortion, so the change is maximally contrasting: wrecked image -> pristine image.
  3. Nothing eases after the cut. Optionally a 1-2 frame impact (below), then pristine.
  4. Vary the vocabulary per transition (pick 1-2 base glitches + a finisher) so repeats do not feel scripted.

## 2. Timing model for Liminal

Let tD = audible downbeat time of the new loop (already latency-compensated; see section 6), tS = start of the outgoing fill (landmark from the drum take; fallback tD - 2.0 s, or last beat of the bar), T = tD - tS.
Progress p = clamp((t - tS)/T, 0, 1). All glitches take an intensity a(p) and the cut happens at p=1.

Intensity curves (practice):
- `a = p^3` (cubic) gentle start, violent end; `a = (exp(k p) - 1)/(exp(k) - 1)`, k = 4..6 for a hard exponential.
- Add staircase quantization for rhythmic build: `a_q = floor(p*N)/N` blended with smooth `a` (N = number of fill hits, e.g. 8 or 16), so each fill hit steps the intensity. Better: if fill hit times are known, `a = a + 0.15 * decay(t - lastHit)` kicks.
- Event density rises too: glitch "slice rate" `rate = mix(4, 60, a)` Hz; re-hash block seeds at `floor(t*rate)` so patterns change faster toward the cut (stepped time, not smooth, reads as digital).
- Swap happens exactly at p=1 (new image from the first frame at or after tD, never later). Hide the swap: at p>=~0.9 the outgoing image is already too destroyed (or whited/blacked) for the swap to be noticed, plus an optional impact frame.

## 3. Glitch techniques as single-fragment-shader recipes

Common helpers (MSL-style pseudo):
```
float hash11(float n){ return fract(sin(n*127.1)*43758.5453); }
float hash21(float2 p){ return fract(sin(dot(p, float2(127.1,311.7)))*43758.5453); }
float tstep(float t, float rate){ return floor(t*rate); }   // stepped time
```
`a` below is the intensity in [0,1]; `uv` in [0,1], row 0 at top.

1. **RGB / chromatic split** ([Compose VHS glitch article](https://proandroiddev.com/vhs-glitch-shader-for-compose-from-zero-to-production-3139d74c48e8): apply displacement first, then split on the displaced UV so fringes follow the tear).
   `off = a*a*0.03` (up to ~3% of width) along x, or radial from centre: `dir = normalize(uv-0.5)`.
   `r = tex(uv2 + dir*off).r; g = tex(uv2).g; b = tex(uv2 - dir*off).b`. At high `a` add a y component and jitter angle per step. Cost: 3 taps (use only 3 taps total with one channel each).
2. **Block / macroblock displacement and datamosh look**. Real datamosh needs previous-frame feedback ([Codrops real-time datamosh](https://tympanus.net/codrops/2026/09/02/breaking-the-frame-building-a-real-time-datamosh-effect-with-three-js/), [Godot ping-pong buffer tutorial](https://forum.godotengine.org/t/free-tutorial-datamosh-shader-part-1-how-to-pass-textures-between-frames-sample-the-previous-frame-and-multiple-shaders-per-compositor-effect/144716)), which our single-pass shader does not have. Stateless approximation:
   ```
   float2 g = floor(uv * float2(W/bw, H/bh));        // block grid, bw,bh = 16..64 px (mix by a)
   float s = tstep(t, mix(6,30,a));
   float h = hash21(g + s);
   float gate = step(1.0 - a*0.6, h);                // fraction of blocks that move
   float2 d = (float2(hash21(g+s+7.1), hash21(g+s+3.3)) - 0.5) * a * 0.25;
   uv2 = uv + gate*d;                                // block samples from displaced source (looks like wrong-motion-vector reuse)
   ```
   Macroblock look: quantize uv inside moved blocks to 8..16 px cells (`uv2 = floor(uv2*res/q)*q/res`) so moved blocks go chunky. Fake smear: sample along a drifting direction N=4 taps and average. If true datamosh is wanted later, keep last output in a texture (we already build textures per frame; this is the expensive route, not recommended for v1).
3. **Scanline tear / horizontal slice shift**. Rows grouped into strips `strip = floor(uv.y * n)`, n = mix(6, 48, a) (strip height large = bands, small = fine tear, as in [Shotcut glitch filter](https://forum.shotcut.org/pub/glitch-video-filter)).
   `h = hash11(strip + tstep(t,rate)*13.7); gate = step(1 - a*0.8, h); uv.x += gate*(h-0.5)*a*0.4` with wrap (`fract`) or mirror. Rate-limit changes so it does not just strobe ([shadcn glitch shader](https://www.shadcn.io/shaders/glitch-shader)).
4. **Pixel sorting look**. True sorting is not feasible in one pass. Approximation: threshold on luma, then smear along a direction: `if luma(c) > thr: sample N taps stepping along x (or y) and keep the brightest/darkest tap` with `N ~ a*16`, `thr = mix(0.9, 0.3, a)`. This gives streaking "sorted" columns. Cost N taps; keep N<=12 on visionOS.
5. **Posterize / bit-crush**. `levels = mix(32, 3, a^2); c = floor(c*levels)/levels`; resolution crush: `cells = mix(res, 24, a^2); uv = (floor(uv*cells)+0.5)/cells` (pixelation increases into the cut). Optionally ordered-dither before quantize (Bayer 4x4) for a retro look.
6. **Stutter / frame hold and strobe**. Quantize time of the effect parameters (not the picture): `ts = floor(t*fps_h)/fps_h` with `fps_h = mix(12, 30, ...)` for holds, and a repeat-loop stutter by sampling the Ken Burns state at `tHold` where `tHold = tHoldStart + fract((t-tHoldStart)/L)*L`, L = one beat/16th shrinking each fill hit (the audio-style stutter edit). Strobe: `flash = step(0.5, fract(t*rate))`, rate stepping 4,8,16 Hz toward the cut; apply as inverted/boosted-contrast alternate frames. Photosensitivity caution: limit full-field flash rate to <3 Hz white-black alternation or keep strobe low-contrast; this is a viewer comfort issue (WCAG 2.3.1: no more than 3 flashes per second), so prefer the single impact frame over sustained strobing.
7. **Zoom punch / scale pulse**. `scale = 1 + a^2*0.35` plus per-hit kicks `+ 0.08*exp(-12*(t-lastHit))`; sample at `uv' = c + (uv-c)/scale`. Combined with a radial blur (4-6 taps along the radial direction) for speed feel. After the cut, scale resets to 1 instantly (the punch is the build, the clean frame is the release); optionally a punch-out (1.06 -> 1.0 in 80 ms) is a different "feel" and violates "no ease", so avoid by default.
8. **VHS tracking roll**. Horizontal band at `y0 = fract(t*speed)` with height `bh = 0.08+0.15a`: inside, `uv.x += sin(uv.y*80 + t*40)*a*0.05 + noise`, add luma noise, desaturate, bright edge line; vertical roll `uv.y = fract(uv.y + a^3 * 0.5 * stepped_random)` (picture rolls vertically, a classic "V-hold" loss). Chroma bleed: sample chroma from `uv.x - 0.01`.
9. **Slit-scan**. Needs time history; stateless version: displace each column/row by a function of position and time: `uv.x += sin(uv.y*k + t*w)*a*0.1 * (uv.y)` or sample time-warped Ken Burns state per row: `t_row = t - uv.y*delay*a`. Gives smeared/streaked tunnel look. Good for a "warp" transition type.
10. **Kaleidoscope / mirror**. Polar fold: `p = uv-0.5; ang = atan2(p.y,p.x); r = length(p); seg = 2pi/N; ang = abs(fmod(ang, seg) - seg/2); uv2 = 0.5 + r*float2(cos(ang),sin(ang))`. N steps 1 -> 2 -> 4 -> 8 across the fill (N=floor(mix(1,8,a))) so symmetry multiplies into the hit. Simple mirror: `uv.x = abs(fract(uv.x*2)-0.5)*2` style folds with rising count.
11. **Noise burst**. `n = hash21(floor(uv*res/blk) + tstep(t, 60))`; `c = mix(c, float3(n), a^3*0.8)`; blocky coloured noise (per-channel hash) reads more digital than grey grain.
12. **Whiteout / blackout flash frame**. `c = mix(c, 1.0, flash)` with `flash = smoothstep(0.85, 1.0, p)` for a rising whiteout (blow-out: pre-multiply exposure `c *= 1 + a^3*6` then tonemap) that peaks exactly at the cut so the swap is invisible; blackout: `c *= 1 - a^4`. A white flash that cuts straight to clean new image is the classic "drop" hit. To avoid a perceived fade-in, the new image must appear at full brightness in one frame.
13. **Invert flash**. `c = mix(c, 1-c, step(0.5, fract(t*rate)))` in the last 1-3 frames; or a luminance-only invert keeping hue (`c' = c * (1 - 2*luma)/luma` clamped) for a less harsh look.
14. **Wipe / shutter**. Hard-edged mask moving toward the cut: bars `mask = step(frac(uv.x*N), p_wipe)`; shutter closing: `mask = abs(uv.y-0.5) > (1-p)*0.5` (blackout bars close from top/bottom, center strip last). Combine with glitch edges (RGB split on the mask edge). The new image opens at p=1 with no reverse animation.
15. **Combination macro**. A transition = {base distortion A (geometry: tear/blocks/vhs/kaleido/slit/zoom), colour layer B (rgb split/posterize/invert/noise), finisher C (white/black/invert flash or hard black bars)}. Randomly choose A, B, C per transition from a seeded RNG; with uniform ranges on parameters (strip count, block size, hit direction) to get "a lot of different transitions" cheaply.

## 4. Impact frame conventions after the cut (practice)

- Options: (a) none; clean image from frame 0 (most precise, our default); (b) 1-2 frame (<=33 ms at 60 Hz) white flash overlaid on the new image, `c = mix(newClean, 1, 1 - (frameIdx/2))`; (c) a 1-frame over-bright/over-saturated "pop" that decays linearly in <=50 ms; (d) hold the zoom punch 1.03 for 2 frames.
- Given the user's brief ("completely done by the first hit", "no fade in"), use (a) or (b) with a hard budget of 33 ms. Never exceed ~60-80 ms, or the "easing back to normal" feeling returns.
- A 1-frame pre-cut blackout/whiteout (blank frame just before tD) is a standard device that sharpens the cut ([blank frames](https://reelmind.ai/blog/the-art-of-the-cut-creating-rhythmic-pacing-with-blank-video-transitions)); the build can end with it (the final frame before tD is a pure flash colour; the frame at tD is pristine).

## 5. Audio-visual sync tolerance

- ITU-R BT.1359-1 (1998), detectability thresholds for lip sync: roughly audio ahead of video by 45 ms to audio behind video by 125 ms; acceptability roughly 90 ms early to 185 ms late ([A/V sync overview](https://en.wikipedia.org/wiki/Audio-to-video_synchronization), [TV Technology "How bad is bad"](https://tvtechnology.com/opinions/av-synchronization-how-bad-is-bad), [Forasoft summary](https://www.forasoft.com/learn/audio-for-video/articles-audio/lip-sync-itu-r-bt-1359-tolerance-windows), [NTIA report](https://its.ntia.gov/publications/download/11-474.pdf)). Note sign conventions differ between sources; the asymmetry is robust: sound arriving after the picture (as in nature, where sound travels slower) is tolerated much more than sound arriving before the picture. Equivalent for us: the picture event may precede the audio hit by a few tens of ms without notice; the picture must not follow the audio by more than ~one frame.
- BT.1359 was derived from newsreader clips, not percussive music ([Subjective study, arXiv 2212.01686](https://arxiv.org/pdf/2212.01686)). For sharp transient events (hand claps, drum hits) the audiovisual temporal integration window is narrower and trained listeners (musicians) detect around 20-30 ms; thresholds are from the broader AV simultaneity-judgement literature (Vroomen and Keetels 2010 review, "Perception of intersensory synchrony"; Vatakis and Spence on stimulus complexity). I could not fetch these directly, so treat the 20-30 ms as approximate.
- Practical design budget: aim the cut at tD minus 0 to 8 ms (the frame that contains the onset, or at most one 60 Hz frame (16.7 ms) early); never later than tD + 8 ms. Total end-to-end error (rendering jitter + display latency) should stay under ~±20 ms. The build-up events can be sloppier (hundreds of ms), because only the cut is a sync point.
- Rendering quantization: at 60 Hz the cut can only land on a 16.7 ms grid; on visionOS the display is ~90 Hz (11 ms). Choose the frame whose presentation time is the latest one not after tD (prefer slightly early), compute from the frame's predicted presentation timestamp, not "now".

## 6. Land on the audible onset

- The scheduled sample time is when the audio engine renders the hit; the sound is heard later by output latency (device/buffer/Bluetooth). If the visual follows the scheduling clock, the picture leads the sound by exactly that output latency (small for built-in speakers, large for Bluetooth), then it looks like the picture hit early. Per the asymmetry above, early picture is tolerated better but a good implementation compensates: tD_visual = tD_sampleTime + outputLatency (+ any display pipeline latency: roughly 1-2 frames for macOS compositing, visionOS drawable queue depth).
- Liminal already clocks on the drum transport's audible downbeat (per repo docs); the build should use that audible time as tD and read device latency once when arming (CLAUDE.md contract: do not query Core Audio latency per tick).
- Drive the build from time-to-downbeat (`p` computed from a continuous clock), not from per-frame increments, so a dropped frame cannot make the cut late: on resume, p jumps forward and the cut frame still lands at tD or the first frame after.
- If the render misses the frame, apply the swap on the first frame at or after tD, never skipping it; prefer that the glitch peak is already on screen (a(p)=1 held) so a late frame still looks like part of the plan.

## 7. Defaults suggested for the implementation

- Pure-visual "cut frame": the swap happens at p=1; before that, `a` from the exponential curve (k=5) for geometry glitches, linear for flash/darkening.
- Build window: from the fill landmark to tD; if the fill start is unknown use 1 bar (about 2 s at the Lo-Fi tempo) or the final 8 beats; clamp to [0.75 s, 4 s]; if shorter than 0.5 s (e.g. user skip, ambient mode with no drum), use a short 0.4-0.6 s burst and swap at its end (a symmetrical `a` ramp up, hard cut, no ramp down).
- Ambient mode (no drum transport): same system with a fixed T and the swap at p=1 followed by a gentler 150-250 ms de-glitch is acceptable, since there is no "boom" to protect; a flag selects hard vs soft release.
- Keep seeds deterministic per transition (seed from a counter) so debug flags can reproduce a look; expose a "type" debug override for review clips.
- Perf: all of the above fit in the existing staged fragment shader with function constants per transition type (tap counts N <= 12, no loops over big radii), keeping the visionOS 2048x2048 render size.
- Archive footage: apply the same UV-space distortions to both the still and the video layer by distorting the composite UV before sampling either, so footage glitches with the image.

## Sources

- [Audio-to-video synchronization](https://en.wikipedia.org/wiki/Audio-to-video_synchronization)
- [A/V Synchronization: How Bad Is Bad?](https://tvtechnology.com/opinions/av-synchronization-how-bad-is-bad)
- [Forasoft: lip sync BT.1359 tolerance windows](https://www.forasoft.com/learn/audio-for-video/articles-audio/lip-sync-itu-r-bt-1359-tolerance-windows)
- [NTIA 11-474](https://its.ntia.gov/publications/download/11-474.pdf)
- [arXiv 2212.01686 subjective study of AV desync](https://arxiv.org/pdf/2212.01686)
- [Codrops: real-time datamosh in Three.js](https://tympanus.net/codrops/2026/09/02/breaking-the-frame-building-a-real-time-datamosh-effect-with-three-js/)
- [Godot datamosh ping-pong tutorial](https://forum.godotengine.org/t/free-tutorial-datamosh-shader-part-1-how-to-pass-textures-between-frames-sample-the-previous-frame-and-multiple-shaders-per-compositor-effect/144716)
- [VHS glitch shader for Compose](https://proandroiddev.com/vhs-glitch-shader-for-compose-from-zero-to-production-3139d74c48e8)
- [Shotcut glitch filter](https://forum.shotcut.org/pub/glitch-video-filter)
- [shadcn glitch shader](https://www.shadcn.io/shaders/glitch-shader)
- [Soundstripe datamoshing guide](https://www.soundstripe.com/blogs/what-is-datamoshing)
- [Blank video transitions](https://reelmind.ai/blog/the-art-of-the-cut-creating-rhythmic-pacing-with-blank-video-transitions)
- [Intro-Build-Drop MV structure](https://suno.bi/en/blog/intro-build-drop-mv-structure-method-sunomv-2026)
- [MusicRadar build-up tricks](https://www.musicradar.com/how-to/6-essential-build-up-edit-and-fill-tricks)
- [VIDVOX docs](https://docs.vidvox.net/vv-edu/handout_module_2)
- [Adobe smash cut](https://www.adobe.com/creativecloud/video/post-production/cuts-in-film/smash-cut.html)
