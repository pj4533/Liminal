//
//  ClevelandProvider.swift
//  Liminal
//
//  Cleveland Museum of Art Open Access, keyless. `type` keeps queries to prints and photographs;
//  `images.print` is a JPEG of about 3400 px (never `images.full`, a TIFF). share_license_status
//  must be CC0.
//

import Foundation

nonisolated struct ClevelandProvider: ImageProvider {
    let id = "cma"
    static let api = "https://openaccess-api.clevelandart.org/api/artworks/"

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        guard case .search(let q) = query else { return CandidatePage(candidates: [], next: nil) }
        let skip = Int(cursor ?? "0") ?? 0
        guard let url = LooseJSON.query(Self.api, [
            ("q", q.q), ("type", q.type), ("has_image", "1"), ("cc0", "1"), ("limit", String(perPage)), ("skip", String(skip)),
        ]) else { return CandidatePage(candidates: [], next: nil) }
        let result = try Self.parseSearch(try await http.data(url))
        let next = skip + perPage < result.total ? String(skip + perPage) : nil
        return CandidatePage(candidates: result.candidates, next: next)
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        var c = candidate
        if c.imageURL == nil {
            guard let url = URL(string: Self.api + c.itemID) else { throw CandidateRejected(reason: "bad id") }
            let root = try LooseJSON.object(try await http.data(url))
            guard let data = LooseJSON.dict(root["data"]), let found = Self.candidate(data) else {
                throw CandidateRejected(reason: "no print image")
            }
            c = found
        }
        guard let s = c.imageURL, let url = ImageHTTP.secure(s) else { throw CandidateRejected(reason: "no print image") }
        return ResolvedImage(url: url, width: c.width, height: c.height, bytes: c.bytes, mime: "image/jpeg",
                             credit: try credit(for: c, source: source, context: context, imageURL: url))
    }

    // MARK: - Parsing

    static func candidate(_ a: [String: Any]) -> ImageCandidate? {
        guard let id = LooseJSON.string(a["id"]) else { return nil }
        let print = LooseJSON.dict(LooseJSON.dict(a["images"])?["print"])
        let creators = LooseJSON.array(a["creators"]).compactMap { ($0 as? [String: Any]).flatMap { LooseJSON.string($0["description"]) } }
        return ImageCandidate(
            providerID: "cma", itemID: id, title: LooseJSON.string(a["title"]),
            // "Utagawa Hiroshige (Japanese, 1797–1858)" -> "Utagawa Hiroshige"
            creator: creators.first.map { $0.components(separatedBy: " (").first ?? $0 },
            date: LooseJSON.string(a["creation_date"]),
            width: LooseJSON.int(print?["width"]), height: LooseJSON.int(print?["height"]),
            bytes: LooseJSON.int(print?["filesize"]), mime: "image/jpeg",
            rights: LooseJSON.string(a["share_license_status"]), pageURL: LooseJSON.string(a["url"]),
            imageURL: LooseJSON.string(print?["url"]), hint: LooseJSON.string(a["type"]))
    }

    static func parseSearch(_ data: Data) throws -> (candidates: [ImageCandidate], total: Int) {
        let root = try LooseJSON.object(data)
        let list = LooseJSON.array(root["data"]).compactMap { ($0 as? [String: Any]).flatMap(candidate) }
        let total = LooseJSON.int(LooseJSON.dict(root["info"])?["total"]) ?? list.count
        return (list.filter { $0.imageURL != nil }, total)
    }
}
