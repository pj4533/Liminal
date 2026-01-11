//
//  PlatformImage.swift
//  Liminal
//
//  Platform abstraction for image types to support macOS and visionOS.
//

import Foundation
import CoreGraphics
import CoreImage

#if os(macOS)
import AppKit

/// Platform-native image type
public typealias PlatformImage = NSImage

extension NSImage {
    /// Get CGImage representation
    public var cgImageRepresentation: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Create NSImage from CGImage
    public convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Create NSImage from Data
    public static func from(data: Data) -> NSImage? {
        NSImage(data: data)
    }

    /// Create NSImage from file URL
    public static func from(url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    /// Get PNG data representation
    public var pngData: Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }

    /// Get image dimensions
    public var pixelSize: CGSize {
        size
    }
}

#else
import UIKit

/// Platform-native image type
public typealias PlatformImage = UIImage

extension UIImage {
    /// Get CGImage representation
    public var cgImageRepresentation: CGImage? {
        cgImage
    }

    /// Create UIImage from CGImage (matches NSImage signature)
    public convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage)
    }

    /// Create UIImage from Data
    public static func from(data: Data) -> UIImage? {
        UIImage(data: data)
    }

    /// Create UIImage from file URL
    public static func from(url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Get PNG data representation
    public var pngData: Data? {
        pngData()
    }

    /// Get image dimensions
    public var pixelSize: CGSize {
        size
    }
}

#endif

// MARK: - Cross-platform helpers

/// Resize a CGImage to target size using Core Graphics (works on all platforms)
/// This is nonisolated to allow use from any actor context.
public nonisolated func resizeCGImage(_ cgImage: CGImage, to targetSize: CGSize) -> CGImage? {
    let context = CGContext(
        data: nil,
        width: Int(targetSize.width),
        height: Int(targetSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )

    context?.interpolationQuality = .high
    context?.draw(cgImage, in: CGRect(origin: .zero, size: targetSize))

    return context?.makeImage()
}

/// Resize an image to target size using Core Graphics (works on all platforms)
@MainActor
public func resizeImage(_ image: PlatformImage, to targetSize: CGSize) -> PlatformImage? {
    guard let cgImage = image.cgImageRepresentation else { return nil }
    guard let resizedCGImage = resizeCGImage(cgImage, to: targetSize) else { return nil }
    return PlatformImage(cgImage: resizedCGImage)
}
