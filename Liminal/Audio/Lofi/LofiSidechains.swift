import Accelerate
import Foundation

/// The sidechain listens to low-frequency transients in the actual break. It only changes the bass gain.
/// A take with kick landmarks keys it from them (`landmarkGains`); the level detector below is the
/// fallback for a take without them. Plan 8.3 asked for at most 3 dB; mix calibration (docs/plans/mpc-chopping-measurements.md) set 4 dB
/// with a steeper detector so the measured duck under sustained notes reads 1.5 to 4.5 dB (C-B2) on every
/// matrix case (3 dB read 1.1 to 1.6). 3 ms attack, 100 ms release. It never mutes the bass.
nonisolated struct LofiKickDuck {
    /// Linear depth at full detection: 1 - 10^(-4 / 20).
    static let depth: Float = 0.369_043
    /// Detection slope: the excess over the adaptive threshold that reaches full depth is 1 / slope.
    static let slope: Float = 28
    static let attack = 0.003
    static let release = 0.100

    private let highpassStep: Float
    private let lowpassStep: Float
    private let detectorStep: Float
    private let backgroundStep: Float
    private let attackStep: Float
    private let releaseStep: Float
    private var left = DetectorChannel()
    private var right = DetectorChannel()
    private var peak: Float = 0
    private var background: Float = 0
    private var amount: Float = 0

    init(sampleRate: Double) {
        func pole(_ hz: Double) -> Float { Float(1 - exp(-2 * .pi * hz / sampleRate)) }
        func step(_ seconds: Double) -> Float { Float(1 - exp(-1 / (seconds * sampleRate))) }
        highpassStep = pole(35)
        lowpassStep = pole(112)
        detectorStep = step(0.006)
        backgroundStep = step(0.235)
        attackStep = step(Self.attack)
        releaseStep = step(Self.release)
    }

    @_transparent
    mutating func gain(drumLeft: Float, drumRight: Float) -> Float {
        // Rectify each channel before linking so antiphase kicks still open the sidechain.
        let a = left.band(drumLeft, highpassStep: highpassStep, lowpassStep: lowpassStep)
        let b = right.band(drumRight, highpassStep: highpassStep, lowpassStep: lowpassStep)
        let level = max(abs(a), abs(b))
        peak += detectorStep * (level - peak)
        background += backgroundStep * (level - background)
        let excess = peak - max(0.018, 1.8 * background)
        let target = min(1, max(0, excess * Self.slope))
        amount += (target > amount ? attackStep : releaseStep) * (target - amount)
        return 1 - Self.depth * amount
    }

    // MARK: Landmark-keyed duck

    /// Kicks at or above this landmark confidence key the duck (the C-B2 measure uses the same floor).
    static let landmarkConfidence: Float = 0.5
    /// The gate opens at a kick's broadband attack and holds until this long after its 40-160 Hz rise
    /// (`LofiDrumLandmark.lowRiseFrame`), the kick body; the 3 ms attack and 100 ms release then shape it.
    static let landmarkHold = 0.040
    /// Smoother run-in before the phrase, so a kick just before it still releases into the phrase.
    static let landmarkPreroll = 0.5

    /// Per-frame bass gains for take frames `start ..< start + count`, keyed by the take's kick landmarks
    /// instead of the level detector (19 November 2026). The detector's adaptive threshold (1.8 times a
    /// 235 ms background) skipped the second kick of a double: on the 72 BPM private take half of the kicks
    /// inside sustained notes got no duck of their own and the bass was still rising out of the first
    /// kick's duck (C-B2 read -0.48 dB). Here every confident kick ducks, scaled by the square root of its
    /// strength against the take's median kick, so ghost kicks barely move the bass. Nil when the take has no confident kick
    /// (the detector then runs as before). Offline, on the renderer's thread.
    static func landmarkGains(_ landmarks: [LofiDrumLandmark], start: Int, count: Int, sampleRate: Double) -> [Float]? {
        let kicks = landmarks.filter { $0.kind == .kick && $0.confidence >= landmarkConfidence }
        guard count > 0, !kicks.isEmpty else { return nil }
        let strengths = kicks.map(\.strength).sorted()
        let reference = max(1e-6, strengths[strengths.count / 2])
        let preroll = Int(landmarkPreroll * sampleRate)
        let origin = start - preroll
        let total = preroll + count
        let hold = Int(landmarkHold * sampleRate)
        var target = [Float](repeating: 0, count: total)
        for kick in kicks {
            let from = max(0, kick.attackFrame - origin)
            let to = min(total, max(kick.attackFrame, kick.lowRiseFrame) + hold - origin)
            guard to > from else { continue }
            // Square-root scaling: a kick at half the median strength still ducks about 2.8 dB (linear
            // scaling gave the soft kicks of the 62 BPM take 1.5 dB), a ghost at a twentieth about 0.9 dB.
            let level = min(1, (kick.strength / reference).squareRoot())
            for i in from..<to where target[i] < level { target[i] = level }
        }
        func step(_ seconds: Double) -> Float { Float(1 - exp(-1 / (seconds * sampleRate))) }
        let attack = step(Self.attack), release = step(Self.release)
        var amount: Float = 0
        var gains = [Float](repeating: 1, count: count)
        for i in 0..<total {
            let t = target[i]
            amount += (t > amount ? attack : release) * (t - amount)
            if i >= preroll { gains[i - preroll] = 1 - depth * amount }
        }
        return gains
    }

    /// True when the raw bass is silent just before phrase frame `kick` (20 ms ending 2 ms before it) and
    /// sounds in the 40 ms after it: a note anchored to that kick starts there.
    static func noteStarts(on kick: Int, bass: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Bool {
        let before = kick - Int(0.022 * sampleRate), gap = kick - Int(0.002 * sampleRate)
        let after = kick + Int(0.040 * sampleRate)
        guard before >= 0, after <= count, kick >= 0 else { return false }
        var quiet: Float = 0, loud: Float = 0
        vDSP_maxmgv(bass + before, 1, &quiet, vDSP_Length(gap - before))
        vDSP_maxmgv(bass + kick, 1, &loud, vDSP_Length(after - kick))
        return loud > 1e-3 && quiet < 0.02 * loud
    }

    // MARK: Split duck

    /// The duck is split at this frequency (plan 2.3): full depth below, so the kick clears the sub, and
    /// `upperShare` of the depth above, so the body keeps sounding through the kick.
    static let splitHz = 150.0
    static let upperShare: Float = 1.0 / 3

    /// Applies per-frame duck gains `g` to the mono bass in place: `g` below `splitHz` and
    /// `1 - (1 - g) upperShare` above. The split is complementary (low = 2nd-order low-pass, high = the
    /// rest), so with no duck the bass is unchanged sample for sample. Offline, on the renderer's thread.
    static func applySplit(_ gains: [Float], to bass: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        let n = min(count, gains.count)
        guard n > 0 else { return }
        // Zero phase (forward, then backward): the bands keep the bass's timing exactly.
        var low = Array(UnsafeBufferPointer(start: bass, count: n))
        let kinds: [LofiBiquad.Kind] = [.lowpass(hz: splitHz, q: 0.707_106_781_186_547_5)]
        low.withUnsafeMutableBufferPointer { b in
            var forward = LofiFilterChain(kinds, sampleRate: sampleRate)
            forward.process(b.baseAddress!, count: n)
            vDSP_vrvrs(b.baseAddress!, 1, vDSP_Length(n))
            var backward = LofiFilterChain(kinds, sampleRate: sampleRate)
            backward.process(b.baseAddress!, count: n)
            vDSP_vrvrs(b.baseAddress!, 1, vDSP_Length(n))
        }
        // upper = 1 - (1 - g) share, low gain g: out = upper x + (g - upper) low, as two vector ramps.
        // g - upper = (1 - share)(g - 1).
        var share = upperShare, oneMinus = 1 - upperShare, rest = 1 - upperShare, minusRest = upperShare - 1
        var upper = [Float](repeating: 0, count: n), lowGain = upper
        vDSP_vsmsa(gains, 1, &share, &oneMinus, &upper, 1, vDSP_Length(n))
        vDSP_vsmsa(gains, 1, &rest, &minusRest, &lowGain, 1, vDSP_Length(n))
        vDSP_vmma(bass, 1, upper, 1, low, 1, lowGain, 1, bass, 1, vDSP_Length(n))
    }

    private struct DetectorChannel {
        var low: Float = 0
        var first: Float = 0
        var second: Float = 0

        @_transparent
        mutating func band(_ sample: Float, highpassStep: Float, lowpassStep: Float) -> Float {
            let x = sample.isFinite ? sample : 0
            low += highpassStep * (x - low)
            first += lowpassStep * ((x - low) - first)
            second += lowpassStep * (first - second)
            return second
        }
    }
}
