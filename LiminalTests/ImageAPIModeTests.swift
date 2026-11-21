//
//  ImageAPIModeTests.swift
//  LiminalTests
//
//  API image mode (docs/plans/image-api-mode.md 9): the setting and flags, the bundled collections,
//  each provider's parsing on saved responses, the rights rule, both rotations, openness scoring
//  and the on-disk pool. No test touches the network or Gemini.
//

import Foundation
import CoreGraphics
import Testing
@testable import Liminal

// MARK: - Helpers

enum ImageAPIFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ImageAPI", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    static func source(id: String = "test-source", provider: String = "loc", weight: Double = 1,
                       pinned: [String] = [], rejectTitleWords: [String]? = nil) -> CuratedSource {
        CuratedSource(id: id, provider: provider, enabled: true, weight: weight, themes: [], collection: "c",
                      queries: [CuratedQuery(q: "q")], searches: nil, categories: nil,
                      pinned: pinned.map(FlexibleID.init), rejectTitleWords: rejectTitleWords,
                      requireTitleContains: nil, requireIIIF: true, requiresKey: nil, allowClassification: nil,
                      allowMonochrome: false,
                      mood: SourceMood(moods: [.serene, .eerie], subjectCategory: .landscape, energy: 0.3, warmth: 0.2),
                      license: "test")
    }

    static let context = ResolveContext(targetLongSide: 3072, maxBytes: 12_000_000, institution: "Test",
                                        allowlist: ImageCollections.bundled.licenseAllowlist)

    static func credit(source: String = "test-source", item: String = UUID().uuidString) -> ImageSourceCredit {
        ImageSourceCredit(providerID: "loc", sourceID: source, itemID: item, title: "Neon diner", creator: "Someone",
                          date: "1999", institution: "Library of Congress", license: "No known restrictions",
                          licenseURL: nil, sourceURL: "https://www.loc.gov/item/x/", imageURL: "https://tile.loc.gov/x.jpg")
    }

    static func metadata(source: String = "test-source", openness: Double = 0.7, saturation: Double = 0.4) -> ImageMetadata {
        let score = OpennessScore(shadowShare: 0.3, highlightShare: 0.1, keyShare: 0.3, calmShare: 0.4, edgeDensity: 0.03,
                                  paperShare: 0, saturation: saturation, openness: openness)
        return ImageMetadata(id: UUID(), createdAt: Date(), spec: Self.source(id: source).promptSpec, model: "api.loc",
                             pixelWidth: 60, pixelHeight: 40, mimeType: "image/jpeg", dominantColors: [],
                             measuredBrightness: 0.4, measuredSaturation: saturation, archiveReference: nil,
                             source: credit(source: source), openness: score)
    }

    static let jpeg: Data = {
        let img = image(width: 60, height: 40) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        return ImageStore.encodeJPEG(img)!
    }()

    static func tempRoot() -> (URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAPITests-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "ImageAPITests-\(UUID().uuidString)")!
        return (root, defaults)
    }
}

// MARK: - Setting and flags

struct ImageSourceSettingsTests {
    @Test func defaultIsAI() {
        #expect(ImageSource.defaultSource == .ai)
        #expect(ImageSource.resolve(stored: nil, debugFlag: nil) == .ai)
        #expect(ImageSource.resolve(stored: "bogus", debugFlag: nil) == .ai)
    }

    @Test func storedValueAndFlagOverride() {
        #expect(ImageSource.resolve(stored: "api", debugFlag: nil) == .api)
        #expect(ImageSource.resolve(stored: "ai", debugFlag: "API") == .api)
        #expect(ImageSource.resolve(stored: "api", debugFlag: "ai") == .ai)
        // An unknown flag value is ignored.
        #expect(ImageSource.resolve(stored: "api", debugFlag: "gemini") == .api)
        #expect(ImageSource.defaultsKey == "visual.imageSource")
        #expect(ImageSource.allCases.map(\.title) == ["AI", "API"])
    }

    /// Every API flag is in `anyImageAPIFlag`, which `blocksImageGeneration` includes (source check:
    /// launch flags are constants read once per process).
    @Test func everyAPIFlagBlocksGeneration() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Liminal/Utils/DebugLaunchOptions.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for key in ["LiminalImageSource", "LiminalImageProvider", "LiminalImageAPIOffline", "LiminalImageAPISeed",
                    "LiminalImageAPIFresh"] {
            #expect(text.contains("\"\(key)\""), "\(key) is read")
        }
        let any = try #require(text.range(of: "static var anyImageAPIFlag: Bool {"))
        let body = text[any.upperBound...].prefix(200)
        for name in ["imageSource", "imageProviders", "imageAPIOffline", "imageAPISeed", "imageAPIFresh"] {
            #expect(body.contains(name), "\(name) in anyImageAPIFlag")
        }
        let gate = try #require(text.range(of: "static var blocksImageGeneration: Bool {"))
        #expect(text[gate.upperBound...].prefix(1500).contains("|| anyImageAPIFlag"))
    }
}

// MARK: - Collections

struct ImageCollectionsTests {
    @Test func bundledJSONDecodes() throws {
        let c = ImageCollections.bundled
        #expect(c.version >= 2)
        #expect(c.sources.count >= 12)
        #expect(c.defaults.targetLongSide == 2528)
        #expect(c.defaults.storeBudgetBytes == 3_000_000_000)
    }

    /// Library of Congress sources allowed to be monochrome (added with D45).
    static let locMonochrome: Set<String> = []

    @Test func enabledSourcesAreComplete() {
        let c = ImageCollections.bundled
        let keyless: Set<String> = ["loc", "nasa", "wikimedia", "cma", "met", "dc", "aic"]
        for s in c.sources where s.enabled {
            #expect(keyless.contains(s.provider), "\(s.id) uses a keyless provider")
            #expect(c.providers[s.provider] != nil, "\(s.id) has a provider block")
            #expect(s.weight > 0)
            #expect(!s.mood.moods.isEmpty && s.mood.moods.count <= 4)
            #expect((0...1).contains(s.mood.energy) && (-1...1).contains(s.mood.warmth))
            #expect(!s.allQueries.isEmpty || !s.pinnedIDs.isEmpty, "\(s.id) has something to fetch")
            #expect(s.requiresKey == nil, "\(s.id) needs no key")
        }
        // Monochrome only where it is the subject (early photographs, the lunar surface, 1960s aerials);
        // display still caps it at one picture in `monochromeEvery` (plan section 13.4, D45).
        let monochrome: Set<String> = ["cma-early-photographs", "apollo-archive", "nasa-lunar-orbit",
                                       "nasa-cape-kennedy-aerials", "met-early-photographs"]
        #expect(Set(c.sources.filter { $0.allowMonochrome == true }.map(\.id)).isSubset(of: monochrome.union(Self.locMonochrome)))
    }

    @Test func everyProviderURLIsHTTPS() throws {
        let url = try #require(Bundle.main.url(forResource: "image-collections", withExtension: "json"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let providers = try #require(json["providers"] as? [String: [String: Any]])
        for (id, p) in providers {
            for key in ["search", "category", "assets", "object", "info"] {
                // "{iiifService}/info.json" starts from an https service id taken from a search result.
                if let template = p[key] as? String, !template.hasPrefix("{") {
                    #expect(template.hasPrefix("https://"), "\(id).\(key)")
                }
            }
        }
    }

    @Test func keyedSourcesAreDisabledWithoutTheirKey() {
        let c = ImageCollections.bundled
        let providers = ImageProviders.all(environment: [:])
        #expect(providers["si"] == nil)
        #expect(!c.activeSources(providers: Set(providers.keys), filter: nil).contains { $0.provider == "si" })
        #expect(ImageProviders.all(environment: ["SMITHSONIAN_API_KEY": "k"])["si"] != nil)
    }

    @Test func providerFilterMatchesProviderOrSourceIDs() {
        let c = ImageCollections.bundled
        let all = Set(ImageProviders.all(environment: [:]).keys)
        let nasa = c.activeSources(providers: all, filter: ["nasa"])
        #expect(!nasa.isEmpty && nasa.allSatisfy { $0.provider == "nasa" })
        #expect(c.activeSources(providers: all, filter: ["documerica-1970s"]).map(\.id) == ["documerica-1970s"])
    }

    @Test func titleRejectWordsMatchWholeWords() {
        let s = ImageAPIFixtures.source(rejectTitleWords: ["man", "portrait"])
        #expect(s.rejectsTitle("Portrait of a lady"))
        #expect(s.rejectsTitle("Old man by the sea"))
        #expect(!s.rejectsTitle("Manhattan skyline at night"))
        // requireTitleContains also accepts the provider's item id (Commons file names carry "NARA").
        var doc = s
        doc.requireTitleContains = "NARA"
        #expect(!doc.rejectsTitle("OIL REFINERY IN THE SUNSET", itemID: "File:OIL REFINERY IN THE SUNSET - NARA - 546384.jpg"))
        #expect(doc.rejectsTitle("A sunset", itemID: "File:A sunset.jpg"))
    }

    @Test func promptSpecCarriesTheSourceMood() {
        let spec = ImageAPIFixtures.source(id: "x").promptSpec
        #expect(spec.styleID == "api.x")
        #expect(spec.moods == [.serene, .eerie])
        #expect(spec.subjectCategory == .landscape)
    }
}

// MARK: - Provider parsing

struct ImageProviderParsingTests {
    @Test func locSearchKeepsIIIFAndDerivesTheFullSize() throws {
        let result = try LOCProvider.parseSearch(try ImageAPIFixtures.data("loc-search.json"))
        #expect(result.candidates.count == 2)
        #expect(result.next != nil)
        let noIIIF = result.candidates[0]
        #expect(noIIIF.hint == nil)   // 2018 item: 1024 px v.jpg only, skipped by requireIIIF
        let ok = result.candidates[1]
        #expect(ok.itemID == "2015632003")
        #expect(ok.hint == "https://tile.loc.gov/image-services/iiif/service:pnp:highsm:31900:31928")
        #expect(ok.width == 7360 && ok.height == 4912)   // pct:25 is 1840x1228
        #expect(ok.rights == "No known restrictions on publication.")
        #expect(ok.creator == "Highsmith, Carol M.")
        #expect(ok.pageURL == "https://www.loc.gov/item/2015632003/")
    }

    @Test func digitalCommonwealthKeepsTheIIIFImageAndTheReuseVerdict() throws {
        let result = try DigitalCommonwealthProvider.parseSearch(try ImageAPIFixtures.data("dc-search.json"))
        #expect(result.hasNext)
        let c = try #require(result.candidates.first)
        #expect(c.itemID == "commonwealth:xs55mj59t")
        #expect(c.hint == "commonwealth:xs55mj60k")
        #expect(c.title == "Frontier Motel, Omaha's finest motel")
        #expect(c.creator == "Tichnor Bros., Inc.")
        #expect(c.date == "ca. 1930–1945")
        #expect(c.rights == "no restrictions")
        #expect(ImageRights.canonical(c.rights!) == "No restrictions")
        #expect(c.pageURL == "https://ark.digitalcommonwealth.org/ark:/50959/xs55mj59t")
    }

    @Test func articTakesTheNativeSizeAndPublicDomainFlag() throws {
        let result = try ArticProvider.parseSearch(try ImageAPIFixtures.data("aic-search.json"))
        #expect(result.totalPages == 10)
        let c = try #require(result.candidates.first { $0.itemID == "15086" })
        #expect(c.hint == "7a63b68a-a84f-87b0-80a4-2848404f1ad6")
        #expect(c.width == 2933 && c.height == 2259)
        #expect(c.rights == "CC0")
        #expect(c.pageURL == "https://www.artic.edu/artworks/15086")
        #expect(ArticProvider.candidate(["id": 1, "image_id": "x", "is_public_domain": false, "title": "t"])?.rights
                    .flatMap(ImageRights.canonical) == nil)
    }

    @Test func locMastersStandInForTheMissingIIIFDerivative() throws {
        #expect(LOCProvider.masterIIIF(from: "https://tile.loc.gov/storage-services/service/pnp/fsac/1a33000/1a33800/1a33849v.jpg#h=715&w=1024")
                == "https://tile.loc.gov/image-services/iiif/master:pnp:fsac:1a33000:1a33800:1a33849u")
        #expect(LOCProvider.masterIIIF(from: "https://tile.loc.gov/storage-services/service/pnp/ppmsc/07700/07735r.jpg")
                == "https://tile.loc.gov/image-services/iiif/master:pnp:ppmsc:07700:07735u")
        #expect(LOCProvider.masterIIIF(from: "https://example.com/pnp/x/1v.jpg") == nil)

        let result = try LOCProvider.parseSearch(try ImageAPIFixtures.data("loc-search.json"), allowMaster: true)
        let master = result.candidates[0]   // the 2018 item that had only a 1024 px v.jpg
        #expect(master.hint == "https://tile.loc.gov/image-services/iiif/master:pnp:highsm:52000:52077u")
        #expect(master.width == nil && master.height == nil)   // read from info.json when resolved
        #expect(result.candidates[1].hint == "https://tile.loc.gov/image-services/iiif/service:pnp:highsm:31900:31928")
    }

    @Test func locItemAndInfo() throws {
        let item = try LOCProvider.parseItem(try ImageAPIFixtures.data("loc-item.json"), id: "2013631471")
        #expect(item.hint == "https://tile.loc.gov/image-services/iiif/service:pnp:highsm:24200:24293")
        #expect(item.width == 4048 && item.height == 4373)
        #expect(item.title?.hasPrefix("Neon sign for Mel's Drive-In") == true)
        #expect(item.creator == "Highsmith, Carol M.")
        #expect(item.date == "2013")
        let info = try LOCProvider.parseInfo(try ImageAPIFixtures.data("loc-info.json"))
        #expect(info.width == 7360 && info.height == 4912)
    }

    @Test func locResolveRequestsTheTargetSize() async throws {
        let c = ImageCandidate(providerID: "loc", itemID: "1", title: "A diner", creator: nil, date: nil, width: 7360,
                               height: 4912, rights: "No known restrictions on publication.", pageURL: "https://www.loc.gov/item/1/",
                               hint: "https://tile.loc.gov/image-services/iiif/service:pnp:highsm:1:2")
        let http = ImageHTTP(userAgent: "test", offline: true, hostGaps: [:], defaultGap: 0)
        let r = try await LOCProvider().resolve(c, source: ImageAPIFixtures.source(), context: ImageAPIFixtures.context, http: http)
        #expect(r.url.absoluteString == "https://tile.loc.gov/image-services/iiif/service:pnp:highsm:1:2/full/!3072,3072/0/default.jpg")
        #expect(r.width == 3072 && r.height == 2050)
        #expect(r.credit.license == "No known restrictions")
        #expect(await http.requestCount == 0)
    }

    @Test func nasaSearchAndAsset() throws {
        let result = try NASAProvider.parseSearch(try ImageAPIFixtures.data("nasa-search.json"))
        #expect(result.candidates.count == 2)
        #expect(result.hasNext)
        let first = result.candidates[0]
        #expect(first.itemID == "as13-60-8588")
        #expect(first.date == "1970")
        #expect(first.creator == "NASA JSC")
        #expect(first.pageURL == "https://images.nasa.gov/details/as13-60-8588")
        let original = try #require(NASAProvider.parseAsset(try ImageAPIFixtures.data("nasa-asset.json")))
        #expect(original.absoluteString == "https://images-assets.nasa.gov/image/as11-44-6549/as11-44-6549~orig.jpg")
        #expect(ImageRights.verdict(rightsText: NASAProvider.rights, allowlist: ImageAPIFixtures.context.allowlist)
                == .allowed(license: "Public domain"))
    }

    @Test func wikimediaCategoryAndTitles() throws {
        let page = try WikimediaProvider.parse(try ImageAPIFixtures.data("wikimedia-category.json"), thumbWidth: 3072)
        #expect(page.candidates.count == 2)
        #expect(page.next?.hasPrefix("file|") == true)
        let plate = try #require(page.candidates.first { $0.itemID == "File:Acephala. - Muscheln LCCN2014645038.jpg" })
        #expect(plate.imageURL?.contains("3840px-") == true)   // 6124 px original: scaled copy
        #expect(plate.rights == "Public domain")
        #expect(plate.creator?.contains("Haeckel") == true)

        let titles = try WikimediaProvider.parse(try ImageAPIFixtures.data("wikimedia-titles.json"), thumbWidth: 3072)
        let fungus = try #require(titles.candidates.first { $0.itemID == "File:Amanita muscaria qtl4.jpg" })
        #expect(fungus.rights == "CC BY-SA 3.0")
        #expect(fungus.creator == "Quartl")    // HTML stripped
        let sunset = try #require(titles.candidates.first { $0.itemID == "File:SUNSET - NARA - 544071.jpg" })
        #expect(sunset.imageURL?.contains("utm_content=original") == true)   // 3000 px: the original
        #expect(sunset.width == 3000 && sunset.height == 2023)
        #expect(sunset.creator == "Cornelius M. Keyes")
    }

    @Test func wikimediaSearchOffsetsAndTiffIsSkipped() async throws {
        let page = try WikimediaProvider.parse(try ImageAPIFixtures.data("wikimedia-search.json"), thumbWidth: 3072)
        #expect(page.next == "5")
        var tiff = try #require(page.candidates.first)
        tiff.mime = "image/tiff"
        let http = ImageHTTP(userAgent: "test", offline: true, hostGaps: [:], defaultGap: 0)
        await #expect(throws: CandidateRejected.self) {
            _ = try await WikimediaProvider().resolve(tiff, source: ImageAPIFixtures.source(provider: "wikimedia"),
                                                      context: ImageAPIFixtures.context, http: http)
        }
        var svg = tiff
        svg.mime = "image/svg+xml"
        await #expect(throws: CandidateRejected.self) {
            _ = try await WikimediaProvider().resolve(svg, source: ImageAPIFixtures.source(provider: "wikimedia"),
                                                      context: ImageAPIFixtures.context, http: http)
        }
    }

    @Test func clevelandSearch() throws {
        let result = try ClevelandProvider.parseSearch(try ImageAPIFixtures.data("cma-search.json"))
        #expect(result.total == 73)
        let first = try #require(result.candidates.first)
        #expect(first.rights == "CC0")
        #expect(first.width == 3400 && first.height == 2270)   // strings in the JSON
        #expect(first.imageURL?.hasSuffix("_print.jpg") == true)
        #expect(first.creator == "Utagawa Hiroshige")
    }

    @Test func metSearchAndObject() throws {
        let search = try MetProvider.parseSearch(try ImageAPIFixtures.data("met-search.json"))
        #expect(search.ids.first == "57196" && search.total == 198)
        let object = try MetProvider.parseObject(try ImageAPIFixtures.data("met-object.json"),
                                                 allowClassification: ["Prints", "Photographs"])
        #expect(object.title == "Landscape in the Mist")
        #expect(object.rights == "CC0")
        #expect(object.imageURL?.hasPrefix("https://images.metmuseum.org/") == true)

        var json = try #require(try JSONSerialization.jsonObject(with: try ImageAPIFixtures.data("met-object.json")) as? [String: Any])
        json["isPublicDomain"] = false
        let notPD = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: CandidateRejected.self) { _ = try MetProvider.parseObject(notPD, allowClassification: nil) }
        #expect(throws: CandidateRejected.self) {
            _ = try MetProvider.parseObject(try ImageAPIFixtures.data("met-object.json"), allowClassification: ["Furniture"])
        }
    }

    @Test func htmlBotWallMapsToBlocked() throws {
        let url = URL(string: "https://collectionapi.metmuseum.org/x")!
        let wall = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        #expect(throws: ImageFetchError.blocked) { try ImageHTTP.check(wall) }
        let htmlOK = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        #expect(throws: ImageFetchError.blocked) { try ImageHTTP.check(htmlOK) }
        let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        #expect(throws: ImageFetchError.http(404)) { try ImageHTTP.check(missing) }
        #expect(ImageFetchError.http(404).isItemFailure && !ImageFetchError.blocked.isItemFailure)
    }

    @Test func httpIsUpgradedAndOtherSchemesRefused() {
        #expect(ImageHTTP.secure("http://images-assets.nasa.gov/a.jpg")?.absoluteString == "https://images-assets.nasa.gov/a.jpg")
        #expect(ImageHTTP.secure("//upload.wikimedia.org/a.jpg")?.scheme == "https")
        #expect(ImageHTTP.secure("ftp://example.org/a.jpg") == nil)
    }

    @Test func offlineClientMakesNoRequests() async {
        let http = ImageHTTP(userAgent: "test", offline: true, hostGaps: [:], defaultGap: 0)
        await #expect(throws: ImageFetchError.offline) { _ = try await http.data(URL(string: "https://www.loc.gov/")!) }
        #expect(await http.requestCount == 0)
    }

    @Test func declaredSizeGate() {
        let d = ImageCollections.bundled.defaults
        #expect(CuratedImageFeed.coverCropFits(width: 3072, height: 2048, defaults: d))
        #expect(CuratedImageFeed.coverCropFits(width: 4096, height: 4096, defaults: d))   // square Hasselblad
        #expect(!CuratedImageFeed.coverCropFits(width: 1920, height: 1280, defaults: d))
        #expect(CuratedImageFeed.coverCropFits(width: 2026, height: 2651, defaults: d))   // within 2% of 2048 (D40)
        #expect(!CuratedImageFeed.coverCropFits(width: 4000, height: 1200, defaults: d))  // panorama too short
        // Decode size: the crop ends up about 3072 wide.
        #expect(CuratedImageFeed.decodeLongSide(width: 6124, height: 8664, target: 3072) == 4346)
        #expect(CuratedImageFeed.decodeLongSide(width: 3000, height: 2000, target: 3072) == 3000)
    }
}

// MARK: - Rights

struct ImageRightsTests {
    let allow = ImageCollections.bundled.licenseAllowlist

    @Test func allowlistedSpellingsAreAccepted() {
        for (text, label) in [("Public domain", "Public domain"), ("PD-US", "Public domain"), ("pd-old-70", "Public domain"),
                              ("CC0", "CC0"), ("cc0 1.0", "CC0"),
                              ("No known restrictions on publication.", "No known restrictions"),
                              ("CC BY-SA 4.0", "CC BY-SA 4.0"), ("CC-BY-SA-3.0", "CC BY-SA 3.0"),
                              ("CC BY-SA 3.0 de", "CC BY-SA 3.0"), ("CC BY 2.0", "CC BY 2.0")] {
            #expect(ImageRights.verdict(rightsText: text, allowlist: allow) == .allowed(license: label), "\(text)")
        }
    }

    @Test func otherRightsAreRejected() {
        for text in ["Rights status not evaluated.", "Publication may be restricted.", "CC BY-NC 4.0", "CC BY-ND 2.0",
                     "CC BY-NC-SA 3.0", "", "   ", "All rights reserved", "Copyrighted free use"] {
            if case .allowed = ImageRights.verdict(rightsText: text, allowlist: allow) { Issue.record("allowed \(text)") }
        }
        if case .allowed = ImageRights.verdict(rightsText: nil, allowlist: allow) { Issue.record("allowed nil") }
    }

    @Test func attributionAndDeedLinks() {
        var c = ImageAPIFixtures.credit()
        #expect(!c.requiresAttribution)
        c = ImageSourceCredit(providerID: "wikimedia", sourceID: "s", itemID: "i", title: "t", creator: "Quartl", date: nil,
                              institution: "Wikimedia Commons", license: "CC BY-SA 3.0", licenseURL: nil, sourceURL: "u", imageURL: "u")
        #expect(c.requiresAttribution)
        #expect(c.displayLine == "t · Quartl · Wikimedia Commons · CC BY-SA 3.0")
        #expect(ImageRights.licenseURL("CC BY-SA 3.0") == "https://creativecommons.org/licenses/by-sa/3.0/")
        #expect(ImageRights.licenseURL("CC0") == "https://creativecommons.org/publicdomain/zero/1.0/")
    }

    @Test func attributionLicencesNeedACreator() throws {
        let provider = WikimediaProvider()
        let source = ImageAPIFixtures.source(provider: "wikimedia")
        let url = URL(string: "https://upload.wikimedia.org/x.jpg")!
        var c = ImageCandidate(providerID: "wikimedia", itemID: "File:x.jpg", title: "Fly agaric", creator: "  ",
                               rights: "CC BY-SA 3.0")
        #expect(throws: CandidateRejected.self) {
            _ = try provider.credit(for: c, source: source, context: ImageAPIFixtures.context, imageURL: url)
        }
        c.creator = "Quartl"
        #expect(try provider.credit(for: c, source: source, context: ImageAPIFixtures.context, imageURL: url).creator == "Quartl")
        // Public domain needs no creator.
        c.creator = nil
        c.rights = "Public domain"
        #expect(try provider.credit(for: c, source: source, context: ImageAPIFixtures.context, imageURL: url).creator == nil)
    }
}

// MARK: - Rotation

struct ImageRotationTests {
    private func sources() -> [CuratedSource] {
        [ImageAPIFixtures.source(id: "a", provider: "loc", weight: 3),
         ImageAPIFixtures.source(id: "b", provider: "loc", weight: 2),
         ImageAPIFixtures.source(id: "c", provider: "nasa", weight: 3),
         ImageAPIFixtures.source(id: "d", provider: "wikimedia", weight: 1)]
    }

    @Test func sharesFollowWeightsAndRunsAreBroken() {
        let src = sources()
        var bag = ImageRotation.SourceBag()
        var rng = SeededRNG(seed: 7)
        var counts: [String: Int] = [:]
        var picks: [CuratedSource] = []
        let all = Set(src.map(\.id))
        for _ in 0..<10_000 {
            let s = ImageRotation.nextSource(sources: src, bag: &bag, available: all, using: &rng)!
            counts[s.id, default: 0] += 1
            picks.append(s)
        }
        for s in src {
            let share = Double(counts[s.id] ?? 0) / 10_000
            #expect(abs(share - s.weight / 9) < 0.04, "\(s.id) share \(share)")
        }
        for i in 1..<picks.count { #expect(picks[i].id != picks[i - 1].id) }
        for i in 2..<picks.count {
            #expect(!(picks[i].provider == picks[i - 1].provider && picks[i].provider == picks[i - 2].provider))
        }
    }

    @Test func unavailableSourcesAreSkipped() {
        var bag = ImageRotation.SourceBag()
        var rng = SeededRNG(seed: 1)
        for _ in 0..<50 {
            let s = ImageRotation.nextSource(sources: sources(), bag: &bag, available: ["c"], using: &rng)
            #expect(s?.id == "c")
        }
        #expect(ImageRotation.nextSource(sources: sources(), bag: &bag, available: [], using: &rng) == nil)
    }

    @Test func pinnedComeFirstAndSeenAreNeverDrawn() {
        var rng = SeededRNG(seed: 2)
        let pinned = ["p1", "p2"].map { ImageCandidate.stub(provider: "loc", id: $0) }
        let searched = ["s1", "s2"].map { ImageCandidate.stub(provider: "loc", id: $0) }
        let first = ImageRotation.nextCandidate(pinned: pinned, searched: searched, seen: [], using: &rng)
        #expect(first?.itemID.hasPrefix("p") == true)
        let after = ImageRotation.nextCandidate(pinned: pinned, searched: searched, seen: ["loc:p1", "loc:p2"], using: &rng)
        #expect(after?.itemID == "s1")
        #expect(ImageRotation.nextCandidate(pinned: pinned, searched: searched,
                                            seen: ["loc:p1", "loc:p2", "loc:s1", "loc:s2"], using: &rng) == nil)
    }

    private func pool(_ n: Int, sources: Int = 4, monochromeEvery: Int = 0) -> [ImageRotation.DisplayItem] {
        (0..<n).map { i in
            ImageRotation.DisplayItem(id: UUID(), sourceID: "s\(i % sources)", sourceWeight: 1, openness: 0.5,
                                      monochrome: monochromeEvery > 0 && i % monochromeEvery == 0, lastShown: nil)
        }
    }

    /// Simulates showing `steps` pictures, updating lastShown like the pool does.
    private func run(_ items: [ImageRotation.DisplayItem], steps: Int, seed: UInt64 = 3) -> [ImageRotation.DisplayItem] {
        var items = items
        var history = ImageRotation.DisplayHistory()
        var rng = SeededRNG(seed: seed)
        var shown: [ImageRotation.DisplayItem] = []
        var current: UUID?
        for _ in 0..<steps {
            let pick = ImageRotation.nextDisplay(pool: items, history: history, current: current, using: &rng)!
            history.record(sourceID: pick.sourceID, monochrome: pick.monochrome)
            let i = items.firstIndex { $0.id == pick.id }!
            items[i] = ImageRotation.DisplayItem(id: pick.id, sourceID: pick.sourceID, sourceWeight: pick.sourceWeight,
                                                 openness: pick.openness, monochrome: pick.monochrome, lastShown: history.serial)
            shown.append(pick)
            current = pick.id
        }
        return shown
    }

    @Test func noRepeatInsideTheRecencyWindow() {
        let shown = run(pool(60), steps: 300)
        for i in 0..<shown.count {
            let window = shown[max(0, i - 23)..<i]
            #expect(!window.contains { $0.id == shown[i].id }, "repeat at \(i)")
        }
    }

    @Test func neverTheSameSourceTwiceWithThreeOrMore() {
        let shown = run(pool(40, sources: 3), steps: 200)
        for i in 1..<shown.count { #expect(shown[i].sourceID != shown[i - 1].sourceID) }
    }

    @Test func monochromeCapHolds() {
        let shown = run(pool(60, monochromeEvery: 2), steps: 300)
        for i in 0..<shown.count where shown[i].monochrome {
            let previous = shown[max(0, i - 5)..<i]
            #expect(!previous.contains { $0.monochrome }, "two monochrome within 6 at \(i)")
        }
    }

    @Test func poolSmallerThanTheWindowShowsTheLeastRecent() {
        let items = (0..<5).map { i in
            ImageRotation.DisplayItem(id: UUID(), sourceID: "s\(i % 3)", sourceWeight: 1, openness: 0.5, monochrome: false,
                                      lastShown: 10 + i)
        }
        var history = ImageRotation.DisplayHistory()
        history.serial = 15
        history.recent = [.init(sourceID: "s1", monochrome: false)]
        var rng = SeededRNG(seed: 4)
        // Every picture is inside the 24-picture window: the oldest whose source differs from the last wins.
        #expect(ImageRotation.nextDisplay(pool: items, history: history, current: items[4].id, using: &rng)?.id == items[0].id)
    }

    @Test func smallPoolsStillRotate() {
        let one = pool(1)
        var rng = SeededRNG(seed: 1)
        #expect(ImageRotation.nextDisplay(pool: one, history: .init(), current: one[0].id, using: &rng)?.id == one[0].id)
        let shown = run(pool(3), steps: 12)
        for i in 1..<shown.count { #expect(shown[i].id != shown[i - 1].id) }
    }

    @Test func newArrivalsSurfaceFirst() {
        var items = pool(30)
        items = items.map { ImageRotation.DisplayItem(id: $0.id, sourceID: $0.sourceID, sourceWeight: 1, openness: 0.5,
                                                       monochrome: false, lastShown: 1) }
        let fresh = ImageRotation.DisplayItem(id: UUID(), sourceID: "s9", sourceWeight: 1, openness: 0.5, monochrome: false, lastShown: nil)
        var history = ImageRotation.DisplayHistory()
        history.serial = 200
        var hits = 0
        var rng = SeededRNG(seed: 5)
        for _ in 0..<1000 where ImageRotation.nextDisplay(pool: items + [fresh], history: history, current: nil, using: &rng)?.id == fresh.id {
            hits += 1
        }
        #expect(hits > 60)   // x3 boost: about 3/33 of draws
    }
}

// MARK: - Openness

struct ImageOpennessTests {
    @Test func darkSkyOverABrightStripIsOpen() {
        let img = ImageAPIFixtures.image(width: 300, height: 200) { ctx in
            ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 120))   // bottom 60% bright (CG origin is bottom-left)
        }
        let s = ImageOpenness.score(img)
        #expect(s.shadowShare > 0.3 && s.shadowShare < 0.5)
        #expect(s.keyShare == s.shadowShare)
        #expect(s.openness > 0.8)
        #expect(ImageOpenness.rejection(s, allowMonochrome: false) == nil)
    }

    @Test func pageOfTextIsADocument() {
        // White page with lines of heavy type (dense small text blurs to grey at 48x32; Vision's text
        // detector covers that case in the feed).
        let img = ImageAPIFixtures.image(width: 480, height: 320) { ctx in
            ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
            for y in stride(from: 10, to: 310, by: 40) {
                for x in stride(from: 20, to: 450, by: 60) { ctx.fill(CGRect(x: x, y: y, width: 40, height: 10)) }
            }
        }
        let s = ImageOpenness.score(img)
        #expect(ImageOpenness.looksLikeDocument(s))
        #expect(ImageOpenness.rejection(s, allowMonochrome: true) != nil)
    }

    @Test func uniformMidGreyHasNoKeyAndGreyIsMonochrome() {
        let grey = ImageAPIFixtures.image(width: 300, height: 200) { ctx in
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let s = ImageOpenness.score(grey)
        #expect(s.keyShare < 0.04)
        #expect(ImageOpenness.rejection(s, allowMonochrome: true)?.contains("no room") == true)

        let ramp = ImageAPIFixtures.image(width: 300, height: 200) { ctx in
            for x in 0..<300 {
                let v = CGFloat(x) / 299
                ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 200))
            }
        }
        let r = ImageOpenness.score(ramp)
        #expect(ImageOpenness.isMonochrome(r))
        #expect(ImageOpenness.rejection(r, allowMonochrome: false)?.contains("monochrome") == true)
        #expect(ImageOpenness.rejection(r, allowMonochrome: true) == nil)
    }

    @Test func portraitWindowPicksTheOpenEnd() throws {
        // Portrait: busy noise at the bottom, a calm dark band at the top.
        let img = ImageAPIFixtures.image(width: 200, height: 400) { ctx in
            var rng = SeededRNG(seed: 9)
            for y in stride(from: 0, to: 400, by: 4) {
                for x in stride(from: 0, to: 200, by: 4) {
                    let v = CGFloat(Double.random(in: 0.35...0.65, using: &rng))
                    ctx.setFillColor(CGColor(red: v, green: v * 0.8, blue: 0.3, alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
            ctx.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 300, width: 200, height: 100))   // top quarter (CG y up)
        }
        let window = try #require(ImageOpenness.bestWindow(img))
        #expect(window.midY < 0.4)   // top-left origin: towards the calm top, away from the busy bottom
        #expect(abs(window.width * 200 / (window.height * 400) - 1.5) < 0.02)
        // Within 1.3...1.8 nothing is cut.
        #expect(ImageOpenness.bestWindow(ImageAPIFixtures.image(width: 300, height: 200) { _ in }) == nil)
    }
}

// MARK: - Pool

struct CuratedImagePoolTests {
    @Test func separateFolderAndEpochFromTheAICache() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ai = ImageStore(root: root, defaults: defaults)
        let pool = CuratedImagePool(root: root, defaults: defaults)
        #expect(ai.directory != pool.store.directory)
        // Save one in each.
        let aiMeta = ImageAPIFixtures.metadata()
        try ai.save(jpeg: ImageAPIFixtures.jpeg, metadata: aiMeta, clearGeneration: ai.clearGeneration)
        pool.loadIfNeeded()
        try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: ImageAPIFixtures.metadata(), budget: 1 << 40)
        // Migrating (purging) the AI cache leaves the pool; migrating the pool leaves the AI cache.
        defaults.set(0, forKey: ImageStore.epochDefaultsKey)
        ai.migrateIfNeeded()
        #expect(ai.imageCount() == 0)
        #expect(pool.store.imageCount() == 1)
        try ai.save(jpeg: ImageAPIFixtures.jpeg, metadata: ImageAPIFixtures.metadata(), clearGeneration: ai.clearGeneration)
        defaults.set(0, forKey: CuratedImagePool.epochKey)
        pool.store.migrateIfNeeded()
        #expect(pool.store.imageCount() == 0)
        #expect(ai.imageCount() == 1)
        #expect(pool.store.maxImageCount == nil)
    }

    @Test func sidecarRoundTripWithCreditAndOldSidecarsDecode() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let meta = ImageAPIFixtures.metadata()
        try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: meta, budget: 1 << 40)
        let entry = try #require(pool.store.entries().first)
        #expect(entry.metadata?.source == meta.source)
        #expect(entry.metadata?.openness == meta.openness)
        // A second pool instance reads it back from disk with its ledger record.
        let again = CuratedImagePool(root: root, defaults: defaults)
        again.loadIfNeeded()
        #expect(again.count == 1)
        #expect(again.seenKeys.contains(meta.source!.candidateKey))
        // An AI sidecar written before `source` existed still decodes.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
        json["source"] = nil
        json["openness"] = nil
        let old = try JSONDecoder().decode(ImageMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.source == nil && old.openness == nil)
    }

    @Test func sweepRemovesOnlyJunk() {
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
        let now = Date()
        let junk = CuratedPoolPolicy.sweep(
            files: ["\(a).jpg", "\(a).json", "\(b).jpg", "\(c).json", "ledger.json", "tmp", "notes.txt", ".DS_Store"],
            tmpFiles: [("old.download", now.addingTimeInterval(-7200)), ("new.download", now.addingTimeInterval(-60))],
            now: now)
        #expect(Set(junk) == Set(["\(b).jpg", "\(c).json", "notes.txt", ".DS_Store", "tmp/old.download"]))
    }

    @Test func evictionOnlyOverBudgetLeastRecentlyShownFirst() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let size = Int64(ImageAPIFixtures.jpeg.count)
        var ids: [UUID] = []
        for _ in 0..<3 {
            let m = ImageAPIFixtures.metadata()
            #expect(try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: m, budget: size * 3).isEmpty)
            ids.append(m.id)
        }
        pool.markShown(ids[1])
        pool.markShown(ids[0])
        pool.markShown(ids[2])
        let removedKey = pool.items.first { $0.id == ids[1] }!.candidateKey
        let fourth = ImageAPIFixtures.metadata()
        let evicted = try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: fourth, budget: size * 3)
        #expect(evicted == [ids[1]])
        #expect(pool.count == 3)
        #expect(!pool.seenKeys.contains(removedKey))   // can be fetched again
        #expect(pool.store.imageFiles().count == 3)
    }

    @Test func clearRemovesPicturesAndLedger() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: ImageAPIFixtures.metadata(), budget: 1 << 40)
        pool.recordRejected("loc:x", reason: "test")
        pool.clear()
        #expect(pool.count == 0 && pool.seenKeys.isEmpty && pool.store.imageCount() == 0)
    }

    /// A picture whose ingest began before Clear is refused, and the cleared ledger stays cleared on disk.
    @Test func pictureInFlightDuringClearIsRefused() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        pool.recordRejected("loc:before", reason: "test")
        let generation = pool.store.clearGeneration
        pool.clear()
        #expect(throws: ImageStore.StoreError.self) {
            try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: ImageAPIFixtures.metadata(), budget: 1 << 40,
                         clearGeneration: generation)
        }
        #expect(pool.count == 0 && pool.store.imageCount() == 0)
        pool.recordRejected("loc:after", reason: "test")
        let again = CuratedImagePool(root: root, defaults: defaults)
        again.loadIfNeeded()
        #expect(again.seenKeys == ["loc:after"])
    }
}

// MARK: - Feed reservations

struct CuratedImageFeedTests {
    /// A picture picked for display but never shown is not held back forever.
    @Test func droppedReservationsExpire() throws {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = CuratedImagePool(root: root, defaults: defaults)
        pool.loadIfNeeded()
        let feed = CuratedImageFeed(collections: .bundled, pool: pool, providers: ImageProviders.all(environment: [:]),
                                    offline: true, filter: nil, seed: 1)
        let source = try #require(feed.sources.first)
        let meta = ImageAPIFixtures.metadata(source: source.id)
        try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: meta, budget: 1 << 40)
        #expect(feed.nextDisplay(current: nil)?.id == meta.id)
        #expect(feed.nextDisplay(current: nil) == nil)   // reserved
        feed.expireReservations(olderThan: 0)
        #expect(feed.nextDisplay(current: nil)?.id == meta.id)
    }
}

// MARK: - Queue in API mode

@MainActor
struct ImageQueueAPIModeTests {
    private func makeQueue() -> (ImageQueue, CuratedImagePool, URL) {
        let (root, defaults) = ImageAPIFixtures.tempRoot()
        let pool = CuratedImagePool(root: root, defaults: defaults)
        let ai = ImageStore(root: root, defaults: defaults)
        let feed = CuratedImageFeed(collections: .bundled, pool: pool, providers: ImageProviders.all(environment: [:]),
                                    offline: true, filter: nil, seed: 1)
        return (ImageQueue(store: ai, source: .api, feed: { feed }), pool, root)
    }

    /// API mode only shows pool pictures and never records a Gemini generation.
    @Test func apiDisplayLeavesTheGenerationLedgerUnchanged() async throws {
        let (queue, pool, root) = makeQueue()
        defer { try? FileManager.default.removeItem(at: root) }
        pool.loadIfNeeded()
        let source = try #require(ImageCollections.bundled.sources.first { $0.enabled })
        for _ in 0..<3 {
            try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: ImageAPIFixtures.metadata(source: source.id), budget: 1 << 40)
        }
        let before = UserDefaults.standard.data(forKey: GenerationBudget.Keys.ledger)
        queue.start()
        try await Task.sleep(for: .seconds(3))
        let reserved = await queue.reserveForFill(excluding: nil)
        queue.stop()
        #expect(reserved?.metadata?.source != nil)
        #expect(UserDefaults.standard.data(forKey: GenerationBudget.Keys.ledger) == before)
        #expect(queue.activeSource == .api)
        #expect(queue.activeStore.directory == pool.store.directory)
    }

    /// API -> AI -> API while running: the stores swap, pending pictures are dropped, and the AI side
    /// (an automation test host) never generates.
    @Test func switchingSourcesSwapsStoresWithoutGenerating() async throws {
        let (queue, pool, root) = makeQueue()
        defer { try? FileManager.default.removeItem(at: root) }
        pool.loadIfNeeded()
        let source = try #require(ImageCollections.bundled.sources.first { $0.enabled })
        for _ in 0..<3 {
            try pool.add(jpeg: ImageAPIFixtures.jpeg, metadata: ImageAPIFixtures.metadata(source: source.id), budget: 1 << 40)
        }
        let before = UserDefaults.standard.data(forKey: GenerationBudget.Keys.ledger)
        queue.start()
        try await Task.sleep(for: .seconds(2))
        await queue.switchSource(.ai)
        #expect(queue.activeSource == .ai)
        #expect(queue.imageSource == .ai)
        #expect(queue.activeStore.directory != pool.store.directory)
        #expect(queue.queuedCount == 0)
        try await Task.sleep(for: .seconds(1))
        await queue.switchSource(.api)
        #expect(queue.activeSource == .api)
        try await Task.sleep(for: .seconds(2))
        #expect(queue.queuedCount > 0)
        queue.stop()
        #expect(UserDefaults.standard.data(forKey: GenerationBudget.Keys.ledger) == before)
    }

    @Test func emptyPoolGivesNoFillButStandbyArt() async {
        let (queue, _, root) = makeQueue()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await queue.reserveForFill(excluding: nil) == nil)
        #expect(queue.standbyImage(index: 0) != nil)
    }
}

// MARK: - Scan edges

struct ScanEdgeTrimmerTests {
    /// 1200x800 slide: a black rebate 8% wide on the left, 2% elsewhere, a mid-grey picture inside.
    static func slide() -> CGImage {
        let w = 1200, h = 800
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0.55, green: 0.5, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 96, y: 16, width: w - 96 - 24, height: h - 32))
        return ctx.makeImage()!
    }

    @Test func blackRebateIsTrimmedSideBySide() throws {
        let rect = try #require(ScanEdgeTrimmer.contentRect(Self.slide()))
        #expect(rect.minX >= 96 && rect.minX <= 96 + 40)        // left rebate plus the inset
        #expect(rect.maxX <= 1200 - 24 && rect.maxX >= 1200 - 24 - 40)
        #expect(rect.minY >= 16 && rect.maxY <= 800 - 16)
    }

    @Test func aPictureWithoutRebateStillLosesTheMinimumTrim() throws {
        let ctx = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        let rect = try #require(ScanEdgeTrimmer.contentRect(ctx.makeImage()!))
        #expect(rect.minX >= 27 && rect.minX <= 30)   // 3% of 900, rounded up on the 300 px proxy
        #expect(rect.width >= 900 * 0.93 && rect.width <= 900 * 0.94 + 1)
    }
}
