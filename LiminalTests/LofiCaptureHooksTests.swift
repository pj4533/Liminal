import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// The hooks are process-global, so these tests run serialized.
@Suite(.serialized) struct LofiCaptureHooksTests {
    @Test func disabledHooksAreNoOps() {
        LofiCaptureHooks.end()
        #expect(!LofiCaptureHooks.isEnabled)
        LofiCaptureHooks.tap("x", AVAudioMixerNode())
        LofiCaptureHooks.report("a", 1)
        LofiCaptureHooks.appendReport("b", 2)
        LofiCaptureHooks.file("f.json", Data([1]))
        nonisolated(unsafe) var ran = false
        LofiCaptureHooks.onFinish { ran = true }
        LofiCaptureHooks.runFinishers()
        #expect(LofiCaptureHooks.taps.isEmpty)
        #expect(LofiCaptureHooks.reports.isEmpty)
        #expect(LofiCaptureHooks.files.isEmpty)
        #expect(LofiCaptureHooks.option("masterInputGainDb") == nil)
        #expect(!ran)
    }

    @Test func roundTrip() {
        LofiCaptureHooks.begin(options: ["masterInputGainDb": "4", "transcription": "off"])
        defer { LofiCaptureHooks.end() }
        #expect(LofiCaptureHooks.isEnabled)
        #expect(LofiCaptureHooks.option("masterInputGainDb") == "4")
        #expect(LofiCaptureHooks.option("missing") == nil)

        let node = AVAudioMixerNode()
        LofiCaptureHooks.tap("dialogue-pre-fx", node)
        #expect(LofiCaptureHooks.taps.map(\.name) == ["dialogue-pre-fx"])
        #expect(LofiCaptureHooks.taps.first?.node === node)

        LofiCaptureHooks.report("answer", 42)
        LofiCaptureHooks.appendReport("list", ["n": 1])
        LofiCaptureHooks.appendReport("list", ["n": 2])
        #expect(LofiCaptureHooks.reports["answer"] as? Int == 42)
        #expect((LofiCaptureHooks.reports["list"] as? [Any])?.count == 2)

        LofiCaptureHooks.file("master-gr.csv", Data("a,b\n".utf8))
        #expect(LofiCaptureHooks.files["master-gr.csv"] == Data("a,b\n".utf8))

        // A finisher may register more output, and runs only once.
        LofiCaptureHooks.onFinish { LofiCaptureHooks.report("finished", true) }
        LofiCaptureHooks.runFinishers()
        LofiCaptureHooks.runFinishers()
        #expect(LofiCaptureHooks.reports["finished"] as? Bool == true)
    }

    @Test func beginAndEndClear() {
        LofiCaptureHooks.begin(options: ["a": "1"])
        LofiCaptureHooks.report("k", 1)
        LofiCaptureHooks.file("x.json", Data())
        LofiCaptureHooks.begin(options: ["b": "2"])
        #expect(LofiCaptureHooks.reports.isEmpty)
        #expect(LofiCaptureHooks.files.isEmpty)
        #expect(LofiCaptureHooks.option("a") == nil)
        #expect(LofiCaptureHooks.option("b") == "2")
        LofiCaptureHooks.end()
        #expect(!LofiCaptureHooks.isEnabled)
        #expect(LofiCaptureHooks.option("b") == nil)
    }
}
