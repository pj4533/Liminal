//
//  LOCProvider.swift
//  Liminal
//
//  Library of Congress (docs/research/image-apis/collections.md). Collection search JSON; only items
//  with a IIIF image service reach 2K (Carol M. Highsmith's archive). The search result already
//  carries the rights advisory and the IIIF derivatives with their sizes in the URL fragment, so
//  a search hit needs no further request. Pinned ids are looked up through /item/<id>/?fo=json.
//

import Foundation

nonisolated struct LOCProvider: ImageProvider {
    let id = "loc"

    func search(source: CuratedSource, query: SourceQuery, cursor: String?, perPage: Int,
                http: ImageHTTP) async throws -> CandidatePage {
        guard case .search(let q) = query, let collection = source.collection else { return CandidatePage(candidates: [], next: nil) }
        let page = Int(cursor ?? "1") ?? 1
        guard let url = LooseJSON.query("https://www.loc.gov/collections/\(collection)/", [
            ("fo", "json"), ("q", q.q), ("c", String(perPage)), ("sp", String(page)), ("fa", "online-format:image"),
        ]) else { return CandidatePage(candidates: [], next: nil) }
        let result = try Self.parseSearch(try await http.data(url), allowMaster: source.useMasters ?? false)
        let kept = (source.requireIIIF ?? true) ? result.candidates.filter { $0.hint != nil } : result.candidates
        return CandidatePage(candidates: kept, next: result.next == nil ? nil : String(page + 1))
    }

    func resolve(_ candidate: ImageCandidate, source: CuratedSource, context: ResolveContext,
                 http: ImageHTTP) async throws -> ResolvedImage {
        var c = candidate
        if c.hint == nil {
            guard let url = URL(string: "https://www.loc.gov/item/\(c.itemID)/?fo=json") else { throw CandidateRejected(reason: "bad id") }
            c = try Self.parseItem(try await http.data(url), id: c.itemID, allowMaster: source.useMasters ?? false)
        }
        guard let service = c.hint else { throw CandidateRejected(reason: "no IIIF service (1024 px only)") }
        if c.width == nil || c.height == nil, let infoURL = URL(string: service + "/info.json") {
            let size = try Self.parseInfo(try await http.data(infoURL))
            c.width = size.width; c.height = size.height
        }
        let long = max(c.width ?? 0, c.height ?? 0)
        let target = long > 0 ? min(long, context.targetLongSide) : context.targetLongSide
        guard let imageURL = URL(string: "\(service)/full/!\(target),\(target)/0/default.jpg") else {
            throw CandidateRejected(reason: "bad IIIF url")
        }
        var w = c.width, h = c.height
        if let fw = w, let fh = h, long > target {
            let scale = Double(target) / Double(long)
            w = Int((Double(fw) * scale).rounded()); h = Int((Double(fh) * scale).rounded())
        }
        var resolved = ResolvedImage(url: imageURL, width: w, height: h, bytes: nil, mime: "image/jpeg",
                                     credit: try credit(for: c, source: source, context: context, imageURL: imageURL))
        if service.contains("/iiif/master:") { resolved.fallbackURL = URL(string: "\(service)/full/full/0/default.jpg") }
        return resolved
    }

    // MARK: - Parsing

    /// IIIF service id and the full size it implies, from a derivative URL such as
    /// `https://tile.loc.gov/image-services/iiif/service:pnp:highsm:31900:31928/full/pct:25/0/default.jpg#h=1228&w=1840`.
    static func iiif(from urlString: String) -> (service: String, width: Int?, height: Int?)? {
        let pattern = #"^(https://tile\.loc\.gov/image-services/iiif/[^/]+)/full/([^/]+)/"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let sr = Range(m.range(at: 1), in: urlString), let rr = Range(m.range(at: 2), in: urlString) else { return nil }
        let service = String(urlString[sr])
        let region = String(urlString[rr])
        var width: Int?, height: Int?
        if region.hasPrefix("pct:"), let pct = Double(region.dropFirst(4)), pct > 0,
           let hash = urlString.split(separator: "#").last, urlString.contains("#") {
            var fw: Int?, fh: Int?
            for part in hash.split(separator: "&") {
                let kv = part.split(separator: "=")
                guard kv.count == 2, let v = Int(kv[1]) else { continue }
                if kv[0] == "w" { fw = v } else if kv[0] == "h" { fh = v }
            }
            if let fw, let fh {
                width = Int((Double(fw) * 100 / pct).rounded())
                height = Int((Double(fh) * 100 / pct).rounded())
            }
        }
        return (service, width, height)
    }

    /// IIIF service of the scanned master behind a 1024 px derivative, the trick from OpenPics' LoC
    /// provider: `.../storage-services/service/pnp/fsac/1a33000/1a33800/1a33849v.jpg` ->
    /// `https://tile.loc.gov/image-services/iiif/master:pnp:fsac:1a33000:1a33800:1a33849u`. FSA/OWI
    /// colour, photochroms and Prokudin-Gorskii only expose their large TIFF masters this way
    /// (measured 2026-11-21: 4698x3280, 2759x3666, 3808x3726). The size comes from info.json, and an
    /// item without a master service fails that request and is rejected on its own.
    static func masterIIIF(from urlString: String) -> String? {
        let pattern = #"^https://tile\.loc\.gov/storage-services/service/(pnp/[^#?]+?)(?:v|r|_150px|t)\.(?:jpg|gif)(?:[#?].*)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let r = Range(m.range(at: 1), in: urlString) else { return nil }
        let path = urlString[r].replacingOccurrences(of: "/", with: ":")
        return "https://tile.loc.gov/image-services/iiif/master:\(path)u"
    }

    static func itemID(from idURL: String) -> String {
        idURL.split(separator: "/").last.map(String.init) ?? idURL
    }

    /// "highsmith, carol m." -> "Highsmith, Carol M."
    static func displayName(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        guard s == s.lowercased() else { return s }
        return s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func parseSearch(_ data: Data, allowMaster: Bool = false) throws -> (candidates: [ImageCandidate], next: String?) {
        let root = try LooseJSON.object(data)
        var out: [ImageCandidate] = []
        for case let r as [String: Any] in LooseJSON.array(root["results"]) {
            guard let idURL = LooseJSON.string(r["id"]) else { continue }
            let item = LooseJSON.dict(r["item"]) ?? [:]
            // The largest IIIF derivative gives the most exact full size.
            var best: (service: String, width: Int?, height: Int?)?
            for case let u as String in LooseJSON.array(r["image_url"]) {
                if let i = iiif(from: u), (i.width ?? 0) >= (best?.width ?? 0) { best = i }
            }
            if best == nil, allowMaster {
                for case let u as String in LooseJSON.array(r["image_url"]) {
                    if let m = masterIIIF(from: u) { best = (m, nil, nil); break }
                }
            }
            let id = itemID(from: idURL)
            out.append(ImageCandidate(
                providerID: "loc", itemID: id, title: LooseJSON.string(r["title"]),
                creator: displayName(LooseJSON.string(r["contributor"])), date: LooseJSON.year(LooseJSON.string(r["date"])),
                width: best?.width, height: best?.height, bytes: nil, mime: "image/jpeg",
                rights: LooseJSON.string(item["rights_advisory"]) ?? LooseJSON.string(item["rights_information"]),
                pageURL: "https://www.loc.gov/item/\(id)/", imageURL: nil, hint: best?.service))
        }
        let pagination = LooseJSON.dict(root["pagination"])
        return (out, LooseJSON.string(pagination?["next"]))
    }

    /// /item/<id>/?fo=json: title, rights and the IIIF service with the master's size.
    static func parseItem(_ data: Data, id: String, allowMaster: Bool = false) throws -> ImageCandidate {
        let root = try LooseJSON.object(data)
        let item = LooseJSON.dict(root["item"]) ?? [:]
        var service: String?, width: Int?, height: Int?
        for case let res as [String: Any] in LooseJSON.array(root["resources"]) {
            for case let group as [Any] in LooseJSON.array(res["files"]) {
                for case let f as [String: Any] in group {
                    guard let u = LooseJSON.string(f["url"]) else { continue }
                    if service == nil, let i = iiif(from: u) { service = i.service }
                    let w = LooseJSON.int(f["width"]) ?? 0
                    if w > (width ?? 0) { width = w; height = LooseJSON.int(f["height"]) }
                }
            }
            if service == nil, let u = LooseJSON.string(res["image"]), let i = iiif(from: u) { service = i.service }
            if service != nil { break }
        }
        var fromMaster = false
        if service == nil, allowMaster {
            for case let res as [String: Any] in LooseJSON.array(root["resources"]) {
                for case let group as [Any] in LooseJSON.array(res["files"]) {
                    for case let f as [String: Any] in group {
                        if service == nil, let u = LooseJSON.string(f["url"]), let m = masterIIIF(from: u) { service = m }
                    }
                }
            }
            fromMaster = service != nil
        }
        let contributor = LooseJSON.string(item["contributor_names"]).map {
            // "Highsmith, Carol M., 1946-, photographer" -> "Highsmith, Carol M."
            $0.split(separator: ",").prefix(2).joined(separator: ",").trimmingCharacters(in: .whitespaces)
        }
        return ImageCandidate(providerID: "loc", itemID: id, title: LooseJSON.string(item["title"]),
                              creator: contributor, date: LooseJSON.year(LooseJSON.string(item["date"])),
                              width: service == nil || fromMaster ? nil : width,
                              height: service == nil || fromMaster ? nil : height,
                              bytes: nil, mime: "image/jpeg",
                              rights: LooseJSON.string(item["rights_advisory"]) ?? LooseJSON.string(item["rights_information"]),
                              pageURL: "https://www.loc.gov/item/\(id)/", imageURL: nil, hint: service)
    }

    static func parseInfo(_ data: Data) throws -> (width: Int, height: Int) {
        let root = try LooseJSON.object(data)
        guard let w = LooseJSON.int(root["width"]), let h = LooseJSON.int(root["height"]) else {
            throw ImageFetchError.badContent("info.json without a size")
        }
        return (w, h)
    }
}
