import Foundation

/// The riddim bass line (plan 2.5). A four-bar phrase states a two-bar cell in bars 1-2 and repeats it in
/// bars 3-4 with a change in bar 4. The cell is built from the take's own kicks and seeded per take
/// (`phrase / 4`), so one figure runs for sixteen bars and changes with the drum take. Every note that
/// lands on a confident kick is anchored: its 40-160 Hz rise is placed on the kick's (C-B2). Notes between
/// the kicks sit behind the beat and are never within `bassKickSafety` beats of a confident kick.
nonisolated extension LofiScore {
    /// The downbeat looks this far (in beats) for a played kick to lock to.
    static let bassAccentWindow = 0.12
    /// Kicks below this confidence never move a bass note.
    static let bassAccentConfidence: Float = 0.6
    /// A note not anchored to a kick never starts this close (beats) to a confident kick: it moves onto it.
    static let bassKickSafety = 0.20
    /// Gap answers keep this far (beats) from any confident kick or snare.
    static let bassGapClearance = 0.25
    /// An anchored or struck note's predecessor is silent this long (seconds) before it starts.
    static let bassAccentClearance = 0.030
    /// Into a note that is neither, the predecessor's release may overlap it by this much (seconds): a
    /// cross-fade with no gap (plan bass-tone-redo 4.3).
    static let bassLegatoOverlap = 0.040
    /// Anchored notes sustain to the next onset, at most this many beats (`hold` `bassHoldCap`).
    static let bassSustainCap = 2.5
    static let bassHoldCap = 3.0
    /// One breath per two-bar cell: the note before a pickup keeps its drawn length when that leaves at
    /// least this many beats of rest.
    static let bassBreathRest = 0.35
    /// The strike layer moves at most this far (seconds) from its note's start onto the kick's attack.
    static let bassStrikeAdvance = 0.025
    /// A sustained note whose last `bassEndingKickWindow` beats would sound over a kick it is not anchored
    /// to (confidence at least `bassEndingKickConfidence`, the C-B2 measure's) ends `bassAccentClearance`
    /// before that kick instead: a note fading out under a kick at the same level cancels it (D119).
    static let bassEndingKickWindow = 0.06
    static let bassEndingKickConfidence: Float = 0.5
    /// A shortened bass note keeps at least this many beats of sustain.
    static let bassShortestLength = 0.12
    /// Sounding beats per bar at most, and per phrase for the full sections (plan bass-tone-redo 4.2).
    static let bassBarSoundingLimit = 3.8
    static let bassPhraseSounding = 10.5...14.5
    /// A note anchored early to a kick on the bar line belongs to the new bar: bars are counted from this
    /// many beats before each bar line, and a note behind the beat never crosses it.
    static let bassBarLead = 0.12
    /// The bar (0 to 3) a performed bass note belongs to.
    static func bassBar(_ beat: Double) -> Int { min(3, max(0, Int((beat + bassBarLead) / 4))) }
    /// The send level that marks a thrown bass note (`LofiBassThrow`).
    static let bassThrowSend: Float = 1

    struct BassLine: Sendable {
        var notes: [Note]
        var anchors: [BassAnchor]
        var sweep: ClosedRange<Double>?
    }

    /// Every phrase plays one tone (`LofiBassTone.current`: `standard` in the app, plan bass-tone-redo 2).
    static func bassVoice(seed: UInt64, section: Section, phrase: Int) -> LofiBassVoice {
        LofiBassTone.current.voice
    }

    /// The strike of a note anchored to a kick: full on the downbeat, kick and weight notes, lighter on an
    /// ornament or pickup that landed on a kick; never on a ghost.
    static func bassStrike(role: BassRole) -> Float {
        switch role {
        case .downbeat, .kick, .weight: 1.0
        case .answer, .pickup: 0.6
        case .ghost: 0
        }
    }

    // MARK: Cell

    enum BassDegree: Sendable { case root, fifth, octave, flatSeven, minorThird, approach }
    enum BassRole: Sendable { case downbeat, kick, weight, answer, ghost, pickup }

    struct CellNote: Sendable {
        var grid: Double
        var degree: BassDegree
        var role: BassRole
        var stroke: BassStroke
        var length: Double
        var velocity: Float
    }

    /// The take-seeded choices of the cell, drawn in a fixed order so they never depend on the kicks.
    struct CellDraws: Sendable {
        var keep: [Float]
        var length: [Double]
        var degree: [Float]
        var holdOnDownbeat: Bool
        var holdLength: Double
        var holdOnFifth: Bool
        var answers: Int
        var answerOrder: [Double]
        var ghostChance: Float
        var pickup: Double
        var pickupDegree: BassDegree
        var pocket: Double
        var dropOut: Double
        var slide: Int
        var ghostVelocity: Float

        init(seed: UInt64, take: Int) {
            var r = MusicRNG(seed: seed).fork(UInt64(take) &* 31 &+ 1_240)
            keep = (0..<32).map { _ in r.unit() }
            length = (0..<32).map { _ in r.unitD() }
            degree = (0..<32).map { _ in r.unit() }
            holdOnDownbeat = r.chance(0.5)
            holdLength = r.range(1.0...2.0)
            holdOnFifth = r.chance(0.3)
            answers = r.chance(0.5) ? 2 : 1
            var order: [Double] = [1.5, 2.75, 3.5, 5.5, 6.75, 3.25]
            for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, r.int(0...i)) }
            answerOrder = order
            ghostChance = r.unit()
            pickup = 7.5
            pickupDegree = r.pick([.fifth, .octave, .approach])
            pocket = r.range(0.020...0.045)
            dropOut = r.pick([2.0, 3.0, 4.0])
            slide = r.chance(0.5) ? r.int(2...5) : 0
            ghostVelocity = r.rangeF(0.30...0.50)
        }
    }

    /// Boom-bap kick figures (cell beats) for a phrase without drums, seeded per take.
    static let bassKickTemplates: [[Double]] = [
        [0, 1.75, 2.5, 4, 5.75, 6.5],
        [0, 0.75, 2.5, 4, 4.75, 6.5, 7.25],
        [0, 1.5, 2.75, 4, 5.5, 6.75]
    ]

    static func bassLine(harmony: Harmony, section: Section, random: MusicRNG, kickBeats: [Double],
                         timing: LofiTimingField?, timingStartBeat: Int, voice: LofiBassVoice,
                         beatSeconds: Double, seed: UInt64 = 0, phrase: Int = 0) -> BassLine {
        let take = max(0, phrase) / LofiDrumTake.phraseCount
        let position = max(0, phrase) % LofiDrumTake.phraseCount
        let draws = CellDraws(seed: seed, take: take)
        let kicks = timing.map { kickRises($0, phraseStartBeat: timingStartBeat) } ?? []
        let snares = timing?.snares(phraseStartBeat: timingStartBeat, minConfidence: LofiTimingField.anchorConfidence)
        // Kick sixteenths of the phrase: the timing field, the legacy kick list, or a template.
        var slots: [Double]
        if timing != nil {
            slots = kicks.map { ($0.attack * 4).rounded() / 4 }
        } else if !kickBeats.isEmpty {
            slots = kickBeats.map { ($0 * 4).rounded() / 4 }
        } else {
            var t = MusicRNG(seed: seed).fork(UInt64(take) &+ 1_377)
            let template = t.pick(bassKickTemplates)
            slots = template + template.map { $0 + 8 }
        }
        slots = Array(Set(slots.filter { (0..<LofiClock.beats).contains($0) })).sorted()
        let backbeats = snares ?? [1, 3, 5, 7, 9, 11, 13, 15]
        let cell = makeCell(draws: draws, kickSlots: slots.filter { $0 < 8 }, snares: backbeats.filter { $0 < 8.25 })

        // Sections (plan 2.5.9).
        let home = harmony.bass(0)
        let fifthRoot = harmony.bass(7, near: home)
        let scale = harmony.pitches(in: 26...55)
        let repeated = balance(changeBarFour(cell.map { note in var n = note; n.grid += 8; return n },
                                             draws: draws, kickSlots: slots, snares: backbeats, octave: section == .variation,
                                             pitch: { pitch($0, root: home, scale: scale) }),
                               bars: [2, 3], range: 3...5, kickSlots: slots, snares: backbeats, draws: draws)
        var grid: [(note: CellNote, root: Int)]
        switch section {
        case .theme, .variation:
            grid = (cell + repeated).map { ($0, home) }
        case .returnTheme:
            let slammed = slam((cell + repeated).map { ($0, home) }, home: home).map(\.note)
            grid = balance(slammed, bars: [0], range: 3...5, kickSlots: slots, snares: backbeats, draws: draws).map { ($0, home) }
        case .answer:
            let home34 = balance(thin(repeated, perBar: 3), bars: [2, 3], range: 2...3, kickSlots: slots, snares: backbeats,
                                 draws: draws)
            grid = cell.map { ($0, fifthRoot) } + home34.map { ($0, home) }
        case .breakdown:
            grid = thin(cell + repeated, perBar: 2).map { ($0, home) }
        }
        var sweep: ClosedRange<Double>?
        var end = LofiClock.beats
        if section == .breakdown {
            // The drop-out: the last two to four beats are silent, and the note before them is thrown.
            end = LofiClock.beats - draws.dropOut
            grid = grid.filter { $0.note.grid < end - 0.25 }
            // Dub filter movement once per eight phrases, in the second breakdown of the form.
            if phrase % phrasesPerForm == 6 { sweep = 0...end }
        }

        // Strokes on the grid: a kick note is a `thump` when another note follows within a beat (or a kick
        // within half a beat), else a `walk`.
        let gridBeats = grid.map(\.note.grid)
        for i in grid.indices where (grid[i].note.role == .kick || grid[i].note.role == .downbeat)
            && grid[i].note.stroke != .hold {
            let g = gridBeats[i]
            let nextNote = gridBeats.filter { $0 > g + 1e-9 }.min() ?? .infinity
            let nextKick = slots.filter { $0 > g + 1e-9 }.min() ?? .infinity
            grid[i].note.stroke = nextNote - g <= 1 || nextKick - g <= 0.5 ? .thump : .walk
            grid[i].note.length = strokeLength(grid[i].note.stroke, draws.length[Int(g * 4) % 32])
        }

        // Pitch and performance. Notes on the kick grid claim their kicks first; the others then sit behind
        // the beat but clear of every confident kick, moving onto a free one if they would crowd it.
        var placed: [(note: Note, role: BassRole)] = []
        var anchors: [BassAnchor] = []
        var claimed = Set<Int>()
        func isStructural(_ n: CellNote) -> Bool { n.role == .downbeat || n.role == .kick || slots.contains(n.grid) }
        let order = grid.indices.filter { isStructural(grid[$0].note) } + grid.indices.filter { !isStructural(grid[$0].note) }
        for index in order {
            let (cellNote, root) = grid[index]
            var midi = pitch(cellNote.degree, root: root, scale: scale)
            let structural = isStructural(cellNote)
            var beat: Double
            var anchor: BassAnchor?
            var strike: Float = 0
            if let timing {
                var target = cellNote.grid
                if !structural {
                    let lean = timing.offset(atBeat: Double(timingStartBeat) + cellNote.grid)
                    // Behind the beat, but never across the next bar line or into the next kick's safety zone.
                    target = min(cellNote.grid + draws.pocket + min(bassAccentWindow, max(-bassAccentWindow, lean)),
                                 (cellNote.grid / 4).rounded(.down) * 4 + 4 - bassBarLead)
                    if let next = kicks.map(\.attack).filter({ $0 > cellNote.grid - 1e-9 }).min(),
                       next - target < bassKickSafety + 0.01 {
                        target = max(cellNote.grid, next - bassKickSafety - 0.01)
                    }
                }
                let kick = kicks.enumerated().filter { abs($0.element.attack - target) <= bassKickSafety + 1e-9 }
                    .min { abs($0.element.attack - target) < abs($1.element.attack - target) }
                if let kick {
                    // Two notes never share a kick: the one that came later gives way.
                    guard !claimed.contains(kick.offset) else { continue }
                    claimed.insert(kick.offset)
                    // An ornament moved onto a kick drops into the structural register, under the kick.
                    if midi > 41 { midi -= 12 }
                    strike = cellNote.stroke == .ghost ? 0 : bassStrike(role: cellNote.role)
                    let lead = voice.lowRiseLead(midi: midi, stroke: cellNote.stroke, struck: strike > 0) / beatSeconds
                    beat = max(0, kick.element.lowRise - lead)
                    anchor = BassAnchor(noteBeat: beat, kickBeat: kick.element.attack,
                                        kickLowRiseBeat: kick.element.lowRise, bassLowRiseBeats: lead)
                } else {
                    beat = target
                }
            } else {
                // Legacy: kick notes snap to a played kick within 0.075 beats; the rest keep the pocket.
                let nearest = kickBeats.min { abs($0 - cellNote.grid) < abs($1 - cellNote.grid) }
                if structural {
                    let snapped = nearest.flatMap { abs($0 - cellNote.grid) <= 0.075 ? $0 : nil }
                    beat = snapped ?? cellNote.grid
                    // Without a timing field a structural note is struck when it sits on a kick (or on the
                    // template's kick figure when there are no drums at all).
                    if snapped != nil || kickBeats.isEmpty, cellNote.stroke != .ghost { strike = bassStrike(role: cellNote.role) }
                } else {
                    beat = cellNote.grid + draws.pocket
                }
            }
            // Drawn length: the cell's own (its holds keep the figure's room), moved into the longer ranges.
            let drawn = cellNote.stroke == .hold ? cellNote.length + 0.5 : cellNote.length
            var note = Note(part: .bass, midi: midi, beat: max(0, beat), length: drawn,
                            velocity: cellNote.velocity, send: 0)
            note.stroke = cellNote.stroke
            note.strike = strike
            // The return's slam is struck whatever the take plays under it.
            if section == .returnTheme, cellNote.grid == 0, cellNote.stroke == .hold { note.strike = 1 }
            placed.append((note, cellNote.role))
            if let anchor { anchors.append(anchor) }
        }
        placed.sort { $0.note.beat < $1.note.beat }
        let endingKicks = timing.map { field -> [Double] in
            let fpb = field.framesPerBeat
            let start = Int((Double(timingStartBeat) * fpb).rounded())
            return field.landmarks.compactMap { mark in
                guard mark.kind == .kick, mark.confidence >= bassEndingKickConfidence,
                      (start..<(start + field.phraseFrames)).contains(mark.attackFrame) else { return nil }
                return Double(mark.attackFrame - start) / fpb
            }
        } ?? []
        var notes = fit(placed.map(\.note), roles: placed.map(\.role), anchors: anchors, voice: voice,
                        beatSeconds: beatSeconds, end: end, full: section != .breakdown && section != .answer,
                        endingKicks: endingKicks)
        anchors = anchors.filter { a in notes.contains { $0.beat == a.noteBeat } }

        // One slide per phrase at most, into a non-anchored walk or hold.
        if draws.slide > 0, section == .theme || section == .variation,
           let i = notes.indices.first(where: { i in
               (notes[i].stroke == .walk || notes[i].stroke == .hold) && notes[i].strike == 0
                   && !anchors.contains { $0.noteBeat == notes[i].beat }
           }) {
            notes[i].slide = draws.slide
        }

        // Throws (plan 2.4): the note before the breakdown's drop-out always, the last note of the phrases
        // at take positions 1 and 3 half the time. At most one per phrase.
        var throwRNG = MusicRNG(seed: seed).fork(UInt64(max(0, phrase)) &* 17 &+ 2_207)
        let chance = throwRNG.chance(0.5)
        if !notes.isEmpty, section == .breakdown || ((position == 1 || position == 3) && chance) {
            notes[notes.count - 1].send = bassThrowSend
        }
        return BassLine(notes: notes, anchors: anchors, sweep: sweep)
    }

    static func strokeLength(_ stroke: BassStroke, _ u: Double) -> Double {
        let range = strokeLengths(stroke)
        return range.lowerBound + (range.upperBound - range.lowerBound) * u
    }

    /// Drawn held length in beats per stroke (plan bass-tone-redo 4.2). A `hold` takes the cell's weight
    /// length (1 to 2 beats, kept so the figure is unchanged) plus half a beat.
    static func strokeLengths(_ stroke: BassStroke) -> ClosedRange<Double> {
        switch stroke {
        case .thump: 0.5...0.75
        case .walk: 0.75...1.0
        case .hold: 1.5...2.5
        case .ghost: 0.12...0.20
        }
    }

    /// Bars 1-2 on the grid: the downbeat root, the kicks the take keeps (always the one nearest the bar
    /// line), one weight note, one or two gap answers, sometimes a ghost before a main note, and the pickup.
    static func makeCell(draws: CellDraws, kickSlots: [Double], snares: [Double]) -> [CellNote] {
        func slot(_ beat: Double) -> Int { Int((beat * 4).rounded()) % 32 }
        func kickDegree(_ beat: Double) -> BassDegree {
            let u = draws.degree[slot(beat)]
            return u < 0.35 ? .root : (u < 0.75 ? .fifth : (u < 0.88 ? .flatSeven : .minorThird))
        }
        var cell: [CellNote] = [CellNote(grid: 0, degree: .root, role: .downbeat, stroke: .thump,
                                         length: strokeLength(.thump, draws.length[0]), velocity: 0.85)]
        let barLine = kickSlots.filter { $0 > 0 && abs($0 - 4) <= 0.5 }.min { abs($0 - 4) < abs($1 - 4) }
        for k in kickSlots where k > 0 && k < 7.5 {
            let isBarLine = k == barLine
            // A kick a sixteenth before the next one gives way to it: a thump needs its release clear.
            guard isBarLine || !kickSlots.contains(where: { $0 > k && $0 - k < 0.3 }) else { continue }
            guard isBarLine || draws.keep[slot(k)] < 0.75 else { continue }
            cell.append(CellNote(grid: k, degree: isBarLine ? .root : kickDegree(k), role: .kick, stroke: .thump,
                                 length: strokeLength(.thump, draws.length[slot(k)]), velocity: isBarLine ? 0.85 : 0.80))
        }
        // One weight note per two bars: a hold on the root or fifth, on the downbeat or the kick nearest 2.5.
        let nearHalf = kickSlots.filter { abs($0 - 2.5) <= 0.75 }.min { abs($0 - 2.5) < abs($1 - 2.5) }
        let weightBeat = draws.holdOnDownbeat ? 0 : (nearHalf ?? 0)
        let holdLength = min(draws.holdLength, max(1.0, (barLine ?? 4) - 0.4 - weightBeat))
        let holdEnd = weightBeat + holdLength
        cell.removeAll { $0.grid == weightBeat || ($0.grid > weightBeat && $0.grid < holdEnd + 0.2) }
        cell.append(CellNote(grid: weightBeat, degree: weightBeat > 0 && draws.holdOnFifth ? .fifth : .root,
                             role: weightBeat == 0 ? .downbeat : .weight, stroke: .hold, length: holdLength,
                             velocity: 0.82))
        // Gap answers behind the beat, at least a quarter beat from any kick or snare.
        func clear(_ beat: Double) -> Bool {
            !(kickSlots + snares).contains { abs($0 - beat) < bassGapClearance - 1e-9 }
                && !cell.contains { abs($0.grid - beat) < 0.5 }
                && !(beat > weightBeat && beat < holdEnd + 0.2)
        }
        var placed = 0
        for beat in draws.answerOrder where placed < draws.answers && beat < draws.pickup - 0.5 && clear(beat) {
            cell.append(CellNote(grid: beat, degree: [.fifth, .flatSeven, .fifth, .minorThird][slot(beat) % 4],
                                 role: .answer, stroke: .thump, length: strokeLength(.thump, draws.length[slot(beat)]),
                                 velocity: 0.70))
            placed += 1
        }
        // A ghost a quarter beat before a main note, sometimes, when that spot is clear.
        if draws.ghostChance < 0.45 {
            let mains = cell.filter { $0.role == .kick }.map(\.grid).sorted()
            if let main = mains.first(where: { m in
                let g = m - 0.25
                return g > 0.5 && !cell.contains { abs($0.grid - g) < 0.24 } && !(g > weightBeat && g < holdEnd + 0.2)
                    && !snares.contains { abs($0 - g) < bassGapClearance - 1e-9 }
            }) {
                cell.append(CellNote(grid: main - 0.25, degree: .root, role: .ghost, stroke: .ghost,
                                     length: strokeLength(.ghost, draws.length[slot(main - 0.25)]),
                                     velocity: draws.ghostVelocity))
            }
        }
        // Pickup into bar 3: fifth, octave or an approach tone a step below the root, on a kick played
        // near it when there is one.
        let pickup = kickSlots.filter { $0 <= draws.pickup && draws.pickup - $0 <= 0.25 }.max() ?? draws.pickup
        cell.removeAll { $0.role != .downbeat && $0.role != .weight && abs($0.grid - pickup) < 0.24 }
        if !cell.contains(where: { abs($0.grid - pickup) < 0.24 }) {
            cell.append(CellNote(grid: pickup, degree: draws.pickupDegree, role: .pickup, stroke: .thump,
                                 length: strokeLength(.thump, draws.length[slot(draws.pickup)]), velocity: 0.68))
        }
        cell = balance(cell, bars: [0, 1], range: 3...5, kickSlots: kickSlots, snares: snares, draws: draws)
        return cell.sorted { $0.grid < $1.grid }
    }

    /// `range` notes per bar: a crowded bar drops ghosts, answers, then off-bar kicks; a sparse one takes
    /// the kicks the draws left out, then answer spots clear of kicks and snares, never under a hold.
    static func balance(_ input: [CellNote], bars: [Int], range: ClosedRange<Int>, kickSlots: [Double],
                        snares: [Double], draws: CellDraws) -> [CellNote] {
        var notes = input
        func rank(_ n: CellNote) -> Int {
            switch n.role {
            case .ghost: 0
            case .answer: 1
            case .kick: abs(n.grid - (n.grid / 4).rounded() * 4) <= 0.5 ? 9 : 2
            case .pickup: 8
            case .weight, .downbeat: 10
            }
        }
        func slot(_ beat: Double) -> Int { Int((beat * 4).rounded()) % 32 }
        for bar in bars {
            let lo = Double(bar * 4), hi = lo + 4
            func members() -> [Int] { notes.indices.filter { notes[$0].grid >= lo && notes[$0].grid < hi } }
            while members().count > range.upperBound, let drop = members().min(by: { rank(notes[$0]) < rank(notes[$1]) }) {
                notes.remove(at: drop)
            }
            func free(_ beat: Double) -> Bool {
                beat >= lo && beat < hi - 0.3 && !notes.contains { abs($0.grid - beat) < 0.35 }
                    && !notes.contains { $0.stroke == .hold && beat > $0.grid && beat < $0.grid + $0.length + 0.2 }
            }
            let spare = kickSlots.filter { $0 > lo && free($0) }
            let spots = [1.5, 2.75, 3.5, 3.25, 0.75, 2.25].map { $0 + lo }.filter { spot in
                !(kickSlots + snares).contains { abs($0 - spot) < bassGapClearance - 1e-9 }
            }
            for beat in spare + spots where members().count < range.lowerBound && free(beat) {
                let isKick = spare.contains(beat)
                let u = draws.degree[slot(beat)]
                let degree: BassDegree = isKick ? (u < 0.35 ? .root : (u < 0.75 ? .fifth : .flatSeven)) : .fifth
                notes.append(CellNote(grid: beat, degree: degree, role: isKick ? .kick : .answer, stroke: .thump,
                                      length: strokeLength(.thump, draws.length[slot(beat)]), velocity: isKick ? 0.80 : 0.70))
            }
        }
        return notes.sorted { $0.grid < $1.grid }
    }

    /// Bar 4 of the repeat: the bar-2 answers move to an unused answer spot and the pickup sits on 15.5
    /// (an octave leap in a variation).
    static func changeBarFour(_ bars: [CellNote], draws: CellDraws, kickSlots: [Double], snares: [Double],
                              octave: Bool, pitch: (BassDegree) -> Int) -> [CellNote] {
        var out = bars.filter { !($0.grid >= 12 && ($0.role == .answer || $0.role == .pickup || $0.role == .ghost)) }
        let used = Set(bars.filter { $0.role == .answer }.map { $0.grid - 8 })
        let alternatives = draws.answerOrder.filter { $0 >= 4 && $0 < 7.5 && !used.contains($0) }.map { $0 + 8 }
        if let beat = alternatives.first(where: { b in
            !(kickSlots + snares).contains { abs($0 - b) < bassGapClearance - 1e-9 }
                && !out.contains { abs($0.grid - b) < 0.5 || ($0.stroke == .hold && b > $0.grid && b < $0.grid + $0.length + 0.2) }
        }) {
            out.append(CellNote(grid: beat, degree: .flatSeven, role: .answer, stroke: .thump,
                                length: strokeLength(.thump, draws.length[Int(beat * 4) % 32]), velocity: 0.70))
        }
        // The bar-4 pickup lands on another pitch than the cell's (an octave leap in a variation).
        let cellPitch = pitch(draws.pickupDegree)
        let choices: [BassDegree] = (octave ? [.octave] : []) + [.fifth, .flatSeven, .approach, .root, .octave]
        let degree = choices.first { pitch($0) != cellPitch } ?? .root
        let beat = kickSlots.filter { $0 <= 15.5 && 15.5 - $0 <= 0.25 }.max() ?? 15.5
        if !out.contains(where: { abs($0.grid - beat) < 0.24 }) {
            out.append(CellNote(grid: beat, degree: degree, role: .pickup, stroke: .thump,
                                length: strokeLength(.thump, draws.length[30]), velocity: 0.70))
        } else if let i = out.firstIndex(where: { abs($0.grid - beat) < 0.24 && $0.role != .pickup }) {
            out[i].degree = out[i].degree == .root ? .fifth : .root
        }
        return out.sorted { $0.grid < $1.grid }
    }

    /// The return's slam: beat 0 is a `hold` at velocity 0.90; notes under it give way.
    static func slam(_ grid: [(note: CellNote, root: Int)], home: Int) -> [(note: CellNote, root: Int)] {
        let length = 1.5
        var out = grid.filter { $0.note.grid >= length + 0.25 }.map { entry -> (note: CellNote, root: Int) in
            // One weight per bar: a hold later in the slammed bar becomes a thump.
            guard entry.note.grid < 4, entry.note.stroke == .hold else { return entry }
            var n = entry.note
            n.stroke = .thump
            n.length = 0.25
            n.role = .kick
            return (n, entry.root)
        }
        out.insert((CellNote(grid: 0, degree: .root, role: .downbeat, stroke: .hold, length: length, velocity: 0.90), home),
                   at: 0)
        return out
    }

    /// Keeps at most `perBar` notes per bar: the downbeat and bar-line kicks first, then the weight, other
    /// kicks, pickups, answers and ghosts.
    static func thin(_ notes: [CellNote], perBar: Int) -> [CellNote] {
        func rank(_ n: CellNote) -> Int {
            switch n.role {
            case .downbeat: 0
            case .weight: 2
            case .kick: n.grid.truncatingRemainder(dividingBy: 4) == 0 ? 1 : 3
            case .pickup: 4
            case .answer: 5
            case .ghost: 6
            }
        }
        var out: [CellNote] = []
        for bar in 0..<4 {
            out += notes.filter { Int($0.grid / 4) == bar }.sorted { rank($0) < rank($1) }.prefix(perBar)
        }
        return out.sorted { $0.grid < $1.grid }
    }

    /// MIDI for a degree over `root`, from the phrase's scale. Structural tones stay in 28...41; the octave
    /// may reach 53.
    static func pitch(_ degree: BassDegree, root: Int, scale: [Int]) -> Int {
        func near(_ target: Int, _ low: Int, _ high: Int) -> Int? {
            guard low <= high else { return nil }
            return scale.filter { (low...high).contains($0) }.min { abs($0 - target) < abs($1 - target) }
        }
        switch degree {
        case .root:
            return root
        case .fifth:
            return near(root + 7, root + 5, min(41, root + 8)) ?? near(root - 5, max(28, root - 7), root - 4) ?? root
        case .octave:
            return root + 12 <= 53 ? root + 12 : root
        case .flatSeven:
            return near(root - 2, max(28, root - 3), root - 1) ?? near(root + 10, root + 9, min(41, root + 11)) ?? root
        case .minorThird:
            return near(root + 3, root + 3, min(41, root + 4)) ?? near(root - 9, max(28, root - 9), root - 8) ?? root
        case .approach:
            return near(root - 1, max(28, root - 2), root - 1) ?? pitch(.fifth, root: root, scale: scale)
        }
    }

    /// Joins and lengths (plan bass-tone-redo 4.2, 4.3). Into a struck or anchored note the predecessor
    /// takes the short release and is silent `bassAccentClearance` before it (a clean re-pluck the C-B2
    /// measure can time); into any other note its release cross-fades over up to `bassLegatoOverlap`.
    /// Struck and anchored notes and holds then sustain to the next onset (capped), unanchored answers,
    /// pickups and kick notes keep their drawn length, ghosts stay short, and the note before a pickup keeps
    /// one breath per cell. Everything ends by `end`; the sounding length per bar and per phrase keeps to
    /// the limits.
    static func fit(_ input: [Note], roles inputRoles: [BassRole], anchors: [BassAnchor], voice: LofiBassVoice,
                    beatSeconds: Double, end: Double, full: Bool, endingKicks: [Double] = []) -> [Note] {
        var notes = input
        var roles = inputRoles
        func crisp(_ i: Int) -> Bool {
            i < notes.count && (notes[i].strike > 0 || anchors.contains { $0.noteBeat == notes[i].beat })
        }
        func release(_ i: Int) -> Double { voice.release(notes[i].stroke, beforeStrike: crisp(i + 1)) / beatSeconds }
        func room(_ i: Int) -> Double {
            guard i + 1 < notes.count else { return end - notes[i].beat - release(i) }
            let gap = notes[i + 1].beat - notes[i].beat
            if crisp(i + 1) { return gap - release(i) - bassAccentClearance / beatSeconds }
            return gap - max(0, release(i) - bassLegatoOverlap / beatSeconds)
        }
        var i = 0
        while i < notes.count {
            let r = room(i)
            if r < 0.06 {
                notes.remove(at: i)
                roles.remove(at: i)
                if i > 0 { i -= 1 }
                continue
            }
            if notes[i].length > r { notes[i] = notes[i].with(length: r) }
            i += 1
        }
        // Sustain: struck and anchored notes and holds ring to the next onset; one breath per cell.
        var breathing = Set<Int>()
        i = 0
        while i < notes.count {
            let isHold = notes[i].stroke == .hold
            if notes[i].stroke != .ghost, isHold || crisp(i) {
                let rest = i + 1 < notes.count ? notes[i + 1].beat - notes[i].beat - notes[i].length - release(i) : 0
                if i + 1 < notes.count, roles[i + 1] == .pickup, rest >= bassBreathRest {
                    breathing.insert(i)
                } else {
                    let cap = isHold ? bassHoldCap : bassSustainCap
                    notes[i] = notes[i].with(length: max(notes[i].length, min(room(i), cap)))
                }
            }
            i += 1
        }
        // Sounding length per bar.
        for bar in 0..<4 {
            var members = notes.indices.filter { bassBar(notes[$0].beat) == bar }
            members.sort { notes[$0].length > notes[$1].length }
            var total = members.reduce(0) { $0 + notes[$1].length }
            for m in members where total > bassBarSoundingLimit {
                let floor = strokeLengths(notes[m].stroke).lowerBound
                let cut = min(total - bassBarSoundingLimit, max(0, notes[m].length - floor))
                notes[m] = notes[m].with(length: notes[m].length - cut)
                total -= cut
            }
        }
        // Sounding length per phrase, for the full sections.
        if full {
            var total = notes.reduce(0) { $0 + $1.length }
            for m in notes.indices.sorted(by: { notes[$0].length > notes[$1].length }) where total < bassPhraseSounding.lowerBound {
                guard notes[m].stroke != .ghost, !breathing.contains(m) else { continue }
                let bar = bassBar(notes[m].beat)
                let barTotal = notes.filter { bassBar($0.beat) == bar }.reduce(0) { $0 + $1.length }
                let cap = notes[m].stroke == .hold ? bassHoldCap : bassSustainCap
                let add = min(bassPhraseSounding.lowerBound - total, max(0, min(cap, room(m)) - notes[m].length),
                              max(0, bassBarSoundingLimit - barTotal))
                notes[m] = notes[m].with(length: notes[m].length + add)
                total += add
            }
            for m in notes.indices.sorted(by: { notes[$0].length > notes[$1].length }) where total > bassPhraseSounding.upperBound {
                let floor = strokeLengths(notes[m].stroke).lowerBound
                let cut = min(total - bassPhraseSounding.upperBound, max(0, notes[m].length - floor))
                notes[m] = notes[m].with(length: notes[m].length - cut)
                total -= cut
            }
        }
        // A sustained note never fades out under a kick it is not anchored to.
        // Last, so no later pass stretches a note back over the kick.
        let clearance = bassAccentClearance / beatSeconds
        i = 0
        while i < notes.count {
            let note = notes[i]
            let sounding = note.beat + note.length + release(i)
            // Kicks a note is anchored to (this one's or its successor's) are where the bass and kick hit together.
            let own = anchors.filter { anchor in notes.contains { $0.beat == anchor.noteBeat } }.map(\.kickBeat)
            if let kick = endingKicks.filter({ k in k > note.beat + bassKickSafety && k < sounding + clearance
                                                && k > note.beat + note.length - bassEndingKickWindow
                                                && !own.contains { abs($0 - k) < 1e-6 } }).min() {
                let length = kick - note.beat - release(i) - clearance
                if length >= bassShortestLength, length < note.length { notes[i] = note.with(length: length) }
            }
            i += 1
        }
        return notes
    }

    /// Where a kick's C-B2 rise (the -6 dB point of its 40-160 Hz Hilbert envelope) sits between its
    /// broadband attack and its 2 ms-power low-band rise (`lowRiseFrame`). Measured on the 25 installed
    /// AJ Hall takes (20 November 2026): median 0.48 on the 72 BPM take (11.6 ms after the attack, p10 to
    /// p90 10.7 to 12.2 ms over 70 kicks); over all takes the error of 0.47 has median 0.5 ms, p10 -7 ms,
    /// p90 +24 ms (slow kicks whose body swells late). The mix rebalance (D118) set 0.40: at 0.47 the three
    /// 70 BPM matrix cases (seed 1042) read the bass 4.7 to 5.0 ms late (signed median; C-B2 allows 5 ms
    /// and the `same` case failed at 5.19), and seed 2077 at 72 BPM read +1.3 ms; at 0.40 it reads 0.42 ms.
    static let bassKickRiseShare = 0.40

    /// Phrase-local beats of the attack and the C-B2 rise target of each confident kick in the phrase,
    /// with the frame arithmetic of `LofiTimingField.kicks`.
    static func kickRises(_ timing: LofiTimingField, phraseStartBeat: Int) -> [(attack: Double, lowRise: Double)] {
        let fpb = timing.framesPerBeat
        guard fpb > 0 else { return [] }
        let start = Int((Double(phraseStartBeat) * fpb).rounded())
        let end = start + timing.phraseFrames
        return timing.landmarks.compactMap { landmark in
            guard landmark.kind == .kick, landmark.confidence >= bassAccentConfidence,
                  (start..<end).contains(landmark.attackFrame) else { return nil }
            let attack = Double(landmark.attackFrame - start) / fpb
            let lowRise = Double(max(landmark.attackFrame, landmark.lowRiseFrame) - start) / fpb
            return (attack, attack + bassKickRiseShare * (lowRise - attack))
        }
    }
}

nonisolated extension LofiScore.Note {
    /// The same note with another held length.
    func with(length: Double) -> Self {
        var copy = self
        copy = Self(part: part, midi: midi, beat: beat, length: length, velocity: velocity, color: color, send: send,
                    gain: gain, articulation: articulation, stroke: stroke, slide: slide, strike: strike)
        return copy
    }
}

nonisolated extension LofiScore {
    /// Whether the bass note after `note` is struck or anchored: `note` then takes the short release.
    func bassBeforeStrike(_ note: Note) -> Bool {
        let bass = notes.filter { $0.part == .bass }
        guard let i = bass.firstIndex(of: note), i + 1 < bass.count else { return false }
        let next = bass[i + 1]
        return next.strike > 0 || bassAnchors.contains { $0.noteBeat == next.beat }
    }

    /// Frames from an anchored note's start to its strike: the strike layer peaks about 1 ms after it
    /// starts, so it starts that much before the kick's broadband attack (the sub's rise sits on the kick's
    /// later low rise). At most `bassStrikeAdvance` either way; 0 for a note without an anchor.
    func bassStrikeShift(_ note: Note, clock: LofiClock) -> Int {
        guard note.strike > 0, let anchor = bassAnchors.first(where: { $0.noteBeat == note.beat }) else { return 0 }
        let seconds = (anchor.kickBeat - note.beat) * clock.beatDuration - LofiBassVoice.strikePeakTime
        let limit = LofiScore.bassStrikeAdvance
        return Int((min(limit, max(-limit, seconds)) * clock.sampleRate).rounded())
    }

    /// Seconds of release the phrase's voice gives `note`.
    func bassRelease(_ note: Note) -> Double {
        bassVoice.release(note.stroke, beforeStrike: bassBeforeStrike(note))
    }
}
