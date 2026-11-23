import Foundation
import Testing
@testable import Liminal

/// Deterministic fixture measurement, shared unchanged by the before/after runs. These are synthetic
/// speech and drum fixtures, not a replacement for the cached-film probe or listening acceptance.
struct DialogueFeelMetricsTests {
    @Test func emitPatternAndTimingMeasurements() throws {
        let emit = DialogueHookProbeTests.Sink("chop-feel-metrics")
        defer { emit.flush() }
        var count = 0
        for (name, bpm, film) in DialogueChopVarietyTests.films {
            for seed: UInt64 in 1...12 {
                for loop in DialogueChopVarietyTests.run(film, bpm: bpm, seed: seed) {
                    let placed = DialogueChopMetrics.placed(loop.events, loop: loop.index)
                    var moves: [String: [Int]] = ["reverse": [], "stutter": [], "roll": [], "rest": [], "quiet": []]
                    var occupied = Set<Int>()
                    for (s, e) in placed {
                        if e.effect == .reversed { moves["reverse", default: []].append(s) }
                        if e.stutter { moves[e.cell == .build ? "roll" : "stutter", default: []].append(s) }
                        let dry = e.drySeconds ?? e.duration
                        for k in 0..<256 where loop.snapshot.gridTime(sixteenth: k) >= e.startTime
                            && loop.snapshot.gridTime(sixteenth: k) < e.startTime + dry { occupied.insert(k) }
                    }
                    let onsets = Set(placed.map(\.s))
                    moves["rest"] = (0..<256).filter { !onsets.contains($0) }
                    moves["quiet"] = (0..<256).filter { !occupied.contains($0) }
                    let record: [String: Any] = ["film": name, "seed": seed, "loop": loop.index,
                        "line": String(loop.motif.lineKey), "moves": moves,
                        "grid": placed.map { "\($0.s):\($0.e.piece ?? -1):\($0.e.gateSteps ?? -1):\($0.e.effect.name)" },
                        "hookRecurrence": DialogueChopMetrics.recurrence(loop.events, loop: loop.index)]
                    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    emit("FEEL-METRIC " + String(decoding: data, as: UTF8.self))
                    count += 1
                }
            }
        }
        #expect(count == 108, "All seeds, fixture films and loops must be measured")
    }
}
