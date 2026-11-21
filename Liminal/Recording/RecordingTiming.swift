//
//  RecordingTiming.swift
//  Liminal
//
//  The recorder's timing decisions as pure values, so they can be tested without a writer
//  (docs/recording.md "Timing", docs/decisions/images.md D47).
//
//  One movie clock: t = 0 is the presentation time of the first video frame (T0, uptime seconds).
//  Video slot k is at k/60 s exactly; audio sample n is at n/rate exactly. Nothing is "next slot"
//  or "next sample" without a time: every frame and every audio buffer is placed by when it was
//  shown or heard, so neither track can drift or shift against the other.
//

import Foundation

/// Picks, for every 60 Hz slot of the movie, the rendered frame presented nearest to that slot's time.
///
/// The renderers do not run at 60 Hz (the visionOS loop is sleep-paced near 83 fps; a Mac display may
/// run MTKView at 60, 72 or 75 Hz). A frame goes to the slot nearest its presentation time; two frames
/// for one slot keep the nearer and drop the other; a slot with no frame repeats the previous frame
/// (up to `maxRepeats`, 10 s), so the movie is constant 60 fps and its length is the real length.
///
/// Hysteresis, only for sources near the output rate: a 60 Hz source whose phase sits on a slot
/// boundary would otherwise alternate drop and repeat with every few ms of jitter.
nonisolated struct FrameSlotter<Frame> {
    struct Output {
        let frame: Frame
        let slot: Int
        /// The previous frame written again for an empty slot.
        let repeated: Bool
        /// The emitted frame's offset from its slot's time, in slots (0 for repeats).
        let error: Double
    }

    let rate: Double
    let hysteresis: Double
    let maxRepeats: Int

    private var candidate: (frame: Frame, slot: Int, x: Double)?
    private var lastEmitted: (frame: Frame, slot: Int)?
    private var lastX: Double?
    private var meanStep: Double?

    private(set) var offered = 0
    private(set) var dropped = 0
    private(set) var repeats = 0
    private(set) var emitted = 0
    /// Largest |frame time - slot time| of an emitted frame, in seconds.
    private(set) var maxError = 0.0

    init(rate: Double = 60, hysteresis: Double = 0.25, maxRepeats: Int = 600) {
        self.rate = rate
        self.hysteresis = hysteresis
        self.maxRepeats = maxRepeats
    }

    /// Last slot written (nil before the first).
    var lastSlot: Int? { lastEmitted?.slot }

    /// Offers a frame presented at `time` (movie seconds). Returns what to write now, in slot order.
    mutating func offer(_ frame: Frame, at time: Double) -> [Output] {
        offered += 1
        let x = time * rate
        if let lx = lastX {
            let step = x - lx
            meanStep = meanStep.map { $0 + 0.1 * (step - $0) } ?? step
        }
        lastX = x
        var s = max(0, Int(x.rounded()))
        let floor = lastEmitted?.slot ?? -1
        let nearRate = meanStep.map { abs($0 - 1) < 0.2 } ?? false
        if let cand = candidate, nearRate {
            let c = cand.slot
            if s == c, x >= Double(c) + 0.5 - hysteresis { s = c + 1 }
            else if s == c + 2, x <= Double(c) + 1.5 + hysteresis { s = c + 1 }
        } else if candidate == nil, s == floor, nearRate, x >= Double(floor) + 0.5 - hysteresis {
            s = floor + 1
        }
        // Late or out of order: its slot is already written.
        guard s > floor else { dropped += 1; return [] }
        guard let cand = candidate else {
            candidate = (frame, s, x)
            return []
        }
        if s < cand.slot { dropped += 1; return [] }
        if s == cand.slot {
            if abs(x - Double(s)) < abs(cand.x - Double(s)) { candidate = (frame, s, x) }
            dropped += 1
            return []
        }
        let out = emit(cand)
        candidate = (frame, s, x)
        return out
    }

    /// Writes the held candidate (call when the recording stops).
    mutating func finish() -> [Output] {
        guard let cand = candidate else { return [] }
        candidate = nil
        return emit(cand)
    }

    private mutating func emit(_ cand: (frame: Frame, slot: Int, x: Double)) -> [Output] {
        var out: [Output] = []
        if let last = lastEmitted {
            let gap = cand.slot - last.slot - 1
            if gap > 0 {
                for k in 0..<min(gap, maxRepeats) {
                    out.append(Output(frame: last.frame, slot: last.slot + 1 + k, repeated: true, error: 0))
                    repeats += 1
                }
            }
        }
        let error = cand.x - Double(cand.slot)
        maxError = max(maxError, abs(error) / rate)
        out.append(Output(frame: cand.frame, slot: cand.slot, repeated: false, error: error))
        emitted += 1
        lastEmitted = (cand.frame, cand.slot)
        return out
    }
}

/// Places each tap buffer of the final mix on the movie's audio track by when it is heard.
///
/// A buffer whose sample time continues the previous one (and whose host time agrees) goes right
/// after it: the track is the mix sample for sample. Missing samples (a ring overrun, a dropped
/// buffer) become silence of exactly the missing length. A break in the sample clock (an engine
/// restart after a route change) is placed again by its host time. Audio heard before T0 is skipped;
/// a gap before the first buffer is silence. Nothing can shift the audio against the picture.
///
/// `driftSeconds` follows the audio device's clock against the host clock (heard time minus track
/// time); the recorder subtracts it from video times so the movie's clock is the audio's.
nonisolated struct AudioTimeline: Sendable {
    struct Placement: Equatable, Sendable {
        /// Silent frames to write before this buffer.
        var silence = 0
        /// Leading frames of the buffer to discard (heard before T0, or already covered).
        var skip = 0
        /// Frames of the buffer to write (after `skip`).
        var take = 0
        /// Track frame of the first written frame of the buffer.
        var position = 0
    }

    static let invalidSampleTime = Int64.min

    let rate: Double
    /// Seconds from a tap buffer's host time to when it is heard (the output's presentation latency).
    var latency: Double
    /// Host-time disagreement (seconds) above which a buffer is placed again by its host time.
    var tolerance = 0.02
    /// A placement asking for more silence than this is a bad host time: the buffer is appended instead.
    var maxSilence = 30.0

    private(set) var written = 0
    private(set) var started = false
    private(set) var driftSeconds = 0.0
    private(set) var silenceFrames = 0
    private(set) var skippedFrames = 0
    private(set) var discontinuities = 0
    private var expected: (sample: Int64?, heard: Double)?

    init(rate: Double, latency: Double) {
        self.rate = rate
        self.latency = latency
    }

    /// Places a buffer of `frames` frames whose first frame has `hostSeconds` and `sampleTime`
    /// (`invalidSampleTime` when the tap had none). `t0` is the movie's start (uptime seconds).
    mutating func place(hostSeconds: Double, sampleTime: Int64, frames: Int, t0: Double) -> Placement {
        let heard = hostSeconds + latency
        let sample: Int64? = sampleTime == Self.invalidSampleTime ? nil : sampleTime
        var ideal: Int?
        if started, let e = expected {
            let hostAgrees = abs(heard - e.heard) <= tolerance
            if let es = e.sample, let sample {
                let gap = sample - es
                if gap == 0, hostAgrees {
                    ideal = written
                } else if gap > 0, gap < Int64(maxSilence * rate),
                          abs(heard - (e.heard + Double(gap) / rate)) <= tolerance {
                    ideal = written + Int(gap)          // lost samples: exactly that much silence
                }
            } else if hostAgrees {
                ideal = written
            }
        }
        let reanchor = ideal == nil
        if reanchor, started { discontinuities += 1 }
        var target = ideal ?? Int(((heard - t0 - driftSeconds) * rate).rounded())
        if target - written > Int(maxSilence * rate) { target = written }
        defer { expected = (sample.map { $0 + Int64(frames) }, heard + Double(frames) / rate) }

        var p = Placement()
        if target < written {
            p.skip = min(frames, written - target)
        } else {
            p.silence = target - written
        }
        p.take = frames - p.skip
        p.position = written + p.silence
        guard p.take > 0 else {
            skippedFrames += frames
            return Placement(silence: 0, skip: frames, take: 0, position: written)
        }
        skippedFrames += p.skip
        silenceFrames += p.silence
        let residual = (heard + Double(p.skip) / rate - t0) - Double(p.position) / rate
        driftSeconds = started ? driftSeconds + 0.02 * (residual - driftSeconds) : residual
        written = p.position + p.take
        started = true
        return p
    }

    /// Silence to append so the track ends at `endFrame` (0 when it already reaches it).
    mutating func pad(to endFrame: Int) -> Int {
        let n = max(0, endFrame - written)
        written += n
        silenceFrames += n
        return n
    }
}
