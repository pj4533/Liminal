//
//  ImageRepeatTests.swift
//  LiminalTests
//
//  A curated picture is never shown twice while a new one is available (decision D48): the display
//  rotation, the first frame, catalogue aliases across providers and the perceptual fingerprint.
//  No network.
//

import Foundation
import CoreGraphics
import Testing
@testable import Liminal

private func item(_ source: String = "s0", lastShown: Int? = nil, monochrome: Bool = false) -> ImageRotation.DisplayItem {
    ImageRotation.DisplayItem(id: UUID(), sourceID: source, sourceWeight: 1, openness: 0.5, monochrome: monochrome,
                              lastShown: lastShown)
}

private func pattern(seed: UInt64, width: Int = 600, height: Int = 400, shift: Double = 0) -> CGImage {
    ImageAPIFixtures.pattern(seed: seed, width: width, height: height, shift: shift)
}

struct ImageRepeatRotationTests {
    @Test func aShownPictureNeverBeatsANewOne() {
        // 60 pictures shown long ago, one new picture from the source just shown and monochrome right after
        // a monochrome: the source and monochrome rules yield, the new picture still wins every draw.
        let old = (0..<60).map { item("s\($0 % 4)", lastShown: $0 + 1) }
        let fresh = item("s1", monochrome: true)
        var history = ImageRotation.DisplayHistory()
        history.serial = 500
        history.recent = [.init(sourceID: "s1", monochrome: true)]
        var rng = SeededRNG(seed: 9)
        for _ in 0..<500 {
            #expect(ImageRotation.nextDisplay(pool: old + [fresh], history: history, current: nil, using: &rng)?.id == fresh.id)
        }
    }

    @Test func theSourceRuleChoosesAmongNewPicturesOnly() {
        let new = [item("s0"), item("s1"), item("s2")]
        let shown = (0..<30).map { item("s\($0 % 3 + 3)", lastShown: $0 + 1) }
        var history = ImageRotation.DisplayHistory()
        history.serial = 200
        history.recent = [.init(sourceID: "s0", monochrome: false)]
        var rng = SeededRNG(seed: 3)
        for _ in 0..<300 {
            let pick = ImageRotation.nextDisplay(pool: new + shown, history: history, current: nil, using: &rng)
            #expect(pick?.lastShown == nil)
            #expect(pick?.sourceID != "s0")
        }
    }

    /// Offline (nothing new can arrive): a pool of n cycles with no picture back within 3n/4 displays.
    @Test func anOfflinePoolCyclesLeastRecentlyShownFirst() {
        var items = (0..<40).map { item("s\($0 % 5)", lastShown: $0 + 1) }
        var history = ImageRotation.DisplayHistory()
        history.serial = 40
        var rng = SeededRNG(seed: 11)
        var shown: [UUID] = []
        var current: UUID? = items.last?.id
        for _ in 0..<400 {
            let pick = ImageRotation.nextDisplay(pool: items, history: history, current: current, using: &rng)!
            history.record(sourceID: pick.sourceID, monochrome: pick.monochrome)
            let i = items.firstIndex { $0.id == pick.id }!
            items[i] = ImageRotation.DisplayItem(id: pick.id, sourceID: pick.sourceID, sourceWeight: 1, openness: 0.5,
                                                 monochrome: false, lastShown: history.serial)
            shown.append(pick.id)
            current = pick.id
        }
        for i in 0..<shown.count {
            #expect(!shown[max(0, i - 29)..<i].contains(shown[i]), "back after fewer than 30 at \(i)")
        }
    }

    /// A two-hour Lo-Fi session (257 pictures at 28 s) over a pool of 300 pictures already shown, with
    /// ingest adding one new picture per display: nothing is shown twice. Before D48 about 85% were repeats.
    @Test func aLongSessionWithIngestShowsNoRepeat() {
        var items = (0..<300).map { item("s\($0 % 7)", lastShown: $0 + 1) }
        var history = ImageRotation.DisplayHistory()
        history.serial = 300
        var rng = SeededRNG(seed: 21)
        var current: UUID?
        var repeats = 0
        for k in 0..<257 {
            while items.filter({ $0.lastShown == nil }).count < 12 { items.append(item("s\((k + items.count) % 7)")) }
            let pick = ImageRotation.nextDisplay(pool: items, history: history, current: current, using: &rng)!
            if pick.lastShown != nil { repeats += 1 }
            history.record(sourceID: pick.sourceID, monochrome: false)
            let i = items.firstIndex { $0.id == pick.id }!
            items[i] = ImageRotation.DisplayItem(id: pick.id, sourceID: pick.sourceID, sourceWeight: 1, openness: 0.5,
                                                 monochrome: false, lastShown: history.serial)
            current = pick.id
        }
        #expect(repeats == 0)
    }
}

struct ImageIdentityTests {
    @Test func commonsCopiesOfLibraryOfCongressScansShareTheLCCN() {
        let loc = ImageCandidate.stub(provider: "loc", id: "2017657809")
        let commons = ImageCandidate.stub(provider: "wikimedia", id: "File:Kotau Point. West Coast LCCN2017657809.jpg")
        #expect(ImageIdentity.aliases(of: loc).contains("~lccn:2017657809"))
        #expect(ImageIdentity.isKnown(commons, in: ImageIdentity.aliases(of: loc)))
        #expect(ImageIdentity.isKnown(loc, in: ImageIdentity.aliases(of: commons)))
    }

    @Test func nasaFramesMatchTheirCommonsUploads() {
        let nasa = ImageCandidate.stub(provider: "nasa", id: "as08-14-2383")
        let commons = ImageCandidate.stub(provider: "wikimedia", id: "File:NASA-Apollo8-Dec24-Earthrise AS08-14-2383HR.jpg")
        #expect(ImageIdentity.isKnown(commons, in: ImageIdentity.aliases(of: nasa)))
        let mission = ImageCandidate.stub(provider: "nasa", id: "s65-34661")
        #expect(ImageIdentity.isKnown(ImageCandidate.stub(provider: "wikimedia", id: "File:S65-34661.jpg"),
                                      in: ImageIdentity.aliases(of: mission)))
        #expect(ImageIdentity.aliases(providerID: "wikimedia", itemID: "File:Pillars PIA15985 big.png").contains("~nasa:PIA15985"))
    }

    @Test func documericaPrintsUploadedTwiceShareTheNARANumber() {
        let a = ImageCandidate.stub(provider: "wikimedia", id: "File:SUNSET - NARA - 544071.jpg")
        let b = ImageCandidate.stub(provider: "wikimedia", id: "File:Sunset over the bay, 1973 - NARA - 544071.tif.jpg")
        #expect(ImageIdentity.isKnown(b, in: ImageIdentity.aliases(of: a)))
        let c = ImageCandidate.stub(provider: "wikimedia", id: "File:SUNSET - NARA - 544655.jpg")
        #expect(!ImageIdentity.isKnown(c, in: ImageIdentity.aliases(of: a)))
    }

    @Test func commonsTitlesIgnoreUnderscoresAndCase() {
        let a = ImageCandidate.stub(provider: "wikimedia", id: "File:Aurora_over_Brastad.jpg")
        let b = ImageCandidate.stub(provider: "wikimedia", id: "File:Aurora over Brastad.jpg")
        #expect(ImageIdentity.isKnown(b, in: ImageIdentity.aliases(of: a)))
    }

    @Test func unrelatedIdsShareNothing() {
        let ids: [(String, String)] = [("loc", "2010630400"), ("loc", "2013633512"), ("nasa", "as11-40-5903"),
                                       ("cma", "120227"), ("met", "36491"), ("wikimedia", "File:Fly agaric.jpg")]
        let sets = ids.map { ImageIdentity.aliases(providerID: $0.0, itemID: $0.1) }
        for i in 0..<sets.count { for j in 0..<sets.count where i != j { #expect(sets[i].isDisjoint(with: sets[j])) } }
        // A museum number is never read as an LCCN.
        #expect(ImageIdentity.aliases(providerID: "cma", itemID: "2017657809").isEmpty)
    }

    @Test func nextCandidateSkipsAStoredPictureUnderAnotherId() {
        var rng = SeededRNG(seed: 1)
        let known: Set<String> = ["loc:2017657809", "~lccn:2017657809"]
        let searched = [ImageCandidate.stub(provider: "wikimedia", id: "File:Kotau Point LCCN2017657809.jpg"),
                        ImageCandidate.stub(provider: "wikimedia", id: "File:Something else.jpg")]
        #expect(ImageRotation.nextCandidate(pinned: [], searched: searched, seen: known, using: &rng)?.itemID == "File:Something else.jpg")
    }
}

struct ImageFingerprintTests {
    @Test func copiesMatchAndDifferentPicturesDoNot() throws {
        let a = try #require(ImageFingerprint.of(pattern(seed: 1)))
        // Another size, a re-encoded JPEG, a 1% shift: the same picture.
        let resized = try #require(ImageFingerprint.of(pattern(seed: 1, width: 2400, height: 1600)))
        #expect(a.matches(resized))
        let jpeg = try #require(ImageStore.encodeJPEG(pattern(seed: 1), quality: 0.5))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try jpeg.write(to: url)
        #expect(a.matches(try #require(ImageFingerprint.of(fileAt: url))))
        #expect(a.matches(try #require(ImageFingerprint.of(pattern(seed: 1, shift: 0.01)))))
        // Other pictures do not.
        var matches = 0
        for seed in 2..<60 where a.matches(try #require(ImageFingerprint.of(pattern(seed: UInt64(seed))))) { matches += 1 }
        #expect(matches == 0)
    }

    @Test func plainDarkPicturesAreNotAllOneAnother() throws {
        // Night skies: two different gradients of near-black must not collapse into one picture.
        let up = ImageAPIFixtures.image(width: 300, height: 200) { ctx in
            for y in 0..<200 { ctx.setFillColor(CGColor(gray: Double(y) / 200 * 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: y, width: 300, height: 1)) }
        }
        let across = ImageAPIFixtures.image(width: 300, height: 200) { ctx in
            for x in 0..<300 { ctx.setFillColor(CGColor(gray: Double(x) / 300 * 0.15, alpha: 1)); ctx.fill(CGRect(x: x, y: 0, width: 1, height: 200)) }
        }
        #expect(!(try #require(ImageFingerprint.of(up))).matches(try #require(ImageFingerprint.of(across))))
        // The same layout in another colour (a red and a teal nebula centred on black) is another picture.
        func blob(_ r: Double, _ g: Double, _ b: Double) -> CGImage {
            ImageAPIFixtures.image(width: 300, height: 200) { ctx in
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
                ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 90, y: 50, width: 120, height: 100))
            }
        }
        #expect(!(try #require(ImageFingerprint.of(blob(0.9, 0.2, 0.2)))).matches(try #require(ImageFingerprint.of(blob(0.1, 0.7, 0.7)))))
        #expect((try #require(ImageFingerprint.of(blob(0.9, 0.2, 0.2)))).matches(try #require(ImageFingerprint.of(blob(0.85, 0.22, 0.2)))))
    }
}

struct ImageRepeatPoolTests {
    private func patternJPEG(_ seed: UInt64) -> Data { ImageAPIFixtures.patternJPEG(seed) }

    @Test func storedFingerprintsAndAliasesKeepCopiesOut() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let fp = try #require(ImageFingerprint.of(pattern(seed: 5)))
        let meta = ImageAPIFixtures.metadata()
        try pool.add(jpeg: patternJPEG(5), metadata: meta, budget: 1 << 40, fingerprint: fp, aliases: ["~lccn:2017657809"])
        #expect(pool.duplicate(of: try #require(ImageFingerprint.of(pattern(seed: 5, width: 1800, height: 1200))))?.id == meta.id)
        #expect(pool.duplicate(of: try #require(ImageFingerprint.of(pattern(seed: 6)))) == nil)
        #expect(pool.knownIdentities.contains("~lccn:2017657809"))
        // Read back from disk.
        let again = CuratedImagePool(root: root, defaults: defaults)
        again.loadIfNeeded()
        #expect(again.knownIdentities.contains("~lccn:2017657809"))
        #expect(again.duplicate(of: fp)?.id == meta.id)
    }

    @Test func evictionForgetsAliasesAndFingerprints() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let jpeg = patternJPEG(7)
        let size = Int64(jpeg.count)
        let first = ImageAPIFixtures.metadata()
        let fp = try #require(ImageFingerprint.of(pattern(seed: 7)))
        try pool.add(jpeg: jpeg, metadata: first, budget: size, fingerprint: fp, aliases: ["~nasa:AS08-14-2383"])
        pool.markShown(first.id)
        let evicted = try pool.add(jpeg: patternJPEG(8), metadata: ImageAPIFixtures.metadata(), budget: size + size / 2)
        #expect(evicted == [first.id])
        #expect(!pool.knownIdentities.contains("~nasa:AS08-14-2383"))
        #expect(pool.duplicate(of: fp) == nil)
        #expect(pool.ledger.fingerprints[first.id] == nil)
    }

    /// A pool stored before D48: the backfill fingerprints it from its JPEGs and keeps one copy of a
    /// picture stored twice, with the later "last shown".
    @Test func backfillRemovesTheLaterCopyOfAPictureStoredTwice() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let t = Date()
        let original = ImageAPIFixtures.metadata(createdAt: t)
        let copy = ImageAPIFixtures.metadata(createdAt: t.addingTimeInterval(60))
        let other = ImageAPIFixtures.metadata(createdAt: t.addingTimeInterval(120))
        try pool.add(jpeg: patternJPEG(3), metadata: original, budget: 1 << 40)
        try pool.add(jpeg: ImageStore.encodeJPEG(pattern(seed: 3, width: 900, height: 600), quality: 0.6)!, metadata: copy, budget: 1 << 40)
        try pool.add(jpeg: patternJPEG(4), metadata: other, budget: 1 << 40)
        pool.markShown(original.id)
        pool.markShown(other.id)
        pool.markShown(copy.id)
        let removed = pool.backfillFingerprints()
        #expect(removed == [copy.id])
        #expect(pool.count == 2 && pool.store.entries().count == 2)
        #expect(pool.ledger.shown[original.id]?.lastShown == 3)
        #expect(pool.ledger.candidates[copy.source!.candidateKey]?.rejected?.hasPrefix("duplicate") == true)
        #expect(pool.backfillFingerprints().isEmpty)   // nothing left to do
    }

    /// A ledger written before D48 (no aliases or fingerprints) keeps its shown history.
    @Test func olderLedgerDecodesWithItsHistory() throws {
        var ledger = CuratedLedger()
        let id = UUID()
        ledger.shown[id] = .init(lastShown: 41, count: 2)
        ledger.history.serial = 41
        ledger.candidates["loc:1"] = .init(stored: id, rejected: nil, date: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(ledger)) as? [String: Any])
        json["aliases"] = nil
        json["fingerprints"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(CuratedLedger.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.shown[id]?.lastShown == 41 && old.history.serial == 41 && old.candidates["loc:1"]?.stored == id)
        #expect(old.aliases.isEmpty && old.fingerprints.isEmpty)
    }
}

struct ImageRepeatFeedTests {
    /// The launch frame is the rotation's pick: a never-shown picture, not a random (possibly just seen) one.
    @Test func theFirstFrameIsANewPicture() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let feed = CuratedImageFeed(collections: .bundled, pool: pool, providers: ImageProviders.all(environment: [:]),
                                    offline: true, filter: nil, seed: 2)
        let source = try #require(feed.sources.first)
        for _ in 0..<8 {
            let m = ImageAPIFixtures.metadata(source: source.id)
            try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: m, budget: 1 << 40)
            pool.markShown(m.id)
        }
        let fresh = ImageAPIFixtures.metadata(source: source.id)
        try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: fresh, budget: 1 << 40)
        #expect(feed.anyPicture()?.id == fresh.id)
    }

    /// Showing a picture records it before it is released, so the next pick never takes it as new.
    @Test func aShownPictureIsNotPickedAgainNext() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let feed = CuratedImageFeed(collections: .bundled, pool: pool, providers: ImageProviders.all(environment: [:]),
                                    offline: true, filter: nil, seed: 4)
        let source = try #require(feed.sources.first)
        var metas: [UUID: ImageMetadata] = [:]
        for _ in 0..<6 {
            let m = ImageAPIFixtures.metadata(source: source.id)
            try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: m, budget: 1 << 40)
            metas[m.id] = m
        }
        var seen: [UUID] = []
        for _ in 0..<6 {
            let entry = try #require(feed.nextDisplay(current: seen.last))
            feed.markShown(try #require(metas[entry.id]))
            seen.append(entry.id)
        }
        #expect(Set(seen).count == 6)
    }
}
