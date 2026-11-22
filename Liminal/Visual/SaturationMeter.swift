//
//  SaturationMeter.swift
//  Liminal
//
//  Measures how colourful a picture is: draws it into 48x32 RGBA and returns the mean
//  HSV saturation of the pixels. CoreGraphics only, under 1 ms. The feed stores the value
//  in each picture's sidecar (the pool's monochrome fallback reads it).
//

import Foundation
import CoreGraphics

nonisolated enum SaturationMeter {

    /// 0...1 mean saturation, (max - min) / max per pixel; 0 when the picture cannot be drawn.
    static func meanSaturation(_ image: CGImage) -> Double {
        let width = 48, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }

        var saturationTotal = 0.0
        let n = width * height
        for i in 0..<n {
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            saturationTotal += maxC > 0 ? (maxC - minC) / maxC : 0
        }
        return saturationTotal / Double(n)
    }
}
