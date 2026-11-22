import Foundation

// Waveform onsets of dialogue chops (D126; user direction of 21 November 2026: "when you trigger the
// sample, it immediately hits the word on beat"). A pad used to start at the quietest frame near its
// cut, so breath, room tone and the consonant played before the step and the heard attack wandered
// by tens of milliseconds. Here each pad starts at its waveform onset and knows the frame that
// belongs on the step. Pure and offline; called while a motif is cut, never on an audio thread.

/// Where a cut's sound begins and which of its frames lands on the step.
nonisolated struct DialogueAttack: Sendable, Equatable {
    /// First frame of the cut's sound: the envelope rises out of breath, room tone or the previous word's tail here.
    let audibleFrame: Int
    /// The frame that belongs on the grid step: half the first syllable's peak (the vowel of a
    /// soft "s", "f" or "h" onset; right at the burst of a plosive or glottal vowel).
    let beatFrame: Int
    /// A plosive or glottal attack: the envelope rises at least `hardRiseDB` within `hardRiseSeconds`.
    let hard: Bool
    /// Pad start: at most `softLeadSeconds` before the beat frame, never before the sound.
    let startFrame: Int
    /// Fade-in frames at the pad start.
    let fadeIn: Int
}

/// A band-limited short RMS envelope of one span of a source: 2 ms windows on a 0.5 ms hop over the
/// chop chain's passband (200 Hz to 4.2 kHz), so it hears what the chop will play.
nonisolated struct DialogueOnsetEnvelope: Sendable {
    let origin: Int
    let hop: Int
    let values: [Float]
    /// The span's noise level: the 10th percentile of the envelope.
    let noise: Float

    /// `filtered: false` skips the band filters, for audio the chop chain has already band-limited.
    init(samples: UnsafePointer<Float>, count: Int, rate: Double, span: Range<Int>, filtered: Bool = true) {
        let lo = max(0, span.lowerBound), hi = min(count, span.upperBound)
        hop = max(1, Int((DialogueOnset.hopSeconds * rate).rounded()))
        let window = max(hop, Int((DialogueOnset.windowSeconds * rate).rounded()))
        // Filters warm up on a little of the preceding source.
        let warm = min(lo, Int(0.010 * rate))
        let start = lo - warm
        let n = max(0, hi - start)
        var x = [Float](repeating: 0, count: n)
        var hp = LofiBiquad(.highpass(hz: DialogueOnset.bandLow, q: 0.7071067811865476), sampleRate: rate)
        var hp2 = LofiBiquad(.highpass(hz: DialogueOnset.bandLow, q: 0.7071067811865476), sampleRate: rate)
        var lp = LofiBiquad(.lowpass(hz: DialogueOnset.bandHigh, q: 0.7071067811865476), sampleRate: rate)
        if filtered {
            for i in 0..<n { x[i] = lp.process(hp2.process(hp.process(samples[start + i]))) }
        } else {
            for i in 0..<n { x[i] = samples[start + i] }
        }
        // Squared prefix sums, then centred windows.
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(x[i] * x[i]) }
        origin = lo
        let hops = max(0, (hi - lo) / hop)
        var v = [Float](repeating: 0, count: hops)
        for k in 0..<hops {
            let centre = warm + k * hop
            let a = max(0, centre - window / 2), b = min(n, centre + window / 2)
            v[k] = b > a ? Float(sqrt(max(0, (prefix[b] - prefix[a]) / Double(b - a)))) : 0
        }
        values = v
        let sorted = v.sorted()
        noise = sorted.isEmpty ? 0 : sorted[sorted.count / 10]
    }

    func index(_ frame: Int) -> Int { min(max(0, (frame - origin) / hop), max(0, values.count - 1)) }
    func frame(_ index: Double) -> Int { origin + Int((index * Double(hop)).rounded()) }
}

nonisolated enum DialogueOnset {
    static let bandLow = 200.0
    static let bandHigh = 4200.0
    static let windowSeconds = 0.002
    static let hopSeconds = 0.0005
    /// The first syllable's peak is the largest envelope value this long after the sound begins.
    static let peakWindowSeconds = 0.300
    /// A syllable peak is the largest envelope value this close around it.
    static let peakNeighbourhoodSeconds = 0.010
    /// The sound begins after the envelope has stayed under `max(2 x noise, 0.1 x peak)` this long.
    static let quietRunSeconds = 0.015
    static let hardRiseDB: Float = 12
    static let hardRiseSeconds = 0.005
    /// A chop pad starts at most this long before its beat frame (a long "s" keeps its last 30 ms;
    /// 0 would put the pad start on the step).
    static let softLeadSeconds = 0.030
    static let preRollSeconds = 0.002
    static let zeroCrossingSeconds = 0.001
    static let hardFadeInSeconds = 0.002
    static let softFadeInSeconds = 0.005
    /// The full line keeps its consonant: it starts this long before its sound, at most
    /// `lineMaximumLeadSeconds` before its beat frame (clipped with `lineClipFadeSeconds`).
    static let lineLeadSeconds = 0.003
    static let lineMaximumLeadSeconds = 0.120
    static let lineClipFadeSeconds = 0.008

    /// The attack of the cut that spans `search`. `line` keeps the whole consonant (the intro and
    /// outro statements) instead of starting `softLeadSeconds` before the beat frame. The first
    /// syllable is the first peak that reaches `firstPeakShare` of the loudest value in the first
    /// 300 ms (half: a lead syllable more than 6 dB quieter is skipped).
    static func attack(_ e: DialogueOnsetEnvelope, samples: UnsafePointer<Float>, count: Int, rate: Double,
                       search: Range<Int>, line: Bool = false, firstPeakShare: Float = 0.5) -> DialogueAttack {
        func frames(_ s: Double) -> Int { Int((s * rate).rounded()) }
        let lo = max(search.lowerBound, e.origin)
        let hi = min(search.upperBound, e.origin + e.values.count * e.hop)
        let fallback = DialogueAttack(audibleFrame: search.lowerBound, beatFrame: search.lowerBound, hard: false,
                                      startFrame: search.lowerBound, fadeIn: frames(softFadeInSeconds))
        guard hi - lo > frames(0.02) else { return fallback }
        let iLo = e.index(lo), iHi = max(iLo + 1, e.index(hi - 1) + 1)
        let peakHops = max(1, frames(peakWindowSeconds) / e.hop)
        func peak(from i: Int) -> Float {
            var p: Float = 0
            for k in i..<min(iHi, i + peakHops) where e.values[k] > p { p = e.values[k] }
            return p
        }
        // Fractional index of the first crossing of `level` at or after `i`.
        func crossing(_ level: Float, from i: Int) -> Double? {
            var k = i
            while k < iHi {
                if e.values[k] >= level {
                    guard k > i, e.values[k - 1] < level else { return Double(k) }
                    let a = e.values[k - 1], b = e.values[k]
                    return Double(k - 1) + Double((level - a) / max(1e-12, b - a))
                }
                k += 1
            }
            return nil
        }
        // The first syllable's peak: the first local maximum (within `peakNeighbourhoodSeconds`) that
        // reaches half the loudest value of the first 300 ms. A lead syllable quieter than that is not
        // the beat (a chop starts on the strong one after it); a trailing burst never is.
        let end = min(iHi, iLo + peakHops)
        let loudest = peak(from: iLo)
        guard loudest > 1e-6 else { return fallback }
        let around = max(1, frames(peakNeighbourhoodSeconds) / e.hop)
        var first = (iLo..<end).max { e.values[$0] < e.values[$1] } ?? iLo
        // From the second hop: a tail still decaying at the search start is not a peak.
        var k = iLo + 1
        while k < end {
            let v = e.values[k]
            if v >= firstPeakShare * loudest {
                var top = true
                for j in max(iLo, k - around)..<min(iHi, k + around + 1) where e.values[j] > v { top = false; break }
                if top { first = k; break }
            }
            k += 1
        }
        let p0 = e.values[first]
        guard let c50 = crossing(0.5 * p0, from: iLo) else { return fallback }
        // Walk back from the half-peak crossing to the end of the last quiet run before it.
        let threshold = max(2 * e.noise, 0.1 * p0)
        let quietHops = max(1, frames(quietRunSeconds) / e.hop)
        var audibleIndex = iLo
        k = Int(c50)
        var quiet = 0
        while k > iLo {
            k -= 1
            if e.values[k] < threshold {
                quiet += 1
                if quiet >= quietHops { audibleIndex = k + quiet; break }
            } else {
                quiet = 0
            }
        }
        if audibleIndex == iLo, quiet > 0, k == iLo { audibleIndex = iLo + quiet }
        audibleIndex = min(audibleIndex, Int(c50))
        let beatIndex = c50
        let audible = e.frame(Double(audibleIndex))
        let beat = min(max(search.lowerBound, e.frame(beatIndex)), search.upperBound - 1)
        // Hard: a rise of `hardRiseDB` within `hardRiseSeconds` of the sound's start.
        let before = audibleIndex > iLo ? e.values[audibleIndex - 1] : e.values[audibleIndex]
        var rise: Float = 0
        for k in audibleIndex..<min(iHi, audibleIndex + max(1, frames(hardRiseSeconds) / e.hop) + 1) where e.values[k] > rise { rise = e.values[k] }
        let hard = 20 * log10f(max(rise, 1e-9) / max(before, e.noise, 1e-9)) >= hardRiseDB
        var start: Int
        let fadeIn: Int
        if line {
            start = max(audible - frames(lineLeadSeconds), beat - frames(lineMaximumLeadSeconds))
            fadeIn = start > audible - frames(lineLeadSeconds) ? frames(lineClipFadeSeconds) : frames(hard ? hardFadeInSeconds : softFadeInSeconds)
        } else {
            start = max(audible, beat - frames(softLeadSeconds)) - frames(preRollSeconds)
            fadeIn = frames(hard ? hardFadeInSeconds : softFadeInSeconds)
        }
        start = zeroCrossing(near: start, samples: samples, count: count, radius: frames(zeroCrossingSeconds), before: beat)
        start = min(max(search.lowerBound, start), beat)
        return DialogueAttack(audibleFrame: max(search.lowerBound, audible), beatFrame: beat, hard: hard, startFrame: start, fadeIn: fadeIn)
    }

    /// The zero crossing nearest `frame` within `radius`, never at or after `before`.
    static func zeroCrossing(near frame: Int, samples: UnsafePointer<Float>, count: Int, radius: Int, before: Int) -> Int {
        var best = frame, distance = Int.max
        let lo = max(1, frame - radius), hi = min(count, frame + radius + 1, before)
        guard hi > lo else { return frame }
        for i in lo..<hi where (samples[i - 1] <= 0) != (samples[i] <= 0) {
            if abs(i - frame) < distance { distance = abs(i - frame); best = i }
        }
        return best
    }
}
