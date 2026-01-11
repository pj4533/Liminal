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

// MARK: - fBM for distortion

float fbm_distort(float2 p, float time, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float lacunarity = 2.0;
    float persistence = 0.5;

    float angle = sin(time * 0.03) * 0.5 + sin(time * 0.017) * 0.3;
    float2x2 rot = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));

    for (int i = 0; i < octaves; i++) {
        float2 animatedP = p * frequency + float2(
            sin(time * 0.02) * 2.0 + sin(time * 0.013) * 1.5,
            cos(time * 0.015) * 2.0 + cos(time * 0.021) * 1.5
        );
        animatedP = rot * animatedP;
        value += amplitude * snoise2d(animatedP);
        frequency *= lacunarity;
        amplitude *= persistence;
    }

    return value;
}

// MARK: - Uniforms

struct EffectsUniforms {
    float time;
    float kenBurnsScale;
    float2 kenBurnsOffset;      // normalized -1 to 1
    float distortionAmplitude;
    float distortionSpeed;
    float hueBaseShift;
    float hueWaveIntensity;
    float hueBlendAmount;
    float contrastBoost;
    float saturationBoost;
    float feedbackAmount;       // 0 = no trails, 1 = full trails
    float feedbackZoom;         // slight zoom on feedback (1.0 = no zoom)
    float feedbackDecay;        // darken feedback each frame
    float saliencyInfluence;    // how much saliency affects hue (0 = none, 1 = full)
    float hasSaliencyMap;       // 1.0 if saliency map available, 0.0 otherwise
};

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

fragment half4 effectsFragment(
    VertexOut in [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]],
    texture2d<half> feedbackTexture [[texture(1)]],
    texture2d<half> saliencyTexture [[texture(2)]],
    constant EffectsUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);

    float2 uv = in.texCoord;

    // === 1. KEN BURNS TRANSFORM ===
    // Apply scale around center
    float2 center = float2(0.5, 0.5);
    float2 centered = uv - center;
    centered /= uniforms.kenBurnsScale;
    // Apply offset (normalized, convert to UV space)
    centered -= uniforms.kenBurnsOffset * 0.05;  // scale down offset
    uv = centered + center;

    // === 2. DREAMY DISTORTION (fBM) ===
    float2 noiseCoord = uv * 3.0;  // frequency
    float noiseX = fbm_distort(noiseCoord, uniforms.time * uniforms.distortionSpeed, 5);
    float noiseY = fbm_distort(noiseCoord + float2(100.0, 100.0), uniforms.time * uniforms.distortionSpeed, 5);
    float2 displacement = float2(noiseX, noiseY) * uniforms.distortionAmplitude;
    uv += displacement;

    // Clamp UV to valid range
    uv = clamp(uv, float2(0.001), float2(0.999));

    // Sample source texture
    half4 color = sourceTexture.sample(texSampler, uv);

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

    // === 4. FEEDBACK TRAILS - Drifting Echoes ===
    float2 feedbackUV = in.texCoord;
    float2 fbCenter = float2(0.5, 0.5);
    float2 fbCentered = feedbackUV - fbCenter;

    // DIRECTIONAL DRIFT - trails expand outward
    // Tighter spacing but still visible movement
    float driftAngle = uniforms.time * 0.12 + sin(uniforms.time * 0.07) * 2.0;
    float driftMagnitude = 0.03 * uniforms.feedbackAmount;  // moderate drift
    float2 drift = float2(cos(driftAngle), sin(driftAngle)) * driftMagnitude;

    // Rotation for spiral effect - aggressive
    float rotation = sin(uniforms.time * 0.15) * 0.08 + sin(uniforms.time * 0.23) * 0.04;
    float cosR = cos(rotation);
    float sinR = sin(rotation);
    float2 rotated = float2(
        fbCentered.x * cosR - fbCentered.y * sinR,
        fbCentered.x * sinR + fbCentered.y * cosR
    );

    // Zoom for depth - more aggressive
    rotated *= uniforms.feedbackZoom;

    // Apply drift AFTER rotation/zoom so echoes visibly separate
    feedbackUV = rotated + fbCenter + drift;
    feedbackUV = clamp(feedbackUV, float2(0.001), float2(0.999));

    half4 feedback = feedbackTexture.sample(texSampler, feedbackUV);

    // Check if feedback has any content (not black)
    half feedbackBrightness = dot(feedback.rgb, half3(0.299h, 0.587h, 0.114h));

    // Only blend if we have feedback content AND feedbackAmount > 0
    if (uniforms.feedbackAmount > 0.001 && feedbackBrightness > 0.01h) {
        // Transparency fade: reduce blend amount rather than darkening RGB
        // This makes ghosts transparent rather than dim
        half effectiveAmount = half(uniforms.feedbackAmount * uniforms.feedbackDecay);

        // Blend: ghosts at full brightness but reduced opacity (via blend amount)
        half3 trailsBlended = mix(currentColor, feedback.rgb, effectiveAmount);
        currentColor = trailsBlended;
    }

    return half4(currentColor, 1.0h);
}
