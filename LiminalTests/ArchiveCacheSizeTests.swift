import Testing
import Foundation
@testable import Liminal

/// Footage cache size limits (docs/decisions/archive-video.md A31): the per-clip cap on file choice, the
/// total budget with pinned clips included, and the launch sweep of unindexed and stale temporary files.
struct ArchiveCacheSizeTests {
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

    // MARK: Per-clip cap

    @Test func capIsAReasonableShareOfTheBudget() {
        #expect(ArchiveCachePolicy.maxClipBytes == 600_000_000)
        #expect(ArchiveCachePolicy.maxClipBytes * 5 <= ArchiveCachePolicy.capBytes)
    }

    @Test func pickFilePrefersASmallerDerivativeUnderTheCap() {
        // VAM026-like: a 1080p main encode far over the cap and an SD derivative under it.
        let files = [ArchiveFile(name: "Film.mp4", format: "h.264", size: "1380509459", length: "1908"),
                     ArchiveFile(name: "Film.ia.mp4", format: "h.264 IA", size: "240000000", length: "1908")]
        #expect(ArchiveCatalog.pickFile(files, preferSmallest: false)?.name == "Film.ia.mp4")
        #expect(ArchiveCatalog.pickFile(files, preferSmallest: true)?.name == "Film.ia.mp4")
    }

    @Test func pickFileSkipsATitleThatOnlyExistsOverTheCap() {
        let files = [ArchiveFile(name: "Big.mp4", format: "h.264", size: "1380509459", length: "1908"),
                     ArchiveFile(name: "Big_512kb.mp4", format: "512Kb MPEG4", size: "700000000", length: "1908")]
        #expect(ArchiveCatalog.pickFile(files, preferSmallest: true) == nil)
        #expect(ArchiveCatalog.pickFile(files, preferSmallest: false) == nil)
        #expect(ArchiveCatalog.smallestPlayableBytes(files) == 700_000_000)
        // Exactly at the cap is allowed; a smaller cap can be passed explicitly.
        let edge = [ArchiveFile(name: "Edge.mp4", format: "h.264", size: "600000000", length: "900")]
        #expect(ArchiveCatalog.pickFile(edge, preferSmallest: true)?.name == "Edge.mp4")
        #expect(ArchiveCatalog.pickFile(edge, preferSmallest: true, maxBytes: 500_000_000) == nil)
    }

    @Test func storeRefusesAClipOverTheCap() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveClipStore(directory: dir)
        await store.load()
        let staged = dir.appendingPathComponent("incoming.mp4")
        try Data([1]).write(to: staged)
        await #expect(throws: ArchiveClipStore.AddFailure.clipTooLarge) {
            try await store.add(Self.clip("huge", mb: 601), from: staged, protected: [])
        }
        #expect(await store.clips.isEmpty)
    }

    // MARK: Budget including pinned clips

    @Test func budgetCountsPinnedClips() throws {
        let pins = ArchiveSeedList.pinned.map(\.id)
        try #require(pins.count >= 4)
        // Four pinned clips of 300 MB against a 1 GB budget: the three most used stay.
        let clips = [Self.clip(pins[0], mb: 300, count: 9), Self.clip(pins[1], mb: 300, count: 1),
                     Self.clip(pins[2], mb: 300, count: 5), Self.clip(pins[3], mb: 300, count: 7)]
        #expect(ArchiveCachePolicy.overBudget(clips, capBytes: 1_000_000_000) == [pins[1]])
        // Under the budget: nothing goes.
        #expect(ArchiveCachePolicy.overBudget(clips, capBytes: 1_200_000_000).isEmpty)
    }

    @Test func pinnedOutrankDiscoveriesAndSmallerClipsStillFit() throws {
        let pins = ArchiveSeedList.pinned.map(\.id)
        let clips = [Self.clip("discovery", mb: 100, used: 9000), Self.clip(pins[0], mb: 500, count: 3),
                     Self.clip(pins[1], mb: 400, count: 2), Self.clip(pins[2], mb: 50, count: 1)]
        // 500 + 400 fit in 1 GB; the 50 MB pinned clip still fits after that; the discovery does not.
        #expect(ArchiveCachePolicy.overBudget(clips, capBytes: 1_000_000_000) == ["discovery"])
    }

    @Test func oversizedClipsGoEvenWhenTheBudgetHasRoom() throws {
        let pin = try #require(ArchiveSeedList.pinned.first?.id)
        let clips = [Self.clip(pin, mb: 1381, count: 20), Self.clip("small", mb: 50)]
        #expect(ArchiveCachePolicy.overBudget(clips) == [pin])
        // A clip on screen is kept whatever its size.
        #expect(ArchiveCachePolicy.overBudget(clips, protected: [pin]).isEmpty)
    }

    // MARK: Launch sweep

    @Test func loadSweepsUnindexedFilesAndDropsOversizedPins() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pins = ArchiveSeedList.pinned.map(\.id)
        let indexed = [Self.clip(pins[0], mb: 300, count: 4), Self.clip(pins[1], mb: 1381, count: 4),
                       Self.clip("discovery", mb: 50)]
        for clip in indexed { try Self.touch(dir.appendingPathComponent(clip.fileName)) }
        try JSONEncoder().encode(ArchiveClipStore.Index(clips: indexed)).write(to: dir.appendingPathComponent("index.json"))
        let orphans = ["VAM026.mp4", "old-build-name.mp4", ".DS_Store"]
        for name in orphans { try Self.touch(dir.appendingPathComponent(name), bytes: 64) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Self.touch(dir.appendingPathComponent("tmp/partial.mp4"))

        let store = ArchiveClipStore(directory: dir)
        await store.load()
        #expect(Set(await store.clips.map(\.id)) == [pins[0], "discovery"])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["index.json", "\(pins[0]).mp4", "discovery.mp4"])

        // The index on disk agrees, so a second launch finds nothing more to do.
        let again = ArchiveClipStore(directory: dir)
        await again.load()
        #expect(Set(await again.clips.map(\.id)) == [pins[0], "discovery"])
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
