//
//  ImmersiveDomeView.swift
//  Liminal
//
//  RealityKit immersive view with full effects pipeline.
//  Uses OffscreenEffectsRenderer + DrawableQueue for continuous animated effects.
//

#if os(visionOS)

import SwiftUI
import RealityKit
import OSLog

struct ImmersiveDomeView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService

    @State private var panelEntity: ModelEntity?
    @State private var effectsRenderer: OffscreenEffectsRenderer?
    @State private var isSetupComplete = false
    @State private var renderTask: Task<Void, Never>?
    @State private var loadingState: String = "Initializing..."

    // Animation state
    @State private var effectTime: Float = 0

    // DEBUG: Test with solid color first to verify pipeline
    private let debugSolidColorTest = false  // Pipeline verified! Now testing images

    // Curved panel parameters
    private let panelRadius: Float = 2.0        // Distance from user
    private let horizontalArc: Float = 110.0    // Degrees of horizontal coverage
    private let verticalArc: Float = 75.0       // Degrees of vertical coverage
    private let horizontalSegments: Int = 32    // Mesh resolution
    private let verticalSegments: Int = 24

    var body: some View {
        ZStack {
            RealityView { content in
                LMLog.visual.info("🎬 CURVED PANEL: Creating mesh with effects pipeline...")

                // Generate curved panel mesh
                guard let mesh = createCurvedPanelMesh() else {
                    LMLog.visual.error("❌ CURVED PANEL: Failed to create mesh!")
                    return
                }

                // Start with RED material while we set up effects
                var material = UnlitMaterial()
                material.color = .init(tint: .red)

                let entity = ModelEntity(mesh: mesh, materials: [material])
                entity.position = SIMD3<Float>(0, 1.5, 0)  // Eye level

                content.add(entity)
                panelEntity = entity

                LMLog.visual.info("🎬 CURVED PANEL: Entity added, starting effects setup...")
            }
            .task {
                await setupEffectsRenderer()
            }
            .onDisappear {
                renderTask?.cancel()
                LMLog.visual.info("🎬 CURVED PANEL: Render loop cancelled")
            }

            // Loading indicator overlay
            if !isSetupComplete {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(2)
                    Text(loadingState)
                        .font(.title2)
                        .foregroundColor(.white)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }
    }

    // MARK: - Effects Setup

    @MainActor
    private func setupEffectsRenderer() async {
        loadingState = "Creating renderer..."
        LMLog.visual.info("🎨 Setting up OffscreenEffectsRenderer...")

        // Create effects renderer
        guard let renderer = OffscreenEffectsRenderer() else {
            loadingState = "❌ Renderer failed!"
            LMLog.visual.error("❌ Failed to create OffscreenEffectsRenderer!")
            return
        }
        effectsRenderer = renderer

        // Set up DrawableQueue
        loadingState = "Setting up DrawableQueue..."
        do {
            try await renderer.setupDrawableQueue()
            LMLog.visual.info("🎨 DrawableQueue ready!")
        } catch {
            loadingState = "❌ DrawableQueue failed!"
            LMLog.visual.error("❌ DrawableQueue setup failed: \(error.localizedDescription)")
            return
        }

        // Apply the DrawableQueue-backed texture to our panel
        guard let textureResource = renderer.textureResource,
              let entity = panelEntity else {
            loadingState = "❌ No texture/entity!"
            LMLog.visual.error("❌ No texture resource or panel entity!")
            return
        }

        var material = UnlitMaterial()
        material.color = .init(texture: .init(textureResource))
        entity.model?.materials = [material]
        LMLog.visual.info("🎨 ✅ Applied DrawableQueue texture to panel!")

        // Wait for first image (or skip if debug mode)
        if debugSolidColorTest {
            loadingState = "DEBUG: Solid color mode"
            LMLog.visual.info("🔴 DEBUG: Skipping image wait, using solid color test")
        } else {
            loadingState = "Waiting for Gemini image..."
            LMLog.visual.info("🎨 Waiting for first image...")
            var waitCount = 0
            while visualEngine.imageBuffer.loadCurrent() == nil {
                waitCount += 1
                loadingState = "Waiting for image... \(waitCount)s"
                if waitCount % 10 == 0 {
                    LMLog.visual.info("🎨 Still waiting for image... (\(waitCount)s)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if waitCount > 60 {
                    loadingState = "❌ Timed out!"
                    LMLog.visual.error("❌ Timed out waiting for image")
                    return
                }
            }
        }

        loadingState = "Rendering!"
        LMLog.visual.info("🎨 ✅ Starting render loop...")
        isSetupComplete = true

        // Start the continuous effects render loop
        startRenderLoop()
    }

    // MARK: - Render Loop

    @MainActor
    private func startRenderLoop() {
        renderTask = Task { @MainActor in
            var frameCount = 0
            let startTime = Date()

            while !Task.isCancelled {
                frameCount += 1

                // Update effect time (60fps equivalent)
                effectTime = Float(Date().timeIntervalSince(startTime))

                // Get current image from atomic buffer
                guard let cgImage = visualEngine.imageBuffer.loadCurrent(),
                      let renderer = effectsRenderer else {
                    // No image yet, wait and retry
                    try? await Task.sleep(nanoseconds: 16_666_667) // ~60fps
                    continue
                }

                // DEBUG: Test pipeline with solid color first
                let success: Bool
                if debugSolidColorTest {
                    // Fill with solid RED to verify pipeline works
                    success = renderer.renderSolidColor(red: 1.0, green: 0.0, blue: 0.0)
                } else {
                    // Full effects rendering with fBM, hue shift, feedback trails
                    let uniforms = computeUniforms(time: effectTime)
                    success = renderer.renderAndPresent(sourceImage: cgImage, uniforms: uniforms)
                }

                // Log periodically
                if frameCount == 1 || frameCount % 300 == 0 {
                    let fps = Double(frameCount) / Date().timeIntervalSince(startTime)
                    LMLog.visual.info("🎬 Effects render #\(frameCount) | t=\(String(format: "%.1f", effectTime)) | \(String(format: "%.1f", fps))fps | success=\(success)")
                }

                // Target ~60fps (RealityKit will handle actual frame pacing)
                try? await Task.sleep(nanoseconds: 16_666_667)
            }
        }
    }

    // MARK: - Uniform Computation (matches macOS ContentView)

    private func computeUniforms(time: Float) -> EffectsUniforms {
        // Ken Burns: smooth continuous motion matching macOS
        let kenBurnsScale: Float = 1.2 + 0.15 * sin(time * 0.05) + 0.05 * sin(time * 0.03)

        // Ken Burns offset: computed same as macOS, then NORMALIZED by /100
        // macOS divides by 100 before passing to shader (see EffectsMetalViewRepresentable)
        let maxOffset: Float = 60
        let rawOffsetX = maxOffset * sin(time * 0.04) + 20 * sin(time * 0.025)
        let rawOffsetY = maxOffset * cos(time * 0.035) + 20 * cos(time * 0.02)
        let kenBurnsOffsetX = rawOffsetX / 100.0  // Normalize like macOS
        let kenBurnsOffsetY = rawOffsetY / 100.0

        // Distortion: macOS uses 0.012 base, 0.08 speed (NOT 0.3!)
        let distortionAmplitude: Float = 0.012

        // Full effects chain matching macOS EffectsMetalView defaults
        return EffectsUniforms(
            time: time,
            kenBurnsScale: kenBurnsScale,
            kenBurnsOffsetX: kenBurnsOffsetX,
            kenBurnsOffsetY: kenBurnsOffsetY,
            distortionAmplitude: distortionAmplitude,
            distortionSpeed: 0.08,          // macOS default (was 0.3 - too fast!)
            hueBaseShift: 0,
            hueWaveIntensity: 0.5,          // Rainbow spatial waves
            hueBlendAmount: 0.65,           // How much hue shift applies
            contrastBoost: 1.4,
            saturationBoost: 1.3,
            feedbackAmount: 0.5,            // Trails! (controlled by delay slider on macOS)
            feedbackZoom: 0.96,             // < 1 = expand outward
            feedbackDecay: 0.5,             // Ghost fade rate
            saliencyInfluence: 0,           // No saliency map on visionOS yet
            hasSaliencyMap: 0
        )
    }

    // MARK: - Mesh Generation

    private func createCurvedPanelMesh() -> MeshResource? {
        let hArc = horizontalArc * .pi / 180.0
        let vArc = verticalArc * .pi / 180.0

        let startH = -hArc / 2
        let startV = -vArc / 2

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for v in 0...verticalSegments {
            let vFrac = Float(v) / Float(verticalSegments)
            let vAngle = startV + vFrac * vArc

            for h in 0...horizontalSegments {
                let hFrac = Float(h) / Float(horizontalSegments)
                let hAngle = startH + hFrac * hArc

                let x = panelRadius * sin(hAngle)
                let y = panelRadius * tan(vAngle)
                let z = -panelRadius * cos(hAngle)

                positions.append(SIMD3<Float>(x, y, z))
                normals.append(normalize(SIMD3<Float>(-x, 0, -z)))
                uvs.append(SIMD2<Float>(hFrac, 1.0 - vFrac))
            }
        }

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

        var descriptor = MeshDescriptor(name: "CurvedPanel")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            LMLog.visual.error("❌ MeshResource.generate failed: \(error.localizedDescription)")
            return nil
        }
    }
}

#endif
