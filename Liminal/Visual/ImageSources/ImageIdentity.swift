//
//  ImageIdentity.swift
//  Liminal
//
//  The same picture can reach API mode under more than one id (decision D48): Commons holds copies of
//  Library of Congress scans (titles end in "LCCN<n>"), of NASA frames ("AS08-14-2383") and of
//  DOCUMERICA prints uploaded twice ("... - NARA - 544071"), and two museums can hold the same print.
//  Two checks keep one copy:
//  - aliases, before any download: catalogue numbers read from the provider id and the title;
//  - a perceptual fingerprint of the stored picture, after decode, against every picture in the pool.
//

import Foundation
import CoreGraphics
import ImageIO

nonisolated enum ImageIdentity {

    /// Catalogue numbers that name the same picture across providers. Each starts with "~", so an alias
    /// never collides with a candidate key ("provider:itemID").
    static func aliases(of c: ImageCandidate) -> Set<String> {
        aliases(providerID: c.providerID, itemID: c.itemID)
    }

    static func aliases(providerID: String, itemID: String) -> Set<String> {
        var out = Set<String>()
        switch providerID {
        case "loc":
            // LoC item ids are LCCNs ("2017657809"); Commons copies carry them as "LCCN2017657809".
            if itemID.range(of: #"^\d{8,12}$"#, options: .regularExpression) != nil { out.insert("~lccn:\(itemID)") }
        case "nasa":
            out.insert("~nasa:\(itemID.uppercased())")
            out.formUnion(nasaFrames(in: itemID))
        case "wikimedia":
            var title = itemID.replacingOccurrences(of: "_", with: " ")
            if title.hasPrefix("File:") { title.removeFirst(5) }
            out.insert("~commons:\(title.lowercased())")
            if let n = firstMatch(#"LCCN\s?(\d{8,12})"#, in: title) { out.insert("~lccn:\(n)") }
            if let n = firstMatch(#"NARA\s*-\s*(\d{5,9})"#, in: title) { out.insert("~nara:\(n)") }
            out.formUnion(nasaFrames(in: title))
        default:
            break
        }
        return out
    }

    /// NASA frame and catalogue numbers: Apollo/Gemini/Shuttle frames, Skylab, ISS, PIA and GPN ids.
    static func nasaFrames(in text: String) -> Set<String> {
        let pattern = #"(?i)(?<![A-Z0-9])(AS\d{1,2}-\d{1,3}-\d{3,6}|S\d{2,3}-[A-Z0-9]{1,5}-\d{3,6}|S\d{2,3}-\d{4,6}|SL\d-\d{1,3}-\d{3,6}|ISS\d{3}-E-\d{3,7}|PIA\d{5}|GPN-\d{4}-\d{6})(?![0-9])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(re.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { "~nasa:\(text[$0].uppercased())" }
        })
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// True when the candidate's key or one of its aliases is already in `known` (keys and aliases).
    static func isKnown(_ c: ImageCandidate, in known: Set<String>) -> Bool {
        known.contains(c.key) || aliases(of: c).contains { known.contains($0) }
    }
}

/// A 64+64-bit difference hash (rows and columns of a 9x9 grey thumbnail) and a 3x3 colour thumbnail.
/// Two copies of a picture (another scan, another size, another JPEG) stay within a few bits and a
/// few colour levels; unrelated pictures differ in about half the bits, and the colour check keeps
/// two different pictures with the same layout (a bright object centred on black) apart. Computed on
/// the stored 3:2 picture: the same pixels at ingest and when backfilling an older pool from its JPEGs.
nonisolated struct ImageFingerprint: Codable, Sendable, Hashable {
    var rows: UInt64
    var columns: UInt64
    /// 3x3 cells, RGB, row-major (27 values).
    var colors: [UInt8]

    /// Bits that may differ in each hash for two pictures to count as one.
    static let maxBitDistance = 8
    /// Mean absolute difference of the colour cells, in 8-bit levels.
    static let maxColorDistance = 24.0

    func matches(_ other: ImageFingerprint) -> Bool {
        guard (rows ^ other.rows).nonzeroBitCount <= Self.maxBitDistance,
              (columns ^ other.columns).nonzeroBitCount <= Self.maxBitDistance,
              colors.count == other.colors.count, !colors.isEmpty else { return false }
        let total = zip(colors, other.colors).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(colors.count) <= Self.maxColorDistance
    }

    /// Box averages of one 72x72 draw (so every source pixel counts): 9x9 grey for the hashes, 3x3 colour.
    static func of(_ image: CGImage) -> ImageFingerprint? {
        let side = 72, cells = 9, block = side / cells, colorBlock = side / 3
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var grid = [Double](repeating: 0, count: cells * cells)
        var color = [Double](repeating: 0, count: 27)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
                grid[(y / block) * cells + x / block] += 0.299 * r + 0.587 * g + 0.114 * b
                let c = ((y / colorBlock) * 3 + x / colorBlock) * 3
                color[c] += r; color[c + 1] += g; color[c + 2] += b
            }
        }
        grid = grid.map { $0 / Double(block * block) }
        var rows: UInt64 = 0, columns: UInt64 = 0, bit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if grid[y * cells + x] < grid[y * cells + x + 1] { rows |= 1 << bit }
                if grid[y * cells + x] < grid[(y + 1) * cells + x] { columns |= 1 << bit }
                bit += 1
            }
        }
        let colors = color.map { UInt8(max(0, min(255, ($0 / Double(colorBlock * colorBlock)).rounded()))) }
        return ImageFingerprint(rows: rows, columns: columns, colors: colors)
    }

    /// From a stored JPEG, decoded small (the JPEG decoder scales while it decodes).
    static func of(fileAt url: URL) -> ImageFingerprint? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 288,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return of(thumb)
    }
}
