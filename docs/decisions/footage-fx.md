# Footage interaction modes: decisions

Decision log for the footage-effects workstream. Plan with all numbers: `docs/plans/footage-fx.md`.
Request: composite the archive footage in more ways than a blend, bring it in through the effects, let
film and effects interact.

Status: built on both platforms (F10-F19): 17 recipes (today's four looks plus 13 interaction modes) picked
by the weaver, shader, uniforms, DEBUG flag `-LiminalVideoMode`, unit tests. Blind-judge round 0 scored
(F20); tuning round 1 (F21-F22) made every mode show the film's shape and replaced Ghost film with Facets;
tuning round 2 (F23-F26) made the film a shaped region with its own treatment, replaced Palette with Poster
and split the glass drives into their own shader group. Final verification (F27-F28): visionOS 27.2
Simulator 3 min run (11 recipes in 19 pieces, no back-to-back repeat, 79.4 fps, no slow frame at a piece
change), macOS run, parity, GPU A/B, judge-set gates, builds and 133 tests. Not done: round-2 blind judges
and the headset (plan 9.5).

## Tooling and baseline

### F1. Render the footage offline with the app's own decoder timing and pre-pass kernel
- What: `scripts/shader-bench.sh --footage-seq` decodes an mp4 with `AVAssetReader`, ticks at 30 Hz at the
  piece's rate as `VideoFrameSource` does, measures levels as `ArchiveClipValidator` does and runs
  `videoPrepass` (compiled from `ArchiveVideo.metal`) into three rotating stage textures; the uniforms come
  from `EffectsUniformsComputer.compute(video:)` with a real `VideoCompositeState`. `scripts/ffx-clip.sh`
  wraps it (footage on, footage off, effect-free reference, clip, filmstrip, scores).
- Why: the bench's existing `--video FRAME.png` builds one stage on the CPU with an edge measure in the
  motion channel. The new modes read motion and the slow average over time, so a still frame cannot show
  or score them, and a CPU copy of the pre-pass would drift from the kernel.
- A second clip on layer B with the weaver's complementary crossfade (`--footage-b`, `--footage-xfade`) is
  included from the start: every mode has to hold through a piece-to-piece crossfade.

### F2. Score a clip against its footage-off twin and its effect-free reference
- What: `scripts/ffx-check.py`. Readability = HOG (and edge) similarity to the effect-free picture with
  footage, divided by the same without (`keep_hog`). Visibility = mean difference to the footage-off frame
  and the area that differs; `film_corr` and `motion_corr` relate that difference to the film's tones and
  motion (the stage is dumped per frame). Calm = frame step, second difference, mean-luma flash.
- Why the ratio to the twin: the effects already cost some structure (E2); what matters here is what the
  footage adds. Why the stage dump: a drive shows the film without matching its tones, so "is the film
  there" needs a movement-based score next to the tone-based one.

### F3. The step gate is absolute, not a ratio
- Today's looks on the dark hummingbird picture change the frame by at most 0.0044 per 1/30 s, which is
  2-2.8 times the footage-off step of that almost still picture; the same looks on the bright picture are
  at 1.1-1.5 times. A ratio gate fails today's (calm, liked) looks, so the gate is the absolute 95th
  percentile step <= 0.010 and the ratio is reported.

### F4. Baseline: the picture is safe, the film is faint, and it shows only where the picture is dark
- Measured on 2 pictures x 2 clips x 4 looks at the weaver's mid level (plan section 1):
  `keep_hog` 0.96-1.00, mean difference 3-5 levels (Emerge 10-15), `motion_corr` 0.3-0.65.
- On the dark picture the film reads as a ghost figure in the picture's colours. On the bright, saturated
  picture it is a haze (Window softens detail without showing the film's shapes; Phantom and Imprint are
  nearly invisible in a still frame). High-key film is a flat wash in every look.
- Consequence for the design: modes act through the picture's own pixels (warp, fringes, hue, light) so
  the film has a way into bright pictures, and the shadow behaviour becomes deliberate (luminance and
  depth keys).

## Design

### F5. Three choices per piece (carrier, key, drive), picked as curated recipes
- Why not one flat list of new looks: most modes are not blends. A drive (the film steering an effect)
  combines naturally with a faint blend so the film can still be found, and a key (where the film may
  show) combines with any blend. Why not the free product: about 5 x 4 x 9 combinations, most of them
  untested and some ugly. Seventeen named recipes in five families are tested one by one and can be
  dropped one by one.

### F6. The film is tapped once at the top of stage B; drives are summed over both layers
- Why: displacement and fringing must be known before the picture is sampled, and the composite comes
  after. One tap per layer feeds every hook, so a drive costs arithmetic, not samples (Undertow +2,
  Relief +1). The drive fields are sums weighted by each layer's amount, which contains the piece's
  crossfade envelope: two pieces with different modes crossfade without a special case.
- Stage A (`distortedUV`) and the plain fragments are not touched, so footage-off frames stay identical to
  `main` by construction (A7).

### F7. Edge magnitude goes into the stage's unused alpha; gradients stay in the fragment shader
- Why: alpha is written 1 and never read; the pre-pass runs at 960 x 720 and 15-25 Hz, so four more reads
  there are free. A gradient needs two signed channels, which would mean a second stage texture; that is
  kept as the fallback if Undertow's two extra samples break the GPU budget.

### F8. Budget relative to today's footage-on cost
- One layer in any recipe <= 15 % over today's one-layer frame, two layers <= 15 % over today's two-layer
  frame, plain looks <= 3 % after the refactor, footage off identical. Today (Apple M4, mono, 2048 x 2048):
  off 4.58 ms, one layer 4.95 ms, two layers 5.36 ms.

### F9. Left out
- Film grain and dither noise (per-frame noise is flicker), optical-flow direction for the warp (the
  stage has motion magnitude only), the film as a transition's swap order (the footage dips while a
  picture arrives), a blurred halo (needs a spatial blur pass).

## Build (round 0)

### F10. Pre-drives get a small tap of their own; everything else taps the film at the composite
- What: Undertow and Fringe (and Ghost film's Fringe half) must move the picture's samples, so they sample
  the stage at the top of stage B (`addPreDrive`, 1 sample, Undertow +2). Every other drive, key and carrier
  reads one tap taken where today's composite samples (`tapFootage`, `addDrive`, `compositeVideo`).
- Why not "tap once at the top" (plan 2.2, F6): keeping both layers' taps live across the picture samples
  cost occupancy for no gain; measured with the hook groups removed one by one, every group added 2-4 %
  and the sum reached 1.14x on a plain look. The drive fields that do cross stages are 6 halves.
- The film is tapped at the stage-A uv in the mode variants (it does not ride its own Undertow); the blend
  variant keeps today's post-parallax uv, so the plain looks stay bit-identical (F11).

### F11. Four footage shader variants; the weaver never needs the full one
- What: `shadeEye<kVideo>` with bits FOOTAGE 1, KEYS 2 (keys, Kaleido, Palette, Print), DRIVES 4. Fragments:
  `effectsFragment[Stereo]Video` (1: today's looks, code identical to `main`), `...VideoKeys` (3),
  `...VideoDrives` (5), `...VideoFX` (7). `VideoComposite.footageVariant(uniforms)` picks per frame; both
  renderers and `shader-bench` build the extra pipelines once and fall back to the blend variant.
- Why: registers are allocated for the worst path of a variant, so one mode variant made every mode pay for
  all hooks (Palette, which has no drive, cost 1.19x). Split, each frame pays only for its group.
- The weaver never crossfades a key-group recipe into a drive-group one or back (`shaderGroup`,
  `FootageWeaver.compatible`): a plain look sits between them, so variant 7 (1.34x with two layers) only
  exists as a fallback.
- Parity (`shader-bench --compare` against `main`): footage off identical (max abs diff 0, stereo and mono);
  the four plain looks identical too (0, mono, footage on).
- GPU (Apple M4, mono two-pass 2048 x 2048, romanesco, 5 x 200 frames, interleaved B/A against `main`'s
  Window look): footage off 1.00; plain looks 1.00; one layer: Solar 1.07, Palette 1.08, Wake 1.08, Aurora
  1.08, Shadowplay 1.08, Print 1.08, Ghost film 1.08, Glow 1.09, Relief 1.10, Kaleido 1.12, Fringe 1.13,
  Undertow 1.15 (limit 1.15). Two layers against `main`'s two layers: mode + plain 1.15-1.17, two drive
  modes 1.15-1.21 (Wake + Aurora 1.15, Undertow + Fringe 1.21), two key modes 1.23 (Kaleido + Print).
  The two-mode crossfades are over the plan's 1.15 for the few seconds a crossfade lasts; accepted for
  now and listed under Open (fallback: forbid same-group crossfades, which would raise the plain share).

### F12. Amounts after the first look: the modes were too faint on a bright picture
- The first renders at the plan's numbers read like today's looks on the romanesco: mean difference under 2
  levels for Fringe, Wake, Glow, Print, Kaleido, while readability had all its headroom (`keep_hog`
  0.97-1.00). Raised: Undertow maximum 0.016 -> 0.028 UV with an 8-texel stencil (the film's broad shapes
  bend the picture, not the foil texture), Fringe 0.014 -> 0.022 UV, Relief 0.45 -> 0.70, Solar mix
  0.55 -> 0.75 x k and its ceiling (0, 0.75, 1.0), Glow bloom x (1 + 3.5 g) with a 0.7 g brightness floor,
  Wake feedback warp x (1 + 3 w), Print ceiling (0, 0.75, 0.9). Aurora was the strongest from the start
  and is unchanged.
- Drive ceilings by intensity 0 / 0.5 / 1 (`FootageDrive.ceilings`) carry the size; the shader maxima are
  amount 1. Amount = envelope x ceiling x (0.6 + 0.4 clarity) x hold (F15).

### F13. Shadowplay: the film is light in the picture's shadows and ink in its highlights
- What: keyed Palette carrier. In shadows (key `1 - smoothstep(0.08, 0.32, Y)`) the film's whites glow in
  the tint over the picture's colour; on a bright picture without a dark ground the key flips to the
  highlights (`smoothstep(0.50, 0.80, Y)`) and the film's blacks sink to the shade.
- Why: with the plan's gradient map the dark film parts disappeared into the dark ground and only the
  film's lights showed, on the subject. Polarity is from the 16 x 16 thumbnail the tint already uses
  (shadows when at least 18 % is darker than 0.3), eased like the tint and blended continuously in the
  shader, so a new picture never flips the key in one frame.

### F14. Kaleido rides Palette, not Phantom, and folds harder
- Phantom screens the film's highlights, which is invisible on a bright picture (mean difference 0.55 levels).
  Palette inside the Window oval shows the fold on any picture. Fold strength 0.85-1.0 (a 0.6 partial fold
  read as smear, not ornament). 6 or 8 wedges by seed, turning slowly; the hexagonal Facets variant of the
  plan is not built.

### F15. Holds, crossfades and the clarity cycle
- Geometric drives (Undertow, Fringe, Ghost film) are zero in the fresh-image hold (`EffectLook.fresh`); the
  others dip with the mix's settled term. Drives scale with the piece's envelope (and its swell, not its
  level, `FootagePiece.driveEnvelope`), so a crossfade between two modes fades one drive out as the next
  fades in. Pinned stills (`-LiminalVideoMix`) use envelope 1.

### F16. Weaver: recipes, families, plain share
- `FootageWeaver.chooseRecipe`: eligible by intensity and depth map; never the previous recipe or family or
  an incompatible shader group (F11); recently used (last 4) at half weight; water halved under intensity
  0.25; after a mode the plain looks get at least 45 % of the weight. A plain piece is never followed by
  another (same family), so 45 % gives about 30 % plain pieces (unit test: 22-42 % over 200 pieces, 150
  seeds, 3 intensities). Emerge, Solar and Print are capped at 16 s and never swell.
- Backdrop is eligible only when the visionOS render loop reports a depth texture (`Conditions.hasDepth`).

### F17. Smaller choices
- Carrier-less recipes (Solar, Ghost film) write `videoLook` 0 (VIDEO_NONE) and a mix from the Window
  ceiling: the mix stays the renderers' layer gate (textures, pipeline) and the shader skips the blend.
- Solar has no Window oval: its fold already follows the film's highlights only.
- Print: halftone dots in the film's coordinates (82 cells across, 30 degrees, `fwidth` edges) for seeds
  under 0.5, soft four-level posterised bands otherwise. Ink is the shade colour.
- Stage alpha = edge magnitude of the previous stage's slow average, eased with the motion coefficient
  (F7 as planned). The bench's CPU stage for single frames writes its edge into alpha too.
- `-LiminalVideoMode <recipe>` (alias `-LiminalFootageMode`) pins a recipe; `-LiminalVideoLook` still pins a
  plain look. `shader-bench --video-mode / --video-mode-b`, `ffx-clip.sh --mode / --mode-b / --reuse`.

### F18. Shadowplay's mix follows how much of the picture its key covers
- Round 0: on the dark hummingbird the shadow key covered nearly the frame, so the film took it over
  (difference 18 levels, keep_edge 0.73, jerk ratio 1.89 over the 1.8 gate). The picture statistics now also
  give the key's coverage (thumbnail share under 0.3 luma, or over 0.6 for the highlight key), eased like
  the tint; the mix is scaled by `min(max(0.35 / coverage, 0.4), 1)`. After: keep_edge 0.98-0.99, jerk 1.04-1.27,
  difference 4-8 levels, every gate passes.

### F19. Round 0: every recipe on 2 pictures x 2 films (68 clips, 8 s, intensity 0.5, level 0.5)
- Readability: `keep_hog` median at least 0.946 on every clip before F18, 0.959 after (the gate is 0.85;
  today's looks 0.96-1.00). The still image stays the anchor in every clip (overview sheet).
- Calm: step p95 at most 0.0061, flash at most 0.028, jerk at most 1.40 after F18.
- Visibility: 9 clips are under the 2-level gate, all on the dark, low-texture hummingbird or with the
  high-key Mennen film, and all drives that act through the picture's own pixels: Relief (3 clips, 0.9-1.7
  levels), Ghost film (2), Fringe, Glow, Undertow (Mennen on the hummingbird, 1.6-1.8) and Print (WhatsIt on
  the hummingbird, 1.2). Nothing is broken; the film is faint there. Left for the judges (a drive that
  shows little on a dark picture may still read as movement), then a per-mode retune.
- Aurora and Shadowplay are the most visible modes (difference 7-11 levels), Kaleido is subtle at the
  weaver's level (a mandala hint, 4 levels).

## Tuning round 1

### F20. Round 0 blind verdicts: the film was invisible in nearly every mode
- Two blind judges scored the 68 round-0 clips (1-5 on five axes). Mapped to recipes through the private
  key and averaged over both judges and the 4 clips of each recipe (distinct, interplay, image readable,
  footage noticeable, beautiful):

  | Recipe | dist | inter | read | notice | beauty |
  |---|---|---|---|---|---|
  | Backdrop | 3.25 | 2.88 | 4.00 | 3.38 | 3.75 |
  | Emerge | 3.25 | 2.75 | 4.00 | 3.25 | 3.62 |
  | Shadowplay | 2.62 | 2.12 | 4.38 | 2.25 | 3.38 |
  | Kaleido | 2.00 | 1.88 | 4.75 | 1.75 | 3.62 |
  | Phantom | 1.75 | 1.75 | 4.75 | 1.88 | 3.38 |
  | Aurora | 2.00 | 1.62 | 4.88 | 1.38 | 3.38 |
  | Wake | 1.50 | 1.50 | 4.88 | 1.62 | 3.38 |
  | Window | 1.62 | 1.50 | 4.62 | 1.62 | 3.25 |
  | Palette | 1.50 | 1.38 | 4.75 | 1.62 | 3.25 |
  | Imprint | 1.50 | 1.38 | 4.88 | 1.50 | 3.25 |
  | Solar | 1.25 | 1.25 | 5.00 | 1.12 | 3.25 |
  | Fringe | 1.12 | 1.12 | 5.00 | 1.12 | 3.25 |
  | Print, Glow, Relief, Undertow, Ghost film | 1.00 | 1.00 | 5.00 | 1.00 | 3.25 |

- Every recipe is under 3.5 on at least one axis; most read "baseline-like, no film visible". The best
  single clips showed the film's *shape*: Kaleido with WhatsIt on the hummingbird (a scalloped film shape
  that shatters into shards, 5/5/4/4/5), Backdrop's palette-tinted glow field behind the romanesco, Emerge
  and Window figures on the dark picture. A drive that only modulates the picture's own pixels with the
  film's slow average (round-0 Aurora: "a colour effect, no film seen") is not perceived as footage.
- Readability had all its headroom (4-5 everywhere): the modes can be much louder.

### F21. Round 1 changes: every mode shows the film's figure; Ghost film replaced by Facets
- Drives read the film's figure (`figureOf` = 0.3 slow average + 0.7 levelled luma) instead of the slow
  average alone, which had blurred moving figures into a haze. Undertow, Relief and Glow use a calmer
  0.6/0.4 mix (`figureSoftOf`): the levelled luma steps at the film's frame rate, which read as jitter on
  the dark, still hummingbird (jerk ratio 2.2-2.5 in the first round-1 renders, 1.5-1.8 after).
- The pre-pass edge (stage alpha) is the edge of the levelled luma, not of the slow average (crisper
  contours for Fringe). The blend looks never read alpha, so they stay bit-identical.
- A new screened light term `lift` (in the picture's colours lifted toward the tint, so it shows on a dark
  picture): Glow's film highlights, Wake's moving parts, Fringe's contours.
- Per mode:
  - Undertow: figure gradient on a 5-texel stencil (8 texels of the slow average before), maximum
    0.028 -> 0.032 UV, plus a pane light along the film's shapes through Relief's light (one extra
    sample at the composite; a separate shade value cost 2-3 % for every drive).
  - Wake: carrier share 0.5 -> 0.8, trail feedback +0.28 (was +0.24), moving parts lift 0.25.
  - Ghost film (Wake + Fringe, indistinct from both, 1.0 on every axis) -> **Facets**: the picture is cut
    into triangular shards (30 per frame height, slowly turned grid by seed); where the film's figure is
    bright (or dark, by seed) each shard flattens toward the picture at its centre and slips by its own
    small offset: the film's shapes appear as cut glass made of the picture. A pre-drive (no extra live
    value), faint Imprint carrier (0.5), water family, intensity >= 0.3. Built on round 0's best clip,
    whose appeal was shards.
  - Fringe: chroma split 0.022 -> 0.030 UV, plus the contours themselves: light on the picture's darks
    (lift 0.4) and ink on its lights (a negative relief), so they read on the bright romanesco too.
  - Aurora: hue offset x 1.4 plus iridescent contour bands along the film's levels (sin of 6 pi x figure),
    hue blend floor 0.35: the figure is drawn in hue.
  - Solar: key smoothstep(0.42, 0.66) on the figure (was 0.35-0.85 on the slow average), fold 0.75 -> 0.9.
  - Relief: 4-texel light step x 14 on the soft figure (3 x 5), maximum 0.7 -> 1.0, +0.10 light on the lit
    side, carrier 0.3 -> 0.55.
  - Glow: lift 0.7 on the film's highlights; the bloom boost halved (its per-frame noise flickered).
  - Print: ink from the figure, and it contrasts with what it lands on (shade on the picture's lights, a
    lifted tint on its darks); carrier share 1.4. Round 0's multiply by a dark ink vanished on dark pixels.
  - Palette, Kaleido: gradient map contrast smoothstep(0.14, 0.86) (was 0.08-0.92); shares 1.5 and 1.5.
  - Shadowplay 1.3 -> 1.7, Backdrop 1.2 -> 1.6 (their key coverage gain, F18, still applies).
  - Drive ceilings at intensity 0.5 raised 5-15 % (Undertow 0.75, Fringe 0.8, Wake 0.9, Aurora 0.8,
    Solar 0.85, Relief 0.85, Glow 0.85, Facets 0.8).
- The four plain looks are unchanged on purpose: they are the shipped, liked baseline and must stay
  bit-identical to `main`; with modes now louder they are the quiet pieces between them.

### F22. Round 1 measurements (68 clips, same images, films, timeline and level as round 0)
- Mean difference to footage off per recipe, round 0 -> round 1 (levels, average of 4 clips): Undertow
  3.8 -> 5.1, Wake 4.2 -> 7.6, Facets (new) 5.2, Fringe 2.9 -> 5.2, Aurora 8.5 -> 15.6, Solar 3.1 -> 7.5,
  Palette 3.8 -> 6.0, Shadowplay 6.0 -> 8.0, Backdrop 8.0 -> 10.6, Kaleido 3.6 -> 5.2, Relief 1.6 -> 4.9,
  Glow 2.7 -> 10.8, Print 2.4 -> 7.9; plain looks unchanged (3.8-13.0). No mode clip is under the 2-level
  gate now (lowest: Facets with the high-key Mennen film on the hummingbird, 2.25).
- Readability: `keep_hog` at least 0.931 (Relief, WhatsIt on the romanesco), every other clip >= 0.948;
  gate 0.85. The overview sheet reads the picture in all 68.
- Calm: flash at most 0.034, step p95 at most 0.0100 (Undertow on the romanesco, at the gate). One clip
  over a gate: Wake with Mennen on the hummingbird, jerk ratio 1.86 (gate 1.8) at an absolute step of
  0.0046; on that dark, nearly still picture any film motion is a large ratio (F3). Accepted for the judges.
- GPU (Apple M4, mono 2048 x 2048, 5 x 200 frames, against `main`'s Window frame in the same run; noise
  about +-2 %): Print 1.10, Aurora 1.11, Relief 1.13, Wake 1.13, Glow 1.13, Kaleido 1.13, Fringe 1.15,
  Undertow 1.17, Facets 1.19. The louder modes cost 3-5 % more than round 0 (one more sample in Undertow
  and Relief, the lift, the larger drive function). Undertow and Facets are over the 15 % target; the
  fallback is to split the drives variant into a pre-drive group (Undertow, Fringe, Facets) and a
  composite group (the rest), each paying only for its own hooks (F11's method).
- Parity: footage off identical to `main` (max abs diff 0, stereo and mono); the four plain looks
  identical with footage on (0, mono). Builds: macOS, visionOS simulator, visionOS device; 133 unit tests pass.

## Tuning round 2

### F23. Round 1 blind verdicts: louder, but the film still read as a tint
- Two blind judges scored the 68 round-1 clips; mapped through the private key and averaged over both
  judges and the 4 clips of each recipe (distinct, interplay, image readable, footage noticeable, beautiful):

  | Recipe | dist | inter | read | notice | beauty |
  |---|---|---|---|---|---|
  | Aurora | 3.38 | 3.00 | 4.50 | 2.38 | 4.00 |
  | Print | 3.38 | 3.00 | 4.00 | 2.88 | 3.38 |
  | Solar | 2.75 | 2.75 | 4.62 | 2.25 | 3.75 |
  | Kaleido | 2.62 | 2.62 | 4.38 | 2.12 | 3.38 |
  | Relief | 2.50 | 2.50 | 4.50 | 2.25 | 3.12 |
  | Facets | 2.50 | 2.38 | 4.25 | 1.75 | 3.12 |
  | Backdrop | 2.00 | 2.25 | 4.50 | 2.88 | 3.25 |
  | Emerge (plain) | 1.75 | 2.12 | 4.62 | 2.38 | 3.12 |
  | Wake | 1.62 | 1.88 | 4.88 | 2.25 | 3.25 |
  | Glow | 1.62 | 1.88 | 4.75 | 2.25 | 3.38 |
  | Shadowplay | 1.50 | 1.88 | 4.75 | 2.25 | 3.25 |
  | Phantom (plain) | 1.38 | 1.50 | 4.62 | 1.75 | 3.25 |
  | Window (plain) | 1.25 | 1.50 | 4.88 | 1.62 | 3.25 |
  | Fringe | 1.25 | 1.50 | 4.88 | 1.62 | 3.25 |
  | Palette | 1.25 | 1.50 | 4.62 | 1.88 | 3.12 |
  | Undertow | 1.12 | 1.50 | 5.00 | 1.38 | 3.25 |
  | Imprint (plain) | 1.00 | 1.25 | 5.00 | 1.38 | 3.25 |

- Still every recipe under 3.5 on at least one axis, but the spread opened up: the clips the judges liked
  (Kaleido's posterised shard mosaic 5/5/3/4/4, Print's halftone in tone-shaped regions 5/4/4/4/4, Aurora's
  magenta film regions with the bird recoloured 4/4/5/3/4, Solar's etched texture 4/4/4/2/5) all show the
  film as a *hard-edged region with its own treatment*. Soft, low-contrast changes (Palette's gradient map,
  Fringe's thin contours, Undertow's outline bend, Glow's light, Wake) read as "baseline-like" or "a plain
  blend", and readability (4.0-5.0) still had headroom everywhere.
- The four plain looks are the shipped baseline and stay bit-identical to `main` (F21): they are the quiet
  pieces between modes, not candidates for this retune.

### F24. Round 2 changes: the film as a shaped region with its own treatment; Poster replaces Palette
- Indistinct, replaced: **Palette -> Poster** (new carrier `VIDEO_POSTER` 7, keys group, colour family): the
  picture posterised into four flat bands of its own colour (chroma raised, every other band pulled toward
  the tint); the film's figure shifts the band thresholds, so the band edges follow and crawl with the
  film's shapes. It acts through the picture's own pixels, so it reads on a bright picture where the
  gradient map was invisible. `-LiminalVideoLook palette` now resolves to Shadowplay (the palette carrier
  stays: Shadowplay and Kaleido ride it).
- Indistinct, reworked in place (same recipe ids, new character):
  - Fringe -> a contour map: iso-lines of the film's soft figure at four levels (anti-aliased with
    `fwidth`, 2-4 px at 2048) plus its sharp edges, as light (0.95) on the picture's darks and ink (-0.7) on
    its lights; the colour split along the edges stays.
  - Glow -> chiaroscuro: the film projected onto the picture as light and shade (relief gain
    (hl - 0.35) x 1.3, lift hl^2 x 0.45, bloom as before): where the film is dark the picture falls into
    shadow. Its Phantom carrier share 0.6 -> 0.4.
  - Undertow: the film's lights also shift the picture behind them along a slowly turning direction (the
    darks the other way, 0.45 of the maximum), so the whole figure reads as a pane of thick glass with torn
    edges, not only its outlines; maximum 0.032 -> 0.040 UV (shared cap of the pre-drives); pane light
    0.5 -> 0.8 plus lift 0.3 on its lit edge; carrier 0.6 -> 0.45. It reads the calmest figure
    (`figureCalmOf`, 0.8 slow average + 0.2 levelled luma) and its ceilings drop to 0.30 / 0.58 / 0.85: with
    the round-1 figure and ceilings the romanesco stepped 0.0132 per frame (gate 0.010), now 0.0098.
  - Wake: moving parts carry light 0.25 -> 0.6 (from 0.08 motion, weighted by the film's tone); carrier
    0.8 -> 1.0.
- Kept, pushed toward what the judges liked:
  - Aurora: two broad regions of rotated hue keyed on the film's figure (smoothstep 0.35-0.65) plus a
    softer continuous term, hue blend 0.45-0.85, film lights lift 0.22 (dark pictures); the iridescent
    bands of round 1 were dropped (they made it a Fringe look-alike).
  - Solar: key 0.36-0.60 on the soft figure, and the fold starts 0.2 k up, so the picture's darks fold into
    colour and the film's lights show as solarised figures on a dark picture. (First render: on the levelled
    figure x 1.15 it flashed 0.048-0.053, over the 0.04 photosensitivity gate; now at most 0.026.)
  - Relief: height from the calmest figure (the old film's scan lines read as "harsh ripple"), 6-texel step
    x 9, lit side lift 0.25 (x 12 and 0.35 stepped 0.0127 on the romanesco).
  - Facets: shard slip 0.016 -> 0.022 UV, and the shards inside the figure catch light, each its own (a hash
    of the shard, relief (h - 0.4) x 0.9 and lift 0.35 h): the figure reads as a lit glass mosaic.
  - Print: the posterised-band variant (seed >= 0.5, "blurry green glow") replaced by an engraving line
    screen (lines thicken with the film's darks); dots 82 -> 70 cells, slightly larger; share 1.4 -> 1.5.
  - Shadowplay: hard-edged silhouettes (smoothstep 0.40-0.60 of the film: shadow theatre); share 1.7 -> 2.2.
  - Kaleido: the palette ramp's contrast 0.14-0.86 -> 0.28-0.72 (all palette carriers), over a calmer figure
    for the fold (half slow average); share 1.5 -> 2.2 (2.6 on the levelled luma flashed 0.059).
  - Backdrop: the keyed Window shows a near two-tone film (0.25-0.75) behind the subject; share 1.6 -> 1.9.
- Still 13 interaction modes plus the 4 plain looks (17 recipes, all distinct in the round-2 sheet).

### F25. A glass shader group: the drives that move the picture's samples get their own variant
- What: `VARIANT_GLASS` 8 for Undertow, Fringe and Facets (their pre-drives, the colour split and their
  composite light); `VARIANT_DRIVES` 4 now holds only the composite drives (Wake, Aurora, Solar, Relief,
  Glow). `addDrive<kComp, kGlass>` compiles only its group's branches; the lift and relief fields serve both.
  Fragments 9 (`*VideoGlass`) plus the unions 11, 13, 15 as fallbacks; `FootageRecipe.fxVariants` lists
  what both renderers and the bench build. The F22 fallback, done.
- Why: round 2's louder modes put Undertow at 1.20, Facets 1.21 and Fringe 1.17 of `main`'s frame with all
  drives in one variant; every composite drive paid for the pre-drive code too. After the split the
  composite drives dropped 4-6 % (Glow 1.11 -> 1.05, Aurora 1.12 -> 1.06, Relief 1.12 -> 1.07, Wake
  1.11 -> 1.05, Solar 1.09 -> 1.03) and the glass ones 2-5 %.
- Weaver: a key-group recipe still never meets a drive or glass one (`compatible`: the union has bit 2 and
  one of 4 / 8). Drives and glass may crossfade (variant 13, which is round 1's drives variant): forbidding
  that too left a glass piece only plain looks to follow, and the plain share left the 22-42 % band
  (unit test failed). Rendered frames are unchanged by the split (scores identical to the digit).

### F26. Round 2 measurements (68 clips, same images, films, timeline and level as rounds 0 and 1)
- Mean difference to footage off per recipe, round 1 -> round 2 (levels, 4 clips each): Aurora 15.6 ->
  27.2, Solar 7.5 -> 19.9, Glow 10.8 -> 17.6, Wake 7.6 -> 11.8, Facets 5.2 -> 10.2, Shadowplay 8.0 -> 10.2,
  Backdrop 10.6 -> 12.9, Print 7.9 -> 8.8, Kaleido 5.2 -> 8.0, Undertow 5.1 -> 8.0, Fringe 5.2 -> 7.3,
  Poster 6.8 (Palette was 6.0), Relief 4.9 -> 5.8; plain looks unchanged (3.8-13.0). Lowest mode clip:
  Relief with Mennen on the hummingbird, 2.7 levels (gate 2).
- The overview sheet: the film reads as a shape in most mode clips now (Aurora's hue regions, Glow's
  projected light, Solar's folded figures, Kaleido's mandala, Facets' shard mosaic, Print's dots and
  lines, Relief's emboss, Undertow's torn pane, Fringe's contour lines); the picture is the anchor in all 68.
- Readability: `keep_hog` at least 0.917 (Relief, WhatsIt on the romanesco); gate 0.85.
- Calm: step p95 at most 0.0098, flash at most 0.034 (gate 0.04). Jerk ratio over 1.8 in 11 clips, all on
  the dark, nearly still hummingbird (1.80-2.37: Aurora, Backdrop, Fringe, Glow, Kaleido, Solar, Wake): the
  ratio to an almost still footage-off picture, with absolute steps 0.004-0.008 (F3, as Wake in F22).
  Accepted; the louder modes do move that picture more, which is what the judges asked for.
- GPU (Apple M4, mono 2048 x 2048, 5 x 200 frames, against `main`'s frame with the same footage in the same
  run, noise about +-2 %): Solar 1.03, Glow 1.05, Wake 1.05, Aurora 1.06, Relief 1.07, Poster 1.08,
  Shadowplay 1.09, Print 1.10, Kaleido 1.13, Fringe 1.14, Undertow 1.15, Facets 1.18. Facets stays over the
  15 % target (its light costs 1-2 %, noise level; the shard pre-drive is the cost); open.
- Parity: footage off identical to `main` (max abs diff 0, stereo and mono); the four plain looks identical
  with footage on (0, mono). Builds: macOS, visionOS simulator, visionOS device; 133 unit tests pass.

## Final verification

### F27. The app with the weaver choosing: visionOS Simulator and macOS
- visionOS 27.2 Simulator (Apple Vision Pro), `scripts/perf-run.sh` 180 s after a 15 s warm-up with
  `-LiminalVideoForce YES -LiminalVideoFile <WhatsIt clip> -LiminalTestImage <fixtures> -LiminalImageInterval 15
  -LiminalHideControls YES`, 60 s of it recorded (`simctl io recordVideo`). The weaver's sequence from the log
  (19 pieces, 17 retired): undertow, phantom, relief, window, poster, backdrop, window, glow, undertow, glow,
  facets, solar, window, undertow, glow, wake, imprint, poster, backdrop. 11 of the 17 recipes in 3.3 min,
  no recipe twice in a row, plain looks 5 of 19 (26 %, inside the weaver's 22-42 % band).
- PERF, footage on: 79.4 fps mean, interval p95 13.28 ms, 0.39 slow frames per 5 s. Footage off, same flags,
  90 s: 79.1 fps, p95 13.29 ms, 0.28 per 5 s. Every slow frame in both runs falls on the 15 s image change
  (01:19:07, :22, :37, :52 ...; the pre-existing image-change frame of T39), none at any of the 17 piece
  changes. The on run also carried the screen recording for 60 s. A27's 79.5 fps (120 s, default image
  interval) is matched; the extra slow frames against A27's 0.04 come from the 15 s image interval.
- The recording shows the film reading as a figure (a man in a suit, hands) through Backdrop, Window and
  Glow over the hummingbird and ferris wheel pictures, Facets' shards and Solar's folded colour over the
  romanesco; the picture is the anchor throughout. Nothing new in the log's errors and faults.
- macOS (Debug, `-LiminalVideoForce YES`, real cached archive clips because the sandboxed Mac app cannot
  read a scratch file): 5 pieces from 5 films in the first minute (shadowplay, poster, phantom, glow, emerge), 59.5 fps
  mean, METAL PERF GPU 2.9 ms average, no slow frame logged.

### F28. Parity, GPU, gates, builds
- Footage off against `main`'s `EffectsRenderer.metal` (`shader-bench --compare`): max abs diff 0, PSNR inf,
  stereo MRT and mono, 10 frames each.
- GPU A/B, Apple M4, mono 2048 x 2048, 5 x 200 frames interleaved, B = branch with the recipe pinned, A =
  `main` with the same footage frame (its blend variant): footage off 1.01 (noise, spread 6 %; identical
  frames), Window 1.00, Phantom 1.00, Solar 1.03, Backdrop 1.04, Glow 1.05, Wake 1.05, Aurora 1.06, Poster
  1.07, Relief 1.08, Shadowplay 1.09, Print 1.10, Kaleido 1.14, Fringe 1.14, Undertow 1.15, Facets 1.17. Same
  as F26 within the noise; Facets is the one recipe over +15 % (open).
- `scripts/fx-judge-set.py` (footage off, 180 frames): PASS at 0.25 / 0.5 / 1.0 (hog loss mean 0.065 / 0.091
  / 0.122, strain p90 max 0.50 / 0.80 / 1.18), unchanged.
- Builds: macOS, visionOS Simulator, visionOS device (no signing): succeeded. 133 unit tests pass, 0 fail.
- Highlight reel for the user (session scratchpad `ffx/highlights.mp4`, 37.7 s, 7.8 MB): the strongest
  round-2 clip of each of the 13 modes by mean change with readability kept, 2.9 s each, labelled.
  The simulator recording is `ffx/final/sim.mp4` (61 s, 19 MB) with `ffx/final/sim-sheet.jpg`.

## Open

- Round 2 judges on the new clips (key kept outside the repo); retune what still scores < 3.5.
- GPU: Facets 1.17-1.18 of today's one-layer frame (F26); a cheaper shard grid (no rotation) is the next step if
  the headset shows it.
- Everything in the plan's sections 3-5 is untested; the per-mode numbers are starting points.
- Plan section 11: the share of plain looks, a "Footage effects" setting, whether Kaleido and Print are
  wanted at all.
- Two-mode crossfades cost 1.21-1.23x of today's two-layer frame (F11) for a few seconds (variant 13 is
  round 1's drives variant); measure on the headset before deciding whether to forbid them.
- Round-2 blind judges (plan 9.4) and the headset checklist (Undertow and Kaleido comfort, Print
  aliasing, Backdrop on the relief, 90 Hz with Facets and two-mode crossfades). The simulator run with the
  weaver choosing is done (F27); the Mac app cannot read a scratch footage file from its sandbox.
- The faint drives of F19 are addressed in F21; Facets is the faintest mode on the dark picture with high-key film.
