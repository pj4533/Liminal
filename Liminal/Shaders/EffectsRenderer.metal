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

// Double-angle octave recurrence for the flowing variant (Round 2b, noise-double-angle).
// Octave j of nishitsujiNoiseFlowing needs sin(pos*2^j) and cos(pos*2^j); the component swizzles
// only permute them, so one sin/cos of pos gives every octave via sin 2a = 2 sin a cos a,
// cos 2a = 1 - 2 sin^2 a. s1 = sin(pos), c1 = cos(pos).
#define DBL(S,C) { half3 _t = 2.0h * S * C; C = 1.0h - 2.0h * S * S; S = _t; }
static inline half flowOctaves(half3 s1, half3 c1, int octaves) {
    half e = 0.0h;
    half w = 1.0h;
    for (int j = 0; j < octaves; j++) {
        e += sin(dot(s1.zxy - 0.5h, 1.0h - c1.yxz)) * w;
        DBL(s1, c1)
        w *= 0.5h;
    }
    return e;
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

    // 6-octave sinusoidal noise in half precision (Apple GPU runs FP16 at 2x rate).
    // One sin/cos of p; octaves 2..6 by double-angle recurrence (flowOctaves, logsphere-double-angle).
    half e = p.y - 1.0h;
    e += flowOctaves(sin(p), cos(p), 6);

    // UV displacement along radial direction (back to float for UV math).
    // centered / R == (cos(angle), sin(angle)); atan2(0,0) == 0, so (1,0) at the exact centre.
    float ef = float(e);
    // Periphery mask (docs/decisions/effects-balance.md): the centre of the source image, where a
    // photo's subject usually is, is left alone; the kaleidoscope lives in the periphery.
    float displacement = ef * intensity * smoothstep(0.10, 0.42, R);
    float2 offset = (R > 1.0e-6 ? centered / R : float2(1.0, 0.0)) * displacement;

    return float3(offset, ef);
}

// MARK: - Chroma helpers (vibrance; docs/decisions/vibrance.md)
// All colour math runs on gamma-encoded sRGB values (the shader never linearises; see V1).
// "Chroma" here is max-min of RGB: cheap, hue-agnostic, and what an RGB average destroys.

constant half3 LUMA_W = half3(0.299h, 0.587h, 0.114h);

static inline half chromaOf(half3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

// Scale chroma about luma l by g, then fit into [0,1]: gamutFit(l + (c - l) * g, l).
// hi/lo are c's max/min channel, already known to the caller. For g >= 0 the scaled colour's
// extremes are l + (hi - l) * g and l + (lo - l) * g, so they are not re-derived from the
// scaled colour (one max/min analysis per colour instead of two). Hue and luma are unchanged.
static inline half3 scaleChromaFit(half3 c, half l, half hi, half lo, half g) {
    half k = min(1.0h, min((1.0h - l) / max((hi - l) * g, 1.0e-4h),
                           l / max((l - lo) * g, 1.0e-4h)));
    return l + (c - l) * (g * k);
}

// Raise chroma toward `target` (never lower it), luma-preserving and gamut-safe.
// Used after RGB mixes of differently-hued colours, which otherwise pass through grey.
// target is a convex combination of the inputs' chroma, so it can never over-saturate
// (and the feedback loop cannot run away). The 0.02 floor keeps grey noise grey.
static inline half3 restoreChroma(half3 c, half target, half maxGain) {
    half l = dot(c, LUMA_W);
    half hi = max(c.r, max(c.g, c.b));
    half lo = min(c.r, min(c.g, c.b));
    half g = clamp(target / max(hi - lo, 0.02h), 1.0h, maxGain);
    return scaleChromaFit(c, l, hi, lo, g);
}

// MARK: - Shader variants (template parameter of shadeEye; docs/decisions/footage-fx.md F11)
constant int VARIANT_FOOTAGE = 1;   // archive footage blend looks (effectsFragment*Video)
constant int VARIANT_KEYS = 2;      // + keys, Kaleido, Palette, Print (effectsFragment*VideoKeys)
constant int VARIANT_DRIVES = 4;    // + the composite drives (effectsFragment*VideoDrives); 7 = keys and drives (*VideoFX)
constant int VARIANT_GLASS = 8;     // + the drives that move the picture's samples: Undertow and Fringe
                                    // (*VideoGlass; 11, 13, 15 the crossfade fallbacks; round 2, decision F25)

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
    // Image transition (docs/plans/transitions.md 9.1). All 0 outside a transition.
    float txStyle;              // TransitionStyle raw value (TX_* below; 0 = classic dissolve)
    float txMix;                // swap progress M, 0...1
    float txEnv;                // envelope E, 0...1
    float txSeed;               // 0...1: direction, centre, wedge count, channel order
    float txSoft;               // swap mask edge softness; negative = reversed order
    float txAmount;             // style amount: Prism stagger, fold, swirl angle, wave, lens, ring, tone fold, drip
    // Archive footage (docs/plans/archive-video.md 2.2). All 0 when no footage is showing.
    float videoMix;             // envelope x look ceiling; 0 = stage skipped
    float videoLook;            // VIDEO_* below
    float videoSeed;            // 0...1: drift direction, region shape
    float videoScale;           // footage size relative to the frame (1 = cover fit)
    float videoAspect;          // (footage w/h) / display aspect
    float videoTintR, videoTintG, videoTintB;     // highlight colour
    float videoShadeR, videoShadeG, videoShadeB;  // shadow colour (duotone looks)
    // Footage as crossfading pieces (docs/decisions/archive-video.md A27). Layer A = the fields above
    // (texture 7), layer B = the *B fields (texture 8); videoMixB 0 = layer B skipped.
    float videoWarp;            // share of the picture's warp layer A rides
    float videoMixB;
    float videoLookB;
    float videoSeedB;
    float videoScaleB;
    float videoAspectB;
    float videoWarpB;
    // Footage interaction modes (docs/plans/footage-fx.md 6; appended last). Per layer: which effect the
    // film drives (FD_*) and how much (0...1, the piece's envelope included), and where it may show (FK_*;
    // the sign of the key amount is the polarity / fold kind, its size the fold strength).
    float videoDrive;
    float videoDriveAmt;
    float videoKey;
    float videoKeyAmt;
    float videoDriveB;
    float videoDriveAmtB;
    float videoKeyB;
    float videoKeyAmtB;
    float tunnelStrength;
    float outgoingZoomScale;
};

// One footage layer of the composite (A or B).
struct VideoLayerParams {
    float mix, look, seed, scale, aspect, warp, drive, driveAmt, key, keyAmt;
};

// VideoLook raw values (VideoComposite.swift). NONE: the layer has no carrier, only its drive.
constant int VIDEO_NONE = 0;
constant int VIDEO_PHANTOM = 1;
constant int VIDEO_IMPRINT = 2;
constant int VIDEO_WINDOW = 3;
[[maybe_unused]] constant int VIDEO_EMERGE = 4;
constant int VIDEO_PALETTE = 5;
constant int VIDEO_PRINT = 6;
constant int VIDEO_POSTER = 7;   // round 2: the picture posterised in bands the film shifts (Poster)

// FootageDrive raw values (VideoComposite.swift): the effect the film steers.
constant int FD_UNDERTOW = 1;   // the film's figure bends and shifts the picture's UVs (glass)
constant int FD_FRINGE = 2;     // the film as a contour map; its edges split the picture's colours (glass)
constant int FD_WAKE = 3;       // the film's motion feeds the trails and ghost taps
constant int FD_AURORA = 4;     // the film's tones rotate the hue waves
constant int FD_SOLAR = 5;      // the film's highlights fold the tone curve
constant int FD_RELIEF = 6;     // the film embossed into the picture
constant int FD_GLOW = 7;       // the film projected as light and shade; its highlights swell the bloom
// FootageKey raw values: where the film may show.
constant int FK_SHADOW = 1;     // the picture's shadows (key amount > 0) or highlights (< 0)
constant int FK_BACKDROP = 2;   // far depth, behind the subject (visionOS: a depth map is bound)
constant int FK_KALEIDO = 3;    // the film's own UVs folded into 6 (> 0) or 8 (< 0) wedges
// Maxima at drive amount 1 (the CPU scales the amount by intensity and the clarity cycle).
constant float FD_UNDERTOW_MAX = 0.040;   // UV (the water itself is 0.028-0.058 at the default intensity)
constant float FD_FRINGE_MAX = 0.030;     // UV (today's radial fringing reaches about 0.01 at the frame edge)
constant half FD_AURORA_MAX = 0.42h;      // hue turns per unit of film tone offset
constant half FD_RELIEF_MAX = 1.0h;

// TransitionStyle raw values (ImageTransition.swift)
constant int TX_CLASSIC = 0;
constant int TX_TIDE = 1;
constant int TX_FACETS = 2;
constant int TX_PRISM = 3;
constant int TX_RAINBOW = 4;
constant int TX_KALEIDOSCOPE = 5;
constant int TX_WHIRLPOOL = 6;
constant int TX_DIVE = 7;
[[maybe_unused]] constant int TX_AFTERIMAGE = 8;   // whole-frame swap; its trails do the dissolving
constant int TX_RIPPLE = 9;
constant int TX_SOLARIZE = 10;
constant int TX_MELT = 11;
constant int TX_SHATTER = 12;

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

// Stage A output: the distorted UV plus the fields a transition's swap mask is ordered by.
// Only one extra float crosses into Stage B (more live state there costs occupancy outside transitions).
struct WarpOut {
    float2 uv;
    float field;     // swap order of the flow / crystal / UV-move styles; flow term for the others
};

// Leave the center and outer frame stable, concentrating motion in the periphery.
static inline float tunnelBand(float2 fromCenter, float radius) {
    float edge = max(abs(fromCenter.x), abs(fromCenter.y));
    return smoothstep(0.13, 0.40, radius) * (1.0 - smoothstep(0.35, 0.50, edge));
}

// Drive the outward wave with the crop itself. With this phase and amplitude
// the displacement only grows as zoom advances, then holds with the image.
static inline float2 tunnelOffset(float2 radial, float radius, float scale, float strength) {
    float progress = clamp((scale - 1.035) / (1.32 - 1.035), 0.0, 1.0);
    float flow = 0.72 + 0.28 * sin(radius * 25.0 - 2.0 * progress);
    return radial * (strength * progress * tunnelBand(radial, radius) * flow);
}

// Stage A: Ken Burns + transition UV move + turbulence + log-spherical + sinusoidal noise, through
// the UV clamp. Depends only on texCoord and uniforms, so both stereo eyes share the result.
static inline WarpOut distortedUV(float2 texCoord, constant EffectsUniforms &uniforms, texture2d<half> depthTexture) {
    WarpOut o;
    o.field = 0.5;
    float crystal = 0.0;
    float2 uv = texCoord;

    // === 1. KEN BURNS TRANSFORM ===
    // Apply scale around center
    float2 center = float2(0.5, 0.5);
    float2 centered = uv - center;
    centered /= uniforms.kenBurnsScale;
    // Apply offset (normalized, convert to UV space)
    centered -= float2(uniforms.kenBurnsOffsetX, uniforms.kenBurnsOffsetY) * 0.05;  // scale down offset
    uv = centered + center;

    if (uniforms.tunnelStrength > 0.0) {
        float2 radial = texCoord - center;
        uv -= tunnelOffset(radial, length(radial), uniforms.kenBurnsScale, uniforms.tunnelStrength);
    }

    // === 1.5 TRANSITION UV MOVES (docs/plans/transitions.md 6) ===
    // Kaleidoscope, Whirlpool, Tide, Facets, Ripple and Melt move UVs here; txEnv is 0 outside a transition.
    if (uniforms.txEnv > 0.0) {
        int style = int(uniforms.txStyle + 0.5);
        if (style == TX_KALEIDOSCOPE) {
            // Mirror-fold into 6 or 8 wedges about the view centre; the UV is pulled toward its
            // folded position (a position mix stays continuous where an angle mix would tear).
            float2 c = uv - 0.5;
            float r = length(c);
            float wedge = 6.2831853 / (uniforms.txSeed < 0.5 ? 6.0 : 8.0);
            float rot = uniforms.txSeed * 6.2831853;
            float f = fract((atan2(c.y, c.x) + rot) / wedge);
            float tri = 1.0 - abs(f - 0.5) * 2.0;            // 0 on the seams, 1 mid-wedge
            float af = wedge * 0.5 * (1.0 - tri) - rot;       // mirrored angle, continuous
            float cs;
            float sn = sincos(af, cs);
            float2 folded = 0.5 + r * float2(cs, sn);
            uv = mix(uv, folded, uniforms.txEnv * uniforms.txAmount);
            o.field = 0.65 * tri + 0.35 * saturate(r * 1.6);
        } else if (style == TX_WHIRLPOOL) {
            // Swirl about a seeded point, strongest at the centre (Gaussian falloff).
            float2 c0 = 0.5 + 0.36 * (float2(fract(uniforms.txSeed * 7.13), fract(uniforms.txSeed * 3.71)) - 0.5);
            float2 d = uv - c0;
            float r = length(d);
            float ang = uniforms.txAmount * uniforms.txEnv * exp(-r * r * 5.0);
            float cs;
            float sn = sincos(ang, cs);
            uv = c0 + float2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
            o.field = saturate(r / 0.65);
        } else if (style == TX_TIDE) {
            // A breaking wave rolls across the frame along the seed direction and leaves the new
            // picture behind it: the front is where the swap mask is (same threshold as swapWeight).
            float a = uniforms.txSeed * 6.2831853;
            float2 dir = float2(cos(a), sin(a));
            float2 perp = float2(-dir.y, dir.x);
            float along = dot(texCoord - 0.5, dir);
            float s = max(abs(uniforms.txSoft), 0.02);
            float th = mix(-s, 1.0 + s, uniforms.txMix);
            float front = uniforms.txSoft < 0.0 ? 0.85 - 1.7 * th : -0.85 + 1.7 * th;
            float x = (along - front) * 3.5;
            float k = uniforms.txAmount * uniforms.txEnv * exp(-x * x);
            float across = dot(uv, perp);
            uv -= dir * (k * (0.6 + 0.4 * sin(across * 13.0 + uniforms.time * 1.3 + uniforms.txSeed * 20.0)));
            uv += perp * (0.5 * k * sin(along * 24.0 - uniforms.time * 2.0));
            o.field = (along + 0.85) / 1.7;
        } else if (style == TX_FACETS) {
            // A compound eye: the picture breaks into hexagonal lenses. Each lens first flattens to
            // its centre colour (a hex mosaic), then shows its patch inverted and magnified; the
            // lenses exchange one by one, in a random order loosely from the centre out.
            float n = 6.0 + 4.0 * fract(uniforms.txSeed * 3.3);
            float2 p = (uv - 0.5) * n;
            const float2 hs = float2(1.0, 1.7320508);
            float4 hc = floor(float4(p, p - float2(0.5, 1.0)) / hs.xyxy) + 0.5;
            float2 ca = hc.xy * hs, cb = (hc.zw + 0.5) * hs;
            float2 cell = dot(p - ca, p - ca) < dot(p - cb, p - cb) ? ca : cb;
            float2 lens = 0.5 + (cell - 1.6 * (p - cell)) / n;
            uv = mix(uv, lens, uniforms.txAmount * uniforms.txEnv);
            float h = fract(sin(dot(cell, float2(12.9898, 78.233))) * 43758.5453);
            o.field = 0.6 * h + 0.4 * saturate(length(cell) / n * 1.6);
        } else if (style == TX_RIPPLE) {
            // A drop in a pond: rings travel out from a seeded point; the new picture rides the front.
            float2 c0 = 0.5 + 0.30 * (float2(fract(uniforms.txSeed * 5.17), fract(uniforms.txSeed * 9.31)) - 0.5);
            float2 d = uv - c0;
            float r = length(d);
            float ring = sin(r * 30.0 - uniforms.time * 6.0) * smoothstep(0.0, 0.05, r);
            uv += d / max(r, 0.001) * (uniforms.txAmount * uniforms.txEnv * ring);
            o.field = saturate(r / 0.75) + 0.08 * ring;   // the front follows the rings
        } else if (style == TX_MELT) {
            // The picture drips downward in uneven columns; the new one arrives from the top down.
            // Narrow drips (powered sine peaks) on a slower sag; the stretch grows down the frame.
            float x = uv.x + uniforms.txSeed * 3.0;
            float p1 = 0.5 + 0.5 * sin(x * 31.0), p2 = 0.5 + 0.5 * sin(x * 13.0 + 2.0);
            p1 *= p1; p1 *= p1 * p1;
            p2 *= p2; p2 *= p2;
            float n = saturate(p1 + 0.6 * p2);
            float drop = uniforms.txAmount * uniforms.txEnv * (0.15 + 0.85 * n) * (0.3 + 0.7 * texCoord.y);
            uv.y -= drop;
            o.field = 0.2 + 0.65 * texCoord.y - 0.35 * (n - 0.5);
        }
    }

    // === 2. DREAMY DISTORTION (Turbulence) ===
    // XorDev's layered sine wave turbulence — organic fluid motion
    float2 flow = turbulence_distort(uv * 3.0, uniforms.time, uniforms.distortionSpeed);
    float2 displacement = flow * uniforms.distortionAmplitude;
    uv += displacement;

    // === 2.5 LOG-SPHERICAL DISTORTION (Nishitsuji signature technique) ===
    // Kaleidoscopic warping through log-polar fractal space
    if (uniforms.logSphereAmount > 0.00002) {  // amounts pass through 0 without a pop
        float3 fractalResult = logSphericalTransform(
            uv, uniforms.time, uniforms.logSphereAmount
        );
        uv += fractalResult.xy;
    }

    // === 2.7 SINUSOIDAL INTERFERENCE NOISE (Nishitsuji crystalline distortion) ===
    // Refracting, prismatic texture — complements XorDev's smoky turbulence
    if (uniforms.fractalNoiseAmount > 0.00002) {  // amounts pass through 0 without a pop
        half3 noisePos = half3(half2(uv * 6.0), half(fmod(uniforms.time * 0.15, 6.2831853)));
        // One sin/cos of noisePos; octaves by double-angle recurrence (flowOctaves), and the second
        // field (noisePos + (17, 31, 7)) by angle addition with ks/kc = sin/cos(17, 31, 7).
        half3 ns = sin(noisePos), nc = cos(noisePos);
        const half3 ks = half3(-0.961397h, -0.404038h, 0.656987h);
        const half3 kc = half3(-0.275163h,  0.914742h, 0.753902h);
        float noiseX = float(flowOctaves(ns, nc, 5));
        float noiseY = float(flowOctaves(ns * kc + nc * ks, nc * kc - ns * ks, 5));
        float amount = uniforms.fractalNoiseAmount;
        uv += float2(noiseX, noiseY) * amount;
        crystal = noiseX;
    }

    // Swap order fields that come from this stage (docs/plans/transitions.md 5).
    if (uniforms.transitionProgress > 0.0) {
        int style = int(uniforms.txStyle + 0.5);
        float seedAng = uniforms.txSeed * 6.2831853;
        float2 dir = float2(cos(seedAng), sin(seedAng));
        float fd = clamp(dot(flow, dir), -1.0, 1.0);
        if (style == TX_TIDE) {
            o.field += 0.05 * fd;   // a ragged wave front
        } else if (style == TX_PRISM) {
            // A light sweep across the frame along the split direction, loosened by the flow.
            o.field = 0.5 + 0.7 * dot(texCoord - 0.5, dir) + 0.25 * fd;
        } else if (style == TX_SHATTER) {
            o.field = fract(floor(crystal * 3.0 + uniforms.txSeed * 7.0) * 0.618034 + uniforms.txSeed);
        } else if (style == TX_RAINBOW) {
            // A sweep across the frame, banded by the strongest terms of the hue-wave field.
            float t = uniforms.time;
            float bands = sin(uv.x * 2.0 + t * 0.2) + 0.6 * sin(uv.x * 5.0 - t * 0.15)
                        + 0.8 * sin(uv.y * 3.0 + t * 0.18) + 0.7 * sin((uv.x + uv.y) * 4.0 + t * 0.12);
            o.field = 0.55 * (0.5 + dot(texCoord - 0.5, dir)) + 0.45 * (0.5 + 0.5 * sin(bands * 1.7));
        } else if (style == TX_DIVE) {
            o.field = length(texCoord - 0.5) * 1.4 + 0.15 * fd;   // the centre first, ragged: out the far side of the tunnel
        } else if (style != TX_KALEIDOSCOPE && style != TX_WHIRLPOOL && style != TX_RIPPLE && style != TX_MELT
                   && style != TX_FACETS) {
            // Flow term that spreads orders whose values bunch up (a dark picture's luma), so the
            // whole frame never swaps in one frame.
            o.field = 0.5 + 0.5 * fd;
        }
    }

    // Clamp UV to valid range
    o.uv = clamp(uv, float2(0.001), float2(0.999));
    return o;
}

// Swap weight per channel (docs/plans/transitions.md 5): 0 = previous picture, 1 = new picture.
// m is the style's order field (which pixels go first; Stage A computes it for every style),
// swept by txMix with edge softness txSoft. Kept small and in half: the call sits in a uniform
// branch, but its registers count against every frame.
static inline half3 swapWeight(WarpOut warp, constant EffectsUniforms &uniforms) {
    int style = int(uniforms.txStyle + 0.5);
    if (style == TX_CLASSIC) return half3(half(uniforms.txMix));
    half m = saturate(half(warp.field));
    if (uniforms.txSoft < 0.0) m = 1.0h - m;
    half s = half(max(abs(uniforms.txSoft), 0.02));
    half c = style == TX_PRISM ? half(uniforms.txAmount) * (fract(uniforms.txSeed * 5.0) < 0.5 ? 1.0h : -1.0h) : 0.0h;
    half th = mix(-s - abs(c), 1.0h + s + abs(c), half(uniforms.txMix));
    return smoothstep(half3(m - s), half3(m + s), th + half3(c, 0.0h, -c));
}

// Archive footage tap (docs/plans/footage-fx.md 2.2): one stage sample per layer at the top of stage B,
// read by every hook (drives, keys, the carrier composite). The video texture is the pre-pass stage
// (ArchiveVideo.metal): r = levelled luma (frame-blended), g = slow average of r, b = motion, a = edge.
struct FootageTap {
    half4 v;
    float2 vuv;      // footage uv
    float2 d;        // aspect-correct offset from the footage centre (the looks' regions)
    float rag;       // ragged, flow-ordered region edge
    half feather;    // 14 % edge feather of the footage rectangle
};

// What the film steers this frame, summed over both layers (each term carries its layer's amount, which
// contains the piece's envelope, so pieces with different drives crossfade without a special case).
struct FootageDrive {
    half hue, hueBlend, solar, relief, wake, glow, lift;
};

// The film's figure for the drives (round 1, decision F21): mostly the levelled luma, a little of the slow
// average. The slow average alone (round 0) blurred moving figures into a haze nobody saw.
static inline half figureOf(half4 v) { return mix(v.g, v.r, 0.7h); }
// The calmer figure for what moves or lights the picture itself (Undertow, Relief, Glow): the levelled luma
// steps at the film's frame rate, which read as jitter on a dark, still picture.
static inline half figureSoftOf(half4 v) { return mix(v.g, v.r, 0.4h); }
// The calmest figure, for the glass that moves the picture's own samples (Undertow, round 2: a detailed picture
// behind a pane that jumps at the film's frame rate stepped over the 0.010 gate).
static inline half figureCalmOf(half4 v) { return mix(v.g, v.r, 0.2h); }

// The footage rides part of the picture's warp (per piece, 0.35-0.85: it swims with the water but stays
// legible as film) and drifts slowly on its own (less for the full-frame looks). uvA is the stage-A uv
// (before the per-eye parallax; on the mono paths that is exactly where the footage was always sampled).
template <bool kFX>
static inline float2 footageUV(float2 uvA, float2 texCoord, VideoLayerParams L, constant EffectsUniforms &u,
                               thread float2 &fuvOut, thread float2 &driftOut) {
    int look = int(L.look + 0.5);
    float seedA = L.seed * 6.2831853;
    float t = u.time;
    float2 fuv = mix(texCoord, uvA, L.warp);
    float driftAmt = (look == VIDEO_PHANTOM || look == VIDEO_WINDOW || look == VIDEO_PALETTE) ? 0.05 : 0.012;
    float2 drift = float2(sin(fmod(t * 0.031, 6.2831853) + seedA),
                          cos(fmod(t * 0.023, 6.2831853) + seedA * 1.7)) * driftAmt;
    // Cover fit of the footage's aspect on the 3:2 frame, then the look's size.
    float2 k = L.aspect < 1.0 ? float2(1.0, L.aspect) : float2(1.0 / L.aspect, 1.0);
    float2 vuv = 0.5 + (fuv - 0.5 - drift) * k / max(L.scale, 0.1);
    if (kFX && int(L.key + 0.5) == FK_KALEIDO) {
        // Kaleido: the film's own UVs mirror-folded into wedges about its centre (the Kaleidoscope
        // transition's fold), slowly turning; the picture is not folded. A partial fold keeps a hint
        // of the film's scene.
        float2 c = (vuv - 0.5) * float2(1.333, 1.0);
        float r = length(c);
        float wedge = 6.2831853 / (L.keyAmt < 0.0 ? 8.0 : 6.0);
        float rot = seedA + fmod(t * 0.02, 6.2831853);
        float f = fract((atan2(c.y, c.x) + rot) / wedge);
        float tri = 1.0 - abs(f - 0.5) * 2.0;
        float af = wedge * 0.5 * (1.0 - tri) - rot;
        float cs;
        float sn = sincos(af, cs);
        float2 folded = 0.5 + r * float2(cs, sn) / float2(1.333, 1.0);
        vuv = mix(vuv, folded, saturate(abs(L.keyAmt)));
    }
    fuvOut = fuv;
    driftOut = drift;
    return vuv;
}

static inline half featherOf(float2 vuv) {
    float2 e = smoothstep(float2(0.0), float2(0.14), vuv) * smoothstep(float2(0.0), float2(0.14), 1.0 - vuv);
    return half(e.x * e.y);
}

template <bool kFX>
static inline FootageTap tapFootage(float2 uvA, float2 texCoord, float field, texture2d<half> videoTexture,
                                    VideoLayerParams L, constant EffectsUniforms &u) {
    constexpr sampler vs(address::clamp_to_edge, filter::linear);
    float seedA = L.seed * 6.2831853;
    float t = u.time;
    float2 fuv, drift;
    float2 vuv = footageUV<kFX>(uvA, texCoord, L, u, fuv, drift);
    FootageTap o;
    o.v = videoTexture.sample(vs, vuv);
    o.feather = featherOf(vuv);
    o.vuv = vuv;
    // Ragged, flow-ordered mask edges (the transition field is 0.5 outside a transition).
    o.rag = 0.12 * (field - 0.5) + 0.03 * sin(fuv.x * 9.0 + fuv.y * 7.0 + seedA + fmod(t * 0.2, 6.2831853));
    o.d = (fuv - 0.5 - drift) * float2(1.5, 1.0);
    return o;
}

// The drives that move the picture's samples (Undertow and Fringe) must be known before the picture
// is sampled: a small tap of their own at the top of stage B. Only the two offsets and one shade stay live
// across the picture samples (keeping the whole tap live there cost 14 % in occupancy).
static inline bool isPreDrive(VideoLayerParams L) {
    int drive = int(L.drive + 0.5);
    return (drive == FD_UNDERTOW || drive == FD_FRINGE) && L.driveAmt > 0.0;
}

static inline void addPreDrive(thread float2 &uvOffset, thread float2 &chroma, VideoLayerParams L,
                               texture2d<half> videoTexture, float2 uvA, float2 texCoord, constant EffectsUniforms &u) {
    constexpr sampler vs(address::clamp_to_edge, filter::linear);
    int drive = int(L.drive + 0.5);
    float2 fuv, drift;
    float2 vuv = footageUV<false>(uvA, texCoord, L, u, fuv, drift);   // no recipe folds and drives at once
    half4 v = videoTexture.sample(vs, vuv);
    half a = half(L.driveAmt) * featherOf(vuv);
    if (drive == FD_UNDERTOW) {
        // The image bends around the film's shapes and ripples where the film moves (moving glass), and the
        // glass catches a slowly turning light along those shapes, so the film's figure reads as a pane.
        // A 5-texel stencil on the figure (round 1; round 0's 8 texels of the slow average was a haze).
        float2 px = float2(5.0 / 960.0, 5.0 / 720.0);
        half f0 = figureCalmOf(v);
        float2 gr = float2(float(figureCalmOf(videoTexture.sample(vs, vuv + float2(px.x, 0.0))) - f0),
                           float(figureCalmOf(videoTexture.sample(vs, vuv + float2(0.0, px.y))) - f0)) * 5.0;
        float gl = length(gr);
        gr *= min(gl, 1.0) / max(gl, 1.0e-3);
        // Round 2 (F24): the film's lights also shift the picture behind them along a slowly turning
        // direction (its darks the other way), so the whole figure reads as a pane of thick glass with
        // torn edges, not only its outlines.
        float sa = L.seed * 6.2831853 + fmod(u.time * 0.04, 6.2831853);
        float2 tone = float2(cos(sa), sin(sa)) * float(smoothstep(0.25h, 0.75h, f0) - 0.5h) * 0.45;
        uvOffset += (gr * (0.7 + 0.3 * float(saturate(v.b * 5.0h))) + tone) * (float(a) * FD_UNDERTOW_MAX);
    } else {
        // Prismatic outlines in the picture's colours along the film's contours.
        float2 r = uvA - 0.5;
        float rl = length(r);
        float2 dir = rl > 0.02 ? r / rl : float2(1.0, 0.0);
        float cs;
        float sn = sincos(L.seed * 6.2831853, cs);
        dir = float2(dir.x * cs - dir.y * sn, dir.x * sn + dir.y * cs);
        chroma += dir * float(v.a * a) * FD_FRINGE_MAX;
    }
}

// Adds one layer's drive to fd (docs/plans/footage-fx.md 3). Reads the film's figure (mostly the levelled,
// frame-blended luma: cuts and flashes are already softened there, as for the blend looks), its motion and
// its edges. Round 1 (decision F21): every drive also shows the film's shape, not only its tone.
template <bool kComp, bool kGlass>
static inline void addDrive(thread FootageDrive &fd, FootageTap tp, VideoLayerParams L,
                            texture2d<half> videoTexture, constant EffectsUniforms &u) {
    int drive = int(L.drive + 0.5);
    half a = half(L.driveAmt) * tp.feather;
    if (drive == 0 || a <= 0.0h) return;
    constexpr sampler vs(address::clamp_to_edge, filter::linear);
    half fig = figureOf(tp.v);
    half mot = saturate(tp.v.b * 5.0h);
    float seedA = L.seed * 6.2831853;
    if (kGlass && drive == FD_UNDERTOW) {
        // The pane catches a slowly turning light along the film's shapes (the bend itself is a pre-drive),
        // through Relief's light: no value stays live across the picture's samples and no field of its own.
        // Round 2: a stronger pane light, and its lit edge carries light of its own (dark pictures).
        float la = seedA + fmod(u.time * 0.05, 6.2831853);
        float2 ld = float2(cos(la), sin(la)) * float2(5.0 / 960.0, 5.0 / 720.0);
        half h = clamp((figureSoftOf(tp.v) - figureSoftOf(videoTexture.sample(vs, tp.vuv + ld))) * 7.0h, -1.0h, 1.0h);
        fd.relief += h * a * 0.8h;
        fd.lift += max(h, 0.0h) * a * 0.3h;
    } else if (kComp && drive == FD_WAKE) {
        // Where the film moves the picture lingers and smears, and the moving parts carry light, so the
        // film's movement is drawn into the picture as glowing trails (round 2: 0.25 -> 0.6, from 0.1 motion).
        fd.wake += mot * a;
        fd.lift += smoothstep(0.08h, 0.5h, mot) * (0.45h + 0.55h * fig) * a * 0.6h;
    } else if (kGlass && drive == FD_FRINGE) {
        // Round 2 (F24): the film drawn as a contour map, iso-lines of its soft figure at four levels,
        // as light on the picture's darks (the lift) and ink on its lights (a negative relief), plus its
        // sharp edges (their colour split is a pre-drive). The lines crawl as the film moves.
        half x = figureSoftOf(tp.v) * 4.0h + 0.5h;
        half dist = abs(fract(x) - 0.5h) / max(fwidth(x), 0.004h);
        half e = max(1.0h - smoothstep(1.6h, 4.5h, dist), smoothstep(0.10h, 0.40h, tp.v.a)) * a;
        fd.lift += e * 0.95h;
        fd.relief -= e * 0.7h;
    } else if (kComp && drive == FD_AURORA) {
        // Round 2: the film's lights and darks as two broad regions of rotated hue (the liked "magenta
        // regions"), a softer continuous term between, and the film's lights carry a little light of their
        // own, so the figure shows on a dark picture; luma is otherwise restored by the hue stage.
        half reg = smoothstep(0.35h, 0.65h, fig);
        fd.hue += ((reg - 0.5h) * 0.75h + (fig - 0.5h) * 0.5h) * a * FD_AURORA_MAX;
        fd.hueBlend += a * (0.45h + 0.4h * abs(reg - 0.5h) * 2.0h);
        fd.lift += reg * a * 0.22h;
    } else if (kComp && drive == FD_SOLAR) {
        fd.solar += smoothstep(0.36h, 0.60h, figureSoftOf(tp.v)) * a;   // calmer figure: the fold flashed
    } else if (kComp && drive == FD_RELIEF) {
        // A height difference along a slowly turning light: the film pressed into the picture's surface.
        // Round 2: a smoother height (more slow average: the old film's scan lines read as noise), a wider
        // step, and the lit side carries light so the relief shows on a dark picture.
        float la = seedA + fmod(u.time * 0.03, 6.2831853);
        float2 ld = float2(cos(la), sin(la)) * float2(6.0 / 960.0, 6.0 / 720.0);
        half h = clamp((figureCalmOf(tp.v) - figureCalmOf(videoTexture.sample(vs, tp.vuv + ld))) * 9.0h, -1.0h, 1.0h);
        fd.relief += h * a * FD_RELIEF_MAX;
        fd.lift += max(h, 0.0h) * a * 0.25h;
    } else if (kComp && drive == FD_GLOW) {
        // Round 2 (F24): the film is projected onto the picture as light and shade (chiaroscuro): where it
        // is bright the picture is lit and blooms, where it is dark the picture falls into shadow. Through
        // the relief's light (a gain on the processed colour) and the lift: no field of its own.
        half hl = smoothstep(0.30h, 0.80h, figureSoftOf(tp.v));
        fd.glow += hl * a * 0.5h;
        fd.relief += (hl - 0.35h) * a * 1.3h;
        fd.lift += hl * hl * a * 0.45h;
    }
}

// Where a layer may show: 1 everywhere for the looks' own masks; a luminance key of the picture
// (Shadowplay) or a depth key (Backdrop). Multiplies the carrier's mix.
static inline half footageKey(VideoLayerParams L, half3 c, float2 uv, texture2d<half> depthTexture) {
    int key = int(L.key + 0.5);
    if (key == FK_SHADOW) {
        half y = dot(c, LUMA_W);
        half w = half(saturate(L.keyAmt * 0.5 + 0.5));
        return mix(smoothstep(0.50h, 0.80h, y), 1.0h - smoothstep(0.08h, 0.32h, y), w);
    }
    if (key == FK_BACKDROP) {
        constexpr sampler ds(address::clamp_to_edge, filter::linear);
        return 1.0h - smoothstep(0.25h, 0.55h, depthTexture.sample(ds, uv).r);
    }
    return 1.0h;
}

// Archive footage carrier composite (docs/plans/archive-video.md 2.2, footage-fx.md 3.9 and 3.12). Called
// only inside a uniform branch on the layer's mix, right after the crossfade: everything downstream (hue
// waves, contrast, taps' host colour, feedback trails, vibrance) then acts on picture and footage together.
// Every look feathers the footage (edges and a flow-ordered mask), so no rectangle is ever visible.
// `key` multiplies the mix; a keyed layer (Shadowplay, Backdrop) drops the Window and Palette oval.
template <int kVideo>
static inline half3 compositeVideo(half3 c, FootageTap tp, VideoLayerParams L, half key, constant EffectsUniforms &u) {
    constexpr bool kFX = (kVideo & VARIANT_KEYS) != 0;
    int look = int(L.look + 0.5);
    if ((kVideo & (VARIANT_KEYS | VARIANT_DRIVES | VARIANT_GLASS)) != 0 && look == VIDEO_NONE) return c;
    float seedA = L.seed * 6.2831853;
    float t = u.time;
    int keyId = int(L.key + 0.5);
    bool keyed = kFX && (keyId == FK_SHADOW || keyId == FK_BACKDROP);
    half3 v = tp.v.rgb;
    half edge = tp.feather;
    half m = kFX ? half(L.mix) * key : half(L.mix);
    half luma = smoothstep(0.03h, 0.97h, v.r);   // a little film contrast
    half3 tint = half3(half(u.videoTintR), half(u.videoTintG), half(u.videoTintB));
    half3 shade = half3(half(u.videoShadeR), half(u.videoShadeG), half(u.videoShadeB));
    float rag = tp.rag;
    float2 d = tp.d;

    if (look == VIDEO_PHANTOM) {
        // What glows and moves shows, screen-blended in the picture's highlight colour, inside a soft
        // drifting oval: a projection on smoke.
        half oval = half(1.0 - smoothstep(0.32, 0.66, length(d) + rag));
        half hl = smoothstep(0.18h, 0.85h, luma);
        half mot = saturate(v.b * 5.0h);
        half a = hl * (0.55h + 0.45h * mot) * edge * oval * m;
        return 1.0h - (1.0h - c) * (1.0h - tint * a);
    } else if (look == VIDEO_IMPRINT) {
        // Soft light (Pegtop): the footage's tones shade the picture's own colours.
        half b = saturate(0.5h + (mix(luma, v.g, 0.25h) - 0.5h) * 2.2h);
        half3 sl = (1.0h - 2.0h * b) * c * c + 2.0h * b * c;
        return mix(c, sl, m * edge);
    } else if (look == VIDEO_WINDOW || (kFX && (look == VIDEO_PALETTE || look == VIDEO_PRINT))) {
        // A breathing, flow-edged region near the centre (or the key's area alone).
        float r0 = 0.40 + 0.04 * sin(fmod(t * 0.21, 6.2831853) + seedA);
        half wm = keyed ? 1.0h : half(1.0 - smoothstep(r0 - 0.18, r0 + 0.05, length(d) + rag));
        // Round 2: a keyed Window (Backdrop) shows the film as a near two-tone figure behind the subject.
        if (kFX && keyed && look == VIDEO_WINDOW) return mix(c, mix(shade, tint, smoothstep(0.25h, 0.75h, luma)), edge * m);
        if (!kFX || look == VIDEO_WINDOW) return mix(c, mix(shade, tint, luma), wm * edge * m);
        if (look == VIDEO_PALETTE) {
            half3 cs = restoreChroma(c, min(chromaOf(c) * 1.4h + 0.03h, 1.0h), 2.0h);
            // Round 2: near two-tone film (round 1: 0.14-0.86), so the film's shapes read as figures on a
            // bright picture where shade -> picture -> tint are close.
            // Kaleido's fold reads a calmer figure (half slow average): its hard ramp over the folded film flashed.
            half l2 = smoothstep(0.28h, 0.72h, keyId == FK_KALEIDO ? smoothstep(0.03h, 0.97h, mix(v.g, v.r, 0.5h)) : luma);
            if (keyId == FK_SHADOW) {
                // Shadowplay: shadow theatre. In the picture's shadows the film is a lit silhouette (its whites
                // in the tint), in its highlights it is ink (its blacks sink to the shade); the polarity eases
                // continuously. Round 2: hard-edged (0.40-0.60) so the figures read as cut shapes.
                half w = half(saturate(L.keyAmt * 0.5 + 0.5));
                half l3 = smoothstep(0.40h, 0.60h, luma);
                half3 lit = mix(cs, tint, l3);
                half3 inked = mix(shade, cs, l3);
                return mix(c, mix(inked, lit, w), edge * m);
            }
            // The film gradient-mapped through the picture: shade -> the picture's own colour (chroma
            // raised) -> tint. At the film's mid-grey the picture shows through unchanged.
            half3 ramp = l2 < 0.5h ? mix(shade, cs, l2 * 2.0h) : mix(cs, tint, l2 * 2.0h - 1.0h);
            return mix(c, ramp, wm * edge * m);
        }
        // Print: the film's slow average as halftone ink (or soft posterised bands, by seed) in the
        // picture's darkest colour. The grid lives in the footage's coordinates, so it swims with the film.
        half ink;
        half s = 1.0h - smoothstep(0.05h, 0.95h, mix(v.g, v.r, 0.7h));
        float ca = 0.8660254, sa = 0.5;   // 30 degrees
        float2 p = (tp.vuv - 0.5) * float2(1.333, 1.0) * 70.0;
        p = float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
        if (L.seed < 0.5) {
            float dist = length(fract(p) - 0.5);
            float rad = 0.68 * sqrt(float(s));
            float aa = max(fwidth(dist), 0.02);
            ink = half(1.0 - smoothstep(rad - aa, rad + aa, dist));
        } else {
            // Round 2: an engraving line screen (lines thicken with the film's darks, and bend with them)
            // replaced the posterised bands, which read as a plain blur (F24).
            float y = p.y + 0.35 * float(s);
            float dist = abs(fract(y) - 0.5);
            float aa = max(fwidth(y), 0.02);
            ink = half(1.0 - smoothstep(0.5 * float(s) - aa, 0.5 * float(s) + aa, dist));
        }
        // Round 1: the ink contrasts with what it lands on (the picture's darkest colour on its lights, a
        // lifted tint on its darks), so the print shows on a dark picture as well as a bright one.
        half3 inkCol = mix(min(tint * 0.85h + 0.12h, 1.0h), shade * 0.8h, smoothstep(0.12h, 0.40h, dot(c, LUMA_W)));
        return mix(c, inkCol, ink * wm * edge * m);
    }
    if (kFX && look == VIDEO_POSTER) {
        // Poster (round 2, F24; replaced Palette): the picture posterised into four flat bands of its own
        // colour, chroma raised, every other band pulled toward the tint; the film's figure shifts the band
        // thresholds, so the band edges follow and crawl with the film's shapes. Inside the flow-edged
        // region; the picture's forms survive as the bands.
        float r0 = 0.46 + 0.04 * sin(fmod(t * 0.21, 6.2831853) + seedA);
        half wm = half(1.0 - smoothstep(r0 - 0.20, r0 + 0.06, length(d) + rag));
        half y = dot(c, LUMA_W);
        half q = saturate(y * 0.85h + (mix(v.g, v.r, 0.6h) - 0.5h) * 0.7h + 0.08h) * 4.0h;
        half bnd = floor(q) + smoothstep(0.42h, 0.58h, fract(q));
        half ly = bnd * 0.25h;
        half3 cs = restoreChroma(c, min(chromaOf(c) * 1.5h + 0.06h, 1.0h), 2.0h);
        half3 pc = min(cs * ((ly + 0.03h) / (y + 0.03h)), 1.0h);
        half odd = abs(fract(bnd * 0.5h) - 0.5h) * 2.0h;   // 1 on even bands, 0 on odd ones
        pc = mix(pc, min(tint * (ly + 0.25h), 1.0h), odd * 0.5h);
        return mix(c, pc, wm * edge * m);
    }
    // Emerge: the footage takes the frame as a duotone; the picture stays as a quarter of the colour.
    half3 duo = mix(shade, tint, luma);
    return mix(c, mix(duo, duo * (0.6h + 0.8h * c), 0.25h), m * edge);
}

// Stage B: stereo parallax through the final colour. Everything that differs per eye lives here.
// kVideo: 0 = no footage (the plain fragments: exactly the shader without footage, bit-identical frames,
// no cost: docs/decisions/archive-video.md); 1 = footage blend looks only (effectsFragmentVideo /
// effectsFragmentStereoVideo: today's four looks at today's cost); | 2 keys and the new carriers (Kaleido,
// Shadowplay, Backdrop, Poster, Print), | 4 the composite drives, | 8 the glass drives (Undertow and Fringe).
// The renderers bind the bits a frame's layers need (VideoComposite.footageVariant): every hook adds
// registers that all frames of its variant pay for (docs/decisions/footage-fx.md F11, F25).
template <int kVideo>
static inline half4 shadeEye(
    WarpOut warp,
    float2 texCoord,
    float2 fragPos,
    float stereoOffset,
    texture2d<half> sourceTexture,
    texture2d<half> saliencyTexture,
    texture2d<half> previousTexture,
    texture2d<half> feedbackTexture,
    texture2d<half> depthTexture,
    texture2d<half> videoTexture,
    texture2d<half> videoTextureB,
    constant EffectsUniforms &uniforms,
    constant GhostTap *ghostTaps
) {
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);
    constexpr bool kAny = (kVideo & VARIANT_FOOTAGE) != 0;
    constexpr bool kKeys = (kVideo & VARIANT_KEYS) != 0;      // keys, Kaleido's fold, Palette and Print
    constexpr bool kDrives = (kVideo & VARIANT_DRIVES) != 0;  // the composite drives' hooks
    constexpr bool kGlass = (kVideo & VARIANT_GLASS) != 0;    // Undertow and Fringe (pre-drives + light)
    constexpr bool kLight = kDrives || kGlass;                // the lift and relief fields both groups use
    constexpr bool kFX = kKeys || kLight;
    float2 uv = warp.uv;

    // === 0. ARCHIVE FOOTAGE PRE-DRIVES (docs/plans/footage-fx.md 2.2) ===
    // kVideo only: Undertow bends the picture and Fringe splits it before it is sampled.
    VideoLayerParams la = {}, lb = {};
    bool hasA = false, hasB = false;
    float2 fdChroma = float2(0.0);
    if (kAny) {
        hasA = uniforms.videoMix > 0.0;
        hasB = uniforms.videoMixB > 0.0;
        la = { uniforms.videoMix, uniforms.videoLook, uniforms.videoSeed, uniforms.videoScale,
               uniforms.videoAspect, uniforms.videoWarp, uniforms.videoDrive, uniforms.videoDriveAmt,
               uniforms.videoKey, uniforms.videoKeyAmt };
        lb = { uniforms.videoMixB, uniforms.videoLookB, uniforms.videoSeedB, uniforms.videoScaleB,
               uniforms.videoAspectB, uniforms.videoWarpB, uniforms.videoDriveB, uniforms.videoDriveAmtB,
               uniforms.videoKeyB, uniforms.videoKeyAmtB };
    }
    if (kGlass) {
        float2 off = float2(0.0);
        if (hasA && isPreDrive(la)) addPreDrive(off, fdChroma, la, videoTexture, warp.uv, texCoord, uniforms);
        if (hasB && isPreDrive(lb)) addPreDrive(off, fdChroma, lb, videoTextureB, warp.uv, texCoord, uniforms);
        // Both layers together at most one cap.
        float ol = length(off);
        if (ol > 1.0e-6) uv = clamp(uv + off * (min(ol, FD_UNDERTOW_MAX) / ol), float2(0.001), float2(0.999));
    }

    // === STEREO DEPTH PARALLAX ===
    // Per-eye shift scaled by depth so near subjects separate more than distant background.
    if (abs(stereoOffset) > 0.000001) {
        constexpr sampler depthSampler(address::clamp_to_edge, filter::linear);
        float depthVal = float(depthTexture.sample(depthSampler, uv).r);  // 0=far, 1=near
        // d^0.75 == sqrt(d) * sqrt(sqrt(d)): two sqrts instead of pow's log2/exp2.
        float dClamped = clamp(depthVal, 0.0, 1.0);
        float dRoot = sqrt(dClamped);
        float boostedDepth = dRoot * sqrt(dRoot);
        float parallax = stereoOffset * boostedDepth;
        uv.x = clamp(uv.x + parallax, 0.001, 0.999);
    }

    // === CHROMATIC ABERRATION ===
    // Sample RGB channels at slightly offset UVs for prismatic fringing.
    // Radial: stronger at edges, zero at center.
    float2 chromOffset = (uv - 0.5) * uniforms.chromaticAmount;
    // Prism: a wide straight split along the seed direction plus a twist (red turns one way about
    // the centre, blue the other), on top of the radial fringing.
    if (int(uniforms.txStyle + 0.5) == TX_PRISM && uniforms.txEnv > 0.0) {
        float a = uniforms.txSeed * 6.2831853;
        float k = uniforms.txAmount * uniforms.txEnv;
        chromOffset += float2(cos(a), sin(a)) * (0.35 * k) + float2(0.5 - uv.y, uv.x - 0.5) * (0.7 * k);
    }
    if (kGlass) {
        // Fringe: the film's contours part the picture's red and blue (green, the luma detail, stays).
        float cl = length(fdChroma);
        if (cl > 1.0e-6) chromOffset += fdChroma * (min(cl, FD_FRINGE_MAX) / cl);
    }
    // Keep the old crop as its image fades out. Both samples share the live effects,
    // but the wider framing belongs only to the incoming image.
    float2 previousUV = uv;
    if (uniforms.outgoingZoomScale > 0.0) {
        float2 radial = texCoord - 0.5;
        float radius = length(radial);
        float zoomDelta = 1.0 / uniforms.outgoingZoomScale - 1.0 / uniforms.kenBurnsScale;
        float2 tunnelDelta = tunnelOffset(radial, radius, uniforms.kenBurnsScale, uniforms.tunnelStrength)
                           - tunnelOffset(radial, radius, uniforms.outgoingZoomScale, uniforms.tunnelStrength);
        previousUV = clamp(uv + radial * zoomDelta + tunnelDelta, float2(0.001), float2(0.999));
    }
    half4 prevColor = half4(
        previousTexture.sample(texSampler, previousUV + chromOffset).r,
        previousTexture.sample(texSampler, previousUV).g,
        previousTexture.sample(texSampler, previousUV - chromOffset).b,
        1.0h
    );

    // === GPU CROSSFADE BLENDING ===
    // Outside a transition previousTexture == sourceTexture (the renderers' fallback) and w = 0, so the
    // new picture is only sampled inside the transition branch (3 fewer samples on a normal frame).
    // Per pixel and channel, ordered by the transition style's field (swapWeight).
    half3 w = half3(0.0h);
    half4 color = prevColor;
    if (uniforms.transitionProgress > 0.0) {
        half3 sourceRGB = half3(
            sourceTexture.sample(texSampler, uv + chromOffset).r,
            sourceTexture.sample(texSampler, uv).g,
            sourceTexture.sample(texSampler, uv - chromOffset).b
        );
        w = swapWeight(warp, uniforms);
        color = half4(mix(prevColor.rgb, sourceRGB, w), 1.0h);
        if (int(uniforms.txStyle + 0.5) == TX_SOLARIZE) {
            // The tone curve folds over itself (f = 1 an S-curve, 2 solarized, 3 two bands), each
            // channel a little out of phase, so darks and lights trade places in coloured contours.
            half k = half(uniforms.txEnv);
            // The phase offsets scale with the value, so blacks stay black (no flat colour flood).
            half3 ph = color.rgb * (3.14159h * (1.0h + half(uniforms.txAmount) * k) + k * half3(0.0h, 1.2h, 2.4h));
            color.rgb = mix(color.rgb, 0.5h - 0.5h * cos(ph), 0.85h * k);
        }
    }
    // Bloom and ghost taps sample the picture this pixel is showing (transitions.md T7): no glow or
    // echo of the new picture over the old one before the swap reaches it.
    bool showNew = w.g >= 0.5h;
    // One handle, one sample (a per-sample select made the compiler fetch both textures).
    texture2d<half> shownTexture = showNew ? sourceTexture : previousTexture;
    float2 shownUV = showNew ? uv : previousUV;

    // === 2.9 ARCHIVE FOOTAGE (docs/plans/archive-video.md 2.2, footage-fx.md 2.2) ===
    // Two layers: during a piece-to-piece crossfade both show (A27); each is skipped at mix 0.
    // Each layer is tapped once here (at the stage-A uv: the film does not ride its own Undertow); the
    // tap feeds the carrier and the drives that act later (hue, solar, relief, wake, glow).
    FootageDrive fd = {};
    if (kAny && hasA) {
        FootageTap ta = tapFootage<kKeys>(kFX ? warp.uv : uv, texCoord, warp.field, videoTexture, la, uniforms);
        if (kLight) addDrive<kDrives, kGlass>(fd, ta, la, videoTexture, uniforms);
        half key = kKeys ? footageKey(la, color.rgb, uv, depthTexture) : 1.0h;
        color.rgb = compositeVideo<kVideo>(color.rgb, ta, la, key, uniforms);
    }
    if (kAny && hasB) {
        FootageTap tb = tapFootage<kKeys>(kFX ? warp.uv : uv, texCoord, warp.field, videoTextureB, lb, uniforms);
        if (kLight) addDrive<kDrives, kGlass>(fd, tb, lb, videoTextureB, uniforms);
        half key = kKeys ? footageKey(lb, color.rgb, uv, depthTexture) : 1.0h;
        color.rgb = compositeVideo<kVideo>(color.rgb, tb, lb, key, uniforms);
    }
    if (kLight && fd.lift > 0.001h) {
        // Light the film carries (Glow's lights, Fringe's contours, Wake's moving parts), screened in the
        // picture's own colours lifted toward the tint, so it reads on a dark picture too.
        half3 tint = half3(half(uniforms.videoTintR), half(uniforms.videoTintG), half(uniforms.videoTintB));
        half3 lc = min(color.rgb * 1.6h + tint * 0.55h, 1.0h);
        color.rgb = 1.0h - (1.0h - color.rgb) * (1.0h - lc * min(fd.lift, 0.9h));
    }
    if (kDrives && fd.solar > 0.001h) {
        // Solar: where the film is bright the picture's tone curve folds over (the Solarize transition's
        // curve, channels a little out of phase); where it is dark the picture is plain.
        // Round 2 (F24): the curve starts a little up (0.2 k), so the picture's darks fold into colour too and
        // the film's lights show as solarised figures on a dark picture.
        half k = min(fd.solar, 1.0h);
        half3 ph = (color.rgb + 0.2h * k) * (3.14159h * 2.0h + k * half3(0.0h, 1.0h, 2.0h));
        color.rgb = mix(color.rgb, 0.5h - 0.5h * cos(ph), 0.9h * k);
    }

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
    // The six x-dependent waves (uv.x differs per eye after parallax) run in half. Each time
    // phase is wrapped to [0, 2pi) in float first, so half only ever sees arguments < ~15
    // (seamless: phases only enter through sin). The y-only waves stay float: they are
    // identical for both eyes, so the compiler shares them across the inlined shadeEye calls.
    constexpr float TWO_PI = 6.2831853;
    half2 hx = half2(uv);
    half hwi = half(wi);
    half horizWaves = (sin(hx.x * 2.0h + half(fmod(t * 0.2, TWO_PI)))
                     + sin(hx.x * 5.0h - half(fmod(t * 0.15, TWO_PI))) * 0.6h
                     + sin(hx.x * 8.0h + half(fmod(t * 0.3, TWO_PI))) * 0.3h) * hwi;

    float vertWaves = sin(uv.y * 3.0 + t * 0.18) * wi * 0.8
                    + sin(uv.y * 6.0 - t * 0.22) * wi * 0.5
                    + sin(uv.y * 10.0 + t * 0.25) * wi * 0.25;

    half diagWaves = (sin((hx.x + hx.y) * 4.0h + half(fmod(t * 0.12, TWO_PI))) * 0.7h
                    + sin((hx.x - hx.y) * 3.0h - half(fmod(t * 0.16, TWO_PI))) * 0.5h) * hwi;

    half dist = length(hx - 0.5h);
    half radialWaves = sin(dist * 12.0h - half(fmod(t * 0.3, TWO_PI))) * hwi * 0.5h;

    float spatialOffset = float(horizWaves + diagWaves + radialWaves) + vertWaves;

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
    if (kDrives) hsv.x = fract(hsv.x + fd.hue);   // Aurora

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
    half hb = kDrives ? min(half(uniforms.hueBlendAmount) + fd.hueBlend, 1.0h) : half(uniforms.hueBlendAmount);
    half3 currentColor = mix(color.rgb, saturated, hb);
    // d (from the RGB->HSV step above) is exactly max - min of color.rgb == chromaOf(color.rgb).
    currentColor = restoreChroma(currentColor, mix(d, chromaOf(saturated), hb), 2.0h);

    // === 6.5 FRACTAL HUE CYCLING (Nishitsuji organic color shifts) ===
    // Spatially-varying hue shifts driven by sinusoidal interference noise.
    // Depth-map aware: foreground shifts more than background.
    if (uniforms.fractalHueAmount > 0.001) {
        // Sample depth for foreground/background modulation
        float depth = float(depthTexture.sample(texSampler, uv).r);

        // Fractal noise for hue modulation
        half3 noisePos = half3(half2(uv * 5.0), half(fmod(uniforms.time * 0.1, 6.2831853)));
        // One sin/cos of noisePos; octaves 2..4 by double-angle recurrence (flowOctaves).
        float fractalValue = float(flowOctaves(sin(noisePos), cos(noisePos), 4));

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

    // Relief: the film's height field lights and shades the processed colour (hue and saturation stay).
    if (kLight && abs(fd.relief) > 0.001h) {
        // Round 1: the lit side also gains a little light of its own, so the relief shows on a dark picture.
        half rl = clamp(fd.relief, -0.7h, 0.7h);
        currentColor = clamp(currentColor * (1.0h + rl) + half3(0.10h) * max(rl, 0.0h), 0.0h, 1.0h);
    }

    // === 4. GHOST TAPS - Discrete Delay Echoes ===
    // Each ghost tap spawns at the image, animates outward, and fades.
    // Multiple taps flow in similar directions, creating streaming trails.
    // Loop only over active taps (packed at front) to avoid branch divergence.
    // Taps sample the picture this pixel shows, so they need no gate during transitions.
    int tapCount = int(uniforms.ghostTapCount);
    half preTapChroma = chromaOf(currentColor);
    // Wake: echoes are stronger where the film moves.
    half tapGain = kDrives ? 0.15h * (1.0h + 1.2h * min(fd.wake, 1.0h)) : 0.15h;
    for (int i = 0; i < tapCount; i++) {
        GhostTap tap = ghostTaps[i];
        // Ghost starts at center (progress=0), moves outward (progress=1)
        float2 ghostUV = clamp(shownUV + float2(tap.directionX, tap.directionY) * tap.progress * uniforms.ghostTapMaxDistance,
                               float2(0.001), float2(0.999));
        half4 ghostSample = shownTexture.sample(texSampler, ghostUV);
        // Alpha fade: stronger at start (progress=0), transparent at end (progress=1)
        half ghostAlpha = half(1.0 - tap.progress * tap.progress);
        // Very subtle - ghosts should be background whispers, not dominant
        currentColor = mix(currentColor, ghostSample.rgb, ghostAlpha * tapGain);
    }

    // Ghosts keep their shape (luma) and take on the processed colour's chroma.
    if (int(uniforms.ghostTapCount) > 0) {
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
        float2 bloomUV = clamp(shownUV + noise * uniforms.bloomRadius, float2(0.001), float2(0.999));
        half3 bloomSample = shownTexture.sample(texSampler, bloomUV).rgb;
        half brightness = dot(bloomSample, half3(0.299h, 0.587h, 0.114h));
        half bloomAmt = half(uniforms.bloomAmount);
        if (kDrives) {
            // Glow: where the film is bright the picture's own colours bloom (light breathing inside it).
            half fg = min(fd.glow, 1.0h);
            bloomAmt *= 1.0h + 3.5h * fg;
            brightness = max(brightness, 0.7h * fg);
        }
        // Saturate the glow about its own luma and SCREEN it: highlights roll off with their
        // colour instead of the old clamped add flattening them to white.
        half3 glow = bloomSample * brightness * bloomAmt;
        half glowL = dot(glow, LUMA_W);
        glow = clamp(glowL + (glow - glowL) * 1.5h, 0.0h, 1.0h);
        currentColor = 1.0h - (1.0h - currentColor) * (1.0h - glow);
    }

    // === 6. FEEDBACK WARPING ===
    // Sample previous frame output with turbulence-warped UVs.
    // Each frame compounds the warp, creating evolving fractal trails.
    if (uniforms.feedbackMix > 0.001) {
        // Wake: where the film moves the picture lingers and smears (mix at most 0.5: a trail then
        // halves every frame at worst; restoreChroma's target is convex, so it cannot run away).
        half wk = kDrives ? min(fd.wake, 1.0h) : 0.0h;
        float fbWarp = kDrives ? uniforms.feedbackWarpAmount * (1.0 + 3.0 * float(wk)) : uniforms.feedbackWarpAmount;
        float2 feedbackBase = mix(previousUV, uv, float(w.g));
        float2 feedbackUV = feedbackBase + turbulence_distort(feedbackBase * 2.0, uniforms.time, 0.05) * fbWarp;
        feedbackUV = clamp(feedbackUV, float2(0.001), float2(0.999));
        half3 feedbackColor = feedbackTexture.sample(texSampler, feedbackUV).rgb;
        half fm = half(uniforms.feedbackMix);
        if (kDrives) fm = max(fm, min(fm + 0.28h * wk, 0.5h));
        half fbTarget = mix(chromaOf(currentColor), chromaOf(feedbackColor), fm);
        currentColor = restoreChroma(mix(currentColor, feedbackColor, fm), fbTarget, 1.5h);
    }

    // === 7. VIBRANCE ===
    // Black-point pull-down, then a chroma gain weighted toward under-saturated pixels
    // (tapers to 1 as saturation -> 1: the soft knee), gated off for near-greys, then
    // scaleChromaFit: luma- and hue-preserving, never leaves [0,1] (no clipping to white).
    {
        half bp = half(uniforms.blackPoint);
        half3 c = max((currentColor - bp) / (1.0h - bp), 0.0h);
        half l = dot(c, LUMA_W);
        half mx = max(c.r, max(c.g, c.b));
        half mn = min(c.r, min(c.g, c.b));
        half ch = mx - mn;
        half sat = ch / max(mx, 1.0e-3h);
        // g >= 1 (vibranceAmount >= 0), so c's own max/min feed the gamut fit directly.
        half g = 1.0h + half(uniforms.vibranceAmount) * (1.0h - sat) * smoothstep(0.02h, 0.10h, ch);
        currentColor = scaleChromaFit(c, l, mx, mn, g);
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

    WarpOut warp = distortedUV(in.texCoord, uniforms, depthTexture);
    return shadeEye<0>(warp, in.texCoord, in.position.xy, uniforms.stereoOffset,
                           sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture,
                           sourceTexture, sourceTexture, uniforms, ghostTaps);
}

// Archive footage variant of effectsFragment (docs/plans/archive-video.md 2.3): bound only while
// footage shows; textures 7 and 8 are the footage stages of layers A and B.
fragment half4 effectsFragmentVideo(
    VertexOut in [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]],
    texture2d<half> saliencyTexture [[texture(2)]],
    texture2d<half> previousTexture [[texture(3)]],
    texture2d<half> feedbackTexture [[texture(4)]],
    texture2d<half> depthTexture [[texture(5)]],
    texture2d<half> videoTexture [[texture(7)]],
    texture2d<half> videoTextureB [[texture(8)]],
    constant EffectsUniforms &uniforms [[buffer(0)]],
    constant GhostTap *ghostTaps [[buffer(1)]]
) {
    WarpOut warp = distortedUV(in.texCoord, uniforms, depthTexture);
    return shadeEye<1>(warp, in.texCoord, in.position.xy, uniforms.stereoOffset,
                          sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture,
                          videoTexture, videoTextureB, uniforms, ghostTaps);
}

// Footage interaction-mode variants of effectsFragmentVideo (docs/plans/footage-fx.md): bound only while a
// footage layer needs them (VideoComposite.footageVariant): Keys (keys, Kaleido, Palette, Print), Drives
// (the composite drives over the blend looks or none), Glass (Undertow and Fringe: the drives that move
// the picture's samples, round 2), and their unions (fallbacks, during a crossfade between two kinds).
#define FOOTAGE_FRAGMENT(NAME, V) \
fragment half4 NAME( \
    VertexOut in [[stage_in]], \
    texture2d<half> sourceTexture [[texture(0)]], \
    texture2d<half> saliencyTexture [[texture(2)]], \
    texture2d<half> previousTexture [[texture(3)]], \
    texture2d<half> feedbackTexture [[texture(4)]], \
    texture2d<half> depthTexture [[texture(5)]], \
    texture2d<half> videoTexture [[texture(7)]], \
    texture2d<half> videoTextureB [[texture(8)]], \
    constant EffectsUniforms &uniforms [[buffer(0)]], \
    constant GhostTap *ghostTaps [[buffer(1)]] \
) { \
    WarpOut warp = distortedUV(in.texCoord, uniforms, depthTexture); \
    return shadeEye<V>(warp, in.texCoord, in.position.xy, uniforms.stereoOffset, \
                       sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture, \
                       videoTexture, videoTextureB, uniforms, ghostTaps); \
}
FOOTAGE_FRAGMENT(effectsFragmentVideoKeys, 3)
FOOTAGE_FRAGMENT(effectsFragmentVideoDrives, 5)
FOOTAGE_FRAGMENT(effectsFragmentVideoFX, 7)
FOOTAGE_FRAGMENT(effectsFragmentVideoGlass, 9)
FOOTAGE_FRAGMENT(effectsFragmentVideoKeysGlass, 11)
FOOTAGE_FRAGMENT(effectsFragmentVideoDrivesGlass, 13)
FOOTAGE_FRAGMENT(effectsFragmentVideoFXGlass, 15)

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
    WarpOut warp = distortedUV(in.texCoord, uniforms, depthTexture);
    float mag = abs(uniforms.stereoOffset);
    StereoEyesOut out;
    out.left = shadeEye<0>(warp, in.texCoord, in.position.xy, -mag,
                        sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture,
                        sourceTexture, sourceTexture, uniforms, ghostTaps);
    out.right = shadeEye<0>(warp, in.texCoord, in.position.xy, mag,
                         sourceTexture, saliencyTexture, previousTexture, feedbackTextureRight, depthTexture,
                         sourceTexture, sourceTexture, uniforms, ghostTaps);
    return out;
}

// Archive footage variant of effectsFragmentStereo (texture 7 = footage stage).
fragment StereoEyesOut effectsFragmentStereoVideo(
    VertexOut in [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]],
    texture2d<half> saliencyTexture [[texture(2)]],
    texture2d<half> previousTexture [[texture(3)]],
    texture2d<half> feedbackTexture [[texture(4)]],       // left eye's previous output
    texture2d<half> depthTexture [[texture(5)]],
    texture2d<half> feedbackTextureRight [[texture(6)]],  // right eye's previous output
    texture2d<half> videoTexture [[texture(7)]],          // archive footage stage, layer A
    texture2d<half> videoTextureB [[texture(8)]],         // layer B (crossfades)
    constant EffectsUniforms &uniforms [[buffer(0)]],
    constant GhostTap *ghostTaps [[buffer(1)]]
) {
    WarpOut warp = distortedUV(in.texCoord, uniforms, depthTexture);
    float mag = abs(uniforms.stereoOffset);
    StereoEyesOut out;
    out.left = shadeEye<1>(warp, in.texCoord, in.position.xy, -mag,
                        sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture,
                        videoTexture, videoTextureB, uniforms, ghostTaps);
    out.right = shadeEye<1>(warp, in.texCoord, in.position.xy, mag,
                         sourceTexture, saliencyTexture, previousTexture, feedbackTextureRight, depthTexture,
                         videoTexture, videoTextureB, uniforms, ghostTaps);
    return out;
}

// Footage interaction-mode variants of effectsFragmentStereoVideo.
#define FOOTAGE_STEREO_FRAGMENT(NAME, V) \
fragment StereoEyesOut NAME( \
    VertexOut in [[stage_in]], \
    texture2d<half> sourceTexture [[texture(0)]], \
    texture2d<half> saliencyTexture [[texture(2)]], \
    texture2d<half> previousTexture [[texture(3)]], \
    texture2d<half> feedbackTexture [[texture(4)]], \
    texture2d<half> depthTexture [[texture(5)]], \
    texture2d<half> feedbackTextureRight [[texture(6)]], \
    texture2d<half> videoTexture [[texture(7)]], \
    texture2d<half> videoTextureB [[texture(8)]], \
    constant EffectsUniforms &uniforms [[buffer(0)]], \
    constant GhostTap *ghostTaps [[buffer(1)]] \
) { \
    WarpOut warp = distortedUV(in.texCoord, uniforms, depthTexture); \
    float mag = abs(uniforms.stereoOffset); \
    StereoEyesOut out; \
    out.left = shadeEye<V>(warp, in.texCoord, in.position.xy, -mag, \
                        sourceTexture, saliencyTexture, previousTexture, feedbackTexture, depthTexture, \
                        videoTexture, videoTextureB, uniforms, ghostTaps); \
    out.right = shadeEye<V>(warp, in.texCoord, in.position.xy, mag, \
                         sourceTexture, saliencyTexture, previousTexture, feedbackTextureRight, depthTexture, \
                         videoTexture, videoTextureB, uniforms, ghostTaps); \
    return out; \
}
FOOTAGE_STEREO_FRAGMENT(effectsFragmentStereoVideoKeys, 3)
FOOTAGE_STEREO_FRAGMENT(effectsFragmentStereoVideoDrives, 5)
FOOTAGE_STEREO_FRAGMENT(effectsFragmentStereoVideoFX, 7)
FOOTAGE_STEREO_FRAGMENT(effectsFragmentStereoVideoGlass, 9)
FOOTAGE_STEREO_FRAGMENT(effectsFragmentStereoVideoKeysGlass, 11)
FOOTAGE_STEREO_FRAGMENT(effectsFragmentStereoVideoDrivesGlass, 13)
FOOTAGE_STEREO_FRAGMENT(effectsFragmentStereoVideoFXGlass, 15)
