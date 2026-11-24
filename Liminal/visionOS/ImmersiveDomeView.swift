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
import Metal
import Synchronization

// MARK: - Simple CGImage Transition State (Value Type, No @Published)

/// Lightweight transition tracker for visionOS - no @Observable/@Published overhead
struct CGImageTransitionState {
    var currentImage: CGImage?
    var previousImage: CGImage?
    var transitionStartTime: Date?
    var beatReveal: LofiImageReveal?
    var lastGeneration: UInt64 = 0

    /// The running (or last) transition; its duration drives the progress (docs/plans/transitions.md 7).
    var spec: TransitionSpec = .classic

    /// Raw linear transition progress (0-1)
    var transitionProgress: Float {
        guard let startTime = transitionStartTime else { return 0 }
        if let beatReveal {
            // A drop is evaluated when the frame reaches the display, so its cut lands on the downbeat.
            let lead = beatReveal.isDrop ? LofiImageReveal.displayLead : 0
            return max(0.000001, Float(beatReveal.progress(at: ArchiveFootageService.uptime() + lead)))
        }
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / Double(max(spec.duration, 0.1)), 1.0)
        return Float(progress)
    }

    var isTransitioning: Bool {
        guard transitionStartTime != nil else { return false }
        return transitionProgress < 1.0
    }

    /// The running drop's frame at this frame's presentation time (nil outside a drop).
    var dropFrame: DropFrame? {
        guard transitionStartTime != nil, let beatReveal, beatReveal.isDrop else { return nil }
        return beatReveal.frame(presentedAt: ArchiveFootageService.uptime() + LofiImageReveal.displayLead)
    }

    mutating func setInitialImage(_ image: CGImage) {
        currentImage = image
        previousImage = nil
        transitionStartTime = nil
    }

    mutating func transitionTo(_ image: CGImage, reveal: LofiImageReveal? = nil) {
        beatReveal = reveal
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

// MARK: - Off-main image preparation (docs/decisions/performance.md, image-change hitch)

/// A new image made ready for the render loop off the main actor: framed for display, its
/// vibrance factors cached, and its 2048² source texture built. The render loop only swaps
/// references and starts the transition when this arrives (a few frames after the image does).
nonisolated struct PreparedImage: @unchecked Sendable {
    let generation: UInt64
    let framed: CGImage
    let depthOverride: CGImage?
    let texture: MTLTexture?
    let milliseconds: Double
}

/// Hand-off from the preparation task to the render loop (latest result wins).
nonisolated final class PreparedImageSlot: Sendable {
    struct Depth: Sendable {
        let image: CGImage
        let field: DepthReliefField
        let texture: MTLTexture?
    }

    let generation: UInt64
    init(generation: UInt64) { self.generation = generation }

    private let depth = Mutex<Depth?>(nil)
    func storeDepth(_ prepared: Depth) { depth.withLock { $0 = prepared } }
    func takeDepth() -> Depth? { depth.withLock { v in defer { v = nil }; return v } }

    private let value = Mutex<PreparedImage?>(nil)
    func store(_ prepared: PreparedImage) { value.withLock { $0 = prepared } }
    func take() -> PreparedImage? { value.withLock { v in defer { v = nil }; return v } }
}

// MARK: - Immersive Dome View

struct ImmersiveDomeView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService
    /// Plain reference, not observed: only its nonisolated bus and visual-input methods are used (C13).
    let music: GenerativeEngine
    @Binding var isImmersed: Bool
    @Binding var controlsVisible: Bool
    @Binding var immersivePictureReady: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Shell centre (viewer's head at entry); parent of the three tile entities.
    @State private var shellRoot: Entity?
    @State private var effectsRenderer: OffscreenEffectsRenderer?
    @State private var isSetupComplete = false
    @State private var renderTask: Task<Void, Never>?
    @State private var loadingState: String = "Initializing..."

    // Simple CGImage transition tracking (no @Observable overhead)
    @State private var transitionState = CGImageTransitionState()

    // Spatial shell tile mesh (LowLevelMesh, CPU-written relief + breathing), shared by all tiles
    @State private var shellMesh: SpatialShellMesh?
    /// Depth relief fields (previous / current image) for the shell.
    @State private var relief = ReliefBlend()

    // Depth map generation
    @State private var depthGenerator: DepthMapGenerator?
    @State private var lastDepthGeneration: UInt64 = 0

    /// ARKit head pose: entry placement and slow re-centre (fallback centre when unavailable).
    @State private var headPose: HeadPoseProvider?
    /// Entry yaw of the shell (radians), applied under the DEBUG view rotation.
    @State private var shellYaw: Float = 0

    // DEBUG A/B only (-LiminalShellTextureStereo): old per-eye texture parallax on the hero tile
    @State private var stereoMaterialBuilder: StereoMaterialBuilder?

    // DEBUG: Test with solid color first to verify pipeline
    private let debugSolidColorTest = false

    // Shell geometry, fades and relief constants: ShellLayout (docs/plans/spatial.md).

    /// Shell centre until HeadPoseProvider places it: standing eye height.
    private static let shellCentre = ShellPlacement.fallbackCentre

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
                root.addChild(Self.makeControlsTapTarget())
                content.add(root)
                shellRoot = root
                LMLog.visual.info("🎬 SHELL: root entity added, setup will create the tiles...")
            }
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in toggleControls() })
            .task {
                await setupEffectsRendererWithBreathingMesh()
            }
            .onDisappear {
                immersivePictureReady = false
                RecordingController.shared.playbackStopped()
                renderTask?.cancel()
                ArchiveFootageService.shared.stop()
                headPose?.stop()
                isImmersed = false
                if !controlsVisible { showControls() }
                LMLog.visual.info("🎬 SHELL: Render loop cancelled")
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

    private func toggleControls() {
        guard isImmersed else { return }
        if controlsVisible {
            controlsVisible = false
            dismissWindow(id: LiminalVisionApp.controlsWindowID)
            LMLog.general.info("Immersive tap hid controls")
        } else {
            showControls()
            LMLog.general.info("Immersive tap showed controls")
        }
    }

    private func showControls() {
        controlsVisible = true
        openWindow(id: LiminalVisionApp.controlsWindowID)
    }

    /// Thin box walls catch taps looking out from inside the shell. The collision is
    /// for input only and remains separate from the deforming render mesh.
    private static func makeControlsTapTarget() -> Entity {
        let target = Entity()
        target.name = "ImmersiveControlsTapTarget"
        let extent: Float = 12
        let distance = extent / 2
        let walls = [
            ShapeResource.generateBox(size: [0.04, extent, extent]).offsetBy(translation: [distance, 0, 0]),
            ShapeResource.generateBox(size: [0.04, extent, extent]).offsetBy(translation: [-distance, 0, 0]),
            ShapeResource.generateBox(size: [extent, 0.04, extent]).offsetBy(translation: [0, distance, 0]),
            ShapeResource.generateBox(size: [extent, 0.04, extent]).offsetBy(translation: [0, -distance, 0]),
            ShapeResource.generateBox(size: [extent, extent, 0.04]).offsetBy(translation: [0, 0, distance]),
            ShapeResource.generateBox(size: [extent, extent, 0.04]).offsetBy(translation: [0, 0, -distance]),
        ]
        target.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        target.components.set(CollisionComponent(shapes: walls, filter: CollisionFilter(group: [], mask: [])))
        return target
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
        await placeShellAtHead(root)

        // Ensure depth model is ready before first render so the first image has depth.
        _ = await ensureDepthGeneratorReady()

        // Wait for first image
        if debugSolidColorTest {
            loadingState = "DEBUG: Solid color mode"
            LMLog.visual.info("🔴 DEBUG: Skipping image wait, using solid color test")
        } else {
            loadingState = "Waiting for a picture..."
            LMLog.visual.info("🎨 Waiting for first image...")
            var waitCount = 0
            while visualEngine.imageBuffer.loadCurrent() == nil {
                if Task.isCancelled { return }
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
        let initial = visualEngine.imageBuffer.loadCurrentWithGeneration()
        if let rawImage = initial.image {
            let uploader = renderer.textureUploader
            let generation = initial.generation
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.prepareImage(rawImage, generation: generation, uploader: uploader)
            }.value
            let cgImage = prepared.framed
            if let texture = prepared.texture { renderer.registerPreparedTexture(texture, for: cgImage) }
            transitionState.setInitialImage(cgImage)
            transitionState.lastGeneration = initial.generation
            relief.imageChanged(generation: initial.generation)
            LMLog.visual.info("🎬 Initial image set directly from CGImage (gen \(transitionState.lastGeneration))")

            loadingState = "Preparing 3D depth..."
            await generateAndApplyDepth(for: cgImage, logLabel: "initial")
        }

        // Left the space while setting up (the .task is cancelled on disappear, after onDisappear
        // already ran): starting the loop now would leave it running with nothing to cancel it.
        guard !Task.isCancelled else {
            headPose?.stop()
            LMLog.visual.info("🎬 SHELL: setup cancelled (space closed), render loop not started")
            return
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
    /// A full surround fills the poles and rear gap behind the depth-displaced tiles.
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
        LMLog.visual.info("🎨 ✅ Shell tiles built (\(root.children.filter { $0 is ModelEntity }.count)) texture=\(DebugLaunchOptions.shellTextureStereo && stereoMaterialBuilder != nil ? "stereo A/B" : "mono", privacy: .public)")

        let surroundMaterial: any RealityKit.Material
        do {
            surroundMaterial = try await ShellMaterialBuilder.buildSurround(texture: sideTexture)
        } catch {
            LMLog.visual.warning("⚠️ Surround material failed: \(error.localizedDescription); using standard spherical mapping")
            var unlit = UnlitMaterial(applyPostProcessToneMap: false)
            unlit.color = .init(texture: .init(sideTexture))
            unlit.faceCulling = .front
            surroundMaterial = unlit
        }
        // Outside the shell's largest possible corner (farRadius / cos(60°) = 12 m).
        let surround = ModelEntity(mesh: .generateSphere(radius: 14), materials: [surroundMaterial])
        surround.name = "ShellSurround"
        root.addChild(surround)
        LMLog.visual.info("🎨 ✅ Full shell surround built")
    }

    /// Entry placement: centre the shell on the head and face the entry yaw (ARKit), else the
    /// fallback centre facing forward. The DEBUG head offset / view rotation apply on top.
    @MainActor
    private func placeShellAtHead(_ root: Entity) async {
        let provider = HeadPoseProvider()
        headPose = provider
        await provider.start()
        let pose = await provider.entryPose()
        let centre = pose?.position ?? Self.shellCentre
        shellYaw = pose?.yaw ?? 0
        root.position = centre - DebugLaunchOptions.shellHeadOffset
        root.orientation = simd_quatf(angle: shellYaw, axis: [0, 1, 0]) * Self.debugViewRotation
        LMLog.visual.info("🧭 SHELL placed at (\(String(format: "%.2f, %.2f, %.2f", centre.x, centre.y, centre.z), privacy: .public)) yaw=\(String(format: "%.1f", shellYaw * 180 / .pi), privacy: .public)° source=\(pose == nil ? "fallback" : "ARKit", privacy: .public)")
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
            var submittedFrames = 0
            var showedPicture = false

            // Performance tracking
            var lastFrameTime: Date?
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

            // Music <-> visuals coupling (docs/plans/av-coupling.md); local to this loop, no locks.
            var reactor = MusicReactor(strength: DebugLaunchOptions.syncStrength)
            var lastSyncLogTime = Date.distantPast
            // Effect look (docs/plans/effects-balance.md 7.3): intensity eased toward the setting,
            // image age from the start of the current crossfade.
            var intensitySmoother = EffectIntensitySmoother()
            var transitionStartEffectTime: Float?
            var zoom = ImageZoomTiming()
            var lastEnergy: Float?   // music energy of the last frame (nil when the visuals do not follow the music)
            var wasInDrop = false    // the previous frame was inside a drop build (its successor is the cut)
            // Spatial comfort: Depth setting eased, slow re-centre on the head (docs/plans/spatial.md 5).
            var depthSmoother = DepthSettingSmoother()
            var recentre = ShellRecentre(centre: (shellRoot?.position ?? Self.shellCentre) + DebugLaunchOptions.shellHeadOffset)
            var lastPoseTime = Date()
            var lastBreathing: Float = 0
            // Image change: prepared off the main actor, applied when ready (no long frame).
            var preparingGeneration: UInt64 = 0
            var preparedSlot = PreparedImageSlot(generation: 0)
            var stagedRaw: CGImage?
            var stagedSlot = PreparedImageSlot(generation: 0)
            // Archive footage (docs/plans/archive-video.md): prefetch and the footage pieces run off the main actor;
            // this loop only reads the current frame and reports what the weaver listens to.
            let footage = ArchiveFootageService.shared
            var playbackEpoch: Date?
            var lastVideoMix: Float = 0
            var lastVideoMixes: (Float, Float) = (0, 0)

            while !Task.isCancelled {
                let iterationStart = CACurrentMediaTime()
                let monoDrawable = stereoMaterialBuilder == nil ? await effectsRenderer?.acquireDrawable() : nil
                guard !Task.isCancelled else { return }
                frameCount += 1
                let frameStartTime = Date()

                // Track frame interval (time since last frame started)
                let frameInterval = lastFrameTime.map { frameStartTime.timeIntervalSince($0) * 1000 } ?? 0
                lastFrameTime = frameStartTime
                if frameInterval > 0 { frameIntervals.append(frameInterval) }

                if frameInterval > 15 {
                    droppedFrames += 1
                    consecutiveSlowFrames += 1

                    // Log individual slow frames to find patterns
                    if consecutiveSlowFrames <= 5 || consecutiveSlowFrames % 10 == 0 {
                        LMLog.visual.warning("⚠️ SLOW FRAME #\(frameCount): interval=\(String(format: "%.1f", frameInterval))ms consecutive=\(consecutiveSlowFrames)")
                    }
                } else {
                    if consecutiveSlowFrames > 0 {
                        LMLog.visual.info("✅ Frame timing recovered after \(consecutiveSlowFrames) slow frames")
                    }
                    consecutiveSlowFrames = 0
                }

                // Update effect time (DEBUG: -LiminalFreezeTime pins it for deterministic captures)
                if music.isPlaybackReady, playbackEpoch == nil {
                    playbackEpoch = frameStartTime
                    footage.start()
                } else if !music.isPlaybackReady, playbackEpoch != nil {
                    playbackEpoch = nil
                    footage.stop()
                }
                let effectTime = DebugLaunchOptions.effectTime(
                    playbackEpoch.map { Float(frameStartTime.timeIntervalSince($0)) } ?? 0)

                // Tag this frame's command buffers (eyes) for GPU timing
                effectsRenderer?.gpuStats.beginFrame()

                // Check for new images from AtomicImageBuffer (thread-safe)
                // One atomic read of image and generation.
                // DEBUG -LiminalShellCycle: switch to the next fixture image every N seconds.
                if !Self.debugCycle.isEmpty, frameStartTime.timeIntervalSince(lastCycleSwitch) >= DebugLaunchOptions.shellCycleSeconds {
                    lastCycleSwitch = frameStartTime
                    cycleIndex = (cycleIndex + 1) % Self.debugCycle.count
                    visualEngine.imageBuffer.storeCurrent(Self.debugCycle[cycleIndex].image, metadata: nil)
                    LMLog.visual.info("🧪 DEBUG: shell cycle -> image \(cycleIndex)")
                }
                let (rawImage, newGeneration) = visualEngine.imageBuffer.loadCurrentWithGeneration()
                if let staged = visualEngine.stagedImage, stagedRaw !== staged.cgImage {
                    stagedRaw = staged.cgImage
                    stagedSlot = prepareForDisplay(staged.cgImage, generation: newGeneration &+ 1)
                }
                if let rawImage, newGeneration != transitionState.lastGeneration, newGeneration != preparingGeneration {
                    preparingGeneration = newGeneration
                    if stagedRaw === rawImage, stagedSlot.generation == newGeneration {
                        preparedSlot = stagedSlot
                        stagedRaw = nil
                    } else {
                        preparedSlot = prepareForDisplay(rawImage, generation: newGeneration)
                    }
                }
                // A result for an older generation (superseded while preparing) is dropped.
                if let prepared = preparedSlot.take(), prepared.generation == preparingGeneration,
                   prepared.generation != transitionState.lastGeneration {
                    // Colour and depth share the same framed image.
                    let framedImage = prepared.framed
                    let generation = prepared.generation
                    if let texture = prepared.texture { effectsRenderer?.registerPreparedTexture(texture, for: framedImage) }
                    let wasFirst = transitionState.currentImage == nil
                    transitionState.lastGeneration = generation
                    if !wasFirst {
                        transitionState.spec = visualEngine.nextTransition(
                            effectTime: effectTime,
                            intensity: DebugLaunchOptions.effectIntensity(setting: settings.effectIntensity),
                            energy: lastEnergy,
                            hasDepth: lastDepthGeneration > 0 && !DebugLaunchOptions.forceStereoFlatDepth)
                    }
                    transitionState.transitionTo(framedImage, reveal: visualEngine.reveal)
                    relief.imageChanged(generation: generation)
                    if !wasFirst { transitionStartEffectTime = effectTime }
                    let zoomStart = wasFirst && DebugLaunchOptions.freezeTime != nil ? 0 : effectTime
                    // A drop: the new picture's push starts on the cut, not under the build.
                    let cut = !wasFirst ? transitionState.beatReveal.flatMap { r in
                        r.isDrop ? zoomStart + Float(r.downbeat - ArchiveFootageService.uptime()) : nil } : nil
                    zoom.imageChanged(at: zoomStart, replacing: !wasFirst, holdUntil: cut)
                    LMLog.visual.info("🎬 New image detected (gen \(generation)), triggering transition (prepared off-main in \(String(format: "%.1f", prepared.milliseconds), privacy: .public)ms)")
                }

                if preparedSlot.generation == transitionState.lastGeneration, let ready = preparedSlot.takeDepth() {
                    visualEngine.imageBuffer.storeDepth(ready.image)
                    if let texture = ready.texture {
                        effectsRenderer?.depthTexture = texture
                        lastDepthGeneration = visualEngine.imageBuffer.loadDepthWithGeneration().generation
                    }
                    relief.depthArrived(ready.field.q, generation: preparedSlot.generation, now: frameStartTime.timeIntervalSince1970)
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
                // A drop (docs/plans/drop-transitions.md 3.5): only the old picture until the cut, then a step.
                // The frame's presentation time, sampled with the drop state: the recorder places it by this.
                let presentAt = ArchiveFootageService.uptime() + LofiImageReveal.presentationLatency
                let dropFrame = transitionState.dropFrame
                let inDrop = dropFrame.map { !$0.done } ?? false
                if transitionState.isTransitioning, let prev = transitionState.previousImage {
                    let from = ImageColorStats.cachedFactors(key: prev) { prev }
                    vibrance = inDrop ? from : VibranceFactors.lerp(from, vibrance, transitionState.transitionProgress)
                }
                let transitionProgress = transitionState.isTransitioning ? transitionState.transitionProgress : 0
                // The first clean frame after a drop: the trails hold the wrecked old picture, so none of it.
                let cutFrame = wasInDrop && !inDrop
                if cutFrame, let reveal = transitionState.beatReveal {
                    LMLog.visual.info("Lo-Fi drop cut frame starts \((ArchiveFootageService.uptime() - (reveal.downbeat - LofiImageReveal.displayLead)) * 1000, format: .fixed(precision: 1)) ms from downbeat minus lead")
                }
                wasInDrop = inDrop
                // Music -> visuals: one seqlock read and ~10 one-pole updates. visionOS has no un-synced
                // hue drift (baseHueRate 0). Frozen time bypasses the reactor (deterministic captures).
                let musicBus = music.musicState
                let modulation: MusicModulation
                if DebugLaunchOptions.freezeTime != nil {
                    modulation = .neutral
                } else {
                    modulation = reactor.update(state: musicBus.read(), now: musicBus.now(), effectTime: effectTime,
                                                enabled: settings.syncVisualsToMusic, baseHueRate: 0)
                }
                renderer.requestGhostBurst(serial: modulation.ghostBurstSerial)
                lastEnergy = modulation.amount > 0 ? modulation.energy : nil
                let intensityTarget = DebugLaunchOptions.effectIntensity(setting: settings.effectIntensity)
                let look = EffectLook(
                    intensity: DebugLaunchOptions.freezeTime != nil
                        ? intensityTarget : intensitySmoother.next(target: intensityTarget, time: effectTime),
                    imageAge: transitionStartEffectTime.map { effectTime - $0 }.flatMap { $0 >= 0 ? $0 : nil },
                    transitionDuration: transitionState.spec.duration,
                    freshFadeEnd: transitionState.spec.drop != nil ? transitionState.spec.duration : nil)
                let footageFrame = footage.frame(image: cgImage)
                if frameCount % 30 == 0 {
                    footage.update(.init(musicIntensity: modulation.amount > 0 ? modulation.energy : 0,
                                         effectIntensity: look.intensity,
                                         hasDepth: renderer.depthTexture != nil))
                }
                var uniforms = EffectsUniformsComputer.compute(
                    time: effectTime,
                    transitionProgress: transitionProgress,
                    hasSaliencyMap: false,
                    vibrance: vibrance,
                    music: modulation,
                    look: look,
                    zoomAge: zoom.age(at: effectTime, cut: !inDrop),
                    outgoingZoomScale: transitionState.isTransitioning ? zoom.outgoingScale : 0,
                    transition: transitionState.spec,
                    video: footageFrame.state,
                    drop: transitionState.isTransitioning ? dropFrame : nil
                )
                if cutFrame { uniforms.feedbackMix = 0 }
                // Two footage layers (A27): a layer without its stage texture is skipped.
                if footageFrame.texture == nil { uniforms.videoMix = 0 }
                if footageFrame.textureB == nil { uniforms.videoMixB = 0 }
                renderer.videoTexture = uniforms.videoMix > 0 ? footageFrame.texture : nil
                renderer.videoTextureB = uniforms.videoMixB > 0 ? footageFrame.textureB : nil
                lastVideoMix = uniforms.videoMix + uniforms.videoMixB
                lastVideoMixes = (uniforms.videoMix, uniforms.videoMixB)

                if DebugLaunchOptions.syncLog, frameStartTime.timeIntervalSince(lastSyncLogTime) >= 1 {
                    lastSyncLogTime = frameStartTime
                    let neutral = EffectsUniformsComputer.compute(time: effectTime, transitionProgress: transitionProgress,
                                                                  hasSaliencyMap: false, vibrance: vibrance, look: look,
                                                                  transition: transitionState.spec)
                    let line = MusicSyncLog.line(reactor: reactor, state: musicBus.read(), uniforms: uniforms, neutral: neutral)
                    LMLog.visual.info("\(line, privacy: .public)")
                }

                // Shell vertices: relief + breathing (vDSP, ~11k vertices). Relief strength follows the
                // Depth amount, the clarity cycle and the transition (ShellLayout.reliefStrength).
                let meshStart = Date()
                let depthSetting = depthSmoother.next(target: DebugLaunchOptions.shellDepth ?? settings.depthStrength,
                                                      dt: Float(frameInterval / 1000))
                // A drop flattens the shell as the picture breaks up and steps to the new relief at the cut.
                let reliefK = inDrop
                    ? ShellLayout.reliefStrength(depth: depthSetting, drive: look.drive(time: effectTime),
                                                 dropEnvelope: transitionState.spec.envelope(transitionProgress))
                    : ShellLayout.reliefStrength(depth: depthSetting, drive: look.drive(time: effectTime),
                                                 transitionProgress: transitionState.spec.drop != nil ? 0 : transitionProgress)
                let reliefW = relief.weight(transitionProgress: inDrop ? 0 : (transitionState.isTransitioning && transitionState.spec.drop == nil ? transitionState.transitionProgress : nil),
                                            now: frameStartTime.timeIntervalSince1970)
                // Music -> geometry: breathing swells 2 -> 3 cm with the music's energy and slow pulse.
                let breathing = ShellLayout.breathingAmplitude(amount: modulation.amount, energy: modulation.energy,
                                                               pulseMotion: modulation.pulseMotion)
                shellMesh?.update(previous: relief.previous, current: relief.current, weight: reliefW, k: reliefK, time: effectTime,
                                  breathingAmplitude: breathing)
                lastBreathing = breathing
                // Slow re-centre, about 10 Hz (no-op without ARKit tracking).
                let poseDt = frameStartTime.timeIntervalSince(lastPoseTime)
                if poseDt >= 0.1, let head = headPose?.headTransform() {
                    lastPoseTime = frameStartTime
                    let wasRecentring = recentre.isRecentring
                    let centre = recentre.update(head: ShellPlacement.position(of: head), dt: Float(poseDt))
                    shellRoot?.position = centre - DebugLaunchOptions.shellHeadOffset
                    if recentre.isRecentring != wasRecentring {
                        LMLog.visual.info("🧭 SHELL re-centre \(recentre.isRecentring ? "started" : "settled", privacy: .public)")
                    }
                } else if poseDt >= 0.1 {
                    lastPoseTime = frameStartTime
                }
                totalMeshTime += Date().timeIntervalSince(meshStart) * 1000
                lastReliefK = reliefK
                lastReliefW = reliefW

                // Render frame: one mono effects pass shown on every tile (decision S4); the per-eye
                // stereo path only for the DEBUG texture-stereo A/B.
                let renderStartTime = Date()
                let previousImage = transitionState.isTransitioning ? transitionState.previousImage : nil

                let submitted: Bool
                if let stereoBuilder = stereoMaterialBuilder,
                   let leftQueue = stereoBuilder.leftDrawableQueue,
                   let rightQueue = stereoBuilder.rightDrawableQueue {
                    // DEBUG A/B: left/right drawable queues with texture-space depth parallax
                    let stereoOsc = SmoothOscillator.value(at: effectTime)
                    let stereoOffset = 0.003 + 0.007 * stereoOsc  // Subtle stereo separation
                    submitted = renderer.renderStereoAndPresent(
                        sourceImage: cgImage,
                        previousImage: previousImage,
                        uniforms: uniforms,
                        leftQueue: leftQueue,
                        rightQueue: rightQueue,
                        stereoOffset: stereoOffset
                    )
                } else if let monoDrawable {
                    submitted = renderer.renderAndPresent(drawable: monoDrawable, sourceImage: cgImage,
                                                          previousImage: previousImage, uniforms: uniforms,
                                                          presentationTime: presentAt)
                } else {
                    submitted = false
                }
                if submitted {
                    submittedFrames += 1
                    if !showedPicture {
                        showedPicture = true
                        immersivePictureReady = true
                        let readiness = $immersivePictureReady
                        RecordingController.shared.scheduleDebugRecording(audio: music) { readiness.wrappedValue }
                    }
                }
                let renderTime = Date().timeIntervalSince(renderStartTime) * 1000
                totalRenderTime += renderTime
                maxRenderTime = max(maxRenderTime, renderTime)

                // Log stats every second
                let timeSinceStats = Date().timeIntervalSince(lastStatsTime)
                if timeSinceStats >= perfLogInterval {
                    let avgRenderTime = totalRenderTime / Double(frameCount)
                    let actualFPS = Double(submittedFrames) / timeSinceStats
                    let fpsPercent = (actualFPS / 90.0) * 100

                    let hasDepth = effectsRenderer?.depthTexture != nil
                    let hasStereo = stereoMaterialBuilder != nil

                    frameIntervals.sort()
                    let intervalP95 = GPUTimingStats.percentile(frameIntervals, 0.95)
                    let gpuFragment = effectsRenderer?.gpuStats.drain().logFragment ?? "gpu n=0"

                    let perfLine = "📊 visionOS PERF: fps=\(String(format: "%.1f", actualFPS)) (\(String(format: "%.0f", fpsPercent))% of 90) | render avg=\(String(format: "%.1f", avgRenderTime))ms max=\(String(format: "%.1f", maxRenderTime))ms | dropped=\(droppedFrames) unsubmitted=\(frameCount - submittedFrames) | transition=\(String(format: "%.0f", transitionState.transitionProgress * 100))% | interval p95=\(String(format: "%.2f", intervalP95))ms worst=\(String(format: "%.2f", frameIntervals.last ?? 0))ms | \(gpuFragment)"
                    LMLog.visual.info("\(perfLine, privacy: .public)")
                    if lastVideoMix > 0 {
                        LMLog.visual.info("📼 FOOTAGE mix=\(String(format: "%.3f", lastVideoMix), privacy: .public) A=\(String(format: "%.3f", lastVideoMixes.0), privacy: .public) \(footageFrame.state.a?.resolvedRecipe.name ?? "-", privacy: .public) B=\(String(format: "%.3f", lastVideoMixes.1), privacy: .public) \(footageFrame.state.b?.resolvedRecipe.name ?? "-", privacy: .public)")
                    }
                    LMLog.visual.info("🔮 3D STATUS: depth=\(hasDepth) textureStereo=\(hasStereo) gen=\(transitionState.lastGeneration) mesh avg=\(String(format: "%.3f", totalMeshTime / Double(max(frameCount, 1))), privacy: .public)ms relief k=\(String(format: "%.3f", lastReliefK), privacy: .public) breath=\(String(format: "%.3f", lastBreathing), privacy: .public)m w=\(String(format: "%.2f", lastReliefW), privacy: .public) fields=\(relief.previous != nil ? 1 : 0)+\(relief.current != nil ? 1 : 0)")

                    frameCount = 0
                    submittedFrames = 0
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
                let frameElapsedNs = UInt64((CACurrentMediaTime() - iterationStart) * 1_000_000_000)
                if frameElapsedNs < targetFrameTimeNs {
                    let sleepTime = targetFrameTimeNs - frameElapsedNs
                    try? await Task.sleep(nanoseconds: sleepTime)
                }
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

    /// Stage colour first. Inference and mesh preparation can use the remaining
    /// lead time before the fill. A late depth result only belongs to its own slot.
    private func prepareForDisplay(_ raw: CGImage, generation: UInt64) -> PreparedImageSlot {
        let slot = PreparedImageSlot(generation: generation)
        let uploader = effectsRenderer?.textureUploader
        let generator = DebugLaunchOptions.forceStereoFlatDepth ? nil : depthGenerator
        Task.detached(priority: .userInitiated) {
            let image = Self.prepareImage(raw, generation: generation, uploader: uploader)
            slot.store(image)
            guard let generator else { return }
            do {
                let depth: CGImage
                if let fixture = image.depthOverride { depth = fixture }
                else { depth = try await generator.generateDepth(from: image.framed) }
                slot.storeDepth(.init(image: depth, field: Self.buildRelief(depth, generation: generation),
                                      texture: uploader?.makeDepthTexture(from: depth)))
            } catch {
                LMLog.visual.error("Depth generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return slot
    }

    /// Off the main actor: frame the image, cache its vibrance factors, build its source texture.
    nonisolated private static func prepareImage(_ raw: CGImage, generation: UInt64,
                                                 uploader: SourceTextureUploader?) -> PreparedImage {
        let start = Date()
        let framed = ImageFraming.coverCrop(raw)
        _ = ImageColorStats.cachedFactors(key: framed) { framed }
        let texture = uploader?.makeTexture(from: framed, label: "source")
        return PreparedImage(generation: generation, framed: framed,
                             depthOverride: debugDepth(for: raw), texture: texture,
                             milliseconds: Date().timeIntervalSince(start) * 1000)
    }

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
