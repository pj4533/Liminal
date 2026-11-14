import Testing
import Foundation
import Combine
@testable import Liminal

/// Offline render harness. Not run by default (slow); enable with env LIMINAL_RENDER=1.
///   LIMINAL_RENDER=1 LIMINAL_RENDER_LABEL=baseline LIMINAL_RENDER_SECONDS=300 xcodebuild test ... -only-testing:LiminalTests/MusicRenderTests
/// Prefer scripts/render-music.sh, which wires this up and runs analysis.
@MainActor
struct MusicRenderTests {

    @Test func renderOffline() throws {
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
            #if DEBUG
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
        try engine.renderOffline(seconds: seconds, to: url, limiterBypassed: bypass) { e in
            guard let solo else { return }
            for l in e.layers where "\(l.id)" != solo { l.strip.trim = 0 }
        }
        let wall = Date().timeIntervalSince(t0)
        print("RENDERED \(url.path) \(seconds)s in \(String(format: "%.1f", wall))s wall")
        #expect(FileManager.default.fileExists(atPath: url.path))
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
