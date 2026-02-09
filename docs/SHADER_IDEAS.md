# Shader Ideas for Liminal

Research from [@XorDev](https://x.com/XorDev) (Xor) — shader artist, 38K followers, 397+ published shaders, wrote VFX for the Shopify Sphere.

This document catalogs shader techniques from XorDev's tweets that could work as Liminal effects. Each entry has:
- What it does visually
- Link to the original tweet (with demo video/image)
- How it could be implemented in Liminal's Metal shader pipeline
- Impact rating for psychedelic experience

**Liminal's current effect pipeline** (all in one fragment shader, `EffectsRenderer.metal`):
1. Ken Burns (pan/zoom) → 2. Turbulence Distortion (XorDev sine-wave fluid motion, replaced fBM) → 3. Crossfade → 4. Hue Shift (rainbow waves) → 5. Saliency Hue → 6. Contrast/Saturation → 7. Ghost Taps (delay echoes)

New effects slot into this pipeline as additional stages or replacements for existing ones.

---

## Tier 1: High Impact — These Would Transform Liminal

### 1. Turbulence Distortion (Fluid Motion)

**What it does:** Layered perpendicular sine waves create organic fluid-like motion — water, fire, smoke — without expensive fluid simulation. XorDev calls this his signature technique and uses it in nearly every shader.

**Tweet:** https://x.com/XorDev/status/2008979114544509285 (477❤, 40🔁)
**Thread:** Full technique breakdown with progressive examples
**Tutorial:** https://mini.gmshaders.com/p/turbulence

**The technique:**
```glsl
// 2D turbulence: add rotated sine waves at increasing frequencies
float freq = 2.0;
mat2 rot = mat2(0.6, -0.8, 0.8, 0.6);
for (float i = 0.0; i < 10.0; i++) {
    float phase = freq * (pos * rot).y + speed * time + i;
    pos += amplitude * rot[0] * sin(phase) / freq;
    rot *= mat2(0.6, -0.8, 0.8, 0.6);
    freq *= 1.4;
}
```

**Liminal implementation:**
- **Replace or augment the existing fBM distortion** (which uses simplex noise)
- XorDev's turbulence is cheaper than fBM (just sine waves, no noise function) and produces more organic motion
- Add as UV displacement before texture sampling, similar to current `fbm_distort()`
- Parameters: `turbulenceIterations` (4-10), `turbulenceAmplitude`, `turbulenceSpeed`
- Could animate amplitude with the music/delay slider for reactive fluidity

**Why it's high impact:** Liminal's current fBM distortion is subtle (0.012 amplitude). Turbulence would give dramatic, flowing, psychedelic warping that looks like the image is melting or breathing. This is the single biggest visual upgrade available.

**Psychedelic score: 10/10** — This IS the psychedelic visual effect. Breathing, flowing, melting.

---

### 2. Combustion / Fire Turbulence

**What it does:** Turbulence applied with color mapping to create fire, plasma, and combustion effects. Warm colors (fire palette) mapped through `tanh` tonemapping.

**Tweet:** https://x.com/XorDev/status/1995634971030196401 (561❤, 40🔁)
```glsl
vec2 p = FC.xy * 6.0 / r.y;
for (float i; i++ < 10.0;)
    p += sin(p.yx * i + i * i + t * i + r) / i;
o = tanh(0.2 / tan(p.y + vec4(0, 0.1, 0.3, 0)));
o *= o;
```

**Liminal implementation:**
- Apply turbulence to UV coordinates, then use the displaced Y coordinate to drive a color gradient
- Use `tanh` tonemapping (which XorDev uses extensively) for HDR-like glow
- Layer on top of existing image as a blend mode (screen or additive)
- Parameters: `fireIntensity`, `fireSpeed`, `firePalette` (warm/cool/rainbow)
- Could trigger during image transitions (the `transitionBoost` mechanism already exists)

**Why it's high impact:** Fire/plasma overlays on AI-generated surrealist images would be extremely psychedelic. The existing transition boost mechanism could amplify this during crossfades.

**Psychedelic score: 9/10** — Fire/plasma flowing across surreal imagery is peak psychedelia.

---

### 3. Feedback Buffer / Fractal Recursion (Rocaille Series)

**What it does:** Iterative feedback where previous frame output feeds back into the next frame, creating fractal-like recursive patterns. XorDev's most viral technique — "Rocaille 2" got 2,043 likes.

**Tweet (Rocaille 2):** https://x.com/XorDev/status/2015813875833225715 (2043❤, 187🔁)
**Tweet (Rocaille 1):** https://x.com/XorDev/status/2015809381665812862 (450❤, 40🔁)
```glsl
vec2 p = (FC.xy * 2.0 - r) / r.y / 0.3, v;
for (float i, f; i++ < 10.0; o += (cos(i + vec4(0,1,2,3)) + 1.0) / 6.0 / length(v))
    for (v = p, f = 0.0; f++ < 9.0; v += sin(v.yx * f + i + t) / f);
o = tanh(o * o);
```

**Liminal implementation:**
- Liminal ALREADY has a feedback buffer system (double-buffered `readFeedback`/`writeFeedback` textures)
- Current feedback just does drift/zoom/decay — could add recursive warping
- Apply turbulence displacement to the feedback UV lookup coordinates
- Each frame compounds the warping, creating fractal trails
- Parameters: `feedbackWarpAmount`, `feedbackWarpFrequency`
- The ghost tap system could trigger localized fractal recursion

**Why it's high impact:** Liminal's feedback system is underutilized. Adding recursive warping would turn simple trailing echoes into fractal kaleidoscopic patterns. Low implementation effort since the buffer infrastructure exists.

**Psychedelic score: 10/10** — Fractal feedback is the definition of a psychedelic visual.

---

### 4. Chromatic Aberration

**What it does:** Separates RGB channels with slight UV offsets, creating prismatic fringing especially at edges and during motion. XorDev lists this as achievable in 280 chars of GLSL.

**Tweet (techniques list):** https://x.com/XorDev/status/2017259417809412224 (330❤, 19🔁)

**Liminal implementation:**
```metal
// Sample each channel at slightly different UVs
float2 offset = (uv - 0.5) * chromaticAmount;
half r = sourceTexture.sample(texSampler, uv + offset).r;
half g = sourceTexture.sample(texSampler, uv).g;
half b = sourceTexture.sample(texSampler, uv - offset).b;
half3 color = half3(r, g, b);
```
- Radial chromatic aberration (stronger at edges) is simple and cheap
- Could animate the aberration amount with time or tie to distortion amplitude
- Parameters: `chromaticAmount` (0.0-0.02), `chromaticAnimate` (bool)
- During transitions, boost chromatic aberration for a "reality melting" feel

**Why it's high impact:** Extremely cheap to implement (3 texture samples instead of 1), massively psychedelic. Prismatic color fringing is a hallmark of altered perception.

**Psychedelic score: 9/10** — Classic psychedelic visual. Rainbow fringing = perception shifting.

---

### 5. Stochastic Bloom

**What it does:** Cheap, noisy glow effect that adds dreamy halation around bright areas. Uses random sampling rather than Gaussian blur, so it's a single-pass effect.

**Tweet:** https://x.com/XorDev/status/2016609610640056735 (7❤ but technique referenced in high-engagement Dithering+Bloom tweet)
**Technique tweet:** https://x.com/XorDev/status/2017305475872690606 (8❤)

**Liminal implementation:**
```metal
// Stochastic 1spp bloom: sample at random offset, blend based on brightness
float2 noise = fract(dot(FC, sin(FC.yxyx)));  // XorDev's compact pseudo-noise
float2 bloomUV = uv + noise * bloomRadius;
half4 bloomSample = sourceTexture.sample(texSampler, bloomUV);
half brightness = dot(bloomSample.rgb, half3(0.299, 0.587, 0.114));
color += bloomSample.rgb * brightness * bloomAmount;
```
- Single extra texture sample per pixel — very cheap
- Noisy quality actually enhances the psychedelic "glow"
- Could bloom the hue-shifted colors specifically for rainbow halos
- Parameters: `bloomRadius` (0.01-0.1), `bloomAmount` (0.0-1.0)

**Why it's high impact:** Bloom adds a dreamlike quality to everything. Combined with hue shifting, bright areas would glow with rainbow halos. Very cheap.

**Psychedelic score: 8/10** — Dreamy glow transforms mundane into ethereal.

---

## Tier 2: Medium Impact — Strong Additions

### 6. Drip / Rain Effect

**What it does:** Vertical dripping trails with per-column random velocity. Creates a melting/dripping appearance.

**Tweet:** https://x.com/XorDev/status/2019209536352268572 (224❤, 18🔁)
**Thread:** Full breakdown of grid stretching → random offset → edge fading

```glsl
vec2 p = (FC.xy * 2.0 - r) / r.y * vec2(10, 1);  // stretch into columns
vec2 a = vec2(0.5, 0.1);  // asymmetric cell origin
vec2 f = fract(vec2(p.x, p.y + t * 4.0/PI + sin(ceil(p.x) / 0.1 + t))) - a;
vec2 m = 1.0 - max(f / (1.0 - a), -f / a);
o += tanh(0.1 / (1.0 - m.x)) * m.x * m.y;
```

**Liminal implementation:**
- Apply as a displacement/overlay to the source image
- Each column of the image drips downward at different speeds
- Use the cell-edge fading technique for smooth blending
- Parameters: `dripColumns` (number of columns), `dripSpeed`, `dripAmount`
- Could map drip velocity to saliency — subject drips differently from background

**Psychedelic score: 7/10** — Melting/dripping is a recognizable psychedelic pattern.

---

### 7. Glassy Hollow Raymarching

**What it does:** Makes surfaces appear hollow and translucent by stepping through the absolute of the signed distance. Creates glass-like iridescent effects.

**Tweet:** https://x.com/XorDev/status/2019431167443767319 (5❤ but technique is powerful)
```glsl
d = 0.005 + abs(d);  // step through absolute SDF = hollow
color += vec3(1) / d;  // accumulate glow inversely proportional to distance
// tonemap the output
```

**Liminal implementation:**
- Not a direct SDF raymarcher, but the principle applies: make edges glow by computing edge distance
- Use the existing saliency map as a distance field
- Areas near saliency boundaries glow with iridescent colors
- Parameters: `glassAmount`, `glassColor` (iridescent palette)
- Could combine with chromatic aberration at edges for refraction look

**Psychedelic score: 6/10** — Glowing translucent edges add otherworldly quality.

---

### 8. Cyberspace / Digital Grid

**What it does:** Raymarched 3D grid with turbulence, creating a flying-through-cyberspace effect. Think Tron or Matrix aesthetic.

**Tweet (CYBERSPACE):** https://x.com/XorDev/status/1986176381680521639 (430❤, 33🔁)
**Tweet (CYBERSPACE 2):** https://x.com/XorDev/status/1986182095614406664 (212❤, 21🔁)

**Liminal implementation:**
- This is a full 3D raymarcher — too expensive to run as an image effect
- BUT: could pre-render cyberspace frames and use them as transition overlays
- Or: simplify to a 2D grid distortion applied to the image
- Apply `round()` to turbulence-displaced UVs for blocky digital fragmentation
- Parameters: `gridDensity`, `gridDistortion`, `gridSpeed`

**Psychedelic score: 7/10** — Digital fragmentation of reality. Different flavor of psychedelia.

---

### 9. Escher Tiling / Geometric Patterns

**What it does:** Mathematical tiling patterns that create impossible geometry. Escher-like tessellations using modular arithmetic.

**Tweet:** https://x.com/XorDev/status/2001840446054764763 (91❤, 6🔁)
```glsl
vec3 p = 0.3 * (FC.xy * 2.0 - r) / r.y * mat3x2(-8,0,4,7,4,-7);
vec3 c = ceil(p + 0.5 + 0.66 * (abs(fract(p.yzx) - 0.3) + abs(fract(p.zxy + 0.5) - 0.3)));
o.rgb = mod(c + c.yzx, 2.0);
```

**Liminal implementation:**
- Apply as a UV transformation before texture sampling
- The image content would tile in Escher-like patterns
- Use modular arithmetic on UVs for impossible repetition
- Parameters: `tileType` (hexagonal, triangular, cubic), `tileScale`, `tileAnimate`
- Could slowly morph between tiling patterns over time

**Psychedelic score: 7/10** — Impossible geometry is deeply psychedelic. Escher meets AI art.

---

### 10. Scatter / Shatter

**What it does:** Image shatters into particles or fragments that scatter outward, with each fragment preserving a piece of the original image.

**Tweet (Scatter):** https://x.com/XorDev/status/2001733058949714173 (151❤, 8🔁)
**Tweet (Scatter 2):** https://x.com/XorDev/status/2001739376204697905 (302❤, 21🔁)

**Liminal implementation:**
- Divide the screen into cells using `ceil()`
- Offset each cell's UV by a pseudo-random amount based on cell ID
- Animate the offset to make fragments scatter and reform
- Could trigger during image transitions — old image shatters, new image assembles
- Parameters: `scatterCells`, `scatterAmount`, `scatterSpeed`

**Psychedelic score: 6/10** — Fragmentation of visual reality. More dramatic than subtle.

---

### 11. Depth of Field (Stochastic)

**What it does:** Blurs areas at different depths by offsetting the camera position by noise. Creates dreamy focus effects cheaply.

**Tweet:** https://x.com/XorDev/status/1983553936159314148 (275❤, 29🔁)
**Tweet (technique):** https://x.com/XorDev/status/2019433838607274278 (6❤ but explains the method)

```glsl
// Quick stochastic motion blur / DOF
pos.z += noise(FC);  // offset camera by noise
// XorDev's compact pseudo noise:
noise = mod(dot(FC, sin(FC.yxyx)), 1.0);
```

**Liminal implementation:**
- Use the saliency map as a depth proxy (salient = near, background = far)
- Offset UV sampling by noise scaled by inverse saliency
- Background areas blur softly while subject stays sharp
- Parameters: `dofAmount`, `dofFocusRange`
- Already have saliency infrastructure — this leverages it beautifully

**Psychedelic score: 6/10** — Dreamy selective focus. Subtle but effective for trance state.

---

### 12. Bitdumb / Digital Fractal Zoom

**What it does:** Recursive coordinate doubling creates infinitely zooming fractal patterns with digital/glitch aesthetic. XorDev's Bitdumb series was extremely popular (505❤).

**Tweet (Bitdumb):** https://x.com/XorDev/status/1981728326533218310 (505❤, 56🔁)
**Tweet (Bitdumb 2):** https://x.com/XorDev/status/1981733290626240632 (103❤, 14🔁)

```glsl
vec2 p = (round(FC.xy) - 0.5 * r) / r.y;
for (float i; i++ < 20.0; o += vec4(fwidth(v = ceil(p)).xyy,
    fract(length(v) / i - t * 0.2)) * (1.0 - o.a))
    p += p;  // coordinate doubling = infinite zoom
```

**Liminal implementation:**
- Apply coordinate doubling to UVs for a fractal zoom into the image
- Each level shows a different scale of the same image content
- Use `fwidth` for edge detection at each level (creates outlines)
- Could use as a transition effect — zoom fractally into one image, emerge into the next
- Parameters: `fractalLevels` (4-20), `fractalSpeed`, `fractalEdgeGlow`

**Psychedelic score: 8/10** — Infinite zoom is deeply psychedelic. "Falling into the image."

---

## Tier 3: Specialized — Niche but Interesting

### 13. Whirl / Vortex Rotation

**What it does:** 3D rotation around an axis using Rodrigues' formula, creating spiraling vortex motion.

**Tweet:** https://x.com/XorDev/status/1986071686785986848 (792❤, 71🔁)

**Liminal implementation:**
- Apply spiral UV distortion centered on saliency hot spots
- The subject of the image becomes the eye of a vortex
- Parameters: `vortexStrength`, `vortexSpeed`
- Could combine with feedback for spiral trails

**Psychedelic score: 7/10** — Vortex/spiral is a classic psychedelic pattern.

---

### 14. Observer / Concentric Rings

**What it does:** Concentric expanding circles with layered color shifts, creating a pulsing "eye" or "portal" effect.

**Tweet:** https://x.com/XorDev/status/2016531421926703247 (321❤, 30🔁)

**Liminal implementation:**
- Compute distance from center (or from saliency centroid)
- Create concentric rings using `sin(distance * frequency - time)`
- Color each ring differently using the existing hue shift
- Parameters: `ringFrequency`, `ringSpeed`, `ringCenter`

**Psychedelic score: 7/10** — Pulsing concentric patterns are hypnotic.

---

### 15. Phoenix / Mainframe (Iterative Pattern Overlay)

**What it does:** Multi-layered iterative patterns that create complex organic-looking structures. Uses buffer texture feedback for self-interaction.

**Tweet (Phoenix):** https://x.com/XorDev/status/2016630958070419569 (290❤, 34🔁)
**Tweet (Mainframe):** https://x.com/XorDev/status/2018038820822773969 (363❤, 54🔁)
**Tweet (Event 2):** https://x.com/XorDev/status/2016620111809876283 (715❤, 64🔁)

**Liminal implementation:**
- These use `texture(b, ...)` — sampling the buffer texture with distorted UVs
- Liminal's feedback buffer IS this buffer texture
- The key pattern: render procedural glow, THEN blend with warped feedback
- `o = max(tanh(o + (o = texture(b, distorted_uv)) * o), 0.0)`
- This creates self-interacting light patterns on top of the source image

**Psychedelic score: 8/10** — Self-similar evolving light patterns. Very trance-inducing.

---

### 16. Anti-Aliased Edge Glow

**What it does:** Smooth glowing edges using derivatives (`dFdx`/`dFdy`) with proper anti-aliasing.

**Tweet:** https://x.com/XorDev/status/2003584625822818334 (432❤, 30🔁)
```glsl
vec2 dxy = vec2(dFdx(d), dFdy(d));
float aa = smoothstep(-1.0, 1.0, d / max(length(dxy), 0.0001));
```

**Liminal implementation:**
- Apply to saliency edges for glowing outlines around subjects
- Or apply to the distortion field for visible flow lines
- Very cheap — uses built-in derivative functions
- Parameters: `edgeGlow`, `edgeWidth`

**Psychedelic score: 5/10** — Subtle aura effect. Nice accent, not a primary effect.

---

### 17. Chords / Organic SDF Shapes

**What it does:** Raymarched signed distance fields creating organic flowing 3D shapes — strings, tentacles, organic surfaces.

**Tweet:** https://x.com/XorDev/status/1982814385572569175 (441❤, 44🔁)

**Liminal implementation:**
- Too expensive for a real-time image effect as-is
- But the SDF distance function could drive a 2D displacement field
- Or render a simplified 2D version as an overlay (organic flowing lines)
- Parameters: `organicDensity`, `organicScale`

**Psychedelic score: 6/10** — Organic flowing shapes. Tentacles and biomorphic forms.

---

## Implementation Priority

Based on psychedelic impact, implementation difficulty, and synergy with Liminal's existing pipeline:

| Priority | Effect | Impact | Effort | Notes |
|----------|--------|--------|--------|-------|
| 1 | **Turbulence** | 10/10 | Low | ~~Replaces fBM distortion, cheaper and better~~ **DONE** - Implemented in `EffectsRenderer.metal`, base amplitude 0.08 |
| 2 | **Chromatic Aberration** | 9/10 | Very Low | ~~3 extra texture samples, huge visual payoff~~ **DONE** - Radial CA with golden-ratio oscillation (0.003-0.015), transition boost |
| 3 | **Feedback Warping** | 10/10 | Low | Infrastructure exists, just add warp to UV lookup |
| 4 | **Stochastic Bloom** | 8/10 | Very Low | 1 extra texture sample, instant dream quality |
| 5 | **Combustion Overlay** | 9/10 | Medium | Turbulence + color mapping + blend mode |
| 6 | **Fractal Zoom (Bitdumb)** | 8/10 | Medium | Coordinate doubling on UVs, good for transitions |
| 7 | **Drip / Melt** | 7/10 | Medium | Column-based UV offset with cell fading |
| 8 | **Vortex / Whirl** | 7/10 | Low | Spiral UV distortion, simple math |
| 9 | **Concentric Rings** | 7/10 | Very Low | sin(distance) modulation |
| 10 | **Scatter / Shatter** | 6/10 | Medium | Cell-based UV fragmentation |

**Recommended first batch:** Turbulence + Chromatic Aberration + Stochastic Bloom. These three together would dramatically transform Liminal's visual quality with minimal code changes. All three fit cleanly into the existing `effectsFragment()` pipeline.

---

## Key Technical Notes

### XorDev's Common Patterns (reusable in Metal)

**Tonemapping with `tanh`:** Nearly every XorDev shader uses `tanh(color)` or `tanh(color * color)` for HDR tonemapping. This compresses bright values smoothly and creates natural-looking glow. Metal equivalent: `tanh()` is available in MSL.

**Compact pseudo-noise:** `mod(dot(FC, sin(FC.yxyx)), 1.0)` — no noise texture needed, good enough for stochastic effects. Useful for bloom and DOF.

**Coordinate doubling for fractals:** `p += p` or `p *= mat2(2,2,-2,2)` creates self-similar patterns at multiple scales. Apply to UVs for fractal image effects.

**Buffer feedback with distortion:** `texture(buffer, uv + distortion)` creates self-interacting patterns. Liminal's existing feedback system directly supports this.

**Perpendicular axis swizzle:** `sin(p.yx)` or `.zxy` creates perpendicular wave interference without explicit rotation matrices. Cheaper than matrix multiplication.

### XorDev Resources

- **Portfolio:** https://xordev.com (397+ shaders)
- **Shader Arsenal:** https://xordev.com/arsenal
- **Tutorials:** https://mini.gmshaders.com (turbulence, tonemaps, derivatives, anti-aliasing)
- **Substack:** https://shaderarsenal.substack.com
- **Live demos:** https://twigl.app (many shaders have twigl links for interactive viewing)
- **ShaderToy:** Various shaders with commented source code
- **Licensing:** Free for non-commercial with credit; $100/shader for commercial with expanded code + comments + macro parameters

---

*Research compiled Feb 2026 from ~250 tweets spanning Oct 2025 — Feb 2026*
