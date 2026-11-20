import Testing
import Foundation
@testable import Liminal

/// Footage cache cleanup (docs/decisions/archive-video.md A31): the launch sweep of files the index does
/// not list and of stale temporary files. Nothing indexed, and so nothing that can play, is removed.
struct ArchiveCacheSweepTests {
    static func clip(_ id: String, mb: Int64, used: Double? = nil, count: Int = 0) -> ArchiveClip {
        ArchiveCachePolicyTests.clip(id, mb: mb, used: used, count: count)
    }

    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("liminal-cache-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func touch(_ url: URL, bytes: Int = 1, age: TimeInterval = 0) throws {
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    // MARK: Launch sweep

    @Test func loadSweepsUnindexedFilesAndKeepsEveryIndexedClip() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pins = ArchiveSeedList.pinned.map(\.id)
        // Indexed clips stay whatever their size (a 1.38 GB pinned film included).
        let indexed = [Self.clip(pins[0], mb: 300, count: 4), Self.clip(pins[1], mb: 1381, count: 4),
                       Self.clip("discovery", mb: 50)]
        for clip in indexed { try Self.touch(dir.appendingPathComponent(clip.fileName)) }
        try JSONEncoder().encode(ArchiveClipStore.Index(clips: indexed)).write(to: dir.appendingPathComponent("index.json"))
        let orphans = ["old-build-name.mp4", "unlisted.mp4", ".DS_Store"]
        for name in orphans { try Self.touch(dir.appendingPathComponent(name), bytes: 64) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Self.touch(dir.appendingPathComponent("tmp/partial.mp4"))

        let store = ArchiveClipStore(directory: dir)
        await store.load()
        #expect(Set(await store.clips.map(\.id)) == Set(indexed.map(\.id)))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == Set(["index.json"] + indexed.map(\.fileName)))
    }

    @Test func addReplacesAnUnindexedFileOfTheSameName() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveClipStore(directory: dir)
        await store.load()
        // Written after load (as by a crash between the move and the index write in an older build).
        try Self.touch(dir.appendingPathComponent("x.mp4"), bytes: 64)
        let staged = dir.appendingPathComponent("incoming.mp4")
        try Data([7]).write(to: staged)
        try await store.add(Self.clip("x", mb: 1), from: staged, protected: [])
        #expect(try Data(contentsOf: dir.appendingPathComponent("x.mp4")) == Data([7]))
    }

    @Test func orphansAreEverythingTheIndexDoesNotList() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["index.json", "kept.mp4", "orphan.mp4"] { try Self.touch(dir.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("stray"), withIntermediateDirectories: true)
        let found = ArchiveDiskSweep.orphans(in: dir, indexed: ["kept.mp4"]).map(\.lastPathComponent)
        #expect(Set(found) == ["orphan.mp4", "stray"])
    }

    @Test func staleTemporaryItemsAreOldDownloadsAndFixturesOnly() throws {
        let tmp = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.touch(tmp.appendingPathComponent("CFNetworkDownload_old.tmp"), bytes: 1000, age: 3600)
        try Self.touch(tmp.appendingPathComponent("CFNetworkDownload_live.tmp"), age: 30)
        try Self.touch(tmp.appendingPathComponent("liminal-360.jpg"), age: 86_400)
        try Self.touch(tmp.appendingPathComponent("liminal-lofi-fixture.jpg"), age: 120)
        try Self.touch(tmp.appendingPathComponent("someone-else.tmp"), age: 86_400)
        let fixtures = tmp.appendingPathComponent("liminal-rotation-check.5TP2f1")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try Self.touch(fixtures.appendingPathComponent("a.jpg"), bytes: 500)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: fixtures.path)

        let stale = Set(ArchiveDiskSweep.staleTemporaryItems(in: tmp).map(\.lastPathComponent))
        #expect(stale == ["CFNetworkDownload_old.tmp", "liminal-360.jpg", "liminal-rotation-check.5TP2f1"])

        ArchiveDiskSweep.sweepTemporaryDirectory(tmp)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        #expect(left == ["CFNetworkDownload_live.tmp", "liminal-lofi-fixture.jpg", "someone-else.tmp"])
    }

    @Test func removeReportsLogicalBytes() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.bin")
        try Self.touch(file, bytes: 1234)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Self.touch(sub.appendingPathComponent("g.bin"), bytes: 766)
        let result = ArchiveDiskSweep.remove([file, sub, dir.appendingPathComponent("missing")])
        #expect(result.count == 2)
        #expect(result.bytes == 2000)
    }
}
