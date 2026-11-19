//
//  ArchiveClient.swift
//  Liminal
//
//  Internet Archive HTTP client (docs/plans/archive-video.md 1.1). Polite by construction: one
//  connection, requests strictly sequential with at least 2 s between them, a generic User-Agent with
//  no personal data, no downloads in Low Data Mode. No key: Prelinger items are public.
//

import Foundation
import Synchronization

nonisolated enum ArchiveClientError: Error, CustomStringConvertible {
    case http(Int)
    case backend(String)
    case offline
    /// The response's Content-Length, or the bytes received so far, exceed the per-clip cap.
    case tooLarge(Int64)

    var isContentFailure: Bool {
        if case .http(let s) = self { return ArchiveCatalog.isContentFailure(status: s) }
        return false
    }

    var description: String {
        switch self {
        case .http(let s): return "HTTP \(s)"
        case .backend(let m): return "search backend: \(m)"
        case .offline: return "offline (requests disabled)"
        case .tooLarge(let b): return String(format: "larger than the %.0f MB clip cap (%.0f MB)",
                                             Double(ArchiveCachePolicy.maxClipBytes) / 1e6, Double(b) / 1e6)
        }
    }
}

actor ArchiveClient {
    static let userAgent = "Liminal/1.0"
    static let minInterval: TimeInterval = 2

    private let configuration: URLSessionConfiguration
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
        configuration = config
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

    /// Downloads to `destination` (replacing it). The transfer is cancelled as soon as the response's
    /// Content-Length or the bytes received exceed `maxBytes` (`ArchiveClientError.tooLarge`), so a
    /// mislabelled or oversized file never fills the disk.
    func download(id: String, file: String, to destination: URL,
                  maxBytes: Int64 = ArchiveCachePolicy.maxClipBytes) async throws {
        try await pace()
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { lastRequest = Date() }
        try await CappedDownload.run(ArchiveCatalog.downloadURL(id: id, file: file), configuration: configuration,
                                     maxBytes: maxBytes, to: destination)
    }
}

/// One download task with a size cap. The async `URLSession.download` cannot be stopped part way on size,
/// and when the process dies mid-transfer its `CFNetworkDownload_*.tmp` is left in `tmp/`
/// (`ArchiveDiskSweep` removes those at launch). The finished file is moved out of CFNetwork's temporary
/// location inside the delegate callback, as the system deletes it when the callback returns.
nonisolated final class CappedDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var failure: Error?
    }

    private let maxBytes: Int64
    private let destination: URL
    private let state = Mutex(State())

    private init(maxBytes: Int64, destination: URL) {
        self.maxBytes = maxBytes
        self.destination = destination
    }

    static func run(_ url: URL, configuration: URLSessionConfiguration, maxBytes: Int64, to destination: URL) async throws {
        let delegate = CappedDownload(maxBytes: maxBytes, destination: destination)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.state.withLock { $0.continuation = c }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func fail(_ error: Error) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        guard max(expected, totalBytesWritten) > maxBytes else { return }
        fail(ArchiveClientError.tooLarge(max(expected, totalBytesWritten)))
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let h = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            fail(ArchiveClientError.http(h.statusCode))
            return
        }
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: location.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size <= maxBytes else { fail(ArchiveClientError.tooLarge(size)); return }
        do {
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            fail(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure) = state.withLock { s in
            defer { s.continuation = nil }
            return (s.continuation, s.failure)
        }
        if let failure = failure ?? error {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
