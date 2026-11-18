import AudioKit
import AudioKitEX
import AVFoundation
import CryptoKit
import Darwin
import Foundation
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
        let seed: UInt64
        let tempo: Double
        let bars: Int
        let explicitFootageSuffix: String?
        let cachedFootage: Bool
        let receiver: String
        let noFootage: Bool
        let privateDrums: Bool
        let block: Int
        let postrollBeats: Int?
        let limiter: String?
    }

    @MainActor @Test func captureCombinedMix() async throws {
        let path = URL(fileURLWithPath: "/private/tmp/liminal-lofi-audio-config-\(getuid()).json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: path))
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
        let audio = AudioEngine()
        let format = AudioKit.Settings.audioFormat
        let tempo = LofiOptions(tempo: config.tempo, scale: nil).safeTempo
        let clock = LofiClock(tempo: tempo, sampleRate: format.sampleRate)
        let bus = LofiBus(gain: 1)
        let archive = ArchiveVoice(format: format)
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
        let drums: LofiDrumTake
        if config.privateDrums {
            let candidates = LofiDrumLibrary.assets().sorted {
                abs($0.entry.bpm - tempo) < abs($1.entry.bpm - tempo)
            }
            let asset = try #require(candidates.first)
            let recording = try LofiDrumLibrary.load(asset)
            drums = try LofiDrumTake(recording: recording, clock: clock)
            sourceHash = SHA256.hash(data: try Data(contentsOf: asset.url, options: .mappedIfSafe)).description
        } else {
            drums = try LofiDrumTake(recording: drumFixture(clock: clock), clock: clock)
        }
        var footageHash = config.noFootage ? "none" : "public-formant-fixture-v1"
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
            cue = try #require(selected, "No playable audio in the local archive clip cache")
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
        bus.schedule(drums)
        for i in 0..<phrases {
            let request = LofiPlayback.Request(seed: config.seed, index: i, options: .init(tempo: tempo))
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
                "foregroundRest": [clock.frame(at: phrase.score.foregroundSpace.lowerBound) + i * clock.frameCount,
                                   clock.frame(at: phrase.score.foregroundSpace.upperBound) + i * clock.frameCount],
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
            ("footage-dry", mix.dryBus.avAudioNode), ("footage-delay", mix.delayReturn.avAudioNode),
            ("footage-room", mix.reverbReturn.avAudioNode), ("lofi", bus.output.avAudioNode),
            ("footage", mix.output.avAudioNode), ("pre-master", master.input.avAudioNode),
            ("glue", master.glue.avAudioNode),
        ]
        try audio.start()
        defer { audio.stop() }
        let capture = try nodes.map { name, node in
            (node, try TapFile(name: name, format: format, directory: config.out, frames: frames))
        }
        for (node, sink) in capture {
            node.installTap(onBus: 0, bufferSize: 1024, format: nil, block: sink.tap)
        }
        var tapsInstalled = true
        defer { if tapsInstalled { for (node, _) in capture { node.removeTap(onBus: 0) } } }
        try FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        let finalFile = try Self.file("master", format: format, directory: config.out)
        let work = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))

        mix.syncDelay(toBeatDuration: clock.beatDuration)
        mix.setMaster(1, over: 0)
        for player in bus.players { player.play() }
        let ducker = OfflineDucker(bus: bus)
        var cueStarted = false
        let cueFrame = clock.frame(at: 5)
        var cursor = 0
        var noProgress = 0
        let controlFrames = Int((format.sampleRate * 0.04).rounded())
        var nextControl = 0
        let t0 = Date()
        while cursor < frames {
            let time = Double(cursor) / format.sampleRate
            if let cue, !cueStarted, cursor == cueFrame {
                archive.begin(.init(buffer: cue, gain: 0.9, fadeIn: 0.5, label: "offline fixture",
                                    activity: ArchiveAudioMath.activity(cue)), now: time)
                cueStarted = true
            }
            if cursor == nextControl {
                archive.modulate(t: time)
                ducker.update(archive.speechActivity, interval: Double(controlFrames) / format.sampleRate)
                nextControl += controlFrames
            }
            let remaining = cueStarted || cue == nil ? frames - cursor : min(cueFrame - cursor, frames - cursor)
            let size = min(config.block, remaining, nextControl - cursor)
            let status = try audio.avEngine.renderOffline(AVAudioFrameCount(size), to: work)
            if status == .success {
                let written = Int(work.frameLength)
                if written > 0 {
                    try finalFile.write(from: work)
                    cursor += written
                    noProgress = 0
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
        let wall = Date().timeIntervalSince(t0)
        let manifest: [String: Any] = [
            "schema": "liminal-lofi-capture-v1", "frames": frames, "sampleRate": format.sampleRate,
            "block": config.block, "seed": String(config.seed), "bpm": tempo, "beatsPerBar": 4,
            "clockOriginFrame": 0, "postrollFrames": postroll, "scoredFrames": scoreFrames,
            "hasFootage": cue != nil, "footageStartFrame": cueFrame,
            "privateSources": config.privateDrums || config.cachedFootage || config.explicitFootageSuffix != nil,
            "drumSourceHash": sourceHash, "footageSourceHash": footageHash, "gitRevision": config.revision,
            "renderedSeconds": Double(frames) / format.sampleRate, "mixWallSeconds": wall,
            "providers": ["kit": "full-take-linked-varispeed", "acoustic": "native-resampled-wav-v2",
                          "room": "native-parallel-rack-v2", "master": limiterID],
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "topology": nodes.map(\.0) + ["master"],
            "latencySamples": ["reportedGlue": master.glue.avAudioNode.latency * format.sampleRate,
                               "reportedLimiter": limiterNode.latency * format.sampleRate],
            "kickCandidates": drums.kicks.filter { $0.frame < frames }.map { ["frame": $0.frame, "strength": $0.strength] },
        ]
        try Self.write(manifest, file: "manifest.json", in: config.out)
        try Self.write(score, file: "score.json", in: config.out)
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

    /// Offline-only taps. File writes run inside the tool's pull graph, never in app playback.
    nonisolated private final class TapFile: @unchecked Sendable {
        private let name: String
        private let required: Int
        private var file: AVAudioFile?
        private var firstSample: AVAudioFramePosition?
        private var frames = 0
        private var failure: Error?
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
                } catch { failure = error }
            }
        }

        enum CaptureError: Error { case skippedTapFrames(String, Int, Int) }
        func finish(frames required: Int) throws {
            file = nil
            if let failure { throw failure }
            try #require(frames == required, "tap \(name): \(frames)/\(required) samples, offset \(firstSample ?? -1)")
        }
    }

    @MainActor private final class OfflineDucker {
        let bus: LofiBus
        var ducker = LofiForegroundDucker()
        private var last = (dry: Float(1), wet: Float(1))
        init(bus: LofiBus) { self.bus = bus }
        func update(_ activity: Float, interval: Double) {
            let gains = ducker.update(activity: activity, interval: interval)
            if abs(gains.dry - last.dry) > 0.004 {
                ParamRamp.setGain(bus.dryFader, gains.dry, over: 0.075)
                ParamRamp.setGain(bus.textureFader, gains.dry, over: 0.075)
                last.dry = gains.dry
            }
            if abs(gains.wet - last.wet) > 0.004 {
                ParamRamp.setGain(bus.wetFader, gains.wet, over: 0.075)
                last.wet = gains.wet
            }
        }
    }
}
