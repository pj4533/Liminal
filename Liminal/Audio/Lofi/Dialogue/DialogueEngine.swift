import AVFoundation
import Foundation

/// Facade of the dialogue engine (plan 3.4): analysis, bank, performance, rendering and logs.
/// Pure and deterministic; runs off the audio thread.
nonisolated enum DialogueEngine {
    static let analysisVersion = 2

    struct Timings: Sendable, Equatable {
        var analyzeMs: Double = 0
        var bankMs: Double = 0
        var planMs: Double = 0
        var renderMs: Double = 0
        var totalMs: Double { analyzeMs + bankMs + planMs + renderMs }

        var dictionary: [String: Double] {
            ["analyzeMs": analyzeMs, "bankMs": bankMs, "planMs": planMs, "renderMs": renderMs, "totalMs": totalMs]
                .mapValues { ($0 * 10).rounded() / 10 }
        }
    }

    struct Prepared: @unchecked Sendable {
        let analysis: DialogueAnalysis
        let bank: DialoguePadBank?
        let plan: DialoguePerformancePlan
        let chops: [DialogueChop]
        let timings: Timings
    }

    static func analyze(_ source: DialogueSource, speech: [LofiSpeechFocus.Window]) -> DialogueAnalysis {
        DialogueAnalyzer.analyze(source, speech: speech, version: analysisVersion)
    }

    static func bank(_ analysis: DialogueAnalysis, transcript: DialogueTranscript?, seed: UInt64) -> DialoguePadBank? {
        DialogueBankBuilder.build(analysis, transcript: transcript, seed: seed)
    }

    static func perform(_ bank: DialoguePadBank, snapshot: DialogueTransportSnapshot, window: Range<Double>,
                        earliestStart: Double, memory: inout DialoguePerformanceMemory, seed: UInt64) -> DialoguePerformancePlan {
        DialoguePerformer.perform(bank, snapshot: snapshot, window: window, earliestStart: earliestStart,
                                  memory: &memory, seed: seed)
    }

    /// A window without a bank: every block is logged as `noDialogue`.
    static func perform(_ bank: DialoguePadBank?, snapshot: DialogueTransportSnapshot, window: Range<Double>,
                        earliestStart: Double, memory: inout DialoguePerformanceMemory, seed: UInt64,
                        cueToken: Int, revision: Int) -> DialoguePerformancePlan {
        DialoguePerformer.perform(bank, snapshot: snapshot, window: window, earliestStart: earliestStart,
                                  memory: &memory, seed: seed, cueToken: cueToken, revision: revision)
    }

    static func render(_ plan: DialoguePerformancePlan, bank: DialoguePadBank, source: DialogueSource,
                       analysis: DialogueAnalysis) -> [DialogueChop] {
        DialogueChopRenderer.render(plan, bank: bank, source: source, analysis: analysis)
    }

    /// Fallback order (plan 5.5): the current bank, otherwise the previous bank for at most one
    /// further piece, otherwise rest.
    static func fallbackBank(current: DialoguePadBank?, previous: DialoguePadBank?,
                             memory: inout DialoguePerformanceMemory) -> DialoguePadBank? {
        if let current { return current }
        guard let previous, memory.fallbackPieces < 1 else { return nil }
        memory.fallbackPieces += 1
        return previous
    }

    /// Runs every stage and measures it with `ContinuousClock`.
    static func prepare(_ source: DialogueSource, speech: [LofiSpeechFocus.Window], transcript: DialogueTranscript?,
                        snapshot: DialogueTransportSnapshot, window: Range<Double>, earliestStart: Double,
                        memory: inout DialoguePerformanceMemory, seed: UInt64) -> Prepared {
        let clock = ContinuousClock()
        var timings = Timings()
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var t = clock.now
        let analysis = analyze(source, speech: speech)
        timings.analyzeMs = ms(clock.now - t)
        t = clock.now
        // A transcript that leaves no playable bank falls back to the acoustic bank.
        let bank = bank(analysis, transcript: transcript, seed: seed) ?? (transcript == nil ? nil : bank(analysis, transcript: nil, seed: seed))
        timings.bankMs = ms(clock.now - t)
        t = clock.now
        let played = DialoguePerformer.bankForPiece(bank, snapshot: snapshot, window: window, memory: memory)
        let plan = DialoguePerformer.perform(played, snapshot: snapshot, window: window, earliestStart: earliestStart,
                                             memory: &memory, seed: seed, cueToken: source.cueToken, revision: 0)
        timings.planMs = ms(clock.now - t)
        t = clock.now
        let chops = played.map { render(plan, bank: $0, source: source, analysis: analysis) } ?? []
        timings.renderMs = ms(clock.now - t)
        return Prepared(analysis: analysis, bank: played, plan: plan, chops: chops, timings: timings)
    }

    // MARK: Logging

    /// The `diagnostics.dialoguePlans` element of the capture manifest (plan 3.2).
    static func log(_ plan: DialoguePerformancePlan, bank: DialoguePadBank?) -> [String: Any] {
        func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        var result: [String: Any] = [
            "cue": plan.cueToken, "sourceID": plan.sourceID, "bankID": String(plan.bankID, radix: 16),
            "analysisVersion": plan.analysisVersion, "seed": String(plan.seed), "transportRevision": Int(plan.transportRevision),
            "revision": plan.revision, "usedTranscript": plan.usedTranscript,
        ]
        if let bank {
            result["pads"] = bank.pads.map { pad -> [String: Any] in
                var entry: [String: Any] = [
                    "padID": pad.padID, "unit": pad.unitID, "role": pad.role.rawValue, "level": pad.level.name,
                    "source": [r3(bank.clock.sourceSeconds(frame: pad.frames.lowerBound)),
                               r3(bank.clock.sourceSeconds(frame: pad.frames.upperBound))],
                    "transform": pad.transform.name, "accentOffset": r3(pad.accentOffset), "duration": r3(pad.duration),
                    "protected": pad.protected, "score": pad.score.components,
                ]
                if let text = pad.text { entry["text"] = text }
                return entry
            }
            result["anchorPadID"] = bank.anchorPadID
            result["siblingGroups"] = bank.siblingGroups
            if bank.usedTranscript {
                result["intendedText"] = bank.intendedText ?? ""
                result["originalOrder"] = bank.originalOrder
                result["arrangedOrder"] = bank.arrangedOrder
                result["reorderTemplate"] = bank.reorder.template?.rawValue ?? "sourceOrder"
            }
        }
        result["blocks"] = plan.blocks.map { block -> [String: Any] in
            [
                "phrase": block.phrase, "section": sectionName(block.section), "family": block.family.rawValue,
                "variation": block.variation, "fingerprint": String(block.fingerprint, radix: 16),
                "forcedChange": block.forcedChange, "noDialogue": block.noDialogue, "change": block.change,
                "events": block.events.map { e -> [String: Any] in
                    var entry: [String: Any] = [
                        "padID": e.padID, "role": e.role.rawValue, "slot": e.slot, "accentTime": r3(e.accentTime),
                        "startTime": r3(e.startTime), "duration": r3(e.duration), "gainDB": Double(e.gainDB),
                        "protected": e.protected, "transform": e.transform.name, "padKey": String(e.padKey, radix: 16),
                        "snareLanded": e.snareLanded,
                    ]
                    if let choke = e.chokeAt { entry["chokeAt"] = r3(choke) }
                    if let text = e.text { entry["text"] = text }
                    return entry
                },
            ]
        }
        result["rejections"] = plan.rejections.map { ["unit": $0.unit, "reason": $0.reason.rawValue] }
        return result
    }

    static func sectionName(_ section: LofiScore.Section) -> String {
        switch section {
        case .theme: "theme"
        case .answer: "answer"
        case .breakdown: "breakdown"
        case .returnTheme: "returnTheme"
        case .variation: "variation"
        }
    }
}
