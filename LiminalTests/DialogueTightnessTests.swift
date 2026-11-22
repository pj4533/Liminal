import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// One 16-bar loop of motif plans on a fixture film, as the coordinator plays it (two 8-bar cues),
/// on a swung grid: odd sixteenths 0.1 beat late (the D125 captures' median swing at 70 BPM).
struct GateRun: @unchecked Sendable {
    let snapshot: DialogueTransportSnapshot
    let plans: [DialogueMotifPlan]
    var events: [DialogueEvent] { plans.flatMap(\.plan.events).sorted { $0.startTime < $1.startTime } }
    var motifs: [DialogueMotif] { plans.flatMap(\.motifs) }

    static let investigate = DialogueFixtures.speech(DialogueFixtures.Options(seed: 4, sentences: [
        "when they want to investigate the house.", "the old car stood empty for years.",
        "listen to the rhythm of the city.", "she runs to the station every morning.",
        "keep your eyes on the road ahead.", "nobody knows where the river goes.",
    ]))
    static let corpus = DialogueFixtures.speech(DialogueFixtures.Options(seed: 9))

    static func swung(bpm: Double, seed: UInt64 = 3) -> DialogueTransportSnapshot {
        var s = DialogueFixtures.snapshot(bpm: bpm, origin: 0.5, seed: seed)
        s.grooveOffsets = (0..<DialogueTransportSnapshot.takeSixteenths).map { $0 % 2 == 1 ? 0.10 : 0.01 }
        return s
    }

    static func make(_ fixture: SpeechFixture, bpm: Double, seed: UInt64, transcribed: Bool) -> GateRun {
        let source = fixture.source(contentID: "gate-\(seed)-\(transcribed)")
        let analysis = DialogueEngine.analyze(source, speech: [])
        let transcript = transcribed ? DialogueFixtures.transcript(fixture) : nil
        let bank = DialogueEngine.bank(analysis, transcript: transcript, seed: 11)
        let snapshot = swung(bpm: bpm)
        var memory = DialoguePerformanceMemory()
        var plans: [DialogueMotifPlan] = []
        for half in 0..<2 {
            let window = snapshot.time(beat: Double(32 * half))..<snapshot.time(beat: Double(32 * (half + 1)))
            if let plan = DialogueMotif.plan(source: source, analysis: analysis, bank: bank, transcript: transcript, snapshot: snapshot,
                                             window: window, earliestStart: window.lowerBound, memory: &memory,
                                             seed: seed &+ UInt64(half), cueToken: half + 1, revision: 0) {
                plans.append(plan)
            }
        }
        return GateRun(snapshot: snapshot, plans: plans)
    }

    static let cases: [(SpeechFixture, Double, Bool)] = [(investigate, 72, false), (investigate, 62, true), (corpus, 84, true)]
}

/// Rendered chop attacks against their steps (D126, C-D10): measured on the rendered buffers with
/// a detector of its own (a plain 2 ms RMS on the full-band output, as `scripts/mixlib` measures the
/// dialogue stem), not with `DialogueOnset`.
enum DialogueTightnessMetrics {
    struct Hit { let attackMs: Double; let audibleMs: Double; let line: Bool; let steps: Double; var weakLead = false }

    /// Beat-point error (the first crossing of half the first 300 ms peak, minus the accent time)
    /// and the audible lead (the first crossing of a tenth) of each rendered chop, in milliseconds.
    /// `weakLead`: pads whose weak first syllable is the beat by design (`DialogueMotifFragment.weakLead`).
    static func hits(_ chops: [DialogueChop], sixteenth: Double, weakLead: Set<Int> = []) -> [Hit] {
        chops.compactMap { chop in
            let e = chop.event
            guard e.effect != .reversed, let x = chop.buffer.floatChannelData?[0] else { return nil }
            let sr = chop.buffer.format.sampleRate
            let n = Int(chop.buffer.frameLength)
            let k = max(1, Int(0.002 * sr))
            guard n > k + Int(0.03 * sr) else { return nil }
            var prefix = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { prefix[i + 1] = prefix[i] + Double(x[i] * x[i]) }
            let m = n - k
            let env = (0..<m).map { sqrt(max(0, (prefix[$0 + k] - prefix[$0]) / Double(k))) }
            // The dry part only (an echo throw's repeats follow it).
            let dry = min(m, Int(((e.drySeconds ?? (e.effect == .none ? e.duration : Double(n) / sr))) * sr))
            let first = env[0..<min(dry, Int(0.3 * sr))]
            guard let p = first.max(), p > 1e-5 else { return nil }
            func cross(_ level: Double) -> Int? { first.firstIndex { $0 >= level } }
            guard let t50 = cross(0.5 * p), let t10 = cross(0.1 * p) else { return nil }
            func ms(_ i: Int) -> Double { (e.startTime + Double(i) / sr - e.accentTime) * 1000 }
            return Hit(attackMs: ms(t50), audibleMs: ms(t10), line: e.piece == 0, steps: Double(dry) / sr / sixteenth,
                       weakLead: weakLead.contains(e.padID))
        }
    }

    static func percentile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
    }
}

struct DialogueTightnessTests {
    @Test(arguments: [62.0, 72.0, 84.0]) func renderedAttacksLandOnTheirSteps(_ bpm: Double) throws {
        var all: [DialogueTightnessMetrics.Hit] = []
        for (fixture, transcribed) in [(GateRun.investigate, false), (GateRun.investigate, true), (GateRun.corpus, true)] {
            for seed: UInt64 in [1, 2] {
                let run = GateRun.make(fixture, bpm: bpm, seed: seed, transcribed: transcribed)
                for plan in run.plans {
                    for part in plan.parts {
                        let chops = DialogueChopRenderer.render(part.plan, bank: part.motif.bank, source: part.motif.source,
                                                                analysis: part.motif.analysis, prerendered: part.motif.renders)
                        let weak = Set(part.motif.fragments.filter(\.weakLead).map(\.id))
                        all += DialogueTightnessMetrics.hits(chops, sixteenth: run.snapshot.beatDuration / 4, weakLead: weak)
                    }
                }
            }
        }
        // A transcribed piece whose first word starts weakly ("re-MEM-ber") puts that weak syllable on
        // the step rather than cut into the word; half its loudest peak comes with the stressed one.
        // Those start on the step (their audible lead is checked with the rest) and are counted apart.
        let weakLead = all.filter { !$0.line && $0.weakLead }
        #expect(Double(weakLead.count) <= 0.08 * Double(all.count), "\(weakLead.count) weak-lead hits of \(all.count)")
        let pieces = all.filter { !$0.line }
        let errors = pieces.filter { !$0.weakLead }.map { abs($0.attackMs) }
        let median = DialogueTightnessMetrics.percentile(errors, 0.5), p95 = DialogueTightnessMetrics.percentile(errors, 0.95)
        // A consonant or breath never leads a piece by more than 35 ms (C-D10).
        let early = pieces.filter { $0.audibleMs < -35 }.count
        let lineEarly = all.filter { $0.line && $0.audibleMs < -125 }.count
        let steps = pieces.map(\.steps)
        let summary = ("TIGHT bpm \(bpm): \(pieces.count) pieces (\(weakLead.count) weak-lead), |attack error| median \(String(format: "%.1f", median)) ms p95 "
              + "\(String(format: "%.1f", p95)) ms, audible lead p5 \(String(format: "%.1f", DialogueTightnessMetrics.percentile(pieces.map(\.audibleMs), 0.05))) ms, "
              + "audible > 35 ms early \(early), over 12 ms \(errors.filter { $0 > 12 }.count), "
              + "length median \(String(format: "%.2f", DialogueTightnessMetrics.percentile(steps, 0.5))) steps, "
              + "<=1 step \(String(format: "%.2f", Double(steps.filter { $0 <= 1.05 }.count) / Double(max(1, steps.count)))), "
              + "<=2 \(String(format: "%.2f", Double(steps.filter { $0 <= 2.05 }.count) / Double(max(1, steps.count))))")
        print(summary)
        Attachment.record(summary + "\n", named: "tightness-\(Int(bpm)).txt")
        #expect(pieces.count > 40)
        #expect(median <= 5, "median |attack error| \(median) ms")
        #expect(p95 <= 12, "p95 |attack error| \(p95) ms")
        #expect(early == 0, "\(early) pieces audible more than 35 ms before their step")
        #expect(lineEarly == 0)
    }
}
