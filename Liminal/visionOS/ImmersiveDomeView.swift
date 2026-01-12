//
//  ImmersiveDomeView.swift
//  Liminal
//
//  RealityKit immersive dome that displays visual effects.
//
//  ============================================================================
//  🧪 MINIMAL TEST MODE - Stripped down to diagnose basic rendering
//  ============================================================================
//
//  REMOVED FOR DEBUGGING (restore once basic rendering works):
//  - TimelineView(.animation) for 90fps render loop
//  - DrawableQueue for dynamic texture updates
//  - Metal shader pipeline (effectsVertex, effectsFragment)
//  - Ken Burns animation (zoom/pan effects)
//  - Feedback/trails effect
//  - FrameCounter for frame tracking
//  - Continuous render loop
//
//  CURRENT TEST:
//  1. Create dome with RED material (verify RealityKit works at all)
//  2. Wait for Nano Banana to generate first image
//  3. Create TextureResource directly from CGImage (no DrawableQueue)
//  4. Apply static texture to dome
//
//  If this works, we can add back complexity layer by layer.
//  ============================================================================
//

#if os(visionOS)

import SwiftUI
import RealityKit
import OSLog

struct ImmersiveDomeView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService

    @State private var domeEntity: ModelEntity?
    @State private var textureResource: TextureResource?
    @State private var isSetupComplete = false

    // BACK TO SPHERE - the curved display didn't work (black screen)
    // The sphere DID show the image, just with some distortion.
    // Let's iterate from what works rather than breaking things.
    //
    // Radius tuning - testing different values
    private let domeRadius: Float = 3.0

    var body: some View {
        RealityView { content in
            LMLog.visual.info("🌐 MINIMAL TEST: Creating sphere dome...")

            // Create inverted sphere - THIS WORKED BEFORE
            let mesh = MeshResource.generateSphere(radius: domeRadius)

            // Start with bright RED so we can see if it exists
            var material = UnlitMaterial()
            material.color = .init(tint: .red)

            let entity = ModelEntity(mesh: mesh, materials: [material])

            // Flip scale to see inside of sphere - THIS IS KEY
            entity.scale = SIMD3<Float>(-1, -1, -1)
            entity.position = .zero

            content.add(entity)
            domeEntity = entity

            LMLog.visual.info("🌐 MINIMAL TEST: Sphere dome created - radius=\(domeRadius)m, RED material")
        }
        .task {
            await setupTexture()
        }
    }

    // MARK: - Setup

    @MainActor
    private func setupTexture() async {
        LMLog.visual.info("🎨 MINIMAL TEST: Setting up texture...")

        // Wait for first generated image
        LMLog.visual.info("🎨 MINIMAL TEST: Waiting for first image from Nano Banana...")

        // Poll for image (simple approach)
        var waitCount = 0
        while visualEngine.imageBuffer.loadCurrent() == nil {
            waitCount += 1
            if waitCount % 10 == 0 {
                LMLog.visual.info("🎨 MINIMAL TEST: Still waiting for image... (\(waitCount)s)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

            if waitCount > 60 {
                LMLog.visual.error("❌ MINIMAL TEST: Timed out waiting for image after 60s")
                return
            }
        }

        guard let cgImage = visualEngine.imageBuffer.loadCurrent() else {
            LMLog.visual.error("❌ MINIMAL TEST: No image after wait")
            return
        }

        LMLog.visual.info("🎨 MINIMAL TEST: Got image! \(cgImage.width)x\(cgImage.height)")

        do {
            // Create TextureResource directly from CGImage - NO DrawableQueue!
            let resource = try await TextureResource(image: cgImage, options: .init(semantic: .color))
            LMLog.visual.info("🎨 MINIMAL TEST: TextureResource created")

            // Apply texture to sphere dome
            if let entity = domeEntity {
                var material = UnlitMaterial()
                material.color = .init(texture: .init(resource))
                entity.model?.materials = [material]
                LMLog.visual.info("🎨 MINIMAL TEST: ✅ Applied texture to sphere dome!")
            } else {
                LMLog.visual.error("❌ MINIMAL TEST: No dome entity!")
            }

            self.textureResource = resource
            self.isSetupComplete = true

        } catch {
            LMLog.visual.error("❌ MINIMAL TEST: Failed to create TextureResource: \(error.localizedDescription)")
        }
    }
}

#endif
