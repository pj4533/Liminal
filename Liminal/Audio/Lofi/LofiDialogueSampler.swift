import Accelerate
import AVFoundation
import Foundation
import OSLog

/// Samples the decoded soundtrack of one upcoming picture. Analysis and all varispeed
/// rendering run on the footage worker. The music queue only schedules finished buffers.
nonisolated enum LofiDialogueSampler {
    enum Articulation: String { case phrase, extended, pickup, tail, splitHead, splitReply, lineFragment, wholeLine }

    struct Hit {
        let articulation: Articulation
        let time: Double             // Absolute audible time on the supplied transport
        let source: Range<Int>       // Frames in the decoded picture cue
        let speed: Double
        var reversed = false
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
            let quality = sqrtf(peak) * occupied * Float(1 - 0.45 * abs(duration - 0.79))
            result.append(Slice(frames: (start * analysis.hop)..<(end * analysis.hop), score: quality))
        }
        return result
    }

    /// Continue across a nearby consonant only when the speaker carries on.
    private static func extended(_ frames: Range<Int>, analysis: Analysis) -> Range<Int> {
        let start = frames.lowerBound / analysis.hop
        let end = frames.upperBound / analysis.hop
        guard let next = analysis.cuts.first(where: { $0 >= end - 3 }), next <= end + 12 else { return frames }
        let limit = min(start + 176, next + 51, analysis.energy.count - 1,
                        analysis.cuts.first(where: { $0 > next }) ?? analysis.energy.count - 1)
        guard limit >= max(end + 13, next + 10) else { return frames }
        let gate = (analysis.energy[next...limit].max() ?? 0) * 0.24
        let landing = (next + 10...limit).first { analysis.energy[$0] < gate } ?? limit
        return frames.lowerBound..<max(frames.upperBound, landing * analysis.hop)
    }

    /// Use an actual syllable onset as the internal edit, keeping a usable word fragment on both sides.
    private static func splitPoint(_ frames: Range<Int>, analysis: Analysis, rate: Double) -> Int? {
        let margin = Int(0.145 * rate)
        let middle = frames.lowerBound + frames.count / 2
        return analysis.cuts.lazy.map { $0 * analysis.hop }
            .filter { $0 >= frames.lowerBound + margin && $0 < frames.upperBound - margin }
            .min { abs($0 - middle) < abs($1 - middle) }
    }

    /// Follow a promising onset through several syllables. Prefer a breath near
    /// the end of a two-second thought; stop searching at a break in the delivery.
    private static func lines(from slices: [Slice], analysis: Analysis) -> [Slice] {
        let e = analysis.energy
        let hop = analysis.hop
        return slices.compactMap { slice in
            let start = slice.frames.lowerBound / hop
            let limit = min(e.count, start + 270)
            let peak = e[start..<(slice.frames.upperBound / hop)].max() ?? 0
            let quietLevel = peak * 0.22
            let onsets = analysis.cuts.drop { $0 < start }
            guard let fourth = onsets.dropFirst(3).first, fourth < limit else { return nil }
            let lead = e[max(0, start - 12)...start]
            let cleanStart = Float(lead.filter { $0 <= quietLevel }.count) / Float(lead.count)
            var quiet = 0
            var best: Slice?
            var bestScore: Float = 0
            for j in start..<limit {
                quiet = e[j] <= quietLevel ? quiet + 1 : 0
                if quiet > 28 { break }
                let end = j - quiet + 3  // retain the release without padding the quote with silence
                guard quiet >= 3, end >= start + 118, end >= fourth + 8 else { continue }
                let durationFit = 1 - 0.003 * Float(abs(190 - (end - start)))
                let score = durationFit * (0.7 + 0.3 * cleanStart) * (1 + Float(min(quiet, 14)) / 18)
                if score > bestScore {
                    bestScore = score
                    best = Slice(frames: start * hop..<end * hop, score: slice.score * score)
                }
            }
            return best
        }
    }

    /// Quote two parts of one line, then play it intact on the next downbeat.
    /// Reserve space for the intact take before choosing the length of its pickups.
    private static func buildLine(_ pool: [Slice], source: AVAudioPCMBuffer, analysis: Analysis,
                                  cueStart: Double, earliest: Double, downbeat: Double, beat: Double,
                                  deadline: Double, previous: Range<Int>?, rng: inout MusicRNG) -> [Hit] {
        let rate = source.format.sampleRate
        let room = deadline - downbeat
        guard downbeat >= earliest, room >= 1 else { return [] }
        func rank(_ s: Slice) -> Float {
            let age = abs((downbeat - cueStart) - Double(s.frames.lowerBound) / rate)
            return s.score / Float(1 + 0.18 * age) * (s.frames == previous ? 0.4 : 1)
        }
        let candidates = pool.filter { Double($0.frames.count) / rate <= room * 1.08 }
        guard let line = candidates.max(by: { rank($0) < rank($1) }) else { return [] }
        let frames = line.frames
        let duration = Double(frames.count) / rate
        let target = max(beat / 2, (duration / (beat / 2)).rounded() * beat / 2)
        let speed = max(duration / room, min(1.08, max(0.92, duration / target)))
        guard let whole = sample(source, frames: frames, analysis: analysis, speed: speed, accent: 1) else { return [] }
        let cuts = analysis.cuts.map { $0 * analysis.hop }.filter { frames.contains($0) }
        func cut(after start: Int, seconds: Double) -> Int? {
            let target = start + Int(seconds * rate)
            return cuts.filter { $0 >= start + Int(0.15 * rate) }.min { abs($0-target) < abs($1-target) }
        }
        var hits: [Hit] = []
        if let first = cut(after: frames.lowerBound, seconds: 0.40),
           let second = cut(after: first, seconds: 0.66) {
            let calls = [(downbeat - rng.pick([3.0, 3.5]) * beat, frames.lowerBound..<first, rng.range(0.83...1.20)),
                         (downbeat - rng.pick([1.5, 2.0]) * beat, first..<second, rng.range(0.9...1.14))]
            var available = earliest
            for (i, call) in calls.enumerated() {
                let (at, part, speed) = call
                let end = at + Double(part.count) / (speed * rate)
                let next = i == 0 ? calls[1].0 : downbeat
                guard at >= available, end + 0.04 <= next,
                      let buffer = sample(source, frames: part, analysis: analysis, speed: speed, accent: 0.88) else { continue }
                hits.append(Hit(articulation: .lineFragment, time: at, source: part, speed: speed, buffer: buffer))
                available = end + 0.04
            }
        }
        hits.append(Hit(articulation: .wholeLine, time: downbeat, source: frames, speed: speed, buffer: whole))
        return hits
    }

    static func prepareFootage(_ source: AVAudioPCMBuffer, grid: LofiTakeGrid, cueStart: Double,
                               duration: Double, seed: UInt64) -> [Hit] {
        let windows = LofiSpeechFocus.classify(source, seconds: duration)
        let spoken = windows.filter { $0.speech > max(0.3, $0.singing, $0.music) }.count
        LMLog.audio.info("Lo-Fi speech analysis: \(spoken) of \(windows.count) windows predominantly spoken")
        return prepare(source, grid: grid, cueStart: cueStart, duration: duration, seed: seed, speech: windows)
    }

    static func prepare(_ source: AVAudioPCMBuffer, grid: LofiTakeGrid, cueStart: Double,
                        duration: Double, seed: UInt64, speech: [LofiSpeechFocus.Window] = []) -> [Hit] {
        let rate = source.format.sampleRate
        let span = min(32, duration, Double(source.frameLength) / rate)
        guard grid.beatDuration > 0, span > 1, let input = source.floatChannelData?[0],
              let analysis = analyze(input, count: min(Int(source.frameLength), Int(span * rate)), rate: rate)
        else { return [] }
        func ranked(_ candidates: [Slice]) -> [Slice] {
            candidates.compactMap { slice in
                let weight = LofiSpeechFocus.weight(slice.frames, rate: rate, windows: speech)
                return weight > 0 ? Slice(frames: slice.frames, score: slice.score * weight) : nil
            }
        }
        let candidates = slices(analysis, rate: rate)
        let pool = ranked(candidates)
        guard !pool.isEmpty else { return [] }
        let linePool = ranked(lines(from: pool, analysis: analysis))
        let turn = grid.origin + 64 * grid.beatDuration
        let nextBeat = grid.nextBeatDuration ?? grid.beatDuration
        func time(_ beat: Double) -> Double {
            beat < 64 ? grid.origin + beat * grid.beatDuration : turn + (beat - 64) * nextBeat
        }
        let firstBeat = cueStart < turn ? (cueStart - grid.origin) / grid.beatDuration : 64 + (cueStart - turn) / nextBeat
        var group = floor(firstBeat / 8) * 8
        var hits: [Hit] = []
        var rng = MusicRNG(seed: seed)
        var phrasing = rng.fork(304)
        var lineRNG = rng.fork(305)
        let lineGroup = lineRNG.int(0...1)
        var lastEnd = cueStart + 0.18
        var previous: Range<Int>?
        var previousLine: Range<Int>?
        while time(group) < cueStart + span {
            defer { group += 8 }
            if !linePool.isEmpty, (Int(group / 8) - lineGroup).isMultiple(of: 2) {
                let resolve = group + 4
                let fillStart = floor(group / 32) * 32 + 30
                let line = buildLine(linePool, source: source, analysis: analysis, cueStart: cueStart,
                                     earliest: lastEnd, downbeat: time(resolve), beat: time(resolve + 1) - time(resolve),
                                     deadline: min(cueStart + span, time(min(group + 8, fillStart)) - 0.04),
                                     previous: previousLine, rng: &lineRNG)
                if let whole = line.last {
                    hits += line
                    previousLine = whole.source
                    lastEnd = whole.time + Double(whole.buffer.frameLength) / rate + 0.04
                    continue
                }
            }
            // Two bars of call and response. Leave the drummer the run-up to
            // each eight-bar fill, with a different pocket on the next picture.
            let positions = rng.pick([[1.5, 4, 6.5], [2.0, 3.5, 6.0], [0.5, 3, 4.5], [1, 5]])
            let slots = positions.map { group + $0 }.filter { beat in
                let at = time(beat)
                guard beat.truncatingRemainder(dividingBy: 32) < 30,
                      at >= lastEnd, at < cueStart + span - 0.25 else { return false }
                return true
            }
            var slice: Slice?
            var played = 0
            let answerWithTail = rng.chance(0.56)
            let sustain = phrasing.chance(0.46)
            let brokenReply = phrasing.chance(0.68)
            let shortPickup = !sustain && phrasing.chance(0.47)
            let lateReply = phrasing.chance(0.5)
            for (index, position) in slots.enumerated() {
                let at = time(position)
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
                var frames = sustain ? extended(slice.frames, analysis: analysis) : slice.frames
                if frames != slice.frames, LofiSpeechFocus.weight(frames, rate: rate, windows: speech) == 0 {
                    frames = slice.frames
                }
                var articulation: Articulation = frames == slice.frames ? .phrase : .extended
                let split = splitPoint(frames, analysis: analysis, rate: rate)
                if played == 0, shortPickup, let split {
                    frames = frames.lowerBound..<split
                    articulation = .pickup
                } else if played == 2, answerWithTail,
                          let syllable = analysis.cuts.last(where: { cut in
                              let tail = Double(frames.upperBound - cut * analysis.hop) / rate
                              return cut * analysis.hop > frames.lowerBound && (0.17...0.48).contains(tail)
                          }) {
                    frames = (syllable * analysis.hop)..<frames.upperBound
                    articulation = .tail
                }
                let length = Double(frames.count) / rate
                let target = played == 2 ? (rng.chance(0.5) ? 0.83 : 1.20) : 1.0
                let quarters = max(1, (length / (beat * 0.25 * target)).rounded())
                let speed = min(1.38, max(0.72, length / (quarters * beat * 0.25)))
                let fillStart = floor(position / 32) * 32 + 30
                let nextSlot = index + 1 < slots.count ? slots[index+1] : group + 8
                let deadline = min(cueStart + span, time(min(nextSlot, fillStart)) - 0.04)
                guard at >= lastEnd, at + length / speed <= deadline else { continue }

                if played == 1, brokenReply, let split {
                    let head = frames.lowerBound..<split, reply = split..<frames.upperBound
                    let headEnd = at + Double(head.count) / (rate * speed)
                    // Wait at least a sixth of a beat after the first sound dies.
                    // Land on an eighth, or a sixteenth later for a softer delayed answer.
                    let earliest = position + (headEnd - at) / beat + 1.0 / 6
                    let reentry = time(ceil(earliest * 2) / 2 + (lateReply ? 0.25 : 0))
                    let replyEnd = reentry + Double(reply.count) / (rate * speed)
                    if reentry > headEnd, replyEnd <= deadline,
                       let first = sample(source, frames: head, analysis: analysis, speed: speed, accent: 0.84),
                       let second = sample(source, frames: reply, analysis: analysis, speed: speed, accent: 0.92) {
                        hits.append(Hit(articulation: .splitHead, time: at, source: head, speed: speed, buffer: first))
                        hits.append(Hit(articulation: .splitReply, time: reentry, source: reply, speed: speed, buffer: second))
                        lastEnd = replyEnd + 0.04
                        played += 1
                        previous = slice.frames
                        continue
                    }
                }

                guard let buffer = sample(source, frames: frames, analysis: analysis, speed: speed,
                                          accent: played == 1 ? 0.84 : 1) else { continue }
                played += 1
                previous = slice.frames
                hits.append(Hit(articulation: articulation, time: at, source: frames, speed: speed, buffer: buffer))
                lastEnd = at + Double(buffer.frameLength) / rate + 0.04
            }
        }
        // Reverse one short pickup occasionally, keeping the recognisable returns forward.
        let pickups = hits.indices.filter { i in
            [.lineFragment, .pickup, .tail].contains(hits[i].articulation) &&
                Double(hits[i].buffer.frameLength) / rate < 0.7
        }
        if !pickups.isEmpty, phrasing.chance(0.72) {
            let i = phrasing.pick(pickups)
            let buffer = hits[i].buffer
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    vDSP_vrvrs(channels[c], 1, vDSP_Length(buffer.frameLength))
                }
                hits[i].reversed = true
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
        var presenceTrim: Float = 1
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
                // Tame a forward presence band in thin or already heavily EQ’d film audio.
                presenceTrim = 1 - 0.27 * min(1, power.y / max(1e-9, power.x + power.y) * 1.7)
                lastWindow = window
            }
            weights += (target - weights) * 0.012
            low += (SIMD3(repeating: x) - low) * coef
            let filtered = (low.y - low.x) * weights.x + (low.z - low.y) * weights.y * presenceTrim + (x - low.z) * weights.z * 0.12
            let edge = min(1, Float(i) / Float(rate * 0.006), Float(count-1-i) / Float(rate * 0.025))
            out[0][i] = filtered * edge
        }
        var scale = clipGain(out[0], count: count, rate: rate) * accent
        vDSP_vsmul(out[0], 1, &scale, out[0], 1, vDSP_Length(count))
        for c in 1..<Int(source.format.channelCount) { out[c].update(from: out[0], count: count) }
        return buffer
    }

    /// Level the audible syllables after EQ. Quiet spaces between words must not
    /// turn a shout up. Short cuts use their actual duration, without zero padding.
    static func clipGain(_ samples: UnsafePointer<Float>, count: Int, rate: Double) -> Float {
        guard count > 0 else { return 0 }
        let hop = max(1, Int(rate * 0.05))
        var weighting = LofiKWeighting(sampleRate: rate)
        var powers: [Double] = []
        var peak: Float = 0
        for start in stride(from: 0, to: count, by: hop) {
            let end = min(start + hop, count)
            var power = 0.0
            for i in start..<end {
                let weighted = weighting.process(Double(samples[i]))
                power += weighted * weighted
                peak = max(peak, abs(samples[i]))
            }
            powers.append(power / Double(end - start))
        }
        let loud = powers.sorted()[powers.count * 4 / 5]
        let width = min(8, powers.count)
        var momentary = 0.0
        for i in width...powers.count {
            momentary = max(momentary, powers[(i-width)..<i].reduce(0, +) / Double(width))
        }
        let level = Float(sqrt(max(1e-9, loud, momentary)))
        return min(5, 0.132 / level, 0.44 / max(0.001, peak))
    }

}
