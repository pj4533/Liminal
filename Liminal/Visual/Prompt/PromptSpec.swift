//
//  PromptSpec.swift
//  Liminal
//
//  Everything that went into one prompt. Stored in each image's metadata
//  sidecar so later consumers (audio, UI) can read style, palette and mood.
//

import Foundation

nonisolated struct PromptSpec: Sendable, Codable, Equatable {
    let text: String
    let styleID: String
    let styleFamily: StyleFamily
    let paletteID: String
    let paletteSwatches: [RGB]
    let subjectID: String
    let subjectCategory: SubjectCategory
    let secondSubjectID: String?
    let transformationID: String
    let transformationKind: TransformationKind
    /// Material slot value, when the transformation uses one (held by materialThread series).
    let materialID: String?
    let compositionID: String
    let moods: [Mood]                      // 2 to 4, from a fixed vocabulary
    let energy: Double                     // 0 calm ... 1 intense
    let warmth: Double                     // -1 cool ... +1 warm
    let needsStrongSurreal: Bool
    let series: SeriesInfo?
    let promptVersion: Int

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
}
