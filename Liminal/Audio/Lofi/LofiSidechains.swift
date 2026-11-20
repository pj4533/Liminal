import Foundation

/// The sidechain listens to low-frequency transients in the actual break. It only changes the bass gain.
/// Plan 8.3 asked for at most 3 dB; mix calibration (docs/plans/mpc-chopping-measurements.md) set 4 dB
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
