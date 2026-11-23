import Foundation
import Synchronization

/// Speech learned from completed cue transcripts. No decoder, transcription or disk work runs on
/// the audio thread. Ahead-of-cue scanning remains disabled until cue-latency evidence is available.
nonisolated final class DialogueSalienceIndex: Sendable {
    static let scannerEnabled = false

    struct Line: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var interest: Float
        var peakWord: String
        var peakWeight: Float
        var seconds: Range<Double> { start..<end }
    }

    struct Span: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
    }

    struct Entry: Codable, Sendable, Equatable {
        var spans: [Span] = []
        var lines: [Line] = []
    }

    struct Snapshot: Codable, Sendable {
        var lexiconVersion: Int
        var entries: [String: Entry]
    }

    static let shared: DialogueSalienceIndex = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Liminal", isDirectory: true)
        return DialogueSalienceIndex(url: directory?.appendingPathComponent("DialogueSalience.json"))
    }()

    static let active: DialogueSalienceIndex = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        && !DebugLaunchOptions.isAutomated ? .shared : DialogueSalienceIndex()

    private let url: URL?
    private let entries: Mutex<[String: Entry]>
    private let pendingSave = Mutex(false)
    private static let saveQueue = DispatchQueue(label: "com.saygoodnight.Liminal.dialogueSalience", qos: .utility)

    /// Nil URL isolates tests and automated runs from the user's index.
    init(url: URL? = nil) {
        self.url = url
        var loaded: [String: Entry] = [:]
        if let url, let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.lexiconVersion == DialogueLineInterest.lexiconVersion {
            loaded = snapshot.entries
        }
        entries = Mutex(loaded)
    }

    func entry(contentID: String) -> Entry { entries.withLock { $0[contentID] ?? Entry() } }

    func unplayed(contentID: String, ledger: DialogueLineLedger, minimum: Float = 0.6) -> [Line] {
        entry(contentID: contentID).lines.filter {
            $0.interest >= minimum && ledger.lastPlay(contentID: contentID, seconds: $0.seconds) == nil
        }
    }

    func record(contentID: String, scanned: Range<Double>, lines: [Line]) {
        guard scanned.lowerBound.isFinite, scanned.upperBound.isFinite, scanned.upperBound > scanned.lowerBound else { return }
        entries.withLock { all in
            var entry = all[contentID] ?? Entry()
            let spans = (entry.spans + [Span(start: scanned.lowerBound, end: scanned.upperBound)]).sorted { $0.start < $1.start }
            entry.spans = []
            for span in spans {
                if let last = entry.spans.last, span.start <= last.end {
                    entry.spans[entry.spans.count - 1].end = max(last.end, span.end)
                } else { entry.spans.append(span) }
            }
            // Repeated or late transcripts replace overlapping candidates, retaining the better line.
            for line in lines where line.start.isFinite && line.end.isFinite && line.interest.isFinite
                && line.end > line.start && line.start >= scanned.lowerBound && line.end <= scanned.upperBound && line.interest >= 0.45 {
                if let i = entry.lines.firstIndex(where: { DialogueLineLedger.sameLine($0.seconds, line.seconds) }) {
                    if line.interest >= entry.lines[i].interest { entry.lines[i] = line }
                } else { entry.lines.append(line) }
            }
            var kept: [Line] = []
            for line in entry.lines.sorted(by: { ($0.interest, -$0.start) > ($1.interest, -$1.start) }) {
                if kept.filter({ abs($0.start - line.start) < 30 }).count < 6 { kept.append(line) }
            }
            entry.lines = kept.sorted { $0.start < $1.start }
            all[contentID] = entry
        }
        scheduleSave()
    }

    func record(source: DialogueSource, analysis: DialogueAnalysis, transcript: DialogueTranscript) {
        guard let features = analysis.features, features.frameCount > 0 else { return }
        let refined = DialogueHierarchy.refine(analysis, transcript: transcript)
        let salience = DialogueLineInterest.wordSalience(refined.words)
        let weights = salience.map(\.weight)
        let ranked = DialogueMotif.rankLines(units: refined.units, rejections: refined.rejections, rate: source.sampleRate,
                                             maximum: DialogueMotifTuning.relaxedLineSeconds.upperBound,
                                             words: refined.words, weights: weights, salience: salience)
        let lines: [Line] = ranked.compactMap { candidate in
            guard candidate.unit.text != nil, let tokens = candidate.unit.tokenRange,
                  !tokens.isEmpty, tokens.lowerBound >= 0, tokens.upperBound <= weights.count,
                  let peak = tokens.max(by: { weights[$0] < weights[$1] }) else { return nil }
            return Line(start: source.sourceSeconds(frame: candidate.unit.frames.lowerBound),
                        end: source.sourceSeconds(frame: candidate.unit.frames.upperBound), interest: candidate.interest,
                        peakWord: refined.words[peak].text, peakWeight: weights[peak])
        }
        record(contentID: source.contentID, scanned: source.sourceStart..<source.sourceSeconds(frame: features.frameCount), lines: lines)
    }

    /// Also provides a deterministic persistence barrier for tests; ordinary records coalesce below.
    func save() throws {
        guard let url else { return }
        let snapshot = entries.withLock { Snapshot(lexiconVersion: DialogueLineInterest.lexiconVersion, entries: $0) }
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func scheduleSave() {
        guard url != nil else { return }
        let pending = pendingSave.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !pending else { return }
        Self.saveQueue.asyncAfter(deadline: .now() + 1) { [self] in
            pendingSave.withLock { $0 = false }
            try? save()
        }
    }
}
