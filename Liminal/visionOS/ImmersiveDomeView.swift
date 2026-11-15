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
import ImageIO

// MARK: - Simple CGImage Transition State (Value Type, No @Published)

/// Lightweight transition tracker for visionOS - no @Observable/@Published overhead
struct CGImageTransitionState {
    var currentImage: CGImage?
    var previousImage: CGImage?
    var transitionStartTime: Date?
    var lastGeneration: UInt64 = 0

    private let crossfadeDuration: Double = VisualMoodBuilder.crossfadeDuration

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
    /// Plain reference, not observed: only its nonisolated bus and visual-input methods are used (C13).
    let music: GenerativeEngine

    /// Shell centre (viewer's head at entry); parent of the three tile entities.
    @State private var shellRoot: Entity?
    @State private var effectsRenderer: OffscreenEffectsRenderer?
    @State private var isSetupComplete = false
    @State private var renderTask: Task<Void, Never>?
    @State private var loadingState: String = "Initializing..."

    // Animation state
    @State private var effectTime: Float = 0

    // Simple CGImage transition tracking (no @Observable overhead)
    @State private var transitionState = CGImageTransitionState()

    // Spatial shell tile mesh (LowLevelMesh, CPU-written relief + breathing), shared by all tiles
    @State private var shellMesh: SpatialShellMesh?
    /// Depth relief fields (previous / current image) for the shell.
    @State private var relief = ReliefBlend()

    // Depth map generation
    @State private var depthGenerator: DepthMapGenerator?
    @State private var lastDepthGeneration: UInt64 = 0

    // DEBUG A/B only (-LiminalShellTextureStereo): old per-eye texture parallax on the hero tile
    @State private var stereoMaterialBuilder: StereoMaterialBuilder?

    // DEBUG: Test with solid color first to verify pipeline
    private let debugSolidColorTest = false

    // Shell geometry, fades and relief constants: ShellLayout (docs/plans/spatial.md).

    /// Shell centre until HeadPoseProvider places it (phase 3): standing eye height.
    private static let shellCentre = SIMD3<Float>(0, 1.5, 0)

    /// DEBUG harness (-LiminalShellYaw / -LiminalShellPitch): rotating the scene by this brings the
    /// content at (yaw, pitch) in front of the fixed simulator camera. Identity in Release.
    static var debugViewRotation: simd_quatf {
        ShellLayout.viewRotation(yawDeg: DebugLaunchOptions.shellYaw, pitchDeg: DebugLaunchOptions.shellPitch)
    }

    var body: some View {
        ZStack {
            RealityView { content in
                // Shell root at the viewer's head; the tiles are added in setup.
                let root = Entity()
                root.name = "LiminalShell"
                root.position = Self.shellCentre - DebugLaunchOptions.shellHeadOffset
                root.orientation = Self.debugViewRotation
                root.isEnabled = false  // Hidden until the first frame is ready to render
                content.add(root)
                shellRoot = root
                LMLog.visual.info("🎬 SHELL: root entity added, setup will create the tiles...")
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

        // One shell tile mesh shared by the three tiles (relief + breathing written on the CPU)
        guard let mesh = SpatialShellMesh() else {
            loadingState = "❌ Mesh creation failed!"
            LMLog.visual.error("❌ Failed to create SpatialShellMesh!")
            return
        }
        shellMesh = mesh

        loadingState = "Setting up DrawableQueue..."
        do {
            try await renderer.setupDrawableQueue()
            LMLog.visual.info("🎨 DrawableQueue ready!")
        } catch {
            loadingState = "❌ DrawableQueue failed!"
            LMLog.visual.error("❌ DrawableQueue setup failed: \(error.localizedDescription)")
            return
        }

        guard let monoTexture = renderer.textureResource, let root = shellRoot else {
            loadingState = "❌ No texture/entity!"
            LMLog.visual.error("❌ No texture resource or shell root!")
            return
        }

        await buildTiles(mesh: mesh, monoTexture: monoTexture, root: root)

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
        let initial = visualEngine.imageBuffer.loadCurrentWithMetadata()
        if let rawImage = initial.image {
            let cgImage = ImageFraming.coverCrop(rawImage)
            transitionState.setInitialImage(cgImage)
            transitionState.lastGeneration = initial.generation
            relief.imageChanged(generation: initial.generation)
            LMLog.visual.info("🎬 Initial image set directly from CGImage (gen \(transitionState.lastGeneration))")
            // Visuals -> music: first image sets the mood, no imageDidChange (no crossfade).
            postVisualMood(metadata: initial.metadata, image: cgImage, imageChanged: false)

            loadingState = "Preparing 3D depth..."
            await generateAndApplyDepth(for: cgImage, logLabel: "initial")
        }

        // Everything is ready — show the shell and start rendering
        shellRoot?.isEnabled = true
        loadingState = "Rendering!"
        LMLog.visual.info("🎨 ✅ Starting render loop (detached from MainActor)...")
        isSetupComplete = true

        // Start the continuous effects render loop - DETACHED from MainActor!
        startRenderLoop()
    }

    /// Three tiles (hero, right, left) sharing `mesh`, each with its own faded material.
    /// Default: every tile samples the one mono effects texture. DEBUG -LiminalShellTextureStereo:
    /// the hero uses the old per-eye stereo material and the sides its left-eye texture.
    /// Fallback if ShaderGraph fails: mono UnlitMaterial on the hero only.
    @MainActor
    private func buildTiles(mesh: SpatialShellMesh, monoTexture: TextureResource, root: Entity) async {
        var sideTexture = monoTexture
        var heroOverride: ShaderGraphMaterial?
        if DebugLaunchOptions.shellTextureStereo {
            let stereoBuilder = StereoMaterialBuilder(outputSize: 2048)
            do {
                try await stereoBuilder.build()
                if let mat = stereoBuilder.material, let left = stereoBuilder.leftTextureResource {
                    stereoMaterialBuilder = stereoBuilder
                    heroOverride = mat
                    sideTexture = left
                }
            } catch {
                LMLog.visual.warning("⚠️ Texture-stereo A/B material failed: \(error.localizedDescription); using mono")
            }
        }

        for tile in ShellLayout.Tile.allCases {
            let material: any RealityKit.Material
            do {
                if tile == .hero, let heroOverride {
                    var m = heroOverride
                    m.faceCulling = .none
                    material = m
                } else {
                    if DebugLaunchOptions.forceMonoMaterial { throw CocoaError(.featureUnsupported) }
                    material = try await ShellMaterialBuilder.build(texture: sideTexture, tile: tile)
                }
            } catch {
                guard tile == .hero else {
                    LMLog.visual.warning("⚠️ Shell material failed for \(String(describing: tile)): \(error.localizedDescription); tile hidden")
                    continue
                }
                LMLog.visual.warning("⚠️ Shell material failed: \(error.localizedDescription), mono UnlitMaterial on the hero only")
                var unlit = UnlitMaterial(applyPostProcessToneMap: false)
                unlit.color = .init(texture: .init(monoTexture))
                unlit.faceCulling = .none
                material = unlit
            }
            let entity = ModelEntity(mesh: mesh.meshResource, materials: [material])
            entity.name = "ShellTile-\(tile)"
            entity.transform = Transform(scale: [tile.isMirrored ? -1 : 1, 1, 1],
                                         rotation: simd_quatf(angle: tile.yaw, axis: [0, 1, 0]))
            root.addChild(entity)
        }
        LMLog.visual.info("🎨 ✅ Shell tiles built (\(root.children.count)) texture=\(DebugLaunchOptions.shellTextureStereo && stereoMaterialBuilder != nil ? "stereo A/B" : "mono", privacy: .public)")
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
            var totalMeshTime: Double = 0
            var lastReliefK: Float = 0
            var lastCycleSwitch = Date()
            var cycleIndex = 0
            var lastReliefW: Float = 0
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

            // Music <-> visuals coupling (docs/plans/av-coupling.md); local to this loop, no locks.
            var reactor = MusicReactor(strength: DebugLaunchOptions.syncStrength)
            var activityThrottle = VisualActivityThrottle()
            var lastSyncLogTime = Date.distantPast
            let musicBus = music.musicState
            // Effect look (docs/plans/effects-balance.md 7.3): intensity eased toward the setting,
            // image age from the start of the current crossfade.
            var intensitySmoother = EffectIntensitySmoother()
            var transitionStartEffectTime: Float?

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

                // Check for new images from AtomicImageBuffer (thread-safe)
                // One atomic read of image, metadata and generation (C10).
                // DEBUG -LiminalShellCycle: switch to the next fixture image every N seconds.
                if !Self.debugCycle.isEmpty, frameStartTime.timeIntervalSince(lastCycleSwitch) >= DebugLaunchOptions.shellCycleSeconds {
                    lastCycleSwitch = frameStartTime
                    cycleIndex = (cycleIndex + 1) % Self.debugCycle.count
                    visualEngine.imageBuffer.storeCurrent(Self.debugCycle[cycleIndex].image, metadata: nil)
                    LMLog.visual.info("🧪 DEBUG: shell cycle -> image \(cycleIndex)")
                }
                let (rawImage, metadata, generation) = visualEngine.imageBuffer.loadCurrentWithMetadata()
                if let rawImage = rawImage, generation != transitionState.lastGeneration {
                    // Centre-crop to the dome's 3:2 once; colour AND depth use the framed image.
                    let framedImage = ImageFraming.coverCrop(rawImage)
                    let depthOverride = Self.debugDepth(for: rawImage)
                    let wasFirst = transitionState.currentImage == nil
                    transitionState.lastGeneration = generation
                    transitionState.transitionTo(framedImage)
                    relief.imageChanged(generation: generation)
                    if !wasFirst { transitionStartEffectTime = effectTime }
                    LMLog.visual.info("🎬 New image detected (gen \(generation)), triggering transition")
                    // Visuals -> music at the crossfade start.
                    postVisualMood(metadata: metadata, image: framedImage, imageChanged: !wasFirst)

                    // Trigger depth map generation in background (~31ms, images change every ~30s)
                    if let depthGen = depthGenerator, !DebugLaunchOptions.forceStereoFlatDepth {
                        let imageBuffer = visualEngine.imageBuffer
                        Task.detached {
                            do {
                                let depth: CGImage
                                if let d = depthOverride { depth = d } else { depth = try await depthGen.generateDepth(from: framedImage) }
                                let field = Self.buildRelief(depth, generation: generation)
                                await MainActor.run {
                                    imageBuffer.storeDepth(depth)
                                    self.effectsRenderer?.updateDepthTexture(from: depth)
                                    self.lastDepthGeneration = imageBuffer.loadDepthWithGeneration().generation
                                    self.relief.depthArrived(field.q, generation: generation, now: Date().timeIntervalSince1970)
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
                // Per-image vibrance factors (measured once per image, cached), blended across a crossfade
                var vibrance = ImageColorStats.cachedFactors(key: cgImage) { cgImage }
                if transitionState.isTransitioning, let prev = transitionState.previousImage {
                    let from = ImageColorStats.cachedFactors(key: prev) { prev }
                    vibrance = VibranceFactors.lerp(from, vibrance, transitionState.transitionProgress)
                }
                let transitionProgress = transitionState.isTransitioning ? transitionState.transitionProgress : 0
                // Music -> visuals: one seqlock read and ~10 one-pole updates. visionOS has no un-synced
                // hue drift (baseHueRate 0). Frozen time bypasses the reactor (deterministic captures).
                let modulation: MusicModulation
                if DebugLaunchOptions.freezeTime != nil {
                    modulation = .neutral
                } else {
                    modulation = reactor.update(state: musicBus.read(), now: musicBus.now(), effectTime: effectTime,
                                                enabled: settings.syncVisualsToMusic, baseHueRate: 0)
                }
                renderer.requestGhostBurst(serial: modulation.ghostBurstSerial)
                let intensityTarget = DebugLaunchOptions.effectIntensity(setting: settings.effectIntensity)
                let look = EffectLook(
                    intensity: DebugLaunchOptions.freezeTime != nil
                        ? intensityTarget : intensitySmoother.next(target: intensityTarget, time: effectTime),
                    imageAge: transitionStartEffectTime.map { effectTime - $0 }.flatMap { $0 >= 0 ? $0 : nil },
                    imageInterval: Float(settings.imageInterval))
                let uniforms = EffectsUniformsComputer.compute(
                    time: effectTime,
                    transitionProgress: transitionProgress,
                    hasSaliencyMap: false,
                    vibrance: vibrance,
                    music: modulation,
                    look: look
                )

                // Visuals -> music activity (un-modulated oscillators, follows the clarity drive; at most 2 Hz)
                let activity = EffectsUniformsComputer.visualActivity(time: effectTime, transitionProgress: transitionProgress,
                                                                      look: look)
                if let a = activityThrottle.next(activity, at: Double(effectTime)) { music.setVisualActivity(a) }
                if DebugLaunchOptions.syncLog, frameStartTime.timeIntervalSince(lastSyncLogTime) >= 1 {
                    lastSyncLogTime = frameStartTime
                    let neutral = EffectsUniformsComputer.compute(time: effectTime, transitionProgress: transitionProgress,
                                                                  hasSaliencyMap: false, vibrance: vibrance, look: look)
                    let line = MusicSyncLog.line(reactor: reactor, state: musicBus.read(), uniforms: uniforms, neutral: neutral,
                                                 mood: sentMood.load(), activity: activityThrottle.lastSent)
                    LMLog.visual.info("\(line, privacy: .public)")
                }

                // Shell vertices: relief + breathing (vDSP, ~11k vertices). Relief strength follows the
                // Depth amount, the clarity cycle and the transition (ShellLayout.reliefStrength).
                let meshStart = Date()
                let reliefK = ShellLayout.reliefStrength(
                    depth: DebugLaunchOptions.shellDepth ?? ShellLayout.defaultDepth,
                    drive: look.drive(time: effectTime), transitionProgress: transitionProgress)
                let reliefW = relief.weight(transitionProgress: transitionState.isTransitioning ? transitionState.transitionProgress : nil,
                                            now: frameStartTime.timeIntervalSince1970)
                shellMesh?.update(previous: relief.previous, current: relief.current, weight: reliefW, k: reliefK, time: effectTime)
                totalMeshTime += Date().timeIntervalSince(meshStart) * 1000
                lastReliefK = reliefK
                lastReliefW = reliefW

                // Render frame: one mono effects pass shown on every tile (decision S4); the per-eye
                // stereo path only for the DEBUG texture-stereo A/B.
                let renderStartTime = Date()
                let previousImage = transitionState.isTransitioning ? transitionState.previousImage : nil

                if let stereoBuilder = stereoMaterialBuilder,
                   let leftQueue = stereoBuilder.leftDrawableQueue,
                   let rightQueue = stereoBuilder.rightDrawableQueue {
                    // DEBUG A/B: left/right drawable queues with texture-space depth parallax
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
                    LMLog.visual.info("🔮 3D STATUS: depth=\(hasDepth) textureStereo=\(hasStereo) gen=\(transitionState.lastGeneration) mesh avg=\(String(format: "%.3f", totalMeshTime / Double(max(frameCount, 1))), privacy: .public)ms relief k=\(String(format: "%.3f", lastReliefK), privacy: .public) w=\(String(format: "%.2f", lastReliefW), privacy: .public) fields=\(relief.previous != nil ? 1 : 0)+\(relief.current != nil ? 1 : 0)")

                    frameCount = 0
                    totalRenderTime = 0
                    totalMeshTime = 0
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

    /// Last mood sent (for the sync log); written from the background mood task.
    private let sentMood = SentMoodRecord()

    /// Visuals -> music. `imageDidChange` is posted immediately (the conductor lands its chord change on the
    /// crossfade midpoint); the mood needs one 32x32 pass over the image, done off the render loop.
    @MainActor
    private func postVisualMood(metadata: ImageMetadata?, image: CGImage, imageChanged: Bool) {
        if imageChanged { music.imageDidChange(transitionDuration: VisualMoodBuilder.crossfadeDuration) }
        let music = self.music
        let record = sentMood
        Task.detached(priority: .utility) {
            let mood = VisualMoodBuilder.mood(metadata: metadata, image: image)
            music.setVisualMood(mood)
            record.store(mood)
            LMLog.visual.info("🎼 setVisualMood b=\(String(format: "%.2f", mood.brightness), privacy: .public) w=\(String(format: "%.2f", mood.warmth), privacy: .public) s=\(String(format: "%.2f", mood.saturation), privacy: .public) e=\(String(format: "%.2f", mood.energy), privacy: .public) words=\(mood.moodWords.joined(separator: ","), privacy: .public) imageDidChange=\(imageChanged)")
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
            relief.depthArrived(DepthReliefField.flat.q, generation: transitionState.lastGeneration, now: Date().timeIntervalSince1970)
            return
        }
        guard let generator = await ensureDepthGeneratorReady() else {
            LMLog.visual.error("🗺️ \(logLabel): No depth generator available")
            return
        }

        do {
            let depth: CGImage
            if let d = Self.debugDepthImage { depth = d } else { depth = try await generator.generateDepth(from: image) }
            visualEngine.imageBuffer.storeDepth(depth)
            effectsRenderer?.updateDepthTexture(from: depth)
            lastDepthGeneration = visualEngine.imageBuffer.loadDepthWithGeneration().generation
            LMLog.visual.info("🗺️ \(logLabel): Depth generated + uploaded (\(depth.width)x\(depth.height))")
            let generation = transitionState.lastGeneration
            let field = await Task.detached(priority: .userInitiated) { Self.buildRelief(depth, generation: generation) }.value
            relief.depthArrived(field.q, generation: generation, now: Date().timeIntervalSince1970)
        } catch {
            LMLog.visual.error("🗺️ \(logLabel): Depth generation failed: \(error.localizedDescription)")
        }
    }

    /// DEBUG -LiminalDepthImage: depth map loaded from a file (nil when the flag is not set).
    nonisolated private static let debugDepthImage: CGImage? = {
        guard let path = DebugLaunchOptions.depthImagePath,
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }()

    /// DEBUG -LiminalShellCycle: (image, depth) pairs loaded from files.
    nonisolated private static let debugCycle: [(image: CGImage, depth: CGImage?)] = {
        func load(_ path: String) -> CGImage? {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        return DebugLaunchOptions.shellCycle.compactMap { item in
            load(item.image).map { ($0, item.depth.flatMap(load)) }
        }
    }()

    /// DEBUG depth override for a source image: its -LiminalShellCycle depth map, else -LiminalDepthImage.
    nonisolated private static func debugDepth(for image: CGImage) -> CGImage? {
        debugCycle.first { $0.image === image }?.depth ?? debugDepthImage
    }

    /// Relief field for a depth map (off the main actor; a few ms). Logs range, slope and time.
    nonisolated private static func buildRelief(_ depth: CGImage, generation: UInt64) -> DepthReliefField {
        let start = Date()
        let field = DepthReliefField.build(depthImage: depth) ?? .flat
        let ms = Date().timeIntervalSince(start) * 1000
        let r = field.range
        let step = DepthReliefField.maxNeighbourStep(field.q, cols: DepthReliefField.columns, rows: DepthReliefField.rows)
        LMLog.visual.info("🏔️ Relief field gen=\(generation) q=[\(String(format: "%.3f", r.min), privacy: .public), \(String(format: "%.3f", r.max), privacy: .public)] maxStep=\(String(format: "%.4f", step), privacy: .public) built in \(String(format: "%.1f", ms), privacy: .public)ms")
        return field
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
