import AVFoundation
import Foundation
import Testing
@testable import Liminal

struct DialogueGateTests {
    @Test func gatesEndBeforeTheirStepOnTheSwungGrid() throws {
        var gated = 0, short = 0, hits = 0
        for (fixture, bpm, transcribed) in GateRun.cases {
            for seed: UInt64 in [1, 2, 3] {
                let run = GateRun.make(fixture, bpm: bpm, seed: seed, transcribed: transcribed)
                let events = run.events
                #expect(!events.isEmpty)
                let six = run.snapshot.beatDuration / 4
                for e in events where e.piece != 0 && e.effect != .reversed {
                    hits += 1
                    let dry = e.drySeconds ?? e.duration
                    if dry <= 2.05 * six { short += 1 }
                    if e.gateSteps != nil { gated += 1 }
                    guard let g = e.gateSteps, e.gateEnd == "gate" || e.gateEnd == "valley" else { continue }
                    let step = (e.block - run.snapshot.phraseAtOrigin) * 64 + e.slot
                    let close = run.snapshot.gridTime(sixteenth: step + Int(g)) - DialogueMotifTuning.gateLeadSeconds
                    let end = e.startTime + dry
                    #expect(end <= close + 1e-6, "bpm \(bpm) seed \(seed): gate \(g) ends \((end - close) * 1000) ms late")
                    if e.gateEnd == "valley" {
                        #expect(end >= close - DialogueMotifTuning.valleySnapSeconds - 1e-6)
                    }
                    #expect(end - e.accentTime >= DialogueMotifTuning.minimumGateSeconds - 1e-6)
                }
            }
        }
        // Most hits are held for a gate now (or end naturally inside it); most last two steps or less.
        #expect(gated > hits / 2, "\(gated) gated of \(hits)")
        #expect(Double(short) >= 0.6 * Double(hits), "\(short) of \(hits) at two steps or less")
    }

    @Test func hitsNeverOverlapAndTheLineIsNeverGated() throws {
        for (fixture, bpm, transcribed) in GateRun.cases {
            for seed: UInt64 in [1, 2, 3] {
                let events = GateRun.make(fixture, bpm: bpm, seed: seed, transcribed: transcribed).events
                for (a, b) in zip(events, events.dropFirst()) {
                    #expect(b.startTime >= a.endTime - 1e-6, "bpm \(bpm) seed \(seed): overlap \((a.endTime - b.startTime) * 1000) ms")
                }
                for e in events where e.piece == 0 {
                    #expect(e.gateEnd == "natural" && e.drySeconds == nil && e.gateSteps == nil)
                }
            }
        }
    }

    @Test func gatedChopsReleaseWithoutAClickAndShareTheirPadsGain() throws {
        let run = GateRun.make(GateRun.investigate, bpm: 72, seed: 2, transcribed: true)
        var byPad: [Int: [DialogueChop]] = [:]
        var checked = 0
        for plan in run.plans {
            for chop in plan.render() where chop.event.gateEnd == "gate" || chop.event.gateEnd == "valley" {
                let x = try #require(chop.buffer.floatChannelData?[0])
                let n = Int(chop.buffer.frameLength)
                let sr = chop.buffer.format.sampleRate
                var peak: Float = 0
                for i in 0..<n { peak = max(peak, abs(x[i])) }
                guard peak > 1e-4 else { continue }
                checked += 1
                if case .echoThrow = chop.event.effect { continue }
                #expect(x[n - 1] == 0)
                var tail: Float = 0
                for i in max(0, n - Int(0.001 * sr))..<n { tail = max(tail, abs(x[i])) }
                #expect(tail <= 0.05 * peak, "last millisecond at \(20 * log10(tail / peak)) dB")
                if chop.event.effect == .none { byPad[chop.event.padID, default: []].append(chop) }
            }
        }
        #expect(checked > 4)
        // Two gates of one pad play the same samples up to the shorter one's release.
        var compared = 0
        for chops in byPad.values {
            let lengths = Dictionary(grouping: chops) { Int($0.buffer.frameLength) }
            guard lengths.count >= 2, let a = lengths.values.first?.first, let b = lengths.values.dropFirst().first?.first,
                  a.event.gainDB == b.event.gainDB else { continue }
            let pa = try #require(a.buffer.floatChannelData?[0]), pb = try #require(b.buffer.floatChannelData?[0])
            let common = min(Int(a.buffer.frameLength), Int(b.buffer.frameLength)) - Int(0.009 * a.buffer.format.sampleRate)
            var worst: Float = 0
            for i in 0..<max(0, common) { worst = max(worst, abs(pa[i] - pb[i])) }
            #expect(worst < 1e-5, "pad \(a.event.padID): gates differ by \(worst)")
            compared += 1
        }
        #expect(compared >= 1, "no pad played at two gate lengths")
    }

    @Test func theHookLogShowsGates() throws {
        let run = GateRun.make(GateRun.investigate, bpm: 72, seed: 1, transcribed: true)
        let motif = try #require(run.motifs.first)
        let summary = motif.hookSummary(events: run.events)
        #expect(summary.contains("/1") || summary.contains("/2"), "\(summary)")
    }
}
