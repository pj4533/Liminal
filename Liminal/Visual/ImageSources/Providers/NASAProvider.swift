//
//  NASAProvider.swift
//  Liminal
//
//  NASA Image and Video Library (images-api.nasa.gov), keyless. Search with a year window, then
//  /asset/<id> for the original. `~large` is only 1920 px, below the size gate, so an original over
//  maxBytes is rejected rather than replaced (D40). Asset links are http and are upgraded to https.
//

import Foundation

nonisolated struct NASAProvider: ImageProvider {
    let id = "nasa"
    static let rights = "US Government work (NASA media are generally not copyrighted)"

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        guard case .search(let q) = query else { return CandidatePage(candidates: [], next: nil) }
        let page = Int(cursor ?? "1") ?? 1
        guard let url = LooseJSON.query("https://images-api.nasa.gov/search", [
            ("q", q.q), ("media_type", "image"), ("year_start", q.yearStart.map(String.init)),
            ("year_end", q.yearEnd.map(String.init)), ("page_size", String(perPage)), ("page", String(page)),
        ]) else { return CandidatePage(candidates: [], next: nil) }
        let result = try Self.parseSearch(try await http.data(url))
        return CandidatePage(candidates: result.candidates, next: result.hasNext ? String(page + 1) : nil)
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        var c = candidate
        if c.title == nil {
            guard let url = LooseJSON.query("https://images-api.nasa.gov/search", [("nasa_id", c.itemID)]) else {
                throw CandidateRejected(reason: "bad id")
            }
            guard let found = try Self.parseSearch(try await http.data(url)).candidates.first(where: { $0.itemID == c.itemID }) else {
                throw ImageFetchError.http(404)
            }
            c = found
        }
        guard let assetURL = URL(string: "https://images-api.nasa.gov/asset/" + (c.itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.itemID)),
              let original = Self.parseAsset(try await http.data(assetURL)) else {
            throw CandidateRejected(reason: "no JPEG or PNG original")
        }
        if let length = try await http.contentLength(original), length > context.maxBytes {
            throw CandidateRejected(reason: "original is \(length) bytes (over maxBytes; ~large is 1920 px)")
        }
        return ResolvedImage(url: original, width: nil, height: nil, bytes: nil, mime: nil,
                             credit: try credit(for: c, source: source, context: context, imageURL: original))
    }

    // MARK: - Parsing

    static func parseSearch(_ data: Data) throws -> (candidates: [ImageCandidate], hasNext: Bool) {
        let root = try LooseJSON.object(data)
        let collection = LooseJSON.dict(root["collection"]) ?? [:]
        var out: [ImageCandidate] = []
        for case let item as [String: Any] in LooseJSON.array(collection["items"]) {
            guard let d = LooseJSON.array(item["data"]).first as? [String: Any],
                  let nasaID = LooseJSON.string(d["nasa_id"]),
                  (LooseJSON.string(d["media_type"]) ?? "image") == "image" else { continue }
            let creator = LooseJSON.plainText(LooseJSON.string(d["photographer"]) ?? LooseJSON.string(d["secondary_creator"]))
                .map { String($0.prefix(120)) } ?? LooseJSON.string(d["center"]).map { "NASA \($0)" }
            out.append(ImageCandidate(
                providerID: "nasa", itemID: nasaID, title: LooseJSON.string(d["title"]), creator: creator,
                date: LooseJSON.year(LooseJSON.string(d["date_created"])), width: nil, height: nil, bytes: nil,
                mime: nil, rights: rights, pageURL: "https://images.nasa.gov/details/\(nasaID)", imageURL: nil,
                hint: nil))
        }
        let hasNext = LooseJSON.array(collection["links"]).contains { ($0 as? [String: Any]).flatMap { LooseJSON.string($0["rel"]) } == "next" }
        return (out, hasNext)
    }

    /// The `~orig` JPEG or PNG from /asset/<id>, as https.
    static func parseAsset(_ data: Data) -> URL? {
        guard let root = try? LooseJSON.object(data) else { return nil }
        let items = LooseJSON.array(LooseJSON.dict(root["collection"])?["items"])
        let hrefs = items.compactMap { ($0 as? [String: Any]).flatMap { LooseJSON.string($0["href"]) } }
        let original = hrefs.first { h in
            let lower = h.lowercased()
            return lower.contains("~orig.") && (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png"))
        }
        return original.flatMap { ImageHTTP.secure($0.replacingOccurrences(of: " ", with: "%20")) }
    }
}
