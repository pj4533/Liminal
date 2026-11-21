import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Hook probe: prints the per-bar trigger sequence of the motif (which fragment on which sixteenth)
/// and hook metrics, and the ranked line order with texts. Offline, synthetic fixtures only.
/// Output lines start with `HOOK-PROBE`. Run with -only-testing:LiminalTests/DialogueHookProbeTests;
/// xcodebuild does not echo stdout, so export the attachments (`xcrun xcresulttool export attachments`). D125.
struct DialogueHookProbeTests {
    struct Film { let source: DialogueSource; let analysis: DialogueAnalysis; let bank: DialoguePadBank?; let transcript: DialogueTranscript? }

    static func film(_ fixture: SpeechFixture, id: String, transcribed: Bool) -> Film {
        let source = fixture.source(contentID: id)
        let analysis = DialogueEngine.analyze(source, speech: [])
        let transcript = transcribed ? DialogueFixtures.transcript(fixture) : nil
        return Film(source: source, analysis: analysis, bank: DialogueEngine.bank(analysis, transcript: transcript, seed: 11), transcript: transcript)
    }

    static let investigate = DialogueFixtures.speech(DialogueFixtures.Options(seed: 4, sentences: [
        "when they want to investigate the house.", "the old car stood empty for years.",
        "listen to the rhythm of the city.", "she runs to the station every morning.",
        "keep your eyes on the road ahead.", "nobody knows where the river goes.",
    ]))
    /// Plain and evocative lines side by side (line-choice probe).
    static let mixed = DialogueFixtures.speech(DialogueFixtures.Options(seconds: 40, seed: 6, sentences: [
        "and then we went to the other one.", "Sally, this is mother.", "it did not work that way at all.",
        "he took a large dose of LSD.", "there is one of them over there.", "I saw a flying saucer over the desert.",
        "so that is what they have for us.", "the marks of death are rigid.", "what is it that you want to do.",
        "your mind is dreaming in color.",
    ]))

    /// xcodebuild does not echo the test host's stdout, so the lines are recorded as an attachment
    /// (`xcrun xcresulttool export attachments`) as well as printed.
    final class Sink: @unchecked Sendable {
        var lines: [String] = []
        let name: String
        init(_ name: String) { self.name = name }
        func callAsFunction(_ line: String) { lines.append(line); print(line) }
        func flush() { Attachment.record(lines.joined(separator: "\n") + "\n", named: "hook-probe-\(name).txt") }
    }

    typealias Hit = DialogueHookMetrics.Hit
    typealias Metrics = DialogueHookMetrics.Metrics
    static func loopHits(_ events: [DialogueEvent], loop: Int) -> [[Hit]] { DialogueHookMetrics.loopHits(events, loop: loop) }
    static func metrics(_ bars: [[Hit]]) -> Metrics { DialogueHookMetrics.metrics(bars) }

    @Test func printTriggerSequencesAndHookMetrics() throws {
        let emit = Sink("hooks")
        defer { emit.flush() }
        let shapes: [(String, Double, [Film])] = [
            ("transcript-72", 72, [Self.film(Self.investigate, id: "hp-inv-t", transcribed: true)]),
            ("acoustic-72", 72, [Self.film(Self.investigate, id: "hp-inv-a", transcribed: false)]),
            ("mixed-transcript-84", 84, [Self.film(Self.mixed, id: "hp-mix-t", transcribed: true)]),
        ]
        var sums: [String: [Metrics]] = [:]
        for (name, bpm, films) in shapes {
            for seed: UInt64 in [1, 2, 3, 5, 8, 13] {
                var memory = DialoguePerformanceMemory()
                let beat = 60 / bpm
                for take in 0..<3 {
                    let snapshot = DialogueFixtures.snapshot(bpm: bpm, origin: 0.5 + Double(take) * 64 * beat, phraseAtOrigin: 4 * take, takeIndex: take, seed: 3)
                    var events: [DialogueEvent] = []
                    var motif: DialogueMotif?
                    for half in 0..<2 {
                        let cue = take * 2 + half
                        let film = films[cue % films.count]
                        let window = snapshot.time(beat: Double(32 * half))..<snapshot.time(beat: Double(32 * (half + 1)))
                        guard let planned = DialogueMotif.plan(source: film.source, analysis: film.analysis, bank: film.bank, transcript: film.transcript,
                                                               snapshot: snapshot, window: window, earliestStart: window.lowerBound, memory: &memory,
                                                               seed: seed &+ UInt64(cue), cueToken: cue + 1, revision: 0) else { continue }
                        events += planned.plan.events
                        motif = planned.motif
                    }
                    guard let motif else { continue }
                    let bars = Self.loopHits(events, loop: take)
                    let m = Self.metrics(bars)
                    sums[name, default: []].append(m)
                    let frags = motif.fragments.map { "\($0.id)=\($0.kind.rawValue):\($0.text ?? "-")" }.joined(separator: " | ")
                    emit("HOOK-PROBE \(name) seed=\(seed) loop=\(take) line=\"\(motif.text ?? "-")\" cells=\(motif.cells.map { "\($0.kind.rawValue)\($0.variant)" }.joined(separator: ","))")
                    emit("HOOK-PROBE   fragments: \(frags)")
                    if let hook = motif.hook {
                        emit("HOOK-PROBE   hook template=\(hook.template) S=\(hook.signature) R=\(hook.response) T=\(hook.third)")
                    }
                    if seed <= 2 {
                        for row in DialogueHookMetrics.grid(bars) { emit("HOOK-PROBE   \(row)") }
                    }
                    emit(String(format: "HOOK-PROBE   metrics cellRepeat=%.2f cellRhythm=%.2f cellVsBest=%.2f fourBar=%.2f exactBar=%.2f signature=%.2f focalStep=%.2f rhythms=%d fragsPer4=%.1f steps=%d hits=%d",
                                 m.cellRepeat, m.cellRhythm, m.cellVsBest, m.fourBarRepeat, m.exactBarRepeats, m.signatureShare, m.focalConsistency,
                                 m.distinctRhythms, m.fragmentsPer4, m.distinctSteps, m.hits))
                }
            }
        }
        for (name, list) in sums.sorted(by: { $0.key < $1.key }) {
            func mean(_ k: (Metrics) -> Double) -> Double { list.map(k).reduce(0, +) / Double(list.count) }
            emit(String(format: "HOOK-PROBE SUMMARY %@ n=%d cellRepeat=%.2f cellRhythm=%.2f cellVsBest=%.2f fourBar=%.2f exactBar=%.2f signature=%.2f focalStep=%.2f rhythms=%.1f fragsPer4=%.1f steps=%.1f hits=%.1f",
                         name, list.count, mean(\.cellRepeat), mean(\.cellRhythm), mean(\.cellVsBest), mean(\.fourBarRepeat), mean(\.exactBarRepeats),
                         mean(\.signatureShare), mean(\.focalConsistency), mean { Double($0.distinctRhythms) }, mean(\.fragmentsPer4),
                         mean { Double($0.distinctSteps) }, mean { Double($0.hits) }))
        }
    }

    @Test func printRankedLines() throws {
        let emit = Sink("lines")
        defer { emit.flush() }
        let film = Self.film(Self.mixed, id: "hp-mix-rank", transcribed: true)
        let refined = DialogueHierarchy.refine(film.analysis, transcript: film.transcript!)
        let rate = film.analysis.sampleRate
        let ranked = DialogueMotif.rankLines(units: refined.units, rejections: refined.rejections, rate: rate, maximum: 4.0,
                                             words: refined.words, weights: DialogueLineInterest.wordWeights(refined.words))
        for (i, r) in ranked.enumerated() {
            let u = r.unit
            emit(String(format: "HOOK-PROBE RANK %2d %@ %.2fs sound=%.3f interest=%.2f value=%.3f text=\"%@\"", i, u.level.name, u.seconds(rate), u.score.sound, r.interest, r.value, u.text ?? "-"))
        }
        // Every line-level unit with text: why a line is or is not a candidate.
        let rejected = Dictionary(refined.rejections.map { ($0.unit, $0.reason.rawValue) }, uniquingKeysWith: { a, _ in a })
        for u in refined.units where [.utterance, .phrase, .wordGroup].contains(u.level) && u.text != nil {
            emit(String(format: "HOOK-PROBE UNIT %@ %.2fs nuclei=%d sound=%.3f rejected=%@ ranked=%@ text=\"%@\"", u.level.name, u.seconds(rate), u.nuclei,
                        u.score.sound, rejected[u.id] ?? "-", ranked.contains { $0.unit.id == u.id } ? "yes" : "no", u.text ?? "-"))
        }
        // The lines that actually lead loops over 10 loops, three seeds.
        for seed: UInt64 in [1, 2, 3, 0xC0FF_EE12_3456_789A] {
            var memory = DialoguePerformanceMemory()
            var led: [String] = []
            for loop in 0..<10 {
                guard let motif = DialogueMotif.resolve(loop: loop, source: film.source, analysis: film.analysis, hasBank: true,
                                                        transcript: film.transcript, memory: memory, seed: seed,
                                                        beatDuration: 60.0 / 84) else { led.append("nil"); continue }
                memory.setMotif(motif, statements: 0)
                memory.ledger.record(contentID: film.source.contentID, seconds: motif.source.sourceSeconds(frame: motif.line.frames.lowerBound)..<motif.source.sourceSeconds(frame: motif.line.frames.upperBound))
                led.append(String(format: "%@ (%.2f)", motif.text ?? "-", motif.interest))
            }
            emit("HOOK-PROBE LED seed=\(seed): \(led.joined(separator: " / "))")
        }
    }
}
