//
//  DigitalCommonwealthProvider.swift
//  Liminal
//
//  Digital Commonwealth (Boston Public Library and other Massachusetts collections), keyless
//  Blacklight JSON plus IIIF 2 (docs/research/image-apis/new-providers.md 1). A source's `collection`
//  is the host collection facet (for example "The Tichnor Brothers Collection": 1930-45 linen
//  postcards of motels, highways and moonlit main streets, about 3300 px). Only records whose
//  `reuse_allowed_ssi` is "no restrictions" are kept; other collections on the site are mixed.
//

import Foundation

nonisolated struct DigitalCommonwealthProvider: ImageProvider {
    let id = "dc"
    static let site = "https://www.digitalcommonwealth.org"
    static let iiif = "https://iiif.digitalcommonwealth.org/iiif/2/"

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        guard case .search(let q) = query else { return CandidatePage(candidates: [], next: nil) }
        let page = Int(cursor ?? "1") ?? 1
        guard let url = LooseJSON.query(Self.site + "/search.json", [
            ("q", q.q), ("per_page", String(perPage)), ("page", String(page)),
            ("f[related_item_host_ssim][]", source.collection),
        ]) else { return CandidatePage(candidates: [], next: nil) }
        let result = try Self.parseSearch(try await http.data(url))
        return CandidatePage(candidates: result.candidates, next: result.hasNext ? String(page + 1) : nil)
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        var c = candidate
        if c.hint == nil {
            guard let url = URL(string: "\(Self.site)/search/\(c.itemID).json") else { throw CandidateRejected(reason: "bad id") }
            let root = try LooseJSON.object(try await http.data(url))
            guard let data = LooseJSON.dict(root["data"]), let found = Self.candidate(data) else {
                throw CandidateRejected(reason: "no image")
            }
            c = found
        }
        guard let imageID = c.hint else { throw CandidateRejected(reason: "no image") }
        if c.width == nil || c.height == nil, let infoURL = URL(string: Self.iiif + imageID + "/info.json") {
            let size = try LOCProvider.parseInfo(try await http.data(infoURL))
            c.width = size.width; c.height = size.height
        }
        let target = context.targetLongSide
        guard let url = URL(string: "\(Self.iiif)\(imageID)/full/!\(target),\(target)/0/default.jpg") else {
            throw CandidateRejected(reason: "bad IIIF url")
        }
        var w = c.width, h = c.height
        if let fw = w, let fh = h, max(fw, fh) > target {
            let scale = Double(target) / Double(max(fw, fh))
            w = Int((Double(fw) * scale).rounded()); h = Int((Double(fh) * scale).rounded())
        }
        return ResolvedImage(url: url, width: w, height: h, bytes: nil, mime: "image/jpeg",
                             credit: try credit(for: c, source: source, context: context, imageURL: url))
    }

    // MARK: - Parsing

    /// One record (`data[]` of a search, or `data` of /search/<id>.json).
    static func candidate(_ record: [String: Any]) -> ImageCandidate? {
        guard let id = LooseJSON.string(record["id"]) else { return nil }
        let a = LooseJSON.dict(record["attributes"]) ?? [:]
        guard let image = LooseJSON.string(a["exemplary_image_ssi"]) else { return nil }
        // reuse_allowed_ssi is the site's normalised verdict ("no restrictions", "contact host", ...).
        let rights = LooseJSON.string(a["reuse_allowed_ssi"]) ?? LooseJSON.string(a["license_ss"])
        return ImageCandidate(
            providerID: "dc", itemID: id, title: LooseJSON.string(a["title_info_primary_tsi"]),
            creator: publisher(LooseJSON.string(a["publisher_tsi"])),
            date: LooseJSON.string(a["date_tsim"]).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) },
            width: nil, height: nil, bytes: nil, mime: "image/jpeg", rights: rights,
            pageURL: LooseJSON.string(a["identifier_uri_ss"]) ?? "\(site)/search/\(id)",
            imageURL: nil, hint: image)
    }

    /// "\"Tichnor Quality Views,\" Reg. U. S. Pat. Off. Made Only by Tichnor Bros., Inc., Boston, Mass." -> "Tichnor Bros., Inc."
    static func publisher(_ s: String?) -> String? {
        guard let s else { return nil }
        if let r = s.range(of: "Made Only by ") {
            let rest = s[r.upperBound...]
            let parts = rest.components(separatedBy: ", ")
            return parts.prefix(2).joined(separator: ", ")
        }
        return s
    }

    static func parseSearch(_ data: Data) throws -> (candidates: [ImageCandidate], hasNext: Bool) {
        let root = try LooseJSON.object(data)
        let list = LooseJSON.array(root["data"]).compactMap { ($0 as? [String: Any]).flatMap(candidate) }
        let pages = LooseJSON.dict(LooseJSON.dict(root["meta"])?["pages"])
        let hasNext = (LooseJSON.int(pages?["next_page"]) ?? 0) > 0
        return (list, hasNext)
    }
}
