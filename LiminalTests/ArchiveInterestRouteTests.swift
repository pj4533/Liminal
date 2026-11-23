import Testing
import Foundation
@testable import Liminal

/// The interest routes and pins (docs/decisions/archive-video.md A32), the full exclusions on every route, and
/// the offline curation script's mirror of the catalog.
struct ArchiveInterestRouteTests {

    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/archive-curate.py")

    /// `(name, text, allowsColour)` from the script's `QUERIES` list.
    static func scriptQueries(_ source: String) throws -> [(String, String, Bool)] {
        let body = try #require(source.range(of: "QUERIES = [").map { source[$0.upperBound...] })
        let list = try #require(body.range(of: "\n]").map { body[..<$0.lowerBound] })
        let row = try Regex(#"^\s*\("([^"]+)", '(.*)', (True|False)\),\s*$"#)
        return list.split(separator: "\n").compactMap { line -> (String, String, Bool)? in
            guard let m = try? row.wholeMatch(in: String(line)) else { return nil }
            return (String(m.output[1].substring!), String(m.output[2].substring!), m.output[3].substring! == "True")
        }
    }

    static func scriptExclusions(_ source: String) throws -> [String] {
        let body = try #require(source.range(of: "EXCLUDE = [").map { source[$0.upperBound...] })
        let list = try #require(body.range(of: "]").map { body[..<$0.lowerBound] })
        return list.matches(of: try Regex(#""([^"]+)""#)).map { String($0.output[1].substring!) }
    }

    @Test func scriptMirrorsTheCatalog() throws {
        let source = try String(contentsOf: Self.script, encoding: .utf8)
        let mirrored = try Self.scriptQueries(source)
        #expect(mirrored.count == ArchiveCatalog.queries.count)
        let catalog = Dictionary(uniqueKeysWithValues: ArchiveCatalog.queries.map { ($0.name, $0) })
        for (name, text, colour) in mirrored {
            let q = try #require(catalog[name], "script route \(name) is not in ArchiveCatalog.queries")
            #expect(q.text == text, "\(name) clause differs")
            #expect(q.allowsColour == colour, "\(name) colour flag differs")
        }
        #expect(try Self.scriptExclusions(source) == ArchiveCatalog.exclusions)
    }

    @Test func everyRouteCarriesTheFullExclusions() {
        for q in ArchiveCatalog.queries {
            let full = ArchiveCatalog.fullQuery(q)
            for term in q.excludedTerms {
                #expect(full.contains(term.contains(" ") ? "\"\(term)\"" : term), "\(q.name) misses \(term)")
            }
            #expect(full.contains("mediatype:movies"))
            #expect(full.contains("year:[1950 TO 1969]"))
            #expect(q.text.hasPrefix("collection:prelinger AND "))
            // Only drug education has exceptions; the interest routes have none.
            if q.name != "drug-education" { #expect(q.excludedTerms == ArchiveCatalog.exclusions) }
        }
    }

    @Test func interestRoutesHoldAClearMajorityOfSearches() throws {
        let interest = ArchiveCatalog.queries.filter(\.isInterest)
        #expect(Set(interest.map(\.name)) == ["machines", "perception", "recording", "ecosystems", "nightcity"])
        let total = ArchiveCatalog.queries.reduce(Float(0)) { $0 + $1.weight }
        let share = interest.reduce(Float(0)) { $0 + $1.weight } / total
        #expect(share >= 0.55 && share <= 0.65, "interest share \(share)")
        for q in interest {
            #expect(q.candidateWeight == 5)
            #expect(q.allowsColour)
        }
        // Existing routes keep their weights and candidate weights.
        let old = Dictionary(uniqueKeysWithValues: ArchiveCatalog.queries.filter { !$0.isInterest }.map { ($0.name, $0) })
        #expect(old.mapValues(\.weight) == ["newsreel": 3, "trippy": 10, "drug-education": 5, "educational": 2, "spaceage": 2, "bw": 1])
        #expect(old.mapValues(\.candidateWeight) == ["newsreel": 1, "trippy": 5, "drug-education": 5, "educational": 1, "spaceage": 1, "bw": 1])
    }

    @Test func everyPinNamesAnExistingRoute() throws {
        let names = Set(ArchiveCatalog.queries.map(\.name))
        for pin in ArchiveSeedList.pinned { #expect(names.contains(pin.query), "\(pin.id) names \(pin.query)") }
        #expect(ArchiveSeedList.pinned.count == ArchiveSeedList.pinnedIDs.count)
        // The reviewed interest pins take the 640x480 main encode, not the 320x240 derivative.
        let interestPins = ArchiveSeedList.pinned.filter { ["LivingSt1958", "SoundAndTheS", "SpringCo1952"].contains($0.id) }
        #expect(interestPins.count == 3)
        for pin in interestPins { #expect(pin.preferredFile == "\(pin.id).mp4") }
        // Lookalike uploads without a licence record and the two filtered films stay out.
        for id in ["Logic_by_Machine", "Sound_and_the_Story_The", "OnGuard1956", "HowtoLis1957"] {
            #expect(!ArchiveSeedList.pinnedIDs.contains(id))
        }
    }

    @Test func preferredFileWinsOverTheSmallerDerivative() throws {
        let files = [
            ArchiveFile(name: "SoundAndTheS.mp4", format: "h.264", size: "148640862", length: "1422.89"),
            ArchiveFile(name: "SoundAndTheS_512kb.mp4", format: "512Kb MPEG4", size: "103389250", length: "1422.89"),
        ]
        #expect(ArchiveCatalog.pickFile(files, preferSmallest: true)?.name == "SoundAndTheS_512kb.mp4")
        let pin = try #require(ArchiveSeedList.pinned.first { $0.id == "SoundAndTheS" })
        let preferred = files.filter { $0.name == pin.preferredFile }
        #expect(ArchiveCatalog.pickFile(preferred, preferSmallest: true)?.name == "SoundAndTheS.mp4")
    }

    @Test func bundledSeedsReachTheInterestRoutes() {
        let seeds = ArchiveSeedList.bundled()
        #expect(seeds.count >= 229)
        let names = Set(ArchiveCatalog.queries.map(\.name))
        for s in seeds { #expect(names.contains(s.query), "\(s.id) names \(s.query)") }
        let interest = Set(ArchiveCatalog.queries.filter(\.isInterest).map(\.name))
        #expect(seeds.filter { interest.contains($0.query) }.count >= 50)
    }

    @Test func cacheHoldsThePinsAndTwoDiscoveries() {
        // Thirteen pins measured about 3.02 GB (A31 sizes plus the three reviewed files, A32).
        #expect(ArchiveCachePolicy.capBytes == 4_000_000_000)
        #expect(ArchiveCachePolicy.poolTarget == ArchiveSeedList.pinned.count + 2)
    }
}
