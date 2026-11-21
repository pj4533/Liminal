//
//  SmithsonianProvider.swift
//  Liminal
//
//  Smithsonian Open Access (api.si.edu). Needs an api.data.gov key, read only from the environment
//  (SMITHSONIAN_API_KEY); without one the provider is not registered and its source stays disabled.
//  Rows with `online_media` null are skipped; `metadata_usage.access` must be CC0.
//

import Foundation

nonisolated struct SmithsonianProvider: ImageProvider {
    let id = "si"
    let apiKey: String

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        guard case .search(let q) = query else { return CandidatePage(candidates: [], next: nil) }
        let start = Int(cursor ?? "0") ?? 0
        guard let url = LooseJSON.query("https://api.si.edu/openaccess/api/v1.0/search", [
            ("q", q.q + " AND online_media_type:Images"), ("api_key", apiKey), ("rows", String(perPage)), ("start", String(start)),
        ]) else { return CandidatePage(candidates: [], next: nil) }
        let result = try Self.parseSearch(try await http.data(url))
        return CandidatePage(candidates: result.candidates, next: start + perPage < result.total ? String(start + perPage) : nil)
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        guard let s = candidate.imageURL, let url = ImageHTTP.secure(s) else { throw CandidateRejected(reason: "no media") }
        return ResolvedImage(url: url, width: candidate.width, height: candidate.height, bytes: nil, mime: nil,
                             credit: try credit(for: candidate, source: source, context: context, imageURL: url))
    }

    static func parseSearch(_ data: Data) throws -> (candidates: [ImageCandidate], total: Int) {
        let root = try LooseJSON.object(data)
        let response = LooseJSON.dict(root["response"]) ?? [:]
        var out: [ImageCandidate] = []
        for case let row as [String: Any] in LooseJSON.array(response["rows"]) {
            let content = LooseJSON.dict(row["content"]) ?? [:]
            let dnr = LooseJSON.dict(content["descriptiveNonRepeating"]) ?? [:]
            guard let id = LooseJSON.string(row["id"]),
                  let media = LooseJSON.array(LooseJSON.dict(dnr["online_media"])?["media"]).first as? [String: Any],
                  let image = LooseJSON.string(media["content"]) else { continue }
            let access = LooseJSON.string(LooseJSON.dict(dnr["metadata_usage"])?["access"])
                ?? LooseJSON.string(LooseJSON.dict(media["usage"])?["access"])
            let freetext = LooseJSON.dict(content["freetext"]) ?? [:]
            let name = (LooseJSON.array(freetext["name"]).first as? [String: Any]).flatMap { LooseJSON.string($0["content"]) }
            let date = (LooseJSON.array(freetext["date"]).first as? [String: Any]).flatMap { LooseJSON.string($0["content"]) }
            out.append(ImageCandidate(providerID: "si", itemID: id, title: LooseJSON.string(row["title"]), creator: name,
                                      date: date, width: nil, height: nil, bytes: nil, mime: nil, rights: access,
                                      pageURL: LooseJSON.string(dnr["record_link"]), imageURL: image, hint: nil))
        }
        return (out, LooseJSON.int(response["rowCount"]) ?? out.count)
    }
}
