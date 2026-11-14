import Testing
import Foundation
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

        let engine = GenerativeEngine()
        let t0 = Date()
        try engine.renderOffline(seconds: seconds, to: url)
        let wall = Date().timeIntervalSince(t0)
        print("RENDERED \(url.path) \(seconds)s in \(String(format: "%.1f", wall))s wall")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

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
