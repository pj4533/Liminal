//
//  ImageStore.swift
//  Liminal
//
//  Persistent image cache (replaces ImageCache). docs/decisions/images.md D13-D15.
//
//    Application Support/Liminal/ImageStore/
//        <uuid>.jpg | .png      original bytes from the model (after border trim if trimmed)
//        <uuid>.json            ImageMetadata sidecar
//        <uuid>.depth.png       optional depth map
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
    /// Posted once after every image (files, buffers, history) has been removed.
    static let imageCacheCleared = Notification.Name("imageCacheCleared")
}

nonisolated final class ImageStore: @unchecked Sendable {

    static let shared = ImageStore()

    /// Bump to purge every device's cache on its next launch. 2 = first 3:2 / Gemini 3.1 release,
    /// which removes the old square images from before prompt version 2.
    static let cacheEpoch = 2
    static let epochDefaultsKey = "images.cacheEpoch"
    /// Oldest images beyond this are deleted on save.
    static let maxImages = 400

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
        var errorDescription: String? { "Image belongs to a generation started before Clear All Images" }
    }

    let root: URL                     // .../Liminal
    let directory: URL                // .../Liminal/ImageStore
    private let legacyDirectories: [URL]
    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock()
    nonisolated(unsafe) private var _clearGeneration: UInt64 = 0

    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(root: appSupport.appendingPathComponent("Liminal", isDirectory: true), defaults: .standard)
    }

    /// Injectable for tests (temporary directory, private defaults suite).
    init(root: URL, defaults: UserDefaults) {
        self.root = root
        self.directory = root.appendingPathComponent("ImageStore", isDirectory: true)
        self.legacyDirectories = [
            root.appendingPathComponent("RawImages", isDirectory: true),
            root.appendingPathComponent("UpscaledImages", isDirectory: true),
        ]
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Clear generation

    /// Increments on every clear. A save carrying an older value is refused, so an
    /// image that was in flight when the user tapped Clear never reappears.
    var clearGeneration: UInt64 {
        lock.withLock { _clearGeneration }
    }

    // MARK: - Migration

    /// Runs once at launch before anything is loaded. A lower or missing stored epoch
    /// deletes ImageStore/ and the legacy RawImages/ and UpscaledImages/ directories.
    func migrateIfNeeded() {
        let stored = defaults.integer(forKey: Self.epochDefaultsKey)   // 0 when missing
        guard stored < Self.cacheEpoch else { return }
        LMLog.visual.info("🗄️ [ImageStore] cache epoch \(stored) < \(Self.cacheEpoch): purging all cached images")
        removeAllFiles()
        defaults.set(Self.cacheEpoch, forKey: Self.epochDefaultsKey)
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
            guard ext == "jpg" || ext == "png", !url.lastPathComponent.contains(".depth."),
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let sidecar = directory.appendingPathComponent("\(id.uuidString).json")
            let metadata = (try? Data(contentsOf: sidecar)).flatMap { try? decoder.decode(ImageMetadata.self, from: $0) }
            let date = metadata?.createdAt
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            result.append((Entry(id: id, imageURL: url, metadata: metadata), date))
        }
        return result.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Cheap listing for the recycler: ids and file URLs, no sidecars, no pixels.
    func imageFiles() -> [(id: UUID, url: URL)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "png", !url.lastPathComponent.contains(".depth."),
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return (id, url)
        }
    }

    func imageCount() -> Int { imageFiles().count }

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

    /// Writes the bytes (re-encoded only if the border trimmer cropped the image) and the sidecar.
    @discardableResult
    func save(_ image: GeneratedImageData, metadata: ImageMetadata, trimmed: CGImage? = nil,
              clearGeneration: UInt64) throws -> Entry {
        guard clearGeneration == self.clearGeneration else { throw StoreError.staleClearGeneration }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var bytes = image.data
        var ext = image.mimeType.contains("png") ? "png" : "jpg"
        if let trimmed, let encoded = Self.encodeJPEG(trimmed) {
            bytes = encoded
            ext = "jpg"
        }
        let imageURL = directory.appendingPathComponent("\(metadata.id.uuidString).\(ext)")
        try bytes.write(to: imageURL, options: .atomic)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: sidecarURL(metadata.id), options: .atomic)

        // A clear may have happened while writing: undo so nothing stale survives.
        if clearGeneration != self.clearGeneration {
            removeFiles(for: metadata.id)
            throw StoreError.staleClearGeneration
        }
        evictBeyondCap()
        return Entry(id: metadata.id, imageURL: imageURL, metadata: metadata)
    }

    // MARK: - Depth (slot for the dome view; see docs/decisions/images.md)

    func saveDepth(_ depth: CGImage, for id: UUID) {
        let url = directory.appendingPathComponent("\(id.uuidString).depth.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, depth, nil)
        CGImageDestinationFinalize(dest)
    }

    func loadDepth(for id: UUID) -> CGImage? {
        let url = directory.appendingPathComponent("\(id.uuidString).depth.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Usage and clearing

    /// Image count and total bytes on disk (current store plus any legacy directories).
    func usage() -> Usage {
        let fm = FileManager.default
        var count = 0
        var bytes: Int64 = 0
        for dir in [directory] + legacyDirectories {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                bytes += Int64(values?.fileSize ?? 0)
                let ext = url.pathExtension.lowercased()
                if (ext == "jpg" || ext == "png") && !url.lastPathComponent.contains(".depth.") { count += 1 }
            }
        }
        return Usage(imageCount: count, bytes: bytes)
    }

    /// Deletes every cached image, sidecar and depth map, plus the legacy directories,
    /// as whole directories. Increments clearGeneration first. Returns what was removed.
    @discardableResult
    func clearEverything() -> Usage {
        lock.withLock { _clearGeneration &+= 1 }
        let removed = usage()
        removeAllFiles()
        LMLog.visual.info("🗑️ [ImageStore] cleared \(removed.imageCount) images (\(removed.bytes) bytes)")
        return removed
    }

    // MARK: - Private

    private func sidecarURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func removeAllFiles() {
        let fm = FileManager.default
        for dir in [directory] + legacyDirectories where fm.fileExists(atPath: dir.path) {
            do { try fm.removeItem(at: dir) } catch {
                LMLog.visual.error("🗑️ [ImageStore] could not remove \(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeFiles(for id: UUID) {
        let fm = FileManager.default
        for name in ["\(id.uuidString).jpg", "\(id.uuidString).png", "\(id.uuidString).json", "\(id.uuidString).depth.png"] {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func evictBeyondCap() {
        let all = entries()
        guard all.count > Self.maxImages else { return }
        for entry in all.dropFirst(Self.maxImages) {
            removeFiles(for: entry.id)
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
