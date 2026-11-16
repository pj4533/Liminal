import Testing
import Foundation
import Combine
import AVFoundation
@testable import Liminal

/// Offline render harness. Not run by default (slow); enable with env LIMINAL_RENDER=1.
///   LIMINAL_RENDER=1 LIMINAL_RENDER_LABEL=baseline LIMINAL_RENDER_SECONDS=300 xcodebuild test ... -only-testing:LiminalTests/MusicRenderTests
/// Prefer scripts/render-music.sh, which wires this up and runs analysis.
@MainActor
struct MusicRenderTests {

    @Test func renderOffline() async throws {
        // xcodebuild strips env vars unless prefixed TEST_RUNNER_; the script also writes a config file.
        let cfg = Self.loadConfig()
        guard cfg["enabled"] == "1" else { return }
        let label = cfg["label"] ?? "render"
        let seconds = Double(cfg["seconds"] ?? "") ?? 300
        let dir = cfg["outdir"] ?? "/private/tmp/claude-501/-Users-pj4533-Developer-Liminal/7dc59965-0f73-427a-9142-59d4c00317b0/scratchpad/music-eval"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(label).wav")
        try? FileManager.default.removeItem(at: url)

        if cfg["mode"] == "realtime" {
            #if DEBUG
            try realtimeSmoke(seconds: seconds, dir: dir)
            #endif
            return
        }
        if cfg["mode"] == "bench" {
            #if DEBUG || LIMINAL_BENCH
            let lines = try MusicProbes.bench(dir: URL(fileURLWithPath: dir))
            try lines.joined(separator: "\n").write(toFile: dir + "/bench.txt", atomically: true, encoding: .utf8)
            #endif
            return
        }
        if cfg["mode"] == "probe" {
            #if DEBUG
            let done = try MusicProbes.runAll(dir: URL(fileURLWithPath: dir))
            print("RENDERED probes \(done)")
            #endif
            return
        }
        let seed = UInt64(cfg["seed"] ?? "") ?? 1
        let bypass = cfg["bypass"] == "1"
        let engine = GenerativeEngine(seed: seed)
        let t0 = Date()
        let solo = cfg["solo"]   // debug: mute every layer but this one (gain-staging checks)
        // Stems (diagnosis): `only=<layer>` zeroes every other layer's trim WITHOUT forcing the layer on, so the
        // score is the same as the full render's and the stem is that layer exactly as it sounds in the piece.
        // `mute=a,b` zeroes the named layers' trims; the names reverb, delay and shimmer mute those returns.
        let only = cfg["only"]
        let mute = Set((cfg["mute"] ?? "").split(separator: ",").map(String.init))
        // Archive footage sound (docs/plans/archive-video.md 4): `archive=<mp4>` mixes one moment's sound in,
        // timed and decoded exactly as the app does. `only=archive` renders its stem, `mute=archive` leaves it out.
        let archive = mute.contains("archive") || (only != nil && only != "archive")
            ? nil : try await Self.archiveCue(cfg, engine: engine, dir: dir, label: label)
        var archiveBegun = false, archiveEnded = false
        let onStep: (Double) -> Void = { t in
            guard let a = archive else { return }
            if !archiveBegun, t >= a.plan.beginAt { archiveBegun = true; engine.post(.archiveBegin(a.cue)) }
            if !archiveEnded, t >= a.plan.fadeOutAt { archiveEnded = true; engine.post(.archiveEnd(fade: a.plan.fadeOut)) }
        }
        try engine.renderOffline(seconds: seconds, to: url, limiterBypassed: bypass, configure: { e in
            for l in e.layers where (only != nil && "\(l.id)" != only) || mute.contains("\(l.id)") {
                l.allStrips.forEach { $0.trim = 0 }
            }
            e.mix.mutedReturns = mute.intersection(["reverb", "delay", "shimmer"])
            guard let solo else { return }
            for l in e.layers where "\(l.id)" != solo { l.allStrips.forEach { $0.trim = 0 } }
            if let id = e.layers.first(where: { "\($0.id)" == solo })?.id { e.conductor.post(.forceLayers([id])) }
        }, onStep: onStep)
        let wall = Date().timeIntervalSince(t0)
        print("RENDERED \(url.path) \(seconds)s in \(String(format: "%.1f", wall))s wall")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The archive piece of a render: a piece like the app's (picture fade in 4 s, the next piece's crossfade
    /// 4 s), its sound cue and the decoded buffer. Writes `<label>.archive.json` with the timings for
    /// scripts/analyze-archive-audio.py.
    private static func archiveCue(_ cfg: [String: String], engine: GenerativeEngine, dir: String,
                                   label: String) async throws -> (plan: ArchiveAudioCuePlan, cue: ArchiveVoice.Cue)? {
        guard let path = cfg["archive"], !path.isEmpty else { return nil }
        let at = Double(cfg["archive_at"] ?? "") ?? 60
        let length = Double(cfg["archive_len"] ?? "") ?? 30
        let rate = Float(cfg["archive_rate"] ?? "") ?? 0.72
        let segment = Double(cfg["archive_start"] ?? "") ?? 120
        let level = Float(cfg["archive_level"] ?? "") ?? 0.5
        let fadeIn = 4.0, fadeOut = 4.0
        var piece = FootagePiece(index: 0, slot: 0, clipID: "render", segmentStart: segment, rate: rate, look: .window,
                                 seed: 0.5, warp: 0.6, level: 0.5, swell: 0, start: at, origin: at, fadeIn: fadeIn,
                                 length: length, fadeOutStart: nil, fadeOut: nil, sound: true)
        piece.fadeOutStart = at + length
        piece.fadeOut = fadeOut
        let url = URL(fileURLWithPath: path)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard let plan = ArchiveAudioCuePlan(piece: piece, clipDuration: duration),
              let gain = ArchiveAudioCuePlan.gain(level: level) else { return nil }
        let buffer = try await ArchiveAudioDecoder.decode(url: url, sourceStart: plan.sourceStart,
                                                          sourceLength: plan.sourceLength, rate: rate,
                                                          format: engine.archiveFormat)
        let info: [String: Any] = ["clip": url.lastPathComponent, "pictureStart": piece.start,
                                   "pictureFadeIn": fadeIn, "pictureFadeOutStart": piece.fadeOutStart ?? 0,
                                   "pictureEnd": piece.end ?? 0, "beginAt": plan.beginAt, "fadeIn": plan.fadeIn,
                                   "fadeOutAt": plan.fadeOutAt, "fadeOut": plan.fadeOut, "rate": rate,
                                   "sourceStart": plan.sourceStart, "sourceLength": plan.sourceLength,
                                   "level": level, "gain": gain,
                                   "bufferSeconds": Double(buffer.frameLength) / buffer.format.sampleRate]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(label).archive.json"))
        print("RENDERED archive cue \(url.lastPathComponent) begin=\(plan.beginAt)s fadeOut=\(plan.fadeOutAt)s")
        return (plan, ArchiveVoice.Cue(buffer: buffer, gain: gain, fadeIn: plan.fadeIn, label: url.lastPathComponent))
    }

    /// Realtime conductor path (DispatchSourceTimer on the music queue) against an engine in offline
    /// manual-rendering mode, pumped at wall-clock pace, so nothing plays through the speakers.
    #if DEBUG
    private func realtimeSmoke(seconds: Double, dir: String) throws {
        let engine = GenerativeEngine(seed: 5)
        var notes = 0
        let sub = engine.shimmerNotePlayed.sink { _ in notes += 1 }
        let report = try engine.realtimeSmoke(seconds: seconds) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        sub.cancel()
        let text = report + " shimmerNotePlayed=\(notes)"
        try text.write(toFile: dir + "/realtime-smoke.txt", atomically: true, encoding: .utf8)
        #expect(report.contains("ok"))
    }
    #endif

    private static func loadConfig() -> [String: String] {
        var out: [String: String] = [:]
        let path = "/private/tmp/liminal-render-config.txt"
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { out[kv[0]] = kv[1] }
            }
        }
        return out
    }
}
