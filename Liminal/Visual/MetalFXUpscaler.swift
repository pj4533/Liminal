//
//  MetalFXUpscaler.swift
//  Liminal
//
//  GPU-accelerated image upscaling using Apple's MetalFX framework.
//  Designed for visionOS where CoreML competes with RealityKit for GPU.
//  MetalFX encodes into command buffers alongside other Metal work.
//
//  Supported: macOS 13+, iOS 16+, visionOS 1.0+ (DEVICE ONLY - not simulator)
//

// MetalFX is NOT available on simulator - wrap entire file
#if !targetEnvironment(simulator)

import Foundation
import Metal
import MetalFX
import CoreGraphics
import OSLog

/// Upscales images using MetalFX Spatial Scaler.
/// Unlike CoreML, MetalFX is designed to work alongside Metal rendering
/// without competing for GPU resources.
final class MetalFXUpscaler {

    // MARK: - Errors

    enum UpscalerError: LocalizedError {
        case metalNotAvailable
        case deviceNotSupported
        case scalerCreationFailed
        case textureCreationFailed
        case commandBufferFailed
        case imageConversionFailed

        var errorDescription: String? {
            switch self {
            case .metalNotAvailable: return "Metal device not available"
            case .deviceNotSupported: return "MetalFX not supported on this device"
            case .scalerCreationFailed: return "Failed to create MetalFX scaler"
            case .textureCreationFailed: return "Failed to create Metal textures"
            case .commandBufferFailed: return "Failed to create command buffer"
            case .imageConversionFailed: return "Failed to convert image"
            }
        }
    }

    // MARK: - Metal Objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var scaler: MTLFXSpatialScaler?

    // Cache textures for reuse (expensive to create)
    private var inputTexture: MTLTexture?
    private var outputTexture: MTLTexture?      // Private storage (MetalFX requirement)
    private var stagingTexture: MTLTexture?     // Shared storage (for CPU readback)
    private var currentInputSize: (width: Int, height: Int) = (0, 0)
    private var currentOutputSize: (width: Int, height: Int) = (0, 0)

    // Default 2x upscale
    private let scaleFactor: Int = 2

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            LMLog.visual.error("🔺 [MetalFX] ❌ Metal device not available")
            return nil
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            LMLog.visual.error("🔺 [MetalFX] ❌ Failed to create command queue")
            return nil
        }
        self.commandQueue = queue

        // Check MetalFX support
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            LMLog.visual.error("🔺 [MetalFX] ⚠️🚨⚠️ Device does NOT support MetalFX Spatial Scaler!")
            return nil
        }

        LMLog.visual.info("🔺 [MetalFX] ✅ Initialized - device: \(device.name)")
    }

    // MARK: - Public API

    /// Upscale a CGImage using MetalFX Spatial Scaler
    /// - Parameter cgImage: Input image
    /// - Returns: Upscaled CGImage (2x by default)
    func upscale(_ cgImage: CGImage) throws -> CGImage {
        let inputWidth = cgImage.width
        let inputHeight = cgImage.height
        let outputWidth = inputWidth * scaleFactor
        let outputHeight = inputHeight * scaleFactor

        LMLog.visual.info("🔺 [MetalFX] Upscaling \(inputWidth)x\(inputHeight) → \(outputWidth)x\(outputHeight)")
        let startTime = Date()

        // Create/update textures if needed
        try ensureTextures(inputWidth: inputWidth, inputHeight: inputHeight,
                          outputWidth: outputWidth, outputHeight: outputHeight)

        guard let inputTexture = inputTexture,
              let outputTexture = outputTexture,
              let stagingTexture = stagingTexture else {
            throw UpscalerError.textureCreationFailed
        }

        // Copy CGImage to input texture
        try copyImageToTexture(cgImage, texture: inputTexture)

        // Create/update scaler if needed
        try ensureScaler(inputWidth: inputWidth, inputHeight: inputHeight,
                        outputWidth: outputWidth, outputHeight: outputHeight)

        guard let scaler = scaler else {
            throw UpscalerError.scalerCreationFailed
        }

        // Encode upscaling
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw UpscalerError.commandBufferFailed
        }

        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)

        // Copy from private output to shared staging for CPU readback
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(from: outputTexture, to: stagingTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Check for errors
        if let error = commandBuffer.error {
            LMLog.visual.error("🔺 [MetalFX] ❌ Command buffer error: \(error.localizedDescription)")
            throw UpscalerError.commandBufferFailed
        }

        // Convert staging texture back to CGImage (staging is shared, can use getBytes)
        guard let result = textureToImage(stagingTexture) else {
            throw UpscalerError.imageConversionFailed
        }

        let elapsed = Date().timeIntervalSince(startTime)
        LMLog.visual.info("🔺 [MetalFX] ✅ Upscale complete in \(String(format: "%.2f", elapsed))s: \(result.width)x\(result.height)")

        return result
    }

    // MARK: - Private

    private func ensureTextures(inputWidth: Int, inputHeight: Int,
                                outputWidth: Int, outputHeight: Int) throws {
        // Recreate input texture if size changed
        if inputTexture == nil || currentInputSize != (inputWidth, inputHeight) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: inputWidth,
                height: inputHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw UpscalerError.textureCreationFailed
            }
            inputTexture = texture
            currentInputSize = (inputWidth, inputHeight)
            LMLog.visual.debug("🔺 [MetalFX] Created input texture: \(inputWidth)x\(inputHeight)")
        }

        // Recreate output texture if size changed
        // IMPORTANT: MetalFX requires output texture with .private storage mode!
        if outputTexture == nil || currentOutputSize != (outputWidth, outputHeight) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: outputWidth,
                height: outputHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget]
            descriptor.storageMode = .private  // MetalFX REQUIRES private storage

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw UpscalerError.textureCreationFailed
            }
            outputTexture = texture
            LMLog.visual.debug("🔺 [MetalFX] Created output texture: \(outputWidth)x\(outputHeight) (private storage)")

            // Also create staging texture for CPU readback (private → shared copy)
            let stagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: outputWidth,
                height: outputHeight,
                mipmapped: false
            )
            stagingDescriptor.usage = [.shaderRead]
            stagingDescriptor.storageMode = .shared  // For getBytes() access

            guard let staging = device.makeTexture(descriptor: stagingDescriptor) else {
                throw UpscalerError.textureCreationFailed
            }
            stagingTexture = staging
            currentOutputSize = (outputWidth, outputHeight)
            LMLog.visual.debug("🔺 [MetalFX] Created staging texture: \(outputWidth)x\(outputHeight) (shared storage)")
        }
    }

    private func ensureScaler(inputWidth: Int, inputHeight: Int,
                              outputWidth: Int, outputHeight: Int) throws {
        // Check if we need to recreate (size changed or doesn't exist)
        if scaler == nil || currentInputSize != (inputWidth, inputHeight) {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = inputWidth
            descriptor.inputHeight = inputHeight
            descriptor.outputWidth = outputWidth
            descriptor.outputHeight = outputHeight
            descriptor.colorTextureFormat = .bgra8Unorm
            descriptor.outputTextureFormat = .bgra8Unorm
            descriptor.colorProcessingMode = .perceptual

            guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
                LMLog.visual.error("🔺 [MetalFX] ❌ Failed to create scaler")
                throw UpscalerError.scalerCreationFailed
            }

            scaler = newScaler
            LMLog.visual.info("🔺 [MetalFX] Created scaler: \(inputWidth)x\(inputHeight) → \(outputWidth)x\(outputHeight)")
        }
    }

    private func copyImageToTexture(_ cgImage: CGImage, texture: MTLTexture) throws {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width

        // Create pixel buffer
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw UpscalerError.imageConversionFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )
    }

    private func textureToImage(_ texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }
}

#endif // !targetEnvironment(simulator)
