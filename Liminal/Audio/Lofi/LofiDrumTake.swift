import Accelerate
import AVFoundation
import Foundation

/// One continuous recording on the session grid. Backing rhythms stay on their original
/// timeline. The detector supplies evidence for other parts and never moves a drum hit.
nonisolated struct LofiDrumTake: @unchecked Sendable {
    static let phraseCount = 4
    let buffer: AVAudioPCMBuffer
    let clock: LofiClock
    let name: String?
    let kicks: [Kick]
    /// Multiband attack landmarks of the unprocessed take, sorted by attack frame.
    let landmarks: [LofiDrumLandmark]
    /// Sparse timing evidence built from `landmarks` on this take's clock.
    let timing: LofiTimingField

    struct Kick: Equatable, Sendable {
        let frame: Int
        let strength: Float
    }

    /// Landmarks and kicks are found on the unprocessed take; `chain` (the drum bus, plan 8.2) then
    /// runs on the whole buffer before the splice taper. It has no latency, so both still point at
    /// the same frames. `nil` keeps the raw recording (tests).
    init(recording: LofiDrumLibrary.Break?, clock: LofiClock,
         chain: LofiStemChains.Drums? = .standard) throws {
        let count = clock.frameCount * Self.phraseCount
        buffer = try LofiRenderer.stereoBuffer(clock: clock, frames: count)
        self.clock = clock
        name = recording?.entry.name
        guard let recording, let channels = buffer.floatChannelData else {
            kicks = []
            landmarks = []
            timing = LofiTimingField(landmarks: [], clock: clock)
            return
        }
        let sourceCount = recording.left.count
        guard sourceCount > 0, recording.right.count == sourceCount else { throw LofiDrumLibrary.LibraryError.badRecording }
        let rate = Double(sourceCount) / Double(count)
        if sourceCount == count {
            for frame in 0..<count {
                if frame.isMultiple(of: 8192) { try Task.checkCancellation() }
                channels[0][frame] = recording.left[frame] * recording.gain
                channels[1][frame] = recording.right[frame] * recording.gain
            }
        } else {
            try Self.resample(recording, into: channels, count: count, rate: rate)
        }
        landmarks = try LofiDrumLandmarks.detect(left: channels[0], right: channels[1], count: count,
                                                 sampleRate: clock.sampleRate)
        timing = LofiTimingField(landmarks: landmarks, clock: clock)
        kicks = try Self.detectKicks(channels, count: count, sampleRate: clock.sampleRate)
        if let chain {
            try Task.checkCancellation()
            // Capture only: the kick's low-band attack time before and after the drum bus (C-B4).
            let probe = LofiCaptureHooks.isEnabled ? Self.attackProbe(landmarks) : []
            let raw = probe.isEmpty ? [] : Self.kickAttackTimes(channels, count: count, at: probe, sampleRate: clock.sampleRate)
            var stats = LofiStemChains.applyDrums(left: channels[0], right: channels[1], count: count,
                                                  sampleRate: clock.sampleRate, settings: chain)
            if !probe.isEmpty {
                let processed = Self.kickAttackTimes(channels, count: count, at: probe, sampleRate: clock.sampleRate)
                if let before = Self.median(raw), let after = Self.median(processed), before > 0 {
                    stats.extra["kickAttackRatio"] = Float(after / before)
                    stats.extra["kickAttackMs"] = Float(after * 1000 / clock.sampleRate)
                }
            }
            LofiStemChains.report(stats, bus: "drums", take: LofiStemChains.nextReportedTake())
        }
        // Independent takes can end well away from zero. Taper just the splice,
        // leaving the drummer's downbeat position and all interior fills intact.
        let attack = min(count / 2, max(2, Int(clock.sampleRate * 0.001)))
        let release = min(count / 2, max(2, Int(clock.sampleRate * 0.004)))
        for channel in [channels[0], channels[1]] {
            for i in 0..<attack { channel[i] *= Float(i) / Float(attack - 1) }
            for i in 0..<release { channel[count - 1 - i] *= Float(i) / Float(release - 1) }
        }
    }

    /// The strongest confident kicks of a take (at most 24), for the attack-time probe.
    private static func attackProbe(_ landmarks: [LofiDrumLandmark]) -> [Int] {
        landmarks.filter { $0.kind == .kick && $0.confidence >= 0.6 }
            .sorted { $0.strength > $1.strength }.prefix(24).map(\.attackFrame)
    }

    /// Frames from 10 to 90 percent of each kick's 40-160 Hz envelope rise (mono sum).
    private static func kickAttackTimes(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int,
                                        at frames: [Int], sampleRate: Double) -> [Double] {
        let span = Int(0.3 * sampleRate)
        var mono = [Float](repeating: 0, count: 2 * span)
        return frames.compactMap { frame in
            let start = max(0, frame - span), end = min(count, frame + span)
            guard end > start else { return nil }
            for i in start..<end { mono[i - start] = 0.5 * (channels[0][i] + channels[1][i]) }
            return mono.withUnsafeBufferPointer { m -> Double? in
                let n = end - start, center = frame - start
                guard let a = LofiDrumLandmarks.lowBandRise(m.baseAddress!, count: n, around: center, sampleRate: sampleRate, share: 0.1),
                      let b = LofiDrumLandmarks.lowBandRise(m.baseAddress!, count: n, around: center, sampleRate: sampleRate, share: 0.9),
                      b > a else { return nil }
                return Double(b - a)
            }
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Phrase-local performance times for placing bass attacks. Keep the original take intact.
    func bassAnchors(startBeat: Int) -> [Double] {
        let start = clock.frame(at: Double(startBeat))
        let end = start + clock.frameCount
        return kicks.compactMap { hit in
            guard hit.strength >= 0.55, (start..<end).contains(hit.frame) else { return nil }
            return Double(hit.frame - start) / clock.framesPerBeat
        }
    }

    /// Short windowed-sinc interpolation. Both channels use one position and coefficient
    /// table. The kernel narrows when speeding up enough to cross the output Nyquist limit.
    private static func resample(_ recording: LofiDrumLibrary.Break,
                                 into channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                                 count: Int, rate: Double) throws {
        let halfWidth = 7, phases = 256
        let taps = 2 * halfWidth
        let cutoff = min(1, 1 / rate) * 0.94
        let last = recording.left.count - 1
        func sinc(_ x: Double) -> Double { abs(x) < 0.00001 ? 1 : sin(.pi * x) / (.pi * x) }
        let table = (0..<phases).flatMap { phase -> [Float] in
            let fraction = Double(phase) / Double(phases)
            let weights = (0..<taps).map { tap -> Double in
                let distance = Double(tap - halfWidth + 1) - fraction
                return cutoff * sinc(distance * cutoff) * sinc(distance / Double(halfWidth))
            }
            let sum = weights.reduce(0, +)
            return weights.map { Float($0 / sum) }
        }
        try recording.left.withUnsafeBufferPointer { x in
            try recording.right.withUnsafeBufferPointer { y in
                try table.withUnsafeBufferPointer { kernel in
                    guard let x = x.baseAddress, let y = y.baseAddress, let kernel = kernel.baseAddress else { return }
                    let outL = channels[0], outR = channels[1]
                    let gain = recording.gain
                    for frame in 0..<count {
                        if frame.isMultiple(of: 8192) { try Task.checkCancellation() }
                        let position = Double(frame) * rate
                        let whole = Int(position)
                        let phase = Int((position - Double(whole)) * Double(phases))
                        let weights = kernel + phase * taps
                        let start = whole - halfWidth + 1
                        var left: Float = 0, right: Float = 0
                        if start >= 0, start + taps <= last + 1 {
                            vDSP_dotpr(x + start, 1, weights, 1, &left, vDSP_Length(taps))
                            vDSP_dotpr(y + start, 1, weights, 1, &right, vDSP_Length(taps))
                        } else {
                            for tap in 0..<taps {
                                let sample = min(last, max(0, start + tap))
                                left += x[sample] * weights[tap]
                                right += y[sample] * weights[tap]
                            }
                        }
                        outL[frame] = gain * left
                        outR[frame] = gain * right
                    }
                }
            }
        }
    }

    /// Low-band flux gated by its share of the attack energy. Snare bleed and quiet hits make
    /// these candidates, so the sidechain uses a small depth and never hard-mutes bass.
    private static func detectKicks(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                                    count: Int, sampleRate: Double) throws -> [Kick] {
        let hop = max(1, Int(sampleRate * 0.005))
        let low = Float(1 - exp(-2 * .pi * 105 / sampleRate))
        let dc = Float(1 - exp(-2 * .pi * 32 / sampleRate))
        var lp = SIMD2<Float>.zero
        var hp = SIMD2<Float>.zero
        var previous: Float = 0
        var bins: [(frame: Int, novelty: Float)] = []
        for start in stride(from: 0, to: count, by: hop) {
            if (start / hop).isMultiple(of: 128) { try Task.checkCancellation() }
            var body: Float = 0, total: Float = 0
            for i in start..<min(start + hop, count) {
                let x = SIMD2(channels[0][i], channels[1][i])
                lp += (x - lp) * low
                hp += (lp - hp) * dc
                let kick = lp - hp
                body += kick.x * kick.x + kick.y * kick.y
                total += x.x * x.x + x.y * x.y
            }
            let energy = sqrtf(body / Float(hop))
            let novelty = energy - previous
            bins.append((start, total > 1e-8 && body / total > 0.19 ? max(0, novelty) : 0))
            previous += (energy - previous) * 0.60
        }
        guard bins.count > 2, let peak = bins.map(\.novelty).max(), peak > 0.008 else { return [] }
        let separation = Int(sampleRate * 0.11)
        var hits: [Kick] = []
        for i in bins.indices {
            let bin = bins[i]
            guard bin.novelty >= max(0.006, peak * 0.185),
                  (i == 0 || bin.novelty > bins[i - 1].novelty),
                  (i == bins.count - 1 || bin.novelty >= bins[i + 1].novelty) else { continue }
            let kick = Kick(frame: max(0, bin.frame - hop), strength: min(1, bin.novelty / (peak * 0.58)))
            if let last = hits.last, kick.frame - last.frame < separation {
                if kick.strength > last.strength { hits[hits.count - 1] = kick }
            } else {
                hits.append(kick)
            }
        }
        return hits
    }
}
