//
//  ImageOpenness.swift
//  Liminal
//
//  How much room a picture leaves for the archive film (docs/plans/image-api-mode.md 6, D38).
//  Film shows in the picture's shadows when at least 18% of it is darker than luma 0.3, otherwise
//  in its highlights (VideoComposite.stats), and calm areas (sky, water, road, night) give the
//  soft looks room. Pure and nonisolated: runs inside the ingest task.
//

import Foundation
import CoreGraphics

nonisolated struct OpennessScore: Codable, Sendable, Equatable {
    /// Fraction of the 48x32 cover-cropped thumbnail with luma < 0.3.
    let shadowShare: Double
    /// Fraction with luma > 0.65.
    let highlightShare: Double
    /// shadowShare when >= 0.18 (the film keys the shadows), else highlightShare.
    let keyShare: Double
    /// Fraction of a 12x8 grid of cells whose luma standard deviation is < 0.06.
    let calmShare: Double
    /// Mean absolute luma step between neighbouring thumbnail pixels.
    let edgeDensity: Double
    /// Fraction with luma > 0.85 and saturation < 0.12 (blank paper, scan margins).
    let paperShare: Double
    /// Mean HSV saturation.
    let saturation: Double
    /// 0...1 combined score; more open pictures are shown more often.
    let openness: Double
}

/// Ingest gates (image-collections.json `defaults.openness`).
nonisolated struct OpennessThresholds: Codable, Sendable, Equatable {
    var minOpenness: Double = 0.2
    var minKeyShare: Double = 0.04
    var documentPaperShare: Double = 0.5
    var documentEdgeDensity: Double = 0.06
    var maxTextCoverage: Double = 0.06
    var monochromeSaturation: Double = 0.025
    var maxFaceArea: Double = 0.015
    var maxFaces: Int = 4

    static let standard = OpennessThresholds()
}

nonisolated enum ImageOpenness {
    static let shadowLuma = 0.3          // VideoComposite.shadowLuma
    static let shadowMinShare = 0.18     // VideoComposite.shadowMinShare
    static let highlightLuma = 0.65

    static let width = 48, height = 32

    /// Scores the 3:2 cover crop of `image`.
    static func score(_ image: CGImage) -> OpennessScore {
        score(window: ImageFraming.coverCrop(image))
    }

    /// Scores `image` as given (already the window that will be shown).
    static func score(window image: CGImage) -> OpennessScore {
        guard let px = rgba(image, width: width, height: height) else {
            return OpennessScore(shadowShare: 0, highlightShare: 0, keyShare: 0, calmShare: 0, edgeDensity: 0,
                                 paperShare: 0, saturation: 0, openness: 0)
        }
        let n = width * height
        var luma = [Double](repeating: 0, count: n)
        var shadows = 0, highlights = 0, paper = 0
        var satSum = 0.0
        for i in 0..<n {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let mx = max(r, g, b), mn = min(r, g, b)
            let s = mx > 0 ? (mx - mn) / mx : 0
            luma[i] = l
            satSum += s
            if l < shadowLuma { shadows += 1 }
            if l > highlightLuma { highlights += 1 }
            if l > 0.85 && s < 0.12 { paper += 1 }
        }
        let shadowShare = Double(shadows) / Double(n)
        let highlightShare = Double(highlights) / Double(n)
        let keyShare = shadowShare >= shadowMinShare ? shadowShare : highlightShare

        // 12x8 cells of 4x4 pixels.
        var calm = 0
        for cy in 0..<8 {
            for cx in 0..<12 {
                var sum = 0.0, sq = 0.0
                for y in 0..<4 { for x in 0..<4 {
                    let v = luma[(cy * 4 + y) * width + cx * 4 + x]
                    sum += v; sq += v * v
                } }
                let mean = sum / 16
                if (sq / 16 - mean * mean).squareRoot() < 0.06 { calm += 1 }
            }
        }
        let calmShare = Double(calm) / 96

        var grad = 0.0, count = 0
        for y in 0..<height {
            for x in 0..<width {
                let v = luma[y * width + x]
                if x + 1 < width { grad += abs(luma[y * width + x + 1] - v); count += 1 }
                if y + 1 < height { grad += abs(luma[(y + 1) * width + x] - v); count += 1 }
            }
        }
        let edge = count > 0 ? grad / Double(count) : 0
        return OpennessScore(shadowShare: shadowShare, highlightShare: highlightShare, keyShare: keyShare,
                             calmShare: calmShare, edgeDensity: edge, paperShare: Double(paper) / Double(n),
                             saturation: satSum / Double(n),
                             openness: combined(keyShare: keyShare, calmShare: calmShare))
    }

    /// 0.5 x key band + 0.5 x calm. The key band is 1 for 18-60% of the frame, falls to 0 at 3% and
    /// to 0.3 when the key covers everything (night pictures: the shader's keyGain already tames them).
    static func combined(keyShare: Double, calmShare: Double) -> Double {
        let band: Double
        switch keyShare {
        case ..<0.03: band = 0
        case ..<0.18: band = (keyShare - 0.03) / 0.15
        case ...0.60: band = 1
        default: band = 1 - 0.7 * min(1, (keyShare - 0.60) / 0.40)
        }
        return min(1, max(0, 0.5 * band + 0.5 * min(calmShare / 0.35, 1)))
    }

    // MARK: - Gates

    static func isMonochrome(_ s: OpennessScore, thresholds t: OpennessThresholds = .standard) -> Bool {
        s.saturation < t.monochromeSaturation
    }

    /// Paper-heavy and busy like a page of text.
    static func looksLikeDocument(_ s: OpennessScore, thresholds t: OpennessThresholds = .standard) -> Bool {
        s.paperShare > t.documentPaperShare && s.edgeDensity > t.documentEdgeDensity
    }

    /// nil when the picture passes, else the reason it was rejected.
    static func rejection(_ s: OpennessScore, allowMonochrome: Bool,
                          thresholds t: OpennessThresholds = .standard) -> String? {
        if s.keyShare < t.minKeyShare { return "no room for the film (key \(fmt(s.keyShare)))" }
        if s.openness < t.minOpenness { return "not open enough (\(fmt(s.openness)))" }
        if looksLikeDocument(s, thresholds: t) { return "looks like a document (paper \(fmt(s.paperShare)))" }
        if !allowMonochrome && isMonochrome(s, thresholds: t) { return "monochrome (saturation \(fmt(s.saturation)))" }
        return nil
    }

    // MARK: - Window search

    /// Aspect range kept as is; the renderers' cover crop handles it.
    static let keepAspect: ClosedRange<Double> = 1.3...1.8

    /// Normalised 3:2 window (top-left origin) to cut from an image outside `keepAspect`: the most
    /// open of five offsets along the long axis. nil when the image is kept whole.
    static func bestWindow(_ image: CGImage) -> CGRect? {
        let aspect = Double(image.width) / Double(max(1, image.height))
        guard !keepAspect.contains(aspect) else { return nil }
        let centre = ImageFraming.coverCropRect(width: image.width, height: image.height)
        var best: (CGRect, Double)?
        for i in 0..<5 {
            let t = CGFloat(i) / 4
            var r = centre
            if aspect > ImageFraming.displayAspect {
                r.origin.x = (1 - r.width) * t
            } else {
                r.origin.y = (1 - r.height) * t
            }
            let s = score(window: ImageFraming.crop(image, normalized: r)).openness
            // Ties go to the centre.
            let bias = i == 2 ? 0.02 : 0
            if best == nil || s + bias > best!.1 { best = (r, s + bias) }
        }
        return best?.0
    }

    // MARK: - Pixels

    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? px : nil
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
