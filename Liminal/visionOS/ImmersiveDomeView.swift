//
//  ImmersiveDomeView.swift
//  Liminal
//
//  RealityKit immersive view - curved panel for sharp, immersive visuals.
//
//  ============================================================================
//  🧪 CURVED PANEL TEST - Concentrates pixels in main field of view
//  ============================================================================
//
//  Instead of spreading 2048x2048 across 360°, we create a curved panel
//  that fills ~140° horizontal, ~100° vertical. All pixels concentrated
//  where you're actually looking = sharper image.
//
//  DEBUG APPROACH: Start with RED material, verify geometry, THEN add texture.
//  ============================================================================
//

#if os(visionOS)

import SwiftUI
import RealityKit
import OSLog

struct ImmersiveDomeView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService

    @State private var panelEntity: ModelEntity?
    @State private var textureResource: TextureResource?
    @State private var isSetupComplete = false

    // Curved panel parameters
    private let panelRadius: Float = 2.0        // Distance from user
    private let horizontalArc: Float = 110.0    // Degrees of horizontal coverage
    private let verticalArc: Float = 75.0       // Degrees of vertical coverage
    private let horizontalSegments: Int = 32    // Mesh resolution
    private let verticalSegments: Int = 24

    var body: some View {
        RealityView { content in
            LMLog.visual.info("🎬 CURVED PANEL: Creating mesh...")
            LMLog.visual.info("🎬 CURVED PANEL: radius=\(panelRadius)m, h=\(horizontalArc)°, v=\(verticalArc)°")

            // Generate curved panel mesh
            guard let mesh = createCurvedPanelMesh() else {
                LMLog.visual.error("❌ CURVED PANEL: Failed to create mesh!")
                return
            }
            LMLog.visual.info("🎬 CURVED PANEL: Mesh created successfully")

            // Start with bright RED so we can see if geometry exists
            var material = UnlitMaterial()
            material.color = .init(tint: .red)

            let entity = ModelEntity(mesh: mesh, materials: [material])

            // Position panel at eye level (visionOS origin is at floor, eyes ~1.5m up)
            entity.position = SIMD3<Float>(0, 1.5, 0)

            content.add(entity)
            panelEntity = entity

            LMLog.visual.info("🎬 CURVED PANEL: ✅ Entity added with RED material")
        }
        .task {
            // Wait a moment to see red, then apply texture
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await setupTexture()
        }
    }

    // MARK: - Mesh Generation

    /// Creates a curved panel mesh (partial cylinder) facing inward toward the user
    private func createCurvedPanelMesh() -> MeshResource? {
        let hArc = horizontalArc * .pi / 180.0  // Convert to radians
        let vArc = verticalArc * .pi / 180.0

        let startH = -hArc / 2  // Center horizontally
        let startV = -vArc / 2  // Center vertically

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        // Generate vertices
        for v in 0...verticalSegments {
            let vFrac = Float(v) / Float(verticalSegments)
            let vAngle = startV + vFrac * vArc

            for h in 0...horizontalSegments {
                let hFrac = Float(h) / Float(horizontalSegments)
                let hAngle = startH + hFrac * hArc

                // Cylindrical coordinates (panel curves around Y axis)
                let x = panelRadius * sin(hAngle)
                let y = panelRadius * tan(vAngle)  // Vertical spread
                let z = -panelRadius * cos(hAngle) // Negative Z = in front of user

                positions.append(SIMD3<Float>(x, y, z))

                // Normal points inward (toward user at origin)
                let normal = normalize(SIMD3<Float>(-x, 0, -z))
                normals.append(normal)

                // UV: 0-1 across the panel
                uvs.append(SIMD2<Float>(hFrac, 1.0 - vFrac))  // Flip V for correct orientation
            }
        }

        // Generate triangle indices
        let rowSize = horizontalSegments + 1
        for v in 0..<verticalSegments {
            for h in 0..<horizontalSegments {
                let topLeft = UInt32(v * rowSize + h)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((v + 1) * rowSize + h)
                let bottomRight = bottomLeft + 1

                // Two triangles per quad - CLOCKWISE winding for inward-facing surface
                indices.append(contentsOf: [topLeft, topRight, bottomLeft])
                indices.append(contentsOf: [topRight, bottomRight, bottomLeft])
            }
        }

        LMLog.visual.info("🎬 CURVED PANEL: Generated \(positions.count) vertices, \(indices.count / 3) triangles")

        // Build mesh descriptor
        var descriptor = MeshDescriptor(name: "CurvedPanel")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            return mesh
        } catch {
            LMLog.visual.error("❌ CURVED PANEL: MeshResource.generate failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Texture Setup

    @MainActor
    private func setupTexture() async {
        LMLog.visual.info("🎨 CURVED PANEL: Setting up texture...")

        // Poll for image
        var waitCount = 0
        while visualEngine.imageBuffer.loadCurrent() == nil {
            waitCount += 1
            if waitCount % 10 == 0 {
                LMLog.visual.info("🎨 CURVED PANEL: Waiting for image... (\(waitCount)s)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            if waitCount > 60 {
                LMLog.visual.error("❌ CURVED PANEL: Timed out waiting for image")
                return
            }
        }

        guard let cgImage = visualEngine.imageBuffer.loadCurrent() else {
            LMLog.visual.error("❌ CURVED PANEL: No image after wait")
            return
        }

        LMLog.visual.info("🎨 CURVED PANEL: Got image \(cgImage.width)x\(cgImage.height)")

        do {
            let resource = try await TextureResource(image: cgImage, options: .init(semantic: .color))
            LMLog.visual.info("🎨 CURVED PANEL: TextureResource created")

            if let entity = panelEntity {
                var material = UnlitMaterial()
                material.color = .init(texture: .init(resource))
                entity.model?.materials = [material]
                LMLog.visual.info("🎨 CURVED PANEL: ✅ Applied texture!")
            } else {
                LMLog.visual.error("❌ CURVED PANEL: No panel entity!")
            }

            self.textureResource = resource
            self.isSetupComplete = true

        } catch {
            LMLog.visual.error("❌ CURVED PANEL: TextureResource failed: \(error.localizedDescription)")
        }
    }
}

#endif
