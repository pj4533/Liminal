//
//  LowLevelDomeMesh.swift
//  Liminal
//
//  Dome mesh using LowLevelMesh for breathing displacement.
//  Breathing is computed on the CPU each frame and written straight into the
//  LowLevelMesh vertex buffer (no compute pass / command buffer).
//

#if os(visionOS)

import RealityKit
import Metal  // vertex/index format enums used by LowLevelMesh descriptors
import OSLog

/// Dome mesh wrapping LowLevelMesh with CPU-computed breathing displacement.
@MainActor
final class LowLevelDomeMesh {

    // MARK: - Configuration

    let horizontalSegments: Int
    let verticalSegments: Int
    let panelRadius: Float
    let horizontalArc: Float  // degrees
    let verticalArc: Float    // degrees

    // MARK: - Base Geometry (allocated once)

    private let vertexCount: Int
    /// Undeformed vertices: position(3) + normal(3) + uv(2) floats per vertex.
    private let baseVertices: [Float]
    /// Per-vertex grid fractions and distance from grid centre (precomputed).
    private let hFracs: [Float]
    private let vFracs: [Float]
    private let centerDists: [Float]

    // MARK: - Mesh

    let lowLevelMesh: LowLevelMesh
    let meshResource: MeshResource

    // MARK: - Vertex Layout Constants

    /// Stride: float3 position (12) + float3 normal (12) + float2 uv (8) = 32 bytes
    static let vertexStride = 32

    // MARK: - Init

    init?(
        horizontalSegments: Int = 48,
        verticalSegments: Int = 36,
        panelRadius: Float = 2.0,
        horizontalArc: Float = 110.0,
        verticalArc: Float = 75.0
    ) {
        self.horizontalSegments = horizontalSegments
        self.verticalSegments = verticalSegments
        self.panelRadius = panelRadius
        self.horizontalArc = horizontalArc
        self.verticalArc = verticalArc

        let vertexCount = (horizontalSegments + 1) * (verticalSegments + 1)
        self.vertexCount = vertexCount
        let indexCount = horizontalSegments * verticalSegments * 6

        // Create LowLevelMesh descriptor
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .normal, format: .float3, offset: 12),
            .init(semantic: .uv0, format: .float2, offset: 24)
        ]

        let layouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferOffset: 0, bufferStride: Self.vertexStride)
        ]

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertexCount
        descriptor.vertexAttributes = attributes
        descriptor.vertexLayouts = layouts
        descriptor.indexCapacity = indexCount
        descriptor.indexType = .uint32

        guard let mesh = try? LowLevelMesh(descriptor: descriptor) else {
            LMLog.visual.error("❌ LowLevelDomeMesh: Failed to create LowLevelMesh")
            return nil
        }
        self.lowLevelMesh = mesh

        // Generate base geometry on CPU and write to both LowLevelMesh and base buffer
        let hArc = horizontalArc * .pi / 180.0
        let vArc = verticalArc * .pi / 180.0
        let startH = -hArc / 2
        let startV = -vArc / 2

        // Calculate vertices
        var vertexData = [Float]()
        vertexData.reserveCapacity(vertexCount * 8)  // 8 floats per vertex
        var hFracData = [Float](), vFracData = [Float](), centerDistData = [Float]()
        hFracData.reserveCapacity(vertexCount)
        vFracData.reserveCapacity(vertexCount)
        centerDistData.reserveCapacity(vertexCount)

        for v in 0...verticalSegments {
            let vFrac = Float(v) / Float(verticalSegments)
            let vAngle = startV + vFrac * vArc

            for h in 0...horizontalSegments {
                let hFrac = Float(h) / Float(horizontalSegments)
                let hAngle = startH + hFrac * hArc

                let x = panelRadius * sin(hAngle)
                let y = panelRadius * tan(vAngle)
                let z = -panelRadius * cos(hAngle)

                let normal = simd_normalize(SIMD3<Float>(-x, 0, -z))

                hFracData.append(hFrac)
                vFracData.append(vFrac)
                let dh = hFrac - 0.5, dv = vFrac - 0.5
                centerDistData.append((dh * dh + dv * dv).squareRoot())

                // position (float3)
                vertexData.append(x)
                vertexData.append(y)
                vertexData.append(z)
                // normal (float3)
                vertexData.append(normal.x)
                vertexData.append(normal.y)
                vertexData.append(normal.z)
                // uv (float2), standard USD/RealityKit convention: u left→right, v = 0 at the
                // BOTTOM edge, v = 1 at the TOP edge (v grows with height). RealityKit materials
                // sample texture row (1 - v) * H, so v = 1 hits row 0 = image top
                // (docs/decisions/orientation.md). Was 1 - vFrac, which only looked right because
                // the upload also stored the image upside down.
                vertexData.append(hFrac)
                vertexData.append(vFrac)
            }
        }

        // Write vertices to LowLevelMesh
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBuffer in
            let dest = rawBuffer.baseAddress!
            vertexData.withUnsafeBytes { src in
                dest.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        self.baseVertices = vertexData
        self.hFracs = hFracData
        self.vFracs = vFracData
        self.centerDists = centerDistData

        // Generate indices
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        let rowSize = horizontalSegments + 1

        for v in 0..<verticalSegments {
            for h in 0..<horizontalSegments {
                let topLeft = UInt32(v * rowSize + h)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((v + 1) * rowSize + h)
                let bottomRight = bottomLeft + 1

                indices.append(contentsOf: [topLeft, topRight, bottomLeft])
                indices.append(contentsOf: [topRight, bottomRight, bottomLeft])
            }
        }

        // Write indices to LowLevelMesh
        mesh.withUnsafeMutableIndices { rawBuffer in
            let dest = rawBuffer.baseAddress!
            indices.withUnsafeBytes { src in
                dest.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        // Set mesh parts with bounding box
        let extent = panelRadius * 1.5  // Conservative bounding box
        let bounds = BoundingBox(
            min: SIMD3<Float>(-extent, -extent, -extent),
            max: SIMD3<Float>(extent, extent, 0.1)
        )

        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexOffset: 0,
                indexCount: indexCount,
                topology: .triangle,
                materialIndex: 0,
                bounds: bounds
            )
        ])

        // Create MeshResource from LowLevelMesh
        do {
            self.meshResource = try MeshResource(from: mesh)
        } catch {
            LMLog.visual.error("❌ LowLevelDomeMesh: Failed to create MeshResource: \(error.localizedDescription)")
            return nil
        }

        LMLog.visual.info("✅ LowLevelDomeMesh: \(vertexCount) vertices, \(indexCount / 3) triangles, stride=\(Self.vertexStride)")
    }

    // MARK: - Breathing Update (CPU)

    /// Displace every vertex along its normal on the CPU and write the full vertex buffer.
    /// Same maths and constants as the former `breathingDisplacement` compute kernel.
    /// ~1.8k vertices x 4 sines: tens of microseconds, no command buffer or GPU dispatch.
    func updateBreathing(time: Float, amplitude: Float = 0.06, speed: Float = 0.4) {
        let breathTime = time * speed
        let t1 = breathTime * 1.0
        let t2 = breathTime * 0.7
        let t3 = breathTime * 0.5
        let t4 = breathTime * 0.8
        let count = vertexCount

        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBuffer in
            guard rawBuffer.count >= count * Self.vertexStride else { return }
            let dst = rawBuffer.bindMemory(to: Float.self)
            baseVertices.withUnsafeBufferPointer { base in
                hFracs.withUnsafeBufferPointer { hF in
                vFracs.withUnsafeBufferPointer { vF in
                centerDists.withUnsafeBufferPointer { cD in
                    for i in 0..<count {
                        let h = hF[i]
                        let v = vF[i]
                        let wave1 = sin(h * 6.0 + t1) * 0.4
                        let wave2 = sin(v * 5.0 + t2) * 0.3
                        let wave3 = sin((h + v) * 4.0 + t3) * 0.2
                        let wave4 = sin(cD[i] * 8.0 - t4) * 0.1
                        let d = (wave1 + wave2 + wave3 + wave4) * amplitude

                        let o = i * 8
                        let nx = base[o + 3], ny = base[o + 4], nz = base[o + 5]
                        dst[o + 0] = base[o + 0] + nx * d
                        dst[o + 1] = base[o + 1] + ny * d
                        dst[o + 2] = base[o + 2] + nz * d
                        dst[o + 3] = nx
                        dst[o + 4] = ny
                        dst[o + 5] = nz
                        dst[o + 6] = base[o + 6]
                        dst[o + 7] = base[o + 7]
                    }
                }
                }
                }
            }
        }
    }
}

#endif
