//
//  ImageStore.swift
//  Liminal
//
//  A folder of pictures on disk, the backing store of CuratedImagePool:
//
//    Application Support/Liminal/<directoryName>/
//        <uuid>.jpg             the picture
//        <uuid>.json            ImageMetadata sidecar
//
//  ARCHITECTURE NOTE: Not an actor and not MainActor (the 90fps visionOS render
//  loop starves MainActor). A lock guards the in-memory counters; FileManager
//  is thread-safe.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.lock
import OSLog

extension Notification.Name {
    /// Posted once after every picture (files, buffers, ledger) has been removed.
    static let imageCacheCleared = Notification.Name("imageCacheCleared")
}

nonisolated final class ImageStore: @unchecked Sendable {

    struct Entry: Sendable, Equatable {
        let id: UUID
        let imageURL: URL
        let metadata: ImageMetadata?
    }

    struct Usage: Sendable, Equatable {
        let imageCount: Int
        let bytes: Int64
    }

    enum StoreError: LocalizedError {
        case staleClearGeneration
        var errorDescription: String? { "The picture was fetched before the pictures were cleared" }
    }

    let root: URL                     // .../Liminal
    let directory: URL                // .../Liminal/<directoryName>
    private let lock = OSAllocatedUnfairLock()
    nonisolated(unsafe) private var _clearGeneration: UInt64 = 0

    static var applicationRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Liminal", isDirectory: true)
    }

    /// Injectable for tests (temporary directory).
    init(root: URL, directoryName: String) {
        self.root = root
        self.directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Clear generation

    /// Increments on every clear. A save carrying an older value is refused, so a
    /// picture that was in flight when the user tapped Clear never reappears.
    var clearGeneration: UInt64 {
        lock.withLock { _clearGeneration }
    }

    // MARK: - Listing and loading

    /// Newest first. Reads sidecars only; decodes no pixels.
    func entries() -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [(Entry, Date)] = []
        for url in files {
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "png",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let sidecar = directory.appendingPathComponent("\(id.uuidString).json")
            let metadata = (try? Data(contentsOf: sidecar)).flatMap { try? decoder.decode(ImageMetadata.self, from: $0) }
            let date = metadata?.createdAt
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            result.append((Entry(id: id, imageURL: url, metadata: metadata), date))
        }
        return result.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Entry for one id, reading only its sidecar.
    func entry(id: UUID, url: URL) -> Entry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = (try? Data(contentsOf: sidecarURL(id))).flatMap { try? decoder.decode(ImageMetadata.self, from: $0) }
        return Entry(id: id, imageURL: url, metadata: metadata)
    }

    func loadImage(_ entry: Entry) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(entry.imageURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - Saving

    /// Saves a picture's JPEG bytes with their sidecar.
    @discardableResult
    func save(jpeg: Data, metadata: ImageMetadata, clearGeneration: UInt64) throws -> Entry {
        guard clearGeneration == self.clearGeneration else { throw StoreError.staleClearGeneration }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("\(metadata.id.uuidString).jpg")
        try jpeg.write(to: imageURL, options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: sidecarURL(metadata.id), options: .atomic)
        if clearGeneration != self.clearGeneration {
            removeFiles(for: metadata.id)
            throw StoreError.staleClearGeneration
        }
        return Entry(id: metadata.id, imageURL: imageURL, metadata: metadata)
    }

    /// Removes one picture with its sidecar.
    func remove(id: UUID) {
        removeFiles(for: id)
    }

    // MARK: - Usage and clearing

    /// Picture count and total bytes on disk.
    func usage() -> Usage {
        let fm = FileManager.default
        var count = 0
        var bytes: Int64 = 0
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                bytes += Int64(values?.fileSize ?? 0)
                let ext = url.pathExtension.lowercased()
                if ext == "jpg" || ext == "png" { count += 1 }
            }
        }
        return Usage(imageCount: count, bytes: bytes)
    }

    /// Deletes every picture and sidecar, as a whole directory. Increments clearGeneration first.
    /// Returns what was removed.
    @discardableResult
    func clearEverything() -> Usage {
        lock.withLock { _clearGeneration &+= 1 }
        let removed = usage()
        removeAllFiles()
        LMLog.visual.info("🗑️ [ImageStore] cleared \(removed.imageCount) pictures (\(removed.bytes) bytes)")
        return removed
    }

    // MARK: - Private

    private func sidecarURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func removeAllFiles() {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            do { try fm.removeItem(at: directory) } catch {
                LMLog.visual.error("🗑️ [ImageStore] could not remove \(self.directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeFiles(for id: UUID) {
        let fm = FileManager.default
        for name in ["\(id.uuidString).jpg", "\(id.uuidString).png", "\(id.uuidString).json"] {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func encodeJPEG(_ image: CGImage, quality: Double = 0.92) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
