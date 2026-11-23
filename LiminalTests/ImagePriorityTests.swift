//
//  ImagePriorityTests.swift
//  LiminalTests
//
//  The interest packs and the priority share of the curated feed (docs/decisions/images.md D130):
//  the governor's rule, a seeded ingest simulation with unequal admission rates, the fallbacks, and the
//  bundled collection (the twelve packs are priority sources, the existing sources are unchanged).
//  No test touches the network.
//

import Foundation
import Testing
@testable import Liminal

struct ImagePriorityRuleTests {
    @Test func dueOnlyBelowTheTarget() {
        #expect(ImageRotation.priorityDue(recent: [], target: 0.6))
        #expect(!ImageRotation.priorityDue(recent: [], target: 0))
        #expect(!ImageRotation.priorityDue(recent: [false, false], target: 0))
        #expect(!ImageRotation.priorityDue(recent: [false], target: -1))
        #expect(ImageRotation.priorityDue(recent: [false, false, false], target: 0.6))
        #expect(!ImageRotation.priorityDue(recent: [true, true, true], target: 0.6))
        // 3 of 5 is exactly 0.6: not below the target.
        #expect(!ImageRotation.priorityDue(recent: [true, true, true, false, false], target: 0.6))
        #expect(ImageRotation.priorityDue(recent: [true, true, false, false, false], target: 0.6))
        #expect(!ImageRotation.priorityDue(recent: Array(repeating: true, count: 40), target: 1.0))
        #expect(ImageRotation.priorityDue(recent: Array(repeating: true, count: 39) + [false], target: 1.0))
    }
}

struct ImagePriorityRotationTests {
    private func source(_ id: String, _ provider: String, _ weight: Double, priority: Bool) -> CuratedSource {
        var s = ImageAPIFixtures.source(id: id, provider: provider, weight: weight)
        s.priority = priority ? true : nil
        return s
    }

    private func sources() -> [CuratedSource] {
        [source("p-loc", "loc", 4, priority: true), source("p-wiki", "wikimedia", 3, priority: true),
         source("p-nasa", "nasa", 3, priority: true), source("p-cma", "cma", 1, priority: true),
         source("o-loc", "loc", 3, priority: false), source("o-wiki", "wikimedia", 2, priority: false),
         source("o-nasa", "nasa", 3, priority: false), source("o-dc", "dc", 1, priority: false)]
    }

    /// 2,000 attempts where interest candidates are admitted 30% of the time and the others 70%:
    /// the share of admitted pictures from priority sources lands in 55-65%, where weight alone
    /// (11 of 20 weight, admitted at less than half the rate) would give about 34%.
    @Test func governorHoldsTheAdmittedShareDespiteUnequalAdmission() {
        let src = sources()
        let byID = Dictionary(uniqueKeysWithValues: src.map { ($0.id, $0) })
        var bags = ImageRotation.PriorityBags()
        var rng = SeededRNG(seed: 42)
        var admitRNG = SeededRNG(seed: 4242)
        var stored: [Bool] = []   // oldest first
        var picks: [CuratedSource] = []
        let all = Set(src.map(\.id))
        for _ in 0..<2_000 {
            let recent = Array(stored.suffix(ImageRotation.priorityWindow).reversed())
            let due = ImageRotation.priorityDue(recent: recent, target: 0.6)
            let s = ImageRotation.nextSource(sources: src, bags: &bags, available: all, due: due, using: &rng)!
            picks.append(s)
            let rate = byID[s.id]!.isPriority ? 0.3 : 0.7
            if Double.random(in: 0..<1, using: &admitRNG) < rate { stored.append(s.isPriority) }
        }
        let share = Double(stored.filter { $0 }.count) / Double(stored.count)
        #expect(share > 0.55 && share < 0.65, "admitted priority share \(share)")
        // Every source still draws, and the run rules still hold across the two bags.
        for s in src { #expect(picks.contains { $0.id == s.id }, "\(s.id) drawn") }
        for i in 1..<picks.count { #expect(picks[i].id != picks[i - 1].id) }
        for i in 2..<picks.count {
            #expect(!(picks[i].provider == picks[i - 1].provider && picks[i].provider == picks[i - 2].provider))
        }
    }

    /// Inside a group the weighted draw still follows the weights.
    @Test func weightsSplitTheDrawInsideTheGroup() {
        let src = sources()
        var bags = ImageRotation.PriorityBags()
        var rng = SeededRNG(seed: 9)
        var counts: [String: Int] = [:]
        let all = Set(src.map(\.id))
        for _ in 0..<5_500 {
            let s = ImageRotation.nextSource(sources: src, bags: &bags, available: all, due: true, using: &rng)!
            #expect(s.isPriority)
            counts[s.id, default: 0] += 1
        }
        for s in src where s.isPriority {
            let share = Double(counts[s.id] ?? 0) / 5_500
            #expect(abs(share - s.weight / 11) < 0.05, "\(s.id) share \(share)")
        }
    }

    /// With every priority source dry or backing off, the others fill in; nothing returns nil.
    @Test func allPriorityDryFallsBackToTheOthers() {
        let src = sources()
        var bags = ImageRotation.PriorityBags()
        var rng = SeededRNG(seed: 3)
        let others = Set(src.filter { !$0.isPriority }.map(\.id))
        for _ in 0..<200 {
            let s = ImageRotation.nextSource(sources: src, bags: &bags, available: others, due: true, using: &rng)
            #expect(s != nil && !(s!.isPriority))
        }
        // And the reverse: no other source available while the share is met.
        let priority = Set(src.filter(\.isPriority).map(\.id))
        for _ in 0..<200 {
            let s = ImageRotation.nextSource(sources: src, bags: &bags, available: priority, due: false, using: &rng)
            #expect(s?.isPriority == true)
        }
        #expect(ImageRotation.nextSource(sources: src, bags: &bags, available: [], due: true, using: &rng) == nil)
    }

    /// Governor off (`due` nil): the same picks, in the same order, as the single bag before D130.
    @Test func governorOffKeepsTheOldSequence() {
        let src = sources()
        let all = Set(src.map(\.id))
        var bag = ImageRotation.SourceBag()
        var bags = ImageRotation.PriorityBags()
        var a = SeededRNG(seed: 11), b = SeededRNG(seed: 11)
        for _ in 0..<1_000 {
            let old = ImageRotation.nextSource(sources: src, bag: &bag, available: all, using: &a)
            let new = ImageRotation.nextSource(sources: src, bags: &bags, available: all, due: nil, using: &b)
            #expect(old?.id == new?.id)
        }
        #expect(bag == bags.main)
    }
}

struct ImagePriorityFeedTests {
    private func feed(filter: [String]?, collections: ImageCollections = .bundled) -> (CuratedImageFeed, URL) {
        let root = ImageAPIFixtures.tempRoot()
        let pool = CuratedImagePool(root: root)
        pool.loadIfNeeded()
        let feed = CuratedImageFeed(collections: collections, pool: pool, providers: ImageProviders.all(environment: [:]),
                                    offline: true, filter: filter, seed: 1, preview: nil)
        return (feed, root)
    }

    @Test func governorRunsOnlyWithBothGroupsActive() throws {
        let (mixed, r1) = feed(filter: nil)
        defer { try? FileManager.default.removeItem(at: r1) }
        #expect(mixed.governedShare == 0.6)
        #expect(mixed.priorityDue() == true)   // an empty pool is due

        let (packsOnly, r2) = feed(filter: ImagePriorityCollectionTests.packIDs)
        defer { try? FileManager.default.removeItem(at: r2) }
        #expect(packsOnly.governedShare == nil)

        let (oldOnly, r3) = feed(filter: ["loc-highsmith-roadside", "nasa-space-age"])
        defer { try? FileManager.default.removeItem(at: r3) }
        #expect(oldOnly.governedShare == nil)
        #expect(oldOnly.priorityDue() == nil)
    }

    /// The newest stored pictures decide: 40 old-source pictures make the packs due, and once priority
    /// pictures are 60% of the newest 40 they are not.
    @Test func dueFollowsTheNewestStoredPictures() throws {
        let (feed, root) = feed(filter: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<40 {
            let meta = ImageAPIFixtures.metadata(source: "loc-highsmith-roadside", createdAt: start.addingTimeInterval(Double(i)))
            try feed.pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: meta, budget: 1 << 40)
        }
        #expect(feed.priorityDue() == true)
        for i in 0..<24 {
            let meta = ImageAPIFixtures.metadata(source: "commons-analog-machines", createdAt: start.addingTimeInterval(100 + Double(i)))
            try feed.pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: meta, budget: 1 << 40)
        }
        #expect(feed.pool.newestSourceIDs(1) == ["commons-analog-machines"])
        #expect(feed.priorityDue() == false)
    }

    /// A collection without `priorityShare` (every collection before D130) has no governor.
    @Test func absentShareTurnsTheGovernorOff() throws {
        let url = try #require(Bundle.main.url(forResource: "image-collections", withExtension: "json"))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var defaults = try #require(json["defaults"] as? [String: Any])
        defaults["priorityShare"] = nil
        json["defaults"] = defaults
        let c = try ImageCollections.load(JSONSerialization.data(withJSONObject: json))
        #expect(c.defaults.priorityShare == nil)
        let (feed, root) = feed(filter: nil, collections: c)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(feed.governedShare == nil)
        #expect(feed.priorityDue() == nil)
    }
}

struct ImagePriorityCollectionTests {
    static let packIDs = ["loc-highsmith-record-rooms", "loc-highsmith-stations-and-domes", "commons-analog-machines",
                          "commons-record-machines", "commons-inner-worlds", "commons-night-infrastructure",
                          "nasa-machine-rooms", "nasa-imagined-habitats", "dc-tichnor-stations", "cma-quiet-water",
                          "aic-rail-and-ponds", "met-water-and-nocturnes"]

    /// Every source before D130 with its weight (0 = disabled). None may change, be disabled or turn priority.
    static let existing: [String: Double] = [
        "loc-highsmith-roadside": 3, "loc-highsmith-landscape": 2, "loc-fsa-owi-color": 2, "nasa-space-age": 3,
        "nasa-deep-space": 1, "documerica-1970s": 3, "fungi-photographs": 2, "fungi-plates": 1, "haeckel-art-forms": 1,
        "landsat-earth-as-art": 1, "photochrom-landscapes": 2, "cma-ukiyoe-landscapes": 1, "cma-early-photographs": 1,
        "met-landscapes": 1, "si-american-landscapes": 0, "documerica-western-landscapes": 2,
        "documerica-smog-and-neon": 2, "aurora-and-milky-way": 1, "galaxies-hubble-webb": 1, "forests-featured": 1,
        "apollo-archive": 1, "american-west-painters": 1, "shin-hanga-pinned": 1, "nasa-orbital-earth-1960s": 2,
        "nasa-lunar-orbit": 1, "nasa-aurora-from-orbit": 1, "nasa-cape-kennedy-aerials": 1,
        "cma-american-landscapes": 1, "cma-weather-prints": 1, "met-american-tonalists": 1,
        "met-early-photographs": 1, "met-hiroshige-night": 1, "dc-tichnor-postcards": 3, "aic-landscapes": 1,
        "loc-margolies-roadside": 3, "loc-photochrom": 1, "loc-prokudin-gorskii": 1, "loc-detroit-landscapes": 1,
        "loc-japanese-prints": 1, "loc-gottscho-fireworks": 1, "loc-fsa-owi-bw-landscapes": 1,
        "loc-popular-graphic-arts-moonlight": 1, "loc-highsmith-space-fair": 1, "loc-matson-desert": 1,
    ]

    @Test func theTwelvePacksArePrioritySources() throws {
        let c = ImageCollections.bundled
        #expect(c.defaults.priorityShare == 0.6)
        for id in Self.packIDs {
            let s = try #require(c.source(id: id), "\(id) exists")
            #expect(s.enabled && s.isPriority && s.weight >= 1 && s.weight <= 6, "\(id)")
            #expect(!s.allQueries.isEmpty, "\(id) searches")
        }
        #expect(Set(c.sources.filter(\.isPriority).map(\.id)) == Set(Self.packIDs))
        #expect(c.sources.count == Self.existing.count + Self.packIDs.count)
    }

    @Test func existingSourcesAreUnchanged() throws {
        let c = ImageCollections.bundled
        #expect(Self.existing.count == 44)
        for (id, weight) in Self.existing {
            let s = try #require(c.source(id: id), "\(id) still exists")
            #expect(s.priority == nil, "\(id) is not a priority source")
            if weight == 0 {
                #expect(!s.enabled, "\(id) stays disabled")
            } else {
                #expect(s.enabled, "\(id) stays enabled")
                #expect(s.weight == weight, "\(id) keeps weight \(weight)")
            }
        }
        // Every existing source is still in the rotation.
        let active = Set(c.activeSources(providers: Set(ImageProviders.all(environment: [:]).keys), filter: nil).map(\.id))
        #expect(Set(Self.existing.filter { $0.value > 0 }.keys).isSubset(of: active))
    }

    /// The same search in the same collection twice, or a picture pinned twice, is a mistake.
    @Test func noDuplicateSearchesOrPins() {
        let c = ImageCollections.bundled
        var searches: [String: String] = [:]
        var pins: [String: String] = [:]
        for s in c.sources {
            let scope = [s.provider, s.collection ?? "", s.partof ?? ""].joined(separator: "/")
            for q in s.allQueries {
                let key = scope + " " + q.key
                #expect(searches[key] == nil, "\(key) in \(s.id) and \(searches[key] ?? "")")
                searches[key] = s.id
            }
            for p in s.pinnedIDs {
                let key = s.provider + ":" + p
                #expect(pins[key] == nil, "\(key) pinned in \(s.id) and \(pins[key] ?? "")")
                pins[key] = s.id
            }
        }
    }
}
