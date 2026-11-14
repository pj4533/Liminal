//
//  StereoMaterialBuilder.swift
//  Liminal
//
//  Builds a ShaderGraphMaterial with GeometrySwitchCameraIndex for
//  true stereoscopic per-eye rendering on visionOS.
//  Uses ShaderGraphCoder to create the material programmatically.
//

#if os(visionOS)

import RealityKit
import ShaderGraphCoder
import Metal
import CoreGraphics
import OSLog

/// Builds and manages a stereo ShaderGraphMaterial for per-eye rendering.
@MainActor
final class StereoMaterialBuilder {

    /// The stereo material ready for use on a ModelEntity.
    private(set) var material: ShaderGraphMaterial?

    /// DrawableQueues for rendering per-eye content.
    private(set) var leftDrawableQueue: TextureResource.DrawableQueue?
    private(set) var rightDrawableQueue: TextureResource.DrawableQueue?

    /// Texture resources linked to drawable queues.
    private(set) var leftTextureResource: TextureResource?
    private(set) var rightTextureResource: TextureResource?

    /// Names of texture parameters in the shader graph.
    private let leftTextureName = "_texture0"
    private let rightTextureName = "_texture1"

    private let outputSize: Int

    init(outputSize: Int = 2048) {
        self.outputSize = outputSize
    }

    /// Build the stereo material with two drawable queues (left/right eye).
    /// Call once during setup.
    func build() async throws {
        let size = outputSize

        // Create placeholder images for initial textures
        let placeholderLeft = createPlaceholder(width: size, height: size)
        let placeholderRight = createPlaceholder(width: size, height: size)

        // Create texture resources from placeholders
        let leftResource = try await TextureResource(
            image: placeholderLeft,
            options: .init(semantic: .raw)
        )
        let rightResource = try await TextureResource(
            image: placeholderRight,
            options: .init(semantic: .raw)
        )

        // Build shader graph: left texture → camera index switch ← right texture → unlit surface
        let leftTex = SGValue.texture(leftResource)
        let rightTex = SGValue.texture(rightResource)

        // Flip V so this material samples EXACTLY like the mono UnlitMaterial fallback.
        // Measured in the simulator with -LiminalTestPattern (docs/decisions/orientation.md):
        // UnlitMaterial samples texture row (1 - v) * H, while ShaderGraph's image node samples
        // row v * H (no implicit flip). Feeding it (u, 1 - v) makes both read row (1 - v) * H:
        // mesh v = 1 (dome top) → row 0 → image top. Removing this flip turns stereo upside down.
        let rawUV = SGValue.uv0
        let flippedUV = SGValue.vector2f(rawUV.x, SGValue.float(1.0) - rawUV.y)

        let leftColor = leftTex.sampleColor3f(texcoord: flippedUV)
        let rightColor = rightTex.sampleColor3f(texcoord: flippedUV)

        let perEyeColor = geometrySwitchCameraIndex(
            mono: leftColor,
            left: leftColor,
            right: rightColor
        )

        let surface = unlitSurface(
            color: perEyeColor,
            applyPostProcessToneMap: false
        )

        let sgMaterial = try await ShaderGraphMaterial(surface: surface)

        // Create drawable queues
        let descriptor = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: size,
            height: size,
            usage: [.renderTarget, .shaderRead],  // no .shaderWrite: allows lossless compression
            mipmapsMode: .none
        )

        let leftQueue = try TextureResource.DrawableQueue(descriptor)
        leftQueue.allowsNextDrawableTimeout = true
        let rightQueue = try TextureResource.DrawableQueue(descriptor)
        rightQueue.allowsNextDrawableTimeout = true

        // Replace texture resources with drawable queues
        leftResource.replace(withDrawables: leftQueue)
        rightResource.replace(withDrawables: rightQueue)

        self.material = sgMaterial
        self.leftDrawableQueue = leftQueue
        self.rightDrawableQueue = rightQueue
        self.leftTextureResource = leftResource
        self.rightTextureResource = rightResource

        LMLog.visual.info("✅ StereoMaterialBuilder: Built stereo material \(size)x\(size)")
    }

    private func createPlaceholder(width: Int, height: Int) -> CGImage {
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

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()!
    }
}

#endif
