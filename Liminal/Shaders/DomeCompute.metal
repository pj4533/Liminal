#include <metal_stdlib>
using namespace metal;

// MARK: - Dome Vertex Structure
// Must match the LowLevelMesh layout in LowLevelDomeMesh.swift:
// position (float3, offset 0) + normal (float3, offset 12) + uv (float2, offset 24) = 32 bytes

struct DomeVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 uv;
};

// MARK: - Breathing Parameters

struct BreathingParams {
    float time;
    float amplitude;
    float speed;
    uint vertexCount;
    uint horizontalSegments;
    uint verticalSegments;
};

// MARK: - Breathing Displacement Kernel
// Reads base vertices, applies multi-wave breathing displacement along normals.

kernel void breathingDisplacement(
    device DomeVertex *vertices [[buffer(0)]],
    const device DomeVertex *baseVertices [[buffer(1)]],
    constant BreathingParams &params [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.vertexCount) return;

    DomeVertex base = baseVertices[id];
    float3 position = float3(base.position);
    float3 normal = float3(base.normal);

    float breathTime = params.time * params.speed;

    // Calculate grid fractions from vertex index
    uint rowSize = params.horizontalSegments + 1;
    uint v = id / rowSize;
    uint h = id % rowSize;
    float hFrac = float(h) / float(params.horizontalSegments);
    float vFrac = float(v) / float(params.verticalSegments);

    // Multiple overlapping sine waves for organic breathing
    float wave1 = sin(hFrac * 6.0 + breathTime * 1.0) * 0.4;
    float wave2 = sin(vFrac * 5.0 + breathTime * 0.7) * 0.3;
    float wave3 = sin((hFrac + vFrac) * 4.0 + breathTime * 0.5) * 0.2;
    float centerDist = sqrt(pow(hFrac - 0.5, 2.0) + pow(vFrac - 0.5, 2.0));
    float wave4 = sin(centerDist * 8.0 - breathTime * 0.8) * 0.1;

    float displacement = (wave1 + wave2 + wave3 + wave4) * params.amplitude;

    vertices[id].position = packed_float3(position + normal * displacement);
    vertices[id].normal = base.normal;
    vertices[id].uv = base.uv;
}
