//
//  ArchiveClient.swift
//  Liminal
//
//  Internet Archive HTTP client (docs/plans/archive-video.md 1.1). Polite by construction: one
//  connection, requests strictly sequential with at least 2 s between them, a generic User-Agent with
//  no personal data, no downloads in Low Data Mode. No key: Prelinger items are public.
//

import Foundation

nonisolated enum ArchiveClientError: Error, CustomStringConvertible {
    case http(Int)
    case backend(String)
    case offline

    var isContentFailure: Bool {
        if case .http(let s) = self { return ArchiveCatalog.isContentFailure(status: s) }
        return false
    }

    var description: String {
        switch self {
        case .http(let s): return "HTTP \(s)"
        case .backend(let m): return "search backend: \(m)"
        case .offline: return "offline (requests disabled)"
        }
    }
}

actor ArchiveClient {
    static let userAgent = "Liminal/1.0"
    static let minInterval: TimeInterval = 2

    private let session: URLSession
    private var lastRequest: Date = .distantPast
    /// -LiminalVideoOffline: every request fails immediately with `.offline`.
    private let offline: Bool
    private(set) var requestCount = 0

    init(offline: Bool = false) {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        config.httpMaximumConnectionsPerHost = 1
        config.allowsConstrainedNetworkAccess = false   // Low Data Mode: no footage downloads
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
        self.offline = offline
    }

    /// Waits until 2 s after the previous request (requests are serialised by the actor, and every
    /// call holds its slot until it starts).
    private func pace() async throws {
        if offline { throw ArchiveClientError.offline }
        let wait = Self.minInterval - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        lastRequest = Date()
        requestCount += 1
    }

    private func checked(_ response: URLResponse) throws {
        if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw ArchiveClientError.http(h.statusCode)
        }
    }

    func search(_ query: ArchiveCatalog.Query, page: Int, rows: Int) async throws -> ArchiveSearchResponse.Body {
        try await pace()
        let (data, response) = try await session.data(from: ArchiveCatalog.searchURL(query, page: page, rows: rows))
        lastRequest = Date()
        try checked(response)
        let decoded = try JSONDecoder().decode(ArchiveSearchResponse.self, from: data)
        if let e = decoded.error { throw ArchiveClientError.backend(e) }
        guard let body = decoded.response else { throw ArchiveClientError.backend("no response body") }
        return body
    }

    func metadata(id: String) async throws -> ArchiveItemMetadata {
        try await pace()
        let (data, response) = try await session.data(from: ArchiveCatalog.metadataURL(id: id))
        lastRequest = Date()
        try checked(response)
        let m = try JSONDecoder().decode(ArchiveItemMetadata.self, from: data)
        // An unknown or withdrawn identifier answers 200 with an empty object.
        if m.is_dark == true || m.files.isEmpty { throw ArchiveClientError.http(404) }
        return m
    }

    /// Downloads to a temporary file and moves it to `destination` (replacing it).
    func download(id: String, file: String, to destination: URL) async throws {
        try await pace()
        let (tmp, response) = try await session.download(from: ArchiveCatalog.downloadURL(id: id, file: file))
        lastRequest = Date()
        try checked(response)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: destination)
    }
}
