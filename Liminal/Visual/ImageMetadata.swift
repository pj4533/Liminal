//
//  ImageMetadata.swift
//  Liminal
//
//  Per-image metadata, stored as a JSON sidecar next to each cached image and
//  carried through AtomicImageBuffer next to the CGImage (docs/decisions/images.md D12).
//  A later consumer (audio, UI) reads imageBuffer.loadCurrentMetadata() when the
//  generation counter changes. RGB is defined in Prompt/PromptTypes.swift.
//

import Foundation

nonisolated struct ImageMetadata: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    /// Style id, palette id, moods, energy, warmth, series, prompt text, prompt version.
    let spec: PromptSpec
    let model: String
    let pixelWidth: Int
    let pixelHeight: Int
    let mimeType: String
    /// Measured from the pixels, 5 colors, most coverage first (the model does not always follow the palette).
    let dominantColors: [RGB]
    /// 0...1 mean luma.
    let measuredBrightness: Double
    /// 0...1 mean saturation.
    let measuredSaturation: Double
    /// Set when a real film frame served as the subject reference.
    var archiveReference: ArchiveReference? = nil

    nonisolated struct ArchiveReference: Codable, Sendable, Equatable {
        let clipID: String
        let sourceTime: Double
        let width: Int
        let height: Int
        let prompt: String
        var plannedStart: Double? = nil
        var cachedSince: Date? = nil
    }
}
