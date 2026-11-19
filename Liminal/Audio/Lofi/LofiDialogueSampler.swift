import Accelerate
import AVFoundation
import Foundation

/// Samples the decoded soundtrack of one upcoming picture. Analysis and all varispeed
/// rendering run on the footage worker. The music queue only schedules finished buffers.
nonisolated enum LofiDialogueSampler {
    struct Hit {
        let time: Double             // Absolute audible time on the supplied transport
        let source: Range<Int>       // Frames in the decoded picture cue
        let speed: Double
        let buffer: AVAudioPCMBuffer
    }

    private struct Analysis {
        let hop: Int
        let bands: [SIMD3<Float>]
        let floor: SIMD3<Float>
        let energy: [Float]
        let cuts: [Int]
    }

    /// A 10 ms envelope in three speech bands. Estimate a stationary background
    /// separately in each band, retaining a little of it to preserve the film's texture.
    private static func analyze(_ input: UnsafePointer<Float>, count: Int, rate: Double) -> Analysis? {
        let hop = max(1, Int((rate * 0.010).rounded()))
        guard count / hop >= 40 else { return nil }
        let step = SIMD3<Float>(145, 820, 3900)
        let coefficients = SIMD3<Float>((0..<3).map { Float(1 - exp(-2 * .pi * Double(step[$0]) / rate)) })
        var low = SIMD3<Float>.zero
        var bands: [SIMD3<Float>] = []
        for start in stride(from: 0, through: count - hop, by: hop) {
            var sum = SIMD3<Float>.zero
            for i in start..<(start + hop) {
                low += coefficients * (SIMD3(repeating: input[i]) - low)
                let band = SIMD3(low.y - low.x, low.z - low.y, input[i] - low.z)
                sum += band * band
            }
            bands.append(sum / Float(hop))
        }
        let floor = SIMD3<Float>((0..<3).map { b in bands.map { $0[b] }.sorted()[bands.count / 5] })
        var energy = bands.map { band -> Float in
            sqrtf(max(0, band.x - floor.x) + 1.35 * max(0, band.y - floor.y))
        }
        // Retain consonant onsets but smooth over individual glottal pulses.
        for i in 1..<(energy.count - 1) { energy[i] = (energy[i-1] + 2 * energy[i] + energy[i+1]) * 0.25 }
        let typical = energy.sorted()[energy.count * 4 / 5]
        let gate = max(0.0025, typical * 0.19)
        var cuts: [Int] = []
        for i in 4..<(energy.count - 6) {
            let before = energy[(i-4)..<i].min() ?? 0
            let after = energy[i...i+5].max() ?? 0
            guard after > gate * 2, after - before > max(gate, after * 0.44),
                  energy[i+1] > energy[i], i - (cuts.last ?? -20) >= 12 else { continue }
            let onset = (i-4...i).min { energy[$0] < energy[$1] } ?? i
            cuts.append(onset)
        }
        guard cuts.count >= 2 else { return nil }
        return Analysis(hop: hop, bands: bands, floor: floor, energy: energy, cuts: cuts)
    }

    private struct Slice {
        let frames: Range<Int>
        let score: Float
    }

    /// Combine nearby syllables into a single gesture, ending in a valley. Wide
    /// gaps, sustained beds and short clicks give little evidence for a spoken hook.
    private static func slices(_ analysis: Analysis, rate: Double) -> [Slice] {
        let e = analysis.energy
        var result: [Slice] = []
        for (i, start) in analysis.cuts.enumerated() {
            guard i + 1 < analysis.cuts.count else { continue }
            let next = analysis.cuts[i+1]
            guard (12...55).contains(next - start) else { continue }
            // Allow three syllables when the speaker runs them together. A real
            // pause still wins over this upper bound, even in a fast sentence.
            let last = min(i + 3, analysis.cuts.count - 1)
            let limit = min(e.count - 1, start + 124, analysis.cuts[last] + (last == i + 3 ? 0 : 38))
            guard limit >= next + 8 else { continue }
            let peak = e[start...limit].max() ?? 0
            guard peak > 0.006 else { continue }
            var end = (next+8...limit).first { j in
                e[j] < 0.19 * peak && (e[max(next, j-3)...j].max() ?? 0) < 0.26 * peak
            } ?? limit
            end = min(limit, end + 2)
            let body = e[start...end]
            let occupied = Float(body.filter { $0 > peak * 0.21 }.count) / Float(body.count)
            guard (0.23...0.96).contains(occupied) else { continue }
            var mid: Float = 0, hiss: Float = 0
            for j in start...end {
                let b = analysis.bands[j]
                mid += max(0, b.x - analysis.floor.x) + max(0, b.y - analysis.floor.y)
                hiss += b.z
            }
            guard mid > hiss * 0.65 else { continue }
            let duration = Double(end-start) * Double(analysis.hop) / rate
            let quality = peak * occupied * Float(1 - 0.45 * abs(duration - 0.79))
            result.append(Slice(frames: (start * analysis.hop)..<(end * analysis.hop), score: quality))
        }
        return result
    }

    static func prepare(_ source: AVAudioPCMBuffer, grid: LofiTakeGrid, cueStart: Double,
                        duration: Double, seed: UInt64) -> [Hit] {
        let rate = source.format.sampleRate
        let span = min(32, duration, Double(source.frameLength) / rate)
        guard grid.beatDuration > 0, span > 1, let input = source.floatChannelData?[0],
              let analysis = analyze(input, count: min(Int(source.frameLength), Int(span * rate)), rate: rate)
        else { return [] }
        let pool = slices(analysis, rate: rate)
        guard !pool.isEmpty else { return [] }
        let turn = grid.origin + 64 * grid.beatDuration
        let nextBeat = grid.nextBeatDuration ?? grid.beatDuration
        func time(_ beat: Double) -> Double {
            beat < 64 ? grid.origin + beat * grid.beatDuration : turn + (beat - 64) * nextBeat
        }
        let firstBeat = cueStart < turn ? (cueStart - grid.origin) / grid.beatDuration : 64 + (cueStart - turn) / nextBeat
        var group = floor(firstBeat / 8) * 8
        var hits: [Hit] = []
        var rng = MusicRNG(seed: seed)
        var lastEnd = cueStart + 0.18
        var previous: Range<Int>?
        while time(group) < cueStart + span {
            // Two bars of call and response. Leave the drummer the run-up to
            // each eight-bar fill, with a different pocket on the next picture.
            let positions = rng.pick([[1.5, 4, 6.5], [2.0, 3.5, 6.0], [0.5, 3, 4.5], [1, 5]])
            let slots = positions.compactMap { offset -> Double? in
                let beat = group + offset
                let at = time(beat)
                guard beat.truncatingRemainder(dividingBy: 32) < 30,
                      at >= lastEnd, at < cueStart + span - 0.25 else { return nil }
                return at
            }
            defer { group += 8 }
            var slice: Slice?
            var played = 0
            let answerWithTail = rng.chance(0.56)
            for at in slots {
                if slice == nil {
                    let elapsed = at - cueStart
                    let nearby = pool.filter {
                        let start = Double($0.frames.lowerBound) / rate
                        return start <= elapsed + 0.35 && start >= elapsed - 6
                    }
                    // A speaker may pause for several bars, or the picture may
                    // open in silence. Borrow the closest phrase from this same
                    // cue, so the vocal rhythm can continue through either gap.
                    let candidates = nearby.isEmpty ? pool : nearby
                    slice = candidates.max { a, b in
                        func rank(_ s: Slice) -> Float {
                            let age = abs(elapsed - Double(s.frames.upperBound) / rate)
                            return s.score / Float(1 + 0.23 * age) * (s.frames == previous ? 0.6 : 1)
                        }
                        return rank(a) < rank(b)
                    }
                }
                guard let slice else { continue }
                let beat = at < turn ? grid.beatDuration : nextBeat
                var frames = slice.frames
                if played == 2, answerWithTail,
                   let syllable = analysis.cuts.last(where: { cut in
                       let tail = Double(frames.upperBound - cut * analysis.hop) / rate
                       return cut * analysis.hop > frames.lowerBound && (0.17...0.48).contains(tail)
                   }) {
                    frames = (syllable * analysis.hop)..<frames.upperBound
                }
                let length = Double(frames.count) / rate
                let target = played == 2 ? (rng.chance(0.5) ? 0.83 : 1.20) : 1.0
                let quarters = max(1, (length / (beat * 0.25 * target)).rounded())
                let speed = min(1.38, max(0.72, length / (quarters * beat * 0.25)))
                guard at >= lastEnd, at + length / speed <= cueStart + span,
                      let buffer = sample(source, frames: frames, analysis: analysis, speed: speed,
                                          accent: played == 1 ? 0.84 : 1) else { continue }
                played += 1
                previous = slice.frames
                hits.append(Hit(time: at, source: frames, speed: speed, buffer: buffer))
                lastEnd = at + Double(buffer.frameLength) / rate + 0.04
            }
        }
        return hits
    }

    private static func sample(_ source: AVAudioPCMBuffer, frames: Range<Int>, analysis: Analysis,
                               speed: Double, accent: Float) -> AVAudioPCMBuffer? {
        let rate = source.format.sampleRate
        let count = Int(Double(frames.count - 1) / speed)
        guard count > 1, let src = source.floatChannelData?[0],
              let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let coef = SIMD3<Float>([150.0, 820.0, 3900.0].map { Float(1 - exp(-2 * .pi * $0 / rate)) })
        var low = SIMD3<Float>.zero
        var weights = SIMD3<Float>(repeating: 0.5)
        var lastWindow = -1
        var target = weights
        for i in 0..<count {
            let p = Double(frames.lowerBound) + Double(i) * speed
            let j = Int(p)
            let x = src[j] + Float(p - Double(j)) * (src[j+1] - src[j])
            let window = j / analysis.hop
            if window != lastWindow {
                let power = analysis.bands[window]
                for b in 0..<3 {
                    target[b] = max(0.18, 1 - 1.4 * analysis.floor[b] / max(power[b], 1e-10))
                }
                lastWindow = window
            }
            weights += (target - weights) * 0.012
            low += (SIMD3(repeating: x) - low) * coef
            let filtered = (low.y - low.x) * weights.x + (low.z - low.y) * weights.y + (x - low.z) * weights.z * 0.12
            let edge = min(1, Float(i) / Float(rate * 0.006), Float(count-1-i) / Float(rate * 0.025))
            out[0][i] = filtered * edge
        }
        var rms: Float = 0, peak: Float = 0
        vDSP_rmsqv(out[0], 1, &rms, vDSP_Length(count))
        vDSP_maxmgv(out[0], 1, &peak, vDSP_Length(count))
        let gain = accent * min(12, 0.22 / max(0.001, rms), 0.76 / max(0.001, peak))
        var scale = gain
        vDSP_vsmul(out[0], 1, &scale, out[0], 1, vDSP_Length(count))
        for c in 1..<Int(source.format.channelCount) { out[c].update(from: out[0], count: count) }
        return buffer
    }
}
