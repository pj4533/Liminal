#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex Structures

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - Simplex Noise (2D) - copied from DreamyEffects.metal

float3 mod289_v3(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float2 mod289_v2(float2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 permute_v3(float3 x) {
    return mod289_v3(((x * 34.0) + 1.0) * x);
}

float snoise2d(float2 v) {
    const float4 C = float4(
        0.211324865405187,
        0.366025403784439,
        -0.577350269189626,
        0.024390243902439
    );

    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);

    float2 i1;
    i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;

    i = mod289_v2(i);
    float3 p = permute_v3(permute_v3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));

    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;

    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// MARK: - Turbulence Distortion (XorDev technique)
// Layered perpendicular sine waves create organic fluid-like motion.
// Cheaper than fBM (just sine waves, no noise function) and more organic.
// See: https://mini.gmshaders.com/p/turbulence

float2 turbulence_distort(float2 pos, float time, float speed) {
    half2 result = half2(pos);
    half freq = 2.0h;

    // Rotation matrix (~53 degrees) for perpendicular wave interference
    half2x2 rot = half2x2(0.6h, -0.8h, 0.8h, 0.6h);
    // Wrap in float before converting: half loses sub-second precision past ~2048s.
    // Seamless because time only enters through sin(), which has period 2π.
    half htime = half(fmod(speed * time, 6.2831853));

    for (half i = 0.0h; i < 8.0h; i++) {
        half phase = freq * (rot * result).y + htime + i;
        result += rot[0] * sin(phase) / freq;
        rot = rot * half2x2(0.6h, -0.8h, 0.8h, 0.6h);
        freq *= 1.4h;
    }

    // Return displacement (difference from original position)
    return float2(result) - pos;
}

// MARK: - HSV Conversion (for Nishitsuji fractal hue cycling)

float3 hsv2rgb(float h, float s, float v) {
    float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

// MARK: - Nishitsuji Sinusoidal Interference Noise
// Crystalline noise using swizzled sin/cos dot products — distinct from XorDev turbulence.
// See: docs/NISHITSUJI_SHADERS.md

float nishitsujiNoise(half3 pos, int octaves) {
    half e = 0.0h;
    half s = 1.0h;
    for (int j = 0; j < octaves; j++) {
        e += abs(dot(sin(pos.yzx * s), cos(pos.xzz * s))) / s * 0.6h;
        s *= 2.0h;
    }
    return float(e);
}

// Flowing/organic variant (from the viral fractal tweets)
float nishitsujiNoiseFlowing(half3 pos, int octaves) {
    half e = 0.0h;
    half s = 1.0h;
    for (int j = 0; j < octaves; j++) {
        half3 sinP = sin(pos.zxy * s) - 0.5h;
        half3 cosP = 1.0h - cos(pos.yxz * s);
        e += sin(dot(sinP, cosP)) / s;
        s *= 2.0h;
    }
    return float(e);
}

// MARK: - Log-Spherical Transform (Nishitsuji's signature viral technique)
// UV distortion through logarithmic-spherical coordinates — infinite-depth kaleidoscopic warping.
// 6-octave sinusoidal noise in log-polar space (higher octaves are sub-pixel at 2048²).

float3 logSphericalTransform(float2 uv, float time, float intensity) {
    float2 centered = uv - 0.5;
    float R = length(centered);

    // Logarithmic-spherical mapping (float for UV precision)
    float logR = log2(max(R, 0.001));
    float angle = atan2(centered.y, centered.x);

    // Animate through fractal space — convert to half for noise evaluation
    half3 p = half3(
        logR - fmod(time * 0.3, 6.2831853),  // wrap: p.x only feeds sin/cos at integer multiples
        exp(half(1.0 - centered.y / max(R, 0.001))),
        angle + half(cos(time * 0.5)) * 0.2h
    );

    // 6-octave sinusoidal noise in half precision (Apple GPU runs FP16 at 2x rate)
    half e = p.y - 1.0h;
    half s = 1.0h;
    for (int j = 0; j < 6; j++) {
        half3 sinP = sin(p.zxy * s) - 0.5h;
        half3 cosP = 1.0h - cos(p.yxz * s);
        e += sin(dot(sinP, cosP)) / s;
        s *= 2.0h;
    }

    // UV displacement along radial direction (back to float for UV math)
    float ef = float(e);
    float displacement = ef * intensity;
    float2 offset = float2(
        cos(angle) * displacement,
        sin(angle) * displacement
    );

    return float3(offset, ef);
}

// MARK: - Chroma helpers (vibrance; docs/decisions/vibrance.md)
// All colour math runs on gamma-encoded sRGB values (the shader never linearises; see V1).
// "Chroma" here is max-min of RGB: cheap, hue-agnostic, and what an RGB average destroys.

constant half3 LUMA_W = half3(0.299h, 0.587h, 0.114h);

static inline half chromaOf(half3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

// Scale chroma about luma l so every channel lands in [0,1]. Hue and luma are unchanged.
static inline half3 gamutFit(half3 c, half l) {
    half hi = max(c.r, max(c.g, c.b));
    half lo = min(c.r, min(c.g, c.b));
    half k = min(1.0h, min((1.0h - l) / max(hi - l, 1.0e-4h), l / max(l - lo, 1.0e-4h)));
    return l + (c - l) * k;
}

// Raise chroma toward `target` (never lower it), luma-preserving and gamut-safe.
// Used after RGB mixes of differently-hued colours, which otherwise pass through grey.
// target is a convex combination of the inputs' chroma, so it can never over-saturate
// (and the feedback loop cannot run away). The 0.02 floor keeps grey noise grey.
static inline half3 restoreChroma(half3 c, half target, half maxGain) {
    half l = dot(c, LUMA_W);
    half g = clamp(target / max(chromaOf(c), 0.02h), 1.0h, maxGain);
    return gamutFit(l + (c - l) * g, l);
}

// MARK: - Uniforms

struct EffectsUniforms {
    float time;
    float kenBurnsScale;
    float kenBurnsOffsetX;      // normalized -1 to 1
    float kenBurnsOffsetY;      // normalized -1 to 1
    float distortionAmplitude;
    float distortionSpeed;
    float hueBaseShift;
    float hueWaveIntensity;
    float hueBlendAmount;
    float contrastBoost;
    float saturationBoost;
    float ghostTapMaxDistance;  // how far ghost taps travel (0.25 = 25% of image)
    float saliencyInfluence;    // how much saliency affects hue (0 = none, 1 = full)
    float hasSaliencyMap;       // 1.0 if saliency map available, 0.0 otherwise
    float transitionProgress;   // 0-1 for GPU crossfade blending between images
    float ghostTapCount;        // number of active ghost taps (0-8), avoids branch divergence
    float chromaticAmount;      // radial chromatic aberration strength (0 = off, 0.01 = subtle)
    float feedbackWarpAmount;   // turbulence displacement applied to feedback UV lookup
    float feedbackMix;          // how much previous frame bleeds through (0 = none, 0.3 = trails)
    float bloomRadius;          // stochastic bloom sample offset radius
    float bloomAmount;          // bloom intensity (0 = off)
    float stereoOffset;         // signed per-eye UV shift, scaled by depth
    float logSphereAmount;      // log-spherical fractal distortion intensity
    float fractalNoiseAmount;   // sinusoidal interference noise distortion intensity
    float fractalHueAmount;     // fractal-driven hue cycling intensity
    float vibranceAmount;       // final vibrance stage chroma gain (0 = off)
    float blackPoint;           // final vibrance stage black-point pull-down (0 = off)
};

// Ghost tap data - passed in separate buffer as array of 8
struct GhostTap {
    float progress;     // 0 = just spawned, 1 = expired
    float directionX;   // normalized direction X component
    float directionY;   // normalized direction Y component
    float active;       // 1.0 if active, 0.0 if slot empty
};

constant int MAX_GHOST_TAPS = 8;

// MARK: - DEBUG: Simple Passthrough Fragment (no effects)
// Use this to verify shader pipeline is working before debugging effects

fragment half4 passthroughFragment(
    VertexOut in [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]],
    constant EffectsUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);
    return sourceTexture.sample(texSampler, in.texCoord);
}

// MARK: - Full-screen Quad Vertex Shader

vertex VertexOut effectsVertex(uint vertexID [[vertex_id]]) {
    // Full-screen quad
    float2 positions[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1)
    };

    float2 texCoords[4] = {
        float2(0, 1),  // flip Y for Metal
        float2(1, 1),
        float2(0, 0),
        float2(1, 0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Combined Effects Fragment Shader

// DEBUG: Set to 0 for full effects, 1-6 for debug stages
// 1 = just source, 2 = +KenBurns, 3 = +fBM, 4 = +color, 5 = +feedback, 0 = all
#define DEBUG_STAGE 0

// Stage A: Ken Burns + turbulence + log-spherical + sinusoidal noise, through the UV clamp.
// Depends only on texCoord and uniforms, so both stereo eyes share the result.
static inline float2 distortedUV(float2 texCoord, constant EffectsUniforms &uniforms) {
    float2 uv = texCoord;

    // === 1. KEN BURNS TRANSFORM ===
    // Apply scale around center
    float2 center = float2(0.5, 0.5);
    float2 centered = uv - center;
    centered /= uniforms.kenBurnsScale;
    // Apply offset (normalized, convert to UV space)
    centered -= float2(uniforms.kenBurnsOffsetX, uniforms.kenBurnsOffsetY) * 0.05;  // scale down offset
    uv = centered + center;

    // === 2. DREAMY DISTORTION (Turbulence) ===
    // XorDev's layered sine wave turbulence — organic fluid motion
    float2 displacement = turbulence_distort(uv * 3.0, uniforms.time, uniforms.distortionSpeed)
                        * uniforms.distortionAmplitude;
    uv += displacement;

    // === 2.5 LOG-SPHERICAL DISTORTION (Nishitsuji signature technique) ===
    // Kaleidoscopic warping through log-polar fractal space
    if (uniforms.logSphereAmount > 0.001) {
        float3 fractalResult = logSphericalTransform(
            uv, uniforms.time, uniforms.logSphereAmount
        );
        uv += fractalResult.xy;
    }

    // === 2.7 SINUSOIDAL INTERFERENCE NOISE (Nishitsuji crystalline distortion) ===
    // Refracting, prismatic texture — complements XorDev's smoky turbulence
    if (uniforms.fractalNoiseAmount > 0.001) {
        half3 noisePos = half3(half2(uv * 6.0), half(fmod(uniforms.time * 0.15, 6.2831853)));
        float noiseX = nishitsujiNoiseFlowing(noisePos, 5);
        float noiseY = nishitsujiNoiseFlowing(noisePos + half3(17.0h, 31.0h, 7.0h), 5);
        float amount = uniforms.fractalNoiseAmount;
        uv += float2(noiseX, noiseY) * amount;
    }

    // Clamp UV to valid range
    uv = clamp(uv, float2(0.001), float2(0.999));

    return uv;
}

// Stage B: stereo parallax through the final colour. Everything that differs per eye lives here.
static inline half4 shadeEye(
    float2 uv,
    float2 texCoord,
    float2 fragPos,
    float stereoOffset,
    texture2d<half> sourceTexture,
    texture2d<half> saliencyTexture,
    texture2d<half> previousTexture,
    texture2d<half> feedbackTexture,
    texture2d<half> depthTexture,
    constant EffectsUniforms &uniforms,
    constant GhostTap *ghostTaps
) {
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);

    // === STEREO DEPTH PARALLAX ===
    // Per-eye shift scaled by depth so near subjects separate more than distant background.
    if (abs(stereoOffset) > 0.000001) {
        constexpr sampler depthSampler(address::clamp_to_edge, filter::linear);
        float depthVal = float(depthTexture.sample(depthSampler, uv).r);  // 0=far, 1=near
        float boostedDepth = pow(clamp(depthVal, 0.0, 1.0), 0.75);
        float parallax = stereoOffset * boostedDepth;
        uv.x = clamp(uv.x + parallax, 0.001, 0.999);
    }

    // === CHROMATIC ABERRATION ===
    // Sample RGB channels at slightly offset UVs for prismatic fringing.
    // Radial: stronger at edges, zero at center.
    float2 chromOffset = (uv - 0.5) * uniforms.chromaticAmount;
    half4 sourceColor = half4(
        sourceTexture.sample(texSampler, uv + chromOffset).r,
        sourceTexture.sample(texSampler, uv).g,
        sourceTexture.sample(texSampler, uv - chromOffset).b,
        1.0h
    );
    half4 prevColor = half4(
        previousTexture.sample(texSampler, uv + chromOffset).r,
        previousTexture.sample(texSampler, uv).g,
        previousTexture.sample(texSampler, uv - chromOffset).b,
        1.0h
    );

    // === GPU CROSSFADE BLENDING ===
    // Always blend - when not transitioning, previousTexture == sourceTexture (fallback)
    // This avoids the "jump to new image" on first frame of transition
    float blendT = uniforms.transitionProgress;
    float eased = blendT < 0.5 ? 4.0 * blendT * blendT * blendT : 1.0 - pow(-2.0 * blendT + 2.0, 3.0) / 2.0;

    // Blend: previous -> current as progress goes 0 -> 1
    // At t=0: show previous (old image), at t=1: show source (new image)
    half4 color = mix(prevColor, sourceColor, half(eased));

    // DEBUG STAGE 3: Ken Burns + fBM distortion
    #if DEBUG_STAGE == 3
    return color;
    #endif

    // === 3. SPATIAL HUE SHIFT ===
    // Store original luminance
    half originalLuma = dot(color.rgb, half3(0.299h, 0.587h, 0.114h));

    // Convert RGB to HSV
    half4 K = half4(0.0h, -1.0h / 3.0h, 2.0h / 3.0h, -1.0h);
    half4 p = mix(half4(color.bg, K.wz), half4(color.gb, K.xy), step(color.b, color.g));
    half4 q = mix(half4(p.xyw, color.r), half4(color.r, p.yzx), step(p.x, color.r));

    half d = q.x - min(q.w, q.y);
    half e = 1.0e-10h;
    half3 hsv = half3(abs(q.z + (q.w - q.y) / (6.0h * d + e)), d / (q.x + e), q.x);

    // Spatial waves for rainbow effect
    float t = uniforms.time;
    float wi = uniforms.hueWaveIntensity;

    float horizWaves = sin(uv.x * 2.0 + t * 0.2) * wi
                     + sin(uv.x * 5.0 - t * 0.15) * wi * 0.6
                     + sin(uv.x * 8.0 + t * 0.3) * wi * 0.3;

    float vertWaves = sin(uv.y * 3.0 + t * 0.18) * wi * 0.8
                    + sin(uv.y * 6.0 - t * 0.22) * wi * 0.5
                    + sin(uv.y * 10.0 + t * 0.25) * wi * 0.25;

    float diagWaves = sin((uv.x + uv.y) * 4.0 + t * 0.12) * wi * 0.7
                    + sin((uv.x - uv.y) * 3.0 - t * 0.16) * wi * 0.5;

    float2 centerOffset = uv - 0.5;
    float dist = length(centerOffset);
    float radialWaves = sin(dist * 12.0 - t * 0.3) * wi * 0.5;

    float spatialOffset = horizWaves + vertWaves + diagWaves + radialWaves;

    // === SALIENCY-BASED HUE VARIATION ===
    // Sample saliency map if available - subjects get different hue treatment
    float saliencyOffset = 0.0;
    half saliencyValue = 0.5h;  // Default to neutral
    if (uniforms.hasSaliencyMap > 0.5) {
        // Sample saliency at the original UV (before distortion for consistency)
        saliencyValue = saliencyTexture.sample(texSampler, texCoord).r;
        // Shift hue based on saliency: high saliency (subjects) shift one direction,
        // low saliency (background) shifts the other direction
        // Range: -0.5 to +0.5 * saliencyInfluence
        saliencyOffset = (float(saliencyValue) - 0.5) * uniforms.saliencyInfluence;
    }

    hsv.x = fract(hsv.x + half(uniforms.hueBaseShift + spatialOffset + saliencyOffset));

    // Saturation boost - slightly more for salient regions
    float satBoost = 1.4 + float(saliencyValue) * 0.2;  // 1.4 to 1.6
    hsv.y = min(1.0h, hsv.y * half(satBoost));

    // Convert back to RGB
    half4 K2 = half4(1.0h, 2.0h / 3.0h, 1.0h / 3.0h, 3.0h);
    half3 p2 = abs(fract(hsv.xxx + K2.xyz) * 6.0h - K2.www);
    half3 shiftedRgb = hsv.z * mix(K2.xxx, clamp(p2 - K2.xxx, 0.0h, 1.0h), hsv.y);

    // Color blend mode
    half shiftedLuma = dot(shiftedRgb, half3(0.299h, 0.587h, 0.114h));
    // Restore the original luma, but cap the scale so the largest channel stops at 1.
    // (Scale-then-clamp turned bright->dark hue rotations into pastels.)
    half shiftedMax = max(shiftedRgb.r, max(shiftedRgb.g, shiftedRgb.b));
    half3 colorBlended = shiftedRgb * min(originalLuma / max(shiftedLuma, 0.001h),
                                          1.0h / max(shiftedMax, 0.001h));

    // Contrast boost
    half3 contrasted = (colorBlended - 0.5h) * half(uniforms.contrastBoost) + 0.5h;
    contrasted = clamp(contrasted, 0.0h, 1.0h);

    // Saturation boost
    half contrastedLuma = dot(contrasted, half3(0.299h, 0.587h, 0.114h));
    half3 saturated = mix(half3(contrastedLuma), contrasted, half(uniforms.saturationBoost));
    saturated = clamp(saturated, 0.0h, 1.0h);

    // Mix with original based on blend amount
    // The two colours often have opposite hues; compensate the chroma the RGB mix loses.
    half hb = half(uniforms.hueBlendAmount);
    half3 currentColor = mix(color.rgb, saturated, hb);
    currentColor = restoreChroma(currentColor, mix(chromaOf(color.rgb), chromaOf(saturated), hb), 2.0h);

    // === 6.5 FRACTAL HUE CYCLING (Nishitsuji organic color shifts) ===
    // Spatially-varying hue shifts driven by sinusoidal interference noise.
    // Depth-map aware: foreground shifts more than background.
    if (uniforms.fractalHueAmount > 0.001) {
        // Sample depth for foreground/background modulation
        float depth = float(depthTexture.sample(texSampler, uv).r);

        // Fractal noise for hue modulation
        half3 noisePos = half3(half2(uv * 5.0), half(fmod(uniforms.time * 0.1, 6.2831853)));
        float fractalValue = nishitsujiNoiseFlowing(noisePos, 4);

        // Convert current color to HSV (full float precision)
        float3 rgb = float3(currentColor);
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

        // Shift hue by fractal pattern, modulated by depth (more shift in foreground)
        float hueShift = fractalValue * uniforms.fractalHueAmount;
        hueShift *= mix(0.3, 1.0, depth);
        hue = fract(hue + hueShift);

        // Boost saturation slightly at fractal high-points
        sat = clamp(sat * (1.0 + abs(fractalValue) * 0.3), 0.0, 1.0);

        currentColor = half3(hsv2rgb(hue, sat, val));
    }

    // === 4. GHOST TAPS - Discrete Delay Echoes ===
    // Each ghost tap spawns at the image, animates outward, and fades.
    // Multiple taps flow in similar directions, creating streaming trails.
    // Loop only over active taps (packed at front) to avoid branch divergence.
    // IMPORTANT: Skip ghost taps during transitions - they sample sourceTexture (new image)
    // which would bleed through before the crossfade completes.
    int tapCount = (uniforms.transitionProgress > 0.001) ? 0 : int(uniforms.ghostTapCount);
    half preTapChroma = chromaOf(currentColor);
    for (int i = 0; i < tapCount; i++) {
        GhostTap tap = ghostTaps[i];

        // Compute offset from progress and direction
        // Ghost starts at center (progress=0), moves outward (progress=1)
        float2 offset = float2(tap.directionX, tap.directionY)
                      * tap.progress * uniforms.ghostTapMaxDistance;
        float2 ghostUV = uv + offset;
        ghostUV = clamp(ghostUV, float2(0.001), float2(0.999));

        // Sample source at ghost's offset position
        half4 ghostSample = sourceTexture.sample(texSampler, ghostUV);

        // Alpha fade: stronger at start (progress=0), transparent at end (progress=1)
        // Use ease-out curve for smoother fade
        half ghostAlpha = half(1.0 - tap.progress * tap.progress);

        // Blend ghost with current color
        // Very subtle - ghosts should be background whispers, not dominant
        currentColor = mix(currentColor, ghostSample.rgb, ghostAlpha * 0.15h);
    }

    // Ghosts keep their shape (luma) and take on the processed colour's chroma.
    if (tapCount > 0) {
        currentColor = restoreChroma(currentColor, preTapChroma, 1.5h);
    }

    // === 5. STOCHASTIC BLOOM ===
    // Single random-offset sample weighted by brightness — dreamy glow around bright areas.
    // Noise varies per pixel and per frame so the bloom shimmers organically.
    if (uniforms.bloomAmount > 0.001) {
        float2 fc = fragPos;
        // Animated pseudo-noise: varies per pixel (fc) and per frame (time)
        float2 noise = fract(sin(float2(
            dot(fc, float2(127.1, 311.7)) + uniforms.time * 43.7,
            dot(fc, float2(269.5, 183.3)) + uniforms.time * 71.3
        )) * 43758.5453) * 2.0 - 1.0;
        float2 bloomUV = clamp(uv + noise * uniforms.bloomRadius, float2(0.001), float2(0.999));
        half3 bloomSample = sourceTexture.sample(texSampler, bloomUV).rgb;
        half brightness = dot(bloomSample, half3(0.299h, 0.587h, 0.114h));
        // Saturate the glow about its own luma and SCREEN it: highlights roll off with their
        // colour instead of the old clamped add flattening them to white.
        half3 glow = bloomSample * brightness * half(uniforms.bloomAmount);
        half glowL = dot(glow, LUMA_W);
        glow = clamp(glowL + (glow - glowL) * 1.5h, 0.0h, 1.0h);
        currentColor = 1.0h - (1.0h - currentColor) * (1.0h - glow);
    }

    // === 6. FEEDBACK WARPING ===
    // Sample previous frame output with turbulence-warped UVs.
    // Each frame compounds the warp, creating evolving fractal trails.
    if (uniforms.feedbackMix > 0.001) {
        float2 feedbackUV = uv + turbulence_distort(uv * 2.0, uniforms.time, 0.05)
                          * uniforms.feedbackWarpAmount;
        feedbackUV = clamp(feedbackUV, float2(0.001), float2(0.999));
        half3 feedbackColor = feedbackTexture.sample(texSampler, feedbackUV).rgb;
        half fm = half(uniforms.feedbackMix);
        half fbTarget = mix(chromaOf(currentColor), chromaOf(feedbackColor), fm);
        currentColor = restoreChroma(mix(currentColor, feedbackColor, fm), fbTarget, 1.5h);
    }

    // === 7. VIBRANCE ===
    // Black-point pull-down, then a chroma gain weighted toward under-saturated pixels
    // (tapers to 1 as saturation -> 1: the soft knee), gated off for near-greys, then
    // gamutFit: luma- and hue-preserving, never leaves [0,1] (no clipping to white).
    {
        half bp = half(uniforms.blackPoint);
        half3 c = max((currentColor - bp) / (1.0h - bp), 0.0h);
        half l = dot(c, LUMA_W);
        half mx = max(c.r, max(c.g, c.b));
        half ch = mx - min(c.r, min(c.g, c.b));
        half sat = ch / max(mx, 1.0e-3h);
        half g = 1.0h + half(uniforms.vibranceAmount) * (1.0h - sat) * smoothstep(0.02h, 0.10h, ch);
        currentColor = gamutFit(l + (c - l) * g, l);
    }

    return half4(currentColor, 1.0h);
}

fragment half4 effectsFragment(
    VertexOut in [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]],
    texture2d<half> saliencyTexture [[texture(2)]],
    texture2d<half> previousTexture [[texture(3)]],
    texture2d<half> feedbackTexture [[texture(4)]],
    texture2d<half> depthTexture [[texture(5)]],
    constant EffectsUniforms &uniforms [[buffer(0)]],
    constant GhostTap *ghostTaps [[buffer(1)]]
) {
    // DEBUG STAGE 1: Just sample source texture (should match passthrough)
    #if DEBUG_STAGE == 1
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);
    return sourceTexture.sample(texSampler, in.texCoord);
    #endif

    // DEBUG STAGE 2: Ken Burns only
    #if DEBUG_STAGE == 2
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);
    float2 kb = (in.texCoord - 0.5) / uniforms.kenBurnsScale
              - float2(uniforms.kenBurnsOffsetX, uniforms.kenBurnsOffsetY) * 0.05 + 0.5;
    return sourceTexture.sample(texSampler, clamp(kb, float2(0.001), float2(0.999)));
    #endif

    float2 uv = distortedUV(in.texCoord, uniforms);
    return shadeEye(uv, in.texCoord, in.position.xy, uniforms.stereoOffset,
                    sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture,
                    uniforms, ghostTaps);
}

// MARK: - Stereo MRT Fragment Shader (visionOS)
// Both eyes in one pass: the distortion field (about 125 of about 175 trig per eye-pixel)
// is computed once and shared. uniforms.stereoOffset carries the magnitude (0 when there
// is no depth map); left eye gets -|offset|, right eye +|offset|.

struct StereoEyesOut {
    half4 left  [[color(0)]];
    half4 right [[color(1)]];
};

fragment StereoEyesOut effectsFragmentStereo(
    VertexOut in [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]],
    texture2d<half> saliencyTexture [[texture(2)]],
    texture2d<half> previousTexture [[texture(3)]],
    texture2d<half> feedbackTexture [[texture(4)]],       // left eye's previous output
    texture2d<half> depthTexture [[texture(5)]],
    texture2d<half> feedbackTextureRight [[texture(6)]],  // right eye's previous output
    constant EffectsUniforms &uniforms [[buffer(0)]],
    constant GhostTap *ghostTaps [[buffer(1)]]
) {
    float2 uv = distortedUV(in.texCoord, uniforms);
    float mag = abs(uniforms.stereoOffset);
    StereoEyesOut out;
    out.left = shadeEye(uv, in.texCoord, in.position.xy, -mag,
                        sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture,
                        uniforms, ghostTaps);
    out.right = shadeEye(uv, in.texCoord, in.position.xy, mag,
                         sourceTexture, saliencyTexture, previousTexture, feedbackTextureRight, depthTexture,
                         uniforms, ghostTaps);
    return out;
}

