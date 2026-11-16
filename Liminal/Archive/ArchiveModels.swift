//
//  ArchiveModels.swift
//  Liminal
//
//  Internet Archive response models (docs/plans/archive-video.md 1.1). The metadata and file models
//  follow LostArchiveTV's ArchiveMetadata / ArchiveFile; the search model is new (LostArchiveTV never
//  searches). Archive fields are loosely typed: one item has `year: 1954`, another `"1954"`, another
//  `["1954"]`, so every scalar decodes through `LooseString`.
//

import Foundation

/// A string field that may arrive as a string, a number or an array of strings (first element used,
/// arrays joined for free text). Missing or null decodes as nil at the use site (`decodeIfPresent`).
nonisolated struct LooseString: Codable, Sendable, Equatable {
    let value: String
    /// All elements when the field was an array (description, subject).
    let all: [String]

    init(_ value: String) { self.value = value; self.all = [value] }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s; all = [s]
        } else if let i = try? c.decode(Int.self) {
            value = String(i); all = [value]
        } else if let d = try? c.decode(Double.self) {
            value = String(d); all = [value]
        } else if let a = try? c.decode([String].self) {
            value = a.first ?? ""; all = a
        } else {
            value = ""; all = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    /// Array fields joined with a space (free-text matching).
    var joined: String { all.joined(separator: " ") }
}

// MARK: - advancedsearch.php

nonisolated struct ArchiveSearchResponse: Decodable, Sendable {
    let response: Body?
    let error: String?

    struct Body: Decodable, Sendable {
        let numFound: Int
        let start: Int?
        let docs: [ArchiveSearchDoc]
    }
}

nonisolated struct ArchiveSearchDoc: Codable, Sendable, Equatable {
    let identifier: String
    let title: LooseString?
    let year: LooseString?
    let sound: LooseString?
    let color: LooseString?
    let licenseurl: LooseString?
    let runtime: LooseString?

    var titleText: String { title?.joined ?? identifier }
    /// First four digits of the year field (archive years are sometimes "1954-01-01" or "195?").
    var yearValue: Int? { year.flatMap { Int($0.value.prefix(4)) } }
}

// MARK: - /metadata/{id}

nonisolated struct ArchiveItemMetadata: Decodable, Sendable {
    let files: [ArchiveFile]
    let metadata: ArchiveItemInfo?
    /// True for items the Archive has taken down or restricted ("is_dark").
    let is_dark: Bool?
}

nonisolated struct ArchiveItemInfo: Decodable, Sendable {
    let identifier: LooseString?
    let title: LooseString?
    let description: LooseString?
    let subject: LooseString?
    let year: LooseString?
    let date: LooseString?
    let color: LooseString?
    let sound: LooseString?
    let licenseurl: LooseString?
    let collection: LooseString?
}

nonisolated struct ArchiveFile: Codable, Sendable, Equatable {
    let name: String
    let format: String?
    let size: LooseString?
    let length: LooseString?
    let height: LooseString?
    let width: LooseString?

    init(name: String, format: String?, size: String? = nil, length: String? = nil,
         height: String? = nil, width: String? = nil) {
        self.name = name
        self.format = format
        self.size = size.map(LooseString.init)
        self.length = length.map(LooseString.init)
        self.height = height.map(LooseString.init)
        self.width = width.map(LooseString.init)
    }

    var bytes: Int64? { size.flatMap { Int64($0.value) } }
    var pixelHeight: Int? { height.flatMap { Int($0.value) } }
}
