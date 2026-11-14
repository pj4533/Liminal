//
//  PromptBuilderTests.swift
//  LiminalTests
//
//  Seeded tests for the prompt grammar. `printSample` writes 20 prompts to the
//  test log so wording changes can be eyeballed in CI output.
//

import Foundation
import Testing
@testable import Liminal

struct PromptBuilderTests {

    let builder = PromptBuilder()

    @Test func deterministic() {
        let a = builder.batch(count: 50, seed: 7)
        let b = builder.batch(count: 50, seed: 7)
        #expect(a == b)
        let c = builder.batch(count: 50, seed: 8)
        #expect(a != c)
    }

    @Test func libraryIsValid() {
        let problems = PromptLibrary.standard.validate()
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func libraryHasPlannedSize() {
        let lib = PromptLibrary.standard
        #expect(lib.styles.count == 16)
        #expect(lib.palettes.count == 17)
        #expect(lib.subjects.count >= 110)
        #expect(lib.compositions.count == 8)
        let photographic = lib.styles.filter { $0.family == .photographic }.map(\.weight).reduce(0, +)
        let total = lib.styles.map(\.weight).reduce(0, +)
        #expect(abs(photographic / total - 0.78) < 0.01)
    }

    /// Two images belong to the same series that holds `kinds`.
    private func sameSeries(_ a: PromptSpec, _ b: PromptSpec, holding kinds: [SeriesKind]) -> Bool {
        guard let sa = a.series, let sb = b.series else { return false }
        return sa.id == sb.id && kinds.contains(sa.kind)
    }

    @Test func noNearRepeats() {
        let specs = builder.batch(count: 300, seed: 42)
        for i in specs.indices {
            for j in (i + 1)..<min(specs.count, i + 41) {
                let a = specs[i], b = specs[j]
                let gap = j - i
                if gap <= 2 && a.styleID == b.styleID {
                    #expect(sameSeries(a, b, holding: [.styleSet]), "style \(a.styleID) repeats at \(i),\(j)")
                }
                if gap <= 3 && a.paletteID == b.paletteID {
                    #expect(sameSeries(a, b, holding: [.paletteRun]), "palette \(a.paletteID) repeats at \(i),\(j)")
                }
                if a.subjectID == b.subjectID {
                    #expect(sameSeries(a, b, holding: [.subjectStudy]), "subject \(a.subjectID) repeats at \(i),\(j)")
                }
            }
        }
    }

    @Test func coverage() {
        let lib = PromptLibrary.standard
        let specs = builder.batch(count: 1000, seed: 3)
        let totalWeight = lib.styles.map(\.weight).reduce(0, +)
        for style in lib.styles {
            let n = specs.filter { $0.styleID == style.id }.count
            #expect(n > 0, "style \(style.id) never drawn")
            let share = Double(n) / Double(specs.count)
            #expect(share <= 2.5 * style.weight / totalWeight, "style \(style.id) share \(share)")
        }
        for palette in lib.palettes {
            #expect(specs.contains { $0.paletteID == palette.id }, "palette \(palette.id) never drawn")
        }
        for category in SubjectCategory.allCases {
            #expect(specs.contains { $0.subjectCategory == category }, "category \(category) never drawn")
        }
        for kind in TransformationKind.allCases {
            #expect(specs.contains { $0.transformationKind == kind }, "kind \(kind) never drawn")
        }
        for composition in lib.compositions {
            #expect(specs.contains { $0.compositionID == composition.id }, "composition \(composition.id) never drawn")
        }
        #expect(specs.contains { $0.needsStrongSurreal })
        #expect(specs.contains { $0.series != nil })
    }

    @Test func wordBudget() {
        for spec in builder.batch(count: 500, seed: 11) {
            #expect((70...140).contains(spec.wordCount), "\(spec.wordCount) words: \(spec.text)")
            #expect(spec.text.contains(PromptLibrary.fullBleedSentence))
            #expect(spec.promptVersion == PromptLibrary.version)
            #expect((2...4).contains(spec.moods.count))
            #expect(!spec.text.contains("{"), "unfilled slot: \(spec.text)")
            #expect(!spec.text.contains("  "))
        }
    }

    @Test func bannedWords() {
        let banned = ["illustration", "digital art", "cgi", "render", "border", "frame", "watermark", "film scan"]
        for spec in builder.batch(count: 500, seed: 5) {
            let lower = spec.text.lowercased()
            for word in banned {
                #expect(!lower.contains(word), "'\(word)' in: \(spec.text)")
            }
        }
    }

    @Test func seriesInvariants() {
        let specs = builder.batch(count: 600, seed: 99)
        let grouped = Dictionary(grouping: specs.filter { $0.series != nil }, by: { $0.series!.id })
        #expect(!grouped.isEmpty)
        for (_, group) in grouped {
            let kind = group[0].series!.kind
            #expect(group.map { $0.series!.index } == Array(0..<group.count), "series indices out of order")
            let runsOffEnd = group.last! == specs.last!
            #expect(group.count == group[0].series!.length || runsOffEnd)
            func allSame<T: Equatable>(_ values: [T]) -> Bool { values.allSatisfy { $0 == values[0] } }
            func allDifferent<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
            switch kind {
            case .subjectStudy:
                #expect(allSame(group.map(\.subjectID)))
                #expect(allDifferent(group.map(\.styleID)), "\(group.map(\.styleID))")
                #expect(allDifferent(group.map(\.paletteID)))
                #expect(allDifferent(group.map(\.transformationKind)), "\(group.map(\.transformationKind))")
            case .paletteRun:
                #expect(allSame(group.map(\.paletteID)))
                #expect(allDifferent(group.map(\.styleID)))
                #expect(allDifferent(group.map(\.subjectID)))
            case .styleSet:
                #expect(allSame(group.map(\.styleID)))
                if group[0].styleFamily == .photographic {   // abstract styles hold only the style
                    #expect(allSame(group.map(\.subjectCategory)))
                }
                #expect(allDifferent(group.map(\.subjectID)))
                #expect(allDifferent(group.map(\.paletteID)))
            case .materialThread:
                #expect(allSame(group.map(\.materialID)))
                #expect(group.allSatisfy { $0.transformationKind == .material })
                #expect(allDifferent(group.map(\.subjectID)))
                #expect(allDifferent(group.map(\.styleID)))
            }
        }
    }

    @Test func textProneSubjectsGetBlankClause() {
        let lib = PromptLibrary.standard
        let prone = Set(lib.subjects.filter(\.textProne).map(\.id))
        #expect(!prone.isEmpty)
        var checked = 0
        for spec in builder.batch(count: 800, seed: 21) {
            let second = spec.secondSubjectID.map { prone.contains($0) } ?? false
            if prone.contains(spec.subjectID) || second {
                #expect(spec.text.contains(PromptLibrary.blankClause), "\(spec.text)")
                checked += 1
            } else {
                #expect(!spec.text.contains(PromptLibrary.blankClause))
            }
        }
        #expect(checked > 0)
    }

    @Test func styleRulesHold() {
        let lib = PromptLibrary.standard
        for spec in builder.batch(count: 800, seed: 31) {
            let palette = lib.palettes.first { $0.id == spec.paletteID }!
            switch spec.styleID {
            case "aerochrome": #expect(spec.paletteID == "aerochrome")
            case "biolumNight", "longExposure", "flashNight": #expect(palette.isDark, "\(spec.styleID) got \(spec.paletteID)")
            case "doubleExposure", "studioProduct", "liquidAbstract": break
            default: #expect(spec.paletteID != "aerochrome", "\(spec.styleID) got aerochrome")
            }
            if spec.styleID == "aerial" { #expect(spec.compositionID == "topDown") }
        }
    }

    @Test func historyPersistsAsJSON() throws {
        var history = PromptHistory()
        var rng = SeededRNG(seed: 1)
        for _ in 0..<10 { _ = builder.next(history: &history, using: &rng) }
        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(PromptHistory.self, from: data)
        #expect(decoded == history)
        #expect(history.styles.count == 6)
    }

    @Test func printSample() {
        let specs = builder.batch(count: 20, seed: 14)
        for (i, spec) in specs.enumerated() {
            let series = spec.series.map { " series=\($0.kind.rawValue)#\($0.index + 1)/\($0.length)" } ?? ""
            print("[\(i)] \(spec.styleID) / \(spec.paletteID) / \(spec.subjectID) / \(spec.transformationID)\(series)")
            print("    \(spec.text)")
        }
        #expect(specs.count == 20)
    }
}
