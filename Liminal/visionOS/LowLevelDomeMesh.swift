//
//  LowLevelDomeMesh.swift
//  Liminal
//
//  GPU-driven dome mesh using LowLevelMesh for breathing displacement.
//  Replaces CPU-side MeshResource.generate()/replace() with a Metal compute shader.
//

#if os(visionOS)

import RealityKit
import Metal
import OSLog

/// GPU-driven dome mesh wrapping LowLevelMesh for compute-shader breathing displacement.
@MainActor
final class LowLevelDomeMesh {

    // MARK: - Configuration

    let horizontalSegments: Int
    let verticalSegments: Int
    let panelRadius: Float
    let horizontalArc: Float  // degrees
    let verticalArc: Float    // degrees

    // MARK: - Metal Objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let baseVertexBuffer: MTLBuffer  // Undeformed dome vertices

    // MARK: - Mesh

    let lowLevelMesh: LowLevelMesh
    let meshResource: MeshResource

    /// Optional GPU timing sink (the effects renderer's stats; same command queue).
    var gpuStats: GPUTimingStats?

    // MARK: - Vertex Layout Constants

    /// Stride: float3 position (12) + float3 normal (12) + float2 uv (8) = 32 bytes
    static let vertexStride = 32

    // MARK: - Breathing Parameters (matches Metal struct)

    struct BreathingParams {
        var time: Float
        var amplitude: Float
        var speed: Float
        var vertexCount: UInt32
        var horizontalSegments: UInt32
        var verticalSegments: UInt32
    }

    // MARK: - Init

    init?(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        horizontalSegments: Int = 48,
        verticalSegments: Int = 36,
        panelRadius: Float = 2.0,
        horizontalArc: Float = 110.0,
        verticalArc: Float = 75.0
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.horizontalSegments = horizontalSegments
        self.verticalSegments = verticalSegments
        self.panelRadius = panelRadius
        self.horizontalArc = horizontalArc
        self.verticalArc = verticalArc

        let vertexCount = (horizontalSegments + 1) * (verticalSegments + 1)
        let indexCount = horizontalSegments * verticalSegments * 6

        // Load compute pipeline
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "breathingDisplacement"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            LMLog.visual.error("❌ LowLevelDomeMesh: Failed to create compute pipeline")
            return nil
        }
        self.computePipeline = pipeline

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

                // position (float3)
                vertexData.append(x)
                vertexData.append(y)
                vertexData.append(z)
                // normal (float3)
                vertexData.append(normal.x)
                vertexData.append(normal.y)
                vertexData.append(normal.z)
                // uv (float2)
                vertexData.append(hFrac)
                vertexData.append(1.0 - vFrac)
            }
        }

        // Write vertices to LowLevelMesh
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBuffer in
            let dest = rawBuffer.baseAddress!
            vertexData.withUnsafeBytes { src in
                dest.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        // Create base vertex buffer (GPU-readable copy of undeformed positions)
        let vertexBufferSize = vertexCount * Self.vertexStride
        guard let baseBuffer = device.makeBuffer(
            bytes: vertexData,
            length: vertexBufferSize,
            options: .storageModeShared
        ) else {
            LMLog.visual.error("❌ LowLevelDomeMesh: Failed to create base vertex buffer")
            return nil
        }
        self.baseVertexBuffer = baseBuffer

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

    // MARK: - Breathing Update (GPU Compute)

    /// Dispatch compute shader to update breathing displacement.
    func updateBreathing(time: Float, amplitude: Float = 0.06, speed: Float = 0.4) {
        let vertexCount = (horizontalSegments + 1) * (verticalSegments + 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let vertexBuffer = lowLevelMesh.replace(bufferIndex: 0, using: commandBuffer)

        encoder.setComputePipelineState(computePipeline)
        encoder.setBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setBuffer(baseVertexBuffer, offset: 0, index: 1)

        var params = BreathingParams(
            time: time,
            amplitude: amplitude,
            speed: speed,
            vertexCount: UInt32(vertexCount),
            horizontalSegments: UInt32(horizontalSegments),
            verticalSegments: UInt32(verticalSegments)
        )
        encoder.setBytes(&params, length: MemoryLayout<BreathingParams>.size, index: 2)

        let threadgroupSize = min(computePipeline.maxTotalThreadsPerThreadgroup, 256)
        let threadgroups = (vertexCount + threadgroupSize - 1) / threadgroupSize
        encoder.dispatchThreadgroups(
            MTLSize(width: threadgroups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadgroupSize, height: 1, depth: 1)
        )

        encoder.endEncoding()
        gpuStats?.track(commandBuffer, pass: "dome")
        commandBuffer.commit()
    }
}

#endif
