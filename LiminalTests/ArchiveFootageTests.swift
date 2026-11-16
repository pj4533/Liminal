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
        // Over 120 MB, shorter than 25 s, or tiny: nothing.
        #expect(ArchiveCatalog.pickFile([ArchiveFile(name: "B.mp4", format: "h.264", size: "130000000")], preferSmallest: false) == nil)
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
        // With shown segments the re-roll keeps away from them when it can.
        var far = 0
        for _ in 0..<200 {
            let s = ArchiveCatalog.segmentStart(duration: 900, length: 40, avoid: [300, 450], rng: &rng)
            if abs(s - 300) >= 20 && abs(s - 450) >= 20 { far += 1 }
        }
        #expect(far >= 190)
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
        #expect(ArchiveCachePolicy.victims(clips, incoming: 200_000_000) == ["d", "b"])
        // Under the cap and the pool size: nothing.
        #expect(ArchiveCachePolicy.victims(clips, incoming: 10_000_000).isEmpty)
        // The clip on screen is never evicted.
        #expect(ArchiveCachePolicy.victims(clips, incoming: 200_000_000, protected: ["d"]) == ["b"])
    }

    @Test func neverBelowMinimumAndPoolCap() {
        let three = [Self.clip("a", mb: 600, used: 1), Self.clip("b", mb: 600, used: 2), Self.clip("c", mb: 600, used: 3)]
        // Over the cap, but the pool (counting the incoming clip) never drops below 3.
        #expect(ArchiveCachePolicy.victims(three, incoming: 600_000_000) == ["a"])
        #expect(ArchiveCachePolicy.victims(Array(three.prefix(2)), incoming: 900_000_000).isEmpty)
        let many = (0..<12).map { Self.clip("k\($0)", mb: 10, used: Double($0)) }
        #expect(ArchiveCachePolicy.victims(many, incoming: 10_000_000) == ["k0"])   // 13th clip: one goes
    }

    @Test func replacementIsMostUsed() {
        let clips = [Self.clip("a", mb: 10, used: 10, count: 2), Self.clip("b", mb: 10, used: 5, count: 4),
                     Self.clip("c", mb: 10, used: 1, count: 4)]
        #expect(ArchiveCachePolicy.replacement(clips) == "c")   // tie on count: the less recent
        #expect(ArchiveCachePolicy.replacement(clips, protected: ["c"]) == "b")
    }

    @Test func storeAddsEvictsAndPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("liminal-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveClipStore(directory: dir)
        await store.load()
        for i in 0..<3 {
            let f = dir.appendingPathComponent("in\(i).bin")
            try Data(repeating: 1, count: 10).write(to: f)
            try await store.add(Self.clip("x\(i)", mb: 1, used: Double(i)), from: f, protected: [])
        }
        await store.markUsed("x1", segmentStart: 42)
        await store.markBad("bad1")
        let again = ArchiveClipStore(directory: dir)
        await again.load()
        let clips = await again.clips
        #expect(clips.map(\.id).sorted() == ["x0", "x1", "x2"])
        #expect(clips.first { $0.id == "x1" }?.useCount == 1)
        #expect(clips.first { $0.id == "x1" }?.shownStarts == [42])
        #expect(await again.badIDs == ["bad1"])
        await again.remove("x0")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x0.mp4").path))
    }
}

struct VideoMomentDirectorTests {
    static let calm = VideoMomentDirector.Conditions(transitionRunning: false, imageAge: 20, musicIntensity: 0.3,
                                                     effectIntensity: 0.5)

    /// Runs a director for `seconds` at 2 Hz; returns the plans it began (plans begin at the tick time).
    static func run(seed: UInt64, timing: VideoMomentDirector.Timing, seconds: Double,
                    conditions: (Double) -> VideoMomentDirector.Conditions = { _ in calm }) -> [MomentPlan] {
        var d = VideoMomentDirector(seed: seed, timing: timing)
        var plans: [MomentPlan] = []
        var t = 0.0
        while t < seconds {
            if case .begin(let b) = d.tick(elapsed: t, conditions: conditions(t), hasClip: true) {
                let p = MomentPlan(clipID: "c", segmentStart: 0, rate: b.rate, look: b.look, seed: b.seed, start: t,
                                   fadeIn: b.fadeIn, hold: b.hold, fadeOut: b.fadeOut)
                d.didBegin(p)
                plans.append(p)
            }
            t += 0.5
        }
        return plans
    }

    @Test func normalScheduleBoundsOverManySeeds() {
        let timing = VideoMomentDirector.Timing.amount(.normal)
        for seed in UInt64(0)..<1000 {
            let plans = Self.run(seed: seed, timing: timing, seconds: 1800)
            #expect(!plans.isEmpty)
            guard let first = plans.first else { continue }
            #expect(first.start >= 90 && first.start <= 150.5)
            for p in plans {
                #expect(p.start >= 60)
                #expect(p.length >= 30 - 1e-9 && p.length <= 80 + 1e-9)
                #expect(p.fadeIn >= 8 && p.fadeIn <= 14)
                #expect(p.fadeOut >= 10 && p.fadeOut <= 16)
                #expect(p.rate >= 0.6 && p.rate <= 0.85)
                if p.look == .emerge { #expect(p.hold <= 20) }
            }
            for (a, b) in zip(plans, plans.dropFirst()) {
                let gap = b.start - a.end
                #expect(gap >= 150 - 0.5 && gap <= 360 + 1)
                #expect(a.look != b.look)
            }
        }
    }

    @Test func rareAndOftenFirstMoments() {
        for seed in UInt64(0)..<200 {
            let rare = Self.run(seed: seed, timing: .amount(.rare), seconds: 400).first!.start
            #expect(rare >= 150 && rare <= 240.5)
            let often = Self.run(seed: seed, timing: .amount(.often), seconds: 200).first!.start
            #expect(often >= 60 && often <= 90.5)
        }
    }

    @Test func waitsForTransitionsFreshImagesAndLoudMusic() {
        let timing = VideoMomentDirector.Timing(first: 100...100, gap: 200...200)
        // A transition runs from 95 to 110 and the image is fresh until 118: the start waits to 118.
        let plans = Self.run(seed: 1, timing: timing, seconds: 300) { t in
            .init(transitionRunning: t >= 95 && t < 110, imageAge: t < 110 ? 2 : t - 110, musicIntensity: 0.2,
                  effectIntensity: 0.5)
        }
        #expect(plans.first.map { $0.start >= 118 && $0.start <= 118.5 } == true)
        // Loud music forever: waits the full 60 s, then goes anyway.
        let loud = Self.run(seed: 1, timing: timing, seconds: 300) { _ in
            .init(transitionRunning: false, imageAge: 50, musicIntensity: 0.95, effectIntensity: 0.5)
        }
        #expect(loud.first.map { abs($0.start - 160) <= 0.5 } == true)
        // Constant transitions: starts after the 30 s image wait.
        let busy = Self.run(seed: 1, timing: timing, seconds: 300) { _ in
            .init(transitionRunning: true, imageAge: 1, musicIntensity: 0.2, effectIntensity: 0.5)
        }
        #expect(busy.first.map { abs($0.start - 130) <= 0.5 } == true)
    }

    @Test func noClipPostpones() {
        var d = VideoMomentDirector(seed: 2, timing: .forced)
        #expect(d.tick(elapsed: 6, conditions: Self.calm, hasClip: false) == .none)
        #expect(d.nextDue == 21)
    }

    @Test func forcedAndPinnedLook() {
        var d = VideoMomentDirector(seed: 5, timing: .forced, pinnedLook: .window)
        guard case .begin(let b) = d.tick(elapsed: 5, conditions: Self.calm, hasClip: true) else {
            Issue.record("forced director did not begin at 5 s"); return
        }
        #expect(b.look == .window)
    }

    @Test func emergeOnlyAtHigherIntensity() {
        var rng = MusicRNG(seed: 9)
        for _ in 0..<500 {
            #expect(VideoMomentDirector.chooseLook(last: nil, intensity: 0.3, rng: &rng) != .emerge)
            let l = VideoMomentDirector.chooseLook(last: .imprint, intensity: 0.9, rng: &rng)
            #expect(l != .imprint)
        }
    }

    @Test func envelopeShape() {
        var p = MomentPlan(clipID: "c", segmentStart: 0, rate: 0.7, look: .phantom, seed: 0, start: 10,
                           fadeIn: 10, hold: 20, fadeOut: 10)
        #expect(p.envelope(at: 9) == 0)
        #expect(abs(p.envelope(at: 15) - 0.5) < 1e-6)
        #expect(p.envelope(at: 25) == 1)
        #expect(abs(p.envelope(at: 45) - 0.5) < 1e-6)
        #expect(p.envelope(at: 50) == 0)
        #expect(abs(p.sourceLength - 28) < 1e-4)   // rate is a Float
        // Early fade out continues from the current level, within the new duration.
        p.fadeOutEarly(at: 25, duration: 2)
        #expect(p.end == 27)
        #expect(p.envelope(at: 26) < 1 && p.envelope(at: 26) > 0)
        #expect(p.envelope(at: 27.5) == 0)
    }

    @Test func clipChoiceAvoidsTheLastClip() {
        let clips = ["a", "b", "c"].enumerated().map { ArchiveCachePolicyTests.clip($1, mb: 10, used: Double($0)) }
        var rng = MusicRNG(seed: 4)
        var counts: [String: Int] = [:]
        for _ in 0..<600 {
            let c = VideoMomentDirector.chooseClip(clips, lastID: "a", rng: &rng)!
            #expect(c.id != "a")
            counts[c.id, default: 0] += 1
        }
        #expect((counts["b"] ?? 0) > (counts["c"] ?? 0))   // least recently used is likelier
        #expect(VideoMomentDirector.chooseClip([clips[0]], lastID: "a", rng: &rng)?.id == "a")
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
        // 25 original + 2 vibrance + 6 transition + 11 footage floats, no padding (EffectsRenderer.metal).
        #expect(MemoryLayout<EffectsUniforms>.size == 44 * 4)
        #expect(MemoryLayout<EffectsUniforms>.stride == 44 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoMix) == 33 * 4)
        #expect(MemoryLayout<EffectsUniforms>.offset(of: \.videoShadeB) == 43 * 4)
    }

    @Test func mixFormula() {
        // envelope x ceiling x (0.75 + 0.25 drive) x (0.55 + 0.45 settled)
        let m = VideoComposite.mix(Self.state, intensity: 0.5, drive: 1, settled: 1)
        #expect(abs(m - 0.75) < 1e-6)
        let low = VideoComposite.mix(Self.state, intensity: 0.5, drive: 0, settled: 0)
        #expect(abs(low - 0.75 * 0.75 * 0.55) < 1e-6)
        var half = Self.state
        half.envelope = 0.5
        #expect(abs(VideoComposite.mix(half, intensity: 0.5, drive: 1, settled: 1) - 0.375) < 1e-6)
        var constant = Self.state
        constant.envelope = 0
        constant.constantMix = 0.4
        #expect(VideoComposite.mix(constant, intensity: 0, drive: 0, settled: 0) == 0.4)
        // Emerge is absent at intensity 0.
        var emerge = Self.state
        emerge.look = .emerge
        #expect(VideoComposite.mix(emerge, intensity: 0, drive: 1, settled: 1) == 0)
        // Ceilings rise with intensity and stay below 1.
        for look in VideoLook.allCases {
            let c = [0, 0.25, 0.5, 0.75, 1].map { VideoComposite.ceiling(look, intensity: Float($0)) }
            #expect(c == c.sorted())
            #expect(c.allSatisfy { $0 <= 0.9 })
        }
    }

    @Test func settledHoldsBackDuringAndAfterACrossfade() {
        #expect(VideoComposite.settled(imageAge: 1, transitionDuration: 4, inTransition: true) == 0)
        #expect(VideoComposite.settled(imageAge: 4, transitionDuration: 4, inTransition: false) == 0)
        #expect(VideoComposite.settled(imageAge: 10, transitionDuration: 4, inTransition: false) == 1)
        #expect(VideoComposite.settled(imageAge: nil, transitionDuration: 4, inTransition: false) == 1)
    }

    @Test func computeWritesVideoUniforms() {
        let u = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, look: EffectLook(intensity: 0.5),
                                                video: Self.state)
        #expect(u.videoMix > 0.3 && u.videoMix <= 0.75)
        #expect(u.videoLook == 3)
        #expect(u.videoSeed == 0.4)
        #expect(abs(u.videoAspect - (4.0 / 3.0) / 1.5) < 1e-6)
        #expect(u.videoTintR == 0.9 && u.videoShadeB == 0.02)
        // Everything else matches the no-footage uniforms.
        var v = u
        v.videoMix = 0; v.videoLook = 0; v.videoSeed = 0; v.videoScale = 0; v.videoAspect = 0
        v.videoTintR = 0; v.videoTintG = 0; v.videoTintB = 0; v.videoShadeR = 0; v.videoShadeG = 0; v.videoShadeB = 0
        let off = EffectsUniformsComputer.compute(time: 300, transitionProgress: 0, look: EffectLook(intensity: 0.5))
        #expect(withUnsafeBytes(of: v) { Data($0) } == withUnsafeBytes(of: off) { Data($0) })
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
