import Testing
import Foundation
import CoreGraphics
@testable import Liminal

/// Archive footage pure logic (docs/plans/archive-video.md 7): queries, filters, file pick, durations,
/// segments, the shuffle bag, the cache policy, the moment director and the composite uniforms.
struct ArchiveCatalogTests {

    // A trimmed advancedsearch.php response (scripts/archive-curate.py --save-raw), with the loose field
    // types the Archive really returns: year as number and as string, colour spelt three ways, a list title.
    static let searchJSON = """
    {"responseHeader":{"status":0},"response":{"numFound":131,"start":0,"docs":[
     {"color":"B&W","identifier":"HowtoGoP1954","licenseurl":"http://creativecommons.org/licenses/publicdomain/","runtime":"10:40","sound":"Sd","title":"How to Go Places","year":1954},
     {"color":"C","identifier":"YoungMan1952","runtime":"14:19","sound":"Sd","title":"Young Man's Fancy (Part I)","year":"1952"},
     {"color":"b&w","identifier":"Eisenhow1952","sound":"sound","title":["[Eisenhower Campaign Spots, 1952 Presidential Campaign]"],"year":"1952"},
     {"identifier":"Late1975","title":"A Later Film","year":1975},
     {"color":"color","identifier":"Countdow1960","title":"[Countdown Leader: Technicolor Corporation]","year":["1960"]}
    ]}}
    """

    @Test func decodesLooseSearchFields() throws {
        let r = try JSONDecoder().decode(ArchiveSearchResponse.self, from: Data(Self.searchJSON.utf8))
        let docs = try #require(r.response?.docs)
        #expect(r.response?.numFound == 131)
        #expect(docs.count == 5)
        #expect(docs[0].yearValue == 1954)
        #expect(docs[1].yearValue == 1952)
        #expect(docs[4].yearValue == 1960)
        #expect(docs[2].titleText.contains("Eisenhower"))
    }

    @Test func backendErrorDecodes() throws {
        let r = try JSONDecoder().decode(ArchiveSearchResponse.self,
                                         from: Data(#"{"error":"[BACKEND_ERROR] Invalid or no response from Elasticsearch"}"#.utf8))
        #expect(r.response == nil)
        #expect(r.error != nil)
    }

    @Test func acceptsByYearToneAndExclusions() throws {
        let docs = try JSONDecoder().decode(ArchiveSearchResponse.self, from: Data(Self.searchJSON.utf8)).response!.docs
        let newsreel = ArchiveCatalog.queries.first { $0.name == "newsreel" }!   // black and white only
        let trippy = ArchiveCatalog.queries.first { $0.name == "trippy" }!       // colour allowed
        #expect(ArchiveCatalog.accept(docs[0], query: newsreel))
        #expect(!ArchiveCatalog.accept(docs[1], query: newsreel))   // colour
        #expect(ArchiveCatalog.accept(docs[1], query: trippy))
        #expect(!ArchiveCatalog.accept(docs[2], query: trippy))     // "campaign"
        #expect(!ArchiveCatalog.accept(docs[3], query: trippy))     // 1975
        #expect(ArchiveCatalog.accept(docs[4], query: trippy))
    }

    @Test func toneSpellings() {
        #expect(ArchiveCatalog.tone("B&W") == .blackAndWhite)
        #expect(ArchiveCatalog.tone("b/w") == .blackAndWhite)
        #expect(ArchiveCatalog.tone("B&W (tinted)") == .blackAndWhite)
        #expect(ArchiveCatalog.tone("C") == .colour)
        #expect(ArchiveCatalog.tone("Color") == .colour)
        #expect(ArchiveCatalog.tone(nil) == .unknown)
        #expect(ArchiveCatalog.tone("Si") == .unknown)
    }

    @Test func exclusionIsWholeWord() {
        #expect(ArchiveCatalog.isExcluded("The War Years"))
        #expect(!ArchiveCatalog.isExcluded("Wardrobe of Tomorrow"))   // "war" inside a word
        #expect(ArchiveCatalog.isExcluded("Notes on Civil Defense, 1955"))
        #expect(!ArchiveCatalog.isExcluded("Civil Engineering"))
        #expect(ArchiveCatalog.isExcluded("<p>a FIRE in the hills</p>"))
    }

    @Test func drugEducationAllowsItsSubjectWithoutRelaxingOtherFilters() throws {
        let drugEducation = try #require(ArchiveCatalog.queries.first { $0.name == "drug-education" })
        let newsreel = try #require(ArchiveCatalog.queries.first { $0.name == "newsreel" })
        let metadata = try JSONDecoder().decode(ArchiveItemInfo.self, from: Data(
            #"{"title":"Classroom Drug Education","description":"A film about drug and alcohol use."}"#.utf8))
        #expect(ArchiveCatalog.accept(metadata, query: drugEducation))
        #expect(!ArchiveCatalog.accept(metadata, query: newsreel))
        #expect(!drugEducation.excludedTerms.contains("drug"))
        #expect(ArchiveCatalog.isExcluded("Drug education and war", query: drugEducation))
    }

    @Test func searchURLEncodesTheQuery() throws {
        let q = ArchiveCatalog.queries.first { $0.name == "bw" }!
        let url = ArchiveCatalog.searchURL(q, page: 3, rows: 50)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = c.queryItems ?? []
        let qv = try #require(items.first { $0.name == "q" }?.value)
        #expect(qv == ArchiveCatalog.fullQuery(q))
        #expect(qv.contains("color:\"B&W\""))
        #expect(qv.contains("year:[1950 TO 1969]"))
        #expect(qv.contains("NOT ("))
        #expect(items.filter { $0.name == "fl[]" }.map(\.value) == ArchiveCatalog.searchFields)
        #expect(items.first { $0.name == "page" }?.value == "3")
        #expect(items.first { $0.name == "rows" }?.value == "50")
        // "&" inside the query must not split the parameter list.
        #expect(!(c.percentEncodedQuery ?? "").contains("B&W"))
    }

    @Test func parsesDurations() {
        #expect(ArchiveCatalog.parseDuration("1724.14") == 1724.14)
        #expect(ArchiveCatalog.parseDuration("10:40") == 640)
        #expect(ArchiveCatalog.parseDuration("1:02:03") == 3723)
        #expect(ArchiveCatalog.parseDuration("") == nil)
        #expect(ArchiveCatalog.parseDuration("abc") == nil)
        #expect(ArchiveCatalog.parseDuration("0") == nil)
    }

    @Test func picksPlayableFile() {
        let files = [
            ArchiveFile(name: "Film.mpeg", format: "MPEG2", size: "900000000"),
            ArchiveFile(name: "Film_edit.mp4", format: "h.264", size: "50000000", length: "640"),
            ArchiveFile(name: "Film.mp4", format: "h.264", size: "60000000", length: "640"),
            ArchiveFile(name: "Film_512kb.mp4", format: "512Kb MPEG4", size: "30000000", length: "640"),
            ArchiveFile(name: "Film.ogv", format: "Ogg Video", size: "20000000"),
        ]
        #expect(ArchiveCatalog.playableFiles(files).map(\.name) == ["Film.mp4", "Film_512kb.mp4"])
        #expect(ArchiveCatalog.pickFile(files, preferSmallest: false)?.name == "Film.mp4")
        #expect(ArchiveCatalog.pickFile(files, preferSmallest: true)?.name == "Film_512kb.mp4")
        // Main file too big: the 512kb derivative.
        let big = [ArchiveFile(name: "A.mp4", format: "h.264", size: "100000000", length: "900"),
                   ArchiveFile(name: "A_512kb.mp4", format: "512Kb MPEG4", size: "40000000", length: "900")]
        #expect(ArchiveCatalog.pickFile(big, preferSmallest: false)?.name == "A_512kb.mp4")
        // A large, long film still qualifies when it is the only playable version.
        let long = ArchiveFile(name: "B.mp4", format: "h.264", size: "690000000", length: "1743")
        #expect(ArchiveCatalog.pickFile([long], preferSmallest: false)?.name == "B.mp4")
        // Brief and tiny files do not qualify.
        #expect(ArchiveCatalog.pickFile([ArchiveFile(name: "C.mp4", format: "h.264", size: "5000000", length: "12")], preferSmallest: false) == nil)
        #expect(ArchiveCatalog.pickFile([ArchiveFile(name: "D.mp4", format: "h.264", size: "1000")], preferSmallest: false) == nil)
    }

    @Test func segmentStartStaysInsideAndAvoidsShown() {
        var rng = MusicRNG(seed: 7)
        for _ in 0..<500 {
            let d = Double.random(in: 30...1500)
            let len = Double.random(in: 10...min(60, d - 1))
            let s = ArchiveCatalog.segmentStart(duration: d, length: len, avoid: [], rng: &rng)
            #expect(s >= 0)
            #expect(s + len <= d + 1e-9)
            if d > 400 {   // margins honoured when there is room
                #expect(s >= min(0.2 * d, 60) - 1e-9)
                #expect(s + len <= d - min(0.2 * d, 60) + 1e-9)
            }
        }
        // Too short for the request: start at 0.
        #expect(ArchiveCatalog.segmentStart(duration: 20, length: 40, avoid: [], rng: &rng) == 0)
        // Leave 20 seconds when there is room, even if the first random draw would be close.
        for _ in 0..<200 {
            let s = ArchiveCatalog.segmentStart(duration: 900, length: 40, avoid: [300, 450], rng: &rng)
            #expect(abs(s - 300) >= 20 && abs(s - 450) >= 20)
        }

        // A short, frequently reused film still gets a fresh start after its wide gaps fill up.
        var shown: [Double] = [0, 5, 10]
        for _ in 0..<50 {
            let s = ArchiveCatalog.segmentStart(duration: 30, length: 20, avoid: shown, rng: &rng)
            #expect((0...10).contains(s))
            #expect(!shown.contains(s))
            shown.append(s)
        }
    }

    @Test func shuffleBagHasNoRepeatsUntilExhausted() {
        var bag = ShuffleBag(["a", "b", "c", "d", "e"])
        var rng = MusicRNG(seed: 3)
        let first = (0..<5).compactMap { _ in bag.next(rng: &rng) }
        #expect(Set(first).count == 5)
        let second = (0..<5).compactMap { _ in bag.next(rng: &rng) }
        #expect(Set(second).count == 5)
        // Exclusions are never drawn; an all-excluded bag is empty.
        for _ in 0..<20 { #expect(bag.next(rng: &rng, excluding: ["a", "b"]).map { $0 != "a" && $0 != "b" } ?? false) }
        #expect(bag.next(rng: &rng, excluding: Set(["a", "b", "c", "d", "e"])) == nil)
        #expect(!bag.hasAny(excluding: Set(["a", "b", "c", "d", "e"])))
    }

    @Test func failuresAndBackoff() {
        #expect(ArchiveCatalog.isContentFailure(status: 404))
        #expect(ArchiveCatalog.isContentFailure(status: 403))
        #expect(!ArchiveCatalog.isContentFailure(status: 503))
        #expect(ArchiveCatalog.backoff(failures: 1) == 60)
        #expect(ArchiveCatalog.backoff(failures: 3) == 300)
        #expect(ArchiveCatalog.backoff(failures: 99) == 1800)
    }

    @Test func bundledSeedsAreVetted() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Liminal/Archive/archive-seeds.json")
        let list = try JSONDecoder().decode(ArchiveSeedList.self, from: Data(contentsOf: url))
        #expect(list.seeds.count >= 100)
        #expect(Set(list.seeds.map(\.id)).count == list.seeds.count)
        for s in list.seeds {
            #expect(ArchiveCatalog.years.contains(s.year))
            #expect(!ArchiveCatalog.isExcluded(s.title), "\(s.id): \(s.title)")
        }
    }
}

struct ArchiveCachePolicyTests {
    static func clip(_ id: String, mb: Int64, used: Double?, count: Int = 0) -> ArchiveClip {
        ArchiveClip(id: id, title: id, year: 1955, fileName: "\(id).mp4", bytes: mb * 1_000_000, duration: 600,
                    width: 640, height: 480, hasAudio: true, black: 0.05, white: 0.9, isColour: false, licence: nil,
                    added: Date(timeIntervalSince1970: 1000), lastUsed: used.map { Date(timeIntervalSince1970: $0) },
                    useCount: count, shownStarts: [])
    }

    @Test func evictsLeastRecentlyUsedOverTheCap() {
        let clips = [Self.clip("a", mb: 300, used: 5000), Self.clip("b", mb: 300, used: 2000),
                     Self.clip("c", mb: 300, used: 8000), Self.clip("d", mb: 50, used: nil)]
        // 950 MB + 200 MB incoming > 1 GB: the oldest by recency goes first (d was added at 1000, never used).
        #expect(ArchiveCachePolicy.victims(clips, incoming: 200_000_000, capBytes: 1_000_000_000) == ["d", "b"])
        // Under the cap and the pool size: nothing.
        #expect(ArchiveCachePolicy.victims(clips, incoming: 10_000_000, capBytes: 1_000_000_000).isEmpty)
        // The clip on screen is never evicted.
        #expect(ArchiveCachePolicy.victims(clips, incoming: 200_000_000, capBytes: 1_000_000_000,
                                           protected: ["d"]) == ["b"])
    }

    @Test func neverBelowMinimumAndPoolCap() {
        let three = [Self.clip("a", mb: 600, used: 1), Self.clip("b", mb: 600, used: 2), Self.clip("c", mb: 600, used: 3)]
        // Over the cap, but the pool (counting the incoming clip) never drops below 3.
        #expect(ArchiveCachePolicy.victims(three, incoming: 600_000_000, capBytes: 1_000_000_000) == ["a"])
        #expect(ArchiveCachePolicy.victims(Array(three.prefix(2)), incoming: 900_000_000, capBytes: 1_000_000_000).isEmpty)
        let many = (0..<ArchiveCachePolicy.poolTarget).map { Self.clip("k\($0)", mb: 10, used: Double($0)) }
        #expect(ArchiveCachePolicy.victims(many, incoming: 10_000_000) == ["k0"])
    }

    @Test func replacementIsMostUsed() {
        let clips = [Self.clip("a", mb: 10, used: 10, count: 2), Self.clip("b", mb: 10, used: 5, count: 4),
                     Self.clip("c", mb: 10, used: 1, count: 4)]
        #expect(ArchiveCachePolicy.replacement(clips) == "c")   // tie on count: the less recent
        #expect(ArchiveCachePolicy.replacement(clips, protected: ["c"]) == "b")
    }

    @Test func curatedFilmsSurviveRotationAndSizeEviction() throws {
        let pinned = try #require(ArchiveSeedList.pinned.first)
        let clips = [Self.clip(pinned.id, mb: 90, used: 1, count: 20),
                     Self.clip("rotating", mb: 90, used: 10, count: 2)]
        #expect(ArchiveCachePolicy.replacement(clips) == "rotating")
        #expect(ArchiveCachePolicy.victims(clips, incoming: 90_000_000, capBytes: 180_000_000,
                                           minKeep: 2) == ["rotating"])
    }

    @Test func discoveryReplacementWaitsForTwoPlaysAndTheFade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("liminal-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveClipStore(directory: dir)
        await store.load()
        let staged = dir.appendingPathComponent("incoming.mp4")
        for id in ["a", "b"] {
            try Data([1]).write(to: staged)
            try await store.add(Self.clip(id, mb: 1, used: nil), from: staged, protected: [])
        }
        // Fill the pinned slots around the existing discoveries, as on a catalog upgrade.
        for pin in ArchiveSeedList.pinned {
            try Data([1]).write(to: staged)
            try await store.add(Self.clip(pin.id, mb: 1, used: nil), from: staged, protected: [])
        }
        #expect(ArchiveSeedList.pinnedIDs.count == 13)
        #expect(await store.clips.count == 15)
        try Data([1]).write(to: staged)
        let newcomer = Self.clip("c", mb: 1, used: nil)
        await store.markUsed("a", segmentStart: 40)
        await #expect(throws: ArchiveClipStore.AddFailure.insufficientCacheSpace) {
            try await store.add(newcomer, from: staged, protected: [])
        }
        await store.markUsed("a", segmentStart: 90)
        await #expect(throws: ArchiveClipStore.AddFailure.insufficientCacheSpace) {
            try await store.add(newcomer, from: staged, protected: ["a"])
        }
        #expect(try await store.add(newcomer, from: staged, protected: []) == ["a"])
        #expect(await store.recentDiscoveryIDs == ["a"])
    }

    @Test func storeAddsEvictsAndPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("liminal-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveClipStore(directory: dir)
        await store.load()
        for i in 0..<2 {
            let f = dir.appendingPathComponent("in\(i).bin")
            try Data(repeating: 1, count: 10).write(to: f)
            try await store.add(Self.clip("x\(i)", mb: 1, used: Double(i)), from: f, protected: [])
        }
        await store.markUsed("x1", segmentStart: 42)
        await store.markBad("bad1")
        let again = ArchiveClipStore(directory: dir)
        await again.load()
        let clips = await again.clips
        #expect(clips.map(\.id).sorted() == ["x0", "x1"])
        #expect(clips.first { $0.id == "x1" }?.useCount == 1)
        #expect(clips.first { $0.id == "x1" }?.shownStarts == [42])
        #expect(await again.badIDs == ["bad1"])
        await again.remove("x0")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x0.mp4").path))
    }

    @Test func loadingAnExistingCacheRemovesRetiredFilms() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("liminal-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kept = try #require(ArchiveSeedList.pinned.first?.id)
        let retired = ["Narcotic1967_2", "lsdthespringgroveexperimentreel1"]
        let legacy = (retired + [kept, "fresh-a", "fresh-b"]).map { Self.clip($0, mb: 1, used: nil) }
            + [Self.clip("old-discovery", mb: 1, used: nil, count: 2)]
        for clip in legacy {
            try Data([1]).write(to: dir.appendingPathComponent(clip.fileName))
        }
        try JSONEncoder().encode(ArchiveClipStore.Index(clips: legacy)).write(to: dir.appendingPathComponent("index.json"))

        let reloaded = ArchiveClipStore(directory: dir)
        await reloaded.load()
        #expect(Set(await reloaded.clips.map(\.id)) == [kept, "fresh-a", "fresh-b"])
        #expect(await reloaded.recentDiscoveryIDs == ["old-discovery"])
        for id in retired {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).mp4").path))
        }
    }
}

struct FootageWeaverTests {
    typealias C = FootageWeaver.Conditions
    static let calm = C(musicIntensity: 0.3, effectIntensity: 0.5)

    @Test func filmCutsCenterOnBothFillDownbeatsAcrossTempoChanges() throws {
        let first = LofiClock(tempo: 58, sampleRate: 48_000)
        let second = LofiClock(tempo: 82, sampleRate: 48_000)
        // Footage can be enabled partway through an already running drum take.
        let origin = -3.713
        let turn = origin + 64 * first.beatDuration
        var w = FootageWeaver(seed: 12, timing: .standard)
        var cuts: [Double] = []
        let conditions = Self.calm
        for step in 0..<240 {
            let t = Double(step) * 0.5
            let grid = t < turn ? LofiTakeGrid(origin: origin, beatDuration: first.beatDuration,
                                                nextBeatDuration: t >= turn - 4 ? second.beatDuration : nil)
                                : LofiTakeGrid(origin: turn, beatDuration: second.beatDuration, takeIndex: 1)
            let action = w.tick(elapsed: t, conditions: conditions, hasClip: true, grid: grid) { _ in true }
            if case .prepare(let r) = action {
                if let fill = r.fill {
                    // The piece change completes on the downbeat, with the picture's drop cut.
                    let center = r.start + r.fadeIn
                    cuts.append(center)
                    if abs(center - turn) < 1e-8 {
                        #expect(abs(r.start + r.length - (turn + 32 * second.beatDuration)) < 1e-8)
                    }
                    #expect(t < r.start)
                    #expect(fill == (cuts.count.isMultiple(of: 2) ? .turnaround : .halfway))
                    #expect(abs(grid.accent(at: center) - (fill == .turnaround ? 1 : 0.65)) < 0.00001)
                }
                w.didPrepare(r.piece(clipID: "clip-\(r.index)", segmentStart: 0))
            }
        }
        let expected = [origin + 32 * first.beatDuration, turn, turn + 32 * second.beatDuration,
                        turn + 64 * second.beatDuration]
        #expect(cuts.count == expected.count)
        for (cut, beat) in zip(cuts, expected) { #expect(abs(cut - beat) < 1e-8) }
    }

    @Test func missedFillKeepsTheOldFilmUntilTheNextDownbeat() throws {
        let grid = LofiTakeGrid(origin: 0, beatDuration: 0.8)
        var weaver = FootageWeaver(seed: 14, timing: .standard)
        var dropped = false
        var fills: [LofiFill] = []
        for step in 0...108 {
            let t = Double(step) / 2
            let decision = weaver.tick(elapsed: t, conditions: Self.calm, hasClip: true,
                                       grid: grid) { slot in slot == 0 || dropped }
            switch decision {
            case .prepare(let request):
                if let fill = request.fill { fills.append(fill) }
                weaver.didPrepare(request.piece(clipID: "film-\(request.index)", segmentStart: 0))
            case .drop:
                dropped = true
                let retained = try #require(weaver.current)
                #expect(retained.index == 0 && retained.envelope(at: t) == 1)
            default: break
            }
        }
        #expect(dropped)
        #expect(fills == [.halfway, .turnaround])
        #expect(weaver.current?.index == 2)
    }

    /// 75 BPM: a fill boundary (halfway or turnaround) every 32 beats, 25.6 s.
    static let grid = LofiTakeGrid(origin: 0, beatDuration: 0.8)
    static var boundarySeconds: Double { 32 * grid.beatDuration }

    struct Run {
        /// Every piece, in its final state (fade out set once the next was placed).
        var pieces: [FootagePiece] = []
        /// (t, presence, pieces live) every 0.1 s.
        var samples: [(t: Double, presence: Float, live: Int)] = []
        var decisions: [(t: Double, d: FootageWeaver.Decision)] = []
    }

    /// Runs a weaver at 2 Hz (as the service does) on `grid` and samples what the render loop would see
    /// every 0.1 s. Like the render loop, an incoming fill edit whose decoder has no frame yet freezes the
    /// crossfade at its start, so the current piece shows at full level until the weaver drops the edit.
    static func run(seed: UInt64, timing: FootageWeaver.Timing = .standard, seconds: Double, clipFrom: Double = 0,
                    ready: @escaping (Int, Double) -> Bool = { _, _ in true },
                    conditions: (Double) -> C = { _ in calm }) -> Run {
        var w = FootageWeaver(seed: seed, timing: timing)
        var out = Run()
        var byIndex: [Int: FootagePiece] = [:]
        let steps = Int(seconds * 10)
        for i in 0..<steps {
            let t = Double(i) / 10
            if i % 5 == 0 {
                let d = w.tick(elapsed: t, conditions: conditions(t), hasClip: t >= clipFrom, grid: grid) { ready($0, t) }
                if d != .none { out.decisions.append((t, d)) }
                if case .prepare(let r) = d {
                    w.didPrepare(r.piece(clipID: "c\(r.index % 3)", segmentStart: 10))
                }
                for p in w.pieces { byIndex[p.index] = p }
            }
            let pieces = w.pieces
            let awaiting = pieces.count == 2 && pieces[1].fill != nil && !ready(pieces[1].slot, t)
            let shown = awaiting ? min(t, pieces[1].start) : t
            out.samples.append((t, pieces.reduce(0) { $0 + $1.weight(at: shown) }, pieces.count))
        }
        out.pieces = byIndex.keys.sorted().map { byIndex[$0]! }
        return out
    }

    @Test func alwaysPresentAboveTheFloorAfterTheFirstFade() {
        for seed in UInt64(0)..<150 {
            let r = Self.run(seed: seed, seconds: 900)
            guard let first = r.pieces.first else { Issue.record("no piece"); continue }
            // Cold start with a clip at once: the first piece fades in after 1 s, over 5 s.
            #expect(first.start <= 1.5)
            #expect(first.fadeIn == FootageWeaver.Timing.standard.firstFade)
            let on = first.start + first.fadeIn
            for s in r.samples where s.t >= on {
                #expect(s.presence >= FootageWeaver.floor - 1e-5)
                #expect(s.presence <= FootageWeaver.bandTop + FootageWeaver.swellRange.upperBound + 1e-5)
                #expect(s.live >= 1 && s.live <= 2)
            }
            // Before the first fade the envelope only rises (a fade in, not a pop).
            let early = r.samples.filter { $0.t < on }.map { first.envelope(at: $0.t) }
            #expect(early == early.sorted())
        }
    }

    @Test func everyPieceChangeCompletesOnTheNextFillDownbeat() {
        let span = Self.boundarySeconds
        for seed in UInt64(0)..<60 {
            let r = Self.run(seed: seed, seconds: 600)
            // Calm conditions: no fill boundary is skipped.
            #expect(r.pieces.count == Int(600 / span) + 1)
            for (n, (a, b)) in zip(r.pieces, r.pieces.dropFirst()).enumerated() {
                let downbeat = Double(n + 1) * span
                let fill = (n + 1).isMultiple(of: 2) ? LofiFill.turnaround : .halfway
                #expect(b.fill == fill)
                #expect(abs(b.start + b.fadeIn - downbeat) < 1e-9)
                #expect(abs(b.fadeIn - fill.dissolveBeats * Self.grid.beatDuration) < 1e-9)
                // A piece is planned to last until the boundary after its fade in.
                #expect(abs(b.start + b.length - (downbeat + span)) < 1e-9)
                #expect(abs(a.start + a.length - downbeat) < 1e-9)
                #expect(a.recipe != b.recipe)
                #expect(a.recipe.family != b.recipe.family)
                #expect(a.slot != b.slot)
            }
        }
    }

    @Test func crossfadesAreContinuousAndComplementary() {
        let r = Self.run(seed: 11, seconds: 600)
        #expect(r.pieces.count > 10)
        for (a, b) in zip(r.pieces, r.pieces.dropFirst()) {
            #expect(a.fadeOutStart == b.start)
            #expect(a.fadeOut == b.fadeIn)
            // Through the crossfade the envelopes add to exactly 1: never a cut, never a gap.
            var t = b.start
            while t <= b.start + b.fadeIn {
                #expect(abs(a.envelope(at: t) + b.envelope(at: t) - 1) < 1e-5)
                t += 0.01
            }
            #expect(a.envelope(at: b.start + b.fadeIn + 0.01) == 0)
        }
        // A piece is retired only after it has fully faded out.
        for (t, d) in r.decisions {
            if case .retire(let slot) = d {
                let gone = r.pieces.filter { $0.slot == slot && ($0.end ?? .infinity) <= t }
                #expect(!gone.isEmpty)
            }
        }
    }

    @Test func everyPieceRequestsSoundAndMayPrepareBeforeTheOldCueEnds() {
        var overlaps = 0
        for seed in UInt64(0)..<100 {
            let r = Self.run(seed: seed, seconds: 900)
            #expect(r.pieces.allSatisfy { $0.sound })
            let preparationTimes = Dictionary(uniqueKeysWithValues: r.decisions.compactMap { time, decision -> (Int, Double)? in
                guard case .prepare(let request) = decision else { return nil }
                return (request.index, time)
            })
            // The scheduler can prepare the next cue while the first one still has audio.
            for (a, b) in zip(r.pieces, r.pieces.dropFirst()) {
                let ca = ArchiveAudioCuePlan(piece: a, clipDuration: 10_000)!
                let cb = ArchiveAudioCuePlan(piece: b, clipDuration: 10_000)!
                #expect(cb.beginAt > ca.beginAt)
                if let prepareAt = preparationTimes[b.index], prepareAt < ca.fadeOutAt { overlaps += 1 }
            }
        }
        #expect(overlaps > 0)
    }

    @Test func stillsHoldOneSilentPiece() {
        let r = Self.run(seed: 4, timing: .stills, seconds: 300)
        #expect(r.pieces.count == 1)
        #expect(r.pieces.first.map { !$0.sound && $0.fadeIn == 1 && $0.end == nil } == true)
        #expect(r.samples.filter { $0.t >= 2.5 }.allSatisfy { $0.presence >= FootageWeaver.floor - 1e-5 })
    }

    @Test func coldStartWaitsForTheFirstClipOnly() {
        let r = Self.run(seed: 3, seconds: 60, clipFrom: 20)
        #expect(r.pieces.first.map { $0.start >= 20 && $0.start <= 21.5 } == true)
        #expect(r.samples.filter { $0.t < 20 }.allSatisfy { $0.presence == 0 })
    }

    @Test func theFirstPieceHoldsUntilItsDecoderDelivers() {
        // Slot 0 has no frame until 6 s: the first piece's fade in waits for it.
        let late = Self.run(seed: 5, seconds: 60, ready: { slot, t in slot != 0 || t >= 6 })
        let first = late.pieces[0]
        #expect(first.start >= 6 - 1e-9 && first.start <= 7.5)
        #expect(first.origin <= 1.5)   // the decoder's clock and the sound stay anchored
        #expect(late.samples.filter { $0.t < 6 }.allSatisfy { $0.presence == 0 })
        // A decoder that never delivers is given up after `maxReadyWait`; another first piece follows.
        let never = Self.run(seed: 5, seconds: 60, ready: { slot, t in slot != 0 || t >= 30 })
        let drops = never.decisions.filter { if case .drop(slot: 0) = $0.d { return true }; return false }
        #expect(drops.first.map { $0.t >= FootageWeaver.Timing.standard.maxReadyWait } == true)
        #expect(never.pieces.contains { $0.slot == 0 && $0.start >= 30 })
    }

    @Test func aDecoderThatNeverDeliversIsDroppedWhileTheCurrentPieceHolds() {
        // Slot 1 never produces a frame until 80 s.
        let r = Self.run(seed: 9, seconds: 140, ready: { slot, t in slot == 0 || t >= 80 })
        #expect(r.decisions.contains { if case .drop(slot: 1) = $0.d { return true }; return false })
        let on = r.pieces[0].start + r.pieces[0].fadeIn
        #expect(r.samples.filter { $0.t >= on }.allSatisfy { $0.presence >= FootageWeaver.floor - 1e-5 })
        // Once slot 1 delivers, pieces flow again, on the next fill downbeat.
        #expect(r.pieces.contains { $0.slot == 1 && $0.start >= 80 })
    }

    @Test func recipeEligibilityByIntensityAndDepth() {
        var rng = MusicRNG(seed: 9)
        for _ in 0..<800 {
            let low = FootageWeaver.chooseRecipe(last: nil, recent: [], intensity: 0.15, hasDepth: false, rng: &rng)
            #expect(low.minIntensity <= 0.15)
            #expect(![.emerge, .solar, .print, .kaleido, .undertow, .backdrop].contains(low))
            let mac = FootageWeaver.chooseRecipe(last: .imprint, recent: [], intensity: 0.9, hasDepth: false, rng: &rng)
            #expect(mac != .backdrop)
            #expect(mac.family != .plain)
        }
        #expect(FootageWeaver.eligible(intensity: 1, hasDepth: true).count == FootageRecipe.allCases.count)
        #expect(!FootageWeaver.eligible(intensity: 1, hasDepth: false).contains(.backdrop))
        // With a depth map, Backdrop does come up.
        var seen = false
        for _ in 0..<400 where FootageWeaver.chooseRecipe(last: .phantom, recent: [], intensity: 0.5, hasDepth: true, rng: &rng) == .backdrop {
            seen = true
        }
        #expect(seen)
        // A capped recipe is never chosen for a piece longer than its cap.
        for _ in 0..<400 {
            let r = FootageWeaver.chooseRecipe(last: nil, recent: [], intensity: 1, hasDepth: true,
                                               minimumLength: FootageRecipe.cappedLength + 1, rng: &rng)
            #expect(r.maxLength == nil)
        }
    }

    @Test func recipeSequenceHasVarietyAndKeepsThePlainLooks() {
        for intensity: Float in [0.1, 0.5, 1.0] {
            for seed in UInt64(0)..<150 {
                var rng = MusicRNG(seed: seed)
                var last: FootageRecipe?
                var recent: [FootageRecipe] = []
                var plain = 0
                var kinds = Set<FootageRecipe>()
                let n = 200
                for _ in 0..<n {
                    let r = FootageWeaver.chooseRecipe(last: last, recent: recent, intensity: intensity, hasDepth: seed % 2 == 0,
                                                       rng: &rng)
                    #expect(r != last)
                    #expect(r.family != last?.family)
                    let u = (last?.shaderGroup ?? 1) | r.shaderGroup
                    #expect(u != 7 && u != 11 && u != 15)   // keys never meet drives or glass (F11, F25)
                    #expect(intensity >= r.minIntensity)
                    if r.family == .plain { plain += 1 }
                    kinds.insert(r)
                    last = r
                    recent.append(r)
                    if recent.count > FootageWeaver.recentCount { recent.removeFirst() }
                }
                // About 30 % of the pieces are today's blend looks.
                #expect(Float(plain) / Float(n) >= 0.22 && Float(plain) / Float(n) <= 0.42)
                #expect(kinds.count >= 8)
            }
        }
    }

    @Test func pinnedRecipe() {
        var w = FootageWeaver(seed: 5, timing: .standard, pinnedRecipe: .undertow)
        guard case .prepare(let r) = w.tick(elapsed: 0, conditions: Self.calm, hasClip: true, grid: Self.grid,
                                            ready: { _ in true }) else {
            Issue.record("no first piece"); return
        }
        #expect(r.recipe == .undertow)
        #expect(FootageRecipe(name: "Shadow-play") == .shadowplay)
        #expect(FootageRecipe(name: "facets") == nil)
        #expect(FootageRecipe(name: "nope") == nil)
    }

    @Test func pinnedLook() {
        var w = FootageWeaver(seed: 5, timing: .standard, pinnedLook: .window)
        guard case .prepare(let r) = w.tick(elapsed: 0, conditions: Self.calm, hasClip: true, grid: Self.grid,
                                            ready: { _ in true }) else {
            Issue.record("no first piece"); return
        }
        #expect(r.look == .window)
        #expect(r.recipe == .window)
    }

    @Test func pieceEnvelopeAndSwell() {
        var p = FootagePiece(index: 0, slot: 0, clipID: "c", segmentStart: 0, rate: 0.7, recipe: .phantom, seed: 0,
                             warp: 0.5, level: 0.5, swell: 0.3, start: 10, origin: 10, fadeIn: 4, length: 20,
                             fadeOutStart: nil, fadeOut: nil, sound: false)
        #expect(p.envelope(at: 9) == 0)
        #expect(abs(p.envelope(at: 12) - 0.5) < 1e-6)
        #expect(p.envelope(at: 100) == 1)          // holds until the next piece is placed
        p.fadeOutStart = 30
        p.fadeOut = 4
        #expect(abs(p.envelope(at: 32) - 0.5) < 1e-6)
        #expect(p.envelope(at: 34) == 0)
        #expect(p.level(at: 10) == 0.5)
        #expect(abs(p.level(at: 20) - 0.8) < 1e-6)  // the swell peaks mid-piece
        #expect(p.level(at: 30) - 0.5 < 1e-6)
        // The drive follows the envelope and the swell, not the level.
        #expect(abs(p.driveEnvelope(at: 20) - 1.6) < 1e-5)
        #expect(abs(p.driveEnvelope(at: 32) - 0.5 * p.level(at: 32) / 0.5) < 1e-5)
    }

    @Test func playbackRunsFourCuratedExcerptsBetweenDiscoveries() throws {
        let pinnedID = try #require(ArchiveSeedList.pinned.first?.id)
        let pinned = ArchiveCachePolicyTests.clip(pinnedID, mb: 80, used: 10)
        let regular = ArchiveCachePolicyTests.clip("regular", mb: 20, used: 1)
        var weaver = FootageWeaver(seed: 7, timing: .standard)
        var rng = MusicRNG(seed: 11)
        #expect(weaver.chooseClipForPlayback([regular], rng: &rng)?.id == regular.id)

        var selected: [String] = []
        for step in 0..<360 {
            let decision = weaver.tick(elapsed: Double(step) / 2, conditions: Self.calm, hasClip: true,
                                       grid: Self.grid) { _ in true }
            if case .prepare(let request) = decision {
                let clip = try #require(weaver.chooseClipForPlayback([regular, pinned], rng: &rng))
                selected.append(clip.id)
                weaver.didPrepare(request.piece(clipID: clip.id, segmentStart: 10))
            }
        }
        #expect(selected.count >= 6)
        #expect(selected.first == pinnedID)
        #expect(selected.contains(regular.id))
        for (index, id) in selected.enumerated() {
            #expect(id == (index % 5 == 4 ? regular.id : pinnedID))
        }
    }

    @Test func clipChoiceAvoidsClipsOnScreen() {
        let clips = ["a", "b", "c"].enumerated().map { ArchiveCachePolicyTests.clip($1, mb: 10, used: Double($0)) }
        var rng = MusicRNG(seed: 4)
        var counts: [String: Int] = [:]
        for _ in 0..<600 {
            let c = FootageWeaver.chooseClip(clips, avoiding: ["a"], rng: &rng)!
            #expect(c.id != "a")
            counts[c.id, default: 0] += 1
        }
        #expect((counts["b"] ?? 0) > (counts["c"] ?? 0))   // least recently used is likelier
        #expect(FootageWeaver.chooseClip(clips, avoiding: ["a", "b"], rng: &rng)?.id == "c")
        // One clip cached: pieces reuse it (other segments).
        #expect(FootageWeaver.chooseClip([clips[0]], avoiding: ["a"], rng: &rng)?.id == "a")
    }
}

@MainActor
struct VideoCompositeTests {
    static let state = VideoCompositeState(envelope: 1, look: .window, seed: 0.4, aspect: 4.0 / 3.0,
                                           tint: SIMD3(0.9, 0.6, 0.3), shade: SIMD3(0.1, 0.05, 0.02))

    @Test func offLeavesUniformsUnchanged() {
        for t: Float in [0, 37, 113, 611] {
            let a = EffectsUniformsComputer.compute(time: t, transitionProgress: 0)
            let b = EffectsUniformsComputer.compute(time: t, transitionProgress: 0, video: .off)
            #expect(withUnsafeBytes(of: a) { Data($0) } == withUnsafeBytes(of: b) { Data($0) })
            #expect(a.videoMix == 0)
        }
    }

    @Test func uniformStrideMatchesTheShaderStruct() {
        // 25 original + 2 vibrance + 6 transition + 11 footage + 7 footage layer B + 8 interaction floats,
        // no padding (EffectsRenderer.metal).
        #expect(MemoryLayout<EffectsUniforms>.size == 65 * 4)
        #expect(MemoryLayout<EffectsUniforms>.stride == 65 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.txStep) == 61 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.txFinish) == 64 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoDrive) == 51 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoKeyAmtB) == 58 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.tunnelStrength) == 59 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.outgoingZoomScale) == 60 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoMix) == 33 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoShadeB) == 43 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoWarp) == 44 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoWarpB) == 50 * 4)
    }

    @Test func mixFormula() {
        // weight x ceiling x (0.75 + 0.25 drive) x (0.6 + 0.4 settled)
        let a = Self.state.a
        let m = VideoComposite.mix(a, intensity: 0.5, drive: 1, settled: 1)
        #expect(abs(m - 0.75) < 1e-6)
        let low = VideoComposite.mix(a, intensity: 0.5, drive: 0, settled: 0)
        #expect(abs(low - 0.75 * 0.75 * 0.6) < 1e-6)   // a new picture dips the footage, never hides it
        var half = a!
        half.weight = 0.5
        #expect(abs(VideoComposite.mix(half, intensity: 0.5, drive: 1, settled: 1) - 0.375) < 1e-6)
        #expect(VideoComposite.mix(nil, intensity: 0.5, drive: 1, settled: 1) == 0)
        #expect(VideoComposite.mix(a, constantMix: 0.4, intensity: 0, drive: 0, settled: 0) == 0.4)
        // Emerge is absent at intensity 0.
        var emerge = a!
        emerge.look = .emerge
        #expect(VideoComposite.mix(emerge, intensity: 0, drive: 1, settled: 1) == 0)
        // Ceilings rise with intensity and stay below 1.
        for look in VideoLook.allCases {
            let c = [0, 0.25, 0.5, 0.75, 1].map { VideoComposite.ceiling(look, intensity: Float($0)) }
            #expect(c == c.sorted())
            #expect(c.allSatisfy { $0 <= 0.9 })
        }
        // The floor of the band stays visible: even at its lowest (clear stretch, a new picture arriving)
        // every look keeps a mix of at least 0.1 at the default intensity.
        for look in VideoLook.allCases {
            let l = VideoLayer(weight: FootageWeaver.floor, look: look, seed: 0, aspect: 1.33)
            #expect(VideoComposite.mix(l, intensity: 0.5, drive: 0, settled: 0) > 0.1)
        }
    }

    @Test func settledDipsSmoothlyDuringAndAfterACrossfade() {
        #expect(VideoComposite.settled(imageAge: 0, transitionDuration: 4, inTransition: true, progress: 0) == 1)
        #expect(VideoComposite.settled(imageAge: 1, transitionDuration: 4, inTransition: true, progress: 0.3) == 0)
        #expect(VideoComposite.settled(imageAge: 4, transitionDuration: 4, inTransition: false) == 0)
        #expect(VideoComposite.settled(imageAge: 10, transitionDuration: 4, inTransition: false) == 1)
        #expect(VideoComposite.settled(imageAge: nil, transitionDuration: 4, inTransition: false) == 1)
        // No step: small progress, small dip.
        let s = VideoComposite.settled(imageAge: 0, transitionDuration: 4, inTransition: true, progress: 0.01)
        #expect(s > 0.99)
    }

    @Test func computeWritesVideoUniforms() {
        let u = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, look: EffectLook(intensity: 0.5),
                                                video: Self.state)
        #expect(u.videoMix > 0.3 && u.videoMix <= 0.75)
        #expect(u.videoLook == 3)
        #expect(u.videoSeed == 0.4)
        #expect(u.videoWarp == 0.6)
        #expect(abs(u.videoAspect - (4.0 / 3.0) / 1.5) < 1e-6)
        #expect(u.videoTintR == 0.9 && u.videoShadeB == 0.02)
        #expect(u.videoMixB == 0)
        #expect(u.videoDrive == 0 && u.videoDriveAmt == 0 && u.videoKey == 0 && u.videoKeyAmt == 0)
        // Everything else matches the no-footage uniforms.
        var v = u
        v.videoMix = 0; v.videoLook = 0; v.videoSeed = 0; v.videoScale = 0; v.videoAspect = 0; v.videoWarp = 0
        v.videoTintR = 0; v.videoTintG = 0; v.videoTintB = 0; v.videoShadeR = 0; v.videoShadeG = 0; v.videoShadeB = 0
        let off = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, look: EffectLook(intensity: 0.5))
        #expect(withUnsafeBytes(of: v) { Data($0) } == withUnsafeBytes(of: off) { Data($0) })
    }

    @Test func crossfadeWritesBothLayers() {
        var s = Self.state
        s.a?.weight = 0.3
        s.b = VideoLayer(weight: 0.2, look: .phantom, seed: 0.8, aspect: 1.0, warp: 0.4)
        let u = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, look: EffectLook(intensity: 0.5),
                                                video: s)
        #expect(u.videoMix > 0 && u.videoMixB > 0)
        #expect(u.videoLook == 3 && u.videoLookB == 1)
        #expect(u.videoSeedB == 0.8 && u.videoWarpB == 0.4)
        #expect(abs(u.videoAspectB - 1.0 / 1.5) < 1e-6)
        #expect(u.videoScaleB == VideoComposite.scale(.phantom))
        // Only layer B (the outgoing piece on slot 0 has gone): layer A stays 0.
        s.a = nil
        let ub = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, look: EffectLook(intensity: 0.5),
                                                 video: s)
        #expect(ub.videoMix == 0 && ub.videoLook == 0 && ub.videoMixB > 0)
    }

    @Test func recipesWriteDriveAndKeyUniforms() {
        for r in FootageRecipe.allCases {
            var s = Self.state
            s.a?.recipe = r
            s.a?.weight = 0.5
            s.a?.envelope = 1
            let u = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, look: EffectLook(intensity: 1), video: s)
            #expect(u.videoMix > 0)   // the layer gate is open for every recipe, carrier or not
            #expect(u.videoLook == Float(r.carrier?.rawValue ?? 0))
            #expect(u.videoDrive == Float(r.drive.rawValue))
            #expect(u.videoKey == Float(r.key.rawValue))
            #expect((u.videoDriveAmt > 0) == (r.drive != .none))
            #expect(u.videoDriveAmt <= 1)
            #expect((u.videoKeyAmt != 0) == (r.key != .own))
            #expect(u.videoMix <= 0.95)
            // The frame binds the recipe's shader variant; plain looks keep the blend variant.
            #expect(VideoComposite.footageVariant(u) == r.shaderGroup)
            #expect((r.shaderGroup == 1) == (r.family == .plain))
        }
        #expect(VideoComposite.footageVariant(EffectsUniformsComputer.compute(time: 300, transitionProgress: 0)) == 0)
        // A carrier runs at its share of the plain look's mix.
        var plain = Self.state, fringe = Self.state
        plain.a?.recipe = .phantom
        fringe.a?.recipe = .fringe
        let mp = VideoComposite.mix(plain.a, intensity: 0.5, drive: 1, settled: 1)
        let mf = VideoComposite.mix(fringe.a, intensity: 0.5, drive: 1, settled: 1)
        #expect(abs(mf - mp * FootageRecipe.fringe.carrierShare) < 1e-6)
    }

    @Test func driveAmountsScaleWithIntensityClarityAndHold() {
        for r in FootageRecipe.allCases where r.drive != .none {
            let l = VideoLayer(weight: 0.5, look: .window, seed: 0.2, aspect: 1.33, recipe: r, envelope: 1)
            let a = [0, 0.25, 0.5, 0.75, 1].map {
                VideoComposite.driveAmount(l, intensity: Float($0), drive: 1, settled: 1, fresh: 1)
            }
            #expect(a == a.sorted())
            // The clarity cycle: wild stretches drive harder than clear ones.
            let clear = VideoComposite.driveAmount(l, intensity: 0.5, drive: 0, settled: 1, fresh: 1)
            #expect(clear < a[2] && clear > 0)
            // A new picture: the geometric drives stop, the others dip.
            let held = VideoComposite.driveAmount(l, intensity: 0.5, drive: 1, settled: 0, fresh: 0)
            if r.drive.isGeometric { #expect(held == 0) } else { #expect(held > 0 && held < a[2]) }
            // The envelope fades the drive with the piece (continuity through a crossfade).
            var half = l
            half.envelope = 0.5
            #expect(abs(VideoComposite.driveAmount(half, intensity: 0.5, drive: 1, settled: 1, fresh: 1) - a[2] * 0.5) < 1e-6)
        }
        // Solar is absent at intensity 0.
        let solar = VideoLayer(weight: 0.5, look: .window, seed: 0, aspect: 1, recipe: .solar, envelope: 1)
        #expect(VideoComposite.driveAmount(solar, intensity: 0, drive: 1, settled: 1, fresh: 1) == 0)
        #expect(VideoComposite.driveAmount(nil, intensity: 0.5, drive: 1, settled: 1, fresh: 1) == 0)
    }

    @Test func shadowplayPolarityFollowsThePicture() {
        #expect(VideoComposite.polarity(shadowShare: 0.6) == 1)
        #expect(VideoComposite.polarity(shadowShare: 0.05) == -1)
        var s = Self.state
        s.a?.recipe = .shadowplay
        s.keyPolarity = -0.4
        let u = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, video: s)
        #expect(u.videoKey == 1 && u.videoKeyAmt == -0.4)
        // A picture that is mostly shadow: the key covers nearly the frame, so the mix comes down.
        #expect(VideoComposite.keyGain(coverage: 0.2) == 1)
        #expect(abs(VideoComposite.keyGain(coverage: 0.7) - 0.5) < 1e-6)
        #expect(VideoComposite.keyGain(coverage: 1) == 0.4)
        var dark = s
        dark.keyCoverage = 0.7
        let ud = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, video: dark)
        #expect(abs(ud.videoMix - u.videoMix * 0.5) < 1e-5)
    }

    @Test func tintComesFromThePicture() throws {
        // Left half deep blue, right half bright orange.
        let w = 32, h = 32
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            if x < 16 { px[i] = 10; px[i + 1] = 20; px[i + 2] = 90 } else { px[i] = 250; px[i + 1] = 150; px[i + 2] = 40 }
        } }
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let img = try #require(ctx.makeImage())
        let t = VideoComposite.tint(of: img)
        #expect(t.tint.x > t.tint.z)            // highlight is orange
        #expect(t.shade.z > t.shade.x)          // shadow is blue
        #expect(max(t.shade.x, t.shade.y, t.shade.z) <= 0.14 + 1e-6)
        #expect(max(t.tint.x, t.tint.y, t.tint.z) >= 0.9)
    }
}
