//
//  MetProvider.swift
//  Liminal
//
//  The Met Open Access, keyless. The v1.1 search returns object ids only and ignores its
//  isPublicDomain filter, so every object is checked on its own record; a classification allowlist
//  keeps furniture and netsuke out. An Incapsula bot wall answers 403 HTML after about 100 quick
//  requests: ImageHTTP keeps 5 s between Met requests and maps that page to `.blocked`, which backs
//  the provider off for 30 minutes.
//

import Foundation

nonisolated struct MetProvider: ImageProvider {
    let id = "met"
    static let search = "https://collectionapi.metmuseum.org/public/collection/v1.1/search"
    static let object = "https://collectionapi.metmuseum.org/public/collection/v1/objects/"

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        guard case .search(let q) = query else { return CandidatePage(candidates: [], next: nil) }
        let offset = Int(cursor ?? "0") ?? 0
        guard let url = LooseJSON.query(Self.search, [
            ("hasImages", "true"), ("isPublicDomain", "true"), ("q", q.q), ("departmentId", q.departmentId.map(String.init)),
            ("limit", String(perPage)), ("offset", String(offset)),
        ]) else { return CandidatePage(candidates: [], next: nil) }
        let result = try Self.parseSearch(try await http.data(url))
        let candidates = result.ids.map { ImageCandidate.stub(provider: id, id: $0) }
        let next = offset + perPage < result.total && !result.ids.isEmpty ? String(offset + perPage) : nil
        return CandidatePage(candidates: candidates, next: next)
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        guard let url = URL(string: Self.object + candidate.itemID) else { throw CandidateRejected(reason: "bad id") }
        let c = try Self.parseObject(try await http.data(url), allowClassification: source.allowClassification)
        guard let s = c.imageURL, let imageURL = ImageHTTP.secure(s) else { throw CandidateRejected(reason: "no primary image") }
        return ResolvedImage(url: imageURL, width: nil, height: nil, bytes: nil, mime: "image/jpeg",
                             credit: try credit(for: c, source: source, context: context, imageURL: imageURL))
    }

    // MARK: - Parsing

    static func parseSearch(_ data: Data) throws -> (ids: [String], total: Int) {
        let root = try LooseJSON.object(data)
        let ids = LooseJSON.array(root["objectIDs"]).compactMap { LooseJSON.string($0) }
        return (ids, LooseJSON.int(root["total"]) ?? ids.count)
    }

    /// One object record. Not public domain, or outside the classification allowlist, is a rejection.
    static func parseObject(_ data: Data, allowClassification: [String]?) throws -> ImageCandidate {
        let o = try LooseJSON.object(data)
        guard let id = LooseJSON.string(o["objectID"]) else { throw ImageFetchError.http(404) }
        guard (o["isPublicDomain"] as? Bool) == true else { throw CandidateRejected(reason: "not public domain") }
        let classification = LooseJSON.string(o["classification"]) ?? ""
        if let allow = allowClassification, !allow.isEmpty, !allow.contains(classification) {
            throw CandidateRejected(reason: "classification \(classification)")
        }
        return ImageCandidate(
            providerID: "met", itemID: id, title: LooseJSON.string(o["title"]),
            creator: LooseJSON.string(o["artistDisplayName"]), date: LooseJSON.string(o["objectDate"]),
            width: nil, height: nil, bytes: nil, mime: "image/jpeg",
            rights: "CC0", pageURL: LooseJSON.string(o["objectURL"]), imageURL: LooseJSON.string(o["primaryImage"]),
            hint: classification)
    }
}
