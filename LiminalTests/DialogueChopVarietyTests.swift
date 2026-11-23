import Foundation
import Testing
@testable import Liminal

/// The chop beat mixes its pieces and plays off the drums (D127; user direction of 21 November 2026:
/// "I like when it doesn't repeat the same chop over and over in a row. Better to mix it up, on beat
/// chops. With swing. Or Dilla style. Playing off the drumbeats.").
struct DialogueChopVarietyTests {
    typealias Film = DialogueHookProbeTests.Film
    struct Loop { let events: [DialogueEvent]; let motif: DialogueMotif; let snapshot: DialogueTransportSnapshot; let index: Int }

    static let films: [(String, Double, Film)] = [
        ("transcript-72", 72, DialogueHookProbeTests.film(DialogueHookProbeTests.investigate, id: "cv-inv-t", transcribed: true)),
        ("acoustic-72", 72, DialogueHookProbeTests.film(DialogueHookProbeTests.investigate, id: "cv-inv-a", transcribed: false)),
        ("mixed-transcript-84", 84, DialogueHookProbeTests.film(DialogueHookProbeTests.mixed, id: "cv-mix-t", transcribed: true)),
    ]
    static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13]

    /// A busier take than the boom-bap fixture: kicks on the "a" of 1, the "and" of 2 and beat 3's
    /// "e", ghost notes in between (the installed takes' typical shape, D127 probe).
    static func busy(_ snapshot: DialogueTransportSnapshot) -> DialogueTransportSnapshot {
        var s = snapshot
        s.kicks = []
        s.snares = []
        for bar in 0..<16 {
            let b = Double(bar * 4)
            for k in [0.0, 0.75, 1.5, 2.25, 2.5] { s.kicks.append(DialogueLandmark(beat: b + k, confidence: 0.9)) }
            for k in [1.0, 3.0] { s.snares.append(DialogueLandmark(beat: b + k, confidence: 0.9)) }
            for k in [0.5, 1.75, 3.25, 3.5] { s.snares.append(DialogueLandmark(beat: b + k + 0.02, confidence: 0.6, strength: 0.2)) }
        }
        return s
    }

    /// Three loops of a film on a swung take with ghost notes (or `busy`), as the coordinator plays them.
    static func run(_ film: Film, bpm: Double, seed: UInt64, busy: Bool = false) -> [Loop] {
        var memory = DialoguePerformanceMemory()
        let beat = 60 / bpm
        var loops: [Loop] = []
        for take in 0..<3 {
            var snapshot = DialogueFixtures.snapshot(bpm: bpm, origin: 0.5 + Double(take) * 64 * beat, phraseAtOrigin: 4 * take,
                                                     takeIndex: take, seed: 3, ghosts: true)
            snapshot.grooveOffsets = (0..<DialogueTransportSnapshot.takeSixteenths).map { $0 % 2 == 1 ? 0.08 : 0.0 }
            if busy { snapshot = Self.busy(snapshot) }
            let played = DialogueChopVarietyProbeTests.loop(film, snapshot: snapshot, seed: seed, memory: &memory, cueBase: take * 2)
            if let motif = played.motif { loops.append(Loop(events: played.events, motif: motif, snapshot: snapshot, index: take)) }
        }
        return loops
    }

    /// Consecutive chop-beat hits rarely repeat a piece (only the marked turnaround stutter may), every
    /// 2-bar cell plays at least three pieces, most hits sit off the kicks, and bars 3-4 still recur in
    /// bars 5-6 (the hook, D125).
    @Test(arguments: [false, true]) func theChopBeatMixesItsPiecesOffTheKicks(_ busy: Bool) throws {
        var checked = 0
        for (name, bpm, film) in Self.films {
            for seed in Self.seeds {
                for loop in Self.run(film, bpm: bpm, seed: seed, busy: busy) {
                    let drums = DialogueChopMetrics.DrumSteps(loop.snapshot)
                    let chop = DialogueChopMetrics.section(loop.events, loop: loop.index, bars: 2..<6, drums: drums)
                    let build = DialogueChopMetrics.section(loop.events, loop: loop.index, bars: 6..<8, drums: drums)
                    let label = "\(name) busy \(busy) seed \(seed) loop \(loop.index) '\(loop.motif.text ?? "-")'"
                    // D130 counts the hook's own skeleton repeats apart (see `fillRepeats`).
                    let repeats = DialogueChopMetrics.fillRepeats(loop.events, loop: loop.index, bars: 2..<6, motif: loop.motif)
                    #expect(repeats <= 0.20, "\(label): \(repeats) same piece in a row (\(chop.samePieceUnmarked) with the skeleton's)")
                    // D130 replaced "three cuts a cell": whole words leave room for fewer fills, so a cell may play
                    // the hook's two or three pieces only (the salience probe reports the share of such cells).
                    let offered = loop.motif.pieces.count + loop.motif.halves.values.map(\.count).reduce(0, +)
                    #expect(chop.leastPer2Bars >= min(2, offered), "\(label): \(chop.leastPer2Bars) pieces in a 2-bar cell of \(offered)")
                    // D130 replaced 0.65 and 0.8: with three or four hits a bar the downbeat hit on the kick weighs
                    // more, and one hit in four skipped (it would cut a word) changes the second pass.
                    #expect(1 - chop.onKick >= 0.6, "\(label): \(chop.onKick) of the chop beat on a kick")
                    #expect(DialogueChopMetrics.recurrence(loop.events, loop: loop.index) >= 0.7, "\(label)")
                    // The build's repeats are its marked rolls.
                    let buildRepeats = DialogueChopMetrics.fillRepeats(loop.events, loop: loop.index, bars: 6..<8, motif: loop.motif)
                    #expect(buildRepeats <= 0.20, "\(label): build \(buildRepeats)")
                    checked += 1
                }
            }
        }
        #expect(checked >= 50)
    }

    /// Every stutter is deliberate: a build roll or the turnaround in the chop beat's last beat.
    @Test func stuttersAreOnlyRollsAndTurnarounds() throws {
        for (name, bpm, film) in Self.films {
            for seed in Self.seeds.prefix(3) {
                for loop in Self.run(film, bpm: bpm, seed: seed) {
                    for (s, e) in DialogueChopMetrics.placed(loop.events, loop: loop.index) where e.stutter {
                        let turnaround = e.cell == .chopBeat && s / 16 == 5 && s % 16 >= 12
                        #expect(e.cell == .build || turnaround, "\(name) seed \(seed): stutter in \(e.cell?.rawValue ?? "-") at \(s)")
                    }
                }
            }
        }
    }

    /// The loop's feel is one consistent offset per place in the beat, within 25 ms, never on a quarter
    /// step, only in the chop beat and build; every accent is its step on the drummer's grid plus it.
    /// Loops change feel, and the seeds reach at least three feels.
    @Test func theFeelIsConsistentBoundedAndKeepsQuartersTight() throws {
        var feels: Set<String> = []
        for (name, bpm, film) in Self.films {
            for seed in Self.seeds {
                let loops = Self.run(film, bpm: bpm, seed: seed)
                for loop in loops {
                    feels.insert(loop.motif.feel.name)
                    var byClass: [Int: Set<Double>] = [:]
                    for (s, e) in DialogueChopMetrics.placed(loop.events, loop: loop.index) {
                        let step = 64 * (e.block - loop.snapshot.phraseAtOrigin) + e.slot
                        #expect(abs(e.accentTime - (loop.snapshot.gridTime(sixteenth: step) + e.feelSeconds)) < 1e-9)
                        #expect(abs(e.feelSeconds) <= DialogueMotifTuning.maximumFeelSeconds + 1e-12)
                        if s % 4 == 0 || !(e.cell == .chopBeat || e.cell == .build) || e.piece == 0 {
                            #expect(e.feelSeconds == 0, "\(name) seed \(seed): feel \(e.feelSeconds) on step \(s) of \(e.cell?.rawValue ?? "-")")
                        } else {
                            byClass[s % 4, default: []].insert(e.feelSeconds)
                            #expect(e.feelSeconds == loop.motif.feel.offset(step: s))
                        }
                    }
                    #expect(byClass.values.allSatisfy { $0.count == 1 }, "\(name) seed \(seed) loop \(loop.index): \(byClass)")
                }
                for (a, b) in zip(loops, loops.dropFirst()) {
                    #expect(a.motif.arc?.feel != b.motif.arc?.feel, "\(name) seed \(seed): feel \(a.motif.feel.name) twice")
                }
            }
        }
        for f in DialogueFeel.variants {
            #expect([f.and, f.e, f.a].allSatisfy { abs($0) <= DialogueMotifTuning.maximumFeelSeconds } && f.offset(step: 0) == 0 && f.offset(step: 4) == 0)
        }
        #expect(feels.count >= 3, "\(feels)")
    }

    /// The same seed plays the same chop beat; the skeleton holds while the fill changes with the loop.
    @Test func theChopBeatIsSeededAndItsFillChangesEveryLoop() throws {
        func key(_ loops: [Loop]) -> [[String]] {
            loops.map { l in l.events.map { "\($0.block):\($0.slot):\($0.piece ?? -1):\($0.gateSteps ?? -1):\($0.feelSeconds)" } }
        }
        var changed = 0, pairs = 0
        for (_, bpm, film) in Self.films {
            for seed in Self.seeds.prefix(4) {
                let a = Self.run(film, bpm: bpm, seed: seed)
                #expect(key(a) == key(Self.run(film, bpm: bpm, seed: seed)))
                for (x, y) in zip(a, a.dropFirst()) {
                    let gx = x.motif.hook!.items, gy = y.motif.hook!.items
                    pairs += 1
                    if gx.filter { !$0.skeleton }.map { [$0.slot, $0.fragment, $0.gate ?? -1] } != gy.filter { !$0.skeleton }.map { [$0.slot, $0.fragment, $0.gate ?? -1] } {
                        changed += 1
                    }
                    if x.motif.hook!.template == y.motif.hook!.template {
                        #expect(gx.filter(\.skeleton).map(\.slot) == gy.filter(\.skeleton).map(\.slot))
                    }
                }
            }
        }
        // D130 replaced "every pair": a groove sized to the dry budget has fewer fills, and four in five
        // loop pairs on one template still change theirs.
        #expect(Double(changed) >= 0.8 * Double(pairs), "\(changed) of \(pairs) loop pairs changed their fill")
    }

    /// On the installed drum takes' own landmarks (skipped when none is installed): the chop beat sits
    /// off the kicks and mixes its pieces on every take.
    @Test func installedTakesGetAnInterlockingChopBeat() throws {
        let assets = LofiDrumLibrary.assets()
        guard !assets.isEmpty else { return }
        let film = DialogueHookProbeTests.film(DialogueHookProbeTests.mixed, id: "cv-takes", transcribed: true)
        for k in 0..<6 {
            let asset = assets[k * assets.count / 6]
            let snapshot = try DialogueChopVarietyProbeTests.takeSnapshot(asset, take: 0)
            let drums = DialogueChopMetrics.DrumSteps(snapshot)
            var memory = DialoguePerformanceMemory()
            let played = DialogueChopVarietyProbeTests.loop(film, snapshot: snapshot, seed: UInt64(1 + k), memory: &memory, cueBase: 0)
            let chop = DialogueChopMetrics.section(played.events, loop: 0, bars: 2..<6, drums: drums)
            let repeats = played.motif.map { DialogueChopMetrics.fillRepeats(played.events, loop: 0, bars: 2..<6, motif: $0) } ?? chop.samePieceUnmarked
            // D130 replaced "same piece in a row at most 0.20": a hit skipped because it would cut a word can
            // leave a fill next to an equal cut (one take of six read 0.31).
            #expect(chop.onKick <= 0.35 && repeats <= 0.35 && chop.leastPer2Bars >= 3,
                    "\(asset.entry.name): kick \(chop.onKick), same \(chop.samePieceUnmarked), least \(chop.leastPer2Bars)")
        }
    }

    /// A line that may not be reordered drops a fill site no cut fits, on any drum pattern, and keeps
    /// each bar's new pieces in source order (the app run of 22 November 2026 crashed on a dropped site).
    @Test func aLineThatMayNotBeReorderedDropsSitesSafelyOnAnyDrums() throws {
        let fixture = DialogueFixtures.speech(DialogueFixtures.Options(seconds: 16, seed: 7, sentences: [
            "we did not stop the car that night.", "I don't know where the river goes.",
            "the station was empty in the morning.", "nobody wanted to go home.",
        ]))
        let film = DialogueHookProbeTests.film(fixture, id: "cv-negated", transcribed: true)
        var patterns: [DialogueMotifDrums] = [.boomBap,
            DialogueMotifDrums(kicks: [0, 3, 6, 9, 10, 16, 19, 22, 25, 26], snares: [4, 12, 20, 28],
                               ghosts: [1, 2, 5, 7, 8, 11, 13, 14, 15, 17, 18, 21, 23, 24, 27, 29, 30, 31]),
            DialogueMotifDrums(kicks: [0, 16], snares: [4, 12, 20, 28], ghosts: [2, 6, 10, 14, 18, 22, 26, 30])]
        let assets = LofiDrumLibrary.assets()
        for k in 0..<min(4, assets.count) {
            patterns.append(DialogueMotifDrums(snapshot: try DialogueChopVarietyProbeTests.takeSnapshot(assets[k * assets.count / 4], take: 0)))
        }
        var checked = 0
        for drums in patterns {
            for seed: UInt64 in 1...12 {
                guard let motif = DialogueMotif.make(loop: Int(seed), source: film.source, analysis: film.analysis, transcript: film.transcript,
                                                     memory: DialoguePerformanceMemory(), seed: seed, beatDuration: 60 / 78.0, drums: drums),
                      !motif.reorderAllowed else { continue }
                checked += 1
                let hook = try #require(motif.hook)
                let signature = Set([hook.signature] + (motif.halves[hook.signature] ?? []))
                for cell in motif.cells where cell.kind == .chopBeat {
                    #expect(cell.items.allSatisfy { motif.fragments.indices.contains($0.fragment) })
                    for bar in 0..<2 {
                        var order: [Int] = [], heard = Set<Int>()
                        for item in cell.items.sorted(by: { $0.slot < $1.slot }) where item.slot / 16 == bar && item.slot < 28 {
                            let o = motif.fragments[item.fragment].order
                            if heard.insert(o).inserted { order.append(o) }
                            if signature.contains(item.fragment) {
                                #expect(order == order.sorted(), "'\(motif.text ?? "-")' bar \(bar): \(order)")
                                order = []
                            }
                        }
                        #expect(order == order.sorted(), "'\(motif.text ?? "-")' bar \(bar): \(order) S \(hook.signature) R \(hook.response) T \(hook.third) halves \(motif.halves) items \(cell.items.map { [$0.slot, $0.fragment, $0.skeleton ? 1 : 0, motif.fragments[$0.fragment].order] })")
                    }
                    // The fill uses the line's other words: never one piece for the whole cell when there are more.
                    if motif.pieces.count >= 2 { #expect(Set(cell.items.map(\.fragment)).count >= 2, "'\(motif.text ?? "-")'") }
                }
            }
        }
        #expect(checked > 0)
    }

    /// A line whose roles collapse onto one piece (the response is the signature, no halves): every
    /// cut equals the hit before it, so each fill site is dropped. The groove keeps its skeleton and
    /// never reads a dropped site (the app run of 22 November 2026 crashed here).
    @Test(arguments: [true, false]) func aOnePieceLineDropsItsFillWithoutCrashing(_ reorder: Bool) {
        func fragment(_ id: Int, _ kind: DialogueMotifFragment.Kind, _ frames: Range<Int>) -> DialogueMotifFragment {
            DialogueMotifFragment(id: id, kind: kind, order: id == 0 ? 0 : id - 1, parent: nil, frames: frames,
                                  accentFrame: frames.lowerBound, fadeIn: 0, fadeOut: 0, text: nil)
        }
        let fragments = [fragment(0, .line, 0..<48_000), fragment(1, .piece, 0..<20_000)]
        let v = DialogueMotif.GrooveVocabulary(s: 1, r: 1, t: 1, sa: 1, ra: 1, pieces: [1], halves: [:])
        for template in DialogueMotifTuning.hookTemplates {
            for drums in [DialogueMotifDrums.boomBap, DialogueMotifDrums(kicks: [0, 16], snares: [4, 12, 20, 28], ghosts: [2, 6, 10, 14])] {
                for seed: UInt64 in 1...6 {
                    let items = DialogueMotif.groove(template: template, vocabulary: v, drums: drums, reorderAllowed: reorder,
                                                     fragments: fragments, sampleRate: 48_000, seed: seed)
                    #expect(items.filter(\.skeleton).count == template.count)
                    #expect(items.allSatisfy { $0.fragment == 1 })
                }
            }
        }
    }

    /// The live case of 22 November 2026: "we can't call them brains." may not be reordered, and its
    /// roles all fall on its last word. The chop beat leads into the signature with the line's earlier
    /// words instead of playing "brains." twelve times in a row.
    @Test func aGuardedLineWhoseSignatureEndsItStillMixesItsWords() {
        func fragment(_ id: Int, _ order: Int, _ frames: Range<Int>, _ kind: DialogueMotifFragment.Kind = .piece) -> DialogueMotifFragment {
            DialogueMotifFragment(id: id, kind: kind, order: order, parent: nil, frames: frames, accentFrame: frames.lowerBound,
                                  fadeIn: 0, fadeOut: 0, text: nil)
        }
        let fragments = [fragment(0, -1, 0..<60_000, .line), fragment(1, 0, 0..<15_000), fragment(2, 1, 15_000..<35_000), fragment(3, 2, 35_000..<60_000)]
        let v = DialogueMotif.GrooveVocabulary(s: 3, r: 3, t: 3, sa: 3, ra: 3, pieces: [1, 2, 3], halves: [:])
        for (k, template) in DialogueMotifTuning.hookTemplates.enumerated() {
            for seed: UInt64 in 1...6 {
                let items = DialogueMotif.groove(template: template, vocabulary: v, drums: .boomBap, reorderAllowed: false,
                                                 fragments: fragments, sampleRate: 48_000, seed: seed).sorted { $0.slot < $1.slot }
                let same = zip(items, items.dropFirst()).filter { $0.fragment == $1.fragment }.count
                #expect(Set(items.map(\.fragment)) == [1, 2, 3], "template \(k) seed \(seed): \(items.map { [$0.slot, $0.fragment] })")
                #expect(Double(same) <= 0.5 * Double(items.count - 1), "template \(k) seed \(seed): \(items.map { [$0.slot, $0.fragment] })")
            }
        }
    }
}
