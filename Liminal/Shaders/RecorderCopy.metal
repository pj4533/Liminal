//
//  RecorderCopy.metal
//  Liminal
//
//  The recorder's copy of each rendered frame into the video pixel buffer (FrameRecorder): one
//  full-screen triangle, bilinear. It scales the visionOS 2048² shell texture back to the picture's
//  3:2, and copies the macOS drawable 1:1. Values pass through unchanged (both sources hold
//  sRGB-encoded values in a bgra8Unorm texture).
//

#include <metal_stdlib>
using namespace metal;

struct RecorderVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex RecorderVertexOut recorderCopyVertex(uint vid [[vertex_id]]) {
    // (0,0) (2,0) (0,2): covers the target; uv row 0 is the top of the picture.
    float2 p = float2((vid << 1) & 2, vid & 2);
    RecorderVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 recorderCopyFragment(RecorderVertexOut in [[stage_in]],
                                     texture2d<float> source [[texture(0)]],
                                     sampler s [[sampler(0)]]) {
    return source.sample(s, in.uv);
}
