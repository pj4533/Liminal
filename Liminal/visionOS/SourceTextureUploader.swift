//
//  SourceTextureUploader.swift
//  Liminal
//
//  Builds a source-image texture OFF the main actor (docs/decisions/performance.md, image-change
//  hitch). Decoding + downsampling a generated JPEG into 2048² BGRA takes 40-90 ms; on the
//  @MainActor render loop that was one long frame at every image change.
//
//  Every image gets its OWN new texture (never an in-place overwrite), so a texture that an
//  in-flight command buffer is still sampling is never touched; the renderer just swaps
//  references. Metal command buffers retain the textures they use.
//
//  Orientation: CGBitmapContext memory is top row first, so the image is drawn UNFLIPPED and
//  texture row 0 = image top (docs/decisions/orientation.md, ImageFraming.swift).
//

#if os(visionOS)

import Foundation
import Metal
import CoreGraphics

nonisolated final class SourceTextureUploader: @unchecked Sendable {
    // MTLDevice / MTLCommandQueue are thread-safe; this class holds no mutable state.
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    let size: Int

    init(device: MTLDevice, commandQueue: MTLCommandQueue, size: Int) {
        self.device = device
        self.commandQueue = commandQueue
        self.size = size
    }

    /// A new `size`² bgra8Unorm (sRGB-encoded bytes, sampled raw like before) shared texture holding
    /// `cgImage` stretched to the square (the image is pre-cropped to 3:2; the dome stretches it
    /// back). Safe to call from any thread.
    func makeTexture(from cgImage: CGImage, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        texture.label = label

        let bytesPerRow = 4 * size
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * size, alignment: 16)
        defer { pixels.deallocate() }
        guard let context = CGContext(
            data: pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue  // BGRA
        ) else { return nil }
        context.interpolationQuality = .high
        // NO flip (see header).
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bytesPerRow)

        // Lossless re-layout for faster sampling. Committed before the texture is handed to the
        // render loop, so every render command buffer that uses it is committed after this one on
        // the same (in-order) queue.
        optimize(texture, label: label)
        return texture
    }

    /// Build a fresh R8 texture so the CPU never overwrites depth in use by an older frame.
    func makeDepthTexture(from image: CGImage) -> MTLTexture? {
        let width = image.width, height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: context.bytesPerRow)
        optimize(texture, label: "depth")
        return texture
    }

    private func optimize(_ texture: MTLTexture, label: String) {
        if let commandBuffer = commandQueue.makeCommandBuffer(),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            commandBuffer.label = "Optimize \(label) texture"
            blit.optimizeContentsForGPUAccess(texture: texture)
            blit.endEncoding()
            commandBuffer.commit()
        }
    }
}

#endif
