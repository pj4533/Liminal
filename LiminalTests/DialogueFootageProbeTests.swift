import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Opt-in probe of the dialogue engine on cached archive films. It runs only when
/// `/private/tmp/liminal-dialogue-probe-<uid>.json` names this checkout, for example
/// `{"checkout": "/path/to/Liminal", "films": 8, "bpm": 70, "seed": 1}`, and prints one
/// `DIALOGUE-PROBE {json}` line per film. It never downloads and never spends API budget.
struct DialogueFootageProbeTests {
    struct Config: Decodable {
        let checkout: String
        let films: Int?
        let bpm: Double?
        let seed: UInt64?
        let offsetShare: Double?
    }

    static var checkout: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
    }

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
        let clips = catalog.clips.filter(\.hasAudio).shuffled(using: &rng)
        var probed = 0
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
            var memory = DialoguePerformanceMemory()
            var timings: DialogueEngine.Timings?
            var blocks: [[String: Any]] = []
            var bank: DialoguePadBank?
            var analysis: DialogueAnalysis?
            for take in 0..<4 {
                let snapshot = DialogueFixtures.snapshot(bpm: bpm, origin: Double(take) * 64 * beat, phraseAtOrigin: 4 * take,
                                                         takeIndex: take, seed: 3)
                for half in 0..<2 {
                    let window = snapshot.time(beat: Double(32 * half))..<snapshot.time(beat: Double(32 * half + 32))
                    let plan: DialoguePerformancePlan
                    if take == 0 && half == 0 {
                        let prepared = DialogueEngine.prepare(source, speech: windows, transcript: nil, snapshot: snapshot,
                                                              window: window, earliestStart: window.lowerBound, memory: &memory,
                                                              seed: config.seed ?? 1)
                        timings = prepared.timings
                        bank = prepared.bank
                        analysis = prepared.analysis
                        plan = prepared.plan
                    } else {
                        plan = DialogueEngine.perform(bank, snapshot: snapshot, window: window, earliestStart: window.lowerBound,
                                                      memory: &memory, seed: (config.seed ?? 1) &+ UInt64(take * 2 + half),
                                                      cueToken: probed, revision: 0)
                    }
                    for block in plan.blocks {
                        blocks.append(["p": block.phrase, "f": block.family.rawValue, "n": block.events.count, "c": block.change,
                                       "pads": block.events.map(\.padID)])
                    }
                }
            }
            let spoken = windows.filter { $0.speech > max(0.3, $0.singing, $0.music) }.count
            var reasons: [String: Int] = [:]
            for r in analysis?.rejections ?? [] { reasons[r.reason.rawValue, default: 0] += 1 }
            let levels = Dictionary(grouping: analysis?.units ?? [], by: { $0.level.name }).mapValues(\.count)
            func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
            let line: [String: Any] = [
                "title": String(clip.title.prefix(40)), "offset": r2(offset), "seconds": r2(seconds),
                "spokenWindows": "\(spoken)/\(windows.count)", "classifyMs": r2(Double(classify.components.attoseconds) / 1e15 + Double(classify.components.seconds) * 1000),
                "timings": timings?.dictionary ?? [:], "units": levels, "rejections": reasons,
                "nuclei": analysis?.features?.nuclei.count ?? 0,
                "pads": (bank?.pads ?? []).map { pad -> [String: Any] in
                    ["id": pad.padID, "role": pad.role.rawValue, "level": pad.level.name,
                     "src": [r2(Double(pad.frames.lowerBound) / 48_000), r2(Double(pad.frames.upperBound) / 48_000)],
                     "dur": r2(pad.duration), "tx": pad.transform.name, "sound": r2(Double(pad.score.sound)),
                     "speech": r2(Double(pad.score.speech)), "clarity": r2(Double(pad.score.clarity)),
                     "onset": pad.fadeIn < 200 ? "burst" : "gradual"]
                },
                "blocks": blocks,
            ]
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("DIALOGUE-PROBE " + String(decoding: data, as: UTF8.self))
        }
        print("DIALOGUE-PROBE-DONE films \(probed)")
    }
}
