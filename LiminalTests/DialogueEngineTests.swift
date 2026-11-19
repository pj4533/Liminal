import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// One analysed speech fixture shared by the suite (analysis is pure and deterministic).
private enum Shared {
    static let fixture = DialogueFixtures.speech()
    static let source = fixture.source(contentID: "fixture-speech")
    static let analysis = DialogueEngine.analyze(source, speech: [])
    static let bank = DialogueEngine.bank(analysis, transcript: nil, seed: 11)
}

/// Runs one bank over `takes` drum takes in 8-bar pieces with carried memory.
private func performance(_ bank: DialoguePadBank, seed: UInt64, bpm: Double = 70, takes: Int = 4,
                         earliest: ((DialogueTransportSnapshot, Int) -> Double)? = nil)
    -> (blocks: [DialogueBlock], snapshots: [DialogueTransportSnapshot], plans: [DialoguePerformancePlan]) {
    var memory = DialoguePerformanceMemory()
    var blocks: [DialogueBlock] = []
    var snapshots: [DialogueTransportSnapshot] = []
    var plans: [DialoguePerformancePlan] = []
    let beat = 60 / bpm
    for take in 0..<takes {
        let snapshot = DialogueFixtures.snapshot(bpm: bpm, origin: Double(take) * 64 * beat, phraseAtOrigin: 4 * take,
                                                 takeIndex: take, seed: 3)
        snapshots.append(snapshot)
        for half in 0..<2 {
            let window = snapshot.time(beat: Double(32 * half))..<snapshot.time(beat: Double(32 * (half + 1)))
            let plan = DialogueEngine.perform(bank, snapshot: snapshot, window: window,
                                              earliestStart: earliest?(snapshot, half) ?? window.lowerBound,
                                              memory: &memory, seed: seed &+ UInt64(take * 2 + half))
            plans.append(plan)
            blocks += plan.blocks
        }
    }
    return (blocks, snapshots, plans)
}

private func elements(_ block: DialogueBlock, position: Int) -> [String] {
    block.events.map { "\(position)|\($0.padKey)|\($0.slot)" }
}

private func windowDifference(_ a: [String], _ b: [String]) -> Double {
    let m = max(a.count, b.count)
    guard m > 0 else { return 1 }
    var counts: [String: Int] = [:]
    for e in a { counts[e, default: 0] += 1 }
    var shared = 0
    for e in b where (counts[e] ?? 0) > 0 {
        counts[e]! -= 1
        shared += 1
    }
    return 1 - Double(shared) / Double(m)
}

struct DialogueEngineTests {
    // MARK: Clocks

    @Test func clockMappingsAtNativeAndSlowedRates() throws {
        let buffer = DialogueFixtures.buffer([Float](repeating: 0, count: 48_000), rate: 48_000)
        for rate in [1.0, 0.8] {
            let source = DialogueSource(contentID: "c", cueToken: 1, buffer: buffer, sourceStart: 12.5, rate: rate)
            #expect(source.sourceSeconds(frame: 0) == 12.5)
            #expect(abs(source.sourceSeconds(frame: 48_000) - (12.5 + rate)) < 1e-9)
            for frame in [0, 1, 12_345, 47_999] {
                #expect(source.frame(sourceSeconds: source.sourceSeconds(frame: frame)) == frame)
            }
        }
        let snapshot = DialogueFixtures.snapshot(bpm: 75, origin: 3, nextBPM: 60)
        #expect(abs(snapshot.time(beat: 64) - (3 + 64 * 0.8)) < 1e-9)
        #expect(abs(snapshot.time(beat: 65) - (3 + 64 * 0.8 + 1)) < 1e-9)
        for beat in [0, 10.5, 63.9, 64, 70.25] { #expect(abs(snapshot.beat(time: snapshot.time(beat: beat)) - beat) < 1e-9) }
    }

    // MARK: Hierarchy

    @Test func unitsLieInsideParentsAndNeighboursAreInSourceOrder() throws {
        let analysis = Shared.analysis
        #expect(analysis.units.count > 20)
        let byID = Dictionary(uniqueKeysWithValues: analysis.units.map { ($0.id, $0) })
        for unit in analysis.units {
            #expect(unit.frames.lowerBound >= 0 && unit.frames.upperBound <= analysis.bufferFrames)
            if let p = unit.parentID, let parent = byID[p] {
                #expect(parent.frames.lowerBound <= unit.frames.lowerBound && unit.frames.upperBound <= parent.frames.upperBound,
                        "unit \(unit.id) \(unit.frames) outside parent \(p) \(parent.frames)")
                #expect(parent.level.rawValue < unit.level.rawValue)
            }
            if let next = unit.nextID, let n = byID[next] {
                #expect(n.level == unit.level && n.previousID == unit.id)
                #expect(n.frames.lowerBound >= unit.frames.lowerBound)
            }
            for anchor in unit.stressAnchors { #expect(unit.frames.contains(anchor)) }
            #expect(unit.stressAnchors.count <= 3 && unit.stressAnchors == unit.stressAnchors.sorted())
        }
        let utterances = analysis.units.filter { $0.level == .utterance }
        let accepted = utterances.filter { u in !analysis.rejections.contains { $0.unit == u.id } }
        #expect(accepted.count >= Shared.fixture.sentences.count / 2, "\(accepted.count) of \(Shared.fixture.sentences.count) sentences")
    }

    @Test func phrasesReconstructTheirUtteranceInSourceOrder() throws {
        let analysis = Shared.analysis
        let f = try #require(analysis.features)
        let pauses = f.pauses.map { ($0.lowerBound * f.hop)..<($0.upperBound * f.hop) }
        for utterance in analysis.units where utterance.level == .utterance {
            let children = analysis.units.filter { $0.parentID == utterance.id && $0.level == .phrase }
                .sorted { $0.frames.lowerBound < $1.frames.lowerBound }
            guard let first = children.first, let last = children.last else { continue }
            #expect(first.frames.lowerBound == utterance.frames.lowerBound)
            #expect(last.frames.upperBound == utterance.frames.upperBound)
            for (a, b) in zip(children, children.dropFirst()) {
                #expect(a.frames.upperBound <= b.frames.lowerBound, "duplicated frames between \(a.id) and \(b.id)")
                if a.frames.upperBound < b.frames.lowerBound {
                    let gap = a.frames.upperBound..<b.frames.lowerBound
                    #expect(pauses.contains { $0.lowerBound <= gap.lowerBound && gap.upperBound <= $0.upperBound },
                            "missing frames \(gap) outside a pause")
                }
            }
        }
    }

    @Test func randomSourcesNeverReadOutsideTheBufferOrProduceNonFiniteSamples() throws {
        var rng = MusicRNG(seed: 4242)
        for seed in 0..<50 {
            var o = DialogueFixtures.Options()
            o.seconds = rng.range(4...9)
            o.sampleRate = rng.pick([16_000, 44_100, 48_000])
            o.seed = UInt64(seed)
            o.whisper = rng.chance(0.2)
            o.musicBed = rng.chance(0.3) ? rng.rangeF(0.1...0.6) : 0
            o.secondSpeaker = rng.chance(0.2)
            o.pitch = rng.range(0.8...1.3)
            let fixture = DialogueFixtures.speech(o)
            let source = fixture.source(contentID: "random-\(seed)", sourceStart: rng.range(0...100), rate: rng.pick([1, 0.8]))
            var memory = DialoguePerformanceMemory()
            let snapshot = DialogueFixtures.snapshot(bpm: rng.range(58...82))
            let prepared = DialogueEngine.prepare(source, speech: [], transcript: nil, snapshot: snapshot,
                                                  window: 0..<snapshot.time(beat: 64), earliestStart: 0,
                                                  memory: &memory, seed: UInt64(seed))
            for unit in prepared.analysis.units {
                #expect(unit.frames.lowerBound >= 0 && unit.frames.upperBound <= source.frameCount && unit.frames.count >= 2)
            }
            for pad in prepared.bank?.pads ?? [] {
                #expect(pad.frames.lowerBound >= 0 && pad.frames.upperBound <= source.frameCount)
                let last = DialogueChopRenderer.readPosition(pad, outputFrame: DialogueChopRenderer.outputCount(pad) - 1)
                #expect(last < Double(source.frameCount - 1))
            }
            for chop in prepared.chops {
                let channels = try #require(chop.buffer.floatChannelData)
                #expect(chop.buffer.format == source.buffer.format)
                for c in 0..<Int(chop.buffer.format.channelCount) {
                    for i in 0..<Int(chop.buffer.frameLength) where !channels[c][i].isFinite {
                        Issue.record("non-finite sample in seed \(seed)")
                        break
                    }
                }
                #expect(abs(channels[0][0]) < 1e-6)
            }
        }
    }

    // MARK: Bank

    @Test func bankHasStableRolesInSourceOrder() throws {
        let bank = try #require(Shared.bank)
        print("DIALOGUE-BANK", bank.pads.map { "\($0.padID):\($0.role.rawValue):\($0.level.name):\(String(format: "%.2f", Double($0.frames.lowerBound) / 48_000))+\(String(format: "%.2f", $0.duration)):\($0.transform.name)" })
        #expect(DialogueTuning.bankSize.contains(bank.pads.count))
        #expect(bank.pads.map(\.padID) == Array(bank.pads.indices))
        #expect(bank.pads.map(\.frames.lowerBound) == bank.pads.map(\.frames.lowerBound).sorted())
        let anchors = bank.pads(.anchor)
        #expect(anchors.count == 1 && anchors[0].transform == .native && anchors[0].protected && bank.anchorPadID == anchors[0].padID)
        let siblings = bank.pads(.sibling)
        #expect(siblings.count == 1)
        if case .linkedRate(let s) = siblings[0].transform { #expect((-4.0)...(-2.0) ~= s) } else { Issue.record("sibling is native") }
        #expect(bank.siblingGroups.count == 1 && bank.siblingGroups[0][1] == siblings[0].padID)
        #expect((1...2).contains(bank.pads(.head).count))
        #expect(bank.pads(.answer).count <= 2)
        #expect((2...4).contains(bank.pads(.stab).count))
        #expect(bank.pads(.texture).count <= 1)
        for pad in bank.pads where pad.role == .texture { #expect(!pad.protected) }
        // Same inputs, same bank.
        let again = try #require(DialogueEngine.bank(DialogueEngine.analyze(Shared.source, speech: []), transcript: nil, seed: 11))
        #expect(again.bankID == bank.bankID && again.pads == bank.pads)
        let other = DialogueEngine.bank(Shared.analysis, transcript: nil, seed: 12)
        #expect(other?.pads.count == bank.pads.count)
    }

    @Test func sameSeedGivesTheSamePlan() throws {
        let bank = try #require(Shared.bank)
        let a = performance(bank, seed: 77, takes: 2).blocks
        let b = performance(bank, seed: 77, takes: 2).blocks
        #expect(a.map(\.fingerprint) == b.map(\.fingerprint))
        #expect(a.flatMap(\.events) == b.flatMap(\.events))
        let others = (78..<88).map { performance(bank, seed: UInt64($0), takes: 2).blocks.map(\.fingerprint) }
        #expect(Set(others.map { $0.description }).count > 1)
    }

    // MARK: Rendering

    @Test func renderedAccentOffsetFollowsTheRate() throws {
        let rate = 48_000.0
        var x = [Float](repeating: 0, count: 60_000)
        let start = 20_000, accent = 3_000
        x[start + accent] = 1
        let source = DialogueSource(contentID: "impulse", cueToken: 1, buffer: DialogueFixtures.buffer(x, rate: rate),
                                    sourceStart: 0, rate: 1)
        let analysis = DialogueAnalysis(version: 1, contentID: "impulse", cueToken: 1,
                                        clock: DialogueClock(sourceStart: 0, rate: 1, sampleRate: rate), bufferFrames: x.count,
                                        features: nil, speech: [], units: [], rejections: [])
        for transform in [DialogueTransform.native, .linkedRate(semitones: -3), .linkedRate(semitones: -4), .linkedRate(semitones: 2)] {
            let pad = DialoguePad(padID: 0, unitID: 0, role: .sibling, frames: start..<(start + 10_000), transform: transform,
                                  accentOffset: Double(accent) / rate, duration: 10_000 / rate / transform.playbackRate,
                                  protected: false, text: nil, fadeIn: 96, fadeOut: 480, level: .stab, score: DialogueScore(),
                                  padKey: 1)
            var level: Float?
            let buffer = try #require(DialogueChopRenderer.renderPad(pad, source: source, analysis: analysis, gainDB: 0, level: &level))
            let y = try #require(buffer.floatChannelData?[0])
            let peak = (0..<Int(buffer.frameLength)).max { abs(y[$0]) < abs(y[$1]) }!
            let expected = Double(accent) / transform.playbackRate
            #expect(abs(Double(peak) - expected) <= 1, "\(transform.name): peak \(peak), expected \(expected)")
            #expect(abs(pad.renderedAccentOffset * rate - expected) < 1e-6)
        }
        // Scheduled starts honour the rendered accent offset.
        let bank = try #require(Shared.bank)
        for block in performance(bank, seed: 5, takes: 1).blocks {
            for e in block.events {
                let pad = try #require(bank.pad(e.padID))
                #expect(abs(e.startTime + pad.renderedAccentOffset - e.accentTime) < 1e-9)
            }
        }
    }

    /// The shared bank with every stab lengthened to 0.62 s, so fills choke them.
    private func longStabBank() throws -> DialoguePadBank {
        let bank = try #require(Shared.bank)
        let extra = Int(0.62 * 48_000)
        let pads = bank.pads.map { p -> DialoguePad in
            guard p.role == .stab || p.role == .sibling else { return p }
            let frames = p.frames.lowerBound..<min(Shared.source.frameCount, p.frames.lowerBound + extra)
            return DialoguePad(padID: p.padID, unitID: p.unitID, role: p.role, frames: frames, transform: p.transform,
                               accentOffset: p.accentOffset, duration: Double(frames.count) / 48_000 / p.transform.playbackRate,
                               protected: p.protected, text: p.text, fadeIn: p.fadeIn, fadeOut: p.fadeOut, level: p.level,
                               score: p.score, padKey: p.padKey &+ 1)
        }
        return DialoguePadBank(bankID: bank.bankID &+ 1, analysisVersion: bank.analysisVersion, pads: pads,
                               anchorPadID: bank.anchorPadID, siblingGroups: bank.siblingGroups, sourceID: bank.sourceID,
                               clock: bank.clock, rejections: [], usedTranscript: false, reorder: .sourceOrder,
                               originalOrder: bank.originalOrder, arrangedOrder: bank.arrangedOrder, intendedText: nil)
    }

    @Test func dryVoiceIsExclusiveAndChokesRelease() throws {
        let banks = [try #require(Shared.bank), try longStabBank()]
        var choked = 0
        for seed in 0..<80 {
            let bank = banks[seed % 2]
            let run = performance(bank, seed: UInt64(seed), bpm: seed % 4 < 2 ? 70 : 82, takes: 4)
            let events = run.blocks.flatMap(\.events).sorted { $0.startTime < $1.startTime }
            for (a, b) in zip(events, events.dropFirst()) {
                #expect(a.endTime <= b.startTime + 1e-9, "overlap seed \(seed): \(a.padID)@\(a.startTime) + \(a.duration) > \(b.startTime)")
            }
            for e in events where e.protected { #expect(e.chokeAt == nil, "protected event choked, seed \(seed)") }
            for plan in run.plans where plan.events.contains(where: { $0.chokeAt != nil }) || seed < 4 {
                for chop in DialogueEngine.render(plan, bank: bank, source: Shared.source, analysis: Shared.analysis)
                where chop.event.chokeAt != nil {
                    choked += 1
                    let y = try #require(chop.buffer.floatChannelData?[0])
                    let n = Int(chop.buffer.frameLength)
                    #expect(abs(Double(n) / 48_000 - chop.event.duration) < 2.0 / 48_000)
                    #expect(y[n - 1] == 0)
                    #expect(chop.event.startTime + Double(n) / 48_000 <= chop.event.chokeAt! - 0.0019)
                    let release = Int(0.012 * 48_000)
                    let tail = (n - release / 3..<n).map { abs(y[$0]) }.max() ?? 0
                    let before = (max(0, n - 4 * release)..<(n - release)).map { abs(y[$0]) }.max() ?? 0
                    #expect(tail <= before + 1e-6)
                }
            }
        }
        print("DIALOGUE-CHOKES rendered choked statements: \(choked)")
        #expect(choked > 0, "no choke was exercised")
    }

    @Test func occupancyRestsAndFillRunUps() throws {
        let bank = try #require(Shared.bank)
        for seed in 0..<60 {
            let run = performance(bank, seed: UInt64(seed))
            for (take, snapshot) in run.snapshots.enumerated() {
                for half in 0..<2 {
                    let groupStart = snapshot.time(beat: Double(32 * half)), groupEnd = snapshot.time(beat: Double(32 * half + 32))
                    let phrase = 4 * take + 2 * half
                    let events = run.blocks.filter { $0.phrase == phrase || $0.phrase == phrase + 1 }.flatMap(\.events)
                    let occupancy = events.map(\.duration).reduce(0, +) / (groupEnd - groupStart)
                    #expect(occupancy <= 0.55 + 1e-9, "seed \(seed) group \(phrase / 2) occupancy \(occupancy)")
                    let firstAllowed = snapshot.time(beat: Double(32 * half + 2))
                    let lastBar = snapshot.time(beat: Double(32 * half + 28))
                    for e in events {
                        #expect(e.startTime >= firstAllowed - 1e-9, "event in the first 2 beats after a boundary")
                        #expect(e.endTime <= lastBar + 1e-9, "event in the last bar before the fill")
                    }
                    // An empty bar in every 8.
                    let bars = (0..<8).map { b in
                        let lo = snapshot.time(beat: Double(32 * half + 4 * b)), hi = snapshot.time(beat: Double(32 * half + 4 * b + 4))
                        return events.contains { $0.startTime < hi && $0.endTime > lo }
                    }
                    #expect(bars.contains(false))
                    let breakdowns = run.blocks.filter { ($0.phrase == phrase || $0.phrase == phrase + 1) && $0.section == .breakdown }
                    for b in breakdowns { #expect(b.events.count <= 2) }
                    for b in run.blocks where b.phrase == phrase || b.phrase == phrase + 1 { #expect(b.events.count <= 5) }
                    let nonNative = events.filter { !$0.transform.isNative }.count
                    #expect(Double(nonNative) <= 0.4 * Double(max(events.count, 1)) + 1e-9 || events.count < 3,
                            "non-native share \(nonNative) of \(events.count)")
                }
            }
            for block in run.blocks where block.section == .returnTheme {
                let snapshot = run.snapshots[block.phrase / 4]
                let barTwo = snapshot.time(beat: Double(16 * (block.phrase % 4) + 4))
                for e in block.events { #expect(e.startTime >= barTwo - 1e-9, "return theme bar 1 not empty") }
            }
        }
    }

    @Test func cadenceChangesEverySixteenBarsWithOneReusedBank() throws {
        let bank = try #require(Shared.bank)
        var forced = 0, families: [DialogueFamily: Int] = [:], withEvents = 0, total = 0, chokes = 0
        var minimum = 1.0
        for seed in 0..<200 {
            let blocks = performance(bank, seed: UInt64(seed) &* 7919).blocks
            #expect(blocks.count == 16)
            total += blocks.count
            withEvents += blocks.filter { !$0.events.isEmpty }.count
            forced += blocks.filter(\.forcedChange).count
            chokes += blocks.flatMap(\.events).filter { $0.chokeAt != nil }.count
            for b in blocks { families[b.family, default: 0] += 1 }
            let windows = (0..<4).map { n in (0..<4).flatMap { j in elements(blocks[4 * n + j], position: j) } }
            for n in 1..<4 where !windows[n].isEmpty && !windows[n - 1].isEmpty {
                let d = windowDifference(windows[n], windows[n - 1])
                minimum = min(minimum, d)
                #expect(d >= 0.25, "seed \(seed) windows \(n - 1), \(n) differ by \(d)")
            }
            for g in 1..<8 {
                let a = blocks[2 * (g - 1)], b = blocks[2 * g]
                if !a.events.isEmpty && !b.events.isEmpty { #expect(a.family != b.family, "seed \(seed) family repeats at group \(g)") }
            }
            for (a, b) in zip(blocks, blocks.dropFirst()) where !a.events.isEmpty && !b.events.isEmpty {
                #expect(a.events.map { "\($0.padKey)|\($0.slot)" }.sorted() != b.events.map { "\($0.padKey)|\($0.slot)" }.sorted(),
                        "seed \(seed) blocks \(a.phrase) and \(b.phrase) identical")
            }
        }
        print("DIALOGUE-CADENCE minimum 16-bar difference \(minimum), blocks with events \(withEvents)/\(total), forced \(forced), chokes \(chokes), families \(families)")
        #expect(Double(withEvents) >= 0.75 * Double(total))
    }

    @Test func echoRepeatsShareOneBuffer() throws {
        let bank = try #require(Shared.bank)
        var checked = 0
        for seed in 0..<30 where checked < 3 {
            let run = performance(bank, seed: UInt64(seed), takes: 1)
            for plan in run.plans {
                for block in plan.blocks where block.family == .echo {
                    let chops = DialogueEngine.render(plan, bank: bank, source: Shared.source, analysis: Shared.analysis)
                        .filter { $0.event.block == block.phrase }
                    guard chops.count >= 2, chops[0].event.padID == chops[1].event.padID else { continue }
                    #expect(chops[0].buffer === chops[1].buffer)
                    #expect(chops[0].event.transform == chops[1].event.transform)
                    checked += 1
                }
            }
        }
        #expect(checked >= 1, "no echo block found")
    }

    @Test func accentsAvoidKicksAndOneLandsOnTheSnare() throws {
        let bank = try #require(Shared.bank)
        var clear = 0, all = 0, groups = 0, landed = 0
        for seed in 0..<60 {
            let run = performance(bank, seed: UInt64(seed) &* 31)
            for (take, snapshot) in run.snapshots.enumerated() {
                let kicks = snapshot.kicks.filter { $0.confidence >= 0.5 }.map { snapshot.time(beat: $0.beat) }
                let snares = snapshot.snares.map { snapshot.time(beat: $0.beat) }
                for half in 0..<2 {
                    let phrase = 4 * take + 2 * half
                    let events = run.blocks.filter { $0.phrase == phrase || $0.phrase == phrase + 1 }.flatMap(\.events)
                    for e in events {
                        all += 1
                        if kicks.allSatisfy({ abs($0 - e.accentTime) >= 0.050 }) { clear += 1 }
                    }
                    guard !events.isEmpty else { continue }
                    groups += 1
                    if events.contains(where: { e in snares.contains { abs($0 - e.accentTime) <= 0.015 } }) { landed += 1 }
                }
            }
        }
        print("DIALOGUE-TIMING accents clear of kicks \(clear)/\(all), groups with a snare landing \(landed)/\(groups)")
        #expect(Double(clear) >= 0.9 * Double(all))
        #expect(landed == groups)
    }

    @Test func silenceToneAndChoirGiveNoEvents() throws {
        let singing = (0..<60).map { LofiSpeechFocus.Window(range: Double($0) * 0.5..<(Double($0) * 0.5 + 1), speech: 0.1, music: 0.8, singing: 0.9) }
        let cases: [(String, SpeechFixture, [LofiSpeechFocus.Window])] = [
            ("silence", DialogueFixtures.silence(), []), ("tone", DialogueFixtures.tone(), []),
            ("choir", DialogueFixtures.sung(), []), ("choir-classified", DialogueFixtures.sung(), singing),
        ]
        for (name, fixture, windows) in cases {
            var memory = DialoguePerformanceMemory()
            let snapshot = DialogueFixtures.snapshot(bpm: 70)
            let prepared = DialogueEngine.prepare(fixture.source(contentID: name), speech: windows, transcript: nil, snapshot: snapshot,
                                                  window: 0..<snapshot.time(beat: 64), earliestStart: 0, memory: &memory, seed: 1)
            #expect(prepared.plan.events.isEmpty, "\(name) produced \(prepared.plan.events.count) events")
            #expect(prepared.chops.isEmpty)
            if prepared.bank == nil { #expect(prepared.plan.blocks.allSatisfy { $0.noDialogue }) }
        }
    }

    @Test func lateStartDropsWholeGesturesAndBeginsAtTheNextBar() throws {
        let bank = try #require(Shared.bank)
        for seed in 0..<40 {
            let snapshot = DialogueFixtures.snapshot(bpm: 70)
            let earliest = snapshot.time(beat: 5.3)
            var memory = DialoguePerformanceMemory()
            let plan = DialogueEngine.perform(bank, snapshot: snapshot, window: 0..<snapshot.time(beat: 32), earliestStart: earliest,
                                              memory: &memory, seed: UInt64(seed))
            for e in plan.events { #expect(e.startTime >= snapshot.time(beat: 8) - 1e-9) }
            for block in plan.blocks where block.family == .echo {
                let heads = block.events.filter { $0.role == .head || $0.role == .answer }
                #expect(heads.count != 1, "echo gesture split by the late start")
            }
            let late = DialogueEngine.perform(bank, snapshot: snapshot, window: 0..<snapshot.time(beat: 32),
                                              earliestStart: snapshot.time(beat: 40), memory: &memory, seed: UInt64(seed))
            #expect(late.events.isEmpty)
        }
    }

    // MARK: Transcript and reorder guards

    private func words(_ text: String, confidence: Float? = 0.9, gap: Int = 2_400) -> [DialogueWordSpan] {
        var frame = 1_000
        return text.split(separator: " ").enumerated().map { i, w in
            defer { frame += 9_600 + (w.hasSuffix(",") ? 8_000 : gap) }
            return DialogueWordSpan(index: i, text: String(w), frames: frame..<(frame + 9_600), confidence: confidence)
        }
    }

    @Test func protectedSpansCoverGrammaticalUnits() throws {
        func covered(_ text: String, _ indices: ClosedRange<Int>) -> Bool {
            DialogueReorderGuard.protectedSpans(words(text)).contains { $0.lowerBound <= indices.lowerBound && indices.upperBound < $0.upperBound }
        }
        #expect(covered("we did not stop the music", 2...3), "negation with predicate")
        #expect(covered("Johnny Carson walked in, the band played on", 0...1), "name")
        #expect(covered("the old house stood empty", 0...2), "determiner with noun")
        #expect(covered("she runs every morning", 0...1), "pronoun with verb")
        #expect(covered("they found seven dollars", 2...3), "number with noun")
        #expect(covered("the music ended there", 0...1))
        let low = DialogueReorderGuard.protectedSpans(words("keep moving now", confidence: 0.2))
        #expect(low.contains { $0 == 0..<3 }, "uncertain words are protected whole")
    }

    private func guarded(_ sentence: String, confidence: Float? = 0.92) throws -> (DialogueReorder, DialoguePadBank?) {
        var o = DialogueFixtures.Options()
        o.seconds = 9
        o.sentences = [sentence]
        let fixture = DialogueFixtures.speech(o)
        let source = fixture.source(contentID: sentence)
        let analysis = DialogueEngine.analyze(source, speech: [])
        let transcript = DialogueFixtures.transcript(fixture, confidence: confidence)
        let refined = DialogueHierarchy.refine(analysis, transcript: transcript)
        let reorder = DialogueReorderGuard.arrange(words: refined.words, units: refined.units, analysis: analysis,
                                                   excluded: Set(refined.rejections.map(\.unit)))
        return (reorder, DialogueEngine.bank(analysis, transcript: transcript, seed: 3))
    }

    @Test func reorderGuardsKeepMeaningConservative() throws {
        let (independent, bank) = try guarded("the night was cold, the band played on.")
        print("DIALOGUE-REORDER independent clauses: \(independent) text \(bank?.intendedText ?? "-")")
        #expect(independent.template == .exchangeClauses, "two independent clauses can be exchanged")
        #expect(bank?.usedTranscript == true)
        let (subordinate, _) = try guarded("when the lights go down, we keep moving.")
        #expect(subordinate.template != .exchangeClauses, "subordinator blocks the exchange")
        let (negation, _) = try guarded("we did not stop, the night went on.")
        #expect(negation.template != .exchangeClauses, "negation at the join blocks the exchange")
        let (pronoun, _) = try guarded("the band came in, they played all night.")
        #expect(pronoun.template != .exchangeClauses, "anaphoric pronoun blocks the exchange")
        let (low, lowBank) = try guarded("the night was cold, the band played on.", confidence: 0.3)
        #expect(low == .sourceOrder, "low confidence gives source order")
        #expect(lowBank?.reorder == .sourceOrder)
        let plain = try #require(Shared.bank)
        #expect(plain.reorder == .sourceOrder && !plain.usedTranscript && plain.arrangedOrder == plain.originalOrder)
        #expect(DialogueReorderGuard.arrange(transcript: nil, units: Shared.analysis.units, analysis: Shared.analysis) == .sourceOrder)
    }

    @Test func protectedSpansAreNeverCutByPads() throws {
        var o = DialogueFixtures.Options()
        o.seconds = 10   // each sentence once: a 3-gram heard three times is dropped as a hallucination
        o.sentences = ["Johnny Carson walked in, the band played on.", "we did not stop, the night went on."]
        let fixture = DialogueFixtures.speech(o)
        let analysis = DialogueEngine.analyze(fixture.source(contentID: "names"), speech: [])
        let transcript = DialogueFixtures.transcript(fixture)
        let refined = DialogueHierarchy.refine(analysis, transcript: transcript)
        let spans = DialogueReorderGuard.protectedSpans(refined.words).map {
            refined.words[$0.lowerBound].frames.lowerBound..<refined.words[$0.upperBound - 1].frames.upperBound
        }
        #expect(!spans.isEmpty)
        let bank = try #require(DialogueEngine.bank(analysis, transcript: transcript, seed: 2))
        for pad in bank.pads {
            for s in spans {
                #expect(!(s.lowerBound < pad.frames.lowerBound && pad.frames.lowerBound < s.upperBound), "pad \(pad.padID) starts inside \(s)")
                #expect(!(s.lowerBound < pad.frames.upperBound && pad.frames.upperBound < s.upperBound), "pad \(pad.padID) ends inside \(s)")
            }
        }
    }

    @Test func hallucinatedOrImplausibleWordsAreDropped() throws {
        let fixture = Shared.fixture
        let analysis = Shared.analysis
        func transcript(_ words: [DialogueTranscript.Word]) -> DialogueTranscript {
            DialogueTranscript(locale: "en_US", modelVersion: "fixture", words: words)
        }
        let real = DialogueFixtures.transcript(fixture).words
        // A 3-gram repeated three times.
        var repeated = Array(real.prefix(6))
        var t = real[6].start
        for _ in 0..<3 {
            for w in ["keep", "on", "moving"] {
                repeated.append(.init(text: w, start: t, end: t + 0.2, confidence: 0.9))
                t += 0.25
            }
        }
        let (accepted, dropped) = DialogueHierarchy.acceptedWords(transcript(repeated), analysis: analysis)
        #expect(!accepted.contains { $0.text == "moving" })
        #expect(dropped.values.filter { $0 == "repeatedGram" }.count == 9)
        #expect(accepted.count == 6)
        // Too short and too long words.
        let odd = [DialogueTranscript.Word(text: "a", start: 1, end: 1.02, confidence: 0.9),
                   DialogueTranscript.Word(text: "long", start: 2, end: 4.5, confidence: 0.9)]
        #expect(DialogueHierarchy.acceptedWords(transcript(odd), analysis: analysis).words.isEmpty)
        // More than seven words per second.
        let fast = (0..<12).map { i in DialogueTranscript.Word(text: "w\(i)", start: 1 + Double(i) * 0.08, end: 1 + Double(i) * 0.08 + 0.07, confidence: 0.9) }
        #expect(DialogueHierarchy.acceptedWords(transcript(fast), analysis: analysis).words.isEmpty)
        // Zero speech weight.
        let music = [LofiSpeechFocus.Window(range: 0..<40, speech: 0.05, music: 0.9, singing: 0.8)]
        let masked = DialogueAnalysis(version: 1, contentID: "m", cueToken: 1, clock: analysis.clock, bufferFrames: analysis.bufferFrames,
                                      features: analysis.features, speech: music, units: analysis.units, rejections: analysis.rejections)
        #expect(DialogueHierarchy.acceptedWords(DialogueFixtures.transcript(fixture), analysis: masked).words.isEmpty)
        // Low confidence: words accepted, no unit transcribed.
        let unsure = DialogueHierarchy.refine(analysis, transcript: DialogueFixtures.transcript(fixture, confidence: 0.3))
        #expect(unsure.transcribedUnits.isEmpty)
        let sure = DialogueHierarchy.refine(analysis, transcript: DialogueFixtures.transcript(fixture, confidence: 0.9))
        #expect(!sure.transcribedUnits.isEmpty)
        // Film seconds map through the source clock (slowed decode).
        let slowed = DialogueEngine.analyze(fixture.source(contentID: "slow", sourceStart: 40, rate: 0.8), speech: [])
        let mapped = DialogueHierarchy.acceptedWords(DialogueFixtures.transcript(fixture, sourceStart: 40, rate: 0.8), analysis: slowed).words
        let first = try #require(mapped.first)
        #expect(abs(Double(first.frames.lowerBound) / 48_000 - fixture.words[first.index].start) < 0.07)
    }

    @Test(.responsivePool) func fixtureTranscriptProviderRespectsTheDeadline() async throws {
        let transcript = DialogueFixtures.transcript(Shared.fixture)
        let clock = ContinuousClock()
        let quick = FixtureTranscriptProvider(transcript, delay: .milliseconds(10))
        #expect(await quick.transcript(for: Shared.source, deadline: clock.now.advanced(by: .seconds(2))) == transcript)
        let slow = FixtureTranscriptProvider(transcript, delay: .seconds(5))
        let start = clock.now
        #expect(await slow.transcript(for: Shared.source, deadline: start.advanced(by: .milliseconds(50))) == nil)
        #expect(clock.now - start < .seconds(1))
        #expect(await DialogueTranscription.makeProvider().transcript(for: Shared.source, deadline: clock.now) == nil)
    }

    // MARK: Budget and logs

    @Test(.responsivePool) func prepareFinishesWithinTheStageBudget() throws {
        let fixture = DialogueFixtures.speech(DialogueFixtures.Options(seconds: 30, seed: 9))
        let snapshot = DialogueFixtures.snapshot(bpm: 70)
        var best = DialogueEngine.Timings(analyzeMs: .infinity)
        for _ in 0..<3 {
            var memory = DialoguePerformanceMemory()
            let prepared = DialogueEngine.prepare(fixture.source(contentID: "budget"), speech: [], transcript: nil, snapshot: snapshot,
                                                  window: 0..<snapshot.time(beat: 32), earliestStart: 0, memory: &memory, seed: 1)
            #expect(!prepared.chops.isEmpty)
            if prepared.timings.totalMs < best.totalMs { best = prepared.timings }
            let log = DialogueEngine.log(prepared.plan, bank: prepared.bank)
            #expect(JSONSerialization.isValidJSONObject(log))
        }
        print("DIALOGUE-TIMINGS 30 s at 48 kHz: \(best.dictionary)")
        #expect(best.totalMs < 400)
    }
}
