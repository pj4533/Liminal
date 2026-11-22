import Foundation

/// The drummer's kicks, full snares and ghost notes on one phrase's 64 sixteenths, and the grid time
/// of each sixteenth (D128). Built from the take's landmarks the way the dialogue chops read them: kicks
/// and snares from confidence 0.5, a snare at most `DialogueMotifTuning.ghostStrength` strong is a ghost
/// (from `ghostConfidence`), and a landmark takes a step by the rule of `LofiTimingField.sixteenthOffsets`.
/// Without a timing field the phrase is a plain boom-bap bar: kicks on steps 0 and 10, snares on 4 and 12.
nonisolated struct LofiStrumDrums: Sendable {
    static let steps = 64
    static let confidence: Float = 0.5

    private(set) var kick = [Bool](repeating: false, count: steps)
    private(set) var snare = [Bool](repeating: false, count: steps)
    private(set) var ghost = [Bool](repeating: false, count: steps)
    /// Phrase-local attack beats of confident kicks and of full snares.
    private(set) var kickBeats: [Double] = []
    private(set) var snareBeats: [Double] = []
    /// Phrase-local beat of each sixteenth on the drummer's own grid: `bar * 4 + step / 4 + offset`, where
    /// the offset is the take's `sixteenthOffsets` at that step (the chops' grid), or 0 without timing.
    private(set) var grid: [Double] = (0..<steps).map { Double($0) / 4 }

    init(timing: LofiTimingField?, timingStartBeat: Int) {
        guard let timing, timing.framesPerBeat > 0 else {
            for bar in 0..<4 {
                for step in [0, 10] { kick[bar * 16 + step] = true; kickBeats.append(grid[bar * 16 + step]) }
                for step in [4, 12] { snare[bar * 16 + step] = true; snareBeats.append(grid[bar * 16 + step]) }
            }
            return
        }
        let base = timingStartBeat * 4
        let offsets = timing.sixteenthOffsets()
        for s in 0..<Self.steps where base + s >= 0 && base + s < offsets.count { grid[s] += offsets[base + s] }
        for landmark in timing.landmarks where landmark.kind == .kick || landmark.kind == .snare {
            let isKick = landmark.kind == .kick && landmark.confidence >= Self.confidence
            let isFull = landmark.kind == .snare && landmark.confidence >= Self.confidence
                && landmark.strength > DialogueMotifTuning.ghostStrength
            let isGhost = landmark.kind == .snare && landmark.confidence >= DialogueMotifTuning.ghostConfidence
                && landmark.strength <= DialogueMotifTuning.ghostStrength
            guard isKick || isFull || isGhost else { continue }
            let takeBeat = Double(landmark.attackFrame) / timing.framesPerBeat
            let beat = takeBeat - Double(timingStartBeat)
            if beat > -1, beat < LofiClock.beats + 1 {
                if isKick { kickBeats.append(beat) }
                if isFull { snareBeats.append(beat) }
            }
            guard let step = Self.step(sixteenths: takeBeat * 4).map({ $0 - base }), (0..<Self.steps).contains(step)
            else { continue }
            if isKick { kick[step] = true }
            if isFull { snare[step] = true }
            if isGhost { ghost[step] = true }
        }
    }

    /// The sixteenth a hit at `x` sixteenths belongs to (`LofiTimingField.sixteenthOffsets`): the step it
    /// follows within a quarter of a sixteenth, an even step it precedes by at most a quarter, or, between,
    /// an odd step it follows (a swung "e" or "a").
    static func step(sixteenths x: Double) -> Int? {
        let below = Int(x.rounded(.down))
        let q = x - Double(below)
        if q <= 0.24 { return below }
        if q >= 0.76 { return (below + 1).isMultiple(of: 2) ? below + 1 : nil }
        return below.isMultiple(of: 2) ? nil : below
    }

    func anyHit(_ i: Int) -> Bool {
        guard (0..<Self.steps).contains(i) else { return false }
        return kick[i] || snare[i] || ghost[i]
    }
}

/// The strummed hook line (D128): a few choked chord stabs placed against the drums, repeated exactly,
/// with one echo throw. It yields to everything already scored: the melody, ornaments, bass, pad and
/// shells are made first and never see it, and it only takes steps they leave free.
///
/// Five archetypes (X is one sixteenth for the whole statement; bar 3 is always empty):
/// - A, lone stab: a stab at X in bars 0 and 2 (harps: a three-string roll that rings a beat);
/// - B, call and answer: bar 0 V1, bar 1 V1 an inversion lower for half a beat, bar 2 V1;
/// - C, chk-a: bars 0 and 2 a four-string down-stab at an even X with an up-stroke on X + 1, and a
///   dead-stroke pickup one step before X in bar 2 now and then;
/// - D, held chord: bar 0 a five-string hold (harps: a slow roll), bar 2 its top three strings;
/// - E, dyad hook: a two-string stab at X in bars 0, 1 and 2 (0 and 2 in take bars 5-8).
/// The statement's last stroke is thrown into the echo when it starts by beat 10.5.
///
/// Turn-taking with the chops follows the 16-bar arc's fixed shape: in take bars 9-12 (position 2) the
/// chops hold a word or two a bar, so the hook answers the snare and pushes into kicks; in take bars 5-8
/// (position 1, the chop beat) it only plays with kicks or on an even gap, at most twice.
nonisolated enum LofiStrumHook {
    /// A to E, in `LofiStrum.Event.archetype` numbering.
    enum Archetype: Int, CaseIterable, Sendable { case loneStab, callAndAnswer, chka, held, dyad }

    enum Tuning {
        /// Hook events start here or later, end by `windowEnd` (or the phrase's ending rest) and are
        /// thrown only up to `latestThrow`, so the last bar and the approach to the next phrase are clear.
        static let earliest = 1.0
        static let windowEnd = 12.5
        static let latestThrow = 10.5
        static let snareClearance = 0.040
        static let kickClearance = 0.030
        /// Strings under this MIDI pitch keep `kickClearance` from a kick.
        static let lowString = 52
        static let leadClearance = 0.25
        static let shellClearance = 0.25
        static let ornamentClearance = 0.12
        /// A bar with this many melody onsets has no hook.
        static let busyBar = 3
        /// Beats between gestures (an up-stroke or a pickup belongs to its stab).
        static let spacing = 1.0
        /// How often a hook plays: guitars in take bars 5-8 (position 1; always in position 2), and
        /// harps in positions 1 and 2. A harp roll rings into the chop beat of take bars 5-8 and sat level
        /// with the chops in 1-4 kHz there (D128 stage 5), so harps play hooks only in the breakdown.
        static let variationChance: Float = 0.60
        static let harpChance: (variation: Float, breakdown: Float) = (0, 0.70)
        /// Gain of a hook in take bars 5-8 (position 1), where the chop beat is the foreground: 3 dB
        /// under the breakdown's, so a stab that meets a chop sits at least 3 dB under it in 1-4 kHz.
        static let variationGain: Float = 0.71
        /// Archetype C's dead-stroke pickup.
        static let pickupChance: Float = 0.35
        /// Programs with `fingerstyle` under this lean to strummed archetypes (A, B, C).
        static let strumLean = 0.55
        /// Lowest string of a stab, dyad or up-stroke; of a hold or roll.
        static let stabFloor = 50
        static let holdFloor = 48
        /// The voicings' top string sits three semitones under the melody's highest note, inside this range.
        static let ceiling = 60...67
        /// Odd takes' breakdowns play the held chord (D) first this often, the dyad hook (E) otherwise.
        static let heldChance: Float = 0.75
        /// Added to a step whose statement can end with a throw.
        static let throwBonus = 1.0

        /// Site scores in take bars 9-12 (position 2) and 5-8 (position 1); nil is not allowed.
        static func score(_ site: LofiStrum.Site, position: Int, snarePlusOne: Bool = false) -> Double? {
            if position == 1 {
                switch site {
                case .withKick: return 3.0
                case .gap: return 1.5
                case .answer, .push: return nil
                }
            }
            switch site {
            case .answer: return snarePlusOne ? 2.0 : 3.0
            case .push: return 2.2
            case .withKick: return 0.8
            case .gap: return 1.5
            }
        }
    }

    /// One stroke of a statement before X is chosen.
    private struct Stroke {
        var bar: Int
        /// Sixteenths from X.
        var offset: Int
        var kind: LofiStrum.Kind
        var strings: [Int]
        var length: Double
        var spreadMs: Double
        /// The gesture this stroke belongs to; the gesture's first stroke is its primary.
        var gesture: Int
        var primary: Bool
        /// The shortest length a hold or roll may be cut to at the window's end.
        var minimumLength: Double
    }

    struct Context {
        let chord: [(pitchClass: Int, role: LofiStrumVoicing.Role)]
        let leadOnsets: [Double]
        let shellOnsets: [Double]
        let ornamentOnsets: [Double]
        let drums: LofiStrumDrums
        let position: Int
        let beatSeconds: Double
        let windowEnd: Double
        let busyBars: Set<Int>
    }

    /// The hook events of one phrase, or none. `position` is the phrase's place in its take (1 or 2),
    /// `take` its take index (`phrase / 4`), `sessionSeed` the drift's seed (the archetype cycle) and
    /// `random` the phrase's own stream (`phraseRandom.fork(2_512)`).
    static func make(lead: [LofiScore.Note], ornaments: [LofiScore.Note], texture: [LofiScore.Note],
                     harmony: LofiScore.Harmony, chordDegree: Int, position: Int, preset: LofiPreset,
                     timing: LofiTimingField?, timingStartBeat: Int, beatSeconds: Double, windowEnd: Double,
                     take: Int, sessionSeed: UInt64, random: MusicRNG) -> [LofiStrum.Event] {
        guard preset.strum != .none, (1...2).contains(position), !lead.isEmpty else { return [] }
        var rng = random
        let gate = rng.unit()
        let chance: Float
        switch (preset.strum, position) {
        case (.roll, 1): chance = Tuning.harpChance.variation
        case (.roll, _): chance = Tuning.harpChance.breakdown
        case (_, 1): chance = Tuning.variationChance
        default: chance = 1
        }
        guard gate < chance else { return [] }

        var busy: [Int: Int] = [:]
        for note in lead { busy[Int((note.beat / 4).rounded(.down)), default: 0] += 1 }
        let chord = LofiStrumVoicing.classes(harmony: harmony, chordDegree: chordDegree)
        let context = Context(chord: chord, leadOnsets: lead.map(\.beat),
                              shellOnsets: texture.filter { $0.articulation != .pad }.map(\.beat),
                              ornamentOnsets: ornaments.map(\.beat),
                              drums: LofiStrumDrums(timing: timing, timingStartBeat: timingStartBeat),
                              position: position, beatSeconds: max(0.001, beatSeconds),
                              windowEnd: min(Tuning.windowEnd, windowEnd),
                              busyBars: Set(busy.filter { $0.value >= Tuning.busyBar }.keys))
        let top = lead.map(\.midi).max() ?? 67
        let ceiling = min(Tuning.ceiling.upperBound, max(Tuning.ceiling.lowerBound, top - 3))
        for archetype in archetypes(take: take, position: position, preset: preset, sessionSeed: sessionSeed) {
            var statementRandom = rng.fork(UInt64(archetype.rawValue) + 1)
            let strokes = statement(archetype, roll: preset.strum == .roll, position: position, chord: chord,
                                    ceiling: ceiling, random: &statementRandom)
            if let events = choose(strokes, archetype: archetype, chord: chord, context: context,
                                  random: &statementRandom), !events.isEmpty {
                return events
            }
        }
        return []
    }

    /// The archetypes a take may play, best first. Even takes draw from A, B and C, odd takes from D and
    /// E, so two consecutive takes never play the same one whatever their programs and positions (the
    /// 16-bar ceiling). Position 1 plays only A (even) or E (odd), harps only A or D, and the fingerstyle
    /// lean never plays C. Inside a class the order turns with the take.
    static func archetypes(take: Int, position: Int, preset: LofiPreset, sessionSeed: UInt64) -> [Archetype] {
        let even = take.isMultiple(of: 2)
        let root = MusicRNG(seed: sessionSeed).fork(2_513)
        if preset.strum == .roll { return even ? [.loneStab] : [.held] }
        if position == 1 { return even ? [.loneStab] : [.dyad] }
        let pair = take / 2
        if even {
            if preset.fingerstyle < Tuning.strumLean {
                let first = root.fork(1).shuffledCycle(Archetype.allCases.filter { $0.rawValue <= 2 }, index: pair)
                return [first] + [Archetype.loneStab, .callAndAnswer, .chka].filter { $0 != first }
            }
            var turn = root.fork(2 + UInt64(pair))
            return turn.chance(0.5) ? [.callAndAnswer, .loneStab] : [.loneStab, .callAndAnswer]
        }
        var turn = root.fork(1_000 + UInt64(pair))
        return turn.chance(Tuning.heldChance) ? [.held, .dyad] : [.dyad, .held]
    }

    // MARK: Statement

    private static func statement(_ archetype: Archetype, roll: Bool, position: Int,
                                  chord: [(pitchClass: Int, role: LofiStrumVoicing.Role)], ceiling: Int,
                                  random: inout MusicRNG) -> [Stroke] {
        // A minor chord's three-string shapes need its seventh or ninth on top, so a low ceiling may
        // leave none: the ceiling then opens to the register's top, string count before ceiling.
        func voicing(_ strings: [Int], floor: Int, ceiling: Int) -> [Int] {
            for count in strings {
                for top in [ceiling, Tuning.ceiling.upperBound, LofiStrumVoicing.register.upperBound] where top >= ceiling {
                    let v = LofiStrumVoicing.voicing(classes: chord, strings: count, floor: floor, ceiling: top,
                                                     random: &random)
                    if !v.isEmpty { return v }
                }
            }
            return []
        }
        func spread(_ kind: LofiStrum.Kind) -> Double { random.range(LofiStrum.Tuning.shape(kind).spreadMs) }
        func stroke(_ bar: Int, _ kind: LofiStrum.Kind, _ strings: [Int], _ length: Double, _ spreadMs: Double,
                    gesture: Int, offset: Int = 0, primary: Bool = true, minimum: Double? = nil) -> Stroke {
            Stroke(bar: bar, offset: offset, kind: kind, strings: strings, length: length, spreadMs: spreadMs,
                   gesture: gesture, primary: primary, minimumLength: minimum ?? length)
        }
        let stabLength = LofiStrum.Tuning.stabLength
        if roll {
            let rollSpread = spread(.roll)
            switch archetype {
            case .held:
                let full = voicing([5, 4, 3], floor: Tuning.holdFloor, ceiling: ceiling)
                guard !full.isEmpty else { return [] }
                let upper = subset(full, top: 3, chord: chord) ?? voicing([3], floor: Tuning.holdFloor, ceiling: full[full.count - 1])
                let length = random.range(1.5...LofiStrum.Tuning.roll.length.upperBound)
                return [stroke(0, .roll, full, length, rollSpread, gesture: 0, minimum: LofiStrum.Tuning.roll.length.lowerBound),
                        stroke(2, .roll, upper, 1.0, rollSpread, gesture: 1)]
            default:
                let v = voicing([3], floor: Tuning.holdFloor, ceiling: ceiling)
                guard !v.isEmpty else { return [] }
                return [stroke(0, .roll, v, 1.0, rollSpread, gesture: 0), stroke(2, .roll, v, 1.0, rollSpread, gesture: 1)]
            }
        }
        switch archetype {
        case .loneStab:
            let v = voicing(random.chance(0.5) ? [4, 3] : [3, 4], floor: Tuning.stabFloor, ceiling: ceiling)
            guard !v.isEmpty else { return [] }
            let s = spread(.stab)
            return [stroke(0, .stab, v, stabLength, s, gesture: 0), stroke(2, .stab, v, stabLength, s, gesture: 1)]
        case .callAndAnswer:
            let v = voicing(random.chance(0.5) ? [4, 3] : [3, 4], floor: Tuning.stabFloor, ceiling: ceiling)
            guard !v.isEmpty else { return [] }
            let s = spread(.stab)
            let answer = LofiStrumVoicing.inversionBelow(v, floor: Tuning.stabFloor)
            return [stroke(0, .stab, v, stabLength, s, gesture: 0),
                    stroke(1, .stab, answer, LofiStrum.Tuning.answerLength, s, gesture: 1),
                    stroke(2, .stab, v, stabLength, s, gesture: 2)]
        case .chka:
            let v = voicing([4, 3], floor: Tuning.stabFloor, ceiling: ceiling)
            guard !v.isEmpty else { return [] }
            let s = spread(.stab)
            let upStrings = subset(v, top: 3, chord: chord) ?? subset(v, top: 2, chord: chord) ?? []
            let deadStrings = subset(v, bottom: 3, chord: chord) ?? subset(v, bottom: 2, chord: chord) ?? []
            let up = LofiStrum.Tuning.up.length.lowerBound
            let dead = LofiStrum.Tuning.dead.length.lowerBound
            let deadSpread = spread(.dead)
            let pickup = random.chance(Tuning.pickupChance)
            var out = [stroke(0, .stab, v, stabLength, s, gesture: 0)]
            if !upStrings.isEmpty {
                out.append(stroke(0, .up, upStrings, up, s * LofiStrum.Tuning.upSpreadScale, gesture: 0, offset: 1, primary: false))
            }
            if pickup, !deadStrings.isEmpty {
                out.append(stroke(2, .dead, deadStrings, dead, deadSpread, gesture: 1, offset: -1, primary: false))
            }
            out.append(stroke(2, .stab, v, stabLength, s, gesture: 1))
            if !upStrings.isEmpty {
                out.append(stroke(2, .up, upStrings, up, s * LofiStrum.Tuning.upSpreadScale, gesture: 1, offset: 1, primary: false))
            }
            return out
        case .held:
            let full = voicing([5, 4], floor: Tuning.holdFloor, ceiling: ceiling)
            guard !full.isEmpty else { return [] }
            let stab = subset(full, top: 3, chord: chord).flatMap { $0[0] >= Tuning.stabFloor ? $0 : nil }
                ?? voicing([3], floor: Tuning.stabFloor, ceiling: full[full.count - 1])
            let length = random.range(LofiStrum.Tuning.hold.length)
            var out = [stroke(0, .hold, full, length, spread(.hold), gesture: 0,
                              minimum: LofiStrum.Tuning.hold.length.lowerBound)]
            if !stab.isEmpty { out.append(stroke(2, .stab, stab, stabLength, spread(.stab), gesture: 1)) }
            return out
        case .dyad:
            let v = voicing([2], floor: Tuning.stabFloor, ceiling: ceiling)
            guard !v.isEmpty else { return [] }
            let s = spread(.dyad)
            let length = LofiStrum.Tuning.dyad.length.lowerBound
            let bars = position == 1 ? [0, 2] : [0, 1, 2]
            return bars.enumerated().map { stroke($0.element, .dyad, v, length, s, gesture: $0.offset) }
        }
    }

    /// The top or bottom `count` strings of `voicing` when they keep every voicing rule on their own.
    private static func subset(_ voicing: [Int], top: Int? = nil, bottom: Int? = nil,
                               chord: [(pitchClass: Int, role: LofiStrumVoicing.Role)]) -> [Int]? {
        let count = top ?? bottom ?? 0
        guard count >= 2, voicing.count >= count else { return nil }
        let part = top != nil ? Array(voicing.suffix(count)) : Array(voicing.prefix(count))
        return LofiStrumVoicing.isValid(part, chord: chord, rootClass: chord.first?.pitchClass) ? part : nil
    }

    // MARK: Placement

    /// The strongest drum site of a stroke at phrase step `i`, with its score, or nil when none is allowed.
    static func site(at i: Int, kind: LofiStrum.Kind, drums: LofiStrumDrums, position: Int)
        -> (site: LofiStrum.Site, score: Double)? {
        let step = i % 16
        var best: (site: LofiStrum.Site, score: Double)?
        func offer(_ site: LofiStrum.Site, snarePlusOne: Bool = false) {
            guard let score = Tuning.score(site, position: position, snarePlusOne: snarePlusOne) else { return }
            if best.map({ score > $0.score }) ?? true { best = (site, score) }
        }
        if i >= 2, drums.snare[i - 2] { offer(.answer) } else if i >= 1, drums.snare[i - 1] { offer(.answer, snarePlusOne: true) }
        if i + 2 < LofiStrumDrums.steps, drums.kick[i + 2], !drums.anyHit(i) { offer(.push) }
        // A hold rings through the kick; only short strokes and rolls sit with one.
        if drums.kick[i], step != 0, kind != .hold { offer(.withKick) }
        if !drums.anyHit(i - 1), !drums.anyHit(i), !drums.anyHit(i + 1), position != 1 || step.isMultiple(of: 2) {
            offer(.gap)
        }
        return best
    }

    /// Whether a stroke whose strings start at `onsets` (first string first) and end at `end` keeps
    /// every rule of the hook window, the drums and the scored parts.
    static func allowed(bar: Int, step: Int, onsets: [Double], strings: [Int], end: Double, context: Context) -> Bool {
        guard (0...3).contains(bar), (1...14).contains(step), let first = onsets.first, !context.busyBars.contains(bar)
        else { return false }
        let i = bar * 16 + step
        let drums = context.drums
        guard !drums.snare[i], first >= Tuning.earliest - 1e-9, end <= context.windowEnd + 1e-9 else { return false }
        let seconds = context.beatSeconds
        if drums.snareBeats.contains(where: { abs($0 - first) * seconds < Tuning.snareClearance }) { return false }
        for (onset, midi) in zip(onsets, strings) where midi < Tuning.lowString {
            if drums.kickBeats.contains(where: { abs($0 - onset) * seconds < Tuning.kickClearance }) { return false }
        }
        for onset in onsets {
            if context.leadOnsets.contains(where: { abs($0 - onset) < Tuning.leadClearance - 1e-9 }) { return false }
            if context.shellOnsets.contains(where: { abs($0 - onset) < Tuning.shellClearance - 1e-9 }) { return false }
            if context.ornamentOnsets.contains(where: { abs($0 - onset) < Tuning.ornamentClearance - 1e-9 }) { return false }
        }
        return true
    }

    /// String onsets of a stroke, in stroke order (low first on a down-stroke), paired with their pitches.
    private static func onsets(beat: Double, kind: LofiStrum.Kind, strings: [Int], spreadMs: Double,
                               beatSeconds: Double) -> (onsets: [Double], strings: [Int]) {
        let order = kind == .up ? Array(strings.reversed()) : strings
        let spread = spreadMs / 1000 / beatSeconds
        return (order.indices.map { beat + Double($0) * spread }, order)
    }

    private struct Placed {
        var stroke: Stroke
        var step: Int
        var beat: Double
        var length: Double
        var site: LofiStrum.Site
        var score: Double
    }

    /// The strokes that survive at statement step `x`: a gesture whose primary is not allowed is dropped
    /// with its up-stroke and pickup; those are dropped alone when only they break a rule.
    private static func placements(_ strokes: [Stroke], x: Int, context: Context) -> [Placed] {
        var out: [Placed] = []
        var keptGestures = Set<Int>()
        var siteOfGesture: [Int: LofiStrum.Site] = [:]
        var lastPrimary = -Double.infinity
        // Primaries first, in order, so secondaries know whether their gesture survived.
        for stroke in strokes where stroke.primary {
            guard let placed = place(stroke, x: x, site: nil, context: context),
                  placed.beat - lastPrimary >= Tuning.spacing - 1e-9 else { continue }
            lastPrimary = placed.beat
            keptGestures.insert(stroke.gesture)
            siteOfGesture[stroke.gesture] = placed.site
            out.append(placed)
        }
        for stroke in strokes where !stroke.primary {
            guard keptGestures.contains(stroke.gesture), let site = siteOfGesture[stroke.gesture],
                  let placed = place(stroke, x: x, site: site, context: context) else { continue }
            out.append(placed)
        }
        return out.sorted { $0.beat < $1.beat }
    }

    private static func place(_ stroke: Stroke, x: Int, site inherited: LofiStrum.Site?, context: Context) -> Placed? {
        let step = x + stroke.offset
        guard (1...14).contains(step), !stroke.strings.isEmpty else { return nil }
        let i = stroke.bar * 16 + step
        let found: (site: LofiStrum.Site, score: Double)
        if let inherited {
            found = (inherited, 0)
        } else {
            guard let site = site(at: i, kind: stroke.kind, drums: context.drums, position: context.position) else { return nil }
            found = site
        }
        // With a kick, only the top three strings, when they make a voicing of their own.
        let strings = found.site == .withKick && inherited == nil ? Array(stroke.strings.suffix(3)) : stroke.strings
        if strings.count < stroke.strings.count,
           !LofiStrumVoicing.isValid(strings, chord: context.chord, rootClass: context.chord.first?.pitchClass) {
            return nil
        }
        let beat = context.drums.grid[i]
        let length = min(stroke.length, context.windowEnd - beat)
        guard length >= stroke.minimumLength - 1e-9 else { return nil }
        let timing = onsets(beat: beat, kind: stroke.kind, strings: strings, spreadMs: stroke.spreadMs,
                            beatSeconds: context.beatSeconds)
        guard allowed(bar: stroke.bar, step: step, onsets: timing.onsets, strings: timing.strings, end: beat + length,
                      context: context) else { return nil }
        var kept = stroke
        kept.strings = strings
        return Placed(stroke: kept, step: step, beat: beat, length: length, site: found.site, score: found.score)
    }

    /// Chooses X (the best summed site score over the statement's surviving gestures, plus a bonus when
    /// its last stroke can be thrown; ties by the seeded RNG) and returns the statement's events.
    private static func choose(_ strokes: [Stroke], archetype: Archetype,
                              chord: [(pitchClass: Int, role: LofiStrumVoicing.Role)], context: Context,
                              random: inout MusicRNG) -> [LofiStrum.Event]? {
        guard !strokes.isEmpty else { return nil }
        let evenOnly = archetype == .chka
        var best: [(x: Int, placed: [Placed])] = []
        var bestScore = -Double.infinity
        for x in 1...14 where !evenOnly || x.isMultiple(of: 2) {
            let placed = placements(strokes, x: x, context: context)
            let gestures = Set(placed.map(\.stroke.gesture))
            guard gestures.count >= 2 else { continue }
            var score = placed.reduce(0) { $0 + $1.score }
            if let last = placed.last, last.beat <= Tuning.latestThrow + 1e-9 { score += Tuning.throwBonus }
            if score > bestScore + 1e-9 {
                bestScore = score
                best = [(x, placed)]
            } else if abs(score - bestScore) <= 1e-9 {
                best.append((x, placed))
            }
        }
        guard !best.isEmpty else { return nil }
        var placed = best.count == 1 ? best[0].placed : best[random.int(0...(best.count - 1))].placed
        // Exact repeats: when one stab of a voicing sits with a kick (top three strings), every repeat of
        // that voicing plays the same three strings.
        for index in placed.indices where placed[index].stroke.kind != .up && placed[index].stroke.kind != .dead {
            let source = strokes.first { $0.gesture == placed[index].stroke.gesture && $0.primary }?.strings
            guard let source, placed[index].stroke.strings.count < source.count else { continue }
            let reduced = placed[index].stroke.strings
            for other in placed.indices where other != index && placed[other].stroke.primary {
                let otherSource = strokes.first { $0.gesture == placed[other].stroke.gesture && $0.primary }?.strings
                if otherSource == source { placed[other].stroke.strings = reduced }
            }
        }
        // Up-strokes and pickups take their strings from the stab they belong to as placed.
        for index in placed.indices where !placed[index].stroke.primary {
            guard let stab = placed.first(where: { $0.stroke.primary && $0.stroke.gesture == placed[index].stroke.gesture })
            else { continue }
            let count = placed[index].stroke.strings.count
            let derived = placed[index].stroke.kind == .up
                ? (subset(stab.stroke.strings, top: count, chord: chord) ?? subset(stab.stroke.strings, top: 2, chord: chord))
                : (subset(stab.stroke.strings, bottom: count, chord: chord) ?? subset(stab.stroke.strings, bottom: 2, chord: chord))
            if let derived { placed[index].stroke.strings = derived }
        }
        let lastIndex = placed.indices.last
        return placed.enumerated().map { index, p in
            LofiStrum.Event(bar: p.stroke.bar, step: p.step, beat: p.beat, kind: p.stroke.kind, down: p.stroke.kind != .up,
                            strings: p.stroke.strings, spreadMs: p.stroke.spreadMs, length: p.length,
                            thrown: index == lastIndex && p.beat <= Tuning.latestThrow + 1e-9,
                            site: p.site, archetype: archetype.rawValue)
        }
    }
}
