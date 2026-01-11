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

        // Create pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            LMLog.visual.error("❌ Failed to create pipeline: \(error.localizedDescription)")
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

    /// Render effects and present to DrawableQueue.
    /// - Parameters:
    ///   - sourceImage: The source image (from visual engine)
    ///   - uniforms: Effect parameters
    /// - Returns: True if rendering succeeded
    func renderAndPresent(sourceImage: CGImage, uniforms: EffectsUniforms) -> Bool {
        guard let drawableQueue = drawableQueue,
              let outputTexture = outputTexture else {
            LMLog.visual.debug("🖼️ No drawable queue or output texture")
            return false
        }

        // Get next drawable
        guard let drawable = try? drawableQueue.nextDrawable() else {
            LMLog.visual.debug("🖼️ No drawable available")
            return false
        }

        // Update source texture from CGImage
        updateSourceTexture(from: sourceImage)

        guard let sourceTexture = sourceTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        // Render to our output texture
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = outputTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
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

        // Present to RealityKit
        drawable.present()

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
