//
//  ArchiveCatalog.swift
//  Liminal
//
//  Pure logic for choosing Internet Archive footage (docs/plans/archive-video.md 1.2-1.4): the curated
//  Prelinger queries, the exclusion filter, the playable-file pick, duration parsing, segment maths
//  and a shuffle bag. File pick, duration parse and safe random start are ported from LostArchiveTV
//  (ArchiveService.findPlayableFiles / estimateDuration, VideoLoadingService). No I/O here.
//  scripts/archive-curate.py mirrors the queries and the exclusions (keep them in step).
//

import Foundation

nonisolated enum ArchiveCatalog {

    // MARK: - Queries

    struct Query: Sendable, Equatable {
        let name: String
        let text: String
        let weight: Float
        /// Colour items are allowed from this query (at `colourOdds`); otherwise black and white only.
        let allowsColour: Bool
    }

    /// Weighted queries (plan 1.2). Only the Prelinger collection: its items carry a public-domain
    /// licence and the collection states no restrictions on reuse (A1).
    static let queries: [Query] = [
        Query(name: "newsreel",
              text: "collection:prelinger AND (newsreel OR \"news magazine\" OR telenews OR \"screen magazine\")",
              weight: 3, allowsColour: false),
        Query(name: "trippy",
              text: "collection:prelinger AND (abstract OR experimental OR kaleidoscope OR optical OR hypnosis OR dream OR surreal)",
              weight: 3, allowsColour: true),
        Query(name: "educational",
              text: "collection:prelinger AND subject:(animation OR cartoon OR \"visual effects\" OR psychology OR science OR future)",
              weight: 2, allowsColour: false),
        Query(name: "spaceage",
              text: "collection:prelinger AND (rocket OR satellite OR \"outer space\" OR computer OR electronic OR television)",
              weight: 2, allowsColour: true),
        // color:"B&W" (quoted): the unquoted form makes the search backend fail.
        Query(name: "bw", text: "collection:prelinger AND color:\"B&W\"", weight: 1, allowsColour: false),
    ]

    /// Odds that a colour item from a colour-allowing query is accepted (plan 1.2, tune).
    static let colourOdds: Float = 0.2
    static let years = 1950...1969

    /// Terms excluded in the query and again on title + description + subject (plan 1.2, extended
    /// after the first curation pass: politics, crime, bodies, the military).
    static let exclusions: [String] = [
        "war", "bomb", "casualty", "casualties", "surgery", "operation", "disease", "nazi", "hitler",
        "execution", "biological", "venereal", "accident", "crash", "autopsy", "civil defense",
        "propaganda", "korea", "vietnam", "fallout", "radiation", "germ", "hygiene", "birth", "death",
        "funeral", "fire", "riot", "flicker", "strobe", "murder", "kidnapping", "revolt", "strike",
        "hospital", "mental", "police", "crime", "protest", "ammunition", "atom", "atomic", "nuclear",
        "gun", "prison", "drug", "narcotic", "alcohol", "seale", "panther", "puberty", "adolescence", "sex",
        "larynx", "campaign", "debate", "nixon", "nixons", "eisenhower", "kennedy", "candidacy", "miss america",
        "dew line", "turmoil",
    ]

    /// The query sent to advancedsearch.php: the curated clause, movies, 1950-1969, minus exclusions.
    static func fullQuery(_ q: Query) -> String {
        let terms = exclusions.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " OR ")
        return "(\(q.text)) AND mediatype:movies AND year:[\(years.lowerBound) TO \(years.upperBound)] AND NOT (\(terms))"
    }

    static let searchFields = ["identifier", "title", "year", "sound", "color", "licenseurl", "runtime"]

    static func searchURL(_ q: Query, page: Int, rows: Int) -> URL {
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        var items = [URLQueryItem(name: "q", value: fullQuery(q))]
        items += searchFields.map { URLQueryItem(name: "fl[]", value: $0) }
        items += [URLQueryItem(name: "rows", value: String(rows)),
                  URLQueryItem(name: "page", value: String(max(page, 1))),
                  URLQueryItem(name: "output", value: "json")]
        // Strict encoding (URLComponents leaves "&", "+" and "=" alone in some positions).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        c.percentEncodedQuery = items.map { "\(enc($0.name))=\(enc($0.value ?? ""))" }.joined(separator: "&")
        return c.url!
    }

    static func metadataURL(id: String) -> URL {
        URL(string: "https://archive.org/metadata/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!
    }

    static func downloadURL(id: String, file: String) -> URL {
        let i = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let f = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return URL(string: "https://archive.org/download/\(i)/\(f)")!
    }

    /// Pages to pick from for a query with `numFound` hits at `rows` per page.
    static func pageCount(numFound: Int, rows: Int) -> Int { max(1, (numFound + rows - 1) / max(rows, 1)) }

    // MARK: - Filters

    /// Whole-word (or whole-phrase) match of any exclusion term, case-insensitive.
    static func isExcluded(_ text: String) -> Bool {
        let words = " " + text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") + " "
        return exclusions.contains { words.contains(" \($0) ") }
    }

    enum Tone: Sendable, Equatable { case blackAndWhite, colour, unknown }

    /// Archive colour fields are spelt many ways: "B&W", "b&w", "b/w", "B&W (tinted)", "C", "color", "Color".
    static func tone(_ field: String?) -> Tone {
        guard let raw = field?.lowercased().replacingOccurrences(of: " ", with: ""), !raw.isEmpty else { return .unknown }
        if raw.contains("b&w") || raw.contains("b/w") || raw == "bw" || raw.contains("black") { return .blackAndWhite }
        if raw == "c" || raw.hasPrefix("col") { return .colour }
        return .unknown
    }

    /// Search-level acceptance (before the colour coin flip): years, title exclusion, colour rule.
    static func accept(_ doc: ArchiveSearchDoc, query: Query) -> Bool {
        guard let y = doc.yearValue, years.contains(y) else { return false }
        if isExcluded(doc.titleText) { return false }
        if tone(doc.color?.value) == .colour && !query.allowsColour { return false }
        return true
    }

    /// Metadata-level acceptance: the exclusion terms over title, description and subject.
    static func accept(_ info: ArchiveItemInfo?) -> Bool {
        guard let info else { return true }
        let text = [info.title?.joined, info.description?.joined, info.subject?.joined].compactMap { $0 }.joined(separator: " ")
        // Descriptions hold HTML; tags split into words harmlessly.
        return !isExcluded(text)
    }

    // MARK: - Files

    static let playableFormats: Set<String> = ["h.264", "h.264 ia", "512kb mpeg4", "mpeg4"]
    static let maxBytes: Int64 = 120 * 1_000_000
    static let preferredMaxBytes: Int64 = 80 * 1_000_000
    static let minBytes: Int64 = 2 * 1_000_000
    static let durationRange: ClosedRange<Double> = 25...1500

    /// mp4 files in a playable format (LostArchiveTV findPlayableFiles, minus edit masters).
    static func playableFiles(_ files: [ArchiveFile]) -> [ArchiveFile] {
        files.filter { f in
            let name = f.name.lowercased()
            guard name.hasSuffix(".mp4"), !name.hasSuffix("_edit.mp4") else { return false }
            return f.format.map { playableFormats.contains($0.lowercased()) } ?? false
        }
    }

    static func is512kb(_ f: ArchiveFile) -> Bool {
        f.name.lowercased().hasSuffix("_512kb.mp4") || f.format?.lowercased() == "512kb mpeg4"
    }

    /// The file to download (plan 1.3): the main h.264 file when it is at most 80 MB, else the
    /// `_512kb.mp4`; nothing over 120 MB or outside 25 s...25 min. `preferSmallest` (fewer than two clips
    /// ready) takes the smallest acceptable file for a fast first start.
    static func pickFile(_ files: [ArchiveFile], preferSmallest: Bool) -> ArchiveFile? {
        let ok = playableFiles(files).filter { f in
            guard let b = f.bytes, b >= minBytes, b <= maxBytes else { return false }
            if let d = parseDuration(f.length?.value) { return durationRange.contains(d) }
            return true
        }
        guard !ok.isEmpty else { return nil }
        if preferSmallest { return ok.min { ($0.bytes ?? 0) < ($1.bytes ?? 0) } }
        let main = ok.filter { !is512kb($0) && ($0.bytes ?? .max) <= preferredMaxBytes }
        if let best = main.max(by: { ($0.bytes ?? 0) < ($1.bytes ?? 0) }) { return best }
        return ok.filter(is512kb).max { ($0.bytes ?? 0) < ($1.bytes ?? 0) } ?? ok.min { ($0.bytes ?? 0) < ($1.bytes ?? 0) }
    }

    /// Seconds from an Archive `length` ("1724.14", "10:40", "0:10:40"). Nil if unparseable or <= 0
    /// (LostArchiveTV's estimateDuration, without its 30-minute default).
    static func parseDuration(_ s: String?) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = Double(s) { return d > 0 ? d : nil }
        let parts = s.split(separator: ":").map { Double($0) }
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let v = parts.reduce(0.0) { $0 * 60 + $1! }
        return v > 0 ? v : nil
    }

    // MARK: - Segments

    /// Start of a `length`-second segment of a `duration`-second clip (plan 1.4). LostArchiveTV's safe
    /// random start: a margin of min(0.2 d, 60) s at both ends (title cards, end slates), re-rolled up to
    /// four times to stay 20 s away from segments already shown. A clip too short for the request starts at 0.
    static func segmentStart(duration: Double, length: Double, avoid: [Double], rng: inout MusicRNG) -> Double {
        guard duration > length else { return 0 }
        let margin = min(0.2 * duration, 60)
        var lo = margin, hi = duration - margin - length
        if hi < lo { lo = 0; hi = duration - length }
        var best = lo + (hi - lo) * rng.unitD()
        var bestGap = avoid.map { abs($0 - best) }.min() ?? .infinity
        var tries = 0
        while bestGap < 20, tries < 4 {
            tries += 1
            let c = lo + (hi - lo) * rng.unitD()
            let gap = avoid.map { abs($0 - c) }.min() ?? .infinity
            if gap > bestGap { best = c; bestGap = gap }
        }
        return best
    }

    // MARK: - Failures

    /// HTTP statuses that mean the item itself is unusable (bad list), as opposed to a network problem
    /// (back off and retry). LostArchiveTV's isContentFailure, for status codes.
    static func isContentFailure(status: Int) -> Bool { [401, 403, 404, 410, 451].contains(status) }

    /// Back-off after network failures (plan 1.4): 1, 2, 5, 15, 30 min.
    static func backoff(failures: Int) -> TimeInterval {
        let steps: [TimeInterval] = [60, 120, 300, 900, 1800]
        return steps[min(max(failures - 1, 0), steps.count - 1)]
    }
}

/// Draws without repeats until every item has been drawn once, then reshuffles (plan 1.3).
nonisolated struct ShuffleBag<T: Hashable> {
    private(set) var items: [T]
    private var remaining: [T] = []

    init(_ items: [T]) { self.items = Array(Set(items)).sorted { "\($0)" < "\($1)" } }

    var isEmpty: Bool { items.isEmpty }

    func hasAny(excluding: Set<T>) -> Bool { items.contains { !excluding.contains($0) } }

    mutating func next(rng: inout MusicRNG, excluding: Set<T> = []) -> T? {
        let usable = items.filter { !excluding.contains($0) }
        guard !usable.isEmpty else { return nil }
        if remaining.allSatisfy({ excluding.contains($0) }) { remaining = usable }
        let pool = remaining.enumerated().filter { !excluding.contains($0.element) }
        let pick = pool[rng.int(0...(pool.count - 1))]
        remaining.remove(at: pick.offset)
        return pick.element
    }
}

/// Bundled seed list (scripts/archive-curate.py): used when search fails and on a first launch.
nonisolated struct ArchiveSeedList: Decodable, Sendable {
    struct Seed: Decodable, Sendable, Equatable {
        let id: String
        let title: String
        let year: Int
        let query: String
        let color: Bool
    }
    let seeds: [Seed]

    static func bundled() -> [Seed] {
        guard let url = Bundle.main.url(forResource: "archive-seeds", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ArchiveSeedList.self, from: data) else { return [] }
        return list.seeds
    }
}
