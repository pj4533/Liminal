import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Opt-in salience and partial-word probe of the motif chop path on the cached archive films (user
/// direction of 22 November 2026: more recognisable, cool words such as "psilocybin" and "DMT"; fewer
/// chops of connective words and of partial words, which sometimes sound like a bug).
///
/// It runs only when `/private/tmp/liminal-salience-probe-<uid>.json` names this checkout, e.g.
/// `{"checkout": "/path/to/Liminal", "chunks": 6, "bpm": 72, "seed": 1, "modes": ["T", "A"]}`.
/// For each cached film with audio it decodes `chunks` 30 s windows spread over the film's interior
/// (the weaver's own margins), classifies speech, transcribes each window with the installed on-device
/// model (never downloads, never spends API budget), and plans two takes (four 8-bar pieces) through
/// `DialogueMotif.plan` exactly as `DialogueCueCoordinator.build` does, with the transcript at the first
/// plan (`T`) and without it (`A`, the acoustic fallback, classified against the same transcript).
///
/// Output lines (in the xcodebuild log): `SALIENCE-WINDOW {json}` per window (raw and accepted words with
/// weights, dropped words, top ranked lines, chosen lines), `SALIENCE-HIT {json}` per played hit (its
/// fragment, the words it covers and how much of each, which edge lands inside a word and the mechanism
/// that put it there, and the signal level around its edges), and `SALIENCE-SNIPPET` lines for the
/// suspect hits (the played chop and its source context as WAV, base64 when the test host cannot write
/// `snippetDirectory`). `scripts/dialogue-salience-report.py` turns a log into the report and WAVs.
struct DialogueSalienceProbeTests {
    struct Config: Decodable {
        let checkout: String
        /// Windows per film.
        let chunks: Int?
        let films: Int?
        let bpm: Double?
        let seed: UInt64?
        let modes: [String]?
        let only: [String]?
        let maxSnippets: Int?
        let snippetDirectory: String?
        let focus: [String]?
    }

    static var checkout: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
    }

    /// A played edge further than this inside a word counts as cutting it.
    static let tolerance = 0.030
    static let windowSeconds = 30.0

    static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Max RMS (dB, 10 ms windows, hop 5 ms) of channel 0 in `range`.
    static func peakDB(_ samples: UnsafePointer<Float>, count: Int, range: Range<Int>, rate: Double) -> Double {
        let w = max(1, Int(0.010 * rate)), hop = max(1, w / 2)
        let lo = max(0, range.lowerBound), hi = min(count, range.upperBound)
        guard hi - lo >= 1 else { return -120 }
        var best: Float = 0
        var i = lo
        repeat {
            let end = min(hi, i + w)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            best = max(best, sum / Float(max(1, end - i)))
            i += hop
        } while i < hi - w / 2
        return 10 * log10(Double(max(best, 1e-12)))
    }

    static func wav(_ buffer: AVAudioPCMBuffer, frames: Range<Int>? = nil) -> Data? {
        let range = frames ?? 0..<Int(buffer.frameLength)
        let lo = max(0, range.lowerBound), hi = min(Int(buffer.frameLength), range.upperBound)
        guard hi > lo, let data = buffer.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let n = hi - lo
        var pcm = Data(capacity: n * 2)
        for i in lo..<hi {
            var v: Float = 0
            for c in 0..<channels { v += data[c][i] }
            v /= Float(channels)
            let s = Int16(max(-1, min(1, v)) * 32767)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var out = Data()
        func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { out.append(contentsOf: $0) } }
        let rate = UInt32(buffer.format.sampleRate)
        out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); out.append(pcm)
        return out
    }

    /// The D126 independent onset detector, on the rendered chop: the steepest rise of a 10 ms RMS
    /// envelope (1 ms hop, in dB) of the 300 Hz to 3.4 kHz band into the first attack of the dry part
    /// (up to 10 ms after the envelope first comes within 10 dB of the first 300 ms peak), counted only
    /// where the envelope is within 30 dB of that peak. Milliseconds from the
    /// event's accent (which includes the feel); nil for a silent or too short chop.
    static func bandOnsetMs(_ chop: DialogueChop) -> Double? {
        let e = chop.event
        guard e.effect != .reversed, let x = chop.buffer.floatChannelData?[0] else { return nil }
        let sr = chop.buffer.format.sampleRate
        let n = Int(chop.buffer.frameLength)
        let dry = min(n, Int(((e.drySeconds ?? (e.effect == .none ? e.duration : Double(n) / sr))) * sr))
        let limit = min(dry, Int(0.3 * sr))
        let half = max(1, Int(0.005 * sr)), hop = max(1, Int(0.001 * sr))
        guard limit > 4 * half else { return nil }
        // RBJ biquads: a 300 Hz high-pass into a 3.4 kHz low-pass (Q 0.707).
        func biquad(_ input: [Float], hz: Double, highPass: Bool) -> [Float] {
            let w = 2 * Double.pi * hz / sr, c = cos(w), alpha = sin(w) / (2 * 0.7071)
            let b0 = highPass ? (1 + c) / 2 : (1 - c) / 2, b1 = highPass ? -(1 + c) : 1 - c, b2 = b0
            let a0 = 1 + alpha, a1 = -2 * c, a2 = 1 - alpha
            var out = [Float](repeating: 0, count: input.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in input.indices {
                let x0 = Double(input[i])
                let y0 = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                out[i] = Float(y0); x2 = x1; x1 = x0; y2 = y1; y1 = y0
            }
            return out
        }
        let raw = Array(UnsafeBufferPointer(start: x, count: limit + half))
        let band = biquad(biquad(raw, hz: 300, highPass: true), hz: 3400, highPass: false)
        var prefix = [Double](repeating: 0, count: band.count + 1)
        for i in band.indices { prefix[i + 1] = prefix[i] + Double(band[i] * band[i]) }
        // dB of the 10 ms window centred on frame `c`.
        func level(_ c: Int) -> Double {
            let lo = max(0, c - half), hi = min(band.count, c + half)
            return 10 * log10(max(1e-14, (prefix[hi] - prefix[lo]) / Double(max(1, hi - lo))))
        }
        let centres = Array(stride(from: half, to: limit, by: hop))
        guard let peak = centres.map(level).max(), peak > -100 else { return nil }
        // The first attack only: up to 10 ms after the envelope first comes within 10 dB of the peak.
        let reach = centres.first { level($0) >= peak - 10 } ?? limit
        let end = min(limit - half, reach + 2 * half)
        var best: (t: Int, rise: Double)?
        for t in stride(from: 2 * half, to: max(2 * half + 1, end), by: hop) where level(t + half) >= peak - 30 {
            let rise = level(t + half) - level(t - half)
            if best == nil || rise > best!.rise { best = (t, rise) }
        }
        guard let best else { return nil }
        return (e.startTime + Double(best.t) / sr - e.accentTime) * 1000
    }

    @Test func independentAttackRequiresActualSignalAndExcludesReverses() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        audio.frameLength = 24_000
        let samples = try #require(audio.floatChannelData?[0])
        samples.update(repeating: 0, count: 24_000)
        var event = DialogueEvent(padID: 0, role: .stab, block: 0, slot: 0, accentTime: 0,
            startTime: 0, duration: 0.5, gainDB: 0, protected: false, chokeAt: nil, text: nil,
            transform: .native, padKey: 0, snareLanded: false)
        #expect(Self.bandOnsetMs(DialogueChop(event: event, buffer: audio)) == nil)
        for i in 2_400..<12_000 { samples[i] = Float(sin(Double(i) * 2 * .pi * 1000 / 48_000)) * 0.3 }
        #expect(Self.bandOnsetMs(DialogueChop(event: event, buffer: audio)) != nil)
        event.effect = .reversed
        #expect(Self.bandOnsetMs(DialogueChop(event: event, buffer: audio)) == nil)
    }

    struct Word {
        let text: String
        let index: Int
        /// Buffer frames (accepted words: the voiced core; raw words: the recogniser's times).
        let frames: Range<Int>
        let weight: Float
        let accepted: Bool
        let dropped: String?
    }

    @Test func probeSalienceOnCachedFilms() async throws {
        let path = URL(fileURLWithPath: "/private/tmp/liminal-salience-probe-\(getuid()).json")
        guard FileManager.default.fileExists(atPath: path.path),
              let config = try? JSONDecoder().decode(Config.self, from: Data(contentsOf: path)),
              URL(fileURLWithPath: config.checkout).standardizedFileURL.path == Self.checkout else { return }
        let directory = ArchiveClipStore.defaultDirectory()
        struct Catalog: Decodable { let clips: [ArchiveClip] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: directory.appending(path: "index.json")))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let bpm = config.bpm ?? 72
        let beat = 60 / bpm
        let baseSeed = config.seed ?? 1
        let modes = config.modes ?? ["T", "A"]
        var clips = catalog.clips.filter(\.hasAudio).sorted { $0.id < $1.id }
        if let only = config.only { clips = clips.filter { c in only.contains { c.id.contains($0) } } }
        if let n = config.films { clips = Array(clips.prefix(n)) }
        var provider: AppleSpeechTranscriptProvider?
        if let environment = AppleSpeechTranscriptProvider.liveEnvironment,
           await DialogueSpeechAssets.status(mode: .installedOnly, environment: environment) == .ready {
            provider = AppleSpeechTranscriptProvider.live()
        }
        let expectedChunks = max(1, config.chunks ?? 6)
        print("SALIENCE-CORPUS " + Self.json(["films": clips.map { clip -> [String: Any] in
            let sidecar = directory.appending(path: clip.fileName).deletingPathExtension().appendingPathExtension("provenance.json")
            let identity = (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return ["id": clip.id, "file": clip.fileName, "duration": clip.duration,
                    "sha256": identity?["sha256"] as? String ?? "missing", "url": identity?["url"] as? String ?? "missing"]
        },
            "chunks": expectedChunks, "bpm": bpm, "seed": baseSeed, "modes": modes]))
        print("SALIENCE-TRANSCRIBER \(provider == nil ? "none" : "apple") films=\(clips.count)")
        var snippetDir: URL?
        if let d = config.snippetDirectory {
            let url = URL(fileURLWithPath: d)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appending(path: ".write-probe")
            if (try? Data("ok".utf8).write(to: probe)) != nil { snippetDir = url; try? FileManager.default.removeItem(at: probe) }
        }
        print("SALIENCE-SNIPPET-DIR \(snippetDir?.path ?? "base64")")
        let footageIndex = DialogueSalienceIndex()
        var auditionCounts: [String: Int] = [:]
        var auditionLines = Set<String>()
        var snippets = 0
        let maxSnippets = config.maxSnippets ?? 60
        /// Words (normalized prefixes) whose hits always get a snippet, once per kind and gate per window.
        let focus = (config.focus ?? []).map { DialogueLineInterest.normalize($0) }
        func emitSnippet(_ name: String, _ data: Data?) {
            guard let data else { return }
            if let dir = snippetDir, (try? data.write(to: dir.appending(path: name))) != nil {
                print("SALIENCE-SNIPPET \(name) file")
            } else {
                print("SALIENCE-SNIPPET \(name) \(data.base64EncodedString())")
            }
        }

        /// What the recogniser hears in a played chop alone (0.6 s of silence either side).
        func reheard(_ chop: AVAudioPCMBuffer) async -> String? {
            guard let provider, let from = chop.floatChannelData else { return nil }
            let pad = Int(0.6 * format.sampleRate), n = Int(chop.frameLength)
            guard chop.format.sampleRate == format.sampleRate,
                  let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n + 2 * pad)),
                  let to = b.floatChannelData else { return nil }
            b.frameLength = AVAudioFrameCount(n + 2 * pad)
            for c in 0..<Int(format.channelCount) {
                to[c].update(repeating: 0, count: n + 2 * pad)
                to[c].advanced(by: pad).update(from: from[min(c, Int(chop.format.channelCount) - 1)], count: n)
            }
            let source = DialogueSource(contentID: "reheard", cueToken: 99, buffer: b, sourceStart: 0, rate: 1)
            return await provider.transcript(for: source, deadline: .now.advanced(by: .seconds(10)))?.words.map(\.text).joined(separator: " ")
        }

        for clip in clips {
            let usable = clip.duration - Self.windowSeconds - 1
            guard usable > 0 else {
                for chunk in 0..<expectedChunks {
                    print("SALIENCE-ATTEMPT " + Self.json(["film": clip.id, "chunk": chunk, "decode": "boundarySkip", "reason": "film shorter than 31 seconds"]))
                }
                continue
            }
            let margin = min(0.2 * clip.duration, 60)
            let lo = usable > 2 * margin ? margin : 0, hi = usable > 2 * margin ? usable - margin : usable
            let count = max(1, config.chunks ?? 6)
            let offsets = (0..<count).map { k in count == 1 ? (lo + hi) / 2 : lo + (hi - lo) * Double(k) / Double(count - 1) }
            for (chunk, offset) in offsets.enumerated() {
                print("SALIENCE-ATTEMPT " + Self.json(["film": clip.id, "chunk": chunk, "offset": Self.r3(offset), "decode": "attempted"]))
                let url = directory.appending(path: clip.fileName)
                guard let buffer = try? await ArchiveAudioDecoder.decode(url: url, sourceStart: offset, sourceLength: Self.windowSeconds,
                                                                         rate: 1, format: format),
                      let samples = buffer.floatChannelData?[0] else {
                    print("SALIENCE-ATTEMPT " + Self.json(["film": clip.id, "chunk": chunk, "offset": Self.r3(offset), "decode": "failed"]))
                    continue
                }
                let rate = buffer.format.sampleRate
                let frameCount = Int(buffer.frameLength)
                let speech = LofiSpeechFocus.classify(buffer, seconds: Self.windowSeconds)
                let baseSource = DialogueSource(contentID: clip.id, cueToken: 1, buffer: buffer, sourceStart: offset, rate: 1)
                var transcript: DialogueTranscript?
                var transcribeMs = 0.0
                if let provider {
                    let clock = ContinuousClock()
                    let t0 = clock.now
                    transcript = await provider.transcript(for: baseSource, deadline: .now.advanced(by: .seconds(25)))
                    transcribeMs = DialogueCueCoordinator.ms(clock.now - t0)
                }
                let analysis = DialogueEngine.analyze(baseSource, speech: speech)
                func film(_ frame: Int) -> Double { Self.r3(offset + Double(frame) / rate) }
                // Reference words: accepted (voiced cores) and raw (all recognised, with drop reasons).
                var accepted: [Word] = [], raw: [Word] = []
                var refinement: DialogueHierarchy.Refinement?
                if let transcript {
                    let r = DialogueHierarchy.refine(analysis, transcript: transcript)
                    footageIndex.record(source: baseSource, analysis: analysis, transcript: transcript)
                    refinement = r
                    let weights = DialogueLineInterest.wordWeights(r.words)
                    var weightByIndex: [Int: Float] = [:]
                    for (k, w) in r.words.enumerated() {
                        accepted.append(Word(text: w.text, index: w.index, frames: w.frames, weight: weights[k], accepted: true, dropped: nil))
                        weightByIndex[w.index] = weights[k]
                    }
                    for (i, w) in transcript.words.enumerated() {
                        let a = analysis.clock.frame(sourceSeconds: w.start), b = analysis.clock.frame(sourceSeconds: w.end)
                        raw.append(Word(text: w.text, index: i, frames: a..<max(a + 1, b), weight: weightByIndex[i] ?? -1,
                                        accepted: weightByIndex[i] != nil, dropped: r.dropped[i]))
                    }
                }
                var windowLine: [String: Any] = [
                    "film": clip.id, "title": String(clip.title.prefix(60)), "chunk": chunk, "offset": Self.r3(offset),
                    "decode": "success", "decodedFrames": Int(buffer.frameLength), "sampleRate": buffer.format.sampleRate,
                    "transcriptLocale": transcript?.locale ?? "missing", "transcriptModelVersion": transcript?.modelVersion ?? "missing", "transcriptWords": transcript?.words.count ?? 0, "model": provider == nil ? "unavailable" : "apple", "transcriptOutcome": transcript == nil ? "missing" : "result",
                    "duration": Self.r3(clip.duration), "transcribed": transcript != nil, "transcribeMs": Self.r3(transcribeMs),
                    "speechWindows": speech.filter { $0.speech > max(0.3, $0.singing, $0.music) }.count, "windows": speech.count,
                    "raw": raw.map { ["t": $0.text, "s": film($0.frames.lowerBound), "e": film($0.frames.upperBound),
                                      "w": Self.r3(Double($0.weight)), "drop": $0.dropped ?? ""] as [String: Any] },
                ]
                if let r = refinement {
                    let maximum = min(DialogueMotifTuning.lineSeconds.upperBound, DialogueMotifTuning.lineMaximumBars * 4 * beat)
                    let ranked = DialogueMotif.rankLines(units: r.units, rejections: r.rejections, rate: rate, maximum: maximum,
                                                         words: r.words, weights: DialogueLineInterest.wordWeights(r.words))
                    windowLine["ranked"] = ranked.prefix(10).map { l -> [String: Any] in
                        ["text": l.unit.text ?? "-", "interest": Self.r3(Double(l.interest)), "value": Self.r3(Double(l.value)),
                         "s": film(l.unit.frames.lowerBound), "e": film(l.unit.frames.upperBound), "level": l.unit.level.name]
                    }
                    windowLine["rankedCount"] = ranked.count
                    // Why each salient word's lines are or are not candidates (lexicon, names, numbers,
                    // acronyms): every line-level unit holding it, with the rank gates.
                    let rejected = Dictionary(r.rejections.map { ($0.unit, $0.reason.rawValue) }, uniquingKeysWith: { a, _ in a })
                    let weights = DialogueLineInterest.wordWeights(r.words)
                    windowLine["salient"] = r.words.indices.filter { k in
                        let rawText = r.words[k].text.filter { $0.isLetter }
                        return weights[k] >= 0.5 || (rawText.count >= 2 && rawText.count <= 5 && rawText.allSatisfy(\.isUppercase))
                    }.map { k -> [String: Any] in
                        let w = r.words[k]
                        let mid = (w.frames.lowerBound + w.frames.upperBound) / 2
                        let holders = r.units.filter { [.utterance, .phrase, .wordGroup, .stab].contains($0.level) && $0.frames.contains(mid) }
                        return ["t": w.text, "w": Self.r3(Double(weights[k])), "s": film(w.frames.lowerBound), "e": film(w.frames.upperBound),
                                "lexicon": Self.r3(Double(DialogueLineInterest.lexiconWeight(DialogueLineInterest.normalize(w.text)))),
                                "units": holders.map { u -> [String: Any] in
                                    let rank = ranked.firstIndex { $0.unit.id == u.id }
                                    return ["level": u.level.name, "sec": Self.r3(u.seconds(rate)), "nuclei": u.nuclei,
                                            "sound": Self.r3(Double(u.score.sound)), "rejected": rejected[u.id] ?? "",
                                            "rank": rank ?? -1, "interest": rank.map { Self.r3(Double(ranked[$0].interest)) } ?? -1,
                                            "text": u.text ?? "-"]
                                }]
                    }
                    let lineUnits = r.units.filter { [.utterance, .phrase, .wordGroup].contains($0.level) && $0.text != nil }
                    windowLine["lineUnits"] = lineUnits.count
                }
                var chosen: [String] = []
                var rendered = Set<String>()
                var perWindow = 0, controlsThisWindow = 0
                var mechanisms = Set<String>()

                var renderOutcomes: [String: [String: Int]] = [:]
                func recordRenders(mode: String, events: [DialogueEvent], chops: [DialogueChop]) {
                    var counts = renderOutcomes[mode] ?? ["planned": 0, "rendered": 0, "audible": 0]
                    counts["planned", default: 0] += events.count
                    for event in events {
                        if let chop = chops.first(where: { $0.event == event }) {
                            counts["rendered", default: 0] += 1
                            if let x = chop.buffer.floatChannelData?[0],
                               Self.peakDB(x, count: Int(chop.buffer.frameLength), range: 0..<Int(chop.buffer.frameLength), rate: chop.buffer.format.sampleRate) > -100 {
                                counts["audible", default: 0] += 1
                            }
                        }
                    }
                    renderOutcomes[mode] = counts
                }
                for mode in modes {
                    let useTranscript = mode == "T" ? transcript : nil
                    if mode == "T", transcript == nil { continue }
                    let seed = baseSeed &+ UInt64(chunk) &* 7919 &+ (clip.id.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) })
                    let bank = DialogueEngine.bank(analysis, transcript: useTranscript, seed: seed)
                    var memory = DialoguePerformanceMemory()
                    var loopEvents: [Int: [DialogueEvent]] = [:]
                    var loopMotif: [Int: DialogueMotif] = [:]
                    for piece in 0..<4 {
                        let take = piece / 2
                        let source = DialogueSource(contentID: clip.id, cueToken: piece + 1, buffer: buffer, sourceStart: offset, rate: 1)
                        let info = LofiTransportInfo(revision: 1, takeIndex: take, phraseAtTakeStart: 4 * take, origin: Double(take * 64) * beat,
                                                     beatDuration: beat, nextBeatDuration: nil, seed: seed, options: LofiOptions(tempo: bpm),
                                                     timing: nil)
                        let due = Double(piece * 32) * beat
                        let window = DialogueCueCoordinator.window(due: due, span: Self.windowSeconds, transport: info)
                        let snapshot = DialogueCueCoordinator.snapshot(info, window: window)
                        guard let planned = DialogueMotif.plan(source: source, analysis: analysis, bank: bank, transcript: useTranscript,
                                                               snapshot: snapshot, window: window,
                                                               earliestStart: due + DialogueCueCoordinator.commitMargin, memory: &memory,
                                                               seed: seed &+ UInt64(piece), cueToken: piece + 1, revision: 0)
                        else {
                            // No motif: the grammar's pad-bank fallback (`DialogueCueCoordinator.build`).
                            let playedBank = DialoguePerformer.bankForPiece(bank, snapshot: snapshot, window: window, memory: memory)
                            let plan = DialogueEngine.perform(playedBank, snapshot: snapshot, window: window,
                                                              earliestStart: due + DialogueCueCoordinator.commitMargin, memory: &memory,
                                                              seed: seed &+ UInt64(piece), cueToken: piece + 1, revision: 0)
                            print("SALIENCE-NOPLAN \(clip.id) chunk=\(chunk) mode=\(mode) piece=\(piece) fallbackEvents=\(plan.events.count)")
                            guard let playedBank else { continue }
                            let fallbackChops = DialogueChopRenderer.render(plan, bank: playedBank, source: source, analysis: analysis)
                            recordRenders(mode: mode, events: plan.events, chops: fallbackChops)
                            let tol = Int(Self.tolerance * rate)
                            for (e, event) in plan.events.enumerated() where playedBank.pads.indices.contains(event.padID) {
                                let pad = playedBank.pads[event.padID]
                                let played = pad.frames.lowerBound..<min(pad.frames.upperBound, pad.frames.lowerBound + max(1, Int(event.duration * rate * pad.transform.playbackRate)))
                                func covers(_ list: [Word]) -> [[String: Any]] {
                                    list.filter { $0.frames.upperBound > played.lowerBound && $0.frames.lowerBound < played.upperBound }.map { w in
                                        let ov = min(w.frames.upperBound, played.upperBound) - max(w.frames.lowerBound, played.lowerBound)
                                        return ["t": w.text, "cov": Self.r3(Double(ov) / Double(max(1, w.frames.count))), "s": film(w.frames.lowerBound),
                                                "e": film(w.frames.upperBound), "w": Self.r3(Double(w.weight)), "drop": w.dropped ?? "",
                                                "fn": DialogueLineInterest.functionWords.contains(DialogueLineInterest.normalize(w.text))]
                                    }
                                }
                                func inside(_ x: Int) -> Word? { accepted.first { $0.frames.lowerBound + tol < x && x < $0.frames.upperBound - tol } }
                                let peak = Self.peakDB(samples, count: frameCount, range: played, rate: rate)
                                let pre = Self.peakDB(samples, count: frameCount, range: (played.lowerBound - Int(0.03 * rate))..<played.lowerBound, rate: rate)
                                let post = Self.peakDB(samples, count: frameCount, range: played.upperBound..<(played.upperBound + Int(0.03 * rate)), rate: rate)
                                let tail = Self.peakDB(samples, count: frameCount, range: (played.upperBound - Int(0.012 * rate))..<played.upperBound, rate: rate)
                                let words = covers(accepted)
                                let heard = words.filter { ($0["cov"] as? Double ?? 0) >= 0.3 }
                                var hit: [String: Any] = [
                                    "film": clip.id, "chunk": chunk, "mode": mode, "piece": piece, "loop": -1, "ev": e, "line": "-", "interest": -1,
                                    "rendered": false, "renderAudible": false, "onsetEligible": false, "onsetStatus": "padUnmeasured", "usedT": playedBank.usedTranscript, "frag": event.padID, "kind": "pad", "ftext": pad.text ?? "",
                                    "level": pad.level.name, "role": pad.role.rawValue, "transform": pad.transform.name,
                                    "playS": film(played.lowerBound), "playE": film(played.upperBound), "dur": Self.r3(Double(played.count) / rate),
                                    "gate": -1, "gateEnd": event.chokeAt != nil ? "choke" : "natural", "stutter": false, "cell": "", "carried": false,
                                    "peak": Self.r3(peak), "preDB": Self.r3(pre - peak), "postDB": Self.r3(post - peak), "tailDB": Self.r3(tail - peak),
                                    "words": [], "rawWords": covers(raw),
                                    "functionOnly": !heard.isEmpty && heard.allSatisfy { ($0["fn"] as? Bool) == true },
                                ]
                                if let w = inside(played.lowerBound) {
                                    hit["startIn"] = ["word": w.text, "into": Self.r3(Double(played.lowerBound - w.frames.lowerBound) / rate),
                                                      "mech": "padEdge", "drop": ""] as [String: Any]
                                }
                                if let w = inside(played.upperBound) {
                                    hit["endIn"] = ["word": w.text, "short": Self.r3(Double(w.frames.upperBound - played.upperBound) / rate),
                                                    "mech": event.chokeAt != nil && pad.frames.upperBound >= w.frames.upperBound - tol ? "padChoke" : "padEdge",
                                                    "drop": ""] as [String: Any]
                                }
                                let actual = fallbackChops.first { $0.event == event }
                                let audible = actual.map { chop in
                                    chop.buffer.floatChannelData.map { Self.peakDB($0[0], count: Int(chop.buffer.frameLength), range: 0..<Int(chop.buffer.frameLength), rate: chop.buffer.format.sampleRate) > -100 } ?? false
                                } ?? false
                                hit["rendered"] = actual != nil; hit["renderAudible"] = audible
                                hit["words"] = audible ? words : []
                                print("SALIENCE-HIT " + Self.json(hit))
                            }
                            continue
                        }
                        for part in planned.parts {
                            let motif = part.motif
                            guard motif.source.contentID == clip.id, motif.source.sourceStart == offset else {
                                print("SALIENCE-CRATE \(clip.id) chunk=\(chunk) mode=\(mode) piece=\(piece) from=\(motif.source.contentID)")
                                continue
                            }
                            let units = useTranscript != nil ? (refinement?.units ?? analysis.units) : analysis.units
                            let lineUnitFrames = units.first { $0.id == motif.lineUnit }?.frames ?? motif.line.frames
                            // Original (untrimmed) lower edges and the kind of each edge.
                            var origLower: [Int: Int] = [:]
                            var lowerKind: [Int: String] = [:], upperKind: [Int: String] = [:]
                            origLower[0] = lineUnitFrames.lowerBound
                            lowerKind[0] = "lineStart"; upperKind[0] = "lineEnd"
                            for (k, id) in motif.pieces.enumerated() {
                                origLower[id] = k == 0 ? lineUnitFrames.lowerBound : motif.fragments[motif.pieces[k - 1]].frames.upperBound
                                lowerKind[id] = k == 0 ? "lineStart" : "pieceCut"
                                upperKind[id] = k == motif.pieces.count - 1 ? "lineEnd" : "pieceCut"
                                // Two to four ordered units (halves, syllables or letters) of a piece.
                                if let h = motif.halves[id], h.count >= 2 {
                                    for (j, u) in h.enumerated() {
                                        origLower[u] = j == 0 ? origLower[id] : motif.fragments[h[j - 1]].frames.upperBound
                                        lowerKind[u] = j == 0 ? lowerKind[id] : "halfSplit"
                                        upperKind[u] = j == h.count - 1 ? upperKind[id] : "halfSplit"
                                    }
                                }
                            }
                            let lineText = motif.text ?? "-"
                            let lineKey = "\(mode)|\(motif.loop)|\(lineText)"
                            if !chosen.contains(lineKey) { chosen.append(lineKey) }
                            let chops = DialogueChopRenderer.render(part.plan, bank: motif.bank, source: motif.source, analysis: motif.analysis,
                                                                    prerendered: motif.renders)
                            recordRenders(mode: mode, events: part.plan.events, chops: chops)
                            // Preserve short actual performed figures, with event timing and FX intact.
                            // Two distinct examples per class give four auditions when the real corpus offers them.
                            if !auditionLines.contains(mode + clip.id + (mode == "T" ? lineText : String(chunk))) {
                                for kind in (mode == "T" ? ["letter", "syllable"] : ["acoustic"]) where auditionCounts[kind, default: 0] < (mode == "T" ? 2 : 4) {
                                    let unitHits = chops.filter { chop in
                                        guard let id = chop.event.piece, motif.fragments.indices.contains(id) else { return false }
                                        return kind == "acoustic" || motif.fragments[id].kind.rawValue == kind
                                    }.sorted { $0.event.startTime < $1.event.startTime }
                                    let figure = unitHits.indices.first { i in
                                        guard kind != "acoustic", let id = unitHits[i].event.piece,
                                              let parent = motif.fragments[id].parent,
                                              let expected = motif.halves[parent], expected.count >= 2,
                                              i + expected.count <= unitHits.count else { return false }
                                        let ordered = Array(unitHits[i..<(i + expected.count)])
                                        guard ordered.compactMap({ $0.event.piece }) == expected else { return false }
                                        let steps = ordered.map { $0.event.block * 64 + $0.event.slot }
                                        let strides = zip(steps, steps.dropFirst()).map { $1 - $0 }
                                        guard Set(strides) == [1] || Set(strides) == [2] else { return false }
                                        let landing = (steps.last! / 4 + 1) * 4
                                        return chops.contains { $0.event.piece == parent && $0.event.block * 64 + $0.event.slot == landing }
                                    }
                                    let first = figure.map { unitHits[$0] } ?? (kind == "acoustic" ? unitHits.first : nil)
                                    if unitHits.count >= 2, let first {
                                        let start = first.event.startTime - 0.3
                                        let seconds = 6.0
                                        let parent = first.event.piece.flatMap { motif.fragments[$0].parent }
                                        let expected = parent.flatMap { motif.halves[$0] } ?? []
                                        let firstStep = first.event.block * 64 + first.event.slot
                                        let lastStep = figure.map { unitHits[$0 + expected.count - 1].event.block * 64 + unitHits[$0 + expected.count - 1].event.slot } ?? firstStep
                                        let landingStep = (lastStep / 4 + 1) * 4
                                        let relevant = chops.filter { chop in
                                            guard let id = chop.event.piece else { return false }
                                            let step = chop.event.block * 64 + chop.event.slot
                                            return (expected.contains(id) || id == parent) && step >= firstStep && step <= landingStep
                                        }.sorted { $0.event.startTime < $1.event.startTime }
                                        guard kind == "acoustic" || relevant.allSatisfy({ $0.event.startTime >= start && $0.event.startTime + Double($0.buffer.frameLength) / rate <= start + seconds }) else { continue }
                                        let n = Int(seconds * rate)
                                        if let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                                           let output = audio.floatChannelData {
                                            audio.frameLength = AVAudioFrameCount(n)
                                            for c in 0..<Int(format.channelCount) { output[c].update(repeating: 0, count: n) }
                                            for chop in chops {
                                                guard let input = chop.buffer.floatChannelData else { continue }
                                                let at = Int(((chop.event.startTime - start) * rate).rounded())
                                                let lo = max(0, -at), hi = min(Int(chop.buffer.frameLength), n - at)
                                                if hi > lo {
                                                    for c in 0..<Int(format.channelCount) {
                                                        for i in lo..<hi { output[c][at + i] += input[min(c, Int(chop.buffer.format.channelCount) - 1)][i] }
                                                    }
                                                }
                                            }
                                            auditionCounts[kind, default: 0] += 1
                                            let name = "audition-\(kind)-\(auditionCounts[kind]!)-\(clip.id)"
                                            emitSnippet(name + ".wav", Self.wav(audio))
                                            emitSnippet(name + "-context.wav", Self.wav(buffer, frames: motif.line.frames))
                                            print("SALIENCE-AUDITION " + Self.json(["name": name, "film": clip.id, "chunk": chunk,
                                                "line": lineText, "mode": mode, "kind": kind, "transportStart": start, "seconds": seconds,
                                                "parentText": parent.map { motif.fragments[$0].text ?? "" } ?? "",
                                                "parent": parent ?? -1, "spellUnits": expected, "complete": kind != "acoustic",
                                                "semanticClass": parent.map { ["psilocybin", "mescaline", "marijuana", "peyote", "ergot", "lysergic", "amphetamine", "cocaine", "heroin"].contains(DialogueLineInterest.normalize(motif.fragments[$0].text ?? "")) ? "drug" : "unclassified" } ?? "unclassified",
                                                "render": "performed-effects", "mixEvidence": "unavailable: isolated dialogue only",
                                                "events": relevant.map { ["id": $0.event.piece ?? -1, "step": $0.event.block * 64 + $0.event.slot,
                                                    "start": $0.event.startTime, "end": $0.event.startTime + Double($0.buffer.frameLength) / rate] }]))
                                            auditionLines.insert(mode + clip.id + (mode == "T" ? lineText : String(chunk)))
                                        }
                                    }
                                }
                            }
                            loopEvents[motif.loop, default: []] += part.plan.events
                            loopMotif[motif.loop] = motif
                            for (e, event) in part.plan.events.enumerated() {
                                guard let id = event.piece, motif.fragments.indices.contains(id), let played = event.sourceFrames else { continue }
                                let fr = motif.fragments[id]
                                let tol = Int(Self.tolerance * rate)
                                func covers(_ list: [Word]) -> [[String: Any]] {
                                    list.filter { $0.frames.upperBound > played.lowerBound && $0.frames.lowerBound < played.upperBound }.map { w in
                                        let ov = min(w.frames.upperBound, played.upperBound) - max(w.frames.lowerBound, played.lowerBound)
                                        return ["t": w.text, "cov": Self.r3(Double(ov) / Double(max(1, w.frames.count))),
                                                "s": film(w.frames.lowerBound), "e": film(w.frames.upperBound),
                                                "w": Self.r3(Double(w.weight)), "drop": w.dropped ?? "",
                                                "fn": DialogueLineInterest.functionWords.contains(DialogueLineInterest.normalize(w.text))]
                                    }
                                }
                                func inside(_ x: Int, _ list: [Word]) -> Word? {
                                    list.first { $0.frames.lowerBound + tol < x && x < $0.frames.upperBound - tol }
                                }
                                // Start edge: inside a word, and which mechanism put it there.
                                func startEdge(_ list: [Word]) -> [String: Any]? {
                                    guard let w = inside(played.lowerBound, list) else { return nil }
                                    let o = origLower[id] ?? fr.frames.lowerBound
                                    let mech = o <= w.frames.lowerBound + tol ? "onsetTrim" : (lowerKind[id] ?? "?")
                                    return ["word": w.text, "into": Self.r3(Double(played.lowerBound - w.frames.lowerBound) / rate),
                                            "left": Self.r3(Double(w.frames.upperBound - played.lowerBound) / rate), "mech": mech,
                                            "drop": w.dropped ?? "", "origInside": inside(o, list) != nil]
                                }
                                func endEdge(_ list: [Word]) -> [String: Any]? {
                                    guard let w = inside(played.upperBound, list) else { return nil }
                                    let natural = fr.frames.upperBound
                                    let gated = event.gateEnd != "natural" && natural >= w.frames.upperBound - tol
                                    let mech = gated ? "gate:\(event.gateEnd)" : (upperKind[id] ?? "?")
                                    return ["word": w.text, "short": Self.r3(Double(w.frames.upperBound - played.upperBound) / rate),
                                            "kept": Self.r3(Double(played.upperBound - w.frames.lowerBound) / rate), "mech": mech,
                                            "drop": w.dropped ?? ""]
                                }
                                let peak = Self.peakDB(samples, count: frameCount, range: played, rate: rate)
                                let pre = Self.peakDB(samples, count: frameCount, range: (played.lowerBound - Int(0.03 * rate))..<played.lowerBound, rate: rate)
                                let post = Self.peakDB(samples, count: frameCount, range: played.upperBound..<(played.upperBound + Int(0.03 * rate)), rate: rate)
                                let tail = Self.peakDB(samples, count: frameCount, range: (played.upperBound - Int(0.012 * rate))..<played.upperBound, rate: rate)
                                var hit: [String: Any] = [
                                    "film": clip.id, "chunk": chunk, "mode": mode, "piece": piece, "loop": motif.loop, "ev": e,
                                    "line": lineText, "interest": Self.r3(Double(motif.interest)), "usedT": motif.usedTranscript,
                                    "lineS": film(motif.line.frames.lowerBound), "lineE": film(motif.line.frames.upperBound),
                                    "frag": id, "kind": fr.kind.rawValue, "ftext": fr.text ?? "", "weight": Self.r3(Double(fr.weight)),
                                    "fragS": film(fr.frames.lowerBound), "fragE": film(fr.frames.upperBound),
                                    "origS": film(origLower[id] ?? fr.frames.lowerBound),
                                    "playS": film(played.lowerBound), "playE": film(played.upperBound),
                                    "dur": Self.r3(Double(played.count) / rate), "gate": event.gateSteps ?? -1, "gateEnd": event.gateEnd,
                                    "stutter": event.stutter, "effect": "\(event.effect)".prefix(9).description,
                                    "cell": event.cell.map { "\($0)" } ?? "", "slot": event.slot, "block": event.block,
                                    "weakLead": fr.weakLead, "hard": fr.hardOnset, "carried": motif.carried,
                                    "reorder": motif.reorderAllowed, "pieces": motif.pieces.count, "halves": motif.halves.count,
                                    "peak": Self.r3(peak), "preDB": Self.r3(pre - peak), "postDB": Self.r3(post - peak), "tailDB": Self.r3(tail - peak),
                                    "words": covers(accepted), "rawWords": covers(raw),
                                ]
                                // Planned source overlap earns no audible credit without an actual rendered signal.
                                let actual = chops.first(where: { $0.event == event })
                                let audible = actual.map { chop in
                                    chop.buffer.floatChannelData.map { Self.peakDB($0[0], count: Int(chop.buffer.frameLength),
                                        range: 0..<Int(chop.buffer.frameLength), rate: chop.buffer.format.sampleRate) > -100 } ?? false
                                } ?? false
                                let eligible = id != 0 && motif.isSubLine(id) && event.effect != .reversed
                                let onset = actual.flatMap { Self.bandOnsetMs($0) }
                                hit["rendered"] = actual != nil
                                hit["renderAudible"] = audible
                                hit["onsetEligible"] = eligible
                                hit["onsetStatus"] = !eligible ? "excluded" : (onset == nil ? "undetectable" : "detected")
                                if eligible, let onset { hit["onsetMs"] = Self.r3(onset) }
                                if !audible { hit["words"] = []; hit["rawWords"] = [] }

                                if let parent = fr.parent { hit["parentText"] = motif.fragments[parent].text ?? ""; hit["parent"] = parent; hit["spellUnits"] = motif.halves[parent] ?? [] }
                                let sEdge = startEdge(accepted), eEdge = endEdge(accepted)
                                if let sEdge { hit["startIn"] = sEdge }
                                if let eEdge { hit["endIn"] = eEdge }
                                if let s = startEdge(raw.filter { !$0.accepted }) { hit["startInDropped"] = s }
                                if let s = endEdge(raw.filter { !$0.accepted }) { hit["endInDropped"] = s }
                                if let s = startEdge(raw) { hit["startInRaw"] = s }
                                if let s = endEdge(raw) { hit["endInRaw"] = s }
                                let heard = (hit["words"] as? [[String: Any]] ?? []).filter { ($0["cov"] as? Double ?? 0) >= 0.3 }
                                let functionOnly = !heard.isEmpty && heard.allSatisfy { ($0["fn"] as? Bool) == true }
                                hit["functionOnly"] = functionOnly
                                let focused = focus.first { term in heard.contains { DialogueLineInterest.normalize(($0["t"] as? String) ?? "").hasPrefix(term) } }
                                let suspect = sEdge != nil || eEdge != nil || hit["startInDropped"] != nil || hit["endInDropped"] != nil || functionOnly
                                    || focused != nil
                                let key = "\(mode)|\(motif.loop)|\(id)|\(event.gateEnd)|\(Int((Double(played.count) / rate * 50).rounded()))"
                                let control = !suspect && controlsThisWindow < 1 && e % 5 == 2
                                // One snippet per mechanism per window and mode (gate, half split, piece cut, ...).
                                let primary = focused.map { "\(mode):focus:\($0):\(fr.kind.rawValue):\(event.gateEnd):\(event.gateSteps ?? -1)" }
                                    ?? (mode + ":" + ((eEdge?["mech"] as? String) ?? (sEdge?["mech"] as? String) ?? (functionOnly ? "fn" : "dropped")))
                                if suspect || control, !rendered.contains(key), suspect ? ((perWindow < 8 || focused != nil) && !mechanisms.contains(primary)) : true,
                                   snippets < maxSnippets,
                                   let chop = chops.first(where: { $0.event == event }) {
                                    rendered.insert(key)
                                    if suspect { perWindow += 1; mechanisms.insert(primary) } else { controlsThisWindow += 1 }
                                    snippets += 1
                                    if let heard = await reheard(chop.buffer) { hit["reheard"] = heard } else { hit["reheard"] = "" }
                                    hit["control"] = control
                                    let tag = [focused.map { "focus-" + $0 }, sEdge?["mech"] as? String, eEdge?["mech"] as? String, functionOnly ? "fn" : nil,
                                               control ? "control" : nil].compactMap { $0 }
                                        .joined(separator: "+").replacingOccurrences(of: ":", with: "-")
                                    let name = String(format: "%03d-%@-%.1fs-%@-%@", snippets, String(clip.id.prefix(24)), offset + Double(played.lowerBound) / rate,
                                                      mode, tag.isEmpty ? "hit" : tag)
                                    hit["snippet"] = name
                                    let pad = Int(0.35 * rate)
                                    emitSnippet(name + "-played.wav", Self.wav(chop.buffer))
                                    emitSnippet(name + "-context.wav", Self.wav(buffer, frames: (motif.line.frames.lowerBound - pad)..<(motif.line.frames.upperBound + pad)))
                                }
                                print("SALIENCE-HIT " + Self.json(hit))
                            }
                        }
                    }
                    // Variety per loop (D127, `DialogueChopMetrics`): the chop beat's unmarked same-cut
                    // pairs and longest run, distinct cuts per 2-bar cell of the chop beat and build,
                    // onsets per bar and dry occupancy per 8-bar section.
                    for (loop, events) in loopEvents.sorted(by: { $0.key < $1.key }) {
                        guard let motif = loopMotif[loop] else { continue }
                        let drums = DialogueChopMetrics.DrumSteps(kicks: [], snares: [])
                        let chop = events.filter { $0.cell == .chopBeat }.sorted { $0.startTime < $1.startTime }
                        let same = zip(chop, chop.dropFirst()).filter { $0.piece == $1.piece && !$1.stutter }.count
                        var run = chop.isEmpty ? 0 : 1, longest = run
                        for (a, b) in zip(chop, chop.dropFirst()) { run = a.piece == b.piece ? run + 1 : 1; longest = max(longest, run) }
                        let chopSection = DialogueChopMetrics.section(events, loop: loop, bars: 2..<6, drums: drums)
                        let buildSection = DialogueChopMetrics.section(events, loop: loop, bars: 6..<8, drums: drums)
                        let placed = DialogueChopMetrics.placed(events, loop: loop)
                        let onsets = (0..<16).map { b in placed.filter { $0.s / 16 == b }.count }
                        let cells = stride(from: 2, to: 8, by: 2).map { b in
                            Set(placed.filter { $0.s / 16 == b || $0.s / 16 == b + 1 }.compactMap(\.e.piece)).count
                        }
                        let section = 32 * beat
                        func dry(_ e: DialogueEvent) -> Double { Double(e.sourceFrames?.count ?? 0) / (rate * e.transform.playbackRate) }
                        let occupancy = (0..<2).map { k in
                            Self.r3(placed.filter { $0.s / 128 == k }.map { dry($0.e) }.reduce(0, +) / section)
                        }
                        let offered = motif.pieces.count + motif.halves.values.map(\.count).reduce(0, +)
                        // Without the hook's own skeleton repeats (`DialogueChopMetrics.fillRepeats`).
                        let chopPlaced = placed.filter { (2..<6).contains($0.s / 16) }
                        let fillSame = Int((DialogueChopMetrics.fillRepeats(events, loop: loop, bars: 2..<6, motif: motif)
                            * Double(max(0, chopPlaced.count - 1))).rounded())
                        let line: [String: Any] = [
                            "film": clip.id, "chunk": chunk, "mode": mode, "loop": loop, "line": motif.text ?? "-",
                            "chopHits": chop.count, "chopSame": same, "chopSameFill": fillSame, "chopPairs": max(0, chop.count - 1), "chopLongestRun": longest,
                            "chopPer2Bars": Self.r3(chopSection.piecesPer2Bars), "chopLeast2Bars": chopSection.leastPer2Bars,
                            "buildPer2Bars": Self.r3(buildSection.piecesPer2Bars), "cells2Bars": cells,
                            "onsetsPerBar": onsets, "occupancy": occupancy, "offered": offered, "pieces": motif.pieces.count,
                        ]
                        print("SALIENCE-LOOP " + Self.json(line))
                    }
                }
                windowLine["chosen"] = chosen
                windowLine["renderOutcomes"] = renderOutcomes
                print("SALIENCE-WINDOW " + Self.json(windowLine))
            }
        }
        Self.simulateFootage(clips: clips, index: footageIndex)
        print("SALIENCE-DONE snippets=\(snippets)")
    }
    /// Paired production-policy requests. Fresh-index sampling measures the targeting policy before
    /// exhaustion; evolving playback independently consumes contained lines and updates cache history.
    /// Never present finite-index depletion as an indefinitely repeatable targeting success.
    static func simulateFootage(clips: [ArchiveClip], index: DialogueSalienceIndex) {
        for evolving in [false, true] {
            for indexed in [false, true] {
                let ledger = DialogueLineLedger()
                var history = clips
                var weaver = FootageWeaver(seed: 0x5A11_EACE, timing: .standard)
                var rng = MusicRNG(seed: 0x5A11_EACE)
                var salient = 0, random = 0, consumed = 0, picks = 0
                var shares: [String: Int] = [:]
                for piece in 0..<500 {
                    let request = FootageWeaver.Request(index: piece, slot: piece % 2, start: Double(piece) * 48,
                                                       fadeIn: 2, length: 48, recipe: .plain(.window), seed: rng.unit(),
                                                       rate: 0.75, warp: 0, level: 0.5, swell: 0, sound: true)
                    guard let selection = FootageSalience.prepare(request, clips: history, weaver: &weaver,
                                                                   rng: &rng, elapsed: request.start, index: index,
                                                                   ledger: ledger, indexed: indexed),
                          let cue = ArchiveAudioCuePlan(piece: selection.piece, clipDuration: selection.clip.duration) else { continue }
                    picks += 1
                    let clip = selection.clip
                    shares[clip.id, default: 0] += 1
                    let end = cue.sourceStart + min(cue.sourceLength, DialogueTuning.analysisSeconds * Double(cue.rate))
                    let contained = index.unplayed(contentID: clip.id, ledger: ledger).filter {
                        $0.start >= cue.sourceStart && $0.end <= end
                    }
                    if !contained.isEmpty { salient += 1 }
                    // Random share means the original catalog start survived, including infeasible picks.
                    if !selection.targeted { random += 1 }
                    weaver.didPrepare(selection.piece)
                    _ = weaver.tick(elapsed: request.start + request.fadeIn, conditions: .init(), hasClip: true,
                                    grid: LofiTakeGrid(origin: 0, beatDuration: 60 / 72), ready: { _ in true })
                    if evolving, let i = history.firstIndex(where: { $0.id == clip.id }) {
                        history[i].shownStarts.append(selection.piece.segmentStart)
                        history[i].lastUsed = Date(timeIntervalSinceReferenceDate: (clips.map { $0.recency.timeIntervalSinceReferenceDate }.max() ?? 0) + Double(piece + 1))
                        history[i].useCount += 1
                        // Conservative proxy: count only complete salient lines heard in the actual cue.
                        // Playback may choose fewer lines; this is explicitly a depletion stress test.
                        for line in contained { ledger.record(contentID: clip.id, seconds: line.seconds); consumed += 1 }
                    }
                }
                print("SALIENCE-FOOTAGE " + json(["indexed": indexed, "policy": evolving ? "evolvingPlayback" : "freshIndex",
                    "picks": picks, "salient": salient, "random": random, "consumed": consumed, "filmShares": shares]))
            }
        }
    }

}
