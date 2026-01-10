#include <metal_stdlib>
using namespace metal;

// MARK: - Simplex Noise (2D)
// Based on Stefan Gustavson's implementation

float3 mod289(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float2 mod289(float2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 permute(float3 x) {
    return mod289(((x * 34.0) + 1.0) * x);
}

float snoise(float2 v) {
    const float4 C = float4(
        0.211324865405187,   // (3.0 - sqrt(3.0)) / 6.0
        0.366025403784439,   // 0.5 * (sqrt(3.0) - 1.0)
        -0.577350269189626,  // -1.0 + 2.0 * C.x
        0.024390243902439    // 1.0 / 41.0
    );

    // First corner
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);

    // Other corners
    float2 i1;
    i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;

    // Permutations
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));

    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;

    // Gradients
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    // Compute final noise value at P
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// MARK: - Fractal Brownian Motion

float fbm(float2 p, float time, int octaves, float lacunarity, float persistence) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;

    // Slowly rotate the noise field over time for organic movement
    float angle = time * 0.1;
    float2x2 rot = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));

    for (int i = 0; i < octaves; i++) {
        // Add time-based offset for animation
        float2 animatedP = p * frequency + float2(time * 0.05, time * 0.03);
        animatedP = rot * animatedP;

        value += amplitude * snoise(animatedP);
        frequency *= lacunarity;
        amplitude *= persistence;
    }

    return value;
}

// MARK: - SwiftUI Distortion Effect
// Creates organic, flowing displacement like underwater or heat haze

[[stitchable]] float2 dreamyDistortion(
    float2 position,
    float4 bounds,
    float time,
    float amplitude,
    float frequency,
    float speed
) {
    // Normalize position to 0-1 range
    float2 uv = position / bounds.zw;

    // Scale UV for noise sampling
    float2 noiseCoord = uv * frequency;

    // Get fBM displacement (5 octaves for nice detail)
    float noiseX = fbm(noiseCoord, time * speed, 5, 2.0, 0.5);
    float noiseY = fbm(noiseCoord + float2(100.0, 100.0), time * speed, 5, 2.0, 0.5);

    // Apply displacement
    float2 displacement = float2(noiseX, noiseY) * amplitude * bounds.zw;

    return position + displacement;
}

// MARK: - Hue Rotation Color Effect
// Slowly shifts all colors through the spectrum

[[stitchable]] half4 hueShift(
    float2 position,
    half4 color,
    float shift
) {
    // Convert RGB to HSV
    half4 K = half4(0.0h, -1.0h / 3.0h, 2.0h / 3.0h, -1.0h);
    half4 p = mix(half4(color.bg, K.wz), half4(color.gb, K.xy), step(color.b, color.g));
    half4 q = mix(half4(p.xyw, color.r), half4(color.r, p.yzx), step(p.x, color.r));

    half d = q.x - min(q.w, q.y);
    half e = 1.0e-10h;
    half3 hsv = half3(abs(q.z + (q.w - q.y) / (6.0h * d + e)), d / (q.x + e), q.x);

    // Rotate hue
    hsv.x = fract(hsv.x + half(shift));

    // Convert back to RGB
    half4 K2 = half4(1.0h, 2.0h / 3.0h, 1.0h / 3.0h, 3.0h);
    half3 p2 = abs(fract(hsv.xxx + K2.xyz) * 6.0h - K2.www);
    half3 rgb = hsv.z * mix(K2.xxx, clamp(p2 - K2.xxx, 0.0h, 1.0h), hsv.y);

    return half4(rgb, color.a);
}

// MARK: - Breathing Wave Effect
// Subtle sine wave displacement for "breathing" feel

[[stitchable]] float2 breathingWave(
    float2 position,
    float4 bounds,
    float time,
    float amplitude,
    float frequency
) {
    float2 uv = position / bounds.zw;

    // Create gentle wave pattern
    float wave = sin(uv.x * frequency + time) * cos(uv.y * frequency * 0.7 + time * 0.8);

    float2 displacement = float2(
        wave * amplitude * bounds.z,
        wave * amplitude * bounds.w * 0.5
    );

    return position + displacement;
}
