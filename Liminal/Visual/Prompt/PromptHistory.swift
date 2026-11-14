//
//  PromptHistory.swift
//  Liminal
//
//  Recent choices per axis, used for the recency penalty, plus the series
//  in progress. Codable so PromptDirector can persist it across launches.
//

import Foundation

nonisolated struct ActiveSeries: Codable, Sendable, Equatable {
    let id: UUID
    let kind: SeriesKind
    let length: Int
    /// Index the next image in this series will get.
    var nextIndex: Int

    // Held values (set from the first image of the series).
    var styleID: String?
    var subjectID: String?
    var paletteID: String?
    var category: SubjectCategory?
    var materialID: String?

    // Values already used inside the series; varying axes must avoid them.
    var usedStyles: [String] = []
    var usedPalettes: [String] = []
    var usedSubjects: [String] = []
    var usedKinds: [TransformationKind] = []

    var isFinished: Bool { nextIndex >= length }
}

nonisolated struct PromptHistory: Codable, Sendable, Equatable {
    static let styleDepth = 6
    static let paletteDepth = 6
    static let subjectDepth = 40
    static let categoryDepth = 3
    static let kindDepth = 4
    static let compositionDepth = 2

    // Most recent last.
    var styles: [String] = []
    var palettes: [String] = []
    var subjects: [String] = []
    var categories: [SubjectCategory] = []
    var transformationKinds: [TransformationKind] = []
    var compositions: [String] = []
    var activeSeries: ActiveSeries?

    init() {}

    mutating func record(_ spec: PromptSpec) {
        Self.push(&styles, spec.styleID, Self.styleDepth)
        Self.push(&palettes, spec.paletteID, Self.paletteDepth)
        Self.push(&subjects, spec.subjectID, Self.subjectDepth)
        Self.push(&categories, spec.subjectCategory, Self.categoryDepth)
        Self.push(&transformationKinds, spec.transformationKind, Self.kindDepth)
        Self.push(&compositions, spec.compositionID, Self.compositionDepth)
    }

    private static func push<T>(_ list: inout [T], _ value: T, _ depth: Int) {
        list.append(value)
        if list.count > depth { list.removeFirst(list.count - depth) }
    }

    /// Position counted from the most recent (0 = previous image), or nil if absent.
    static func distance<T: Equatable>(of value: T, in list: [T]) -> Int? {
        guard let index = list.lastIndex(of: value) else { return nil }
        return list.count - 1 - index
    }
}
