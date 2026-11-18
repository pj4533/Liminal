import Foundation

/// The sidechain listens to low-frequency transients in the actual break. It only changes the bass gain.
nonisolated struct LofiKickDuck {
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
        attackStep = step(0.004)
        releaseStep = step(0.135)
    }

    mutating func gain(drumLeft: Float, drumRight: Float) -> Float {
        // Rectify each channel before linking so antiphase kicks still open the sidechain.
        let a = left.band(drumLeft, highpassStep: highpassStep, lowpassStep: lowpassStep)
        let b = right.band(drumRight, highpassStep: highpassStep, lowpassStep: lowpassStep)
        let level = max(abs(a), abs(b))
        peak += detectorStep * (level - peak)
        background += backgroundStep * (level - background)
        let excess = peak - max(0.018, 1.8 * background)
        let target = min(1, max(0, excess * 19))
        amount += (target > amount ? attackStep : releaseStep) * (target - amount)
        return 1 - 0.30 * amount
    }

    private struct DetectorChannel {
        var low: Float = 0
        var first: Float = 0
        var second: Float = 0

        mutating func band(_ sample: Float, highpassStep: Float, lowpassStep: Float) -> Float {
            let x = sample.isFinite ? sample : 0
            low += highpassStep * (x - low)
            first += lowpassStep * ((x - low) - first)
            second += lowpassStep * (first - second)
            return second
        }
    }
}
