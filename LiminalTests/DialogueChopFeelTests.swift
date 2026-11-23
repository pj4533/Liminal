import AVFoundation
import Foundation
import Testing
@testable import Liminal

struct DialogueChopFeelTests {
    @Test func cadenceMatchingIsBoundedDeterministicAndDependsOnTempo() {
        let beat = 60.0 / 72
        let speed = DialogueVarispeed.transform(period: 0.23, beatDuration: beat)
        let slow = DialogueVarispeed.transform(period: 0.38, beatDuration: beat)
        #expect(speed.playbackRate > 1 && slow.playbackRate < 1)
        #expect(speed == DialogueVarispeed.transform(period: 0.23, beatDuration: beat))
        #expect(speed != DialogueVarispeed.transform(period: 0.23, beatDuration: 60 / 84))
        for period in stride(from: 0.08, through: 0.8, by: 0.01) {
            let transform = DialogueVarispeed.transform(period: period, beatDuration: beat)
            #expect(abs(12 * log2(transform.playbackRate)) <= 2.5 + 1e-9)
        }
        #expect(DialogueVarispeed.transform(period: .nan, beatDuration: beat) == .native)
    }

    @Test func previousMovePositionsAreAvoidedAcrossDifferentLinesAndReplayIsDeterministic() throws {
        var changes = 0, reverses = Set<Int>(), rates = Set<Int>()
        for (_, bpm, film) in DialogueChopVarietyTests.films {
            for seed: UInt64 in 1...6 {
                let loops = DialogueChopVarietyTests.run(film, bpm: bpm, seed: seed)
                let replay = DialogueChopVarietyTests.run(film, bpm: bpm, seed: seed)
                #expect(loops.map { $0.motif.cells } == replay.map { $0.motif.cells })
                for loop in loops {
                    rates.insert(Int((loop.motif.transform.playbackRate * 10000).rounded()))
                    reverses.formUnion(DialogueMovePool.positions(loop.motif.cells) { $0.effect == .reversed })
                    #expect(loop.events.allSatisfy { $0.transform == loop.motif.transform })
                    #expect(DialogueChopMetrics.recurrence(loop.events, loop: loop.index) >= 0.7)
                    for pad in loop.motif.bank.pads {
                        #expect(pad.transform == loop.motif.transform)
                        #expect(abs(pad.duration * loop.motif.playbackSampleRate - Double(pad.frames.count)) < 1e-6)
                        let render = try #require(loop.motif.renders[pad.padID])
                        #expect(Int(render.frameLength) == DialogueChopRenderer.outputCount(pad))
                    }
                }
                for (a, b) in zip(loops, loops.dropFirst()) {
                    if a.motif.lineKey != b.motif.lineKey { changes += 1 }
                    #expect(b.motif.priorCells == a.motif.cells)
                    // These are arranged quiet entrances, rather than all naturally empty steps.
                    for kind in [DialogueCell.intro, .outro] {
                        func entrance(_ motif: DialogueMotif) -> Int? {
                            motif.cells.first { $0.kind == kind }?.items.first { $0.fragment != 0 && $0.effect != .reversed }?.slot
                        }
                        if let before = entrance(a.motif), let after = entrance(b.motif) {
                            #expect(before != after, "repeated intentional quiet entrance in \(kind)")
                        }
                    }
                    for reverse in [false, true] {
                        let filter: (DialogueMotifCell.Item) -> Bool = { reverse ? $0.effect == .reversed : $0.stutter }
                        let before = DialogueMovePool.positions(a.motif.cells, where: filter)
                        let after = DialogueMovePool.positions(b.motif.cells, where: filter)
                        #expect(before.isDisjoint(with: after))
                    }
                }
            }
        }
        #expect(changes >= 20)
        #expect(reverses.count >= 8, "pickup positions: \(reverses)")
        #expect(rates.count >= 3, "line playback rates: \(rates)")
    }

    @Test func movePoolPreservesCompleteSpellingFiguresAndDynamicChains() throws {
        func fragment(_ id: Int, _ kind: DialogueMotifFragment.Kind, parent: Int? = nil) -> DialogueMotifFragment {
            DialogueMotifFragment(id: id, kind: kind, order: parent ?? id, parent: parent,
                frames: (id * 100)..<(id * 100 + (kind == .letter ? 100 : 300)),
                accentFrame: id * 100, fadeIn: 0, fadeOut: 0, text: nil, weight: 0.95)
        }
        let fragments = [fragment(0, .line), fragment(1, .piece), fragment(2, .piece),
                         fragment(3, .letter, parent: 1), fragment(4, .letter, parent: 1), fragment(5, .letter, parent: 1)]
        typealias Item = DialogueMotifCell.Item
        func figure(_ start: Int) -> [Item] {
            [Item(fragment: 3, slot: start, fixed: true, gate: 1),
             Item(fragment: 4, slot: start + 1, fixed: true, gate: 1),
             Item(fragment: 5, slot: start + 2, fixed: true, gate: 1),
             Item(fragment: 1, slot: start + 4, fixed: true, gate: 4)]
        }
        let chain = Item(fragment: 2, slot: 16, after: 0, onEighths: true)
        let follow = Item(fragment: 2, slot: 0, fixed: true, gate: 2, follow: 2)
        let cells = [DialogueMotifCell(kind: .build, bar: 6, bars: 2, variant: 0, items: figure(20)),
                     DialogueMotifCell(kind: .outro, bar: 12, bars: 4, variant: 0,
                        items: [Item(fragment: 2, slot: 12), Item(fragment: 0, slot: 16), chain, follow] + figure(56))]
        var previous: [DialogueMotifCell] = []
        for seed: UInt64 in 1...30 {
            let arranged = DialogueMovePool.arrange(cells, fragments: fragments, signature: 1,
                sampleRate: 1000, beatDuration: 60 / 72, seed: seed, avoiding: previous)
            for cell in arranged {
                let units = cell.items.filter { fragments[$0.fragment].kind == .letter }
                #expect(units.map(\.fragment) == [3, 4, 5])
                #expect(zip(units, units.dropFirst()).allSatisfy { $1.slot - $0.slot == 1 })
                let whole = try #require(cell.items.first { $0.fragment == 1 && $0.slot > units.last!.slot })
                #expect(whole.slot % 4 == 0 && whole.slot == (units.last!.slot / 4 + 1) * 4)
            }
            let outro = try #require(arranged.last)
            let lineIndex = try #require(outro.items.firstIndex { $0.fragment == 0 })
            #expect(outro.items[lineIndex + 1] == chain && outro.items[lineIndex + 2] == follow)
            previous = arranged
        }
    }

    /// Run the independent D126 detector on native and speed-matched renders of the same chosen lines.
    /// Unlike a duration or source-coordinate assertion, this measures the audio after resampling/DSP.
    @Test func resampledRenderedAttacksRetainNativeTightness() throws {
        var native: [DialogueTightnessMetrics.Hit] = [], matched: [DialogueTightnessMetrics.Hit] = []
        for (fixture, bpm, transcribed) in GateRun.cases {
            let film = DialogueHookProbeTests.film(fixture, id: "feel-tight-\(bpm)-\(transcribed)", transcribed: transcribed)
            for seed: UInt64 in 1...4 {
                let snapshot = GateRun.swung(bpm: bpm)
                let memory = DialoguePerformanceMemory()
                let line = try #require(DialogueMotif.make(loop: 0, source: film.source, analysis: film.analysis,
                    transcript: film.transcript, memory: memory, seed: seed, beatDuration: snapshot.beatDuration))
                for (isNative, transform) in [(true, DialogueTransform.native), (false, line.transform)] {
                    let motif = try #require(DialogueMotif.make(loop: 0, source: film.source, analysis: film.analysis,
                        transcript: film.transcript, memory: memory, seed: seed, beatDuration: snapshot.beatDuration,
                        line: line.lineUnit, transform: transform))
                    var trial = DialoguePerformanceMemory()
                    for half in 0..<2 {
                        let window = snapshot.time(beat: Double(half * 32))..<snapshot.time(beat: Double((half + 1) * 32))
                        let plan = DialogueMotifPerformer.perform(motif, snapshot: snapshot, window: window, owned: Double(half * 32)..<Double((half + 1) * 32),
                            earliestStart: window.lowerBound, memory: &trial, seed: seed, cueToken: half + 1, revision: 0)
                        let chops = DialogueChopRenderer.render(plan, bank: motif.bank, source: motif.source, analysis: motif.analysis, prerendered: motif.renders)
                        let hits = DialogueTightnessMetrics.hits(chops, sixteenth: snapshot.beatDuration / 4,
                            weakLead: Set(motif.fragments.filter(\.weakLead).map(\.id))).filter { !$0.line && !$0.weakLead }
                        if isNative { native += hits } else { matched += hits }
                    }
                }
            }
        }
        let before = DialogueTightnessMetrics.percentile(native.map { abs($0.attackMs) }, 0.5)
        let after = DialogueTightnessMetrics.percentile(matched.map { abs($0.attackMs) }, 0.5)
        let badBefore = native.filter { abs($0.attackMs) > 35 }.count
        let badAfter = matched.filter { abs($0.attackMs) > 35 }.count
        let summary = "FEEL-TIGHT native=\(native.count) matched=\(matched.count) medianMs=\(before),\(after) over35ms=\(badBefore),\(badAfter)"
        print(summary)
        Attachment.record(summary, named: "feel-tightness.txt")
        #expect(native.count > 100 && matched.count > 100)
        #expect(abs(after - before) <= 2, "\(summary)")
        #expect(badAfter <= badBefore, "\(summary)")
    }
}
