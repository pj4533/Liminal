//
//  ImageFraming.swift
//  Liminal
//
//  Orientation + aspect convention shared by every display path
//  (docs/decisions/orientation.md).
//
//  ORIENTATION: everywhere in the pipeline, texture row 0 / texCoord.y = 0 is the TOP of the image.
//    - Upload: CGBitmapContext memory is already top-row-first, so images are drawn UNFLIPPED into
//      the staging buffer (OffscreenEffectsRenderer) or loaded with MTKTextureLoader (macOS,
//      top-left origin).
//    - Effects pass (effectsVertex): drawable row r samples texture row r (identity).
//    - visionOS dome: mesh UV v = 1 at the top (USD convention); both the mono UnlitMaterial and
//      the stereo ShaderGraph material sample drawable row 0 at v = 1 (see StereoMaterialBuilder).
//
//  ASPECT: sources are centre-cropped to the 16:9 display aspect before upload. The square
//  visionOS render target stores that picture anisotropically; the shell and movie restore
//  its proportions. The collection pipeline retains its original 3:2 selection window.
//  This file has no app dependencies (also compiled into tools/VibranceHarness).
//

import CoreGraphics

nonisolated enum ImageFraming {

    static let displayAspectWidth = 16
    static let displayAspectHeight = 9
    static let displayAspect = CGFloat(displayAspectWidth) / CGFloat(displayAspectHeight)
    static let collectionAspect: CGFloat = 3.0 / 2.0

    /// Normalized (0-1, top-left origin) crop rect that centre-crops an image of `width` x `height`
    /// to `aspect` ("cover"). Identity when the image already matches within 0.5%.
    static func coverCropRect(width: Int, height: Int, aspect: CGFloat = displayAspect) -> CGRect {
        guard width > 0, height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = CGFloat(width) / CGFloat(height)
        if abs(imageAspect / aspect - 1) < 0.005 { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if imageAspect > aspect {
            let w = aspect / imageAspect          // too wide: crop left/right
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = imageAspect / aspect          // too tall: crop top/bottom
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }

    /// Centre-crop `image` to `aspect`. `CGImage.cropping(to:)` references the original pixels
    /// (no copy); returns the original image when no crop is needed.
    static func coverCrop(_ image: CGImage, aspect: CGFloat = displayAspect) -> CGImage {
        crop(image, normalized: coverCropRect(width: image.width, height: image.height, aspect: aspect))
    }

    /// Crop `image` to a normalized (0-1, top-left origin) rect — e.g. apply a colour image's
    /// cover-crop to its saliency/depth map, which may have a different pixel size.
    static func crop(_ image: CGImage, normalized r: CGRect) -> CGImage {
        if r.width >= 1 && r.height >= 1 { return image }
        // CGImage pixel space is top-left origin, same as our normalized rect.
        let px = CGRect(
            x: (r.minX * CGFloat(image.width)).rounded(),
            y: (r.minY * CGFloat(image.height)).rounded(),
            width: (r.width * CGFloat(image.width)).rounded(),
            height: (r.height * CGFloat(image.height)).rounded()
        )
        return image.cropping(to: px) ?? image
    }
}
