//
//  ArticProvider.swift
//  Liminal
//
//  Art Institute of Chicago, keyless (docs/research/image-apis/new-providers.md 2). Search with an
//  Elasticsearch bool query in GET parameters: the title match plus `is_public_domain` (combining
//  `q` with a filter falls back to popularity order). The IIIF server serves only a few fixed widths;
//  `full/3000,/0/default.jpg` gives 3000 px on the long side, or native size when smaller. The
//  native size is in `thumbnail.width/height`, so the size gate needs no info.json. Rate limit about
//  60 requests a minute across both hosts (hostGaps 2 s).
//

import Foundation

nonisolated struct ArticProvider: ImageProvider {
    let id = "aic"
    static let api = "https://api.artic.edu/api/v1/artworks"
    static let iiif = "https://www.artic.edu/iiif/2/"
    static let fields = "id,title,image_id,is_public_domain,thumbnail,artist_title,date_display,artwork_type_title"
    /// The served long side: AIC allows `full/3000,` but not 2528.
    static let servedLongSide = 3000

    /// CuratedQuery.type -> artwork_type_id.
    static let artworkTypes = ["Painting": 1, "Photograph": 2, "Drawing and Watercolor": 14, "Print": 18]

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        guard case .search(let q) = query else { return CandidatePage(candidates: [], next: nil) }
        let page = Int(cursor ?? "1") ?? 1
        var items: [(String, String?)] = [
            ("query[bool][must][0][match][title]", q.q),
            ("query[bool][must][1][term][is_public_domain]", "true"),
        ]
        if let type = q.type, let typeID = Self.artworkTypes[type] {
            items.append(("query[bool][must][2][term][artwork_type_id]", String(typeID)))
        }
        items += [("fields", Self.fields), ("limit", String(min(perPage, 100))), ("page", String(page))]
        guard let url = LooseJSON.query(Self.api + "/search", items) else { return CandidatePage(candidates: [], next: nil) }
        let result = try Self.parseSearch(try await http.data(url))
        return CandidatePage(candidates: result.candidates, next: page < result.totalPages ? String(page + 1) : nil)
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        var c = candidate
        if c.hint == nil {
            guard let url = LooseJSON.query("\(Self.api)/\(c.itemID)", [("fields", Self.fields)]) else {
                throw CandidateRejected(reason: "bad id")
            }
            let root = try LooseJSON.object(try await http.data(url))
            guard let data = LooseJSON.dict(root["data"]), let found = Self.candidate(data) else {
                throw CandidateRejected(reason: "no image")
            }
            c = found
        }
        guard let imageID = c.hint,
              let url = URL(string: "\(Self.iiif)\(imageID)/full/\(Self.servedLongSide),/0/default.jpg") else {
            throw CandidateRejected(reason: "no image")
        }
        // Served size: the native size fitted inside 3000 on the long side, never upscaled.
        var w = c.width, h = c.height
        if let fw = w, let fh = h, max(fw, fh) > Self.servedLongSide {
            let scale = Double(Self.servedLongSide) / Double(max(fw, fh))
            w = Int((Double(fw) * scale).rounded()); h = Int((Double(fh) * scale).rounded())
        }
        return ResolvedImage(url: url, width: w, height: h, bytes: nil, mime: "image/jpeg",
                             credit: try credit(for: c, source: source, context: context, imageURL: url))
    }

    // MARK: - Parsing

    static func candidate(_ a: [String: Any]) -> ImageCandidate? {
        guard let id = LooseJSON.string(a["id"]), let image = LooseJSON.string(a["image_id"]) else { return nil }
        let thumb = LooseJSON.dict(a["thumbnail"])
        let publicDomain = (a["is_public_domain"] as? Bool) ?? false
        return ImageCandidate(
            providerID: "aic", itemID: id, title: LooseJSON.string(a["title"]),
            creator: LooseJSON.string(a["artist_title"]), date: LooseJSON.string(a["date_display"]),
            width: LooseJSON.int(thumb?["width"]), height: LooseJSON.int(thumb?["height"]),
            bytes: nil, mime: "image/jpeg",
            // AIC's open-access terms: public-domain works are released under CC0.
            rights: publicDomain ? "CC0" : "not public domain (restricted)",
            pageURL: "https://www.artic.edu/artworks/\(id)", imageURL: nil, hint: image)
    }

    static func parseSearch(_ data: Data) throws -> (candidates: [ImageCandidate], totalPages: Int) {
        let root = try LooseJSON.object(data)
        let list = LooseJSON.array(root["data"]).compactMap { ($0 as? [String: Any]).flatMap(candidate) }
        let pages = LooseJSON.int(LooseJSON.dict(root["pagination"])?["total_pages"]) ?? 1
        return (list, pages)
    }
}
