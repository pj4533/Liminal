import Foundation

// The chop beat's groove cell (D127; user direction of 21 November 2026: "I like when it doesn't
// repeat the same chop over and over in a row. Better to mix it up, on beat chops. With swing. Or
// Dilla style. Playing off the drumbeats."). The hook template's skeleton (S, R and T on fixed steps,
// D125) is filled like a finger-drummed phrase: each stab is a different cut than the hit before it
// (the signature's head or tail half, the response's halves, the third piece, the line's other words),
// placed off the drummer's kicks: in the gaps, answering the snare, in the ghost notes' pockets and as
// a pickup on the swung "a" into a downbeat, leaving the drummer's busiest beat to the drums. The
// fill is drawn from the loop seed, so the skeleton recurs for two loops but the phrase does not.
// Pure and seeded; nothing here touches audio threads.

/// A loop's microtiming feel (D127): seconds added to a chop-beat or build hit's step on the drummer's
/// grid by its place in the beat, the same for every such hit of the loop. Quarter steps (the
/// downbeats and backbeats) are never moved; the "and", "e" and "a" may sit a few milliseconds behind
/// or ahead of the take's own swing, a consistent push or drag like an MPC's swing or a Dilla-style
/// late "e", never a random jitter.
nonisolated struct DialogueFeel: Sendable, Equatable {
    let name: String
    /// Step 2 of the beat (the "and"), step 1 (the "e") and step 3 (the "a").
    let and: Double
    let e: Double
    let a: Double

    /// Feels the loop seed chooses from. Every offset is within `DialogueMotifTuning.maximumFeelSeconds`.
    static let variants: [DialogueFeel] = [
        // The take's own grid.
        DialogueFeel(name: "grid", and: 0, e: 0, a: 0),
        // Laid back: every offbeat late, the "e" most (the Dilla drag).
        DialogueFeel(name: "laid", and: 0.008, e: 0.018, a: 0.014),
        // Rushed "a": the pickup pushes into the beat, the "e" lags.
        DialogueFeel(name: "rush", and: 0.004, e: 0.012, a: -0.016),
        // Drunk: the "and" and "e" dragged hard, the "a" barely.
        DialogueFeel(name: "drunk", and: 0.014, e: 0.024, a: 0.006),
        // Ahead: every offbeat a little early, against a laid-back drummer.
        DialogueFeel(name: "ahead", and: -0.006, e: -0.004, a: -0.012),
    ]

    /// The offset of a sixteenth (any integer; its place in the beat is `step mod 4`).
    func offset(step: Int) -> Double {
        switch ((step % 4) + 4) % 4 {
        case 1: e
        case 2: and
        case 3: a
        default: 0
        }
    }
}

nonisolated extension DialogueMotif {
    /// What a fill stab does against the drums.
    enum FillSite: Equatable {
        /// Between the drummer's hits.
        case gap
        /// The 8th after a backbeat snare.
        case answer
        /// On a ghost note's step.
        case ghost
        /// The swung "a" before a downbeat.
        case push
        /// On a kick (only when nothing better fits).
        case kick
        /// With a snare that is not the template's backbeat answer (low; a busy take's last resort).
        case snare
    }

    /// The cuts a groove draws from, by role: the signature's (whole, head and tail), the response's,
    /// the third piece and the line's other words and syllables.
    struct GrooveVocabulary {
        let s: Int, r: Int, t: Int, sa: Int, sb: Int, ra: Int, rb: Int
        let others: [Int]
        /// Every cut's weight and kind, and whether the line has a content cut (D130 stage 2).
        let weights: [Float]
        let kinds: [DialogueMotifFragment.Kind]
        let content: Bool
        /// The signature's letters or syllables in source order, when it spells.
        let spellUnits: [Int]?

        init(s: Int, r: Int, t: Int, sa: Int, ra: Int, pieces: [Int], halves: [Int: [Int]], fragments: [DialogueMotifFragment]? = nil) {
            self.s = s; self.r = r; self.t = t; self.sa = sa; self.ra = ra
            sb = halves[s]?.first { $0 != sa } ?? s
            rb = halves[r]?.first { $0 != ra } ?? r
            let roles: Set<Int> = [s, r, t, sa, ra]
            var rest = pieces.filter { !roles.contains($0) }
            rest += ([t] + rest).flatMap { halves[$0] ?? [] }
            // D130: no connective fill (weight 0) while the line has a content cut.
            if let fragments, rest.contains(where: { fragments[$0].weight > 0 }) || [s, r, t].contains(where: { fragments[$0].weight > 0 }) {
                rest = rest.filter { fragments[$0].weight > 0 }
            }
            var seen = Set<Int>([s, r, t, sa, sb, ra, rb])
            // D130 stage 2: the signature's and response's other spell units (a third letter, the last
            // syllables) join the vocabulary, heaviest words first.
            rest += [s, r].flatMap { halves[$0] ?? [] }
            let weights = fragments?.map(\.weight) ?? []
            if let fragments, let units = halves[s], units.count >= 2,
               units.allSatisfy({ fragments[$0].kind == .letter || fragments[$0].kind == .syllable }) {
                spellUnits = units
            } else {
                spellUnits = nil
            }
            self.weights = weights
            kinds = fragments?.map(\.kind) ?? []
            content = fragments.map { f in [s, r, t].contains { f[$0].weight > 0 } || rest.contains { f[$0].weight > 0 } } ?? false
            let order = rest.enumerated().sorted { a, b in
                let wa = weights.indices.contains(a.element) ? weights[a.element] : 0
                let wb = weights.indices.contains(b.element) ? weights[b.element] : 0
                return (wa, -a.offset) > (wb, -b.offset)
            }.map(\.element)
            others = order.filter { seen.insert($0).inserted }
        }

        /// The cuts a site prefers, most fitting first (duplicates removed).
        func preferred(_ site: FillSite, fragments: [DialogueMotifFragment], sampleRate: Double) -> [Int] {
            func seconds(_ id: Int) -> Double { Double(fragments[id].frames.count) / sampleRate }
            let list: [Int]
            switch site {
            // The hook's own cuts first, the line's other words only when those are used up around a
            // site, so the phrase stays the signature's and the response's (D125) while it varies.
            case .gap: list = [sa, sb, t, ra, rb] + others
            case .answer: list = [ra, rb, t, r, sb] + others
            case .ghost, .push: list = ([sb, rb, sa, ra] + others).sorted { (seconds($0), $0) < (seconds($1), $1) }
            case .kick: list = [sa, s, sb] + others.filter { fragments[$0].isUnit }
            case .snare: list = [ra, rb, sa, sb] + others
            }
            // D130 stage 2: the heavier word first at every site but the ghost and push (by length), the
            // role order breaking ties, so the stabs say the line's recognisable words.
            let ranked = site == .ghost || site == .push ? list
                : list.enumerated().sorted { a, b in
                    let wa = weights.indices.contains(a.element) ? weights[a.element] : 0
                    let wb = weights.indices.contains(b.element) ? weights[b.element] : 0
                    return (wa, -a.offset) > (wb, -b.offset)
                }.map(\.element)
            var seen = Set<Int>()
            // D130 stage 2: never a weight-0 cut while the line has a content one (weight-0 pieces sound
            // only in the whole line and the outro's in-order walk).
            // Spell units (letters, syllables) are no stand-alone fill: they sound in source order only (the
            // fill's spell run into the signature, the build and the outro's tag).
            func spellUnit(_ f: Int) -> Bool { kinds.indices.contains(f) && (kinds[f] == .letter || kinds[f] == .syllable) }
            return ranked.filter { !spellUnit($0) && seen.insert($0).inserted && (!content || (weights.indices.contains($0) && weights[$0] > 0)) }
        }
    }

    /// The take's drum activity over the 2-bar cell: kick, backbeat snare and ghost-note steps.
    struct GrooveDrums {
        let kick: [Bool], snare: [Bool], ghost: [Bool]
        init(_ d: DialogueMotifDrums) {
            kick = (0..<32).map { d.kicks.contains($0) }
            snare = (0..<32).map { d.snares.contains($0) }
            ghost = (0..<32).map { d.ghosts.contains($0) }
        }
        func any(_ k: Int) -> Bool { (0..<32).contains(k) && (kick[k] || snare[k] || ghost[k]) }
        func strong(_ k: Int) -> Bool { (0..<32).contains(k) && (kick[k] || snare[k]) }
        /// The beat (0...3) of `bar` with the most drum hits, kicks and snares counting double; beat 1 never.
        func busiestBeat(bar: Int) -> Int {
            (1..<4).max { a, b in weight(bar, a) < weight(bar, b) } ?? 3
        }
        private func weight(_ bar: Int, _ beat: Int) -> Int {
            (0..<4).map { k in let s = bar * 16 + beat * 4 + k; return (strong(s) ? 2 : 0) + (ghost[s] ? 1 : 0) }.reduce(0, +)
        }
        /// Drum hits in `bar` (steps with any hit).
        func activity(bar: Int) -> Int { (bar * 16..<(bar * 16 + 16)).filter(any).count }
    }

    /// The chop beat's 2-bar groove cell (D127, replacing D126 part 2's kick-locked signature stabs):
    /// the hook template's skeleton on its fixed steps, filled to `grooveHits` onsets a bar (one less
    /// in a bar where the drummer plays on most steps) at the best-scoring free steps against the
    /// drums (`FillSite`), then each stab given the cut its site prefers that differs from the hits on
    /// either side. At most `grooveRun` onsets on consecutive sixteenths, a beat without an onset in
    /// every bar, at most `grooveOffEighths` stabs on odd sixteenths per cell (one swung pickup and one
    /// ghost pocket). A line that may not be reordered keeps the new pieces of each run into a signature
    /// hit in source order.
    /// Skeleton hits hold 1/8 (less when the next hit is nearer), one signature hit per cell holds three
    /// sixteenths (a word and a syllable) and the cell's last response plays out.
    static func groove(template: [(DialogueMotifTuning.HookRole, Int)], vocabulary v: GrooveVocabulary,
                       drums: DialogueMotifDrums, reorderAllowed: Bool, fragments: [DialogueMotifFragment],
                       sampleRate: Double, seed: UInt64, beatDuration: Double = 0) -> [DialogueMotifCell.Item] {
        typealias Item = DialogueMotifCell.Item
        struct Hit { var fragment: Int; var gate: Int?; var skeleton: Bool; var site: FillSite? }
        var rng = MusicRNG(seed: seed ^ 0xD127_C40B)
        let d = GrooveDrums(drums)
        var hits: [Int: Hit] = [:]
        // The skeleton plays off the kicks too: a hit on a kick that is not a downbeat moves an 8th later
        // (or earlier) to a step without a kick, onto a snare only for the response. It depends on the
        // take alone, so the hook holds for its loops on one take.
        for (role, step) in template {
            var at = step
            if step % 16 != 0, d.kick[step] {
                let bar = (step / 16) * 16
                let free = { (k: Int) in k >= bar && k < bar + 16 && !d.kick[k] && (role == .r || !d.snare[k])
                    && !template.contains { $0.1 == k } && hits[k] == nil }
                at = [step + 2, step - 2].first(where: free) ?? step
            }
            hits[at] = Hit(fragment: role == .s ? v.s : (role == .r ? v.r : v.t), gate: nil, skeleton: true, site: nil)
        }

        func fits(_ step: Int) -> Bool {
            guard hits[step] == nil, step >= 0, step < 32 else { return false }
            let bar = (step / 16) * 16
            var on = Set(hits.keys.filter { $0 >= bar && $0 < bar + 16 })
            on.insert(step)
            var run = 0
            for k in bar..<(bar + 16) {
                run = on.contains(k) ? run + 1 : 0
                if run > DialogueMotifTuning.grooveRun { return false }
            }
            return (bar...(bar + 12)).contains { a in (a..<(a + 4)).allSatisfy { !on.contains($0) } }
        }
        func count(_ bar: Int) -> Int { hits.keys.filter { $0 / 16 == bar }.count }
        func oddCount() -> Int { hits.keys.filter { $0 % 2 == 1 }.count }

        // Positions. The pickup on the swung "a" goes into one downbeat of the cell (seeded), when it is free.
        let pushBar = rng.int(0...1)
        let jitter = (0..<32).map { _ in rng.range(0...DialogueMotifTuning.grooveJitter) }
        // D130: whole words are longer than a sixteenth, so a bar takes only as many onsets as its share
        // of the section's dry budget holds at the hook's typical cut length (at least the skeleton plus
        // one), the same in both passes of the cell. Before, the budget cut the second pass short.
        let typical: Double = {
            guard beatDuration > 0 else { return 0 }
            let cuts = Array(Set([v.s, v.r, v.t, v.sa, v.sb, v.ra, v.rb] + v.others))
            return cuts.map { DialogueMotif.cleanSeconds($0, fragments: fragments, sampleRate: sampleRate) }.reduce(0, +) / Double(max(1, cuts.count))
        }()
        let budgetHits = typical > 0
            ? Int((DialogueMotifTuning.grooveBudgetShare * DialogueMotifTuning.maximumSectionOccupancy * 4 * beatDuration / typical).rounded(.down))
            : DialogueMotifTuning.grooveHits
        for bar in 0..<2 {
            let lo = bar * 16, hi = lo + 16
            let busiest = d.busiestBeat(bar: bar)
            let skeleton = hits.keys.filter { $0 >= lo && $0 < hi }.count
            let target = min(DialogueMotifTuning.grooveHits - (d.activity(bar: bar) >= DialogueMotifTuning.busyBarSteps ? 1 : 0),
                             max(skeleton + 1, budgetHits))
            func site(_ k: Int) -> FillSite? {
                if k % 2 == 1 {
                    if k == hi - 1, bar == pushBar, !d.kick[k] { return .push }
                    if d.ghost[k] { return .ghost }
                    return nil
                }
                if d.kick[k] { return .kick }
                if d.ghost[k] { return .ghost }
                if !d.snare[k], k >= 2, d.snare[k - 2] { return .answer }
                return d.snare[k] ? .snare : .gap
            }
            func score(_ k: Int, _ s: FillSite) -> Double {
                var x: Double
                switch s {
                case .gap: x = 2
                case .answer: x = 2.6
                case .ghost: x = k % 2 == 0 ? 1.8 : 1.2
                case .push: x = 2.4
                case .kick: x = k % 16 == 0 ? 0.6 : -0.6
                case .snare: x = 0.3
                }
                // Leave the drummer's busiest beat to the drums.
                if (k % 16) / 4 == busiest { x -= 1.4 }
                // Against a flam or roll of drum hits on both neighbours.
                if d.any(k - 1) && d.any(k + 1) { x -= 0.6 }
                // Spread the stabs: a neighbour hit already on the next or previous sixteenth.
                if hits[k - 1] != nil || hits[k + 1] != nil { x -= 0.7 }
                return x + jitter[k]
            }
            while count(bar) < target {
                let open = (lo..<hi).compactMap { k -> (Int, FillSite, Double)? in
                    guard let s = site(k), fits(k) else { return nil }
                    if k % 2 == 1, oddCount() >= DialogueMotifTuning.grooveOffEighths { return nil }
                    return (k, s, score(k, s))
                }
                guard let best = open.max(by: { ($0.2, -$0.0) < ($1.2, -$1.0) }), best.2 > -1 else { break }
                hits[best.0] = Hit(fragment: -1, gate: nil, skeleton: false, site: best.1)
            }
        }

        // D130: two skeleton hits of the same cut with nothing between them (the push template's signature
        // twice) take one fill between them, past the bar's budget, so the same cut never plays twice in a row.
        let skeletonSteps = hits.keys.sorted()
        for (a, b) in zip(skeletonSteps, skeletonSteps.dropFirst()) where b - a >= 4 && hits[a]!.fragment == hits[b]!.fragment {
            let between = ((a + 2)...(b - 2)).filter { $0 % 2 == 0 && fits($0) && !d.kick[$0] }
            if let k = between.min(by: { abs(2 * $0 - a - b) < abs(2 * $1 - a - b) }) {
                hits[k] = Hit(fragment: -1, gate: nil, skeleton: false, site: d.ghost[k] ? .ghost : .gap)
            }
        }

        // Pieces, in time order: the site's preferred cut that differs from the hits on either side.
        let steps = hits.keys.sorted()
        // A site no cut fits (a line that may not be reordered) is dropped; it stays out of every later
        // lookup (an app run of 22 November 2026 crashed on a removed site still in `steps`).
        var dropped = Set<Int>()
        // A line that may not be reordered (D127): each run of a bar's hits up to and including a
        // signature hit, and the run after the bar's last one, plays its new pieces in source order,
        // so the line's words lead into its signature ("we can't | call them | brains.") and a negation
        // is never heard reversed. Before D127 the whole bar had to be in order, which left a line whose
        // signature is its last word with nothing but the signature (a live run of 22 November 2026:
        // "brains." twelve times in a row).
        let signature: Set<Int> = [v.s, v.sa, v.sb]
        func orderOK(_ step: Int, _ fragment: Int) -> Bool {
            guard !reorderAllowed else { return true }
            let bar = (step / 16) * 16
            var orders: [Int] = [], heard = Set<Int>()
            for k in steps where k >= bar && k < bar + 16 && !dropped.contains(k) {
                let f = k == step ? fragment : hits[k]!.fragment
                guard f >= 0 else { continue }
                // Only a piece new to the bar counts; a repeat of one already heard is a stutter.
                let o = fragments[f].order
                if heard.insert(o).inserted { orders.append(o) }
                if signature.contains(f) {
                    guard orders == orders.sorted() else { return false }
                    orders = []
                }
            }
            return orders == orders.sorted()
        }
        // D130: each stab takes a cut whose first content word ends before the next hit (a whole word,
        // a letter or a syllable of a salient word), and a stab that leaves the hit before it no room for
        // its own cut is dropped, so a hit is not choked or gated inside a word.
        func fits(_ f: Int, _ steps: Int) -> Bool {
            fitsRoom(f, steps: steps, fragments: fragments, sampleRate: sampleRate, beatDuration: beatDuration)
        }
        var rotation: [FillSite: Int] = [:]
        for step in steps where !hits[step]!.skeleton {
            let site = hits[step]!.site!
            let live = steps.filter { !dropped.contains($0) }
            if let p = live.last(where: { $0 < step }), hits[p]!.fragment >= 0, !fits(hits[p]!.fragment, step - p) {
                dropped.insert(step)
                continue
            }
            let room = (live.first { $0 > step } ?? (32 + (live.first ?? 0))) - step
            let prev = live.last { $0 < step }.map { hits[$0]!.fragment } ?? -1
            let next = (live.first { $0 > step } ?? live.first { $0 != step }).map { hits[$0]!.fragment } ?? -1
            var list = v.preferred(site, fragments: fragments, sampleRate: sampleRate)
            // A seeded start in the list for each kind of site, advancing as it is used, so two gaps
            // in a bar do not take the same cut.
            // D130 stage 2: among the first three (the list is weight-ordered now, so two left the fill alike).
            let start = (rotation[site] ?? rng.int(0...max(0, min(2, list.count - 1)))) % max(1, list.count)
            list = Array(list[start...] + list[..<start])
            let pool = list + v.preferred(.gap, fragments: fragments, sampleRate: sampleRate)
            // Units of one word sound in source order next to each other ("D" never right before "M"'s "L").
            func unitOrderOK(_ f: Int) -> Bool {
                guard fragments[f].kind == .letter || fragments[f].kind == .syllable, let parent = fragments[f].parent else { return true }
                if prev >= 0, fragments[prev].parent == parent, fragments[prev].isUnit, prev >= f { return false }
                if next >= 0, fragments[next].parent == parent, fragments[next].isUnit, next <= f { return false }
                return true
            }
            // D130 stage 2: a cut the cell has not played yet first (three or more cuts a cell where the line
            // offers them), and never the cut of either neighbour: a site with none is left out.
            let used = Set(steps.filter { $0 != step && !dropped.contains($0) }.map { hits[$0]!.fragment })
            func ok(_ f: Int) -> Bool { f != prev && f != next && orderOK(step, f) && fits(f, room) && unitOrderOK(f) }
            let pick = pool.first { ok($0) && !used.contains($0) } ?? pool.first(where: ok)
            guard let pick else { dropped.insert(step); continue }
            rotation[site] = start + 1 + (list.firstIndex(of: pick) ?? 0)
            let gate: Int
            switch site {
            case .gap: gate = rng.chance(0.7) ? 1 : 2
            case .answer: gate = rng.chance(0.5) ? 1 : 2
            case .ghost, .push, .kick, .snare: gate = 1
            }
            hits[step]!.fragment = pick
            hits[step]!.gate = gate
        }

        // D130 stage 2: a spell run inside the fill. Before the cell's first signature hit, the fills that
        // lead into it take the signature's letters or syllables in source order, so "D", "M" ascend into
        // "DMT" (each unit whole in its room, the run kept in order like `orderOK`'s runs).
        if let units = v.spellUnits {
            for target in steps where hits[target]!.skeleton && hits[target]!.fragment == v.s && !dropped.contains(target) {
                guard target % 4 == 0 else { continue }
                var installed = false
                for stride in [1, 2] {
                    let run = units.indices.map { target - (units.count - $0) * stride }
                    guard let first = run.first, first >= 0,
                          run.allSatisfy({ hits[$0] != nil && !hits[$0]!.skeleton && !dropped.contains($0) }),
                          units.allSatisfy({ fits($0, stride) }) else { continue }
                    let between = steps.filter { $0 >= first && $0 < target && !dropped.contains($0) }
                    guard between == run else { continue }
                    let before = steps.last { $0 < first && !dropped.contains($0) }
                    guard before.map({ fits(hits[$0]!.fragment, first - $0) }) ?? true else { continue }
                    for (i, k) in run.enumerated() { hits[k]!.fragment = units[i]; hits[k]!.gate = stride }
                    installed = true
                    break
                }
                if installed { break }
            }
        }

        // D130 stage 2: never one cut twice in a row, the cell's repeat included (whole words leave no room
        // for a fill between two skeleton hits of one cut, and a two-piece line made its third its
        // response): the later hit takes another content cut that fits its room (the last hit of the cell
        // when the pair wraps into the repeat), else it is left out when its bar keeps another onset.
        do {
            var order = steps.filter { !dropped.contains($0) }
            let pool = v.preferred(.gap, fragments: fragments, sampleRate: sampleRate) + [v.s, v.r, v.t]
            var k = 0
            while order.count >= 2, k < order.count {
                let wrap = k == order.count - 1
                let a = order[k], b = order[wrap ? 0 : k + 1]
                guard hits[a]!.fragment == hits[b]!.fragment else { k += 1; continue }
                // The hit that changes: the later one, or the cell's last one when the pair wraps; never a
                // signature skeleton hit (the signature keeps its home steps, D125).
                let later = wrap ? k : k + 1, earlier = wrap ? 0 : k
                func home(_ i: Int) -> Bool { hits[order[i]]!.skeleton && hits[order[i]]!.fragment == v.s }
                let x = home(later) && !home(earlier) && !(wrap && earlier == 0) ? earlier : later
                let step = order[x]
                let before = order[(x + order.count - 1) % order.count], after = order[(x + 1) % order.count]
                let room = (after > step ? after : after + 32) - step
                let avoid = [hits[before]!.fragment, hits[after]!.fragment]
                func unitOK(_ f: Int) -> Bool {
                    guard fragments[f].isUnit, let parent = fragments[f].parent else { return true }
                    let b = hits[before]!.fragment, n = hits[after]!.fragment
                    return !(fragments[b].isUnit && fragments[b].parent == parent && b >= f)
                        && !(fragments[n].isUnit && fragments[n].parent == parent && n <= f)
                }
                if let alt = pool.first(where: { !avoid.contains($0) && fits($0, room) && orderOK(step, $0) && unitOK($0) }) {
                    hits[step]!.fragment = alt
                    if hits[step]!.gate == nil { hits[step]!.gate = 2 }
                    k += 1
                } else if !hits[step]!.skeleton, order.filter({ $0 / 16 == step / 16 }).count > 1 {
                    dropped.insert(step)
                    order.remove(at: x)
                    k = max(0, x - 1)
                } else {
                    k += 1
                }
            }
        }

        for step in dropped { hits[step] = nil }
        let placed = hits.keys.sorted()
        let lastResponse = placed.last { hits[$0]!.fragment == v.r && hits[$0]!.skeleton }
        var held = false
        return placed.enumerated().map { k, step in
            let h = hits[step]!
            let space = (k + 1 < placed.count ? placed[k + 1] : 32) - step
            var gate: Int?
            if let g = h.gate {
                gate = min(g, max(1, space))
            } else if step == lastResponse {
                // D130: held to the next cell's first hit (it ends at a word end), so the repeat of the
                // cell is not skipped behind a response still sounding.
                gate = beatDuration > 0 ? max(1, 32 + (placed.first ?? 0) - step) : nil
            } else if space <= 2 {
                gate = max(1, space)
            } else if !held, space >= 3, h.fragment == v.s {
                // The cell's one "word and a syllable": the signature held three sixteenths.
                gate = 3
                held = true
            } else {
                gate = h.fragment == v.r ? min(space, 4) : 2
            }
            return Item(fragment: h.fragment, slot: step, fixed: true, gate: gate, skeleton: h.skeleton)
        }
    }

    /// A stab for `slot` that differs from the hits on either side: the first of `choices` that is
    /// neither the previous nor the next item's piece (and keeps source order when `reorderAllowed` is false).
    static func freshCut(_ choices: [Int], at slot: Int, among items: [DialogueMotifCell.Item]) -> Int {
        let prev = items.last { $0.slot < slot }?.fragment
        let next = items.first { $0.slot > slot }?.fragment
        return choices.first { $0 != prev && $0 != next } ?? choices.first { $0 != prev } ?? choices[0]
    }
}
