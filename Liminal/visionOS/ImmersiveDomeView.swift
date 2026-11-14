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

    // GPU-driven breathing mesh (LowLevelMesh + compute shader)
    @State private var domeMesh: LowLevelDomeMesh?

    // Depth map generation
    @State private var depthGenerator: DepthMapGenerator?
    @State private var lastDepthGeneration: UInt64 = 0

    // Stereoscopic per-eye rendering
    @State private var stereoMaterialBuilder: StereoMaterialBuilder?

    // DEBUG: Test with solid color first to verify pipeline
    private let debugSolidColorTest = false

    // Curved panel parameters
    private static let panelRadius: Float = 2.0
    // 112.5° x 75° = 3:2 in view angle, matching ImageFraming.displayAspect so the 3:2 image is
    // shown undistorted (docs/decisions/orientation.md). Was 110° (1.467, a 2% horizontal squeeze).
    private static let verticalArc: Float = 75.0
    private static let horizontalArc: Float = verticalArc * Float(ImageFraming.displayAspect)
    private static let horizontalSegments: Int = 48
    private static let verticalSegments: Int = 36

    // Panel breathing parameters
    private static let breathingAmplitude: Float = 0.04
    private static let breathingSpeed: Float = 0.4

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
                entity.isEnabled = false  // Hidden until first frame is ready to render

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
        LMLog.visual.info("🫁 Creating GPU-driven breathing mesh (LowLevelMesh)...")

        loadingState = "Creating renderer..."
        LMLog.visual.info("🎨 Setting up OffscreenEffectsRenderer...")

        guard let renderer = OffscreenEffectsRenderer() else {
            loadingState = "❌ Renderer failed!"
            LMLog.visual.error("❌ Failed to create OffscreenEffectsRenderer!")
            return
        }
        effectsRenderer = renderer

        // Create LowLevelDomeMesh (breathing is computed on the CPU)
        guard let mesh = LowLevelDomeMesh(
            horizontalSegments: Self.horizontalSegments,
            verticalSegments: Self.verticalSegments,
            panelRadius: Self.panelRadius,
            horizontalArc: Self.horizontalArc,
            verticalArc: Self.verticalArc
        ) else {
            loadingState = "❌ Mesh creation failed!"
            LMLog.visual.error("❌ Failed to create LowLevelDomeMesh!")
            return
        }
        domeMesh = mesh

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

        // Build stereo material for per-eye rendering
        let stereoBuilder = StereoMaterialBuilder(outputSize: 2048)
        do {
            if DebugLaunchOptions.forceMonoMaterial {
                throw CocoaError(.featureUnsupported)  // DEBUG: inspect the mono fallback path
            }
            try await stereoBuilder.build()
            self.stereoMaterialBuilder = stereoBuilder
            if let stereoMat = stereoBuilder.material {
                entity.model = ModelComponent(mesh: mesh.meshResource, materials: [stereoMat])
                LMLog.visual.info("🎨 ✅ Applied stereo ShaderGraphMaterial to panel!")
            } else {
                // Fallback to mono UnlitMaterial
                var material = UnlitMaterial(applyPostProcessToneMap: false)
                material.color = .init(texture: .init(textureResource))
                entity.model = ModelComponent(mesh: mesh.meshResource, materials: [material])
                LMLog.visual.info("🎨 ✅ Applied mono UnlitMaterial (stereo build returned nil)")
            }
        } catch {
            // Fallback to mono UnlitMaterial if stereo fails
            LMLog.visual.warning("⚠️ Stereo material failed: \(error.localizedDescription), falling back to mono")
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(texture: .init(textureResource))
            entity.model = ModelComponent(mesh: mesh.meshResource, materials: [material])
        }

        // Ensure depth model is ready before first render so the first image has depth.
        _ = await ensureDepthGeneratorReady()

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
        if let rawImage = visualEngine.imageBuffer.loadCurrent() {
            let cgImage = ImageFraming.coverCrop(rawImage)
            transitionState.setInitialImage(cgImage)
            transitionState.lastGeneration = visualEngine.imageBuffer.generation()
            LMLog.visual.info("🎬 Initial image set directly from CGImage (gen \(transitionState.lastGeneration))")

            loadingState = "Preparing 3D depth..."
            await generateAndApplyDepth(for: cgImage, logLabel: "initial")
        }

        // Everything is ready — show the dome and start rendering
        panelEntity?.isEnabled = true
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
            var frameIntervals: [Double] = []
            frameIntervals.reserveCapacity(512)
            let perfLogInterval = DebugLaunchOptions.perfLogInterval
            DebugLaunchOptions.logApplied()

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
                if frameCount > 1 { frameIntervals.append(frameInterval) }

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

                // Update effect time (DEBUG: -LiminalFreezeTime pins it for deterministic captures)
                effectTime = DebugLaunchOptions.effectTime(Float(Date().timeIntervalSince(startTime)))

                // Tag this frame's command buffers (eyes) for GPU timing
                effectsRenderer?.gpuStats.beginFrame()

                // Update panel mesh with CPU-computed breathing
                domeMesh?.updateBreathing(
                    time: effectTime,
                    amplitude: Self.breathingAmplitude,
                    speed: Self.breathingSpeed
                )

                // Check for new images from AtomicImageBuffer (thread-safe)
                let (rawImage, generation) = visualEngine.imageBuffer.loadWithGeneration()
                if let rawImage = rawImage, generation != transitionState.lastGeneration {
                    // Centre-crop to the dome's 3:2 once; colour AND depth use the framed image.
                    let framedImage = ImageFraming.coverCrop(rawImage)
                    transitionState.lastGeneration = generation
                    transitionState.transitionTo(framedImage)
                    LMLog.visual.info("🎬 New image detected (gen \(generation)), triggering transition")

                    // Trigger depth map generation in background (~31ms, images change every ~30s)
                    if let depthGen = depthGenerator, !DebugLaunchOptions.forceStereoFlatDepth {
                        let imageBuffer = visualEngine.imageBuffer
                        Task.detached {
                            do {
                                let depth = try await depthGen.generateDepth(from: framedImage)
                                await MainActor.run {
                                    imageBuffer.storeDepth(depth)
                                    self.effectsRenderer?.updateDepthTexture(from: depth)
                                    self.lastDepthGeneration = imageBuffer.loadDepthWithGeneration().generation
                                }
                            } catch {
                                await MainActor.run {
                                    LMLog.visual.error("🗺️ Depth generation failed: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }

                // Poll depth buffer and upload to renderer when new
                let (depthImage, depthGen) = visualEngine.imageBuffer.loadDepthWithGeneration()
                if let depthImage = depthImage, depthGen != lastDepthGeneration {
                    let isFirst = lastDepthGeneration == 0
                    lastDepthGeneration = depthGen
                    effectsRenderer?.updateDepthTexture(from: depthImage)
                    LMLog.visual.info("🗺️ Depth texture uploaded to renderer (depthGen=\(depthGen), \(depthImage.width)x\(depthImage.height)\(isFirst ? " — FIRST, 3D effects now active!" : ""))")
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

                // Render frame - use stereo path if available, otherwise mono
                let renderStartTime = Date()
                let previousImage = transitionState.isTransitioning ? transitionState.previousImage : nil

                if let stereoBuilder = stereoMaterialBuilder,
                   let leftQueue = stereoBuilder.leftDrawableQueue,
                   let rightQueue = stereoBuilder.rightDrawableQueue {
                    // Stereo: render to left/right drawable queues with depth-based parallax
                    let stereoOsc = SmoothOscillator.value(at: effectTime)
                    let stereoOffset = 0.003 + 0.007 * stereoOsc  // Subtle stereo separation
                    _ = renderer.renderStereoAndPresent(
                        sourceImage: cgImage,
                        previousImage: previousImage,
                        uniforms: uniforms,
                        delay: settings.delay,
                        leftQueue: leftQueue,
                        rightQueue: rightQueue,
                        stereoOffset: stereoOffset
                    )
                } else {
                    // Mono fallback
                    _ = renderer.renderAndPresent(sourceImage: cgImage, previousImage: previousImage, uniforms: uniforms, delay: settings.delay)
                }
                let renderTime = Date().timeIntervalSince(renderStartTime) * 1000
                totalRenderTime += renderTime
                maxRenderTime = max(maxRenderTime, renderTime)

                // Log stats every second
                let timeSinceStats = Date().timeIntervalSince(lastStatsTime)
                if timeSinceStats >= perfLogInterval {
                    let avgRenderTime = totalRenderTime / Double(frameCount)
                    let actualFPS = Double(frameCount) / timeSinceStats
                    let fpsPercent = (actualFPS / 60.0) * 100

                    let hasDepth = effectsRenderer?.depthTexture != nil
                    let hasStereo = stereoMaterialBuilder != nil

                    frameIntervals.sort()
                    let intervalP95 = GPUTimingStats.percentile(frameIntervals, 0.95)
                    let gpuFragment = effectsRenderer?.gpuStats.drain().logFragment ?? "gpu n=0"

                    let perfLine = "📊 visionOS PERF: fps=\(String(format: "%.1f", actualFPS)) (\(String(format: "%.0f", fpsPercent))% of 60) | render avg=\(String(format: "%.1f", avgRenderTime))ms max=\(String(format: "%.1f", maxRenderTime))ms | dropped=\(droppedFrames) | transition=\(String(format: "%.0f", transitionState.transitionProgress * 100))% | interval p95=\(String(format: "%.2f", intervalP95))ms | \(gpuFragment)"
                    LMLog.visual.info("\(perfLine, privacy: .public)")
                    LMLog.visual.info("🔮 3D STATUS: depth=\(hasDepth) stereo=\(hasStereo) gen=\(transitionState.lastGeneration)")

                    frameCount = 0
                    totalRenderTime = 0
                    maxRenderTime = 0
                    droppedFrames = 0
                    frameIntervals.removeAll(keepingCapacity: true)
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

    @MainActor
    private func ensureDepthGeneratorReady() async -> DepthMapGenerator? {
        if let existing = depthGenerator {
            return existing
        }
        let generator = await Task.detached(priority: .userInitiated) {
            DepthMapGenerator()
        }.value
        depthGenerator = generator
        if generator != nil {
            LMLog.visual.info("🗺️ DepthMapGenerator ready")
        } else {
            LMLog.visual.error("🗺️ DepthMapGenerator failed to initialize")
        }
        return generator
    }

    @MainActor
    private func generateAndApplyDepth(for image: CGImage, logLabel: String) async {
        if DebugLaunchOptions.forceStereoFlatDepth {
            // DEBUG: constant mid-grey depth (zero parallax variation) instead of the ML map.
            let flat = Self.makeFlatDepthMap()
            visualEngine.imageBuffer.storeDepth(flat)
            effectsRenderer?.updateDepthTexture(from: flat)
            lastDepthGeneration = visualEngine.imageBuffer.loadDepthWithGeneration().generation
            LMLog.visual.info("🗺️ \(logLabel): FLAT debug depth uploaded (\(flat.width)x\(flat.height))")
            return
        }
        guard let generator = await ensureDepthGeneratorReady() else {
            LMLog.visual.error("🗺️ \(logLabel): No depth generator available")
            return
        }

        do {
            let depth = try await generator.generateDepth(from: image)
            visualEngine.imageBuffer.storeDepth(depth)
            effectsRenderer?.updateDepthTexture(from: depth)
            lastDepthGeneration = visualEngine.imageBuffer.loadDepthWithGeneration().generation
            LMLog.visual.info("🗺️ \(logLabel): Depth generated + uploaded (\(depth.width)x\(depth.height))")
        } catch {
            LMLog.visual.error("🗺️ \(logLabel): Depth generation failed: \(error.localizedDescription)")
        }
    }

    /// Constant 0.5 depth map (DEBUG -LiminalForceStereoFlatDepth), same size as DepthAnything output.
    private static func makeFlatDepthMap() -> CGImage {
        let w = 518, h = 392
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}

#endif
