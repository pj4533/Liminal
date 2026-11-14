//
//  DominantColorExtractor.swift
//  Liminal
//
//  Measures what the image actually looks like: draws it into 48x32 RGBA,
//  buckets pixels into a 4x4x4 RGB histogram and returns the mean color of the
//  5 fullest buckets, plus mean luma and saturation. CoreGraphics only, under 1 ms.
//

import Foundation
import CoreGraphics

nonisolated enum DominantColorExtractor {

    static func analyze(_ image: CGImage) -> (colors: [RGB], brightness: Double, saturation: Double) {
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
        guard drawn else { return ([], 0, 0) }

        var counts = [Int](repeating: 0, count: 64)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: 64)
        var lumaTotal = 0.0, saturationTotal = 0.0
        let n = width * height
        for i in 0..<n {
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            let bucket = min(3, Int(r * 4)) * 16 + min(3, Int(g * 4)) * 4 + min(3, Int(b * 4))
            counts[bucket] += 1
            sums[bucket].0 += r; sums[bucket].1 += g; sums[bucket].2 += b
            lumaTotal += 0.2126 * r + 0.7152 * g + 0.0722 * b
            let maxC = max(r, g, b), minC = min(r, g, b)
            saturationTotal += maxC > 0 ? (maxC - minC) / maxC : 0
        }
        let top = (0..<64).filter { counts[$0] > 0 }
            .sorted { counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1 }
            .prefix(5)
        let colors = top.map { index -> RGB in
            let c = Double(counts[index])
            return RGB(r: sums[index].0 / c, g: sums[index].1 / c, b: sums[index].2 / c)
        }
        return (colors, lumaTotal / Double(n), saturationTotal / Double(n))
    }
}
