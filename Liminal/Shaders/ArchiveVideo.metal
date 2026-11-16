#include <metal_stdlib>
using namespace metal;

// Archive footage pre-pass (docs/plans/archive-video.md 2.1). One small compute pass per decoded
// video frame (15-25 a second), into the next of three rotating 960 x 720 stage textures:
//   r = luma after the clip's levels, blended with the previous frame (softens cuts and flashes,
//       film-like smear; photosensitivity)
//   g = slow temporal average of r (glows, the Window look)
//   b = motion |luma - previous r|, smoothed (the Phantom look)
//   a = soft edge magnitude of the previous stage's g (one frame late; footage interaction modes,
//       docs/plans/footage-fx.md 6: the film's contours drive the colour fringes)
// The effects shader samples only the stage (texture 7), never the decoded frame.

struct VideoPrepassParams {
    float black;      // luma black point of the clip (0...1)
    float white;      // luma white point
    float blend;      // weight of the previous frame in r (0.4)
    float slowK;      // one-pole coefficient of g for this frame interval
    float motionK;    // one-pole coefficient of b
    float crop;       // inset crop of film borders, each side (0.06)
    float hasPrev;    // 0 on the first frame of a segment: no history
    float pad;
};

kernel void videoPrepass(texture2d<half, access::sample> frame [[texture(0)]],
                         texture2d<half, access::read> prev [[texture(1)]],
                         texture2d<half, access::write> out [[texture(2)]],
                         constant VideoPrepassParams &p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
    uv = p.crop + uv * (1.0 - 2.0 * p.crop);
    half3 rgb = frame.sample(s, uv).rgb;
    half l = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    l = saturate((l - half(p.black)) / max(half(p.white - p.black), 0.05h));
    half4 q = p.hasPrev > 0.5 ? prev.read(gid) : half4(l, l, 0.0h, 1.0h);
    half r = mix(l, q.r, half(p.blend));
    half g = mix(q.g, r, half(p.slowK));
    half mo = mix(q.b, saturate(abs(l - q.r) * 4.0h), half(p.motionK));
    // Edge of the slow average, 2 texels each way, eased like the motion (no flicker on cuts).
    half ed = 0.0h;
    if (p.hasPrev > 0.5) {
        uint2 hi = uint2(out.get_width() - 1, out.get_height() - 1);
        half gx = prev.read(uint2(min(gid.x + 2, hi.x), gid.y)).g - prev.read(uint2(gid.x >= 2 ? gid.x - 2 : 0, gid.y)).g;
        half gy = prev.read(uint2(gid.x, min(gid.y + 2, hi.y))).g - prev.read(uint2(gid.x, gid.y >= 2 ? gid.y - 2 : 0)).g;
        ed = mix(q.a, saturate(length(half2(gx, gy)) * 6.0h), half(p.motionK));
    }
    out.write(half4(r, g, mo, ed), gid);
}
