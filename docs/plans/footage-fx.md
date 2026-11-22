# Footage interaction modes: plan

The archive footage is blended into the picture today (four looks). This plan adds ways for the film and
the effects to drive each other: the film bends the water, splits the colour fringes, feeds the trails,
steers the hue waves, lights the bloom, hides in the picture's shadows. Branch `feature/footage-fx`.

Request: "Can you composite the video footage in different ways other than just blending it in? Can you use
different effects to bring it in along side the regular effects? Maybe interact them somehow."

Status: phases 1-4 built (round 0). What changed against this plan while building is in the decision log:
the film is tapped at the composite and only the pre-drives tap early (F10), the shader has blend / keys /
drives / full variants and the weaver never needs the full one (F11), amounts raised (F12), Shadowplay and
Kaleido carriers (F13, F14). Phases 5 and 6 (judges, app runs) are open.

Decisions taken while building go in `docs/decisions/footage-fx.md` (prefix `F`). Numbers marked *(tune)*
are starting points. This document changes no behaviour; it comes with the tooling of section 9.

## 0. What was read and measured, and what it means

| Finding | Consequence |
|---|---|
| The composite sits in stage B (`shadeEye<kVideo>`) after the picture is sampled; the warp is finished in stage A (`distortedUV`) before the film is ever read. | A mode that moves the picture's UVs (film as a displacement field, film edges as colour fringes) needs the film sampled first. Section 2: the film is tapped once at the top of stage B and every later hook reads that tap. |
| The plain fragments instantiate `shadeEye<false>` and are byte-for-byte the shader without footage (A7). | Every change lives in the `kVideo` variants. Footage-off frames stay identical to `main` by construction; `shader-bench --compare` confirms it per phase. |
| Stage texture (960 x 720, rgba8): r = levelled luma (frame-blended), g = slow average (0.5 s), b = motion (0.25 s); alpha is written 1 and never read. | Modes read the channels that are already temporally smooth (g, b). Alpha is free for one more field (section 6: soft edge magnitude). No new texture. |
| The app renders mono on both platforms (S4); macOS binds no depth texture, visionOS binds it at index 5. | Costs are judged on the mono path. A depth-keyed mode exists only where a depth map does (visionOS); elsewhere the weaver never picks it. |
| Footage on costs 5-8 % over footage off today, two layers 6-9 % over one (A7, A27; re-measured in 9.3). | Budget of this work: one layer in any mode at most 15 % over today's one-layer cost, two layers at most 15 % over today's two-layer cost (section 9.3). |
| Today's looks, rendered as moving clips at the weaver's level (section 1). | The film reads mostly as a tinted haze over the dark parts of the picture and is nearly invisible on a bright, saturated subject. The picture is never at risk. So the new modes may be clearer about the film's shapes than today's looks are, as long as they act through the picture's own pixels. |

## 1. Today's looks as moving clips (baseline)

Rendered with `scripts/ffx-clip.sh` (new): the real shader, the app's uniform code, the app's pre-pass
kernel on frames decoded from the mp4 at rate 0.72, level 0.5 of the look's ceiling (the weaver's band is
0.42-0.58), intensity 0.5, settled picture, effect time 113-121 s, 8 s at 30 fps, left eye 768 x 512.

- Images: `r2-04.jpg` (romanesco: bright, saturated subject on a dark ground) and `r2-02.jpg`
  (hummingbird at night: mostly dark, blue).
- Footage: `MennenBabyMa.mp4` from 5 s (black and white, high key, slow hands) and `WhatsItt1955_2.mp4`
  from 20 s (colour stock, a man moving in front of crinkled foil: strong contrast and motion).
- Clips, filmstrips and scores: `<scratchpad>/ffx/current/<image>-<clip>-<look>/` (`clip.mp4`,
  `filmstrip.png`, `check.json`), table in `<scratchpad>/ffx/current/table.md`.

Means over the two clips per picture (per-clip rows in `table.md`; the scores are defined in 9.2):

| Look | Picture | keep_hog | worst tenth | keep_edge | delta | area | film_corr | motion_corr | step p95 | step ratio | jerk ratio | flash |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Phantom | romanesco | 1.00 | 1.00 | 0.99 | 3.9 | 0.26 | 0.26 | 0.46 | 0.0043 | 1.12 | 1.02 | 0.01 |
| Phantom | hummingbird | 1.00 | 0.99 | 0.97 | 4.1 | 0.31 | 0.28 | 0.51 | 0.0031 | 1.99 | 1.30 | 0.01 |
| Imprint | romanesco | 0.99 | 0.98 | 0.99 | 4.8 | 0.54 | 0.60 | 0.51 | 0.0046 | 1.17 | 1.06 | 0.01 |
| Imprint | hummingbird | 0.99 | 0.98 | 1.00 | 2.8 | 0.34 | 0.51 | 0.54 | 0.0019 | 1.26 | 1.08 | 0.00 |
| Window | romanesco | 1.00 | 1.00 | 0.93 | 4.5 | 0.34 | 0.27 | 0.50 | 0.0042 | 1.07 | 1.03 | 0.01 |
| Window | hummingbird | 0.99 | 0.97 | 0.97 | 4.5 | 0.31 | 0.26 | 0.50 | 0.0027 | 1.75 | 1.19 | 0.01 |
| Emerge | romanesco | 0.96 | 0.96 | 0.94 | 14.5 | 0.83 | 0.52 | 0.46 | 0.0057 | 1.47 | 1.12 | 0.02 |
| Emerge | hummingbird | 0.98 | 0.97 | 0.93 | 11.6 | 0.69 | 0.56 | 0.54 | 0.0040 | 2.63 | 1.49 | 0.01 |

The render-loop mix in these clips is 0.30-0.375 (level 0.5 x the look's ceiling at 0.5 x the clarity term).

What the clips show:

- The picture is never at risk. HOG similarity to the plain picture drops by at most 4 % with footage on
  (Emerge); for the other three looks it is within 1 %. There is a lot of room.
- The film is faint. Outside Emerge the frame differs from its footage-off twin by 3-5 levels of 255 on
  average, over a quarter to a half of its area.
- Where the film shows depends on the picture, not on the look. On the dark hummingbird picture the man
  from the film stands in the frame as a ghost in the picture's blues and greens (Phantom, Window and
  Emerge all read; it looks very good). On the bright romanesco the same film at the same mix is a soft
  haze over the centre: Window softens the picture's detail without showing the film's shapes, Phantom
  and Imprint are close to invisible in a still frame, and only Emerge shows the film, in the dark ground
  around the subject. The film already lives in the picture's shadows; on a bright subject it has no way in.
- The film's movement does come through: the added frame-to-frame change follows the film's motion energy
  (correlation 0.3-0.65, higher for the clip with a moving figure).
- High-key film (the Mennen clip is nearly white) becomes a flat tinted wash in every look.
- Calm: no flash, and the frame-to-frame step with footage is at most 0.006 (the transitions' limit is
  0.05). On the dark, almost still picture the same small step is 2-2.8 times the footage-off step, so the
  gate of 9.2 is on the absolute step and the ratio is only reported.

What this means for the modes: they should give the film a way into bright, saturated pictures that does
not depend on painting grey over colour (Undertow, Fringe, Aurora, Relief, Glow act through the picture's
own pixels), make the "film in the shadows" behaviour deliberate (Shadowplay, Backdrop), and give
high-key film a shape (Kaleido, Fringe and Relief read its contours, not its tones).

## 2. Design: tap once, hook many

### 2.1 Three choices per piece

A piece of footage is described by three independent choices instead of one look:

| Choice | Question | Values |
|---|---|---|
| Carrier | How do the film's tones become pixels? | the four looks (Phantom, Imprint, Window, Emerge) plus Palette (3.9); or none |
| Key | Where may the film show? | the look's own mask (today), Shadowplay (the picture's shadows or highlights, 3.6), Backdrop (far depth, 3.7), Kaleido (the film's own UVs folded, 3.8) |
| Drive | Which effect does the film steer? | none, Undertow, Fringe, Wake, Aurora, Solar, Relief, Glow, Print (3.1-3.5, 3.10-3.12) |

The weaver does not pick from the full product. It picks a recipe from a curated table (section 5): a named
combination with its own carrier share. A drive makes the film felt through the picture's own pixels, so
its carrier runs lower than a plain look (the film is half shown, half felt). A few recipes have no carrier
at all: the film is only there as movement, fringe or colour.

### 2.2 Shader structure (`kVideo` variants only)

```
shadeEye<true>:
  0. FootageTap ta = tapFootage(videoTexture,  layerA)     // one sample per layer (three for Undertow,
     FootageTap tb = tapFootage(videoTextureB, layerB)     // two for Relief), skipped at mix 0
     FootageDrive fd = drivesOf(ta, layerA) + drivesOf(tb, layerB)   // sums weighted by each layer's amount
  1. uv += fd.uvOffset                 (Undertow)          before the parallax and the picture samples
     chromOffset += fd.chroma          (Fringe)
  2. picture samples, crossfade        (unchanged)
  3. carrier composite from ta / tb    (today's compositeVideo, without its own texture sample;
                                        keys multiply its mask; Palette and Print live here)
     colour = solarFold(colour, fd.solar)                  (Solar)
  4. hue stage: hsv.x += fd.hue        (Aurora)
     colour *= 1 + fd.relief           (Relief), after the hue stage
  5. ghost taps: alpha x (1 + fd.wake) (Wake)
     bloom: amount x (1 + fd.glow)     (Glow)
     feedback: mix + fd.wake x k       (Wake)
  6. vibrance                          (unchanged)
```

- `FootageTap`: `half4 v` (the stage), `float2 vuv`, `half feather` (the 14 % edge feather of today), `half
  luma` (film contrast), plus `half2 grad` only for the drives that need it.
- `FootageDrive`: `float2 uvOffset; float2 chroma; half hue, solar, relief, wake, glow;` (9 scalars). Every
  field is a sum over the two layers, each term scaled by that layer's `videoDriveAmt`, which contains the
  piece's envelope. During a piece-to-piece crossfade the envelopes are complementary (A27), so one drive
  fades out exactly as the next fades in: no pop, no special case, and two different drives may overlap.
- The tap uses `mix(texCoord, warp.uv, warp)` with the stage-A uv (before the per-eye parallax). On the
  mono paths (the app) that is exactly today's sample point. On the stereo debug path the film loses the
  parallax shift of at most 0.01 UV; accepted (S4: stereo is a debug A/B only).
- Every drive is a uniform-conditioned branch on the layer's drive id, as the transition styles are. A
  frame pays for the drive it shows.
- Each hook is bounded where it is applied (sections 3 and 4), so the sum of two layers cannot exceed the
  cap of one.

### 2.3 What does not change

- `distortedUV` (stage A), the plain fragments, the transition code, vibrance.
- The pre-pass keeps its three channels and its timing. It gains one output (alpha, section 6).
- `VideoFrameSource`, decoding, the two slots, the cache, the sound.
- The visionOS shell: no geometry or material change. Backdrop reads the same depth map the relief is
  built from, so the film sits on the far wall without a hook into the shell.

## 3. The modes

Amounts are written for `a` = the layer's `videoDriveAmt` (0...1 after section 4) and the stage channels
`r` (luma), `g` (slow average), `b` (motion), `e` (edge, alpha). GPU cost is the expected addition to a
one-layer footage frame on the mono path; the measured numbers replace these in the decision log.

### 3.1 Undertow: the film is the water's displacement field

- Drives: the picture's UVs (hook 1). The image bends around the film's shapes and ripples where the film
  moves, like looking at the picture through moving glass.
- Math: `grad = (g(vuv + dx) - g(vuv), g(vuv + dy) - g(vuv))` with `dx, dy` = 3 stage texels (the slow
  average is smooth, so the gradient is stable). `uvOffset += normalize_soft(grad) * min(|grad| * 6, 1) *
  a * A_u * (0.35 + 0.65 * saturate(b * 5)) * feather`, `A_u` = 0.006 / 0.012 / 0.018 UV at intensity
  0 / 0.5 / 1 *(tune)*. The total offset of both layers is clamped to `A_u`.
- Recognisability: the offset is at most a third of the water's own amplitude at the same intensity
  (0.028-0.058), and it follows a smooth field. It is outside the strain budget (E8) on purpose, so the
  budget code is untouched; the readability gate of 9.2 decides the cap. Scaled by the fresh-image hold
  (section 4): a new picture is not bent.
- Cost: 2 more stage samples per layer. Expected +3 %.
- Black and white film over a colourful still: colour-blind by construction. Only the geometry of the
  film arrives; every pixel is still the picture's.
- Carrier: Imprint at 45 % of its usual mix, or none.

### 3.2 Fringe: the film's contours split the colours

- Drives: chromatic aberration (hook 1). The red and blue samples of the picture part along the film's
  edges, so the film appears as prismatic outlines drawn in the picture's own colours.
- Math: `chroma += dir * e * a * A_f * feather`, `dir` = the radial direction `normalize(uv - 0.5)`
  turned by the piece's seed angle, `A_f` = 0.004 / 0.010 / 0.016 UV *(tune)* (today's radial fringing is
  `(uv - 0.5) x 0.004-0.02`). Luma detail is carried by green, which is not moved.
- Cost: no extra sample (the edge is in the tap's alpha). Expected +1 %.
- Black and white: ideal. The film has no colour to lose, and the outlines take the picture's palette.
- Carrier: Phantom at 35 %, or none.

### 3.3 Wake: the film's motion feeds the trails

- Drives: feedback mix and warp, ghost-tap strength (hook 5). Where the film moves, the picture lingers
  and smears; where the film is still, the picture is crisp. A dancer in the film becomes a moving patch
  of afterimage in the picture.
- Math: `wake = saturate(b * 5) * a * feather`; `feedbackMix_px = min(feedbackMix + 0.22 * wake, 0.5)`,
  `feedbackWarp_px = feedbackWarpAmount * (1 + 1.5 * wake)`, ghost alpha `0.15 * (1 + 1.2 * wake)`.
- Stability: `restoreChroma` targets a convex mix of the inputs' chroma, so a higher mix cannot run away,
  and the mix is capped at 0.5 (a trail then halves every frame at worst). Checked by the step and jerk
  scores of 9.2 and a 60 s soak clip.
- Cost: no extra sample. Expected +1 %.
- Black and white: irrelevant, only motion is read.
- Carrier: Phantom at 50 % (its own weight is motion too, so the two agree).

### 3.4 Aurora: the film steers the hue waves

- Drives: the hue offset of the spatial hue stage (hook 4). The film's tones become bands of rotated hue.
  Luma is restored by that stage, so the picture's structure is untouched: the film is seen purely as
  colour, like oil on water in the shape of the film.
- Math: `hue += (g - 0.5) * a * A_h * feather`, `A_h` = 0.10 / 0.22 / 0.32 turns *(tune)*, and the local
  `hueBlendAmount` rises by `0.25 * a * |g - 0.5| * 2`. Together with the existing waves the total stays
  under the rainbow cap of E25: `A_h` is reduced by the frame's `hueWaveIntensity x hueBlendAmount` share.
- Cost: no extra sample. Expected under +1 %.
- Black and white: the film brings no hue; it rotates the picture's. The safest mode for readability
  (HOG and edge metrics are on luma).
- Carrier: none, or Imprint at 30 %.

### 3.5 Solar: the film folds the tone curve

- Drives: a solarize fold of the composite colour (hook 3), the same curve as the Solarize transition
  (`0.5 - 0.5 cos(c * pi * (1 + f))`), with its strength from the film: `k = smoothstep(0.35, 0.85, g) *
  a * feather`, fold `f` = 0.6 / 1.0 / 1.4. Where the film is bright the picture's lights and darks trade
  places in coloured contours; where it is dark the picture is plain.
- Readability: this changes luma, inside the film's bright regions only. Mix capped at `0.55 k`; pieces at
  most 16 s (as Emerge); intensity 0.35 and above.
- Cost: no extra sample; three `cos`. Expected +1 %.
- Black and white: the film is a mask; all colour is the picture's.
- Carrier: none (the fold is the picture's response); the Window mask shapes it.

### 3.6 Shadowplay: the film lives in the picture's shadows (or highlights)

- A key (hook 3). The carrier's mask is multiplied by a luminance key of the picture: `key = 1 -
  smoothstep(0.12, 0.42, Y(c))` (shadows) or `smoothstep(0.55, 0.85, Y(c))` (highlights). The subject,
  usually the bright and saturated part, is left alone; the film plays in the night sky or the dark ground.
- Polarity: chosen per piece by the service from the 16 x 16 thumbnail it already measures for the tint
  (A10): the polarity whose key covers 25-60 % of the picture, shadows preferred. Passed as the sign of
  `videoKeyAmt`.
- Because the key shrinks the film's area, its carrier may run at 130 % of the look's usual mix (still
  under the ceiling).
- Cost: no extra sample. Expected under +1 %.
- Black and white: shown as a duotone (shade to tint) or Palette, in the dark where a grey film looks at
  home; the baseline clips show today's looks already tend this way.
- Carrier: Window's duotone without the oval, Emerge's duotone, or Palette.

### 3.7 Backdrop: the film plays behind the subject (visionOS)

- A key (hook 3) from the depth map: `key = 1 - smoothstep(0.25, 0.55, depth(uv))`. The film is projected
  on what is far; the near subject stays in front of it, untouched.
- Only when a depth map is bound (`hasDepth`), so visionOS; the weaver never picks it otherwise.
- The relief shell displaces by the same map, so on the headset the film is on the far wall of the scene.
  No change to the shell.
- Cost: one r8 depth sample. Expected +1 %.
- Carrier: Window's duotone without the oval, or Palette.

### 3.8 Kaleido: the film through folds and facets

- A key on the film's own UVs (hook 0), not on the picture: before the tap, `vuv` is mirror-folded into 6
  or 8 wedges (the Kaleidoscope transition's fold) or, by seed, into hexagonal lenses (the Facets
  transition's cell maths). The film becomes a slow mandala or a compound eye, symmetrical, with no frame
  and no upright figure, so it reads as ornament growing out of the picture instead of a second picture.
- The picture is not folded. Fold strength `0.6 + 0.4 a`: a partial fold keeps a hint of the film's scene.
- Cost: `atan2` + `sincos` (or the hex cell maths), no extra sample. Expected +2 %.
- Black and white: becomes a luminous pattern in the tint colour; the nicest use of high-key film.
- Carrier: Phantom (screen) or Imprint.

### 3.9 Palette: the film gradient-mapped through the picture's colours

- A carrier (hook 3). Instead of the two-colour duotone, the film's luma runs through three stops, the
  middle one being the picture's own colour at that pixel with its chroma raised: `ramp(l) = l < 0.5 ?
  mix(shade, cs, 2l) : mix(cs, tint, 2l - 1)`, `cs = restoreChroma(c, 1.4 x chroma)`. Composite: `mix(c,
  ramp, m x mask)`. The film is painted with the picture: its mid-tones are the picture, its shadows and
  lights are the picture's darkest and brightest colours.
- Readability: at the film's mid-grey the picture shows through unchanged, so a typical film keeps more of
  the picture than the duotone does at the same mix.
- Cost: no extra sample. Expected under +1 %.
- Carrier of its own; uses the Window oval, a key, or the full frame (at Imprint's ceiling).

### 3.10 Relief: the film embossed into the picture

- Drives: a light term on the processed colour (hook 4, after the hue stage). `h = g(vuv) - g(vuv + L x 4
  texels)`, `L` = a light direction from the seed, slowly turning; `relief = clamp(h x 5, -1, 1) x a x
  A_r x feather`, `A_r` = 0.18 / 0.30 / 0.40; `colour *= 1 + relief`, then the gamut fit. The film's shapes
  appear pressed into the picture's surface like a bas-relief; hue and saturation stay the picture's.
- Cost: 1 more stage sample per layer. Expected +2 %.
- Black and white: irrelevant, the film is a height map.
- Carrier: none, or Imprint at 30 %.
- The shell is not involved: the relief is in the texture.

### 3.11 Glow: the film lights the bloom

- Drives: the bloom amount and a light leak (hook 5). `glow = smoothstep(0.45, 0.95, g) x (0.5 + 0.5
  saturate(b x 5)) x a x feather`; `bloomAmount_px = bloomAmount x (1 + 2.5 glow)` and the bloom sample's
  brightness weight gets a floor of `0.5 glow`, so the picture's own colours bloom where the film is
  bright. The film is seen as light breathing inside the picture.
- Cost: no extra sample (the bloom sample exists). Expected under +1 %.
- Black and white: the light takes the picture's colour, not the film's grey.
- Carrier: Phantom at 40 %.

### 3.12 Print: the film as halftone ink

- A treatment of the carrier (hook 3): the film's luma becomes a dot screen. Grid in the footage's warped
  coordinates (it swims with the film), 110 cells across the frame, turned 30 degrees; dot radius from `1
  - luma`; ink = the shade colour multiplied onto the picture: `c *= mix(1, shade x 1.6, dot x m x mask)`.
  By seed the dots are replaced by 4-level posterised bands with soft steps.
- Shimmer: a cell is 18 px at 2048, the dot edge is `smoothstep` over `fwidth`, and the luma comes from
  the slow average, so dots grow and shrink slowly instead of flickering. Checked by `jerk_ratio` (9.2) and
  on the headset. Film grain is not planned: per-frame noise is exactly what the flicker gate forbids.
- Intensity 0.4 and above, pieces at most 16 s.
- Cost: no extra sample; two `sin`, one `fwidth`. Expected +1 %.
- Black and white: a newspaper picture printed over the scene in the picture's darkest colour.
- Carrier of its own inside the Window oval or a key.

### 3.13 Considered and left out

- Film grain and dither noise: flicker (see Print).
- Film motion as the direction of the warp (optical flow): needs a flow estimate; the stage has motion
  magnitude only. Undertow gets its direction from the tone gradient instead.
- The film as the transition's swap order: transitions are owned by `TransitionDirector`, and the footage
  dips while a picture arrives (A27). Possible later.
- A blurred film halo: needs a spatial blur pass at stage size; the slow average is temporal only.

## 4. Amounts: intensity, the clarity cycle, a new picture

Per layer, next to the existing mix:

```
videoMix      = weight x ceiling(look, I) x carrierShare(recipe) x (0.75 + 0.25 drive) x (0.6 + 0.4 settled)
videoDriveAmt = envelope x driveCeiling(mode, I)                  x (0.60 + 0.40 drive) x hold
videoKeyAmt   = +-1 (polarity or fold kind); the key follows the carrier's mix
```

- `envelope` is the piece's crossfade envelope without its level; `drive` is the clarity cycle
  (`EffectLook.drive`); `settled` as today (A11, A27).
- `hold`: the geometric drives (Undertow, Fringe, Kaleido's fold strength) use `EffectLook.fresh()`: they
  are zero while a new picture settles and return with the other warps. The colour and light drives use
  `0.6 + 0.4 settled`, like the mix.
- `driveCeiling(mode, I)` at intensity 0 / 0.5 / 1 *(tune)*:

| Mode | 0 | 0.5 | 1 | Lowest intensity it is picked at |
|---|---|---|---|---|
| Undertow | 0.35 | 0.75 | 1.0 | 0.2 |
| Fringe | 0.35 | 0.75 | 1.0 | 0 |
| Wake | 0.40 | 0.80 | 1.0 | 0 |
| Aurora | 0.45 | 0.80 | 1.0 | 0 |
| Solar | 0 | 0.60 | 0.90 | 0.35 |
| Relief | 0.40 | 0.75 | 1.0 | 0 |
| Glow | 0.50 | 0.80 | 1.0 | 0 |
| Print | 0 | 0.60 | 0.85 | 0.4 |

  The per-mode amplitudes (`A_u`, `A_f`, ...) carry the absolute size at each intensity; the ceiling only
  shapes how far a piece may go.
- A piece's swell (A27) raises the mix as today and raises `videoDriveAmt` by the same factor, capped at 1.
- Loud music eases the mix to 70 % (A27); the drives follow it.

## 5. The weaver picks a recipe per piece

`VideoLook` stays. `FootageRecipe` (new, pure, in `VideoComposite.swift`) names a combination:

| # | Recipe | Carrier (share of its usual mix) | Key | Drive | Family | Weight | Notes |
|---|---|---|---|---|---|---|---|
| 1 | Phantom | Phantom 1.0 | own | - | plain | 3 | today |
| 2 | Imprint | Imprint 1.0 | own | - | plain | 2 | today; faint on busy pictures (A25) |
| 3 | Window | Window 1.0 | own | - | plain | 3 | today |
| 4 | Emerge | Emerge 1.0 | own | - | plain | 1 | I >= 0.4, at most 16 s |
| 5 | Undertow | Imprint 0.45 | own | Undertow | water | 3 | I >= 0.2 |
| 6 | Wake | Phantom 0.5 | own | Wake | water | 3 | |
| 7 | Fringe | Phantom 0.35 | own | Fringe | colour | 3 | |
| 8 | Aurora | Imprint 0.3 | own | Aurora | colour | 3 | |
| 9 | Solar | none | Window oval | Solar | colour | 1 | I >= 0.35, at most 16 s |
| 10 | Palette | Palette 1.0 | Window oval | - | colour | 2 | |
| 11 | Shadowplay | Palette 1.3 | Shadowplay | - | keyed | 3 | |
| 12 | Backdrop | Window duotone 1.2 | Backdrop | - | keyed | 3 | depth map only |
| 13 | Kaleido | Phantom 0.9 | Kaleido | - | keyed | 2 | I >= 0.25 |
| 14 | Relief | Imprint 0.3 | own | Relief | light | 2 | |
| 15 | Glow | Phantom 0.4 | own | Glow | light | 3 | |
| 16 | Print | Print 1.0 | Window oval | - | light | 1 | I >= 0.4, at most 16 s |
| 17 | Ghost film | none | own | Wake + Fringe (0.7 each) | water | 1 | I >= 0.5; the one two-drive recipe |

Selection (`FootageWeaver.chooseRecipe`, seeded, replaces `chooseLook`):

1. Eligible recipes: by intensity, by `Conditions.hasDepth` (new, reported by the render loop with the
   other conditions), and Shadowplay only when one polarity covers 25-60 % of the picture.
2. Never the recipe of the previous piece, and never the family of the previous piece. Five families
   (plain, water, colour, keyed, light), so there is always a choice.
3. A recipe used within the last four pieces has its weight halved; the plain family as a whole keeps at
   least 30 % of the weight (the user likes today's looks; the modes join them, they do not replace them).
4. Weighted draw. At intensity under 0.25 the weights of the water family are halved.
5. Length caps: Emerge, Solar and Print at most 16 s. Swells never on those three.
6. During a crossfade two recipes overlap for 2.5-7 s. No pair is forbidden: the drives add, each hook is
   capped, and the two carriers already composite in sequence today.

`-LiminalVideoLook` keeps working (pins a plain recipe). New DEBUG flag `-LiminalVideoMode <recipe name>`
pins a recipe; `shader-bench` / `ffx-clip.sh` pin one with `--set` (section 9.1).

Settings: none. The existing "Archive footage" card is unchanged; Effect intensity
scales the modes. If the user wants plain blends only, that is one toggle later ("Footage effects"); not
built unless asked.

## 6. Uniforms and textures

Appended to `EffectsUniforms` (Swift and Metal in step; all 0 when footage is off):

```
videoDrive      layer A: drive id (0 = none, 1 Undertow, 2 Fringe, 3 Wake, 4 Aurora, 5 Solar, 6 Relief,
                7 Glow, 8 Wake + Fringe)
videoDriveAmt   layer A: 0...1 (section 4)
videoKey        layer A: 0 own, 1 Shadowplay, 2 Backdrop, 3 Kaleido; sign of videoKeyAmt = polarity / fold kind
videoKeyAmt
videoDriveB, videoDriveAmtB, videoKeyB, videoKeyAmtB        layer B
```

- 8 floats (32 bytes). `videoLook` gains two values (5 = Palette, 6 = Print); the carrier share is folded
  into `videoMix` on the CPU. Tint and shade are shared by both layers, as today.
- `VideoLayerParams` in the shader gains `drive, driveAmt, key, keyAmt`. `VideoLayer` in Swift gains
  `recipe`. `VideoComposite.apply` writes them; `.off` still writes nothing.
- The uniform stride test and `uniformFields` in `shader-bench.swift` get the new fields.

Textures: no new binding.

- Stage alpha = soft edge magnitude of the slow average: in the pre-pass, `e = saturate(length(float2(
  prev.g(x+2) - prev.g(x-2), prev.g(y+2) - prev.g(y-2))) x 6)`, eased with the motion coefficient (4
  reads of the previous stage, one frame late, which a 0.5 s average does not notice). Read by Fringe.
  960 x 720 at 15-25 Hz: far below measurement noise in the eye pass.
- Undertow and Relief take their gradient from extra samples of `g` in the fragment shader. If 9.3 shows
  Undertow over budget, the fallback is a second small stage texture (rg8, the gradient) written by the
  same pre-pass; that costs a binding and 0.7 MB per stage, so it is the fallback and not the plan.
- Backdrop reads the depth texture already bound at index 5.
- Both layers: each has its own tap, drive id and amount. Layer A = texture 7, layer B = texture 8, fixed
  slot mapping as today, so nothing reorders at a piece change.

## 7. Platforms

- macOS `EffectsMetalView` and visionOS `OffscreenEffectsRenderer`: no new bindings; both already pass the
  `VideoCompositeState` to `compute`. The render loops add `hasDepth` to the conditions they report.
- `ArchiveFootageService`: maps the piece's recipe into `VideoLayer`, picks the Shadowplay polarity from
  the thumbnail statistics it already computes off the main actor. No new work on the main actor.
- The stereo debug path keeps working (drives are computed once per eye from the shared tap inputs).

## 8. Risks

| Risk | Handling |
|---|---|
| A drive makes the picture unreadable (Undertow, Solar, Kaleido at high mix). | Caps in section 3, the fresh-image hold, the readability gates of 9.2 on every clip, and the blind judges of 9.4. A mode that cannot pass is dropped, not shipped weak. |
| Flicker: film cuts and flashes reach the picture through a drive. | Drives read only `g` (0.5 s), `b` (0.25 s) and `e`; never the raw frame. `flash`, step and `jerk_ratio` gates. |
| GPU: the `kVideo` shader grows; more live registers cost occupancy even in untaken branches (T19). | Measure each mode and the plain looks after the refactor (9.3). Budget per section 0. Fallbacks: gradient in the pre-pass, drop the two-drive recipe, drop Print. |
| Feedback instability with Wake. | Mix cap 0.5; convex chroma target; 60 s soak render in 9.2. |
| "Gimmicky": a mode reads as a filter demo instead of a dream. | Judges rate woven-in versus pasted-on (9.4); under 3.5 of 5 after one retune means the recipe is removed. Weights favour the quiet recipes. |
| Too much variety hides the film the user liked. | Plain family keeps 30 % or more; drive recipes keep a carrier share so the film stays findable. |
| Kaleido and Print alias in the headset. | `fwidth`-based edges, cell sizes of 18 px or more, device check listed in the decision log. |

## 9. Evaluation

### 9.1 Tooling (in this commit)

- `scripts/shader-bench.sh --footage-seq`: renders a still image with moving footage. Decodes the mp4 with
  `AVAssetReader` at the piece's rate, ticks at 30 Hz like `VideoFrameSource`, runs the app's
  `videoPrepass` kernel (compiled from `ArchiveVideo.metal`, or a candidate via `PREPASS=`) into three
  rotating stage textures, measures the clip's levels as `ArchiveClipValidator` does, and feeds
  `EffectsUniformsComputer.compute(video:)` with a real `VideoCompositeState` (level or pinned mix, look,
  warp, seed). `--footage-b` + `--footage-xfade AT,LEN` adds a second piece on layer B with the weaver's
  complementary crossfade. `--footage-dump` writes the stage per frame. Without `--footage` the same
  timeline is rendered with footage off; `--seq-ref b` renders it with every effect off.
- `--set k=v` pins any uniform after `compute`, so a look or mode is pinned as soon as its uniform exists
  (`--set videoDrive=1,videoDriveAmt=0.75`). Once recipes exist: `--video-recipe NAME` through
  `VideoComposite` itself.
- `scripts/ffx-clip.sh`: one call renders footage on, footage off and the plain reference, writes
  `clip.mp4`, `filmstrip.png` and `check.json`, and deletes the frame dumps.
- `scripts/ffx-check.py`: the scores of 9.2 (`score`), the filmstrip (`sheet`), a table over many clips
  (`table`).
- To add with the shader work: the single-frame `--video FRAME.png` path of the timing runs still builds
  its stage on the CPU; it must go through the pre-pass kernel too once alpha carries the edge.

### 9.2 Objective checks per clip

Each clip is 8 s, 30 fps, 768 x 512, with its footage-off twin and its effect-free reference on the same
timeline. All on luma unless noted.

| Question | Score | First gate *(tune after the baseline)* |
|---|---|---|
| Does the still image still read? | `keep_hog`: HOG similarity to the effect-free picture with footage, divided by the same without footage (the fx-structure metric; 1 = the footage costs nothing). Median and worst tenth of the frames. `keep_edge` likewise. | median >= 0.85, worst tenth >= 0.70 (today's looks: 0.96-1.00). Solar: median >= 0.75 (it is capped in time instead). |
| Is the film there? | `delta`: mean abs difference to the footage-off frame, 8-bit levels. `area`: share of the frame that differs by more than 6 levels. `film_corr`: correlation of that difference with the film's luma (96 x 64). | delta >= 2, area >= 5 %. `film_corr` is reported, not gated: a drive shows the film without matching its tones. |
| Does the picture answer the film's movement? | `motion_corr`: correlation over time between the film's motion energy (stage b) and the change the footage adds between frames. | drives: > 0.3 on the moving clip; reported for carriers. |
| Is it calm? | `step_p95_on`: 95th percentile luma change per frame with footage (and its ratio to footage off, reported). `jerk_ratio`: mean second difference, on / off. `flash`: largest change of the frame mean within 0.1 s. | step p95 <= 0.010 absolute (today at most 0.006), jerk <= 1.8 (today at most 1.5), flash <= 0.04 (today at most 0.03). |

Matrix per recipe: 2 images x 2 clips at intensity 0.5 (4 clips), 1 image x 1 clip at 0.25 and 1.0, one
crossfade clip against a recipe of another family (`--footage-b`), and for Wake a 60 s soak. About 7 clips
per recipe, 120 in all, 50 s each on the M4. The four plain looks are the baseline (section 1).

Footage off: `shader-bench.sh --shader <main's> --shader-b <branch> --out DIR` then `--compare DIR DIR/b`
must report identical (max abs diff 0) after every shader commit, and `scripts/fx-judge-set.py` keeps
passing at 0.25 / 0.5 / 1.0.

### 9.3 GPU A/B

`shader-bench.sh --shader <main's EffectsRenderer.metal> --shader-b <branch> --video FRAME.png --mono`
(the app's path; MRT stereo reported too), 2048 x 2048, 5 trials of 300 frames, interleaved.

| Case | A | B | Limit (median B/A) |
|---|---|---|---|
| Footage off | main, no video | branch, no video | 0.99-1.01, frames identical |
| Plain looks after the refactor | main, look x | branch, same look | <= 1.03 |
| Each recipe, one layer | main, the recipe's carrier look (Window for carrier-less recipes) | branch, the recipe pinned | <= 1.15 |
| Crossfade | main, two layers | branch, the two most expensive recipes on A and B | <= 1.15 |

Today's cost, measured for this plan (Apple M4, mono two-pass at 2048 x 2048, romanesco fixture, 5 trials
of 200 frames, separate runs, so +-2 %): footage off 4.58 ms, one layer (Window) 4.95 ms (+8 %), two layers
(Window + Phantom) 5.36 ms (+17 % over off, +8 % over one layer). The limits above are therefore about
5.70 ms for one layer and 6.17 ms for two on this machine.

Then `scripts/perf-run.sh` in the visionOS simulator, 120 s with `-LiminalVideoFile` and each family
pinned: no added slow frames against the A27 run (79.5 fps, p95 13.31 ms).

### 9.4 Blind judges

As for the effects balance (E13) and the transitions (T14): fresh judges with no knowledge of the app, one
clip (as a filmstrip of 12 frames plus the mp4) per question set, recipes and plain looks shuffled, names
hidden.

1. "What is the main picture of?" Scored against `truth.json`. Pass: correct for at least 80 % of clips
   per recipe (the footage-off twin of the same clip is the control).
2. "Is anything else in the picture besides that? Describe it." Scores whether the film is noticed and
   whether it is described as part of the picture (a reflection, a ghost, a pattern) or as an overlay.
3. "Dreamlike and woven in (5) ... pasted on, a filter demo (1)." Pass: mean >= 3.5; the plain looks are
   the reference line.
4. "Anything uncomfortable: flicker, strobing, clutter?" Any flicker report fails the clip.
5. A/B pairs, plain look versus recipe on the same picture and film: "which is more interesting to
   watch?" and "in which is the main picture clearer?".

Two rounds: tune or drop after the first, confirm with new judges after the second. Recipes that fail
question 1 or 4 twice are removed from the table.

### 9.5 In the apps

- visionOS simulator and macOS with `-LiminalVideoFile <fixture>` and `-LiminalVideoMode <recipe>`:
  screenshots per recipe, a 4 min free run logging the recipe sequence (no repeats, family spacing), PERF.
- Unit tests: recipe choice over 150 seeds x 3 speeds (never the same recipe or family twice in a row,
  eligibility by intensity and depth, the plain share, length caps), drive amounts (zero in the fresh hold
  for the geometric drives, continuity through a crossfade), uniform stride, `.off` writes nothing.
- Headset checklist for the user: Undertow and Kaleido comfort, Print and Kaleido aliasing, Backdrop on
  the relief, GPU with two layers.

## 10. Phases

| Phase | Work | Exit |
|---|---|---|
| 0 | Tooling and this plan (this commit). | Baseline clips and scores for today's looks. |
| 1 | Shader refactor: tap once, `FootageDrive`, carrier composite from the tap; uniforms and `VideoLayer` fields; pre-pass alpha. No new mode yet. | Footage off identical to `main`; the four looks within 1/255 of today on the mono path; GPU <= 1.03. |
| 2 | Zero-sample drives and keys: Fringe, Wake, Aurora, Glow, Shadowplay, Palette. | 9.2 gates and 9.3 budget per mode. |
| 3 | Undertow, Relief, Backdrop, Kaleido, Solar, Print. | Same. |
| 4 | Recipes in the weaver, service mapping, DEBUG flag, unit tests. | Tests; 4 min simulator run. |
| 5 | Judges round 1, tune or drop, round 2. | 9.4. |
| 6 | Both apps verified, perf, README and `docs/decisions/footage-fx.md`. | 9.5. |

## 11. Open questions for the user

1. Should the plain looks stay at 30 % of the pieces, or would more (or fewer) pieces with interaction be
   better once seen on the headset?
2. Is a "Footage effects" on/off setting wanted, or is Effect intensity enough?
3. Kaleido and Print are the two most stylised modes. They are the first to drop if the result looks like
   a filter demo; say so early if they are not wanted at all.
