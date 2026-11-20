#if os(macOS)

import MetalKit
import AppKit
import SwiftUI
import OSLog

// MARK: - Effects Metal View

/// Custom MTKView that renders all visual effects in a single GPU pass with feedback trails.
/// Replaces the SwiftUI modifier chain for better performance and proper feedback loop.
final class EffectsMetalView: MTKView {

    // MARK: - Metal Resources

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    /// Archive footage variant (effectsFragmentVideo), bound only while footage shows.
    private var videoPipelineState: MTLRenderPipelineState?
    /// Footage interaction-mode variants (effectsFragmentVideo{Keys,Drives,FX}) by variant id, bound only
    /// while a layer needs them (VideoComposite.footageVariant; docs/decisions/footage-fx.md F11).
    private var videoFXPipelineStates: [Int: MTLRenderPipelineState] = [:]

    // Source texture (from morphPlayer - current/target image)
    private var sourceTexture: MTLTexture?
    var beatReveal: LofiImageReveal?
    private var lastLoggedDownbeat: Double?
    private var stagingID: ObjectIdentifier?
    private var stagedTexture: (image: NSImage, texture: MTLTexture, crop: CGRect)?
    private var textureLoader: MTKTextureLoader?
    private var lastSourceImageHash: Int = 0  // Track image changes
    /// Hash of the image whose texture MTKTextureLoader is decoding off the main thread (0 = none).
    private var pendingSourceHash: Int = 0
    /// The texture the source had before the latest swap: it becomes the crossfade's previous
    /// texture without a second decode (docs/decisions/performance.md, image-change hitch).
    private var retiredSource: (hash: Int, texture: MTLTexture)?

    // Previous texture (for GPU crossfade blending during transitions)
    private var previousTexture: MTLTexture?
    private var lastPreviousImageHash: Int = 0

    // Saliency texture (from DepthAnalyzer)
    private var saliencyTexture: MTLTexture?
    private var lastSaliencyImage: CGImage?

    // Feedback texture for frame-to-frame recursive warping
    private var feedbackTexture: MTLTexture?

    // Ghost tap manager for discrete delay echoes
    private let ghostTapManager = GhostTapManager()

    // MARK: - Effect Parameters

    /// Single uniforms struct - matches visionOS pattern for platform parity
    var uniforms = EffectsUniforms(
        time: 0,
        kenBurnsScale: 1.2,
        kenBurnsOffsetX: 0,
        kenBurnsOffsetY: 0,
        distortionAmplitude: 0.012,
        distortionSpeed: 0.08,
        hueBaseShift: 0,
        hueWaveIntensity: 0.5,
        hueBlendAmount: 0.65,
        contrastBoost: 1.4,
        saturationBoost: 1.3,
        ghostTapMaxDistance: 0.25,
        saliencyInfluence: 0.6,
        hasSaliencyMap: 0,
        transitionProgress: 0,
        ghostTapCount: 0,
        chromaticAmount: 0.006,
        feedbackWarpAmount: 0.03,
        feedbackMix: 0.3,
        bloomRadius: 0.04,
        bloomAmount: 0.5,
        stereoOffset: 0,
        logSphereAmount: 0,
        fractalNoiseAmount: 0,
        fractalHueAmount: 0
    )

    /// Delay setting from slider (0-1), controls ghost tap spawn frequency

    // Track if we have a valid source
    private var hasValidSource = false
    /// Normalized cover-crop applied to the current source image (re-used for its saliency map).
    private var sourceCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: - Performance Tracking

    private var frameCount: Int = 0
    private var lastLogTime: Date = Date()
    private var totalDrawTime: Double = 0
    private var textureUpdateCount: Int = 0
    private let gpuStats = GPUTimingStats()
    private var lastDrawStart: CFTimeInterval?
    private var lastDrawDuration: Double = 0
    private var frameIntervals: [Double] = []
    private let perfLogInterval = DebugLaunchOptions.perfLogInterval

    // MARK: - Initialization

    init() {
        // Get the default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        super.init(frame: .zero, device: device)

        self.commandQueue = device.makeCommandQueue()
        self.textureLoader = MTKTextureLoader(device: device)

        // Configure the view
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = false  // Allow reading back for feedback
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.isPaused = false
        self.enableSetNeedsDisplay = false  // Use internal draw loop
        self.preferredFramesPerSecond = 60

        // Set up the render pipeline
        setupPipeline()

        LMLog.visual.info("🎨 EffectsMetalView initialized - device: \(device.name)")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Pipeline Setup

    private func setupPipeline() {
        guard let device = self.device else {
            LMLog.visual.error("❌ No Metal device available")
            return
        }

        // Load shader library
        guard let library = device.makeDefaultLibrary() else {
            LMLog.visual.error("❌ Failed to load Metal library - check that EffectsRenderer.metal is in the project")
            return
        }

        LMLog.visual.debug("📚 Metal library loaded, functions: \(library.functionNames)")

        guard let vertexFunction = library.makeFunction(name: "effectsVertex") else {
            LMLog.visual.error("❌ Failed to load effectsVertex function")
            return
        }

        // DEBUG -LiminalNoEffects: bare image via passthroughFragment (orientation/colour checks).
        let fragmentName = DebugLaunchOptions.noEffects ? "passthroughFragment" : "effectsFragment"
        guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
            LMLog.visual.error("❌ Failed to load effectsFragment function")
            return
        }

        LMLog.visual.debug("✅ Loaded shader functions: effectsVertex, effectsFragment")

        // Create pipeline descriptor
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            LMLog.visual.info("✅ Metal pipeline created successfully")
        } catch {
            LMLog.visual.error("❌ Failed to create pipeline: \(error.localizedDescription)")
        }
        if !DebugLaunchOptions.noEffects, let f = library.makeFunction(name: "effectsFragmentVideo") {
            pipelineDescriptor.fragmentFunction = f
            videoPipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        for v in FootageRecipe.fxVariants where !DebugLaunchOptions.noEffects {
            guard let f = library.makeFunction(name: "effectsFragment" + VideoComposite.variantSuffix(v)) else { continue }
            pipelineDescriptor.fragmentFunction = f
            videoFXPipelineStates[v] = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }


    }

    // MARK: - Texture Management

    func preload(_ item: ImageQueue.DisplayItem?) {
        guard let item, let image = item.image, stagingID != ObjectIdentifier(image), let device else { return }
        let id = ObjectIdentifier(image)
        stagingID = id
        Task.detached(priority: .utility) { [weak self] in
            let cg = item.cgImage
            let crop = ImageFraming.coverCropRect(width: cg.width, height: cg.height)
            let framed = ImageFraming.crop(cg, normalized: crop)
            if let image = item.image { _ = ImageColorStats.cachedFactors(key: image) { framed } }
            let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .generateMipmaps: false]
            nonisolated(unsafe) let texture = try? await MTKTextureLoader(device: device).newTexture(cgImage: framed, options: options)
            await MainActor.run { [weak self] in
                guard let self, stagingID == id, let image = item.image, let texture else { return }
                stagedTexture = (image, texture, crop)
            }
        }
    }

    /// Update the source image from morphPlayer - ONLY if image changed.
    /// The decode + upload runs on MTKTextureLoader's background queue; the old source keeps
    /// drawing until the new texture lands (a frame or a few into the transition, which then
    /// shows previous = source = old image), so the main thread never stalls on it.
    func updateSourceImage(_ image: NSImage?) {
        guard let image = image else {
            if hasValidSource {
                LMLog.visual.debug("⚠️ Source image became nil")
            }
            hasValidSource = false
            pendingSourceHash = 0
            return
        }

        // Check if image actually changed using hash
        let newHash = image.hash
        if newHash == pendingSourceHash { return }  // already loading
        if newHash == lastSourceImageHash && hasValidSource {
            // Same image, skip expensive texture creation
            return
        }

        if let staged = stagedTexture, staged.image === image {
            sourceCrop = staged.crop
            pendingSourceHash = newHash
            sourceTextureLoaded(staged.texture, hash: newHash, error: nil, startTime: Date())
            stagedTexture = nil
            stagingID = nil
            return
        }

        guard let textureLoader = self.textureLoader else {
            hasValidSource = false
            return
        }

        // Convert NSImage to CGImage, centre-cropped to the 3:2 display aspect
        // (the view itself is kept at 3:2 by VisualDisplayView; docs/decisions/orientation.md).
        // MTKTextureLoader's default origin is top-left: texture row 0 = image top.
        guard let rawImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            LMLog.visual.error("❌ Failed to get CGImage from NSImage")
            hasValidSource = false
            return
        }

        let startTime = Date()
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: false
        ]
        sourceCrop = ImageFraming.coverCropRect(width: rawImage.width, height: rawImage.height)
        pendingSourceHash = newHash
        textureLoader.newTexture(cgImage: ImageFraming.crop(rawImage, normalized: sourceCrop), options: options) { @Sendable [weak self] texture, error in
            let message = error?.localizedDescription
            nonisolated(unsafe) let texture = texture
            Task { @MainActor [weak self] in
                self?.sourceTextureLoaded(texture, hash: newHash, error: message, startTime: startTime)
            }
        }
    }

    /// Main thread: swap in a texture loaded by `updateSourceImage` (a new texture object, so a
    /// command buffer still sampling the old one is unaffected). Stale loads are dropped.
    private func sourceTextureLoaded(_ texture: MTLTexture?, hash: Int, error: String?, startTime: Date) {
        guard hash == pendingSourceHash else { return }
        pendingSourceHash = 0
        guard let texture = texture else {
            LMLog.visual.error("❌ Failed to create texture: \(error ?? "unknown")")
            return
        }
        if hasValidSource, let old = sourceTexture { retiredSource = (lastSourceImageHash, old) }
        sourceTexture = texture
        hasValidSource = true
        lastSourceImageHash = hash
        textureUpdateCount += 1
        let loadTime = Date().timeIntervalSince(startTime) * 1000
        let updateNum = textureUpdateCount
        LMLog.visual.debug("🖼️ Source texture updated: \(texture.width)x\(texture.height) in \(String(format: "%.1f", loadTime))ms off-main (update #\(updateNum))")
    }

    /// Update the saliency map texture - ONLY if image changed
    func updateSaliencyMap(_ image: CGImage?) {
        guard let cgImage = image else {
            saliencyTexture = nil
            lastSaliencyImage = nil
            return
        }
        guard cgImage !== lastSaliencyImage, let textureLoader else { return }

        // Load as Metal texture
        do {
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false
            ]
            // Same normalized crop as the colour image so saliency stays registered with it.
            saliencyTexture = try textureLoader.newTexture(cgImage: ImageFraming.crop(cgImage, normalized: sourceCrop), options: options)
            lastSaliencyImage = cgImage

            if let tex = saliencyTexture {
                LMLog.visual.info("🔍 Saliency texture loaded: \(tex.width)x\(tex.height)")
            }
        } catch {
            LMLog.visual.error("❌ Failed to create saliency texture: \(error.localizedDescription)")
        }
    }

    /// Update the previous image texture for GPU crossfade blending - ONLY if image changed
    func updatePreviousImage(_ image: NSImage?) {
        guard let image = image else {
            previousTexture = nil
            lastPreviousImageHash = 0
            return
        }

        // Check if previous image actually changed
        let newHash = image.hash
        if newHash == lastPreviousImageHash && previousTexture != nil {
            return
        }

        // The previous image is (almost always) the old source: reuse its texture, no decode.
        if hasValidSource, newHash == lastSourceImageHash, let current = sourceTexture {
            previousTexture = current
            lastPreviousImageHash = newHash
            return
        }
        if let retired = retiredSource, retired.hash == newHash {
            previousTexture = retired.texture
            lastPreviousImageHash = newHash
            return
        }

        guard let textureLoader = self.textureLoader else {
            return
        }

        // Convert NSImage to CGImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            LMLog.visual.error("❌ Failed to get CGImage from previous NSImage")
            return
        }

        // Load as Metal texture
        do {
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false
            ]
            previousTexture = try textureLoader.newTexture(cgImage: ImageFraming.coverCrop(cgImage), options: options)
            lastPreviousImageHash = newHash

            if let tex = previousTexture {
                LMLog.visual.debug("🔄 Previous texture loaded for crossfade: \(tex.width)x\(tex.height)")
            }
        } catch {
            LMLog.visual.error("❌ Failed to create previous texture: \(error.localizedDescription)")
        }
    }

    // MARK: - Feedback Texture

    /// Ensure feedback texture matches the drawable size
    private func ensureFeedbackTexture(width: Int, height: Int) {
        if let existing = feedbackTexture, existing.width == width, existing.height == height {
            return
        }
        guard let device = self.device else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: self.colorPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        feedbackTexture = device.makeTexture(descriptor: desc)
        if feedbackTexture != nil {
            LMLog.visual.info("🔁 Feedback texture created: \(width)x\(height)")
        }
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        let drawStart = CACurrentMediaTime()

        // Early exit checks with logging
        guard hasValidSource else {
            if frameCount % 60 == 0 {
                LMLog.visual.debug("⏸️ Skipping draw: no valid source")
            }
            return
        }

        guard let sourceTexture = sourceTexture else {
            LMLog.visual.debug("⏸️ Skipping draw: sourceTexture nil")
            return
        }

        guard let pipelineState = pipelineState else {
            LMLog.visual.error("❌ Skipping draw: pipelineState nil")
            return
        }

        guard let commandQueue = commandQueue else {
            LMLog.visual.error("❌ Skipping draw: commandQueue nil")
            return
        }

        guard let drawable = currentDrawable else {
            if frameCount % 60 == 0 {
                LMLog.visual.debug("⏸️ Skipping draw: no drawable")
            }
            return
        }

        if let last = lastDrawStart {
            let interval = (drawStart - last) * 1000
            frameIntervals.append(interval)
            #if DEBUG
            if interval >= 50 {
                LMLog.visual.info("Slow Mac frame: interval=\(interval, format: .fixed(precision: 1))ms previous draw=\(self.lastDrawDuration, format: .fixed(precision: 1))ms")
            }
            #endif
        }
        lastDrawStart = drawStart

        let ghostTapResult = ghostTapManager.updateWithCount(currentTime: uniforms.time)
        var uniformsCopy = uniforms
        if let beatReveal, previousTexture != nil {
            let now = ArchiveFootageService.uptime()
            let p = max(0.000001, Float(beatReveal.progress(at: now)))
            if beatReveal.spec.swap(p) >= 1, lastLoggedDownbeat != beatReveal.downbeat, previousTexture !== sourceTexture {
                lastLoggedDownbeat = beatReveal.downbeat
                LMLog.visual.info("Lo-Fi image fully in on draw \((now - beatReveal.downbeat) * 1000, format: .fixed(precision: 1)) ms after downbeat")
            }
            uniformsCopy.transitionProgress = p
            uniformsCopy.txMix = beatReveal.spec.swap(p)
            uniformsCopy.txEnv = beatReveal.spec.envelope(p)
        }
        uniformsCopy.hasSaliencyMap = saliencyTexture != nil ? 1.0 : 0.0
        uniformsCopy.ghostTapCount = Float(ghostTapResult.activeCount)
        // Archive footage: the newest stage texture of each layer at draw time (a lock read each; slot 0 =
        // layer A, slot 1 = layer B, A27); a layer without one is skipped.
        let footageOK = videoPipelineState != nil
        let videoTexture = uniformsCopy.videoMix > 0 && footageOK ? ArchiveFootageService.shared.texture(slot: 0) : nil
        let videoTextureB = uniformsCopy.videoMixB > 0 && footageOK ? ArchiveFootageService.shared.texture(slot: 1) : nil
        if videoTexture == nil { uniformsCopy.videoMix = 0 }
        if videoTextureB == nil { uniformsCopy.videoMixB = 0 }
        let footage = videoTexture != nil || videoTextureB != nil

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            LMLog.visual.error("❌ Failed to create command buffer")
            return
        }

        // Ensure feedback texture matches drawable size
        ensureFeedbackTexture(width: drawable.texture.width, height: drawable.texture.height)

        // Single render pass with ghost taps + feedback
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            let videoState = videoFXPipelineStates[VideoComposite.footageVariant(uniformsCopy)] ?? videoPipelineState
            encoder.setRenderPipelineState(footage ? videoState ?? pipelineState : pipelineState)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            if let saliencyTex = saliencyTexture {
                encoder.setFragmentTexture(saliencyTex, index: 2)
            }
            // Previous texture for GPU crossfade (falls back to source if no transition)
            encoder.setFragmentTexture(previousTexture ?? sourceTexture, index: 3)
            // Feedback texture for recursive warping (previous frame's output)
            if let fbTex = feedbackTexture {
                encoder.setFragmentTexture(fbTex, index: 4)
            }
            if let videoTexture { encoder.setFragmentTexture(videoTexture, index: 7) }
            if let videoTextureB { encoder.setFragmentTexture(videoTextureB, index: 8) }
            // Metal retains its own copy of these small constants for each in-flight frame.
            encoder.setFragmentBytes(&uniformsCopy, length: MemoryLayout<EffectsUniforms>.size, index: 0)
            encoder.setFragmentBytes(ghostTapResult.data, length: ghostTapResult.data.count * MemoryLayout<GhostTapData>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        // Blit rendered result to feedback texture for next frame
        if let fbTex = feedbackTexture {
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                let size = MTLSize(width: min(drawable.texture.width, fbTex.width),
                                   height: min(drawable.texture.height, fbTex.height),
                                   depth: 1)
                blitEncoder.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                                 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                                 to: fbTex, destinationSlice: 0, destinationLevel: 0,
                                 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blitEncoder.endEncoding()
            }
        }

        gpuStats.beginFrame()
        gpuStats.track(commandBuffer, pass: "fx")
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Track frame timing
        frameCount += 1
        lastDrawDuration = (CACurrentMediaTime() - drawStart) * 1000
        totalDrawTime += lastDrawDuration

        // Log performance every second
        let timeSinceLastLog = Date().timeIntervalSince(lastLogTime)
        if timeSinceLastLog >= perfLogInterval {
            let avgDrawTime = totalDrawTime / Double(frameCount)
            let fps = Double(frameCount) / timeSinceLastLog

            let srcW = sourceTexture.width
            let srcH = sourceTexture.height
            let texUpdates = textureUpdateCount

            frameIntervals.sort()
            let intervalP95 = GPUTimingStats.percentile(frameIntervals, 0.95)
            let longestInterval = frameIntervals.last ?? 0
            frameIntervals.removeAll(keepingCapacity: true)
            let gpuFragment = gpuStats.drain().logFragment

            if uniformsCopy.videoMix > 0 || uniformsCopy.videoMixB > 0 {
                LMLog.visual.info("📼 FOOTAGE mix=\(String(format: "%.3f", uniformsCopy.videoMix + uniformsCopy.videoMixB), privacy: .public) A=\(String(format: "%.3f", uniformsCopy.videoMix), privacy: .public)/\(Int(uniformsCopy.videoLook)) B=\(String(format: "%.3f", uniformsCopy.videoMixB), privacy: .public)/\(Int(uniformsCopy.videoLookB))")
            }
            let perfLine = "📊 METAL PERF: fps=\(String(format: "%.1f", fps)) avgDraw=\(String(format: "%.2f", avgDrawTime))ms src=\(srcW)x\(srcH) texUpdates=\(texUpdates) | interval p95=\(String(format: "%.2f", intervalP95))ms worst=\(String(format: "%.2f", longestInterval))ms | \(gpuFragment)"
            LMLog.visual.info("\(perfLine, privacy: .public)")

            // Reset counters
            frameCount = 0
            totalDrawTime = 0
            textureUpdateCount = 0
            lastLogTime = Date()
        }
    }

    /// Reset ghost taps (call when stopping playback)
    func resetGhostTaps() {
        ghostTapManager.reset()
        LMLog.visual.info("🔄 Ghost taps reset")
    }

    /// Music scene change: forward to the ghost tap manager (no-op unless the serial changed).
    func requestGhostBurst(serial: UInt32) {
        ghostTapManager.requestBurst(serial: serial)
    }
}

// MARK: - SwiftUI Wrapper

struct EffectsMetalViewRepresentable: NSViewRepresentable {
    let sourceImage: NSImage?
    var stagedImage: ImageQueue.DisplayItem? = nil
    var beatReveal: LofiImageReveal? = nil
    let previousImage: NSImage?  // For GPU crossfade blending
    let saliencyMap: CGImage?
    let uniforms: EffectsUniforms  // Single struct - matches visionOS pattern
    var ghostBurstSerial: UInt32 = 0  // MusicModulation.ghostBurstSerial (scene-change trail burst)

    func makeNSView(context: Context) -> EffectsMetalView {
        let view = EffectsMetalView()
        LMLog.visual.info("🎬 EffectsMetalViewRepresentable created")
        return view
    }

    func updateNSView(_ nsView: EffectsMetalView, context: Context) {
        // Update source image (internally checks if changed)
        nsView.preload(stagedImage)
        nsView.updateSourceImage(sourceImage)
        nsView.beatReveal = beatReveal

        // Update previous image for GPU crossfade (internally checks if changed)
        nsView.updatePreviousImage(previousImage)

        // Update saliency map (internally checks if changed)
        nsView.updateSaliencyMap(saliencyMap)

        // Pass uniforms
        nsView.uniforms = uniforms
        nsView.requestGhostBurst(serial: ghostBurstSerial)
    }
}

#endif
