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
    float2 result = pos;
    float freq = 2.0;

    // Rotation matrix (~53 degrees) for perpendicular wave interference
    float2x2 rot = float2x2(0.6, -0.8, 0.8, 0.6);

    for (float i = 0.0; i < 8.0; i++) {
        float phase = freq * (rot * result).y + speed * time + i;
        result += rot[0] * sin(phase) / freq;
        rot = rot * float2x2(0.6, -0.8, 0.8, 0.6);
        freq *= 1.4;
    }

    // Return displacement (difference from original position)
    return result - pos;
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

fragment half4 effectsFragment(
    VertexOut in [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]],
    texture2d<half> saliencyTexture [[texture(2)]],
    texture2d<half> previousTexture [[texture(3)]],
    constant EffectsUniforms &uniforms [[buffer(0)]],
    constant GhostTap *ghostTaps [[buffer(1)]]
) {
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);

    float2 uv = in.texCoord;

    // DEBUG STAGE 1: Just sample source texture (should match passthrough)
    #if DEBUG_STAGE == 1
    return sourceTexture.sample(texSampler, uv);
    #endif

    // === 1. KEN BURNS TRANSFORM ===
    // Apply scale around center
    float2 center = float2(0.5, 0.5);
    float2 centered = uv - center;
    centered /= uniforms.kenBurnsScale;
    // Apply offset (normalized, convert to UV space)
    centered -= float2(uniforms.kenBurnsOffsetX, uniforms.kenBurnsOffsetY) * 0.05;  // scale down offset
    uv = centered + center;

    // DEBUG STAGE 2: Ken Burns only
    #if DEBUG_STAGE == 2
    uv = clamp(uv, float2(0.001), float2(0.999));
    return sourceTexture.sample(texSampler, uv);
    #endif

    // === 2. DREAMY DISTORTION (Turbulence) ===
    // XorDev's layered sine wave turbulence — organic fluid motion
    float2 displacement = turbulence_distort(uv * 3.0, uniforms.time, uniforms.distortionSpeed)
                        * uniforms.distortionAmplitude;
    uv += displacement;

    // Clamp UV to valid range
    uv = clamp(uv, float2(0.001), float2(0.999));

    // Sample source texture (current image) and previous texture
    half4 sourceColor = sourceTexture.sample(texSampler, uv);
    half4 prevColor = previousTexture.sample(texSampler, uv);

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
        saliencyValue = saliencyTexture.sample(texSampler, in.texCoord).r;
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
    half3 colorBlended = shiftedRgb * (originalLuma / max(shiftedLuma, 0.001h));
    colorBlended = clamp(colorBlended, 0.0h, 1.0h);

    // Contrast boost
    half3 contrasted = (colorBlended - 0.5h) * half(uniforms.contrastBoost) + 0.5h;
    contrasted = clamp(contrasted, 0.0h, 1.0h);

    // Saturation boost
    half contrastedLuma = dot(contrasted, half3(0.299h, 0.587h, 0.114h));
    half3 saturated = mix(half3(contrastedLuma), contrasted, half(uniforms.saturationBoost));
    saturated = clamp(saturated, 0.0h, 1.0h);

    // Mix with original based on blend amount
    half3 currentColor = mix(color.rgb, saturated, half(uniforms.hueBlendAmount));

    // === 4. GHOST TAPS - Discrete Delay Echoes ===
    // Each ghost tap spawns at the image, animates outward, and fades.
    // Multiple taps flow in similar directions, creating streaming trails.
    // Loop only over active taps (packed at front) to avoid branch divergence.
    // IMPORTANT: Skip ghost taps during transitions - they sample sourceTexture (new image)
    // which would bleed through before the crossfade completes.
    int tapCount = (uniforms.transitionProgress > 0.001) ? 0 : int(uniforms.ghostTapCount);
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

    return half4(currentColor, 1.0h);
}
