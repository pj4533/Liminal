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

    // Double-buffered feedback textures
    private var feedbackTextures: [MTLTexture] = []
    private var currentFeedbackIndex = 0

    // Source texture (from morphPlayer)
    private var sourceTexture: MTLTexture?
    private var textureLoader: MTKTextureLoader?
    private var lastSourceImageHash: Int = 0  // Track image changes

    // Saliency texture (from DepthAnalyzer)
    private var saliencyTexture: MTLTexture?
    private var lastSaliencyImageHash: Int = 0

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
        feedbackAmount: 0.5,
        feedbackZoom: 0.96,
        feedbackDecay: 0.5,
        saliencyInfluence: 0.6,
        hasSaliencyMap: 0,
        transitionProgress: 0
    )

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
    }

    // MARK: - Texture Management

    private func createFeedbackTextures(width: Int, height: Int) {
        guard let device = self.device else { return }

        // Only recreate if size changed
        if let existing = feedbackTextures.first,
           existing.width == width && existing.height == height {
            return
        }

        feedbackTextures.removeAll()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private

        // Create two textures for double buffering
        for i in 0..<2 {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                LMLog.visual.error("❌ Failed to create feedback texture \(i)")
                continue
            }
            feedbackTextures.append(texture)
            LMLog.visual.debug("📦 Created feedback texture \(i): \(width)x\(height)")
        }

        currentFeedbackIndex = 0
        let count = feedbackTextures.count
        LMLog.visual.info("📦 Feedback textures ready: \(width)x\(height), count=\(count)")
    }

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
                createFeedbackTextures(width: src.width, height: src.height)
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

        guard let uniformBuffer = uniformBuffer else {
            LMLog.visual.error("❌ Skipping draw: uniformBuffer nil")
            return
        }

        guard feedbackTextures.count >= 2 else {
            let fbCount = feedbackTextures.count
            LMLog.visual.error("❌ Skipping draw: only \(fbCount) feedback textures")
            return
        }

        // Copy uniforms to GPU buffer (uniforms are set externally via the uniforms property)
        // Update hasSaliencyMap based on current saliency texture state
        var uniformsCopy = uniforms
        uniformsCopy.hasSaliencyMap = saliencyTexture != nil ? 1.0 : 0.0
        memcpy(uniformBuffer.contents(), &uniformsCopy, MemoryLayout<EffectsUniforms>.size)

        // Get feedback textures (read from current, write to next)
        let readFeedback = feedbackTextures[currentFeedbackIndex]
        let writeFeedbackIndex = (currentFeedbackIndex + 1) % 2
        let writeFeedback = feedbackTextures[writeFeedbackIndex]

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            LMLog.visual.error("❌ Failed to create command buffer")
            return
        }

        // === PASS 1: Render with feedback to writeFeedback texture ===
        let feedbackPassDescriptor = MTLRenderPassDescriptor()
        feedbackPassDescriptor.colorAttachments[0].texture = writeFeedback
        feedbackPassDescriptor.colorAttachments[0].loadAction = .clear
        feedbackPassDescriptor.colorAttachments[0].storeAction = .store
        feedbackPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: feedbackPassDescriptor) {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentTexture(readFeedback, index: 1)
            if let saliencyTex = saliencyTexture {
                encoder.setFragmentTexture(saliencyTex, index: 2)
            }
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        // === PASS 2: Copy writeFeedback (which now has trails) to screen ===
        // BUG FIX: Was using readFeedback, should use writeFeedback for trails to show
        let screenPassDescriptor = MTLRenderPassDescriptor()
        screenPassDescriptor.colorAttachments[0].texture = drawable.texture
        screenPassDescriptor.colorAttachments[0].loadAction = .clear
        screenPassDescriptor.colorAttachments[0].storeAction = .store
        screenPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: screenPassDescriptor) {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentTexture(writeFeedback, index: 1)  // USE writeFeedback for trails!
            if let saliencyTex = saliencyTexture {
                encoder.setFragmentTexture(saliencyTex, index: 2)
            }
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Swap feedback buffers for next frame
        currentFeedbackIndex = writeFeedbackIndex

        // Track frame timing
        frameCount += 1
        let drawTime = Date().timeIntervalSince(drawStart) * 1000
        totalDrawTime += drawTime

        // Log performance every second
        let timeSinceLastLog = Date().timeIntervalSince(lastLogTime)
        if timeSinceLastLog >= 1.0 {
            let avgDrawTime = totalDrawTime / Double(frameCount)
            let fps = Double(frameCount) / timeSinceLastLog

            // Extract values for logging (now from uniforms struct)
            let fbPct = uniforms.feedbackAmount * 100
            let srcW = sourceTexture.width
            let srcH = sourceTexture.height
            let fbIdx = currentFeedbackIndex
            let texUpdates = textureUpdateCount

            LMLog.visual.info("📊 METAL PERF: fps=\(String(format: "%.1f", fps)) avgDraw=\(String(format: "%.2f", avgDrawTime))ms fb=\(String(format: "%.0f", fbPct))% src=\(srcW)x\(srcH) fbIdx=\(fbIdx) texUpdates=\(texUpdates)")

            // Log uniforms once per second for debugging
            let t = uniforms.time
            let kb = uniforms.kenBurnsScale
            let kbX = uniforms.kenBurnsOffsetX
            let kbY = uniforms.kenBurnsOffsetY
            let dist = uniforms.distortionAmplitude
            let hue = uniforms.hueBaseShift
            let fb = uniforms.feedbackAmount
            let fbZoom = uniforms.feedbackZoom
            let fbDecay = uniforms.feedbackDecay
            LMLog.visual.debug("🎛️ UNIFORMS: t=\(String(format: "%.1f", t)) kb=\(String(format: "%.2f", kb)) kbOff=(\(String(format: "%.2f", kbX)),\(String(format: "%.2f", kbY))) dist=\(String(format: "%.3f", dist)) hue=\(String(format: "%.2f", hue)) fb=\(String(format: "%.2f", fb)) fbZoom=\(String(format: "%.3f", fbZoom)) fbDecay=\(String(format: "%.2f", fbDecay))")

            // Reset counters
            frameCount = 0
            totalDrawTime = 0
            textureUpdateCount = 0
            lastLogTime = Date()
        }
    }

    /// Reset the feedback buffer (call when stopping playback)
    func resetFeedback() {
        feedbackTextures.removeAll()
        currentFeedbackIndex = 0
        LMLog.visual.info("🔄 Feedback buffer reset")
    }
}

// MARK: - SwiftUI Wrapper

struct EffectsMetalViewRepresentable: NSViewRepresentable {
    let sourceImage: NSImage?
    let saliencyMap: NSImage?
    let uniforms: EffectsUniforms  // Single struct - matches visionOS pattern

    func makeNSView(context: Context) -> EffectsMetalView {
        let view = EffectsMetalView()
        LMLog.visual.info("🎬 EffectsMetalViewRepresentable created")
        return view
    }

    func updateNSView(_ nsView: EffectsMetalView, context: Context) {
        // Update source image (internally checks if changed)
        nsView.updateSourceImage(sourceImage)

        // Update saliency map (internally checks if changed)
        nsView.updateSaliencyMap(saliencyMap)

        // Pass uniforms directly - single assignment, platform parity with visionOS
        nsView.uniforms = uniforms
    }
}

#endif
