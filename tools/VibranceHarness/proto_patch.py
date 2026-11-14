#!/usr/bin/env python3
"""Prototype patch for the vibrance fix plan (docs/plans/vibrance.md).

Applies the proposed per-stage fixes and the final vibrance stage to a COPY of
EffectsRenderer.metal so they can be measured with the offline harness without touching
the app's shader. Used by scripts/vibrance-proto.sh. Constants are hardcoded through
-D flags (FIX_HUE, FIX_TAPS, FIX_BLOOM, FIX_FB, VIB, BP) so the uniform layout is unchanged.

    proto_patch.py <path-to-copied-EffectsRenderer.metal>
"""
import sys

p=sys.argv[1]; s=open(p).read()
def rep(a,b):
    global s
    assert a in s, a[:60]
    s=s.replace(a,b,1)
helpers='''
#ifndef FIX_HUE
#define FIX_HUE 1
#endif
#ifndef FIX_TAPS
#define FIX_TAPS 1
#endif
#ifndef FIX_BLOOM
#define FIX_BLOOM 1
#endif
#ifndef FIX_FB
#define FIX_FB 1
#endif
#ifndef VIB
#define VIB 0.35h
#endif
#ifndef BP
#define BP 0.03h
#endif
constant half3 LUMA_W = half3(0.299h, 0.587h, 0.114h);
static inline half chromaOf(half3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
static inline half3 gamutFit(half3 c, half l) {
    half hi = max(c.r, max(c.g, c.b));
    half lo = min(c.r, min(c.g, c.b));
    half k = min(1.0h, min((1.0h - l) / max(hi - l, 1.0e-4h), l / max(l - lo, 1.0e-4h)));
    return l + (c - l) * k;
}
static inline half3 restoreChroma(half3 c, half target, half maxGain) {
    half l = dot(c, LUMA_W);
    half g = clamp(target / max(chromaOf(c), 0.02h), 1.0h, maxGain);
    return gamutFit(l + (c - l) * g, l);
}
// MARK: - Uniforms
'''
rep("// MARK: - Uniforms\n", helpers)
rep('''    half3 colorBlended = shiftedRgb * (originalLuma / max(shiftedLuma, 0.001h));
    colorBlended = clamp(colorBlended, 0.0h, 1.0h);''','''#if FIX_HUE
    half shiftedMax = max(shiftedRgb.r, max(shiftedRgb.g, shiftedRgb.b));
    half3 colorBlended = shiftedRgb * min(originalLuma / max(shiftedLuma, 0.001h), 1.0h / max(shiftedMax, 0.001h));
#else
    half3 colorBlended = shiftedRgb * (originalLuma / max(shiftedLuma, 0.001h));
    colorBlended = clamp(colorBlended, 0.0h, 1.0h);
#endif''')
rep('''    half3 currentColor = mix(color.rgb, saturated, half(uniforms.hueBlendAmount));''','''    half3 currentColor = mix(color.rgb, saturated, half(uniforms.hueBlendAmount));
#if FIX_HUE
    currentColor = restoreChroma(currentColor, mix(chromaOf(color.rgb), chromaOf(saturated), half(uniforms.hueBlendAmount)), 2.0h);
#endif''')
rep('''    for (int i = 0; i < tapCount; i++) {''','''    half preTapChroma = chromaOf(currentColor);
    for (int i = 0; i < tapCount; i++) {''')
rep('''    // === 5. STOCHASTIC BLOOM ===''','''#if FIX_TAPS
    if (tapCount > 0) { currentColor = restoreChroma(currentColor, preTapChroma, 1.5h); }
#endif
    // === 5. STOCHASTIC BLOOM ===''')
rep('''        currentColor += bloomSample * brightness * half(uniforms.bloomAmount);
        currentColor = clamp(currentColor, 0.0h, 1.0h);''','''#if FIX_BLOOM
        half3 glow = bloomSample * brightness * half(uniforms.bloomAmount);
        half glowL = dot(glow, LUMA_W);
        glow = clamp(glowL + (glow - glowL) * 1.5h, 0.0h, 1.0h);
        currentColor = 1.0h - (1.0h - currentColor) * (1.0h - glow);
#else
        currentColor += bloomSample * brightness * half(uniforms.bloomAmount);
        currentColor = clamp(currentColor, 0.0h, 1.0h);
#endif''')
rep('''        currentColor = mix(currentColor, feedbackColor, half(uniforms.feedbackMix));''','''#if FIX_FB
        half fbTarget = mix(chromaOf(currentColor), chromaOf(feedbackColor), half(uniforms.feedbackMix));
        currentColor = restoreChroma(mix(currentColor, feedbackColor, half(uniforms.feedbackMix)), fbTarget, 1.5h);
#else
        currentColor = mix(currentColor, feedbackColor, half(uniforms.feedbackMix));
#endif''')
rep('''    return half4(currentColor, 1.0h);
}''','''    {
        half3 c = max((currentColor - BP) / (1.0h - BP), 0.0h);
        half l = dot(c, LUMA_W);
        half mx = max(c.r, max(c.g, c.b));
        half ch = mx - min(c.r, min(c.g, c.b));
        half sat = ch / max(mx, 1.0e-3h);
        half g = 1.0h + VIB * (1.0h - sat) * smoothstep(0.02h, 0.10h, ch);
        currentColor = gamutFit(l + (c - l) * g, l);
    }
    return half4(currentColor, 1.0h);
}''')
open(p,'w').write(s)
