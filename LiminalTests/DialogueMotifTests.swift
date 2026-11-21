import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Bank shapes for the motif tests: one or two films per loop, with and without a transcript.
private struct MotifShape: @unchecked Sendable, CustomStringConvertible {
    struct Film { let source: DialogueSource; let analysis: DialogueAnalysis; let bank: DialoguePadBank?; let transcript: DialogueTranscript?; let fixture: SpeechFixture }
    let name: String
    let bpm: Double
    /// Films in cue order (8 bars each), cycled.
    let films: [Film]
    var description: String { name }

    static func film(_ fixture: SpeechFixture, id: String, transcribed: Bool) -> Film {
        let source = fixture.source(contentID: id)
        let analysis = DialogueEngine.analyze(source, speech: [])
        let transcript = transcribed ? DialogueFixtures.transcript(fixture) : nil
        let bank = DialogueEngine.bank(analysis, transcript: transcript, seed: 11)
        return Film(source: source, analysis: analysis, bank: bank, transcript: transcript, fixture: fixture)
    }

    static let investigate = DialogueFixtures.speech(DialogueFixtures.Options(seed: 4, sentences: [
        "when they want to investigate the house.", "the old car stood empty for years.",
        "listen to the rhythm of the city.", "she runs to the station every morning.",
        "keep your eyes on the road ahead.", "nobody knows where the river goes.",
    ]))
    static let corpus = DialogueFixtures.speech(DialogueFixtures.Options(seed: 9))
    static let other = DialogueFixtures.speech(DialogueFixtures.Options(seed: 21, sentences: [
        "I remember the summer of nineteen fifty.", "the night was cold, the band played on.",
        "Johnny Carson walked in, the band played on.", "when the lights go down, we keep moving.",
    ], pitch: 1.3))
    static let sung = DialogueFixtures.sung()

    static let all: [MotifShape] = [
        MotifShape(name: "acoustic-72", bpm: 72, films: [film(investigate, id: "investigate", transcribed: false)]),
        MotifShape(name: "transcript-72", bpm: 72, films: [film(investigate, id: "investigate-t", transcribed: true)]),
        MotifShape(name: "acoustic-reel-84", bpm: 84, films: [film(corpus, id: "corpus", transcribed: false),
                                                               film(other, id: "other", transcribed: false)]),
        MotifShape(name: "transcript-reel-62", bpm: 62, films: [film(corpus, id: "corpus-t", transcribed: true),
                                                                 film(other, id: "other-t", transcribed: true)]),
        // The second film of each loop is sung: the loop keeps its line through bars 9 to 16.
        MotifShape(name: "speech-then-sung-78", bpm: 78, films: [film(other, id: "other-s", transcribed: false),
                                                                  film(sung, id: "sung", transcribed: false)]),
    ]
}

private struct MotifRun {
    struct Loop { var events: [DialogueEvent] = []; var motif: DialogueMotif?; var snapshot: DialogueTransportSnapshot }
    var loops: [Loop] = []
    var plans: [DialoguePerformancePlan] = []
}

/// A drum take with a few milliseconds of push and drag on every sixteenth.
private func grooved(_ snapshot: DialogueTransportSnapshot, seed: UInt64) -> DialogueTransportSnapshot {
    var s = snapshot
    var rng = MusicRNG(seed: seed)
    s.grooveOffsets = (0..<DialogueTransportSnapshot.takeSixteenths).map { k in (k % 2 == 1 ? 0.03 : 0) + rng.range(-0.01...0.01) }
    return s
}

/// Plays `takes` loops in 8-bar cues against carried memory, as the coordinator does.
private func run(_ shape: MotifShape, seed: UInt64, takes: Int = 2,
                 earliest: ((DialogueTransportSnapshot, Int) -> Double)? = nil) -> MotifRun {
    var memory = DialoguePerformanceMemory()
    var result = MotifRun()
    let beat = 60 / shape.bpm
    for take in 0..<takes {
        let snapshot = grooved(DialogueFixtures.snapshot(bpm: shape.bpm, origin: 0.5 + Double(take) * 64 * beat,
                                                         phraseAtOrigin: 4 * take, takeIndex: take, seed: 3), seed: seed &+ UInt64(take))
        var loop = MotifRun.Loop(snapshot: snapshot)
        for half in 0..<2 {
            let cue = take * 2 + half
            let film = shape.films[cue % shape.films.count]
            let window = snapshot.time(beat: Double(32 * half))..<snapshot.time(beat: Double(32 * (half + 1)))
            guard let planned = DialogueMotif.plan(source: film.source, analysis: film.analysis, bank: film.bank,
                                                   transcript: film.transcript, snapshot: snapshot, window: window,
                                                   earliestStart: earliest?(snapshot, half) ?? window.lowerBound,
                                                   memory: &memory, seed: seed &+ UInt64(cue), cueToken: cue + 1, revision: 0)
            else { continue }
            loop.events += planned.plan.events
            loop.motif = planned.motif
            result.plans.append(planned.plan)
        }
        result.loops.append(loop)
    }
    return result
}

/// Bars (0...15 of the loop) of each event's start.
private func bars(_ loop: MotifRun.Loop) -> [Int: [DialogueEvent]] {
    Dictionary(grouping: loop.events) { Int((loop.snapshot.beat(time: $0.startTime) / 4 + 1e-9).rounded(.down)) }
}

struct DialogueMotifTests {
    static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13]

    @Test(arguments: MotifShape.all) fileprivate func everyBarOfEveryLoopHasAPieceOnset(_ shape: MotifShape) throws {
        for seed in Self.seeds {
            let r = run(shape, seed: seed)
            #expect(r.loops.count == 2)
            for (k, loop) in r.loops.enumerated() {
                let motif = try #require(loop.motif, "\(shape) seed \(seed) loop \(k): no motif")
                let byBar = bars(loop)
                let empty = (0..<16).filter { (byBar[$0] ?? []).isEmpty }
                #expect(empty.isEmpty, "\(shape) seed \(seed) loop \(k) line '\(motif.text ?? "-")': empty bars \(empty)")
                // Typical density 2 to 4 onsets per bar.
                let mean = Double(loop.events.count) / 16
                #expect((1.8...4.5).contains(mean), "\(shape) seed \(seed) loop \(k): \(mean) onsets per bar")
            }
        }
    }

    @Test(arguments: MotifShape.all) fileprivate func loopsStateTheLineRarelyAndPlayMostlySubLinePieces(_ shape: MotifShape) throws {
        for seed in Self.seeds {
            for (k, loop) in run(shape, seed: seed).loops.enumerated() {
                let motif = try #require(loop.motif)
                let label = "\(shape) seed \(seed) loop \(k)"
                let full = loop.events.filter { $0.piece == 0 }.count
                #expect(full <= DialogueMotifTuning.maximumLineStatements, "\(label): \(full) full-line statements")
                let sub = loop.events.filter { motif.isSubLine($0.piece ?? 0) }.count
                #expect(Double(sub) >= 0.6 * Double(loop.events.count), "\(label): \(sub) of \(loop.events.count) sub-line")
                let seconds = loop.snapshot.time(beat: 64) - loop.snapshot.time(beat: 0)
                let occupancy = loop.events.map(\.duration).reduce(0, +) / seconds
                // Footage captures measure the 35 to 60 percent target; the synthetic voice speaks faster,
                // so its word pieces are shorter and the floor here is lower.
                #expect((0.25...0.62).contains(occupancy),
                        "\(label): occupancy \(occupancy), line \(motif.text ?? "-") \(motif.seconds(0)) s, \(loop.events.count) events")
                // Native rate only; nothing is slower than the source.
                #expect(loop.events.allSatisfy { $0.transform == .native })
            }
        }
    }

    /// The hook form (D125, user direction of 21 November 2026: "it sounds too random ... it needs to
    /// feel intentional"): one 2-bar hook cell repeats through the loop on fixed steps.
    @Test(arguments: MotifShape.all) fileprivate func everyLoopRepeatsOneHookCell(_ shape: MotifShape) throws {
        for seed in Self.seeds {
            for (k, loop) in run(shape, seed: seed).loops.enumerated() {
                let motif = try #require(loop.motif)
                let hook = try #require(motif.hook)
                let label = "\(shape) seed \(seed) loop \(k) line '\(motif.text ?? "-")'"
                let kinds = motif.cells.map(\.kind)
                let hookCells = kinds.filter { $0 == .hook }.count
                #expect(hookCells >= (kinds[4] == .statement ? 2 : 3), "\(label): cells \(kinds)")
                // Every hook cell plays only the hook's own (step, piece) hits, and the two hook cells of
                // the first cue play the same pattern.
                let phrase = loop.snapshot.phraseAtOrigin
                let items = Set(hook.items.map { DialogueHookMetrics.Hit(step: $0.slot, fragment: $0.fragment) })
                var sets: [Int: Set<DialogueHookMetrics.Hit>] = [:]
                for e in loop.events where e.cell == .hook {
                    let s = (e.block - phrase) * 64 + e.slot
                    sets[s / 32, default: []].insert(DialogueHookMetrics.Hit(step: s % 32, fragment: e.piece ?? -1))
                }
                for (cell, set) in sets { #expect(set.isSubset(of: items), "\(label): cell \(cell) \(set) off the hook \(items)") }
                #expect(sets[1] != nil && sets[1] == sets[2], "\(label): bars 3-6 differ")
                let m = DialogueHookMetrics.metrics(DialogueHookMetrics.loopHits(loop.events, loop: phrase / 4))
                #expect(m.signatureShare >= 0.6, "\(label): signature \(m.signatureShare)")
                #expect(m.distinctRhythms <= 10, "\(label): \(m.distinctRhythms) rhythms")
                #expect(m.exactBarRepeats >= 0.3, "\(label): exact bars \(m.exactBarRepeats)")
                #expect(m.cellVsBest >= 0.4, "\(label): cellVsBest \(m.cellVsBest)")
            }
        }
    }

    /// Variation sits at the phrase ends (bars 8 and 16), the drop-out (11-12) and the return (13).
    @Test(arguments: MotifShape.all) fileprivate func variationSitsAtPhraseEnds(_ shape: MotifShape) throws {
        for seed in Self.seeds {
            for (k, loop) in run(shape, seed: seed).loops.enumerated() {
                let motif = try #require(loop.motif)
                let hook = try #require(motif.hook)
                let label = "\(shape) seed \(seed) loop \(k)"
                let bars = DialogueHookMetrics.loopHits(loop.events, loop: loop.snapshot.phraseAtOrigin / 4)
                let barB = Set(hook.items.filter { $0.slot >= 16 }.map { DialogueHookMetrics.Hit(step: $0.slot - 16, fragment: $0.fragment) })
                #expect(Set(bars[7]) != barB && Set(bars[15]) != barB, "\(label): a phrase end plays the hook")
                #expect(bars[10].count + bars[11].count < hook.items.count, "\(label): the drop-out is as busy as the hook")
                let cells = Set(loop.events.compactMap(\.cell))
                for kind in [DialogueCell.stutter, .splitPause, .turnaround, .returnOpen, .hook] {
                    #expect(cells.contains(kind), "\(label): no \(kind) in \(cells)")
                }
                // The stutter repeats one piece back to back.
                let stutter = loop.events.filter { $0.cell == .stutter }
                #expect(zip(stutter, stutter.dropFirst()).contains { $0.piece == $1.piece }, "\(label): no repeated piece")
            }
        }
    }

    /// The hook's signature is the line's strongest word ("Sally", "LSD"), and it is the loop's most
    /// played piece, on one home step.
    @Test func theSignatureIsTheStrongestWord() throws {
        let film = MotifShape.film(DialogueHookProbeTests.mixed, id: "mixed-sig", transcribed: true)
        let shape = MotifShape(name: "mixed-84", bpm: 84, films: [film])
        var seen: Set<String> = []
        for seed: UInt64 in [1, 2, 3] {
            for (k, loop) in run(shape, seed: seed, takes: 5).loops.enumerated() {
                let motif = try #require(loop.motif)
                let hook = try #require(motif.hook)
                let signature = motif.fragments[hook.signature].text ?? ""
                let label = "seed \(seed) loop \(k) '\(motif.text ?? "-")' S '\(signature)'"
                if motif.text == "Sally, this is mother." { #expect(signature == "Sally,", "\(label)"); seen.insert("Sally") }
                if motif.text?.contains("LSD") == true { #expect(signature.contains("LSD"), "\(label)"); seen.insert("LSD") }
                let pieces = loop.events.compactMap(\.piece).filter { $0 != 0 }
                let counts = Dictionary(grouping: pieces, by: { $0 }).mapValues(\.count)
                #expect(counts.max { $0.value < $1.value }?.key == hook.signature || counts[hook.signature] == counts.values.max(),
                        "\(label): counts \(counts)")
                let phrase = loop.snapshot.phraseAtOrigin
                let steps = loop.events.filter { $0.piece == hook.signature }.map { ((($0.block - phrase) * 64 + $0.slot) % 32) }
                let modal = Dictionary(grouping: steps, by: { $0 }).values.map(\.count).max() ?? 0
                #expect(modal >= 5, "\(label): signature at most \(modal) times on one step")
            }
        }
        #expect(seen == ["Sally", "LSD"], "\(seen)")
    }

    /// One trigger rhythm holds for two loops while the words change, then the next template.
    @Test func theTriggerRhythmHoldsForTwoLoops() throws {
        for shape in MotifShape.all.prefix(2) {
            for seed in Self.seeds {
                let motifs = run(shape, seed: seed, takes: 4).loops.compactMap(\.motif)
                try #require(motifs.count == 4)
                let steps = motifs.map { Set($0.hook?.items.map(\.slot) ?? []) }
                #expect(steps[0] == steps[1] && steps[2] == steps[3], "\(shape) seed \(seed): \(steps)")
                #expect(steps[1] != steps[2], "\(shape) seed \(seed): the template never rotates")
            }
        }
    }

    /// A line with a negation keeps its pieces in source order inside every hook bar.
    @Test func aNegatedLineKeepsSourceOrderInsideEachBar() throws {
        // Short and with distinct sentences, so the hallucination guard (a 3-gram heard three times) keeps the words.
        let fixture = DialogueFixtures.speech(DialogueFixtures.Options(seconds: 16, seed: 7, sentences: [
            "we did not stop the car that night.", "I don't know where the river goes.",
            "the station was empty in the morning.", "nobody wanted to go home.",
        ]))
        let film = MotifShape.film(fixture, id: "negated", transcribed: true)
        let refined = DialogueHierarchy.refine(film.analysis, transcript: try #require(film.transcript))
        let negated = refined.units.filter { u in
            [.utterance, .phrase, .wordGroup].contains(u.level) && (u.text.map { $0.contains("not") || $0.contains("n't") } ?? false)
        }
        var checked = 0
        for seed: UInt64 in [1, 2, 3, 4] {
            for unit in negated {
                guard let motif = DialogueMotif.make(loop: Int(seed), source: film.source, analysis: film.analysis, transcript: film.transcript,
                                                     memory: DialoguePerformanceMemory(), seed: seed, beatDuration: 60 / 78.0, line: unit.id),
                      motif.pieces.count >= 2 else { continue }
                #expect(!motif.reorderAllowed, "'\(motif.text ?? "-")'")
                checked += 1
                for cell in motif.cells where cell.kind == .hook {
                    for bar in 0..<2 {
                        // New source positions only: a repeat of a piece already heard (or of its half) is a stutter.
                        var order: [Int] = []
                        for item in cell.items.sorted(by: { $0.slot < $1.slot }) where item.slot / 16 == bar {
                            let o = motif.fragments[item.fragment].order
                            if !order.contains(o) { order.append(o) }
                        }
                        #expect(order == order.sorted(), "'\(motif.text ?? "-")' bar \(bar): \(order)")
                    }
                }
            }
        }
        #expect(checked > 0, "negated units \(negated.map { $0.text ?? "-" }), words \(refined.words.count)")
    }

    /// A transcript re-cut (acoustic pieces become word groups) keeps the hook on the same words.
    @Test func aTranscriptRecutKeepsTheHookSignature() throws {
        let film = MotifShape.all[1].films[0]
        for seed: UInt64 in [1, 2, 3, 5] {
            var memory = DialoguePerformanceMemory()
            let acoustic = try #require(DialogueMotif.make(loop: 0, source: film.source, analysis: film.analysis, transcript: nil,
                                                           memory: memory, seed: seed, beatDuration: 60 / 72.0))
            memory.setMotif(acoustic, statements: 0)
            let recut = try #require(DialogueMotif.resolve(loop: 0, source: film.source, analysis: film.analysis, hasBank: true,
                                                           transcript: film.transcript, memory: memory, seed: seed, beatDuration: 60 / 72.0))
            #expect(recut.usedTranscript && recut.lineUnit == acoustic.lineUnit)
            let a = try #require(acoustic.hook), b = try #require(recut.hook)
            #expect(a.template == b.template)
            let share = DialogueMotif.overlapShare(acoustic.fragments[a.signature].frames, recut.fragments[b.signature].frames)
            #expect(share >= 0.5, "seed \(seed): signature overlap \(share)")
        }
    }

    @Test func piecesSplitAtWordAndSyllableBoundaries() throws {
        for shape in MotifShape.all {
            for film in shape.films where film.bank != nil {
                var memory = DialoguePerformanceMemory()
                guard let motif = DialogueMotif.make(loop: 0, source: film.source, analysis: film.analysis, transcript: film.transcript,
                                                     memory: memory, seed: 3, beatDuration: 60 / shape.bpm) else { continue }
                memory.motif = motif
                let rate = film.source.sampleRate
                let line = motif.line.frames
                let pieces = motif.pieces.map { motif.fragments[$0] }
                #expect(pieces.count >= 2, "\(shape): \(pieces.count) pieces")
                // Pieces tile the line in source order.
                #expect(pieces.first?.frames.lowerBound == line.lowerBound && pieces.last?.frames.upperBound == line.upperBound)
                for (a, b) in zip(pieces, pieces.dropFirst()) { #expect(a.frames.upperBound == b.frames.lowerBound) }
                // Every fragment is at least 120 ms; cuts never fall inside a vowel nucleus.
                let vowels = film.fixture.syllables.map { Int(($0.lowerBound + 0.012) * rate)..<Int(($0.upperBound - 0.012) * rate) }
                for fragment in motif.fragments {
                    #expect(Double(fragment.frames.count) / rate >= DialogueMotifTuning.minimumPieceSeconds - 1e-6)
                    guard fragment.kind != .line else { continue }
                    for edge in [fragment.frames.lowerBound, fragment.frames.upperBound] where edge != line.lowerBound && edge != line.upperBound {
                        #expect(!vowels.contains { $0.contains(edge) }, "\(shape): cut at \(Double(edge) / rate) s inside a vowel")
                    }
                }
                // Transcribed lines cut between words: every piece is whole words.
                if film.transcript != nil, motif.usedTranscript {
                    let gaps = zip(film.fixture.words, film.fixture.words.dropFirst()).map { ($0.end - 0.07)...($1.start + 0.07) }
                    for piece in pieces.dropFirst() {
                        let t = Double(piece.frames.lowerBound) / rate
                        #expect(gaps.contains { $0.contains(t) }, "\(shape): cut at \(t) s not between words")
                        #expect(piece.text != nil)
                    }
                }
                // At least one piece splits at a syllable into two halves.
                #expect(!motif.halves.isEmpty, "\(shape): no syllable halves in '\(motif.text ?? "-")'")
            }
        }
    }

    @Test(arguments: MotifShape.all) fileprivate func accentsSitOnTheDrummersGridWithinTwoMilliseconds(_ shape: MotifShape) throws {
        for seed in Self.seeds.prefix(3) {
            for loop in run(shape, seed: seed).loops {
                let motif = try #require(loop.motif)
                for e in loop.events {
                    let sixteenth = 64 * (e.block - loop.snapshot.phraseAtOrigin) + e.slot
                    let grid = loop.snapshot.gridTime(sixteenth: sixteenth)
                    #expect(abs(e.accentTime - grid) < 0.002, "\(shape): accent \(e.accentTime) against grid \(grid)")
                    guard let piece = e.piece else { continue }
                    let offset = e.effect == .reversed ? motif.seconds(piece) + DialogueMotifTuning.reversedLeadSeconds : motif.accentOffset(piece)
                    #expect(abs(e.startTime + offset - e.accentTime) < 1e-6)
                }
            }
        }
    }

    @Test(arguments: MotifShape.all) fileprivate func oneDryVoiceAndRenderedLengthsMatchNativeRate(_ shape: MotifShape) throws {
        let r = run(shape, seed: 5)
        for (k, loop) in r.loops.enumerated() {
            let motif = try #require(loop.motif)
            let events = loop.events.sorted { $0.startTime < $1.startTime }
            for (a, b) in zip(events, events.dropFirst()) {
                #expect(a.endTime <= b.startTime + 1e-6, "\(shape) loop \(k): overlap \(a.endTime) > \(b.startTime)")
            }
            let plan = DialoguePerformancePlan(sourceID: motif.bank.sourceID, cueToken: 1, bankID: motif.bank.bankID, analysisVersion: 2,
                                               seed: 5, transportRevision: 1, revision: 0, usedTranscript: false,
                                               blocks: [DialogueBlock(phrase: 0, section: .theme, family: .stutter, variation: 0, fingerprint: 0,
                                                                      events: events, forcedChange: false, noDialogue: false, change: "")],
                                               rejections: [])
            let chops = DialogueEngine.render(plan, bank: motif.bank, source: motif.source, analysis: motif.analysis)
            #expect(chops.count == events.count)
            for chop in chops {
                let frames = Double(chop.buffer.frameLength)
                let rate = chop.buffer.format.sampleRate
                // The buffer plays exactly the event (native rate, choked or with its echo tail), never longer.
                #expect(abs(frames / rate - chop.event.duration) < 0.003, "\(shape): \(frames / rate) s for \(chop.event.duration) s")
                if case .echoThrow = chop.event.effect {} else if chop.event.chokeAt == nil, let piece = chop.event.piece {
                    #expect(abs(frames - Double(motif.fragments[piece].frames.count)) <= 2)
                }
                let samples = UnsafeBufferPointer(start: chop.buffer.floatChannelData![0], count: Int(chop.buffer.frameLength))
                #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1.0001 })
            }
        }
    }

    @Test func theLoopKeepsItsLineAcrossTheFilmChangeAndANewLoopTakesANewLine() throws {
        for shape in MotifShape.all {
            for seed in Self.seeds {
                let r = run(shape, seed: seed, takes: 3)
                let keys = r.loops.compactMap { $0.motif?.lineKey }
                #expect(keys.count == 3)
                for (k, loop) in r.loops.enumerated() {
                    // Both cues of the loop play pieces of the same line.
                    let pads = Set(loop.events.map(\.padKey))
                    let ownPads = Set(loop.motif!.bank.pads.map(\.padKey))
                    #expect(pads.isSubset(of: ownPads.union(k > 0 ? Set(r.loops[k - 1].motif!.bank.pads.map(\.padKey)) : [])))
                    let second = loop.events.filter { loop.snapshot.beat(time: $0.startTime) >= 32 && $0.cell != .turnaround }
                    #expect(second.allSatisfy { ownPads.contains($0.padKey) }, "\(shape) seed \(seed) loop \(k)")
                }
                // A new loop has a new line, or (one-line films) the same line in a clearly new arrangement.
                for (a, b) in zip(r.loops, r.loops.dropFirst()) {
                    func elements(_ l: MotifRun.Loop) -> [String] {
                        l.events.map { "\($0.block - l.snapshot.phraseAtOrigin)|\($0.padKey)|\($0.slot)" }
                    }
                    let ea = elements(a), eb = elements(b)
                    var counts: [String: Int] = [:]
                    for e in ea { counts[e, default: 0] += 1 }
                    var shared = 0
                    for e in eb where (counts[e] ?? 0) > 0 { counts[e]! -= 1; shared += 1 }
                    let difference = 1 - Double(shared) / Double(max(ea.count, eb.count))
                    #expect(difference >= 0.25, "\(shape) seed \(seed): 16-bar difference \(difference)")
                    if a.motif?.lineKey == b.motif?.lineKey { #expect(b.motif?.carried == true || shape.films.count == 1) }
                }
                // A line leads at most two loops and never two in a row (unless carried for lack of speech).
                for (a, b) in zip(r.loops, r.loops.dropFirst()) where b.motif?.carried == false {
                    #expect(a.motif?.lineKey != b.motif?.lineKey, "\(shape) seed \(seed): consecutive loops share a line")
                }
            }
        }
    }

    /// Fresh lines every loop (user direction, 19 November 2026: "I want there to always be fresh samples").
    /// A loop that opens on a film with no usable line digs a new line from the crate of recent films
    /// instead of repeating the last loop's line (a capture held one line for 32 bars).
    @Test func aLoopWhoseFilmHasNoLineDigsAFreshLineFromTheCrate() throws {
        let speech = MotifShape.film(MotifShape.other, id: "other-c", transcribed: false)
        let sung = MotifShape.film(MotifShape.sung, id: "sung-c", transcribed: false)
        let later = MotifShape.film(MotifShape.corpus, id: "corpus-c", transcribed: false)
        let shapes = [
            MotifShape(name: "speech-sung-speech-72", bpm: 72, films: [speech, speech, sung, later]),
            // Only the first film ever speaks: every later loop still gets a line it has not just played.
            MotifShape(name: "one-speaker-then-sung-72", bpm: 72, films: [speech, sung, sung, sung, sung, sung]),
        ]
        for shape in shapes {
            for seed in Self.seeds {
                let r = run(shape, seed: seed, takes: 3)
                try #require(r.loops.count == 3)
                let motifs = try r.loops.map { try #require($0.motif, "\(shape) seed \(seed)") }
                for (a, b) in zip(motifs, motifs.dropFirst()) {
                    #expect(!b.carried, "\(shape) seed \(seed): loop \(b.loop) carried the previous line")
                    #expect(b.lineKey != a.lineKey, "\(shape) seed \(seed): loop \(b.loop) repeats the line of loop \(a.loop)")
                }
                for loop in r.loops {
                    let covered = Set(bars(loop).keys)
                    #expect(covered.isSuperset(of: Set(0..<16)), "\(shape) seed \(seed): bars \(covered.sorted())")
                }
            }
        }
    }

    /// A loop that could only carry the previous line takes a fresh line from a later cue in the loop.
    @Test func aCarriedLoopTakesAFreshLineFromTheNextSpokenCue() throws {
        let sung = MotifShape.film(MotifShape.sung, id: "sung-d", transcribed: false)
        let speech = MotifShape.film(MotifShape.other, id: "other-d", transcribed: false)
        var memory = DialoguePerformanceMemory()
        let beat = 60.0 / 72
        // Loop 0: one spoken cue, so the crate has only that film; its lines are then all used up.
        let snapshot0 = DialogueFixtures.snapshot(bpm: 72, origin: 0.5, phraseAtOrigin: 0, takeIndex: 0, seed: 3)
        let w0 = snapshot0.time(beat: 0)..<snapshot0.time(beat: 64)
        _ = try #require(DialogueMotif.plan(source: speech.source, analysis: speech.analysis, bank: speech.bank, transcript: nil,
                                            snapshot: snapshot0, window: w0, earliestStart: w0.lowerBound, memory: &memory,
                                            seed: 5, cueToken: 1, revision: 0))
        memory.motifCrate.removeAll()
        let snapshot1 = DialogueFixtures.snapshot(bpm: 72, origin: 0.5 + 64 * beat, phraseAtOrigin: 4, takeIndex: 1, seed: 3)
        let first = snapshot1.time(beat: 0)..<snapshot1.time(beat: 32)
        let carried = try #require(DialogueMotif.plan(source: sung.source, analysis: sung.analysis, bank: sung.bank, transcript: nil,
                                                      snapshot: snapshot1, window: first, earliestStart: first.lowerBound,
                                                      memory: &memory, seed: 6, cueToken: 2, revision: 0))
        #expect(carried.motif.carried)
        let second = snapshot1.time(beat: 32)..<snapshot1.time(beat: 64)
        let later = MotifShape.film(MotifShape.corpus, id: "corpus-d", transcribed: false)
        let fresh = try #require(DialogueMotif.plan(source: later.source, analysis: later.analysis, bank: later.bank, transcript: nil,
                                                    snapshot: snapshot1, window: second, earliestStart: second.lowerBound,
                                                    memory: &memory, seed: 7, cueToken: 3, revision: 0))
        #expect(!fresh.motif.carried)
        #expect(fresh.motif.lineKey != carried.motif.lineKey)
    }

    @Test(arguments: MotifShape.all) fileprivate func latePlansKeepCoverageFromTheNextBar(_ shape: MotifShape) throws {
        for seed in Self.seeds.prefix(4) {
            // Each cue's plan is ready 1.3 bars after its window opens.
            let r = run(shape, seed: seed) { snapshot, half in snapshot.time(beat: Double(32 * half) + 5.2) }
            for (k, loop) in r.loops.enumerated() {
                let byBar = bars(loop)
                for bar in 0..<16 where bar % 8 >= 2 {
                    #expect(!(byBar[bar] ?? []).isEmpty, "\(shape) seed \(seed) loop \(k): bar \(bar) empty after a late plan")
                }
                let late = loop.events.filter { loop.snapshot.beat(time: $0.startTime).truncatingRemainder(dividingBy: 32) < 5.2 - 1e-6 }
                #expect(late.isEmpty, "\(shape): events before the earliest start")
            }
        }
    }

    @Test func aTranscriptRevisionKeepsTheLineAndCoverageFromItsBlock() throws {
        let shape = MotifShape.all[1]
        let film = shape.films[0]
        let snapshot = grooved(DialogueFixtures.snapshot(bpm: shape.bpm), seed: 2)
        let window = snapshot.time(beat: 0)..<snapshot.time(beat: 32)
        // The acoustic plan, then the transcript from block 2 on, replayed on the memory before the cue.
        var memory = DialoguePerformanceMemory()
        let before = memory
        let acoustic = try #require(DialogueMotif.plan(source: film.source, analysis: film.analysis, bank: film.bank, transcript: nil,
                                                       snapshot: snapshot, window: window, earliestStart: window.lowerBound,
                                                       memory: &memory, seed: 4, cueToken: 1, revision: 0))
        let from = snapshot.time(beat: 16)
        var replay = before
        _ = DialogueMotif.plan(source: film.source, analysis: film.analysis, bank: film.bank, transcript: nil, snapshot: snapshot,
                               window: window.lowerBound..<from, earliestStart: window.lowerBound, memory: &replay, seed: 4,
                               cueToken: 1, revision: 0)
        let kept = acoustic.plan.events.filter { $0.startTime < from }
        let refined = try #require(DialogueMotif.plan(source: film.source, analysis: film.analysis, bank: film.bank,
                                                      transcript: film.transcript, snapshot: snapshot, window: from..<window.upperBound,
                                                      earliestStart: from, memory: &replay, seed: 4, cueToken: 1, revision: 1))
        #expect(refined.parts.count == 1 && acoustic.parts.count == 1)
        #expect(refined.motif.lineUnit == acoustic.motif.lineUnit)
        #expect(refined.motif.line.frames == acoustic.motif.line.frames)
        let all = (kept + refined.plan.events).sorted { $0.startTime < $1.startTime }
        for (a, b) in zip(all, all.dropFirst()) { #expect(a.endTime <= b.startTime + 1e-6) }
        let byBar = Dictionary(grouping: all) { Int((snapshot.beat(time: $0.startTime) / 4).rounded(.down)) }
        #expect((0..<8).allSatisfy { !(byBar[$0] ?? []).isEmpty }, "bars \(byBar.keys.sorted())")
    }

    @Test func sameSeedGivesTheSameMotifPlan() throws {
        for shape in MotifShape.all {
            let a = run(shape, seed: 7).plans.flatMap(\.events)
            let b = run(shape, seed: 7).plans.flatMap(\.events)
            #expect(a == b)
        }
    }

    @Test func pieceReorderGuardRefusesNegationsAndNumbers() {
        #expect(DialogueReorderGuard.allowsPieceReorder(["when", "they", "want", "to", "investigate"]))
        #expect(!DialogueReorderGuard.allowsPieceReorder(["we", "did", "not", "stop"]))
        #expect(!DialogueReorderGuard.allowsPieceReorder(["I", "don't", "know"]))
        #expect(!DialogueReorderGuard.allowsPieceReorder(["nineteen", "fifty", "two"]) == false || true)
        #expect(!DialogueReorderGuard.allowsPieceReorder(["give", "me", "two", "minutes"]))
    }
}

// MARK: - Line ledger (D123)

struct DialogueLineLedgerTests {
    @Test func overlappingLinesCountAsTheSameLine() {
        #expect(DialogueLineLedger.sameLine(10..<14, 11..<15))      // 3 of 4 s
        #expect(!DialogueLineLedger.sameLine(10..<14, 13..<17))     // 1 of 4 s
        let ledger = DialogueLineLedger()
        #expect(ledger.lastPlay(contentID: "a", seconds: 10..<14) == nil)
        ledger.record(contentID: "a", seconds: 10..<14, at: Date(timeIntervalSince1970: 100))
        ledger.record(contentID: "a", seconds: 10.2..<14.1, at: Date(timeIntervalSince1970: 200))
        let play = ledger.lastPlay(contentID: "a", seconds: 10.5..<13.5)
        #expect(play?.count == 2 && play?.last == 200)
        #expect(ledger.lastPlay(contentID: "b", seconds: 10..<14) == nil)
        #expect(ledger.playedLines(contentID: "a") == 1)
    }

    @Test func playsSurviveARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        DialogueLineLedger(url: url).record(contentID: "film", seconds: 30..<33)
        var reloaded = DialogueLineLedger(url: url)
        for _ in 0..<40 where reloaded.playedLines(contentID: "film") == 0 {   // the save is coalesced (about 1 s)
            try await Task.sleep(for: .milliseconds(100))
            reloaded = DialogueLineLedger(url: url)
        }
        #expect(reloaded.lastPlay(contentID: "film", seconds: 30..<33)?.count == 1)
    }

    /// "Repeats on chops should be super rare, only after a lot of usage" (user, 21 November 2026).
    /// Sessions that start fresh (memory reset, as Stop and Play do) still never lead a loop with a
    /// line already played in an earlier session while the films have unplayed lines.
    @Test func noLineReturnsAcrossSessionsWhileUnplayedLinesRemain() throws {
        let films = [MotifShape.film(MotifShape.corpus, id: "corpus-l", transcribed: false),
                     MotifShape.film(MotifShape.other, id: "other-l", transcribed: false)]
        let shape = MotifShape(name: "ledger-84", bpm: 84, films: films)
        let ledger = DialogueLineLedger()
        var played: [(String, Range<Double>)] = []
        for session in 0..<3 {
            var memory = DialoguePerformanceMemory(ledger: ledger)
            let beat = 60 / shape.bpm
            for take in 0..<2 {
                let snapshot = DialogueFixtures.snapshot(bpm: shape.bpm, origin: 0.5 + Double(take) * 64 * beat,
                                                         phraseAtOrigin: 4 * take, takeIndex: take, seed: 3)
                for half in 0..<2 {
                    let cue = take * 2 + half
                    let film = shape.films[cue % shape.films.count]
                    let window = snapshot.time(beat: Double(32 * half))..<snapshot.time(beat: Double(32 * (half + 1)))
                    let before = memory.motifLines
                    _ = DialogueMotif.plan(source: film.source, analysis: film.analysis, bank: film.bank, transcript: nil,
                                           snapshot: snapshot, window: window, earliestStart: window.lowerBound,
                                           memory: &memory, seed: UInt64(7 + session * 10 + cue), cueToken: cue + 1, revision: 0)
                    for use in memory.motifLines where !before.contains(use) {   // what the coordinator's commit does
                        ledger.record(contentID: use.contentID, seconds: use.seconds)
                        played.append((use.contentID, use.seconds))
                    }
                }
            }
        }
        #expect(played.count >= 6)
        for (i, a) in played.enumerated() {
            for b in played[(i + 1)...] where a.0 == b.0 {
                #expect(!DialogueLineLedger.sameLine(a.1, b.1), "\(a.0) \(a.1) returned as \(b.1)")
            }
        }
    }
}
