// TapTimingCheck: checks, sample for sample, the clock assumption the recorder relies on
// (docs/recording.md "Timing", D47): a tap buffer's AVAudioTime host time is the host time of its first
// frame on the same timeline that AVAudioPlayerNode.play(at:) schedules against, and the tap's sample
// time advances by exactly the frames delivered.
//
//   swiftc -O -parse-as-library tools/TapTimingCheck.swift -o /tmp/tap-timing && /tmp/tap-timing
//
// Graph like the app's: player -> mixer -> mixer (tapped, "recordTap") -> output node, no main mixer.
// Five single-sample impulses are started with play(at:) at known host times; the tap finds each
// impulse and reports (tap host time + index / rate) - scheduled host time. Plays five clicks on the
// default output device at low level.

import AVFoundation
import Foundation

final class Found: @unchecked Sendable {
    let lock = NSLock()
    var hits: [(host: Double, index: Int, sample: Int64)] = []
    var buffers: [(host: Double, sample: Int64, frames: Int)] = []
}

@main struct TapTimingCheck {
    static func main() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let a = AVAudioMixerNode(), b = AVAudioMixerNode()
        [player, a, b].forEach(engine.attach)
        let format = engine.outputNode.outputFormat(forBus: 0)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
        engine.connect(player, to: a, format: stereo)
        engine.connect(a, to: b, format: stereo)
        engine.connect(b, to: engine.outputNode, format: stereo)
        let found = Found()
        b.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
            guard let d = buffer.floatChannelData else { return }
            let host = AVAudioTime.seconds(forHostTime: when.hostTime)
            found.lock.lock(); defer { found.lock.unlock() }
            found.buffers.append((host, when.sampleTime, Int(buffer.frameLength)))
            for i in 0..<Int(buffer.frameLength) where abs(d[0][i]) > 0.05 {
                found.hits.append((host, i, when.sampleTime)); break
            }
        }
        try engine.start()
        let rate = stereo.sampleRate
        let click = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4800)!
        click.frameLength = 4800
        for c in 0..<2 { for i in 0..<4800 { click.floatChannelData![c][i] = i == 0 ? 0.2 : 0 } }
        var scheduled: [Double] = []
        for k in 0..<5 {
            let at = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3 + Double(k % 3) * 0.0137)
            scheduled.append(AVAudioTime.seconds(forHostTime: at))
            player.stop()
            player.scheduleBuffer(click, at: nil)
            player.play(at: AVAudioTime(hostTime: at))
            Thread.sleep(forTimeInterval: 0.8)
        }
        engine.stop()
        print("rate \(rate) Hz, output presentation latency \(String(format: "%.2f", b.outputPresentationLatency * 1000)) ms, output node \(String(format: "%.2f", engine.outputNode.presentationLatency * 1000)) ms")
        found.lock.lock(); defer { found.lock.unlock() }
        let gaps = zip(found.buffers, found.buffers.dropFirst()).filter { $1.sample != $0.sample + Int64($0.frames) }.count
        let hostSlope = zip(found.buffers, found.buffers.dropFirst()).map { ($1.host - $0.host) * rate - Double($0.frames) }
        print("tap buffers \(found.buffers.count), frames \(found.buffers.first?.frames ?? 0), sample-time gaps \(gaps), host step - frames: max |\(String(format: "%.3f", hostSlope.map(abs).max() ?? 0))| samples")
        for (k, at) in scheduled.enumerated() {
            guard let hit = found.hits.first(where: { $0.host + Double($0.index) / rate > at - 0.2 && $0.host + Double($0.index) / rate < at + 0.2 }) else {
                print("click \(k): not found"); continue
            }
            let heard = hit.host + Double(hit.index) / rate
            print(String(format: "click %d: tap host + index/rate - scheduled = %+.4f ms (%+.2f samples), index %d", k, (heard - at) * 1000, (heard - at) * rate, hit.index))
        }
    }
}
