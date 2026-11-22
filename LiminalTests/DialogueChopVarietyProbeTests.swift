import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Chop-beat probe (D127): per-loop grids under the drums and the variety and interplay metrics of
/// the chop beat (bars 3-6) and the build (bars 7-8), on the fixture take and on the installed drum
/// takes' own landmarks (skipped when none is installed). Offline, synthetic speech only. Output lines
/// start with `CHOP-PROBE`; export the attachments (`xcrun xcresulttool export attachments`).
struct DialogueChopVarietyProbeTests {
    typealias Film = DialogueHookProbeTests.Film

    /// A loop on `snapshot` (two 8-bar cues), as the coordinator plays it.
    static func loop(_ film: Film, snapshot: DialogueTransportSnapshot, seed: UInt64, memory: inout DialoguePerformanceMemory,
                     cueBase: Int) -> (events: [DialogueEvent], motif: DialogueMotif?) {
        var events: [DialogueEvent] = []
        var motif: DialogueMotif?
        for half in 0..<2 {
            let cue = cueBase + half
            let window = (snapshot.time(beat: Double(32 * half)) - 0.7)..<snapshot.time(beat: Double(32 * (half + 1)))
            guard let planned = DialogueMotif.plan(source: film.source, analysis: film.analysis, bank: film.bank, transcript: film.transcript,
                                                   snapshot: snapshot, window: window, earliestStart: window.lowerBound, memory: &memory,
                                                   seed: seed &+ UInt64(cue), cueToken: cue + 1, revision: 0) else { continue }
            events += planned.plan.events
            motif = planned.motif
        }
        return (events, motif)
    }

    /// A snapshot of an installed take, built as the coordinator builds it.
    static func takeSnapshot(_ asset: LofiDrumLibrary.Asset, take: Int) throws -> DialogueTransportSnapshot {
        let bpm = asset.entry.bpm
        let clock = LofiClock(tempo: bpm, sampleRate: asset.entry.sampleRate)
        let drums = try LofiDrumTake(recording: LofiDrumLibrary.load(asset), clock: clock)
        let beat = 60 / bpm
        let info = LofiTransportInfo(revision: 1, takeIndex: take, phraseAtTakeStart: 4 * take, origin: 0.5 + Double(take) * 64 * beat,
                                     beatDuration: beat, nextBeatDuration: nil, seed: 5, options: LofiOptions(tempo: bpm), timing: drums.timing)
        return DialogueCueCoordinator.snapshot(info, window: info.origin..<(info.origin + 64 * beat))
    }

    static func describe(_ name: String, _ c: DialogueChopMetrics.Section) -> String {
        let feel = Set(c.otherFeelMs.map { Int($0.rounded()) }).sorted()
        return String(format: "%@ hits=%d same=%.2f samePiece=%.2f sameUnmarked=%.2f samePieceUnmarked=%.2f stutters=%d run=%d pieces/bar=%.1f pieces/2bars=%.1f least/2bars=%d kick=%.2f snare=%.2f ghost=%.2f gap=%.2f a=%.2f off8=%.2f",
               name, c.hits, c.samePieceGate, c.samePiece, c.samePieceGateUnmarked, c.samePieceUnmarked, c.stutters, c.longestRun,
               c.piecesPerBar, c.piecesPer2Bars, c.leastPer2Bars, c.onKick, c.onSnare, c.onGhost, c.inGap, c.onA, c.offEighths)
            + String(format: " quarterFeelMax=%.1fms", c.quarterFeelMs.map(abs).max() ?? 0) + " offbeatFeelMs=\(feel)"
    }

    struct Tally {
        var chop: [DialogueChopMetrics.Section] = []
        var build: [DialogueChopMetrics.Section] = []
        var recurrence: [Double] = []
        mutating func add(_ events: [DialogueEvent], loop: Int, drums: DialogueChopMetrics.DrumSteps) {
            chop.append(DialogueChopMetrics.section(events, loop: loop, bars: 2..<6, drums: drums))
            build.append(DialogueChopMetrics.section(events, loop: loop, bars: 6..<8, drums: drums))
            recurrence.append(DialogueChopMetrics.recurrence(events, loop: loop))
        }
        func summary(_ name: String) -> [String] {
            func mean(_ list: [DialogueChopMetrics.Section], _ k: (DialogueChopMetrics.Section) -> Double) -> Double {
                list.map(k).reduce(0, +) / Double(max(1, list.count))
            }
            return [("chopBeat", chop), ("build", build)].map { name2, list in
                String(format: "CHOP-PROBE SUMMARY %@ %@ n=%d same=%.3f samePiece=%.3f sameUnmarked=%.3f samePieceUnmarked=%.3f stutters=%.1f run=%.1f pieces/bar=%.2f pieces/2bars=%.2f least/2bars=%.1f kick=%.2f snare=%.2f ghost=%.2f gap=%.2f a=%.2f off8=%.2f",
                       name, name2, list.count, mean(list, \.samePieceGate), mean(list, \.samePiece), mean(list, \.samePieceGateUnmarked),
                       mean(list, \.samePieceUnmarked), mean(list) { Double($0.stutters) }, mean(list) { Double($0.longestRun) },
                       mean(list, \.piecesPerBar), mean(list, \.piecesPer2Bars), mean(list) { Double($0.leastPer2Bars) },
                       mean(list, \.onKick), mean(list, \.onSnare), mean(list, \.onGhost), mean(list, \.inGap), mean(list, \.onA), mean(list, \.offEighths))
            } + [String(format: "CHOP-PROBE SUMMARY %@ recurrence(bars3-4 vs 5-6)=%.2f min=%.2f", name,
                        recurrence.reduce(0, +) / Double(max(1, recurrence.count)), recurrence.min() ?? 0)]
        }
    }

    @Test func printChopBeatsOnTheFixtureTake() throws {
        let emit = DialogueHookProbeTests.Sink("chops-fixture")
        defer { emit.flush() }
        let shapes: [(String, Double, Film)] = [
            ("transcript-72", 72, DialogueHookProbeTests.film(DialogueHookProbeTests.investigate, id: "cp-inv-t", transcribed: true)),
            ("acoustic-72", 72, DialogueHookProbeTests.film(DialogueHookProbeTests.investigate, id: "cp-inv-a", transcribed: false)),
            ("mixed-transcript-84", 84, DialogueHookProbeTests.film(DialogueHookProbeTests.mixed, id: "cp-mix-t", transcribed: true)),
        ]
        var all = Tally()
        for (name, bpm, film) in shapes {
            var tally = Tally()
            for seed: UInt64 in [1, 2, 3, 5, 8, 13] {
                var memory = DialoguePerformanceMemory()
                let beat = 60 / bpm
                for take in 0..<3 {
                    var snapshot = DialogueFixtures.snapshot(bpm: bpm, origin: 0.5 + Double(take) * 64 * beat, phraseAtOrigin: 4 * take,
                                                             takeIndex: take, seed: 3, ghosts: true)
                    snapshot.grooveOffsets = (0..<DialogueTransportSnapshot.takeSixteenths).map { $0 % 2 == 1 ? 0.08 : 0.0 }
                    let drums = DialogueChopMetrics.DrumSteps(snapshot)
                    let played = Self.loop(film, snapshot: snapshot, seed: seed, memory: &memory, cueBase: take * 2)
                    guard let motif = played.motif else { continue }
                    tally.add(played.events, loop: take, drums: drums)
                    all.add(played.events, loop: take, drums: drums)
                    emit("CHOP-PROBE \(name) seed=\(seed) loop=\(take) line=\"\(motif.text ?? "-")\" arc=\(motif.arc?.name ?? "-") S=\(motif.hook?.signature ?? -1) R=\(motif.hook?.response ?? -1) T=\(motif.hook?.third ?? -1) halves=\(motif.halves.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
                    if seed <= 2 { for row in DialogueChopMetrics.grid(played.events, loop: take, drums: drums, bars: 2..<8) { emit("CHOP-PROBE   \(row)") } }
                    emit("CHOP-PROBE   " + Self.describe("chopBeat", DialogueChopMetrics.section(played.events, loop: take, bars: 2..<6, drums: drums)))
                    emit("CHOP-PROBE   " + Self.describe("build", DialogueChopMetrics.section(played.events, loop: take, bars: 6..<8, drums: drums)))
                }
            }
            tally.summary(name).forEach { emit($0) }
        }
        all.summary("fixture-all").forEach { emit($0) }
    }

    @Test func printChopBeatsOnInstalledTakes() throws {
        let assets = LofiDrumLibrary.assets()
        guard !assets.isEmpty else { return }
        let emit = DialogueHookProbeTests.Sink("chops-takes")
        defer { emit.flush() }
        let film = DialogueHookProbeTests.film(DialogueHookProbeTests.mixed, id: "cp-takes", transcribed: true)
        // Eight takes spread across the library.
        let picked = (0..<8).map { assets[$0 * assets.count / 8] }
        var all = Tally()
        for (k, asset) in picked.enumerated() {
            let snapshot = try Self.takeSnapshot(asset, take: 0)
            let drums = DialogueChopMetrics.DrumSteps(snapshot)
            let motifDrums = DialogueMotifDrums(snapshot: snapshot)
            var soft = [Int](repeating: 0, count: 32), strong = [Int](repeating: 0, count: 32), kick = [Int](repeating: 0, count: 32)
            for m in snapshot.snares where m.confidence >= 0.25 {
                let s = ((Int((m.beat * 4).rounded()) % 32) + 32) % 32
                if m.strength < DialogueChopMetrics.DrumSteps.ghostStrength { soft[s] += 1 } else if m.confidence >= 0.5 { strong[s] += 1 }
            }
            for m in snapshot.kicks where m.confidence >= 0.5 { kick[((Int((m.beat * 4).rounded()) % 32) + 32) % 32] += 1 }
            emit("CHOP-PROBE TAKE \(asset.entry.name) bpm=\(asset.entry.bpm) kicks=\(drums.kicks.sorted()) snares=\(drums.snares.sorted()) ghosts=\(drums.ghosts.sorted()) motifDrums=\(motifDrums)")
            emit("CHOP-PROBE   counts kick=\(kick) snare=\(strong) soft=\(soft)")
            for seed: UInt64 in [1, 2] {
                var memory = DialoguePerformanceMemory()
                let played = Self.loop(film, snapshot: snapshot, seed: seed &+ UInt64(k * 7), memory: &memory, cueBase: 0)
                guard let motif = played.motif else { continue }
                all.add(played.events, loop: 0, drums: drums)
                emit("CHOP-PROBE   seed=\(seed) line=\"\(motif.text ?? "-")\" arc=\(motif.arc?.name ?? "-")")
                if seed == 1 { for row in DialogueChopMetrics.grid(played.events, loop: 0, drums: drums, bars: 2..<8) { emit("CHOP-PROBE   \(row)") } }
                emit("CHOP-PROBE   " + Self.describe("chopBeat", DialogueChopMetrics.section(played.events, loop: 0, bars: 2..<6, drums: drums)))
                emit("CHOP-PROBE   " + Self.describe("build", DialogueChopMetrics.section(played.events, loop: 0, bars: 6..<8, drums: drums)))
            }
        }
        all.summary("takes-all").forEach { emit($0) }
    }
}
