//
//  ImageMetadata.swift
//  Liminal
//
//  Per-picture metadata, stored as a JSON sidecar next to each pool picture and
//  carried through AtomicImageBuffer next to the CGImage, so the credit line and
//  the rotation read it with the picture on screen.
//

import Foundation

nonisolated struct ImageMetadata: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let mimeType: String
    /// 0...1 mean saturation (SaturationMeter), measured at ingest.
    let measuredSaturation: Double
    /// Where the picture came from (title, creator, institution, licence, links).
    var source: ImageSourceCredit? = nil
    /// How much room the picture leaves for the film (ImageOpenness), measured at ingest.
    var openness: OpennessScore? = nil
}
