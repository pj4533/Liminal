//
//  WikimediaProvider.swift
//  Liminal
//
//  Wikimedia Commons MediaWiki API, keyless with a descriptive User-Agent. Curated categories and
//  `filetype:bitmap` searches with prop=imageinfo give size, mime, licence and credit in one call;
//  pinned files are fetched 50 titles per request. JPEG and PNG only. The licence is the file's own
//  `LicenseShortName`, judged against the allowlist.
//

import Foundation

nonisolated struct WikimediaProvider: ImageProvider {
    let id = "wikimedia"
    static let api = "https://commons.wikimedia.org/w/api.php"
    static let metadataFilter = "LicenseShortName|Artist|DateTimeOriginal|ObjectName|Credit"
    /// Requested thumbnail width; Commons serves its 3840 px step, decoded down to the target.
    var thumbWidth = 3072

    private func baseItems() -> [(String, String?)] {
        [("action", "query"), ("format", "json"), ("prop", "imageinfo"), ("iiprop", "url|size|mime|extmetadata"),
         ("iiurlwidth", String(thumbWidth)), ("iiextmetadatafilter", Self.metadataFilter)]
    }

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        var items = baseItems()
        switch query {
        case .category(let name):
            items += [("generator", "categorymembers"), ("gcmtitle", "Category:" + name), ("gcmtype", "file"),
                      ("gcmlimit", String(perPage)), ("gcmcontinue", cursor)]
        case .search(let q):
            items += [("generator", "search"), ("gsrnamespace", "6"), ("gsrsearch", q.q + " filetype:bitmap"),
                      ("gsrlimit", String(perPage)), ("gsroffset", cursor)]
        }
        guard let url = LooseJSON.query(Self.api, items) else { return CandidatePage(candidates: [], next: nil) }
        return try Self.parse(try await http.data(url), thumbWidth: thumbWidth)
    }

    func pinned(source: CuratedSource, ids: [String], http: ImageHTTP) async throws -> [ImageCandidate] {
        var out: [ImageCandidate] = []
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            guard let url = LooseJSON.query(Self.api, baseItems() + [("titles", chunk.joined(separator: "|"))]) else { continue }
            out += try Self.parse(try await http.data(url), thumbWidth: thumbWidth).candidates
        }
        return out
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        var c = candidate
        if c.imageURL == nil {
            c = try await pinned(source: source, ids: [c.itemID], http: http).first ?? c
        }
        guard let mime = c.mime, ["image/jpeg", "image/png"].contains(mime) else {
            throw CandidateRejected(reason: "mime \(c.mime ?? "unknown")")
        }
        guard let s = c.imageURL, let url = ImageHTTP.secure(s) else { throw CandidateRejected(reason: "no image url") }
        return ResolvedImage(url: url, width: c.width, height: c.height, bytes: c.bytes, mime: mime,
                             credit: try credit(for: c, source: source, context: context, imageURL: url))
    }

    // MARK: - Parsing

    /// "File:SUNSET - NARA - 544071.jpg" -> "SUNSET - NARA - 544071".
    static func displayTitle(_ fileTitle: String) -> String {
        var t = fileTitle
        if t.hasPrefix("File:") { t.removeFirst(5) }
        if let dot = t.lastIndex(of: "."), t.distance(from: dot, to: t.endIndex) <= 5 { t = String(t[..<dot]) }
        return t
    }

    static func parse(_ data: Data, thumbWidth: Int) throws -> CandidatePage {
        let root = try LooseJSON.object(data)
        let pages = LooseJSON.dict(LooseJSON.dict(root["query"])?["pages"]) ?? [:]
        var out: [ImageCandidate] = []
        // Sorted by page id so a page of results always comes out in the same order.
        for (_, value) in pages.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
            guard let page = value as? [String: Any], page["missing"] == nil,
                  let fileTitle = LooseJSON.string(page["title"]),
                  let info = LooseJSON.array(page["imageinfo"]).first as? [String: Any] else { continue }
            let meta = LooseJSON.dict(info["extmetadata"]) ?? [:]
            func field(_ k: String) -> String? { LooseJSON.plainText(LooseJSON.string(LooseJSON.dict(meta[k])?["value"])) }
            let width = LooseJSON.int(info["width"]) ?? 0, height = LooseJSON.int(info["height"]) ?? 0
            // The original when it is no wider than the request, else the scaled thumbnail.
            let useOriginal = width <= thumbWidth || LooseJSON.string(info["thumburl"]) == nil
            let imageURL = useOriginal ? LooseJSON.string(info["url"]) : LooseJSON.string(info["thumburl"])
            let w = useOriginal ? width : (LooseJSON.int(info["thumbwidth"]) ?? width)
            let h = useOriginal ? height : (LooseJSON.int(info["thumbheight"]) ?? height)
            out.append(ImageCandidate(
                providerID: "wikimedia", itemID: fileTitle,
                title: field("ObjectName") ?? displayTitle(fileTitle),
                creator: field("Artist").map { String($0.prefix(120)) },
                date: LooseJSON.year(field("DateTimeOriginal")),
                width: w, height: h, bytes: useOriginal ? LooseJSON.int(info["size"]) : nil,
                mime: LooseJSON.string(info["mime"]), rights: field("LicenseShortName"),
                pageURL: LooseJSON.string(info["descriptionurl"]), imageURL: imageURL, hint: nil))
        }
        let cont = LooseJSON.dict(root["continue"])
        let next = LooseJSON.string(cont?["gcmcontinue"]) ?? LooseJSON.string(cont?["gsroffset"])
        return CandidatePage(candidates: out, next: next)
    }
}
