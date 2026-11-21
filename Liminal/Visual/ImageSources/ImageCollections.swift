//
//  ImageCollections.swift
//  Liminal
//
//  The approved sources API mode rotates through: bundled image-collections.json
//  (docs/research/image-apis/collections.md, docs/plans/image-api-mode.md 3.2).
//

import Foundation
import OSLog

nonisolated struct ImageCollections: Codable, Sendable {
    let version: Int
    let defaults: Defaults
    let providers: [String: ProviderInfo]
    let licenseAllowlist: [String]
    let sources: [CuratedSource]

    nonisolated struct Defaults: Codable, Sendable, Equatable {
        let minLongSide: Int
        let minShortSide: Int
        /// Long side requested from providers that scale on the server, and the decode cap.
        let targetLongSide: Int
        let maxBytes: Int
        let allowedMime: [String]
        let userAgent: String
        /// Pool size past which the least recently shown picture is removed (3 GB, D39).
        let storeBudgetBytes: Int64
        /// Ingest pauses while the volume has less free space than this.
        let minFreeBytes: Int64
        /// Ingest runs while fewer never-shown pictures than this wait in the pool.
        let unseenAhead: Int
        /// Seconds between downloads, on top of the per-host gaps.
        let ingestInterval: Double
        /// Pictures shown since, below which a picture is not shown again.
        let recencyWindow: Int
        /// At most one monochrome picture in this many.
        let monochromeEvery: Int
        /// Cached search pages are refetched after this many days.
        let candidateRefreshDays: Double
        let hostGaps: [String: Double]
        let defaultHostGap: Double
        let openness: OpennessThresholds
    }

    nonisolated struct ProviderInfo: Codable, Sendable, Equatable {
        let name: String
        let institution: String
    }

    /// The bundled list, loaded once. Falls back to an empty list (API mode then shows standby art).
    static let bundled: ImageCollections = {
        guard let url = Bundle.main.url(forResource: "image-collections", withExtension: "json") else {
            LMLog.visual.error("🖼️ [API] image-collections.json missing from the bundle")
            return .empty
        }
        do {
            return try load(Data(contentsOf: url))
        } catch {
            LMLog.visual.error("🖼️ [API] image-collections.json failed to decode: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }()

    static func load(_ data: Data) throws -> ImageCollections {
        try JSONDecoder().decode(ImageCollections.self, from: data)
    }

    static let empty = ImageCollections(
        version: 0,
        defaults: Defaults(minLongSide: 2048, minShortSide: 1365, targetLongSide: 2528, maxBytes: 12_000_000,
                           allowedMime: ["image/jpeg", "image/png"], userAgent: "Liminal/1.0",
                           storeBudgetBytes: 3_000_000_000, minFreeBytes: 1_000_000_000, unseenAhead: 12,
                           ingestInterval: 4, recencyWindow: 24, monochromeEvery: 6, candidateRefreshDays: 7,
                           hostGaps: [:], defaultHostGap: 1, openness: .standard),
        providers: [:], licenseAllowlist: [], sources: [])

    func institution(provider: String) -> String {
        providers[provider]?.institution ?? provider
    }

    /// Enabled sources whose provider is registered, optionally restricted by -LiminalImageProvider
    /// (provider or source ids).
    func activeSources(providers available: Set<String>, filter: [String]?) -> [CuratedSource] {
        sources.filter { source in
            guard source.enabled, source.weight > 0, available.contains(source.provider) else { return false }
            guard let filter else { return true }
            return filter.contains(source.id) || filter.contains(source.provider)
        }
    }

    func source(id: String) -> CuratedSource? { sources.first { $0.id == id } }
}

// MARK: - Sources

nonisolated struct CuratedSource: Codable, Sendable, Equatable {
    let id: String
    let provider: String
    let enabled: Bool
    let weight: Double
    let themes: [String]
    var collection: String?
    var queries: [CuratedQuery]?
    var searches: [String]?
    var categories: [String]?
    var pinned: [FlexibleID]?
    var rejectTitleWords: [String]?
    var requireTitleContains: String?
    var requireIIIF: Bool?
    /// LoC: when a result has no IIIF derivative, use the IIIF service of its scanned master (FSA/OWI
    /// colour, photochroms), derived from the 1024 px JPEG url. `LOCProvider.masterIIIF`.
    var useMasters: Bool?
    /// Trim the film rebate of scanned slides (`ScanEdgeTrimmer`) before the border and openness checks.
    var trimScanEdges: Bool?
    /// Share of each side cut after the trim (Prokudin-Gorskii's coloured plate-misregistration bands,
    /// which are not dark enough for `ScanEdgeTrimmer`).
    var edgeInset: Double?
    /// LoC: search `/photos/` with the `partof:` facet instead of `/collections/<collection>/`
    /// (collections that only exist as a facet: Margolies Roadside America, Matson).
    var partof: String?
    var requiresKey: String?
    var allowClassification: [String]?
    var allowMonochrome: Bool?
    let mood: SourceMood
    let license: String

    var pinnedIDs: [String] { (pinned ?? []).map(\.value) }

    /// Every search this source can page through, in JSON order.
    var allQueries: [SourceQuery] {
        (queries ?? []).map { .search($0) }
            + (searches ?? []).map { .search(CuratedQuery(q: $0)) }
            + (categories ?? []).map { .category($0) }
    }

    /// True when the title contains a reject word (case-insensitive), or neither the title nor the
    /// provider's item id (a Commons file name such as "File:SUNSET - NARA - 544071.jpg") contains the
    /// required phrase.
    func rejectsTitle(_ title: String, itemID: String = "") -> Bool {
        let lower = title.lowercased()
        if let required = requireTitleContains?.lowercased(),
           !lower.contains(required), !itemID.lowercased().contains(required) { return true }
        return (rejectTitleWords ?? []).contains { word in
            let w = word.lowercased()
            // Whole words only, so "man" does not reject "Manhattan".
            return lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b", options: .regularExpression) != nil
        }
    }

    /// The synthesized prompt spec VisualMoodBuilder reads (moods, category, energy, warmth).
    var promptSpec: PromptSpec {
        PromptSpec(text: "Curated picture from \(id)", styleID: "api.\(id)", styleFamily: .photographic,
                   paletteID: "api", paletteSwatches: [], subjectID: "api.\(id)",
                   subjectCategory: mood.subjectCategory, secondSubjectID: nil, transformationID: "none",
                   transformationKind: .plain, materialID: nil, compositionID: "api", moods: mood.moods,
                   energy: mood.energy, warmth: mood.warmth, needsStrongSurreal: false, series: nil,
                   promptVersion: 0)
    }
}

nonisolated struct SourceMood: Codable, Sendable, Equatable {
    let moods: [Mood]
    let subjectCategory: SubjectCategory
    let energy: Double
    let warmth: Double
}

/// A search: a plain string, or an object with a year window (NASA), type (Cleveland) or
/// department (the Met).
nonisolated struct CuratedQuery: Codable, Sendable, Equatable {
    let q: String
    var yearStart: Int?
    var yearEnd: Int?
    var type: String?
    var departmentId: Int?

    init(q: String, yearStart: Int? = nil, yearEnd: Int? = nil, type: String? = nil, departmentId: Int? = nil) {
        self.q = q; self.yearStart = yearStart; self.yearEnd = yearEnd; self.type = type; self.departmentId = departmentId
    }

    private enum CodingKeys: String, CodingKey { case q, yearStart, yearEnd, type, departmentId }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(q: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(q: try c.decode(String.self, forKey: .q),
                  yearStart: try c.decodeIfPresent(Int.self, forKey: .yearStart),
                  yearEnd: try c.decodeIfPresent(Int.self, forKey: .yearEnd),
                  type: try c.decodeIfPresent(String.self, forKey: .type),
                  departmentId: try c.decodeIfPresent(Int.self, forKey: .departmentId))
    }
}

nonisolated enum SourceQuery: Sendable, Equatable {
    case search(CuratedQuery)
    case category(String)

    /// Stable key for page cursors and cached candidate lists.
    var key: String {
        switch self {
        case .search(let q):
            return "q:" + [q.q, q.type ?? "", q.departmentId.map(String.init) ?? "",
                           q.yearStart.map(String.init) ?? "", q.yearEnd.map(String.init) ?? ""].joined(separator: "|")
        case .category(let c): return "cat:" + c
        }
    }
}

/// An id that the JSON writes as a string or a number.
nonisolated struct FlexibleID: Codable, Sendable, Equatable {
    let value: String
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else { value = String(try c.decode(Int.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}
