import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Opt-in probe of the dialogue engine on cached archive films. It runs only when
/// `/private/tmp/liminal-dialogue-probe-<uid>.json` names this checkout, for example
/// `{"checkout": "/path/to/Liminal", "films": 8, "bpm": 70, "seed": 1, "transcribe": true}`, and prints one
/// `DIALOGUE-PROBE {json}` line per film. It never downloads and never spends API budget.
///
/// With `"transcribe": true` and the on-device English model already installed (status `ready`;
/// the probe never requests an install), each film is also transcribed locally. The words then
/// serve as a reference for the acoustic cuts (`cutsWord`: a pad edge more than 30 ms inside a
/// recognised word) and the transcript-refined bank is printed beside the acoustic one.
struct DialogueFootageProbeTests {
    struct Config: Decodable {
        let checkout: String
        let films: Int?
        let bpm: Double?
        let seed: UInt64?
        let offsetShare: Double?
        let transcribe: Bool?
        /// Probe only clips whose id contains one of these strings.
        let only: [String]?
        /// "reel" (another film every 8 bars) or "same" (one film repeated), planned the way the
        /// capture harness commits them: at each piece boundary, with the commit margin.
        let session: String?
        let bars: Int?
    }

    static var checkout: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
    }

    /// A pad edge further than this inside a recognised word counts as a cut word.
    static let wordCutTolerance = 0.030

    @Test func probeCachedFilms() async throws {
        let path = URL(fileURLWithPath: "/private/tmp/liminal-dialogue-probe-\(getuid()).json")
        guard FileManager.default.fileExists(atPath: path.path),
              let config = try? JSONDecoder().decode(Config.self, from: Data(contentsOf: path)),
              URL(fileURLWithPath: config.checkout).standardizedFileURL.path == Self.checkout else { return }
        let directory = ArchiveClipStore.defaultDirectory()
        struct Catalog: Decodable { let clips: [ArchiveClip] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: directory.appending(path: "index.json")))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let bpm = config.bpm ?? 70
        let beat = 60 / bpm
        var rng = MusicRNG(seed: config.seed ?? 1)
        var clips = catalog.clips.filter(\.hasAudio).shuffled(using: &rng)
        if let only = config.only { clips = clips.filter { c in only.contains { c.id.contains($0) } } }
        var provider: AppleSpeechTranscriptProvider?
        if config.transcribe == true, let environment = AppleSpeechTranscriptProvider.liveEnvironment,
           await DialogueSpeechAssets.status(mode: .installedOnly, environment: environment) == .ready {
            provider = AppleSpeechTranscriptProvider.live()
        }
        print("DIALOGUE-PROBE-TRANSCRIBER \(provider == nil ? "none" : "apple")")
        var probed = 0
        var reel: [(DialogueSource, [LofiSpeechFocus.Window])] = []
        var totals: [String: Int] = [:]
        for clip in clips where probed < (config.films ?? 8) {
            let seconds = min(32, clip.duration)
            guard seconds >= 5 else { continue }
            let offset = max(0, clip.duration - seconds - 0.1) * (config.offsetShare ?? rng.range(0.12...0.78))
            let url = directory.appending(path: clip.fileName)
            guard let buffer = try? await ArchiveAudioDecoder.decode(url: url, sourceStart: offset, sourceLength: seconds,
                                                                     rate: 1, format: format) else { continue }
            probed += 1
            let clock = ContinuousClock()
            let started = clock.now
            let windows = LofiSpeechFocus.classify(buffer, seconds: seconds)
            let classify = clock.now - started
            let source = DialogueSource(contentID: clip.id, cueToken: probed, buffer: buffer, sourceStart: offset, rate: 1)
            reel.append((source, windows))
            var transcript: DialogueTranscript?
            var transcribeMs: Double?
            if let provider {
                let t0 = clock.now
                transcript = await provider.transcript(for: source, deadline: .now.advanced(by: .seconds(20)))
                transcribeMs = DialogueCueCoordinator.ms(clock.now - t0)
            }
            func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
            func plan(_ transcript: DialogueTranscript?) -> (bank: DialoguePadBank?, analysis: DialogueAnalysis,
                                                             timings: DialogueEngine.Timings, blocks: [[String: Any]], forced: Int) {
                var memory = DialoguePerformanceMemory()
                var blocks: [[String: Any]] = []
                var result: (DialoguePadBank?, DialogueAnalysis, DialogueEngine.Timings)?
                var forced = 0
                for take in 0..<4 {
                    let snapshot = DialogueFixtures.snapshot(bpm: bpm, origin: Double(take) * 64 * beat, phraseAtOrigin: 4 * take,
                                                             takeIndex: take, seed: 3)
                    for half in 0..<2 {
                        let window = snapshot.time(beat: Double(32 * half))..<snapshot.time(beat: Double(32 * half + 32))
                        let p: DialoguePerformancePlan
                        if let (bank, _, _) = result {
                            let played = DialoguePerformer.bankForPiece(bank, snapshot: snapshot, window: window, memory: memory)
                            p = DialogueEngine.perform(played, snapshot: snapshot, window: window, earliestStart: window.lowerBound,
                                                       memory: &memory, seed: (config.seed ?? 1) &+ UInt64(take * 2 + half),
                                                       cueToken: probed, revision: 0)
                        } else {
                            let prepared = DialogueEngine.prepare(source, speech: windows, transcript: transcript, snapshot: snapshot,
                                                                  window: window, earliestStart: window.lowerBound, memory: &memory,
                                                                  seed: config.seed ?? 1)
                            result = (prepared.bank, prepared.analysis, prepared.timings)
                            p = prepared.plan
                        }
                        for block in p.blocks {
                            if block.forcedChange { forced += 1 }
                            blocks.append(["p": block.phrase, "f": block.family.rawValue, "n": block.events.count, "c": block.change,
                                           "pads": block.events.map(\.padID), "slots": block.events.map(\.slot)])
                        }
                    }
                }
                return (result!.0, result!.1, result!.2, blocks, forced)
            }
            let acoustic = plan(nil)
            // Reference words: the recognised words mapped to source frames and trimmed to their
            // voiced cores by the same refinement the engine uses.
            let words: [DialogueTranscript.Word] = transcript.map { t in
                DialogueHierarchy.acceptedWords(t, analysis: acoustic.analysis).words.map {
                    .init(text: $0.text, start: acoustic.analysis.clock.sourceSeconds(frame: $0.frames.lowerBound),
                          end: acoustic.analysis.clock.sourceSeconds(frame: $0.frames.upperBound), confidence: $0.confidence)
                }
            } ?? []
            func padEntries(_ bank: DialoguePadBank?) -> [[String: Any]] {
                (bank?.pads ?? []).map { pad -> [String: Any] in
                    let a = bank!.clock.sourceSeconds(frame: pad.frames.lowerBound)
                    let b = bank!.clock.sourceSeconds(frame: pad.frames.upperBound)
                    let tol = Self.wordCutTolerance
                    let cutStart = words.first { $0.start + tol < a && a < $0.end - tol }
                    let cutEnd = words.first { $0.start + tol < b && b < $0.end - tol }
                    let heard = words.filter { $0.end > a + 0.02 && $0.start < b - 0.02 }.map(\.text).joined(separator: " ")
                    var entry: [String: Any] = [
                        "id": pad.padID, "role": pad.role.rawValue, "level": pad.level.name,
                        "src": [r2(a), r2(b)], "dur": r2(pad.duration), "tx": pad.transform.name,
                        "sound": r2(Double(pad.score.sound)), "speech": r2(Double(pad.score.speech)),
                        "clarity": r2(Double(pad.score.clarity)), "entrance": r2(Double(pad.score.entrance)),
                        "exit": r2(Double(pad.score.exit)), "interference": r2(Double(pad.score.interference)),
                    ]
                    if let text = pad.text { entry["text"] = text }
                    if !words.isEmpty {
                        entry["heard"] = heard
                        if let w = cutStart { entry["cutsStart"] = w.text }
                        if let w = cutEnd { entry["cutsEnd"] = w.text }
                    }
                    return entry
                }
            }
            let spoken = windows.filter { $0.speech > max(0.3, $0.singing, $0.music) }.count
            var reasons: [String: Int] = [:]
            for r in acoustic.analysis.rejections { reasons[r.reason.rawValue, default: 0] += 1 }
            let levels = Dictionary(grouping: acoustic.analysis.units, by: { $0.level.name }).mapValues(\.count)
            let families = Set(acoustic.blocks.compactMap { $0["f"] as? String }.filter { $0 != "rest" })
            totals["films", default: 0] += 1
            totals["banks", default: 0] += acoustic.bank == nil ? 0 : 1
            totals["forced", default: 0] += acoustic.forced
            totals["blocks", default: 0] += acoustic.blocks.count
            let pads = padEntries(acoustic.bank)
            totals["pads", default: 0] += pads.count
            totals["cutWord", default: 0] += pads.filter { $0["cutsStart"] != nil || $0["cutsEnd"] != nil }.count
            var line: [String: Any] = [
                "title": String(clip.title.prefix(40)), "id": clip.id, "offset": r2(offset), "seconds": r2(seconds),
                "spokenWindows": "\(spoken)/\(windows.count)", "classifyMs": r2(DialogueCueCoordinator.ms(classify)),
                "timings": acoustic.timings.dictionary, "units": levels, "rejections": reasons,
                "nuclei": acoustic.analysis.features?.nuclei.count ?? 0, "families": families.sorted(),
                "forced": acoustic.forced, "pads": pads, "blocks": acoustic.blocks,
            ]
            if let transcript {
                line["transcribeMs"] = r2(transcribeMs ?? 0)
                line["rtf"] = r2((transcribeMs ?? 0) / 1000 / seconds * 100) / 100
                line["words"] = words.map { "\($0.text)@\(r2($0.start))-\(r2($0.end))" }.joined(separator: " ")
                _ = transcript
                let refined = plan(transcript)
                let spans = refined.analysis.units.flatMap(\.protectedSpans).count
                let refinement = DialogueHierarchy.refine(refined.analysis, transcript: transcript)
                let why = Dictionary(refinement.rejections.map { ($0.unit, $0.reason.rawValue) }, uniquingKeysWith: { a, _ in a })
                var treasons: [String: Int] = [:]
                for r in refinement.rejections { treasons[r.reason.rawValue, default: 0] += 1 }
                let lines = refinement.units.filter { [.utterance, .phrase, .wordGroup].contains($0.level) && $0.text != nil }
                    .map { u -> String in
                        let a = r2(refined.analysis.clock.sourceSeconds(frame: u.frames.lowerBound))
                        let b = r2(refined.analysis.clock.sourceSeconds(frame: u.frames.upperBound))
                        return "\(u.level.name)[\(a)-\(b)] s=\(r2(Double(u.score.sound))) \(why[u.id] ?? "ok"): \(u.text ?? "")"
                    }
                line["transcribed"] = [
                    "usedTranscript": refined.bank?.usedTranscript ?? false,
                    "reorder": refined.bank?.reorder.template?.rawValue ?? "sourceOrder",
                    "intendedText": refined.bank?.intendedText ?? "",
                    "originalOrder": refined.bank?.originalOrder ?? [], "arrangedOrder": refined.bank?.arrangedOrder ?? [],
                    "pads": padEntries(refined.bank), "blocks": refined.blocks, "forced": refined.forced,
                    "protectedSpans": spans, "rejections": treasons, "lines": lines,
                    "droppedWords": refinement.dropped.count,
                    "sparseReorder": refined.blocks.filter { ($0["f"] as? String) == "sparseReorder" }.count,
                ] as [String: Any]
            } else if provider != nil {
                line["transcribeMs"] = r2(transcribeMs ?? 0)
                line["transcript"] = "nil"
            }
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("DIALOGUE-PROBE " + String(decoding: data, as: UTF8.self))
        }
        print("DIALOGUE-PROBE-DONE films \(probed) totals \(totals.sorted { $0.key < $1.key })")
        if let session = config.session, !reel.isEmpty { Self.session(session, reel: reel, bars: config.bars ?? 64, bpm: bpm, seed: config.seed ?? 1) }
    }

    /// Plans 8-bar pieces back to back as the capture harness does and prints each block, then
    /// the cadence summary: families, distinct anchors, forced changes, the smallest 16-bar difference.
    static func session(_ mode: String, reel: [(DialogueSource, [LofiSpeechFocus.Window])], bars: Int, bpm: Double, seed: UInt64) {
        let beat = 60 / bpm
        let director = DialogueDirector()
        var memory = DialoguePerformanceMemory()
        var blocks: [DialogueBlock] = []
        var leads: Set<UInt64> = []
        var hits = 0
        for piece in 0..<(bars / 8) {
            let (base, speech) = mode == "same" ? reel[0] : reel[piece % reel.count]
            let source = DialogueSource(contentID: base.contentID, cueToken: piece + 1, buffer: base.buffer,
                                        sourceStart: base.sourceStart, rate: 1)
            let due = Double(piece * 32) * beat
            let take = piece / 2
            let info = LofiTransportInfo(revision: 1, takeIndex: take, phraseAtTakeStart: 4 * take, origin: Double(take * 64) * beat,
                                         beatDuration: beat, nextBeatDuration: nil, seed: seed, options: LofiOptions(tempo: bpm), timing: nil)
            let reuse = director.cached(source)
            if reuse != nil { hits += 1 }
            let window = DialogueCueCoordinator.window(due: due, span: Double(base.frameCount) / base.sampleRate, transport: info)
            let built = DialogueCueCoordinator.build(source: source, speech: speech, transcript: nil, transport: info, window: window,
                                                     earliestStart: due + DialogueCueCoordinator.commitMargin, memory: memory,
                                                     seed: seed &+ UInt64(piece), reuse: reuse)
            if reuse == nil { director.store(source, analysis: built.analysis, bank: built.bank) }
            memory = built.memory
            for block in built.plan.blocks {
                blocks.append(block)
                let anchor = built.played.map { b in block.events.filter { $0.padID == b.anchorPadID }.map(\.padKey) } ?? []
                leads.formUnion(anchor)
                let events = block.events.map { "\($0.padID)\($0.role.rawValue.prefix(2))@\($0.slot)" }.joined(separator: " ")
                print("DIALOGUE-SESSION piece \(piece) ph \(block.phrase) \(DialogueEngine.sectionName(block.section)) \(block.family.rawValue) \(block.change)\(block.forcedChange ? " FORCED" : "") | \(events)")
            }
        }
        var minDifference = 1.0
        let windows = stride(from: 0, to: blocks.count - 3, by: 4).map { k in
            blocks[k..<(k + 4)].enumerated().flatMap { i, b in b.events.map { DialogueElement(padKey: $0.padKey ^ UInt64(i), slot: $0.slot) } }
        }
        for (a, b) in zip(windows, windows.dropFirst()) where !a.isEmpty && !b.isEmpty {
            minDifference = min(minDifference, DialoguePerformer.windowDifference(a, b))
        }
        let families = Set(blocks.filter { !$0.events.isEmpty }.map(\.family.rawValue))
        print("DIALOGUE-SESSION-SUMMARY \(mode) blocks \(blocks.count) families \(families.sorted()) anchors \(leads.count) forced \(blocks.filter(\.forcedChange).count) cacheHits \(hits) min16 \(minDifference)")
    }
}
