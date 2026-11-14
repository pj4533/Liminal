//
//  PromptLibrary.swift
//  Liminal
//
//  The data the PromptBuilder draws from, plus the compatibility rules
//  between styles, subjects, transformations and palettes.
//  Data lives in the +Styles, +Subjects, +Transformations, +Palettes and
//  +Legacy extensions.
//

import Foundation

nonisolated struct PromptLibrary: Sendable {
    /// Prompt-system version, stored in every image's metadata.
    /// Bumping it does NOT purge cached images (see ImageStore.cacheEpoch).
    static let version = 2

    let styles: [Style]
    let subjects: [Subject]
    let transformations: [Transformation]
    let palettes: [Palette]
    let compositions: [Composition]
    let materials: [String]
    let solidMaterials: [String]
    let environments: [String]
    let growths: [String]
    let bursts: [String]

    init(styles: [Style], subjects: [Subject], transformations: [Transformation], palettes: [Palette],
         compositions: [Composition], materials: [String] = PromptLibrary.materials,
         solidMaterials: [String] = PromptLibrary.solidMaterials, environments: [String] = PromptLibrary.environments,
         growths: [String] = PromptLibrary.growths, bursts: [String] = PromptLibrary.bursts) {
        self.styles = styles; self.subjects = subjects; self.transformations = transformations
        self.palettes = palettes; self.compositions = compositions; self.materials = materials
        self.solidMaterials = solidMaterials; self.environments = environments; self.growths = growths
        self.bursts = bursts
    }

    static let standard = PromptLibrary(
        styles: standardStyles,
        subjects: standardSubjects,
        transformations: standardTransformations,
        palettes: standardPalettes,
        compositions: standardCompositions
    )

    // MARK: - Compatibility

    /// Subjects a style may draw from (before transformation filtering).
    func subjectPool(for style: Style) -> [Subject] {
        if let own = style.ownSubjects { return own }
        return subjects.filter { subject in
            if let cats = style.categories, !cats.contains(subject.category) { return false }
            return !transformationsFor(style: style, subject: subject).isEmpty
        }
    }

    /// Transformations legal for a style/subject pair.
    func transformationsFor(style: Style, subject: Subject) -> [Transformation] {
        transformations.filter { isLegal(style: style, subject: subject, transformation: $0) }
    }

    func isLegal(style: Style, subject: Subject, transformation t: Transformation) -> Bool {
        if t.forOwnSubjects != (style.ownSubjects != nil) { return false }
        if let kinds = style.kinds, !kinds.contains(t.kind) { return false }
        if style.excludedTransformations.contains(t.id) { return false }
        if t.excludedCategories.contains(subject.category) { return false }
        if let scales = t.scales, !scales.contains(subject.scale) { return false }
        if let scales = style.scales, !scales.contains(subject.scale), !style.scaleOverrides.contains(t.id) { return false }
        if t.usesSecondSubject {
            let allowed = t.secondCategories ?? SubjectCategory.allCases
            if !allowed.contains(where: { $0 != subject.category }) { return false }
        }
        return true
    }

    func secondSubjectPool(for subject: Subject, transformation t: Transformation) -> [Subject] {
        subjects.filter { other in
            guard other.category != subject.category else { return false }
            if let cats = t.secondCategories { return cats.contains(other.category) }
            return true
        }
    }

    func palettePool(for style: Style) -> [Palette] {
        palettes.filter { palette in
            switch style.paletteRule {
            case .any: return true
            case .anyExcept(let ids): return !ids.contains(palette.id)
            case .only(let ids): return ids.contains(palette.id)
            case .darkOnly: return palette.isDark
            }
        }
    }

    func compositionPool(for style: Style) -> [Composition] {
        guard let ids = style.compositions else { return compositions }
        return compositions.filter { ids.contains($0.id) }
    }

    // MARK: - Validation

    /// Empty when the library is internally consistent and every style has at
    /// least one legal subject/transformation/palette/composition combination.
    func validate() -> [String] {
        var problems: [String] = []
        func checkUnique(_ ids: [String], _ what: String) {
            var seen: [String] = []
            for id in ids {
                if seen.contains(id) { problems.append("duplicate \(what) id \(id)") }
                seen.append(id)
            }
        }
        checkUnique(styles.map(\.id), "style")
        checkUnique(subjects.map(\.id) + styles.flatMap { ($0.ownSubjects ?? []).map(\.id) }, "subject")
        checkUnique(transformations.map(\.id), "transformation")
        checkUnique(palettes.map(\.id), "palette")
        checkUnique(compositions.map(\.id), "composition")

        let compositionIDs = compositions.map(\.id)
        let transformationIDs = transformations.map(\.id)
        for style in styles {
            let pool = subjectPool(for: style)
            if pool.isEmpty { problems.append("style \(style.id) has no legal subject") }
            if palettePool(for: style).isEmpty { problems.append("style \(style.id) has no palette") }
            if compositionPool(for: style).isEmpty { problems.append("style \(style.id) has no composition") }
            for id in style.compositions ?? [] where !compositionIDs.contains(id) {
                problems.append("style \(style.id) names unknown composition \(id)")
            }
            for id in style.scaleOverrides + style.excludedTransformations where !transformationIDs.contains(id) {
                problems.append("style \(style.id) names unknown transformation \(id)")
            }
            for subject in pool where transformationsFor(style: style, subject: subject).isEmpty {
                problems.append("style \(style.id) subject \(subject.id) has no transformation")
            }
        }

        let knownSlots = ["{S}", "{Sn}", "{Sp}", "{S2}", "{S2p}", "{M}", "{MS}", "{E}", "{G}", "{B}"]
        for t in transformations {
            var stripped = t.template
            for slot in knownSlots { stripped = stripped.replacingOccurrences(of: slot, with: "") }
            if stripped.contains("{") || stripped.contains("}") {
                problems.append("transformation \(t.id) has an unknown slot")
            }
            if !t.template.contains("{S") { problems.append("transformation \(t.id) never names the subject") }
        }
        for m in solidMaterials where !materials.contains(m) {
            problems.append("solid material \(m) missing from materials")
        }
        for kind in TransformationKind.allCases where !transformations.contains(where: { $0.kind == kind }) {
            problems.append("no transformation of kind \(kind.rawValue)")
        }
        return problems
    }
}
