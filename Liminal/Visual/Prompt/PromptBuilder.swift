//
//  PromptBuilder.swift
//  Liminal
//
//  Pure function of (library, tuning, history, rng) -> PromptSpec.
//  No clock, no globals, no network. Draw order: style, subject,
//  transformation (and slots), palette, composition. Each draw is weighted by
//  weight x recency penalty; hard zeros relax to 0.05 when nothing else is left.
//

import Foundation

nonisolated struct PromptTuning: Sendable {
    var seriesStartProbability = 0.2
    var seriesLength = 3...4
    var plainTransformationShare = 0.10
    static let standard = PromptTuning()
}

nonisolated struct PromptBuilder: Sendable {

    let library: PromptLibrary
    let tuning: PromptTuning

    /// Precomputed legal combinations per style (same order as library.styles).
    private struct Pair: Sendable {
        let subject: Subject
        let transformations: [Transformation]
    }
    private struct Entry: Sendable {
        let style: Style
        let pairs: [Pair]
        let palettes: [Palette]
        let compositions: [Composition]
    }
    private let entries: [Entry]

    static let relaxedFloor = 0.05

    init(library: PromptLibrary = .standard, tuning: PromptTuning = .standard) {
        self.library = library
        self.tuning = tuning
        self.entries = library.styles.map { style in
            let pairs = library.subjectPool(for: style).compactMap { subject -> Pair? in
                let ts = library.transformationsFor(style: style, subject: subject)
                return ts.isEmpty ? nil : Pair(subject: subject, transformations: ts)
            }
            return Entry(style: style, pairs: pairs, palettes: library.palettePool(for: style),
                         compositions: library.compositionPool(for: style))
        }
    }

    // MARK: - Public API

    func next<R: RandomNumberGenerator>(history: inout PromptHistory, using rng: inout R) -> PromptSpec {
        if let series = history.activeSeries, series.isFinished {
            history.activeSeries = nil
        }
        if history.activeSeries == nil, RandomDraw.unit(&rng) < tuning.seriesStartProbability {
            history.activeSeries = ActiveSeries(
                id: RandomDraw.uuid(&rng),
                kind: RandomDraw.element(SeriesKind.allCases, &rng),
                length: RandomDraw.int(in: tuning.seriesLength, &rng),
                nextIndex: 0
            )
        }

        var result = attempt(history: history, series: history.activeSeries, rng: &rng)
        if result == nil {
            // Series constraints cannot be met with this library: end the series.
            history.activeSeries = nil
            result = attempt(history: history, series: nil, rng: &rng)
        }
        guard let (spec, updatedSeries) = result else {
            preconditionFailure("PromptLibrary has no legal combination; run validate()")
        }
        history.activeSeries = updatedSeries
        if let s = updatedSeries, s.isFinished { history.activeSeries = nil }
        history.record(spec)
        return spec
    }

    /// Fresh history and SeededRNG(seed): the same seed always gives the same batch.
    func batch(count: Int, seed: UInt64) -> [PromptSpec] {
        var history = PromptHistory()
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in next(history: &history, using: &rng) }
    }

    // MARK: - One draw

    private func attempt<R: RandomNumberGenerator>(history: PromptHistory, series: ActiveSeries?,
                                                   rng: inout R) -> (PromptSpec, ActiveSeries?)? {
        let index = series?.nextIndex ?? 0
        let first = index == 0

        // STYLE
        let styleCandidates = entries.filter { styleAllowed($0, series: series, first: first) }
        guard !styleCandidates.isEmpty else { return nil }
        let entry = RandomDraw.weighted(styleCandidates, &rng,
            weight: { styleWeight($0, history: history, series: series, first: first, relaxed: false) },
            relaxed: { styleWeight($0, history: history, series: series, first: first, relaxed: true) })
        let style = entry.style

        // SUBJECT
        let pairs = subjectPairs(entry, series: series, first: first)
        guard !pairs.isEmpty else { return nil }
        let categoryCounts = Dictionary(grouping: pairs, by: { $0.subject.category }).mapValues(\.count)
        let pair = RandomDraw.weighted(pairs, &rng,
            weight: { subjectWeight($0, counts: categoryCounts, history: history, series: series, relaxed: false) },
            relaxed: { subjectWeight($0, counts: categoryCounts, history: history, series: series, relaxed: true) })
        let subject = pair.subject

        // TRANSFORMATION
        let transformations = transformationPool(pair, series: series, first: first)
        guard !transformations.isEmpty else { return nil }
        let transformation = drawTransformation(transformations, history: history, series: series, rng: &rng)

        // SLOTS
        var secondSubject: Subject?
        if transformation.usesSecondSubject {
            let pool = library.secondSubjectPool(for: subject, transformation: transformation)
            guard !pool.isEmpty else { return nil }
            secondSubject = RandomDraw.weighted(pool, &rng,
                weight: { history.subjects.contains($0.id) ? 0 : 1 },
                relaxed: { _ in 1 })
        }
        var material: String?
        if transformation.template.contains("{MS}") {
            material = series?.materialID ?? RandomDraw.element(library.solidMaterials, &rng)
        } else if transformation.template.contains("{M}") {
            material = series?.materialID ?? RandomDraw.element(library.materials, &rng)
        }
        let environment = RandomDraw.element(library.environments, &rng)
        let growth = RandomDraw.element(library.growths, &rng)
        let burst = RandomDraw.element(library.bursts, &rng)

        // PALETTE
        let palettes = palettePool(entry, series: series, first: first)
        guard !palettes.isEmpty else { return nil }
        let palette = RandomDraw.weighted(palettes, &rng,
            weight: { paletteWeight($0, history: history, series: series, relaxed: false) },
            relaxed: { paletteWeight($0, history: history, series: series, relaxed: true) })

        // COMPOSITION
        let previousComposition = history.compositions.last
        let composition = RandomDraw.weighted(entry.compositions, &rng,
            weight: { $0.weight * ($0.id == previousComposition ? 0.2 : 1) },
            relaxed: { $0.weight })

        // TEXT
        var subjectText = fill(transformation.template, subject: subject, second: secondSubject,
                               material: material, environment: environment, growth: growth, burst: burst)
        if subject.textProne || (secondSubject?.textProne ?? false) {
            subjectText += ", " + PromptLibrary.blankClause
        }
        let text = [
            "\(style.lead), \(style.camera).",
            sentence(subjectText),
            palette.clause,
            sentence(style.lighting),
            sentence(style.texture),
            sentence(composition.fragment),
            PromptLibrary.tail,
        ].joined(separator: " ")

        // SERIES bookkeeping
        var updated = series
        var seriesInfo: SeriesInfo?
        if var s = updated {
            seriesInfo = SeriesInfo(id: s.id, kind: s.kind, index: s.nextIndex, length: s.length)
            if first {
                s.styleID = style.id
                s.subjectID = subject.id
                s.paletteID = palette.id
                s.category = subject.category
                s.materialID = material
            }
            s.usedStyles.append(style.id)
            s.usedPalettes.append(palette.id)
            s.usedSubjects.append(subject.id)
            s.usedKinds.append(transformation.kind)
            s.nextIndex += 1
            updated = s
        }

        let spec = PromptSpec(
            text: text,
            styleID: style.id,
            styleFamily: style.family,
            paletteID: palette.id,
            paletteSwatches: palette.swatches,
            subjectID: subject.id,
            subjectCategory: subject.category,
            secondSubjectID: secondSubject?.id,
            transformationID: transformation.id,
            transformationKind: transformation.kind,
            materialID: material,
            compositionID: composition.id,
            moods: moods(style: style, transformation: transformation, palette: palette),
            energy: min(1, max(0, style.energy * 0.5 + palette.energy * 0.5 + (transformation.needsStrongSurreal ? 0.1 : 0))),
            warmth: palette.warmth,
            needsStrongSurreal: transformation.needsStrongSurreal,
            series: seriesInfo,
            promptVersion: PromptLibrary.version
        )
        return (spec, updated)
    }

    // MARK: - Style

    private func styleAllowed(_ entry: Entry, series: ActiveSeries?, first: Bool) -> Bool {
        guard !entry.pairs.isEmpty, !entry.palettes.isEmpty, !entry.compositions.isEmpty else { return false }
        guard let series else { return true }
        let style = entry.style
        switch series.kind {
        case .styleSet:
            if first {
                if case .only = style.paletteRule { return false }   // palette must vary
                return !subjectPairs(entry, series: series, first: true).isEmpty
            }
            return style.id == series.styleID
        case .subjectStudy:
            if first { return style.ownSubjects == nil }
            return entry.pairs.contains { $0.subject.id == series.subjectID }
        case .paletteRun:
            if first { return true }
            return entry.palettes.contains { $0.id == series.paletteID }
        case .materialThread:
            return entry.pairs.contains { pair in
                pair.transformations.contains { materialTransformationFits($0, series: series, first: first) }
            }
        }
    }

    private func styleWeight(_ entry: Entry, history: PromptHistory, series: ActiveSeries?, first: Bool,
                             relaxed: Bool) -> Double {
        var penalty = 1.0
        let held = series?.kind == .styleSet && !first
        if !held {
            if let d = PromptHistory.distance(of: entry.style.id, in: history.styles) {
                penalty = d < 2 ? 0 : 0.3
            }
            if let series, series.kind != .styleSet, series.usedStyles.contains(entry.style.id) {
                penalty = 0
            }
        }
        if !relaxed {
            // A style is only worth drawing if it still has a fresh subject and palette.
            let pairs = subjectPairs(entry, series: series, first: first)
            let counts = Dictionary(grouping: pairs, by: { $0.subject.category }).mapValues(\.count)
            let hasSubject = pairs.contains { pair in
                subjectWeight(pair, counts: counts, history: history, series: series, relaxed: false) > 0
                    && transformationPool(pair, series: series, first: first).contains {
                        transformationWeight($0, history: history, series: series, relaxed: false) > 0
                    }
            }
            let hasPalette = palettePool(entry, series: series, first: first).contains {
                paletteWeight($0, history: history, series: series, relaxed: false) > 0
            }
            if !hasSubject || !hasPalette { penalty = 0 }
            return entry.style.weight * penalty
        }
        return entry.style.weight * max(penalty, Self.relaxedFloor)
    }

    // MARK: - Subject

    private func subjectPairs(_ entry: Entry, series: ActiveSeries?, first: Bool) -> [Pair] {
        guard let series else { return entry.pairs }
        switch series.kind {
        case .subjectStudy:
            if first { return entry.pairs.filter { $0.subject.category != .landscape } }
            return entry.pairs.filter { $0.subject.id == series.subjectID }
        case .styleSet:
            // Abstract styles have small own lists; holding the style is enough there.
            if entry.style.ownSubjects != nil { return entry.pairs }
            if first {
                // Only start in a category deep enough to give `length` different subjects.
                let counts = Dictionary(grouping: entry.pairs, by: { $0.subject.category }).mapValues(\.count)
                return entry.pairs.filter { (counts[$0.subject.category] ?? 0) >= series.length * 2 }
            }
            return entry.pairs.filter { $0.subject.category == series.category }
        case .materialThread:
            return entry.pairs.filter { pair in
                pair.transformations.contains { materialTransformationFits($0, series: series, first: first) }
            }
        case .paletteRun:
            return entry.pairs
        }
    }

    private func subjectWeight(_ pair: Pair, counts: [SubjectCategory: Int], history: PromptHistory,
                               series: ActiveSeries?, relaxed: Bool) -> Double {
        let category = pair.subject.category
        let base = 1.0 / Double(counts[category] ?? 1)
        var penalty = 1.0
        let subjectHeld = series?.kind == .subjectStudy && (series?.nextIndex ?? 0) > 0
        if !subjectHeld {
            if history.subjects.contains(pair.subject.id) { penalty = 0 }
            if let series, series.usedSubjects.contains(pair.subject.id) { penalty = 0 }
        }
        let categoryHeld = (series?.kind == .styleSet || series?.kind == .subjectStudy) && (series?.nextIndex ?? 0) > 0
        if !categoryHeld, let d = PromptHistory.distance(of: category, in: history.categories) {
            penalty *= d == 0 ? 0 : 0.5
        }
        return base * (relaxed ? max(penalty, Self.relaxedFloor) : penalty)
    }

    // MARK: - Transformation

    private func materialTransformationFits(_ t: Transformation, series: ActiveSeries, first: Bool) -> Bool {
        guard t.kind == .material else { return false }
        if first { return true }
        guard let material = series.materialID else { return true }
        if t.template.contains("{MS}") { return library.solidMaterials.contains(material) }
        return true
    }

    private func transformationPool(_ pair: Pair, series: ActiveSeries?, first: Bool) -> [Transformation] {
        guard let series, series.kind == .materialThread else { return pair.transformations }
        return pair.transformations.filter { materialTransformationFits($0, series: series, first: first) }
    }

    private func transformationWeight(_ t: Transformation, history: PromptHistory, series: ActiveSeries?,
                                      relaxed: Bool) -> Double {
        var penalty = 1.0
        if series?.kind != .materialThread, let d = PromptHistory.distance(of: t.kind, in: history.transformationKinds) {
            penalty = d == 0 ? 0 : 0.4
        }
        if let series, series.kind == .subjectStudy, series.usedKinds.contains(t.kind) { penalty = 0 }
        return t.weight * (relaxed ? max(penalty, Self.relaxedFloor) : penalty)
    }

    private func drawTransformation<R: RandomNumberGenerator>(_ pool: [Transformation], history: PromptHistory,
                                                             series: ActiveSeries?, rng: inout R) -> Transformation {
        func weight(_ t: Transformation, relaxed: Bool) -> Double {
            transformationWeight(t, history: history, series: series, relaxed: relaxed)
        }

        let plain = pool.filter { $0.kind == .plain }
        let other = pool.filter { $0.kind != .plain }
        var subset = pool
        if !plain.isEmpty && !other.isEmpty {
            subset = RandomDraw.unit(&rng) < tuning.plainTransformationShare ? plain : other
            if !subset.contains(where: { weight($0, relaxed: false) > 0 }) { subset = pool }
        }
        return RandomDraw.weighted(subset, &rng,
                                   weight: { weight($0, relaxed: false) },
                                   relaxed: { weight($0, relaxed: true) })
    }

    // MARK: - Palette

    private func palettePool(_ entry: Entry, series: ActiveSeries?, first: Bool) -> [Palette] {
        guard let series, series.kind == .paletteRun else { return entry.palettes }
        if first { return entry.palettes.filter { $0.id != "aerochrome" } }  // too few styles accept it
        return entry.palettes.filter { $0.id == series.paletteID }
    }

    private func paletteWeight(_ palette: Palette, history: PromptHistory, series: ActiveSeries?,
                               relaxed: Bool) -> Double {
        var penalty = 1.0
        let held = series?.kind == .paletteRun && (series?.nextIndex ?? 0) > 0
        if !held {
            if let d = PromptHistory.distance(of: palette.id, in: history.palettes) {
                penalty = d < 3 ? 0 : 0.3
            }
            if let series, series.kind != .paletteRun, series.usedPalettes.contains(palette.id) { penalty = 0 }
        }
        return palette.weight * (relaxed ? max(penalty, Self.relaxedFloor) : penalty)
    }

    // MARK: - Text helpers

    private func fill(_ template: String, subject: Subject, second: Subject?, material: String?,
                      environment: String, growth: String, burst: String) -> String {
        var text = template
        text = text.replacingOccurrences(of: "{S2p}", with: second?.plural ?? "")
        text = text.replacingOccurrences(of: "{S2}", with: second?.phrase ?? "")
        text = text.replacingOccurrences(of: "{Sp}", with: subject.plural)
        text = text.replacingOccurrences(of: "{Sn}", with: subject.noun)
        text = text.replacingOccurrences(of: "{S}", with: subject.phrase)
        text = text.replacingOccurrences(of: "{MS}", with: material ?? "")
        text = text.replacingOccurrences(of: "{M}", with: material ?? "")
        text = text.replacingOccurrences(of: "{E}", with: environment)
        text = text.replacingOccurrences(of: "{G}", with: growth)
        text = text.replacingOccurrences(of: "{B}", with: burst)
        return text
    }

    private func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        var result = first.uppercased() + text.dropFirst()
        if !result.hasSuffix(".") { result += "." }
        return result
    }

    /// 2 to 4 moods: the ones named by more than one of style/transformation/palette
    /// first, then the style's own, in a fixed order so seeded output is stable.
    private func moods(style: Style, transformation: Transformation, palette: Palette) -> [Mood] {
        let all = style.moods + transformation.moods + palette.moods
        var ordered: [Mood] = []
        for mood in all where !ordered.contains(mood) { ordered.append(mood) }
        let counts = ordered.map { mood in all.filter { $0 == mood }.count }
        let ranked = zip(ordered, counts).enumerated()
            .sorted { lhs, rhs in
                lhs.element.1 != rhs.element.1 ? lhs.element.1 > rhs.element.1 : lhs.offset < rhs.offset
            }
            .map { $0.element.0 }
        let shared = ranked.filter { mood in all.filter { $0 == mood }.count > 1 }
        var picked = Array(shared.prefix(4))
        for mood in ranked where picked.count < 2 && !picked.contains(mood) { picked.append(mood) }
        if picked.count < 3, let extra = ranked.first(where: { !picked.contains($0) }) { picked.append(extra) }
        return picked
    }
}
