//
//  ArchiveClipStore.swift
//  Liminal
//
//  Disk cache of downloaded footage (docs/plans/archive-video.md 1.4): films and excerpts in
//  Application Support/Liminal/ArchiveFootage/ with an index.json. Holds the pinned titles and
//  two discoveries, within a 3 GB budget.
//

import AVFoundation
import CoreGraphics
import Foundation

/// One cached clip.
nonisolated struct ArchiveClip: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let year: Int?
    let fileName: String
    let bytes: Int64
    let duration: Double
    let width: Int
    let height: Int
    let hasAudio: Bool
    /// Luma black / white points (5th / 95th percentile over 8 frames), 0...1. Old prints are often
    /// washed out; the frame pre-pass stretches these to 0...1.
    let black: Float
    let white: Float
    let isColour: Bool
    let licence: String?
    let added: Date
    var lastUsed: Date?
    var useCount: Int
    /// Segment starts already shown (seconds), so revisits pick new footage.
    var shownStarts: [Double]

    var recency: Date { lastUsed ?? added }
}

/// Pure eviction rules (unit-tested).
nonisolated enum ArchiveCachePolicy {
    static let capBytes: Int64 = 3_000_000_000
    static let discoverySlots = 2
    static let discoveryPlayLimit = 2
    static var poolTarget: Int { ArchiveSeedList.pinned.count + discoverySlots }
    static let minReady = 3
    /// No downloads when the volume has less than this free.
    static let minFreeBytes: Int64 = 2_000_000_000

    static func isFreshDiscovery(_ clip: ArchiveClip) -> Bool {
        !ArchiveSeedList.pinnedIDs.contains(clip.id) && clip.useCount < discoveryPlayLimit
    }

    static func excessDiscoveries(_ clips: [ArchiveClip]) -> [String] {
        let discoveries = clips.filter { !ArchiveSeedList.pinnedIDs.contains($0.id) }
        let order = discoveries.sorted {
            if $0.useCount != $1.useCount { return $0.useCount < $1.useCount }
            return $0.recency > $1.recency
        }
        return order.dropFirst(discoverySlots).map(\.id)
    }

    /// Clips to delete so that `incoming` more bytes fit under `capBytes` and the pool stays at most
    /// `maxClips` (counting the incoming clip). Least recently used first; never a protected clip and
    /// never fewer than `minKeep` clips left (counting the incoming clip).
    static func victims(_ clips: [ArchiveClip], incoming: Int64 = 0, capBytes: Int64 = capBytes,
                        maxClips: Int = poolTarget, minKeep: Int = minReady,
                        protected: Set<String> = []) -> [String] {
        var total = clips.reduce(Int64(0)) { $0 + $1.bytes } + incoming
        var count = clips.count + (incoming > 0 ? 1 : 0)
        var out: [String] = []
        let keep = protected.union(ArchiveSeedList.pinnedIDs)
        let order = clips.filter { !keep.contains($0.id) }.sorted { $0.recency < $1.recency }
        for c in order {
            guard total > capBytes || count > maxClips else { break }
            guard clips.count - out.count + (incoming > 0 ? 1 : 0) > minKeep else { break }
            out.append(c.id)
            total -= c.bytes
            count -= 1
        }
        return out
    }

    /// Replace a discovery after two excerpts, once its outgoing crossfade is complete.
    static func replacement(_ clips: [ArchiveClip], protected: Set<String> = []) -> String? {
        let keep = protected.union(ArchiveSeedList.pinnedIDs)
        return clips.filter { !keep.contains($0.id) && $0.useCount >= discoveryPlayLimit }
            .max { ($0.useCount, $1.recency) < ($1.useCount, $0.recency) }?.id
    }
}

actor ArchiveClipStore {
    struct Index: Codable {
        var clips: [ArchiveClip] = []
        /// Items that failed for content reasons (HTTP 4xx, no video track, excluded words): never retried.
        var bad: [String] = []
        var filePolicyVersion: Int? = 2
        var recentDiscoveries: [String]?
    }

    let directory: URL
    private var index = Index()
    private var loaded = false

    init(directory: URL) { self.directory = directory }

    /// `Application Support/Liminal/ArchiveFootage/`, excluded from backup.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Liminal/ArchiveFootage", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    var tmpDirectory: URL { directory.appendingPathComponent("tmp", isDirectory: true) }

    func load() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
        try? fm.removeItem(at: tmpDirectory)
        if let data = try? Data(contentsOf: indexURL), let i = try? JSONDecoder().decode(Index.self, from: data) {
            index = i
        }
        // Older indexes did not distinguish oversized films from unavailable items.
        if index.filePolicyVersion != 2 {
            index.bad.removeAll()
            index.filePolicyVersion = 2
            save()
        }
        // Remove retired titles and entries whose files are gone.
        let before = index.clips.count
        index.clips.removeAll { clip in
            let file = url(for: clip)
            if ArchiveSeedList.retiredIDs.contains(clip.id) {
                try? fm.removeItem(at: file)
                return true
            }
            return !fm.fileExists(atPath: file.path)
        }
        for id in ArchiveCachePolicy.excessDiscoveries(index.clips) { remove(id, rememberDiscovery: true) }
        if index.clips.count != before { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func url(for clip: ArchiveClip) -> URL { directory.appendingPathComponent(clip.fileName) }
    nonisolated func fileURL(for clip: ArchiveClip) -> URL { directory.appendingPathComponent(clip.fileName) }

    var clips: [ArchiveClip] { index.clips }
    var badIDs: Set<String> { Set(index.bad) }
    var recentDiscoveryIDs: Set<String> { Set(index.recentDiscoveries ?? []) }
    var totalBytes: Int64 { index.clips.reduce(0) { $0 + $1.bytes } }

    func contains(_ id: String) -> Bool { index.clips.contains { $0.id == id } }

    func markBad(_ id: String) {
        guard !index.bad.contains(id) else { return }
        index.bad.append(id)
        save()
    }

    enum AddFailure: Error { case insufficientCacheSpace }

    /// Moves a validated file into the store before removing its victims.
    @discardableResult
    func add(_ clip: ArchiveClip, from file: URL, protected: Set<String>) throws -> [String] {
        let addingDiscovery = !ArchiveSeedList.pinnedIDs.contains(clip.id)
        let slotsFull = index.clips.filter { !ArchiveSeedList.pinnedIDs.contains($0.id) }.count >= ArchiveCachePolicy.discoverySlots
        let replacement = addingDiscovery && slotsFull ? ArchiveCachePolicy.replacement(index.clips, protected: protected) : nil
        if addingDiscovery && slotsFull && replacement == nil { throw AddFailure.insufficientCacheSpace }
        let remaining = index.clips.filter { $0.id != replacement }
        let evict = ArchiveCachePolicy.victims(remaining, incoming: clip.bytes, protected: protected)
        let retained = remaining.filter { !evict.contains($0.id) }
        guard retained.count < ArchiveCachePolicy.poolTarget,
              retained.reduce(clip.bytes, { $0 + $1.bytes }) <= ArchiveCachePolicy.capBytes else {
            throw AddFailure.insufficientCacheSpace
        }
        let dest = directory.appendingPathComponent(clip.fileName)
        try FileManager.default.moveItem(at: file, to: dest)
        let victims = [replacement].compactMap { $0 } + evict
        for id in victims { remove(id, rememberDiscovery: true) }
        index.clips.append(clip)
        save()
        return victims
    }

    func remove(_ id: String, rememberDiscovery: Bool = false) {
        guard let c = index.clips.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(for: c))
        index.clips.removeAll { $0.id == id }
        if rememberDiscovery {
            index.recentDiscoveries = Array(((index.recentDiscoveries ?? []) + [id]).suffix(24))
        }
        save()
    }

    func markUsed(_ id: String, segmentStart: Double, at date: Date = Date()) {
        guard let i = index.clips.firstIndex(where: { $0.id == id }) else { return }
        index.clips[i].lastUsed = date
        index.clips[i].useCount += 1
        index.clips[i].shownStarts.append(segmentStart)
        save()
    }

    /// Deletes every cached clip (the bad list is kept), except `keeping` (the clips on screen).
    func clear(keeping: Set<String> = []) {
        for c in index.clips where !keeping.contains(c.id) { try? FileManager.default.removeItem(at: url(for: c)) }
        index.clips.removeAll { !keeping.contains($0.id) }
        save()
    }
}

// MARK: - Validation

/// Checks a downloaded file off the main actor (plan 1.3 step 4): a decodable video track at least
/// 240 px high, the real duration, audio presence, and the luma levels.
nonisolated enum ArchiveClipValidator {
    struct Result: Sendable {
        let duration: Double
        let width: Int
        let height: Int
        let hasAudio: Bool
        let black: Float
        let white: Float
    }

    enum Failure: Error { case noVideo, tooSmall, tooShort, undecodable }

    static func validate(_ url: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= ArchiveCatalog.minimumDuration else { throw Failure.tooShort }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let size = try await video.load(.naturalSize).applying(try await video.load(.preferredTransform))
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
        guard h >= 200 else { throw Failure.tooSmall }   // 512kb derivatives are 320x240 (some 320x232)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let (black, white) = try await levels(asset, duration: duration)
        return Result(duration: duration, width: w, height: h, hasAudio: hasAudio, black: black, white: white)
    }

    /// Keep an interior excerpt without re-encoding the picture or soundtrack.
    static func exportExcerpt(from source: URL, to destination: URL, sourceBytes: Int64,
                              seed: UInt64) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 60 else { return false }
        let fraction = Double(80_000_000) / Double(sourceBytes)
        let length = min(240, max(30, duration * fraction))
        guard length < duration,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        var rng = MusicRNG(seed: seed)
        let start = ArchiveCatalog.segmentStart(duration: duration, length: length, avoid: [], rng: &rng)
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        try await export.export(to: destination, as: .mp4)
        return true
    }

    /// 5th / 95th luma percentiles over 8 small frames spread across the clip.
    static func levels(_ asset: AVURLAsset, duration: Double) async throws -> (Float, Float) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: 160, height: 160)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        var hist = [Int](repeating: 0, count: 256)
        var frames = 0
        for k in 0..<8 {
            let t = CMTime(seconds: duration * (0.1 + 0.8 * Double(k) / 7), preferredTimescale: 600)
            guard let img = try? await gen.image(at: t).image else { continue }
            frames += 1
            lumaHistogram(img, into: &hist)
        }
        guard frames > 0 else { throw Failure.undecodable }
        let total = hist.reduce(0, +)
        func pct(_ p: Double) -> Float {
            var acc = 0
            for (i, n) in hist.enumerated() {
                acc += n
                if Double(acc) >= p * Double(total) { return Float(i) / 255 }
            }
            return 1
        }
        var b = pct(0.05), w = pct(0.95)
        if w - b < 0.25 { let m = (w + b) / 2; b = max(0, m - 0.125); w = min(1, m + 0.125) }   // flat frames: mild stretch only
        return (b, w)
    }

    static func lumaHistogram(_ img: CGImage, into hist: inout [Int]) {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 6 % inset: film borders and burnt-in edges are not picture.
        let ix = w * 6 / 100, iy = h * 6 / 100
        for y in iy..<(h - iy) { for x in ix..<(w - ix) { hist[Int(px[y * w + x])] += 1 } }
    }
}
