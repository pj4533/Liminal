import AudioKit
import AudioKitEX
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Liminal

/// Offline execution of the same sources, buses and dynamics as Lo-Fi playback. The export
/// is opt-in, and private sources must also be explicitly selected by the caller.
struct LofiMixRenderTests {
    nonisolated struct Config: Decodable {
        let runToken: String
        var out: URL {
            URL.cachesDirectory.appending(path: "Liminal/OfflineAudio/\(runToken)", directoryHint: .isDirectory)
        }
        let revision: String
        let trackedDiffSHA256: String?
        let scale: ScaleType?
        let seed: UInt64
        let tempo: Double
        let bars: Int
        let explicitFootageSuffix: String?
        let cachedFootage: Bool
        let filmReel: Bool?
        let receiver: String
        let noFootage: Bool
        let privateDrums: Bool
        let drumName: String?
        let nextDrumName: String?
        let block: Int
        let postrollBeats: Int?
        let limiter: String?
        let checkout: String?
        let hooks: [String: String]?
        let sameFilm: Bool?
    }

    @MainActor @Test func captureCombinedMix() async throws {
        let path = URL(fileURLWithPath: "/private/tmp/liminal-lofi-audio-config-\(getuid()).json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: path))
        // The config path is shared by every worktree; only the checkout that asked may capture.
        if let checkout = config.checkout {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            guard root.standardizedFileURL.path == URL(fileURLWithPath: checkout).standardizedFileURL.path else { return }
        }
        let base = try #require(URL(string: config.receiver))
        try #require(base.host == "127.0.0.1")
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.finishTasksAndInvalidate()
            try? FileManager.default.removeItem(at: config.out)
        }
        do {
            try await capture(config, receiver: base, session: session)
        } catch {
            try? await export(config, to: base, session: session)
            throw error
        }
        try await export(config, to: base, session: session)
    }

    @MainActor private func export(_ config: Config, to base: URL, session: URLSession) async throws {
        let files = try FileManager.default.contentsOfDirectory(at: config.out, includingPropertiesForKeys: nil)
        for url in files where !url.lastPathComponent.hasPrefix("input.") {
            var request = URLRequest(url: base.appending(path: url.lastPathComponent))
            request.httpMethod = "PUT"
            let (_, response) = try await session.upload(for: request, fromFile: url)
            try #require((response as? HTTPURLResponse)?.statusCode == 201, "Upload \(url.lastPathComponent)")
        }
    }

    @MainActor private func capture(_ config: Config, receiver: URL, session: URLSession) async throws {
        try FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        LofiCaptureHooks.begin(options: config.hooks ?? ["masterProfile": "lofi"])
        defer { LofiCaptureHooks.end() }
        let audio = AudioEngine()
        let format = AudioKit.Settings.audioFormat
        let options = LofiOptions(tempo: config.tempo, scale: config.scale)
        let tempo = options.safeTempo
        let clock = LofiClock(tempo: tempo, sampleRate: format.sampleRate)
        let archive = ArchiveVoice(format: format)
        let bus = LofiBus(gain: 1, dialogue: archive.chopOutput)
        let duck = bus.duckTargets
        archive.attachMusicDuck(lead: duck.lead, mids: duck.mids, space: duck.space)
        let mix = MixBus(layers: [archive.strip], delayTime: 1.7)
        let master = LofiMasterBus(archiveAndAmbient: mix.output, lofi: bus.output)
        var limiterID = "system-dynamics-and-peak-limiter"
        var limiterNode = master.limiter.avAudioNode
        #if DEBUG
        if let identity = config.limiter {
            let candidate = try await LofiProviderProbe.makeComparisonLimiter(identity: identity, input: master.trim)
            audio.output = Fader(candidate, gain: dbToGain(LofiMasterBus.safetyTrimDB))
            limiterID = candidate.providerID
            limiterNode = candidate.avAudioNode
        } else {
            audio.output = master.output
        }
        #else
        try #require(config.limiter == nil, "The optional offline AU comparison requires a Debug test host")
        audio.output = master.output
        #endif
        try audio.avEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

        var sourceHash = "public-test-fixture-v1"
        var drums: LofiDrumTake
        if config.privateDrums {
            let eligible = LofiDrumLibrary.assets().filter { config.drumName == nil || $0.entry.name == config.drumName }
            let candidates = eligible.sorted {
                let a = abs($0.entry.bpm - tempo), b = abs($1.entry.bpm - tempo)
                return a == b ? $0.entry.name < $1.entry.name : a < b
            }
            let asset = try #require(candidates.first, "Install the requested private drum take before capturing")
            let recording = try LofiDrumLibrary.load(asset)
            drums = try LofiDrumTake(recording: recording, clock: clock)
            sourceHash = SHA256.hash(data: try Data(contentsOf: asset.url, options: .mappedIfSafe)).description
        } else {
            drums = try LofiDrumTake(recording: drumFixture(clock: clock), clock: clock)
        }
        var footageHash = config.noFootage ? "none" : "public-formant-fixture-v1"
        var reel: [(buffer: AVAudioPCMBuffer, title: String, offset: Double, id: String)] = []
        let cue: AVAudioPCMBuffer?
        if config.noFootage {
            cue = nil
        } else if let suffix = config.explicitFootageSuffix {
            let (download, response) = try await session.download(from: receiver.appending(path: "input"))
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            let source = config.out.appending(component: "input").appendingPathExtension(String(suffix.dropFirst()))
            try FileManager.default.moveItem(at: download, to: source)
            footageHash = SHA256.hash(data: try Data(contentsOf: source, options: .mappedIfSafe)).description
            cue = try await ArchiveAudioDecoder.decode(url: source, sourceStart: 0, sourceLength: 13, rate: 1,
                                                        format: format)
        } else if config.filmReel == true || config.sameFilm == true {
            let directory = ArchiveClipStore.defaultDirectory()
            struct Catalog: Decodable { let clips: [ArchiveClip] }
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: directory.appending(path: "index.json")))
            var rng = MusicRNG(seed: config.seed)
            let clips = catalog.clips.filter { $0.hasAudio }.shuffled(using: &rng)
            var hashes: [String] = []
            for clip in clips {
                let seconds = min(32 * clock.beatDuration, clip.duration)
                guard seconds >= 5 else { continue }
                let offset = max(0, clip.duration - seconds - 0.1) * rng.range(0.12...0.78)
                let url = directory.appending(path: clip.fileName)
                guard let buffer = try? await ArchiveAudioDecoder.decode(url: url, sourceStart: offset,
                    sourceLength: seconds, rate: 1, format: format) else { continue }
                hashes.append(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).description)
                reel.append((buffer, clip.title, offset, clip.id))
                if config.sameFilm == true || reel.count >= (config.bars + 7) / 8 { break }
            }
            cue = try #require(reel.first?.buffer, "No cached film reel with audio")
            footageHash = hashes.joined(separator: "/")
        } else if config.cachedFootage {
            let directory = ArchiveClipStore.defaultDirectory()
            let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var selected: AVAudioPCMBuffer?
            for url in sources.prefix(12) {
                if let decoded = try? await ArchiveAudioDecoder.decode(url: url, sourceStart: 0, sourceLength: 13,
                                                                       rate: 1, format: format) {
                    selected = decoded
                    footageHash = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).description
                    break
                }
            }
            let decoded: AVAudioPCMBuffer = try #require(selected, "No playable audio in the local archive clip cache")
            cue = decoded
        } else {
            cue = try voiceFixture(clock: clock)
        }
        let phrases = config.bars / 4
        let scoreFrames = phrases * clock.frameCount
        let postroll = clock.frame(at: Double(config.postrollBeats ?? 0))
        let frames = scoreFrames + postroll
        var tail: LofiRenderer.Tail?
        var score: [[String: Any]] = []
        var auxiliary = try ["echo", "room", "color"].map {
            try Self.file("fx-\($0)-raw", format: format, directory: config.out)
        }
        let takeFrames = Int(drums.buffer.frameLength)
        var kicks: [[String: Any]] = []
        /// The take scheduled at each take index, for the dialogue transport and the landmark report.
        var takes: [Int: LofiDrumTake] = [:]
        for i in 0..<phrases {
            if i == LofiDrumTake.phraseCount, let name = config.nextDrumName {
                let asset = try #require(LofiDrumLibrary.assets().first { $0.entry.name == name })
                drums = try LofiDrumTake(recording: LofiDrumLibrary.load(asset), clock: clock)
                sourceHash += "/" + SHA256.hash(data: try Data(contentsOf: asset.url, options: .mappedIfSafe)).description
            }
            if i.isMultiple(of: LofiDrumTake.phraseCount) {
                bus.schedule(drums)
                takes[i / LofiDrumTake.phraseCount] = drums
                LofiCaptureHooks.appendReport("landmarks", Self.landmarkReport(drums, take: i / LofiDrumTake.phraseCount,
                                                                              offset: i * clock.frameCount, limit: scoreFrames))
                kicks += drums.kicks.compactMap { hit in
                    let frame = i * clock.frameCount + hit.frame
                    return frame < scoreFrames ? ["frame": frame, "strength": hit.strength] : nil
                }
            }
            let request = LofiPlayback.Request(seed: config.seed, index: i, options: options)
            let phrase = try LofiRenderer.render(seed: request.compositionSeed, section: request.section,
                                                 options: request.options, sampleRate: format.sampleRate,
                                                 drift: .init(seed: request.seed), startBeat: Double(i) * LofiClock.beats,
                                                 drums: drums, drumStartBeat: request.drumStartBeat, carry: tail,
                                                 captureEffects: true)
            tail = phrase.tail
            bus.schedule(phrase)
            if i == phrases - 1, postroll > 0 {
                bus.wet.player.scheduleBuffer(phrase.fallbackWet, at: nil, options: [], completionHandler: nil)
            }
            for j in auxiliary.indices { try auxiliary[j].write(from: phrase.effectReturns[j]) }
            var events: [String: Any] = [
                "section": String(describing: phrase.score.section),
                "program": phrase.score.preset.name,
                "tonic": phrase.score.tonic, "scale": phrase.score.scale.rawValue,
                "range": [i * clock.frameCount, (i + 1) * clock.frameCount],
                "endingRest": [clock.frame(at: phrase.score.endingRest.lowerBound) + i * clock.frameCount,
                                   clock.frame(at: phrase.score.endingRest.upperBound) + i * clock.frameCount],
                "notes": phrase.score.notes.map {
                    ["role": String(describing: $0.part), "midi": $0.midi, "velocity": $0.velocity,
                     "on": clock.frame(at: $0.beat) + i * clock.frameCount,
                     "off": clock.frame(at: $0.beat + $0.length) + i * clock.frameCount,
                     "send": $0.send, "color": $0.color]
                },
            ]
            if let edit = phrase.score.virtualRecord {
                events["virtualRecord"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit))
            }
            score.append(events)
        }
        auxiliary.removeAll()

        let nodes: [(String, AVAudioNode)] = [
            ("drums", bus.drums.player), ("bass", bus.bass.player), ("dry", bus.dryFader.avAudioNode),
            ("texture", bus.textureFader.avAudioNode), ("wet", bus.wetFader.avAudioNode),
            ("dialogue-fx", archive.chopWet.avAudioNode), ("film-soundtrack", archive.bed.avAudioNode), ("dialogue-chops", archive.chopOutput.avAudioNode), ("footage-dry", mix.dryBus.avAudioNode), ("footage-delay", mix.delayReturn.avAudioNode),
            ("footage-room", mix.reverbReturn.avAudioNode), ("lofi", bus.output.avAudioNode),
            ("footage", mix.output.avAudioNode), ("pre-master", master.input.avAudioNode),
            ("glue", master.glue.avAudioNode),
        ] + LofiCaptureHooks.taps.map { ($0.name, $0.node) }
        let tapNames = nodes.map(\.0)
        try #require(Set(tapNames).count == tapNames.count, "Duplicate capture tap names: \(tapNames)")
        try audio.start()
        defer { audio.stop() }
        let capture = try nodes.map { name, node in
            (node, try TapFile(name: name, format: format, directory: config.out, frames: frames))
        }
        for (node, sink) in capture {
            node.installTap(onBus: 0, bufferSize: 1024, format: nil, block: sink.tap)
        }
        var tapsInstalled = true
        let sinks = capture.map(\.1)
        var tapWaits = 0
        defer { if tapsInstalled { for (node, _) in capture { node.removeTap(onBus: 0) } } }
        try FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        let finalFile = try Self.file("master", format: format, directory: config.out)
        let work = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))

        let conductor = MusicConductor(layers: [], mix: mix, seed: config.seed, pinned: config.scale, archive: archive)
        conductor.beginOffline(archiveBeatDuration: clock.beatDuration, pattern: .choose(seed: config.seed, phrase: 0))
        for player in bus.players { player.play() }
        // In the two-take audition the film is audible through each drum fill.
        let cueBeats: [Double]
        if !reel.isEmpty { cueBeats = stride(from: 0, to: config.bars * 4, by: 32).map(Double.init) }
        else { cueBeats = config.nextDrumName == nil ? [5] : [5] + stride(from: 26, to: config.bars * 4, by: 32).map(Double.init) }
        let cueFrames = cue == nil ? [] : cueBeats.map { clock.frame(at: $0) }.filter { $0 < scoreFrames }
        var chopEvents: [[String: Any]] = []
        var dialogueTimings: [[String: Any]] = []
        // `dialogue=engine` (default) plans each cue with the coordinator's core against a transport
        // built from the capture clock; `dialogue=legacy` keeps the old sampler for A/B captures.
        let dialogueMode = LofiCaptureHooks.option("dialogue") ?? "engine"
        let director = DialogueDirector()
        var memory = DialoguePerformanceMemory()
        var cueIndex = 0
        var cursor = 0
        var noProgress = 0
        let controlFrames = Int((format.sampleRate * 0.02).rounded())
        var nextControl = 0
        let t0 = Date()
        while cursor < frames {
            let time = Double(cursor) / format.sampleRate
            if cueIndex < cueFrames.count, cursor == cueFrames[cueIndex], let cue = reel.isEmpty ? cue : reel[cueIndex % reel.count].buffer {
                if dialogueMode == "legacy" {
                    let started = ContinuousClock.now
                    let hits = LofiDialogueSampler.prepareFootage(cue, grid: .init(origin: 0, beatDuration: clock.beatDuration),
                        cueStart: time, duration: Double(cue.frameLength) / format.sampleRate,
                        seed: config.seed &+ UInt64(cueIndex))
                    let elapsed = ContinuousClock.now - started
                    let totalMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                    dialogueTimings.append(["cue": cueIndex, "totalMs": totalMs])
                    chopEvents += hits.map { hit in
                        ["frame": Int((hit.time * format.sampleRate).rounded()), "sourceStart": hit.source.lowerBound,
                         "sourceEnd": hit.source.upperBound, "speed": hit.speed, "articulation": hit.articulation.rawValue, "cue": cueIndex, "reversed": hit.reversed,
                         "durationFrames": Int(hit.buffer.frameLength)]
                    }
                    archive.begin(.init(buffer: cue, gain: 0.9, fadeIn: 0.5, label: "offline fixture",
                                        activity: ArchiveAudioMath.activity(cue), chops: hits), now: time)
                } else {
                    let token = cueIndex + 1
                    let film = reel.isEmpty ? nil : reel[cueIndex % reel.count]
                    let source = DialogueSource(contentID: film?.id ?? "fixture", cueToken: token, buffer: cue,
                                                sourceStart: film?.offset ?? 0, rate: 1)
                    let seconds = Double(cue.frameLength) / format.sampleRate
                    let reuse = director.cached(source)
                    var speech = reuse?.analysis.speech ?? []
                    var classifyMs = 0.0
                    if reuse == nil {
                        let started = ContinuousClock.now
                        speech = await LofiSpeechFocus.classify(cue, seconds: seconds, budget: DialogueCueCoordinator.classifyBudget)
                        classifyMs = DialogueCueCoordinator.ms(ContinuousClock.now - started)
                    }
                    let take = Int((Double(cursor) / clock.framesPerBeat + 0.01) / 64)
                    let info = LofiTransportInfo(revision: 1, takeIndex: take, phraseAtTakeStart: take * LofiDrumTake.phraseCount,
                                                 origin: Double(take * takeFrames) / format.sampleRate,
                                                 beatDuration: clock.beatDuration, nextBeatDuration: nil, seed: config.seed,
                                                 options: options, timing: (takes[take] ?? drums).timing)
                    let window = DialogueCueCoordinator.window(due: time, span: seconds, transport: info)
                    let built = DialogueCueCoordinator.build(source: source, speech: speech, transcript: nil, transport: info,
                                                             window: window, earliestStart: time + DialogueCueCoordinator.commitMargin,
                                                             memory: memory, seed: config.seed &+ UInt64(cueIndex),
                                                             classifyMs: classifyMs, reuse: reuse)
                    if reuse == nil { director.store(source, analysis: built.analysis, bank: built.bank) }
                    memory = built.memory
                    DialogueCueCoordinator.report(built, cue: token, lead: built.firstStart.map { $0 - time })
                    dialogueTimings.append(built.timings.dictionary(cue: cueIndex))
                    let families = Dictionary(built.plan.blocks.map { ($0.phrase, $0.family.rawValue) }, uniquingKeysWith: { a, _ in a })
                    let bankID = String(built.plan.bankID, radix: 16)
                    chopEvents += built.chops.map { chop in
                        let e = chop.event
                        let pad = built.bank?.pad(e.padID)
                        return ["frame": Int((e.startTime * format.sampleRate).rounded()),
                                "sourceStart": pad?.frames.lowerBound ?? 0, "sourceEnd": pad?.frames.upperBound ?? 0,
                                "speed": e.transform.playbackRate, "articulation": e.role.rawValue, "cue": cueIndex,
                                "reversed": false, "durationFrames": Int(chop.buffer.frameLength),
                                "padID": e.padID, "role": e.role.rawValue, "family": families[e.block] ?? "",
                                "block": e.block, "protected": e.protected,
                                "accentFrame": Int((e.accentTime * format.sampleRate).rounded()),
                                "transform": e.transform.name, "text": e.text.map { $0 as Any } ?? NSNull(),
                                "committedFrame": cursor, "bankID": bankID, "slot": e.slot] as [String: Any]
                    }
                    archive.begin(.init(buffer: cue, gain: 0.9, fadeIn: 0.5, label: "offline fixture",
                                        activity: ArchiveAudioMath.activity(cue), token: token), now: time)
                    archive.perform(.init(token: token, revision: 0, chops: built.chops), now: time)
                }
                cueIndex += 1
            }
            if cursor > 0 && cursor < scoreFrames && cursor.isMultiple(of: clock.frameCount) {
                mix.syncDelay(toBeatDuration: clock.beatDuration,
                              pattern: .choose(seed: config.seed, phrase: cursor / clock.frameCount), now: time)
            }
            if cursor == nextControl {
                conductor.advance(to: time)
                nextControl += controlFrames
            }
            let nextCue = cueIndex < cueFrames.count ? cueFrames[cueIndex] : frames
            let remaining = nextCue - cursor
            let phraseBoundary = (cursor / clock.frameCount + 1) * clock.frameCount
            let size = min(config.block, remaining, nextControl - cursor, phraseBoundary - cursor)
            let status = try audio.avEngine.renderOffline(AVAudioFrameCount(size), to: work)
            if status == .success {
                let written = Int(work.frameLength)
                if written > 0 {
                    try finalFile.write(from: work)
                    cursor += written
                    noProgress = 0
                    if Self.awaitTaps(sinks, cursor: cursor) { tapWaits += 1 }
                    continue
                }
            }
            noProgress += 1
            try #require(noProgress < 8, "Manual rendering stopped advancing: \(status.rawValue)")
        }
        // AVAudioEngine taps deliver complete internal blocks. Pull past the exact
        // endpoint to deliver the last block, then retain only its requested prefix.
        let flushBlocks = Int(ceil(0.2 * format.sampleRate / 4096))
        for _ in 0..<flushBlocks { _ = try audio.avEngine.renderOffline(4096, to: work) }
        for (node, _) in capture { node.removeTap(onBus: 0) }
        tapsInstalled = false
        for (_, sink) in capture { try sink.finish(frames: frames) }
        print("Capture taps: the render waited \(tapWaits) times for \(sinks.count) tap files")
        let wall = Date().timeIntervalSince(t0)
        LofiCaptureHooks.runFinishers()
        for (name, data) in LofiCaptureHooks.files {
            try data.write(to: config.out.appending(path: name), options: .atomic)
        }
        var manifest: [String: Any] = [
            "schema": "liminal-lofi-capture-v2", "frames": frames, "sampleRate": format.sampleRate,
            "block": config.block, "seed": String(config.seed), "bpm": tempo, "beatsPerBar": 4,
            "dialogueOnMusicBus": true, "masterCalibration": "fixed-nominal", "archiveMix": "conductor",
            "clockOriginFrame": 0, "postrollFrames": postroll, "scoredFrames": scoreFrames,
            "filmReel": reel.map { ["title": $0.title, "sourceSeconds": $0.offset] },
            "hasFootage": cue != nil, "footageStartFrame": cueFrames.first ?? clock.frame(at: 5), "footageStartFrames": cueFrames,
            "privateSources": config.privateDrums || config.cachedFootage || !reel.isEmpty || config.explicitFootageSuffix != nil,
            "drumSourceHash": sourceHash, "footageSourceHash": footageHash, "gitRevision": config.revision,
            "renderedSeconds": Double(frames) / format.sampleRate, "mixWallSeconds": wall,
            "providers": ["kit": "full-take-linked-varispeed", "acoustic": "native-resampled-wav-v2",
                          "room": "native-parallel-rack-v2", "master": limiterID],
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "trackedDiffSHA256": config.trackedDiffSHA256 ?? "unknown",
            "scaleSetting": config.scale?.rawValue ?? "Auto", "drumTakeFrames": takeFrames,
            "topology": nodes.map(\.0) + ["master"],
            "latencySamples": ["reportedGlue": master.glue.avAudioNode.latency * format.sampleRate,
                               "reportedLimiter": limiterNode.latency * format.sampleRate],
            "kickCandidates": kicks, "dialogueChops": chopEvents,
            "sections": ["drums": ["drums"], "bass": ["bass"], "mids": ["texture"], "lead": ["dry"],
                         "space": ["wet"], "dialogue": ["dialogue-chops"], "bed": ["footage"]],
            "grid": ["beatFrames": clock.framesPerBeat, "barFrames": clock.framesPerBeat * 4,
                     "phraseFrames": Double(clock.frameCount), "takeFrames": Double(takeFrames)],
            "dialogueTimings": dialogueTimings,
            "sameFilm": config.sameFilm == true,
            "hooks": config.hooks ?? [:],
        ]
        manifest["diagnostics"] = LofiCaptureHooks.reports
        try Self.write(manifest, file: "manifest.json", in: config.out)
        try Self.write(score, file: "score.json", in: config.out)
    }

    /// `diagnostics.landmarks[]` (plan 3.2): one take's kick and snare attacks in capture frames.
    private static func landmarkReport(_ take: LofiDrumTake, take index: Int, offset: Int, limit: Int) -> [String: Any] {
        func marks(_ kind: LofiDrumLandmark.Kind) -> [[String: Any]] {
            take.landmarks.filter { $0.kind == kind && offset + $0.attackFrame < limit }.map {
                ["frame": offset + $0.attackFrame, "peakFrame": offset + $0.peakFrame,
                 "strength": Double($0.strength), "confidence": Double($0.confidence)]
            }
        }
        return ["take": index, "name": take.name ?? "fixture", "kicks": marks(.kick), "snares": marks(.snare)]
    }

    private static func write(_ object: Any, file: String, in directory: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: file), options: .atomic)
    }

    private static func file(_ name: String, format: AVAudioFormat, directory: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: directory.appending(path: "\(name).wav"),
                        settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                   AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
                        commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func drumFixture(clock: LofiClock) -> LofiDrumLibrary.Break {
        let frames = clock.frameCount * 4
        var left = [Float](repeating: 0, count: frames)
        var right = left
        var rng = MusicRNG(seed: 5959)
        for beat in 0..<64 {
            let start = clock.frame(at: Double(beat))
            let count = min(Int(clock.sampleRate * 0.17), frames - start)
            let kick = beat.isMultiple(of: 4) || beat % 8 == 6
            for j in 0..<count {
                let t = Double(j) / clock.sampleRate
                let x = Float(exp(-t * (kick ? 24 : 46)) * min(1, t / 0.002)) *
                    (kick ? 0.56 * Float(sin(2 * .pi * (52 * t + 1.2 * (1 - exp(-t * 37)))))
                          : 0.27 * rng.rangeF(-1...1))
                left[start + j] = x
                right[start + j] = x * (beat.isMultiple(of: 2) ? 0.94 : 0.85)
            }
        }
        let entry = LofiDrumLibrary.Entry(name: "fixture", sha256: "", bpm: 60 / clock.beatDuration,
                                          beats: 64, sampleRate: clock.sampleRate, channels: 2,
                                          frameCount: frames, framesPerBeat: clock.framesPerBeat,
                                          onsetPhaseMilliseconds: 0, beatSupport: 1)
        return .init(entry: entry, left: left, right: right, gain: 1)
    }

    private func voiceFixture(clock: LofiClock) throws -> AVAudioPCMBuffer {
        let frames = Int(clock.sampleRate * 9)
        let buffer = try LofiRenderer.stereoBuffer(clock: clock, frames: frames)
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<frames {
            let t = Double(i) / clock.sampleRate
            let segment = Int(t / 0.39)
            guard segment % 5 != 4 else { continue }
            let phase = (t / 0.39).truncatingRemainder(dividingBy: 1)
            let envelope = sin(.pi * phase) * min(1, (9 - t) * 4)
            let base = 101 + 3 * sin(t * 8)
            let tones = sin(2 * .pi * t * base * 4) + 0.58 * sin(2 * .pi * t * base * 11) +
                0.16 * sin(2 * .pi * t * base * 19)
            let x = Float(tones * envelope * 0.063)
            channels[0][i] = x
            channels[1][i] = x
        }
        return buffer
    }

    /// AVAudioEngine hands tap audio over in 0.1 s blocks on its own queue. A manual render that runs
    /// ahead of the file writes overruns a tap's buffer and a block is dropped (`skippedTapFrames`,
    /// seen on a busy machine once the capture had twenty taps), so the render waits while any tap
    /// has two complete blocks outstanding. The limit only bounds a stall; a real skip still fails.
    @discardableResult
    nonisolated private static func awaitTaps(_ sinks: [TapFile], cursor: Int) -> Bool {
        guard sinks.contains(where: { $0.isBehind(cursor) }) else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while sinks.contains(where: { $0.isBehind(cursor) }), DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(200)
        }
        return true
    }

    /// Offline-only taps. File writes run inside the tool's pull graph, never in app playback.
    nonisolated private final class TapFile: @unchecked Sendable {
        private let name: String
        private let required: Int
        private var file: AVAudioFile?
        private var firstSample: AVAudioFramePosition?
        private var frames = 0
        private var failure: Error?
        /// Frames written so far, and the tap's block length, for `awaitTaps` on the render thread.
        private let delivered = Atomic<Int>(0)
        private let block = Atomic<Int>(4800)
        init(name: String, format: AVAudioFormat, directory: URL, frames: Int) throws {
            self.name = name
            required = frames
            file = try LofiMixRenderTests.file(name, format: format, directory: directory)
        }

        var tap: AVAudioNodeTapBlock {
            { [self] buffer, time in
                guard failure == nil, frames < required else { return }
                do {
                    if firstSample == nil { firstSample = time.sampleTime }
                    guard time.sampleTime == AVAudioFramePosition(frames) else {
                        throw CaptureError.skippedTapFrames(name, frames, Int(time.sampleTime))
                    }
                    let count = min(required - frames, Int(buffer.frameLength))
                    if count == Int(buffer.frameLength) {
                        try file?.write(from: buffer)
                    } else {
                        guard let end = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
                              let to = end.floatChannelData, let from = buffer.floatChannelData
                        else { throw LofiRenderer.RenderError.buffer }
                        end.frameLength = AVAudioFrameCount(count)
                        for channel in 0..<Int(buffer.format.channelCount) {
                            to[channel].update(from: from[channel], count: count)
                        }
                        try file?.write(from: end)
                    }
                    frames += count
                    block.store(max(1, Int(buffer.frameLength)), ordering: .relaxed)
                    delivered.store(frames >= required ? .max : frames, ordering: .relaxed)
                } catch {
                    failure = error
                    delivered.store(.max, ordering: .relaxed)
                }
            }
        }

        /// Whether two or more complete tap blocks are still waiting to be written at `cursor`.
        func isBehind(_ cursor: Int) -> Bool {
            let done = delivered.load(ordering: .relaxed)
            return done != .max && cursor - done >= 2 * block.load(ordering: .relaxed)
        }

        enum CaptureError: Error { case skippedTapFrames(String, Int, Int) }
        func finish(frames required: Int) throws {
            file = nil
            if let failure { throw failure }
            try #require(frames == required, "tap \(name): \(frames)/\(required) samples, offset \(firstSample ?? -1)")
        }
    }
}
