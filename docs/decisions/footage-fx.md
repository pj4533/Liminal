# Footage interaction modes: decisions

Decision log for the footage-effects workstream. Plan with all numbers: `docs/plans/footage-fx.md`.
Request: composite the archive footage in more ways than a blend, bring it in through the effects, let
film and effects interact.

Status: designed, not built. This commit holds the plan, the offline tooling and the baseline of today's
four looks. No app behaviour has changed.

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

## Open

- Everything in the plan's sections 3-5 is untested; the per-mode numbers are starting points.
- Plan section 11: the share of plain looks, a "Footage effects" setting, whether Kaleido and Print are
  wanted at all.
