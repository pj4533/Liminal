//
//  OffscreenEffectsRenderer.swift
//  Liminal
//
//  Renders visual effects to an offscreen Metal texture for use with RealityKit.
//  Uses DrawableQueue to bridge Metal → RealityKit TextureResource.
//

#if os(visionOS)

import Foundation
import Metal
import CoreGraphics
import QuartzCore
import RealityKit
import OSLog

/// Renders effects to an offscreen texture, bridged to RealityKit via DrawableQueue.
@MainActor
final class OffscreenEffectsRenderer {

    // MARK: - Metal Objects

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    /// Both eyes in one MRT pass (effectsFragmentStereo): attachment 0 = left, 1 = right.
    private let stereoPipelineState: MTLRenderPipelineState
    private var loggedStereoFallback = false
    private let passthroughPipelineState: MTLRenderPipelineState  // DEBUG: Simple passthrough
    /// Archive footage variants (effectsFragmentVideo / effectsFragmentStereoVideo), used only while
    /// footage shows, so the plain pipelines stay exactly the shader without footage.
    private let videoPipelineState: MTLRenderPipelineState?
    private let stereoVideoPipelineState: MTLRenderPipelineState?
    /// Footage interaction-mode variants (effectsFragment*Video{Keys,Drives,FX}) by variant id, bound only
    /// while a layer needs them (VideoComposite.footageVariant; docs/decisions/footage-fx.md F11).
    private let videoFXPipelineStates: [Int: MTLRenderPipelineState]
    private let stereoVideoFXPipelineStates: [Int: MTLRenderPipelineState]
    /// Drop twins of every effects pipeline (DropPipelines), bound while a drop runs.
    private let dropPipelines: DropPipelines
    private let samplerState: MTLSamplerState

    // MARK: - Textures

    private var sourceTexture: MTLTexture?
    private var previousTexture: MTLTexture?  // For GPU crossfade blending
    // No intermediate output texture: each pass renders straight into its 2048² drawable.
    private var loggedDrawableSize = false
    private var loggedDrawableSizeMismatch = false
    private var saliencyTexture: MTLTexture?
    var depthTexture: MTLTexture?  // ML depth map (r8Unorm)

    private static let renderSize = 2048
    private let outputSize: Int = OffscreenEffectsRenderer.renderSize  // Output texture resolution

    // MARK: - Output encoding + feedback (docs/decisions/vibrance.md V1, V2)

    /// Every pass renders into a plain `bgra8Unorm` VIEW of the `_srgb` drawable. The shader works on
    /// gamma-encoded sRGB values; writing them through an `_srgb` attachment encoded them a second
    /// time (mid-grey 128 showed as ~188, saturation -33%). Through the view the stored bytes are the
    /// shader's values unchanged, exactly like macOS; RealityKit still samples the `_srgb` format.
    static let renderFormat: MTLPixelFormat = .bgra8Unorm
    /// Views keyed by the drawable texture they alias (DrawableQueue recycles a small fixed set).
    private var outputViews: [(texture: MTLTexture, view: MTLTexture)] = []
    private var loggedViewFailure = false

    /// Feedback trails: each eye reads its own previous output (the view of the drawable presented
    /// last frame) at texture 4 (right eye: 6 in the MRT pass). Same semantics as macOS (which copies
    /// its drawable), but with no copy and no extra memory. Index: 0 = left / mono, 1 = right.
    private var lastOutput: [MTLTexture?] = [nil, nil]
    /// 1x1 black, bound when no previous output exists (feedbackMix is also forced to 0 then).
    private let blackTexture: MTLTexture?
    /// Archive footage stage texture for this frame (texture 7; docs/plans/archive-video.md 2.3). Set by
    /// the render loop from ArchiveFootageService.frame; with nil (or videoMix 0) the plain pipeline runs.
    var videoTexture: MTLTexture?
    /// Layer B (texture 8): the other piece of a footage crossfade (A27).
    var videoTextureB: MTLTexture?

    // MARK: - Ghost Taps

    private let ghostTapManager = GhostTapManager()

    /// Music scene change: forward to the ghost tap manager (cheap compare; call every frame with
    /// `MusicModulation.ghostBurstSerial`).
    func requestGhostBurst(serial: UInt32) {
        ghostTapManager.requestBurst(serial: serial)
    }

    // MARK: - DrawableQueue (Bridge to RealityKit)

    private var drawableQueue: TextureResource.DrawableQueue?
    private(set) var textureResource: TextureResource?

    // Track renders for periodic logging
    private var renderCount: Int = 0

    /// One texture per image (current, previous, prepared next): textures are never overwritten in
    /// place, so a command buffer still in flight keeps sampling its own (docs/decisions/performance.md).
    private var imageTextures: [(image: CGImage, texture: MTLTexture)] = []
    private var syncUploadCount: Int = 0
    /// Builds image textures off the main actor (render loop prepares the next image with it).
    nonisolated let textureUploader: SourceTextureUploader

    // Performance tracking
    private var totalTextureUpdateTime: Double = 0
    private var totalGPURenderTime: Double = 0
    private var totalPresentTime: Double = 0
    private let drawableWorker = DispatchQueue(label: "Liminal.drawable", qos: .userInitiated)
    private var gpuBusyFrames = 0
    private var totalDrawableWaitTime: Double = 0
    private var maxDrawableWait: Double = 0
    private var perfFrameCount: Int = 0
    private var lastPerfLogTime: Date = Date()

    /// Per-pass GPU timing (MTLCommandBuffer gpuStart/EndTime). Shared with the dome mesh
    /// compute pass; drained by the render loop's PERF log.
    let gpuStats = GPUTimingStats()

    // MARK: - Triple Buffering
    // Semaphore allows up to 3 frames in flight, preventing GPU starvation
    // while avoiding blocking on waitUntilCompleted()
    private let inFlightSemaphore = DispatchSemaphore(value: 3)

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            LMLog.visual.error("❌ Metal not available")
            return nil
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            LMLog.visual.error("❌ Failed to create command queue")
            return nil
        }
        self.commandQueue = queue

        // Load shader library - same shaders as macOS
        guard let library = device.makeDefaultLibrary() else {
            LMLog.visual.error("❌ Failed to load Metal library")
            return nil
        }

        LMLog.visual.debug("📚 Metal library functions: \(library.functionNames)")

        guard let vertexFunc = library.makeFunction(name: "effectsVertex") else {
            LMLog.visual.error("❌ Failed to load effectsVertex")
            return nil
        }

        guard let fragmentFunc = DropPipelines.function(library, name: "effectsFragment") else {
            LMLog.visual.error("❌ Failed to load effectsFragment")
            return nil
        }

        guard let stereoFragmentFunc = DropPipelines.function(library, name: "effectsFragmentStereo") else {
            LMLog.visual.error("❌ Failed to load effectsFragmentStereo")
            return nil
        }

        guard let passthroughFragFunc = library.makeFunction(name: "passthroughFragment") else {
            LMLog.visual.error("❌ Failed to load passthroughFragment")
            return nil
        }

        // Create full effects pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = Self.renderFormat
        pipelineDescriptor.label = "effectsFragment"
        let drops = DropPipelines()
        dropPipelines = drops

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            drops.register(device: device, library: library, descriptor: pipelineDescriptor, name: "effectsFragment")
        } catch {
            LMLog.visual.error("❌ Failed to create effects pipeline: \(error.localizedDescription)")
            return nil
        }

        // Stereo MRT pipeline: shared distortion field, two eye outputs
        let stereoDescriptor = MTLRenderPipelineDescriptor()
        stereoDescriptor.vertexFunction = vertexFunc
        stereoDescriptor.fragmentFunction = stereoFragmentFunc
        stereoDescriptor.colorAttachments[0].pixelFormat = Self.renderFormat
        stereoDescriptor.colorAttachments[1].pixelFormat = Self.renderFormat
        stereoDescriptor.label = "effectsFragmentStereo"

        do {
            stereoPipelineState = try device.makeRenderPipelineState(descriptor: stereoDescriptor)
            drops.register(device: device, library: library, descriptor: stereoDescriptor, name: "effectsFragmentStereo")
        } catch {
            LMLog.visual.error("❌ Failed to create stereo effects pipeline: \(error.localizedDescription)")
            return nil
        }

        // Archive footage variants (docs/plans/archive-video.md 2.3); footage is skipped if they fail.
        func make(_ d: MTLRenderPipelineDescriptor, _ name: String) -> MTLRenderPipelineState? {
            guard let f = DropPipelines.function(library, name: name) else { return nil }
            d.fragmentFunction = f
            d.label = name
            let state = try? device.makeRenderPipelineState(descriptor: d)
            if state != nil { drops.register(device: device, library: library, descriptor: d, name: name) }
            return state
        }
        videoPipelineState = make(pipelineDescriptor, "effectsFragmentVideo")
        stereoVideoPipelineState = make(stereoDescriptor, "effectsFragmentStereoVideo")
        var mono: [Int: MTLRenderPipelineState] = [:], stereo: [Int: MTLRenderPipelineState] = [:]
        for v in FootageRecipe.fxVariants {
            let suffix = VideoComposite.variantSuffix(v)
            mono[v] = make(pipelineDescriptor, "effectsFragment" + suffix)
            stereo[v] = make(stereoDescriptor, "effectsFragmentStereo" + suffix)
        }
        videoFXPipelineStates = mono
        stereoVideoFXPipelineStates = stereo
        if videoPipelineState == nil || stereoVideoPipelineState == nil {
            LMLog.visual.error("📼 footage pipelines unavailable: archive footage will not show")
        }

        // Create passthrough pipeline for debugging
        let passthroughDescriptor = MTLRenderPipelineDescriptor()
        passthroughDescriptor.vertexFunction = vertexFunc
        passthroughDescriptor.fragmentFunction = passthroughFragFunc
        passthroughDescriptor.colorAttachments[0].pixelFormat = Self.renderFormat

        do {
            passthroughPipelineState = try device.makeRenderPipelineState(descriptor: passthroughDescriptor)
        } catch {
            LMLog.visual.error("❌ Failed to create passthrough pipeline: \(error.localizedDescription)")
            return nil
        }

        // Create sampler
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            LMLog.visual.error("❌ Failed to create sampler")
            return nil
        }
        self.samplerState = sampler

        // 1x1 black feedback placeholder (never sampled with weight: feedbackMix is 0 when it is bound)
        let blackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.renderFormat, width: 1, height: 1, mipmapped: false)
        blackDescriptor.usage = .shaderRead
        blackDescriptor.storageMode = .shared
        let black = device.makeTexture(descriptor: blackDescriptor)
        var blackPixel: [UInt8] = [0, 0, 0, 255]
        black?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &blackPixel, bytesPerRow: 4)
        self.blackTexture = black

        // Create default saliency texture (1x1 neutral gray)
        // IMPORTANT: Prevents undefined behavior when sampling nil texture
        let saliencyDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        saliencyDescriptor.usage = .shaderRead
        saliencyDescriptor.storageMode = .shared

        if let defaultSaliency = device.makeTexture(descriptor: saliencyDescriptor) {
            var grayPixel: UInt8 = 128  // 0.5 in normalized form
            defaultSaliency.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: 1, height: 1, depth: 1)),
                mipmapLevel: 0,
                withBytes: &grayPixel,
                bytesPerRow: 1
            )
            self.saliencyTexture = defaultSaliency
        }

        self.textureUploader = SourceTextureUploader(device: device, commandQueue: queue, size: Self.renderSize)

        let size = outputSize
        LMLog.visual.info("✅ OffscreenEffectsRenderer initialized - \(size)x\(size)")
    }

    // MARK: - DrawableQueue Setup

    /// Set up the DrawableQueue for RealityKit integration.
    /// Call this once, then use `textureResource` on your material.
    func setupDrawableQueue() async throws {
        let size = outputSize

        // `_srgb` so RealityKit decodes on sample. We never render into this format directly: passes
        // target a bgra8Unorm view (outputView(for:)), so the bytes are the shader's gamma values,
        // which RealityKit decodes to linear and the display re-encodes: same result as macOS.
        let descriptor = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: size,
            height: size,
            usage: [.renderTarget, .shaderRead],  // no .shaderWrite: allows lossless compression
            mipmapsMode: .none
        )

        let queue = try TextureResource.DrawableQueue(descriptor)
        queue.allowsNextDrawableTimeout = true

        // Create placeholder image for initial texture
        let placeholderImage = createPlaceholderImage(width: size, height: size)

        // Create texture resource from placeholder, then link to drawable queue
        // .raw semantic: the placeholder's bytes are uploaded as-is (it is replaced by the queue anyway)
        let resource = try await TextureResource(image: placeholderImage, options: .init(semantic: .raw))
        resource.replace(withDrawables: queue)

        self.drawableQueue = queue
        self.textureResource = resource

        LMLog.visual.info("✅ DrawableQueue set up - \(size)x\(size)")
    }

    private func createPlaceholderImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            fatalError("Failed to create placeholder context")
        }

        // Fill with black
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()!
    }

    // MARK: - Render

    // Staging texture for passthrough (reused)
    private var passthroughStaging: MTLTexture?

    /// DEBUG: Fill with solid color to verify pipeline works
    func renderSolidColor(red: Float, green: Float, blue: Float) -> Bool {
        renderCount += 1

        guard let drawableQueue = drawableQueue else {
            LMLog.visual.error("❌ SOLID COLOR: No drawable queue!")
            return false
        }

        guard let drawable = try? drawableQueue.nextDrawable() else {
            if renderCount <= 5 {
                LMLog.visual.warning("⚠️ SOLID COLOR #\(self.renderCount): No drawable available")
            }
            return false
        }

        let width = drawable.texture.width
        let height = drawable.texture.height

        if renderCount <= 3 {
            LMLog.visual.info("🔴 SOLID COLOR #\(self.renderCount): Filling \(width)x\(height) with RGB(\(red),\(green),\(blue))")
        }

        // Create/reuse staging texture
        if passthroughStaging == nil ||
           passthroughStaging?.width != width ||
           passthroughStaging?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared
            passthroughStaging = device.makeTexture(descriptor: desc)
        }

        guard let staging = passthroughStaging else { return false }

        // Fill with solid color (BGRA format)
        let b = UInt8(blue * 255)
        let g = UInt8(green * 255)
        let r = UInt8(red * 255)
        let a: UInt8 = 255

        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            pixelData[i] = b
            pixelData[i + 1] = g
            pixelData[i + 2] = r
            pixelData[i + 3] = a
        }

        staging.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: width * 4
        )

        // Blit to drawable
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return false }

        blitEncoder.copy(from: staging, to: drawable.texture)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        drawable.present()

        if renderCount <= 5 || renderCount % 60 == 0 {
            LMLog.visual.info("🔴 SOLID COLOR #\(self.renderCount): ✅ Presented RED")
        }

        return true
    }

    /// MINIMAL TEST: Just blit the source image directly to drawable, NO shaders.
    /// Use this to verify the basic DrawableQueue → RealityKit pipeline works.
    func renderSimplePassthrough(sourceImage: CGImage) -> Bool {
        renderCount += 1
        let shouldLog = renderCount <= 5 || renderCount % 60 == 0

        guard let drawableQueue = drawableQueue else {
            LMLog.visual.error("❌ PASSTHROUGH: No drawable queue!")
            return false
        }

        guard let drawable = try? drawableQueue.nextDrawable() else {
            if shouldLog {
                LMLog.visual.warning("⚠️ PASSTHROUGH #\(self.renderCount): No drawable available")
            }
            return false
        }

        let drawableWidth = drawable.texture.width
        let drawableHeight = drawable.texture.height

        if renderCount <= 5 {
            LMLog.visual.info("🎯 PASSTHROUGH #\(self.renderCount): source=\(sourceImage.width)x\(sourceImage.height), drawable=\(drawableWidth)x\(drawableHeight)")
        }

        // Create/reuse staging texture (shared storage for CPU writes)
        if passthroughStaging == nil ||
           passthroughStaging?.width != drawableWidth ||
           passthroughStaging?.height != drawableHeight {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: drawableWidth,
                height: drawableHeight,
                mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared  // CPU-writable!
            passthroughStaging = device.makeTexture(descriptor: desc)
            LMLog.visual.info("🎯 PASSTHROUGH: Created staging texture \(drawableWidth)x\(drawableHeight)")
        }

        guard let staging = passthroughStaging else {
            LMLog.visual.error("❌ PASSTHROUGH: Failed to create staging texture")
            return false
        }

        // Render CGImage to staging texture
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * drawableWidth
        var pixelData = [UInt8](repeating: 0, count: drawableWidth * drawableHeight * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: drawableWidth,
            height: drawableHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            LMLog.visual.error("❌ PASSTHROUGH: Failed to create CGContext")
            return false
        }

        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight))

        // Log sample pixels
        if renderCount <= 3 {
            let centerIdx = (drawableHeight / 2 * drawableWidth + drawableWidth / 2) * 4
            LMLog.visual.info("🎯 PASSTHROUGH #\(self.renderCount): CENTER=(\(pixelData[centerIdx]),\(pixelData[centerIdx+1]),\(pixelData[centerIdx+2]),\(pixelData[centerIdx+3]))")
        }

        // Write to staging texture (this works because it's .shared storage)
        staging.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: drawableWidth, height: drawableHeight, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )

        // Blit from staging to drawable using command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            LMLog.visual.error("❌ PASSTHROUGH: Failed to create command buffer")
            return false
        }

        blitEncoder.copy(from: staging, to: drawable.texture)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Present!
        drawable.present()

        if renderCount <= 5 || renderCount % 60 == 0 {
            LMLog.visual.info("🎯 PASSTHROUGH #\(self.renderCount): ✅ Presented via blit")
        }

        return true
    }

    /// RealityKit can hold all drawables while the compositor is busy. Wait on a
    /// serial worker, before sampling this frame's image, music clock or uniforms.
    func acquireDrawable() async -> TextureResource.Drawable? {
        // This serial worker is the only consumer of the mono queue during playback.
        guard let queue = drawableQueue else { return nil }
        nonisolated(unsafe) let drawableQueue = queue
        let started = CACurrentMediaTime()
        let drawable: TextureResource.Drawable? = await withCheckedContinuation { continuation in
            drawableWorker.async {
                continuation.resume(returning: try? drawableQueue.nextDrawable())
            }
        }
        let ms = (CACurrentMediaTime() - started) * 1000
        totalDrawableWaitTime += ms
        maxDrawableWait = max(maxDrawableWait, ms)
        return drawable
    }

    /// DEBUG -LiminalNoEffects: render the bare image (passthroughFragment) instead of effects.
    private let bypassShaderForDebug = DebugLaunchOptions.noEffects

    /// Render effects and present to DrawableQueue.
    /// - Parameters:
    ///   - sourceImage: The current source image
    ///   - previousImage: Optional previous image for GPU crossfade blending during transitions
    ///   - uniforms: Effect parameters (includes transitionProgress for blending)
    /// - Returns: True if rendering succeeded
    func renderAndPresent(drawable: TextureResource.Drawable, sourceImage: CGImage, previousImage: CGImage? = nil, uniforms: EffectsUniforms) -> Bool {
        renderCount += 1
        perfFrameCount += 1
        let shouldLog = renderCount == 1 || renderCount % 300 == 0

        // Track timing for each phase
        var textureUpdateTime: Double = 0
        var gpuRenderTime: Double = 0
        var presentTime: Double = 0

        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            gpuBusyFrames += 1
            return false
        }

        if shouldLog {
            LMLog.visual.info("🎬 renderAndPresent \(self.renderCount): sourceImage=\(sourceImage.width)x\(sourceImage.height), bypass=\(self.bypassShaderForDebug)")
        }

        // DEBUG: Use passthrough shader to test if shader pipeline works
        if bypassShaderForDebug {
            bindImageTextures(source: sourceImage, previous: nil)
            guard let sourceTexture = sourceTexture else {
                inFlightSemaphore.signal()
                LMLog.visual.error("❌ PASSTHROUGH: sourceTexture nil!")
                return false
            }

            if renderCount <= 3 {
                LMLog.visual.info("🔧 PASSTHROUGH SHADER: src=\(sourceTexture.width)x\(sourceTexture.height), out=\(self.outputSize)x\(self.outputSize)")
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                inFlightSemaphore.signal()
                return false
            }

            // Render using passthrough shader directly into the drawable (no effects, just samples texture)
            let renderPassDescriptor = makeDrawablePassDescriptor(for: outputView(for: drawable.texture))

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

            encoder.setRenderPipelineState(passthroughPipelineState)  // Use passthrough shader!

            // Still need uniforms buffer even though passthrough ignores most of it
            var dummyUniforms = EffectsUniforms(
                time: 0, kenBurnsScale: 1, kenBurnsOffsetX: 0, kenBurnsOffsetY: 0,
                distortionAmplitude: 0, distortionSpeed: 0, hueBaseShift: 0,
                hueWaveIntensity: 0, hueBlendAmount: 0, contrastBoost: 1, saturationBoost: 1,
                ghostTapMaxDistance: 0.25, saliencyInfluence: 0, hasSaliencyMap: 0,
                transitionProgress: 0, ghostTapCount: 0,
                chromaticAmount: 0,
                feedbackWarpAmount: 0, feedbackMix: 0,
                bloomRadius: 0, bloomAmount: 0,
                stereoOffset: 0,
                logSphereAmount: 0,
                fractalNoiseAmount: 0,
                fractalHueAmount: 0
            )
            encoder.setFragmentBytes(&dummyUniforms, length: MemoryLayout<EffectsUniforms>.size, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            // Async completion handler - signals semaphore when GPU finishes
            commandBuffer.addCompletedHandler { [weak self] buffer in
                self?.inFlightSemaphore.signal()
                if let error = buffer.error {
                    LMLog.visual.error("❌ PASSTHROUGH GPU error: \(error.localizedDescription)")
                }
            }

            commandBuffer.commit()
            // NO waitUntilCompleted() - GPU works asynchronously
            drawable.present()

            if renderCount <= 5 {
                LMLog.visual.info("🔧 PASSTHROUGH #\(self.renderCount): ✅ Rendered via passthrough shader")
            }
            return true
        }

        // --- Full shader path below ---
        // TIMING: Texture update phase
        let textureUpdateStart = Date()

        // Swap texture references (prepared off the main actor; sync upload only as a fallback)
        bindImageTextures(source: sourceImage, previous: previousImage)

        textureUpdateTime = Date().timeIntervalSince(textureUpdateStart) * 1000
        totalTextureUpdateTime += textureUpdateTime

        // TIMING: GPU render phase
        let gpuRenderStart = Date()

        guard let sourceTexture else {
            inFlightSemaphore.signal()
            LMLog.visual.warning("⚠️ Source texture is nil")
            return false
        }

        // Update ghost taps and get active count for optimized shader loop
        let ghostTapResult = ghostTapManager.updateWithCount(currentTime: uniforms.time)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            LMLog.visual.warning("⚠️ Failed to create command buffer")
            return false
        }

        // Render straight into the drawable (no intermediate texture, no copy)
        let target = outputView(for: drawable.texture)
        let renderPassDescriptor = makeDrawablePassDescriptor(for: target)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            inFlightSemaphore.signal()
            LMLog.visual.warning("⚠️ Failed to create render command encoder")
            return false
        }

        encoder.setRenderPipelineState(dropPipelines.pipeline(for: footagePipeline(uniforms) ?? pipelineState, uniforms: uniforms))

        // Set uniforms with ghost tap count for optimized shader loop
        var mutableUniforms = uniforms
        mutableUniforms.ghostTapCount = Float(ghostTapResult.activeCount)
        let feedback = feedbackSource(eye: 0, target: target)
        if feedback == nil { mutableUniforms.feedbackMix = 0 }
        encoder.setFragmentTexture(feedback ?? blackTexture, index: 4)
        lastOutput[0] = target
        encoder.setFragmentBytes(&mutableUniforms, length: MemoryLayout<EffectsUniforms>.size, index: 0)

        // Set ghost tap buffer
        encoder.setFragmentBytes(ghostTapResult.data, length: ghostTapResult.data.count * MemoryLayout<GhostTapData>.stride, index: 1)

        // Set textures
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(saliencyTexture, index: 2)
        // Previous texture for GPU crossfade (uses sourceTexture as fallback if no previous)
        encoder.setFragmentTexture(previousTexture ?? sourceTexture, index: 3)
        // Depth texture for volumetric atmosphere (index 5)
        if let depthTex = depthTexture {
            encoder.setFragmentTexture(depthTex, index: 5)
        }
        if uniforms.videoMix > 0, let videoTexture { encoder.setFragmentTexture(videoTexture, index: 7) }
        if uniforms.videoMixB > 0, let videoTextureB { encoder.setFragmentTexture(videoTextureB, index: 8) }
        encoder.setFragmentSamplerState(samplerState, index: 0)

        // Draw fullscreen quad (shader generates vertices from vertexID)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        gpuStats.track(commandBuffer, pass: "fx")

        // Async completion handler - signals semaphore when GPU finishes
        // This is the key fix: GPU and CPU now work in parallel
        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.inFlightSemaphore.signal()
            if let error = buffer.error {
                LMLog.visual.error("❌ GPU error: \(error.localizedDescription)")
            }
        }

        commandBuffer.commit()
        // NO waitUntilCompleted() - GPU works asynchronously while CPU prepares next frame

        // Present to RealityKit (schedules presentation at next vsync)
        drawable.present()

        // Note: GPU timing is now approximate since we don't wait
        gpuRenderTime = Date().timeIntervalSince(gpuRenderStart) * 1000
        totalGPURenderTime += gpuRenderTime
        totalPresentTime += 0.1  // Present is now async, negligible CPU time

        // Log detailed timing breakdown every second
        let timeSincePerfLog = Date().timeIntervalSince(lastPerfLogTime)
        if timeSincePerfLog >= 1.0 {
            let avgTextureUpdate = totalTextureUpdateTime / Double(perfFrameCount)
            let avgGPURender = totalGPURenderTime / Double(perfFrameCount)
            let avgPresent = totalPresentTime / Double(perfFrameCount)
            let avgDrawableWait = totalDrawableWaitTime / Double(perfFrameCount)
            let totalAvg = avgTextureUpdate + avgGPURender + avgPresent

            LMLog.visual.info("🔧 RENDERER TIMING: texture=\(String(format: "%.2f", avgTextureUpdate))ms | gpu=\(String(format: "%.2f", avgGPURender))ms | present=\(String(format: "%.2f", avgPresent))ms | TOTAL=\(String(format: "%.2f", totalAvg))ms/frame | syncUploads=\(self.syncUploadCount)")

            // Log wait times separately - these are the stutter culprits
            LMLog.visual.info("⏱️ WAIT TIMES: GPU busy skips=\(self.gpuBusyFrames) | drawable avg=\(avgDrawableWait, format: .fixed(precision: 2))ms max=\(self.maxDrawableWait, format: .fixed(precision: 1))ms")

            // Reset perf counters
            totalTextureUpdateTime = 0
            totalGPURenderTime = 0
            totalPresentTime = 0
            gpuBusyFrames = 0
            totalDrawableWaitTime = 0
            maxDrawableWait = 0
            perfFrameCount = 0
            lastPerfLogTime = Date()
        }

        if shouldLog {
            LMLog.visual.info("🎬 GPU render \(self.renderCount) complete - presented to DrawableQueue")
        }

        return true
    }

    // MARK: - Stereo Rendering

    /// Render effects to two separate drawable queues for stereo per-eye output.
    /// Each eye gets a slightly different UV offset based on depth for parallax.
    /// - Parameters:
    ///   - sourceImage: The current source image
    ///   - previousImage: Optional previous image for GPU crossfade
    ///   - uniforms: Effect parameters
    ///   - leftQueue: DrawableQueue for left eye
    ///   - rightQueue: DrawableQueue for right eye
    ///   - stereoOffset: Per-eye UV offset magnitude (oscillates for depth breathing)
    /// - Returns: True if both eyes rendered
    func renderStereoAndPresent(
        sourceImage: CGImage,
        previousImage: CGImage? = nil,
        uniforms: EffectsUniforms,
        leftQueue: TextureResource.DrawableQueue,
        rightQueue: TextureResource.DrawableQueue,
        stereoOffset: Float = 0.003
    ) -> Bool {
        renderCount += 1
        perfFrameCount += 1

        // Update textures (shared between both eyes)
        bindImageTextures(source: sourceImage, previous: previousImage)

        // Update ghost taps
        let ghostTapResult = ghostTapManager.updateWithCount(currentTime: uniforms.time)
        guard let sourceTexture else {
            return false
        }

        // Acquire both drawables first so both eyes can be written by one MRT pass.
        let leftDrawable = try? leftQueue.nextDrawable()
        let rightDrawable = try? rightQueue.nextDrawable()

        if bypassShaderForDebug {
            // DEBUG -LiminalNoEffects: bare image into each eye (no parallax, no effects).
            var ok = true
            for drawable in [leftDrawable, rightDrawable] {
                guard let drawable else { ok = false; continue }
                ok = renderPassthrough(to: drawable, sourceTexture: sourceTexture) && ok
            }
            return ok
        }

        if let leftDrawable, let rightDrawable {
            return renderBothEyes(
                left: leftDrawable,
                right: rightDrawable,
                sourceTexture: sourceTexture,
                ghostTaps: ghostTapResult.data,
                uniforms: uniforms,
                ghostTapCount: ghostTapResult.activeCount,
                stereoOffset: stereoOffset
            )
        }

        // Fallback: only one eye's drawable was available. Render that eye on its own
        // so it is not left showing a stale frame; the other eye catches up next frame.
        if !loggedStereoFallback {
            loggedStereoFallback = true
            LMLog.visual.info("⚠️ Stereo MRT fallback: only \(leftDrawable != nil ? "left" : (rightDrawable != nil ? "right" : "no")) drawable available, rendering per-eye")
        }

        let leftOk = leftDrawable.map { renderEyeToDrawable(
            drawable: $0,
            sourceTexture: sourceTexture,
            ghostTaps: ghostTapResult.data,
            uniforms: uniforms,
            ghostTapCount: ghostTapResult.activeCount,
            eyeOffset: -stereoOffset,  // Left eye shifts left
            passName: "L"
        ) } ?? false

        let rightOk = rightDrawable.map { renderEyeToDrawable(
            drawable: $0,
            sourceTexture: sourceTexture,
            ghostTaps: ghostTapResult.data,
            uniforms: uniforms,
            ghostTapCount: ghostTapResult.activeCount,
            eyeOffset: stereoOffset,  // Right eye shifts right
            passName: "R"
        ) } ?? false

        return leftOk && rightOk
    }

    /// DEBUG: passthroughFragment (no effects) straight into a drawable.
    private func renderPassthrough(to drawable: TextureResource.Drawable, sourceTexture: MTLTexture) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: makeDrawablePassDescriptor(for: outputView(for: drawable.texture))) else { return false }
        encoder.setRenderPipelineState(passthroughPipelineState)
        let zeroUniforms = [UInt8](repeating: 0, count: MemoryLayout<EffectsUniforms>.size)
        encoder.setFragmentBytes(zeroUniforms, length: zeroUniforms.count, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        drawable.present()
        return true
    }

    /// Render both eyes in one render pass with two colour attachments (MRT).
    /// The distortion field is computed once per pixel and shared by both eyes.
    private func renderBothEyes(
        left: TextureResource.Drawable,
        right: TextureResource.Drawable,
        sourceTexture: MTLTexture,
        ghostTaps: [GhostTapData],
        uniforms: EffectsUniforms,
        ghostTapCount: Int,
        stereoOffset: Float
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let leftTarget = outputView(for: left.texture)
        let rightTarget = outputView(for: right.texture)
        let descriptor = makeDrawablePassDescriptor(for: leftTarget)
        validateDrawableSize(right.texture)
        descriptor.colorAttachments[1].texture = rightTarget
        descriptor.colorAttachments[1].loadAction = .dontCare
        descriptor.colorAttachments[1].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }

        encoder.setRenderPipelineState(dropPipelines.pipeline(for: footagePipeline(uniforms, stereo: true) ?? stereoPipelineState,
                                                              uniforms: uniforms))

        // Shader applies -|offset| to the left eye and +|offset| to the right eye.
        var mutableUniforms = uniforms
        mutableUniforms.ghostTapCount = Float(ghostTapCount)
        mutableUniforms.stereoOffset = depthTexture != nil ? abs(stereoOffset) : 0
        // Feedback: each eye reads its own previous output. feedbackMix is shared by the pass, so if
        // either eye has none (first frame, or a recycled drawable), skip trails for this one frame.
        let leftFeedback = feedbackSource(eye: 0, target: leftTarget)
        let rightFeedback = feedbackSource(eye: 1, target: rightTarget)
        if leftFeedback == nil || rightFeedback == nil { mutableUniforms.feedbackMix = 0 }
        encoder.setFragmentTexture(leftFeedback ?? blackTexture, index: 4)
        encoder.setFragmentTexture(rightFeedback ?? blackTexture, index: 6)
        lastOutput = [leftTarget, rightTarget]
        encoder.setFragmentBytes(&mutableUniforms, length: MemoryLayout<EffectsUniforms>.size, index: 0)

        encoder.setFragmentBytes(ghostTaps, length: ghostTaps.count * MemoryLayout<GhostTapData>.stride, index: 1)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(saliencyTexture, index: 2)
        encoder.setFragmentTexture(previousTexture ?? sourceTexture, index: 3)
        if let depthTex = depthTexture {
            encoder.setFragmentTexture(depthTex, index: 5)
        }
        if uniforms.videoMix > 0, let videoTexture { encoder.setFragmentTexture(videoTexture, index: 7) }
        if uniforms.videoMixB > 0, let videoTextureB { encoder.setFragmentTexture(videoTextureB, index: 8) }
        encoder.setFragmentSamplerState(samplerState, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        gpuStats.track(commandBuffer, pass: "eyes")
        commandBuffer.commit()
        left.present()
        right.present()
        return true
    }

    /// Render a single eye pass to a drawable queue.
    private func renderEyeToDrawable(
        drawable: TextureResource.Drawable,
        sourceTexture: MTLTexture,
        ghostTaps: [GhostTapData],
        uniforms: EffectsUniforms,
        ghostTapCount: Int,
        eyeOffset: Float,
        passName: String
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        // Render straight into this eye's drawable (no intermediate texture, no copy)
        let target = outputView(for: drawable.texture)
        let renderPassDescriptor = makeDrawablePassDescriptor(for: target)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return false
        }

        encoder.setRenderPipelineState(dropPipelines.pipeline(for: footagePipeline(uniforms) ?? pipelineState, uniforms: uniforms))

        // Stereo parallax is applied in-shader using depth + this signed eye offset.
        var mutableUniforms = uniforms
        mutableUniforms.ghostTapCount = Float(ghostTapCount)
        mutableUniforms.stereoOffset = depthTexture != nil ? eyeOffset : 0
        let eye = eyeOffset < 0 ? 0 : 1
        let feedback = feedbackSource(eye: eye, target: target)
        if feedback == nil { mutableUniforms.feedbackMix = 0 }
        encoder.setFragmentTexture(feedback ?? blackTexture, index: 4)
        lastOutput[eye] = target
        encoder.setFragmentBytes(&mutableUniforms, length: MemoryLayout<EffectsUniforms>.size, index: 0)

        encoder.setFragmentBytes(ghostTaps, length: ghostTaps.count * MemoryLayout<GhostTapData>.stride, index: 1)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(saliencyTexture, index: 2)
        encoder.setFragmentTexture(previousTexture ?? sourceTexture, index: 3)
        if let depthTex = depthTexture {
            encoder.setFragmentTexture(depthTex, index: 5)
        }
        if uniforms.videoMix > 0, let videoTexture { encoder.setFragmentTexture(videoTexture, index: 7) }
        if uniforms.videoMixB > 0, let videoTextureB { encoder.setFragmentTexture(videoTextureB, index: 8) }
        encoder.setFragmentSamplerState(samplerState, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // No copy to split out any more, so -LiminalPerfSplitPasses is a no-op here.
        gpuStats.track(commandBuffer, pass: "eye" + passName)
        commandBuffer.commit()
        drawable.present()
        return true
    }

    /// The footage variant when footage shows this frame (texture and mix), else nil (plain pipeline).
    private func footagePipeline(_ u: EffectsUniforms, stereo: Bool = false) -> MTLRenderPipelineState? {
        guard (u.videoMix > 0 && videoTexture != nil) || (u.videoMixB > 0 && videoTextureB != nil) else { return nil }
        let v = VideoComposite.footageVariant(u)
        if stereo { return stereoVideoFXPipelineStates[v] ?? stereoVideoPipelineState }
        return videoFXPipelineStates[v] ?? videoPipelineState
    }

    /// `bgra8Unorm` view of an `_srgb` drawable texture (cached; see `renderFormat`). Falls back to the
    /// drawable itself if the view cannot be made, which only happens if the drawable's format changed.
    private func outputView(for texture: MTLTexture) -> MTLTexture {
        if texture.pixelFormat == Self.renderFormat { return texture }
        if let hit = outputViews.first(where: { $0.texture === texture }) { return hit.view }
        guard let view = texture.makeTextureView(pixelFormat: Self.renderFormat) else {
            if !loggedViewFailure {
                loggedViewFailure = true
                LMLog.visual.error("❌ Could not make bgra8Unorm view of drawable (format \(texture.pixelFormat.rawValue)); output will be double sRGB-encoded")
            }
            return texture
        }
        outputViews.append((texture, view))
        if outputViews.count > 12 { outputViews.removeFirst(outputViews.count - 12) }
        LMLog.visual.info("🎨 Output view #\(self.outputViews.count): drawable format \(texture.pixelFormat.rawValue) → view \(view.pixelFormat.rawValue)")
        return view
    }

    /// Previous output for this eye, or nil if there is none or it is the texture about to be written
    /// (a render pass must not sample its own attachment).
    private func feedbackSource(eye: Int, target: MTLTexture) -> MTLTexture? {
        guard let prev = lastOutput[eye], prev !== target else { return nil }
        if let a = prev.parent, let b = target.parent, a === b { return nil }
        return prev
    }

    /// Render pass that writes the effects quad straight into a drawable texture.
    /// The fullscreen quad covers every pixel, so the old contents are never read (.dontCare).
    private func makeDrawablePassDescriptor(for texture: MTLTexture) -> MTLRenderPassDescriptor {
        validateDrawableSize(texture)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }

    /// The render resolution must stay 2048² (user requirement); verify every drawable we write.
    private func validateDrawableSize(_ texture: MTLTexture) {
        let matches = texture.width == outputSize && texture.height == outputSize
        if !loggedDrawableSize || !matches {
            if matches {
                loggedDrawableSize = true
                LMLog.visual.info("🖼️ Direct drawable render: \(texture.width)x\(texture.height) format=\(texture.pixelFormat.rawValue)")
            } else if !loggedDrawableSizeMismatch {
                loggedDrawableSizeMismatch = true
                LMLog.visual.error("❌ Drawable is \(texture.width)x\(texture.height), expected \(self.outputSize)x\(self.outputSize)")
            }
        }
        assert(matches, "Drawable size must match outputSize")
    }

    // MARK: - Private

    /// Register a texture built off the main actor (`textureUploader`) for `image`, so the frame
    /// that first shows it only swaps references.
    func registerPreparedTexture(_ texture: MTLTexture, for image: CGImage) {
        imageTextures.removeAll { $0.image === image }
        imageTextures.append((image, texture))
        trimImageTextures(keeping: [image])
    }

    /// Point `sourceTexture` / `previousTexture` at the textures of these images. Nil previous
    /// (not transitioning) clears it so the shader falls back to the source.
    private func bindImageTextures(source: CGImage, previous: CGImage?) {
        sourceTexture = texture(for: source, label: "source")
        previousTexture = previous.flatMap { texture(for: $0, label: "previous") }
        // Entries are pinned by the CGImage they hold, so identity can never be reused by a new image.
        if imageTextures.count > 3 { trimImageTextures(keeping: [source] + (previous.map { [$0] } ?? [])) }
    }

    private func texture(for image: CGImage, label: String) -> MTLTexture? {
        if let hit = imageTextures.first(where: { $0.image === image }) { return hit.texture }
        // Fallback: image was not prepared (first frame / a caller that skips preparation). Still a
        // NEW texture, never an overwrite of one the GPU may be reading.
        let start = Date()
        guard let texture = textureUploader.makeTexture(from: image, label: label) else { return nil }
        syncUploadCount += 1
        LMLog.visual.info("🔧 Sync \(label, privacy: .public) texture upload \(image.width)x\(image.height) -> \(self.outputSize)² in \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000), privacy: .public)ms")
        imageTextures.append((image, texture))
        return texture
    }

    /// Drop the oldest textures beyond three (current + previous + one prepared), never the kept ones.
    private func trimImageTextures(keeping kept: [CGImage]) {
        while imageTextures.count > 3,
              let i = imageTextures.firstIndex(where: { entry in !kept.contains { $0 === entry.image } }) {
            imageTextures.remove(at: i)
        }
    }

    /// Update the saliency texture for effects that use it.
    func updateSaliencyTexture(from cgImage: CGImage?) {
        guard let cgImage = cgImage else {
            saliencyTexture = nil
            return
        }

        let width = cgImage.width
        let height = cgImage.height

        // Create or recreate texture if needed
        if saliencyTexture == nil ||
           saliencyTexture?.width != width ||
           saliencyTexture?.height != height {

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,  // Single channel for saliency
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared

            saliencyTexture = device.makeTexture(descriptor: descriptor)
        }

        guard let texture = saliencyTexture else { return }

        // Convert grayscale CGImage to R8 texture
        let bytesPerRow = width
        var pixelData = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )
    }

    /// Update the depth texture from a depth map CGImage.
    /// The depth map is grayscale (0=far, 1=near).
    func updateDepthTexture(from cgImage: CGImage) {
        if let texture = textureUploader.makeDepthTexture(from: cgImage) { depthTexture = texture }
    }
}

#endif
