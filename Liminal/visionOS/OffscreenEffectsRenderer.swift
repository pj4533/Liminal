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
import RealityKit
import OSLog

/// Renders effects to an offscreen texture, bridged to RealityKit via DrawableQueue.
@MainActor
final class OffscreenEffectsRenderer {

    // MARK: - Metal Objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let passthroughPipelineState: MTLRenderPipelineState  // DEBUG: Simple passthrough
    private let samplerState: MTLSamplerState

    // MARK: - Textures

    private var sourceTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var feedbackTexture: MTLTexture?
    private var saliencyTexture: MTLTexture?

    private let outputSize: Int = 2048  // Output texture resolution

    // MARK: - DrawableQueue (Bridge to RealityKit)

    private var drawableQueue: TextureResource.DrawableQueue?
    private(set) var textureResource: TextureResource?

    // Track renders for periodic logging
    private var renderCount: Int = 0

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

        guard let fragmentFunc = library.makeFunction(name: "effectsFragment") else {
            LMLog.visual.error("❌ Failed to load effectsFragment")
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
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            LMLog.visual.error("❌ Failed to create effects pipeline: \(error.localizedDescription)")
            return nil
        }

        // Create passthrough pipeline for debugging
        let passthroughDescriptor = MTLRenderPipelineDescriptor()
        passthroughDescriptor.vertexFunction = vertexFunc
        passthroughDescriptor.fragmentFunction = passthroughFragFunc
        passthroughDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

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

        // Create output and feedback textures
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputSize,
            height: outputSize,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared

        self.outputTexture = device.makeTexture(descriptor: textureDescriptor)
        self.feedbackTexture = device.makeTexture(descriptor: textureDescriptor)

        // Initialize feedback to black (prevents garbage on first frame)
        if let feedback = self.feedbackTexture {
            let blackData = [UInt8](repeating: 0, count: outputSize * outputSize * 4)
            feedback.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: outputSize, height: outputSize, depth: 1)),
                mipmapLevel: 0,
                withBytes: blackData,
                bytesPerRow: outputSize * 4
            )
        }

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

        let size = outputSize
        LMLog.visual.info("✅ OffscreenEffectsRenderer initialized - \(size)x\(size)")
    }

    // MARK: - DrawableQueue Setup

    /// Set up the DrawableQueue for RealityKit integration.
    /// Call this once, then use `textureResource` on your material.
    func setupDrawableQueue() async throws {
        let size = outputSize

        let descriptor = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: .bgra8Unorm,
            width: size,
            height: size,
            usage: [.renderTarget, .shaderRead, .shaderWrite],
            mipmapsMode: .none
        )

        let queue = try TextureResource.DrawableQueue(descriptor)
        queue.allowsNextDrawableTimeout = true

        // Create placeholder image for initial texture
        let placeholderImage = createPlaceholderImage(width: size, height: size)

        // Create texture resource from placeholder, then link to drawable queue
        let resource = try await TextureResource(image: placeholderImage, options: .init(semantic: .color))
        resource.replace(withDrawables: queue)

        self.drawableQueue = queue
        self.textureResource = resource

        LMLog.visual.info("✅ DrawableQueue set up - \(size)x\(size)")
    }

    private func createPlaceholderImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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

    // DEBUG: Bypass shader to isolate if issue is texture update or shader
    private let bypassShaderForDebug = false  // Now testing effectsFragment stages

    /// Render effects and present to DrawableQueue.
    /// - Parameters:
    ///   - sourceImage: The source image (from visual engine)
    ///   - uniforms: Effect parameters
    /// - Returns: True if rendering succeeded
    func renderAndPresent(sourceImage: CGImage, uniforms: EffectsUniforms) -> Bool {
        renderCount += 1
        let shouldLog = renderCount == 1 || renderCount % 300 == 0

        guard let drawableQueue = drawableQueue else {
            LMLog.visual.warning("⚠️ No drawable queue (render \(self.renderCount))")
            return false
        }

        guard let drawable = try? drawableQueue.nextDrawable() else {
            if shouldLog {
                LMLog.visual.warning("⚠️ No drawable available (render \(self.renderCount))")
            }
            return false
        }

        if shouldLog {
            LMLog.visual.info("🎬 renderAndPresent \(self.renderCount): sourceImage=\(sourceImage.width)x\(sourceImage.height), bypass=\(self.bypassShaderForDebug)")
        }

        // DEBUG: Use passthrough shader to test if shader pipeline works
        if bypassShaderForDebug {
            guard let outputTexture = outputTexture else {
                LMLog.visual.warning("⚠️ No output texture for passthrough")
                return false
            }

            updateSourceTexture(from: sourceImage)
            guard let sourceTexture = sourceTexture else {
                LMLog.visual.error("❌ PASSTHROUGH: sourceTexture nil!")
                return false
            }

            if renderCount <= 3 {
                LMLog.visual.info("🔧 PASSTHROUGH SHADER: src=\(sourceTexture.width)x\(sourceTexture.height), out=\(self.outputSize)x\(self.outputSize)")
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

            // Render using passthrough shader (no effects, just samples texture)
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = outputTexture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

            encoder.setRenderPipelineState(passthroughPipelineState)  // Use passthrough shader!

            // Still need uniforms buffer even though passthrough ignores most of it
            var dummyUniforms = EffectsUniforms(
                time: 0, kenBurnsScale: 1, kenBurnsOffsetX: 0, kenBurnsOffsetY: 0,
                distortionAmplitude: 0, distortionSpeed: 0, hueBaseShift: 0,
                hueWaveIntensity: 0, hueBlendAmount: 0, contrastBoost: 1, saturationBoost: 1,
                feedbackAmount: 0, feedbackZoom: 1, feedbackDecay: 1, saliencyInfluence: 0, hasSaliencyMap: 0
            )
            encoder.setFragmentBytes(&dummyUniforms, length: MemoryLayout<EffectsUniforms>.size, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            // Blit output to drawable
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.copy(
                    from: outputTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: outputSize, height: outputSize, depth: 1),
                    to: drawable.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blitEncoder.endEncoding()
            }

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            drawable.present()

            if renderCount <= 5 {
                LMLog.visual.info("🔧 PASSTHROUGH #\(self.renderCount): ✅ Rendered via passthrough shader")
            }
            return true
        }

        // --- Full shader path below ---
        guard let outputTexture = outputTexture else {
            LMLog.visual.warning("⚠️ No output texture (render \(self.renderCount))")
            return false
        }

        // Update source texture from CGImage
        updateSourceTexture(from: sourceImage)

        guard let sourceTexture = sourceTexture else {
            LMLog.visual.warning("⚠️ Source texture is nil after update")
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            LMLog.visual.warning("⚠️ Failed to create command buffer")
            return false
        }

        // Render to our output texture
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = outputTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            LMLog.visual.warning("⚠️ Failed to create render command encoder")
            return false
        }

        encoder.setRenderPipelineState(pipelineState)

        // Set uniforms
        var mutableUniforms = uniforms
        encoder.setFragmentBytes(&mutableUniforms, length: MemoryLayout<EffectsUniforms>.size, index: 0)

        // Set textures
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(feedbackTexture, index: 1)
        encoder.setFragmentTexture(saliencyTexture, index: 2)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        // Draw fullscreen quad (shader generates vertices from vertexID)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Copy output to drawable
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(
                from: outputTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outputSize, height: outputSize, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }

        // Copy output to feedback for next frame's trails
        if let feedbackTexture = feedbackTexture,
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(from: outputTexture, to: feedbackTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Check for GPU errors
        if let error = commandBuffer.error {
            LMLog.visual.error("❌ GPU error: \(error.localizedDescription)")
            return false
        }

        // Present to RealityKit
        drawable.present()

        if shouldLog {
            LMLog.visual.info("🎬 GPU render \(self.renderCount) complete - presented to DrawableQueue")
        }

        return true
    }

    // MARK: - Private

    private func updateSourceTexture(from cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height

        // Create or recreate texture if needed
        if sourceTexture == nil ||
           sourceTexture?.width != width ||
           sourceTexture?.height != height {

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared

            sourceTexture = device.makeTexture(descriptor: descriptor)
        }

        guard let texture = sourceTexture else { return }

        // Convert CGImage to BGRA texture data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue  // BGRA
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )
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
}

#endif
