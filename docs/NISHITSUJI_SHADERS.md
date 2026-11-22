# Yohei Nishitsuji Shader Techniques for Liminal

> Implementation guide for adapting [@YoheiNishitsuji](https://x.com/YoheiNishitsuji)'s GLSL shader art into Liminal's Metal pipeline. Each technique includes the original GLSL, Metal translation, and integration instructions for both 2D effects and visionOS 3D dome.

---

## Artist Context

**Yohei Nishitsuji** is a GLSL artist and PhD physicist (TU Delft, acoustic wave phenomena/moonquake analysis). His work explores the simulation hypothesis through #tsubuyakiGLSL — complete shader programs in 267 characters. His shader artwork has exhibited at the Osaka City Museum of Fine Arts and won the Grand Award at ADAA Fukuoka 2022. XorDev calls him "a legend when it comes to tiny fractals."

His code is **MIT Licensed**. His 400K-view viral fractal tweet demonstrates the visual impact these techniques can achieve.

---

## Liminal Architecture Quick Reference

Before implementing, understand how Liminal's pipeline works:

### Shader Files
| File | Purpose |
|------|---------|
| `Shaders/EffectsRenderer.metal` | Main single-pass fragment shader — 9 sequential effect stages |
| `Shaders/DomeCompute.metal` | visionOS dome vertex deformation compute shader |

### Available Textures (in `effectsFragment`)
| Index | Texture | Format | What It Contains |
|-------|---------|--------|-----------------|
| 0 | `sourceTexture` | BGRA8 sRGB | Current image |
| 2 | `saliencyTexture` | R8 Unorm | ML subject detection map |
| 3 | `previousTexture` | BGRA8 sRGB | Previous image (for crossfade) |
| 4 | `feedbackTexture` | BGRA8 | Previous frame output (recursive effects) |
| 5 | `depthTexture` | R8 Unorm | ML depth map (0=far, 1=near) |

### EffectsUniforms (key fields for new effects)
```metal
struct EffectsUniforms {
    float time;                  // Elapsed seconds
    float distortionAmplitude;   // 0.02-0.08
    float distortionSpeed;       // 0.08
    // ... other existing fields
    float feedbackMix;           // 0.3 (previous frame blend)
    float feedbackWarpAmount;    // 0.03
};
```

### Adding a New Effect — Two Paths

**Path A: New stage in `effectsFragment()`** (recommended for image distortion)
- Add code after existing stages in `EffectsRenderer.metal`
- Add new uniform fields to `EffectsUniforms` struct (both `.metal` and `.swift`)
- Compute parameters in `EffectsUniformsComputer.swift`
- Single-pass, access to all textures and feedback

**Path B: a new `[[stitchable]]` function in its own `.metal` file**
- Used with SwiftUI's `.distortionEffect()` or `.colorEffect()`
- Simpler to prototype, but runs as separate pass (the app ships no stitchable shaders today)

### GLSL → Metal Translation Reference
| GLSL | Metal |
|------|-------|
| `vec2/3/4` | `float2/3/4` |
| `mod(a, b)` | `fmod(a, b)` |
| `atan(y, x)` | `atan2(y, x)` |
| `fract(x)` | `fract(x)` (same) |
| `mix(a, b, t)` | `mix(a, b, t)` (same) |
| `mat2` | `float2x2` |
| `FC` (gl_FragCoord) | `in.position` or UV from vertex shader |
| `r` (resolution) | pass as uniform or use texture dimensions |
| `t` (time) | `uniforms.time` |
| `o` (output) | return value / `half4` |

### HSV Helper (Nishitsuji uses `hsv()` constantly — add this to Metal)
```metal
// twigl.app's built-in hsv() function, translated to Metal
float3 hsv2rgb(float h, float s, float v) {
    float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}
```

---

## Technique 1: Logarithmic-Spherical Image Distortion

**Priority: HIGH** — Nishitsuji's signature technique. Creates infinite-depth warping by mapping UVs through log-polar space. Perfect for trippy image distortion.

**What it does:** Transforms the image through logarithmic-spherical coordinates, making it appear to fold into infinite recursive depth — like looking through a kaleidoscopic tunnel.

**Source tweet (400K views):** [x.com/YoheiNishitsuji/status/2027931191777890725](https://x.com/YoheiNishitsuji/status/2027931191777890725)

### Original GLSL (267 chars)
```glsl
float i,e,R,s;vec3 q,p,d=vec3(FC.xy/r-vec2(.6,.5),.7);
for(q.zx--;i++<99.;){
    o.rgb+=hsv(.1,.2,min(e*s,.7-e)/35.);
    s=1.;p=q+=d*e*R*.1;
    p=vec3(log2(R=length(p))-t,exp(1.-p.z/R),atan(p.y,p.x)+cos(t)*.2);
    for(e=--p.y;s<3e2;s+=s)
        e+=sin(dot(sin(p.zxy*s)-.5,1.-cos(p.yxz*s)))/s;
}
```

### Metal Implementation — As Image Distortion Stage

This adapts the log-spherical transform into a UV distortion that warps the source image rather than rendering a standalone fractal. The key insight: use the fractal's distance field to *displace* texture sampling coordinates.

```metal
// Add to EffectsRenderer.metal, as a new function

float3 logSphericalTransform(float2 uv, float time, float intensity) {
    // Map UV to centered coordinates
    float2 centered = uv - 0.5;
    float R = length(centered);

    // Logarithmic-spherical mapping (Nishitsuji's core technique)
    float logR = log2(max(R, 0.001));
    float angle = atan2(centered.y, centered.x);

    // Animate through the fractal space
    float3 p = float3(
        logR - time * 0.3,                         // Continuous zoom
        exp(1.0 - centered.y / max(R, 0.001)),     // Exponential depth
        angle + cos(time * 0.5) * 0.2              // Oscillating rotation
    );

    // Build sinusoidal noise (Nishitsuji's custom fBM)
    float e = p.y - 1.0;
    float s = 1.0;
    for (int j = 0; j < 9; j++) {  // 9 octaves (s: 1 to 256)
        float3 sinP = sin(p.zxy * s) - 0.5;
        float3 cosP = 1.0 - cos(p.yxz * s);
        e += sin(dot(sinP, cosP)) / s;
        s *= 2.0;
    }

    // Return: x,y = UV displacement, z = fractal intensity (for color effects)
    float displacement = e * intensity;
    float2 offset = float2(
        cos(angle) * displacement,
        sin(angle) * displacement
    );

    return float3(offset, e);
}

// Inside effectsFragment(), after turbulence distortion (stage 2):
// ---
// Stage 2.5: Log-Spherical Fractal Distortion
if (uniforms.logSphereAmount > 0.001) {
    float3 fractalResult = logSphericalTransform(
        uv, uniforms.time, uniforms.logSphereAmount
    );
    uv += fractalResult.xy;

    // Optional: modulate hue shift by fractal intensity
    // (creates color variation that follows the distortion pattern)
    // fractalHue = fractalResult.z;
}
half4 currentColor = half4(sourceTexture.sample(texSampler, uv));
```

### New Uniforms
```swift
// Add to EffectsUniforms:
var logSphereAmount: Float    // 0.0-0.06 — distortion intensity
var logSphereSpeed: Float     // 0.1-0.5 — zoom/rotation speed
```

### Parameter Animation (EffectsUniformsComputer.swift)
```swift
// Oscillate the log-sphere distortion slowly
let logSphereAmount = SmoothOscillator.value(time: time,
    baseFreq: 0.02, min: 0.01, max: 0.05)
```

### 3D Dome Application
The fractal distance field can drive dome vertex displacement:
```metal
// In DomeCompute.metal — use log-spherical noise for organic dome breathing
float3 p = float3(
    log2(max(length(vertex.position.xz), 0.001)),
    vertex.position.y,
    atan2(vertex.position.z, vertex.position.x)
);
float displacement = 0.0;
float s = 1.0;
for (int j = 0; j < 6; j++) {
    displacement += sin(dot(sin(p.zxy * s), 1.0 - cos(p.yxz * s))) / s;
    s *= 2.0;
}
vertex.position += vertex.normal * displacement * intensity;
```

---

## Technique 2: Volumetric Cloud Overlay

**Priority: HIGH** — Creates billowing, atmospheric cloud formations that can overlay or distort the source image. The exponential-sine density function produces remarkably realistic cloud shapes in very few instructions.

**Source tweet (269 likes):** [x.com/YoheiNishitsuji/status/1945085630574133533](https://x.com/YoheiNishitsuji/status/1945085630574133533)

### Original GLSL
```glsl
for(float e,i,a,w,x,g,h;i++<99.;){
    vec3 p=vec3((FC.xy-.5*r)/r*g+3.,g);
    p.zy*=rotate2D(.5);
    e=p.y; h=e;
    for(a=.8;a>.001;a*=.72)
        p.zx*=rotate2D(.5),
        e-=w=exp(sin(p.z/a+t)-3.)*a,
        h+=abs(dot(sin(p.xz/a*.27)*a,r/r));
    g+=e=min(e,h*.5-1.2);
    o.rgb+=.01-.035/exp(max(s,e)*2e3)/h*hsv(h*.26,.3,1.);
}
```

### Metal Implementation — Cloud Distortion + Overlay

Two modes: (A) use cloud density to distort the source image, (B) composite semi-transparent clouds on top.

```metal
// Add to EffectsRenderer.metal

// Nishitsuji's cloud density function
// Returns: x = density, y = detail accumulator (for coloring)
float2 cloudDensity(float3 pos, float time) {
    float e = pos.y;
    float h = e;
    float a = 0.8;

    // Lacunarity loop — each octave rotates sampling plane
    // This rotation is what creates the swirling, billowing quality
    float cosR = cos(0.5);
    float sinR = sin(0.5);
    float2x2 rot = float2x2(cosR, -sinR, sinR, cosR);

    for (int j = 0; j < 12; j++) {  // ~12 octaves (a: 0.8 down to ~0.001)
        pos.zx = rot * pos.zx;  // Rotate sampling plane each octave
        float w = exp(sin(pos.z / a + time) - 3.0) * a;
        e -= w;
        h += abs(dot(sin(pos.xz / a * 0.27) * a, float2(1.0)));
        a *= 0.72;
    }

    float density = min(e, h * 0.5 - 1.2);
    return float2(density, h);
}

// Mode A: Cloud-driven UV distortion
// Add as stage in effectsFragment():
if (uniforms.cloudDistortAmount > 0.001) {
    // Map UV to 3D sampling position
    float3 cloudPos = float3(
        (uv - 0.5) * 4.0 + 3.0,  // Scale UVs to cloud space
        uniforms.time * 0.2       // Slow drift through cloud field
    );

    // Tilt the view (Nishitsuji tilts by 0.5 radians)
    float c = cos(0.5), s_r = sin(0.5);
    cloudPos.zy = float2x2(c, -s_r, s_r, c) * cloudPos.zy;

    float2 cloud = cloudDensity(cloudPos, uniforms.time * 0.5);

    // Use density gradient as displacement
    float2 grad;
    float eps = 0.01;
    grad.x = cloudDensity(cloudPos + float3(eps,0,0), uniforms.time * 0.5).x - cloud.x;
    grad.y = cloudDensity(cloudPos + float3(0,eps,0), uniforms.time * 0.5).x - cloud.x;

    uv += grad * uniforms.cloudDistortAmount * 20.0;
}

// Mode B: Semi-transparent cloud overlay (after sampling source)
if (uniforms.cloudOverlayAmount > 0.001) {
    float3 cloudPos = float3((uv - 0.5) * 4.0 + 3.0, uniforms.time * 0.15);
    float c2 = cos(0.5), s2 = sin(0.5);
    cloudPos.zy = float2x2(c2, -s2, s2, c2) * cloudPos.zy;

    float2 cloud = cloudDensity(cloudPos, uniforms.time * 0.5);

    // Cloud emission color (warm tones, Nishitsuji style)
    float3 cloudColor = hsv2rgb(cloud.y * 0.26, 0.3, 1.0);
    float emission = 0.01 - 0.035 / exp(max(0.0, cloud.x) * 2000.0) / cloud.y;
    emission = clamp(emission, 0.0, 1.0);

    currentColor.rgb = mix(
        currentColor.rgb,
        half3(cloudColor * emission),
        half(uniforms.cloudOverlayAmount * emission)
    );
}
```

### New Uniforms
```swift
var cloudDistortAmount: Float   // 0.0-0.08 — UV displacement from cloud density
var cloudOverlayAmount: Float   // 0.0-0.6 — cloud overlay opacity
var cloudSpeed: Float           // 0.1-0.5 — drift speed
```

### 3D Dome Application
Cloud density as dome vertex displacement creates organic, billowing dome motion — far more interesting than the current sine-wave breathing:
```metal
// In DomeCompute.metal — replace or supplement multi-wave displacement
float3 cloudPos = float3(vertex.uv * 4.0, time * 0.2);
float2 cloud = cloudDensity(cloudPos, time * 0.5);
float displacement = clamp(-cloud.x * 0.3, -0.5, 0.5);
vertex.position += vertex.normal * displacement;
```

---

## Technique 3: Sinusoidal Interference Noise

**Priority: HIGH** — Nishitsuji's custom noise is distinctly different from Perlin/simplex. It produces crystalline, organic textures using only `sin()`/`cos()` dot products. Cheaper to compute, and creates a unique visual signature.

**Why this matters for Liminal:** Liminal currently uses XorDev's turbulence (layered sine waves) and simplex noise. Nishitsuji's noise creates a completely different texture — more like looking through water or crystal than through smoke.

### The Core Pattern
```glsl
// Nishitsuji's noise — swizzled sinusoidal dot products, doubling frequency
for(e=--p.y; s<1e3; s+=s)
    e += abs(dot(sin(p.yzx*s), cos(p.xzz*s)) / s * .6);
```

### Metal Implementation — As Distortion Driver

```metal
// Nishitsuji sinusoidal interference noise
// pos: 3D sample position, octaves: number of frequency doublings
// Returns noise value, typically in range [-2, 2]
float nishitsujiNoise(float3 pos, int octaves, float lacunarity) {
    float e = 0.0;
    float s = 1.0;
    for (int j = 0; j < octaves; j++) {
        // Core technique: dot product of sin/cos with swizzled coordinates
        // Different swizzle patterns create different texture characters:
        //   sin(p.yzx) × cos(p.xzz) = crystalline/angular
        //   sin(p.zxy) × cos(p.yxz) = flowing/organic
        //   sin(p.xzy) × cos(p.zzx) = wavy/rippled
        e += abs(dot(sin(pos.yzx * s), cos(pos.xzz * s))) / s * 0.6;
        s *= lacunarity;  // 2.0 for standard doubling
    }
    return e;
}

// Variant: flowing organic (from the viral fractal tweets)
float nishitsujiNoiseFlowing(float3 pos, int octaves) {
    float e = 0.0;
    float s = 1.0;
    for (int j = 0; j < octaves; j++) {
        float3 sinP = sin(pos.zxy * s) - 0.5;
        float3 cosP = 1.0 - cos(pos.yxz * s);
        e += sin(dot(sinP, cosP)) / s;  // Outer sin() smooths transitions
        s *= 2.0;
    }
    return e;
}

// As UV distortion in effectsFragment():
if (uniforms.fractalNoiseAmount > 0.001) {
    // Map UVs to 3D noise space (add time for animation)
    float3 noisePos = float3(uv * 6.0, uniforms.time * 0.15);

    float noiseX = nishitsujiNoiseFlowing(noisePos, 8);
    float noiseY = nishitsujiNoiseFlowing(noisePos + float3(17.0, 31.0, 7.0), 8);

    uv += float2(noiseX, noiseY) * uniforms.fractalNoiseAmount;
}
```

### New Uniforms
```swift
var fractalNoiseAmount: Float   // 0.0-0.05 — distortion intensity
var fractalNoiseScale: Float    // 3.0-8.0 — spatial frequency
var fractalNoiseOctaves: Float  // 4-9 — detail level (cast to int in shader)
```

### Comparison with Existing Turbulence
| Property | XorDev Turbulence (current) | Nishitsuji Noise |
|----------|---------------------------|------------------|
| Base function | `sin(x + sin(y))` nested | `dot(sin(p.yzx), cos(p.xzz))` |
| Character | Smooth, flowing, smoke-like | Crystalline, interference-pattern |
| Cost | ~4 sin calls per octave | ~6 sin/cos + dot per octave |
| Best for | Gentle organic motion | Detailed fractal texture |
| Visual | Melting, liquid | Refracting, prismatic |

**Recommendation:** Don't replace the existing turbulence — layer Nishitsuji noise on top as a secondary distortion. The two techniques produce complementary textures.

---

## Technique 4: IFS/Mandelbox Fractal Overlay

**Priority: MEDIUM** — Creates intricate 3D crystalline/architectural structures. Less useful as image distortion, but stunning as a semi-transparent overlay or as a depth-driven effect on visionOS.

**Source tweet (325 likes):** [x.com/YoheiNishitsuji/status/1915752660583723232](https://x.com/YoheiNishitsuji/status/1915752660583723232)

### Original GLSL
```glsl
for(float i,g,e,s;++i<99.;o.rgb+=hsv(s*.3,-e,e/7e2)){
    vec3 p=vec3((FC.xy-.5*r)/r.y*(.5-sin(t*.6)*.3)+vec2(0,.6),g-1.);
    p.xz*=rotate2D(t*.3);
    s=14.;
    for(int i;i++<7;p=vec3(1.6,4,2.5)-abs(abs(p)*e-vec3(4,4,3)))
        s*=e=9./dot(p,p);
    g+=p.y/s;
    s=log(s);
}
```

### Metal Implementation — Fractal-Driven Color Overlay

Rather than raymarching (expensive for a real-time effect pipeline), use the IFS fractal as a 2D pattern generator driven by UV coordinates:

```metal
// IFS Mandelbox fractal pattern — 2D projection for overlay/distortion
// Returns: x = fractal intensity, y = accumulated scale (for coloring)
float2 mandelboxPattern(float2 uv, float time) {
    // Map UVs to fractal parameter space
    float3 p = float3(
        (uv - 0.5) * 4.0 + float2(0.0, 0.6),  // Centered, scaled
        -1.0  // Fixed depth slice
    );

    // Rotate over time
    float c = cos(time * 0.3), s_r = sin(time * 0.3);
    p.xz = float2x2(c, -s_r, s_r, c) * p.xz;

    float totalScale = 14.0;
    float e = 1.0;

    // IFS folding loop — 7 iterations creates deep self-similarity
    for (int i = 0; i < 7; i++) {
        e = 9.0 / dot(p, p);               // Sphere inversion
        totalScale *= e;
        p = float3(1.6, 4.0, 2.5) - abs(abs(p) * e - float3(4.0, 4.0, 3.0));
        // Double abs() creates the folding symmetry
    }

    float intensity = p.y / totalScale;     // Distance estimate
    float logScale = log(totalScale);       // For coloring

    return float2(intensity, logScale);
}

// In effectsFragment() — fractal overlay:
if (uniforms.fractalOverlayAmount > 0.001) {
    float2 fractal = mandelboxPattern(uv, uniforms.time);

    // Fractal color (warm amber, Nishitsuji style)
    float3 fractalColor = hsv2rgb(
        fractal.y * 0.3,                           // Hue from scale
        clamp(-fractal.x, 0.0, 1.0),               // Saturation from distance
        clamp(fractal.x / 700.0, 0.0, 1.0)         // Value from distance
    );

    currentColor.rgb = mix(
        currentColor.rgb,
        half3(fractalColor),
        half(uniforms.fractalOverlayAmount * clamp(fractal.x * 50.0, 0.0, 1.0))
    );
}
```

### New Uniforms
```swift
var fractalOverlayAmount: Float  // 0.0-0.5 — overlay blend
var fractalScale: Float          // 2.0-6.0 — zoom into fractal
var fractalRotSpeed: Float       // 0.1-0.5 — rotation speed
```

### 3D Dome Application
The IFS fractal creates spectacular dome vertex displacement — crystalline, architectural deformation:
```metal
// In DomeCompute.metal
float3 p = vertex.position * fractalScale;
float totalScale = 14.0;
float e = 1.0;
for (int i = 0; i < 5; i++) {  // Fewer iterations for vertex shader perf
    e = 9.0 / dot(p, p);
    totalScale *= e;
    p = float3(1.6, 4.0, 2.5) - abs(abs(p) * e - float3(4.0, 4.0, 3.0));
}
float displacement = p.y / totalScale;
vertex.position += vertex.normal * displacement * intensity;
```

---

## Technique 5: Recursive Zoom Distortion

**Priority: HIGH** — The "macroscopic microscope" technique continuously zooms into the image through fractal space, creating the sensation of infinite depth. After step 89 of 119, the ray direction reverses, creating an inside-out mirror effect.

**Why this is trippy:** It makes the source image appear to endlessly fold into itself, revealing new detail at every scale.

### Original GLSL (269 chars)
```glsl
float i,e,R,s;vec3 q,p,d=vec3(-FC.yx/r.y*.8*(abs(cos(t*.3)*.3+.1+.8)),1);
for(q--;i++<119.;i>89.?d/=-d:d){
    e+=i/5e3; o+=e*e/25.;
    s=1.; p=q+=d*e*R*.16;
    p=vec3(log2(R=length(p))-2.-t*.3,-p.z/R,atan(p.x,p.y));
    for(e=--p.y;s<1e5;s+=s)
        e+=cos(dot(cos(p.zyy*s),cos(p.xyx*s)))/s;
}
```

### Metal Implementation — Infinite Zoom Image Distortion

```metal
// Recursive zoom — distorts UVs through logarithmic space with breathing zoom
float2 recursiveZoomDistort(float2 uv, float time, float intensity) {
    float2 centered = uv - 0.5;

    // Breathing zoom (Nishitsuji's pulsating camera)
    float zoom = abs(cos(time * 0.3) * 0.3 + 0.1 + 0.8);
    centered *= zoom;

    float R = length(centered);

    // Log-polar mapping — this is what creates infinite zoom
    float logR = log2(max(R, 0.0001)) - 2.0 - time * 0.3;
    float angle = atan2(centered.x, centered.y);
    float depth = -centered.y / max(R, 0.001);

    // Build fractal noise in log-polar space
    float3 p = float3(logR, depth, angle);
    float e = p.y - 1.0;
    float s = 1.0;
    for (int j = 0; j < 9; j++) {  // 9 octaves (cap at 512 for perf)
        e += cos(dot(cos(p.zyy * s), cos(p.xyx * s))) / s;
        s *= 2.0;
    }

    // Convert noise to UV displacement
    // The log-polar space means displacement follows the zoom spiral
    float2 displacement = float2(
        cos(angle + e) - cos(angle),
        sin(angle + e) - sin(angle)
    ) * intensity * R;

    return uv + displacement;
}

// In effectsFragment():
if (uniforms.recursiveZoomAmount > 0.001) {
    uv = recursiveZoomDistort(uv, uniforms.time, uniforms.recursiveZoomAmount);
}
```

### New Uniforms
```swift
var recursiveZoomAmount: Float   // 0.0-0.1 — distortion intensity
var recursiveZoomSpeed: Float    // 0.1-0.5 — zoom speed
```

---

## Technique 6: Exponential-Sine Terrain Distortion

**Priority: MEDIUM-HIGH** — The `exp(sin())` pattern from the cloud shader, applied as terrain-like displacement. Creates rolling, organic waves that look like an alien landscape viewed from above.

### The Core Pattern
```glsl
e -= exp(sin(p.z/a + t) - 3.0) * a;
```

The magic: `sin()` oscillates -1 to 1, so `sin()-3` ranges -4 to -2, and `exp()` of that gives 0.018 to 0.135 — a smooth, always-positive bump function. Stacking these at multiple scales creates cloud/terrain.

### Metal Implementation — Rolling Terrain Distortion

```metal
// Exponential-sine terrain — creates rolling organic displacement
float expSineTerrain(float2 uv, float time, int octaves) {
    float e = 0.0;
    float a = 0.8;
    float2 p = uv * 4.0;

    float cosR = cos(0.5), sinR = sin(0.5);
    float2x2 rot = float2x2(cosR, -sinR, sinR, cosR);

    for (int j = 0; j < octaves; j++) {
        p = rot * p;  // Rotate each octave (creates swirl)
        e -= exp(sin(p.y / a + time * 0.5) - 3.0) * a;
        a *= 0.72;
    }
    return e;
}

// In effectsFragment() — terrain-driven UV distortion:
if (uniforms.terrainDistortAmount > 0.001) {
    float terrain = expSineTerrain(uv, uniforms.time, 10);

    // Compute gradient for displacement direction
    float eps = 0.005;
    float terrainDx = expSineTerrain(uv + float2(eps, 0), uniforms.time, 10) - terrain;
    float terrainDy = expSineTerrain(uv + float2(0, eps), uniforms.time, 10) - terrain;

    uv += float2(terrainDx, terrainDy) * uniforms.terrainDistortAmount * 15.0;
}
```

### New Uniforms
```swift
var terrainDistortAmount: Float  // 0.0-0.06 — displacement intensity
```

---

## Technique 7: Fractal-Modulated Hue Cycling

**Priority: MEDIUM** — Nishitsuji accumulates color per-raymarching-step using HSV, creating volumetric emission effects. Adapted for Liminal, this creates spatially-varying psychedelic color shifts driven by fractal patterns rather than simple waves.

**Why this matters:** Liminal's current spatial hue shift uses 4-layer sine waves. Fractal-driven hue creates far more intricate, organic color patterns that follow the image's structure.

### Metal Implementation — Fractal Hue Overlay

```metal
// In effectsFragment(), replace or supplement spatial hue shift:
if (uniforms.fractalHueAmount > 0.001) {
    // Use depth map to modulate fractal space (foreground vs background)
    float depth = depthTexture.sample(texSampler, uv).r;

    // Fractal noise for hue modulation
    float3 noisePos = float3(uv * 5.0, uniforms.time * 0.1);
    float fractalValue = nishitsujiNoiseFlowing(noisePos, 6);

    // Convert current color to HSV
    float3 rgb = float3(currentColor.rgb);
    float cMax = max(rgb.r, max(rgb.g, rgb.b));
    float cMin = min(rgb.r, min(rgb.g, rgb.b));
    float delta = cMax - cMin;

    float hue = 0.0;
    if (delta > 0.001) {
        if (cMax == rgb.r) hue = fmod((rgb.g - rgb.b) / delta, 6.0) / 6.0;
        else if (cMax == rgb.g) hue = ((rgb.b - rgb.r) / delta + 2.0) / 6.0;
        else hue = ((rgb.r - rgb.g) / delta + 4.0) / 6.0;
    }
    float sat = (cMax > 0.001) ? delta / cMax : 0.0;
    float val = cMax;

    // Shift hue by fractal pattern, scaled by depth
    float hueShift = fractalValue * uniforms.fractalHueAmount;
    hueShift *= mix(0.3, 1.0, depth);  // More shift in foreground
    hue = fract(hue + hueShift);

    // Boost saturation slightly in fractal high-points
    sat = clamp(sat * (1.0 + abs(fractalValue) * 0.3), 0.0, 1.0);

    currentColor.rgb = half3(hsv2rgb(hue, sat, val));
}
```

### New Uniforms
```swift
var fractalHueAmount: Float  // 0.0-0.4 — hue shift intensity
```

---

## Technique 8: Depth-Aware Fractal Parallax (visionOS)

**Priority: HIGH for visionOS** — Uses the ML depth map + fractal noise to create parallax that follows organic fractal patterns instead of simple linear shifts. The result is a depth effect that feels alive.

### Metal Implementation

```metal
// In effectsFragment(), replace or enhance stereo parallax (stage 3):
if (uniforms.stereoOffset != 0.0 && uniforms.fractalParallaxAmount > 0.001) {
    float depth = depthTexture.sample(texSampler, uv).r;

    // Standard parallax
    float baseOffset = uniforms.stereoOffset * depth;

    // Fractal modulation — depth edges get organic displacement
    float3 noisePos = float3(uv * 8.0, uniforms.time * 0.05);
    float fractal = nishitsujiNoise(noisePos, 6, 2.0);

    // Depth edges (where depth changes rapidly) get extra fractal parallax
    float depthDx = abs(depthTexture.sample(texSampler, uv + float2(0.003, 0)).r - depth);
    float depthDy = abs(depthTexture.sample(texSampler, uv + float2(0, 0.003)).r - depth);
    float edgeFactor = clamp((depthDx + depthDy) * 10.0, 0.0, 1.0);

    float fractalOffset = fractal * uniforms.fractalParallaxAmount * edgeFactor;

    uv.x += baseOffset + fractalOffset;
}
```

### New Uniforms
```swift
var fractalParallaxAmount: Float  // 0.0-0.02 — fractal parallax at depth edges
```

---

## Implementation Priority & Roadmap

### Tier 1 — Implement First (high impact, proven trippy)
| # | Technique | Effect Type | Difficulty | Impact |
|---|-----------|-------------|------------|--------|
| 1 | **Log-Spherical Distortion** | UV distortion | Medium | Infinite-depth warping, his signature look |
| 3 | **Sinusoidal Interference Noise** | UV distortion | Low | New noise texture, complements existing turbulence |
| 5 | **Recursive Zoom** | UV distortion | Medium | Infinite zoom into the image |

### Tier 2 — High Value Additions
| # | Technique | Effect Type | Difficulty | Impact |
|---|-----------|-------------|------------|--------|
| 2 | **Volumetric Clouds** | Overlay + distortion | Medium-High | Atmospheric, dreamy cloud layer |
| 7 | **Fractal Hue Cycling** | Color effect | Low | Organic color variation vs current sine waves |

### Tier 3 — Polish & visionOS
| # | Technique | Effect Type | Difficulty | Impact |
|---|-----------|-------------|------------|--------|
| 6 | **Exp-Sine Terrain** | UV distortion | Low | Rolling organic landscape waves |
| 4 | **IFS/Mandelbox Overlay** | Overlay | Medium | Crystalline fractal layer |
| 8 | **Fractal Parallax** | visionOS depth | Medium | Organic depth at edges, alive-feeling parallax |

### Integration Notes

**All new uniforms** should be added to:
1. `EffectsUniforms` struct in both `EffectsRenderer.metal` and `EffectsUniforms.swift`
2. Animated via `EffectsUniformsComputer.swift` using existing `SmoothOscillator` pattern
3. Use golden ratio frequency offsets to prevent repetition (Liminal's existing pattern)

**Performance budget:** Each new stage adds ~0.5-1ms per 2048x2048 frame. The sinusoidal noise functions (Techniques 1, 3, 5, 6) are cheaper than texture lookups. Cloud density (Technique 2) is the most expensive due to 12-octave loop — consider reducing to 8 octaves.

**Composability:** These techniques are designed to layer with existing effects. The recommended insertion point is between the existing turbulence distortion (stage 2) and chromatic aberration (stage 4), so the new distortions feed into the aberration for enhanced visual complexity.

**Feedback loop interaction:** Techniques 1, 3, and 5 interact powerfully with Liminal's existing feedback warping (stage 9). The fractal distortions accumulate frame-over-frame through the feedback texture, creating evolving, self-similar patterns that build over time. This is where the real psychedelia emerges.

---

## Source References

| Tweet | Engagement | Technique |
|-------|-----------|-----------|
| [Volumetric Clouds](https://x.com/YoheiNishitsuji/status/1945085630574133533) | 269 likes | Exp-sine cloud density |
| [Viral Fractal I (320K)](https://x.com/YoheiNishitsuji/status/1757499194053427268) | 624 likes, 320K views | Log-spherical + flowing noise |
| [Viral Fractal II (400K)](https://x.com/YoheiNishitsuji/status/2027931191777890725) | 996 likes, 400K views | Log-spherical variant |
| [Mandelbox Cathedral](https://x.com/YoheiNishitsuji/status/1915752660583723232) | 325 likes | IFS fractal folding |
| [Rotating IFS](https://x.com/YoheiNishitsuji/status/1788841820929286459) | 87 likes | Compact Mandelbox |
| [Deep Organic](https://x.com/YoheiNishitsuji/status/1737618531146219614) | 20 likes | Organic texture noise |
| [Log-Polar Fractal](https://x.com/YoheiNishitsuji/status/1967449495979057417) | 91 likes | Logarithmic polar + rainbow |
| [Shadertoy: Emptiness](https://www.shadertoy.com/view/MX3BDH) | Codrops featured | Blue infinity, philosophical |
| [Codrops Article](https://tympanus.net/codrops/2025/02/18/rendering-the-simulation-theory-exploring-fractals-glsl-and-the-nature-of-reality/) | — | Artist philosophy + technique breakdown |

**All code MIT Licensed** per artist's stated terms.
