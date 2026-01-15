//
//  ImmersiveDomeView.swift
//  Liminal
//
//  RealityKit immersive view with full effects pipeline.
//  Uses OffscreenEffectsRenderer + DrawableQueue for continuous animated effects.
//
//  ARCHITECTURE NOTE (visionOS-specific):
//  This view does NOT use MorphPlayer to avoid @Published/@ObservableObject
//  overhead that causes MainActor starvation. Instead:
//  - Uses simple value-type CGImageTransitionState for transitions
//  - Works with CGImage directly (never UIImage/PlatformImage in render path)
//  - Render loop yields explicitly via Task.yield() to prevent blocking
//
//  Crossfade transitions tracked via transitionProgress uniform, effects applied
//  in the Metal shader.
//

#if os(visionOS)

import SwiftUI
import RealityKit
import OSLog

// MARK: - Simple CGImage Transition State (Value Type, No @Published)

/// Lightweight transition tracker for visionOS - no @Observable/@Published overhead
struct CGImageTransitionState {
    var currentImage: CGImage?
    var previousImage: CGImage?
    var transitionStartTime: Date?
    var lastGeneration: UInt64 = 0

    private let crossfadeDuration: Double = 1.5

    /// Raw linear transition progress (0-1)
    var transitionProgress: Float {
        guard let startTime = transitionStartTime else { return 0 }
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / crossfadeDuration, 1.0)
        return Float(progress)
    }

    /// Eased transition progress for smoother perceptual transitions.
    /// Uses ease-out cubic: smoother deceleration at end.
    var easedProgress: Float {
        let t = transitionProgress
        // Ease-out cubic: 1 - (1 - t)^3
        return 1 - pow(1 - t, 3)
    }

    var isTransitioning: Bool {
        guard transitionStartTime != nil else { return false }
        return transitionProgress < 1.0
    }

    mutating func setInitialImage(_ image: CGImage) {
        currentImage = image
        previousImage = nil
        transitionStartTime = nil
    }

    mutating func transitionTo(_ image: CGImage) {
        previousImage = currentImage
        currentImage = image
        transitionStartTime = Date()
    }

    /// Get the image to render. During transitions, returns current image
    /// (the shader will blend using transitionProgress)
    var renderImage: CGImage? {
        currentImage
    }
}

// MARK: - Immersive Dome View

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

    // Simple CGImage transition tracking (no @Observable overhead)
    @State private var transitionState = CGImageTransitionState()

    // DEBUG: Test with solid color first to verify pipeline
    private let debugSolidColorTest = false

    // Curved panel parameters (static to enable mesh caching)
    private static let panelRadius: Float = 2.0
    private static let horizontalArc: Float = 110.0
    private static let verticalArc: Float = 75.0
    private static let horizontalSegments: Int = 32
    private static let verticalSegments: Int = 24

    // Cached mesh (generated once, reused across view recreations)
    private static var cachedMesh: MeshResource?

    var body: some View {
        ZStack {
            RealityView { content in
                LMLog.visual.info("🎬 CURVED PANEL: Creating mesh with effects pipeline...")

                guard let mesh = createCurvedPanelMesh() else {
                    LMLog.visual.error("❌ CURVED PANEL: Failed to create mesh!")
                    return
                }

                var material = UnlitMaterial(applyPostProcessToneMap: false)
                material.color = .init(tint: .red)

                let entity = ModelEntity(mesh: mesh, materials: [material])
                entity.position = SIMD3<Float>(0, 1.5, 0)

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

        guard let renderer = OffscreenEffectsRenderer() else {
            loadingState = "❌ Renderer failed!"
            LMLog.visual.error("❌ Failed to create OffscreenEffectsRenderer!")
            return
        }
        effectsRenderer = renderer

        loadingState = "Setting up DrawableQueue..."
        do {
            try await renderer.setupDrawableQueue()
            LMLog.visual.info("🎨 DrawableQueue ready!")
        } catch {
            loadingState = "❌ DrawableQueue failed!"
            LMLog.visual.error("❌ DrawableQueue setup failed: \(error.localizedDescription)")
            return
        }

        guard let textureResource = renderer.textureResource,
              let entity = panelEntity else {
            loadingState = "❌ No texture/entity!"
            LMLog.visual.error("❌ No texture resource or panel entity!")
            return
        }

        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(texture: .init(textureResource))
        entity.model?.materials = [material]
        LMLog.visual.info("🎨 ✅ Applied DrawableQueue texture to panel!")

        // Wait for first image
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

        // Set initial image directly from CGImage - NO UIImage conversion!
        if let cgImage = visualEngine.imageBuffer.loadCurrent() {
            transitionState.setInitialImage(cgImage)
            transitionState.lastGeneration = visualEngine.imageBuffer.generation()
            LMLog.visual.info("🎬 Initial image set directly from CGImage (gen \(transitionState.lastGeneration))")
        }

        loadingState = "Rendering!"
        LMLog.visual.info("🎨 ✅ Starting render loop (detached from MainActor)...")
        isSetupComplete = true

        // Start the continuous effects render loop - DETACHED from MainActor!
        startRenderLoop()
    }

    // MARK: - Render Loop

    @MainActor
    private func startRenderLoop() {
        // Render loop runs on MainActor (required by OffscreenEffectsRenderer)
        // but yields regularly to allow other MainActor work to proceed.
        // KEY CHANGES from old broken version:
        // 1. NO MorphPlayer (no @Published overhead)
        // 2. NO UIImage/PlatformImage creation (CGImage only)
        // 3. Explicit Task.yield() after each frame
        renderTask = Task { @MainActor in
            var frameCount = 0
            let startTime = Date()

            // Performance tracking
            var lastFrameTime = Date()
            var totalRenderTime: Double = 0
            var maxRenderTime: Double = 0
            var droppedFrames = 0
            var lastStatsTime = Date()

            while !Task.isCancelled {
                frameCount += 1
                let frameStartTime = Date()

                // Track frame interval
                let frameInterval = frameStartTime.timeIntervalSince(lastFrameTime) * 1000
                lastFrameTime = frameStartTime

                if frameInterval > 20 && frameCount > 1 {
                    droppedFrames += 1
                }

                // Update effect time
                effectTime = Float(Date().timeIntervalSince(startTime))

                // Check for new images from AtomicImageBuffer (thread-safe)
                let (rawImage, generation) = visualEngine.imageBuffer.loadWithGeneration()
                if let rawImage = rawImage, generation != transitionState.lastGeneration {
                    transitionState.lastGeneration = generation
                    transitionState.transitionTo(rawImage)
                    LMLog.visual.info("🎬 New image detected (gen \(generation)), triggering transition")
                }

                // Get current CGImage to render - NO UIImage conversion!
                guard let cgImage = transitionState.renderImage,
                      let renderer = effectsRenderer else {
                    if frameCount <= 3 {
                        LMLog.visual.warning("⏳ Frame \(frameCount): waiting for image...")
                    }
                    // CRITICAL: Yield before sleeping to let other MainActor work proceed
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 16_666_667)
                    continue
                }

                // Compute uniforms
                let uniforms = EffectsUniformsComputer.compute(
                    time: effectTime,
                    transitionProgress: transitionState.easedProgress,
                    hasSaliencyMap: false
                )

                // Render frame - pass previous image for GPU crossfade when transitioning
                let renderStartTime = Date()
                let previousImage = transitionState.isTransitioning ? transitionState.previousImage : nil
                _ = renderer.renderAndPresent(sourceImage: cgImage, previousImage: previousImage, uniforms: uniforms, delay: settings.delay)
                let renderTime = Date().timeIntervalSince(renderStartTime) * 1000
                totalRenderTime += renderTime
                maxRenderTime = max(maxRenderTime, renderTime)

                // Log stats every second
                let timeSinceStats = Date().timeIntervalSince(lastStatsTime)
                if timeSinceStats >= 1.0 {
                    let avgRenderTime = totalRenderTime / Double(frameCount)
                    let actualFPS = Double(frameCount) / timeSinceStats
                    let fpsPercent = (actualFPS / 60.0) * 100

                    LMLog.visual.info("📊 visionOS PERF: fps=\(String(format: "%.1f", actualFPS)) (\(String(format: "%.0f", fpsPercent))% of 60) | render avg=\(String(format: "%.1f", avgRenderTime))ms max=\(String(format: "%.1f", maxRenderTime))ms | dropped=\(droppedFrames) | transition=\(String(format: "%.0f", transitionState.transitionProgress * 100))%")

                    frameCount = 0
                    totalRenderTime = 0
                    maxRenderTime = 0
                    droppedFrames = 0
                    lastStatsTime = Date()
                }

                // CRITICAL: Yield to allow other MainActor work (SwiftUI, etc.) to proceed
                // This is the key fix - without yield, the while loop monopolizes MainActor
                await Task.yield()

                // Target ~60fps
                try? await Task.sleep(nanoseconds: 16_666_667)
            }
        }
    }

    // MARK: - Mesh Generation

    /// Creates or returns cached curved panel mesh.
    /// Mesh is cached as static property to avoid regeneration on view recreation.
    private func createCurvedPanelMesh() -> MeshResource? {
        // Return cached mesh if available
        if let cached = Self.cachedMesh {
            LMLog.visual.debug("🎬 CURVED PANEL: Using cached mesh")
            return cached
        }

        LMLog.visual.info("🎬 CURVED PANEL: Generating new mesh...")

        let hArc = Self.horizontalArc * .pi / 180.0
        let vArc = Self.verticalArc * .pi / 180.0

        let startH = -hArc / 2
        let startV = -vArc / 2

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for v in 0...Self.verticalSegments {
            let vFrac = Float(v) / Float(Self.verticalSegments)
            let vAngle = startV + vFrac * vArc

            for h in 0...Self.horizontalSegments {
                let hFrac = Float(h) / Float(Self.horizontalSegments)
                let hAngle = startH + hFrac * hArc

                let x = Self.panelRadius * sin(hAngle)
                let y = Self.panelRadius * tan(vAngle)
                let z = -Self.panelRadius * cos(hAngle)

                positions.append(SIMD3<Float>(x, y, z))
                normals.append(normalize(SIMD3<Float>(-x, 0, -z)))
                uvs.append(SIMD2<Float>(hFrac, 1.0 - vFrac))
            }
        }

        let rowSize = Self.horizontalSegments + 1
        for v in 0..<Self.verticalSegments {
            for h in 0..<Self.horizontalSegments {
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
            let mesh = try MeshResource.generate(from: [descriptor])
            Self.cachedMesh = mesh  // Cache for future use
            LMLog.visual.info("🎬 CURVED PANEL: Mesh cached (\(positions.count) vertices, \(indices.count/3) triangles)")
            return mesh
        } catch {
            LMLog.visual.error("❌ MeshResource.generate failed: \(error.localizedDescription)")
            return nil
        }
    }
}

#endif
