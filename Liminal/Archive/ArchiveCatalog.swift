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
        /// Weight of this route's films when the next discovery is drawn from the accumulated bag
        /// (separate from `weight`, which picks the route to search).
        var candidateWeight: Float = 1
        /// Routes built around what the user enjoys most (A32). Their route weights are held at a clear
        /// majority of searches (unit-tested).
        var isInterest: Bool = false

        var excludedTerms: [String] {
            guard name == "drug-education" else { return ArchiveCatalog.exclusions }
            return ArchiveCatalog.exclusions.filter { !ArchiveCatalog.drugEducationExceptions.contains($0) }
        }
    }

    /// Weighted queries (plan 1.2). Only the Prelinger collection: its items carry a public-domain
    /// licence and the collection states no restrictions on reuse (A1).
    static let queries: [Query] = [
        Query(name: "newsreel",
              text: "collection:prelinger AND (newsreel OR \"news magazine\" OR telenews OR \"screen magazine\")",
              weight: 3, allowsColour: false),
        Query(name: "trippy",
              text: #"collection:prelinger AND (psychedelic OR psychedelia OR kaleidoscope OR surreal OR hypnosis OR "light show" OR "optical illusion" OR "abstract film" OR "experimental film" OR "dream sequence")"#,
              weight: 10, allowsColour: true, candidateWeight: 5),
        Query(name: "drug-education",
              text: #"collection:prelinger AND (title:("drug abuse" OR "drug addiction" OR "drug education" OR narcotics OR marijuana OR marihuana OR LSD OR hallucinogens) OR subject:("drug abuse" OR "drug addiction" OR "drug education" OR "drug prevention" OR marijuana OR LSD))"#,
              weight: 5, allowsColour: true, candidateWeight: 5),
        Query(name: "educational",
              text: "collection:prelinger AND subject:(animation OR cartoon OR \"visual effects\" OR psychology OR science OR future)",
              weight: 2, allowsColour: false),
        Query(name: "spaceage",
              text: "collection:prelinger AND (rocket OR satellite OR \"outer space\" OR computer OR electronic OR television)",
              weight: 2, allowsColour: true),
        // color:"B&W" (quoted): the unquoted form makes the search backend fail.
        Query(name: "bw", text: "collection:prelinger AND color:\"B&W\"", weight: 1, allowsColour: false),
        // Interest routes (docs/decisions/archive-video.md A32): 34 of 57 route weight (60% of searches),
        // candidate weight 5 like trippy, the full exclusions with no exceptions, colour at `colourOdds`.
        Query(name: "machines",
              text: #"collection:prelinger AND (computer OR cybernetics OR "magnetic tape" OR "data processing" OR "electronic brain" OR "analog computer")"#,
              weight: 9, allowsColour: true, candidateWeight: 5, isInterest: true),
        Query(name: "perception",
              text: #"collection:prelinger AND (perception OR "optical illusion" OR consciousness)"#,
              weight: 7, allowsColour: true, candidateWeight: 5, isInterest: true),
        Query(name: "recording",
              text: #"collection:prelinger AND ("sound recording" OR phonograph OR jukebox OR "magnetic recording" OR "radio broadcasting" OR "record player")"#,
              weight: 9, allowsColour: true, candidateWeight: 5, isInterest: true),
        Query(name: "ecosystems",
              text: #"collection:prelinger AND (microscope OR pond OR astronomy OR microscopy OR "plant growth" OR "time lapse" OR "water surface")"#,
              weight: 5, allowsColour: true, candidateWeight: 5, isInterest: true),
        Query(name: "nightcity",
              text: #"collection:prelinger AND ("city lights" OR subway OR "elevated railway" OR "urban transportation" OR "neon sign")"#,
              weight: 4, allowsColour: true, candidateWeight: 5, isInterest: true),
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
        "dew line", "turmoil", "medical", "medicine", "quack", "quacks", "patient",
    ]

    static let drugEducationExceptions: Set<String> = ["drug", "narcotic", "alcohol"]

    /// The query sent to advancedsearch.php: the curated clause, movies, 1950-1969, minus exclusions.
    static func fullQuery(_ q: Query) -> String {
        let terms = q.excludedTerms.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " OR ")
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
    static func isExcluded(_ text: String, query: Query? = nil) -> Bool {
        let words = " " + text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") + " "
        return (query?.excludedTerms ?? exclusions).contains { words.contains(" \($0) ") }
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
        if isExcluded(doc.titleText, query: query) { return false }
        if tone(doc.color?.value) == .colour && !query.allowsColour { return false }
        return true
    }

    /// Metadata-level acceptance: the exclusion terms over title, description and subject.
    static func accept(_ info: ArchiveItemInfo?, query: Query) -> Bool {
        guard let info else { return true }
        let text = [info.title?.joined, info.description?.joined, info.subject?.joined].compactMap { $0 }.joined(separator: " ")
        // Descriptions hold HTML; tags split into words harmlessly.
        return !isExcluded(text, query: query)
    }

    // MARK: - Files

    static let playableFormats: Set<String> = ["h.264", "h.264 ia", "512kb mpeg4", "mpeg4"]
    static let preferredMaxBytes: Int64 = 80 * 1_000_000
    static let minBytes: Int64 = 2 * 1_000_000
    static let minimumDuration: Double = 25

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

    /// Prefer a modest main encode or a smaller derivative. Longer films can be
    /// trimmed after downloading, so their size and runtime do not disqualify them.
    static func pickFile(_ files: [ArchiveFile], preferSmallest: Bool) -> ArchiveFile? {
        let ok = playableFiles(files).filter { f in
            guard let b = f.bytes, b >= minBytes else { return false }
            if let d = parseDuration(f.length?.value) { return d >= minimumDuration }
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

    /// Pick a start separated from previous excerpts when space allows.
    /// For crowded or short films, pick the point furthest from any previous start.
    static func segmentStart(duration: Double, length: Double, avoid: [Double], separation: Double = 20,
                             preferInterior: Bool = true, rng: inout MusicRNG) -> Double {
        let last = max(0, duration - length)
        guard last > 0 else { return 0 }
        let margin = min(0.2 * duration, 60)
        let interior = preferInterior && last > 2 * margin ? margin...(last - margin) : 0...last
        let shown = avoid.sorted()

        var ranges = freshRanges(in: interior, shown: shown, separation: separation)
        if ranges.isEmpty, interior.lowerBound > 0 {
            ranges = freshRanges(in: 0...last, shown: shown, separation: separation)
        }
        if !ranges.isEmpty {
            let weights = ranges.map { Float($0.upperBound - $0.lowerBound) }
            return rng.range(ranges[rng.weighted(weights)])
        }

        // The maximum distance from prior starts is at a boundary or halfway between two starts.
        let edges = [0.0, last].map { edge in (start: edge, gap: shown.map { abs($0 - edge) }.min() ?? 0) }
        let midpoints = zip(shown, shown.dropFirst()).compactMap { left, right -> (start: Double, gap: Double)? in
            let start = (left + right) / 2
            return (0...last).contains(start) ? (start, (right - left) / 2) : nil
        }
        return (edges + midpoints).max { $0.gap < $1.gap }?.start ?? 0
    }

    /// Once a film has filled its start range, release the oldest exclusions first.
    /// Keep the newest exclusion for a short film so the distance fallback still applies.
    static func protectedStarts(in bounds: ClosedRange<Double>, shown: [Double], separation: Double) -> [Double] {
        guard !shown.isEmpty else { return [] }
        var low = 0
        var high = shown.count - 1
        while low < high {
            let middle = (low + high) / 2
            if freshRanges(in: bounds, shown: shown[middle...].sorted(), separation: separation).isEmpty {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return Array(shown[low...])
    }

    static func freshRanges(in bounds: ClosedRange<Double>, shown: [Double],
                                    separation: Double) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var cursor = bounds.lowerBound
        for previous in shown {
            let end = min(previous - separation, bounds.upperBound)
            if cursor < end { ranges.append(cursor...end) }
            cursor = max(cursor, previous + separation)
            if cursor >= bounds.upperBound { break }
        }
        if cursor < bounds.upperBound { ranges.append(cursor...bounds.upperBound) }
        return ranges
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

    mutating func next(rng: inout MusicRNG, excluding: Set<T> = [], weight: ((T) -> Float)? = nil) -> T? {
        let usable = items.filter { !excluding.contains($0) }
        guard !usable.isEmpty else { return nil }
        if remaining.allSatisfy({ excluding.contains($0) }) { remaining = usable }
        let pool = remaining.enumerated().filter { !excluding.contains($0.element) }
        let index = weight.map { weigh in rng.weighted(pool.map { weigh($0.element) }) }
            ?? rng.int(0...(pool.count - 1))
        let pick = pool[index]
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
        /// A vetted encode when the Archive's smallest listed MP4 is mislabeled.
        var preferredFile: String? = nil
    }
    let seeds: [Seed]

    /// Curated Internet Archive titles. See docs/experience.md for sources and credits.
    static let pinned: [Seed] = [
        Seed(id: "aapb-cpb-aacip-514-n00zp3ws90", title: "The World of LSD", year: 1967,
             query: "drug-education", color: false, preferredFile: "cpb-aacip-514-n00zp3ws90_The World of LSD.ia.mp4"),
        Seed(id: "VAM026", title: "History of Marijuana Legislation, Part One", year: 1967,
             query: "drug-education", color: true),
        Seed(id: "gov.archives.arc.13260", title: "The Mind-Benders: LSD and the Hallucinogens", year: 1970,
             query: "drug-education", color: true),
        Seed(id: "alan-watts-the-flow-of-zen", title: "The Flow of Zen by Alan Watts", year: 1969,
             query: "trippy", color: false),
        Seed(id: "342-usaf-42990", title: "UFO Interview", year: 1966,
             query: "trippy", color: false),
        Seed(id: "Timothy_Leary_Archives_198", title: "A Conversation on LSD", year: 1979,
             query: "drug-education", color: true),
        Seed(id: "Ergotthestoryofaparasiticfungus-wellcome", title: "Ergot: The Story of a Parasitic Fungus", year: 1958,
             query: "trippy", color: false),
        Seed(id: "Designfo1956", title: "Design for Dreaming", year: 1956,
             query: "trippy", color: true),
        Seed(id: "horizons-of-science-thinking-machines", title: "Horizons of Science: Thinking Machines", year: 1959,
             query: "spaceage", color: true),
        Seed(id: "sailfilm_hear", title: "Hear Here", year: 1969,
             query: "spaceage", color: true),
        // Interest pins (A32), each reviewed on 2026-11-23. The main 640x480 encode, not the 320x240 derivative.
        Seed(id: "LivingSt1958", title: "Living Stereo", year: 1958,
             query: "recording", color: true, preferredFile: "LivingSt1958.mp4"),
        Seed(id: "SoundAndTheS", title: "Sound And The Story", year: 1956,
             query: "recording", color: true, preferredFile: "SoundAndTheS.mp4"),
        Seed(id: "SpringCo1952", title: "Spring Comes to a Pond", year: 1952,
             query: "ecosystems", color: true, preferredFile: "SpringCo1952.mp4"),
    ]
    static let pinnedIDs = Set(pinned.map(\.id))

    /// Titles removed from rotation, including known Archive uploads of the same films.
    static let retiredIDs: Set<String> = [
        "Narcotic1967_2", "Narcotics_Pit_of_Despair", "0785_Narcotics_Pit_of_Despair_06_06_30_08",
        "DrugAbus1969", "0052DrugAbuseTheChemicalTomb", "DrugAddi1951",
        "lsdthespringgroveexperiment", "lsdthespringgroveexperimentreel1", "lsdthespringgroveexperimentreel1_202605"
    ]

    static func bundled() -> [Seed] {
        guard let url = Bundle.main.url(forResource: "archive-seeds", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ArchiveSeedList.self, from: data) else { return [] }
        return list.seeds
    }
}
