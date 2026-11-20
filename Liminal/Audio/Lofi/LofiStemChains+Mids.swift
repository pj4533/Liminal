import Accelerate
import Foundation

nonisolated extension LofiStemChains {
    /// Sampled mid shells, per phrase (plan 8.4). The hiss is added after this chain.
    struct Mids: Sendable, Equatable {
        var filters: [LofiBiquad.Kind] = [
            .highpass(hz: 160, q: butterworthQ), .peak(hz: 400, q: 1.0, gainDB: -3),
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
}
