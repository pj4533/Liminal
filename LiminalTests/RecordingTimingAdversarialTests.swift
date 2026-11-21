import Foundation
import Testing
@testable import Liminal

/// Adversarial cases for the recorder's movie clock (docs/recording.md "Timing", D47): render hiccups,
/// throttling, display drift, long stalls, out-of-order completions, latency changes, ring wrap-around
/// and the device's late first frame, each checked against the true presentation and heard times.
struct RecordingTimingAdversarialTests {
    private struct Rng {
        var state: UInt64
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func jitter(_ amount: Double) -> Double { (unit() * 2 - 1) * amount }
    }

    /// Offers frames presented at `times`; returns every output (in write order) and the slotter.
    private func slot(_ times: [Double], order: [Int]? = nil) -> ([FrameSlotter<Int>.Output], FrameSlotter<Int>) {
        var s = FrameSlotter<Int>()
        var out: [FrameSlotter<Int>.Output] = []
        for i in order ?? Array(times.indices) { out += s.offer(i, at: times[i]) }
        out += s.finish()
        return (out, s)
    }

    /// Slots written in order with no gap; every written frame within `maxError` slots of its slot;
    /// the movie's span is the real span within a frame.
    private func expectOnClock(_ out: [FrameSlotter<Int>.Output], _ times: [Double], maxError: Double,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let slots = out.map(\.slot)
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $1 == $0 + 1 }, "slots not consecutive", sourceLocation: sourceLocation)
        var worst = 0.0
        for o in out where !o.repeated { worst = max(worst, abs(times[o.frame] * 60 - Double(o.slot))) }
        #expect(worst <= maxError, "worst slot error \(worst) slots", sourceLocation: sourceLocation)
        let span = Double((slots.last ?? 0) - (slots.first ?? 0)) / 60
        let real = (times.max() ?? 0) - (times.min() ?? 0)
        #expect(abs(span - real) <= 1.0 / 60, "span \(span) real \(real)", sourceLocation: sourceLocation)
    }

    /// The device loop (sleep-paced towards 90 Hz, measured 81.6 fps) with hiccups: a 25 ms frame every
    /// 50 frames and a 60 ms one every 400. A hiccup must not switch the near-60 Hz hysteresis on, which
    /// would move frames up to 0.75 slot (12.5 ms) from their time.
    @Test func hiccupsInAFastStreamKeepFramesWithinHalfASlot() {
        var r = Rng(state: 3)
        var times: [Double] = [0]
        for i in 1..<(81 * 300) {
            let step = i % 400 == 0 ? 0.060 : i % 50 == 0 ? 0.025 : 1 / 81.6 + r.jitter(0.002)
            times.append(times[i - 1] + step)
        }
        let (out, _) = slot(times)
        expectOnClock(out, times, maxError: 0.5 + 1e-9)
    }

    /// Thermal throttling: 90, 45, 72 and 120 fps in turn, 30 s each. Going from 90 to 45 fps the mean
    /// step passes through 60 Hz, so for a few frames hysteresis may hold a frame up to 0.75 slot off.
    @Test func changingRenderRatesStayOnTheClock() {
        var r = Rng(state: 9)
        var times: [Double] = [0]
        for fps in [90.0, 45, 72, 120] {
            for _ in 0..<Int(30 * fps) { times.append(times.last! + 1 / fps + r.jitter(0.0015)) }
        }
        let (out, s) = slot(times)
        expectOnClock(out, times, maxError: 0.75 + 0.09 + 1e-9)
        #expect(s.repeats > 0)   // the 45 fps part repeats frames
    }

    /// A 59.94 Hz display for 10 minutes: its phase walks through every slot boundary. Hysteresis may
    /// hold a frame up to 0.75 slot off, but never more, and the movie keeps the real length.
    @Test func ntscDisplayDriftsWithoutAccumulating() {
        var r = Rng(state: 5)
        var times: [Double] = []
        for i in 0..<(60 * 600) {
            let j: Double = i == 0 ? 0 : r.jitter(0.001)
            times.append(Double(i) / 59.94 + j)
        }
        let (out, s) = slot(times)
        expectOnClock(out, times, maxError: 0.75 + 0.06 + 1e-9)
        // 36 s of drift over 10 min is 0.6 s, 36 frames: about that many repeats, no more.
        #expect(s.repeats >= 30 && s.repeats <= 45, "repeats \(s.repeats)")
    }

    /// A stall longer than the 10 s of repeats: the next frame still lands at its own time.
    @Test func stallLongerThanTheRepeatLimitKeepsTime() {
        let times = [0, 1.0 / 60, 1.0 / 60 + 12, 2.0 / 60 + 12]
        let (out, s) = slot(times)
        let after = out.first { $0.frame == 2 && !$0.repeated }!
        #expect(after.slot == 721)
        #expect(s.repeats == 600)
        #expect(out.last!.slot == 722)
    }

    /// GPU completions out of order at 90 Hz (every 7th pair swapped): slots stay in order and each
    /// written frame is within half a slot of its own presentation time.
    @Test func outOfOrderCompletionsNeverReorderOrShift() {
        var r = Rng(state: 11)
        var times: [Double] = []
        for i in 0..<(90 * 120) {
            let j: Double = i == 0 ? 0 : r.jitter(0.002)
            times.append(Double(i) / 90 + j)
        }
        var order = Array(times.indices)
        for i in stride(from: 7, to: order.count - 1, by: 7) { order.swapAt(i, i + 1) }
        let (out, _) = slot(times, order: order)
        let slots: [Int] = out.map { $0.slot }
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $1 == $0 + 1 })
        var worst = 0.0
        for o in out where !o.repeated { worst = max(worst, abs(times[o.frame] * 60 - Double(o.slot))) }
        #expect(worst <= 0.5 + 1e-9)
    }

    // MARK: Audio

    /// A route change that keeps the sample clock but changes the output latency. Above the 20 ms host
    /// tolerance the next buffer is placed again by its heard time (silence of the change); below it
    /// the audio stays contiguous and the drift estimate absorbs the change, so video placed with it
    /// lands on the audio again within a few seconds. Either way nothing stays shifted.
    @Test(arguments: [0.015, 0.035])
    func latencyChangeIsFollowed(change: Double) {
        let rate = 48_000.0
        var tl = AudioTimeline(rate: rate, latency: 0.010)
        var last = AudioTimeline.Placement()
        var heard = 0.0
        for i in 0..<300 {
            if i == 50 { tl.latency = 0.010 + change }
            let host = 100 + Double(i) * 0.1 - 0.010
            last = tl.place(hostSeconds: host, sampleTime: Int64(i * 4800), frames: 4800, t0: 100)
            heard = host + tl.latency
            if i == 50 {
                #expect(tl.discontinuities == (change > tl.tolerance ? 1 : 0))
                if change > tl.tolerance { #expect(abs(last.silence - Int(change * rate)) <= 1) }
            }
        }
        // The last buffer: a frame presented when it is heard goes where the audio track has it.
        let video = heard - 100 - tl.driftSeconds
        #expect(abs(video - Double(last.position) / rate) < 0.001, "video \(video) audio \(Double(last.position) / rate)")
    }

    /// 10 minutes of 512-frame buffers at 44.1 kHz with ±0.5 ms host jitter: every sample in place.
    @Test func smallBuffersAtAnotherRateAreSampleExact() {
        let rate = 44_100.0
        var tl = AudioTimeline(rate: rate, latency: 0.02)
        var r = Rng(state: 13)
        let count = Int(600 * rate / 512)
        var exact = true
        var first = 0
        for i in 0..<count {
            let p = tl.place(hostSeconds: 50 + Double(i * 512) / rate - 0.02 + r.jitter(0.0005),
                             sampleTime: Int64(i * 512), frames: 512, t0: 50)
            if i == 0 { first = p.position }
            if i > 0, p.position != first + i * 512 || p.silence != 0 || p.skip != 0 { exact = false }
        }
        #expect(exact)
        #expect(tl.discontinuities == 0)
        #expect(abs(tl.written - count * 512) <= 23)   // the first buffer is placed by its jittered host time
    }

    /// The ring across its wrap-around with buffer sizes that do not divide its capacity: every sample
    /// comes out in order with its own mark.
    @Test func ringWrapsWithoutLosingOrReorderingSamples() {
        let ring = AudioRing(capacityFrames: 5000, markCapacity: 16)
        ring.reset(rate: 48_000)
        var next: Float = 0, expect: Float = 0
        var sample: Int64 = 0, expectSample: Int64 = 0
        var ok = true
        let sizes = [1024, 777, 4096, 333, 2048, 1500]
        for round in 0..<400 {
            let n = sizes[round % sizes.count]
            let left = (0..<n).map { next + Float($0) }, right = left.map { -$0 }
            left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { rr in
                ring.write(left: l.baseAddress!, right: rr.baseAddress!, frames: n, rate: 48_000, hostTime: 1, sampleTime: sample)
            } }
            next += Float(n); sample += Int64(n)
            while let m = ring.readMark() {
                var buf = [Float](repeating: 0, count: m.frames * 2)
                let got = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: m.frames) }
                if got != m.frames || m.sampleTime != expectSample { ok = false }
                for i in 0..<m.frames where buf[2 * i] != expect + Float(i) || buf[2 * i + 1] != -(expect + Float(i)) { ok = false }
                expect += Float(m.frames); expectSample += Int64(m.frames)
            }
        }
        #expect(ok)
        #expect(ring.overruns == 0)
    }

    /// The device case end to end through the ring: the consumer does not read for 12 s with a 10 s
    /// ring (the old drain waited for a late first frame). The audio after the overrun is placed at
    /// its heard time, with exactly the lost length as silence, so a kick heard at a given uptime is
    /// at that uptime's movie time.
    @Test func stalledConsumerOverrunIsSilenceOfTheLostLength() {
        let rate = 48_000.0
        let ring = AudioRing(capacityFrames: Int(rate) * 10)
        ring.reset(rate: rate)
        var tl = AudioTimeline(rate: rate, latency: 0.02)
        let t0 = 100.0
        let frames = 4800
        let zeros = [Float](repeating: 0, count: frames)
        let mach = { (s: Double) -> UInt64 in AVAudioTimeHost.hostTime(forSeconds: s) }
        var placements: [(index: Int, p: AudioTimeline.Placement)] = []
        func drain() {
            while let m = ring.readMark() {
                var buf = [Float](repeating: 0, count: m.frames * 2)
                _ = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: m.frames) }
                let host = AVAudioTimeHost.seconds(forHostTime: m.hostTime)
                placements.append((Int(m.sampleTime) / frames, tl.place(hostSeconds: host, sampleTime: m.sampleTime, frames: m.frames, t0: t0)))
            }
        }
        for i in 0..<300 {   // buffer i heard at t0 + i * 0.1
            if i >= 120 { drain() }   // the consumer wakes 12 s in
            zeros.withUnsafeBufferPointer { z in
                ring.write(left: z.baseAddress!, right: z.baseAddress!, frames: frames, rate: rate,
                           hostTime: mach(t0 + Double(i) * 0.1 - 0.02), sampleTime: Int64(i * frames))
            }
        }
        drain()
        #expect(ring.overruns == 20)
        for (index, p) in placements {
            #expect(abs(p.position - index * frames) <= 1, "buffer \(index) at \(p.position)")
        }
        #expect(tl.silenceFrames == 20 * frames)
    }
}

/// mach host time <-> seconds, as AVAudioTime does it (kept here so the test runs without an engine).
private enum AVAudioTimeHost {
    static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func hostTime(forSeconds s: Double) -> UInt64 { UInt64(s * 1e9 * Double(timebase.denom) / Double(timebase.numer)) }
    static func seconds(forHostTime h: UInt64) -> Double { Double(h) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }
}
