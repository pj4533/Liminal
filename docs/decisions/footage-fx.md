# Footage interaction modes: decisions

Decision log for the footage-effects workstream. Plan with all numbers: `docs/plans/footage-fx.md`.
Request: composite the archive footage in more ways than a blend, bring it in through the effects, let
film and effects interact.

Status: built on both platforms (F10-F20): 17 recipes (today's four looks plus 13 interaction modes) picked
by the weaver, shader, uniforms, DEBUG flag `-LiminalVideoMode`, unit tests, offline round-0 clips. Not
done yet: blind judges (plan 9.4), the app run in the simulator and on the headset (plan 9.5).

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

## Open

- Everything in the plan's sections 3-5 is untested; the per-mode numbers are starting points.
- Plan section 11: the share of plain looks, a "Footage effects" setting, whether Kaleido and Print are
  wanted at all.
- Two-mode crossfades cost 1.21-1.23x of today's two-layer frame (F11) for a few seconds; measure on the
  headset before deciding whether to forbid same-group crossfades.
- Blind judges (plan 9.4), a 4 min simulator run logging the recipe sequence and PERF, the headset
  checklist (Undertow and Kaleido comfort, Print aliasing, Backdrop on the relief). The app was launched in
  the visionOS simulator with `-LiminalVideoMode kaleido` (runs, no crash); the Mac app cannot read a
  scratch footage file from its sandbox.
- The faint drives of F19 on dark pictures (Relief, Fringe, Glow, Undertow, Print with high-key film).
