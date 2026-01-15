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
    private var uniformBuffer: MTLBuffer?
    private var ghostTapBuffer: MTLBuffer?

    // Source texture (from morphPlayer - current/target image)
    private var sourceTexture: MTLTexture?
    private var textureLoader: MTKTextureLoader?
    private var lastSourceImageHash: Int = 0  // Track image changes

    // Previous texture (for GPU crossfade blending during transitions)
    private var previousTexture: MTLTexture?
    private var lastPreviousImageHash: Int = 0

    // Saliency texture (from DepthAnalyzer)
    private var saliencyTexture: MTLTexture?
    private var lastSaliencyImageHash: Int = 0

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
        ghostTapCount: 0
    )

    /// Delay setting from slider (0-1), controls ghost tap spawn frequency
    var delay: Float = 0.5

    // Track if we have a valid source
    private var hasValidSource = false

    // MARK: - Performance Tracking

    private var frameCount: Int = 0
    private var lastLogTime: Date = Date()
    private var totalDrawTime: Double = 0
    private var textureUpdateCount: Int = 0

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

        guard let fragmentFunction = library.makeFunction(name: "effectsFragment") else {
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

        // Create uniform buffer
        uniformBuffer = device.makeBuffer(length: MemoryLayout<EffectsUniforms>.size, options: .storageModeShared)
        if uniformBuffer != nil {
            LMLog.visual.debug("✅ Uniform buffer created: \(MemoryLayout<EffectsUniforms>.size) bytes")
        }

        // Create ghost tap buffer (8 taps * 16 bytes each)
        let ghostTapBufferSize = GhostTapManager.maxTaps * MemoryLayout<GhostTapData>.stride
        ghostTapBuffer = device.makeBuffer(length: ghostTapBufferSize, options: .storageModeShared)
        if ghostTapBuffer != nil {
            LMLog.visual.debug("✅ Ghost tap buffer created: \(ghostTapBufferSize) bytes")
        }
    }

    // MARK: - Texture Management

    /// Update the source image from morphPlayer - ONLY if image changed
    func updateSourceImage(_ image: NSImage?) {
        guard let image = image else {
            if hasValidSource {
                LMLog.visual.debug("⚠️ Source image became nil")
            }
            hasValidSource = false
            return
        }

        // Check if image actually changed using hash
        let newHash = image.hash
        if newHash == lastSourceImageHash && hasValidSource {
            // Same image, skip expensive texture creation
            return
        }

        guard let device = self.device,
              let textureLoader = self.textureLoader else {
            hasValidSource = false
            return
        }

        // Convert NSImage to CGImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            LMLog.visual.error("❌ Failed to get CGImage from NSImage")
            hasValidSource = false
            return
        }

        // Load as Metal texture
        let startTime = Date()
        do {
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false
            ]
            sourceTexture = try textureLoader.newTexture(cgImage: cgImage, options: options)
            hasValidSource = true
            lastSourceImageHash = newHash
            textureUpdateCount += 1

            let loadTime = Date().timeIntervalSince(startTime) * 1000
            if let src = sourceTexture {
                let updateNum = textureUpdateCount
                LMLog.visual.debug("🖼️ Source texture updated: \(src.width)x\(src.height) in \(String(format: "%.1f", loadTime))ms (update #\(updateNum))")
            }
        } catch {
            LMLog.visual.error("❌ Failed to create texture: \(error.localizedDescription)")
            hasValidSource = false
        }
    }

    /// Update the saliency map texture - ONLY if image changed
    func updateSaliencyMap(_ image: NSImage?) {
        guard let image = image else {
            saliencyTexture = nil
            return
        }

        // Check if saliency map actually changed
        let newHash = image.hash
        if newHash == lastSaliencyImageHash && saliencyTexture != nil {
            return
        }

        guard let textureLoader = self.textureLoader else {
            return
        }

        // Convert NSImage to CGImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            LMLog.visual.error("❌ Failed to get CGImage from saliency NSImage")
            return
        }

        // Load as Metal texture
        do {
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false
            ]
            saliencyTexture = try textureLoader.newTexture(cgImage: cgImage, options: options)
            lastSaliencyImageHash = newHash

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

        guard let device = self.device,
              let textureLoader = self.textureLoader else {
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
            previousTexture = try textureLoader.newTexture(cgImage: cgImage, options: options)
            lastPreviousImageHash = newHash

            if let tex = previousTexture {
                LMLog.visual.debug("🔄 Previous texture loaded for crossfade: \(tex.width)x\(tex.height)")
            }
        } catch {
            LMLog.visual.error("❌ Failed to create previous texture: \(error.localizedDescription)")
        }
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        let drawStart = Date()

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

        guard let uniformBuffer = uniformBuffer,
              let ghostTapBuffer = ghostTapBuffer else {
            LMLog.visual.error("❌ Skipping draw: buffer nil")
            return
        }

        // Update ghost taps and get active count for optimized shader loop
        let ghostTapResult = ghostTapManager.updateWithCount(currentTime: uniforms.time, delay: delay)

        // Copy ghost tap data to GPU buffer
        ghostTapBuffer.contents().copyMemory(
            from: ghostTapResult.data,
            byteCount: GhostTapManager.maxTaps * MemoryLayout<GhostTapData>.stride
        )

        // Copy uniforms to GPU buffer with ghost tap count
        var uniformsCopy = uniforms
        uniformsCopy.hasSaliencyMap = saliencyTexture != nil ? 1.0 : 0.0
        uniformsCopy.ghostTapCount = Float(ghostTapResult.activeCount)
        memcpy(uniformBuffer.contents(), &uniformsCopy, MemoryLayout<EffectsUniforms>.size)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            LMLog.visual.error("❌ Failed to create command buffer")
            return
        }

        // Single render pass with ghost taps
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            if let saliencyTex = saliencyTexture {
                encoder.setFragmentTexture(saliencyTex, index: 2)
            }
            // Previous texture for GPU crossfade (falls back to source if no transition)
            encoder.setFragmentTexture(previousTexture ?? sourceTexture, index: 3)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(ghostTapBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Track frame timing
        frameCount += 1
        let drawTime = Date().timeIntervalSince(drawStart) * 1000
        totalDrawTime += drawTime

        // Log performance every second
        let timeSinceLastLog = Date().timeIntervalSince(lastLogTime)
        if timeSinceLastLog >= 1.0 {
            let avgDrawTime = totalDrawTime / Double(frameCount)
            let fps = Double(frameCount) / timeSinceLastLog

            let srcW = sourceTexture.width
            let srcH = sourceTexture.height
            let texUpdates = textureUpdateCount
            let delayPct = delay * 100

            LMLog.visual.info("📊 METAL PERF: fps=\(String(format: "%.1f", fps)) avgDraw=\(String(format: "%.2f", avgDrawTime))ms delay=\(String(format: "%.0f", delayPct))% src=\(srcW)x\(srcH) texUpdates=\(texUpdates)")

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
}

// MARK: - SwiftUI Wrapper

struct EffectsMetalViewRepresentable: NSViewRepresentable {
    let sourceImage: NSImage?
    let previousImage: NSImage?  // For GPU crossfade blending
    let saliencyMap: NSImage?
    let uniforms: EffectsUniforms  // Single struct - matches visionOS pattern
    let delay: Float  // Delay slider value (0-1), controls ghost tap spawn frequency

    func makeNSView(context: Context) -> EffectsMetalView {
        let view = EffectsMetalView()
        LMLog.visual.info("🎬 EffectsMetalViewRepresentable created")
        return view
    }

    func updateNSView(_ nsView: EffectsMetalView, context: Context) {
        // Update source image (internally checks if changed)
        nsView.updateSourceImage(sourceImage)

        // Update previous image for GPU crossfade (internally checks if changed)
        nsView.updatePreviousImage(previousImage)

        // Update saliency map (internally checks if changed)
        nsView.updateSaliencyMap(saliencyMap)

        // Pass uniforms and delay
        nsView.uniforms = uniforms
        nsView.delay = delay
    }
}

#endif
