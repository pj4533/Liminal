import Foundation
import Testing
@testable import Liminal

/// The recorder's timing (docs/recording.md "Timing", D47): video slots and audio placement on one
/// movie clock, at any render rate, with no drift and no shift from lost audio.
struct RecordingTimingTests {
    @Test func movieDimensionsKeepAnExactWideAspectAtOddDrawableSizes() throws {
        let native = try #require(RecordingController.fittedPictureSize(width: 2048, height: 1152))
        #expect(native.width == 2048 && native.height == 1152)
        let odd = try #require(RecordingController.fittedPictureSize(width: 1825, height: 1027))
        #expect(odd.width == 1824 && odd.height == 1026)
        let short = try #require(RecordingController.fittedPictureSize(width: 1920, height: 1000))
        #expect(short.width == 1760 && short.height == 990)
        #expect(RecordingController.fittedPictureSize(width: 0, height: 1080) == nil)
    }

    /// Deterministic jitter in [-amount, amount].
    private struct Jitter {
        var state: UInt64
        mutating func next(_ amount: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amount
        }
    }

    private struct Run {
        var outputs: [FrameSlotter<Int>.Output] = []
        var times: [Double] = []
        var slotter = FrameSlotter<Int>()
    }

    /// A render stream at `fps` with ±`jitter` s, for `seconds`, starting at phase `phase` slots.
    private func render(fps: Double, seconds: Double, jitter: Double, phase: Double = 0, seed: UInt64 = 1) -> Run {
        var run = Run()
        var j = Jitter(state: seed)
        let count = Int(seconds * fps)
        for i in 0..<count {
            let t = phase / 60 + Double(i) / fps + (i == 0 ? 0 : j.next(jitter))
            run.times.append(t)
            run.outputs += run.slotter.offer(i, at: t)
        }
        run.outputs += run.slotter.finish()
        return run
    }

    private func check(_ run: Run, seconds: Double, maxError: Double = 0.5) {
        let slots = run.outputs.map(\.slot)
        // Exactly 1/60 s apart: consecutive slots, no gaps, no duplicates.
        #expect(slots.first == 0 || slots.first == 1)
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $1 == $0 + 1 })
        // Each slot holds a frame within half a slot of the slot's time.
        for out in run.outputs where !out.repeated {
            let error = run.times[out.frame] * 60 - Double(out.slot)
            #expect(abs(error) <= maxError, "slot \(out.slot) frame \(out.frame) error \(error) slots")
        }
        // The video span is the real span within one frame.
        let span = Double((slots.last ?? 0) - (slots.first ?? 0)) / 60
        let real = (run.times.last ?? 0) - (run.times.first ?? 0)
        #expect(abs(span - real) <= 1.0 / 60, "span \(span) s, real \(real) s")
        // The frames are in order.
        let frames = run.outputs.filter { !$0.repeated }.map(\.frame)
        #expect(frames == frames.sorted())
    }

    @Test(arguments: [60.0, 83.0, 90.0, 120.0])
    func uniformSlotsAtAnyRenderRate(fps: Double) {
        let run = render(fps: fps, seconds: 600, jitter: 0.002, seed: UInt64(fps))
        check(run, seconds: 600)
        #expect(run.slotter.emitted + run.slotter.repeats == run.outputs.count)
        if fps > 60 { #expect(run.slotter.repeats <= 2) }
    }

    @Test func sixtyHertzWithoutJitterIsOneFramePerSlot() {
        let run = render(fps: 60, seconds: 60, jitter: 0)
        #expect(run.outputs.count == 3600)
        #expect(run.outputs.allSatisfy { !$0.repeated && $0.slot == $0.frame })
        #expect(run.slotter.dropped == 0)
    }

    /// The user's device recording (D47): 9189 frames over the real 113.0 s (81.3 fps; the audio media
    /// is 123.0 s from 12.1 s before the first frame, plus the 2.1 s the overrun lost) cover 113.0 s,
    /// not 153 s.
    @Test func deviceRenderRateKeepsRealLength() {
        let run = render(fps: 81.31, seconds: 9189 / 81.31, jitter: 0.003)
        let span = Double(run.outputs.count) / 60
        #expect(abs(span - 113.0) < 0.1, "span \(span)")
        // A drop cut presented at 57.5 s is in the slot of 57.5 s, not 0.36 s per s later.
        let cutFrame = run.times.firstIndex { $0 >= 57.5 }!
        let slot = run.outputs.first { $0.frame >= cutFrame && !$0.repeated }!.slot
        #expect(abs(Double(slot) / 60 - 57.5) <= 1.0 / 60 + 0.003)
    }

    /// A 60 Hz source whose phase sits on a slot boundary does not alternate drops and repeats.
    @Test func boundaryPhaseDoesNotJudder() {
        let run = render(fps: 60, seconds: 60, jitter: 0.002, phase: 0.5)
        check(run, seconds: 60, maxError: 0.5 + 0.25 + 0.12 + 1e-9)
        #expect(run.slotter.dropped + run.slotter.repeats <= 2, "dropped \(run.slotter.dropped) repeats \(run.slotter.repeats)")
    }

    @Test func slowSourceRepeatsWithoutDrift() {
        let run = render(fps: 48, seconds: 120, jitter: 0.001)
        check(run, seconds: 120)
        #expect(run.slotter.repeats > 0)
    }

    @Test func stallRepeatsThePreviousFrame() {
        var s = FrameSlotter<Int>()
        var out: [FrameSlotter<Int>.Output] = []
        out += s.offer(0, at: 0)
        out += s.offer(1, at: 1.0 / 60)
        out += s.offer(2, at: 1.0 / 60 + 1.0)   // a 1 s stall
        out += s.finish()
        #expect(out.map(\.slot) == Array(0...61))
        #expect(out.filter(\.repeated).count == 59)
        #expect(out.filter(\.repeated).allSatisfy { $0.frame == 1 })
    }

    @Test func lateFrameIsDropped() {
        var s = FrameSlotter<Int>()
        var out: [FrameSlotter<Int>.Output] = []
        out += s.offer(0, at: 0)
        out += s.offer(1, at: 2.0 / 60)
        out += s.offer(2, at: 0.5 / 60)   // completes out of order: its slot is written
        out += s.finish()
        #expect(out.filter { !$0.repeated }.map(\.frame) == [0, 1])
    }

    // MARK: Audio

    private let rate = 48_000.0

    /// Places a stream of `count` buffers of `frames`; returns the placements and the timeline.
    private func stream(count: Int, frames: Int = 4800, t0: Double = 100, start: Double = 100, latency: Double = 0.03,
                        ppm: Double = 0, hostJitter: Double = 0, drop: Set<Int> = [],
                        restart: (at: Int, hostGap: Double)? = nil) -> ([AudioTimeline.Placement], AudioTimeline, [Double]) {
        var tl = AudioTimeline(rate: rate, latency: latency)
        var out: [AudioTimeline.Placement] = []
        var heard: [Double] = []
        var j = Jitter(state: 7)
        var sample: Int64 = 0
        var host = start - latency
        for i in 0..<count {
            if let restart, i == restart.at { sample = 0; host += restart.hostGap }
            defer { sample += Int64(frames); host += Double(frames) / (rate * (1 + ppm * 1e-6)) }
            guard !drop.contains(i) else { continue }
            out.append(tl.place(hostSeconds: host + j.next(hostJitter), sampleTime: sample, frames: frames, t0: t0))
            heard.append(host + latency)
        }
        return (out, tl, heard)
    }

    @Test func contiguousBuffersAreSampleExact() {
        let (p, tl, _) = stream(count: 100, hostJitter: 0.001)
        // The first buffer is placed by its (jittered) host time, within 1 ms of 0; the rest follow it
        // sample for sample.
        #expect(abs(p[0].position - p[0].skip) <= 48)
        #expect(p.dropFirst().allSatisfy { $0.silence == 0 && $0.skip == 0 && $0.take == 4800 })
        #expect(zip(p, p.dropFirst()).allSatisfy { $1.position == $0.position + $0.take })
        #expect(abs(tl.written - 480_000) <= 48)
        #expect(tl.discontinuities == 0)
        #expect(abs(tl.driftSeconds) < 0.001)
    }

    /// The device bug (D47): a lost buffer is silence of its length, and later audio does not move.
    @Test func overrunInsertsSilenceInsteadOfShifting() {
        let (p, tl, _) = stream(count: 100, drop: [40, 41, 42])
        #expect(p[40].silence == 3 * 4800)
        #expect(p[40].position == 43 * 4800)
        #expect(p.last!.position == 99 * 4800)
        #expect(tl.silenceFrames == 3 * 4800)
        #expect(tl.discontinuities == 0)
    }

    @Test func audioBeforeTheFirstFrameIsSkipped() {
        // First tap buffer heard 12.1 s before T0 (the device recording's late first frame).
        let (p, tl, heard) = stream(count: 200, t0: 112.1, start: 100)
        let firstTaken = p.firstIndex { $0.take > 0 }!
        #expect(p[firstTaken].position == 0)
        let skipped = Double(p[firstTaken].skip) / rate
        #expect(abs(heard[firstTaken] + skipped - 112.1) < 1.0 / rate)
        #expect(tl.skippedFrames == Int((12.1 * rate).rounded()))
    }

    @Test func audioStartingAfterTheFirstFrameIsPadded() {
        let (p, _, _) = stream(count: 10, t0: 100, start: 100.08)
        #expect(p[0].silence == 3840)
        #expect(p[0].position == 3840)
    }

    @Test func engineRestartIsPlacedByHostTime() {
        // Sample time resets and the host time jumps 0.4 s past where the next buffer would have been.
        let (p, tl, _) = stream(count: 50, restart: (at: 20, hostGap: 0.4))
        #expect(abs(p[20].silence - 19_200) <= 1)
        #expect(tl.discontinuities == 1)
        #expect(p[21].silence == 0 && p[21].position == p[20].position + 4800)
    }

    @Test func hostJitterDoesNotBreakContiguity() {
        let (p, tl, _) = stream(count: 1000, frames: 1024, hostJitter: 0.001)
        #expect(tl.discontinuities == 0)
        #expect(p.allSatisfy { $0.silence == 0 })
    }

    /// An audio device 100 ppm fast for 10 minutes: the audio keeps every sample and the drift
    /// estimate tracks it, so video placed with it stays on the sound.
    @Test func deviceClockDriftIsTracked() {
        let count = 6000   // 10 min of 0.1 s buffers
        let (p, tl, heard) = stream(count: count, ppm: 100)
        #expect(tl.discontinuities == 0)
        #expect(p.allSatisfy { $0.silence == 0 })
        // Heard time vs track time at the end: the track runs ahead by about 60 ms.
        let last = count - 1
        let trackTime = Double(p[last].position) / rate
        let realRel = heard[last] - 100
        #expect(abs(tl.driftSeconds - (realRel - trackTime)) < 0.001, "drift \(tl.driftSeconds) vs \(realRel - trackTime)")
        #expect(abs(tl.driftSeconds + 0.06) < 0.002)
        // A frame presented at the buffer's heard time lands at the buffer's track time.
        let videoTime = realRel - tl.driftSeconds
        #expect(abs(videoTime - trackTime) < 0.001)
    }

    @Test func padEndsTheTrackAtTheVideoEnd() {
        var (_, tl, _) = stream(count: 10)
        #expect(tl.pad(to: 50_000) == 2000)
        #expect(tl.pad(to: 40_000) == 0)
    }

    // MARK: Ring

    @Test func ringOverrunDropsAudioAndMarkTogether() {
        let ring = AudioRing(capacityFrames: 10_000, markCapacity: 8)
        ring.reset(rate: rate)
        let left = [Float](repeating: 0.5, count: 4800), right = [Float](repeating: -0.5, count: 4800)
        for i in 0..<3 {
            left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
                ring.write(left: l.baseAddress!, right: r.baseAddress!, frames: 4800, rate: rate,
                           hostTime: UInt64(1000 + i), sampleTime: Int64(i * 4800))
            } }
        }
        #expect(ring.overruns == 1)
        #expect(ring.available == 9600)
        var buf = [Float](repeating: 0, count: 9600)
        var marks: [AudioRing.Mark] = []
        while let m = ring.readMark() {
            marks.append(m)
            let n = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: m.frames) }
            #expect(n == m.frames)
        }
        #expect(marks.map(\.sampleTime) == [0, 4800])
        #expect(ring.available == 0)
        #expect(buf[0] == 0.5 && buf[1] == -0.5)
    }

    @Test func ringDropsBuffersAtAnotherRate() {
        let ring = AudioRing(capacityFrames: 10_000)
        ring.reset(rate: rate)
        let x = [Float](repeating: 0, count: 512)
        x.withUnsafeBufferPointer { p in
            ring.write(left: p.baseAddress!, right: p.baseAddress!, frames: 512, rate: 44_100, hostTime: 1, sampleTime: 0)
        }
        #expect(ring.rateMismatches == 1)
        #expect(ring.readMark() == nil)
    }

    /// End to end: an 83 fps render stream, an audio stream with a lost buffer and a late first frame,
    /// both placed on the movie clock; a "kick" heard at a given uptime and the frame presented at
    /// that uptime land at the same movie time.
    @Test func audioAndVideoShareTheMovieClock() {
        let t0 = 112.1
        let (p, tl, heard) = stream(count: 400, t0: t0, start: 100, drop: [250])
        // Kick at the start of buffer 300 (index 299 in placements, since 250 is missing).
        let i = heard.firstIndex { abs($0 - (100 + 300 * 0.1)) < 1e-6 }!
        let kickAudioTime = Double(p[i].position) / rate
        var slotter = FrameSlotter<Double>()
        var outs: [FrameSlotter<Double>.Output] = []
        var t = t0
        while t < 140 {
            outs += slotter.offer(t, at: t - t0 - tl.driftSeconds)
            t += 1 / 83.0
        }
        outs += slotter.finish()
        let kickUptime = heard[i]
        #expect(abs(kickAudioTime - (kickUptime - t0)) < 1.0 / rate)
        // The slot at the kick's movie time shows the frame presented when the kick was heard.
        let slot = Int((kickAudioTime * 60).rounded())
        let shown = outs.first { $0.slot == slot }!
        #expect(abs(Double(slot) / 60 - kickAudioTime) < 1e-9)
        #expect(abs(shown.frame - kickUptime) <= 0.5 / 83 + 1e-6, "frame \(shown.frame) kick \(kickUptime)")
    }
}
