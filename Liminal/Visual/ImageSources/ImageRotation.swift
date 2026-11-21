//
//  ImageRotation.swift
//  Liminal
//
//  The two choices of API mode, kept apart (docs/plans/image-api-mode.md 4): which source the next
//  download comes from (ingest), and which stored picture is shown next (display). Pure and seeded.
//

import Foundation

nonisolated enum ImageRotation {

    // MARK: - Ingest

    /// A weighted bag of source ids (each enabled source `weight` times, rounded, at least once),
    /// drawn without replacement and refilled when empty.
    struct SourceBag: Sendable, Equatable {
        var remaining: [String] = []
        /// Newest last.
        var history: [String] = []

        static func fill(_ sources: [CuratedSource], using rng: inout some RandomNumberGenerator) -> [String] {
            var bag: [String] = []
            for s in sources { bag += Array(repeating: s.id, count: max(1, Int(s.weight.rounded()))) }
            return bag.shuffled(using: &rng)
        }
    }

    /// Next source to download from. Rules: never the same source twice in a row while another is
    /// available; never the same provider three times in a row while another provider is available;
    /// sources not in `available` (backoff, nothing left) are skipped.
    static func nextSource(sources: [CuratedSource], bag: inout SourceBag, available: Set<String>,
                           using rng: inout some RandomNumberGenerator) -> CuratedSource? {
        let usable = sources.filter { available.contains($0.id) }
        guard !usable.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })
        let last = bag.history.last
        let lastTwoProviders = bag.history.suffix(2).compactMap { id in sources.first { $0.id == id }?.provider }
        let providerRun = lastTwoProviders.count == 2 && lastTwoProviders[0] == lastTwoProviders[1] ? lastTwoProviders[0] : nil
        let otherProvider = providerRun.map { p in usable.contains { $0.provider != p } } ?? false
        let otherSource = usable.contains { $0.id != last }

        func acceptable(_ s: CuratedSource) -> Bool {
            if otherSource && s.id == last { return false }
            if otherProvider && s.provider == providerRun { return false }
            return true
        }

        for _ in 0..<2 {
            if let index = bag.remaining.firstIndex(where: { byID[$0].map(acceptable) ?? false }) {
                let id = bag.remaining.remove(at: index)
                bag.history.append(id)
                if bag.history.count > 8 { bag.history.removeFirst(bag.history.count - 8) }
                return byID[id]
            }
            // Nothing acceptable left in the bag: refill with every usable source.
            bag.remaining = SourceBag.fill(usable, using: &rng)
        }
        // Only possible with one source/provider left; the rules yield.
        let s = usable.randomElement(using: &rng)!
        bag.history.append(s.id)
        return s
    }

    /// Pinned ids first (shuffled), then search results in order; keys in `seen` are skipped.
    static func nextCandidate(pinned: [ImageCandidate], searched: [ImageCandidate], seen: Set<String>,
                              using rng: inout some RandomNumberGenerator) -> ImageCandidate? {
        if let p = pinned.filter({ !seen.contains($0.key) }).randomElement(using: &rng) { return p }
        return searched.first { !seen.contains($0.key) }
    }

    // MARK: - Display

    struct DisplayItem: Sendable, Equatable {
        let id: UUID
        let sourceID: String
        let sourceWeight: Double
        let openness: Double
        let monochrome: Bool
        /// Serial of the last time it was shown; nil = never shown.
        let lastShown: Int?
    }

    struct DisplayHistory: Codable, Sendable, Equatable {
        struct Shown: Codable, Sendable, Equatable {
            let sourceID: String
            let monochrome: Bool
        }
        /// Incremented every time a picture is shown.
        var serial = 0
        /// Recently shown, newest last.
        var recent: [Shown] = []

        mutating func record(sourceID: String, monochrome: Bool) {
            serial += 1
            recent.append(Shown(sourceID: sourceID, monochrome: monochrome))
            if recent.count > 32 { recent.removeFirst(recent.count - 32) }
        }
    }

    struct DisplayRules: Sendable, Equatable {
        var recencyWindow = 24
        var monochromeEvery = 6
        var unseenBoost = 3.0
    }

    /// Weight = source weight x recency x (0.5 + openness), never-shown x3. Hard rules: not the picture
    /// on screen, not the previous picture's source when the pool spans three or more sources, at
    /// most one monochrome in any `monochromeEvery`. Each rule yields rather than return nothing.
    static func nextDisplay(pool: [DisplayItem], history: DisplayHistory, current: UUID?, rules: DisplayRules = .init(),
                            using rng: inout some RandomNumberGenerator) -> DisplayItem? {
        let notCurrent = pool.filter { $0.id != current }
        guard !notCurrent.isEmpty else { return pool.first }

        func weight(_ item: DisplayItem) -> Double {
            var w = max(0.01, item.sourceWeight) * (0.5 + item.openness)
            if let shown = item.lastShown {
                let since = history.serial - shown
                // 0 inside the window, then rising back to 1 over another window.
                if since < rules.recencyWindow { w *= 0 }
                else { w *= min(1, Double(since - rules.recencyWindow + 1) / Double(rules.recencyWindow)) }
            } else {
                w *= rules.unseenBoost
            }
            return w
        }

        // Pictures outside the recency window; when there are none (a pool smaller than the window),
        // every picture, and the least recently shown one wins below.
        let rested = notCurrent.filter { weight($0) > 0 }
        var candidates = rested.isEmpty ? notCurrent : rested
        let sources = Set(pool.map(\.sourceID))
        if sources.count >= 3, let last = history.recent.last?.sourceID {
            let other = candidates.filter { $0.sourceID != last }
            if !other.isEmpty { candidates = other }
        }
        let window = max(1, rules.monochromeEvery - 1)
        if history.recent.suffix(window).contains(where: { $0.monochrome }) {
            let colour = candidates.filter { !$0.monochrome }
            if !colour.isEmpty { candidates = colour }
        }
        if rested.isEmpty {
            return candidates.max { (history.serial - ($0.lastShown ?? 0)) < (history.serial - ($1.lastShown ?? 0)) }
        }
        let weights = candidates.map(weight)
        let total = weights.reduce(0, +)
        var r = Double.random(in: 0..<total, using: &rng)
        for (item, w) in zip(candidates, weights) {
            if r < w { return item }
            r -= w
        }
        return candidates.last
    }
}
