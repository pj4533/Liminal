//
//  CuratedImagePool.swift
//  Liminal
//
//  The API-mode pictures on disk (docs/plans/image-api-mode.md 5, decision D39):
//
//    Application Support/Liminal/CuratedImageStore/
//        <uuid>.jpg + <uuid>.json   an ImageStore with its own epoch key and no count cap
//        ledger.json                every candidate seen (stored or rejected), search cursors,
//                                   cached search pages, when each picture was last shown
//        tmp/                       downloads in progress
//
//  Nothing that can play is capped (A31): only past the 3 GB budget, right after a save, is the
//  least recently shown picture removed, and its ledger entry cleared so it can come back.
//  Launch cleanup removes junk only. Not an actor: a Mutex guards the in-memory state.
//

import Foundation
import Synchronization
import OSLog

nonisolated struct CuratedLedger: Codable, Sendable, Equatable {
    struct CandidateRecord: Codable, Sendable, Equatable {
        var stored: UUID?
        var rejected: String?
        var date: Date
    }
    struct ShownRecord: Codable, Sendable, Equatable {
        var lastShown: Int
        var count: Int
    }
    struct CachedList: Codable, Sendable, Equatable {
        var candidates: [ImageCandidate]
        var fetched: Date
    }

    /// Candidate key ("provider:itemID") -> what happened to it.
    var candidates: [String: CandidateRecord] = [:]
    /// "sourceID|queryKey" -> cursor of the next search page; absent = start, "" = no more pages.
    var cursors: [String: String] = [:]
    /// "sourceID|queryKey" (or "sourceID|pinned") -> candidates not yet tried.
    var lists: [String: CachedList] = [:]
    /// Picture uuid -> when it was last shown (display serial) and how often.
    var shown: [UUID: ShownRecord] = [:]
    var history = ImageRotation.DisplayHistory()

    var seenKeys: Set<String> { Set(candidates.keys) }
}

/// What the display rotation needs about one stored picture.
nonisolated struct PoolItem: Sendable, Equatable {
    let id: UUID
    let url: URL
    let sourceID: String
    let providerID: String
    let candidateKey: String
    let openness: Double
    let monochrome: Bool
    let bytes: Int64
    let createdAt: Date
}

nonisolated enum CuratedPoolPolicy {
    static let tmpMaxAge: TimeInterval = 3600

    /// Junk to delete at launch, as file names relative to the pool folder: images without a sidecar,
    /// sidecars without an image, names that are not `<UUID>.jpg|json`, and temp files older than an hour.
    static func sweep(files: [String], tmpFiles: [(name: String, modified: Date)], now: Date) -> [String] {
        var images = Set<String>(), sidecars = Set<String>()
        var junk: [String] = []
        for name in files {
            if name == "ledger.json" || name == "tmp" { continue }
            let parts = name.split(separator: ".")
            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { junk.append(name); continue }
            switch parts[1].lowercased() {
            case "jpg": images.insert(String(parts[0]))
            case "json": sidecars.insert(String(parts[0]))
            default: junk.append(name)
            }
        }
        junk += images.subtracting(sidecars).map { "\($0).jpg" }
        junk += sidecars.subtracting(images).map { "\($0).json" }
        junk += tmpFiles.filter { now.timeIntervalSince($0.modified) > tmpMaxAge }.map { "tmp/\($0.name)" }
        return junk.sorted()
    }

    /// Pictures to remove when the pool is over `budget`: least recently shown first, never-shown
    /// pictures last (oldest first among them), never `keep`.
    static func evictions(items: [PoolItem], shown: [UUID: CuratedLedger.ShownRecord], budget: Int64,
                          keep: UUID?) -> [UUID] {
        var total = items.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > budget else { return [] }
        let ordered = items.filter { $0.id != keep }.sorted { a, b in
            switch (shown[a.id]?.lastShown, shown[b.id]?.lastShown) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.createdAt < b.createdAt
            }
        }
        var out: [UUID] = []
        for item in ordered where total > budget {
            out.append(item.id)
            total -= item.bytes
        }
        return out
    }
}

nonisolated final class CuratedImagePool: Sendable {
    static let directoryName = "CuratedImageStore"
    static let verifyDirectoryName = "CuratedImageStore-Verify"
    static let epochKey = "images.api.cacheEpoch"
    static let epoch = 1

    let store: ImageStore
    private let ledgerURL: URL
    let tmpDirectory: URL

    private struct State {
        var loaded = false
        var items: [UUID: PoolItem] = [:]
        var ledger = CuratedLedger()
    }
    private let state = Mutex(State())

    /// The pool the app uses: the real folder, or the empty verify folder under -LiminalImageAPIFresh.
    static func makeDefault() -> CuratedImagePool {
        let root = ImageStore.applicationRoot
        let fm = FileManager.default
        let verify = root.appendingPathComponent(verifyDirectoryName, isDirectory: true)
        if DebugLaunchOptions.imageAPIFresh {
            try? fm.removeItem(at: verify)
            return CuratedImagePool(root: root, defaults: .standard, directoryName: verifyDirectoryName,
                                    epochKey: epochKey + ".verify")
        }
        // A verify folder left by an earlier -LiminalImageAPIFresh run is junk now.
        if fm.fileExists(atPath: verify.path) { try? fm.removeItem(at: verify) }
        return CuratedImagePool(root: root, defaults: .standard)
    }

    init(root: URL, defaults: UserDefaults, directoryName: String = CuratedImagePool.directoryName,
         epochKey: String = CuratedImagePool.epochKey) {
        store = ImageStore(root: root, defaults: defaults, directoryName: directoryName, epochKey: epochKey,
                           epoch: Self.epoch, maxImages: nil)
        ledgerURL = store.directory.appendingPathComponent("ledger.json")
        tmpDirectory = store.directory.appendingPathComponent("tmp", isDirectory: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var dir = store.directory
        try? dir.setResourceValues(excluded)
    }

    // MARK: - Loading

    /// Migrates, sweeps junk, reads the ledger and every sidecar once. Idempotent.
    func loadIfNeeded() {
        if state.withLock({ $0.loaded }) { return }
        store.migrateIfNeeded()
        sweep()
        let ledger = readLedger()
        var items: [UUID: PoolItem] = [:]
        for entry in store.entries() {
            if let item = Self.poolItem(entry) { items[item.id] = item }
        }
        state.withLock { s in
            guard !s.loaded else { return }
            s.items = items
            s.ledger = ledger
            // Pictures whose files are gone (or were evicted) can be fetched again.
            for (key, record) in s.ledger.candidates {
                if let id = record.stored, items[id] == nil { s.ledger.candidates[key] = nil }
            }
            s.ledger.shown = s.ledger.shown.filter { items[$0.key] != nil }
            s.loaded = true
        }
        LMLog.visual.info("🖼️ [API] pool: \(items.count) pictures in \(self.store.directory.lastPathComponent, privacy: .public)")
    }

    private func sweep() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: store.directory.path)) ?? []
        let tmpNames = (try? fm.contentsOfDirectory(atPath: tmpDirectory.path)) ?? []
        let tmp = tmpNames.map { name -> (name: String, modified: Date) in
            let date = (try? fm.attributesOfItem(atPath: tmpDirectory.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast
            return (name, date)
        }
        let junk = CuratedPoolPolicy.sweep(files: names, tmpFiles: tmp, now: Date())
        for name in junk { try? fm.removeItem(at: store.directory.appendingPathComponent(name)) }
        if !junk.isEmpty { LMLog.visual.info("🖼️ [API] pool sweep removed \(junk.count) junk files") }
        try? fm.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
    }

    static func poolItem(_ entry: ImageStore.Entry) -> PoolItem? {
        guard let m = entry.metadata, let credit = m.source else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: entry.imageURL.path)[.size] as? Int64) ?? 0
        let monochrome = m.openness.map { ImageOpenness.isMonochrome($0) } ?? (m.measuredSaturation < 0.025)
        return PoolItem(id: m.id, url: entry.imageURL, sourceID: credit.sourceID, providerID: credit.providerID,
                        candidateKey: credit.candidateKey, openness: m.openness?.openness ?? 0.5,
                        monochrome: monochrome, bytes: bytes, createdAt: m.createdAt)
    }

    // MARK: - Ledger

    private func readLedger() -> CuratedLedger {
        guard let data = try? Data(contentsOf: ledgerURL) else { return CuratedLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CuratedLedger.self, from: data)) ?? CuratedLedger()
    }

    /// Writes the ledger (small; called after each ingest and each picture shown).
    private func persist(_ ledger: CuratedLedger) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? data.write(to: ledgerURL, options: .atomic)
    }

    private func mutateLedger(_ body: (inout CuratedLedger) -> Void) {
        let snapshot = state.withLock { s -> CuratedLedger in
            body(&s.ledger)
            return s.ledger
        }
        persist(snapshot)
    }

    var ledger: CuratedLedger { state.withLock { $0.ledger } }
    var seenKeys: Set<String> { state.withLock { $0.ledger.seenKeys } }

    func recordRejected(_ key: String, reason: String) {
        mutateLedger { $0.candidates[key] = .init(stored: nil, rejected: reason, date: Date()) }
    }

    /// Forgets a candidate (a transient failure: try it again later).
    func forget(_ key: String) {
        mutateLedger { $0.candidates[key] = nil }
    }

    func cursor(_ listKey: String) -> String?? {
        state.withLock { s in s.ledger.cursors[listKey].map { Optional($0) } }
    }

    func setCursor(_ listKey: String, _ next: String?) {
        mutateLedger { $0.cursors[listKey] = next ?? "" }
    }

    func list(_ key: String) -> CuratedLedger.CachedList? { state.withLock { $0.ledger.lists[key] } }

    func setList(_ key: String, _ candidates: [ImageCandidate]) {
        mutateLedger { $0.lists[key] = .init(candidates: candidates, fetched: Date()) }
    }

    /// Restart a source's searches from the first page (its cached pages have expired).
    func resetSearches(sourceID: String) {
        mutateLedger { l in
            for key in l.cursors.keys where key.hasPrefix(sourceID + "|") { l.cursors[key] = nil }
            for key in l.lists.keys where key.hasPrefix(sourceID + "|") { l.lists[key] = nil }
        }
    }

    // MARK: - Pictures

    var count: Int { state.withLock { $0.items.count } }
    var items: [PoolItem] { state.withLock { Array($0.items.values) } }

    /// Never-shown pictures waiting in the pool.
    var unseenCount: Int {
        state.withLock { s in s.items.keys.filter { s.ledger.shown[$0] == nil }.count }
    }

    func usage() -> ImageStore.Usage {
        state.withLock { s in ImageStore.Usage(imageCount: s.items.count, bytes: s.items.values.reduce(0) { $0 + $1.bytes }) }
    }

    /// Saves a new picture and applies the budget. Returns the ids evicted to make room.
    @discardableResult
    func add(jpeg: Data, metadata: ImageMetadata, budget: Int64) throws -> [UUID] {
        let clear = store.clearGeneration
        let entry = try store.save(jpeg: jpeg, metadata: metadata, clearGeneration: clear)
        guard let item = Self.poolItem(entry) else { return [] }
        let (evict, snapshot) = state.withLock { s -> ([UUID], CuratedLedger) in
            s.items[item.id] = item
            s.ledger.candidates[item.candidateKey] = .init(stored: item.id, rejected: nil, date: Date())
            let evict = CuratedPoolPolicy.evictions(items: Array(s.items.values), shown: s.ledger.shown,
                                                    budget: budget, keep: item.id)
            for id in evict {
                if let gone = s.items.removeValue(forKey: id) { s.ledger.candidates[gone.candidateKey] = nil }
                s.ledger.shown[id] = nil
            }
            return (evict, s.ledger)
        }
        for id in evict { store.remove(id: id) }
        persist(snapshot)
        if !evict.isEmpty { LMLog.visual.info("🖼️ [API] pool over budget: removed \(evict.count) least recently shown") }
        return evict
    }

    /// Inputs of the display rotation, restricted to `sources` (id -> weight).
    func displayItems(sourceWeights: [String: Double]) -> (items: [ImageRotation.DisplayItem], history: ImageRotation.DisplayHistory) {
        state.withLock { s in
            let list = s.items.values.compactMap { item -> ImageRotation.DisplayItem? in
                guard let w = sourceWeights[item.sourceID] else { return nil }
                return ImageRotation.DisplayItem(id: item.id, sourceID: item.sourceID, sourceWeight: w,
                                                 openness: item.openness, monochrome: item.monochrome,
                                                 lastShown: s.ledger.shown[item.id]?.lastShown)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            return (list, s.ledger.history)
        }
    }

    func item(_ id: UUID) -> PoolItem? { state.withLock { $0.items[id] } }

    /// Records that a picture became the one on screen.
    func markShown(_ id: UUID) {
        guard let item = item(id) else { return }
        mutateLedger { l in
            l.history.record(sourceID: item.sourceID, monochrome: item.monochrome)
            let count = (l.shown[id]?.count ?? 0) + 1
            l.shown[id] = .init(lastShown: l.history.serial, count: count)
        }
    }

    /// Deletes every picture and the ledger ("Clear images" in API mode).
    @discardableResult
    func clear() -> ImageStore.Usage {
        let removed = usage()
        store.clearEverything()
        state.withLock { s in
            s.items = [:]
            s.ledger = CuratedLedger()
        }
        try? FileManager.default.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
        return removed
    }

    /// Bytes free on the pool's volume (nil when unknown).
    func freeBytes() -> Int64? {
        let values = try? store.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
