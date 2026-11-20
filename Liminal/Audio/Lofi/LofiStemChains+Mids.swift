import Accelerate
import Foundation

nonisolated extension LofiStemChains {
    /// Sampled mid shells, per phrase (plan 8.4). The hiss is added after this chain. The high-pass rose
    /// from 160 to 180 Hz with the held pad (D117): the shells answer over the pad, the bass owns the lows.
    /// The former +1.5 dB at 1.6 kHz was removed in the mix rebalance (D118): the shells' level is held at
    /// the bottom of its range in theme phrases, so the boost alone kept the chords' 1 to 4 kHz within
    /// 8 dB of the melody's.
    struct Mids: Sendable, Equatable {
        var filters: [LofiBiquad.Kind] = [
            .highpass(hz: 180, q: butterworthQ), .peak(hz: 400, q: 1.0, gainDB: -3),
            .lowpass(hz: 7_000, q: butterworthQ),
        ]
        /// The lower shell voice sits left of centre and the upper right: 0.3 apart in total.
        var voicePan: Float = 0.15
        /// Below this the shell is folded back to the centre.
        var monoBelowHz = 300.0
        static let standard = Mids()
    }

    /// Mid shells of one phrase plus its tail: pans the lower and upper voice apart, folds the band
    /// below `monoBelowHz` back to the centre and applies the EQ. Returns the processed stereo sum.
    static func applyMids(lower: (left: [Float], right: [Float]), upper: (left: [Float], right: [Float]),
                          sampleRate: Double, settings: Mids = .standard) -> (left: [Float], right: [Float], stats: Stats) {
        let count = min(lower.left.count, upper.left.count)
        var left = [Float](repeating: 0, count: count), right = left
        var stats = Stats()
        guard count > 0 else { return (left, right, stats) }
        func gains(_ pan: Float) -> (Float, Float) { ((1 - pan).squareRoot(), (1 + pan).squareRoot()) }
        let (lowerL, lowerR) = gains(-settings.voicePan), (upperL, upperR) = gains(settings.voicePan)
        var inLeft = left, inRight = right
        let n = vDSP_Length(count)
        vDSP_vadd(lower.left, 1, upper.left, 1, &inLeft, 1, n)
        vDSP_vadd(lower.right, 1, upper.right, 1, &inRight, 1, n)
        var gains = (lowerL, upperL, lowerR, upperR)
        vDSP_vsmsma(lower.left, 1, &gains.0, upper.left, 1, &gains.1, &left, 1, n)
        vDSP_vsmsma(lower.right, 1, &gains.2, upper.right, 1, &gains.3, &right, 1, n)
        (stats.inPeakDb, stats.inRmsDb) = level(inLeft, inRight)
        // Linkwitz-Riley fold: the pan survives above the crossover at full level difference.
        LofiStereo.monoBelow(settings.monoBelowHz, left: &left, right: &right, sampleRate: sampleRate)
        var eq = LofiFilterChain(settings.filters, sampleRate: sampleRate)
        eq.process(left: &left, right: &right)
        (stats.outPeakDb, stats.outRmsDb) = level(left, right)
        return (left, right, stats)
    }

    /// The held pad (D117): a higher register floor and a darker top than the shells, so it tucks in
    /// the middle under the lead and the chops. High-pass 300 Hz, -3 dB at 380 Hz, -4.5 dB at 2 kHz,
    /// low-pass 2.2 kHz, both 12 dB per octave; mono below 300 Hz. PADS set 220 Hz, -3.5 dB and 2.8 kHz;
    /// the mix rebalance (D118) raised the floor (the chords' 300 to 800 Hz read +2.3 dB on the baseline
    /// over the whole file, gate +2) and darkened the top (their 1 to 4 kHz read 7.4 dB under the melody's,
    /// gate 8). The level match is metered in 400 Hz to 3 kHz, so cuts inside that band come back as gain;
    /// these corners sit mostly outside it. The shells' presence boost is not used on the pad.
    struct Pad: Sendable, Equatable {
        var filters: [LofiBiquad.Kind] = [
            .highpass(hz: 300, q: butterworthQ), .peak(hz: 380, q: 1.0, gainDB: -3),
            .peak(hz: 2_000, q: 0.8, gainDB: -4.5), .lowpass(hz: 2_200, q: butterworthQ),
        ]
        var monoBelowHz = 300.0
        static let standard = Pad()
    }

    /// The pad of one phrase, in place: folds the band below `monoBelowHz` to the centre (the two grain
    /// streams stay apart above it) and applies the EQ.
    @discardableResult
    static func applyPad(left: inout [Float], right: inout [Float], sampleRate: Double,
                         settings: Pad = .standard) -> Stats {
        var stats = Stats()
        guard !left.isEmpty else { return stats }
        (stats.inPeakDb, stats.inRmsDb) = level(left, right)
        LofiStereo.monoBelow(settings.monoBelowHz, left: &left, right: &right, sampleRate: sampleRate)
        var eq = LofiFilterChain(settings.filters, sampleRate: sampleRate)
        eq.process(left: &left, right: &right)
        (stats.outPeakDb, stats.outRmsDb) = level(left, right)
        return stats
    }
}
