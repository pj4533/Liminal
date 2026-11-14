//
//  PromptTypes.swift
//  Liminal
//
//  Value types for the prompt grammar:
//  style x subject x transformation x palette x composition.
//  Foundation only (see SeededRNG.swift).
//

import Foundation

// MARK: - Shared vocabularies

nonisolated enum Mood: String, Codable, CaseIterable, Sendable {
    case serene, eerie, euphoric, ominous, playful, majestic, intimate, electric, melancholy, lush
}

nonisolated enum StyleFamily: String, Codable, CaseIterable, Sendable {
    case photographic, abstract
}

nonisolated enum SubjectCategory: String, CaseIterable, Codable, Sendable {
    case creature, plant, architecture, object, vehicle, landscape, food, instrument, celestial
}

nonisolated enum SubjectScale: String, CaseIterable, Codable, Sendable {
    case tiny, handheld, humanSized, monumental, landscape
}

nonisolated enum TransformationKind: String, CaseIterable, Codable, Sendable {
    case material, scale, displacement, hybrid, container, multiplicity,
         stateChange, gravity, overgrowth, reflection, luminous, plain
}

/// A color in 0...1 sRGB. Lives in Prompt/ (not ImageMetadata.swift) because
/// PromptSpec carries palette swatches and Prompt/ must compile standalone.
nonisolated struct RGB: Codable, Sendable, Equatable, Hashable {
    let r: Double
    let g: Double
    let b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// From 0xRRGGBB.
    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
}

// MARK: - Library entries

nonisolated struct Subject: Sendable, Equatable {
    let id: String
    let phrase: String          // "a grand piano"
    let plural: String          // "grand pianos"
    let category: SubjectCategory
    let scale: SubjectScale
    let textProne: Bool         // adds "all surfaces blank and unmarked"

    /// Bare noun without its article ("grand piano"), for templates like "a giant glass {S}".
    var noun: String {
        for article in ["a ", "an ", "the "] where phrase.hasPrefix(article) {
            return String(phrase.dropFirst(article.count))
        }
        return phrase
    }
}

nonisolated enum PaletteRule: Sendable, Equatable {
    case any
    case anyExcept([String])
    case only([String])
    case darkOnly
}

nonisolated struct Style: Sendable {
    let id: String
    let family: StyleFamily
    let weight: Double
    let lead: String
    let camera: String
    let lighting: String
    let texture: String
    /// nil = every category.
    let categories: [SubjectCategory]?
    /// nil = every scale.
    let scales: [SubjectScale]?
    /// Transformation ids that make a subject acceptable even when its scale is not
    /// (macro accepts any subject as "a miniature X resting on a single leaf").
    let scaleOverrides: [String]
    /// Transformation ids this style never uses (they fight the look).
    let excludedTransformations: [String]
    /// nil = every kind.
    let kinds: [TransformationKind]?
    let paletteRule: PaletteRule
    /// nil = every composition.
    let compositions: [String]?
    let moods: [Mood]
    let energy: Double
    /// Abstract styles bring their own subjects instead of the shared library.
    let ownSubjects: [Subject]?

    init(id: String, family: StyleFamily = .photographic, weight: Double, lead: String, camera: String,
         lighting: String, texture: String, categories: [SubjectCategory]? = nil, scales: [SubjectScale]? = nil,
         scaleOverrides: [String] = [], excludedTransformations: [String] = [], kinds: [TransformationKind]? = nil,
         paletteRule: PaletteRule = .anyExcept(["aerochrome"]), compositions: [String]? = nil,
         moods: [Mood], energy: Double, ownSubjects: [Subject]? = nil) {
        self.id = id; self.family = family; self.weight = weight; self.lead = lead; self.camera = camera
        self.lighting = lighting; self.texture = texture; self.categories = categories; self.scales = scales
        self.scaleOverrides = scaleOverrides; self.excludedTransformations = excludedTransformations; self.kinds = kinds; self.paletteRule = paletteRule
        self.compositions = compositions; self.moods = moods; self.energy = energy; self.ownSubjects = ownSubjects
    }
}

nonisolated struct Transformation: Sendable {
    let id: String
    let kind: TransformationKind
    /// Slots: {S} subject phrase, {Sn} bare noun, {Sp} plural, {S2} second subject,
    /// {S2p} its plural, {M} material, {E} environment, {G} growth, {B} burst.
    let template: String
    let weight: Double
    let needsStrongSurreal: Bool
    let moods: [Mood]
    /// Categories that cannot take this transformation.
    let excludedCategories: [SubjectCategory]
    /// nil = every scale.
    let scales: [SubjectScale]?
    /// Categories allowed for {S2}; nil = any category other than the subject's.
    let secondCategories: [SubjectCategory]?
    /// Used only by styles with their own subject lists (the subject is already a full scene).
    let forOwnSubjects: Bool

    init(id: String, kind: TransformationKind, template: String, weight: Double = 1, needsStrongSurreal: Bool = false,
         moods: [Mood], excludedCategories: [SubjectCategory] = [], scales: [SubjectScale]? = nil,
         secondCategories: [SubjectCategory]? = nil, forOwnSubjects: Bool = false) {
        self.id = id; self.kind = kind; self.template = template; self.weight = weight
        self.needsStrongSurreal = needsStrongSurreal; self.moods = moods
        self.excludedCategories = excludedCategories; self.scales = scales; self.secondCategories = secondCategories
        self.forOwnSubjects = forOwnSubjects
    }

    var usesSecondSubject: Bool { template.contains("{S2") }
    var usesMaterial: Bool { template.contains("{M}") || template.contains("{MS}") }
}

nonisolated struct Palette: Sendable {
    let id: String
    let words: [String]        // explicit color words that go into the prompt
    let accent: String?
    let swatches: [RGB]        // intended colors, for metadata
    let isDark: Bool           // works on a near-black scene
    let warmth: Double         // -1 cool ... +1 warm
    let energy: Double         // 0 calm ... 1 intense
    let moods: [Mood]
    let weight: Double
    /// Replaces the generated clause when the palette does not fit "w1, w2 and w3 with X accents".
    let customClause: String?

    init(id: String, words: [String], accent: String?, swatches: [RGB], isDark: Bool, warmth: Double,
         energy: Double, moods: [Mood], weight: Double = 1, customClause: String? = nil) {
        self.id = id; self.words = words; self.accent = accent; self.swatches = swatches; self.isDark = isDark
        self.warmth = warmth; self.energy = energy; self.moods = moods; self.weight = weight
        self.customClause = customClause
    }

    var clause: String {
        if let customClause { return customClause }
        let list: String
        switch words.count {
        case 0: list = ""
        case 1: list = words[0]
        default: list = words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
        if let accent {
            return "Color palette: \(list) with \(accent) accents, vivid and clearly separated."
        }
        return "Color palette: \(list), vivid and clearly separated."
    }
}

nonisolated struct Composition: Sendable {
    let id: String
    let fragment: String
    let weight: Double
}

// MARK: - Series

nonisolated enum SeriesKind: String, Codable, CaseIterable, Sendable {
    case subjectStudy, paletteRun, styleSet, materialThread
}

nonisolated struct SeriesInfo: Codable, Sendable, Equatable {
    let id: UUID
    let kind: SeriesKind
    let index: Int      // 0-based position of this image in the series
    let length: Int
}
