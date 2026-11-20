import AVFoundation
import Darwin
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
        /// Device cost beside the stage timings (handoff requirement); sampled once per plan.
        var cost = DialogueCost()
        var totalMs: Double { analyzeMs + bankMs + planMs + renderMs }

        var dictionary: [String: Any] {
            var result: [String: Any] = ["analyzeMs": analyzeMs, "bankMs": bankMs, "planMs": planMs, "renderMs": renderMs,
                                         "totalMs": totalMs].mapValues { ($0 * 10).rounded() / 10 }
            result.merge(cost.dictionary) { a, _ in a }
            return result
        }
    }

    struct Prepared: @unchecked Sendable {
        let analysis: DialogueAnalysis
        let bank: DialoguePadBank?
        let plan: DialoguePerformancePlan
        let chops: [DialogueChop]
        let timings: Timings
        /// Motif mode: the loop motifs the plan played (`bank` is the last one's bank).
        var motifs: [DialogueMotif] = []
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
        if let motif = DialogueMotif.plan(source: source, analysis: analysis, bank: bank, transcript: transcript,
                                          snapshot: snapshot, window: window, earliestStart: earliestStart, memory: &memory,
                                          seed: seed, cueToken: source.cueToken, revision: 0) {
            timings.planMs = ms(clock.now - t)
            t = clock.now
            let chops = motif.render()
            timings.renderMs = ms(clock.now - t)
            timings.cost = .sample(analysis: analysis, bank: bank)
            return Prepared(analysis: analysis, bank: motif.motif.bank, plan: motif.plan, chops: chops, timings: timings,
                            motifs: motif.motifs)
        }
        let played = DialoguePerformer.bankForPiece(bank, snapshot: snapshot, window: window, memory: memory)
        let plan = DialoguePerformer.perform(played, snapshot: snapshot, window: window, earliestStart: earliestStart,
                                             memory: &memory, seed: seed, cueToken: source.cueToken, revision: 0)
        timings.planMs = ms(clock.now - t)
        t = clock.now
        let chops = played.map { render(plan, bank: $0, source: source, analysis: analysis) } ?? []
        timings.renderMs = ms(clock.now - t)
        timings.cost = .sample(analysis: analysis, bank: bank)
        return Prepared(analysis: analysis, bank: played, plan: plan, chops: chops, timings: timings)
    }

    // MARK: Logging

    /// The `diagnostics.dialoguePlans` element of the capture manifest (plan 3.2).
    static func log(_ plan: DialoguePerformancePlan, bank: DialoguePadBank?, motif: DialogueMotif?) -> [String: Any] {
        var result = log(plan, bank: bank)
        if let motif { result["motif"] = motif.log() }
        return result
    }

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
                    if let cell = e.cell { entry["cell"] = cell.rawValue }
                    if let piece = e.piece { entry["piece"] = piece }
                    if e.effect != .none { entry["effect"] = e.effect.name }
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

/// What one plan cost the device beyond wall-clock stage timings (handoff: memory and thermal cost).
/// Sampled on the coordinator's utility task, never on the audio thread. The manifest keys are
/// `thermalState`, `residentMB`, `cacheEntries` and `cacheBytes`; a plan built outside the director (the
/// offline capture) has no bank cache, so its cache fields count only that plan's own analysis and bank.
nonisolated struct DialogueCost: Sendable, Equatable {
    var thermalState = "unknown"
    /// `task_info(TASK_VM_INFO).phys_footprint` in MB (what Activity Monitor and jetsam count).
    var residentMB = 0.0
    var cacheEntries = 0
    /// Estimated bytes of the cached analyses and banks (the bed PCM is not cached).
    var cacheBytes = 0

    var dictionary: [String: Any] {
        ["thermalState": thermalState, "residentMB": (residentMB * 10).rounded() / 10,
         "cacheEntries": cacheEntries, "cacheBytes": cacheBytes]
    }

    /// Thermal state and footprint now, with the given cache totals.
    static func sample(cacheEntries: Int, cacheBytes: Int) -> Self {
        Self(thermalState: thermalName(ProcessInfo.processInfo.thermalState),
             residentMB: Double(residentFootprint() ?? 0) / 1_048_576, cacheEntries: cacheEntries, cacheBytes: cacheBytes)
    }

    /// A plan without the director's cache: one entry, this plan's analysis and bank.
    static func sample(analysis: DialogueAnalysis, bank: DialoguePadBank?) -> Self {
        sample(cacheEntries: 1, cacheBytes: bytes(analysis) + bytes(bank))
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// The process's physical footprint in bytes, or nil when the kernel call fails.
    static func residentFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Estimated heap bytes of an analysis: its feature arrays, units, speech windows and rejections.
    static func bytes(_ analysis: DialogueAnalysis) -> Int {
        var total = MemoryLayout<DialogueAnalysis>.stride
        if let f = analysis.features {
            total += f.bands.count * MemoryLayout<SIMD3<Float>>.stride
            total += (f.energy.count + f.intensity.count + f.fine.count) * MemoryLayout<Float>.stride
            total += f.nuclei.count * MemoryLayout<DialogueNucleus>.stride
            total += f.active.count * MemoryLayout<Bool>.stride + f.pauses.count * MemoryLayout<Range<Int>>.stride
        }
        total += analysis.units.count * MemoryLayout<SpeechUnit>.stride + analysis.units.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
        total += analysis.speech.count * MemoryLayout<LofiSpeechFocus.Window>.stride
        total += analysis.rejections.count * MemoryLayout<DialogueRejection>.stride
        return total
    }

    /// Estimated heap bytes of a bank: its pads, sibling groups, orders and text.
    static func bytes(_ bank: DialoguePadBank?) -> Int {
        guard let bank else { return 0 }
        var total = MemoryLayout<DialoguePadBank>.stride + bank.pads.count * MemoryLayout<DialoguePad>.stride
        total += bank.pads.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
        total += bank.siblingGroups.reduce(0) { $0 + $1.count } * MemoryLayout<Int>.stride
        total += (bank.originalOrder.count + bank.arrangedOrder.count) * MemoryLayout<Int>.stride
        total += bank.rejections.count * MemoryLayout<DialogueRejection>.stride + (bank.intendedText?.utf8.count ?? 0)
        return total
    }

    /// Estimated bytes of a transcript's words.
    static func bytes(_ transcript: DialogueTranscript?) -> Int {
        guard let transcript else { return 0 }
        return transcript.words.count * MemoryLayout<DialogueTranscript.Word>.stride + transcript.words.reduce(0) { $0 + $1.text.utf8.count }
    }
}
