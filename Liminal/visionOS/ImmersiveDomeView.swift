//
//  ImmersiveDomeView.swift
//  Liminal
//
//  RealityKit immersive dome that displays visual effects.
//  Uses an inverted sphere with effects rendered via Metal + DrawableQueue.
//

#if os(visionOS)

import SwiftUI
import RealityKit
import OSLog

struct ImmersiveDomeView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService

    @State private var domeEntity: ModelEntity?
    @State private var effectsRenderer: OffscreenEffectsRenderer?
    @State private var effectTime: Double = 0
    @State private var isRendererReady = false

    private let domeRadius: Float = 50.0

    // Ken Burns computed from effectTime
    private var kenBurnsScale: Float {
        let base: Float = 1.2
        let variation = 0.15 * sin(Float(effectTime) * 0.05) + 0.05 * sin(Float(effectTime) * 0.03)
        return base + Float(variation)
    }

    private var kenBurnsOffsetX: Float {
        let maxOffset: Float = 60
        return maxOffset * sin(Float(effectTime) * 0.04) + 20 * sin(Float(effectTime) * 0.025)
    }

    private var kenBurnsOffsetY: Float {
        let maxOffset: Float = 60
        return maxOffset * cos(Float(effectTime) * 0.035) + 20 * cos(Float(effectTime) * 0.02)
    }

    // Distortion amplitude - can be boosted during transitions
    private var distortionAmplitude: Float {
        return 0.012
    }

    // Feedback amount from delay slider
    private var feedbackAmount: Float {
        return settings.delay * 0.85
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            RealityView { content in
                LMLog.visual.info("🌐 Creating immersive dome...")

                // Create inverted sphere
                let mesh = MeshResource.generateSphere(radius: domeRadius)

                // Start with a simple material - will be replaced when renderer is ready
                var material = UnlitMaterial()
                material.color = .init(tint: .black)

                let entity = ModelEntity(mesh: mesh, materials: [material])

                // Flip scale to invert normals (see inside of sphere)
                entity.scale = SIMD3<Float>(-1, -1, -1)
                entity.position = .zero

                content.add(entity)
                domeEntity = entity

                LMLog.visual.info("🌐 Dome created: radius=\(domeRadius)")
            } update: { content in
                // Update effect time from timeline
                let now = timeline.date.timeIntervalSinceReferenceDate
                effectTime = now

                // Render frame if ready
                renderFrame()
            }
        }
        .task {
            await setupRenderer()
        }
    }

    // MARK: - Setup

    @MainActor
    private func setupRenderer() async {
        LMLog.visual.info("🎨 Setting up effects renderer...")

        guard let renderer = OffscreenEffectsRenderer() else {
            LMLog.visual.error("❌ Failed to create OffscreenEffectsRenderer")
            return
        }

        do {
            try await renderer.setupDrawableQueue()

            // Apply texture to dome
            if let textureResource = renderer.textureResource,
               let entity = domeEntity {
                var material = UnlitMaterial()
                material.color = .init(texture: .init(textureResource))
                entity.model?.materials = [material]
                LMLog.visual.info("🎨 Applied DrawableQueue texture to dome")
            }

            self.effectsRenderer = renderer
            self.isRendererReady = true
            LMLog.visual.info("✅ Effects renderer ready")
        } catch {
            LMLog.visual.error("❌ Failed to setup DrawableQueue: \(error.localizedDescription)")
        }
    }

    // MARK: - Render Loop

    @MainActor
    private func renderFrame() {
        guard isRendererReady,
              let renderer = effectsRenderer,
              let image = visualEngine.currentImage,
              let cgImage = image.cgImageRepresentation else {
            return
        }

        // Build uniforms matching macOS
        let uniforms = EffectsUniforms(
            time: Float(effectTime),
            kenBurnsScale: kenBurnsScale,
            kenBurnsOffsetX: kenBurnsOffsetX,
            kenBurnsOffsetY: kenBurnsOffsetY,
            distortionAmplitude: distortionAmplitude,
            distortionSpeed: 0.08,
            hueBaseShift: 0,
            hueWaveIntensity: 0.5,
            hueBlendAmount: 0.65,
            contrastBoost: 1.4,
            saturationBoost: 1.3,
            feedbackAmount: feedbackAmount,
            feedbackZoom: 0.96,
            feedbackDecay: 0.5,
            saliencyInfluence: 0.6,
            hasSaliencyMap: 0.0  // TODO: Add saliency support
        )

        // Render and present
        _ = renderer.renderAndPresent(sourceImage: cgImage, uniforms: uniforms)
    }
}

#endif
