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
                    #expect(chop.samePieceUnmarked <= 0.20, "\(label): \(chop.samePieceUnmarked) same piece in a row")
                    #expect(chop.leastPer2Bars >= 3, "\(label): \(chop.leastPer2Bars) pieces in a 2-bar cell")
                    #expect(1 - chop.onKick >= 0.65, "\(label): \(chop.onKick) of the chop beat on a kick")
                    #expect(DialogueChopMetrics.recurrence(loop.events, loop: loop.index) >= 0.8, "\(label)")
                    // The build's repeats are its marked rolls.
                    #expect(build.samePieceUnmarked <= 0.20, "\(label): build \(build.samePieceUnmarked)")
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
        #expect(changed == pairs, "\(changed) of \(pairs) loop pairs changed their fill")
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
            #expect(chop.onKick <= 0.35 && chop.samePieceUnmarked <= 0.20 && chop.leastPer2Bars >= 3,
                    "\(asset.entry.name): kick \(chop.onKick), same \(chop.samePieceUnmarked), least \(chop.leastPer2Bars)")
        }
    }
}
