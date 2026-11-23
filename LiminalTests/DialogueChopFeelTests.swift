import AVFoundation
import Foundation
import Testing
@testable import Liminal

struct DialogueChopFeelTests {
    @Test(arguments: [false, true]) func attackPreservationLiftsTheRetainedSyllableWithoutTrimmingOrMovingAudio(_ highCrestTaper: Bool) {
        let rate = 48_000.0
        var original: [Float] = (0..<24_000).map { i in
            let time = Double(i) / rate
            let opening = 0.16 * exp(-pow((time - 0.020) / 0.012, 2))
            let stressed = 0.7 * exp(-pow((time - 0.285) / 0.018, 2))
            return Float((opening + stressed) * sin(2 * .pi * 700 * time))
        }
        if highCrestTaper {
            // Single-sample transients do not move the syllable's RMS maximum. Some land at
            // the gain taper's end, where a second soft shoulder used to attenuate them.
            for (index, time) in stride(from: 0.070, through: 0.110, by: 0.003).enumerated() {
                original[Int(time * rate)] = index.isMultiple(of: 2) ? 0.85 : -0.85
            }
        }
        var output = original
        DialogueChopRenderer.preserveAttack(&output, expected: 0.012, line: false, sampleRate: rate)
        func firstHalfPeak(_ x: [Float]) -> Double {
            let width = 96, end = 14_400
            let rms = stride(from: 0, to: end - width, by: 24).map { i -> Float in
                sqrt(x[i..<(i + width)].reduce(0) { $0 + $1 * $1 } / Float(width))
            }
            let half = (rms.max() ?? 0) / 2
            return Double((rms.firstIndex { $0 >= half } ?? rms.count) * 24) / rate
        }
        #expect(firstHalfPeak(original) > 0.2)
        #expect(firstHalfPeak(output) < 0.035)
        #expect(output.count == original.count)
        #expect(Array(output[7_200...]) == Array(original[7_200...]))
        for (a, b) in zip(original, output) {
            #expect(a * b >= 0)
            #expect(abs(b) + 1e-7 >= abs(a))
            #expect(abs(b) <= abs(a) * powf(10, 9.0 / 20) + 1e-7)
            #expect(b.isFinite && abs(b) < DialogueChopChain.peakCeiling)
        }
    }

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
                    #expect(loop.motif.hook?.items == loop.motif.cells.first { $0.kind == .chopBeat }?.items)
                    rates.insert(Int((loop.motif.transform.playbackRate * 10000).rounded()))
                    reverses.formUnion(DialogueMovePool.positions(loop.motif.cells) { $0.effect == .reversed })
                    #expect(loop.events.allSatisfy { $0.transform == loop.motif.transform })
                    let recurrence = DialogueChopMetrics.recurrence(loop.events, loop: loop.index)
                    if recurrence < 0.7 {
                        let detail = "RECURRENCE bpm=\(bpm) seed=\(seed) loop=\(loop.index) line=\(loop.motif.text ?? "-") cells=\(loop.motif.cells) events=\(loop.events)"
                        Attachment.record(detail, named: "recurrence-\(bpm)-\(seed)-\(loop.index).txt")
                    }
                    #expect(recurrence >= 0.7, "bpm=\(bpm) seed=\(seed) loop=\(loop.index)")
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

    @Test func movingFillsKeepsBothHookPassesAndBackbeatsWhenOnlyTheTurnaroundSpells() {
        func fragment(_ id: Int, _ kind: DialogueMotifFragment.Kind) -> DialogueMotifFragment {
            DialogueMotifFragment(id: id, kind: kind, order: id, parent: kind == .letter ? 1 : nil,
                frames: (id * 1000)..<(id * 1000 + 100), accentFrame: id * 1000,
                fadeIn: 0, fadeOut: 0, text: nil, weight: 0.95)
        }
        let fragments = [fragment(0, .line), fragment(1, .piece), fragment(2, .piece), fragment(3, .letter)]
        typealias Item = DialogueMotifCell.Item
        let shared = [Item(fragment: 1, slot: 0, fixed: true, gate: 2, skeleton: true),
                      Item(fragment: 2, slot: 4, fixed: true, gate: 2, skeleton: true),
                      Item(fragment: 1, slot: 8, fixed: true, gate: 2),
                      Item(fragment: 2, slot: 12, fixed: true, gate: 2, skeleton: true),
                      Item(fragment: 1, slot: 16, fixed: true, gate: 2, skeleton: true),
                      Item(fragment: 2, slot: 20, fixed: true, gate: 2, skeleton: true)]
        let cells = [DialogueMotifCell(kind: .chopBeat, bar: 2, bars: 2, variant: 0, items: shared),
                     DialogueMotifCell(kind: .chopBeat, bar: 4, bars: 2, variant: 0,
                        items: shared + [Item(fragment: 3, slot: 29, fixed: true, gate: 1)])]
        var previous: [DialogueMotifCell] = []
        for seed: UInt64 in 1...30 {
            let arranged = DialogueMovePool.arrange(cells, fragments: fragments, signature: 1,
                sampleRate: 1000, beatDuration: 60 / 72, seed: seed, avoiding: previous)
            for cell in arranged {
                #expect(cell.items.filter(\.skeleton) == shared.filter(\.skeleton))
                #expect(cell.items.filter { $0.effect != .reversed && $0.slot < 28 }.count == shared.count)
                #expect(cell.items.allSatisfy { $0.slot < cell.bars * 16 })
            }
            #expect(arranged[0].items.filter { $0.slot < 28 } == arranged[1].items.filter { $0.slot < 28 })
            previous = arranged
        }
    }

    @Test func anImmovableFirstFillDoesNotHideALaterOpenPocket() {
        typealias Item = DialogueMotifCell.Item
        let fragments = (0..<3).map { id in
            DialogueMotifFragment(id: id, kind: id == 0 ? .line : .piece, order: id, parent: nil,
                frames: 0..<100, accentFrame: 0, fadeIn: 0, fadeOut: 0, text: nil)
        }
        let shared = [Item(fragment: 1, slot: 0, skeleton: true), Item(fragment: 2, slot: 2, skeleton: true),
                      Item(fragment: 1, slot: 4), Item(fragment: 2, slot: 6, skeleton: true),
                      Item(fragment: 1, slot: 12), Item(fragment: 2, slot: 20, skeleton: true)]
        let cells = [DialogueMotifCell(kind: .chopBeat, bar: 2, bars: 2, variant: 0, items: shared),
                     DialogueMotifCell(kind: .chopBeat, bar: 4, bars: 2, variant: 0, items: shared)]
        for seed: UInt64 in 1...20 {
            let result = DialogueMovePool.arrange(cells, fragments: fragments, signature: 1,
                sampleRate: 1000, beatDuration: 0.8, seed: seed, avoiding: [])
            for cell in result {
                let fills = cell.items.filter { !$0.skeleton && $0.effect != .reversed }.map(\.slot)
                #expect(fills.contains(4))
                #expect(fills.contains(10) || fills.contains(14))
                #expect(!fills.contains(12))
                #expect(cell.items.filter(\.skeleton) == shared.filter(\.skeleton))
            }
        }
    }

    @Test func reversePickupsLeaveBothPassesAndTheFollowingConsonantClear() {
        typealias Item = DialogueMotifCell.Item
        func fragment(_ id: Int, length: Int, offset: Int = 0) -> DialogueMotifFragment {
            DialogueMotifFragment(id: id, kind: id == 0 ? .line : .piece, order: id, parent: nil,
                frames: 0..<length, accentFrame: offset, fadeIn: 0, fadeOut: 0, text: nil)
        }
        // The next call's consonant precedes its accent. The response at the end of pass one
        // also extends into pass two's potential pickup; neither may be stolen by a reverse.
        let fragments = [fragment(0, length: 100), fragment(1, length: 450),
                         fragment(2, length: 900, offset: 500), fragment(3, length: 1600)]
        let shared = [Item(fragment: 2, slot: 6, fixed: true, skeleton: true),
                      Item(fragment: 1, slot: 12, fixed: true, skeleton: true),
                      Item(fragment: 3, slot: 28, fixed: true, skeleton: true)]
        let cells = [DialogueMotifCell(kind: .chopBeat, bar: 2, bars: 2, variant: 0, items: shared),
                     DialogueMotifCell(kind: .chopBeat, bar: 4, bars: 2, variant: 0, items: shared)]
        for seed: UInt64 in 1...40 {
            let result = DialogueMovePool.arrange(cells, fragments: fragments, signature: 1,
                sampleRate: 1000, beatDuration: 0.8, seed: seed, avoiding: [])
            let pickups = result.flatMap { cell in cell.items.filter { $0.effect == .reversed }.map { (cell.bar, $0.slot) } }
            #expect(!pickups.contains { $0.1 == 4 }, "pickup would overlap the next consonant")
            #expect(result[0].items == result[1].items, "both hook passes must retain the same pickup")
            for (bar, slot) in pickups {
                let start = Double(bar * 16 + slot) * 0.2 - 0.45 - DialogueMotifTuning.reversedLeadSeconds
                let end = start + 0.45
                for cell in cells {
                    for item in cell.items {
                        let f = fragments[item.fragment]
                        let otherStart = Double(cell.bar * 16 + item.slot) * 0.2 - Double(f.accentFrame) / 1000
                        let otherEnd = otherStart + Double(f.frames.count) / 1000
                        #expect(end + DialogueTuning.dryGapSeconds <= otherStart || start >= otherEnd + DialogueTuning.dryGapSeconds)
                    }
                }
            }
        }
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

    @Test func performedSpellingFigureIsAtomicAcrossDynamicOutroCollisions() throws {
        let film = DialogueHookProbeTests.film(GateRun.corpus, id: "atomic-outro", transcribed: false)
        let snapshot = DialogueFixtures.snapshot(bpm: 72, origin: 0.5, seed: 3)
        let base = try #require(DialogueMotif.make(loop: 0, source: film.source, analysis: film.analysis,
            transcript: film.transcript, memory: DialoguePerformanceMemory(), seed: 1,
            beatDuration: snapshot.beatDuration))
        let line = try #require(film.analysis.units.first)
        let rate = base.sampleRate
        func fragment(_ id: Int, _ kind: DialogueMotifFragment.Kind, seconds: Double, parent: Int? = nil) -> DialogueMotifFragment {
            let start = Int(Double(id) * rate)
            let frames = start..<(start + Int(seconds * rate))
            var result = DialogueMotifFragment(id: id, kind: kind, order: id, parent: parent,
                frames: frames, accentFrame: start, fadeIn: 0, fadeOut: 0, text: nil, weight: 0.95)
            result.words = [.init(frames: frames, weight: 0.95)]
            return result
        }
        let fragments = [fragment(0, .line, seconds: 5), fragment(1, .piece, seconds: 0.3),
                         fragment(2, .piece, seconds: 0.35), fragment(3, .letter, seconds: 0.1, parent: 1),
                         fragment(4, .letter, seconds: 0.1, parent: 1), fragment(5, .letter, seconds: 0.1, parent: 1)]
        let bank = DialogueMotif.motifBank(fragments, line: line, analysis: base.analysis, key: base.lineKey, usedTranscript: false)
        typealias Item = DialogueMotifCell.Item
        var completed = 0, dropped = 0
        for seed: UInt64 in 1...30 {
            let authored = [DialogueMotifCell(kind: .outro, bar: 12, bars: 4, variant: 0, items: [
                Item(fragment: 0, slot: 16), Item(fragment: 2, slot: 44, after: 0, onEighths: true),
                Item(fragment: 2, slot: 0, fixed: true, gate: 2, follow: 2),
                Item(fragment: 3, slot: 56, fixed: true, gate: 1),
                Item(fragment: 4, slot: 57, fixed: true, gate: 1),
                Item(fragment: 5, slot: 58, fixed: true, gate: 1),
                Item(fragment: 1, slot: 60, fixed: true, gate: 4)])]
            let cells = DialogueMovePool.arrange(authored, fragments: fragments, signature: 1, sampleRate: rate,
                beatDuration: snapshot.beatDuration, seed: seed, avoiding: [])
            let motif = DialogueMotif(loop: 0, source: base.source, analysis: base.analysis, lineUnit: base.lineUnit,
                lineKey: base.lineKey, fragments: fragments, pieces: [2], halves: [1: [3, 4, 5]], bank: bank,
                usedTranscript: false, reorderAllowed: false, cells: cells, carried: false, seed: seed)
            var memory = DialoguePerformanceMemory()
            let window = snapshot.time(beat: 48)..<snapshot.time(beat: 64)
            let plan = DialogueMotifPerformer.perform(motif, snapshot: snapshot, window: window, owned: 48..<64,
                earliestStart: window.lowerBound, memory: &memory, seed: seed, cueToken: 1, revision: 0)
            let figure = plan.events.filter { [1, 3, 4, 5].contains($0.piece ?? -1) && $0.effect != .reversed }
            let ids = figure.compactMap(\.piece)
            #expect(ids.isEmpty || ids == [3, 4, 5, 1], "seed \(seed): partial figure \(ids)")
            if ids.isEmpty { dropped += 1 } else {
                completed += 1
                let slots = figure.map(\.slot)
                #expect(slots[1] == slots[0] + 1 && slots[2] == slots[0] + 2)
                #expect(slots[3] % 4 == 0 && slots[3] == slots[0] + 4)
            }
        }
        #expect(completed > 0 && dropped > 0, "complete=\(completed) dropped=\(dropped)")
    }

    /// Run the independent D126 detector on native and speed-matched renders of the same chosen lines.
    /// Unlike a duration or source-coordinate assertion, this measures the audio after resampling/DSP.
    @Test func resampledRenderedAttacksRetainNativeTightness() throws {
        var native: [DialogueTightnessMetrics.Hit] = [], matched: [DialogueTightnessMetrics.Hit] = []
        var inventoryNative: [DialogueTightnessMetrics.Hit] = [], inventoryMatched: [DialogueTightnessMetrics.Hit] = []
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
                    // Every selected pad is measured once with the same full-length event recipe.
                    // Planning at different rates may omit different hits; it cannot shrink this inventory.
                    #expect(motif.fragments.map(\.frames) == line.fragments.map(\.frames))
                    #expect(motif.fragments.map(\.weakLead) == line.fragments.map(\.weakLead))
                    let inventory = line.fragments.filter { $0.id != 0 && !$0.weakLead }.map(\.id)
                    for id in inventory {
                        let pad = try #require(motif.bank.pad(id))
                        let buffer = try #require(motif.renders[pad.padID])
                        var event = DialogueEvent(padID: pad.padID, role: pad.role, block: 0, slot: 0,
                            accentTime: 0, startTime: -motif.accentOffset(pad.padID), duration: pad.duration,
                            gainDB: 0, protected: pad.protected, chokeAt: nil, text: pad.text,
                            transform: pad.transform, padKey: pad.padKey, snareLanded: false)
                        event.piece = pad.padID
                        let hits = DialogueTightnessMetrics.hits([DialogueChop(event: event, buffer: buffer)],
                            sixteenth: snapshot.beatDuration / 4)
                        #expect(hits.count == 1, "pad \(pad.padID) missing independent attack measurement")
                        for hit in hits where abs(hit.attackMs) > 35 {
                            let detail = "FEEL-TIGHT-INVENTORY native=\(isNative) bpm=\(bpm) seed=\(seed) pad=\(id) frames=\(pad.frames) rate=\(transform.playbackRate) attackMs=\(hit.attackMs)"
                            let n = Int(buffer.frameLength), sr = buffer.format.sampleRate
                            let head = min(n, Int(0.45 * sr))
                            let x = buffer.floatChannelData![0]
                            let envelope = DialogueOnsetEnvelope(samples: x, count: n, rate: sr, span: 0..<head, filtered: false)
                            let attack = DialogueOnset.attack(envelope, samples: x, count: n, rate: sr, search: 0..<head)
                            let strongest = DialogueOnset.attack(envelope, samples: x, count: n, rate: sr, search: 0..<head, firstPeakShare: 1)
                            let diagnostics = " storedOffset=\(motif.accentOffset(id)) candidateOffset=\(Double(attack.beatFrame) / sr) strongestOffset=\(Double(strongest.beatFrame) / sr)"
                            print(detail + diagnostics)
                            Attachment.record(detail + diagnostics, named: "inventory-\(bpm)-\(seed)-\(id)-\(isNative).txt")
                        }
                        if isNative { inventoryNative += hits } else { inventoryMatched += hits }
                    }
                    var trial = DialoguePerformanceMemory()
                    for half in 0..<2 {
                        let window = snapshot.time(beat: Double(half * 32))..<snapshot.time(beat: Double((half + 1) * 32))
                        let plan = DialogueMotifPerformer.perform(motif, snapshot: snapshot, window: window, owned: Double(half * 32)..<Double((half + 1) * 32),
                            earliestStart: window.lowerBound, memory: &trial, seed: seed, cueToken: half + 1, revision: 0)
                        let chops = DialogueChopRenderer.render(plan, bank: motif.bank, source: motif.source, analysis: motif.analysis, prerendered: motif.renders)
                        let weak = Set(motif.fragments.filter(\.weakLead).map(\.id))
                        let hits = chops.flatMap { chop -> [DialogueTightnessMetrics.Hit] in
                            let found = DialogueTightnessMetrics.hits([chop], sixteenth: snapshot.beatDuration / 4,
                                weakLead: weak).filter { !$0.line && !$0.weakLead }
                            for hit in found where abs(hit.attackMs) > 35 {
                                let e = chop.event
                                let detail = "FEEL-TIGHT-HIT native=\(isNative) bpm=\(bpm) seed=\(seed) half=\(half) pad=\(e.padID) frames=\(String(describing: e.sourceFrames)) rate=\(transform.playbackRate) gate=\(e.gateEnd) attackMs=\(hit.attackMs)"
                                print(detail)
                                Attachment.record(detail, named: "event-\(bpm)-\(seed)-\(half)-\(e.padID)-\(e.slot)-\(isNative).txt")
                            }
                            return found
                        }
                        if isNative { native += hits } else { matched += hits }
                    }
                }
            }
        }
        let before = DialogueTightnessMetrics.percentile(native.map { abs($0.attackMs) }, 0.5)
        let after = DialogueTightnessMetrics.percentile(matched.map { abs($0.attackMs) }, 0.5)
        let signedBefore = DialogueTightnessMetrics.percentile(native.map(\.attackMs), 0.5)
        let signedAfter = DialogueTightnessMetrics.percentile(matched.map(\.attackMs), 0.5)
        let inventoryBefore = DialogueTightnessMetrics.percentile(inventoryNative.map(\.attackMs), 0.5)
        let inventoryAfter = DialogueTightnessMetrics.percentile(inventoryMatched.map(\.attackMs), 0.5)
        let inventoryBadBefore = inventoryNative.filter { abs($0.attackMs) > 35 }.count
        let inventoryBadAfter = inventoryMatched.filter { abs($0.attackMs) > 35 }.count
        let badBefore = native.filter { abs($0.attackMs) > 35 }.count
        let badAfter = matched.filter { abs($0.attackMs) > 35 }.count
        let summary = "FEEL-TIGHT native=\(native.count) matched=\(matched.count) medianMs=\(before),\(after) over35ms=\(badBefore),\(badAfter) signedMedianMs=\(signedBefore),\(signedAfter) inventory=\(inventoryNative.count),\(inventoryMatched.count) inventorySignedMedianMs=\(inventoryBefore),\(inventoryAfter) inventoryOver35ms=\(inventoryBadBefore),\(inventoryBadAfter)"
        print(summary)
        Attachment.record(summary, named: "feel-tightness.txt")
        #expect(native.count > 100 && matched.count > 100)
        #expect(abs(after - before) <= 2, "\(summary)")
        #expect(badAfter <= badBefore, "\(summary)")
        #expect(abs(signedAfter - signedBefore) <= 2, "\(summary)")
        #expect(inventoryNative.count == inventoryMatched.count && !inventoryNative.isEmpty)
        #expect(abs(inventoryAfter - inventoryBefore) <= 2, "\(summary)")
        let inventoryAbsoluteBefore = DialogueTightnessMetrics.percentile(inventoryNative.map { abs($0.attackMs) }, 0.5)
        let inventoryAbsoluteAfter = DialogueTightnessMetrics.percentile(inventoryMatched.map { abs($0.attackMs) }, 0.5)
        #expect(abs(inventoryAbsoluteAfter - inventoryAbsoluteBefore) <= 2, "\(summary)")
        #expect(inventoryBadAfter <= inventoryBadBefore, "\(summary)")
    }
}
