//
//  ImageProvider.swift
//  Liminal
//
//  One adapter per institution API (docs/plans/image-api-mode.md 3.1). Each keeps its parsing in
//  static pure functions over `Data`, so the tests run on saved JSON with no network.
//

import Foundation

/// What `resolve` needs to know beyond the candidate.
nonisolated struct ResolveContext: Sendable {
    /// Long side to request from servers that scale (LOC IIIF, Commons thumbnails).
    let targetLongSide: Int
    let maxBytes: Int
    let institution: String
    let allowlist: [String]
}

/// A candidate that fails a rule (rights, title, size, type). It is recorded and never retried.
nonisolated struct CandidateRejected: Error, Equatable, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

nonisolated protocol ImageProvider: Sendable {
    var id: String { get }
    /// One page of a source's search. `cursor` nil = first page.
    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage
    /// Candidates for pinned ids. The default returns stubs that `resolve` looks up one at a time.
    func pinned(source: CuratedSource, ids: [String], http: ImageHTTP) async throws -> [ImageCandidate]
    /// Final image URL, declared size and credit. Throws CandidateRejected for rule failures.
    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage
}

nonisolated extension ImageProvider {
    func pinned(source: CuratedSource, ids: [String], http: ImageHTTP) async throws -> [ImageCandidate] {
        ids.map { ImageCandidate.stub(provider: id, id: $0) }
    }

    /// Rights verdict and credit, shared by every provider.
    func credit(for c: ImageCandidate, source: CuratedSource, context: ResolveContext,
                imageURL: URL) throws -> ImageSourceCredit {
        let verdict = ImageRights.verdict(rightsText: c.rights, allowlist: context.allowlist)
        guard let license = verdict.license else {
            if case .rejected(let reason) = verdict { throw CandidateRejected(reason: reason) }
            throw CandidateRejected(reason: "rights")
        }
        let title = (c.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CandidateRejected(reason: "no title") }
        if source.rejectsTitle(title, itemID: c.itemID) { throw CandidateRejected(reason: "title rejected: \(title.prefix(60))") }
        let creator = c.creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = creator.flatMap { $0.isEmpty ? nil : $0 }
        // CC BY and CC BY-SA are kept only when the credit can name the author (D37).
        if license.uppercased().hasPrefix("CC BY"), named == nil {
            throw CandidateRejected(reason: "\(license) without a creator to credit")
        }
        return ImageSourceCredit(providerID: id, sourceID: source.id, itemID: c.itemID, title: title,
                                 creator: named, date: c.date,
                                 institution: context.institution, license: license,
                                 licenseURL: ImageRights.licenseURL(license),
                                 sourceURL: c.pageURL ?? imageURL.absoluteString, imageURL: imageURL.absoluteString)
    }
}

nonisolated enum ImageProviders {
    /// Every keyless provider, plus Smithsonian when SMITHSONIAN_API_KEY is in the environment.
    static func all(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: any ImageProvider] {
        var list: [any ImageProvider] = [LOCProvider(), NASAProvider(), WikimediaProvider(), ClevelandProvider(),
                                         MetProvider()]
        if let key = environment["SMITHSONIAN_API_KEY"], !key.isEmpty {
            list.append(SmithsonianProvider(apiKey: key))
        }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}

// MARK: - Loose JSON helpers

/// Reads the messy JSON of library APIs (fields that are a string, a number or an array of strings).
nonisolated enum LooseJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageFetchError.badContent("not a JSON object")
        }
        return o
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.lazy.compactMap { string($0) }.first
        default: return nil
        }
    }

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func array(_ v: Any?) -> [Any] { v as? [Any] ?? [] }

    /// HTML stripped to plain text (Commons Artist / Credit fields).
    static func plainText(_ html: String?) -> String? {
        guard var s = html else { return nil }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    static func query(_ base: String, _ items: [(String, String?)]) -> URL? {
        guard var c = URLComponents(string: base) else { return nil }
        c.queryItems = (c.queryItems ?? []) + items.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        // '+' must not be read as a space by the servers.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    /// "1969-07-20T00:00:00Z" -> "1969".
    static func year(_ s: String?) -> String? {
        guard let s, let m = s.range(of: #"\d{4}"#, options: .regularExpression) else { return s }
        return String(s[m])
    }
}
