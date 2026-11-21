//
//  DialogueLineLedger.swift
//  Liminal
//
//  Every dialogue line the Lo-Fi motif has led a loop with, per film, in film seconds, kept on disk
//  across sessions (docs/decisions/music.md D123). The motif never takes a line that overlaps one
//  already played; only when every usable line of the cue's film and of the recent films has been
//  played does it go back, to the line played longest ago. Read while planning (off the audio
//  thread), written when a plan is committed.
//

import Foundation
import Synchronization

nonisolated final class DialogueLineLedger: Sendable {
    struct Play: Codable, Sendable, Equatable {
        /// Film seconds of the line.
        var start: Double
        var end: Double
        var count: Int
        /// Seconds since 1970 of the latest play.
        var last: Double
    }

    /// A played line overlapping a candidate by more than this share of the shorter one counts as the same line.
    static let sameLineOverlap = 0.5

    /// The app's ledger, in Application Support/Liminal/DialogueLines.json.
    static let shared: DialogueLineLedger = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Liminal", isDirectory: true)
        return DialogueLineLedger(url: dir?.appendingPathComponent("DialogueLines.json"))
    }()

    private let url: URL?
    private let plays: Mutex<[String: [Play]]>
    private let pendingSave = Mutex(false)
    private static let saveQueue = DispatchQueue(label: "com.saygoodnight.Liminal.dialogueLedger", qos: .utility)

    /// `url` nil keeps the ledger in memory only (tests, offline renders).
    init(url: URL? = nil) {
        self.url = url
        var loaded: [String: [Play]] = [:]
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [Play]].self, from: data) {
            loaded = decoded
        }
        plays = Mutex(loaded)
    }

    /// The latest play of a line overlapping `seconds` in `contentID`, nil when it was never played.
    func lastPlay(contentID: String, seconds: Range<Double>) -> Play? {
        plays.withLock { all in
            (all[contentID] ?? []).filter { Self.sameLine($0.start..<$0.end, seconds) }.max { $0.last < $1.last }
        }
    }

    func playedLines(contentID: String) -> Int { plays.withLock { $0[contentID]?.count ?? 0 } }

    var totalPlays: Int { plays.withLock { $0.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } } }

    func record(contentID: String, seconds: Range<Double>, at date: Date = Date()) {
        guard seconds.upperBound > seconds.lowerBound else { return }
        plays.withLock { all in
            var list = all[contentID] ?? []
            if let i = list.firstIndex(where: { Self.sameLine($0.start..<$0.end, seconds) }) {
                list[i].count += 1
                list[i].last = date.timeIntervalSince1970
            } else {
                list.append(Play(start: seconds.lowerBound, end: seconds.upperBound, count: 1, last: date.timeIntervalSince1970))
            }
            all[contentID] = list
        }
        scheduleSave()
    }

    /// Forgets every play (Reset All Settings does not call this; nothing in the UI does today).
    func removeAll() {
        plays.withLock { $0.removeAll() }
        scheduleSave()
    }

    static func sameLine(_ a: Range<Double>, _ b: Range<Double>) -> Bool {
        let overlap = min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound)
        let shorter = min(a.upperBound - a.lowerBound, b.upperBound - b.lowerBound)
        return shorter > 0 && overlap / shorter > sameLineOverlap
    }

    /// Coalesced write on a utility queue: one save per burst of records.
    private func scheduleSave() {
        guard let url else { return }
        let alreadyPending = pendingSave.withLock { pending -> Bool in
            defer { pending = true }
            return pending
        }
        guard !alreadyPending else { return }
        Self.saveQueue.asyncAfter(deadline: .now() + 1) { [self] in
            pendingSave.withLock { $0 = false }
            let snapshot = plays.withLock { $0 }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
