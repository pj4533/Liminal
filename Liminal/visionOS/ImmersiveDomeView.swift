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

    // Breathing mesh data (MeshResource.replace approach for reliable visual updates)
    @State private var meshResource: MeshResource?
    @State private var basePositions: [SIMD3<Float>] = []
    @State private var baseNormals: [SIMD3<Float>] = []
    @State private var baseUVs: [SIMD2<Float>] = []
    @State private var meshIndices: [UInt32] = []

    // DEBUG: Test with solid color first to verify pipeline
    private let debugSolidColorTest = false

    // Curved panel parameters
    private static let panelRadius: Float = 2.0
    private static let horizontalArc: Float = 110.0
    private static let verticalArc: Float = 75.0
    // Increased segments for smoother breathing deformation
    private static let horizontalSegments: Int = 48
    private static let verticalSegments: Int = 36

    // Panel breathing parameters
    private static let breathingAmplitude: Float = 0.06  // Start aggressive, dial back later
    private static let breathingSpeed: Float = 0.4       // Slow, meditative

    // Cached STATIC mesh (used only when breathing is disabled)
    private static var cachedMesh: MeshResource?

    var body: some View {
        ZStack {
            RealityView { content in
                LMLog.visual.info("🎬 CURVED PANEL: Creating placeholder entity...")

                // Create placeholder mesh (will be replaced with LowLevelMesh in setup)
                let placeholderMesh = MeshResource.generatePlane(width: 0.01, height: 0.01)

                var material = UnlitMaterial(applyPostProcessToneMap: false)
                material.color = .init(tint: .red)

                let entity = ModelEntity(mesh: placeholderMesh, materials: [material])
                entity.position = SIMD3<Float>(0, 1.5, 0)

                content.add(entity)
                panelEntity = entity

                LMLog.visual.info("🎬 CURVED PANEL: Placeholder entity added, setup will create real mesh...")
            }
            .task {
                await setupEffectsRendererWithBreathingMesh()
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
    private func setupEffectsRendererWithBreathingMesh() async {
        loadingState = "Creating breathing mesh..."
        LMLog.visual.info("🫁 Creating breathing mesh (MeshResource.replace approach)...")

        // Create the mesh and store base data for runtime displacement
        guard let meshData = createBreathingMeshData() else {
            loadingState = "❌ Mesh creation failed!"
            LMLog.visual.error("❌ Failed to create breathing mesh!")
            return
        }

        meshResource = meshData.meshResource
        basePositions = meshData.basePositions
        baseNormals = meshData.baseNormals
        baseUVs = meshData.baseUVs
        meshIndices = meshData.indices

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

        // Apply the breathing mesh and texture to the entity
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(texture: .init(textureResource))
        entity.model = ModelComponent(mesh: meshData.meshResource, materials: [material])
        LMLog.visual.info("🎨 ✅ Applied breathing mesh + DrawableQueue texture to panel!")

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

            // Detailed frame timing for stutter investigation
            var consecutiveSlowFrames = 0
            var lastYieldTime: Date = Date()

            while !Task.isCancelled {
                frameCount += 1
                let frameStartTime = Date()

                // Track frame interval (time since last frame started)
                let frameInterval = frameStartTime.timeIntervalSince(lastFrameTime) * 1000
                // Track yield time (time spent in Task.yield + any MainActor contention)
                let yieldDuration = frameStartTime.timeIntervalSince(lastYieldTime) * 1000
                lastFrameTime = frameStartTime

                // Detailed logging for slow frames
                if frameInterval > 15 && frameCount > 1 {
                    droppedFrames += 1
                    consecutiveSlowFrames += 1

                    // Log individual slow frames to find patterns
                    if consecutiveSlowFrames <= 5 || consecutiveSlowFrames % 10 == 0 {
                        LMLog.visual.warning("⚠️ SLOW FRAME #\(frameCount): interval=\(String(format: "%.1f", frameInterval))ms yield=\(String(format: "%.1f", yieldDuration))ms consecutive=\(consecutiveSlowFrames)")
                    }
                } else {
                    if consecutiveSlowFrames > 0 {
                        LMLog.visual.info("✅ Frame timing recovered after \(consecutiveSlowFrames) slow frames")
                    }
                    consecutiveSlowFrames = 0
                }

                // Update effect time
                effectTime = Float(Date().timeIntervalSince(startTime))

                // Update panel mesh with breathing animation (in-place vertex updates)
                updateBreathingMesh(time: effectTime)

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
                // Use raw transitionProgress - shader applies easing (matches macOS)
                // IMPORTANT: Pass 0 when not transitioning, otherwise ghost taps stay disabled forever
                // (transitionProgress stays at 1.0 after transition completes)
                let uniforms = EffectsUniformsComputer.compute(
                    time: effectTime,
                    transitionProgress: transitionState.isTransitioning ? transitionState.transitionProgress : 0,
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

                // Frame pacing: Target 90fps (visionOS refresh rate) to avoid overwhelming compositor
                // Without this, we render at 175fps but compositor only consumes at 90Hz,
                // causing nextDrawable() to block 15-27ms waiting for free textures
                let targetFrameTimeNs: UInt64 = 11_111_111  // ~90fps (11.1ms)
                let frameElapsedNs = UInt64(Date().timeIntervalSince(frameStartTime) * 1_000_000_000)
                if frameElapsedNs < targetFrameTimeNs {
                    let sleepTime = targetFrameTimeNs - frameElapsedNs
                    try? await Task.sleep(nanoseconds: sleepTime)
                }

                lastYieldTime = Date()  // Track when yield returns for next frame's timing
            }
        }
    }

    // MARK: - Mesh Generation (MeshResource.replace approach for reliable visual updates)

    /// Result of mesh creation containing mesh and base geometry data
    struct BreathingMeshData {
        let meshResource: MeshResource
        let basePositions: [SIMD3<Float>]
        let baseNormals: [SIMD3<Float>]
        let baseUVs: [SIMD2<Float>]
        let indices: [UInt32]
    }

    // Breathing logging throttle
    private static var lastBreathingLogTime: Date = .distantPast
    private static var breathingUpdateCount: Int = 0

    /// Creates the breathing mesh with base geometry data for runtime updates
    private func createBreathingMeshData() -> BreathingMeshData? {
        let hArc = Self.horizontalArc * .pi / 180.0
        let vArc = Self.verticalArc * .pi / 180.0

        let startH = -hArc / 2
        let startV = -vArc / 2

        // Build base positions, normals, and UVs
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

                let normal = normalize(SIMD3<Float>(-x, 0, -z))

                positions.append(SIMD3<Float>(x, y, z))
                normals.append(normal)
                uvs.append(SIMD2<Float>(hFrac, 1.0 - vFrac))
            }
        }

        // Build indices
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

        // Create initial MeshResource using MeshDescriptor
        var meshDescriptor = MeshDescriptor()
        meshDescriptor.positions = MeshBuffers.Positions(positions)
        meshDescriptor.normals = MeshBuffers.Normals(normals)
        meshDescriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        meshDescriptor.primitives = .triangles(indices)

        do {
            let meshResource = try MeshResource.generate(from: [meshDescriptor])
            LMLog.visual.info("🫁 BREATHING: MeshResource created - \(positions.count) vertices, \(indices.count/3) triangles")

            return BreathingMeshData(
                meshResource: meshResource,
                basePositions: positions,
                baseNormals: normals,
                baseUVs: uvs,
                indices: indices
            )

        } catch {
            LMLog.visual.error("❌ MeshResource creation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Updates mesh by replacing contents with displaced vertices (MeshResource.replace approach)
    @MainActor
    private func updateBreathingMesh(time: Float) {
        guard let mesh = meshResource else {
            return
        }

        let breathTime = time * Self.breathingSpeed
        let vertexCount = basePositions.count

        // Track displacement range for logging
        var minDisplacement: Float = Float.greatestFiniteMagnitude
        var maxDisplacement: Float = -Float.greatestFiniteMagnitude

        // Calculate displaced positions
        var displacedPositions: [SIMD3<Float>] = []
        displacedPositions.reserveCapacity(vertexCount)

        for i in 0..<vertexCount {
            let basePos = basePositions[i]
            let normal = baseNormals[i]

            // Calculate UV-like coordinates for wave functions
            let v = i / (Self.horizontalSegments + 1)
            let h = i % (Self.horizontalSegments + 1)
            let hFrac = Float(h) / Float(Self.horizontalSegments)
            let vFrac = Float(v) / Float(Self.verticalSegments)

            // BREATHING: Multiple overlapping sine waves
            let wave1 = sin(hFrac * 6.0 + breathTime * 1.0) * 0.4
            let wave2 = sin(vFrac * 5.0 + breathTime * 0.7) * 0.3
            let wave3 = sin((hFrac + vFrac) * 4.0 + breathTime * 0.5) * 0.2
            let centerDist = sqrt(pow(hFrac - 0.5, 2) + pow(vFrac - 0.5, 2))
            let wave4 = sin(centerDist * 8.0 - breathTime * 0.8) * 0.1

            let displacement = (wave1 + wave2 + wave3 + wave4) * Self.breathingAmplitude

            minDisplacement = min(minDisplacement, displacement)
            maxDisplacement = max(maxDisplacement, displacement)

            // Calculate displaced position
            displacedPositions.append(basePos + normal * displacement)
        }

        // Create new mesh descriptor with displaced positions
        var meshDescriptor = MeshDescriptor()
        meshDescriptor.positions = MeshBuffers.Positions(displacedPositions)
        meshDescriptor.normals = MeshBuffers.Normals(baseNormals)
        meshDescriptor.textureCoordinates = MeshBuffers.TextureCoordinates(baseUVs)
        meshDescriptor.primitives = .triangles(meshIndices)

        // Generate new mesh and replace the stored reference
        // Using generate() + replace() approach since direct Contents manipulation is complex
        do {
            let newMesh = try MeshResource.generate(from: [meshDescriptor])
            let contents = newMesh.contents
            try mesh.replace(with: contents)
        } catch {
            // Only log errors occasionally to avoid spam
            if Self.breathingUpdateCount == 0 {
                LMLog.visual.error("❌ Mesh replace failed: \(error.localizedDescription)")
            }
        }

        // Log breathing stats once per second
        Self.breathingUpdateCount += 1
        let now = Date()
        if now.timeIntervalSince(Self.lastBreathingLogTime) >= 1.0 {
            LMLog.visual.info("🫁 BREATHING: updates/sec=\(Self.breathingUpdateCount) time=\(String(format: "%.2f", time)) displacement=[\(String(format: "%.4f", minDisplacement))...\(String(format: "%.4f", maxDisplacement))]")
            Self.breathingUpdateCount = 0
            Self.lastBreathingLogTime = now
        }
    }
}

#endif
