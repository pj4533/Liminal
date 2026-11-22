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

        init(s: Int, r: Int, t: Int, sa: Int, ra: Int, pieces: [Int], halves: [Int: [Int]]) {
            self.s = s; self.r = r; self.t = t; self.sa = sa; self.ra = ra
            sb = halves[s]?.first { $0 != sa } ?? s
            rb = halves[r]?.first { $0 != ra } ?? r
            let roles: Set<Int> = [s, r, t, sa, ra]
            var rest = pieces.filter { !roles.contains($0) }
            rest += ([t] + rest).flatMap { halves[$0] ?? [] }
            var seen = Set<Int>([s, r, t, sa, sb, ra, rb])
            others = rest.filter { seen.insert($0).inserted }
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
            case .kick: list = [sa, s, sb]
            case .snare: list = [ra, rb, sa, sb] + others
            }
            var seen = Set<Int>()
            return list.filter { seen.insert($0).inserted }
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
                       sampleRate: Double, seed: UInt64) -> [DialogueMotifCell.Item] {
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
        for bar in 0..<2 {
            let lo = bar * 16, hi = lo + 16
            let busiest = d.busiestBeat(bar: bar)
            let target = DialogueMotifTuning.grooveHits - (d.activity(bar: bar) >= DialogueMotifTuning.busyBarSteps ? 1 : 0)
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
        var rotation: [FillSite: Int] = [:]
        for step in steps where !hits[step]!.skeleton {
            let site = hits[step]!.site!
            let live = steps.filter { !dropped.contains($0) }
            let prev = live.last { $0 < step }.map { hits[$0]!.fragment } ?? -1
            let next = (live.first { $0 > step } ?? live.first { $0 != step }).map { hits[$0]!.fragment } ?? -1
            var list = v.preferred(site, fragments: fragments, sampleRate: sampleRate)
            // A seeded start in the list for each kind of site, advancing as it is used, so two gaps
            // in a bar do not take the same cut.
            let start = (rotation[site] ?? rng.int(0...max(0, min(1, list.count - 1)))) % max(1, list.count)
            list = Array(list[start...] + list[..<start])
            let pool = list + v.preferred(.gap, fragments: fragments, sampleRate: sampleRate)
            let pick = pool.first { $0 != prev && $0 != next && orderOK(step, $0) }
                ?? pool.first { $0 != prev && orderOK(step, $0) }
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
                gate = nil
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
