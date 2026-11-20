import Accelerate
import Foundation

nonisolated extension LofiStemChains {
    /// Sampled mid shells, per phrase (plan 8.4). The hiss is added after this chain. The high-pass rose
    /// from 160 to 180 Hz with the held pad (D117): the shells answer over the pad, the bass owns the lows.
    struct Mids: Sendable, Equatable {
        var filters: [LofiBiquad.Kind] = [
            .highpass(hz: 180, q: butterworthQ), .peak(hz: 400, q: 1.0, gainDB: -3),
            .peak(hz: 1_600, q: 1.0, gainDB: 1.5), .lowpass(hz: 7_000, q: butterworthQ),
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
    /// the middle under the lead and the chops. High-pass 220 Hz, -3 dB at 380 Hz, -3.5 dB at 2 kHz (room
    /// for the lead's and the chops' presence; plan start -2, which left the chords' 1 to 4 kHz 6.2 dB
    /// under the melody against a gate of 8), low-pass 2.8 kHz, both 12 dB per octave; mono below 300 Hz.
    /// The shells' +1.5 dB at 1.6 kHz is not used on the pad.
    struct Pad: Sendable, Equatable {
        var filters: [LofiBiquad.Kind] = [
            .highpass(hz: 220, q: butterworthQ), .peak(hz: 380, q: 1.0, gainDB: -3),
            .peak(hz: 2_000, q: 0.8, gainDB: -3.5), .lowpass(hz: 2_800, q: butterworthQ),
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
