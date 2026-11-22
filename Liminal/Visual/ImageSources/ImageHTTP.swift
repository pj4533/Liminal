//
//  ImageHTTP.swift
//  Liminal
//
//  The one HTTPS client of the curated feed (docs/plans/image-api-mode.md 3.1). Polite by construction,
//  like ArchiveClient: a generic User-Agent with no personal data, no URL cache, no downloads in
//  Low Data Mode, and a minimum gap per host (5 s for the Met, whose bot wall trips after about 100
//  quick requests). Only awaited from the feed's detached ingest task, never from a render path.
//

import Foundation

nonisolated enum ImageFetchError: Error, Equatable, CustomStringConvertible {
    case offline
    case http(Int)
    /// A bot wall or captcha page (HTML where JSON or an image was expected).
    case blocked
    case tooLarge(Int)
    case badContent(String)
    case insecureURL

    /// A failure of this one item (the provider itself is fine).
    var isItemFailure: Bool {
        switch self {
        case .http(let s): return [401, 403, 404, 410, 451].contains(s)
        case .tooLarge, .badContent, .insecureURL: return true
        case .offline, .blocked: return false
        }
    }

    var description: String {
        switch self {
        case .offline: return "offline"
        case .http(let s): return "HTTP \(s)"
        case .blocked: return "blocked (bot wall)"
        case .tooLarge(let b): return "too large (\(b) bytes)"
        case .badContent(let m): return "bad content: \(m)"
        case .insecureURL: return "not an https URL"
        }
    }
}

actor ImageHTTP {
    private let session: URLSession
    private let offline: Bool
    private let hostGaps: [String: Double]
    private let defaultGap: Double
    private var lastRequest: [String: Date] = [:]
    private(set) var requestCount = 0

    init(userAgent: String, offline: Bool, hostGaps: [String: Double], defaultGap: Double) {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.httpMaximumConnectionsPerHost = 1
        config.allowsConstrainedNetworkAccess = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
        self.offline = offline
        self.hostGaps = hostGaps
        self.defaultGap = defaultGap
    }

    /// Only https URLs are fetched (the app has no ATS exceptions). NASA's http links are upgraded.
    static func secure(_ string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        guard let url = URL(string: s), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private func pace(_ url: URL) async throws {
        if offline { throw ImageFetchError.offline }
        guard url.scheme == "https" else { throw ImageFetchError.insecureURL }
        let host = url.host ?? ""
        let gap = hostGaps[host] ?? defaultGap
        if let last = lastRequest[host] {
            let wait = gap - Date().timeIntervalSince(last)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        lastRequest[host] = Date()
        requestCount += 1
    }

    static func check(_ response: URLResponse, expectingHTML: Bool = false) throws {
        guard let h = response as? HTTPURLResponse else { return }
        let type = (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !(200..<300).contains(h.statusCode) {
            // The Met's Incapsula wall answers 403 with an HTML page.
            if (h.statusCode == 403 || h.statusCode == 429) && type.contains("text/html") { throw ImageFetchError.blocked }
            throw ImageFetchError.http(h.statusCode)
        }
        if !expectingHTML && type.contains("text/html") { throw ImageFetchError.blocked }
    }

    /// GET returning the body (JSON APIs).
    func data(_ url: URL) async throws -> Data {
        try await pace(url)
        do {
            let (data, response) = try await session.data(from: url)
            lastRequest[url.host ?? ""] = Date()
            try Self.check(response)
            return data
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                    || error.code == .dataNotAllowed || error.code == .cannotFindHost {
            throw ImageFetchError.offline
        }
    }

    /// HEAD returning Content-Length, nil when the server does not say.
    func contentLength(_ url: URL) async throws -> Int? {
        try await pace(url)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
        let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) }
        return length
    }

    /// Downloads to `destination` (a temp file is moved there). Refuses more than `maxBytes`.
    func download(_ url: URL, to destination: URL, maxBytes: Int) async throws {
        try await pace(url)
        let tmp: URL, response: URLResponse
        do {
            (tmp, response) = try await session.download(from: url)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                    || error.code == .dataNotAllowed || error.code == .cannotFindHost {
            throw ImageFetchError.offline
        }
        lastRequest[url.host ?? ""] = Date()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tmp) }
        try Self.check(response)
        let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        if size > maxBytes { throw ImageFetchError.tooLarge(size) }
        if size == 0 { throw ImageFetchError.badContent("empty body") }
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: destination)
    }
}
